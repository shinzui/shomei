-- | The WAI layer that finishes what @ErrorFormatters@ cannot.
--
-- Servant lets you format its body-parse, url-parse, header-parse, and not-found failures
-- through 'Servant.ErrorFormatters'. It does __not__ let you format a method mismatch: a request
-- to a known path with the wrong verb raises a hardcoded @err405@ with an empty body from
-- @Servant.Server.Internal.methodCheck@, below any hook. This middleware converts that response
-- into the same RFC 7807 problem document every other failure carries.
--
-- Shōmei never returns 405 from a handler, so rewriting the status unconditionally is safe.
module Shomei.Servant.Middleware
  ( problemMiddleware,
    problemResponse,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Network.HTTP.Types (Status, mkStatus, statusCode)
import Network.Wai (Middleware, Response, responseLBS, responseStatus)
import Servant (ServerError (..))
import Shomei.Prelude
import Shomei.Servant.Error (ProblemSpec (..), pcMethodNotAllowed, problemBody, problemHeaders)

-- | Build a WAI response carrying a problem document. Used by this module and by the
-- rate-limit middleware, which answers before Servant ever sees the request.
problemResponse :: ProblemSpec -> Maybe Text -> Response
problemResponse spec mDetail =
  responseLBS (statusOf spec) (problemHeaders spec) (Aeson.encode (problemBody spec mDetail))

statusOf :: ProblemSpec -> Status
statusOf spec = mkStatus spec.problemStatus.errHTTPCode (BS8.pack spec.problemStatus.errReasonPhrase)

-- | Rewrite Servant's bare @405 Method Not Allowed@ into a problem document.
problemMiddleware :: Middleware
problemMiddleware app req respond =
  app req \res ->
    respond
      if statusCode (responseStatus res) == 405
        then problemResponse pcMethodNotAllowed Nothing
        else res
