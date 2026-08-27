-- | Tests for EP-5's Dhall + environment configuration loader. Writes a small Dhall file to a
-- temp path, loads it through 'loadConfig' (which renders it via @dhall-to-json@ and decodes the
-- result), asserts the parsed values win over the built-in defaults, and then proves an
-- environment variable overrides the file value (twelve-factor precedence). Using a temp file
-- avoids any dependency on the test's working directory.
module Main (main) where

import Control.Exception (try)
import Data.Aeson (Value (Object), eitherDecodeStrict', encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Shomei.Account.Password.Domain (PasswordPolicy (..))
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..))
import Shomei.Authorization.Claims.Domain (Issuer (..))
import Shomei.Config (MachineTokenConfig (..), MfaConfig (..), NotifierConfig (..), NotifierTransport (..), RateLimitConfig (..), ShomeiConfig (..), SigningKeyConfig (..), SmtpConfig (..), SmtpTlsMode (..), WebAuthnConfig (..), WebhookConfig (..))
import Shomei.Notify (NotifierSecrets (..), smtpPasswordText, webhookSecretBytes)
import Shomei.Server.Config (FileConfig, ServerSettings (..), SweepSettings (..), loadConfig, loadConfigFromEnv, loadCoreConfig, loadNotifierSecretsFromEnv)
import Shomei.Server.Keys (loadKekFromEnv)
import System.Directory (makeAbsolute)
import System.Environment (setEnv, unsetEnv)
import System.IO.Error (isUserError)
import System.Process (readProcess)
import Test.Tasty (TestTree, defaultMain)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

configPath :: FilePath
configPath = "/tmp/shomei-config-test.dhall"

schemaProbePath :: FilePath
schemaProbePath = "/tmp/shomei-schema-probe.dhall"

