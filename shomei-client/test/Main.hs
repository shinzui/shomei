-- | Round-trip test for the derived 'shomei-client' against a real server: an ephemeral
-- PostgreSQL (via @shomei-migrations:test-support@), the real @shomei-server@ assembly served
-- in-process with warp, driven through the typed client. Proves the derived client and the
-- server agree on the wire format end-to-end, including the Bearer-authenticated @me@ route.
module Main (main) where

import Data.ByteString qualified as BS
import Data.IORef (newIORef)
import Data.Text (Text)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Client (ClientError (FailureResponse), responseStatusCode)
import Shomei.Client qualified as C
import Shomei.Config (defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..), newHashingLimiter)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Id (parseId)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.TotpCredentialStore (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Servant.DTO
  ( LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    SignupRequest (..),
    SignupResponse (..),
    TokenPairResponse (..),
    UserResponse (..),
  )
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application)
import Shomei.Server.Keys (bootstrapKeys)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- | TOTP is not exercised by this suite; the store is unreachable, so a fixed dummy key keeps
-- the 'Env' shape satisfied (EP-7 added 'envTotpKey').
dummyTotpKey :: TotpEncryptionKey
dummyTotpKey = either (const (error "bad dummy totp key")) id (totpEncryptionKeyFromBytes (BS.replicate 32 0))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "shomei-client round-trip against a live server"
    [ testCase "signup → login → me → refresh; then every admin wrapper reaches its route" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 10 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          limiter <- newHashingLimiter 2
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter, envTotpKey = dummyTotpKey}
          testWithApplication (pure (application env)) \port -> do
            cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show port)

            su <-
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
            expect403 "adminListSessions" =<< C.adminListSessions cenv tok uid
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

-- | The route was reached and the admin gate refused it. A 404 would mean the client built a
-- path the server does not serve; a 405, that it used the wrong verb.
expect403 :: String -> Either C.ClientError a -> IO ()
expect403 label = \case
  Left (FailureResponse _ resp) | statusCode (responseStatusCode resp) == 403 -> pure ()
  Left e -> assertFailure (label <> ": expected a 403, got " <> show e)
  Right _ -> assertFailure (label <> ": expected a 403, got success")

expect :: (Show e) => String -> Either e a -> IO a
expect label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

-- | Body tokens are optional on the wire (cookie transport omits them). This client runs in
-- the default bearer mode, where they are always present.
requireBodyToken :: Maybe Text -> IO Text
requireBodyToken = maybe (assertFailure "expected a body token in bearer mode") pure

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
