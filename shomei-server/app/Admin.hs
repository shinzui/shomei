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
import Shomei.Admin.Keys (keysActivate, keysGenerate, keysList, keysRetire, keysRevoke)
import Shomei.Admin.Users (createUserAction)
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256), signingAlgorithmFromText)
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)

-- The command tree -----------------------------------------------------------

data Command
  = Migrate
  | Keys KeysCommand
  | Users UsersCommand
  | Audit AuditCommand

data KeysCommand
  = KeysGenerate SigningAlgorithm
  | KeysActivate Text
  | KeysRetire Text
  | KeysRevoke Text
  | KeysList

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
        <> command "audit" (info (Audit <$> auditParser) (progDesc "Query the audit log / security events"))
    )

keysParser :: Parser KeysCommand
keysParser =
  hsubparser
    ( command "generate" (info (KeysGenerate <$> algOpt) (progDesc "Mint a new signing key in pending status"))
        <> command "activate" (info (KeysActivate <$> kidArg) (progDesc "Promote a pending key to active (old one auto-retires)"))
        <> command "retire" (info (KeysRetire <$> kidArg) (progDesc "Demote an active key to retired (still trusted)"))
        <> command "revoke" (info (KeysRevoke <$> kidArg) (progDesc "Mark a key revoked (immediately untrusted)"))
        <> command "list" (info (pure KeysList) (progDesc "Show every key with kid / status / timestamps"))
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
      KeysGenerate alg -> keysGenerate alg env.pool
      KeysActivate kid -> keysActivate env.pool kid
      KeysRetire kid -> keysRetire env.pool kid
      KeysRevoke kid -> keysRevoke env.pool kid
      KeysList -> keysList env.pool
  Users (UsersCreate {email, password, displayName}) -> do
    env <- loadAdminEnv
    createUserAction env email password displayName
  Audit ac -> do
    env <- loadAdminEnv
    runAudit env ac
