{-# LANGUAGE TypeApplications #-}

-- | End-to-end HTTP test for @shomei-servant@.
--
-- Boots the 'ShomeiAPI' server in-process on an ephemeral port with a /hybrid/
-- interpreter stack — EP-2's in-memory stores together with EP-4's real @jose@ ES256
-- signer and verifier — so signing and verification are genuinely exercised (not
-- stubbed). Then drives @http-client@ requests and asserts the behaviors from the
-- plan's Purpose: signup, login, me (+ 401 on missing/garbage token), refresh
-- rotation, the public JWKS document, and the @RequireRole "admin"@ guard (403/200).
module Main (main) where

import Crypto.JOSE.Compact (decodeCompact)
import Crypto.JOSE.Error (runJOSE)
import Crypto.JOSE.JWK (JWK, JWKSet)
import Crypto.JWT (ClaimsSet, JWTError, SignedJWT, defaultJWTValidationSettings, verifyClaims)
import Data.Aeson (Value (..), decode, encode, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Effectful (Eff, runEff)
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    applyBasicAuth,
    defaultManagerSettings,
    httpLbs,
    method,
    newManager,
    parseRequest,
    redirectCount,
    requestBody,
    requestHeaders,
    responseBody,
    responseHeaders,
    responseStatus,
    urlEncodedBody,
  )
import Network.HTTP.Types (Header, statusCode)
import Network.HTTP.Types.URI (parseSimpleQuery, urlEncode)
import Network.Wai (Application, Request)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant
  ( Context (EmptyContext, (:.)),
    ErrorFormatters,
    Get,
    Handler,
    JSON,
    NamedRoutes,
    Proxy (Proxy),
    Server,
    serveWithContext,
    type (:<|>) ((:<|>)),
    type (:>),
  )
import Servant.Server.Experimental.Auth (AuthHandler)
import Shomei.Config (ImpersonationConfig (..), NotifierConfig (..), OAuthConfig (..), ServiceAccountConfig (..), ServiceAccountId (..), ServiceTokenConfig (..), ShomeiConfig (..), TokenTransport (..), TotpConfig (..), defaultShomeiConfig)
import Shomei.Totp (TotpSecret (..), base32ToSecret, totpCode, totpCounter)
import Shomei.Domain.AuthorizationCode (AuthorizationCode (..))
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Permission (..), Role (..), Scope (..))
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (emailText, mkEmail)
import Shomei.Domain.LoginAttempt (AccountKey (..))
import Shomei.Domain.LoginId (mkLoginId)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OAuthClient (ClientType (..), NewOAuthClient (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Domain.Passkey (PublicKeyBytes (..), UserHandle (..), WebAuthnCredentialId (..))
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.ServiceAccount (NewServiceAccount (..))
import Shomei.Domain.Session (Session (..), SessionStatus (SessionRevoked))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.InMemory
  ( World (..),
    emptyWorld,
    runAuthEventPublisher,
    runAuthEventReader,
    runAuthUnitOfWork,
    runClaimsEnricherNull,
    runClock,
    runCredentialStore,
    runInMemory,
    runLoginAttemptStore,
    runNotifier,
    runOAuthClientStore,
    runOAuthCodeStore,
    runPasskeyStore,
    runPasswordBreachCheckerFake,
    runPasswordHasher,
    runPasswordResetTokenStore,
    runPendingCeremonyStore,
    runRecoveryCodeStore,
    runRefreshTokenStore,
    runRoleStore,
    runServiceAccountStore,
    runSessionStore,
    runSigningKeyStore,
    runTokenGen,
    runTotpCredentialStore,
    runUserStore,
    runVerificationTokenStore,
    runWebAuthnCeremonyFake,
  )
import Shomei.Effect.Clock (now)
import Shomei.Effect.OAuthClientStore (createOAuthClient)
import Shomei.Effect.RoleStore (allowPermission, defineRole, disallowPermission)
import Shomei.Effect.ServiceAccountStore (createServiceAccount)
import Shomei.Id (UserId, genOAuthClientId, genServiceAccountDbId, genSessionId, genUserId, idText, parseId)
import Shomei.Jwt.Jwks (KeySet (..), jwksDocument, keySetPublicJwks)
import Shomei.Jwt.Key (generateSigningKey)
import Shomei.Jwt.Sign (runTokenSignerJwt, signAccessToken)
import Shomei.Jwt.Verify (runTokenVerifierJwt, verifyToken)
import Shomei.Prelude ((&), (.~), (^.))
import Shomei.Servant.API (ShomeiRoutes)
import Shomei.Servant.Auth (AuthUser, authHandler, cookiePolicyFromConfig)
import Shomei.Servant.Authz (RequirePermission, RequireRole, RequireScope)
import Shomei.Servant.DTO (UserResponse)
import Shomei.Servant.Error (shomeiErrorFormatters)
import Shomei.Servant.Handlers (shomeiRoutes)
import Shomei.Servant.Middleware (problemMiddleware)
import Shomei.Servant.Seam (AppEffects, Env (..))
import Shomei.Workflow qualified as Wf
import Shomei.Workflow.OAuthTokenGrant (pkceChallengeFor)
import Shomei.Workflow.Roles (grantRoleTo, revokeRoleFrom)
import Shomei.Workflow.ServiceToken (sha256Hex)
import Shomei.Workflow.TokenExchange (tokenExchangeSubjectScope)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

serviceAccount :: ServiceAccountId
serviceAccount = ServiceAccountId "connector:rei"

serviceLoginId :: Text
serviceLoginId = "connector-rei"

serviceSecret :: Text
serviceSecret = "test-secret"

servicePassword :: Text
servicePassword = "correct horse battery staple"

ingestScope :: Scope
ingestScope = Scope "kawa:ingest"

-- | The test API: the whole served Shōmei tree ('ShomeiRoutes', so application routes answer
-- under @\/v1@ exactly as they do in production) plus two host routes protected /only/ by the
-- 'RequireRole' and 'RequireScope' combinators. Their handlers contain no authorization code
-- at all, so the 401/403/200 assertions below prove the route type alone enforces — which is
-- the entire point of the combinators having 'HasServer' instances.
--
-- The two host routes are deliberately unversioned: they belong to the embedding application,
-- not to Shōmei, and a host is free to shape its own paths.
--
-- The combinators sit where 'Authenticated' used to: they run the same auth handler themselves
-- and pass the resulting 'AuthUser' through to the handler.
type TestAPI =
  NamedRoutes ShomeiRoutes
    :<|> RequireRole "admin" :> "admin" :> "users" :> Get '[JSON] [UserResponse]
    :<|> RequireScope "kawa:ingest" :> "ingest" :> Get '[JSON] [UserResponse]
    :<|> RequirePermission "projects:write" :> "host" :> "projects" :> Get '[JSON] [UserResponse]

testServer :: Env -> Server TestAPI
testServer env = shomeiRoutes env :<|> adminUsersH :<|> ingestH :<|> projectsH
  where
    adminUsersH :: AuthUser -> Handler [UserResponse]
    adminUsersH _user = pure []
    ingestH :: AuthUser -> Handler [UserResponse]
    ingestH _user = pure []
    -- No authorization code of its own: the RequirePermission combinator alone gates it.
    projectsH :: AuthUser -> Handler [UserResponse]
    projectsH _user = pure []

-- | The test app wraps the Servant application in 'problemMiddleware', exactly as
-- 'Shomei.Server.Boot.application' does, so the 405 assertions exercise the real stack.
app :: Env -> Application
app env = problemMiddleware (serveWithContext (Proxy @TestAPI) ctx (testServer env))
  where
    ctx :: Context '[AuthHandler Request AuthUser, ErrorFormatters]
    ctx =
      authHandler (cookiePolicyFromConfig env.config) env.verifier
        :. shomeiErrorFormatters
        :. EmptyContext

-- | The hybrid runner: in-memory stores + real @jose@ signer/verifier, in the same
-- effect order as EP-2's @runInMemory@ (so 'AppEffects' lines up).
runHybrid :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> Eff AppEffects a -> IO a
runHybrid ref jwk jwkset cfg =
  runEff
    . runTokenGen ref
    . runClock ref
    . runSigningKeyStore ref
    . runAuthEventReader ref
    . runAuthEventPublisher ref
    . runTokenVerifierJwt jwkset cfg
    . runTokenSignerJwt jwk cfg
    . runPasswordHasher ref
    . runPasswordBreachCheckerFake ref
    . runWebAuthnCeremonyFake ref
    . runClaimsEnricherNull
    . runNotifier ref
    . runRecoveryCodeStore ref
    . runTotpCredentialStore ref
    . runOAuthCodeStore ref
    . runOAuthClientStore ref
    . runServiceAccountStore ref
    . runPendingCeremonyStore ref
    . runPasskeyStore ref
    . runLoginAttemptStore ref
    . runPasswordResetTokenStore ref
    . runVerificationTokenStore ref
    . runAuthUnitOfWork ref
    . runRefreshTokenStore ref
    . runSessionStore ref
    . runCredentialStore ref
    . runRoleStore ref
    . runUserStore ref

-- | Grant the @admin@ role to a user through the real audited workflow, straight against the
-- in-memory world the server is running on. The next token minted for that user (by login or
-- refresh) will carry the role.
grantAdminTo :: IORef World -> Text -> IO ()
grantAdminTo ref userIdText = do
  uid <- parseUserId userIdText
  outcome <- runInMemory ref (grantRoleTo Nothing Nothing uid (Role "admin"))
  case outcome of
    Right True -> pure ()
    Right False -> assertFailure "expected the admin grant to be new"
    Left e -> assertFailure ("granting admin failed: " <> show e)

-- | The inverse. The next token minted for the user carries no @admin@ role.
revokeAdminFrom :: IORef World -> Text -> IO ()
revokeAdminFrom ref userIdText = do
  uid <- parseUserId userIdText
  outcome <- runInMemory ref (revokeRoleFrom Nothing uid (Role "admin"))
  case outcome of
    Right True -> pure ()
    Right False -> assertFailure "expected an admin grant to revoke"
    Left e -> assertFailure ("revoking admin failed: " <> show e)

parseUserId :: Text -> IO UserId
parseUserId t =
  either (\e -> assertFailure ("bad user id " <> show t <> ": " <> show e)) pure (parseId t)

-- | EP-9 host helpers over the in-memory world: define a role, wire a permission on or off it,
-- and grant a role to a user through the audited workflow — the operator moves a token check
-- into the store, exactly as @shomei-admin roles@ would on a real box.
defineRoleIn :: IORef World -> Role -> IO ()
defineRoleIn ref role =
  runInMemory ref do
    ts <- now
    _ <- defineRole role Nothing ts
    pure ()

allowPermissionIn :: IORef World -> Role -> Permission -> IO ()
allowPermissionIn ref role perm =
  runInMemory ref do
    ts <- now
    _ <- allowPermission role perm ts
    pure ()

disallowPermissionIn :: IORef World -> Role -> Permission -> IO ()
disallowPermissionIn ref role perm =
  runInMemory ref do
    _ <- disallowPermission role perm
    pure ()

grantRoleIn :: IORef World -> Text -> Role -> IO ()
grantRoleIn ref userIdText role = do
  uid <- parseUserId userIdText
  outcome <- runInMemory ref (grantRoleTo Nothing Nothing uid role)
  either (\e -> assertFailure ("granting " <> show role <> " failed: " <> show e)) (const (pure ())) outcome

-- | Mint an access token carrying the @admin@ role by signing claims directly with the in-test
-- key. Kept alongside the real grant path in (g): it isolates the combinator's claim check from
-- the store, so a failure in one does not mask a failure in the other.
mkAdminToken :: JWK -> ShomeiConfig -> IO Text
mkAdminToken jwk cfg = do
  uid <- genUserId
  sid <- genSessionId
  t <- getCurrentTime
  let claims =
        AuthClaims
          { subject = uid,
            sessionId = sid,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = t,
            expiresAt = addUTCTime 900 t,
            scopes = Set.empty,
            roles = Set.fromList [Role "admin"],
            permissions = Set.empty,
            actor = Nothing,
            extraClaims = mempty
          }
  r <- signAccessToken jwk claims
  case r of
    Right (AccessToken tok) -> pure tok
    Left e -> assertFailure ("admin token signing failed: " <> show e)

-- | Mint a fresh access token carrying the impersonation scope (the workflows issue no
-- scopes, so a token holding @impersonate:user@ must be signed directly). Issued at the
-- world clock @t0@, so the freshness check passes against the in-memory 'Clock'.
-- | Mint an access token for a /named/ subject with the given roles, scopes, and (optional)
-- impersonation actor. EP-2's admin tests need this: the self-target refusal compares the token's
-- subject with the target, and the delegated-token refusal keys off the @act@ claim.
mkTokenFor :: JWK -> ShomeiConfig -> UserId -> Set.Set Role -> Set.Set Scope -> Maybe UserId -> IO Text
mkTokenFor jwk cfg uid roles scopes actor = do
  sid <- genSessionId
  t <- getCurrentTime
  let claims =
        AuthClaims
          { subject = uid,
            sessionId = sid,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = t,
            expiresAt = addUTCTime 900 t,
            scopes = scopes,
            roles = roles,
            permissions = Set.empty,
            actor = actor,
            extraClaims = mempty
          }
  r <- signAccessToken jwk claims
  case r of
    Right (AccessToken tok) -> pure tok
    Left e -> assertFailure ("could not sign token: " <> show e)

mkImpersonatorToken :: JWK -> ShomeiConfig -> UTCTime -> IO Text
mkImpersonatorToken jwk cfg t = do
  uid <- genUserId
  sid <- genSessionId
  let claims =
        AuthClaims
          { subject = uid,
            sessionId = sid,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = t,
            expiresAt = addUTCTime 900 t,
            scopes = Set.fromList [cfg.impersonationConfig.impersonateScope],
            roles = Set.empty,
            permissions = Set.empty,
            actor = Nothing,
            extraClaims = mempty
          }
  r <- signAccessToken jwk claims
  case r of
    Right (AccessToken tok) -> pure tok
    Left e -> assertFailure ("impersonator token signing failed: " <> show e)

main :: IO ()
main = do
  jwk <- generateSigningKey
  let cfg = defaultShomeiConfig (Issuer "https://shomei.test") (Audience "shomei-clients")
      jwkset = keySetPublicJwks (KeySet jwk [])
  t0 <- getCurrentTime
  ref <- newIORef (emptyWorld t0)
  -- Build an 'Env' over a FRESH in-memory World. Each test case that mutates state must use
  -- its own env: tasty runs cases in parallel, so sharing one World IORef races.
  let mkEnvWith cfg' r =
        Env
          { runPorts = runHybrid r jwk jwkset cfg',
            config = cfg',
            verifier = verifyToken jwkset cfg',
            jwksJson = pure (fromMaybe (Object KM.empty) (decode (jwksDocument [jwk]))),
            accountKeyOf = AccountKey
          }
      mkEnv = mkEnvWith cfg
      freshEnv = mkEnv <$> newIORef (emptyWorld t0)
      -- 'emailVerificationRequired' on, over its own World. The World ref comes back too, so
      -- the scenario can read the verification token the notifier captured.
      freshGatedEnv = do
        r <- newIORef (emptyWorld t0)
        pure (r, mkEnvWith gatedCfg r)
      -- The World ref comes back so the RequirePermission scenario can wire roles/permissions
      -- and grant them, exactly as an operator would through the admin CLI.
      freshPermissionEnv = do
        r <- newIORef (emptyWorld t0)
        pure (r, mkEnv r)
      gatedCfg = cfg {notifierConfig = cfg.notifierConfig {emailVerificationRequired = True}}
      -- One env per transport, each over its own World (tasty runs cases in parallel).
      cookieCfg = cfg {tokenTransport = HttpOnlyCookie}
      bothCfg = cfg {tokenTransport = BearerAndCookie}
      freshCookieEnv = mkEnvWith cookieCfg <$> newIORef (emptyWorld t0)
      freshBothEnv = mkEnvWith bothCfg <$> newIORef (emptyWorld t0)
      freshServiceEnv = do
        r <- newIORef (emptyWorld t0)
        serviceUser <- seedServiceUser r jwk jwkset cfg
        let serviceCfg =
              cfg
                & #serviceTokenConfig
                .~ ServiceTokenConfig
                  { enabled = True,
                    ttl = 300,
                    accounts =
                      [ ServiceAccountConfig
                          { accountId = serviceAccount,
                            userId = serviceUser ^. #userId,
                            secretHash = sha256Hex serviceSecret,
                            allowedScopes = Set.singleton ingestScope
                          }
                      ]
                  }
        pure (mkEnvWith serviceCfg r)
      -- EP-4: a database-backed service account (not a config-defined one) in its own World.
      -- Returns its client_id, which the scenario authenticates with. Note this uses the plain
      -- 'cfg': the DB path deliberately does not consult serviceTokenConfig.enabled.
      freshOAuthEnv = do
        r <- newIORef (emptyWorld t0)
        clientId <- seedOAuthAccount r jwk jwkset cfg t0
        pure (clientId, mkEnv r)
      -- EP-5: the OIDC provider switched on. The issuer doubles as the published base URL, so
      -- every endpoint in the discovery document is derived from 'cfg's issuer.
      oidcCfg = cfg {oauthConfig = cfg.oauthConfig {oidcEnabled = True}}
      freshOidcEnv = mkEnvWith oidcCfg <$> newIORef (emptyWorld t0)
      -- EP-5 M2: an OIDC-enabled world holding one confidential and one public client. Returns
      -- the World ref (so a scenario can read the stored code row) and both client ids.
      freshAuthorizeEnv loginUrl = do
        r <- newIORef (emptyWorld t0)
        let c = oidcCfg {oauthConfig = oidcCfg.oauthConfig {loginUrl}}
        (confId, pubId) <- seedOAuthClients r jwk jwkset c t0
        pure (r, confId, pubId, mkEnvWith c r)
      -- EP-2's admin scenarios need the World ref (to grant the admin role in the store) and
      -- the signing key (to mint scoped/delegated tokens by hand).
      freshAdminEnv = do
        r <- newIORef (emptyWorld t0)
        pure (r, mkEnv r)
      -- EP-6: a world holding two database-backed service accounts — one with the
      -- token-exchange:subject gate scope, one without — for the RFC 8693 on-behalf-of scenario.
      freshExchangeEnv = do
        r <- newIORef (emptyWorld t0)
        gateId <- seedExchangeAccount r jwk jwkset cfg t0 "svcgate" (Set.fromList [ingestScope, tokenExchangeSubjectScope])
        noGateId <- seedExchangeAccount r jwk jwkset cfg t0 "svcnogate" (Set.singleton ingestScope)
        pure (gateId, noGateId, mkEnv r)
      -- EP-7: TOTP enabled, over its own World. The World ref comes back so the scenario can
      -- read (and advance) the deterministic clock to move TOTP time-step counters forward.
      totpCfg = cfg {totpConfig = cfg.totpConfig {totpEnabled = True}}
      freshTotpEnv = do
        r <- newIORef (emptyWorld t0)
        pure (r, mkEnvWith totpCfg r)
      env = mkEnv ref
  adminToken <- mkAdminToken jwk cfg
  impToken <- mkImpersonatorToken jwk cfg t0
  -- An operator token issued well before the freshness window opens, for the stale-actor refusal.
  staleImpToken <- mkImpersonatorToken jwk cfg (addUTCTime (negate 1000) t0)
  defaultMain (tests ref env freshEnv freshGatedEnv freshPermissionEnv freshCookieEnv freshBothEnv freshServiceEnv freshOAuthEnv freshOidcEnv freshAuthorizeEnv freshAdminEnv freshExchangeEnv freshTotpEnv jwk cfg adminToken impToken staleImpToken)

seedServiceUser :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> IO User
seedServiceUser ref jwk jwkset cfg = do
  loginId <- either (assertFailure . ("bad service login id: " <>) . show) pure (mkLoginId serviceLoginId)
  email <- either (assertFailure . ("bad service email: " <>) . show) pure (mkEmail "connector-rei@example.com")
  result <-
    runHybrid
      ref
      jwk
      jwkset
      cfg
      ( Wf.signup
          cfg
          SignupCommand
            { loginId,
              email = Just email,
              password = PlainPassword servicePassword,
              displayName = Just "Connector Rei"
            }
      )
  case result of
    Right (user, _) -> pure user
    Left err -> assertFailure ("service user signup failed: " <> show err)

-- | EP-4: seed a database-backed service account (and its backing user) into the in-memory
-- world, returning its @client_id@. The secret is 'oauthClientSecret'.
seedOAuthAccount :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> UTCTime -> IO Text
seedOAuthAccount ref jwk jwkset cfg createdAt = do
  serviceUser <- seedServiceUser ref jwk jwkset cfg
  runHybrid ref jwk jwkset cfg do
    said <- genServiceAccountDbId
    account <-
      createServiceAccount
        NewServiceAccount
          { serviceAccountId = said,
            clientId = idText said,
            userId = serviceUser ^. #userId,
            secretHash = sha256Hex oauthClientSecret,
            displayName = "rei connector",
            allowedScopes = Set.singleton ingestScope,
            createdAt
          }
    pure (account ^. #clientId)

oauthClientSecret :: Text
oauthClientSecret = "oauth-test-secret"

-- | EP-6: sign up a uniquely-named backing user (so several service accounts can coexist in one
-- world without colliding on the fixed 'seedServiceUser' identity).
seedServiceUserNamed :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> Text -> IO User
seedServiceUserNamed ref jwk jwkset cfg name = do
  loginId <- either (assertFailure . ("bad service login id: " <>) . show) pure (mkLoginId name)
  email <- either (assertFailure . ("bad service email: " <>) . show) pure (mkEmail (name <> "@example.com"))
  result <-
    runHybrid
      ref
      jwk
      jwkset
      cfg
      (Wf.signup cfg SignupCommand {loginId, email = Just email, password = PlainPassword servicePassword, displayName = Just name})
  case result of
    Right (user, _) -> pure user
    Left err -> assertFailure ("named service user signup failed: " <> show err)

-- | EP-6: seed a database-backed service account with an explicit scope set, returning its
-- @client_id@. The secret is 'oauthClientSecret'.
seedExchangeAccount :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> UTCTime -> Text -> Set.Set Scope -> IO Text
seedExchangeAccount ref jwk jwkset cfg createdAt name scopes = do
  serviceUser <- seedServiceUserNamed ref jwk jwkset cfg name
  runHybrid ref jwk jwkset cfg do
    said <- genServiceAccountDbId
    account <-
      createServiceAccount
        NewServiceAccount
          { serviceAccountId = said,
            clientId = idText said,
            userId = serviceUser ^. #userId,
            secretHash = sha256Hex oauthClientSecret,
            displayName = name,
            allowedScopes = scopes,
            createdAt
          }
    pure (account ^. #clientId)

-- | EP-4: @POST \/oauth\/token@ end to end, over the real Servant tree.
--
-- Proves the three things a stock OAuth2 client depends on: both client-authentication methods
-- work; a minted token is a real Shōmei token that satisfies the 'RequireScope' combinator on a
-- downstream route; and every failure is an RFC 6749 §5.2 object rather than a problem document.
scenarioOAuthToken :: Text -> Int -> IO ()
scenarioOAuthToken clientId port = do
  mgr <- newManager defaultManagerSettings

  -- (1) client_secret_basic, with an explicit in-allow-list scope.
  basic <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (clientId, oauthClientSecret))
      [("grant_type", "client_credentials"), ("scope", "kawa:ingest")]
  let (basicStatus, basicHdrs, basicBody) = basic
  basicStatus @?= 200
  -- RFC 6749 §5.1 requires the token response to be uncacheable.
  headerValue "Cache-Control" basicHdrs @?= Just "no-store"
  headerValue "Pragma" basicHdrs @?= Just "no-cache"
  doc <- must "basic: body" basicBody
  (dig ["token_type"] doc >>= asText) @?= Just "Bearer"
  (dig ["scope"] doc >>= asText) @?= Just "kawa:ingest"
  case dig ["expires_in"] doc of
    Just (Number n) -> (round n :: Int) @?= 300
    other -> assertFailure ("basic: expires_in not a number: " <> show other)
  token <- must "basic: access_token" (dig ["access_token"] doc >>= asText)

  -- (2) The minted token is a real Shōmei token: it satisfies the RequireScope combinator on a
  -- host route that contains no authorization code of its own.
  (ingestStatus, _) <- getJSON mgr port "/ingest" [("Authorization", "Bearer " <> Text.encodeUtf8 token)]
  ingestStatus @?= 200

  -- (3) client_secret_post: credentials in the body instead of the header. No scope parameter,
  -- so the account's whole allow-list is granted and echoed back.
  post <-
    postForm
      mgr
      port
      "/oauth/token"
      Nothing
      [ ("grant_type", "client_credentials"),
        ("client_id", Text.encodeUtf8 clientId),
        ("client_secret", Text.encodeUtf8 oauthClientSecret)
      ]
  let (postStatus, _, postBody) = post
  postStatus @?= 200
  postDoc <- must "post: body" postBody
  (dig ["scope"] postDoc >>= asText) @?= Just "kawa:ingest"

  -- (4) A wrong secret is invalid_client, with the Basic challenge.
  badSecret <-
    postForm mgr port "/oauth/token" (Just (clientId, "wrong")) [("grant_type", "client_credentials")]
  assertOAuthError "wrong secret" 401 "invalid_client" badSecret
  headerValue "WWW-Authenticate" (headersOf badSecret) @?= Just "Basic realm=\"shomei\""

  -- (5) An unknown client is the SAME response, byte for byte in its body: nothing discloses
  -- whether the client id exists.
  unknown <-
    postForm mgr port "/oauth/token" (Just ("svcacct_nope", "wrong")) [("grant_type", "client_credentials")]
  assertOAuthError "unknown client" 401 "invalid_client" unknown
  bodyOf unknown @?= bodyOf badSecret

  -- (6) No credentials at all is also invalid_client.
  noCreds <- postForm mgr port "/oauth/token" Nothing [("grant_type", "client_credentials")]
  assertOAuthError "no credentials" 401 "invalid_client" noCreds

  -- (7) A scope outside allowed_scopes is invalid_scope, not a silent downgrade.
  badScope <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (clientId, oauthClientSecret))
      [("grant_type", "client_credentials"), ("scope", "channel:egress")]
  assertOAuthError "scope outside allow-list" 400 "invalid_scope" badScope

  -- (8) An explicitly empty scope is invalid_scope, not "grant nothing".
  emptyScope <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (clientId, oauthClientSecret))
      [("grant_type", "client_credentials"), ("scope", "")]
  assertOAuthError "empty scope" 400 "invalid_scope" emptyScope

  -- (9) A missing grant_type is invalid_request...
  noGrant <- postForm mgr port "/oauth/token" (Just (clientId, oauthClientSecret)) []
  assertOAuthError "missing grant_type" 400 "invalid_request" noGrant

  -- (10) ...and a grant this server does not implement is unsupported_grant_type. (EP-5 made
  -- authorization_code and refresh_token supported arms; `password` is the OAuth Security BCP's
  -- deprecated grant, which Shōmei will never add.)
  password <-
    postForm mgr port "/oauth/token" (Just (clientId, oauthClientSecret)) [("grant_type", "password")]
  assertOAuthError "grant_type=password" 400 "unsupported_grant_type" password

-- | A human's login token carries no scopes, so it must NOT satisfy the scope-guarded route that
-- an OAuth client-credentials token does. Guards against the grant leaking scopes onto sessions.
scenarioOAuthScopeIsolation :: Int -> IO ()
scenarioOAuthScopeIsolation port = do
  mgr <- newManager defaultManagerSettings
  let email = "scopeisolation@example.com" :: Text
      pw = "correct horse battery staple" :: Text
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("S" :: Text)])
  sStatus @?= 201
  doc <- must "signup body" sBody
  token <- must "signup access token" (dig ["token", "accessToken"] doc >>= asText)
  (ingestStatus, _, ingestBody) <- getRaw mgr port "/ingest" [("Authorization", "Bearer " <> Text.encodeUtf8 token)]
  ingestStatus @?= 403
  -- and it is a problem document, because /ingest is an ordinary route, not an /oauth/* one
  problem <- must "ingest 403 body" ingestBody
  (dig ["code"] problem >>= asText) @?= Just "missing_scope"

-- | EP-9 end-to-end: the @RequirePermission "projects:write"@ combinator on a host route enforces
-- with no handler code, and the check is /re-wireable/ from the role→permission catalog without
-- touching the route.
--
--   * no token → 401 (the combinator authenticates before it authorizes);
--   * a login token whose principal has the permission on none of its roles → 403;
--   * after granting a role that has the permission allowed, a fresh login token → 200;
--   * the re-wiring proof: disallow the permission from that role and it is 403 again at the next
--     mint; allow it to a /different/ role the user also holds and it is 200 again — the consumer
--     (this route) never changed.
scenarioRequirePermission :: IORef World -> Int -> IO ()
scenarioRequirePermission ref port = do
  mgr <- newManager defaultManagerSettings
  let email = "perms@example.com" :: Text
      pw = "correct horse battery staple" :: Text
      loginBody = object ["email" .= email, "password" .= pw]
      projects tok = fst <$> getJSON mgr port "/host/projects" (bearer tok)
      loginAccess = do
        (st, body) <- postJSON mgr port "/v1/auth/login" loginBody
        st @?= 200
        resp <- must "login body" body
        must "login accessToken" (dig ["token", "accessToken"] resp >>= asText)
      supportRole = Role "support"
      staffRole = Role "staff"
      writePerm = Permission "projects:write"

  -- Sign up and capture the user id (for the grants) and the first token (no roles yet).
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("P" :: Text)])
  sStatus @?= 201
  doc <- must "signup body" sBody
  uid <- must "signup user id" (dig ["user", "userId"] doc >>= asText)
  token0 <- must "signup access token" (dig ["token", "accessToken"] doc >>= asText)

  -- No token → 401; a token without the permission → 403.
  noTok <- projects ""
  -- An empty bearer is no usable credential, so the auth handler answers 401.
  (noHeaderStatus, _) <- getJSON mgr port "/host/projects" []
  noHeaderStatus @?= 401
  noTok @?= 401 -- "Bearer " with an empty token is still no valid token
  forbidden <- projects token0
  forbidden @?= 403

  -- Wire support → projects:write and grant support; a fresh login now opens the route.
  defineRoleIn ref supportRole
  allowPermissionIn ref supportRole writePerm
  grantRoleIn ref uid supportRole
  token1 <- loginAccess
  ok1 <- projects token1
  ok1 @?= 200
  -- The pre-grant token is unchanged (staleness contract): still 403.
  stale <- projects token0
  stale @?= 403

  -- Re-wiring proof, part 1: disallow the permission from support. The next mint loses it.
  disallowPermissionIn ref supportRole writePerm
  token2 <- loginAccess
  afterDisallow <- projects token2
  afterDisallow @?= 403

  -- Re-wiring proof, part 2: grant the user a SECOND role and allow the permission to it instead.
  -- The user reaches the same route again — with zero changes to the route or its handler.
  defineRoleIn ref staffRole
  grantRoleIn ref uid staffRole
  allowPermissionIn ref staffRole writePerm
  token3 <- loginAccess
  rewired <- projects token3
  rewired @?= 200

-- | Every failure, from every layer, is an RFC 7807 problem document.
--
-- Each assertion names the layer it exercises, because they fail for different reasons: the
-- auth handler and the authz combinator throw before any handler runs; @resolvePrincipal@
-- throws inside one; Servant's @ErrorFormatters@ handle its own request parsers; and the bare
-- 405 a method mismatch raises sits below every Servant hook, converted by 'problemMiddleware'.
scenarioProblemEnvelope :: Int -> IO ()
scenarioProblemEnvelope port = do
  mgr <- newManager defaultManagerSettings

  -- (1) The auth handler: no credential at all. The commonest failure in any deployment.
  r1 <- getRaw mgr port "/v1/auth/me" []
  assertProblem "missing token" 401 "missing_token" r1
  headerValue "WWW-Authenticate" (headersOf r1) @?= Just "Bearer"

  -- (2) The auth handler: a credential that fails verification. Deliberately indistinguishable
  --     from an expired one -- the code is the same.
  r2 <- getRaw mgr port "/v1/auth/me" (bearer "garbage.token.value")
  assertProblem "invalid token" 401 "token_invalid" r2
  headerValue "WWW-Authenticate" (headersOf r2) @?= Just "Bearer"

  -- (3) The authorization combinator: authenticated, but lacking the role. 403, and no
  --     WWW-Authenticate -- the credential itself was fine.
  let signupBody' =
        object
          [ "email" .= ("envelope@example.com" :: Text),
            "password" .= ("correct horse battery staple" :: Text),
            "displayName" .= ("Envelope" :: Text)
          ]
  (_, sBody) <- postJSON mgr port "/v1/auth/signup" signupBody'
  sresp <- must "signup body" sBody
  access <- must "signup accessToken" (dig ["token", "accessToken"] sresp >>= asText)
  r3 <- getRaw mgr port "/admin/users" (bearer access)
  assertProblem "missing role" 403 "missing_role" r3
  headerValue "WWW-Authenticate" (headersOf r3) @?= Nothing

  -- (4) A handler's own rejection, with the specific reason carried in `detail`.
  r4 <- postRaw' mgr port "/v1/auth/login" [] (object ["password" .= ("x" :: Text)])
  assertProblem "handler bad request" 400 "bad_request" r4
  (bodyOf r4 >>= dig ["detail"] >>= asText) @?= Just "loginId or email required"

  -- (5) Servant's own body parser, via ErrorFormatters. The parse message rides in `detail`.
  r5 <- postRawBytes mgr port "/v1/auth/signup" "{"
  assertProblem "body parse error" 400 "body_parse_error" r5
  assertBool "body_parse_error carries a detail" (isJust (bodyOf r5 >>= dig ["detail"]))

  -- (6) Servant's not-found formatter.
  r6 <- getRaw mgr port "/no/such/route" []
  assertProblem "unknown route" 404 "not_found" r6

  -- (7) The method check -- below every Servant hook, rewritten by problemMiddleware.
  r7 <- getRaw mgr port "/v1/auth/login" []
  assertProblem "method not allowed" 405 "method_not_allowed" r7

-- | The versioning boundary: every application route answers only under @\/v1@, and the
-- protocol/infrastructure endpoints answer only at the root. Both halves are asserted, because
-- a record that accidentally nested the probes under @\/v1@ would still pass the first half.
--
-- The old unprefixed paths are gone outright — no redirect, no 410 — so an unmigrated client
-- gets a 404 problem document naming nothing it can act on but the CHANGELOG. That is the
-- declared cost of the pre-1.0 breaking window.
scenarioVersionBoundary :: Int -> IO ()
scenarioVersionBoundary port = do
  mgr <- newManager defaultManagerSettings

  -- The old paths are 404 -- and a 404 that is itself a problem document.
  old <- postRaw' mgr port "/auth/login" [] (object ["loginId" .= ("someone" :: Text)])
  assertProblem "old login path" 404 "not_found" old
  oldMe <- getRaw mgr port "/auth/me" []
  assertProblem "old me path" 404 "not_found" oldMe

  -- ...and the versioned one routes: no token, so the auth handler answers 401, which is proof
  -- the request reached the route rather than falling off the end of the tree.
  newMe <- getRaw mgr port "/v1/auth/me" []
  assertProblem "versioned me path routes" 401 "missing_token" newMe

  -- Probes and JWKS stay at the root.
  (healthStatus, _) <- getJSON mgr port "/health" []
  healthStatus @?= 200
  (jwksStatus, jwksHdrs, _) <- getRaw mgr port "/.well-known/jwks.json" []
  jwksStatus @?= 200
  headerValue "Cache-Control" jwksHdrs @?= Just "public, max-age=300"

  -- ...and nothing bleeds into /v1: the version prefix covers the application record only.
  v1Health <- getRaw mgr port "/v1/health" []
  assertProblem "no /v1/health" 404 "not_found" v1Health
  v1Jwks <- getRaw mgr port "/v1/.well-known/jwks.json" []
  assertProblem "no /v1/.well-known/jwks.json" 404 "not_found" v1Jwks

-- | The three status-code corrections, on one account.
--
-- Logout is the interesting one: it is now idempotent. A retry after a network blip, or a
-- double-tapped button, must succeed — "you are already logged out" is what the caller asked
-- for, not a failure. The second call reaches the handler because the default @sessionCheckMode@
-- is @VerifyTokenOnly@, so the access token still verifies against a revoked session; the
-- handler then swallows exactly 'SessionNotFound'.
scenarioStatusCodes :: Int -> IO ()
scenarioStatusCodes port = do
  mgr <- newManager defaultManagerSettings
  let email = "statuscodes@example.com" :: Text
      pw = "correct horse battery staple" :: Text

  -- Signup creates a user: 201, not 200.
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("S" :: Text)])
  sStatus @?= 201
  sresp <- must "signup body" sBody
  access <- must "signup accessToken" (dig ["token", "accessToken"] sresp >>= asText)

  -- The lifecycle *request* endpoints stay 202: the mail leaves the process later.
  (reqStatus, _) <- postJSON mgr port "/v1/auth/password-reset/request" (object ["email" .= email])
  reqStatus @?= 202

  -- Logging out twice succeeds twice.
  (out1, _) <- postJSONAuth mgr port "/v1/auth/logout" (bearer access) Null
  out1 @?= 204
  (out2, _) <- postJSONAuth mgr port "/v1/auth/logout" (bearer access) Null
  out2 @?= 204

-- ---------------------------------------------------------------------------
-- EP-2: the admin HTTP API
-- ---------------------------------------------------------------------------

-- | Sign a user up over HTTP and return @(userId, accessToken)@.
signupOver :: Manager -> Int -> Text -> IO (Text, Text)
signupOver mgr port email = do
  (status, body) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= adminPassword, "displayName" .= ("U" :: Text)])
  status @?= 201
  resp <- must "signup body" body
  uid <- must "signup userId" (dig ["user", "userId"] resp >>= asText)
  tok <- must "signup accessToken" (dig ["token", "accessToken"] resp >>= asText)
  pure (uid, tok)

loginOver :: Manager -> Int -> Text -> IO Text
loginOver mgr port email = do
  (status, body) <- postJSON mgr port "/v1/auth/login" (object ["email" .= email, "password" .= adminPassword])
  status @?= 200
  resp <- must "login body" body
  must "login accessToken" (dig ["token", "accessToken"] resp >>= asText)

adminPassword :: Text
adminPassword = "correct horse battery staple"

-- | Promote a signed-up user to administrator through the real audited workflow, then log in so
-- the fresh token carries the granted role. This is exactly the bootstrap an operator performs
-- with @shomei-admin roles grant@.
becomeAdmin :: IORef World -> Manager -> Int -> Text -> IO Text
becomeAdmin ref mgr port email = do
  (uid, _) <- signupOver mgr port email
  grantAdminTo ref uid
  loginOver mgr port email

-- | The admin gate is a disjunction: the @admin@ role (a human) or the @shomei:admin@ scope (a
-- service token). Both work; neither is optional; an ordinary token is a 403 and no token a 401.
--
-- The 403 says @missing_role@ without mentioning the scope. Telling an unauthorized caller which
-- of two credentials would have let them in is a hint they have no business receiving.
scenarioAdminAuthzMatrix :: IORef World -> JWK -> ShomeiConfig -> Int -> IO ()
scenarioAdminAuthzMatrix ref jwk cfg port = do
  mgr <- newManager defaultManagerSettings
  (_, ordinaryToken) <- signupOver mgr port "ordinary@example.com"
  adminToken' <- becomeAdmin ref mgr port "gatekeeper@example.com"
  scopedUid <- genUserId
  scopedToken <- mkTokenFor jwk cfg scopedUid Set.empty (Set.singleton (Scope "shomei:admin")) Nothing

  noTok <- getRaw mgr port "/v1/admin/users" []
  assertProblem "no token" 401 "missing_token" noTok

  ordinary <- getRaw mgr port "/v1/admin/users" (bearer ordinaryToken)
  assertProblem "ordinary token" 403 "missing_role" ordinary
  assertBool
    "the 403 does not disclose that a shomei:admin scope would also work"
    (maybe True (not . T.isInfixOf "scope") (bodyOf ordinary >>= dig ["title"] >>= asText))

  (roleStatus, _) <- getJSON mgr port "/v1/admin/users" (bearer adminToken')
  roleStatus @?= 200
  (scopeStatus, _) <- getJSON mgr port "/v1/admin/users" (bearer scopedToken)
  scopeStatus @?= 200

-- | The lifecycle an operator actually drives: suspend a compromised account, watch the login
-- die and the sessions with it, reinstate, then soft-delete. The strict transitions mean a second
-- administrator racing the first gets a 409 rather than a misleading success.
scenarioAdminLifecycle :: IORef World -> Int -> IO ()
scenarioAdminLifecycle ref port = do
  mgr <- newManager defaultManagerSettings
  adminToken' <- becomeAdmin ref mgr port "boss@example.com"
  (targetId, _) <- signupOver mgr port "target@example.com"
  let target = "/v1/admin/users/" <> T.unpack targetId

  -- Suspend: the account stops working and its sessions are dead.
  (susp, _) <- postAuthNoBody mgr port (target <> "/suspend") (bearer adminToken')
  susp @?= 204
  (loginStatus, _) <- postJSON mgr port "/v1/auth/login" (object ["email" .= ("target@example.com" :: Text), "password" .= adminPassword])
  loginStatus @?= 401
  (sessStatus, sessBody) <- getJSON mgr port (target <> "/sessions") (bearer adminToken')
  sessStatus @?= 200
  sessions <- must "sessions body" sessBody
  case sessions of
    Array xs -> assertBool "every session is revoked" (all (\v -> (dig ["status"] v >>= asText) == Just "revoked") xs)
    _ -> assertFailure "expected a JSON array of sessions"

  -- A second admin racing the first learns the state already changed.
  again <- postRaw' mgr port (target <> "/suspend") (bearer adminToken') Null
  assertProblem "double suspend" 409 "invalid_user_status" again

  -- Reinstate: login works again.
  (rein, _) <- postAuthNoBody mgr port (target <> "/reinstate") (bearer adminToken')
  rein @?= 204
  (loginAgain, _) <- postJSON mgr port "/v1/auth/login" (object ["email" .= ("target@example.com" :: Text), "password" .= adminPassword])
  loginAgain @?= 200

  -- Soft delete: the row survives and is still listed, but refuses further transitions.
  (del, _) <- deleteAuth mgr port target (bearer adminToken')
  del @?= 204
  redelete <- deleteRaw mgr port target (bearer adminToken')
  assertProblem "delete twice" 409 "invalid_user_status" redelete
  (getStatus, getBody) <- getJSON mgr port target (bearer adminToken')
  getStatus @?= 200
  gotten <- must "get user body" getBody
  (dig ["user", "status"] gotten >>= asText) @?= Just "deleted"

  -- ...and appears in the ?status=deleted listing.
  (listStatus, listBody) <- getJSON mgr port "/v1/admin/users?status=deleted" (bearer adminToken')
  listStatus @?= 200
  listed <- must "list body" listBody
  case dig ["users"] listed of
    Just (Array xs) -> map (\v -> dig ["userId"] v >>= asText) (toList xs) @?= [Just targetId]
    _ -> assertFailure "expected a users array"

-- | Session revocation, one at a time and wholesale, and the audit row that names the admin who
-- did it. An administrative action nobody can be held responsible for is not an audit trail.
scenarioAdminSessionsAndAudit :: IORef World -> Int -> IO ()
scenarioAdminSessionsAndAudit ref port = do
  mgr <- newManager defaultManagerSettings
  adminToken' <- becomeAdmin ref mgr port "auditor@example.com"
  adminId <- must "admin id" . Just =<< userIdOf ref "auditor@example.com"
  (targetId, _) <- signupOver mgr port "victim@example.com"
  _ <- loginOver mgr port "victim@example.com" -- a second live session
  let target = "/v1/admin/users/" <> T.unpack targetId

  (sessStatus, sessBody) <- getJSON mgr port (target <> "/sessions") (bearer adminToken')
  sessStatus @?= 200
  sessions <- must "sessions" sessBody
  firstSession <- case sessions of
    Array xs | (s0 : _) <- toList xs -> must "session id" (dig ["sessionId"] s0 >>= asText)
    _ -> assertFailure "expected at least one session"

  (one, _) <- deleteAuth mgr port ("/v1/admin/sessions/" <> T.unpack firstSession) (bearer adminToken')
  one @?= 204
  (bulk, _) <- deleteAuth mgr port (target <> "/sessions") (bearer adminToken')
  bulk @?= 204

  (afterStatus, afterBody) <- getJSON mgr port (target <> "/sessions") (bearer adminToken')
  afterStatus @?= 200
  after <- must "sessions after" afterBody
  case after of
    Array xs -> assertBool "no session survives" (all (\v -> (dig ["status"] v >>= asText) == Just "revoked") xs)
    _ -> assertFailure "expected an array"

  -- The suspension event carries the acting admin, readable through the audit endpoint.
  (susp, _) <- postAuthNoBody mgr port (target <> "/suspend") (bearer adminToken')
  susp @?= 204
  (auditStatus, auditBody) <- getJSON mgr port "/v1/admin/audit/events?type=user_suspended" (bearer adminToken')
  auditStatus @?= 200
  audit <- must "audit body" auditBody
  case dig ["events"] audit of
    Just (Array xs)
      | (e0 : _) <- toList xs ->
          (dig ["payload", "actor"] e0 >>= asText) @?= Just adminId
    _ -> assertFailure "expected a user_suspended audit event"

-- | Roles over HTTP: a PUT grant is idempotent (set membership), a DELETE of a role the user
-- never held is a 404 rather than a silent success, and the granted role reaches the target's
-- NEXT token — never a token already in flight.
scenarioAdminRoles :: IORef World -> Int -> IO ()
scenarioAdminRoles ref port = do
  mgr <- newManager defaultManagerSettings
  adminToken' <- becomeAdmin ref mgr port "roler@example.com"
  (targetId, staleToken) <- signupOver mgr port "grantee@example.com"
  let roleUrl r = "/v1/admin/users/" <> T.unpack targetId <> "/roles/" <> r

  -- 'auditor' is not in the registry: the grant must fail loudly rather than mint a role no gate
  -- will ever check.
  undefinedRole <- putRaw mgr port (roleUrl "auditor") (bearer adminToken')
  assertProblem "granting an undefined role" 422 "role_not_defined" undefinedRole

  (grant, _) <- putAuth mgr port (roleUrl "admin") (bearer adminToken')
  grant @?= 204
  (regrant, _) <- putAuth mgr port (roleUrl "admin") (bearer adminToken')
  regrant @?= 204 -- idempotent

  -- The grant is in the store, but not in the token minted before it. Asserted behaviourally —
  -- by using the tokens — rather than by decoding the JWT: what matters is that the gate opens.
  stale <- getRaw mgr port "/v1/admin/users" (bearer staleToken)
  assertProblem "a token minted before the grant does not carry the role" 403 "missing_role" stale
  fresh <- loginOver mgr port "grantee@example.com"
  (freshStatus, _) <- getJSON mgr port "/v1/admin/users" (bearer fresh)
  freshStatus @?= 200

  (revoke, _) <- deleteAuth mgr port (roleUrl "admin") (bearer adminToken')
  revoke @?= 204
  revokeAgain <- deleteRaw mgr port (roleUrl "admin") (bearer adminToken')
  assertProblem "revoking a role the user does not hold" 404 "role_not_granted" revokeAgain

  blank <- putRaw mgr port ("/v1/admin/users/" <> T.unpack targetId <> "/roles/%20") (bearer adminToken')
  assertProblem "a blank role name" 400 "bad_request" blank

-- | Two refusals that protect the deployment from its own administrators: an operator
-- impersonating a customer cannot administer as that customer (privilege laundering), and an
-- administrator cannot suspend or delete themselves (locking everyone out with one typo).
--
-- Reads are allowed under impersonation: looking is not laundering.
scenarioAdminRefusals :: IORef World -> JWK -> ShomeiConfig -> Int -> IO ()
scenarioAdminRefusals ref jwk cfg port = do
  mgr <- newManager defaultManagerSettings
  adminToken' <- becomeAdmin ref mgr port "chief@example.com"
  adminIdText <- userIdOf ref "chief@example.com"
  adminId <- parseUserId adminIdText
  (targetId, _) <- signupOver mgr port "bystander@example.com"

  -- A delegated token: same admin role, but acting on behalf of somebody.
  operator <- genUserId
  delegated <- mkTokenFor jwk cfg adminId (Set.singleton (Role "admin")) Set.empty (Just operator)

  blocked <- postRaw' mgr port ("/v1/admin/users/" <> T.unpack targetId <> "/suspend") (bearer delegated) Null
  assertProblem "a delegated token may not administer" 403 "impersonation_action_blocked" blocked
  (readStatus, _) <- getJSON mgr port "/v1/admin/users" (bearer delegated)
  readStatus @?= 200 -- reads are fine

  -- An admin cannot suspend or delete their own account...
  selfSuspend <- postRaw' mgr port ("/v1/admin/users/" <> T.unpack adminIdText <> "/suspend") (bearer adminToken') Null
  assertProblem "self-suspend" 403 "self_target_forbidden" selfSuspend
  selfDelete <- deleteRaw mgr port ("/v1/admin/users/" <> T.unpack adminIdText) (bearer adminToken')
  assertProblem "self-delete" 403 "self_target_forbidden" selfDelete

  -- ...but may revoke their own sessions, which is what you do when your laptop is stolen.
  (selfSessions, _) <- deleteAuth mgr port ("/v1/admin/users/" <> T.unpack adminIdText <> "/sessions") (bearer adminToken')
  selfSessions @?= 204

  -- A typo'd user id must not report cheerful success. The revoke-sessions workflow answers
  -- "0 sessions ended" for a user who does not exist; the handler turns that into a 404.
  ghost <- genUserId
  ghostRevoke <- deleteRaw mgr port ("/v1/admin/users/" <> T.unpack (idText ghost) <> "/sessions") (bearer adminToken')
  assertProblem "revoking the sessions of a nonexistent user" 404 "user_not_found" ghostRevoke
  ghostGet <- getRaw mgr port ("/v1/admin/users/" <> T.unpack (idText ghost)) (bearer adminToken')
  assertProblem "fetching a nonexistent user" 404 "user_not_found" ghostGet

-- | The keyset walk over users: pages are disjoint and complete, and the last page carries no
-- cursor.
scenarioAdminPagination :: IORef World -> Int -> IO ()
scenarioAdminPagination ref port = do
  mgr <- newManager defaultManagerSettings
  adminToken' <- becomeAdmin ref mgr port "pager@example.com"
  _ <- signupOver mgr port "u1@example.com"
  _ <- signupOver mgr port "u2@example.com"
  _ <- signupOver mgr port "u3@example.com" -- four users in total, with the admin
  (s1, b1) <- getJSON mgr port "/v1/admin/users?limit=2" (bearer adminToken')
  s1 @?= 200
  page1 <- must "page 1" b1
  ids1 <- userIdsOf page1
  cursor <- must "page 1 nextCursor" (dig ["nextCursor"] page1 >>= asText)
  length ids1 @?= 2

  (s2, b2) <- getJSON mgr port ("/v1/admin/users?limit=2&before=" <> urlEncodeText cursor) (bearer adminToken')
  s2 @?= 200
  page2 <- must "page 2" b2
  ids2 <- userIdsOf page2
  length ids2 @?= 2

  -- The last page is full, so it still offers a cursor; the page after it is empty and does not.
  lastCursor <- must "page 2 nextCursor" (dig ["nextCursor"] page2 >>= asText)
  (s3, b3) <- getJSON mgr port ("/v1/admin/users?limit=2&before=" <> urlEncodeText lastCursor) (bearer adminToken')
  s3 @?= 200
  page3 <- must "page 3" b3
  ids3 <- userIdsOf page3
  ids3 @?= []
  (dig ["nextCursor"] page3) @?= Just Null

  assertBool "the pages are disjoint" (null (filter (`elem` ids2) ids1))
  length (ids1 <> ids2) @?= 4

  bad <- getRaw mgr port "/v1/admin/users?before=not-a-cursor" (bearer adminToken')
  assertProblem "a malformed cursor" 400 "bad_request" bad
  badStatus <- getRaw mgr port "/v1/admin/users?status=zombie" (bearer adminToken')
  assertProblem "an unknown status filter" 400 "bad_request" badStatus

userIdsOf :: Value -> IO [Text]
userIdsOf page = case dig ["users"] page of
  Just (Array xs) -> traverse (\v -> must "user id" (dig ["userId"] v >>= asText)) (toList xs)
  _ -> assertFailure "expected a users array"

-- | The user id of a signed-up account, read straight from the in-memory World.
userIdOf :: IORef World -> Text -> IO Text
userIdOf ref email = do
  w <- readIORef ref
  case [u | u <- Map.elems w.users, (emailText <$> u.email) == Just email] of
    (u : _) -> pure (idText u.userId)
    [] -> assertFailure ("no user with email " <> T.unpack email)

-- | DELETE / PUT exposing headers and body, for problem-document assertions.
deleteRaw :: Manager -> Int -> String -> [Header] -> IO RawResponse
deleteRaw mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "DELETE", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

putRaw :: Manager -> Int -> String -> [Header] -> IO RawResponse
putRaw mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "PUT", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

type RawResponse = (Int, [Header], Maybe Value)

headersOf :: RawResponse -> [Header]
headersOf (_, h, _) = h

bodyOf :: RawResponse -> Maybe Value
bodyOf (_, _, b) = b

-- | Assert the response is a problem document: the right status, @application/problem+json@, and
-- a body whose @code@ matches, whose @status@ member mirrors the HTTP status, and which carries
-- @type@ and @title@.
assertProblem :: String -> Int -> Text -> RawResponse -> IO ()
assertProblem what expectedStatus expectedCode (status, hdrs, body) = do
  status @?= expectedStatus
  headerValue "Content-Type" hdrs @?= Just "application/problem+json"
  doc <- must (what <> ": body") body
  (dig ["code"] doc >>= asText) @?= Just expectedCode
  (dig ["type"] doc >>= asText) @?= Just "about:blank"
  assertBool (what <> ": has a title") (isJust (dig ["title"] doc))
  case dig ["status"] doc of
    Just (Number n) -> (round n :: Int) @?= expectedStatus
    _ -> assertFailure (what <> ": problem document has no numeric status")

headerValue :: Text -> [Header] -> Maybe Text
headerValue name hdrs =
  listToMaybe [Text.decodeUtf8 v | (n, v) <- hdrs, n == CI.mk (Text.encodeUtf8 name)]

-- | GET, exposing status, headers, and the decoded body.
getRaw :: Manager -> Int -> String -> [Header] -> IO RawResponse
getRaw mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | POST a JSON value, exposing status, headers, and the decoded body.
postRaw' :: Manager -> Int -> String -> [Header] -> Value -> IO RawResponse
postRaw' mgr port path hdrs body = postRaw mgr port path hdrs body

-- | POST an @application\/x-www-form-urlencoded@ body, for the OAuth2 token endpoint.
--
-- @mBasic@, when given, applies RFC 6749's @client_secret_basic@:
-- @Authorization: Basic base64(client_id:client_secret)@, built by @http-client@'s
-- 'applyBasicAuth' so the test encodes it exactly as a real client would.
postForm :: Manager -> Int -> String -> Maybe (Text, Text) -> [(ByteString, ByteString)] -> IO RawResponse
postForm mgr port path mBasic params = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let withBody = urlEncodedBody params req0
      req = maybe withBody (\(c, s) -> applyBasicAuth (Text.encodeUtf8 c) (Text.encodeUtf8 s) withBody) mBasic
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | Assert an RFC 6749 §5.2 error response: the right status, @application\/json@ (never
-- @application\/problem+json@ — that would break a stock OAuth2 client), and an @error@ member
-- that matches. This is the assertion that pins the envelope boundary at runtime, as the
-- OpenAPI conformance suite pins it in the document.
assertOAuthError :: String -> Int -> Text -> RawResponse -> IO ()
assertOAuthError what expectedStatus expectedCode (status, hdrs, body) = do
  assertEqual (what <> ": status") expectedStatus status
  assertEqual (what <> ": content type") (Just "application/json") (headerValue "Content-Type" hdrs)
  -- Never cached, error or not.
  assertEqual (what <> ": no-store") (Just "no-store") (headerValue "Cache-Control" hdrs)
  doc <- must (what <> ": body") body
  assertEqual (what <> ": error code") (Just expectedCode) (dig ["error"] doc >>= asText)
  assertBool (what <> ": has an error_description") (isJust (dig ["error_description"] doc))

-- | POST an arbitrary (here: malformed) body, to exercise Servant's body parser.
postRawBytes :: Manager -> Int -> String -> LBS.ByteString -> IO RawResponse
postRawBytes mgr port path raw = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = [("Content-Type", "application/json")],
            requestBody = RequestBodyLBS raw
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

tests :: IORef World -> Env -> IO Env -> IO (IORef World, Env) -> IO (IORef World, Env) -> IO Env -> IO Env -> IO Env -> IO (Text, Env) -> IO Env -> (Maybe Text -> IO (IORef World, Text, Text, Env)) -> IO (IORef World, Env) -> IO (Text, Text, Env) -> IO (IORef World, Env) -> JWK -> ShomeiConfig -> Text -> Text -> Text -> TestTree
tests ref env freshEnv freshGatedEnv freshPermissionEnv freshCookieEnv freshBothEnv freshServiceEnv freshOAuthEnv freshOidcEnv freshAuthorizeEnv freshAdminEnv freshExchangeEnv freshTotpEnv jwk cfg adminToken impToken staleImpToken =
  testGroup
    "HTTP end-to-end (in-memory interpreters + in-test ES256 key)"
    [ testCase "problem+json envelope from every layer (auth handler, authz, handler, servant formatters, method check)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioProblemEnvelope,
      testCase "the /v1 boundary: application routes are versioned, probes and JWKS are not" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioVersionBoundary,
      testCase "status codes: signup 201, lifecycle requests still 202, logout idempotent (204/204)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioStatusCodes,
      testCase "admin API: the gate is role OR scope; no token 401, ordinary token 403" $ do
        (r, e) <- freshAdminEnv
        testWithApplication (pure (app e)) (scenarioAdminAuthzMatrix r jwk cfg),
      testCase "admin API: suspend → login dies + sessions revoked → 409 on repeat → reinstate → soft delete" $ do
        (r, e) <- freshAdminEnv
        testWithApplication (pure (app e)) (scenarioAdminLifecycle r),
      testCase "admin API: revoke one/all sessions; the audit event names the acting admin" $ do
        (r, e) <- freshAdminEnv
        testWithApplication (pure (app e)) (scenarioAdminSessionsAndAudit r),
      testCase "admin API: PUT role is idempotent, DELETE of an unheld role is 404, grants reach the next token" $ do
        (r, e) <- freshAdminEnv
        testWithApplication (pure (app e)) (scenarioAdminRoles r),
      testCase "admin API: delegated tokens cannot administer; an admin cannot suspend themselves" $ do
        (r, e) <- freshAdminEnv
        testWithApplication (pure (app e)) (scenarioAdminRefusals r jwk cfg),
      testCase "admin API: the user listing pages by keyset, disjoint and complete" $ do
        (r, e) <- freshAdminEnv
        testWithApplication (pure (app e)) (scenarioAdminPagination r),
      testCase "signup → verify/reset → login → me(±token) → refresh → jwks → RequireRole → passkey CRUD → MFA step-up → passwordless → impersonation" $
        testWithApplication (pure (app env)) (scenario ref adminToken impToken),
      testCase "signup/login by loginId with no email (email == null)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioNoEmail,
      testCase "email-only signup defaults loginId to the email (backward compat)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioEmailDefaultsLoginId,
      testCase "service token with allowed scope passes RequireScope while normal login token fails" $ do
        e <- freshServiceEnv
        testWithApplication (pure (app e)) scenarioServiceToken,
      testCase "POST /oauth/token: client_credentials over both auth methods; RFC 6749 errors, not problem docs" $ do
        (clientId, e) <- freshOAuthEnv
        testWithApplication (pure (app e)) (scenarioOAuthToken clientId),
      testCase "POST /oauth/token: RFC 8693 token-exchange, both modes, denyUnderImpersonation inheritance, and wire refusals" $ do
        (gateId, noGateId, e) <- freshExchangeEnv
        testWithApplication (pure (app e)) (scenarioTokenExchange jwk gateId noGateId impToken staleImpToken),
      testCase "EP-7 TOTP: enroll → verify → mfa_required(methods) → complete; replay 401; recovery gen/use/count; impersonation 403; remove; freshness 403" $ do
        (r, e) <- freshTotpEnv
        testWithApplication (pure (app e)) (scenarioTotp r jwk cfg),
      testCase "GET /.well-known/openid-configuration: derived from the issuer when enabled, 404 in the OAuth shape when not" $ do
        e <- freshOidcEnv
        testWithApplication (pure (app e)) scenarioOidcDiscoveryEnabled
        d <- freshEnv
        testWithApplication (pure (app d)) scenarioOidcDiscoveryDisabled,
      testCase "GET /oauth/authorize: unknown client and unregistered redirect_uri are 400 and NEVER redirect" $ do
        (_, confId, _, e) <- freshAuthorizeEnv Nothing
        testWithApplication (pure (app e)) (scenarioAuthorizeNoRedirectRegime confId),
      testCase "GET /oauth/authorize: an authenticated request yields a code; parameter errors redirect with the state" $ do
        (r, confId, pubId, e) <- freshAuthorizeEnv Nothing
        testWithApplication (pure (app e)) (scenarioAuthorizeIssuesCode r confId pubId),
      testCase "GET /oauth/authorize: unauthenticated bounces to the host login page, or 401s when none is configured" $ do
        (_, confId, _, withLogin) <- freshAuthorizeEnv (Just "https://host.test/login")
        testWithApplication (pure (app withLogin)) (scenarioAuthorizeLoginRedirect confId)
        (_, confId', _, noLogin) <- freshAuthorizeEnv Nothing
        testWithApplication (pure (app noLogin)) (scenarioAuthorizeNoLoginUrl confId'),
      testCase "POST /oauth/token: authorization_code + PKCE + ID token; replay, wrong verifier, and a stolen code are one invalid_grant" $ do
        (_, confId, pubId, e) <- freshAuthorizeEnv Nothing
        testWithApplication (pure (app e)) (scenarioOAuthCodeExchange jwk confId pubId),
      testCase "POST /oauth/token: refresh_token is bound to the client that minted the session" $ do
        (_, confId, _, e) <- freshAuthorizeEnv Nothing
        testWithApplication (pure (app e)) (scenarioOAuthRefreshRejectsUnboundSession confId),
      testCase "userinfo, introspection, and the revoke->introspect flip" $ do
        (_, confId, pubId, e) <- freshAuthorizeEnv Nothing
        testWithApplication (pure (app e)) (scenarioOAuthUserinfoIntrospectRevoke jwk confId pubId),
      testCase "a human login token carries no scopes, so it still fails the scope-guarded route" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioOAuthScopeIsolation,
      testCase "RequirePermission: 401 no token, 403 without the permission, 200 with it, and re-wiring proves the indirection" $ do
        (r, e) <- freshPermissionEnv
        testWithApplication (pure (app e)) (scenarioRequirePermission r),
      testCase "emailVerificationRequired blocks login with 403 until the email is verified" $ do
        (r, e) <- freshGatedEnv
        testWithApplication (pure (app e)) (scenarioEmailVerificationRequired r),
      testCase "cookie transport: sets HttpOnly cookies, omits body tokens, authenticates, clears on logout" $ do
        e <- freshCookieEnv
        testWithApplication (pure (app e)) scenarioCookieTransport,
      testCase "cookie transport: CSRF gate on mutating requests (Origin / Referer / none / foreign)" $ do
        e <- freshCookieEnv
        testWithApplication (pure (app e)) scenarioCsrfMatrix,
      testCase "cookie transport: refresh reads the shomei_refresh cookie, rotates, and is CSRF-gated" $ do
        e <- freshCookieEnv
        testWithApplication (pure (app e)) scenarioCookieRefresh,
      testCase "bearer transport: no Set-Cookie, body tokens present, a cookie is not a credential" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioBearerRejectsCookies,
      testCase "both transport: cookies set AND body tokens present" $ do
        e <- freshBothEnv
        testWithApplication (pure (app e)) scenarioBothTransport
    ]

-- | EP-5 M1: the discovery document is what makes Shōmei consumable by stock middleware, and
-- every URL in it is derived from the issuer — not from a second base-URL setting that could
-- disagree with the @iss@ claim in the tokens.
--
-- The test env's issuer is @https:\/\/shomei.test@ (see 'main'), so each endpoint below is that
-- issuer plus a fixed path.
scenarioOidcDiscoveryEnabled :: Int -> IO ()
scenarioOidcDiscoveryEnabled port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- getRaw mgr port "/.well-known/openid-configuration" []
  status @?= 200
  headerValue "Content-Type" hdrs @?= Just "application/json;charset=utf-8"
  doc <- must "discovery document" body
  (dig ["issuer"] doc >>= asText) @?= Just "https://shomei.test"
  (dig ["authorization_endpoint"] doc >>= asText) @?= Just "https://shomei.test/oauth/authorize"
  (dig ["token_endpoint"] doc >>= asText) @?= Just "https://shomei.test/oauth/token"
  (dig ["userinfo_endpoint"] doc >>= asText) @?= Just "https://shomei.test/oauth/userinfo"
  (dig ["introspection_endpoint"] doc >>= asText) @?= Just "https://shomei.test/oauth/introspect"
  (dig ["revocation_endpoint"] doc >>= asText) @?= Just "https://shomei.test/oauth/revoke"
  -- The JWKS document really is served there, unversioned, by this same app.
  (dig ["jwks_uri"] doc >>= asText) @?= Just "https://shomei.test/.well-known/jwks.json"
  (jwksStatus, _) <- getJSON mgr port "/.well-known/jwks.json" []
  jwksStatus @?= 200
  -- Only the code flow is advertised: implicit and hybrid are excluded by the Security BCP, and
  -- advertising a flow the server does not implement makes stock middleware negotiate it.
  dig ["response_types_supported"] doc @?= Just (toJSON (["code"] :: [Text]))
  -- Only S256: `plain` exists for clients that cannot hash, and every modern library can.
  dig ["code_challenge_methods_supported"] doc @?= Just (toJSON (["S256"] :: [Text]))
  dig ["subject_types_supported"] doc @?= Just (toJSON (["public"] :: [Text]))
  -- EP-4's grant is advertised alongside the two EP-5 adds.
  dig ["grant_types_supported"] doc
    @?= Just (toJSON (["authorization_code", "refresh_token", "client_credentials"] :: [Text]))
  -- The default test config signs with ES256.
  dig ["id_token_signing_alg_values_supported"] doc @?= Just (toJSON (["ES256"] :: [Text]))
  dig ["token_endpoint_auth_methods_supported"] doc
    @?= Just (toJSON (["client_secret_basic", "client_secret_post"] :: [Text]))

-- | With @oidcEnabled@ off (the default) the provider does not advertise. The refusal reaches
-- OIDC tooling, so it is an RFC 6749-shaped object rather than a problem document — the same
-- envelope boundary @\/oauth\/*@ observes.
scenarioOidcDiscoveryDisabled :: Int -> IO ()
scenarioOidcDiscoveryDisabled port = do
  mgr <- newManager defaultManagerSettings
  r@(_, hdrs, _) <- getRaw mgr port "/.well-known/openid-configuration" []
  assertOAuthError "discovery with the provider disabled" 404 "not_found" r
  assertBool
    "a disabled provider must not answer with a problem document"
    (headerValue "Content-Type" hdrs /= Just "application/problem+json")
  -- The whole OIDC surface is inert, not just the advertisement: deploying the code before
  -- flipping the flag is safe, and flipping it back makes the endpoints unreachable again.
  authorize <-
    getNoRedirect mgr port (authorizeUrl [("client_id", "oauthclient_x"), ("response_type", "code"), ("redirect_uri", authorizeRedirectUri)]) []
  assertOAuthError "authorize with the provider disabled" 404 "not_found" authorize
  headerValue "Location" (headersOf authorize) @?= Nothing
  -- Nothing else moved: the JWKS document is unconditional (verifiers need it regardless).
  (jwksStatus, _) <- getJSON mgr port "/.well-known/jwks.json" []
  jwksStatus @?= 200

-- | Seed one confidential and one public OAuth client into an in-memory world, returning their
-- client ids. Both register exactly one redirect URI; the exact-match rule is what the
-- no-redirect regime is built on.
seedOAuthClients :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> UTCTime -> IO (Text, Text)
seedOAuthClients ref jwk jwkset cfg createdAt =
  runHybrid ref jwk jwkset cfg do
    confId <- genOAuthClientId
    pubId <- genOAuthClientId
    _ <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = confId,
            clientId = idText confId,
            secretHash = Just (sha256Hex confidentialClientSecret),
            clientType = ConfidentialClient,
            displayName = "confidential",
            redirectUris = [authorizeRedirectUri],
            allowedScopes = Set.fromList [Scope "openid", Scope "profile"],
            createdAt
          }
    _ <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = pubId,
            clientId = idText pubId,
            secretHash = Nothing,
            clientType = PublicClient,
            displayName = "public",
            redirectUris = [authorizeRedirectUri],
            allowedScopes = Set.singleton (Scope "openid"),
            createdAt
          }
    pure (idText confId, idText pubId)

-- | The one URI both seeded clients register.
authorizeRedirectUri :: Text
authorizeRedirectUri = "https://app.example.com/callback"

-- | The seeded confidential OAuth client's secret. (Distinct from 'oauthClientSecret', which is
-- EP-4's /service account/ secret: an OAuth client and a service account are different things.)
confidentialClientSecret :: Text
confidentialClientSecret = "confidential-client-secret"

-- | A well-formed PKCE S256 challenge (43 unpadded base64url characters).
testCodeChallenge :: Text
testCodeChallenge = T.replicate 43 "a"

-- | Build an @\/oauth\/authorize@ query string from @(key, value)@ pairs, percent-encoding both.
authorizeUrl :: [(Text, Text)] -> String
authorizeUrl params =
  "/oauth/authorize?" <> T.unpack (T.intercalate "&" [enc k <> "=" <> enc v | (k, v) <- params])
  where
    enc = Text.decodeUtf8 . urlEncode True . Text.encodeUtf8

-- | GET without following redirects, so a @302@ is the response under test rather than a fetch of
-- wherever it points.
getNoRedirect :: Manager -> Int -> String -> [Header] -> IO RawResponse
getNoRedirect mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs, redirectCount = 0}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | The @Location@ header, split into its base and its decoded query parameters.
locationOf :: String -> RawResponse -> IO (Text, [(Text, Text)])
locationOf what r = do
  loc <- maybe (assertFailure (what <> ": no Location header")) pure (headerValue "Location" (headersOf r))
  let (base, query) = T.breakOn "?" loc
      pairs =
        [ (Text.decodeUtf8 k, Text.decodeUtf8 v)
        | (k, v) <- parseSimpleQuery (Text.encodeUtf8 (T.drop 1 query))
        ]
  pure (base, pairs)

-- | Sign up a user over HTTP and return their access token, for the authorize scenarios.
signupToken :: Manager -> Int -> Text -> IO Text
signupToken mgr port loginId = do
  (status, body) <-
    postJSON
      mgr
      port
      "/v1/auth/signup"
      (object ["loginId" .= loginId, "password" .= ("correct horse battery staple" :: Text), "displayName" .= ("" :: Text)])
  status @?= 201
  resp <- must "signup body" body
  must "signup accessToken" (dig ["token", "accessToken"] resp >>= asText)

-- | Like 'signupToken', but also returns the new user's id text — the impersonation-mode
-- @subject_token@ (a bare user id) and the identity a downstream verifier reads from @sub@.
signupTokenAndId :: Manager -> Int -> Text -> IO (Text, Text)
signupTokenAndId mgr port loginId = do
  (status, body) <-
    postJSON
      mgr
      port
      "/v1/auth/signup"
      (object ["loginId" .= loginId, "password" .= ("correct horse battery staple" :: Text), "displayName" .= ("" :: Text)])
  status @?= 201
  resp <- must "signup body" body
  tok <- must "signup accessToken" (dig ["token", "accessToken"] resp >>= asText)
  uid <- must "signup userId" (dig ["user", "userId"] resp >>= asText)
  pure (tok, uid)

-- | EP-6: the RFC 8693 token-exchange grant end to end, over the real Servant tree — both modes and
-- every wire refusal.
--
--   * impersonation: an operator token exchanges a bare user id for a delegated token whose @sub@ is
--     the target and @act@ the operator; it resolves the customer on @\/auth\/me@ and inherits the
--     'denyUnderImpersonation' 403 on a credential change.
--   * on-behalf-of: an authenticated service account exchanges a user's access token for a narrowed
--     token that satisfies the @RequireScope@ route and carries the user's @sub@ + the service's @act@.
--
-- Every failure is an RFC 6749 §5.2 object, never a problem document.
scenarioTokenExchange :: JWK -> Text -> Text -> Text -> Text -> Int -> IO ()
scenarioTokenExchange jwk gateClientId noGateClientId impToken staleImpToken port = do
  mgr <- newManager defaultManagerSettings
  let teGrant = ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange")
      userIdType = "urn:shomei:params:oauth:token-type:user-id"
      accessType = "urn:ietf:params:oauth:token-type:access_token"
      accessTypeText = "urn:ietf:params:oauth:token-type:access_token" :: Text
      enc = Text.encodeUtf8

  -- ===== Impersonation mode =====
  (_, targetId) <- signupTokenAndId mgr port "exchange-target"
  impR <-
    postForm
      mgr
      port
      "/oauth/token"
      Nothing
      [ teGrant,
        ("subject_token", enc targetId),
        ("subject_token_type", userIdType),
        ("actor_token", enc impToken),
        ("actor_token_type", accessType),
        ("reason", "support ticket 4711")
      ]
  let (impStatus, impHdrs, impBody) = impR
  impStatus @?= 200
  headerValue "Cache-Control" impHdrs @?= Just "no-store"
  impDoc <- must "impersonation exchange body" impBody
  (dig ["token_type"] impDoc >>= asText) @?= Just "Bearer"
  (dig ["issued_token_type"] impDoc >>= asText) @?= Just accessTypeText
  impAccess <- must "impersonation access_token" (dig ["access_token"] impDoc >>= asText)
  impClaims <- verifyIdToken jwk impAccess
  KM.lookup "sub" impClaims @?= Just (String targetId)
  assertBool "impersonation token carries an act claim" (isJust (KM.lookup "act" impClaims))
  -- The delegated token resolves the TARGET on /auth/me.
  (meStatus, meBody) <- getJSON mgr port "/v1/auth/me" (bearer impAccess)
  meStatus @?= 200
  meResp <- must "me (delegated) body" meBody
  (dig ["userId"] meResp >>= asText) @?= Just targetId
  -- A credential change under the delegated token is refused 403 (the standard path inherits the gate).
  (pwStatus, pwBody) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/password/change"
      (bearer impAccess)
      (object ["currentPassword" .= ("x" :: Text), "newPassword" .= ("y" :: Text)])
  pwStatus @?= 403
  (pwBody >>= dig ["code"] >>= asText) @?= Just "impersonation_action_blocked"

  -- Introspection (plan 42) reports the delegated token as active, with an `act` member naming the
  -- operator — the observability surface agrees with the token's contents. Introspection
  -- client-authenticates as the service account.
  introActive <-
    postForm mgr port "/oauth/introspect" (Just (gateClientId, oauthClientSecret)) [("token", enc impAccess)]
  introActiveDoc <- must "introspect (active) body" (bodyOf introActive)
  dig ["active"] introActiveDoc @?= Just (Bool True)
  assertBool "introspection reports the act member" (isJust (dig ["act", "sub"] introActiveDoc >>= asText))
  -- DELETE /auth/impersonate remains the stop mechanism for an exchanged impersonation token; after
  -- it, introspection flips to inactive — session revocation is observable.
  (stopStatus, _) <- deleteAuth mgr port "/v1/auth/impersonate" (bearer impAccess)
  stopStatus @?= 204
  introInactive <-
    postForm mgr port "/oauth/introspect" (Just (gateClientId, oauthClientSecret)) [("token", enc impAccess)]
  introInactiveDoc <- must "introspect (inactive) body" (bodyOf introInactive)
  dig ["active"] introInactiveDoc @?= Just (Bool False)

  -- A stale operator token is one generic invalid_grant.
  staleR <-
    postForm
      mgr
      port
      "/oauth/token"
      Nothing
      [teGrant, ("subject_token", enc targetId), ("subject_token_type", userIdType), ("actor_token", enc staleImpToken), ("actor_token_type", accessType)]
  assertOAuthError "stale operator" 400 "invalid_grant" staleR

  -- A requested_token_type other than access_token is invalid_request (we issue no refresh tokens).
  reqTypeR <-
    postForm
      mgr
      port
      "/oauth/token"
      Nothing
      [ teGrant,
        ("subject_token", enc targetId),
        ("subject_token_type", userIdType),
        ("actor_token", enc impToken),
        ("actor_token_type", accessType),
        ("requested_token_type", "urn:ietf:params:oauth:token-type:refresh_token")
      ]
  assertOAuthError "refresh requested_token_type" 400 "invalid_request" reqTypeR

  -- ===== Service on-behalf-of mode =====
  (userTok, userId) <- signupTokenAndId mgr port "exchange-user"
  obR <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (gateClientId, oauthClientSecret))
      [teGrant, ("subject_token", enc userTok), ("subject_token_type", accessType), ("scope", "kawa:ingest")]
  let (obStatus, obHdrs, obBody) = obR
  obStatus @?= 200
  headerValue "Cache-Control" obHdrs @?= Just "no-store"
  obDoc <- must "on-behalf body" obBody
  (dig ["scope"] obDoc >>= asText) @?= Just "kawa:ingest"
  (dig ["issued_token_type"] obDoc >>= asText) @?= Just accessTypeText
  obAccess <- must "on-behalf access_token" (dig ["access_token"] obDoc >>= asText)
  -- The narrowed token satisfies the RequireScope route.
  (ingestStatus, _) <- getJSON mgr port "/ingest" (bearer obAccess)
  ingestStatus @?= 200
  obClaims <- verifyIdToken jwk obAccess
  KM.lookup "sub" obClaims @?= Just (String userId)
  assertBool "on-behalf token carries a service act claim" (isJust (KM.lookup "act" obClaims))
  assertBool "the act is the service, not the user" (KM.lookup "act" obClaims /= Just (String userId))

  -- No client authentication (and an access-token subject) names neither mode: invalid_request.
  noAuthR <-
    postForm
      mgr
      port
      "/oauth/token"
      Nothing
      [teGrant, ("subject_token", enc userTok), ("subject_token_type", accessType), ("scope", "kawa:ingest")]
  assertOAuthError "on-behalf without client auth" 400 "invalid_request" noAuthR

  -- A service account WITHOUT the gate scope may not exchange at all: invalid_scope.
  noGateR <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (noGateClientId, oauthClientSecret))
      [teGrant, ("subject_token", enc userTok), ("subject_token_type", accessType), ("scope", "kawa:ingest")]
  assertOAuthError "service without gate scope" 400 "invalid_scope" noGateR

  -- Requesting the gate scope itself is never granted: an empty grant is invalid_scope.
  gateR <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (gateClientId, oauthClientSecret))
      [teGrant, ("subject_token", enc userTok), ("subject_token_type", accessType), ("scope", "token-exchange:subject")]
  assertOAuthError "requesting the gate scope" 400 "invalid_scope" gateR

  -- A scope outside the account's ceiling is invalid_scope.
  outsideR <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (gateClientId, oauthClientSecret))
      [teGrant, ("subject_token", enc userTok), ("subject_token_type", accessType), ("scope", "channel:egress")]
  assertOAuthError "scope outside ceiling" 400 "invalid_scope" outsideR

  -- A garbage subject token is one generic invalid_grant.
  garbageR <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (gateClientId, oauthClientSecret))
      [teGrant, ("subject_token", "not-a-real-token"), ("subject_token_type", accessType), ("scope", "kawa:ingest")]
  assertOAuthError "garbage subject token" 400 "invalid_grant" garbageR

-- | EP-5 M2, regime one: an unknown or revoked @client_id@, or a @redirect_uri@ that is not
-- registered, is a @400@ __with no Location header at all__.
--
-- This is the single most important behavior of the endpoint. A server that redirects an error to
-- an unvalidated @redirect_uri@ is an open redirector, and an attacker uses it to have this
-- endpoint hand authorization codes to a host of their choosing. Note these must fail /before/
-- authentication is even considered: none of the requests below carries a token.
scenarioAuthorizeNoRedirectRegime :: Text -> Int -> IO ()
scenarioAuthorizeNoRedirectRegime confId port = do
  mgr <- newManager defaultManagerSettings
  let base =
        [ ("response_type", "code"),
          ("redirect_uri", authorizeRedirectUri),
          ("code_challenge", testCodeChallenge),
          ("code_challenge_method", "S256")
        ]
      assertNoRedirect what r = do
        assertOAuthError what 400 "invalid_request" r
        headerValue "Location" (headersOf r) @?= Nothing

  unknown <- getNoRedirect mgr port (authorizeUrl (("client_id", "oauthclient_nope") : base)) []
  assertNoRedirect "unknown client_id" unknown

  missingClient <- getNoRedirect mgr port (authorizeUrl base) []
  assertNoRedirect "absent client_id" missingClient

  -- A near-miss on the registered URI: a path suffix. Exact string equality is the whole rule.
  mismatched <-
    getNoRedirect
      mgr
      port
      (authorizeUrl [("client_id", confId), ("response_type", "code"), ("redirect_uri", authorizeRedirectUri <> "/../evil")])
      []
  assertNoRedirect "unregistered redirect_uri" mismatched

  missingUri <- getNoRedirect mgr port (authorizeUrl [("client_id", confId), ("response_type", "code")]) []
  assertNoRedirect "absent redirect_uri" missingUri

-- | EP-5 M2: the happy path and regime two (an error redirect to the /validated/ URI).
scenarioAuthorizeIssuesCode :: IORef World -> Text -> Text -> Int -> IO ()
scenarioAuthorizeIssuesCode ref confId pubId port = do
  mgr <- newManager defaultManagerSettings
  token <- signupToken mgr port "authorize-user"
  let bearer' = [("Authorization", "Bearer " <> Text.encodeUtf8 token)]
      base =
        [ ("client_id", confId),
          ("response_type", "code"),
          ("redirect_uri", authorizeRedirectUri),
          ("scope", "openid profile"),
          ("state", "xyz&spliced=1"),
          ("nonce", "n-0S6"),
          ("code_challenge", testCodeChallenge),
          ("code_challenge_method", "S256")
        ]

  ok <- getNoRedirect mgr port (authorizeUrl base) bearer'
  let (status, hdrs, _) = ok
  status @?= 302
  headerValue "Cache-Control" hdrs @?= Just "no-store"
  (locBase, params) <- locationOf "authorize success" ok
  locBase @?= authorizeRedirectUri
  code <- maybe (assertFailure "no code in the redirect") pure (lookup "code" params)
  assertBool "the code is not empty" (not (T.null code))
  -- `state` round-trips verbatim, including the `&` that would splice a parameter if unencoded.
  lookup "state" params @?= Just "xyz&spliced=1"
  lookup "error" params @?= Nothing
  -- RFC 9207: the issuer identifies which provider answered, so a multi-provider client can
  -- detect a mix-up attack.
  lookup "iss" params @?= Just "https://shomei.test"

  -- The stored row is the code's digest, unconsumed, expiring 60 seconds out.
  world <- readIORef ref
  case Map.elems (oauthCodes world) of
    [stored] -> do
      stored.codeHash @?= sha256Hex code
      stored.consumedAt @?= Nothing
      stored.nonce @?= Just "n-0S6"
      stored.redirectUri @?= authorizeRedirectUri
      stored.clientId @?= confId
      stored.scopes @?= Set.fromList [Scope "openid", Scope "profile"]
      diffUTCTime stored.expiresAt stored.createdAt @?= 60
    other -> assertFailure ("expected exactly one stored code, got " <> show (length other))

  -- Regime two: the client_id and redirect_uri were valid, so the error goes back to the client
  -- at the URI we validated, with the state echoed so it can correlate the failure.
  let errorRedirect what expectedCode params' = do
        r <- getNoRedirect mgr port (authorizeUrl params') bearer'
        let (st, _, _) = r
        assertEqual (what <> ": status") 302 st
        (b, ps) <- locationOf what r
        assertEqual (what <> ": redirect target") authorizeRedirectUri b
        assertEqual (what <> ": error code") (Just expectedCode) (lookup "error" ps)
        assertEqual (what <> ": state echoed") (Just "xyz&spliced=1") (lookup "state" ps)
        assertBool (what <> ": no code is issued") (isNothing (lookup "code" ps))

  errorRedirect "response_type=token" "unsupported_response_type" (replaceParam "response_type" "token" base)
  errorRedirect "scope outside the allow-list" "invalid_scope" (replaceParam "scope" "openid admin:everything" base)
  errorRedirect "code_challenge_method=plain" "invalid_request" (replaceParam "code_challenge_method" "plain" base)

  -- A public client cannot skip PKCE: with no secret, the challenge is its only binding between
  -- this request and the exchange.
  errorRedirect
    "public client without a code_challenge"
    "invalid_request"
    [ ("client_id", pubId),
      ("response_type", "code"),
      ("redirect_uri", authorizeRedirectUri),
      ("scope", "openid"),
      ("state", "xyz&spliced=1")
    ]

  -- Exactly one code was ever minted, by the one successful request.
  world' <- readIORef ref
  Map.size (oauthCodes world') @?= 1

replaceParam :: Text -> Text -> [(Text, Text)] -> [(Text, Text)]
replaceParam k v = map (\(k', v') -> if k' == k then (k, v) else (k', v'))

-- | EP-5 M2: an unauthenticated authorize request bounces to the host's login page carrying the
-- reconstructed authorize URL in @return_to@. Shōmei ships no login UI and persists no pending
-- request; the whole state round-trips in that URL.
scenarioAuthorizeLoginRedirect :: Text -> Int -> IO ()
scenarioAuthorizeLoginRedirect confId port = do
  mgr <- newManager defaultManagerSettings
  let params =
        [ ("client_id", confId),
          ("response_type", "code"),
          ("redirect_uri", authorizeRedirectUri),
          ("scope", "openid"),
          ("state", "xyz"),
          ("code_challenge", testCodeChallenge),
          ("code_challenge_method", "S256")
        ]
  r <- getNoRedirect mgr port (authorizeUrl params) []
  let (status, _, _) = r
  status @?= 302
  (base, qs) <- locationOf "login redirect" r
  base @?= "https://host.test/login"
  returnTo <- maybe (assertFailure "no return_to") pure (lookup "return_to" qs)
  -- The URL is rebuilt from the parameters the handler validated, on the issuer's base -- never
  -- copied from anything the caller supplied.
  assertBool
    ("return_to points back at this provider's authorize endpoint: " <> T.unpack returnTo)
    ("https://shomei.test/oauth/authorize?" `T.isPrefixOf` returnTo)
  let (_, returnQuery) = T.breakOn "?" returnTo
      returnParams =
        [ (Text.decodeUtf8 k, Text.decodeUtf8 v)
        | (k, v) <- parseSimpleQuery (Text.encodeUtf8 (T.drop 1 returnQuery))
        ]
  -- Every parameter the user originally sent survives the round trip, so the host can send them
  -- back here after logging them in and the flow resumes unchanged.
  mapM_ (\(k, v) -> assertEqual ("return_to carries " <> T.unpack k) (Just v) (lookup k returnParams)) params

-- | With no @loginUrl@ configured there is nowhere to send the user, so the request is refused --
-- in the OAuth error shape, because the caller is OAuth tooling.
scenarioAuthorizeNoLoginUrl :: Text -> Int -> IO ()
scenarioAuthorizeNoLoginUrl confId port = do
  mgr <- newManager defaultManagerSettings
  r <-
    getNoRedirect
      mgr
      port
      (authorizeUrl [("client_id", confId), ("response_type", "code"), ("redirect_uri", authorizeRedirectUri)])
      []
  assertOAuthError "unauthenticated with no loginUrl" 401 "login_required" r
  headerValue "Location" (headersOf r) @?= Nothing

-- | EP-5 M3: the whole authorization-code exchange, over the real Servant tree with the real
-- ES256 signer.
--
-- Drives the flow exactly as a client does — authorize, parse the code out of the @Location@,
-- exchange it with the PKCE verifier — and then attacks it: replay, wrong verifier, missing
-- verifier, a different client, a mismatched @redirect_uri@. Every one of those must be an
-- indistinguishable @invalid_grant@, and none may mint a token.
scenarioOAuthCodeExchange :: JWK -> Text -> Text -> Int -> IO ()
scenarioOAuthCodeExchange jwk confId pubId port = do
  mgr <- newManager defaultManagerSettings
  token <- signupToken mgr port "exchange-user"
  let verifier = "a-high-entropy-code-verifier-of-sufficient-length-1234567890" :: Text
      challenge = pkceChallengeFor verifier
      basic = Just (confId, confidentialClientSecret)

      getCode client = do
        r <-
          getNoRedirect
            mgr
            port
            ( authorizeUrl
                [ ("client_id", client),
                  ("response_type", "code"),
                  ("redirect_uri", authorizeRedirectUri),
                  ("scope", "openid profile"),
                  ("nonce", "n-0S6"),
                  ("code_challenge", challenge),
                  ("code_challenge_method", "S256")
                ]
            )
            [("Authorization", "Bearer " <> Text.encodeUtf8 token)]
        (_, params) <- locationOf "authorize" r
        maybe (assertFailure "no code in the redirect") pure (lookup "code" params)

      exchange extra = postForm mgr port "/oauth/token" basic ([("grant_type", "authorization_code")] <> extra)

      exchangeOf code =
        exchange
          [ ("code", Text.encodeUtf8 code),
            ("redirect_uri", Text.encodeUtf8 authorizeRedirectUri),
            ("code_verifier", Text.encodeUtf8 verifier)
          ]

  -- (1) The happy path: three tokens, and the ID token really verifies against the served key.
  code <- getCode confId
  ok@(okStatus, okHdrs, _) <- exchangeOf code
  okStatus @?= 200
  headerValue "Cache-Control" okHdrs @?= Just "no-store"
  body <- must "token body" (bodyOf ok)
  accessToken <- must "access_token" (dig ["access_token"] body >>= asText)
  refreshToken <- must "refresh_token" (dig ["refresh_token"] body >>= asText)
  idToken <- must "id_token" (dig ["id_token"] body >>= asText)
  (dig ["token_type"] body >>= asText) @?= Just "Bearer"
  (dig ["scope"] body >>= asText) @?= Just "openid profile"

  -- The ID token is a real JWS over the same key, addressed to the client, echoing the nonce.
  idClaims <- verifyIdToken jwk idToken
  (KM.lookup "aud" idClaims) @?= Just (String confId)
  (KM.lookup "nonce" idClaims) @?= Just (String "n-0S6")
  (KM.lookup "iss" idClaims) @?= Just (String "https://shomei.test")
  assertBool "auth_time is a number of seconds, not a timestamp string" $
    case KM.lookup "auth_time" idClaims of
      Just (Number _) -> True
      _ -> False
  -- Its `sub` is the very user the access token names.
  accessSub <- subjectOf mgr port accessToken
  KM.lookup "sub" idClaims @?= Just (String accessSub)
  -- An ID token is not a credential: presenting it as a bearer token is refused.
  (meWithId, _) <- getJSON mgr port "/v1/auth/me" [("Authorization", "Bearer " <> Text.encodeUtf8 idToken)]
  meWithId @?= 401

  -- (2) Replay: the code is single-use, and the replay is indistinguishable from an unknown code.
  replay <- exchangeOf code
  assertOAuthError "replaying a code" 400 "invalid_grant" replay
  unknown <- exchangeOf "not-a-real-code"
  assertOAuthError "an unknown code" 400 "invalid_grant" unknown
  assertEqual "a replay and an unknown code are indistinguishable" (bodyOf replay) (bodyOf unknown)

  -- (3) A wrong or absent PKCE verifier. Note each burns its own fresh code.
  wrongVerifier <- do
    c <- getCode confId
    exchange
      [ ("code", Text.encodeUtf8 c),
        ("redirect_uri", Text.encodeUtf8 authorizeRedirectUri),
        ("code_verifier", "the-wrong-verifier-entirely-0000000000000000000000")
      ]
  assertOAuthError "a wrong code_verifier" 400 "invalid_grant" wrongVerifier

  absentVerifier <- do
    c <- getCode confId
    exchange [("code", Text.encodeUtf8 c), ("redirect_uri", Text.encodeUtf8 authorizeRedirectUri)]
  assertOAuthError "an absent code_verifier when a challenge was stored" 400 "invalid_grant" absentVerifier

  -- (4) A mismatched redirect_uri at the exchange.
  mismatchedUri <- do
    c <- getCode confId
    exchange
      [ ("code", Text.encodeUtf8 c),
        ("redirect_uri", "https://app.example.com/somewhere-else"),
        ("code_verifier", Text.encodeUtf8 verifier)
      ]
  assertOAuthError "a mismatched redirect_uri" 400 "invalid_grant" mismatchedUri

  -- (5) A stolen code exchanged by a DIFFERENT client. The public client authenticates with a bare
  -- client_id, which is exactly what a code thief would present.
  stolen <- do
    c <- getCode confId
    postForm
      mgr
      port
      "/oauth/token"
      Nothing
      [ ("grant_type", "authorization_code"),
        ("client_id", Text.encodeUtf8 pubId),
        ("code", Text.encodeUtf8 c),
        ("redirect_uri", Text.encodeUtf8 authorizeRedirectUri),
        ("code_verifier", Text.encodeUtf8 verifier)
      ]
  assertOAuthError "a code stolen by another client" 400 "invalid_grant" stolen

  -- (6) A wrong client secret is invalid_client, not invalid_grant: the client never authenticated.
  badSecret <- do
    c <- getCode confId
    postForm
      mgr
      port
      "/oauth/token"
      (Just (confId, "not-the-secret"))
      [ ("grant_type", "authorization_code"),
        ("code", Text.encodeUtf8 c),
        ("redirect_uri", Text.encodeUtf8 authorizeRedirectUri),
        ("code_verifier", Text.encodeUtf8 verifier)
      ]
  assertOAuthError "a wrong client secret" 401 "invalid_client" badSecret

  -- (7) The refresh grant rotates, and is bound to the client that minted the session.
  let refreshWith who params = postForm mgr port "/oauth/token" who ([("grant_type", "refresh_token")] <> params)

  -- A different client cannot rotate this token, and the refusal does NOT revoke the family.
  wrongClient <- refreshWith Nothing [("client_id", Text.encodeUtf8 pubId), ("refresh_token", Text.encodeUtf8 refreshToken)]
  assertOAuthError "another client refreshing" 400 "invalid_grant" wrongClient

  rotated <- refreshWith basic [("refresh_token", Text.encodeUtf8 refreshToken)]
  let (rotStatus, _, _) = rotated
  rotStatus @?= 200
  rotBody <- must "rotate body" (bodyOf rotated)
  newRefresh <- must "rotated refresh_token" (dig ["refresh_token"] rotBody >>= asText)
  assertBool "the refresh token really rotated" (newRefresh /= refreshToken)
  assertBool "the rotation mints a new access token" (isJust (dig ["access_token"] rotBody >>= asText))
  -- A refresh does not mint an ID token: its nonce and auth_time belong to the authorize request.
  dig ["id_token"] rotBody @?= Nothing

  -- Replaying the now-used refresh token is reuse: the family and the session die.
  reuse <- refreshWith basic [("refresh_token", Text.encodeUtf8 refreshToken)]
  assertOAuthError "replaying a rotated refresh token" 400 "invalid_grant" reuse
  dead <- refreshWith basic [("refresh_token", Text.encodeUtf8 newRefresh)]
  assertOAuthError "the whole family is revoked after reuse" 400 "invalid_grant" dead

-- | A session minted by password login carries no @oauth_client_id@, so it cannot be refreshed at
-- the OAuth token endpoint at all — only at the endpoint that created it.
scenarioOAuthRefreshRejectsUnboundSession :: Text -> Int -> IO ()
scenarioOAuthRefreshRejectsUnboundSession confId port = do
  mgr <- newManager defaultManagerSettings
  (status, body) <-
    postJSON
      mgr
      port
      "/v1/auth/signup"
      (object ["loginId" .= ("unbound-user" :: Text), "password" .= ("correct horse battery staple" :: Text), "displayName" .= ("" :: Text)])
  status @?= 201
  resp <- must "signup body" body
  refreshToken <- must "signup refreshToken" (dig ["token", "refreshToken"] resp >>= asText)

  r <-
    postForm
      mgr
      port
      "/oauth/token"
      (Just (confId, confidentialClientSecret))
      [("grant_type", "refresh_token"), ("refresh_token", Text.encodeUtf8 refreshToken)]
  assertOAuthError "an OAuth client refreshing a password-login session" 400 "invalid_grant" r

  -- And the bespoke endpoint still rotates it, unchanged.
  (bespoke, _) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= refreshToken])
  bespoke @?= 200

-- | The @sub@ claim of an access token, read back through the server's own @\/v1\/auth\/me@.
subjectOf :: Manager -> Int -> Text -> IO Text
subjectOf mgr port accessToken = do
  (status, body) <- getJSON mgr port "/v1/auth/me" [("Authorization", "Bearer " <> Text.encodeUtf8 accessToken)]
  status @?= 200
  resp <- must "me body" body
  must "me userId" (dig ["userId"] resp >>= asText)

-- | Verify an ID token's signature against the test signing key and return its claims.
--
-- Verifying rather than merely decoding is the point: an ID token a relying party cannot check is
-- worthless, and only signing it with the same active key and @kid@ as the access token makes it
-- checkable against the JWKS document this deployment already publishes.
verifyIdToken :: JWK -> Text -> IO (KM.KeyMap Value)
verifyIdToken jwk idToken = do
  result <- runJOSE @JWTError do
    jwt <- decodeCompact (LBS.fromStrict (Text.encodeUtf8 idToken))
    -- `aud` is the client_id, so the audience predicate accepts anything: what is under test is
    -- the signature and the claim contents, which the caller asserts on.
    verifyClaims (defaultJWTValidationSettings (const True)) jwk (jwt :: SignedJWT)
  case result of
    Left e -> assertFailure ("the id_token failed signature verification: " <> show (e :: JWTError))
    Right claims -> case toJSON (claims :: ClaimsSet) of
      Object o -> pure o
      other -> assertFailure ("id_token claims were not an object: " <> show other)

-- | EP-5 M4: userinfo, introspection, and revocation, and the revoke->introspect flip that is
-- this plan's headline acceptance behavior.
scenarioOAuthUserinfoIntrospectRevoke :: JWK -> Text -> Text -> Int -> IO ()
scenarioOAuthUserinfoIntrospectRevoke jwk confId pubId port = do
  mgr <- newManager defaultManagerSettings
  token <- signupToken mgr port "resource-user"
  let verifier = "another-high-entropy-verifier-of-good-length-abcdefghij" :: Text
      challenge = pkceChallengeFor verifier
      basic = Just (confId, confidentialClientSecret)
  code <- do
    r <-
      getNoRedirect
        mgr
        port
        ( authorizeUrl
            [ ("client_id", confId),
              ("response_type", "code"),
              ("redirect_uri", authorizeRedirectUri),
              ("scope", "openid profile"),
              ("code_challenge", challenge),
              ("code_challenge_method", "S256")
            ]
        )
        [("Authorization", "Bearer " <> Text.encodeUtf8 token)]
    (_, params) <- locationOf "authorize" r
    maybe (assertFailure "no code") pure (lookup "code" params)
  resp <-
    postForm
      mgr
      port
      "/oauth/token"
      basic
      [ ("grant_type", "authorization_code"),
        ("code", Text.encodeUtf8 code),
        ("redirect_uri", Text.encodeUtf8 authorizeRedirectUri),
        ("code_verifier", Text.encodeUtf8 verifier)
      ]
  body <- must "token body" (bodyOf resp)
  accessToken <- must "access_token" (dig ["access_token"] body >>= asText)
  refreshToken <- must "refresh_token" (dig ["refresh_token"] body >>= asText)
  idToken <- must "id_token" (dig ["id_token"] body >>= asText)

  -- userinfo: sub matches the ID token's sub, and it is bearer-protected.
  (uiStatus, uiBody) <- getJSON mgr port "/oauth/userinfo" [("Authorization", "Bearer " <> Text.encodeUtf8 accessToken)]
  uiStatus @?= 200
  ui <- must "userinfo body" uiBody
  uiSub <- must "userinfo sub" (dig ["sub"] ui >>= asText)
  idSub <- idTokenSub jwk idToken
  uiSub @?= idSub
  assertBool "userinfo carries scopes" (isJust (dig ["scopes"] ui))
  (noTokenUi, _) <- getJSON mgr port "/oauth/userinfo" []
  noTokenUi @?= 401

  -- introspection requires client auth; without it, 401.
  noAuth <- postForm mgr port "/oauth/introspect" Nothing [("token", Text.encodeUtf8 accessToken)]
  assertOAuthError "introspect without client auth" 401 "invalid_client" noAuth
  -- A public client cannot introspect either: it holds no secret.
  pubAuth <- postForm mgr port "/oauth/introspect" Nothing [("client_id", Text.encodeUtf8 pubId), ("token", Text.encodeUtf8 accessToken)]
  assertOAuthError "a public client introspecting" 401 "invalid_client" pubAuth

  -- A live access token introspects active, with the RFC 7662 fields.
  active <- introspect mgr port basic accessToken
  (dig ["active"] active) @?= Just (Aeson.Bool True)
  (dig ["token_type"] active >>= asText) @?= Just "Bearer"
  (dig ["scope"] active >>= asText) @?= Just "openid profile"
  (dig ["sub"] active >>= asText) @?= Just uiSub
  assertBool "introspection reports sid" (isJust (dig ["sid"] active))

  -- Garbage introspects inactive, at 200 (never an error, to prevent probing).
  garbage <- introspect mgr port basic "not-a-token"
  garbage @?= object ["active" .= False]

  -- The flip: revoke the refresh token, and the access token's session dies with it, so
  -- introspection -- which is session-aware regardless of sessionCheckMode -- now reports inactive.
  (revStatus, _, _) <- postForm mgr port "/oauth/revoke" basic [("token", Text.encodeUtf8 refreshToken), ("token_type_hint", "refresh_token")]
  revStatus @?= 200
  afterRevoke <- introspect mgr port basic accessToken
  (dig ["active"] afterRevoke) @?= Just (Aeson.Bool False)
  -- The refresh token no longer rotates.
  reuse <- postForm mgr port "/oauth/token" basic [("grant_type", "refresh_token"), ("refresh_token", Text.encodeUtf8 refreshToken)]
  assertOAuthError "a revoked refresh token" 400 "invalid_grant" reuse
  -- Revoking an unknown token is still 200 (RFC 7009 forbids erroring, to prevent probing).
  (unknownRev, _, _) <- postForm mgr port "/oauth/revoke" basic [("token", "nonexistent")]
  unknownRev @?= 200

introspect :: Manager -> Int -> Maybe (Text, Text) -> Text -> IO Value
introspect mgr port basic tok = do
  r <- postForm mgr port "/oauth/introspect" basic [("token", Text.encodeUtf8 tok)]
  must "introspection body" (bodyOf r)

-- | The @sub@ claim of an ID token, read through the same signature-verifying path the M3 test
-- uses (so it doubles as a second check that the token verifies). @jwk@ is the test signing key.
idTokenSub :: JWK -> Text -> IO Text
idTokenSub jwk idToken = do
  claims <- verifyIdToken jwk idToken
  case KM.lookup "sub" claims of
    Just (String s) -> pure s
    _ -> assertFailure "id_token has no string sub"

-- | SH-25 M4 acceptance: an HTTP caller can sign up with ONLY a @loginId@ (no email). The
-- returned user has that login id and a @null@ email, and the same identifier logs in.
scenarioNoEmail :: Int -> IO ()
scenarioNoEmail port = do
  mgr <- newManager defaultManagerSettings
  let pw = "correct horse battery staple" :: Text
      signupB = object ["loginId" .= ("agent-x" :: Text), "password" .= pw, "displayName" .= ("" :: Text)]
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupB
  sStatus @?= 201
  sresp <- must "signup body" sBody
  (dig ["user", "loginId"] sresp >>= asText) @?= Just "agent-x"
  dig ["user", "email"] sresp @?= Just Null
  (lStatus, lBody) <- postJSON mgr port "/v1/auth/login" (object ["loginId" .= ("agent-x" :: Text), "password" .= pw])
  lStatus @?= 200
  lresp <- must "login body" lBody
  assertBool "login by identifier yields a token" (isJust (dig ["token", "accessToken"] lresp >>= asText))

-- | SH-25 M4 backward compatibility: an email-only signup (no @loginId@) yields a user whose
-- @loginId@ equals the email text.
scenarioEmailDefaultsLoginId :: Int -> IO ()
scenarioEmailDefaultsLoginId port = do
  mgr <- newManager defaultManagerSettings
  let em = "grace@example.com" :: Text
      pw = "correct horse battery staple" :: Text
      signupB = object ["email" .= em, "password" .= pw, "displayName" .= ("" :: Text)]
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupB
  sStatus @?= 201
  sresp <- must "signup body" sBody
  (dig ["user", "loginId"] sresp >>= asText) @?= Just em
  (dig ["user", "email"] sresp >>= asText) @?= Just em

-- | With @emailVerificationRequired@ on, signup still hands out its initial pair (changing
-- that would break the response shape), but the first re-login and the first refresh are
-- refused with @403 email_not_verified@ — a distinct code, because the password was correct.
-- Confirming the emailed token unblocks both.
scenarioEmailVerificationRequired :: IORef World -> Int -> IO ()
scenarioEmailVerificationRequired ref port = do
  mgr <- newManager defaultManagerSettings
  let em = "unverified@example.com" :: Text
      pw = "correct horse battery staple" :: Text
      loginBody = object ["loginId" .= em, "password" .= pw]
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= em, "password" .= pw, "displayName" .= ("" :: Text)])
  sStatus @?= 201
  sresp <- must "signup body" sBody
  refreshTok <- must "signup refreshToken" (dig ["token", "refreshToken"] sresp >>= asText)

  -- Unverified: a correct password is refused, and so is a silent renewal.
  (blockedLogin, blockedBody) <- postJSON mgr port "/v1/auth/login" loginBody
  blockedLogin @?= 403
  bresp <- must "blocked login body" blockedBody
  (dig ["code"] bresp >>= asText) @?= Just "email_not_verified"
  (blockedRefresh, _) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= refreshTok])
  blockedRefresh @?= 403

  -- Verify the email, and both work again.
  (reqStatus, _) <- postJSON mgr port "/v1/auth/verify-email/request" (object ["email" .= em])
  reqStatus @?= 202
  token <- latestVerificationToken ref
  (confirmStatus, _) <- postJSON mgr port "/v1/auth/verify-email/confirm" (object ["token" .= token])
  confirmStatus @?= 200 -- the verification completes synchronously; nothing is pending
  (okLogin, okBody) <- postJSON mgr port "/v1/auth/login" loginBody
  okLogin @?= 200
  okResp <- must "login body" okBody
  assertBool "verified login yields a token" (isJust (dig ["token", "accessToken"] okResp >>= asText))

-- Cookie transport -----------------------------------------------------------

cookieEmail :: Text
cookieEmail = "cookie@example.com"

cookiePassword :: Text
cookiePassword = "correct horse battery staple"

cookieSignupBody :: Value
cookieSignupBody = object ["email" .= cookieEmail, "password" .= cookiePassword, "displayName" .= ("C" :: Text)]

-- | The origin the default 'CookieConfig' allows.
allowedOrigin :: Header
allowedOrigin = ("Origin", "http://localhost:8080")

foreignOrigin :: Header
foreignOrigin = ("Origin", "https://evil.example.com")

-- | Sign up in cookie mode and return the two cookie values.
cookieSignup :: Manager -> Int -> IO (Text, Text, Maybe Value)
cookieSignup mgr port = do
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 201
  let cookies = setCookies hdrs
  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" cookies)
  refr <- must "shomei_refresh cookie" (cookieValueOf "shomei_refresh" cookies)
  pure (sess, refr, body)

sessionCookieHeader :: Text -> Header
sessionCookieHeader v = ("Cookie", Text.encodeUtf8 ("shomei_session=" <> v))

refreshCookieHeader :: Text -> Header
refreshCookieHeader v = ("Cookie", Text.encodeUtf8 ("shomei_refresh=" <> v))

-- | Cookie mode: the attributes browsers rely on, the token-free body, cookie authentication,
-- and logout clearing.
scenarioCookieTransport :: Int -> IO ()
scenarioCookieTransport port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 201
  let cookies = setCookies hdrs
  length cookies @?= 2

  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" cookies)
  sessionAttrs <- must "shomei_session attributes" (listToMaybe (filter (T.isPrefixOf "shomei_session=") cookies))
  refreshAttrs <- must "shomei_refresh attributes" (listToMaybe (filter (T.isPrefixOf "shomei_refresh=") cookies))

  -- HttpOnly is what puts the token out of an XSS payload's reach.
  assertBool ("session HttpOnly: " <> T.unpack sessionAttrs) ("HttpOnly" `T.isInfixOf` sessionAttrs)
  assertBool "session Secure" ("Secure" `T.isInfixOf` sessionAttrs)
  assertBool "session SameSite=Lax" ("SameSite=Lax" `T.isInfixOf` sessionAttrs)
  assertBool "session Path=/" ("Path=/;" `T.isInfixOf` sessionAttrs)
  assertBool "session Max-Age=900" ("Max-Age=900" `T.isInfixOf` sessionAttrs)
  -- The long-lived credential is presented to exactly one endpoint.
  assertBool ("refresh Path: " <> T.unpack refreshAttrs) ("Path=/v1/auth/refresh" `T.isInfixOf` refreshAttrs)
  assertBool "refresh HttpOnly" ("HttpOnly" `T.isInfixOf` refreshAttrs)
  assertBool "refresh Max-Age=2592000" ("Max-Age=2592000" `T.isInfixOf` refreshAttrs)

  -- The body carries no token values at all — not nulls, not empty strings.
  resp <- must "signup body" body
  assertBool "no accessToken key" (isNothing (dig ["token", "accessToken"] resp))
  assertBool "no refreshToken key" (isNothing (dig ["token", "refreshToken"] resp))
  assertBool "expiresIn present" (isJust (dig ["token", "expiresIn"] resp))

  -- A GET authenticated only by the cookie works, and needs no Origin (safe method).
  (meStatus, _) <- getJSON mgr port "/v1/auth/me" [sessionCookieHeader sess]
  meStatus @?= 200

  -- Logout clears both cookies: same names, empty values, Max-Age=0.
  (outStatus, outHdrs, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess, allowedOrigin] Null
  outStatus @?= 204
  let cleared = setCookies outHdrs
  length cleared @?= 2
  assertBool ("session cleared: " <> show cleared) (any (\c -> "shomei_session=;" `T.isPrefixOf` c && "Max-Age=0" `T.isInfixOf` c) cleared)
  assertBool ("refresh cleared: " <> show cleared) (any (\c -> "shomei_refresh=;" `T.isPrefixOf` c && "Max-Age=0" `T.isInfixOf` c) cleared)

-- | The CSRF matrix on a cookie-authenticated mutating route.
scenarioCsrfMatrix :: Int -> IO ()
scenarioCsrfMatrix port = do
  mgr <- newManager defaultManagerSettings
  (sess, _, _) <- cookieSignup mgr port

  -- No Origin, no Referer: fail closed. This is the attack shape.
  (noneStatus, _, noneBody) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess] Null
  noneStatus @?= 403
  nb <- must "csrf body" noneBody
  (dig ["code"] nb >>= asText) @?= Just "csrf_rejected"

  -- A foreign origin: refused.
  (evilStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess, foreignOrigin] Null
  evilStatus @?= 403

  -- Referer fallback, for agents that omit Origin.
  (refStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess, ("Referer", "http://localhost:8080/app/settings")] Null
  refStatus @?= 204

  -- A Referer that merely *starts with* an allowed origin must not pass.
  (sess2, _, _) <- cookieSignupAs mgr port "csrf2@example.com"
  (badRefStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess2, ("Referer", "http://localhost:8080.evil.com/x")] Null
  badRefStatus @?= 403

  -- An allow-listed Origin: accepted.
  (okStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess2, allowedOrigin] Null
  okStatus @?= 204

  -- A bearer credential is never CSRF-gated, even from a foreign origin: a page cannot set
  -- the Authorization header, and gating it would break every non-browser client.
  (sess3, _, _) <- cookieSignupAs mgr port "csrf3@example.com"
  (bearerStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [("Authorization", Text.encodeUtf8 ("Bearer " <> sess3)), foreignOrigin] Null
  bearerStatus @?= 204

-- | Sign up a distinct account in cookie mode.
cookieSignupAs :: Manager -> Int -> Text -> IO (Text, Text, Maybe Value)
cookieSignupAs mgr port email = do
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] (object ["email" .= email, "password" .= cookiePassword, "displayName" .= ("C" :: Text)])
  status @?= 201
  let cookies = setCookies hdrs
  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" cookies)
  refr <- must "shomei_refresh cookie" (cookieValueOf "shomei_refresh" cookies)
  pure (sess, refr, body)

-- | Refresh from the cookie: rotates, re-sets cookies, and is CSRF-gated like any mutation.
scenarioCookieRefresh :: Int -> IO ()
scenarioCookieRefresh port = do
  mgr <- newManager defaultManagerSettings
  (_, refr, _) <- cookieSignup mgr port

  -- Without an Origin the cookie-borne refresh token is refused.
  (noOrigin, _, _) <- postRaw mgr port "/v1/auth/refresh" [refreshCookieHeader refr] (object [])
  noOrigin @?= 403

  -- With an allow-listed Origin it rotates and hands back fresh cookies.
  (okStatus, okHdrs, okBody) <- postRaw mgr port "/v1/auth/refresh" [refreshCookieHeader refr, allowedOrigin] (object [])
  okStatus @?= 200
  let cookies = setCookies okHdrs
  newRefresh <- must "rotated shomei_refresh" (cookieValueOf "shomei_refresh" cookies)
  assertBool "the refresh token rotated" (newRefresh /= refr)
  resp <- must "refresh body" okBody
  assertBool "cookie mode omits body tokens on refresh" (isNothing (dig ["accessToken"] resp))

  -- Presenting the old token again is reuse: rotation already consumed it.
  (reuseStatus, _, _) <- postRaw mgr port "/v1/auth/refresh" [refreshCookieHeader refr, allowedOrigin] (object [])
  assertBool ("old refresh token must be rejected, got " <> show reuseStatus) (reuseStatus >= 400)

-- | Bearer mode: no cookies emitted, body tokens present, and — the review's finding — a
-- cookie is not accepted as a credential.
scenarioBearerRejectsCookies :: Int -> IO ()
scenarioBearerRejectsCookies port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 201
  setCookies hdrs @?= []
  resp <- must "signup body" body
  access <- must "accessToken" (dig ["token", "accessToken"] resp >>= asText)
  assertBool "refreshToken present" (isJust (dig ["token", "refreshToken"] resp))

  -- The bearer token authenticates.
  (bearerStatus, _) <- getJSON mgr port "/v1/auth/me" [("Authorization", Text.encodeUtf8 ("Bearer " <> access))]
  bearerStatus @?= 200

  -- The very same token presented as a shomei_session cookie does not. Before this plan the
  -- cookie fallback was unconditional and this returned 200.
  (cookieStatus, _) <- getJSON mgr port "/v1/auth/me" [sessionCookieHeader access]
  cookieStatus @?= 401

-- | Both: cookies AND body tokens, for clients migrating between transports.
scenarioBothTransport :: Int -> IO ()
scenarioBothTransport port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 201
  length (setCookies hdrs) @?= 2
  resp <- must "signup body" body
  assertBool "accessToken present in both mode" (isJust (dig ["token", "accessToken"] resp))
  assertBool "refreshToken present in both mode" (isJust (dig ["token", "refreshToken"] resp))
  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" (setCookies hdrs))
  (meStatus, _) <- getJSON mgr port "/v1/auth/me" [sessionCookieHeader sess]
  meStatus @?= 200

scenarioServiceToken :: Int -> IO ()
scenarioServiceToken port = do
  mgr <- newManager defaultManagerSettings
  let body =
        object
          [ "accountId" .= serviceAccountText,
            "secret" .= serviceSecret,
            "scopes" .= [scopeText ingestScope],
            "actorId" .= Null
          ]
  (status, responseBody) <- postJSON mgr port "/v1/auth/service-token" body
  status @?= 200
  response <- must "service-token body" responseBody
  access <- must "service-token accessToken" (dig ["accessToken"] response >>= asText)
  assertBool "service-token response has no refreshToken" (isNothing (dig ["refreshToken"] response))
  (ingestStatus, _) <- getJSON mgr port "/ingest" (bearer access)
  ingestStatus @?= 200

  (deniedStatus, _) <-
    postJSON
      mgr
      port
      "/v1/auth/service-token"
      ( object
          [ "accountId" .= serviceAccountText,
            "secret" .= serviceSecret,
            "scopes" .= ["channel:egress" :: Text],
            "actorId" .= Null
          ]
      )
  deniedStatus @?= 403

  (loginStatus, loginBody) <-
    postJSON
      mgr
      port
      "/v1/auth/login"
      (object ["loginId" .= serviceLoginId, "password" .= servicePassword])
  loginStatus @?= 200
  loginResp <- must "service login body" loginBody
  normalAccess <- must "service login accessToken" (dig ["token", "accessToken"] loginResp >>= asText)
  (normalIngestStatus, _) <- getJSON mgr port "/ingest" (bearer normalAccess)
  normalIngestStatus @?= 403
  where
    serviceAccountText =
      case serviceAccount of
        ServiceAccountId t -> t
    scopeText =
      \case
        Scope t -> t

scenario :: IORef World -> Text -> Text -> Int -> IO ()
scenario ref adminToken impToken port = do
  mgr <- newManager defaultManagerSettings

  -- (a) signup
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupBody
  sStatus @?= 201
  sresp <- must "signup body" sBody
  (dig ["user", "email"] sresp >>= asText) @?= Just email
  (dig ["user", "status"] sresp >>= asText) @?= Just "active"
  adaUserId <- must "signup userId" (dig ["user", "userId"] sresp >>= asText)
  assertBool "signup access token present" (isJust (dig ["token", "accessToken"] sresp >>= asText))
  assertBool "signup refresh token present" (isJust (dig ["token", "refreshToken"] sresp >>= asText))

  -- (a2) verify email via notifier-captured token
  (verifyReqStatus, _) <- postJSON mgr port "/v1/auth/verify-email/request" (object ["email" .= email])
  verifyReqStatus @?= 202
  emailVerificationToken <- latestVerificationToken ref
  (verifyConfirmStatus, _) <- postJSON mgr port "/v1/auth/verify-email/confirm" (object ["token" .= emailVerificationToken])
  verifyConfirmStatus @?= 200

  -- (b) login
  (lStatus, lBody) <- postJSON mgr port "/v1/auth/login" loginBody
  lStatus @?= 200
  lresp <- must "login body" lBody
  access <- must "login accessToken" (dig ["token", "accessToken"] lresp >>= asText)
  refreshTok <- must "login refreshToken" (dig ["token", "refreshToken"] lresp >>= asText)

  -- (c) me with Bearer
  (meStatus, meBody) <- getJSON mgr port "/v1/auth/me" (bearer access)
  meStatus @?= 200
  meresp <- must "me body" meBody
  (dig ["email"] meresp >>= asText) @?= Just email

  -- (d) me without and with garbage token
  (noTokStatus, _) <- getJSON mgr port "/v1/auth/me" []
  noTokStatus @?= 401
  (garbageStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer "garbage.token.value")
  garbageStatus @?= 401

  -- (e) refresh rotates the token
  (rStatus, rBody) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= refreshTok])
  rStatus @?= 200
  rresp <- must "refresh body" rBody
  newRefresh <- must "rotated refreshToken" (dig ["refreshToken"] rresp >>= asText)
  assertBool "rotated refresh token differs" (newRefresh /= refreshTok)

  -- (f) jwks document: public key with kid, no private "d"
  (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
  jStatus @?= 200
  jwks <- must "jwks body" jBody
  assertBool "jwks has keys[].kid" (jwksHasKid jwks)
  assertBool "jwks has no private 'd'" (not (hasKeyDeep "d" jwks))

  -- (g) The RequireRole combinator enforces, with no handler guard behind it.
  --
  --     No token → 401 (the combinator authenticates before it authorizes); a token whose
  --     principal lacks the role → 403; a token minted AFTER a real grant → 200.
  (noTokenAdminStatus, _) <- getJSON mgr port "/admin/users" []
  noTokenAdminStatus @?= 401
  (garbageAdminStatus, _) <- getJSON mgr port "/admin/users" (bearer "garbage.token.value")
  garbageAdminStatus @?= 401
  (forbiddenStatus, _) <- getJSON mgr port "/admin/users" (bearer access)
  forbiddenStatus @?= 403

  -- A hand-signed token carrying the role passes: the combinator reads the claim.
  (adminStatus, _) <- getJSON mgr port "/admin/users" (bearer adminToken)
  adminStatus @?= 200

  -- ...and so does one minted by the real path: grant the role to the logged-in user through
  -- the audited workflow, log in again, and the fresh token opens the same door. This is the
  -- whole loop the plan exists to close — before EP-1, no production flow could mint this token.
  grantAdminTo ref adaUserId
  (grantedLoginStatus, grantedLoginBody) <- postJSON mgr port "/v1/auth/login" loginBody
  grantedLoginStatus @?= 200
  grantedResp <- must "post-grant login body" grantedLoginBody
  grantedAccess <- must "post-grant accessToken" (dig ["token", "accessToken"] grantedResp >>= asText)
  (grantedStatus, _) <- getJSON mgr port "/admin/users" (bearer grantedAccess)
  grantedStatus @?= 200

  -- The pre-grant token is unchanged: a JWT is self-contained, so the role appears only on
  -- tokens minted after the grant (the staleness contract in docs/user/security.md).
  (staleStatus, _) <- getJSON mgr port "/admin/users" (bearer access)
  staleStatus @?= 403

  -- Revoke it again, and the next mint has no role — the other half of the same contract.
  -- (This also restores the pre-grant state for the rest of the scenario, whose later logins
  -- mint fresh tokens for this very user and expect them to be non-admin.)
  revokeAdminFrom ref adaUserId
  (revokedLoginStatus, revokedLoginBody) <- postJSON mgr port "/v1/auth/login" loginBody
  revokedLoginStatus @?= 200
  revokedResp <- must "post-revoke login body" revokedLoginBody
  revokedAccess <- must "post-revoke accessToken" (dig ["token", "accessToken"] revokedResp >>= asText)
  (revokedStatus, _) <- getJSON mgr port "/admin/users" (bearer revokedAccess)
  revokedStatus @?= 403

  -- (g2) The RequireScope combinator enforces the same way. An ordinary login token carries no
  --      scopes; only a service token holds 'kawa:ingest' (exercised in the service-token suite).
  (noTokenIngestStatus, _) <- getJSON mgr port "/ingest" []
  noTokenIngestStatus @?= 401
  (ingestForbiddenStatus, _) <- getJSON mgr port "/ingest" (bearer revokedAccess)
  ingestForbiddenStatus @?= 403

  -- (h) password-reset request/confirm allows login with the new password.
  (resetReqStatus, _) <- postJSON mgr port "/v1/auth/password-reset/request" (object ["email" .= email])
  resetReqStatus @?= 202
  resetToken <- latestResetToken ref
  let changedPassword = "correct horse battery staple two" :: Text
  (resetConfirmStatus, _) <-
    postJSON
      mgr
      port
      "/v1/auth/password-reset/confirm"
      (object ["token" .= resetToken, "newPassword" .= changedPassword])
  resetConfirmStatus @?= 200
  (newLoginStatus, newLoginBody) <- postJSON mgr port "/v1/auth/login" (object ["email" .= email, "password" .= changedPassword])
  newLoginStatus @?= 200
  newLoginResp <- must "new login body" newLoginBody
  access2 <- must "new login accessToken" (dig ["token", "accessToken"] newLoginResp >>= asText)

  -- (i) passkey: begin → complete → list → delete (authenticated with the fresh token)
  (beginStatus, beginBody) <- postJSONAuth mgr port "/v1/auth/passkeys/register/begin" (bearer access2) (object [])
  beginStatus @?= 200
  bresp <- must "begin body" beginBody
  cid <- must "ceremonyId" (dig ["ceremonyId"] bresp >>= asText)
  chal <- must "challenge" (dig ["options", "challenge"] bresp >>= asText)
  let cred =
        object
          [ "challenge" .= chal,
            "credentialId" .= WebAuthnCredentialId "passkey-cred-1",
            "userHandle" .= UserHandle "passkey-uh-1",
            "publicKey" .= PublicKeyBytes "passkey-pk-1"
          ]
      completeBody = object ["ceremonyId" .= cid, "credential" .= cred, "label" .= ("YubiKey" :: Text)]
  (compStatus, compBody) <- postJSONAuth mgr port "/v1/auth/passkeys/register/complete" (bearer access2) completeBody
  compStatus @?= 200
  cresp <- must "complete body" compBody
  pkId <- must "passkeyId" (dig ["passkeyId"] cresp >>= asText)
  (dig ["label"] cresp >>= asText) @?= Just "YubiKey"

  (listStatus, listBody) <- getJSON mgr port "/v1/auth/passkeys" (bearer access2)
  listStatus @?= 200
  listResp <- must "list body" listBody
  case listResp of
    Array xs -> assertBool "one passkey listed" (length xs == 1)
    _ -> assertFailure "expected a JSON array of passkeys"

  (delStatus, _) <- deleteAuth mgr port ("/v1/auth/passkeys/" <> T.unpack pkId) (bearer access2)
  delStatus @?= 204

  (list2Status, list2Body) <- getJSON mgr port "/v1/auth/passkeys" (bearer access2)
  list2Status @?= 200
  list2Resp <- must "list2 body" list2Body
  case list2Resp of
    Array xs -> assertBool "no passkeys after delete" (null xs)
    _ -> assertFailure "expected a JSON array after delete"

  -- (j) re-completing the now-consumed ceremony is a 404
  (badStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/passkeys/register/complete"
      (bearer access2)
      (object ["ceremonyId" .= cid, "credential" .= cred])
  badStatus @?= 404

  -- (k) a passkey route without a bearer token is a 401
  (unauthStatus, _) <- getJSON mgr port "/v1/auth/passkeys" []
  unauthStatus @?= 401

  -- (l) re-enroll a passkey so the account now requires MFA at the next password login.
  (rbStatus, rbBody) <- postJSONAuth mgr port "/v1/auth/passkeys/register/begin" (bearer access2) (object [])
  rbStatus @?= 200
  rbresp <- must "mfa enroll begin body" rbBody
  rbCid <- must "mfa enroll ceremonyId" (dig ["ceremonyId"] rbresp >>= asText)
  rbChal <- must "mfa enroll challenge" (dig ["options", "challenge"] rbresp >>= asText)
  let credAssertion challengeText =
        object
          [ "challenge" .= challengeText,
            "credentialId" .= WebAuthnCredentialId "passkey-cred-2",
            "userHandle" .= UserHandle "passkey-uh-2",
            "publicKey" .= PublicKeyBytes "passkey-pk-2"
          ]
  (rcStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/passkeys/register/complete"
      (bearer access2)
      (object ["ceremonyId" .= rbCid, "credential" .= credAssertion rbChal, "label" .= ("MFA Key" :: Text)])
  rcStatus @?= 200

  -- (m) the password login now returns an MFA challenge and NO token.
  (mfaLoginStatus, mfaLoginBody) <- postJSON mgr port "/v1/auth/login" (object ["email" .= email, "password" .= changedPassword])
  mfaLoginStatus @?= 200
  mfaLoginResp <- must "mfa login body" mfaLoginBody
  (dig ["status"] mfaLoginResp >>= asText) @?= Just "mfa_required"
  assertBool "no access token in the mfa_required body" (isNothing (dig ["token"] mfaLoginResp))
  mfaCeremonyId <- must "mfa login ceremonyId" (dig ["ceremonyId"] mfaLoginResp >>= asText)
  mfaChallenge <- must "mfa login challenge" (dig ["options", "challenge"] mfaLoginResp >>= asText)

  -- (n) completing MFA with a valid assertion yields a token pair.
  (mfaCompleteStatus, mfaCompleteBody) <-
    postJSON mgr port "/v1/auth/mfa/complete" (object ["ceremonyId" .= mfaCeremonyId, "assertion" .= credAssertion mfaChallenge])
  mfaCompleteStatus @?= 200
  mfaCompleteResp <- must "mfa complete body" mfaCompleteBody
  mfaAccess <- must "mfa complete accessToken" (dig ["accessToken"] mfaCompleteResp >>= asText)

  -- (o) the MFA-issued access token authenticates /auth/me.
  (meMfaStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer mfaAccess)
  meMfaStatus @?= 200

  -- (p) re-submitting the now-consumed ceremony is a 404.
  (mfaStaleStatus, _) <-
    postJSON mgr port "/v1/auth/mfa/complete" (object ["ceremonyId" .= mfaCeremonyId, "assertion" .= credAssertion mfaChallenge])
  mfaStaleStatus @?= 404

  -- (q) passwordless login: begin → complete → me, no password.
  (plBeginStatus, plBeginBody) <- postJSON mgr port "/v1/auth/login/passkey/begin" (object [])
  plBeginStatus @?= 200
  plBeginResp <- must "passwordless begin body" plBeginBody
  plCid <- must "passwordless ceremonyId" (dig ["ceremonyId"] plBeginResp >>= asText)
  plChal <- must "passwordless challenge" (dig ["options", "challenge"] plBeginResp >>= asText)
  (plCompleteStatus, plCompleteBody) <-
    postJSON mgr port "/v1/auth/login/passkey/complete" (object ["ceremonyId" .= plCid, "assertion" .= credAssertion plChal])
  plCompleteStatus @?= 200
  plResp <- must "passwordless complete body" plCompleteBody
  plAccess <- must "passwordless accessToken" (dig ["accessToken"] plResp >>= asText)
  (mePlStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer plAccess)
  mePlStatus @?= 200

  -- (r) impersonation: an operator holding the impersonate scope exchanges for a
  -- delegated token, sees the customer via /auth/me, is refused a credential change,
  -- and can stop.
  let impBody = object ["userId" .= adaUserId, "reason" .= ("Debugging support issue" :: Text), "ticketId" .= ("SUP-1234" :: Text)]
  (impStatus, impRespBody) <- postJSONAuth mgr port "/v1/auth/impersonate" (bearer impToken) impBody
  impStatus @?= 200
  impResp <- must "impersonate body" impRespBody
  (dig ["subjectUserId"] impResp >>= asText) @?= Just adaUserId
  assertBool "actorUserId present" (isJust (dig ["actorUserId"] impResp >>= asText))
  impAccess <- must "delegated accessToken" (dig ["accessToken"] impResp >>= asText)

  -- the delegated token resolves the *customer's* identity on /auth/me
  (meImpStatus, meImpBody) <- getJSON mgr port "/v1/auth/me" (bearer impAccess)
  meImpStatus @?= 200
  meImpResp <- must "me (delegated) body" meImpBody
  (dig ["email"] meImpResp >>= asText) @?= Just email

  -- a credential change under the delegated token is refused with 403
  (impPwStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/password/change"
      (bearer impAccess)
      (object ["currentPassword" .= ("x" :: Text), "newPassword" .= ("y" :: Text)])
  impPwStatus @?= 403

  -- the operator's OWN token is not impersonation-blocked: it reaches the normal
  -- credential path (and fails there as invalid credentials, NOT 403).
  (opPwStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/password/change"
      (bearer impToken)
      (object ["currentPassword" .= ("x" :: Text), "newPassword" .= ("y" :: Text)])
  assertBool "operator's own token is not impersonation-blocked" (opPwStatus /= 403)

  -- stop impersonating revokes the delegated session
  (stopStatus, _) <- deleteAuth mgr port "/v1/auth/impersonate" (bearer impAccess)
  stopStatus @?= 204
  world <- readIORef ref
  let delegated = filter (\s -> isJust s.actor) (Map.elems world.sessions)
  case delegated of
    [s] -> s.status @?= SessionRevoked
    _ -> assertFailure ("expected exactly one delegated session, got " <> show (length delegated))

  -- (s) EP-7 audit retrieval: admin reads the trail; non-admin/no-token are refused;
  -- filters and keyset pagination behave.
  (auditNoTokStatus, _) <- getJSON mgr port "/v1/admin/audit/events" []
  auditNoTokStatus @?= 401
  (auditForbiddenStatus, _) <- getJSON mgr port "/v1/admin/audit/events" (bearer plAccess)
  auditForbiddenStatus @?= 403
  (auditStatus, auditBody) <- getJSON mgr port "/v1/admin/audit/events" (bearer adminToken)
  auditStatus @?= 200
  auditResp <- must "audit body" auditBody
  case dig ["events"] auditResp of
    Just (Array xs) -> assertBool "audit trail is non-empty" (not (null xs))
    _ -> assertFailure "expected an events array"

  -- type filter: every returned row is a login_succeeded (and there is at least one)
  (auditTypeStatus, auditTypeBody) <- getJSON mgr port "/v1/admin/audit/events?type=login_succeeded" (bearer adminToken)
  auditTypeStatus @?= 200
  auditTypeResp <- must "audit type body" auditTypeBody
  case dig ["events"] auditTypeResp of
    Just (Array xs) -> do
      assertBool "at least one login_succeeded event" (not (null xs))
      assertBool
        "every returned event is login_succeeded"
        (all (\e -> (field "eventType" e >>= asText) == Just "login_succeeded") (toList xs))
    _ -> assertFailure "expected an events array"

  -- a malformed UUID filter is a 400
  (auditBadStatus, _) <- getJSON mgr port "/v1/admin/audit/events?user=not-a-uuid" (bearer adminToken)
  auditBadStatus @?= 400

  -- keyset pagination: limit=1, then follow nextCursor; the two pages are disjoint.
  (p1Status, p1Body) <- getJSON mgr port "/v1/admin/audit/events?limit=1" (bearer adminToken)
  p1Status @?= 200
  p1Resp <- must "audit page1 body" p1Body
  p1Events <- case dig ["events"] p1Resp of
    Just (Array xs) -> pure (toList xs)
    _ -> assertFailure "expected events array (page1)"
  assertBool "page1 has exactly one event" (length p1Events == 1)
  cursor <- must "page1 nextCursor" (dig ["nextCursor"] p1Resp >>= asText)
  let p1Id = listToMaybe p1Events >>= field "eventId" >>= asText
  (p2Status, p2Body) <-
    getJSON mgr port ("/v1/admin/audit/events?limit=1&before=" <> urlEncodeText cursor) (bearer adminToken)
  p2Status @?= 200
  p2Resp <- must "audit page2 body" p2Body
  p2Events <- case dig ["events"] p2Resp of
    Just (Array xs) -> pure (toList xs)
    _ -> assertFailure "expected events array (page2)"
  assertBool "page2 has exactly one event" (length p2Events == 1)
  let p2Id = listToMaybe p2Events >>= field "eventId" >>= asText
  assertBool "the two pages are disjoint" (p1Id /= p2Id)
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text
    signupBody = object ["email" .= email, "password" .= password, "displayName" .= ("Ada Lovelace" :: Text)]
    loginBody = object ["email" .= email, "password" .= password]

latestVerificationToken :: IORef World -> IO Text
latestVerificationToken ref = do
  w <- readIORef ref
  case w.sentNotifications of
    EmailVerificationRequested {token = OneTimeToken t} : _ -> pure t
    _ -> assertFailure "expected email-verification notification"

latestResetToken :: IORef World -> IO Text
latestResetToken ref = do
  w <- readIORef ref
  case w.sentNotifications of
    PasswordResetRequested {token = OneTimeToken t} : _ -> pure t
    _ -> assertFailure "expected password-reset notification"

-- | EP-7: the TOTP + recovery-code flow end to end over HTTP. The in-memory World's clock is
-- fixed, so the scenario advances it deliberately to move TOTP time-step counters forward (a
-- confirmed code cannot be reused for a login at the same counter — the strictly-greater replay
-- rule) and, at the end, to age a token past the freshness window.
scenarioTotp :: IORef World -> JWK -> ShomeiConfig -> Int -> IO ()
scenarioTotp r jwk cfg port = do
  mgr <- newManager defaultManagerSettings
  let email = "totp@example.com" :: Text
      pw = "correct horse battery staple totp" :: Text
      login = postJSON mgr port "/v1/auth/login" (object ["email" .= email, "password" .= pw])
      complete cid body = postJSON mgr port "/v1/auth/mfa/complete" (object (["ceremonyId" .= cid] <> body))

  -- signup, then a first (factor-free) login for a working token.
  (suStatus, _) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("T" :: Text)])
  suStatus @?= 201
  (liStatus, liBody) <- login
  liStatus @?= 200
  (liBody >>= dig ["status"] >>= asText) @?= Just "complete"
  access <- must "login accessToken" (liBody >>= dig ["token", "accessToken"] >>= asText)

  -- Move the deterministic World clock ~2 minutes into the PAST relative to the real wall clock,
  -- then step it forward. Tokens minted at these World times keep an @nbf@/@exp@ that jose (which
  -- validates against the real clock) still accepts, while their time-step counters advance so a
  -- confirmed code cannot be replayed at the next login (the strictly-greater rule).
  now0 <- clock <$> readIORef r
  let start = addUTCTime (-120) now0
  setClock r start

  -- enroll: secret shown once, plus an otpauth URI.
  (enStatus, enBody) <- postAuthNoBody mgr port "/v1/auth/totp/enroll" (bearer access)
  assertEqual ("enroll body: " <> show enBody) 200 enStatus
  secretB32 <- must "enroll secret" (enBody >>= dig ["secret"] >>= asText)
  assertBool "otpauth uri present" (isJust (enBody >>= dig ["otpauthUri"]))
  secret <- either (\e -> assertFailure ("bad base32 secret: " <> e)) pure (base32ToSecret secretB32)
  let codeAt t = totpCode 6 secret (totpCounter t)

  -- activate with the current code.
  (vStatus, _) <- postJSONAuth mgr port "/v1/auth/totp/verify" (bearer access) (object ["code" .= codeAt start])
  vStatus @?= 200

  -- step the clock so a login-complete code is a strictly-later counter than the confirming one.
  let t1 = addUTCTime 60 start
  setClock r t1

  -- login now challenges; a TOTP-only user gets empty options and a methods list naming totp.
  (m1Status, m1Body) <- login
  m1Status @?= 200
  (m1Body >>= dig ["status"] >>= asText) @?= Just "mfa_required"
  m1Methods <- must "methods" (m1Body >>= dig ["methods"] >>= asTextArray)
  assertBool "totp advertised in methods" ("totp" `elem` m1Methods)
  (m1Body >>= dig ["options"]) @?= Just (object [])
  cid1 <- must "ceremonyId" (m1Body >>= dig ["ceremonyId"] >>= asText)

  -- complete with the code for the current counter.
  let code1 = codeAt t1
  (c1Status, c1Body) <- complete cid1 ["totpCode" .= code1]
  c1Status @?= 200
  totpAccess <- must "totp accessToken" (c1Body >>= dig ["accessToken"] >>= asText)

  -- replaying that same code at a fresh challenge fails: its counter is now spent.
  (m2Status, m2Body) <- login
  m2Status @?= 200
  cid2 <- must "cid2" (m2Body >>= dig ["ceremonyId"] >>= asText)
  (rStatus, rBody) <- complete cid2 ["totpCode" .= code1]
  rStatus @?= 401
  (rBody >>= dig ["code"] >>= asText) @?= Just "totp_code_invalid"

  -- a completion naming two arms is a 400 (the exactly-one rule) before any workflow runs.
  (arityStatus, _) <- complete ("webauthn_ceremony_x" :: Text) ["totpCode" .= code1, "recoveryCode" .= ("7Q2FK-9XPRD" :: Text)]
  arityStatus @?= 400

  -- generate recovery codes (the token is fresh: issued at the current clock).
  (gStatus, gBody) <- postAuthNoBody mgr port "/v1/auth/recovery-codes" (bearer totpAccess)
  gStatus @?= 200
  codes <- must "recovery codes" (gBody >>= dig ["codes"] >>= asTextArray)
  length codes @?= 10
  (cntStatus, cntBody) <- getJSON mgr port "/v1/auth/recovery-codes" (bearer totpAccess)
  cntStatus @?= 200
  (cntBody >>= dig ["remaining"] >>= asInt) @?= Just 10

  -- complete a login with a recovery code; the count then drops by one.
  (m3Status, m3Body) <- login
  m3Status @?= 200
  m3Methods <- must "m3 methods" (m3Body >>= dig ["methods"] >>= asTextArray)
  assertBool "recovery_code advertised in methods" ("recovery_code" `elem` m3Methods)
  cid3 <- must "cid3" (m3Body >>= dig ["ceremonyId"] >>= asText)
  let firstRecovery = head codes
  (rc1Status, rc1Body) <- complete cid3 ["recoveryCode" .= firstRecovery]
  rc1Status @?= 200
  rcAccess <- must "recovery accessToken" (rc1Body >>= dig ["accessToken"] >>= asText)
  (cnt2Status, cnt2Body) <- getJSON mgr port "/v1/auth/recovery-codes" (bearer rcAccess)
  cnt2Status @?= 200
  (cnt2Body >>= dig ["remaining"] >>= asInt) @?= Just 9

  -- the same recovery code cannot be spent twice.
  (m4Status, m4Body) <- login
  m4Status @?= 200
  cid4 <- must "cid4" (m4Body >>= dig ["ceremonyId"] >>= asText)
  (rc2Status, rc2Body) <- complete cid4 ["recoveryCode" .= firstRecovery]
  rc2Status @?= 401
  (rc2Body >>= dig ["code"] >>= asText) @?= Just "recovery_code_invalid"

  -- enrolling under a delegated (impersonation) token is refused with an audited 403.
  delegatedTok <- do
    uid <- genUserId
    sid <- genSessionId
    opUid <- genUserId
    let claims =
          AuthClaims
            { subject = uid,
              sessionId = sid,
              issuer = cfg.issuer,
              audience = cfg.audience,
              issuedAt = start,
              expiresAt = addUTCTime 900 start,
              scopes = Set.empty,
              roles = Set.empty,
              permissions = Set.empty,
              actor = Just opUid,
              extraClaims = mempty
            }
    signAccessToken jwk claims >>= either (\e -> assertFailure ("sign delegated: " <> show e)) (\(AccessToken t) -> pure t)
  (impStatus, impBody) <- postAuthNoBody mgr port "/v1/auth/totp/enroll" (bearer delegatedTok)
  impStatus @?= 403
  (impBody >>= dig ["code"] >>= asText) @?= Just "impersonation_action_blocked"

  -- remove the factor with a current code (step the clock again so the code is a later counter),
  -- after which login no longer challenges (recovery codes alone do not trigger MFA).
  let t2 = addUTCTime 60 t1
  setClock r t2
  (delStatus, _) <- deleteAuthBody mgr port "/v1/auth/totp" (bearer totpAccess) (object ["code" .= codeAt t2])
  delStatus @?= 204
  (afterStatus, afterBody) <- login
  afterStatus @?= 200
  (afterBody >>= dig ["status"] >>= asText) @?= Just "complete"

  -- regenerating recovery codes on a token older than the freshness window is refused. Advancing
  -- the World clock ages the earlier token (its jose exp is checked against real time, so it stays
  -- otherwise valid); the freshness gate compares the token's issuedAt to the World clock's now.
  let t3 = addUTCTime 600 t1
  setClock r t3
  (frStatus, frBody) <- postAuthNoBody mgr port "/v1/auth/recovery-codes" (bearer totpAccess)
  frStatus @?= 403
  (frBody >>= dig ["code"] >>= asText) @?= Just "reauthentication_required"

-- Request helpers (parseRequest does not throw on non-2xx, so 401/403/404 come back
-- as ordinary responses).

postJSON :: Manager -> Int -> String -> Value -> IO (Int, Maybe Value)
postJSON mgr port path body = do
  (status, _, b) <- postRaw mgr port path [] body
  pure (status, b)

-- | POST with arbitrary headers, exposing the response's headers too — the cookie tests
-- assert on @Set-Cookie@.
postRaw :: Manager -> Int -> String -> [Header] -> Value -> IO (Int, [Header], Maybe Value)
postRaw mgr port path hdrs body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = ("Content-Type", "application/json") : hdrs,
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | The @Set-Cookie@ values of a response, in order.
setCookies :: [Header] -> [Text]
setCookies hdrs = [Text.decodeUtf8 v | (n, v) <- hdrs, n == "Set-Cookie"]

-- | The value of the named cookie from a @Set-Cookie@ list (the bit before the first @;@).
cookieValueOf :: Text -> [Text] -> Maybe Text
cookieValueOf name =
  listToMaybe . mapMaybe (T.stripPrefix (name <> "=") . T.takeWhile (/= ';'))

getJSON :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
getJSON mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | POST a JSON body with extra headers (e.g. a Bearer token).
postJSONAuth :: Manager -> Int -> String -> [Header] -> Value -> IO (Int, Maybe Value)
postJSONAuth mgr port path hdrs body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = ("Content-Type", "application/json") : hdrs,
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | DELETE with extra headers (e.g. a Bearer token).
deleteAuth :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
deleteAuth mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "DELETE", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | DELETE with a JSON body and extra headers (the TOTP-removal shape).
deleteAuthBody :: Manager -> Int -> String -> [Header] -> Value -> IO (Int, Maybe Value)
deleteAuthBody mgr port path hdrs body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "DELETE",
            requestHeaders = ("Content-Type", "application/json") : hdrs,
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | PUT with a bearer token and no body (the role-grant shape).
putAuth :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
putAuth mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "PUT", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | POST with a bearer token and no body (suspend/reinstate/password-reset).
postAuthNoBody :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
postAuthNoBody mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "POST", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

bearer :: Text -> [Header]
bearer tok = [("Authorization", "Bearer " <> Text.encodeUtf8 tok)]

-- | Percent-encode a query-string value (the audit cursor carries @:@, @.@, @;@).
urlEncodeText :: Text -> String
urlEncodeText = T.unpack . Text.decodeUtf8 . urlEncode True . Text.encodeUtf8

-- JSON navigation helpers.

must :: String -> Maybe a -> IO a
must label = maybe (assertFailure ("missing: " <> label)) pure

field :: Text -> Value -> Maybe Value
field k (Object o) = KM.lookup (K.fromText k) o
field _ _ = Nothing

dig :: [Text] -> Value -> Maybe Value
dig ks v0 = foldl (\mv k -> mv >>= field k) (Just v0) ks

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing

asTextArray :: Value -> Maybe [Text]
asTextArray (Array xs) = traverse asText (toList xs)
asTextArray _ = Nothing

asInt :: Value -> Maybe Int
asInt (Number n) = Just (round n)
asInt _ = Nothing

-- | Move the in-memory World's deterministic clock (EP-7 tests advance it to step TOTP counters
-- forward and to age a token past the freshness window).
setClock :: IORef World -> UTCTime -> IO ()
setClock r t = modifyIORef' r (\w -> w {clock = t})

-- | Does the document have @keys@ as a non-empty array whose first element has a @kid@?
jwksHasKid :: Value -> Bool
jwksHasKid v = case dig ["keys"] v of
  Just (Array xs) -> case toList xs of
    (k0 : _) -> isJust (field "kid" k0)
    [] -> False
  _ -> False

-- | Recursively: does any object anywhere in the value carry a key named @k@?
hasKeyDeep :: Text -> Value -> Bool
hasKeyDeep k = go
  where
    go (Object o) = any (\(kk, vv) -> K.toText kk == k || go vv) (KM.toList o)
    go (Array xs) = any go (toList xs)
    go _ = False
