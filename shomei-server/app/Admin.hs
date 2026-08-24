-- | @shomei-admin@: the operational CLI (EP-4). Subcommands manage migrations, the signing-key
-- rotation lifecycle, and bootstrap user creation against a deployed Shōmei database, without the
-- HTTP server running. See @shomei-admin --help@.
module Main (main) where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate (MigrationReport (..))
import Options.Applicative
import Shomei.Admin.Audit (AuditCommand, auditParser, runAudit)
import Shomei.Admin.Env (AdminEnv (..), loadAdminEnv)
import Shomei.Admin.Keys (keysActivate, keysGenerate, keysList, keysRetire, keysRevoke, keysRewrap)
import Shomei.Admin.OAuthClients (OAuthClientsCommand, oauthClientsParser, runOAuthClients)
import Shomei.Admin.Roles (RolesCommand, rolesParser, runRoles)
import Shomei.Admin.ServiceAccounts (ServiceAccountsCommand, runServiceAccounts, serviceAccountsParser)
import Shomei.Admin.Sweep (SweepOptions, runSweep, sweepParser)
import Shomei.Admin.Users (createUserAction)
import Shomei.Migrations (applyShomeiMigrations)
import Shomei.Server.Keys (loadKekFromEnv, loadNamedKekFromEnv)
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256), signingAlgorithmFromText)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The command tree -----------------------------------------------------------

data Command
  = Migrate
  | Keys KeysCommand
  | Users UsersCommand
  | Roles RolesCommand
  | ServiceAccounts ServiceAccountsCommand
  | OAuthClients OAuthClientsCommand
  | Audit AuditCommand
  | Sweep SweepOptions

data KeysCommand
  = KeysGenerate SigningAlgorithm
  | KeysActivate Text
  | KeysRetire Text
  | KeysRevoke Text
  | KeysList
  | KeysRewrap

data UsersCommand = UsersCreate
  { email :: Text,
    password :: Text,
    displayName :: Maybe Text
  }

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "migrate" (info (pure Migrate) (progDesc "Apply pending database migrations"))
        <> command "keys" (info (Keys <$> keysParser) (progDesc "Manage signing keys"))
        <> command "users" (info (Users <$> usersParser) (progDesc "Manage user accounts"))
        <> command "roles" (info (Roles <$> rolesParser) (progDesc "Declare roles and grant them to users"))
        <> command "service-accounts" (info (ServiceAccounts <$> serviceAccountsParser) (progDesc "Manage OAuth2 client_credentials machine accounts"))
        <> command "oauth-clients" (info (OAuthClients <$> oauthClientsParser) (progDesc "Manage OAuth2/OIDC clients for the authorization-code flow"))
        <> command "audit" (info (Audit <$> auditParser) (progDesc "Query the audit log / security events"))
        <> command "sweep" (info (Sweep <$> sweepParser) (progDesc "Delete expired and dead rows once, then exit"))
    )

keysParser :: Parser KeysCommand
keysParser =
  hsubparser
    ( command "generate" (info (KeysGenerate <$> algOpt) (progDesc "Mint a new signing key in pending status"))
        <> command "activate" (info (KeysActivate <$> kidArg) (progDesc "Promote a pending key to active (old one auto-retires)"))
        <> command "retire" (info (KeysRetire <$> kidArg) (progDesc "Demote an active key to retired (still trusted)"))
        <> command "revoke" (info (KeysRevoke <$> kidArg) (progDesc "Mark a key revoked (immediately untrusted)"))
        <> command "list" (info (pure KeysList) (progDesc "Show every key with kid / status / timestamps"))
        <> command
          "rewrap"
          (info (pure KeysRewrap) (progDesc "Re-encrypt every private key from SHOMEI_KEY_ENCRYPTION_KEY_OLD to SHOMEI_KEY_ENCRYPTION_KEY"))
    )
  where
    kidArg = Text.pack <$> argument str (metavar "KID")
    algOpt =
      option
        (eitherReader (either (Left . Text.unpack) Right . signingAlgorithmFromText . Text.pack))
        (long "alg" <> metavar "ES256|RS256" <> value ES256 <> showDefaultWith (const "ES256") <> help "Signing algorithm for the new key")

usersParser :: Parser UsersCommand
usersParser =
  hsubparser
    (command "create" (info createOpts (progDesc "Create a user account")))
  where
    createOpts =
      UsersCreate
        <$> (Text.pack <$> strOption (long "email" <> metavar "EMAIL" <> help "User email address"))
        <*> (Text.pack <$> strOption (long "password" <> metavar "PASSWORD" <> help "User password"))
        <*> optional (Text.pack <$> strOption (long "display-name" <> metavar "NAME" <> help "Optional display name"))

main :: IO ()
main = do
  cmd <- execParser opts
  run cmd
  where
    opts =
      info
        (commandParser <**> helper)
        (fullDesc <> progDesc "Operational CLI for a Shōmei deployment" <> header "shomei-admin")

run :: Command -> IO ()
run = \case
  Migrate -> do
    env <- loadAdminEnv
    applyShomeiMigrations env.connStr >>= \case
      Left migrationError -> do
        hPutStrLn stderr ("shomei-admin: schema migration failed: " <> show migrationError)
        exitFailure
      Right report ->
        putStrLn
          ( "migrations applied: "
              <> show (NonEmpty.length report.results)
              <> " in plan (started "
              <> show report.startedAt
              <> ", finished "
              <> show report.finishedAt
              <> "); run `shomei-migrate status` for per-migration detail"
          )
  Keys kc -> do
    env <- loadAdminEnv
    case kc of
      KeysGenerate alg -> do
        kek <- loadKekFromEnv
        keysGenerate kek alg env.pool
      KeysActivate kid -> keysActivate env.pool kid
      KeysRetire kid -> keysRetire env.pool kid
      KeysRevoke kid -> keysRevoke env.pool kid
      KeysList -> keysList env.pool
      KeysRewrap -> do
        newKek <- loadKekFromEnv
        oldKek <- loadNamedKekFromEnv "SHOMEI_KEY_ENCRYPTION_KEY_OLD"
        keysRewrap oldKek newKek env.pool
  Users (UsersCreate {email, password, displayName}) -> do
    env <- loadAdminEnv
    createUserAction env email password displayName
  Roles rc -> do
    env <- loadAdminEnv
    runRoles env rc
  ServiceAccounts sc -> do
    env <- loadAdminEnv
    runServiceAccounts env sc
  OAuthClients oc -> do
    env <- loadAdminEnv
    runOAuthClients env oc
  Audit ac -> do
    env <- loadAdminEnv
    runAudit env ac
  Sweep opts -> do
    env <- loadAdminEnv
    runSweep env opts
