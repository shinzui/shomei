-- | Round-trip test for the derived 'shomei-client' against a real server: an ephemeral
-- PostgreSQL (via @shomei-migrations:test-support@), the real @shomei-server@ assembly served
-- in-process with warp, driven through the typed client. Proves the derived client and the
-- server agree on the wire format end-to-end, including the Bearer-authenticated @me@ route.
module Main (main) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (newIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (mkStatus)
import Network.Wai (responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant (ServerError (..))
import Servant.API.MultiVerb (AsUnion (..))
import Servant.Health (ProbeCheck, ProbeVerdict (Healthy))
import Shomei.Account.Dto (SignupRequest (..), SignupResponse (..))
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..), defaultArgon2Params, newHashingLimiter)
import Shomei.Account.User.Domain (NewUser (..), User (..))
import Shomei.Account.User.Dto (UserResponse (..))
import Shomei.Account.User.Postgres (runUserStorePostgres)
import Shomei.Account.User.Store (createUser)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..), Scope (..))
import Shomei.Client qualified as C
import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Error (AuthError)
import Shomei.Id (genServiceAccountDbId, idText, parseId)
import Shomei.Mfa.Totp.Postgres (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Notify (noNotifierSecrets)
import Shomei.Notify.Queue (newNotifierQueue)
import Shomei.OAuth.Boundary (oauthBoundaryError)
import Shomei.OAuth.Result (OAuthErrorWithHeaders (..), TokenResponses, TokenResult, oauthServerErrorResult)
import Shomei.Persistence.Database.Postgres (defaultTransactionRetryPolicy, runDatabasePool)
import Shomei.Persistence.Pool.Postgres (Pool, acquirePool)
import Shomei.Servant.Api (shomeiThrottledRoutes)
import Shomei.Servant.OAuth (OAuthErrorResponse (..), oauthError)
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application, hostMiddleware)
import Shomei.Server.Config (ProxyProtocolMode (ProxyProtocolOff), ServerSettings (..), SweepSettings (..), defaultSweepSettings)
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Server.Middleware.RateLimit (newRateLimiterFor)
import Shomei.Server.Middleware.TrustedProxy (emptyTrustedProxies)
import Shomei.Server.Observability.Metrics (newMetrics)
import Shomei.ServiceAccount.Domain (NewServiceAccount (..))
import Shomei.ServiceAccount.Postgres (runServiceAccountStorePostgres)
import Shomei.ServiceAccount.Secret (sha256Hex)
import Shomei.ServiceAccount.Store (createServiceAccount)
import Shomei.Session.Dto
  ( LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    TokenPairResponse (..),
  )
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256))
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, keyEncryptionKeyFromBase64)
import Shomei.Time.Postgres (runClockIO)
import Shomei.Time.Store (now)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- | TOTP is not exercised by this suite; the store is unreachable, so a fixed dummy key keeps
-- the 'Env' shape satisfied (EP-7 added 'envTotpKey').
dummyTotpKey :: TotpEncryptionKey
dummyTotpKey = either (const (error "bad dummy totp key")) id (totpEncryptionKeyFromBytes (BS.replicate 32 0))

