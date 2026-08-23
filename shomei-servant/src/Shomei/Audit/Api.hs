-- | Administrative audit-query routes.
module Shomei.Audit.Api (AuditApi (..), AuditEventsRoute) where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Audit.Dto (AuditPageCursor, AuditSessionId, AuditTimestamp, AuditUserId)
import Shomei.Audit.Result
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)
import Shomei.Servant.PreHandler (PreHandlerResponses)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)

type AuditEventsRoute = "audit" :> "events" :> RequireAdmin :> PreHandlerResponses BadRequestPreHandlerResponses :> QueryParam "user" AuditUserId :> QueryParam "session" AuditSessionId :> QueryParams "type" Text :> QueryParam "since" AuditTimestamp :> QueryParam "until" AuditTimestamp :> QueryParam "limit" Int :> QueryParam "before" AuditPageCursor :> MultiVerb 'GET ApplicationContentTypes AuditEventsResponses AuditEventsResult

data AuditApi mode = AuditApi
  { events :: mode :- AuditEventsRoute
  }
  deriving stock (Generic)
