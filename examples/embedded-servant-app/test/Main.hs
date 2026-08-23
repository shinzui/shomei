-- | Embedded-demo test: serve the host 'Embedded.App.AppAPI' (mounted Shōmei auth routes
-- + a guarded @\/projects@) in-process over an ephemeral PostgreSQL, then prove the embedded
-- model — @\/projects@ is @401@ without a token and @200@ with a token minted by the mounted
-- @\/v1\/auth\/login@ route (obtained through the real typed @shomei-client@).
module Main (main) where

import Data.ByteString qualified as BS
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Embedded.App (embeddedApplication)
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
import Shomei.Config (defaultShomeiConfig)
import Shomei.Mfa.Totp.Postgres (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Persistence.Pool.Postgres (acquirePool)
import Shomei.Server.App (Env (..))
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Session.Dto (LoginRequest (..), LoginResponse (..), TokenPairResponse (..))
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256))
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, keyEncryptionKeyFromBase64)
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
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys testKek ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = testKek, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = dummyTotpKey}
          testWithApplication (pure (embeddedApplication env (pure Healthy) (pure Healthy))) \port -> do
            mgr <- newManager defaultManagerSettings

            -- /projects with no token → 401.
            noTok <- getProjects mgr port Nothing
            noTok @?= 401

            -- Sign up + log in through the mounted /auth routes (via the real client).
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
            _ <- expect "signup" =<< C.signup cenv SignupRequest {loginId = email, email = Just email, password = password, displayName = "Dev"}
            lr <- expect "login" =<< C.login cenv LoginRequest {loginId = email, password = password}

            -- /projects with the Bearer token → 200.
            withTok <- getProjects mgr port lr.token.accessToken
            withTok @?= 200

            -- The Raw static route serves the passkey-demo page (resolved from www/,
            -- the package's CWD during `cabal test`).
            indexStatus <- getStatus mgr port "/index.html"
            indexStatus @?= 200
    ]
  where
    email = "dev@example.com" :: Text
    password = "correct horse battery staple" :: Text

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

expect :: (Show e) => String -> Either e a -> IO a
expect label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
