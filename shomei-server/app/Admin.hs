-- | @shomei-admin@: the operational CLI (EP-4). Subcommands manage migrations, the signing-key
-- rotation lifecycle, and bootstrap user creation against a deployed Shōmei database, without the
-- HTTP server running. See @shomei-admin --help@.
module Main (main) where

import Control.Exception (finally)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Database.PostgreSQL.Migrate (MigrationReport (..))
import Options.Applicative
import Shomei.Account.Password.Domain (PlainPassword (..))
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
import System.IO (hFlush, hIsTerminalDevice, hPutStr, hPutStrLn, hSetEcho, stderr, stdin)

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
    passwordFile :: Maybe FilePath,
    displayName :: Maybe Text,
    emailVerified :: Bool
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
        <*> optional (strOption (long "password-file" <> metavar "PATH" <> help "Read the password from PATH instead of stdin"))
        <*> optional (Text.pack <$> strOption (long "display-name" <> metavar "NAME" <> help "Optional display name"))
        <*> switch (long "email-verified" <> help "Mark the bootstrap user's email as already verified")

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
  Users (UsersCreate {email, passwordFile, displayName, emailVerified}) -> do
    password <- readPasswordSecret passwordFile
    env <- loadAdminEnv
    createUserAction env email password displayName emailVerified
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

-- | Read a secret without placing it in argv. A terminal gets a no-echo prompt; redirected
-- stdin and files are consumed in full. Remove exactly one conventional line ending so
-- @printf 'secret\n'@ and a one-line secret file preserve every other byte of the password.
readPasswordSecret :: Maybe FilePath -> IO PlainPassword
readPasswordSecret source = do
  raw <- maybe readPasswordStdin TextIO.readFile source
  let password = dropOneTrailingNewline raw
  if Text.null password
    then do
      hPutStrLn stderr "shomei-admin: password must not be empty"
      exitFailure
    else pure (PlainPassword password)
  where
    readPasswordStdin = do
      interactive <- hIsTerminalDevice stdin
      if interactive
        then do
          hPutStr stderr "Password: "
          hFlush stderr
          hSetEcho stdin False
          secret <- TextIO.hGetLine stdin `finally` hSetEcho stdin True
          hPutStrLn stderr ""
          pure secret
        else TextIO.getContents

    dropOneTrailingNewline input =
      case Text.stripSuffix "\r\n" input of
        Just withoutCrLf -> withoutCrLf
        Nothing -> fromMaybe input (Text.stripSuffix "\n" input)
