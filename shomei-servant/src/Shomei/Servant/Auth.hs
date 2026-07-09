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
-- @AuthProtect "shomei-jwt"@ (aliased here as 'Authenticated'), and the server side
-- is driven by an 'AuthHandler' registered in the 'Servant.Context'. The handler is
-- built with 'authHandler', which is parameterized over a token verifier of shape
-- @Text -> IO (Either TokenError AuthClaims)@ (at assembly time this is EP-4's
-- @\\t -> verifyToken jwks config t@); this module therefore never touches @jose@.
--
-- __Why the CSRF gate exists.__ A browser attaches cookies to a request automatically, even
-- when the request was triggered by a page on someone else's site. So a malicious page can
-- make a logged-in victim's browser POST to @\/auth\/logout@ or @\/auth\/password\/change@,
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
import Servant (Handler, ServerError, err401, err403, errBody, errHeaders, throwError)
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Server.Experimental.Auth
  ( AuthHandler,
    AuthServerData,
    mkAuthHandler,
  )
import Shomei.Config (CookieConfig (..), ShomeiConfig (..), TokenTransport (..), transportUsesCookies)
import Shomei.Domain.Claims (AuthClaims (..), Role, Scope)
import Shomei.Error (TokenError)
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Web.Cookie (parseCookies)

-- | Shōmei's principal: the value the 'AuthHandler' hands to every authenticated
-- route once a token verifies. Carries the user id, session id, roles, scopes,
-- and the raw verified 'AuthClaims'.
data AuthUser = AuthUser
  { authUserId :: !UserId,
    authSessionId :: !SessionId,
    authRoles :: !(Set Role),
    authScopes :: !(Set Scope),
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
      authClaims = claims
    }

-- | Build the auth handler. A missing token is a @401@; a failed verification is also a
-- @401@ (we do not distinguish, to avoid leaking why). A cookie-authenticated mutating
-- request from an origin that is not allow-listed is a @403 csrf_rejected@ — refused before
-- the token is even verified, because the credential itself is not admissible here.
authHandler :: CookiePolicy -> (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request AuthUser
authHandler policy verify = mkAuthHandler handle
  where
    handle :: Request -> Handler AuthUser
    handle req = do
      (source, tok) <-
        maybe (throwError err401 {errBody = "missing token"}) pure (extractToken policy.transport req)
      when (source == FromCookie && not (isSafeMethod req) && not (originAllowed policy.allowedOrigins req)) $
        throwError csrfRejected
      res <- liftIO (verify tok)
      case res of
        Left _ -> throwError err401 {errBody = "invalid token"}
        Right claims -> pure (authUserFromClaims claims)

-- | Extract the presented token and record where it came from.
--
-- 'BearerToken' reads the @Authorization@ header only — the cookie is __not__ a fallback,
-- because a deployment that never sets cookies must not accept them either. The cookie modes
-- try bearer first (non-browser callers and service tokens keep working) and fall back to the
-- @shomei_session@ cookie.
extractToken :: TokenTransport -> Request -> Maybe (TokenSource, Text)
extractToken transport req =
  ((FromBearer,) <$> bearer) <|> guard (transportUsesCookies transport) *> ((FromCookie,) <$> cookieToken)
  where
    headers = requestHeaders req

    bearer :: Maybe Text
    bearer = do
      raw <- lookup "Authorization" headers
      Text.stripPrefix "Bearer " (Text.decodeUtf8 raw)

    cookieToken :: Maybe Text
    cookieToken = do
      raw <- lookup "Cookie" headers
      val <- lookup ("shomei_session" :: BS.ByteString) (parseCookies raw)
      pure (Text.decodeUtf8 val)

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
csrfRejected =
  err403
    { errBody = "{\"error\":\"csrf_rejected\",\"message\":\"Origin not allowed for cookie-authenticated request\"}",
      errHeaders = [("Content-Type", "application/json")]
    }
