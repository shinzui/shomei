-- | End-to-end test for the standalone server: a fresh ephemeral PostgreSQL database
-- (via @shomei-migrations:test-support@), the real server in-process through warp's
-- 'testWithApplication', driven over HTTP with @http-client@. Asserts the full lifecycle —
-- signup, login, me (with and without a token), refresh rotation, refresh-token reuse
-- detection (HTTP 401 plus the persisted session revocation and reuse event), logout, the
-- public JWKS document, and health — i.e. the vertical slice actually behaves against real
-- PostgreSQL and real ES256 signing.
module Shomei.Server.E2ESpec (tests) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Data.Aeson (Value (Array, Bool, Object, String), decode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64U
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.IORef (newIORef)
import Data.Int (Int64)
import Data.Maybe (isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
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
import Network.HTTP.Types (Header, status200, statusCode)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Shomei.Config (NotifierConfig (..), NotifierTransport (..), OAuthConfig (..), ShomeiConfig (..), TotpConfig (..), WebhookConfig (..), defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..), newHashingLimiter)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Domain.LoginId (mkLoginId)
import Shomei.Domain.OAuthClient (ClientType (..), NewOAuthClient (..))
import Shomei.Domain.ServiceAccount (NewServiceAccount (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (NewUser (..), User (..))
import Shomei.Effect.Clock (now)
import Shomei.Effect.OAuthClientStore (createOAuthClient)
import Shomei.Effect.ServiceAccountStore (createServiceAccount)
import Shomei.Effect.UserStore (createUser)
import Shomei.Error (AuthError)
import Shomei.Id (UserId, genOAuthClientId, genServiceAccountDbId, genSessionId, idText)
import Shomei.Jwt.Sign (signAccessToken)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Notify (webhookSignature)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.OAuthClientStore (runOAuthClientStorePostgres)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.ServiceAccountStore (runServiceAccountStorePostgres)
import Shomei.Postgres.TotpCredentialStore (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application)
import Shomei.Server.Keys (LoadedKeys (..), bootstrapKeys)
import Shomei.Totp (base32ToSecret, totpCode, totpCounter)
import Shomei.Workflow.OAuthTokenGrant (pkceChallengeFor)
import Shomei.Workflow.ServiceToken (sha256Hex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "auth lifecycle over HTTP against PostgreSQL"
    [ testCase "signup → login → me(±token) → refresh → reuse-detect → logout → jwks → health" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = e2eTotpKey}
          testWithApplication (pure (application env)) (scenario pool),
      testCase "EP-4: service account → POST /oauth/token → the token authenticates and is audited" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = e2eTotpKey}
          clientId <- seedServiceAccount pool
          testWithApplication (pure (application env)) (oauthScenario pool clientId),
      testCase "EP-5: authorize → exchange (PKCE) → verify id_token vs JWKS → userinfo → introspect → revoke → introspect" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          -- OIDC needs an http(s) issuer (it doubles as the endpoint base URL) and the provider on.
          let baseCfg = defaultShomeiConfig (Issuer "http://localhost") (Audience "shomei-clients")
              cfg = baseCfg {oauthConfig = baseCfg.oauthConfig {oidcEnabled = True}}
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = e2eTotpKey}
          clientId <- seedOAuthClient pool
          testWithApplication (pure (application env)) (oidcScenario clientId),
      testCase "EP-6: token-exchange (on-behalf-of + impersonation) → verified vs JWKS → audited" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keys <- bootstrapKeys Nothing ES256 pool
          keysRef <- newIORef keys
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = e2eTotpKey}
          clientId <- seedExchangeServiceAccount pool
          -- The operator token must verify against the server's own key material, so it is signed
          -- with the active signing key (scope granting is host-side; here the host is the test).
          -- The operator must be a real user row: a delegated session's actor_user_id is a foreign
          -- key into shomei_users.
          opUid <- seedOperatorUser pool
          opSid <- genSessionId
          t <- getCurrentTime
          let opClaims =
                AuthClaims
                  { subject = opUid,
                    sessionId = opSid,
                    issuer = cfg.issuer,
                    audience = cfg.audience,
                    issuedAt = t,
                    expiresAt = addUTCTime 900 t,
                    scopes = Set.singleton (Scope "impersonate:user"),
                    roles = Set.empty,
                    actor = Nothing,
                    extraClaims = mempty
                  }
          AccessToken opTok <- either (assertFailure . ("could not sign the operator token: " <>) . show) pure =<< signAccessToken keys.signingKey opClaims
          testWithApplication (pure (application env)) (exchangeScenario pool clientId opTok),
      testCase "EP-7: enroll TOTP → verify → login(mfa) → complete → recovery codes → audited" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              cfg = baseCfg {totpConfig = baseCfg.totpConfig {totpEnabled = True}}
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = e2eTotpKey}
          testWithApplication (pure (application env)) (totpScenario pool),
      testCase "EP-8: webhook transport delivers a signed verification payload whose token is live" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          captured <- newMVar []
          let whSecret = "e2e-webhook-secret" :: Text
              stubApp rq respond = do
                b <- LBS.toStrict <$> Wai.strictRequestBody rq
                modifyMVar_ captured (pure . (<> [(Wai.requestHeaders rq, b)]))
                respond (Wai.responseLBS status200 [] "")
          -- The stub receiver must be up before the app so the synchronous delivery lands.
          testWithApplication (pure stubApp) \stubPort -> do
            let baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
                nc0 = baseCfg.notifierConfig
                webhookCfg =
                  WebhookConfig
                    { url = Text.pack ("http://127.0.0.1:" <> show stubPort <> "/hook"),
                      secret = whSecret,
                      timeoutSeconds = 5,
                      maxAttempts = 1
                    }
                cfg = baseCfg {notifierConfig = nc0 {notifierTransport = WebhookNotifier, webhookConfig = Just webhookCfg}}
                env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = e2eTotpKey}
            testWithApplication (pure (application env)) (webhookScenario captured whSecret)
    ]

