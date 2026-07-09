-- | Tests for the four EP-4 middleware hardening fixes. All of them are database-free: the
-- rate limiter takes its clock as an argument, the metrics registry is plain 'IORef's, and the
-- WAI middlewares are just functions we can apply to a 'defaultRequest'.
module Shomei.Server.MiddlewareSpec (tests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (ErrorCall (..), throwIO, toException, try)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (Object, String), decodeStrict, (.=))
import Data.Aeson.Key (Key)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Word (Word64)
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Status (status200)
import Network.Wai (Request (..), RequestBodyLength (..), Response, defaultRequest, responseLBS, responseStatus)
import Network.Wai.Internal (ResponseReceived (..))
import Shomei.Config (LogFormat (..), RateLimitConfig (..), defaultRateLimitConfig)
import Shomei.Server.Middleware.BodyLimit (bodyLimitMiddleware)
import Shomei.Server.Middleware.RateLimit (bucketCount, newRateLimiterWith, takeToken)
import Shomei.Server.Observability.Logging (emitLine, renderLogLine, serverErrorLine)
import Shomei.Server.Observability.Metrics (exportMetrics, metricsMiddleware, newMetrics)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (BufferMode (LineBuffering), hClose, hSetBuffering, openTempFile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "middleware hardening"
    [ testGroup
        "rate limiter"
        [ testIdleBucketsEvicted,
          testDrainedBucketSurvivesSweep,
          testBucketMapStaysBounded
        ],
      testGroup
        "metrics"
        [ testThrowingHandlerLeavesGaugeAtZero,
          testNormalRequestCountedAndGaugeReturnsToZero
        ],
      testGroup
        "logging"
        [ testRenderLogLineIsOneJsonLine,
          testPlainFormatStripsControlCharacters,
          testConcurrentWritersProduceIntactLines,
          testServerErrorLineIsStructured
        ],
      testGroup
        "body limit"
        [ testOversizedBodyRejected,
          testKnownSmallBodyPassesThrough,
          testChunkedBodyPassesThrough
        ]
    ]

-- Rate limiter ---------------------------------------------------------------

-- | A limiter with a 3-token burst refilling at 1 token/second, pruning every @every@ calls.
testLimiterConfig :: RateLimitConfig
testLimiterConfig =
  defaultRateLimitConfig
    { perIpBurst = 3,
      perIpRequestsPerMinute = 60,
      rateLimitEnabled = True
    }

-- | Every bucket touched at @t=0@ has long since refilled by @t=100@, so the sweep that fires
-- on the eighth call drops all of them. The freshly drained bucket that triggered the sweep
-- survives, because it is not full.
testIdleBucketsEvicted :: TestTree
testIdleBucketsEvicted = testCase "idle buckets are evicted after a sweep" do
  rl <- newRateLimiterWith 8 testLimiterConfig
  -- Eight distinct IPs, one call each at t=0. The eighth call triggers a sweep, but at t=0
  -- every bucket holds 2 of its 3 tokens, so nothing is evictable.
  forM_ [1 .. 8 :: Int] \i -> takeToken rl (ipKey i) 0
  before <- bucketCount rl
  assertEqual "no bucket is full at t=0, so the first sweep evicts nothing" 8 before
  -- Eight calls for a ninth IP at t=100. The sweep on the eighth prunes ip1..ip8 (each has
  -- refilled from 2 tokens to well past its 3-token capacity) and keeps ip9 (drained to 0).
  forM_ [1 .. 8 :: Int] \_ -> takeToken rl "ip9" 100
  after <- bucketCount rl
  assertEqual "only the mid-refill bucket survives" 1 after

-- | Eviction must be observationally lossless: a bucket that still owes tokens is never
-- dropped, so a client that has been throttled stays throttled across a sweep.
testDrainedBucketSurvivesSweep :: TestTree
testDrainedBucketSurvivesSweep = testCase "a drained bucket survives a sweep (lossless)" do
  rl <- newRateLimiterWith 8 testLimiterConfig
  -- Drain ipA at t=0: three allowed, the fourth refused.
  allowed <- forM [1 .. 4 :: Int] \_ -> takeToken rl "ipA" 0
  assertEqual "burst of 3, then refusal" [True, True, True, False] allowed
  -- Four more calls (still t=0) push the counter to 8 and fire the sweep.
  forM_ [1 .. 4 :: Int] \_ -> takeToken rl "ipB" 0
  -- If the sweep had dropped ipA, this would be treated as a fresh full bucket and allowed.
  stillRefused <- takeToken rl "ipA" 0
  assertEqual "the drained bucket was not resurrected by the sweep" False stillRefused

-- | The whole point: ten thousand one-shot IPs must not leave ten thousand buckets behind.
testBucketMapStaysBounded :: TestTree
testBucketMapStaysBounded = testCase "10k one-shot IPs leave a bounded map" do
  let every = 8
  rl <- newRateLimiterWith every testLimiterConfig
  -- One call per IP, ten seconds apart, so each bucket is fully refilled by the next sweep.
  forM_ [1 .. 10_000 :: Int] \i -> takeToken rl (ipKey i) (fromIntegral i * 10)
  n <- bucketCount rl
  assertBool
    ("expected at most " <> show (every + 1) <> " buckets, got " <> show n)
    (n <= every + 1)

ipKey :: Int -> ByteString
ipKey i = BC.pack ("ip" <> show i)

-- Metrics --------------------------------------------------------------------

-- | An application that throws instead of responding must still decrement the gauge. Before
-- this fix the decrement lived only in the response continuation, which never ran.
testThrowingHandlerLeavesGaugeAtZero :: TestTree
testThrowingHandlerLeavesGaugeAtZero = testCase "a throwing handler leaves in-flight at 0" do
  m <- newMetrics
  let boomApp _req _respond = throwIO (ErrorCall "boom")
  -- The continuation is never reached, so 'undefined' is safe and keeps the test honest.
  outcome <- try (metricsMiddleware m boomApp defaultRequest (\_ -> undefined))
  case outcome :: Either ErrorCall ResponseReceived of
    Right _ -> fail "expected the exception to propagate through the middleware"
    Left _ -> pure ()
  body <- exportMetrics m
  assertMetricLine "http_requests_in_flight 0" body

-- | The normal path decrements exactly once too — no double-decrement into negative territory.
testNormalRequestCountedAndGaugeReturnsToZero :: TestTree
testNormalRequestCountedAndGaugeReturnsToZero = testCase "a normal request is counted and the gauge returns to 0" do
  m <- newMetrics
  let okApp _req respond = respond (responseLBS status200 [] "ok")
  ResponseReceived <- metricsMiddleware m okApp defaultRequest (\_ -> pure ResponseReceived)
  body <- exportMetrics m
  assertMetricLine "http_requests_in_flight 0" body
  assertMetricLine "http_requests_total{method=\"GET\",status=\"200\"} 1" body

-- | Assert the exported Prometheus text contains @wanted@ as a whole line.
assertMetricLine :: BL.ByteString -> BL.ByteString -> IO ()
assertMetricLine wanted body =
  assertBool
    ("expected a line " <> show wanted <> " in:\n" <> BLC.unpack body)
    (wanted `elem` BLC.lines body)

-- Logging --------------------------------------------------------------------

-- | Whatever a field value contains, the rendered line is exactly one line, and in JSON format
-- it is exactly one JSON object.
testRenderLogLineIsOneJsonLine :: TestTree
testRenderLogLineIsOneJsonLine = testCase "renderLogLine emits exactly one valid JSON line" do
  let line = renderLogLine LogJson hostileFields
  assertBool "line ends with a newline" ("\n" `BS.isSuffixOf` line)
  assertEqual "exactly one newline, at the end" 1 (BC.count '\n' line)
  case decodeStrict (BS.init line) :: Maybe Value of
    Just (Object _) -> pure ()
    other -> fail ("expected a JSON object, got " <> show other)

-- | The plain format has no encoder to escape a newline for it, so it must filter one out —
-- otherwise a hostile value forges a second log line.
testPlainFormatStripsControlCharacters :: TestTree
testPlainFormatStripsControlCharacters = testCase "the plain format strips control characters" do
  let line = renderLogLine LogPlain hostileFields
  assertBool "line ends with a newline" ("\n" `BS.isSuffixOf` line)
  assertEqual "exactly one newline, at the end" 1 (BC.count '\n' line)
  assertEqual "no embedded quotes survive" 0 (BC.count '"' line)

-- | A value carrying the two characters that could break the one-line contract.
hostileFields :: [(Key, Value)]
hostileFields =
  [ "level" .= ("info" :: Text),
    "msg" .= String "line one\nlevel=error msg=\"forged\"",
    "status" .= (200 :: Int)
  ]

-- | Two hundred threads writing five lines each through the real emit path must produce a
-- thousand intact lines: no chunk of one line interleaved into another.
testConcurrentWritersProduceIntactLines :: TestTree
testConcurrentWritersProduceIntactLines = testCase "200 concurrent writers produce 1000 intact lines" do
  let threads = 200 :: Int
      linesPerThread = 5 :: Int
  tmpDir <- getTemporaryDirectory
  (path, h) <- openTempFile tmpDir "shomei-log-concurrency.jsonl"
  hSetBuffering h LineBuffering
  dones <- forM [1 .. threads] \t -> do
    done <- newEmptyMVar
    _ <- forkIO do
      forM_ [1 .. linesPerThread] \s ->
        emitLine h (renderLogLine LogJson ["thread" .= t, "seq" .= s])
      putMVar done ()
    pure done
  forM_ dones takeMVar
  hClose h
  contents <- BS.readFile path
  removeFile path
  let ls = BC.lines contents
  assertEqual "one line per write" (threads * linesPerThread) (length ls)
  decoded <- forM ls \l ->
    case decodeStrict l :: Maybe (Map Text Int) of
      Nothing -> fail ("line did not parse as a JSON object: " <> show l)
      Just obj -> pure (Map.lookup "thread" obj, Map.lookup "seq" obj)
  let expected = sort [(Just t, Just s) | t <- [1 .. threads], s <- [1 .. linesPerThread]]
  assertEqual "every (thread, seq) pair arrived exactly once" expected (sort decoded)

-- | Warp's exception hook must produce the same structured shape as a request line.
testServerErrorLineIsStructured :: TestTree
testServerErrorLineIsStructured = testCase "the warp exception logger renders structured JSON" do
  let req = defaultRequest {requestMethod = "POST", rawPathInfo = "/auth/login"}
      err = toException (ErrorCall "database is on fire")
      line = serverErrorLine (Just req) err
  case decodeStrict (BS.init line) :: Maybe (Map Text Text) of
    Nothing -> fail ("expected a JSON object, got " <> show line)
    Just obj -> do
      Map.lookup "level" obj @?= Just "error"
      Map.lookup "msg" obj @?= Just "unhandled exception"
      Map.lookup "method" obj @?= Just "POST"
      Map.lookup "path" obj @?= Just "/auth/login"
      assertBool "the exception text is carried" (Map.member "error" obj)
  -- Without a request, the method/path fields are simply absent.
  let bare = serverErrorLine Nothing err
  case decodeStrict (BS.init bare) :: Maybe (Map Text Text) of
    Nothing -> fail "expected a JSON object for the request-less case"
    Just obj -> assertBool "no method field without a request" (not (Map.member "method" obj))

-- Body limit -----------------------------------------------------------------

-- | An oversized declared body is refused with 413 and the inner application never runs.
testOversizedBodyRejected :: TestTree
testOversizedBodyRejected = testCase "a 2 MiB Content-Length is rejected with 413" do
  (status, reached) <- runBodyLimit (KnownLength (2 * 1024 * 1024))
  status @?= 413
  assertEqual "the inner application must not be reached" False reached

-- | A body within the cap passes through untouched.
testKnownSmallBodyPassesThrough :: TestTree
testKnownSmallBodyPassesThrough = testCase "a small Content-Length passes through" do
  (status, reached) <- runBodyLimit (KnownLength 512)
  status @?= 200
  assertEqual "the inner application handled it" True reached

-- | A chunked body declares no length; the documented caveat is that it passes through.
testChunkedBodyPassesThrough :: TestTree
testChunkedBodyPassesThrough = testCase "a chunked body passes through (documented caveat)" do
  (status, reached) <- runBodyLimit ChunkedBody
  status @?= 200
  assertEqual "the inner application handled it" True reached

-- | Drive 'bodyLimitMiddleware' with a 1 MiB cap over a request declaring @len@, reporting the
-- response status and whether the inner application ran.
runBodyLimit :: RequestBodyLength -> IO (Int, Bool)
runBodyLimit len = do
  reachedRef <- newIORef False
  statusRef <- newIORef (0 :: Int)
  let cap = 1024 * 1024 :: Word64
      req = defaultRequest {requestBodyLength = len}
      innerApp _r respond = writeIORef reachedRef True >> respond okResponse
      capture :: Response -> IO ResponseReceived
      capture res = writeIORef statusRef (statusCode (responseStatus res)) >> pure ResponseReceived
  ResponseReceived <- bodyLimitMiddleware cap innerApp req capture
  (,) <$> readIORef statusRef <*> readIORef reachedRef

okResponse :: Response
okResponse = responseLBS status200 [] "ok"
