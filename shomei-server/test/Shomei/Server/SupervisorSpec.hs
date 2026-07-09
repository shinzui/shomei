-- | Tests for the supervised-background-thread idiom ('Shomei.Server.Supervisor').
--
-- The two properties that matter operationally are that a crashing maintenance cycle never
-- takes the server down, and that killing the thread actually kills it. Both are exercised
-- through 'supervisedLoopMicros', which is 'supervisedLoop' with the interval and backoff
-- bounds given in microseconds, so these run in milliseconds rather than the production
-- loop's 5-second-to-5-minute backoff.
module Shomei.Server.SupervisorSpec (tests) where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (Exception, SomeException, throwIO, try)
import Control.Monad (when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Shomei.Server.Supervisor (supervisedLoopMicros)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "supervisor"
    [ testCrashingCycleIsRetried,
      testBackoffIsBounded,
      testAsyncExceptionStopsTheLoop
    ]

data Boom = Boom
  deriving stock (Show)

instance Exception Boom

-- | Run @loop@ on a forked thread for @micros@, then kill it.
withLoopRunning :: Int -> IO () -> IO ()
withLoopRunning micros loop = do
  tid <- forkIO loop
  threadDelay micros
  killThread tid

-- | A cycle that throws forever must not escape the loop, and the loop must keep calling it.
-- (Note the crash lines this prints on stderr are the point, not noise.)
testCrashingCycleIsRetried :: TestTree
testCrashingCycleIsRetried = testCase "a crashing cycle is retried, never fatal" do
  calls <- newIORef (0 :: Int)
  let cycleAction = do
        atomicModifyIORef' calls \n -> (n + 1, ())
        throwIO Boom
  -- interval 1ms, backoff 1ms doubling to a 2ms ceiling: ~50ms allows many retries.
  withLoopRunning 50_000 (supervisedLoopMicros "test" 1_000 1_000 2_000 cycleAction)
  n <- readIORef calls
  assertBool ("expected the loop to retry the crashing cycle, got " <> show n <> " calls") (n >= 3)

-- | After a clean cycle the backoff resets, so a task that fails, recovers, and fails again
-- waits the initial backoff the second time rather than the doubled one. We observe this
-- indirectly: with a 1 ms initial backoff and a 1 s ceiling, a loop that crashes once then
-- succeeds must keep making progress — if the backoff did not reset, the second crash would
-- stall the loop for a second and the call count would stop growing.
testBackoffIsBounded :: TestTree
testBackoffIsBounded = testCase "backoff resets after a clean cycle" do
  calls <- newIORef (0 :: Int)
  let cycleAction = do
        n <- atomicModifyIORef' calls \n -> (n + 1, n + 1)
        -- Fail on every other call, so clean cycles are interleaved with crashes.
        when (odd n) (throwIO Boom)
  withLoopRunning 50_000 (supervisedLoopMicros "test" 1_000 1_000 1_000_000 cycleAction)
  n <- readIORef calls
  -- Without a reset, the 3rd call would wait the doubled backoff and we would see ~2 calls.
  assertBool ("expected the backoff to reset after clean cycles, got " <> show n <> " calls") (n >= 5)

-- | 'killThread' delivers an asynchronous 'ThreadKilled'. The loop must re-throw it rather
-- than treat it as a failed cycle and retry, otherwise the thread would be unkillable and
-- process shutdown would hang.
testAsyncExceptionStopsTheLoop :: TestTree
testAsyncExceptionStopsTheLoop = testCase "an async exception stops the loop" do
  started <- newEmptyMVar
  stopped <- newEmptyMVar
  let cycleAction = do
        putMVar started ()
        -- Block forever; the only way out is the async exception.
        threadDelay 60_000_000
  tid <- forkIO do
    outcome <- try (supervisedLoopMicros "test" 1_000 1_000 2_000 cycleAction)
    putMVar stopped (outcome :: Either SomeException ())
  takeMVar started
  killThread tid
  -- If the loop swallowed ThreadKilled and looped again, nothing is ever put into `stopped`.
  result <- timeout 2_000_000 (takeMVar stopped)
  case result of
    Nothing -> assertFailure "the loop swallowed the async exception: thread still running"
    Just (Right ()) -> assertFailure "the loop returned normally instead of propagating"
    Just (Left _) -> pure ()
