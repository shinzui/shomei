-- | @shomei-admin sweep@: delete expired and dead rows once, then exit.
--
-- The standalone server already runs this sweep on a background thread (see
-- @Shomei.Server.Boot.installSweeper@), which is the turnkey default. This subcommand exists
-- for operators who would rather schedule maintenance externally — a cron entry, a Kubernetes
-- CronJob — and who then set @SHOMEI_SWEEP_ENABLED=false@ on the server. Both triggers call
-- the same 'sweepOnce', so there is one implementation and two ways to fire it. Running both
-- concurrently is harmless: every delete is idempotent and a batch simply finds fewer rows.
--
-- @
-- shomei-admin sweep [--batch-size N] [--dead-session-grace-days N] [--one-time-token-grace-days N]
--                    [--ceremony-grace-minutes N] [--login-attempt-retention-days N]
--                    [--auth-event-retention-days N]
-- @
--
-- Exits 0 with one @table: count@ line per swept table, or 1 with the database error.
module Shomei.Admin.Sweep
  ( SweepOptions (..),
    defaultSweepOptions,
    sweepParser,
    sweepOptionsToConfig,
    runSweep,
    runSweepReport,
  )
where

import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Pool (UsageError)
import Options.Applicative
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Postgres.Maintenance
  ( SweepConfig (..),
    SweepReport,
    defaultSweepConfig,
    sweepOnce,
    sweepReportCounts,
  )
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | The sweep knobs as they arrive from the command line. Defaults match
-- 'defaultSweepConfig', so a bare @shomei-admin sweep@ behaves exactly like one cycle of the
-- server's background sweeper.
data SweepOptions = SweepOptions
  { optBatchSize :: !Int,
    optDeadSessionGraceDays :: !Int,
    optOneTimeTokenGraceDays :: !Int,
    optCeremonyGraceMinutes :: !Int,
    optLoginAttemptRetentionDays :: !Int,
    -- | Absent retains the audit trail forever, which is the default.
    optAuthEventRetentionDays :: !(Maybe Int)
  }

-- | A bare @shomei-admin sweep@ with no flags, i.e. one cycle of the server's background
-- sweeper. The parser's flag defaults are taken from here.
defaultSweepOptions :: SweepOptions
defaultSweepOptions =
  SweepOptions
    { optBatchSize = defaultSweepConfig.batchSize,
      optDeadSessionGraceDays = defaultSweepConfig.deadSessionGraceDays,
      optOneTimeTokenGraceDays = defaultSweepConfig.oneTimeTokenGraceDays,
      optCeremonyGraceMinutes = defaultSweepConfig.ceremonyGraceMinutes,
      optLoginAttemptRetentionDays = defaultSweepConfig.loginAttemptRetentionDays,
      optAuthEventRetentionDays = defaultSweepConfig.authEventRetentionDays
    }

sweepParser :: Parser SweepOptions
sweepParser =
  SweepOptions
    <$> intOpt "batch-size" defaultSweepOptions.optBatchSize "Rows per DELETE (sessions per DELETE, for refresh tokens)"
    <*> intOpt "dead-session-grace-days" defaultSweepOptions.optDeadSessionGraceDays "Grace before an expired or revoked session and its refresh-token family are deleted"
    <*> intOpt "one-time-token-grace-days" defaultSweepOptions.optOneTimeTokenGraceDays "Grace before expired verification/reset tokens and elapsed lockouts are deleted"
    <*> intOpt "ceremony-grace-minutes" defaultSweepOptions.optCeremonyGraceMinutes "Grace before expired WebAuthn ceremonies are deleted"
    <*> intOpt "login-attempt-retention-days" defaultSweepOptions.optLoginAttemptRetentionDays "Maximum age of login-attempt rows"
    <*> optional
      ( option
          auto
          ( long "auth-event-retention-days"
              <> metavar "N"
              <> help "Maximum age of audit events. Omit to retain the audit trail forever (the default)."
          )
      )
  where
    intOpt name def helpText =
      option
        auto
        (long name <> metavar "N" <> value def <> showDefault <> help helpText)

sweepOptionsToConfig :: SweepOptions -> SweepConfig
sweepOptionsToConfig o =
  SweepConfig
    { batchSize = o.optBatchSize,
      deadSessionGraceDays = o.optDeadSessionGraceDays,
      oneTimeTokenGraceDays = o.optOneTimeTokenGraceDays,
      ceremonyGraceMinutes = o.optCeremonyGraceMinutes,
      loginAttemptRetentionDays = o.optLoginAttemptRetentionDays,
      authEventRetentionDays = o.optAuthEventRetentionDays
    }

-- | Run one sweep against the admin pool and hand back the report. Separated from 'runSweep'
-- so tests can assert on the counts without capturing stdout or catching @exitFailure@.
runSweepReport :: AdminEnv -> SweepOptions -> IO (Either UsageError SweepReport)
runSweepReport env opts = do
  now <- getCurrentTime
  sweepOnce env.pool (sweepOptionsToConfig opts) now

-- | Sweep once, print the per-table counts, and exit non-zero if the database was unreachable.
runSweep :: AdminEnv -> SweepOptions -> IO ()
runSweep env opts =
  runSweepReport env opts >>= \case
    Left err -> do
      hPutStrLn stderr ("shomei-admin: sweep failed: " <> show err)
      exitFailure
    Right report -> putStr (renderReport opts.optAuthEventRetentionDays report)

-- | Aligned @table: count@ lines. The audit row is annotated when retention is off, so an
-- operator reading @auth_events: 0@ is never left wondering whether the sweep tried and found
-- nothing or was never asked to look.
renderReport :: Maybe Int -> SweepReport -> String
renderReport authEventRetention report =
  unlines [line table deleted | (table, deleted) <- counts]
  where
    counts = sweepReportCounts report
    width = maximum [Text.length table | (table, _) <- counts] + 2
    line table deleted =
      let label = Text.unpack table <> ":"
          padded = label <> replicate (width - length label) ' '
          suffix
            | table == "auth_events", Nothing <- authEventRetention = " (retention disabled)"
            | otherwise = ""
       in padded <> show deleted <> suffix
