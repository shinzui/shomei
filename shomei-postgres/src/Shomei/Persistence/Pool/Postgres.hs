-- | A finite, cancellation-safe pool over public Hasql connections.
-- Every slot has one owner under masking; query/network work is restored to the caller's
-- masking state, and interruption disposes the connection before returning its capacity.
module Shomei.Persistence.Pool.Postgres
  ( Pool,
    UsageError (..),
    acquirePool,
    use,
    release,
  )
where

import Control.Concurrent.STM
import Control.Exception (SomeException, finally, mask, throwIO, try)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (DiffTime)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors (ConnectionError, SessionError)
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import System.Timeout (timeout)

-- Keep the failure vocabulary stable while owning connection lifecycle explicitly.
data UsageError
  = ConnectionUsageError ConnectionError
  | SessionUsageError SessionError
  | AcquisitionTimeoutUsageError
  deriving stock (Eq, Show)

data Entry = Entry !Connection.Connection !Integer

data Pool = Pool
  { idle :: !(TQueue Entry),
    capacity :: !(TVar Int),
    generation :: !(TVar Integer),
    acquisitionMicros :: !Int,
    connectionSettings :: !Settings.Settings,
    initializeSession :: !(Session ())
  }

data Borrowed = Existing !Entry | Vacant !Integer

-- | Acquire lazily. The timeout bounds waiting for capacity; transaction deadlines also
-- cover connection establishment. Server settings validate positive sizes/timeouts.
acquirePool :: Int -> DiffTime -> Int -> Text -> IO Pool
acquirePool size acquisitionTimeout statementTimeoutMs connStr = do
  idle <- newTQueueIO
  capacity <- newTVarIO (max 1 size)
  generation <- newTVarIO 0
  let milliseconds = max 0 statementTimeoutMs
      setting = Text.pack (show milliseconds)
      setup = "SET statement_timeout = " <> setting <> "; SET idle_in_transaction_session_timeout = " <> setting
      micros = max 1 (min (toInteger (maxBound :: Int)) (floor (toRational acquisitionTimeout * 1000000)))
  pure
    Pool
      { idle,
        capacity,
        generation,
        acquisitionMicros = fromInteger micros,
        connectionSettings = Settings.connectionString connStr,
        initializeSession = Session.script setup
      }

-- | Failures discard the connection conservatively, including a closed backend reported as
-- a decoder error. Successful sessions alone return a connection for reuse.
use :: Pool -> Session a -> IO (Either UsageError a)
use pool session = mask \restore -> do
  let returnSlot = atomically (modifyTVar' pool.capacity (+ 1))
      dispose connection = Connection.release connection `finally` returnSlot
      returnEntry entry@(Entry connection epoch) = do
        reusable <- atomically do
          current <- readTVar pool.generation
          if current == epoch then writeTQueue pool.idle entry >> pure True else pure False
        if reusable then pure () else dispose connection
      execute entry@(Entry connection _) = do
        outcome <- try @SomeException (restore (Connection.use connection session))
        case outcome of
          Left interrupted -> dispose connection >> throwIO interrupted
          Right (Left err) -> dispose connection >> pure (Left (SessionUsageError err))
          Right (Right value) -> returnEntry entry >> pure (Right value)
      establish epoch = do
        acquired <- try @SomeException (restore (Connection.acquire pool.connectionSettings))
        case acquired of
          Left interrupted -> returnSlot >> throwIO interrupted
          Right (Left err) -> returnSlot >> pure (Left (ConnectionUsageError err))
          Right (Right connection) -> do
            initialized <- try @SomeException (restore (Connection.use connection pool.initializeSession))
            case initialized of
              Left interrupted -> dispose connection >> throwIO interrupted
              Right (Left err) -> dispose connection >> pure (Left (SessionUsageError err))
              Right (Right ()) -> execute (Entry connection epoch)
  -- Remain masked across the STM ownership transfer. Blocking STM is interruptible and
  -- rolls back before interruption, so cancellation cannot consume an unowned slot.
  borrowed <-
    timeout
      pool.acquisitionMicros
      ( atomically do
          available <- tryReadTQueue pool.idle
          case available of
            Just entry -> pure (Existing entry)
            Nothing -> do
              free <- readTVar pool.capacity
              check (free > 0)
              modifyTVar' pool.capacity (subtract 1)
              Vacant <$> readTVar pool.generation
      )
  case borrowed of
    Nothing -> pure (Left AcquisitionTimeoutUsageError)
    Just (Existing entry) -> execute entry
    Just (Vacant epoch) -> establish epoch

-- | Flush idle connections and retire in-flight connections on return. The same pool stays
-- usable; old and new generations share capacity, preserving the global connection ceiling.
release :: Pool -> IO ()
release pool = mask \_ -> do
  entries <- atomically do
    modifyTVar' pool.generation (+ 1)
    flushTQueue pool.idle
  failures <- traverse (try @SomeException . close) entries
  forM_ [err | Left err <- failures] throwIO
  where
    close (Entry connection _) = Connection.release connection `finally` atomically (modifyTVar' pool.capacity (+ 1))
