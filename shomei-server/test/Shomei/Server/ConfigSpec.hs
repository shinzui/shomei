{- | Tests for EP-5's Dhall + environment configuration loader. Writes a small Dhall file to a
temp path, loads it through 'loadConfig' (which renders it via @dhall-to-json@ and decodes the
result), asserts the parsed values win over the built-in defaults, and then proves an
environment variable overrides the file value (twelve-factor precedence). Using a temp file
avoids any dependency on the test's working directory.
-}
module Main (main) where

import System.Environment (setEnv, unsetEnv)
import Test.Tasty (TestTree, defaultMain)
import Test.Tasty.HUnit (testCase, (@?=))

import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..))
import Shomei.Server.Config (ServerSettings (..), loadConfig)

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
    (cfg, settings) <- loadConfig
    -- File values beat the defaults (default maxFailedLoginsPerAccount is 5, metrics default True):
    settings.serverPort @?= 8080
    cfg.rateLimitConfig.maxFailedLoginsPerAccount @?= 7
    -- PG_CONNECTION_STRING (env) overrides the file's databaseUrl:
    settings.serverConnStr @?= "host=fromenv dbname=shomei"
    -- An env var overrides the file's port:
    setEnv "SHOMEI_PORT" "9999"
    (_, settings2) <- loadConfig
    settings2.serverPort @?= 9999
    unsetEnv "SHOMEI_CONFIG"
    unsetEnv "SHOMEI_PORT"
    unsetEnv "PG_CONNECTION_STRING"
