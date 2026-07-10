-- | @shomei-admin oauth-clients@ (MasterPlan 7 EP-5): register, list, and revoke the OAuth2 \/
-- OIDC relying parties that drive the authorization-code flow.
--
-- @
-- shomei-admin oauth-clients create --display-name TEXT --type confidential|public
--                                   --redirect-uri URI [--redirect-uri URI]...
--                                   [--scope S]...
-- shomei-admin oauth-clients list
-- shomei-admin oauth-clients revoke \<client_id\>
-- @
--
-- Registration is static — this CLI managing database rows — and there is no dynamic-registration
-- endpoint (RFC 7591). Nor are clients declarable in the config file: that would recreate exactly
-- the dual-source situation EP-4 is deprecating for service accounts.
--
-- __A confidential client's secret is generated here and printed exactly once.__ Only its SHA-256
-- digest is persisted. There is no @rotate-secret@ in this plan: unlike a service account, an
-- OAuth client's credential is held by an application an operator also controls, and a compromised
-- one is handled by revoking and re-registering. (Add rotation here if that proves wrong.)
--
-- A __public__ client (a browser SPA, a native or CLI app) has no secret at all. Its only binding
-- between the authorize and the token request is PKCE, which is therefore mandatory for it.
--
-- Unlike a service account, an OAuth client gets __no backing @shomei_users@ row__: it is never a
-- token subject. The token it exchanges a code for belongs to whichever user authenticated at
-- @\/oauth\/authorize@.
module Shomei.Admin.OAuthClients
  ( OAuthClientsCommand (..),
    oauthClientsParser,
    runOAuthClients,

    -- * Actions

    --

    -- | The subcommands as functions that /return/ what they did, with printing left to
    --     'runOAuthClients'. Exported so the integration suite can assert on the generated secret
    --     without capturing the process's stdout — which is not safe to do in a test runner that
    --     executes cases in parallel (an EP-4 discovery).
    createAction,
    revokeAction,
    listAction,
  )
where

import Control.Monad (forM_, unless)
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
-- Read by /record pattern/ only, never through @OverloadedRecordDot@: 'OAuthClient' shares
-- @clientId@ / @displayName@ / @createdAt@ / @status@ with 'Shomei.Domain.ServiceAccount'.
import Shomei.Domain.OAuthClient
  ( ClientType (..),
    NewOAuthClient (..),
    OAuthClient (..),
    OAuthClientStatus (..),
  )
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.OAuthClientStore
  ( OAuthClientStore,
    createOAuthClient,
    findOAuthClientByClientId,
    listOAuthClients,
    revokeOAuthClient,
  )
import Shomei.Error (AuthError)
import Shomei.Id (OAuthClientId, genOAuthClientId, idText)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.OAuthClientStore (runOAuthClientStorePostgres)
import Shomei.Workflow.ServiceToken (sha256Hex)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The command tree -----------------------------------------------------------

data OAuthClientsCommand
  = -- | display name, client type, redirect URIs, allowed scopes
    OAuthClientsCreate Text ClientType [Text] [Text]
  | OAuthClientsRevoke Text
  | OAuthClientsList

oauthClientsParser :: Parser OAuthClientsCommand
oauthClientsParser =
  hsubparser
    ( command "create" (info createOpts (progDesc "Register an OAuth2/OIDC client; prints a confidential client's secret once"))
        <> command "revoke" (info (OAuthClientsRevoke <$> clientIdArg) (progDesc "Refuse all future authorize and token requests for this client"))
        <> command "list" (info (pure OAuthClientsList) (progDesc "Show every OAuth client (never its secret hash)"))
    )
  where
    createOpts =
      OAuthClientsCreate
        <$> (Text.pack <$> strOption (long "display-name" <> metavar "TEXT" <> help "Human label, e.g. \"grafana\""))
        <*> option
          readClientType
          ( long "type"
              <> metavar "confidential|public"
              <> help "confidential: can keep a secret. public: cannot (SPA, native app); PKCE is then mandatory"
          )
        <*> many (Text.pack <$> strOption (long "redirect-uri" <> metavar "URI" <> help "An exact redirect target; repeatable. Matched by exact string equality"))
        <*> many (Text.pack <$> strOption (long "scope" <> metavar "SCOPE" <> help "A scope this client may request; repeatable"))
    clientIdArg = Text.pack <$> argument str (metavar "CLIENT_ID")

