-- | Complete Servant's parsing hooks with protocol-aware method and negotiation errors.
-- Namespace matching uses the original decoded path at this outer boundary. Responses
-- already carrying OAuth JSON pass through; no response body or stream is inspected.
module Shomei.Servant.Middleware
  ( problemMiddleware,
    problemResponse,
    problemMiddlewareWithOAuthMounts,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Network.HTTP.Types (Status, mkStatus, statusCode)
import Network.Wai (Middleware, Response, pathInfo, requestHeaders, responseHeaders, responseLBS, responseStatus)
import Servant (ServerError (..))
import Shomei.OAuth.Boundary (OAuthMounts, defaultOAuthMounts, isOAuthPath, oauthBoundaryError, oauthBoundaryResponse)
import Shomei.Servant.Error (ProblemOccurrence, ProblemSpec (..), bearerOccurrence, noProblemOccurrence, pcMethodNotAllowed, pcTokenInvalidAuth, problemBody, problemHeaders)

-- | Build a WAI response carrying a problem document. Used by this module and by the
-- rate-limit middleware, which answers before Servant ever sees the request.
problemResponse :: ProblemSpec -> ProblemOccurrence -> Response
problemResponse spec occurrence =
  responseLBS (statusOf spec) (problemHeaders occurrence) (Aeson.encode (problemBody spec occurrence))

statusOf :: ProblemSpec -> Status
statusOf spec = mkStatus spec.problemStatus.errHTTPCode (BS8.pack spec.problemStatus.errReasonPhrase)

-- | Complete Servant's formatter hooks without inspecting downstream bodies or streams.
problemMiddleware :: Middleware
problemMiddleware = problemMiddlewareWithOAuthMounts defaultOAuthMounts

problemMiddlewareWithOAuthMounts :: OAuthMounts -> Middleware
problemMiddlewareWithOAuthMounts mounts app req respond
  | length [() | (name, _) <- requestHeaders req, name == "Authorization"] > 1 =
      respond
        if isOAuthPath mounts (pathInfo req)
          then oauthBoundaryResponse 400
          else problemResponse pcTokenInvalidAuth bearerOccurrence
  | otherwise = app req \res -> respond (normalize res)
  where
    normalize res
      | isOAuthPath mounts (pathInfo req), Just contentType <- lookup "Content-Type" (responseHeaders res), BS8.takeWhile (/= ';') contentType == "application/json" = res
      | isOAuthPath mounts (pathInfo req),
        code `elem` [404, 405, 406, 415] =
          let err = oauthBoundaryError code
              -- Retain semantic headers (e.g. Allow), discard the replaced representation.
              semantic = filter (\(name, _) -> name `notElem` ["Content-Type", "Content-Length", "Content-Encoding", "Content-Range", "Content-Language", "Content-Location", "Content-Disposition", "Content-MD5", "Content-Digest", "Repr-Digest", "Digest", "Transfer-Encoding", "Trailer", "Accept-Ranges", "ETag", "Last-Modified", "Cache-Control", "Pragma", "WWW-Authenticate", "Retry-After"]) (responseHeaders res)
           in responseLBS (responseStatus res) (err.errHeaders <> semantic) err.errBody
      | code == 405 = problemResponse pcMethodNotAllowed noProblemOccurrence
      | otherwise = res
      where
        code = statusCode (responseStatus res)