-- | EP-8 against the real server: a signup + verify-email request delivered over the webhook
-- transport produces one signed @email_verification_requested@ POST whose token, replayed at
-- @\/v1\/auth\/verify-email\/confirm@, verifies the email — proving the delivered token is live.
webhookScenario :: MVar [([Header], BS.ByteString)] -> Text -> Int -> IO ()
webhookScenario captured whSecret port = do
  mgr <- newManager defaultManagerSettings
  let email = "webhook-user@example.com" :: Text
      pw = "correct horse battery staple" :: Text
  (sStatus, _) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("" :: Text)])
  sStatus @?= 201
  -- The delivery is synchronous inside the request handler, so the stub has captured it by 202.
  (reqStatus, _) <- postJSON mgr port "/v1/auth/verify-email/request" (object ["email" .= email])
  reqStatus @?= 202
  reqs <- readMVar captured
  case reqs of
    [(hdrs, body)] -> do
      lookup "X-Shomei-Notification-Type" hdrs @?= Just "email_verification_requested"
      lookup "Content-Type" hdrs @?= Just "application/json"
      -- the signature is the HMAC over the exact bytes delivered
      lookup "X-Shomei-Signature" hdrs @?= Just (webhookSignature (Text.encodeUtf8 whSecret) body)
      token <- must "token in webhook payload" (decode (LBS.fromStrict body) >>= dig ["token"] >>= asText)
      -- the delivered token is the live one: it confirms the email.
      (cStatus, _) <- postJSON mgr port "/v1/auth/verify-email/confirm" (object ["token" .= token])
      cStatus @?= 200
    _ -> assertFailure ("expected exactly one webhook delivery, got " <> show (length reqs))

-- | A fixed 32-byte AES-256-GCM key for the E2E TOTP secrets. Its value is irrelevant to the
-- test; it only has to round-trip encrypt→decrypt through 'Shomei.Postgres.TotpCredentialStore'.
e2eTotpKey :: TotpEncryptionKey
e2eTotpKey = either (error . Text.unpack) id (totpEncryptionKeyFromBytes (BS.replicate 32 9))

-- | The secret the seeded OAuth client authenticates with; only its digest reaches the row.
oidcClientSecret :: Text
oidcClientSecret = "e2e-oauth-client-secret"

oidcRedirectUri :: Text
oidcRedirectUri = "http://localhost:9999/callback"

-- | Insert a confidential OAuth client through the PostgreSQL interpreter, as
-- @shomei-admin oauth-clients create@ does. Returns its @client_id@.
seedOAuthClient :: Pool -> IO Text
seedOAuthClient pool = do
  outcome <-
    runEff
      . runErrorNoCallStack @AuthError
      . runDatabasePool pool
      . runClockIO
      . runOAuthClientStorePostgres
      $ do
        ocid <- genOAuthClientId
        let cid = idText ocid
        ts <- now
        _ <-
          createOAuthClient
            NewOAuthClient
              { oauthClientId = ocid,
                clientId = cid,
                secretHash = Just (sha256Hex oidcClientSecret),
                clientType = ConfidentialClient,
                displayName = "e2e rp",
                redirectUris = [oidcRedirectUri],
                allowedScopes = Set.fromList [Scope "openid", Scope "profile"],
                createdAt = ts
              }
        pure cid
  either (assertFailure . ("could not seed the oauth client: " <>) . show) pure outcome

