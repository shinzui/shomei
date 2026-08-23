-- | Administrative authorization-grant routes.
module Shomei.Authorization.Api (AuthorizationApi (..), GrantRoleRoute, RevokeRoleRoute) where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Authorization.Result
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)

type GrantRoleRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "roles" :> Capture "role" Text :> MultiVerb 'PUT ApplicationContentTypes GrantRoleResponses GrantRoleResult

type RevokeRoleRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "roles" :> Capture "role" Text :> MultiVerb 'DELETE ApplicationContentTypes RevokeRoleResponses RevokeRoleResult

data AuthorizationApi mode = AuthorizationApi
  { grantRole :: mode :- GrantRoleRoute,
    revokeRole :: mode :- RevokeRoleRoute
  }
  deriving stock (Generic)
