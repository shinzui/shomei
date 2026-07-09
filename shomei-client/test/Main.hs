-- | Round-trip test for the derived 'shomei-client' against a real server: an ephemeral
-- PostgreSQL (via @shomei-migrations:test-support@), the real @shomei-server@ assembly served
-- in-process with warp, driven through the typed client. Proves the derived client and the
-- server agree on the wire format end-to-end, including the Bearer-authenticated @me@ route.
module Main (main) where

import Data.IORef (newIORef)
import Data.Text (Text)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.Wai.Handler.Warp (testWithApplication)
import Shomei.Client qualified as C
import Shomei.Config (defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Servant.DTO
  ( LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    SignupRequest (..),
    TokenPairResponse (..),
    UserResponse (..),
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
    "shomei-client round-trip against a live server"
    [ testCase "signup → login → me → refresh" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr}
          testWithApplication (pure (application env)) \port -> do
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)

            _su <-
              expect "signup"
                =<< C.signup cenv SignupRequest {loginId = Nothing, email = Just email, password = password, displayName = "Ada Lovelace"}

            lr <-
              expect "login"
                =<< C.login cenv LoginRequest {loginId = Nothing, email = Just email, password = password}
            tok <- C.Token <$> requireBodyToken lr.token.accessToken

            ur <- expect "me" =<< C.me cenv tok
            ur.email @?= Just email

            tp <- expect "refresh" =<< C.refresh cenv RefreshRequest {refreshToken = lr.token.refreshToken}
            (tp.refreshToken /= lr.token.refreshToken) @?= True
    ]
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text

expect :: (Show e) => String -> Either e a -> IO a
expect label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

-- | Body tokens are optional on the wire (cookie transport omits them). This client runs in
-- the default bearer mode, where they are always present.
requireBodyToken :: Maybe Text -> IO Text
requireBodyToken = maybe (assertFailure "expected a body token in bearer mode") pure
