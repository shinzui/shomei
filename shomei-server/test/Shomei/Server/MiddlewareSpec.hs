-- | Tests for the standalone server's edge middleware. All of them are database-free: the
-- rate limiter takes its clock as an argument, the metrics registry is plain 'IORef's, and the
-- WAI middlewares are just functions we can apply to a 'defaultRequest'.
module Shomei.Server.MiddlewareSpec (tests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (..), SomeException, evaluate, throwIO, toException, try)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (Object, String), decode, decodeStrict, (.=))
import Data.Aeson.Key (Key)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Word (Word16, Word64, Word8)
import Network.HTTP.Types (hContentType, methodDelete, methodPost, statusCode)
import Network.HTTP.Types.Status (status200)
import Network.Socket (SockAddr (..), tupleToHostAddress, tupleToHostAddress6)
import Network.Wai (Request (..), RequestBodyLength (..), Response, defaultRequest, getRequestBodyChunk, responseHeaders, responseLBS, responseStatus, responseToStream, setRequestBodyChunks)
import Network.Wai.Handler.Warp (InvalidRequest (BadFirstLine, PayloadTooLarge))
import Network.Wai.Internal (ResponseReceived (..))
import Servant.Health.Paths (healthRawPaths)
import Shomei.Config (LogFormat (..), RateLimitConfig (..), defaultObservabilityConfig, defaultRateLimitConfig)
import Shomei.Servant.Api (shomeiThrottledRoutes)
import Shomei.Servant.ClientIp (clientIpText)
import Shomei.Servant.Error (ProblemDetails (..))
import Shomei.Servant.Throttle (PathSegment (Literal), ThrottledRoute (..))
import Shomei.Server.ExceptionResponse (problemExceptionResponse)
import Shomei.Server.Middleware.BodyLimit (bodyLimitMiddleware)
import Shomei.Server.Middleware.RateLimit (bucketCount, newRateLimiterWith, takeToken, throttledPath)
import Shomei.Server.Middleware.TrustedProxy (parseTrustedProxies, trustedProxyMiddleware)
import Shomei.Server.Observability.Logging (emitLine, renderLogLine, requestLoggingMiddleware, serverErrorLine)
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
        "trusted proxies"
        [ testUntrustedPeerIgnoresForwardedFor,
          testTrustedPeerUsesRightmostUntrustedHop,
          testSpoofedForwardedHopIsIgnored,
          testAllTrustedHopsUseOrigin,
          testInvalidTrustedProxyRefused
        ],
      testGroup
        "client ip rendering"
        [ testIpv4Rendering,
          testIpv6Rendering
        ],
      testGroup
        "rate limiter"
        [ testIdleBucketsEvicted,
          testDrainedBucketSurvivesSweep,
          testBucketMapStaysBounded,
          testThrottledPathsAreVersioned
        ],
      testGroup
        "metrics"
        [ testThrowingHandlerLeavesGaugeAtZero,
          testNormalRequestCountedAndGaugeReturnsToZero,
          testHostileMethodsShareTheBoundedSeries
        ],
      testGroup
        "logging"
        [ testRenderLogLineIsOneJsonLine,
          testPlainFormatStripsControlCharacters,
          testConcurrentWritersProduceIntactLines,
          testServerErrorLineIsStructured,
          testHealthRequestsSkipLogging
        ],
      testGroup
        "body limit"
        [ testOversizedBodyRejected,
          testKnownSmallBodyPassesThrough,
          testChunkedBodyOverCapRejected,
          testSmallChunkedBodyPassesThrough,
          testEscapedExceptionRendersProblem,
          testWarpInvalidRequestsRenderProblems,
          testAsyncExceptionIsRethrown
        ]
    ]

-- Trusted proxies and canonical client identity --------------------------------

