-- | The house idiom for supervised background threads.
--
-- A /background thread/ here means a periodic maintenance task forked at server boot: the
-- expired-data sweeper ("Shomei.Postgres.Maintenance"), the signing-key reload
-- ("Shomei.Server.Keys"), and whatever later plans add. Every one of them wants the same
-- three things, and none of them wants a supervisor hierarchy:
--
-- 1. Run a cycle, then sleep, forever.
-- 2. If a cycle throws, log loudly and try again later — never take the server down. A failed
--    sweep is strictly less bad than downtime, and the realistic failure mode is "the database
--    was briefly unreachable", which fixes itself.
-- 3. Back off while the failure persists, so a database outage does not turn into a tight
--    retry loop that fills the disk with log lines.
--
-- 'supervisedLoop' is that, and nothing more. It is not respawned by a monitor thread, and it
-- dies with the process: fork it with plain @forkIO@ from @Shomei.Server.Boot.main@ and let
-- process exit collect it. No shutdown plumbing is needed because every cycle is idempotent —
-- a cycle interrupted by exit simply did not happen, and the next boot picks it up.
module Shomei.Server.Supervisor
  ( supervisedLoop,
    supervisedLoopMicros,
    logJsonLine,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as Text
import System.IO (stderr)

-- | Seconds to wait after the first crash.
initialBackoffSeconds :: Int
initialBackoffSeconds = 5

-- | The ceiling the backoff doubles up to. Five minutes is long enough that a night-long
-- outage costs a few hundred log lines rather than a few million, and short enough that
-- recovery is noticed promptly.
maxBackoffSeconds :: Int
maxBackoffSeconds = 300

-- | Run @cycleAction@ forever, sleeping @intervalSeconds@ between clean cycles.
--
-- The first cycle runs immediately, so a freshly booted server does its maintenance at once
-- rather than after a full interval. A crash — any synchronous 'SomeException' — is caught,
-- logged as one structured JSON line on stderr, and retried after an exponential backoff
-- (5 s, doubling to a 300 s ceiling). The backoff resets after the next clean cycle. The loop
-- never rethrows a synchronous exception.
--
-- Asynchronous exceptions are re-thrown rather than swallowed, so that killing the thread (or
-- the process shutting down) actually stops it instead of being mistaken for a failed cycle
-- and retried. @taskName@ appears in every log line this loop emits.
supervisedLoop ::
  -- | Task name, e.g. @"sweeper"@.
  Text ->
  -- | Seconds to sleep between clean cycles.
  Int ->
  -- | One cycle.
  IO () ->
  IO ()
supervisedLoop taskName intervalSeconds =
  -- A non-positive interval would spin the loop at full speed, so clamp to one second: a
  -- misconfigured task that runs too often is recoverable, one that pins a core is not.
  supervisedLoopMicros
    taskName
    (max 1 intervalSeconds * microsPerSecond)
    (initialBackoffSeconds * microsPerSecond)
    (maxBackoffSeconds * microsPerSecond)

-- | 'supervisedLoop' with every duration in microseconds and the backoff bounds given
-- explicitly. Exposed so tests can exercise the crash/backoff/recovery path in milliseconds
-- instead of minutes; production code wants 'supervisedLoop'.
supervisedLoopMicros ::
  -- | Task name.
  Text ->
  -- | Microseconds between clean cycles.
  Int ->
  -- | Microseconds to wait after the first crash.
  Int ->
  -- | Ceiling the backoff doubles up to.
  Int ->
  -- | One cycle.
  IO () ->
  IO ()
supervisedLoopMicros taskName intervalMicros initialBackoff maxBackoff cycleAction =
  loop initialBackoff
  where
    loop backoff = do
      outcome <- try cycleAction
      case outcome of
        Right () -> do
          threadDelay intervalMicros
          loop initialBackoff
        Left err
          -- A ThreadKilled or an async cancellation means someone wants this thread gone.
          | isAsyncException err -> throwIO err
          | otherwise -> do
              logCrash taskName err backoff
              threadDelay backoff
              loop (min maxBackoff (backoff * 2))

microsPerSecond :: Int
microsPerSecond = 1_000_000

-- | Is this an asynchronous exception (@ThreadKilled@, @AsyncCancelled@, a timeout)? Both
-- @AsyncException@ and @async@'s @AsyncCancelled@ route through 'SomeAsyncException', so this
-- one check covers them.
isAsyncException :: SomeException -> Bool
isAsyncException err = case fromException err of
  Just (_ :: SomeAsyncException) -> True
  Nothing -> False

-- | @backoffMicros@ is the wait about to be taken, so successive crashes log 5, 10, 20, …
logCrash :: Text -> SomeException -> Int -> IO ()
logCrash taskName err backoffMicros =
  logJsonLine
    [ "level" .= ("error" :: Text),
      "msg" .= ("background task crashed" :: Text),
      "task" .= taskName,
      "error" .= Text.pack (show err),
      "backoff_s" .= (fromIntegral backoffMicros / 1_000_000 :: Double)
    ]

-- | Emit one structured JSON log line on stderr. Background tasks log here rather than on
-- stdout, where 'Shomei.Server.Observability.Logging' emits one line per HTTP request.
logJsonLine :: [(Key, Value)] -> IO ()
logJsonLine fields = BL.hPut stderr (encode (object fields) <> "\n")