-- | The full OIDC transcript from this plan's Purpose, against real PostgreSQL and real ES256.
oidcScenario :: Text -> Int -> IO ()
oidcScenario clientId port = do
  mgr <- newManager defaultManagerSettings

  -- A user to authenticate the authorize request.
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["loginId" .= ("oidc-user" :: Text), "password" .= ("correct horse battery staple" :: Text), "displayName" .= ("" :: Text)])
  sStatus @?= 201
  sresp <- must "signup body" sBody
  userToken <- must "signup accessToken" (dig ["token", "accessToken"] sresp >>= asText)

  let verifier = "an-e2e-pkce-code-verifier-of-more-than-forty-three-chars" :: Text
      challenge = pkceChallengeFor verifier
      basic = Just (clientId, oidcClientSecret)

  -- authorize with the user's bearer token → 302 carrying a single-use code.
  authResp <-
    getNoRedirect
      mgr
      port
      ( "/oauth/authorize?response_type=code&client_id="
          <> Text.unpack clientId
          <> "&redirect_uri="
          <> escape oidcRedirectUri
          <> "&scope=openid%20profile&state=xyz&nonce=n-0S6&code_challenge="
          <> Text.unpack challenge
          <> "&code_challenge_method=S256"
      )
      (bearer userToken)
  let (authStatus, authHdrs, _) = authResp
  authStatus @?= 302
  loc <- must "Location" (lookup "Location" authHdrs >>= (Just . Text.decodeUtf8))
  code <- must "code in redirect" (paramFrom "code" loc)

  -- exchange with the PKCE verifier → all three tokens.
  (xStatus, _, xBody) <- postForm mgr port "/oauth/token" basic [("grant_type", "authorization_code"), ("code", Text.encodeUtf8 code), ("redirect_uri", Text.encodeUtf8 oidcRedirectUri), ("code_verifier", Text.encodeUtf8 verifier)]
  xStatus @?= 200
  xresp <- must "token body" xBody
  access <- must "access_token" (dig ["access_token"] xresp >>= asText)
  refresh <- must "refresh_token" (dig ["refresh_token"] xresp >>= asText)
  idToken <- must "id_token" (dig ["id_token"] xresp >>= asText)

  -- the id_token's signing key is published, its aud is the client, its nonce echoes.
  (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
  jStatus @?= 200
  jwks <- must "jwks body" jBody
  assertBool "the id_token's kid is in the served JWKS" (maybe False (`elem` jwksKids jwks) (jwtHeaderKid idToken))
  idPayload <- must "id_token payload" (jwtPayload idToken)
  (dig ["aud"] idPayload >>= asText) @?= Just clientId
  (dig ["nonce"] idPayload >>= asText) @?= Just "n-0S6"

  -- userinfo: same sub as the id_token.
  (uStatus, uBody) <- getJSON mgr port "/oauth/userinfo" (bearer access)
  uStatus @?= 200
  uresp <- must "userinfo body" uBody
  (dig ["sub"] uresp >>= asText) @?= (dig ["sub"] idPayload >>= asText)

  -- introspect the access token → active.
  (iStatus, _, iBody) <- postForm mgr port "/oauth/introspect" basic [("token", Text.encodeUtf8 access)]
  iStatus @?= 200
  iresp <- must "introspect body" iBody
  dig ["active"] iresp @?= Just (jsonBool True)

  -- revoke the refresh token → 200.
  (rStatus, _, _) <- postForm mgr port "/oauth/revoke" basic [("token", Text.encodeUtf8 refresh), ("token_type_hint", "refresh_token")]
  rStatus @?= 200

  -- introspect again → inactive (the session is gone, and introspection is session-aware).
  (i2Status, _, i2Body) <- postForm mgr port "/oauth/introspect" basic [("token", Text.encodeUtf8 access)]
  i2Status @?= 200
  i2resp <- must "introspect body 2" i2Body
  dig ["active"] i2resp @?= Just (jsonBool False)

-- | The @Location@ query parameter named @k@, percent-decoded enough for our fixed values.
paramFrom :: Text -> Text -> Maybe Text
paramFrom k loc = do
  let (_, query) = Text.breakOn "?" loc
  listToMaybe [v | pair <- Text.splitOn "&" (Text.drop 1 query), let (n, rest) = Text.breakOn "=" pair, n == k, let v = Text.drop 1 rest]

-- | GET without following redirects, so a 302 is the response under test.
getNoRedirect :: Manager -> Int -> String -> [Header] -> IO (Int, [Header], Maybe Value)
getNoRedirect mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs, redirectCount = 0}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | A JWT's payload segment as JSON (unverified; the kid/JWKS check above is the signature proof).
jwtPayload :: Text -> Maybe Value
jwtPayload token = do
  seg <- case Text.splitOn "." token of (_ : p : _) -> Just p; _ -> Nothing
  raw <- either (const Nothing) Just (B64U.decodeBase64UnpaddedUntyped (Text.encodeUtf8 seg))
  decode (LBS.fromStrict raw)

