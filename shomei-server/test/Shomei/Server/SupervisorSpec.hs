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
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
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

-- | Run @loop@ on a forked thread until @done@ holds, then kill it. 'False' means @done@ never
-- held within @budgetMicros@.
--
-- Waiting for a /condition/ rather than for a fixed slice of wall clock is what keeps these
-- tests honest under load: a machine running twelve test suites at once gives this thread fewer
-- scheduling slices, and "did N cycles happen in 50 ms?" then answers no for reasons that have
-- nothing to do with the supervisor. The budget is deliberately orders of magnitude larger than
-- any of the delays under test, so it only fires when the loop is genuinely stuck.
runLoopUntil :: Int -> IO Bool -> IO () -> IO Bool
runLoopUntil budgetMicros done loop = do
  tid <- forkIO loop
  reached <- timeout budgetMicros poll
  killThread tid
  pure (reached == Just ())
  where
    poll = do
      finished <- done
      if finished then pure () else threadDelay 500 >> poll

-- | A cycle that throws forever must not escape the loop, and the loop must keep calling it.
-- (Note the crash lines this prints on stderr are the point, not noise.)
testCrashingCycleIsRetried :: TestTree
testCrashingCycleIsRetried = testCase "a crashing cycle is retried, never fatal" do
  calls <- newIORef (0 :: Int)
  let cycleAction = do
        atomicModifyIORef' calls \n -> (n + 1, ())
        throwIO Boom
  -- interval 1ms, backoff 1ms doubling to a 2ms ceiling: three retries need ~5ms of delays.
  retried <- runLoopUntil 10_000_000 ((>= 3) <$> readIORef calls) (supervisedLoopMicros "test" 1_000 1_000 2_000 cycleAction)
  n <- readIORef calls
  assertBool ("expected the loop to retry the crashing cycle, got " <> show n <> " calls") retried

-- | After a clean cycle the backoff resets, so the next crash waits the /initial/ backoff
-- rather than the doubled one it had grown to.
--
-- Measured directly rather than inferred from a call count. Three consecutive crashes grow the
-- backoff to 50 → 100 → 200 ms, so a fourth crash would wait 400 ms. Cycle 4 is clean, which
-- must reset the backoff; cycle 5 crashes, and the gap to cycle 6 is the wait it actually took.
-- With the reset that gap is ~50 ms; without it, ~400 ms. Asserting @< 250 ms@ separates the two
-- by a margin far wider than any scheduling jitter, which is measured in milliseconds.
testBackoffIsBounded :: TestTree
testBackoffIsBounded = testCase "backoff resets after a clean cycle" do
  ticks <- newIORef ([] :: [Word64]) -- reverse-ordered start time of each cycle
  let cycleAction = do
        t <- getMonotonicTimeNSec
        n <- atomicModifyIORef' ticks \ts -> (t : ts, length ts + 1)
        when (n <= 3 || n == 5) (throwIO Boom)
  reached <- runLoopUntil 30_000_000 ((>= 6) . length <$> readIORef ticks) (supervisedLoopMicros "test" 1_000 50_000 5_000_000 cycleAction)
  assertBool "the loop never reached its sixth cycle" reached
  ts <- reverse <$> readIORef ticks
  case ts of
    (_ : _ : _ : _ : fifth : sixth : _) -> do
      let gapMs = fromIntegral (sixth - fifth) / 1e6 :: Double
      assertBool
        ("the backoff did not reset after the clean cycle: waited " <> show gapMs <> "ms, expected ~50ms")
        (gapMs < 250)
    _ -> assertFailure ("expected at least six cycles, got " <> show (length ts))

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
