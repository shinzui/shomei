-- | Administrative account lifecycle routes.
module Shomei.Account.Admin.Api
  ( AdminAccountApi (..),
    ListUsersRoute,
    GetUserRoute,
    SuspendUserRoute,
    ReinstateUserRoute,
    DeleteUserRoute,
    AdminPasswordResetRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Account.Result
import Shomei.Account.User.Dto (AdminStatusFilter, UserPageCursor)
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)

type ListUsersRoute = "users" :> RequireAdmin :> PreHandlerResponses BadRequestPreHandlerResponses :> QueryParam "status" AdminStatusFilter :> QueryParam "limit" Int :> QueryParam "before" UserPageCursor :> MultiVerb 'GET ApplicationContentTypes ListUsersResponses ListUsersResult

type GetUserRoute = "users" :> RequireAdmin :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> MultiVerb 'GET ApplicationContentTypes GetUserResponses GetUserResult

type SuspendUserRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "suspend" :> MultiVerb 'POST ApplicationContentTypes SuspendUserResponses SuspendUserResult

type ReinstateUserRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "reinstate" :> MultiVerb 'POST ApplicationContentTypes ReinstateUserResponses ReinstateUserResult

type DeleteUserRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> MultiVerb 'DELETE ApplicationContentTypes DeleteUserResponses DeleteUserResult

type AdminPasswordResetRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "password-reset" :> MultiVerb 'POST ApplicationContentTypes AdminPasswordResetResponses AdminPasswordResetResult

data AdminAccountApi mode = AdminAccountApi
  { listUsers :: mode :- ListUsersRoute,
    getUser :: mode :- GetUserRoute,
    suspendUser :: mode :- SuspendUserRoute,
    reinstateUser :: mode :- ReinstateUserRoute,
    deleteUser :: mode :- DeleteUserRoute,
    passwordReset :: mode :- AdminPasswordResetRoute
  }
  deriving stock (Generic)
