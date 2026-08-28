-- | Embedded-demo test: serve the host 'Embedded.App.AppAPI' (mounted Shōmei auth routes
-- + a guarded @\/projects@) in-process over an ephemeral PostgreSQL, then prove the embedded
-- model — @\/projects@ is @401@ without a token and @200@ with a token minted by the mounted
-- @\/v1\/auth\/login@ route (obtained through the real typed @shomei-client@).
module Main (main) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Time (getCurrentTime)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Embedded.App (embeddedApplication)
import Hasql.Pool (Pool)
import Network.HTTP.Client
  ( Manager,
    defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    requestHeaders,
    responseStatus,
  )
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Health (ProbeVerdict (Healthy))
import Shomei.Account.Dto (SignupRequest (..))
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..), newHashingLimiter)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Client qualified as C
import Shomei.Config (ShomeiConfig (..), SigningKeyConfig (..), defaultShomeiConfig)
import Shomei.Error (AuthError)
import Shomei.Mfa.Totp.Postgres (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Notify (noNotifierSecrets)
import Shomei.Notify.Queue (newNotifierQueue)
import Shomei.Persistence.Database.Postgres (runDatabasePool)
import Shomei.Persistence.Pool.Postgres (acquirePool)
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (HostBackgroundTasks (..), installHostBackgroundTasks)
import Shomei.Server.Config (ProxyProtocolMode (..), ServerSettings (..), SweepSettings (..), defaultSweepSettings)
import Shomei.Server.Keys (LoadedKeys (..), bootstrapKeys)
import Shomei.Server.Middleware.TrustedProxy (emptyTrustedProxies)
import Shomei.Session.Dto (LoginRequest (..), LoginResponse (..), TokenPairResponse (..))
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256), SigningKeyStatus (KeyRevoked))
import Shomei.SigningKey.Key.Jwt (generateSigningKeyFor, keyKid, toStoredSigningKeyFor)
import Shomei.SigningKey.Postgres (runSigningKeyStorePostgres)
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, keyEncryptionKeyFromBase64, protectStoredSigningKey)
import Shomei.SigningKey.Store (replaceActiveSigningKey, updateSigningKeyStatus)
import System.Posix.Signals (raiseSignal, sigHUP)
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
    "embedded demo: mounted /auth + guarded /projects"
    [ testCase "/projects is 401 without a token and 200 with one" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 30000 connStr
          keysRef <- newIORef =<< bootstrapKeys testKek ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          notifierQueue <- newNotifierQueue 64
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = testKek, envHttpManager = envMgr, envNotifierSecrets = noNotifierSecrets, envNotifierQueue = notifierQueue, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = dummyTotpKey}
          testWithApplication (pure (embeddedApplication env (pure Healthy) (pure Healthy))) \port -> do
            mgr <- newManager defaultManagerSettings

            -- /projects with no token → 401.
            noTok <- getProjects mgr port Nothing
            noTok @?= 401

            -- Sign up + log in through the mounted /auth routes (via the real client).
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
            _ <- expectApplicationSuccess "signup" =<< C.signup cenv SignupRequest {loginId = email, email = Just email, password = password, displayName = "Dev"}
            loginResponse <- fmap C.cookieBody . expectApplicationSuccess "login" =<< C.login cenv LoginRequest {loginId = email, password = password}
            lr <- case loginResponse of
              complete@LoginCompleteResponse {} -> pure complete
              LoginMfaRequiredResponse {} -> assertFailure "login unexpectedly required MFA"

            -- /projects with the Bearer token → 200.
            withTok <- getProjects mgr port lr.token.accessToken
            withTok @?= 200

            -- The Raw static route serves the passkey-demo page (resolved from www/,
            -- the package's CWD during `cabal test`).
            indexStatus <- getStatus mgr port "/index.html"
            indexStatus @?= 200,
      testCase "a revoked signing key stops verifying after SIGHUP once background tasks are installed" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 30000 connStr
          keysRef <- newIORef =<< bootstrapKeys testKek ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          notifierQueue <- newNotifierQueue 64
          let baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              cfg = baseCfg {signingKeyConfig = baseCfg.signingKeyConfig {refreshIntervalSeconds = 0}}
              settings = testServerSettings connStr
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = testKek, envHttpManager = envMgr, envNotifierSecrets = noNotifierSecrets, envNotifierQueue = notifierQueue, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = dummyTotpKey}
          testWithApplication (pure (embeddedApplication env (pure Healthy) (pure Healthy))) \port -> do
            mgr <- newManager defaultManagerSettings
            let rotateEmail = "rotate@example.com"
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
            _ <- expectApplicationSuccess "signup" =<< C.signup cenv SignupRequest {loginId = rotateEmail, email = Just rotateEmail, password = password, displayName = "Rotate"}
            loginResponse <- fmap C.cookieBody . expectApplicationSuccess "login" =<< C.login cenv LoginRequest {loginId = rotateEmail, password = password}
            token <- case loginResponse of
              LoginCompleteResponse {token} -> pure token.accessToken
              LoginMfaRequiredResponse {} -> assertFailure "login unexpectedly required MFA"
            oldKid <- keyKid . (.signingKey) <$> readIORef keysRef
            rotateAndRevoke pool oldKid
            getProjects mgr port token >>= (@?= 200)
            tasks <- installHostBackgroundTasks cfg settings env
            raiseSignal sigHUP
            reloaded <- pollUntil 30 100_000 ((== 401) <$> getProjects mgr port token)
            reloaded @?= True
            stopHostBackgroundTasks tasks 1
    ]
  where
    email = "dev@example.com" :: Text
    password = "correct horse battery staple" :: Text

