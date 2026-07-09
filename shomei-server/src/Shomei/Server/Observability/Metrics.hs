-- | A small hand-rolled Prometheus metrics registry and the WAI middleware that records and
-- exposes it (EP-3, M2).
--
-- We deliberately do NOT pull in @prometheus-client@: it is not registered in the project's
-- dependency registry and would add a Hackage build plus transitive deps for what is, here, a
-- handful of counters, one gauge, and one latency histogram. Consistent with this plan's
-- hand-rolled request-logging decision, the registry is plain 'IORef's updated with
-- 'atomicModifyIORef'' and the @/metrics@ body is rendered as Prometheus text exposition by hand.
--
-- Metrics exposed:
--
--   * @http_requests_total{method,status}@ — counter of handled requests.
--   * @http_requests_in_flight@ — gauge of requests currently being handled.
--   * @http_request_duration_seconds@ — latency histogram (fixed buckets) with @_sum@/@_count@.
--   * @shomei_logins_succeeded_total@ / @shomei_logins_failed_total@ /
--     @shomei_tokens_issued_total@ — domain counters derived from the HTTP method/path/status
--     (a @POST /v1/auth/login@ → 200 is a success and issues a token; → 401 is a failure;
--     @POST /v1/auth/signup@ and @/v1/auth/refresh@ → 200 issue a token). This HTTP-derived
--     approach avoids instrumenting the effect stack; see the Decision Log.
module Shomei.Server.Observability.Metrics
  ( Metrics,
    newMetrics,
    metricsMiddleware,
    metricsEndpointMiddleware,
    exportMetrics,
  )
where

