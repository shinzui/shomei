{- | The Shōmei HTTP API as a servant 'NamedRoutes' record (MasterPlan IP-6), plus
the embedded 'AppAPI' example proving the API and combinators compose inside a host
Servant application.

Public routes (@signup@/@login@/@refresh@) carry no auth. Routes that need a
principal carry the 'Authenticated' combinator on the individual field, so only
those handlers receive a leading 'Shomei.Servant.Auth.AuthUser'. The @jwks@ route
returns an @aeson@ 'Value' (the public JWKS document, supplied at assembly time).
-}
module Shomei.Servant.API (
    ShomeiAPI (..),
    shomeiAPI,
    AppAPI,
    Project (..),
) where

import Shomei.Prelude

import "aeson" Data.Aeson (Value)
import "servant" Servant.API

import Shomei.Domain.User (User)
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Authz (RequireRole)
import Shomei.Servant.DTO (
    HealthResponse,
    LoginRequest,
    LoginResponse,
    RefreshRequest,
    SessionResponse,
    SignupRequest,
    SignupResponse,
    TokenPairResponse,
    UserResponse,
 )

{- | The standalone API. @signup@/@login@/@refresh@/@logout@/@me@/@session@ live
under @\/auth@; @jwks@ under @\/.well-known@; @health@ at @\/health@.
-}
data ShomeiAPI mode = ShomeiAPI
    { signup ::
        mode
            :- "auth"
                :> "signup"
                :> ReqBody '[JSON] SignupRequest
                :> Post '[JSON] SignupResponse
    , login ::
        mode
            :- "auth"
                :> "login"
                :> ReqBody '[JSON] LoginRequest
                :> Post '[JSON] LoginResponse
    , refresh ::
        mode
            :- "auth"
                :> "refresh"
                :> ReqBody '[JSON] RefreshRequest
                :> Post '[JSON] TokenPairResponse
    , logout ::
        mode
            :- "auth"
                :> "logout"
                :> Authenticated
                :> PostNoContent
    , me ::
        mode
            :- "auth"
                :> Authenticated
                :> "me"
                :> Get '[JSON] UserResponse
    , session ::
        mode
            :- "auth"
                :> Authenticated
                :> "session"
                :> Get '[JSON] SessionResponse
    , jwks ::
        mode
            :- ".well-known"
                :> "jwks.json"
                :> Get '[JSON] Value
    , health ::
        mode
            :- "health"
                :> Get '[JSON] HealthResponse
    }
    deriving stock (Generic)

-- | A 'Proxy' carrying the API type for 'Servant.serveWithContext'.
shomeiAPI :: Proxy (NamedRoutes ShomeiAPI)
shomeiAPI = Proxy

-- | A stand-in host resource for the embeddability example.
newtype Project = Project {projectId :: Text}
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

{- | Embeddability proof: mount the whole Shōmei API under @\/auth@ alongside a host
route protected by 'Authenticated', plus an admin route documented with the
'RequireRole' phantom combinator. This type-checking shows the API type and the
combinators compose inside a host Servant app. (It is illustrative — it is not
served here; 'RequireRole' has no 'HasServer' instance, so an actual admin route
uses the 'Shomei.Servant.Authz.requireRole' guard instead.)
-}
type AppAPI =
    "auth" :> NamedRoutes ShomeiAPI
        :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
        :<|> RequireRole "admin" :> Authenticated :> "admin" :> "users" :> Get '[JSON] [User]