testKek :: KeyEncryptionKey
testKek = either (error . show) id (keyEncryptionKeyFromBase64 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "shomei-client round-trip against a live server"
    [ testCase "generated token client decodes every error and optional headers" oauthWireResults,
      testCase "OAuth result union round trips every HTTP boundary alternative" oauthUnionRoundTrips,
      testCase "client bearer diagnostics redact the credential" (show (C.Token "sensitive-bearer") @?= "Token <redacted>"),
      testCase "signup → login → me → refresh; then every admin wrapper reaches its route" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 30000 connStr
          keysRef <- newIORef =<< bootstrapKeys testKek ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          notifierQueue <- newNotifierQueue 64
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envDbRetryPolicy = defaultTransactionRetryPolicy, envConfig = cfg, envKeys = keysRef, envKek = testKek, envHttpManager = envMgr, envNotifierSecrets = noNotifierSecrets, envNotifierQueue = notifierQueue, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = dummyTotpKey}
          clientId <- seedClient pool
          metrics <- newMetrics
          rl <- newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig
          let fullApp = hostMiddleware cfg testServerSettings rl metrics (application env {envConfig = cfg {maxActiveNonInteractiveSessions = 1}} healthyProbe healthyProbe)
          testWithApplication (pure fullApp) \port -> do
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
            tooLarge <- C.oauthToken cenv "unknown" "secret" [Text.replicate (1024 * 1024 + 1) "x"]
            case tooLarge of
              Right (C.OAuthPayloadTooLarge err) -> do
                err.oauthErrorBody.oauthErrorCode @?= "invalid_request"
                err.oauthAuthenticate @?= Nothing
                err.oauthRetryAfter @?= Nothing
              _ -> assertFailure ("expected typed 413, got " <> show tooLarge)
            issued <- C.oauthToken cenv clientId "typed-client-secret" []
            case issued of
              Right (C.OAuthSuccess value) -> value.tokenBody.tokenType @?= "Bearer"
              _ -> assertFailure ("expected successful issuance, got " <> show issued)
            badScope <- C.oauthToken cenv clientId "typed-client-secret" ["outside:scope"]
            case badScope of
              Right (C.OAuthBadRequest err) -> err.oauthErrorBody.oauthErrorCode @?= "invalid_scope"
              _ -> assertFailure ("expected typed 400, got " <> show badScope)
            exhausted <- C.oauthToken cenv clientId "typed-client-secret" []
            case exhausted of
              Right (C.OAuthUnavailable err) -> err.oauthErrorBody.oauthErrorCode @?= "temporarily_unavailable"
              _ -> assertFailure ("expected typed 503, got " <> show exhausted)
            badClient <- C.oauthToken cenv "unknown" "secret" []
            case badClient of
              Right (C.OAuthAuthenticationFailed err) -> err.oauthAuthenticate @?= Just "Basic realm=\"shomei\""
              _ -> assertFailure ("expected typed 401, got " <> show badClient)
          emptyRl <- newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig {perIpBurst = 0}
          testWithApplication (pure (hostMiddleware cfg testServerSettings emptyRl metrics (application env healthyProbe healthyProbe))) \port -> do
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
            throttled <- C.oauthToken cenv "unknown" "secret" []
            case throttled of
              Right (C.OAuthTooManyRequests err) -> do
                err.oauthErrorBody.oauthErrorCode @?= "temporarily_unavailable"
                err.oauthRetryAfter @?= Just 60
                err.oauthAuthenticate @?= Nothing
              _ -> assertFailure ("expected typed 429, got " <> show throttled)
          testWithApplication (pure (application env healthyProbe healthyProbe)) \port -> do
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)

            su <-
              fmap C.cookieBody . expectApplicationSuccess "signup"
                =<< C.signup cenv SignupRequest {loginId = email, email = Just email, password = password, displayName = "Ada Lovelace"}

            loginResponse <-
              fmap C.cookieBody . expectApplicationSuccess "login"
                =<< C.login cenv LoginRequest {loginId = email, password = password, remember = Nothing}
            lr <- case loginResponse of
              complete@LoginCompleteResponse {} -> pure complete
              LoginMfaRequiredResponse {} -> assertFailure "login unexpectedly required MFA"
            tok <- C.Token <$> requireBodyToken lr.token.accessToken

            ur <- expectApplicationSuccess "me" =<< C.me cenv tok
            ur.email @?= Just email

            tp <- fmap C.cookieBody . expectApplicationSuccess "refresh" =<< C.refresh cenv RefreshRequest {refreshToken = lr.token.refreshToken}
            (tp.refreshToken /= lr.token.refreshToken) @?= True

            -- EP-2. The admin wrappers are derived from the same route types the server serves,
            -- so what is really under test is that the /paths/ they build reach the handlers --
            -- including the capture segments and the PUT no other route in the API uses. This
            -- token carries no admin role, so every route must answer 403: a 404 would mean the
            -- client built a path the server does not serve, a 405 that it used the wrong verb.
            uid <- either (\e -> assertFailure ("bad user id: " <> show e)) pure (parseId su.user.userId)
            sid <- either (\e -> assertFailure ("bad session id: " <> show e)) pure (parseId straySessionId)

            expect403 "adminListUsers" =<< C.adminListUsers cenv tok Nothing Nothing Nothing
            expect403 "adminGetUser" =<< C.adminGetUser cenv tok uid
            expect403 "adminSuspendUser" =<< C.adminSuspendUser cenv tok uid
            expect403 "adminReinstateUser" =<< C.adminReinstateUser cenv tok uid
            expect403 "adminDeleteUser" =<< C.adminDeleteUser cenv tok uid
            expect403 "adminListSessions" =<< C.adminListSessions cenv tok uid Nothing Nothing
            expect403 "adminRevokeSessions" =<< C.adminRevokeSessions cenv tok uid
            expect403 "adminRevokeSession" =<< C.adminRevokeSession cenv tok sid
            expect403 "adminPasswordReset" =<< C.adminPasswordReset cenv tok uid
            expect403 "adminGrantRole" =<< C.adminGrantRole cenv tok uid "admin"
            expect403 "adminRevokeRole" =<< C.adminRevokeRole cenv tok uid "admin"
    ]
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text
    -- A well-formed session id that belongs to nobody: the 403 fires before any lookup.
    straySessionId = "session_01h455vb4pex5vsknk084sn02q" :: Text

