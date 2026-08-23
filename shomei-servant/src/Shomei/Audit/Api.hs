-- | Administrative audit-query routes.
module Shomei.Audit.Api (AuditApi (..)) where

import Servant.API
import Shomei.Audit.Dto (AuditEventsPage, AuditPageCursor, AuditSessionId, AuditTimestamp, AuditUserId)
import Shomei.Prelude
import Shomei.Servant.Authz (RequireAdmin)

data AuditApi mode = AuditApi
  { events :: mode :- "audit" :> "events" :> RequireAdmin :> QueryParam "user" AuditUserId :> QueryParam "session" AuditSessionId :> QueryParams "type" Text :> QueryParam "since" AuditTimestamp :> QueryParam "until" AuditTimestamp :> QueryParam "limit" Int :> QueryParam "before" AuditPageCursor :> Get '[JSON] AuditEventsPage
  }
  deriving stock (Generic)
