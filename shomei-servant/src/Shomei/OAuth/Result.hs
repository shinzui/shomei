{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | RFC 6749/OIDC response sums. These deliberately do not mention 'ProblemDetails'.
module Shomei.OAuth.Result
  ( OAuthErrorHeaders,
    OAuthErrorWithHeaders (..),
    OAuthErrorResponses,
    OAuthResponses,
    OAuthEmptyResponses,
    OAuthResult (..),
    AuthorizeHeaders,
    AuthorizeRedirect (..),
    TokenHeaders,
    TokenSuccess (..),
    AuthorizeResponses,
    AuthorizeResult,
    TokenResponses,
    TokenResult,
    UserinfoResponses,
    UserinfoResult,
    IntrospectResponses,
    IntrospectResult,
    RevokeResponses,
    RevokeResult,
    OidcDiscoveryResponses,
    OidcDiscoveryResult,
    oauthServerErrorResult,
  )
where

import Data.Aeson (Value, eitherDecode)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.SOP (I (..), NP (..), NS (..))
import Data.Sequence (Seq)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types qualified as HTTP
import Numeric.Natural (Natural)
import Servant (JSON, ServerError (..))
import Servant.API.MultiVerb
import Shomei.Prelude
import Shomei.Servant.OAuth (OAuthErrorResponse (..), TokenResponse)
import Text.Read (readMaybe)
import Web.HttpApiData (FromHttpApiData (parseHeader), ToHttpApiData (toHeader))

type OAuthErrorHeaders =
  '[ DescHeader "Cache-Control" "OAuth responses are not cacheable" Text,
     DescHeader "Pragma" "OAuth responses are not cacheable" Text,
     OptHeader (DescHeader "WWW-Authenticate" "Client authentication challenge" Text),
     OptHeader (DescHeader "Retry-After" "Seconds until retry" Natural)
   ]