readClientType :: ReadM ClientType
readClientType = eitherReader \case
  "confidential" -> Right ConfidentialClient
  "public" -> Right PublicClient
  other -> Left ("must be confidential|public, got " <> other)

-- Field accessors ------------------------------------------------------------

ocId :: OAuthClient -> OAuthClientId
ocId OAuthClient {oauthClientId} = oauthClientId

ocClientId :: OAuthClient -> Text
ocClientId OAuthClient {clientId} = clientId

ocClientType :: OAuthClient -> ClientType
ocClientType OAuthClient {clientType} = clientType

ocDisplayName :: OAuthClient -> Text
ocDisplayName OAuthClient {displayName} = displayName

ocRedirectUris :: OAuthClient -> [Text]
ocRedirectUris OAuthClient {redirectUris} = redirectUris

ocAllowedScopes :: OAuthClient -> Set Scope
ocAllowedScopes OAuthClient {allowedScopes} = allowedScopes

ocStatus :: OAuthClient -> OAuthClientStatus
ocStatus OAuthClient {status} = status

ocCreatedAt :: OAuthClient -> UTCTime
ocCreatedAt OAuthClient {createdAt} = createdAt

-- Execution ------------------------------------------------------------------

-- | Register a client, returning it and — for a confidential client — the generated secret.
-- The secret is returned, never re-read: only its digest is persisted.
createAction :: AdminEnv -> Text -> ClientType -> [Text] -> [Text] -> IO (OAuthClient, Maybe Text)
createAction env displayName clientType rawUris rawScopes = do
  redirectUris <- parseRedirectUris rawUris
  scopes <- parseScopes rawScopes
  -- A public client is issued no secret at all, rather than one that is ignored: a credential
  -- that exists but is never checked is worse than none, because an operator will store it.
  mSecret <- case clientType of
    ConfidentialClient -> Just <$> generateOpaqueToken
    PublicClient -> pure Nothing
  client <- runOrDie env.pool do
    ocid <- genOAuthClientId
    let cid = idText ocid
    ts <- now
    client <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = ocid,
            clientId = cid,
            secretHash = sha256Hex <$> mSecret,
            clientType,
            displayName,
            redirectUris,
            allowedScopes = scopes,
            createdAt = ts
          }
    publishAuthEvent
      ( Event.OAuthClientCreated
          Event.OAuthClientCreatedData
            { oauthClientId = cid,
              clientId = cid,
              clientType = renderClientType clientType,
              displayName,
              redirectUris,
              allowedScopes = scopes,
              occurredAt = ts
            }
      )
    pure client
  pure (client, mSecret)

revokeAction :: AdminEnv -> Text -> IO OAuthClient
revokeAction env cid = do
  client <- requireClient env cid
  runOrDie env.pool do
    ts <- now
    revokeOAuthClient (ocId client) ts
    publishAuthEvent
      ( Event.OAuthClientRevoked
          Event.OAuthClientRevokedData
            { oauthClientId = idText (ocId client),
              clientId = ocClientId client,
              occurredAt = ts
            }
      )
  pure client

listAction :: AdminEnv -> IO [OAuthClient]
listAction env = runOrDie env.pool listOAuthClients

