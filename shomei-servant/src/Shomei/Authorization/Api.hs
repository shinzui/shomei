-- | Administrative authorization-grant routes.
module Shomei.Authorization.Api (AuthorizationApi (..)) where

import Servant.API
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (CsrfProtected)

data AuthorizationApi mode = AuthorizationApi
  { grantRole :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> "roles" :> Capture "role" Text :> Verb 'PUT 204 '[JSON] NoContent,
    revokeRole :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> "roles" :> Capture "role" Text :> Verb 'DELETE 204 '[JSON] NoContent
  }
  deriving stock (Generic)
