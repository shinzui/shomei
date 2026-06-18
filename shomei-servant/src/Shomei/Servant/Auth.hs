-- The @AuthServerData@ instance below is an unavoidable orphan: both the type family
-- (@AuthServerData@) and the type it is indexed by (@AuthProtect "shomei-jwt"@) belong
-- to servant, while 'AuthUser' belongs here. This is the standard servant generalized-auth
-- pattern, so we silence the orphan warning for this module.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The 'Authenticated' combinator (custom 'AuthProtect' + 'AuthHandler') and the
-- 'AuthUser' principal it produces (MasterPlan IP-6).
--
-- Authentication uses Servant's /generalized auth/: the route type carries
-- @AuthProtect "shomei-jwt"@ (aliased here as 'Authenticated'), and the server side
-- is driven by an 'AuthHandler' registered in the 'Servant.Context'. The handler is
-- built with 'authHandler', which is parameterized over a token verifier of shape
-- @Text -> IO (Either TokenError AuthClaims)@ (at assembly time this is EP-4's
-- @\\t -> verifyToken jwks config t@); this module therefore never touches @jose@.
module Shomei.Servant.Auth
  ( AuthUser (..),
    Authenticated,
    authHandler,
    extractToken,
    authUserFromClaims,
  )
where

import Data.ByteString qualified as BS
import Data.Set (Set)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.Wai (Request, requestHeaders)
import Servant (Handler, err401, errBody, throwError)
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Server.Experimental.Auth
  ( AuthHandler,
    AuthServerData,
    mkAuthHandler,
  )
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
-- receive a leading 'AuthUser' argument.
type Authenticated = AuthProtect "shomei-jwt"

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

-- | Build the auth handler from a token verifier. A missing token is a @401@; a
-- failed verification is also a @401@ (we do not distinguish, to avoid leaking why).
authHandler :: (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request AuthUser
authHandler verify = mkAuthHandler handle
  where
    handle :: Request -> Handler AuthUser
    handle req = do
      tok <- maybe (throwError err401 {errBody = "missing token"}) pure (extractToken req)
      res <- liftIO (verify tok)
      case res of
        Left _ -> throwError err401 {errBody = "invalid token"}
        Right claims -> pure (authUserFromClaims claims)

-- | Extract the bearer token: @Authorization: Bearer <tok>@ first, then the
-- @shomei_session@ cookie as a fallback.
extractToken :: Request -> Maybe Text
extractToken req = bearer <|> cookieToken
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
