-- | Microservice-demo test. Two things are proven here.
--
-- First, downstream /local/ JWT verification: boot the real @shomei-server@ (over an
-- ephemeral PostgreSQL) and the downstream @example-project-service@ in-process, point the
-- downstream at the auth service's JWKS URL, log in at the auth service through the typed
-- client, and call the downstream @\/projects@ — a valid token is @200@ (verified offline,
-- @verifyToken@ makes no call back to the auth service), a tampered token @401@, none @401@.
--
-- Second, the resilience properties of 'JwksCache' itself. These run against a stub JWKS
-- server that counts fetches and can be scripted to stall or fail, replaying the real auth
-- service's JWKS document — so the key set is genuinely valid and the 503 assertion below
-- exercises a token that /would/ have verified.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, forM_, replicateM, replicateM_)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Downstream.Service
  ( JwksUnavailable,
    currentJwks,
    downstreamApplication,
    newJwksCache,
  )
import Network.HTTP.Client
  ( Manager,
    defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types
  ( hCacheControl,
    hContentType,
    status200,
    status500,
    statusCode,
  )
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import Shomei.Client qualified as C
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..), newHashingLimiter)
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
import Shomei.Server.Boot (application)
import Shomei.Server.Keys (bootstrapKeys)
import Test.Tasty (DependencyType (AllFinish), TestTree, defaultMain, dependentTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | Boot the auth service once, capture its real JWKS document and one valid access token,
-- then run the whole suite against them. @defaultMain@ exits by throwing, which unwinds both
-- brackets normally.
main :: IO ()
main =
  withShomeiMigratedDatabase \connStr -> do
    pool <- acquirePool 4 10 connStr
    keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
    envMgr <- newManager defaultManagerSettings
    limiter <- newHashingLimiter 2
    let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
        env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr, envArgon2Params = testArgon2Params, envHashingLimiter = limiter}
    testWithApplication (pure (application env)) \authPort -> do
      mgr <- newManager defaultManagerSettings
      let jwksUrl = "http://127.0.0.1:" <> show authPort <> "/.well-known/jwks.json"
      jwksBytes <- fetchBody mgr jwksUrl
      cenv <- C.shomeiClientEnv ("http://127.0.0.1:" <> show authPort)
      _ <- expect "signup" =<< C.signup cenv SignupRequest {loginId = Nothing, email = Just email, password = password, displayName = "MS"}
      lr <- expect "login" =<< C.login cenv LoginRequest {loginId = Nothing, email = Just email, password = password}
      token <- maybe (assertFailure "expected a body token in bearer mode") pure lr.token.accessToken
      defaultMain (tests mgr cfg jwksUrl jwksBytes token)
  where
    email = "ms@example.com" :: Text
    password = "correct horse battery staple" :: Text

tests :: Manager -> ShomeiConfig -> String -> LBS.ByteString -> Text -> TestTree
tests mgr cfg jwksUrl jwksBytes token =
  testGroup
    "microservice demo: downstream local JWT verification"
    [ testCase "valid token → 200 (offline), tampered → 401, none → 401" do
        cache <- newJwksCache mgr jwksUrl 900 86400
        testWithApplication (pure (downstreamApplication cache cfg)) \downPort -> do
          valid <- getProjects mgr downPort (Just token)
          valid @?= 200

          tampered <- getProjects mgr downPort (Just (Text.dropEnd 1 token <> "X"))
          tampered @?= 401

          none <- getProjects mgr downPort Nothing
          none @?= 401,
      cacheTests mgr cfg jwksBytes token
    ]

-- ---------------------------------------------------------------------------
-- JWKS cache resilience
-- ---------------------------------------------------------------------------

