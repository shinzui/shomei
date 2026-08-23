-- | Administrative account lifecycle routes.
module Shomei.Account.Admin.Api (AdminAccountApi (..)) where

import Servant.API
import Shomei.Account.User.Dto (AdminStatusFilter, AdminUserResponse, AdminUsersPage, UserPageCursor)
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (CsrfProtected)

data AdminAccountApi mode = AdminAccountApi
  { listUsers :: mode :- "users" :> RequireAdmin :> QueryParam "status" AdminStatusFilter :> QueryParam "limit" Int :> QueryParam "before" UserPageCursor :> Get '[JSON] AdminUsersPage,
    getUser :: mode :- "users" :> RequireAdmin :> Capture "userId" UserId :> Get '[JSON] AdminUserResponse,
    suspendUser :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> "suspend" :> PostNoContent,
    reinstateUser :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> "reinstate" :> PostNoContent,
    deleteUser :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> Verb 'DELETE 204 '[JSON] NoContent,
    passwordReset :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> "password-reset" :> Verb 'POST 202 '[JSON] NoContent
  }
  deriving stock (Generic)
