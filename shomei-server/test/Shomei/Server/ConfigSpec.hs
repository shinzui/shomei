-- | Tests for EP-5's Dhall + environment configuration loader. Writes a small Dhall file to a
-- temp path, loads it through 'loadConfig' (which renders it via @dhall-to-json@ and decodes the
-- result), asserts the parsed values win over the built-in defaults, and then proves an
-- environment variable overrides the file value (twelve-factor precedence). Using a temp file
-- avoids any dependency on the test's working directory.
module Main (main) where

import Control.Exception (try)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Shomei.Config (NotifierConfig (..), RateLimitConfig (..), ServiceAccountConfig (..), ServiceAccountId (..), ServiceTokenConfig (..), ShomeiConfig (..), SigningKeyConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Claims (Scope (..))
import Shomei.Domain.Password (PasswordPolicy (..))
import Shomei.Id (UserId, genUserId, idText)
import Shomei.Server.Config (ServerSettings (..), SweepSettings (..), loadConfig, loadConfigFromEnv)
import System.Environment (setEnv, unsetEnv)
import System.IO.Error (isUserError)
import Test.Tasty (TestTree, defaultMain)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

configPath :: FilePath
configPath = "/tmp/shomei-config-test.dhall"

-- A partial config (FileConfig's fields are all optional, so absent keys fall back to defaults).
dhallContents :: UserId -> String
dhallContents serviceUserId =
  "{ issuer = \"shomei-prod\""
    <> ", databaseUrl = \"host=fromfile dbname=shomei\""
    <> ", port = 8080"
    <> ", dbPoolSize = 25"
    <> ", dbPoolAcquisitionTimeoutMs = 2500"
    <> ", maxFailedLoginsPerAccount = 7"
    <> ", metricsEnabled = False"
    <> ", keyRefreshIntervalSeconds = 15"
    <> ", passwordMinLength = 16"
    <> ", passwordRejectCommon = False"
    <> ", webauthnRpId = \"auth.fromfile.test\""
    <> ", webauthnOrigins = [ \"https://auth.fromfile.test\" ]"
    <> ", webauthnUserVerification = \"required\""
    <> ", webauthnMfaRequired = False"
    <> ", serviceToken = { enabled = True, ttlSeconds = 120, accounts = [ { accountId = \"connector:file\", userId = \""
    <> Text.unpack (idText serviceUserId)
    <> "\", secretSha256 = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", allowedScopes = [ \"kawa:ingest\" ] } ] }"
    <> " }"

main :: IO ()
main = do
  serviceUserId <- genUserId
  writeFile configPath (dhallContents serviceUserId)
  defaultMain (testLoadAndOverride serviceUserId)

-- | With neither Dhall file nor pool env vars, the pool knobs reproduce the values that were
-- hardcoded before they became configuration.
poolDefaults :: Assertion
poolDefaults = do
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  (_, settings) <- loadConfigFromEnv
  settings.serverDbPoolSize @?= 10
  settings.serverDbPoolAcquisitionTimeoutMs @?= 10000
  unsetEnv "PG_CONNECTION_STRING"

-- | A zero-size pool deadlocks every request and a zero acquisition timeout fails every
-- checkout, so the loader refuses to start rather than booting a server that cannot serve.
poolRejectsNonPositive :: Assertion
poolRejectsNonPositive = do
  unsetEnv "SHOMEI_CONFIG"
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_DB_POOL_SIZE" "0"
  sizeResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_DB_POOL_SIZE" sizeResult
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  setEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS" "-1"
  timeoutResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS" timeoutResult
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  unsetEnv "PG_CONNECTION_STRING"

sweepEnvVars :: [String]
sweepEnvVars =
  [ "SHOMEI_SWEEP_ENABLED",
    "SHOMEI_SWEEP_INTERVAL_SECONDS",
    "SHOMEI_SWEEP_BATCH_SIZE",
    "SHOMEI_SWEEP_DEAD_SESSION_GRACE_DAYS",
    "SHOMEI_SWEEP_ONE_TIME_TOKEN_GRACE_DAYS",
    "SHOMEI_SWEEP_CEREMONY_GRACE_MINUTES",
    "SHOMEI_LOGIN_ATTEMPT_RETENTION_DAYS",
    "SHOMEI_AUTH_EVENT_RETENTION_DAYS"
  ]

-- | With no file and no env, the sweeper is on, hourly, and retains the audit trail forever.
sweepDefaults :: Assertion
sweepDefaults = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv sweepEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  (_, settings) <- loadConfigFromEnv
  let sweep = settings.serverSweep
  sweep.sweepEnabled @?= True
  sweep.sweepIntervalSeconds @?= 3600
  sweep.sweepBatchSize @?= 1000
  sweep.sweepDeadSessionGraceDays @?= 30
  sweep.sweepOneTimeTokenGraceDays @?= 7
  sweep.sweepCeremonyGraceMinutes @?= 60
  sweep.sweepLoginAttemptRetentionDays @?= 90
  -- The one conservative default: never delete the compliance record on your own initiative.
  sweep.sweepAuthEventRetentionDays @?= Nothing
  unsetEnv "PG_CONNECTION_STRING"

-- | Every sweep knob is settable from the environment, and a non-positive audit-retention
-- window means "retain forever" rather than "delete everything" — the failure mode of getting
-- that backwards is unrecoverable.
sweepEnvOverrides :: Assertion
sweepEnvOverrides = do
  unsetEnv "SHOMEI_CONFIG"
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_SWEEP_ENABLED" "false"
  setEnv "SHOMEI_SWEEP_INTERVAL_SECONDS" "900"
  setEnv "SHOMEI_SWEEP_BATCH_SIZE" "250"
  setEnv "SHOMEI_SWEEP_DEAD_SESSION_GRACE_DAYS" "0"
  setEnv "SHOMEI_LOGIN_ATTEMPT_RETENTION_DAYS" "30"
  setEnv "SHOMEI_AUTH_EVENT_RETENTION_DAYS" "365"
  (_, settings) <- loadConfigFromEnv
  let sweep = settings.serverSweep
  sweep.sweepEnabled @?= False
  sweep.sweepIntervalSeconds @?= 900
  sweep.sweepBatchSize @?= 250
  -- A zero grace period is legal: sweep a session the moment it expires.
  sweep.sweepDeadSessionGraceDays @?= 0
  sweep.sweepLoginAttemptRetentionDays @?= 30
  sweep.sweepAuthEventRetentionDays @?= Just 365

  -- Zero (or negative) turns audit deletion back off.
  setEnv "SHOMEI_AUTH_EVENT_RETENTION_DAYS" "0"
  (_, offSettings) <- loadConfigFromEnv
  offSettings.serverSweep.sweepAuthEventRetentionDays @?= Nothing

  mapM_ unsetEnv sweepEnvVars
  unsetEnv "PG_CONNECTION_STRING"

-- | A zero interval would spin the sweeper thread and a zero batch size would make it delete
-- nothing forever, so the loader refuses both. @sweepEnabled = false@ is the off-switch.
sweepRejectsNonPositive :: Assertion
sweepRejectsNonPositive = do
  unsetEnv "SHOMEI_CONFIG"
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_SWEEP_INTERVAL_SECONDS" "0"
  intervalResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_SWEEP_INTERVAL_SECONDS" intervalResult
  unsetEnv "SHOMEI_SWEEP_INTERVAL_SECONDS"

  setEnv "SHOMEI_SWEEP_BATCH_SIZE" "0"
  batchResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_SWEEP_BATCH_SIZE" batchResult
  unsetEnv "SHOMEI_SWEEP_BATCH_SIZE"

  -- A negative grace period would sweep rows that have not expired yet.
  setEnv "SHOMEI_SWEEP_CEREMONY_GRACE_MINUTES" "-1"
  graceResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_SWEEP_CEREMONY_GRACE_MINUTES" graceResult
  unsetEnv "SHOMEI_SWEEP_CEREMONY_GRACE_MINUTES"
  unsetEnv "PG_CONNECTION_STRING"

-- | Assert a config load failed with a 'userError' whose message names the offending variable.
expectUserErrorNaming :: String -> Either IOError a -> Assertion
expectUserErrorNaming name = \case
  Left e ->
    assertBool
      ("expected a userError naming " <> name <> ", got: " <> show e)
      (isUserError e && Text.isInfixOf (Text.pack name) (Text.pack (show e)))
  Right _ -> assertFailure (name <> " out of range should have failed the config load")

testLoadAndOverride :: UserId -> TestTree
testLoadAndOverride serviceUserId = testCase "Dhall file is loaded and env vars override it" do
  setEnv "SHOMEI_CONFIG" configPath
  setEnv "PG_CONNECTION_STRING" "host=fromenv dbname=shomei"
  unsetEnv "SHOMEI_PORT"
  unsetEnv "SHOMEI_ISSUER"
  unsetEnv "SHOMEI_WEBAUTHN_RP_ID"
  unsetEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED"
  unsetEnv "SHOMEI_SERVICE_TOKEN_ENABLED"
  unsetEnv "SHOMEI_SERVICE_TOKEN_TTL"
  unsetEnv "SHOMEI_SERVICE_ACCOUNTS_JSON"
  unsetEnv "SHOMEI_KEY_REFRESH_INTERVAL"
  unsetEnv "SHOMEI_NOTIFIER_LOG_SECRETS"
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  (cfg, settings) <- loadConfig
  -- File values beat the defaults (default maxFailedLoginsPerAccount is 5, metrics default True):
  settings.serverPort @?= 8080
  -- The pool knobs load from the file (defaults are 10 / 10000):
  settings.serverDbPoolSize @?= 25
  settings.serverDbPoolAcquisitionTimeoutMs @?= 2500
  cfg.rateLimitConfig.maxFailedLoginsPerAccount @?= 7
  -- The signing-key refresh interval loads from the file (default is 60):
  cfg.signingKeyConfig.refreshIntervalSeconds @?= 15
  -- Raw one-time tokens are never logged unless the env flag opts in (there is deliberately
  -- no Dhall field for it):
  cfg.notifierConfig.logRawTokens @?= False
  -- File values beat the default password policy (default minLength is 12, rejectCommon True):
  cfg.passwordPolicy.minLength @?= 16
  cfg.passwordPolicy.rejectCommonPasswords @?= False
  -- PG_CONNECTION_STRING (env) overrides the file's databaseUrl:
  settings.serverConnStr @?= "host=fromenv dbname=shomei"
  -- WebAuthn fields load from the Dhall file (defaults are rpId="localhost", mfaRequired=True).
  -- WebAuthnConfig is read via record destructuring, not value.field dot syntax (HasField is
  -- unreliable for it under DuplicateRecordFields — MasterPlan 3, EP-1 discovery).
  let WebAuthnConfig {rpId = fileRpId, origins = fileOrigins, mfaRequired = fileMfa} =
        webauthnConfig cfg
  fileRpId @?= "auth.fromfile.test"
  fileOrigins @?= ["https://auth.fromfile.test"]
  fileMfa @?= False
  -- Service-token fields load from the Dhall file.
  let ServiceTokenConfig {enabled = fileSvcEnabled, ttl = fileSvcTtl, accounts = fileSvcAccounts} =
        serviceTokenConfig cfg
  fileSvcEnabled @?= True
  fileSvcTtl @?= 120
  case fileSvcAccounts of
    [ServiceAccountConfig {accountId = ServiceAccountId account, userId = uid, secretHash = secretHash, allowedScopes = scopes}] -> do
      account @?= "connector:file"
      uid @?= serviceUserId
      secretHash @?= "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      Set.member (Scope "kawa:ingest") scopes @?= True
    _ -> fail "expected one service account from file config"
  -- An env var overrides the file's port:
  setEnv "SHOMEI_PORT" "9999"
  -- and the file's pool knobs (file says 25 / 2500):
  setEnv "SHOMEI_DB_POOL_SIZE" "33"
  setEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS" "2000"
  -- SHOMEI_WEBAUTHN_* env vars override the file (twelve-factor precedence):
  setEnv "SHOMEI_WEBAUTHN_RP_ID" "auth.fromenv.test"
  setEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED" "true"
  -- Service-token env vars override the file, including the account list JSON.
  setEnv "SHOMEI_SERVICE_TOKEN_ENABLED" "false"
  setEnv "SHOMEI_SERVICE_TOKEN_TTL" "60"
  setEnv
    "SHOMEI_SERVICE_ACCOUNTS_JSON"
    ( "[{\"accountId\":\"connector:env\",\"userId\":\""
        <> Text.unpack (idText serviceUserId)
        <> "\",\"secretSha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"allowedScopes\":[\"signal:raise\"]}]"
    )
  (cfg2, settings2) <- loadConfig
  settings2.serverPort @?= 9999
  settings2.serverDbPoolSize @?= 33
  settings2.serverDbPoolAcquisitionTimeoutMs @?= 2000
  let WebAuthnConfig {rpId = envRpId, mfaRequired = envMfa} = webauthnConfig cfg2
  envRpId @?= "auth.fromenv.test"
  envMfa @?= True
  let ServiceTokenConfig {enabled = envSvcEnabled, ttl = envSvcTtl, accounts = envSvcAccounts} =
        serviceTokenConfig cfg2
  envSvcEnabled @?= False
  envSvcTtl @?= 60
  case envSvcAccounts of
    [ServiceAccountConfig {accountId = ServiceAccountId account, allowedScopes = scopes}] -> do
      account @?= "connector:env"
      Set.member (Scope "signal:raise") scopes @?= True
    _ -> fail "expected one service account from env JSON"
  -- An env var overrides the file's password min length (file says 16):
  setEnv "SHOMEI_PASSWORD_MIN_LENGTH" "20"
  -- and the file's signing-key refresh interval (file says 15); 0 disables the reload:
  setEnv "SHOMEI_KEY_REFRESH_INTERVAL" "0"
  -- SHOMEI_NOTIFIER_LOG_SECRETS is env-only; it is the sole way to turn raw-token logging on:
  setEnv "SHOMEI_NOTIFIER_LOG_SECRETS" "true"
  (cfg3, _) <- loadConfig
  cfg3.passwordPolicy.minLength @?= 20
  cfg3.signingKeyConfig.refreshIntervalSeconds @?= 0
  cfg3.notifierConfig.logRawTokens @?= True
  unsetEnv "SHOMEI_NOTIFIER_LOG_SECRETS"
  unsetEnv "SHOMEI_KEY_REFRESH_INTERVAL"
  unsetEnv "SHOMEI_PASSWORD_MIN_LENGTH"
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "SHOMEI_PORT"
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  unsetEnv "PG_CONNECTION_STRING"
  unsetEnv "SHOMEI_WEBAUTHN_RP_ID"
  unsetEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED"
  unsetEnv "SHOMEI_SERVICE_TOKEN_ENABLED"
  unsetEnv "SHOMEI_SERVICE_TOKEN_TTL"
  unsetEnv "SHOMEI_SERVICE_ACCOUNTS_JSON"
  -- Run inline rather than as sibling tasty test cases: each of these mutates process-wide
  -- environment variables, and tasty runs the members of a test group in parallel.
  poolDefaults
  poolRejectsNonPositive
  sweepDefaults
  sweepEnvOverrides
  sweepRejectsNonPositive