testUntrustedPeerIgnoresForwardedFor :: TestTree
testUntrustedPeerIgnoresForwardedFor = testCase "an untrusted peer's X-Forwarded-For is ignored" do
  actual <- observedClient ["10.0.0.0/8"] (ipv4 198 51 100 9) "203.0.113.7"
  actual @?= "198.51.100.9"

testTrustedPeerUsesRightmostUntrustedHop :: TestTree
testTrustedPeerUsesRightmostUntrustedHop = testCase "a trusted peer yields the rightmost untrusted hop" do
  actual <- observedClient ["10.0.0.0/8"] (ipv4 10 0 0 5) "203.0.113.7, 10.0.0.6"
  actual @?= "203.0.113.7"

testSpoofedForwardedHopIsIgnored :: TestTree
testSpoofedForwardedHopIsIgnored = testCase "a spoofed hop behind a trusted proxy is not the client" do
  actual <- observedClient ["10.0.0.0/8"] (ipv4 10 0 0 5) "1.2.3.4, 203.0.113.7"
  actual @?= "203.0.113.7"

testAllTrustedHopsUseOrigin :: TestTree
testAllTrustedHopsUseOrigin = testCase "every hop trusted falls back to the chain's origin" do
  actual <- observedClient ["10.0.0.0/8"] (ipv4 10 0 0 5) "10.0.0.1, 10.0.0.2"
  actual @?= "10.0.0.1"

testInvalidTrustedProxyRefused :: TestTree
testInvalidTrustedProxyRefused = testCase "an invalid trusted-proxy entry is refused" do
  case parseTrustedProxies ["10.0.0.0/8", "nope"] of
    Left _ -> pure ()
    Right _ -> fail "expected the invalid proxy entry to be rejected"

testIpv4Rendering :: TestTree
testIpv4Rendering = testCase "IPv4 renders as a dotted quad" do
  clientIpText (ipv4 127 0 0 1) @?= "127.0.0.1"

testIpv6Rendering :: TestTree
testIpv6Rendering = testCase "IPv6 renders per RFC 5952" do
  clientIpText (ipv6 (0x2001, 0x0db8, 0, 0, 0, 0, 0, 1)) @?= "2001:db8::1"
  clientIpText (ipv6 (0, 0, 0, 0, 0, 0, 0, 1)) @?= "::1"
  clientIpText (ipv6 (0x2001, 0x0db8, 0, 1, 0, 0, 0, 0)) @?= "2001:db8:0:1::"
  clientIpText (ipv6 (0x2001, 0, 0, 1, 0, 0, 0, 1)) @?= "2001:0:0:1::1"

observedClient :: [Text] -> SockAddr -> ByteString -> IO Text
observedClient proxyRanges peer forwarded = do
  proxies <- either (fail . show) pure (parseTrustedProxies proxyRanges)
  observed <- newIORef ""
  let req =
        defaultRequest
          { remoteHost = peer,
            requestHeaders = [("X-Forwarded-For", forwarded)]
          }
      inner request' respond = writeIORef observed (clientIpText (remoteHost request')) >> respond okResponse
  ResponseReceived <- trustedProxyMiddleware proxies inner req (const (pure ResponseReceived))
  readIORef observed

ipv4 :: Word8 -> Word8 -> Word8 -> Word8 -> SockAddr
ipv4 a b c d = SockAddrInet 4711 (tupleToHostAddress (a, b, c, d))

ipv6 :: (Word16, Word16, Word16, Word16, Word16, Word16, Word16, Word16) -> SockAddr
ipv6 groups = SockAddrInet6 4711 0 (tupleToHostAddress6 groups) 0

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