data OAuthErrorWithHeaders = OAuthErrorWithHeaders
  { oauthErrorBody :: !OAuthErrorResponse,
    oauthCacheControl :: !Text,
    oauthPragma :: !Text,
    oauthAuthenticate :: !(Maybe Text),
    oauthRetryAfter :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

instance AsHeaders '[Text, Text, Maybe Text, Maybe Natural] OAuthErrorResponse OAuthErrorWithHeaders where
  toHeaders response =
    ( I response.oauthCacheControl :* I response.oauthPragma :* I response.oauthAuthenticate :* I response.oauthRetryAfter :* Nil,
      response.oauthErrorBody
    )
  fromHeaders (I oauthCacheControl :* I oauthPragma :* I oauthAuthenticate :* I oauthRetryAfter :* Nil, oauthErrorBody) =
    OAuthErrorWithHeaders {oauthErrorBody, oauthCacheControl, oauthPragma, oauthAuthenticate, oauthRetryAfter}

-- servant 0.20.3's generic header decoder rejects absent optional fields. OAuth explicitly
-- permits WWW-Authenticate and Retry-After to be absent, so preserve that contract in clients.
instance {-# OVERLAPPING #-} ServantHeaders OAuthErrorHeaders '[Text, Text, Maybe Text, Maybe Natural] where
  constructHeaders (I oauthCacheControl :* I oauthPragma :* I oauthAuthenticate :* I oauthRetryAfter :* Nil) =
    requiredHeader "Cache-Control" oauthCacheControl
      <> requiredHeader "Pragma" oauthPragma
      <> optionalHeader "WWW-Authenticate" oauthAuthenticate
      <> optionalHeader "Retry-After" oauthRetryAfter
  extractHeaders headers = do
    oauthCacheControl <- extractRequiredHeader "Cache-Control" headers
    oauthPragma <- extractRequiredHeader "Pragma" headers
    oauthAuthenticate <- extractOptionalHeader "WWW-Authenticate" headers
    oauthRetryAfter <- extractOptionalHeader "Retry-After" headers
    pure (I oauthCacheControl :* I oauthPragma :* I oauthAuthenticate :* I oauthRetryAfter :* Nil)

requiredHeader :: (ToHttpApiData a) => HTTP.HeaderName -> a -> [HTTP.Header]
requiredHeader name value = [(name, toHeader value)]

optionalHeader :: (ToHttpApiData a) => HTTP.HeaderName -> Maybe a -> [HTTP.Header]
optionalHeader name = maybe [] (requiredHeader name)

extractRequiredHeader :: (FromHttpApiData a) => HTTP.HeaderName -> Seq HTTP.Header -> Maybe a
extractRequiredHeader name headers = case matchingHeaderValues name headers of
  [value] -> decodeHeader value
  _ -> Nothing

extractOptionalHeader :: (FromHttpApiData a) => HTTP.HeaderName -> Seq HTTP.Header -> Maybe (Maybe a)
extractOptionalHeader name headers = case matchingHeaderValues name headers of
  [] -> Just Nothing
  [value] -> Just <$> decodeHeader value
  _ -> Nothing

matchingHeaderValues :: HTTP.HeaderName -> Seq HTTP.Header -> [ByteString]
matchingHeaderValues name = map snd . filter ((== name) . fst) . toList

decodeHeader :: (FromHttpApiData a) => ByteString -> Maybe a
decodeHeader = either (const Nothing) Just . parseHeader

type OAuthErrorResponses =
  '[ WithHeaders OAuthErrorHeaders OAuthErrorWithHeaders (RespondAs JSON 400 "OAuth request rejected" OAuthErrorResponse),
     WithHeaders OAuthErrorHeaders OAuthErrorWithHeaders (RespondAs JSON 401 "OAuth authentication failed" OAuthErrorResponse),
     WithHeaders OAuthErrorHeaders OAuthErrorWithHeaders (RespondAs JSON 404 "OAuth resource not found" OAuthErrorResponse),
     WithHeaders OAuthErrorHeaders OAuthErrorWithHeaders (RespondAs JSON 500 "OAuth server error" OAuthErrorResponse),
     WithHeaders OAuthErrorHeaders OAuthErrorWithHeaders (RespondAs JSON 503 "OAuth dependency unavailable" OAuthErrorResponse)
   ]

type OAuthResponses status description body = Respond status description body ': OAuthErrorResponses

type OAuthEmptyResponses status description = RespondEmpty status description ': OAuthErrorResponses

data OAuthResult a
  = OAuthSuccess !a
  | OAuthBadRequest !OAuthErrorWithHeaders
  | OAuthAuthenticationFailed !OAuthErrorWithHeaders
  | OAuthNotFound !OAuthErrorWithHeaders
  | OAuthInternal !OAuthErrorWithHeaders
  | OAuthUnavailable !OAuthErrorWithHeaders
  deriving stock (Eq, Show, Generic, Functor)

instance AsUnion (Respond status description a ': OAuthErrorResponses) (OAuthResult a) where
  toUnion = oauthToUnion
  fromUnion = oauthFromUnion

instance AsUnion (RespondEmpty status description ': OAuthErrorResponses) (OAuthResult ()) where
  toUnion = oauthToUnion
  fromUnion = oauthFromUnion

instance AsUnion (WithHeaders headers a response ': OAuthErrorResponses) (OAuthResult a) where
  toUnion = oauthToUnion
  fromUnion = oauthFromUnion

oauthToUnion :: OAuthResult a -> NS I '[a, OAuthErrorWithHeaders, OAuthErrorWithHeaders, OAuthErrorWithHeaders, OAuthErrorWithHeaders, OAuthErrorWithHeaders]
oauthToUnion = \case
  OAuthSuccess value -> Z (I value)
  OAuthBadRequest value -> S (Z (I value))
  OAuthAuthenticationFailed value -> S (S (Z (I value)))
  OAuthNotFound value -> S (S (S (Z (I value))))
  OAuthInternal value -> S (S (S (S (Z (I value)))))
  OAuthUnavailable value -> S (S (S (S (S (Z (I value))))))

oauthFromUnion :: NS I '[a, OAuthErrorWithHeaders, OAuthErrorWithHeaders, OAuthErrorWithHeaders, OAuthErrorWithHeaders, OAuthErrorWithHeaders] -> OAuthResult a
oauthFromUnion = \case
  Z (I value) -> OAuthSuccess value
  S (Z (I value)) -> OAuthBadRequest value
  S (S (Z (I value))) -> OAuthAuthenticationFailed value
  S (S (S (Z (I value)))) -> OAuthNotFound value
  S (S (S (S (Z (I value))))) -> OAuthInternal value
  S (S (S (S (S (Z (I value)))))) -> OAuthUnavailable value
  S (S (S (S (S (S impossible))))) -> case impossible of {}

type AuthorizeHeaders =
  '[ DescHeader "Location" "Redirect target" Text,
     DescHeader "Cache-Control" "Authorization redirects are not cacheable" Text
   ]

data AuthorizeRedirect = AuthorizeRedirect
  { authorizeLocation :: !Text,
    authorizeCacheControl :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance AsHeaders '[Text, Text] () AuthorizeRedirect where
  toHeaders response = (I response.authorizeLocation :* I response.authorizeCacheControl :* Nil, ())
  fromHeaders (I authorizeLocation :* I authorizeCacheControl :* Nil, ()) = AuthorizeRedirect {authorizeLocation, authorizeCacheControl}

type TokenHeaders =
  '[ DescHeader "Cache-Control" "Token responses are not cacheable" Text,
     DescHeader "Pragma" "Token responses are not cacheable" Text
   ]

data TokenSuccess = TokenSuccess
  { tokenBody :: !TokenResponse,
    tokenCacheControl :: !Text,
    tokenPragma :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance AsHeaders '[Text, Text] TokenResponse TokenSuccess where
  toHeaders response = (I response.tokenCacheControl :* I response.tokenPragma :* Nil, response.tokenBody)
  fromHeaders (I tokenCacheControl :* I tokenPragma :* Nil, tokenBody) = TokenSuccess {tokenBody, tokenCacheControl, tokenPragma}

type AuthorizeResponses = WithHeaders AuthorizeHeaders AuthorizeRedirect (RespondEmpty 302 "Redirect") ': OAuthErrorResponses

type AuthorizeResult = OAuthResult AuthorizeRedirect

type TokenResponses = WithHeaders TokenHeaders TokenSuccess (Respond 200 "Token issued" TokenResponse) ': OAuthErrorResponses

type TokenResult = OAuthResult TokenSuccess

type UserinfoResponses = OAuthResponses 200 "OIDC user information" Value

type UserinfoResult = OAuthResult Value

type IntrospectResponses = OAuthResponses 200 "Token status" Value

type IntrospectResult = OAuthResult Value

type RevokeResponses = OAuthEmptyResponses 200 "Token revoked"

type RevokeResult = OAuthResult ()

type OidcDiscoveryResponses = OAuthResponses 200 "OIDC discovery document" Value

type OidcDiscoveryResult = OAuthResult Value

oauthServerErrorResult :: ServerError -> OAuthResult a
oauthServerErrorResult err = constructor response
  where
    body =
      fromMaybe
        (OAuthErrorResponse "server_error" "the authorization server encountered an unexpected condition")
        (either (const Nothing) Just (eitherDecode err.errBody))
    response =
      OAuthErrorWithHeaders
        { oauthErrorBody = body,
          oauthCacheControl = headerText "Cache-Control" "no-store",
          oauthPragma = headerText "Pragma" "no-cache",
          oauthAuthenticate = optionalHeaderText "WWW-Authenticate",
          oauthRetryAfter = optionalHeaderText "Retry-After" >>= readMaybe . Text.unpack
        }
    constructor = case err.errHTTPCode of
      400 -> OAuthBadRequest
      401 -> OAuthAuthenticationFailed
      404 -> OAuthNotFound
      503 -> OAuthUnavailable
      _ -> OAuthInternal
    optionalHeaderText name = TextEncoding.decodeUtf8 <$> lookup name err.errHeaders
    headerText name fallback = fromMaybe fallback (optionalHeaderText name)
