-- | @shomei-admin@: the operational CLI (EP-4). Subcommands manage migrations, the signing-key
-- rotation lifecycle, and bootstrap user creation against a deployed Shōmei database, without the
-- HTTP server running. See @shomei-admin --help@.
module Main (main) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (secondsToDiffTime)
import Options.Applicative
import Shomei.Admin.Audit (AuditCommand, auditParser, runAudit)
import Shomei.Admin.Env (AdminEnv (..), loadAdminEnv)
import Shomei.Admin.Keys (keysActivate, keysEncryptAtRest, keysGenerate, keysList, keysRetire, keysRevoke, keysRewrap)
import Shomei.Admin.Roles (RolesCommand, rolesParser, runRoles)
import Shomei.Admin.Sweep (SweepOptions, runSweep, sweepParser)
import Shomei.Admin.Users (createUserAction)
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256), signingAlgorithmFromText)
import Shomei.Jwt.KeyProtection (KeyEncryptionKey)
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)
import Shomei.Server.Keys (loadKekFromEnv, loadNamedKekFromEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The command tree -----------------------------------------------------------

data Command
  = Migrate
  | Keys KeysCommand
  | Users UsersCommand
  | Roles RolesCommand
  | Audit AuditCommand
  | Sweep SweepOptions

data KeysCommand
  = KeysGenerate SigningAlgorithm
  | KeysActivate Text
  | KeysRetire Text
  | KeysRevoke Text
  | KeysList
  | KeysEncryptAtRest
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
          "encrypt-at-rest"
          (info (pure KeysEncryptAtRest) (progDesc "Encrypt every plaintext private key under SHOMEI_KEY_ENCRYPTION_KEY (idempotent)"))
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
    _ <- runShomeiMigrationsNoCheck (coddSettingsFromConnString env.connStr) (secondsToDiffTime 5)
    putStrLn "migrations applied"
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
      KeysEncryptAtRest -> do
        kek <- requireKek "SHOMEI_KEY_ENCRYPTION_KEY" =<< loadKekFromEnv
        keysEncryptAtRest kek env.pool
      KeysRewrap -> do
        newKek <- requireKek "SHOMEI_KEY_ENCRYPTION_KEY" =<< loadKekFromEnv
        oldKek <- requireKek "SHOMEI_KEY_ENCRYPTION_KEY_OLD" =<< loadNamedKekFromEnv "SHOMEI_KEY_ENCRYPTION_KEY_OLD"
        keysRewrap oldKek newKek env.pool
  Users (UsersCreate {email, password, displayName}) -> do
    env <- loadAdminEnv
    createUserAction env email password displayName
  Roles rc -> do
    env <- loadAdminEnv
    runRoles env rc
  Audit ac -> do
    env <- loadAdminEnv
    runAudit env ac
  Sweep opts -> do
    env <- loadAdminEnv
    runSweep env opts

-- | Demand a key-encryption key that the command cannot run without, naming the variable
-- and how to make one rather than failing with a decryption error later.
requireKek :: String -> Maybe KeyEncryptionKey -> IO KeyEncryptionKey
requireKek name = \case
  Just kek -> pure kek
  Nothing -> do
    hPutStrLn stderr ("shomei-admin: " <> name <> " is not set (32 bytes, base64: head -c 32 /dev/urandom | base64)")
    exitFailure