-- | Minimal percent-encoding for the fixed redirect URI in the authorize query string.
escape :: Text -> String
escape = concatMap enc . Text.unpack
  where
    enc ':' = "%3A"
    enc '/' = "%2F"
    enc c = [c]

jsonBool :: Bool -> Value
jsonBool = Aeson.Bool

-- | The secret the seeded service account authenticates with. Only its digest reaches the row.
oauthSecret :: Text
oauthSecret = "e2e-service-secret"

-- | Insert a service account and its backing user straight through the PostgreSQL interpreters,
-- as @shomei-admin service-accounts create@ does. Returns its @client_id@.
seedServiceAccount :: Pool -> IO Text
seedServiceAccount pool = do
  outcome <-
    runEff
      . runErrorNoCallStack @AuthError
      . runDatabasePool pool
      . runClockIO
      . runServiceAccountStorePostgres
      . runUserStorePostgres
      $ do
        said <- genServiceAccountDbId
        let cid = idText said
        ts <- now
        loginId <- either (const (error "bad login id")) pure (mkLoginId cid)
        User {userId = backingUserId} <- createUser NewUser {loginId, email = Nothing, displayName = Just "e2e connector"}
        _ <-
          createServiceAccount
            NewServiceAccount
              { serviceAccountId = said,
                clientId = cid,
                userId = backingUserId,
                secretHash = sha256Hex oauthSecret,
                displayName = "e2e connector",
                allowedScopes = Set.singleton (Scope "kawa:ingest"),
                createdAt = ts
              }
        pure cid
  either (assertFailure . ("could not seed the service account: " <>) . show) pure outcome

