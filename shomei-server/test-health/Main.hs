module Main (main) where

import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (listToMaybe)
import Hasql.Pool qualified as Pool
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Servant.Health (ProbeVerdict (..))
import Servant.Health.TestKit (probeContractTests)
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..), newHashingLimiter)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (defaultShomeiConfig)
import Shomei.Error (AuthDependency (PostgreSQL), AuthError (DependencyUnavailable))
import Shomei.Health.Server (buildHealthChecks, buildHealthChecksWith)
import Shomei.Mfa.Totp.Postgres (TotpEncryptionKey, totpEncryptionKeyFromBytes)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Notify (noNotifierSecrets)
import Shomei.Notify.Queue (newNotifierQueue)
import Shomei.Persistence.Pool.Postgres (acquirePool)
import Shomei.Prelude
import Shomei.Server.App (Env (..), runAppIO)
import Shomei.Server.Boot (application)
import Shomei.Server.Config (defaultDbStatementTimeoutMs)
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256), SigningKeyStatus (KeyRevoked), StoredSigningKey (..))
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, keyEncryptionKeyFromBase64)
import Shomei.SigningKey.Store (listActiveSigningKeys, updateSigningKeyStatus)
import Shomei.Time.Store (now)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

main :: IO ()
main =
  withShomeiMigratedDatabase \connectionString -> do
    env <- buildTestEnv connectionString
    defaultMain (tests env)

tests :: Env -> TestTree
tests env =
  testGroup
    "Shomei health policy"
    [ probeContractTests
        "servant-health contract through the standalone application builder"
        (\liveness readiness -> pure (application env liveness readiness)),
      testCase "readiness distinguishes active keys, missing keys, and PostgreSQL unavailability" do
        (_, readiness) <- buildHealthChecks env
        readiness >>= (@?= Healthy)

        active <- expectRight =<< runAppIO env listActiveSigningKeys
        key <- maybe (assertFailure "bootstrap did not create an active signing key") pure (listToMaybe active)
        timestamp <- expectRight =<< runAppIO env now
        expectRight =<< runAppIO env (updateSigningKeyStatus key.keyId KeyRevoked timestamp)
        readiness >>= assertFailedAs "signing-key"

        unavailablePool <- acquirePool 1 1 defaultDbStatementTimeoutMs "postgresql://127.0.0.1:1/postgres"
        (_, unavailableReadiness) <- buildHealthChecks env {envPool = unavailablePool}
        unavailableReadiness >>= assertFailedAs "postgres"
        Pool.release unavailablePool,
      testCase "tracked readiness preserves onset, resets after recovery, and starts a new run" do
        queryResult <- newIORef (Left (DependencyUnavailable PostgreSQL))
        (_, readiness) <- buildHealthChecksWith (readIORef queryResult)
        first <- readiness
        second <- readiness
        failureOnset first @?= failureOnset second
        writeIORef queryResult (Right [error "the policy checks only whether the list is empty"])
        readiness >>= (@?= Healthy)
        writeIORef queryResult (Left (DependencyUnavailable PostgreSQL))
        third <- readiness
        case (failureOnset first, failureOnset third) of
          (Just old, Just new) -> unless (new >= old) (assertFailure "a new failing run moved backwards")
          _ -> assertFailure "expected tracked failures before and after recovery"
    ]

buildTestEnv :: Text -> IO Env
buildTestEnv connectionString = do
  pool <- acquirePool 4 10 defaultDbStatementTimeoutMs connectionString
  keys <- newIORef =<< bootstrapKeys testKek ES256 pool
  manager <- newManager defaultManagerSettings
  limiter <- newHashingLimiter 2
  notifierQueue <- newNotifierQueue 64
  let config = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
  pure
    Env
      { envPool = pool,
        envConfig = config,
        envKeys = keys,
        envKek = testKek,
        envHttpManager = manager,
        envNotifierSecrets = noNotifierSecrets,
        envNotifierQueue = notifierQueue,
        envArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1},
        envHashingLimiter = limiter,
        envTotpKey = testTotpKey
      }

testKek :: KeyEncryptionKey
testKek = either (error . show) id (keyEncryptionKeyFromBase64 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")

testTotpKey :: TotpEncryptionKey
testTotpKey = either (error . show) id (totpEncryptionKeyFromBytes (BS.replicate 32 0))

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

assertFailedAs :: Text -> ProbeVerdict -> IO ()
assertFailedAs expected = \case
  Unhealthy actual _ -> actual @?= expected
  Healthy -> assertFailure ("expected an unhealthy " <> show expected <> " verdict")

failureOnset :: ProbeVerdict -> Maybe UTCTime
failureOnset = \case
  Healthy -> Nothing
  Unhealthy _ onset -> Just onset
