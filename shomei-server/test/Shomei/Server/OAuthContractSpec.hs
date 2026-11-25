-- | Exercise the actual executable, configuration loader and outer WAI assembly.
module Shomei.Server.OAuthContractSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Control.Monad (forM_, unless, void)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (statusCode)
import Network.Socket (close)
import Network.Wai.Handler.Warp (openFreePort)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.OAuth.TokenGrant.Workflow (pkceChallengeFor)
import Shomei.Persistence.Pool.Postgres qualified as Pool
import Shomei.Server.Config (defaultDbStatementTimeoutMs)
import Shomei.Server.E2ESpec (seedPublicOAuthClient)
import System.Directory (canonicalizePath, createDirectory, doesFileExist, findExecutable, getTemporaryDirectory, makeAbsolute, removeDirectoryRecursive, removeFile)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, openTempFile, withFile)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (UseHandle), createProcess, getPid, getProcessExitCode, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)

tests :: TestTree
tests = testGroup "packaged OAuth contract" [testCase "Hurl validates executable errors and throttling" packagedContract]

packagedContract :: IO ()
packagedContract = do
  fixtures <- makeAbsolute "test/fixtures"
  hurl <- findExecutable "hurl" >>= maybe (fail "Hurl is required; run in nix develop") pure
  supplied <- lookupEnv "SHOMEI_TEST_SERVER_BIN"
  binary <- case supplied of
    Just path -> canonicalizePath path
    Nothing -> findExecutable "shomei-server" >>= maybe (fail "Cabal must provide the shomei-server executable") canonicalizePath
  exists <- doesFileExist binary
  unless exists (fail "Build exe:shomei-server before running the packaged OAuth test")
  bracket makeTemporaryDirectory removeDirectoryRecursive \tmp ->
    withShomeiMigratedDatabase \connStr -> do
      clientId <- bracket (Pool.acquirePool 2 10 defaultDbStatementTimeoutMs connStr) Pool.release seedPublicOAuthClient
      -- Generated locally, never checked into the repository.
      LBS.writeFile (tmp </> "oversized.form") ("grant_type=client_credentials&padding=" <> LBS.replicate (1024 * 1024 + 1) 120)
      forM_ [("errors.hurl", 100), ("throttling.hurl", 1)] \(suite, burst) -> do
        (port, socket) <- openFreePort
        close socket
        let config = tmp </> "server.dhall"
            base = "http://127.0.0.1:" <> show port
            text value = Text.unpack (Text.decodeUtf8 (LBS.toStrict (encode value)))
        -- Use the production typed Dhall loader. Environment overrides are isolated below.
        writeFile config $
          "let Config = "
            <> (fixtures </> "shomei-types.dhall")
            <> " in Config::{ "
            <> "databaseUrl = Some "
            <> text connStr
            <> ", issuer = Some "
            <> text base
            <> ", audience = Some \"oauth-contract\", port = Some "
            <> show port
            <> ", bindHost = Some \"127.0.0.1\", oidcEnabled = Some True"
            <> ", rateLimitEnabled = Some True, perIpBurst = Some "
            <> show (burst :: Int)
            <> ", perIpRequestsPerMinute = Some 1, sweepEnabled = Some False"
            <> ", requestLoggingEnabled = Some False, metricsEnabled = Some False"
            <> ", gracefulShutdownTimeoutSeconds = Some 1 }\n"
        inherited <- getEnvironment
        let childEnv =
              [(k, v) | (k, v) <- inherited, not ("SHOMEI_" `isPrefixOf` k), k `notElem` ["GHCRTS", "PG_CONNECTION_STRING", "DATABASE_URL"]]
                <> [("SHOMEI_CONFIG", config), ("SHOMEI_KEY_ENCRYPTION_KEY", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")]
        withFile (tmp </> "server.log") WriteMode \logHandle ->
          bracket
            (createProcess (proc binary ["+RTS", "-N2", "-RTS"]) {env = Just childEnv, std_out = UseHandle logHandle, std_err = UseHandle logHandle})
            (\(_, _, _, process) -> stopChild process)
            \(_, _, _, process) -> do
              manager <- HTTP.newManager HTTP.defaultManagerSettings
              ready <- timeout 30_000_000 (awaitReady manager process base)
              unless (ready == Just ()) (assertFailure "packaged server readiness timed out")
              outcome <-
                timeout 30_000_000 $
                  readProcessWithExitCode
                    hurl
                    [ "--test",
                      "--max-time",
                      "5",
                      "--file-root",
                      tmp,
                      "--variable",
                      "base_url=" <> base,
                      "--variable",
                      "client_id=" <> Text.unpack clientId,
                      "--variable",
                      "challenge=" <> Text.unpack (pkceChallengeFor "contract-verifier-with-at-least-forty-three-characters"),
                      fixtures </> suite
                    ]
                    ""
              case outcome of
                Just (ExitSuccess, _, _) -> pure ()
                Just (_, output, errors) -> assertFailure (output <> errors)
                Nothing -> assertFailure "Hurl timed out"

awaitReady :: HTTP.Manager -> ProcessHandle -> String -> IO ()
awaitReady manager process base = do
  exited <- getProcessExitCode process
  case exited of
    Just code -> fail ("packaged server exited before readiness: " <> show code)
    Nothing -> do
      request <- HTTP.parseRequest (base <> "/health/ready")
      result <- try @HTTP.HttpException (HTTP.httpLbs request {HTTP.responseTimeout = HTTP.responseTimeoutMicro 500_000} manager)
      case result of
        Right response | statusCode (HTTP.responseStatus response) == 200 -> pure ()
        _ -> threadDelay 100_000 >> awaitReady manager process base

-- Wait synchronously before the enclosing database and temporary files are released.
stopChild :: ProcessHandle -> IO ()
stopChild process = do
  terminateProcess process
  stopped <- timeout 5_000_000 (waitForProcess process)
  case stopped of
    Just _ -> pure ()
    Nothing -> do
      pid <- getPid process
      forM_ pid (signalProcess sigKILL)
      void (waitForProcess process)

makeTemporaryDirectory :: IO FilePath
makeTemporaryDirectory = do
  base <- getTemporaryDirectory
  (path, handle) <- openTempFile base "shomei-oauth-contract"
  hClose handle
  removeFile path
  createDirectory path
  setFileMode path 0o700
  pure path
