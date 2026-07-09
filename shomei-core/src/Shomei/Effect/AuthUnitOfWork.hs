{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The transactional unit-of-work port: the multi-table write tails that must be atomic.
--
-- Every other store port in this package is one effect per table, and each of its operations
-- is one SQL statement in its own database round-trip. That is the right shape for reads and
-- for standalone writes, but it is wrong for the write /tails/ of the authentication
-- workflows, where several inserts must either all land or none of them do. Persisting a
-- session but not its refresh token leaves a row nothing can ever use; marking a refresh token
-- used but failing to insert its replacement logs the user out mid-rotation.
--
-- This port names those tails as single operations. The PostgreSQL interpreter
-- (@Shomei.Postgres.AuthUnitOfWork@) runs each one inside a single @BEGIN … COMMIT@; the
-- in-memory interpreter ('Shomei.Effect.InMemory') performs the equivalent update to its
-- mutable world in one atomic step. The per-table ports remain, because the workflows that do
-- not have this atomicity requirement (logout, revocation, impersonation, admin) still use
-- them.
module Shomei.Effect.AuthUnitOfWork
  ( AuthUnitOfWork (..),
    NewSessionToken (..),
    RotationOutcome (..),
    persistNewSession,
    rotateRefreshToken,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Event (AuthEvent)
import Shomei.Domain.RefreshToken (NewRefreshToken, PersistedRefreshToken, RefreshTokenHash)
import Shomei.Domain.Session (NewSession, Session)
import Shomei.Id (RefreshTokenId, SessionId)
import Shomei.Prelude

-- | The refresh-token half of a brand-new session, minus the session id.
--
-- The session id is absent because the caller does not know it yet: it is generated inside the
-- interpreter, exactly as @CreateSession@ generates it today. The interpreter fills it in when
-- it builds the token row.
data NewSessionToken = NewSessionToken
  { tokenHash :: !RefreshTokenHash,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | The result of an atomic refresh-token rotation.
--
-- 'RotationConflict' means the compare-and-swap that transitions the presented token
-- @active → used@ matched no row, i.e. some other request already spent it. That is
-- indistinguishable from a stolen token being replayed, so callers treat it as reuse. It is a
-- /signal/, not an error: the transaction simply did not rotate, and no replacement token was
-- inserted. Callers must never re-read the token to "confirm" this — the conflict is the
-- confirmation.
data RotationOutcome
  = Rotated !PersistedRefreshToken
  | RotationConflict
  deriving stock (Generic, Eq, Show)

data AuthUnitOfWork :: Effect where
  -- | Insert a session, its first refresh token, and the audit events built from the
  -- generated session id — atomically. Returns the persisted session and token.
  --
  -- The events arrive as a function of the session id rather than as a list because the id is
  -- generated inside the interpreter, yet the events must name it: signup publishes
  -- @UserRegistered@ + @SessionStarted@, login and MFA completion publish @LoginSucceeded@ +
  -- @SessionStarted@. The builder lets each caller author its own events in the workflow layer
  -- while the interpreter supplies the id.
  PersistNewSession ::
    NewSession ->
    NewSessionToken ->
    (SessionId -> [AuthEvent]) ->
    AuthUnitOfWork m (Session, PersistedRefreshToken)
  -- | Mark the presented refresh token used, insert its replacement, and record the rotation
  -- event — atomically. The 'UTCTime' is the @used_at@ stamp for the token being retired.
  --
  -- Yields 'RotationConflict' without inserting anything when the presented token was no
  -- longer active.
  RotateRefreshToken ::
    RefreshTokenId ->
    UTCTime ->
    NewRefreshToken ->
    AuthEvent ->
    AuthUnitOfWork m RotationOutcome

type instance DispatchOf AuthUnitOfWork = Dynamic

-- | Atomically persist a new session, its first refresh token, and the events naming it.
persistNewSession ::
  (AuthUnitOfWork :> es) =>
  NewSession ->
  NewSessionToken ->
  (SessionId -> [AuthEvent]) ->
  Eff es (Session, PersistedRefreshToken)
persistNewSession ns nst mkEvents = send (PersistNewSession ns nst mkEvents)

-- | Atomically retire a refresh token and issue its replacement, or report a conflict.
rotateRefreshToken ::
  (AuthUnitOfWork :> es) =>
  RefreshTokenId ->
  UTCTime ->
  NewRefreshToken ->
  AuthEvent ->
  Eff es RotationOutcome
rotateRefreshToken rid usedAt nrt ev = send (RotateRefreshToken rid usedAt nrt ev)
