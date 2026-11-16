-- | Protocol ownership at the HTTP boundary, shared by routing and outer middleware.
module Shomei.OAuth.Boundary
  ( OAuthMounts,
    oauthMounts,
    defaultOAuthMounts,
    isOAuthPath,
    oauthBoundaryError,
    oauthBoundaryResponse,
  )
where

import Data.ByteString.Char8 qualified as BS8
import Data.List (isPrefixOf)
import Network.HTTP.Types (mkStatus)
import Network.Wai (Response, responseLBS)
import Servant (ServerError (..))
import Shomei.Prelude
import Shomei.Servant.OAuth (oauthError)

-- | Full decoded namespace prefixes. Construction rejects empty mounts and segments.
newtype OAuthMounts = OAuthMounts [[Text]]
  deriving stock (Eq, Show)

oauthMounts :: [[Text]] -> Either Text OAuthMounts
oauthMounts mounts
  | any (\segments -> null segments || any (== "") segments) mounts = Left "OAuth mounts must contain non-empty path segments"
  | otherwise = Right (OAuthMounts mounts)

defaultOAuthMounts :: OAuthMounts
defaultOAuthMounts = OAuthMounts [["oauth"]]

isOAuthPath :: OAuthMounts -> [Text] -> Bool
isOAuthPath (OAuthMounts mounts) segments = any (`isPrefixOf` segments) mounts

-- | Fixed descriptions deliberately exclude submitted values and parser diagnostics.
-- 413/429 are operational extensions using the OAuth envelope.
oauthBoundaryError :: Int -> ServerError
oauthBoundaryError code =
  let (reason, errorCode, description) = case code of
        404 -> ("Not Found", "invalid_request", "OAuth resource not found")
        405 -> ("Method Not Allowed", "invalid_request", "method not allowed")
        406 -> ("Not Acceptable", "invalid_request", "requested response representation is not supported")
        413 -> ("Payload Too Large", "invalid_request", "request body too large")
        415 -> ("Unsupported Media Type", "invalid_request", "request content type is not supported")
        429 -> ("Too Many Requests", "temporarily_unavailable", "request rate limit exceeded")
        _ -> ("Bad Request", "invalid_request", "request could not be parsed")
      err = oauthError (mkStatus code reason) errorCode description
   in err {errHeaders = err.errHeaders <> [("Retry-After", "60") | code == 429]}

oauthBoundaryResponse :: Int -> Response
oauthBoundaryResponse code =
  let err = oauthBoundaryError code
   in responseLBS (mkStatus err.errHTTPCode (BS8.pack err.errReasonPhrase)) err.errHeaders err.errBody
