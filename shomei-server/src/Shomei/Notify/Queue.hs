-- | A bounded, non-blocking notification queue shared by request handlers and the worker.
module Shomei.Notify.Queue
  ( NotifierQueue,
    EnqueueOutcome (..),
    newNotifierQueue,
    enqueueNotification,
    withDequeued,
    closeNotifierQueue,
    drainNotifierQueue,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    writeTVar,
  )
import Control.Concurrent.STM.TBQueue
  ( TBQueue,
    isFullTBQueue,
    lengthTBQueue,
    newTBQueueIO,
    readTBQueue,
    writeTBQueue,
  )
import Control.Exception (bracket)
import GHC.Clock (getMonotonicTimeNSec)
import Shomei.Account.Notification.Domain (Notification)

data NotifierQueue = NotifierQueue
  { queue :: !(TBQueue Notification),
    closed :: !(TVar Bool),
    inFlight :: !(TVar Int)
  }

data EnqueueOutcome = Enqueued | QueueFull | QueueClosed
  deriving stock (Eq, Show)

-- | Create a queue whose capacity is at least one item.
newNotifierQueue :: Int -> IO NotifierQueue
newNotifierQueue requestedCapacity = do
  q <- newTBQueueIO (fromIntegral (max 1 requestedCapacity))
  closed <- newTVarIO False
  inFlight <- newTVarIO 0
  pure NotifierQueue {queue = q, closed, inFlight}

-- | Attempt one enqueue without ever retrying or blocking.
enqueueNotification :: NotifierQueue -> Notification -> IO EnqueueOutcome
enqueueNotification notifierQueue notification = atomically do
  isClosed <- readTVar notifierQueue.closed
  if isClosed
    then pure QueueClosed
    else do
      full <- isFullTBQueue notifierQueue.queue
      if full
        then pure QueueFull
        else writeTBQueue notifierQueue.queue notification >> pure Enqueued

-- | Block for one item, mark it in flight while the action runs, and clear that mark even when
-- the delivery is cancelled or throws.
withDequeued :: NotifierQueue -> (Notification -> IO ()) -> IO ()
withDequeued notifierQueue action = bracket acquire release action
  where
    acquire = atomically do
      notification <- readTBQueue notifierQueue.queue
      modifyTVar' notifierQueue.inFlight (+ 1)
      pure notification
    release _ = atomically (modifyTVar' notifierQueue.inFlight (max 0 . subtract 1))

-- | Refuse all future enqueues. Existing queued items remain available to the worker.
closeNotifierQueue :: NotifierQueue -> IO ()
closeNotifierQueue notifierQueue = atomically (writeTVar notifierQueue.closed True)

-- | Wait until the queue is empty and no delivery is in flight, or until the monotonic deadline.
-- The returned count includes queued and in-flight items still present at the deadline.
drainNotifierQueue :: NotifierQueue -> Int -> IO Int
drainNotifierQueue notifierQueue timeoutSeconds = do
  started <- getMonotonicTimeNSec
  let deadline = started + fromIntegral (max 0 timeoutSeconds) * 1_000_000_000
      loop = do
        remaining <- atomically do
          queued <- lengthTBQueue notifierQueue.queue
          active <- readTVar notifierQueue.inFlight
          pure (fromIntegral queued + active)
        if remaining == 0
          then pure 0
          else do
            now <- getMonotonicTimeNSec
            if now >= deadline
              then pure remaining
              else threadDelay 50_000 >> loop
  loop