-- | Pin the API-derived set to the credential proofs documented for operators. Adding or moving a
-- 'RateLimited' marker changes this value automatically and makes the conformance assertion fail
-- until the documentation and threat-model inventory are reviewed together.
testThrottledPathsAreVersioned :: TestTree
testThrottledPathsAreVersioned = testCase "the derived throttled set matches every credential proof" do
  let actual = Set.fromList shomeiThrottledRoutes
      expected =
        Set.fromList
          [ postRoute ["v1", "auth", "login"],
            postRoute ["v1", "auth", "signup"],
            postRoute ["v1", "auth", "refresh"],
            postRoute ["v1", "auth", "mfa", "complete"],
            postRoute ["v1", "auth", "login", "passkey", "begin"],
            postRoute ["v1", "auth", "login", "passkey", "complete"],
            postRoute ["v1", "auth", "password", "change"],
            postRoute ["v1", "auth", "verify-email", "request"],
            postRoute ["v1", "auth", "verify-email", "confirm"],
            postRoute ["v1", "auth", "password-reset", "request"],
            postRoute ["v1", "auth", "password-reset", "confirm"],
            route methodDelete ["v1", "auth", "totp"],
            postRoute ["oauth", "token"]
          ]
  assertEqual "the marker-derived operation set" expected actual
  assertEqual "no derived operation is duplicated" (Set.size actual) (length shomeiThrottledRoutes)
  rl <- newRateLimiterWith 8 testLimiterConfig
  assertBool
    "the unversioned login path is not throttled (it no longer exists)"
    (not (throttledPath rl (request methodPost ["auth", "login"])))
  assertBool
    "authenticated routes are not throttled"
    (not (throttledPath rl (request methodPost ["v1", "auth", "logout"])))
  assertBool
    "GET is not throttled"
    (not (throttledPath rl (request "GET" ["v1", "auth", "login"])))
  where
    route method segments = ThrottledRoute method (Literal <$> segments)
    postRoute = route methodPost
    request method segments = defaultRequest {requestMethod = method, pathInfo = segments}

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

testHostileMethodsShareTheBoundedSeries :: TestTree
testHostileMethodsShareTheBoundedSeries = testCase "a hostile method is labelled other and escaped" do
  m <- newMetrics
  let okApp _req respond = respond (responseLBS status200 [] "ok")
      record method =
        metricsMiddleware m okApp defaultRequest {requestMethod = method} (\_ -> pure ResponseReceived)
  ResponseReceived <- record "EVIL\"}"
  ResponseReceived <- record "BREW"
  body <- exportMetrics m
  assertMetricLine "http_requests_total{method=\"other\",status=\"200\"} 2" body
  assertBool "the hostile method is not emitted as a label value" (not ("EVIL" `BS.isInfixOf` BL.toStrict body))

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

testHealthRequestsSkipLogging :: TestTree
testHealthRequestsSkipLogging = testCase "health paths bypass request logging" do
  let okApp _req respond = respond (responseLBS status200 [] "ok")
  forM_ healthRawPaths \path -> do
    let request = defaultRequest {rawPathInfo = path}
    ResponseReceived <- requestLoggingMiddleware defaultObservabilityConfig okApp request \response -> do
      lookup "X-Request-Id" (responseHeaders response) @?= Nothing
      pure ResponseReceived
    pure ()

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
  let req = defaultRequest {requestMethod = "POST", rawPathInfo = "/v1/auth/login"}
      err = toException (ErrorCall "database is on fire")
      line = serverErrorLine (Just req) err
  case decodeStrict (BS.init line) :: Maybe (Map Text Text) of
    Nothing -> fail ("expected a JSON object, got " <> show line)
    Just obj -> do
      Map.lookup "level" obj @?= Just "error"
      Map.lookup "msg" obj @?= Just "unhandled exception"
      Map.lookup "method" obj @?= Just "POST"
      Map.lookup "path" obj @?= Just "/v1/auth/login"
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

-- | A chunked body is metered as the application consumes it. The third chunk crosses the cap,
-- so the inner application cannot send its success response.
testChunkedBodyOverCapRejected :: TestTree
testChunkedBodyOverCapRejected = testCase "a chunked body over the cap is rejected with 413" do
  (status, innerResponded) <- runChunkedBodyLimit (replicate 3 (BS.replicate (512 * 1024) 97))
  status @?= 413
  assertEqual "the inner success response must not run" False innerResponded