-- | The whole EP-4 promise, against the real stack: a stock OAuth2 request mints a token that the
-- server's own verifier accepts, whose signing key is published, and whose issuance is audited.
oauthScenario :: Pool -> Text -> Int -> IO ()
oauthScenario pool clientId port = do
  mgr <- newManager defaultManagerSettings

  -- (a) A textbook client_credentials request with client_secret_basic.
  (tStatus, tHdrs, tBody) <- postForm mgr port "/oauth/token" (Just (clientId, oauthSecret)) [("grant_type", "client_credentials"), ("scope", "kawa:ingest")]
  tStatus @?= 200
  -- RFC 6749 §5.1: a token response must never be cached.
  lookup "Cache-Control" tHdrs @?= Just "no-store"
  tresp <- must "token body" tBody
  (dig ["token_type"] tresp >>= asText) @?= Just "Bearer"
  (dig ["scope"] tresp >>= asText) @?= Just "kawa:ingest"
  access <- must "access_token" (dig ["access_token"] tresp >>= asText)

  -- (b) The minted token is a real Shōmei token: the server's own auth handler accepts it on an
  -- ordinary authenticated route, and resolves it to the account's backing user.
  (meStatus, meBody) <- getJSON mgr port "/v1/auth/me" (bearer access)
  meStatus @?= 200
  meresp <- must "me body" meBody
  (dig ["displayName"] meresp >>= asText) @?= Just "e2e connector"

  -- (c) Its signing key is the one published at the JWKS endpoint, so any downstream verifier
  -- that fetches /.well-known/jwks.json can check this token offline.
  (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
  jStatus @?= 200
  jwks <- must "jwks body" jBody
  let tokenKid = jwtHeaderKid access
  assertBool "the token's kid is published in the JWKS document" (maybe False (`elem` jwksKids jwks) tokenKid)

  -- (d) A wrong secret is an RFC 6749 object, not a problem document.
  (bStatus, bHdrs, bBody) <- postForm mgr port "/oauth/token" (Just (clientId, "wrong")) [("grant_type", "client_credentials")]
  bStatus @?= 401
  lookup "Content-Type" bHdrs @?= Just "application/json"
  lookup "WWW-Authenticate" bHdrs @?= Just "Basic realm=\"shomei\""
  berr <- must "error body" bBody
  (dig ["error"] berr >>= asText) @?= Just "invalid_client"

  -- (e) The successful issuance is audited; the failure mints nothing.
  issued <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'service_token_issued'"
  issued @?= 1
  sessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions"
  sessions @?= 1
  -- A client_credentials session is refresh-less: the credential cannot outlive its TTL.
  refreshes <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens"
  refreshes @?= 0

-- | The secret the EP-6 exchange service account authenticates with.
exchangeSecret :: Text
exchangeSecret = "e2e-exchange-secret"

-- | Create the operator's user row directly, returning its id. Needed because a delegated session's
-- @actor_user_id@ is a foreign key into @shomei_users@, so the operator naming @act@ must exist.
seedOperatorUser :: Pool -> IO UserId
seedOperatorUser pool = do
  outcome <-
    runEff
      . runErrorNoCallStack @AuthError
      . runDatabasePool pool
      . runClockIO
      . runUserStorePostgres
      $ do
        loginId <- either (const (error "bad login id")) pure (mkLoginId "e2e-operator")
        User {userId} <- createUser NewUser {loginId, email = Nothing, displayName = Just "e2e operator"}
        pure userId
  either (assertFailure . ("could not seed the operator user: " <>) . show) pure outcome

-- | Seed a service account holding both @kawa:ingest@ and the @token-exchange:subject@ gate scope,
-- so it can drive the RFC 8693 on-behalf-of grant. Returns its @client_id@.
seedExchangeServiceAccount :: Pool -> IO Text
seedExchangeServiceAccount pool = do
  outcome <-
    runEff
      . runErrorNoCallStack @AuthError
      . runDatabasePool pool
      . runClockIO
      . runServiceAccountStorePostgres
      . runUserStorePostgres
      $ do
        said <- genServiceAccountDbId
        let cid = idText said
        ts <- now
        loginId <- either (const (error "bad login id")) pure (mkLoginId cid)
        User {userId = backingUserId} <- createUser NewUser {loginId, email = Nothing, displayName = Just "e2e exchange svc"}
        _ <-
          createServiceAccount
            NewServiceAccount
              { serviceAccountId = said,
                clientId = cid,
                userId = backingUserId,
                secretHash = sha256Hex exchangeSecret,
                displayName = "e2e exchange svc",
                allowedScopes = Set.fromList [Scope "kawa:ingest", Scope "token-exchange:subject"],
                createdAt = ts
              }
        pure cid
  either (assertFailure . ("could not seed the exchange service account: " <>) . show) pure outcome

-- | The RFC 8693 token-exchange promise against the real stack: both modes mint a delegated token
-- the server's own verifier and JWKS accept, and both write their audit event with subject + actor.
exchangeScenario :: Pool -> Text -> Text -> Int -> IO ()
exchangeScenario pool clientId opTok port = do
  mgr <- newManager defaultManagerSettings
  let teGrant = ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange")
      userIdType = "urn:shomei:params:oauth:token-type:user-id"
      accessType = "urn:ietf:params:oauth:token-type:access_token"
      accessTypeText = "urn:ietf:params:oauth:token-type:access_token" :: Text
      enc = Text.encodeUtf8
      pw = "correct horse battery staple" :: Text
      signup loginId = do
        (s, b) <- postJSON mgr port "/v1/auth/signup" (object ["loginId" .= loginId, "password" .= pw, "displayName" .= ("" :: Text)])
        s @?= 201
        resp <- must (loginId <> " signup body") b
        tok <- must (loginId <> " accessToken") (dig ["token", "accessToken"] resp >>= asText)
        uid <- must (loginId <> " userId") (dig ["user", "userId"] resp >>= asText)
        pure (tok, uid)

  (subjectAccess, subjectId) <- signup "exchange-subject"
  (_, targetId) <- signup "exchange-target"

  -- ===== Service on-behalf-of =====
  (obStatus, obHdrs, obBody) <-
    postForm mgr port "/oauth/token" (Just (clientId, exchangeSecret)) [teGrant, ("subject_token", enc subjectAccess), ("subject_token_type", accessType), ("scope", "kawa:ingest")]
  obStatus @?= 200
  lookup "Cache-Control" obHdrs @?= Just "no-store"
  obResp <- must "on-behalf body" obBody
  (dig ["scope"] obResp >>= asText) @?= Just "kawa:ingest"
  (dig ["issued_token_type"] obResp >>= asText) @?= Just accessTypeText
  obAccess <- must "on-behalf access_token" (dig ["access_token"] obResp >>= asText)

  -- The delegated token is signed by the published key: a downstream verifier checks it offline.
  (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
  jStatus @?= 200
  jwks <- must "jwks body" jBody
  assertBool "the on-behalf token's kid is published" (maybe False (`elem` jwksKids jwks) (jwtHeaderKid obAccess))

  -- Introspection verifies the JWT server-side and reports sub (the user), the scope, and act (the
  -- service) — sub/act/scopes asserted against a real verify, not a hand decode.
  (iStatus, _, iBody) <- postForm mgr port "/oauth/introspect" (Just (clientId, exchangeSecret)) [("token", enc obAccess)]
  iStatus @?= 200
  intro <- must "on-behalf introspect body" iBody
  dig ["active"] intro @?= Just (Bool True)
  (dig ["sub"] intro >>= asText) @?= Just subjectId
  (dig ["scope"] intro >>= asText) @?= Just "kawa:ingest"
  assertBool "on-behalf token carries an act member" (isJust (dig ["act", "sub"] intro >>= asText))

  -- ===== Impersonation =====
  (impStatus, _, impBody) <-
    postForm mgr port "/oauth/token" Nothing [teGrant, ("subject_token", enc targetId), ("subject_token_type", userIdType), ("actor_token", enc opTok), ("actor_token_type", accessType), ("reason", "e2e ticket")]
  impStatus @?= 200
  impResp <- must "impersonation body" impBody
  (dig ["issued_token_type"] impResp >>= asText) @?= Just accessTypeText
  impAccess <- must "impersonation access_token" (dig ["access_token"] impResp >>= asText)
  (impIStatus, _, impIBody) <- postForm mgr port "/oauth/introspect" (Just (clientId, exchangeSecret)) [("token", enc impAccess)]
  impIStatus @?= 200
  impIntro <- must "impersonation introspect body" impIBody
  (dig ["sub"] impIntro >>= asText) @?= Just targetId
  assertBool "impersonation token carries an act member" (isJust (dig ["act", "sub"] impIntro >>= asText))

  -- ===== Audit: both events written, each carrying subject and actor ids =====
  onBehalf <-
    scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'service_on_behalf_issued' AND payload->>'subjectUserId' IS NOT NULL AND payload->>'actorUserId' IS NOT NULL"
  onBehalf @?= 1
  impStarted <-
    scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'impersonation_started' AND payload->>'subjectUserId' IS NOT NULL AND payload->>'actorUserId' IS NOT NULL"
  impStarted @?= 1

-- | The @kid@ from a JWT's header, without verifying anything.
jwtHeaderKid :: Text -> Maybe Text
jwtHeaderKid token = do
  seg <- listToMaybe (Text.splitOn "." token)
  raw <- either (const Nothing) Just (B64U.decodeBase64UnpaddedUntyped (Text.encodeUtf8 seg))
  val <- decode (LBS.fromStrict raw)
  dig ["kid"] val >>= asText

jwksKids :: Value -> [Text]
jwksKids v = case dig ["keys"] v of
  Just (Array ks) -> [k | Object o <- toList ks, Just (String k) <- [KM.lookup "kid" o]]
  _ -> []

-- | EP-7's Purpose transcript against real PostgreSQL and real ES256: enroll TOTP, activate it,
-- log in and complete the challenge with a fresh code, then complete a second login with a
-- recovery code and watch the count drop — with the whole flow recorded in the audit trail.
--
-- The wall clock is real here, so a confirmed code cannot be replayed at the same time-step
-- counter. The completion presents the NEXT counter's code, which the ±1 acceptance window
-- accepts whether or not the clock has ticked into the next step, and which is strictly greater
-- than the confirming counter — so the test never has to wait 30 seconds.
totpScenario :: Pool -> Int -> IO ()
totpScenario pool port = do
  mgr <- newManager defaultManagerSettings
  let loginId = "totp-e2e-user" :: Text
      pw = "correct horse battery staple totp" :: Text
      login = postJSON mgr port "/v1/auth/login" (object ["loginId" .= loginId, "password" .= pw])

  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["loginId" .= loginId, "password" .= pw, "displayName" .= ("" :: Text)])
  sStatus @?= 201
  access <- must "signup accessToken" (sBody >>= dig ["token", "accessToken"] >>= asText)

  -- enroll: the secret is shown once.
  (enStatus, enBody) <- postAuthNoBody mgr port "/v1/auth/totp/enroll" (bearer access)
  enStatus @?= 200
  secretB32 <- must "enroll secret" (enBody >>= dig ["secret"] >>= asText)
  secret <- either (assertFailure . ("bad base32 secret: " <>)) pure (base32ToSecret secretB32)

  -- activate with the current code.
  t <- getCurrentTime
  let c = totpCounter t
  (vStatus, _) <- postJSONAuth mgr port "/v1/auth/totp/verify" (bearer access) (object ["code" .= totpCode 6 secret c])
  vStatus @?= 200

  -- login now challenges for the TOTP factor; complete with the next counter's code.
  (mStatus, mBody) <- login
  mStatus @?= 200
  (mBody >>= dig ["status"] >>= asText) @?= Just "mfa_required"
  methods <- must "methods" (mBody >>= dig ["methods"] >>= asTextArray)
  assertBool "totp advertised in methods" ("totp" `elem` methods)
  cid <- must "ceremonyId" (mBody >>= dig ["ceremonyId"] >>= asText)
  (cStatus, cBody) <- postJSON mgr port "/v1/auth/mfa/complete" (object ["ceremonyId" .= cid, "totpCode" .= totpCode 6 secret (c + 1)])
  cStatus @?= 200
  mfaAccess <- must "mfa accessToken" (cBody >>= dig ["accessToken"] >>= asText)
  -- the MFA-issued token verifies against the running server's key material.
  (meStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer mfaAccess)
  meStatus @?= 200

  -- generate recovery codes, complete another login with one, and watch the count drop to nine.
  (gStatus, gBody) <- postAuthNoBody mgr port "/v1/auth/recovery-codes" (bearer mfaAccess)
  gStatus @?= 200
  codes <- must "recovery codes" (gBody >>= dig ["codes"] >>= asTextArray)
  length codes @?= 10
  (m2Status, m2Body) <- login
  m2Status @?= 200
  cid2 <- must "cid2" (m2Body >>= dig ["ceremonyId"] >>= asText)
  (rcStatus, rcBody) <- postJSON mgr port "/v1/auth/mfa/complete" (object ["ceremonyId" .= cid2, "recoveryCode" .= head codes])
  rcStatus @?= 200
  rcAccess <- must "recovery accessToken" (rcBody >>= dig ["accessToken"] >>= asText)
  (cntStatus, cntBody) <- getJSON mgr port "/v1/auth/recovery-codes" (bearer rcAccess)
  cntStatus @?= 200
  (cntBody >>= dig ["remaining"] >>= asInt) @?= Just 9

  -- the whole flow is recorded against real PostgreSQL, and the secret sits encrypted at rest.
  scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'totp_enrolled'" >>= (@?= 1)
  scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'recovery_codes_generated'" >>= (@?= 1)
  scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'recovery_code_used'" >>= (@?= 1)
  scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'mfa_succeeded'" >>= (@?= 2)
  scalarInt pool "SELECT count(*) FROM shomei.shomei_totp_credentials WHERE confirmed_at IS NOT NULL" >>= (@?= 1)

scenario :: Pool -> Int -> IO ()
scenario pool port = do
  mgr <- newManager defaultManagerSettings

  -- (a) signup: 201 with a token pair and an active user.
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupBody
  sStatus @?= 201
  sresp <- must "signup body" sBody
  (dig ["user", "email"] sresp >>= asText) @?= Just email
  (dig ["user", "status"] sresp >>= asText) @?= Just "active"
  signupRefresh <- must "signup refreshToken" (dig ["token", "refreshToken"] sresp >>= asText)

  -- (b) login: a fresh token pair.
  (lStatus, lBody) <- postJSON mgr port "/v1/auth/login" loginBody
  lStatus @?= 200
  lresp <- must "login body" lBody
  loginAccess <- must "login accessToken" (dig ["token", "accessToken"] lresp >>= asText)

  -- (c) me with Bearer → 200; (d) without → 401.
  (meStatus, meBody) <- getJSON mgr port "/v1/auth/me" (bearer loginAccess)
  meStatus @?= 200
  meresp <- must "me body" meBody
  (dig ["email"] meresp >>= asText) @?= Just email
  (noTokStatus, _) <- getJSON mgr port "/v1/auth/me" []
  noTokStatus @?= 401

  -- (e) refresh rotates the signup token.
  (rStatus, rBody) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= signupRefresh])
  rStatus @?= 200
  rresp <- must "refresh body" rBody
  rotatedRefresh <- must "rotated refreshToken" (dig ["refreshToken"] rresp >>= asText)
  assertBool "rotated refresh token differs" (rotatedRefresh /= signupRefresh)

  -- (f) replaying the OLD signup refresh token is detected as theft → 401.
  (reuseStatus, _) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= signupRefresh])
  reuseStatus @?= 401

  -- reuse must have landed in PostgreSQL: the family's session is revoked and a
  -- reuse event row exists.
  revokedSessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions WHERE status = 'revoked'"
  assertBool "reuse revoked the signup session" (revokedSessions >= 1)
  reuseEvents <-
    scalarInt
      pool
      "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'refresh_token_reuse_detected'"
  reuseEvents @?= 1

  -- (g) the rotated token is now dead too (the whole session was revoked).
  (deadStatus, _) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= rotatedRefresh])
  deadStatus @?= 401

  -- (h) logout the login session → 204, and again → 204: logout is idempotent, so a retry
  -- after a network blip succeeds instead of reporting session_not_found.
  (logoutStatus, _) <- postJSON mgr port "/v1/auth/logout" (object [])
  -- logout needs a Bearer token; send it as a header-only POST.
  logoutStatus' <- postNoBody mgr port "/v1/auth/logout" (bearer loginAccess)
  logoutStatus @?= 401 -- no token → 401
  logoutStatus' @?= 204
  logoutAgain <- postNoBody mgr port "/v1/auth/logout" (bearer loginAccess)
  logoutAgain @?= 204

  -- (i) JWKS: a public key with a kid and no private "d".
  (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
  jStatus @?= 200
  jwks <- must "jwks body" jBody
  assertBool "jwks has keys[].kid" (jwksHasKid jwks)
  assertBool "jwks has no private 'd'" (not (hasKeyDeep "d" jwks))

  -- (j) health → 200.
  (hStatus, _) <- getJSON mgr port "/health" []
  hStatus @?= 200
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text
    signupBody = object ["email" .= email, "password" .= password, "displayName" .= ("Ada Lovelace" :: Text)]
    loginBody = object ["email" .= email, "password" .= password]

-- HTTP helpers (parseRequest does not throw on non-2xx, so 401/404 come back as responses).

-- | POST an @application\/x-www-form-urlencoded@ body, optionally with @client_secret_basic@.
-- Exposes response headers too, because RFC 6749 puts contract in them (@Cache-Control@,
-- @WWW-Authenticate@).
postForm :: Manager -> Int -> String -> Maybe (Text, Text) -> [(BS.ByteString, BS.ByteString)] -> IO (Int, [Header], Maybe Value)
postForm mgr port path mBasic params = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let withBody = urlEncodedBody params req0
      req = maybe withBody (\(c, sec) -> applyBasicAuth (Text.encodeUtf8 c) (Text.encodeUtf8 sec) withBody) mBasic
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

postJSON :: Manager -> Int -> String -> Value -> IO (Int, Maybe Value)
postJSON mgr port path body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = [("Content-Type", "application/json")],
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | POST with no body, only headers (used for the authenticated logout). Returns status.
postNoBody :: Manager -> Int -> String -> [Header] -> IO Int
postNoBody mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "POST", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp))

