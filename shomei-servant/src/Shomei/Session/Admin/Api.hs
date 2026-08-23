-- | Administrative session routes.
module Shomei.Session.Admin.Api
  ( AdminSessionApi (..),
    ListSessionsRoute,
    RevokeSessionsRoute,
    RevokeSessionRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)
import Shomei.Session.Result

type ListSessionsRoute = "users" :> RequireAdmin :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "sessions" :> MultiVerb 'GET ApplicationContentTypes ListSessionsResponses ListSessionsResult

type RevokeSessionsRoute = "users" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "userId" UserId :> "sessions" :> MultiVerb 'DELETE ApplicationContentTypes RevokeSessionsResponses RevokeSessionsResult

type RevokeSessionRoute = "sessions" :> RequireAdmin :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "sessionId" SessionId :> MultiVerb 'DELETE ApplicationContentTypes RevokeSessionResponses RevokeSessionResult

data AdminSessionApi mode = AdminSessionApi
  { listSessions :: mode :- ListSessionsRoute,
    revokeSessions :: mode :- RevokeSessionsRoute,
    revokeSession :: mode :- RevokeSessionRoute
  }
  deriving stock (Generic)
