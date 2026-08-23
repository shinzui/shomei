-- | Thin composition roots for Shōmei's concept-owned route records.
module Shomei.Servant.Api
  ( ShomeiRoutes (..),
    shomeiRoutesApi,
    ApplicationApi (..),
    applicationApi,
    AppApi,
    ApplicationRoutes,
    OAuthRoutes,
    WellKnownRoutes,
    HealthRoutes,
    OpenApiRoute,
    Project (..),
  )
where

import Data.Aeson (Value)
import Servant.API
import Servant.Health (HealthApi)
import Shomei.Account.Admin.Api (AdminAccountApi)
import Shomei.Account.Api (AccountApi)
import Shomei.Account.User.Domain (User)
import Shomei.Audit.Api (AuditApi)
import Shomei.Authorization.Api (AuthorizationApi)
import Shomei.Mfa.Api (MfaApi)
import Shomei.OAuth.Api (OAuthApi)
import Shomei.Passkey.Api (PasskeyApi)
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Authz (RequireRole)
import Shomei.Session.Admin.Api (AdminSessionApi)
import Shomei.Session.Api (SessionApi)
import Shomei.SigningKey.Api (WellKnownApi)

-- | Versioned application routes, grouped by the concept that owns their wire contract and
-- handler adapter. Several fields intentionally share a path prefix; NamedRoutes dispatch uses
-- the complete route beneath each field rather than record declaration order.
data ApplicationApi mode = ApplicationApi
  { account :: mode :- "auth" :> NamedRoutes AccountApi,
    session :: mode :- "auth" :> NamedRoutes SessionApi,
    passkey :: mode :- "auth" :> NamedRoutes PasskeyApi,
    mfa :: mode :- "auth" :> NamedRoutes MfaApi,
    adminAccount :: mode :- "admin" :> NamedRoutes AdminAccountApi,
    adminSession :: mode :- "admin" :> NamedRoutes AdminSessionApi,
    authorization :: mode :- "admin" :> NamedRoutes AuthorizationApi,
    audit :: mode :- "admin" :> NamedRoutes AuditApi
  }
  deriving stock (Generic)

applicationApi :: Proxy (NamedRoutes ApplicationApi)
applicationApi = Proxy

-- | The exact served API. Standalone, embedded, OpenAPI, and client entry points all consume
-- this proxy.
type ApplicationRoutes = "v1" :> NamedRoutes ApplicationApi

type OAuthRoutes = "oauth" :> NamedRoutes OAuthApi

type WellKnownRoutes = ".well-known" :> NamedRoutes WellKnownApi

type HealthRoutes = "health" :> NamedRoutes HealthApi

type OpenApiRoute = "openapi.json" :> Get '[JSON] Value

data ShomeiRoutes mode = ShomeiRoutes
  { application :: mode :- ApplicationRoutes,
    oauth :: mode :- OAuthRoutes,
    wellKnown :: mode :- WellKnownRoutes,
    health :: mode :- HealthRoutes,
    openapi :: mode :- OpenApiRoute
  }
  deriving stock (Generic)

shomeiRoutesApi :: Proxy (NamedRoutes ShomeiRoutes)
shomeiRoutesApi = Proxy

newtype Project = Project {projectId :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Embeddability proof: a host may mount the complete API beside its own authenticated routes.
type AppApi =
  NamedRoutes ShomeiRoutes
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
    :<|> RequireRole "admin" :> "admin" :> "users" :> Get '[JSON] [User]