-- | Metering is transparent below the cap, including the end-of-stream marker.
testSmallChunkedBodyPassesThrough :: TestTree
testSmallChunkedBodyPassesThrough = testCase "a small chunked body passes through" do
  (status, innerResponded) <- runChunkedBodyLimit (replicate 2 (BS.replicate (4 * 1024) 97))
  status @?= 200
  assertEqual "the inner application handled it" True innerResponded

-- | Warp's last-resort exception response carries the same public envelope as handler failures.
testEscapedExceptionRendersProblem :: TestTree
testEscapedExceptionRendersProblem = testCase "an escaped exception renders a problem document" do
  assertExceptionProblem 500 "internal" (toException (ErrorCall "database is on fire"))

testWarpInvalidRequestsRenderProblems :: TestTree
testWarpInvalidRequestsRenderProblems = testCase "warp invalid requests retain the problem envelope" do
  assertExceptionProblem 413 "payload_too_large" (toException PayloadTooLarge)
  assertExceptionProblem 400 "bad_request" (toException (BadFirstLine "hostile"))

testAsyncExceptionIsRethrown :: TestTree
testAsyncExceptionIsRethrown = testCase "the exception response hook rethrows asynchronous cancellation" do
  outcome <- try (evaluate (problemExceptionResponse (toException ThreadKilled)))
  case outcome :: Either AsyncException Response of
    Left ThreadKilled -> pure ()
    Left other -> fail ("unexpected async exception: " <> show other)
    Right _ -> fail "the asynchronous exception was converted into a response"

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

-- | Drive an unknown-length body whose chunks are supplied one at a time. The Boolean reports
-- whether the inner application reached its response continuation, not merely whether it began.
runChunkedBodyLimit :: [ByteString] -> IO (Int, Bool)
runChunkedBodyLimit chunks = do
  chunksRef <- newIORef chunks
  innerRespondedRef <- newIORef False
  statusRef <- newIORef (0 :: Int)
  let cap = 1024 * 1024 :: Word64
      nextChunk =
        atomicModifyIORef' chunksRef \case
          [] -> ([], "")
          chunk : rest -> (rest, chunk)
      req = setRequestBodyChunks nextChunk defaultRequest {requestBodyLength = ChunkedBody}
      drain request = do
        chunk <- getRequestBodyChunk request
        unless (BS.null chunk) (drain request)
      innerApp request respond = do
        drain request
        writeIORef innerRespondedRef True
        respond okResponse
      capture res = writeIORef statusRef (statusCode (responseStatus res)) >> pure ResponseReceived
  ResponseReceived <- bodyLimitMiddleware cap innerApp req capture
  (,) <$> readIORef statusRef <*> readIORef innerRespondedRef

collectResponseBody :: Response -> IO BL.ByteString
collectResponseBody response = do
  builderRef <- newIORef mempty
  let (_, _, withBody) = responseToStream response
  withBody \streamBody -> streamBody (\chunk -> modifyIORef' builderRef (<> chunk)) (pure ())
  toLazyByteString <$> readIORef builderRef

assertExceptionProblem :: Int -> Text -> SomeException -> IO ()
assertExceptionProblem expectedStatus expectedCode err = do
  let response = problemExceptionResponse err
  statusCode (responseStatus response) @?= expectedStatus
  lookup hContentType (responseHeaders response) @?= Just "application/problem+json"
  body <- collectResponseBody response
  problem <- maybe (fail ("expected problem JSON, got " <> show body)) pure (decode body :: Maybe ProblemDetails)
  problem.code @?= expectedCode
  problem.status @?= expectedStatus

okResponse :: Response
okResponse = responseLBS status200 [] "ok"