import Control.Exception (finally)
import Data.ByteString (ByteString)
import Data.ByteString.Builder (Builder, byteString, doubleDec, intDec, toLazyByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (Status (statusCode), methodGet, status200)
import Network.Wai
  ( Middleware,
    Request,
    rawPathInfo,
    requestMethod,
    responseLBS,
    responseStatus,
  )

data Metrics = Metrics
  { reqTotal :: !(IORef (Map (Text, Int) Int)),
    inFlight :: !(IORef Int),
    durSum :: !(IORef Double),
    durCount :: !(IORef Int),
    durBuckets :: !(IORef (Map Double Int)),
    loginsOk :: !(IORef Int),
    loginsFail :: !(IORef Int),
    tokensIssued :: !(IORef Int)
  }

histogramBuckets :: [Double]
histogramBuckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

newMetrics :: IO Metrics
newMetrics =
  Metrics
    <$> newIORef Map.empty
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef (Map.fromList [(le, 0) | le <- histogramBuckets])
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0

bumpInt :: IORef Int -> Int -> IO ()
bumpInt ref n = atomicModifyIORef' ref (\x -> (x + n, ()))

observeDuration :: Metrics -> Double -> IO ()
observeDuration m secs = do
  bumpInt m.durCount 1
  atomicModifyIORef' m.durSum (\s -> (s + secs, ()))
  atomicModifyIORef' m.durBuckets (\bs -> (Map.mapWithKey (\le c -> if secs <= le then c + 1 else c) bs, ()))

-- | Instrument every request: in-flight gauge, total counter, latency histogram, and the
-- HTTP-derived domain counters.
--
-- The in-flight gauge is decremented in a 'finally', not in the response continuation: an
-- application that throws instead of responding (the infrastructure path — @Shomei.Server.Boot@
-- raises an 'IOError' when the database is unreachable, which flies past this middleware to
-- warp) would otherwise inflate the gauge permanently, and after a week of sporadic 500s the
-- gauge — and every dashboard and alert built on it — reads a fiction. Placing the decrement in
-- the release action rather than alongside the latency observation is what makes it run exactly
-- once on every path, including an async exception delivered after the continuation returned.
--
-- The latency histogram and the request counter deliberately stay in the continuation: a
-- request aborted by an exception produced no response status to label, so it is counted
-- nowhere rather than counted wrong.
metricsMiddleware :: Metrics -> Middleware
metricsMiddleware m app req respond = do
  bumpInt m.inFlight 1
  start <- getPOSIXTime
  let handleResponse res = do
        received <- respond res
        end <- getPOSIXTime
        observeDuration m (realToFrac (end - start))
        recordRequest m req (statusCode (responseStatus res))
        pure received
  app req handleResponse `finally` bumpInt m.inFlight (-1)

recordRequest :: Metrics -> Request -> Int -> IO ()
recordRequest m req status = do
  let method = decodeLatin1 (requestMethod req)
      path = rawPathInfo req
  atomicModifyIORef' m.reqTotal (\mp -> (Map.insertWith (+) (method, status) 1 mp, ()))
  case (requestMethod req, path, status) of
    ("POST", "/v1/auth/login", 200) -> bumpInt m.loginsOk 1 >> bumpInt m.tokensIssued 1
    ("POST", "/v1/auth/login", 401) -> bumpInt m.loginsFail 1
    ("POST", "/v1/auth/signup", 200) -> bumpInt m.tokensIssued 1
    ("POST", "/v1/auth/refresh", 200) -> bumpInt m.tokensIssued 1
    _ -> pure ()

-- | Serve @GET /metrics@ directly (bypassing Servant); pass everything else through.
metricsEndpointMiddleware :: Metrics -> Middleware
metricsEndpointMiddleware m app req respond
  | requestMethod req == methodGet && rawPathInfo req == "/metrics" = do
      body <- exportMetrics m
      respond (responseLBS status200 [("Content-Type", "text/plain; version=0.0.4")] body)
  | otherwise = app req respond

-- | Render the whole registry as Prometheus text exposition.
exportMetrics :: Metrics -> IO BL.ByteString
exportMetrics m = do
  reqs <- readIORef m.reqTotal
  flight <- readIORef m.inFlight
  dsum <- readIORef m.durSum
  dcount <- readIORef m.durCount
  buckets <- readIORef m.durBuckets
  ok <- readIORef m.loginsOk
  failed <- readIORef m.loginsFail
  issued <- readIORef m.tokensIssued
  pure
    ( toLazyByteString
        ( mconcat
            ( reqLines reqs
                <> flightLines flight
                <> histLines dsum dcount buckets
                <> domainLines ok failed issued
            )
        )
    )
  where
    reqLines reqs =
      helpType "http_requests_total" "counter"
        : [ line ("http_requests_total" <> labels [("method", method), ("status", tshow status)]) (intDec n)
          | ((method, status), n) <- Map.toList reqs
          ]
    flightLines flight =
      [ helpType "http_requests_in_flight" "gauge",
        line "http_requests_in_flight" (intDec flight)
      ]
    histLines dsum dcount buckets =
      helpType "http_request_duration_seconds" "histogram"
        : [ line ("http_request_duration_seconds_bucket" <> labels [("le", tshow le)]) (intDec c)
          | (le, c) <- sortOn fst (Map.toList buckets)
          ]
          <> [ line ("http_request_duration_seconds_bucket" <> labels [("le", "+Inf")]) (intDec dcount),
               line "http_request_duration_seconds_sum" (doubleDec dsum),
               line "http_request_duration_seconds_count" (intDec dcount)
             ]
    domainLines ok failed issued =
      [ helpType "shomei_logins_succeeded_total" "counter",
        line "shomei_logins_succeeded_total" (intDec ok),
        helpType "shomei_logins_failed_total" "counter",
        line "shomei_logins_failed_total" (intDec failed),
        helpType "shomei_tokens_issued_total" "counter",
        line "shomei_tokens_issued_total" (intDec issued)
      ]

-- Rendering helpers ----------------------------------------------------------

line :: Builder -> Builder -> Builder
line name val = name <> byteString " " <> val <> byteString "\n"

helpType :: ByteString -> ByteString -> Builder
helpType name ty = byteString "# TYPE " <> byteString name <> byteString " " <> byteString ty <> byteString "\n"

labels :: [(ByteString, Text)] -> Builder
labels [] = mempty
labels ls = byteString "{" <> go ls <> byteString "}"
  where
    go [] = mempty
    go [x] = lbl x
    go (x : xs) = lbl x <> byteString "," <> go xs
    lbl (k, v) = byteString k <> byteString "=\"" <> byteString (encodeUtf8 v) <> byteString "\""

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
