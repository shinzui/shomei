-- | The OAuth2 wire mechanics for @POST \/oauth\/token@ (EP-4): the RFC 6749 §5.2 error shape,
-- client authentication, the success response, and the parameter readers the grant dispatcher
-- in "Shomei.Servant.Handlers" uses.
--
-- __This endpoint does not speak Shōmei's error envelope.__ Everywhere else, a failure is an
-- RFC 7807 problem document (see "Shomei.Servant.Error"). Under @\/oauth\/*@ a failure is
-- RFC 6749 §5.2's @{"error":"invalid_grant","error_description":"…"}@, because that is the shape
-- every stock OAuth2 client — Spring, ASP.NET, Go's @clientcredentials@, @oauth2-proxy@ — parses
-- by field name. Wrapping it would break them, which would defeat the entire point of speaking
-- the standard. The boundary is deliberate and permanent: everything under @\/oauth\/*@ speaks
-- the OAuth wire protocol; everything else speaks the application envelope.
--
-- The RFC 6749 error codes, and the statuses they carry:
--
--   * @invalid_request@ (400) — a required parameter is missing or malformed.
--   * @invalid_client@ (401) — client authentication failed. Also carries
--     @WWW-Authenticate: Basic realm="shomei"@ when the client attempted Basic authentication.
--   * @invalid_grant@ (400) — the presented grant is invalid, expired, or revoked.
--   * @unauthorized_client@ (400) — this client may not use this grant type.
--   * @unsupported_grant_type@ (400) — the server does not implement this @grant_type@.
--   * @invalid_scope@ (400) — the requested scope is malformed or exceeds what the client may hold.
module Shomei.Servant.OAuth
  ( -- * The RFC 6749 §5.2 error shape
    oauthError,
    invalidClient,
    invalidRequest,
    unsupportedGrantType,

    -- * Client authentication (RFC 6749 §2.3.1)
    ClientAuth (..),
    extractClientAuth,

    -- * Request parameters
    lookupParam,
    parseScopeParam,

    -- * The success response (RFC 6749 §5.1)
    TokenResponse (..),
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Base64 qualified as B64
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.Status (Status, status400, status401, statusCode, statusMessage)
import Servant (ServerError (..))
import Shomei.Domain.Claims (Scope (..))
import Shomei.Prelude
import Web.FormUrlEncoded (Form, lookupUnique)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Render an RFC 6749 §5.2 error as a 'ServerError'.
--
-- The body is @{"error":…,"error_description":…}@ with @Content-Type: application\/json@.
-- @Cache-Control: no-store@ rides on every response from this endpoint, error included: an
-- intermediary must never cache a token endpoint's answer.
--
-- A 401 additionally carries @WWW-Authenticate: Basic realm="shomei"@, as RFC 6749 §5.2 requires
-- of an @invalid_client@ response to a request that used the Basic scheme. Shōmei sends it on
-- every @invalid_client@, which is permitted and simpler than remembering how the client tried.
oauthError :: Status -> Text -> Text -> ServerError
oauthError status code description =
  ServerError
    { errHTTPCode = statusCode status,
      errReasonPhrase = Text.unpack (TE.decodeUtf8 (statusMessage status)),
      errBody =
        Aeson.encode
          ( Aeson.object
              [ "error" Aeson..= code,
                "error_description" Aeson..= description
              ]
          ),
      errHeaders =
        [ ("Content-Type", "application/json"),
          ("Cache-Control", "no-store"),
          ("Pragma", "no-cache")
        ]
          <> [("WWW-Authenticate", "Basic realm=\"shomei\"") | statusCode status == 401]
    }

-- | The single answer to every client-authentication failure: an unknown @client_id@, a wrong
-- secret, a revoked account, an absent credential, and a malformed @Authorization@ header all
-- produce this exact response. Nothing about which one occurred reaches the caller.
invalidClient :: ServerError
invalidClient = oauthError status401 "invalid_client" "client authentication failed"

-- | A missing or malformed request parameter; @what@ names it.
invalidRequest :: Text -> ServerError
invalidRequest what = oauthError status400 "invalid_request" what

unsupportedGrantType :: Text -> ServerError
unsupportedGrantType grant =
  oauthError status400 "unsupported_grant_type" ("unsupported grant_type: " <> grant)

-- ---------------------------------------------------------------------------
-- Client authentication
-- ---------------------------------------------------------------------------

data ClientAuth = ClientAuth
  { clientId :: !Text,
    clientSecret :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Extract the client's credentials from an @Authorization: Basic …@ header (RFC 6749's
-- @client_secret_basic@) or, failing that, from @client_id@\/@client_secret@ body parameters
-- (@client_secret_post@).
--
-- The header wins when present, even if body parameters also appear: RFC 6749 §2.3.1 says a
-- client MUST NOT use more than one authentication method, and preferring the header means a
-- malformed header is reported rather than silently ignored in favor of a body parameter.
--
-- Every failure is 'invalidClient'. A caller learns only "authentication failed".
extractClientAuth :: Maybe Text -> Form -> Either ServerError ClientAuth
extractClientAuth mAuthHeader form =
  case mAuthHeader >>= stripBasic of
    Just encoded -> decodeBasic encoded
    Nothing
      -- An Authorization header that is present but not Basic (a Bearer token, say) is not a
      -- fallback to body parameters: the client chose a scheme, and it is not one we accept.
      | isJust mAuthHeader -> Left invalidClient
      | otherwise -> fromBody
  where
    stripBasic h =
      let (scheme, rest) = Text.breakOn " " (Text.strip h)
       in if Text.toLower scheme == "basic" then Just (Text.strip rest) else Nothing

    -- Any decoding failure — bad base64, non-UTF-8 bytes, no colon — is just "authentication
    -- failed". The client learns nothing about which.
    orInvalidClient :: Either e a -> Either ServerError a
    orInvalidClient = either (const (Left invalidClient)) Right

    decodeBasic encoded = do
      raw <- orInvalidClient (B64.decodeBase64Untyped (TE.encodeUtf8 encoded))
      decoded <- orInvalidClient (TE.decodeUtf8' raw)
      -- Split on the FIRST colon: a secret may contain colons, a client id may not.
      let (cid, rest) = Text.breakOn ":" decoded
      if Text.null rest
        then Left invalidClient
        else pure ClientAuth {clientId = cid, clientSecret = Text.drop 1 rest}

    fromBody = case (lookupParam "client_id" form, lookupParam "client_secret" form) of
      (Just cid, Just secret) -> pure ClientAuth {clientId = cid, clientSecret = secret}
      _ -> Left invalidClient

-- ---------------------------------------------------------------------------
-- Parameters
-- ---------------------------------------------------------------------------

-- | Read a single-valued form parameter. A parameter that appears more than once, or not at
-- all, is 'Nothing' — 'lookupUnique' is what enforces the "exactly once" part.
lookupParam :: Text -> Form -> Maybe Text
lookupParam k form = either (const Nothing) Just (lookupUnique k form)

-- | Parse the OAuth2 @scope@ parameter: a space-delimited list (RFC 6749 §3.3).
--
-- 'Nothing' means the parameter was absent, which the @client_credentials@ workflow reads as
-- "grant everything this account is allowed". @Just Set.empty@ — the caller sent @scope=@ or
-- @scope=\"   \"@ — is a distinct, malformed request, and the workflow refuses it with
-- @invalid_scope@ rather than silently granting nothing.
parseScopeParam :: Form -> Maybe (Set Scope)
parseScopeParam form = fmap toScopes (lookupParam "scope" form)
  where
    toScopes = Set.fromList . map Scope . Text.words

-- ---------------------------------------------------------------------------
-- The success response
-- ---------------------------------------------------------------------------

-- | RFC 6749 §5.1's access-token response.
--
-- The JSON keys are the RFC's, which are snake_case and therefore not derivable from Haskell
-- field names: the instances below are hand-written and must stay in step with the @ToSchema@
-- in "Shomei.Servant.OpenApi".
--
-- @scope@ is always present, even when the client sent none: it tells the client exactly what it
-- was granted rather than making it infer the server's default.
data TokenResponse = TokenResponse
  { accessToken :: !Text,
    -- | always @"Bearer"@
    tokenType :: !Text,
    -- | lifetime in seconds
    expiresIn :: !Int,
    -- | space-delimited granted scopes
    scope :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance Aeson.ToJSON TokenResponse where
  toJSON r =
    Aeson.object
      [ "access_token" Aeson..= r.accessToken,
        "token_type" Aeson..= r.tokenType,
        "expires_in" Aeson..= r.expiresIn,
        "scope" Aeson..= r.scope
      ]

instance Aeson.FromJSON TokenResponse where
  parseJSON = Aeson.withObject "TokenResponse" \o ->
    TokenResponse
      <$> o Aeson..: "access_token"
      <*> o Aeson..: "token_type"
      <*> o Aeson..: "expires_in"
      <*> o Aeson..: "scope"
