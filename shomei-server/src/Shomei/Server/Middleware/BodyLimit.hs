-- | Refuse oversized request bodies before they reach a handler (EP-4).
--
-- Nothing else in the stack bounds how much a client may send: warp has no request-body size
-- setting (body limiting is a middleware concern), and Shōmei's JSON handlers happily begin
-- consuming whatever arrives. This middleware answers HTTP 413 to any request that declares a
-- @Content-Length@ above the cap, without reading a byte of the body.
--
-- __Caveat: chunked bodies bypass the cap.__ A request whose 'requestBodyLength' is
-- 'ChunkedBody' declares no length, so there is nothing to compare and it passes through. This
-- is deliberate rather than accidental: every legitimate Shōmei client sends @Content-Length@
-- (the JSON request bodies are a few hundred bytes), so the known-length check covers the real
-- API surface, and bounding a chunked body means metering the body-reading action itself. If
-- that ever matters, @wai-extra@'s @Network.Wai.Middleware.RequestSizeLimit@ does exactly that
-- and is the upgrade path; it is not a dependency today, and the house convention is to avoid
-- adding one for code this small and this testable.
module Shomei.Server.Middleware.BodyLimit
  ( bodyLimitMiddleware,
    defaultBodyLimitBytes,
  )
where

import Data.Word (Word64)
import Network.HTTP.Types (status413)
import Network.Wai
  ( Middleware,
    RequestBodyLength (KnownLength),
    requestBodyLength,
    responseLBS,
  )

-- | 1 MiB. Three orders of magnitude above the largest legitimate Shōmei request body (a
-- WebAuthn attestation), and small enough that a flood of maximal bodies cannot exhaust memory.
defaultBodyLimitBytes :: Word64
defaultBodyLimitBytes = 1024 * 1024

-- | Reject requests declaring a @Content-Length@ strictly greater than @limit@ with
-- @413 {"error":"payload_too_large"}@; pass everything else through untouched.
bodyLimitMiddleware :: Word64 -> Middleware
bodyLimitMiddleware limit app req respond
  | KnownLength n <- requestBodyLength req, n > limit = respond tooLarge
  | otherwise = app req respond
  where
    tooLarge =
      responseLBS
        status413
        [("Content-Type", "application/json")]
        "{\"error\":\"payload_too_large\"}"
