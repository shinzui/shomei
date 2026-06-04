{- | Request/response JSON DTOs for 'Shomei.Servant.API.ShomeiAPI' (MasterPlan IP-6).

A pure wire contract: no 'Handler', no 'Eff'. The mapping functions
('userToResponse', 'tokenPairToResponse', 'sessionToResponse') render the EP-2
domain types into these wire shapes — identifiers as their TypeID text, emails as
their normalized text, status lowercased, timestamps as ISO-8601, and the
access-token lifetime as whole seconds.
-}
module Shomei.Servant.DTO (
    SignupRequest (..),
    SignupResponse (..),
    LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    TokenPairResponse (..),
    UserResponse (..),
    SessionResponse (..),
    HealthResponse (..),
    userToResponse,
    tokenPairToResponse,
    sessionToResponse,
) where

import Shomei.Prelude

import "text" Data.Text qualified as Text
import "time" Data.Time.Format.ISO8601 (iso8601Show)

import Shomei.Domain.Email (emailText)
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Domain.Session (Session (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (User (..), UserStatus (..))
import Shomei.Id (idText)

-- | @POST /auth/signup@ body.
data SignupRequest = SignupRequest
    { email :: !Text
    , password :: !Text
    , displayName :: !Text
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | A token pair as wire JSON: @{ accessToken, refreshToken, expiresIn }@.
data TokenPairResponse = TokenPairResponse
    { accessToken :: !Text
    , refreshToken :: !Text
    , expiresIn :: !Int
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | A user as wire JSON: @{ userId, email, displayName, status }@ (status lowercased).
data UserResponse = UserResponse
    { userId :: !Text
    , email :: !Text
    , displayName :: !Text
    , status :: !Text
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/signup@ response: the user + the token pair.
data SignupResponse = SignupResponse
    { user :: !UserResponse
    , token :: !TokenPairResponse
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/login@ body.
data LoginRequest = LoginRequest
    { email :: !Text
    , password :: !Text
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/login@ response (same shape as signup).
data LoginResponse = LoginResponse
    { user :: !UserResponse
    , token :: !TokenPairResponse
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/refresh@ body: just the opaque refresh token.
newtype RefreshRequest = RefreshRequest {refreshToken :: Text}
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @GET /auth/session@ response.
data SessionResponse = SessionResponse
    { sessionId :: !Text
    , userId :: !Text
    , createdAt :: !Text
    , expiresAt :: !Text
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @GET /health@ response.
newtype HealthResponse = HealthResponse {status :: Text}
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Render a domain 'User' to the wire DTO.
userToResponse :: User -> UserResponse
userToResponse u =
    UserResponse
        { userId = idText u.userId
        , email = emailText u.email
        , displayName = fromMaybe "" u.displayName
        , status = renderStatus u.status
        }
  where
    renderStatus UserActive = "active"
    renderStatus UserSuspended = "suspended"
    renderStatus UserDeleted = "deleted"

-- | Render a domain 'TokenPair' to the wire DTO (lifetime as whole seconds).
tokenPairToResponse :: TokenPair -> TokenPairResponse
tokenPairToResponse tp =
    TokenPairResponse
        { accessToken = unAccess tp.accessToken
        , refreshToken = unRefresh tp.refreshToken
        , expiresIn = round (realToFrac tp.expiresIn :: Double)
        }
  where
    unAccess (AccessToken t) = t
    unRefresh (RefreshToken t) = t

-- | Render a domain 'Session' to the wire DTO (timestamps as ISO-8601).
sessionToResponse :: Session -> SessionResponse
sessionToResponse s =
    SessionResponse
        { sessionId = idText s.sessionId
        , userId = idText s.userId
        , createdAt = Text.pack (iso8601Show s.createdAt)
        , expiresAt = Text.pack (iso8601Show s.expiresAt)
        }