runOAuthClients :: AdminEnv -> OAuthClientsCommand -> IO ()
runOAuthClients env = \case
  OAuthClientsCreate displayName clientType rawUris rawScopes -> do
    (client, mSecret) <- createAction env displayName clientType rawUris rawScopes
    putStrLn ("client_id:     " <> Text.unpack (ocClientId client))
    case mSecret of
      Just secret ->
        putStrLn ("client_secret: " <> Text.unpack secret <> "  (shown once - store it now, it cannot be retrieved)")
      Nothing ->
        putStrLn "client_secret: (none - public client; PKCE with S256 is required at /oauth/authorize)"
    putStrLn ("redirect_uris: " <> Text.unpack (Text.unwords (ocRedirectUris client)))
    putStrLn ("scopes:        " <> renderScopes (ocAllowedScopes client))
  OAuthClientsRevoke cid -> do
    client <- revokeAction env cid
    putStrLn ("revoked " <> Text.unpack (ocClientId client))
    -- Access tokens are stateless JWTs; revoking the client stops new grants, not old tokens.
    putStrLn "note: tokens already issued through this client remain valid until they expire"
  OAuthClientsList -> do
    clients <- listAction env
    forM_ clients \c ->
      putStrLn
        ( Text.unpack (ocClientId c)
            <> "  "
            <> renderStatus (ocStatus c)
            <> "  "
            <> renderClientTypePadded (ocClientType c)
            <> "  "
            <> Text.unpack (ocDisplayName c)
            <> "  redirect_uris=["
            <> Text.unpack (Text.unwords (ocRedirectUris c))
            <> "]  scopes=["
            <> renderScopes (ocAllowedScopes c)
            <> "]  created="
            <> show (ocCreatedAt c)
        )

-- | Resolve a @client_id@ or exit 1, so a typo fails loudly instead of updating zero rows.
requireClient :: AdminEnv -> Text -> IO OAuthClient
requireClient env cid = do
  found <- runOrDie env.pool (findOAuthClientByClientId cid)
  maybe (die ("no oauth client with client_id " <> Text.unpack cid)) pure found

renderStatus :: OAuthClientStatus -> String
renderStatus = \case
  OAuthClientActive -> "active "
  OAuthClientRevoked -> "revoked"

renderClientType :: ClientType -> Text
renderClientType = \case
  ConfidentialClient -> "confidential"
  PublicClient -> "public"

renderClientTypePadded :: ClientType -> String
renderClientTypePadded = \case
  ConfidentialClient -> "confidential"
  PublicClient -> "public      "

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

-- | At least one redirect URI, each absolute and fragment-free.
--
-- A client with no registered URI could never complete a flow, and RFC 6749 §3.1.2 requires the
-- URI to be absolute and to carry no fragment (the fragment is where an implicit-flow response
-- would land, and the browser never sends it to the server anyway).
parseRedirectUris :: [Text] -> IO [Text]
parseRedirectUris raws = do
  uris <- traverse one raws
  unless (not (null uris)) (die "at least one --redirect-uri is required")
  pure uris
  where
    one raw =
      let trimmed = Text.strip raw
       in if not (any (`Text.isPrefixOf` trimmed) ["http://", "https://"])
            then die ("invalid redirect-uri: " <> show raw <> " (must be an absolute http(s) URL)")
            else
              if Text.any (== '#') trimmed
                then die ("invalid redirect-uri: " <> show raw <> " (must carry no fragment)")
                else pure trimmed

-- | The minimal chain these commands need. No @UserStore@: an OAuth client has no backing user.
runOAuthClientsEff ::
  Pool ->
  Eff '[OAuthClientStore, AuthEventPublisher, Clock, Database, Error AuthError, IOE] a ->
  IO (Either AuthError a)
runOAuthClientsEff pool =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runClockIO
    . runAuthEventPublisherPostgres
    . runOAuthClientStorePostgres

runOrDie ::
  Pool ->
  Eff '[OAuthClientStore, AuthEventPublisher, Clock, Database, Error AuthError, IOE] a ->
  IO a
runOrDie pool act = do
  res <- runOAuthClientsEff pool act
  either (\e -> die ("database error: " <> show e)) pure res

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
