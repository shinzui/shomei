-- | @shomei-migrate@: the operator CLI for Shōmei's schema.
--
-- The plan is embedded at compile time, so this binary can only ever migrate the schema
-- it was built with. The application owns configuration (@DATABASE_URL@, overridable per
-- command with @--database-url@), rendering, and the process exit code.
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
import Shomei.Migrations (resolveShomeiMigrationPlan)
import System.Environment (lookupEnv)
import System.Exit qualified as System.Exit

main :: IO ()
main = do
  plan <- resolveShomeiMigrationPlan
  parsedCommand <-
    execParser
      ( info
          (migrationCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage the Shōmei database schema" <> header "shomei-migrate")
      )
  -- Absent DATABASE_URL is fine for plan/list/check/new, which never connect. The
  -- database-backed commands fail at acquisition with a clear connection error.
  databaseUrl <- maybe "" Text.pack <$> lookupEnv "DATABASE_URL"
  let environment =
        cliEnvironment (Settings.connectionString databaseUrl) plan defaultRunOptions
  outcome <- runMigrationCommand environment parsedCommand
  case commandOutputFormat parsedCommand of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  System.Exit.exitWith (exitCode outcome.exitClass)

-- | Distinct codes so deployment automation can tell a plan/ledger mismatch from a
-- failed apply from a bad invocation.
exitCode :: ExitClass -> System.Exit.ExitCode
exitCode = \case
  ExitSucceeded -> System.Exit.ExitSuccess
  ExitVerificationFailed -> System.Exit.ExitFailure 2
  ExitUsageFailed -> System.Exit.ExitFailure 64
  ExitExecutionFailed -> System.Exit.ExitFailure 1

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat = \case
  Plan PlanOptions {output = OutputOptions format} -> format
  List ListOptions {output = OutputOptions format} -> format
  Check CheckOptions {output = OutputOptions format} -> format
  Status StatusOptions {output = OutputOptions format} -> format
  Verify VerifyOptions {output = OutputOptions format} -> format
  Up UpOptions {output = OutputOptions format} -> format
  Repair RepairOptions {output = OutputOptions format} -> format
  New NewOptions {output = OutputOptions format} -> format
