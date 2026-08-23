-- | Administrative audit-reader HTTP adapter.
module Shomei.Audit.Handler (auditServer) where

import Servant (Handler)
import Servant.Server.Generic (AsServerT)
import Shomei.Audit.Api (AuditApi (..))
import Shomei.Audit.Dto
import Shomei.Audit.Reader.Store
  ( AuditCursor (..),
    AuditEventQuery (..),
    StoredAuthEvent (..),
    clampLimit,
    emptyAuditQuery,
    queryAuthEvents,
  )
import Shomei.Id (sessionIdToUUID, userIdToUUID)
import Shomei.Prelude
import Shomei.Servant.Auth (AuthUser)
import Shomei.Servant.Seam (Env, runPort)

auditServer :: Env -> AuditApi (AsServerT Handler)
auditServer env = AuditApi {events = auditEventsH env}

auditEventsH ::
  Env ->
  AuthUser ->
  Maybe AuditUserId ->
  Maybe AuditSessionId ->
  [Text] ->
  Maybe AuditTimestamp ->
  Maybe AuditTimestamp ->
  Maybe Int ->
  Maybe AuditPageCursor ->
  Handler AuditEventsPage
auditEventsH env _ user session eventTypes since until limit before = do
  let query =
        emptyAuditQuery
          { queryUserId = userIdToUUID . (.auditUserId) <$> user,
            querySessionId = sessionIdToUUID . (.auditSessionId) <$> session,
            queryEventTypes = eventTypes,
            querySince = (.auditTimestamp) <$> since,
            queryUntil = (.auditTimestamp) <$> until,
            queryLimit = fromMaybe 50 limit,
            queryBefore = (.auditCursor) <$> before
          }
  events <- runPort env (queryAuthEvents query)
  let full = length events == clampLimit query.queryLimit
      nextCursor = if full then encodeCursor . cursorOf <$> lastMay events else Nothing
  pure AuditEventsPage {events = map storedToResponse events, nextCursor}
  where
    cursorOf event = AuditCursor {cursorCreatedAt = event.storedCreatedAt, cursorEventId = event.storedEventId}

lastMay :: [a] -> Maybe a
lastMay = \case
  [] -> Nothing
  values -> Just (last values)
