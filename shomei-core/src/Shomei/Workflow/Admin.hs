-- | The audited administrative lifecycle workflows (EP-2 of MasterPlan 7): suspending,
-- reinstating and deleting a user, and revoking sessions on their behalf.
--
-- Every function takes the acting administrator's 'UserId' first and the target second, and
-- records the actor on the audit event it publishes. That is the whole reason these live in a
-- workflow rather than in the HTTP handlers: an administrative state change that leaves no trace
-- of /who/ made it is not an audit trail.
--
-- __These workflows neither authenticate nor authorize.__ They do not check that the acting user
-- holds the @admin@ role, and they do not refuse a self-targeted suspension. Those are HTTP-layer
-- policy (see @Shomei.Servant.Authz.requireAdmin@ and the handlers' self-target refusal), because
-- a different surface may reasonably decide differently — the @shomei-admin@ CLI, for instance,
-- has no notion of a caller at all.
--
-- Status transitions are strict rather than idempotent: suspending an already-suspended user is
-- an 'InvalidUserStatus' error, not a silent success. Two administrators responding to one
-- incident must be able to tell which of them actually changed the state.
--
-- Deletion is a __soft delete__ ('UserDeleted' status), never a row removal: sessions, role
-- grants, and audit events reference the user row, and the trail must survive the account.
module Shomei.Workflow.Admin
  ( suspendUser,
    reinstateUser,
    deleteUser,
    revokeUserSessions,
    revokeOneSession,
  )
where

import Effectful (Eff, (:>))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Session (Session (..), SessionStatus (..))
import Shomei.Domain.User (User (..), UserStatus (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SessionStore
  ( SessionStore,
    findSessionById,
    listSessionsForUser,
    revokeAllUserSessions,
    revokeSession,
  )
import Shomei.Effect.UserStore (UserStore, findUserById, updateUserStatus)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude

-- | Suspend an active user and kill their sessions.
--
-- Their outstanding /access/ tokens still ride out their short TTL unless the deployment sets
-- @sessionCheckMode = VerifyTokenAndSession@, which re-reads the session on every request. The
-- refresh path is closed immediately either way, so the blast radius is one access-token
-- lifetime.
suspendUser ::
  (UserStore :> es, SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  -- | the acting administrator
  UserId ->
  -- | the target
  UserId ->
  Eff es (Either AuthError ())
suspendUser actingAdmin target =
  transition target [UserActive] UserSuspended \ts -> do
    revokeAllUserSessions target ts
    publishAuthEvent (Event.UserSuspended (Event.UserSuspendedData target (Just actingAdmin) ts))

-- | Return a suspended user to service. Their sessions stay revoked; they log in again.
reinstateUser ::
  (UserStore :> es, SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId ->
  UserId ->
  Eff es (Either AuthError ())
reinstateUser actingAdmin target =
  transition target [UserSuspended] UserActive \ts ->
    publishAuthEvent (Event.UserReinstated (Event.UserReinstatedData target (Just actingAdmin) ts))

-- | Soft-delete a user and kill their sessions. Reachable from either live status.
deleteUser ::
  (UserStore :> es, SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId ->
  UserId ->
  Eff es (Either AuthError ())
deleteUser actingAdmin target =
  transition target [UserActive, UserSuspended] UserDeleted \ts -> do
    revokeAllUserSessions target ts
    publishAuthEvent (Event.UserDeleted (Event.UserDeletedData target (Just actingAdmin) ts))

-- | Look the target up, check it is in one of @allowed@, move it to @newStatus@, and run
-- @after@. The shared skeleton of the three lifecycle transitions.
transition ::
  (UserStore :> es, Clock :> es) =>
  UserId ->
  [UserStatus] ->
  UserStatus ->
  (UTCTime -> Eff es ()) ->
  Eff es (Either AuthError ())
transition target allowed newStatus after = do
  mUser <- findUserById target
  case mUser of
    Nothing -> pure (Left UserNotFound)
    Just user
      | user.status `notElem` allowed -> pure (Left InvalidUserStatus)
      | otherwise -> do
          ts <- now
          updateUserStatus target newStatus
          after ts
          pure (Right ())

-- | Revoke every /active/ session of a user, returning how many were revoked.
--
-- Already-revoked and expired sessions are skipped rather than re-revoked, so the count is the
-- number of sessions this call actually ended and the audit trail carries no duplicate
-- revocations for a session that was already dead.
revokeUserSessions ::
  (SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId ->
  UserId ->
  Eff es (Either AuthError Int)
revokeUserSessions actingAdmin target = do
  sessions <- listSessionsForUser target
  ts <- now
  let active = [s | s <- sessions, s.status == SessionActive]
  forM_ active \s -> do
    revokeSession s.sessionId ts
    publishAuthEvent (Event.SessionRevoked (Event.SessionRevokedData s.sessionId (Just actingAdmin) ts))
  pure (Right (length active))

-- | Revoke one session by id, whoever owns it.
revokeOneSession ::
  (SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId ->
  SessionId ->
  Eff es (Either AuthError ())
revokeOneSession actingAdmin sid = do
  mSession <- findSessionById sid
  case mSession of
    Nothing -> pure (Left SessionNotFound)
    Just _ -> do
      ts <- now
      revokeSession sid ts
      publishAuthEvent (Event.SessionRevoked (Event.SessionRevokedData sid (Just actingAdmin) ts))
      pure (Right ())