-- | These tests are timing-sensitive and each drives a stub server's mode from the outside,
-- so they run one at a time.
cacheTests :: Manager -> ShomeiConfig -> LBS.ByteString -> Text -> TestTree
cacheTests mgr cfg jwksBytes token =
  dependentTestGroup
    "jwks cache resilience"
    AllFinish
    [ testCase "cold start is single-flight (10 callers, 1 fetch)" $
        withStub jwksBytes \stub stubUrl -> do
          writeIORef stub.stubMode (ServeDelayed 300)
          cache <- newJwksCache mgr stubUrl 900 86400
          sets <- concurrently 10 (currentJwks cache)
          case sets of
            [] -> assertFailure "no callers returned"
            first : _ -> forM_ sets (@?= first)
          readIORef stub.stubCount >>= (@?= 1),
      testCase "cache hits never fetch" $
        withStub jwksBytes \stub stubUrl -> do
          cache <- newJwksCache mgr stubUrl 900 86400
          _ <- currentJwks cache
          replicateM_ 100 (currentJwks cache)
          _ <- concurrently 20 (currentJwks cache)
          readIORef stub.stubCount >>= (@?= 1),
      testCase "refresh-ahead returns instantly and refetches in the background" $
        withStub jwksBytes \stub stubUrl -> do
          cache <- newJwksCache mgr stubUrl 1 86400
          warm <- currentJwks cache
          -- Make the refetch cost 400 ms, so a *blocking* refresh could not satisfy the
          -- latency bound below.
          writeIORef stub.stubMode (ServeDelayed 400)
          -- Past 80% of the 1 s TTL, so this call kicks a refresh...
          threadDelay 850_000
          (elapsed, served) <- timed (currentJwks cache)
          served @?= warm
          assertBool
            ("refresh-window read waited on the refetch (" <> show elapsed <> "s)")
            (elapsed < 0.1)
          -- ...which lands on its own thread.
          fetched <- pollUntil 3_000 ((== 2) <$> readIORef stub.stubCount)
          assertBool "background refresh never happened" fetched,
      testCase "stale-on-error keeps serving after the auth service dies" $
        withStub jwksBytes \stub stubUrl -> do
          cache <- newJwksCache mgr stubUrl 1 60
          warm <- currentJwks cache
          writeIORef stub.stubMode Serve500
          threadDelay 1_200_000
          replicateM_ 5 do
            served <- currentJwks cache
            served @?= warm
            threadDelay 200_000,
      testCase "a failure burst stays single-flight" $
        withStub jwksBytes \stub stubUrl -> do
          cache <- newJwksCache mgr stubUrl 1 60
          _ <- currentJwks cache
          writeIORef stub.stubMode Serve500
          threadDelay 1_200_000
          before <- readIORef stub.stubCount
          _ <- concurrently 20 (currentJwks cache)
          threadDelay 200_000 -- let any in-flight refresher finish
          after <- readIORef stub.stubCount
          assertBool
            ("20 concurrent callers caused " <> show (after - before) <> " fetches")
            (after - before <= 2),
      testCase "past max staleness the service fails closed (503)" $
        withStub jwksBytes \stub stubUrl -> do
          cache <- newJwksCache mgr stubUrl 1 3
          _ <- currentJwks cache
          writeIORef stub.stubMode Serve500
          threadDelay 3_300_000
          direct <- try @JwksUnavailable (currentJwks cache)
          case direct of
            Left _ -> pure ()
            Right _ -> assertFailure "currentJwks served a key set past the staleness bound"
          -- The same condition on the wire: the token is fine, the verifier is not.
          testWithApplication (pure (downstreamApplication cache cfg)) \downPort ->
            getProjects mgr downPort (Just token) >>= (@?= 503),
      testCase "Cache-Control max-age overrides the configured TTL" $
        withStub jwksBytes \stub stubUrl -> do
          writeIORef stub.stubMode (ServeOkMaxAge 1)
          -- A 900 s TTL would never refetch; the response's 1 s max-age must win.
          cache <- newJwksCache mgr stubUrl 900 86400
          _ <- currentJwks cache
          threadDelay 1_200_000
          _ <- currentJwks cache
          refetched <- pollUntil 3_000 ((== 2) <$> readIORef stub.stubCount)
          assertBool "max-age was ignored; no refetch happened" refetched
    ]

-- ---------------------------------------------------------------------------
-- The stub JWKS server
-- ---------------------------------------------------------------------------

data StubMode
  = ServeOk
  | -- | Answer 200 with @Cache-Control: max-age=<n>@.
    ServeOkMaxAge Int
  | Serve500
  | -- | Answer 200 after a delay, in milliseconds.
    ServeDelayed Int

data Stub = Stub
  { stubCount :: !(IORef Int),
    stubMode :: !(IORef StubMode)
  }

-- | Run a stub JWKS server replaying @body@, and hand its control handle plus its URL to the
-- action.
withStub :: LBS.ByteString -> (Stub -> String -> IO a) -> IO a
withStub body action = do
  stub <- Stub <$> newIORef 0 <*> newIORef ServeOk
  testWithApplication (pure (stubApplication body stub)) \port ->
    action stub ("http://127.0.0.1:" <> show port <> "/.well-known/jwks.json")

stubApplication :: LBS.ByteString -> Stub -> Application
stubApplication body stub _req respond = do
  atomicModifyIORef' stub.stubCount \n -> (n + 1, ())
  mode <- readIORef stub.stubMode
  case mode of
    ServeOk -> respond (responseLBS status200 [json] body)
    ServeOkMaxAge n ->
      respond (responseLBS status200 [json, (hCacheControl, "public, max-age=" <> BS8.pack (show n))] body)
    Serve500 -> respond (responseLBS status500 [] "auth service is down")
    ServeDelayed ms -> threadDelay (ms * 1000) >> respond (responseLBS status200 [json] body)
  where
    json = (hContentType, "application/json")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Run @n@ copies of an action concurrently and collect their results, rethrowing the first
-- exception. (Hand-rolled so the example's test suite needs no @async@ dependency.)
concurrently :: Int -> IO a -> IO [a]
concurrently n act = do
  slots <- replicateM n newEmptyMVar
  forM_ slots \slot -> forkIO (try @SomeException act >>= putMVar slot)
  forM slots \slot -> takeMVar slot >>= either throwIO pure

-- | Seconds elapsed, alongside the result.
timed :: IO a -> IO (Double, a)
timed act = do
  t0 <- getCurrentTime
  a <- act
  t1 <- getCurrentTime
  pure (realToFrac (diffUTCTime t1 t0), a)

-- | Poll a condition every 20 ms until it holds or the deadline (milliseconds) passes.
-- Deadline-based rather than a fixed sleep, so a loaded machine slows the suite instead of
-- failing it.
pollUntil :: Int -> IO Bool -> IO Bool
pollUntil budgetMs cond
  | budgetMs <= 0 = cond
  | otherwise =
      cond >>= \case
        True -> pure True
        False -> threadDelay 20_000 >> pollUntil (budgetMs - 20) cond

fetchBody :: Manager -> String -> IO LBS.ByteString
fetchBody mgr url = do
  req <- parseRequest url
  responseBody <$> httpLbs req mgr

getProjects :: Manager -> Int -> Maybe Text -> IO Int
getProjects mgr port mtok = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> "/projects")
  let hdrs = maybe [] (\t -> [("Authorization", "Bearer " <> Text.encodeUtf8 t)]) mtok
      req = req0 {requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp))

expect :: (Show e) => String -> Either e a -> IO a
expect label = either (\e -> assertFailure (label <> " failed: " <> show e)) pure

-- | Cheap Argon2 parameters for tests. This suite hashes and verifies real passwords, and the
-- production cost (~100 ms per hash) would dominate its runtime. Hash strength is irrelevant
-- here; only that hashing round-trips.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}
