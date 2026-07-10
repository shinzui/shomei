-- | End-to-end test for the standalone server: a fresh ephemeral PostgreSQL database
-- (via @shomei-migrations:test-support@), the real server in-process through warp's
-- 'testWithApplication', driven over HTTP with @http-client@. Asserts the full lifecycle —
-- signup, login, me (with and without a token), refresh rotation, refresh-token reuse
-- detection (HTTP 401 plus the persisted session revocation and reuse event), logout, the
-- public JWKS document, and health — i.e. the vertical slice actually behaves against real
-- PostgreSQL and real ES256 signing.
module Shomei.Server.E2ESpec (tests) where

import Data.Aeson (Value (Array, Object, String), decode, encode, object, (.=))
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
    requestBody,
    requestHeaders,
    responseBody,
    responseHeaders,
    responseStatus,
    urlEncodedBody,
  )
import Network.HTTP.Types (Header, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Shomei.Config (defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..), newHashingLimiter)
import Shomei.Domain.Claims (Audience (..), Issuer (..), Scope (..))
import Shomei.Domain.LoginId (mkLoginId)
import Shomei.Domain.ServiceAccount (NewServiceAccount (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Domain.User (NewUser (..), User (..))
import Shomei.Effect.Clock (now)
import Shomei.Effect.ServiceAccountStore (createServiceAccount)
import Shomei.Effect.UserStore (createUser)
import Shomei.Error (AuthError)
import Shomei.Id (genServiceAccountDbId, idText)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.ServiceAccountStore (runServiceAccountStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application)
import Shomei.Server.Keys (bootstrapKeys)
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
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter}
          testWithApplication (pure (application env)) (scenario pool),
      testCase "EP-4: service account → POST /oauth/token → the token authenticates and is audited" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter}
          clientId <- seedServiceAccount pool
          testWithApplication (pure (application env)) (oauthScenario pool clientId)
    ]

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
