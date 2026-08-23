module Shomei.Audit.Result (AuditEventsResponses, AuditEventsResult) where

import Shomei.Audit.Dto (AuditEventsPage)
import Shomei.Servant.Result

type AuditEventsResponses = ApplicationResponses 200 "Audit events" AuditEventsPage

type AuditEventsResult = ApplicationResult AuditEventsPage
