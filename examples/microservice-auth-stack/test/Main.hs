-- | Microservice-demo test: prove downstream /local/ JWT verification. Boot the real
-- @shomei-server@ (over an ephemeral PostgreSQL) and the downstream @example-project-service@
-- in-process, point the downstream at the auth service's JWKS URL, log in at the auth
-- service through the typed client, and call the downstream @\/projects@:
--
-- * a valid token → @200@ (verified offline against the cached JWKS — @verifyToken@ makes no
--   call back to the auth service);
-- * a tampered token → @401@;
-- * no token → @401@.
module Main (main) where

import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Downstream.Service (downstreamApplication, newJwksCache)
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
import Shomei.Client qualified as C
import Shomei.Config (defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..), newHashingLimiter)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Servant.DTO
  ( LoginRequest (..),
    LoginResponse (..),
    SignupRequest (..),
    TokenPairResponse (..),
  )
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application)
import Shomei.Server.Keys (bootstrapKeys)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "microservice demo: downstream local JWT verification"
    [ testCase "valid token → 200 (offline), tampered → 401, none → 401" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter}
          -- Boot the auth service in-process.
          testWithApplication (pure (application env)) \authPort -> do
            mgr <- newManager defaultManagerSettings
            cache <-
              newJwksCache
                mgr
                ("http://127.0.0.1:" <> show authPort <> "/.well-known/jwks.json")
                900
            -- Boot the downstream service in-process, pointed at the auth JWKS.
            testWithApplication (pure (downstreamApplication cache cfg)) \downPort -> do
              cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show authPort)
              _ <- expect "signup" =<< C.signup cenv SignupRequest {loginId = Nothing, email = Just email, password = password, displayName = "MS"}
              lr <- expect "login" =<< C.login cenv LoginRequest {loginId = Nothing, email = Just email, password = password}
              token <- maybe (assertFailure "expected a body token in bearer mode") pure lr.token.accessToken

              valid <- getProjects mgr downPort (Just token)
              valid @?= 200

              tampered <- getProjects mgr downPort (Just (Text.dropEnd 1 token <> "X"))
              tampered @?= 401

              none <- getProjects mgr downPort Nothing
              none @?= 401
    ]
  where
    email = "ms@example.com" :: Text
    password = "correct horse battery staple" :: Text

getProjects :: Manager -> Int -> Maybe Text -> IO Int
getProjects mgr port mtok = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> "/projects")
  let hdrs = maybe [] (\t -> [("Authorization", "Bearer " <> Text.encodeUtf8 t)]) mtok
      req = req0 {requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp))

expect :: (Show e) => String -> Either e a -> IO a
expect label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
