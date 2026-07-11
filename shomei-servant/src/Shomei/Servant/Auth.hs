-- The @AuthServerData@ instance below is an unavoidable orphan: both the type family
-- (@AuthServerData@) and the type it is indexed by (@AuthProtect "shomei-jwt"@) belong
-- to servant, while 'AuthUser' belongs here. This is the standard servant generalized-auth
-- pattern, so we silence the orphan warning for this module.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The 'Authenticated' combinator (custom 'AuthProtect' + 'AuthHandler') and the
-- 'AuthUser' principal it produces (MasterPlan IP-6), plus the CSRF gate that guards
-- cookie-borne credentials.
--
-- Authentication uses Servant's /generalized auth/: the route type carries
-- @AuthProtect "shomei-jwt"@ (aliased here as 'Authenticated'), and the server side is driven by
-- an 'AuthHandler' registered in the 'Servant.Context'. The handler is built with 'authHandler'
-- from the seam 'Env'; verification is derived from its port runner and configuration through
-- 'Shomei.Servant.Seam.verifyRequestToken'. This makes
-- @sessionCheckMode = VerifyTokenAndSession@ apply consistently without this module touching
-- @jose@ directly.
--
-- __Why the CSRF gate exists.__ A browser attaches cookies to a request automatically, even
-- when the request was triggered by a page on someone else's site. So a malicious page can
-- make a logged-in victim's browser POST to @\/v1\/auth\/logout@ or @\/v1\/auth\/password\/change@,
-- and the cookie rides along. The attacker cannot read the response, but the side effect is
-- the attack. Bearer tokens are immune — a foreign page cannot set an @Authorization@ header
-- — which is why the gate applies only to cookie-sourced credentials, and only to methods
-- that mutate.
module Shomei.Servant.Auth
  ( AuthUser (..),
    Authenticated,
    CookiePolicy (..),
    cookiePolicyFromConfig,
    TokenSource (..),
    authHandler,
    extractToken,
    extractTokenFromHeaders,
    resolveAuthUser,
    originAllowed,
    originHeaderAllowed,
    isSafeMethod,
    csrfRejected,
    authUserFromClaims,
  )
where

import Data.ByteString qualified as BS
import Data.Set (Set)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.Wai (Request, requestHeaders, requestMethod)
import Servant (Handler, ServerError, throwError)
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Server.Experimental.Auth
  ( AuthHandler,
    AuthServerData,
    mkAuthHandler,
  )
import Shomei.Config (CookieConfig (..), ShomeiConfig (..), TokenTransport (..), transportUsesCookies)
import Shomei.Domain.Claims (AuthClaims (..), Permission, Role, Scope)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Shomei.Servant.Error (pcCsrfRejected, pcMissingToken, pcSessionExpired, pcSessionRevoked, pcTokenInvalidAuth, toProblemError)
import Shomei.Servant.Seam (Env (..), verifyRequestToken)
import Web.Cookie (parseCookies)

-- | Shōmei's principal: the value the 'AuthHandler' hands to every authenticated
-- route once a token verifies. Carries the user id, session id, roles, scopes,
-- and the raw verified 'AuthClaims'.
data AuthUser = AuthUser
  { authUserId :: !UserId,
    authSessionId :: !SessionId,
    authRoles :: !(Set Role),
    authScopes :: !(Set Scope),
    authPermissions :: !(Set Permission),
    authClaims :: !AuthClaims
  }
  deriving stock (Generic)

-- | Register 'AuthUser' as the server-side payload of @AuthProtect "shomei-jwt"@.
type instance AuthServerData (AuthProtect "shomei-jwt") = AuthUser

-- | Put this before a route (or a 'NamedRoutes' record) to make its handler
-- receive a leading 'AuthUser'.
type Authenticated = AuthProtect "shomei-jwt"

-- | Where a presented credential came from. Cookie-sourced credentials are subject to the
-- CSRF origin gate; bearer credentials never are.
data TokenSource = FromBearer | FromCookie
  deriving stock (Eq, Show)

