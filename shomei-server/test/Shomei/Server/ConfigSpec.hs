-- | Tests for EP-5's Dhall + environment configuration loader. Writes a small Dhall file to a
-- temp path, loads it through 'loadConfig' (which renders it via @dhall-to-json@ and decodes the
-- result), asserts the parsed values win over the built-in defaults, and then proves an
-- environment variable overrides the file value (twelve-factor precedence). Using a temp file
-- avoids any dependency on the test's working directory.
module Main (main) where

import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Password (PasswordPolicy (..))
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import System.Environment (setEnv, unsetEnv)
import Test.Tasty (TestTree, defaultMain)
import Test.Tasty.HUnit (testCase, (@?=))

configPath :: FilePath
configPath = "/tmp/shomei-config-test.dhall"

-- A partial config (FileConfig's fields are all optional, so absent keys fall back to defaults).
dhallContents :: String
dhallContents =
  "{ issuer = \"shomei-prod\""
    <> ", databaseUrl = \"host=fromfile dbname=shomei\""
    <> ", port = 8080"
    <> ", maxFailedLoginsPerAccount = 7"
    <> ", metricsEnabled = False"
    <> ", passwordMinLength = 16"
    <> ", passwordRejectCommon = False"
    <> ", webauthnRpId = \"auth.fromfile.test\""
    <> ", webauthnOrigins = [ \"https://auth.fromfile.test\" ]"
    <> ", webauthnUserVerification = \"required\""
    <> ", webauthnMfaRequired = False"
    <> " }"

main :: IO ()
main = do
  writeFile configPath dhallContents
  defaultMain testLoadAndOverride

testLoadAndOverride :: TestTree
testLoadAndOverride = testCase "Dhall file is loaded and an env var overrides it" do
  setEnv "SHOMEI_CONFIG" configPath
  setEnv "PG_CONNECTION_STRING" "host=fromenv dbname=shomei"
  unsetEnv "SHOMEI_PORT"
  unsetEnv "SHOMEI_ISSUER"
  unsetEnv "SHOMEI_WEBAUTHN_RP_ID"
  unsetEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED"
  (cfg, settings) <- loadConfig
  -- File values beat the defaults (default maxFailedLoginsPerAccount is 5, metrics default True):
  settings.serverPort @?= 8080
  cfg.rateLimitConfig.maxFailedLoginsPerAccount @?= 7
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
  -- An env var overrides the file's port:
  setEnv "SHOMEI_PORT" "9999"
  -- SHOMEI_WEBAUTHN_* env vars override the file (twelve-factor precedence):
  setEnv "SHOMEI_WEBAUTHN_RP_ID" "auth.fromenv.test"
  setEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED" "true"
  (cfg2, settings2) <- loadConfig
  settings2.serverPort @?= 9999
  let WebAuthnConfig {rpId = envRpId, mfaRequired = envMfa} = webauthnConfig cfg2
  envRpId @?= "auth.fromenv.test"
  envMfa @?= True
  -- An env var overrides the file's password min length (file says 16):
  setEnv "SHOMEI_PASSWORD_MIN_LENGTH" "20"
  (cfg3, _) <- loadConfig
  cfg3.passwordPolicy.minLength @?= 20
  unsetEnv "SHOMEI_PASSWORD_MIN_LENGTH"
  unsetEnv "SHOMEI_CONFIG"
  unsetEnv "SHOMEI_PORT"
  unsetEnv "PG_CONNECTION_STRING"
  unsetEnv "SHOMEI_WEBAUTHN_RP_ID"
  unsetEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED"