-- A partial config (FileConfig's fields are all optional, so absent keys fall back to defaults).
dhallContents :: String
dhallContents =
  "{ issuer = \"shomei-prod\""
    <> ", databaseUrl = \"host=fromfile dbname=shomei\""
    <> ", port = 8080"
    <> ", dbPoolSize = 25"
    <> ", dbPoolAcquisitionTimeoutMs = 2500"
    <> ", dbStatementTimeoutMs = 5000"
    <> ", notifierQueueSize = 12"
    <> ", maxFailedLoginsPerAccount = 7"
    <> ", metricsEnabled = False"
    <> ", keyRefreshIntervalSeconds = 15"
    <> ", allowedClockSkewSeconds = 20"
    <> ", passwordMinLength = 16"
    <> ", passwordRejectCommon = False"
    <> ", webauthnRpId = \"auth.fromfile.test\""
    <> ", webauthnOrigins = [ \"https://auth.fromfile.test\" ]"
    <> ", webauthnUserVerification = \"required\""
    <> ", mfaRequireSecondFactor = False"
    <> ", machineTokenTtlSeconds = 120"
    <> " }"

main :: IO ()
main = do
  writeFile configPath dhallContents
  defaultMain testLoadAndOverride

-- | With neither Dhall file nor pool env vars, the pool knobs reproduce the values that were
-- hardcoded before they became configuration.
poolDefaults :: Assertion
poolDefaults = do
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  unsetEnv "SHOMEI_DB_STATEMENT_TIMEOUT_MS"
  unsetEnv "SHOMEI_NOTIFIER_QUEUE_SIZE"
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  (_, settings) <- loadConfigFromEnv
  settings.serverDbPoolSize @?= 10
  settings.serverDbPoolAcquisitionTimeoutMs @?= 10000
  settings.serverDbStatementTimeoutMs @?= 30000
  settings.serverNotifierQueueSize @?= 1024
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
  setEnv "SHOMEI_DB_STATEMENT_TIMEOUT_MS" "-1"
  statementTimeoutResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_DB_STATEMENT_TIMEOUT_MS" statementTimeoutResult
  unsetEnv "SHOMEI_DB_STATEMENT_TIMEOUT_MS"
  setEnv "SHOMEI_NOTIFIER_QUEUE_SIZE" "0"
  notifierQueueResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_NOTIFIER_QUEUE_SIZE" notifierQueueResult
  unsetEnv "SHOMEI_NOTIFIER_QUEUE_SIZE"
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

-- | Argon2 defaults, env overrides, and the refusal of non-positive costs.
argon2Settings :: Assertion
argon2Settings = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv argon2EnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"

  (_, defaults) <- loadConfigFromEnv
  defaults.serverArgon2.memoryKiB @?= 65536
  defaults.serverArgon2.iterations @?= 3
  defaults.serverArgon2.parallelism @?= 1
  defaults.serverHashingMaxConcurrency @?= 2

  setEnv "SHOMEI_ARGON2_MEMORY_KIB" "32768"
  setEnv "SHOMEI_ARGON2_ITERATIONS" "4"
  setEnv "SHOMEI_HASHING_MAX_CONCURRENCY" "4"
  (_, overridden) <- loadConfigFromEnv
  overridden.serverArgon2.memoryKiB @?= 32768
  overridden.serverArgon2.iterations @?= 4
  overridden.serverArgon2.parallelism @?= 1
  overridden.serverHashingMaxConcurrency @?= 4
  mapM_ unsetEnv argon2EnvVars

  setEnv "SHOMEI_ARGON2_MEMORY_KIB" "64"
  setEnv "SHOMEI_ARGON2_PARALLELISM" "16"
  hardFloorResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_ARGON2_MEMORY_KIB" hardFloorResult

  setEnv "SHOMEI_ARGON2_MEMORY_KIB" "128"
  (_, boundary) <- loadConfigFromEnv
  boundary.serverArgon2 @?= Argon2Params 128 3 16
  mapM_ unsetEnv argon2EnvVars

  -- crypton would reject these deep inside a login; the loader names the variable instead.
  -- A zero permit count would block every login forever.
  setEnv "SHOMEI_ARGON2_MEMORY_KIB" "0"
  memResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_ARGON2_MEMORY_KIB" memResult
  unsetEnv "SHOMEI_ARGON2_MEMORY_KIB"

  setEnv "SHOMEI_HASHING_MAX_CONCURRENCY" "0"
  concResult <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_HASHING_MAX_CONCURRENCY" concResult
  mapM_ unsetEnv argon2EnvVars
  unsetEnv "PG_CONNECTION_STRING"

argon2EnvVars :: [String]
argon2EnvVars =
  [ "SHOMEI_ARGON2_MEMORY_KIB",
    "SHOMEI_ARGON2_ITERATIONS",
    "SHOMEI_ARGON2_PARALLELISM",
    "SHOMEI_HASHING_MAX_CONCURRENCY"
  ]

-- | Misspelled keys, enum typos, and an empty origin set are deployment errors, not requests to
-- silently keep a default. The email-verification policy is available from the environment too.
strictConfigurationSettings :: Assertion
strictConfigurationSettings = do
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_CONFIG" configPath

  writeFile configPath "{ cookieSecue = False }"
  unknownKey <- try loadConfig
  expectUserErrorNaming "invalid SHOMEI_CONFIG" unknownKey

  writeFile configPath "{ webauthnAttestation = \"nope\" }"
  badAttestation <- try loadConfig
  expectUserErrorNaming "webauthnAttestation" badAttestation

  writeFile configPath "{ webauthnOrigins = ([] : List Text) }"
  emptyFileOrigins <- try loadConfig
  expectUserErrorNaming "webauthnOrigins" emptyFileOrigins

  unsetEnv "SHOMEI_CONFIG"
  setEnv "SHOMEI_WEBAUTHN_ORIGINS" ","
  emptyEnvOrigins <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_WEBAUTHN_ORIGINS" emptyEnvOrigins
  unsetEnv "SHOMEI_WEBAUTHN_ORIGINS"

  setEnv "SHOMEI_EMAIL_VERIFICATION_REQUIRED" "true"
  (emailRequired, _) <- loadConfigFromEnv
  emailRequired.notifierConfig.emailVerificationRequired @?= True
  unsetEnv "SHOMEI_EMAIL_VERIFICATION_REQUIRED"

  writeFile configPath dhallContents
  unsetEnv "PG_CONNECTION_STRING"

-- | Render the schema's completed default while preserving nulls, then compare its key set to
-- the all-'Nothing' JSON representation of 'FileConfig'. This also asks Dhall to check that the
-- shipped default still has exactly the exported 'Type'.
dhallSchemaMatchesFileConfig :: Assertion
dhallSchemaMatchesFileConfig = do
  schema <- makeAbsolute "../config/shomei-types.dhall"
  writeFile schemaProbePath ("(" <> schema <> ")::{=}")
  rendered <- readProcess "dhall-to-json" ["--preserve-null", "--file", schemaProbePath] ""
  dhallKeys <-
    either assertFailure (pure . KeyMap.keys) $
      (eitherDecodeStrict' (Text.encodeUtf8 (Text.pack rendered)) :: Either String (KeyMap.KeyMap Value))
  blank <- either assertFailure pure (eitherDecodeStrict' "{}" :: Either String FileConfig)
  loaderKeys <- case toJSON blank of
    Object fields -> pure (KeyMap.keys fields)
    _ -> assertFailure "FileConfig did not encode as an object"
  Set.fromList dhallKeys @?= Set.fromList loaderKeys

-- | Assert a config load failed with a 'userError' whose message names the offending variable.
expectUserErrorNaming :: String -> Either IOError a -> Assertion
expectUserErrorNaming name = \case
  Left e ->
    assertBool
      ("expected a userError naming " <> name <> ", got: " <> show e)
      (isUserError e && Text.isInfixOf (Text.pack name) (Text.pack (show e)))
  Right _ -> assertFailure (name <> " out of range should have failed the config load")

testLoadAndOverride :: TestTree
testLoadAndOverride = testCase "Dhall file is loaded and env vars override it" do
  setEnv "SHOMEI_CONFIG" configPath
  setEnv "PG_CONNECTION_STRING" "host=fromenv dbname=shomei"
  unsetEnv "SHOMEI_PORT"
  unsetEnv "SHOMEI_ISSUER"
  unsetEnv "SHOMEI_WEBAUTHN_RP_ID"
  unsetEnv "SHOMEI_MFA_REQUIRE_SECOND_FACTOR"
  unsetEnv "SHOMEI_MACHINE_TOKEN_TTL"
  unsetEnv "SHOMEI_KEY_REFRESH_INTERVAL"
  unsetEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS"
  unsetEnv "SHOMEI_NOTIFIER_LOG_SECRETS"
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  unsetEnv "SHOMEI_DB_STATEMENT_TIMEOUT_MS"
  unsetEnv "SHOMEI_NOTIFIER_QUEUE_SIZE"
  (cfg, settings) <- loadConfig
  -- File values beat the defaults (default maxFailedLoginsPerAccount is 5, metrics default True):
  settings.serverPort @?= 8080
  -- The pool knobs load from the file (defaults are 10 / 10000):
  settings.serverDbPoolSize @?= 25
  settings.serverDbPoolAcquisitionTimeoutMs @?= 2500
  settings.serverDbStatementTimeoutMs @?= 5000
  settings.serverNotifierQueueSize @?= 12
  cfg.rateLimitConfig.maxFailedLoginsPerAccount @?= 7
  -- The signing-key refresh interval loads from the file (default is 60):
  cfg.signingKeyConfig.refreshIntervalSeconds @?= 15
  cfg.signingKeyConfig.allowedClockSkewSeconds @?= 20
  -- Raw one-time tokens are never logged unless the env flag opts in (there is deliberately
  -- no Dhall field for it):
  cfg.notifierConfig.logRawTokens @?= False
  -- File values beat the default password policy (default minLength is 12, rejectCommon True):
  cfg.passwordPolicy.minLength @?= 16
  cfg.passwordPolicy.rejectCommonPasswords @?= False
  -- PG_CONNECTION_STRING (env) overrides the file's databaseUrl:
  settings.serverConnStr @?= "host=fromenv dbname=shomei"
  -- WebAuthn and MFA fields load from their respective Dhall settings.
  -- WebAuthnConfig is read via record destructuring, not value.field dot syntax (HasField is
  -- unreliable for it under DuplicateRecordFields — MasterPlan 3, EP-1 discovery).
  let WebAuthnConfig {rpId = fileRpId, origins = fileOrigins} = webauthnConfig cfg
  fileRpId @?= "auth.fromfile.test"
  fileOrigins @?= ["https://auth.fromfile.test"]
  cfg.mfaConfig.requireSecondFactor @?= False
  cfg.machineTokenConfig.machineTokenTTL @?= 120
  -- An env var overrides the file's port:
  setEnv "SHOMEI_PORT" "9999"
  -- and the file's pool knobs (file says 25 / 2500):
  setEnv "SHOMEI_DB_POOL_SIZE" "33"
  setEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS" "2000"
  setEnv "SHOMEI_DB_STATEMENT_TIMEOUT_MS" "7000"
  setEnv "SHOMEI_NOTIFIER_QUEUE_SIZE" "24"
  -- Concept-specific env vars override the file (twelve-factor precedence):
  setEnv "SHOMEI_WEBAUTHN_RP_ID" "auth.fromenv.test"
  setEnv "SHOMEI_MFA_REQUIRE_SECOND_FACTOR" "true"
  setEnv "SHOMEI_MACHINE_TOKEN_TTL" "60"
  (cfg2, settings2) <- loadConfig
  settings2.serverPort @?= 9999
  settings2.serverDbPoolSize @?= 33
  settings2.serverDbPoolAcquisitionTimeoutMs @?= 2000
  settings2.serverDbStatementTimeoutMs @?= 7000
  settings2.serverNotifierQueueSize @?= 24
  let WebAuthnConfig {rpId = envRpId} = webauthnConfig cfg2
  envRpId @?= "auth.fromenv.test"
  cfg2.mfaConfig.requireSecondFactor @?= True
  cfg2.machineTokenConfig.machineTokenTTL @?= 60
  -- An env var overrides the file's password min length (file says 16):
  setEnv "SHOMEI_PASSWORD_MIN_LENGTH" "20"
  -- and the file's signing-key refresh interval (file says 15); 0 disables the reload:
  setEnv "SHOMEI_KEY_REFRESH_INTERVAL" "0"
  setEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS" "45"
  -- SHOMEI_NOTIFIER_LOG_SECRETS is env-only; it is the sole way to turn raw-token logging on:
  setEnv "SHOMEI_NOTIFIER_LOG_SECRETS" "true"
  (cfg3, _) <- loadConfig
  cfg3.passwordPolicy.minLength @?= 20
  cfg3.signingKeyConfig.refreshIntervalSeconds @?= 0
  cfg3.signingKeyConfig.allowedClockSkewSeconds @?= 45
  cfg3.notifierConfig.logRawTokens @?= True
  unsetEnv "SHOMEI_NOTIFIER_LOG_SECRETS"
  unsetEnv "SHOMEI_KEY_REFRESH_INTERVAL"
  unsetEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS"
  unsetEnv "SHOMEI_PASSWORD_MIN_LENGTH"
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "SHOMEI_PORT"
  unsetEnv "SHOMEI_DB_POOL_SIZE"
  unsetEnv "SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS"
  unsetEnv "SHOMEI_DB_STATEMENT_TIMEOUT_MS"
  unsetEnv "SHOMEI_NOTIFIER_QUEUE_SIZE"
  unsetEnv "PG_CONNECTION_STRING"
  unsetEnv "SHOMEI_WEBAUTHN_RP_ID"
  unsetEnv "SHOMEI_MFA_REQUIRE_SECOND_FACTOR"
  unsetEnv "SHOMEI_MACHINE_TOKEN_TTL"
  -- Run inline rather than as sibling tasty test cases: each of these mutates process-wide
  -- environment variables, and tasty runs the members of a test group in parallel.
  poolDefaults
  poolRejectsNonPositive
  sweepDefaults
  sweepEnvOverrides
  sweepRejectsNonPositive
  argon2Settings
  strictConfigurationSettings
  dhallSchemaMatchesFileConfig
  coreLoaderNeedsNoConnectionString
  verifierSettings
  notifierDefaults
  notifierSmtpDhallAndEnv
  notifierWebhookEnv
  notifierSmtpMissingHostFails
  notifierSmtpUsernameWithoutPasswordFails
  notifierWebhookMissingSecretFails
  notifierSecretsAreStrippedAndConfigIsSecretFree
  notifierInsecureTransportFlags
  kekIsRequired

-- | Administrative workflows consume the deployment's core policy without pretending to be a
-- listening server or requiring the server's PostgreSQL variable.
coreLoaderNeedsNoConnectionString :: Assertion
coreLoaderNeedsNoConnectionString = do
  setEnv "SHOMEI_CONFIG" configPath
  unsetEnv "PG_CONNECTION_STRING"
  cfg <- loadCoreConfig
  cfg.passwordPolicy.minLength @?= 16
  cfg.passwordPolicy.rejectCommonPasswords @?= False
  unsetEnv "SHOMEI_CONFIG"

-- | The verifier skew has a safe default, supports env override, and rejects
-- negative values. Issuer and audience are validated as RFC 7519 StringOrURI
-- values before the signer can reach jose's partial IsString conversion.
verifierSettings :: Assertion
verifierSettings = do
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS"
  unsetEnv "SHOMEI_ISSUER"
  unsetEnv "SHOMEI_AUDIENCE"
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"

  (defaults, _) <- loadConfigFromEnv
  defaults.signingKeyConfig.allowedClockSkewSeconds @?= 30

  setEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS" "45"
  (overridden, _) <- loadConfigFromEnv
  overridden.signingKeyConfig.allowedClockSkewSeconds @?= 45

  setEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS" "-1"
  negativeSkew <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS" negativeSkew
  unsetEnv "SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS"

  -- RFC 3986 permits a scheme with a rootless path, so this is a valid URI.
  setEnv "SHOMEI_ISSUER" "shomei:prod"
  (schemeIssuer, _) <- loadConfigFromEnv
  let Issuer schemeIssuerText = schemeIssuer.issuer
  schemeIssuerText @?= "shomei:prod"

  setEnv "SHOMEI_ISSUER" "https://bad host"
  invalidIssuer <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_ISSUER" invalidIssuer
  unsetEnv "SHOMEI_ISSUER"

  setEnv "SHOMEI_AUDIENCE" "https://bad audience"
  invalidAudience <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_AUDIENCE" invalidAudience

  unsetEnv "SHOMEI_AUDIENCE"
  unsetEnv "PG_CONNECTION_STRING"

kekIsRequired :: Assertion
kekIsRequired = do
  unsetEnv "SHOMEI_KEY_ENCRYPTION_KEY"
  missing <- try loadKekFromEnv
  expectUserErrorNaming "SHOMEI_KEY_ENCRYPTION_KEY" missing
  setEnv "SHOMEI_KEY_ENCRYPTION_KEY" "not-base64"
  malformed <- try loadKekFromEnv
  expectUserErrorNaming "SHOMEI_KEY_ENCRYPTION_KEY" malformed
  setEnv "SHOMEI_KEY_ENCRYPTION_KEY" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  _ <- loadKekFromEnv
  unsetEnv "SHOMEI_KEY_ENCRYPTION_KEY"

-- EP-8 notifier transport ------------------------------------------------------

notifierEnvVars :: [String]
notifierEnvVars =
  [ "SHOMEI_NOTIFIER_TRANSPORT",
    "SHOMEI_NOTIFIER_ALSO_LOG",
    "SHOMEI_SMTP_HOST",
    "SHOMEI_SMTP_PORT",
    "SHOMEI_SMTP_TLS_MODE",
    "SHOMEI_SMTP_USERNAME",
    "SHOMEI_SMTP_PASSWORD",
    "SHOMEI_SMTP_FROM",
    "SHOMEI_SMTP_TIMEOUT",
    "SHOMEI_WEBHOOK_URL",
    "SHOMEI_WEBHOOK_SECRET",
    "SHOMEI_WEBHOOK_TIMEOUT",
    "SHOMEI_WEBHOOK_MAX_ATTEMPTS",
    "SHOMEI_WEBHOOK_ALLOW_INSECURE",
    "SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH",
    "SHOMEI_NOTIFIER_QUEUE_SIZE"
  ]

-- | With no config and no env, the notifier is the log sender and both sub-configs are absent.
notifierDefaults :: Assertion
notifierDefaults = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  (cfg, _) <- loadConfigFromEnv
  let nc = cfg.notifierConfig
  nc.notifierTransport @?= LogNotifier
  nc.smtpConfig @?= Nothing
  nc.webhookConfig @?= Nothing
  nc.alsoLogNotifications @?= False
  unsetEnv "PG_CONNECTION_STRING"

smtpConfigPath :: FilePath
smtpConfigPath = "/tmp/shomei-config-smtp-test.dhall"

-- | The SMTP transport loads from the Dhall file, while the relay password enters the separate
-- runtime-only secret value.
notifierSmtpDhallAndEnv :: Assertion
notifierSmtpDhallAndEnv = do
  mapM_ unsetEnv notifierEnvVars
  writeFile
    smtpConfigPath
    ( "{ databaseUrl = \"host=fromfile dbname=shomei\""
        <> ", notifierTransport = \"smtp\""
        <> ", smtpHost = \"email-smtp.us-east-1.amazonaws.com\""
        <> ", smtpPort = 587"
        <> ", smtpTlsMode = \"starttls\""
        <> ", smtpUsername = \"AKIAEXAMPLE\""
        <> ", smtpFromAddress = \"auth@example.com\""
        <> ", smtpTimeoutSeconds = 20"
        <> ", publicBaseUrl = \"https://auth.example.com\""
        <> " }"
    )
  setEnv "SHOMEI_CONFIG" smtpConfigPath
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_SMTP_PASSWORD" "smtp-secret-from-env"
  -- publicBaseUrl is set in the Dhall file; the env var overrides it (twelve-factor).
  setEnv "SHOMEI_PUBLIC_BASE_URL" "https://auth.env.example.com"
  (cfg, _) <- loadConfig
  let nc = cfg.notifierConfig
  nc.notifierTransport @?= SmtpNotifier
  nc.publicBaseUrl @?= "https://auth.env.example.com"
  case nc.smtpConfig of
    Just (SmtpConfig {host = h, port = p, tlsMode = tls, username = u, fromAddress = fromA, timeoutSeconds = to}) -> do
      h @?= "email-smtp.us-east-1.amazonaws.com"
      p @?= 587
      tls @?= SmtpStartTls
      u @?= Just "AKIAEXAMPLE"
      fromA @?= "auth@example.com"
      to @?= 20
    Nothing -> assertFailure "expected smtpConfig to be populated for transport=smtp"
  secrets <- loadNotifierSecretsFromEnv cfg
  fmap smtpPasswordText secrets.smtpPassword @?= Just "smtp-secret-from-env"
  unsetEnv "SHOMEI_SMTP_PASSWORD"
  unsetEnv "SHOMEI_PUBLIC_BASE_URL"
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "PG_CONNECTION_STRING"

-- | The webhook transport can be configured entirely from the environment, with its secret
-- held separately from the printable config.
notifierWebhookEnv :: Assertion
notifierWebhookEnv = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "webhook"
  setEnv "SHOMEI_WEBHOOK_URL" "https://hooks.example.com/shomei"
  setEnv "SHOMEI_WEBHOOK_SECRET" "webhook-secret"
  setEnv "SHOMEI_WEBHOOK_MAX_ATTEMPTS" "5"
  setEnv "SHOMEI_NOTIFIER_ALSO_LOG" "true"
  (cfg, _) <- loadConfigFromEnv
  let nc = cfg.notifierConfig
  nc.notifierTransport @?= WebhookNotifier
  nc.alsoLogNotifications @?= True
  case nc.webhookConfig of
    Just (WebhookConfig {url = u, maxAttempts = ma}) -> do
      u @?= "https://hooks.example.com/shomei"
      ma @?= 5
    Nothing -> assertFailure "expected webhookConfig to be populated for transport=webhook"
  secrets <- loadNotifierSecretsFromEnv cfg
  fmap webhookSecretBytes secrets.webhookSecret @?= Just "webhook-secret"
  mapM_ unsetEnv notifierEnvVars
  unsetEnv "PG_CONNECTION_STRING"

-- | Selecting smtp without a host fails the boot, naming the missing variable.
notifierSmtpMissingHostFails :: Assertion
notifierSmtpMissingHostFails = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "smtp"
  setEnv "SHOMEI_SMTP_FROM" "auth@example.com"
  result <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_SMTP_HOST" result
  mapM_ unsetEnv notifierEnvVars
  unsetEnv "PG_CONNECTION_STRING"

-- | An SMTP username with no password (or vice versa) is refused: it is neither a valid
-- authenticated relay nor a valid lab sink.
notifierSmtpUsernameWithoutPasswordFails :: Assertion
notifierSmtpUsernameWithoutPasswordFails = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "smtp"
  setEnv "SHOMEI_SMTP_HOST" "smtp.example.com"
  setEnv "SHOMEI_SMTP_FROM" "auth@example.com"
  setEnv "SHOMEI_SMTP_USERNAME" "relay-user"
  (cfg, _) <- loadConfigFromEnv
  result <- try (loadNotifierSecretsFromEnv cfg)
  expectUserErrorNaming "SHOMEI_SMTP_PASSWORD" result
  mapM_ unsetEnv notifierEnvVars
  unsetEnv "PG_CONNECTION_STRING"

-- | Selecting webhook without a signing secret fails the boot, naming the missing variable.
notifierWebhookMissingSecretFails :: Assertion
notifierWebhookMissingSecretFails = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "webhook"
  setEnv "SHOMEI_WEBHOOK_URL" "https://hooks.example.com/shomei"
  (cfg, _) <- loadConfigFromEnv
  result <- try (loadNotifierSecretsFromEnv cfg)
  expectUserErrorNaming "SHOMEI_WEBHOOK_SECRET" result
  mapM_ unsetEnv notifierEnvVars
  unsetEnv "PG_CONNECTION_STRING"

notifierSecretsAreStrippedAndConfigIsSecretFree :: Assertion
notifierSecretsAreStrippedAndConfigIsSecretFree = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "  host=localhost dbname=shomei  "
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "webhook"
  setEnv "SHOMEI_WEBHOOK_URL" "  https://hooks.example.com/shomei  "
  setEnv "SHOMEI_WEBHOOK_SECRET" "  webhook-secret\n"
  (cfg, settings) <- loadConfigFromEnv
  settings.serverConnStr @?= "host=localhost dbname=shomei"
  secrets <- loadNotifierSecretsFromEnv cfg
  fmap webhookSecretBytes secrets.webhookSecret @?= Just "webhook-secret"
  let notifier = cfg.notifierConfig
      fullConfig =
        cfg
          { notifierConfig =
              notifier
                { smtpConfig =
                    Just
                      SmtpConfig
                        { host = "smtp.example.com",
                          port = 587,
                          tlsMode = SmtpStartTls,
                          username = Just "relay-user",
                          fromAddress = "auth@example.com",
                          timeoutSeconds = 10
                        }
                }
          }
      encoded = LBS8.unpack (encode fullConfig)
  assertBool "ShomeiConfig JSON must not have an SMTP password field" (not ("\"password\":" `isInfixOf` encoded))
  assertBool "ShomeiConfig JSON must not have a webhook secret field" (not ("\"secret\":" `isInfixOf` encoded))
  mapM_ unsetEnv notifierEnvVars
  unsetEnv "PG_CONNECTION_STRING"

notifierInsecureTransportFlags :: Assertion
notifierInsecureTransportFlags = do
  unsetEnv "SHOMEI_CONFIG"
  mapM_ unsetEnv notifierEnvVars
  setEnv "PG_CONNECTION_STRING" "host=localhost dbname=shomei"
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "webhook"
  setEnv "SHOMEI_WEBHOOK_URL" "http://127.0.0.1:9999/hook"
  setEnv "SHOMEI_WEBHOOK_SECRET" "secret"
  insecureWebhook <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_WEBHOOK_ALLOW_INSECURE" insecureWebhook
  setEnv "SHOMEI_WEBHOOK_ALLOW_INSECURE" "true"
  (webhookCfg, _) <- loadConfigFromEnv
  _ <- loadNotifierSecretsFromEnv webhookCfg

  mapM_ unsetEnv notifierEnvVars
  setEnv "SHOMEI_NOTIFIER_TRANSPORT" "smtp"
  setEnv "SHOMEI_SMTP_HOST" "smtp.example.com"
  setEnv "SHOMEI_SMTP_FROM" "auth@example.com"
  setEnv "SHOMEI_SMTP_TLS_MODE" "plain"
  setEnv "SHOMEI_SMTP_USERNAME" "relay-user"
  setEnv "SHOMEI_SMTP_PASSWORD" "relay-password"
  plaintextAuth <- try loadConfigFromEnv
  expectUserErrorNaming "SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH" plaintextAuth
  setEnv "SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH" "true"
  (smtpCfg, _) <- loadConfigFromEnv
  _ <- loadNotifierSecretsFromEnv smtpCfg

  unsetEnv "SHOMEI_SMTP_USERNAME"
  unsetEnv "SHOMEI_SMTP_PASSWORD"
  unsetEnv "SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH"
  (_, warningSettings) <- loadConfigFromEnv
  assertBool
    "unauthenticated plaintext SMTP warns"
    ("smtpTlsMode=plain sends mail in the clear; lab sinks only" `elem` warningSettings.serverWarnings)
  mapM_ unsetEnv notifierEnvVars
  unsetEnv "PG_CONNECTION_STRING"