-- | The transport policy the auth handler enforces: which credential sources are accepted,
-- and which origins may drive a cookie-authenticated mutation.
data CookiePolicy = CookiePolicy
  { transport :: !TokenTransport,
    allowedOrigins :: ![Text]
  }
  deriving stock (Eq, Show)

-- | The single place the auth policy is read out of runtime configuration, so every assembly
-- (server, tests, embedded hosts) enforces the same thing.
cookiePolicyFromConfig :: ShomeiConfig -> CookiePolicy
cookiePolicyFromConfig cfg =
  CookiePolicy
    { transport = cfg.tokenTransport,
      allowedOrigins = cfg.cookieConfig.allowedOrigins
    }

-- | Project a verified 'AuthClaims' into the principal.
authUserFromClaims :: AuthClaims -> AuthUser
authUserFromClaims claims =
  AuthUser
    { authUserId = claims.subject,
      authSessionId = claims.sessionId,
      authRoles = claims.roles,
      authScopes = claims.scopes,
      authPermissions = claims.permissions,
      authClaims = claims
    }

-- | Build the auth handler. A missing token is a @401@; a failed verification is also a
-- @401@. Revoked and expired sessions carry their actionable problem codes; other failures stay
-- the undifferentiated @token_invalid@. A cookie-authenticated mutating
-- request from an origin that is not allow-listed is a @403 csrf_rejected@ — refused before
-- the token is even verified, because the credential itself is not admissible here.
authHandler :: Env -> AuthHandler Request AuthUser
authHandler env = mkAuthHandler handle
  where
    policy = cookiePolicyFromConfig env.config

    handle :: Request -> Handler AuthUser
    handle req = do
      (source, tok) <-
        maybe (throwError (toProblemError pcMissingToken Nothing)) pure (extractToken policy.transport req)
      when (source == FromCookie && not (isSafeMethod req) && not (originAllowed policy.allowedOrigins req)) $
        throwError csrfRejected
      res <- liftIO (verifyRequestToken env tok)
      case res of
        Left e -> throwError (authFailure e)
        Right claims -> pure (authUserFromClaims claims)

-- | How an authentication failure becomes an HTTP response.
--
-- Deliberately not 'Shomei.Servant.Error.authErrorToServerError': that handler-layer mapping
-- turns 'SessionNotFound' into a 404, which would make a protected route look nonexistent.
-- Revocation and expiry are actionable to a caller already holding the token. Everything else,
-- including an unresolvable session id, fails closed as @401 token_invalid@.
authFailure :: AuthError -> ServerError
authFailure = \case
  SessionExpired -> toProblemError pcSessionExpired Nothing
  SessionRevoked -> toProblemError pcSessionRevoked Nothing
  _ -> toProblemError pcTokenInvalidAuth Nothing

-- | Extract the presented token and record where it came from.
--
-- 'BearerToken' reads the @Authorization@ header only — the cookie is __not__ a fallback,
-- because a deployment that never sets cookies must not accept them either. The cookie modes
-- try bearer first (non-browser callers and service tokens keep working) and fall back to the
-- @shomei_session@ cookie.
extractToken :: TokenTransport -> Request -> Maybe (TokenSource, Text)
extractToken transport req =
  extractTokenFromHeaders transport (header "Authorization") (header "Cookie")
  where
    header name = Text.decodeUtf8 <$> lookup name (requestHeaders req)

