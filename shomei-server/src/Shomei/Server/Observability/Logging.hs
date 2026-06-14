{- | Request-ID + structured-JSON request logging WAI 'Middleware' (EP-3, M1).

This is the OUTERMOST middleware in the server's WAI stack (IP-4): every request — including
any EP-2's rate limiter rejects with 429 — produces exactly one structured log line on stdout
carrying a correlation id. The correlation id (a short unique @request_id@) is taken from an
incoming @X-Request-Id@ header (sanitized to defeat log injection) or generated, and echoed
back in the @X-Request-Id@ response header.

Logging hygiene (a hard rule): the line is built ONLY from the request method, path, response
status, wall-clock duration, and the peer IP. It never reads request/response bodies or
sensitive headers (Authorization, Cookie), so no password, token, or cookie can leak.
-}
module Shomei.Server.Observability.Logging (
    requestLoggingMiddleware,
) where

import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.IO (stdout)
import Network.HTTP.Types (Status (statusCode))
import Network.Socket (SockAddr (..), hostAddressToTuple)
import Network.Wai (
    Middleware,
    Request,
    mapResponseHeaders,
    rawPathInfo,
    remoteHost,
    requestHeaders,
    requestMethod,
    responseStatus,
 )

import Shomei.Config (LogFormat (..), ObservabilityConfig (..))

requestLoggingMiddleware :: ObservabilityConfig -> Middleware
requestLoggingMiddleware cfg app req respond
    | not cfg.requestLoggingEnabled = app req respond
    | otherwise = do
        reqId <- resolveRequestId req
        start <- getMonotonicTimeNSec
        app req \res -> do
            received <- respond (mapResponseHeaders (("X-Request-Id", reqId) :) res)
            end <- getMonotonicTimeNSec
            emit cfg.logFormat (lineFields reqId req (statusCode (responseStatus res)) (durationMs start end))
            pure received

-- | The fields every line carries, in a stable order.
lineFields :: ByteString -> Request -> Int -> Double -> [(Key, Value)]
lineFields reqId req status durMs =
    [ "level" .= ("info" :: Text)
    , "msg" .= ("request" :: Text)
    , "request_id" .= decodeUtf8Lenient reqId
    , "method" .= decodeUtf8Lenient (requestMethod req)
    , "path" .= decodeUtf8Lenient (rawPathInfo req)
    , "status" .= status
    , "duration_ms" .= durMs
    , "client_ip" .= clientIp req
    ]

emit :: LogFormat -> [(Key, Value)] -> IO ()
emit fmt fields = BL.hPut stdout (render fmt fields <> "\n")
  where
    render LogJson fs = encode (object fs)
    render LogPlain fs =
        BL.fromStrict (BC.pack (Text.unpack (Text.intercalate " " [Key.toText k <> "=" <> renderVal v | (k, v) <- fs])))
    renderVal v = Text.filter (/= '"') (decodeUtf8Lenient (BL.toStrict (encode v)))

durationMs :: Word64 -> Word64 -> Double
durationMs start end = fromIntegral (end - start) / 1_000_000

{- | The correlation id: a sanitized incoming @X-Request-Id@, or a freshly generated
@req_<uuid>@. Sanitizing (allow only @[A-Za-z0-9_.:-]@, cap length) stops a malicious client
from injecting a newline and forging a second log line.
-}
resolveRequestId :: Request -> IO ByteString
resolveRequestId req =
    case lookup "X-Request-Id" (requestHeaders req) of
        Just raw | not (BS.null cleaned) -> pure cleaned
          where
            cleaned = sanitize raw
        _ -> do
            u <- UUIDv4.nextRandom
            pure ("req_" <> BC.filter (/= '-') (BC.pack (UUID.toString u)))
  where
    sanitize = BS.take 64 . BC.filter allowed
    allowed c = c `elem` ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-" :: String)

-- | The peer host as text (dotted-quad for IPv4), with the ephemeral port dropped.
clientIp :: Request -> Text
clientIp req = case remoteHost req of
    SockAddrInet _ host ->
        let (a, b, c, d) = hostAddressToTuple host
         in Text.intercalate "." (map (Text.pack . show) [a, b, c, d])
    SockAddrInet6 _ _ host _ -> Text.pack (show host)
    other -> Text.pack (show other)
