-- | @shomei-admin service-accounts@ (MasterPlan 7 EP-4): create, rotate, revoke, and list the
-- database-backed machine credentials that authenticate at @POST \/oauth\/token@ with the OAuth2
-- @client_credentials@ grant.
--
-- @
-- shomei-admin service-accounts create        --display-name TEXT [--scope S]...
-- shomei-admin service-accounts rotate-secret \<client_id\>
-- shomei-admin service-accounts revoke        \<client_id\>
-- shomei-admin service-accounts list
-- @
--
-- This is the runtime lifecycle the config-defined service accounts never had: creating,
-- rotating, or revoking one of those meant editing configuration and redeploying.
--
-- __The secret is generated here and printed exactly once.__ Only its SHA-256 digest is
-- persisted, so a lost secret cannot be recovered — it can only be replaced with
-- @rotate-secret@. The model is single-secret: rotation invalidates the old secret immediately,
-- with no overlap window. An operator who needs a zero-downtime handover creates a /second/
-- account, migrates consumers to it, then revokes the first.
--
-- Every service account owns a dedicated row in @shomei_users@, created here with @login_id@ set
-- to the account's @client_id@ and no password credential. That row is not a convenience: an
-- access token's @sub@ is a 'Shomei.Id.UserId' and @shomei_sessions.user_id@ has a foreign key
-- into @shomei_users@, so a token cannot be minted without one.
--
-- @create@, @rotate-secret@ and @revoke@ publish audit events; @list@ reads only, and never
-- prints a hash.
module Shomei.Admin.ServiceAccounts
  ( ServiceAccountsCommand (..),
    serviceAccountsParser,
    runServiceAccounts,

    -- * Actions

    --

    -- | The subcommands as functions that /return/ what they did, with printing left to
    --     'runServiceAccounts'. Exported so the integration suite can assert on the generated
    --     secret without capturing the process's stdout — which is not safe to do in a test
    --     runner that executes cases in parallel.
    createAction,
    rotateSecretAction,
    revokeAction,
    listAction,
  )
where