healthyProbe :: ProbeCheck
healthyProbe = pure Healthy

-- | The route was reached and the admin gate refused it. A 404 would mean the client built a
-- path the server does not serve; a 405, that it used the wrong verb.
expect403 :: String -> Either C.ClientError (C.ApplicationResult a) -> IO ()
expect403 label = \case
  Right (C.ApplicationForbidden problem) | C.status problem == 403 -> pure ()
  Right _ -> assertFailure (label <> ": expected a typed 403, got a different typed outcome")
  Left e -> assertFailure (label <> ": expected a typed 403, got transport failure " <> show e)

expectApplicationSuccess :: String -> Either C.ClientError (C.ApplicationResult a) -> IO a
expectApplicationSuccess label = \case
  Right (C.ApplicationSuccess value) -> pure value
  Right _ -> assertFailure (label <> ": expected success, got an application failure")
  Left err -> assertFailure (label <> ": transport failure: " <> show err)

-- | Body tokens are optional on the wire (cookie transport omits them). This client runs in
-- the default bearer mode, where they are always present.
requireBodyToken :: Maybe Text -> IO Text
requireBodyToken = maybe (assertFailure "expected a body token in bearer mode") pure

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}

testServerSettings :: ServerSettings
testServerSettings =
  ServerSettings
    { serverPort = 0,
      serverBindHost = "127.0.0.1",
      serverMaxConnections = 1024,
      serverSlowClientTimeoutSeconds = 30,
      serverConnStr = "",
      serverTrustedProxies = emptyTrustedProxies,
      serverProxyProtocol = ProxyProtocolOff,
      serverDbPoolSize = 1,
      serverDbPoolAcquisitionTimeoutMs = 1000,
      serverDbStatementTimeoutMs = 1000,
      serverDbTransactionMaxAttempts = 3,
      serverDbTransactionDeadlineMs = 5000,
      serverNotifierQueueSize = 16,
      serverWarnings = [],
      serverSweep = defaultSweepSettings {sweepEnabled = False},
      serverArgon2 = defaultArgon2Params,
      serverHashingMaxConcurrency = 1
    }

oauthUnionRoundTrips :: IO ()
oauthUnionRoundTrips = forM_ [400, 401, 404, 405, 406, 413, 415, 429, 500, 503] \status ->
  forM_ [[], [("WWW-Authenticate", "Bearer"), ("Retry-After", "60"), ("Allow", "POST")]] \optional -> do
    let err = if status `elem` [405, 406, 413, 415, 429] then oauthBoundaryError status else oauthError (mkStatus status "test") "invalid_request" "test"
        result = oauthServerErrorResult err {errHeaders = err.errHeaders <> optional} :: TokenResult
    (fromUnion @TokenResponses (toUnion @TokenResponses result)) @?= result

oauthWireResults :: IO ()
oauthWireResults = forM_ [400, 401, 404, 405, 406, 413, 415, 429, 500, 503] \status ->
  forM_ [[], [("WWW-Authenticate", "Bearer"), ("Retry-After", "60"), ("Allow", "POST")]] \optional -> do
    let base = oauthError (mkStatus status "test") "invalid_request" "safe test error"
        err = base {errHeaders = base.errHeaders <> optional}
        server _ respond = respond (responseLBS (mkStatus status (BS8.pack err.errReasonPhrase)) err.errHeaders err.errBody)
    testWithApplication (pure server) \port -> do
      cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
      result <- C.oauthToken cenv "unknown" "secret" []
      result @?= Right (oauthServerErrorResult err)

seedClient :: Pool -> IO Text
seedClient pool = do
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
                secretHash = sha256Hex "typed-client-secret",
                displayName = "e2e connector",
                allowedScopes = Set.singleton (Scope "kawa:ingest"),
                createdAt = ts
              }
        pure cid
  either (assertFailure . ("could not seed the service account: " <>) . show) pure outcome
