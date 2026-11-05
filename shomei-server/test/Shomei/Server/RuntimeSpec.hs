module Shomei.Server.RuntimeSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Network.HTTP.Types (status200)
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import Network.Wai (Application, rawPathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Account.Password.Hash.Postgres (defaultArgon2Params)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (ObservabilityConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Server.Config (ProxyProtocolMode (..), ServerSettings (..), defaultSweepSettings)
import Shomei.Server.Middleware.TrustedProxy (emptyTrustedProxies)
import Shomei.Server.Runtime (hostWarpSettings)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

cfg :: ShomeiConfig
cfg = let c = defaultShomeiConfig (Issuer "test") (Audience "test") in c {observabilityConfig = c.observabilityConfig {gracefulShutdownTimeoutSeconds = 1}}

settings :: ServerSettings
settings =
  ServerSettings
    { serverPort = 0,
      serverBindHost = "127.0.0.1",
      serverMaxConnections = 1,
      serverSlowClientTimeoutSeconds = 1,
      serverConnStr = "",
      serverTrustedProxies = emptyTrustedProxies,
      serverProxyProtocol = ProxyProtocolOff,
      serverDbPoolSize = 1,
      serverDbPoolAcquisitionTimeoutMs = 1000,
      serverDbStatementTimeoutMs = 1000,
      serverDbTransactionMaxAttempts = 3,
      serverDbTransactionDeadlineMs = 5000,
      serverNotifierQueueSize = 16,
      serverWarnings = [],
      serverSweep = defaultSweepSettings,
      serverArgon2 = defaultArgon2Params,
      serverHashingMaxConcurrency = 1
    }

connectTo :: Int -> IO Socket.Socket
connectTo port = do
  sock <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
  Socket.connect sock (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
  pure sock

request :: Socket.Socket -> BS.ByteString -> IO BS.ByteString
request sock path = do
  sendAll sock ("GET " <> path <> " HTTP/1.1\r\nHost: localhost\r\n\r\n")
  result <- timeout 2000000 (recv sock 4096)
  maybe (assertFailure "socket response exceeded the acceptance deadline") pure result

rejected :: Int -> IO ()
rejected port = bracket (connectTo port) Socket.close \sock -> do
  reply <- try (request sock "/") :: IO (Either IOException BS.ByteString)
  assertBool "surplus connection is closed immediately" (case reply of Left _ -> True; Right bytes -> BS.null bytes)

awaitHealthy :: Int -> IO ()
awaitHealthy port = awaitResponse port "/" "HTTP/1.1 200"

awaitResponse :: Int -> BS.ByteString -> BS.ByteString -> IO ()
awaitResponse port path expected = do
  let attempt = do
        result <- try (bracket (connectTo port) Socket.close (\sock -> request sock path)) :: IO (Either IOException BS.ByteString)
        case result of
          Right bytes | expected `BS.isPrefixOf` bytes -> pure ()
          _ -> threadDelay 10000 >> attempt
  timeout 3000000 attempt >>= (@?= Just ())

app :: Application
app request' respond
  | rawPathInfo request' == "/explode" = throwIO (userError "runtime fixture failure")
  | otherwise = respond (responseLBS status200 [] "ok")

tests :: TestTree
tests =
  testGroup
    "shared Warp runtime sockets"
    [ testCase "admission rejects surplus sockets without leaking permits on rejection, disconnect or handler exception" do
        runtime <- hostWarpSettings cfg settings Warp.defaultSettings
        Warp.withApplicationSettings runtime (pure app) \port -> do
          bracket (connectTo port) Socket.close \first -> do
            bytes <- request first "/"
            assertBool "first connection admitted" ("HTTP/1.1 200" `BS.isPrefixOf` bytes)
            rejected port
            rejected port
          awaitHealthy port
          awaitResponse port "/explode" "HTTP/1.1 500"
          awaitHealthy port,
      testCase "explicit slow-client timeout releases an idle connection and shutdown releases shared capacity" do
        runtime <- hostWarpSettings cfg settings Warp.defaultSettings
        Warp.withApplicationSettings runtime (pure app) \port ->
          bracket (connectTo port) Socket.close \sock -> do
            bytes <- request sock "/"
            assertBool "idle connection first admitted" ("HTTP/1.1 200" `BS.isPrefixOf` bytes)
            rejected port
            let awaitClose = do
                  bytes <- recv sock 4096
                  if BS.null bytes then pure () else awaitClose
            closed <- timeout 5000000 awaitClose
            closed @?= Just ()
            awaitHealthy port
        -- Reuse the same admission state after the first listener shuts down.
        Warp.withApplicationSettings runtime (pure app) awaitHealthy,
      testCase "shutdown with an admitted socket restores permits for a new listener" do
        runtime <- hostWarpSettings cfg settings {serverSlowClientTimeoutSeconds = 30} Warp.defaultSettings
        held <- newIORef Nothing
        Warp.withApplicationSettings runtime (pure app) \port -> do
          sock <- connectTo port
          writeIORef held (Just sock)
          bytes <- request sock "/"
          assertBool "socket remains admitted when listener stops" ("HTTP/1.1 200" `BS.isPrefixOf` bytes)
        readIORef held >>= mapM_ Socket.close
        Warp.withApplicationSettings runtime (pure app) awaitHealthy,
      testCase "invalid direct-library host policies fail before serving" do
        forM_ [settings {serverSlowClientTimeoutSeconds = maxBound}, settings {serverMaxConnections = 0}, settings {serverSlowClientTimeoutSeconds = 0}, settings {serverBindHost = ""}] \bad -> do
          result <- try (hostWarpSettings cfg bad Warp.defaultSettings) :: IO (Either IOException Warp.Settings)
          assertBool "invalid policy rejected" (case result of Left _ -> True; _ -> False)
    ]