import Control.Monad (forM_)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Options.Applicative
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Crypto (generateOpaqueToken)
import Shomei.Domain.Claims (Scope (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginId (mkLoginId)
-- 'ServiceAccount' shares the field names @userId@ / @createdAt@ / @displayName@ with
-- 'Shomei.Domain.User.User'. Both are imported with @(..)@ and read by /record pattern/ only,
-- never through @OverloadedRecordDot@: a record pattern names its constructor and so is
-- unambiguous, while @user.userId@ would not be.
import Shomei.Domain.ServiceAccount (NewServiceAccount (..), ServiceAccount (..), ServiceAccountStatus (..))
import Shomei.Domain.User (NewUser (..), User (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.ServiceAccountStore
  ( ServiceAccountStore,
    createServiceAccount,
    findServiceAccountByClientId,
    listServiceAccounts,
    revokeServiceAccount,
    rotateServiceAccountSecret,
  )
import Shomei.Effect.UserStore (UserStore, createUser)
import Shomei.Error (AuthError)
import Shomei.Id (ServiceAccountDbId, UserId, genServiceAccountDbId, idText)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.ServiceAccountStore (runServiceAccountStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Workflow.ServiceToken (sha256Hex)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The command tree -----------------------------------------------------------

data ServiceAccountsCommand
  = ServiceAccountsCreate Text [Text]
  | ServiceAccountsRotateSecret Text
  | ServiceAccountsRevoke Text
  | ServiceAccountsList

serviceAccountsParser :: Parser ServiceAccountsCommand
serviceAccountsParser =
  hsubparser
    ( command "create" (info createOpts (progDesc "Create a service account; prints its secret once"))
        <> command "rotate-secret" (info (ServiceAccountsRotateSecret <$> clientIdArg) (progDesc "Replace the secret; the old one stops working immediately"))
        <> command "revoke" (info (ServiceAccountsRevoke <$> clientIdArg) (progDesc "Refuse all future tokens for this account"))
        <> command "list" (info (pure ServiceAccountsList) (progDesc "Show every service account (never its secret hash)"))
    )
  where
    createOpts =
      ServiceAccountsCreate
        <$> (Text.pack <$> strOption (long "display-name" <> metavar "TEXT" <> help "Human label, e.g. \"rei connector\""))
        <*> many (Text.pack <$> strOption (long "scope" <> metavar "SCOPE" <> help "A scope this account may request; repeatable"))
    clientIdArg = Text.pack <$> argument str (metavar "CLIENT_ID")

-- Field accessors ------------------------------------------------------------

saId :: ServiceAccount -> ServiceAccountDbId
saId ServiceAccount {serviceAccountId} = serviceAccountId

saClientId :: ServiceAccount -> Text
saClientId ServiceAccount {clientId} = clientId

saUserId :: ServiceAccount -> UserId
saUserId ServiceAccount {userId} = userId

saDisplayName :: ServiceAccount -> Text
saDisplayName ServiceAccount {displayName} = displayName

saAllowedScopes :: ServiceAccount -> Set Scope
saAllowedScopes ServiceAccount {allowedScopes} = allowedScopes

saStatus :: ServiceAccount -> ServiceAccountStatus
saStatus ServiceAccount {status} = status

saCreatedAt :: ServiceAccount -> UTCTime
saCreatedAt ServiceAccount {createdAt} = createdAt

saRotatedAt :: ServiceAccount -> Maybe UTCTime
saRotatedAt ServiceAccount {rotatedAt} = rotatedAt

-- Execution ------------------------------------------------------------------

-- | Create an account and its backing user, returning the account and the generated secret.
-- The secret is returned, never re-read: only its digest is persisted.
createAction :: AdminEnv -> Text -> [Text] -> IO (ServiceAccount, Text)
createAction env displayName rawScopes = do
  scopes <- parseScopes rawScopes
  secret <- generateOpaqueToken
  account <- runOrDie env.pool do
    said <- genServiceAccountDbId
    let cid = idText said
    ts <- now
    -- The backing principal. No password credential is created, so this row can never be
    -- logged into; it exists to satisfy the session/claims foreign keys.
    loginId <- either (const (error ("impossible: client id is not a valid login id: " <> Text.unpack cid))) pure (mkLoginId cid)
    User {userId = backingUserId} <- createUser NewUser {loginId, email = Nothing, displayName = Just displayName}
    account <-
      createServiceAccount
        NewServiceAccount
          { serviceAccountId = said,
            clientId = cid,
            userId = backingUserId,
            secretHash = sha256Hex secret,
            displayName,
            allowedScopes = scopes,
            createdAt = ts
          }
    publishAuthEvent
      ( Event.ServiceAccountCreated
          Event.ServiceAccountCreatedData
            { serviceAccountId = idText said,
              clientId = cid,
              userId = backingUserId,
              displayName,
              allowedScopes = scopes,
              occurredAt = ts
            }
      )
    pure account
  pure (account, secret)

-- | Replace the account's secret, returning it. The previous secret stops working immediately.
rotateSecretAction :: AdminEnv -> Text -> IO (ServiceAccount, Text)
rotateSecretAction env cid = do
  secret <- generateOpaqueToken
  account <- requireAccount env cid
  runOrDie env.pool do
    ts <- now
    rotateServiceAccountSecret (saId account) (sha256Hex secret) ts
    publishAuthEvent
      ( Event.ServiceAccountSecretRotated
          Event.ServiceAccountSecretRotatedData
            { serviceAccountId = idText (saId account),
              clientId = saClientId account,
              userId = saUserId account,
              occurredAt = ts
            }
      )
  pure (account, secret)

revokeAction :: AdminEnv -> Text -> IO ServiceAccount
revokeAction env cid = do
  account <- requireAccount env cid
  runOrDie env.pool do
    ts <- now
    revokeServiceAccount (saId account) ts
    publishAuthEvent
      ( Event.ServiceAccountRevoked
          Event.ServiceAccountRevokedData
            { serviceAccountId = idText (saId account),
              clientId = saClientId account,
              userId = saUserId account,
              occurredAt = ts
            }
      )
  pure account

listAction :: AdminEnv -> IO [ServiceAccount]
listAction env = runOrDie env.pool listServiceAccounts

runServiceAccounts :: AdminEnv -> ServiceAccountsCommand -> IO ()
runServiceAccounts env = \case
  ServiceAccountsCreate displayName rawScopes -> do
    (account, secret) <- createAction env displayName rawScopes
    putStrLn ("client_id:     " <> Text.unpack (saClientId account))
    putStrLn ("client_secret: " <> Text.unpack secret <> "  (shown once - store it now, it cannot be retrieved)")
    putStrLn ("scopes:        " <> renderScopes (saAllowedScopes account))
  ServiceAccountsRotateSecret cid -> do
    (account, secret) <- rotateSecretAction env cid
    putStrLn ("client_id:     " <> Text.unpack (saClientId account))
    putStrLn ("client_secret: " <> Text.unpack secret <> "  (shown once; the previous secret no longer works)")
  ServiceAccountsRevoke cid -> do
    account <- revokeAction env cid
    putStrLn ("revoked " <> Text.unpack (saClientId account))
    -- Access tokens are stateless JWTs: one minted a moment ago stays valid until it expires.
    putStrLn "note: tokens already issued to this account remain valid until they expire (default 5 minutes)"
  ServiceAccountsList -> do
    accounts <- listAction env
    forM_ accounts \a ->
      putStrLn
        ( Text.unpack (saClientId a)
            <> "  "
            <> renderStatus (saStatus a)
            <> "  "
            <> Text.unpack (saDisplayName a)
            <> "  scopes=["
            <> renderScopes (saAllowedScopes a)
            <> "]  created="
            <> show (saCreatedAt a)
            <> maybe "" (\t -> "  rotated=" <> show t) (saRotatedAt a)
        )

-- | Resolve a @client_id@ or exit 1. Every mutating subcommand names an account this way, so a
-- typo fails loudly instead of silently updating zero rows.
requireAccount :: AdminEnv -> Text -> IO ServiceAccount
requireAccount env cid = do
  found <- runOrDie env.pool (findServiceAccountByClientId cid)
  maybe (die ("no service account with client_id " <> Text.unpack cid)) pure found

renderStatus :: ServiceAccountStatus -> String
renderStatus = \case
  ServiceAccountActive -> "active "
  ServiceAccountRevoked -> "revoked"

renderScopes :: Set Scope -> String
renderScopes scopes = Text.unpack (Text.unwords [s | Scope s <- Set.toList scopes])

-- | Scopes are trimmed and must be non-blank; a scope containing whitespace could never be
-- expressed in the space-delimited OAuth2 @scope@ parameter.
parseScopes :: [Text] -> IO (Set Scope)
parseScopes raws = Set.fromList <$> traverse one raws
  where
    one raw =
      let trimmed = Text.strip raw
       in if Text.null trimmed || Text.any (== ' ') trimmed
            then die ("invalid scope: " <> show raw <> " (must be non-blank and contain no spaces)")
            else pure (Scope trimmed)

-- | The minimal chain these commands need, mirroring @Shomei.Admin.Roles.runRolesEff@.
-- @UserStore@ is present because @create@ provisions the account's backing user row.
runServiceAccountsEff ::
  Pool ->
  Eff '[UserStore, ServiceAccountStore, AuthEventPublisher, Clock, Database, Error AuthError, IOE] a ->
  IO (Either AuthError a)
runServiceAccountsEff pool =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runClockIO
    . runAuthEventPublisherPostgres
    . runServiceAccountStorePostgres
    . runUserStorePostgres

runOrDie ::
  Pool ->
  Eff '[UserStore, ServiceAccountStore, AuthEventPublisher, Clock, Database, Error AuthError, IOE] a ->
  IO a
runOrDie pool act = do
  res <- runServiceAccountsEff pool act
  either (\e -> die ("database error: " <> show e)) pure res

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
