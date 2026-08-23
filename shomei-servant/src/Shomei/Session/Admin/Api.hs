-- | Administrative session routes.
module Shomei.Session.Admin.Api (AdminSessionApi (..)) where

import Servant.API
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (CsrfProtected)
import Shomei.Session.Dto (SessionResponse)

data AdminSessionApi mode = AdminSessionApi
  { listSessions :: mode :- "users" :> RequireAdmin :> Capture "userId" UserId :> "sessions" :> Get '[JSON] [SessionResponse],
    revokeSessions :: mode :- "users" :> RequireAdmin :> CsrfProtected :> Capture "userId" UserId :> "sessions" :> Verb 'DELETE 204 '[JSON] NoContent,
    revokeSession :: mode :- "sessions" :> RequireAdmin :> CsrfProtected :> Capture "sessionId" SessionId :> Verb 'DELETE 204 '[JSON] NoContent
  }
  deriving stock (Generic)
