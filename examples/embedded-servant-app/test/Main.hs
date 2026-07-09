-- | Embedded-demo test: serve the host 'Embedded.App.AppAPI' (mounted Shōmei auth routes
-- + a guarded @\/projects@) in-process over an ephemeral PostgreSQL, then prove the embedded
-- model — @\/projects@ is @401@ without a token and @200@ with a token minted by the mounted
-- @\/auth\/login@ route (obtained through the real typed @shomei-client@).
module Main (main) where

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
import Shomei.Client qualified as C
import Shomei.Config (defaultShomeiConfig)
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
import Shomei.Server.Keys (bootstrapKeys)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "embedded demo: mounted /auth + guarded /projects"
    [ testCase "/projects is 401 without a token and 200 with one" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr}
          testWithApplication (pure (embeddedApplication env)) \port -> do
            mgr <- newManager defaultManagerSettings

            -- /projects with no token → 401.
            noTok <- getProjects mgr port Nothing
            noTok @?= 401

            -- Sign up + log in through the mounted /auth routes (via the real client).
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)
            _ <- expect "signup" =<< C.signup cenv SignupRequest {loginId = Nothing, email = Just email, password = password, displayName = "Dev"}
            lr <- expect "login" =<< C.login cenv LoginRequest {loginId = Nothing, email = Just email, password = password}

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