-- | POST a JSON body with a bearer token (EP-7 TOTP verify).
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

-- | POST with a bearer token and no body, returning the response body (EP-7 enroll / generate).
postAuthNoBody :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
postAuthNoBody mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "POST", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

getJSON :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
getJSON mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

bearer :: Text -> [Header]
bearer tok = [("Authorization", "Bearer " <> Text.encodeUtf8 tok)]

-- A scalar count(*) query run directly against the pool, for DB-state assertions.
scalarInt :: Pool -> Text -> IO Int
scalarInt pool sql = do
  res <- Pool.use pool (Session.statement () stmt)
  either (assertFailure . ("scalar query failed: " <>) . show) pure res
  where
    stmt :: Statement () Int
    stmt = preparable sql E.noParams (D.singleRow (fromIntegral64 <$> D.column (D.nonNullable D.int8)))
    fromIntegral64 :: Int64 -> Int
    fromIntegral64 = fromIntegral

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
asInt (Aeson.Number n) = Just (round n)
asInt _ = Nothing

jwksHasKid :: Value -> Bool
jwksHasKid v = case dig ["keys"] v of
  Just (Array xs) -> case toList xs of
    (k0 : _) -> isJust (field "kid" k0)
    [] -> False
  _ -> False

hasKeyDeep :: Text -> Value -> Bool
hasKeyDeep k = go
  where
    go (Object o) = any (\(kk, vv) -> K.toText kk == k || go vv) (KM.toList o)
    go (Array xs) = any go (toList xs)
    go _ = False

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