-- | 'extractToken' over the header values directly, for routes that receive them as Servant
-- 'Servant.Header' inputs rather than as a WAI 'Request'.
--
-- @\/oauth\/authorize@ is such a route: it must /redirect/ an unauthenticated browser to the
-- host's login page rather than answer @401@, so it cannot use the 'Authenticated' combinator and
-- never sees a 'Request'. Sharing this function is what makes a future transport (the cookie mode
-- today, anything later) reach that endpoint without a second implementation. Compare
-- 'originHeaderAllowed', which exists for the same reason.
extractTokenFromHeaders :: TokenTransport -> Maybe Text -> Maybe Text -> Maybe (TokenSource, Text)
extractTokenFromHeaders transport mAuthorization mCookie =
  ((FromBearer,) <$> bearer) <|> guard (transportUsesCookies transport) *> ((FromCookie,) <$> cookieToken)
  where
    bearer :: Maybe Text
    bearer = mAuthorization >>= Text.stripPrefix "Bearer "

    cookieToken :: Maybe Text
    cookieToken = do
      raw <- mCookie
      val <- lookup ("shomei_session" :: BS.ByteString) (parseCookies (Text.encodeUtf8 raw))
      pure (Text.decodeUtf8 val)

-- | Verify whatever credential the headers carry, yielding 'Nothing' when there is none or it does
-- not verify. The authenticating core the 'AuthHandler' and @\/oauth\/authorize@ share.
--
-- No CSRF gate: the only caller that is not the 'AuthHandler' is a @GET@, and 'isSafeMethod' would
-- exempt it anyway. A caller that /can/ mutate must go through 'authHandler'.
resolveAuthUser ::
  Env ->
  -- | the @Authorization@ header
  Maybe Text ->
  -- | the @Cookie@ header
  Maybe Text ->
  IO (Maybe AuthUser)
resolveAuthUser env mAuthorization mCookie =
  case extractTokenFromHeaders policy.transport mAuthorization mCookie of
    Nothing -> pure Nothing
    Just (_source, tok) -> either (const Nothing) (Just . authUserFromClaims) <$> verifyRequestToken env tok
  where
    policy = cookiePolicyFromConfig env.config

-- | Methods that cannot change state, and so need no CSRF protection.
isSafeMethod :: Request -> Bool
isSafeMethod req = requestMethod req `elem` ["GET", "HEAD", "OPTIONS"]

-- | Is this request driven by an allow-listed origin?
--
-- Prefers the @Origin@ header, which browsers set to the /initiating/ page's origin on every
-- cross-origin request and on same-origin POSTs, and which page JavaScript cannot forge.
-- Falls back to a @Referer@ prefix match for the few agents that omit @Origin@; the prefix
-- must end at a @\/@ or at the end of the header, so @https://evil.com@ cannot satisfy an
-- allow-list containing @https://evil.com.attacker.net@ — or vice versa.
--
-- With neither header present this returns 'False': a cookie-authenticated mutating request
-- carrying no origin information is either a non-browser client that should be sending a
-- bearer token, or an attack. Fail closed.
originAllowed :: [Text] -> Request -> Bool
originAllowed allowed req = originHeaderAllowed allowed (header "Origin") (header "Referer")
  where
    header name = Text.decodeUtf8 <$> lookup name (requestHeaders req)

-- | 'originAllowed' over the header values directly, for routes that receive them as servant
-- 'Header' inputs rather than a WAI 'Request' — the refresh endpoint, which is unauthenticated
-- yet consumes a cookie.
originHeaderAllowed :: [Text] -> Maybe Text -> Maybe Text -> Bool
originHeaderAllowed allowed mOrigin mReferer = maybe refererAllowed (`elem` allowed) mOrigin
  where
    refererAllowed = maybe False matchesPrefix mReferer
    matchesPrefix referer = any (`isOriginPrefixOf` referer) allowed
    isOriginPrefixOf origin referer =
      case Text.stripPrefix origin referer of
        Just "" -> True
        Just rest -> Text.isPrefixOf "/" rest
        Nothing -> False

-- | The refusal for a cookie-authenticated mutating request from a disallowed origin. Shared
-- with the refresh handler, which applies the same gate to the @shomei_refresh@ cookie.
--
-- This is an HTTP-layer error, not an 'Shomei.Error.AuthError': CSRF is a property of /how the
-- credential arrived/, which the core workflows never see.
csrfRejected :: ServerError
csrfRejected = toProblemError pcCsrfRejected Nothing