testServerSettings :: Text -> ServerSettings
testServerSettings connStr =
  ServerSettings
    { serverPort = 0,
      serverConnStr = connStr,
      serverTrustedProxies = emptyTrustedProxies,
      serverProxyProtocol = ProxyProtocolOff,
      serverDbPoolSize = 4,
      serverDbPoolAcquisitionTimeoutMs = 1000,
      serverDbStatementTimeoutMs = 30000,
      serverNotifierQueueSize = 64,
      serverWarnings = [],
      serverSweep = defaultSweepSettings {sweepEnabled = False},
      serverArgon2 = testArgon2Params,
      serverHashingMaxConcurrency = 2
    }

rotateAndRevoke :: Pool -> Text -> IO ()
rotateAndRevoke pool oldKid = do
  jwk <- generateSigningKeyFor ES256
  now <- getCurrentTime
  stored <- either (fail . T.unpack) pure (toStoredSigningKeyFor ES256 now jwk)
  protected <- protectStoredSigningKey testKek stored
  result <-
    runEff
      . runErrorNoCallStack @AuthError
      . runDatabasePool pool
      . runSigningKeyStorePostgres
      $ do
        replaceActiveSigningKey protected now
        updateSigningKeyStatus oldKid KeyRevoked now
  either (fail . show) pure result

pollUntil :: Int -> Int -> IO Bool -> IO Bool
pollUntil attempts delayMicros predicate = go attempts
  where
    go 0 = pure False
    go remaining = do
      done <- predicate
      if done
        then pure True
        else threadDelay delayMicros >> go (remaining - 1)

getProjects :: Manager -> Int -> Maybe Text -> IO Int
getProjects mgr port mtok = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> "/projects")
  let hdrs = maybe [] (\t -> [("Authorization", "Bearer " <> Text.encodeUtf8 t)]) mtok
      req = req0 {requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp))

getStatus :: Manager -> Int -> String -> IO Int
getStatus mgr port path = do
  req <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp))

expectApplicationSuccess :: String -> Either C.ClientError (C.ApplicationResult a) -> IO a
expectApplicationSuccess label = \case
  Right (C.ApplicationSuccess value) -> pure value
  Right _ -> assertFailure (label <> ": expected success, got an application failure")
  Left err -> assertFailure (label <> ": transport failure: " <> show err)

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
