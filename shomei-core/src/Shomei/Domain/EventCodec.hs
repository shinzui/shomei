-- | Reconstruct a typed 'AuthEvent' from the @(event_type, payload)@ columns the write
-- path stores in @shomei_auth_events@.
--
-- The write interpreter ('Shomei.Postgres.AuthEventPublisher.projectAuthEvent') stores only
-- the inner @*Data@ record as the JSONB @payload@ (via @toJSON d@), with the constructor
-- identity captured separately in the @event_type@ text column. A naive
-- @fromJSON payload :: Result AuthEvent@ therefore cannot work — the payload is not the
-- tagged sum. 'reconstructAuthEvent' dispatches on @event_type@ and decodes the payload into
-- the matching @*Data@ record, mirroring the write path's constructor-to-type mapping. It is
-- fully backward compatible with every row already in the table and requires no migration.
--
-- The @*Data@ records derive @FromJSON@/@ToJSON@ with default options (they do NOT use
-- 'eventAesonOptions'), so the payload is decoded with the plain default instances — exactly
-- what was written.
module Shomei.Domain.EventCodec
  ( reconstructAuthEvent,
    projectAuthEvent,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.UUID (UUID)
import Shomei.Domain.Event
import Shomei.Id (sessionIdToUUID, userIdToUUID)
import Shomei.Prelude

-- | Reconstruct a typed event. The @event_type@ strings are the exact ones the writer
-- emits (see 'Shomei.Postgres.AuthEventPublisher.projectAuthEvent'); keep the two in lockstep.
-- A 'Left' means either an unknown @event_type@ or a payload that does not decode into the
-- expected @*Data@ record.
reconstructAuthEvent :: Text -> Aeson.Value -> Either String AuthEvent
reconstructAuthEvent etype payload = case etype of
  "user_registered" -> UserRegistered <$> parse payload
  "login_succeeded" -> LoginSucceeded <$> parse payload
  "login_failed" -> LoginFailed <$> parse payload
  "session_started" -> SessionStarted <$> parse payload
  "session_revoked" -> SessionRevoked <$> parse payload
  "refresh_token_rotated" -> RefreshTokenRotated <$> parse payload
  "refresh_token_reuse_detected" -> RefreshTokenReuseDetected <$> parse payload
  "email_verification_requested" -> EmailVerificationRequested <$> parse payload
  "email_verified" -> EmailVerified <$> parse payload
  "password_reset_requested" -> PasswordResetRequested <$> parse payload
  "password_reset_completed" -> PasswordResetCompleted <$> parse payload
  "password_changed" -> PasswordChanged <$> parse payload
  "user_suspended" -> UserSuspended <$> parse payload
  "user_deleted" -> UserDeleted <$> parse payload
  "account_locked" -> AccountLocked <$> parse payload
  "login_throttled" -> LoginThrottled <$> parse payload
  "passkey_registered" -> PasskeyRegistered <$> parse payload
  "passkey_removed" -> PasskeyRemoved <$> parse payload
  "mfa_challenged" -> MfaChallenged <$> parse payload
  "mfa_succeeded" -> MfaSucceeded <$> parse payload
  "mfa_failed" -> MfaFailed <$> parse payload
  "impersonation_started" -> ImpersonationStarted <$> parse payload
  "impersonation_stopped" -> ImpersonationStopped <$> parse payload
  "impersonation_action_blocked" -> ImpersonationActionBlocked <$> parse payload
  "service_token_issued" -> ServiceTokenIssued <$> parse payload
  other -> Left ("unknown event_type: " <> Text.unpack other)
  where
    parse :: (Aeson.FromJSON a) => Aeson.Value -> Either String a
    parse v = case Aeson.fromJSON v of
      Aeson.Success a -> Right a
      Aeson.Error e -> Left e

-- | Project an 'AuthEvent' to the envelope columns the audit trail stores:
-- @(user_id?, session_id?, event_type, payload, occurredAt)@, where @payload = toJSON@ of the
-- inner @*Data@ record. This is the inverse of 'reconstructAuthEvent' and the single source of
-- truth for the constructor→@event_type@ mapping; the PostgreSQL writer
-- ('Shomei.Postgres.AuthEventPublisher') and the in-memory reader both use it, and the
-- round-trip spec pins @project → reconstruct@ for every constructor. (The writer adds a fresh
-- random @event_id@; that is not part of the projection.)
projectAuthEvent :: AuthEvent -> (Maybe UUID, Maybe UUID, Text, Value, UTCTime)
projectAuthEvent = \case
  UserRegistered d@(UserRegisteredData uid _ _ occ) ->
    (Just (userIdToUUID uid), Nothing, "user_registered", toJSON d, occ)
  LoginSucceeded d@(LoginSucceededData uid sid occ) ->
    (Just (userIdToUUID uid), Just (sessionIdToUUID sid), "login_succeeded", toJSON d, occ)
  LoginFailed d@(LoginFailedData _ occ) ->
    (Nothing, Nothing, "login_failed", toJSON d, occ)
  SessionStarted d@(SessionStartedData sid uid occ) ->
    (Just (userIdToUUID uid), Just (sessionIdToUUID sid), "session_started", toJSON d, occ)
  SessionRevoked d@(SessionRevokedData sid occ) ->
    (Nothing, Just (sessionIdToUUID sid), "session_revoked", toJSON d, occ)
  RefreshTokenRotated d@(RefreshTokenRotatedData sid _ occ) ->
    (Nothing, Just (sessionIdToUUID sid), "refresh_token_rotated", toJSON d, occ)
  RefreshTokenReuseDetected d@(RefreshTokenReuseDetectedData sid _ occ) ->
    (Nothing, Just (sessionIdToUUID sid), "refresh_token_reuse_detected", toJSON d, occ)
  EmailVerificationRequested d@(EmailVerificationRequestedData uid _ occ) ->
    (Just (userIdToUUID uid), Nothing, "email_verification_requested", toJSON d, occ)
  EmailVerified d@(EmailVerifiedData uid _ occ) ->
    (Just (userIdToUUID uid), Nothing, "email_verified", toJSON d, occ)
  PasswordResetRequested d@(PasswordResetRequestedData uid _ occ) ->
    (Just (userIdToUUID uid), Nothing, "password_reset_requested", toJSON d, occ)
  PasswordResetCompleted d@(PasswordResetCompletedData uid occ) ->
    (Just (userIdToUUID uid), Nothing, "password_reset_completed", toJSON d, occ)
  PasswordChanged d@(PasswordChangedData uid occ) ->
    (Just (userIdToUUID uid), Nothing, "password_changed", toJSON d, occ)
  UserSuspended d@(UserSuspendedData uid occ) ->
    (Just (userIdToUUID uid), Nothing, "user_suspended", toJSON d, occ)
  UserDeleted d@(UserDeletedData uid occ) ->
    (Just (userIdToUUID uid), Nothing, "user_deleted", toJSON d, occ)
  AccountLocked d@(AccountLockedData _ _ _ _ occ) ->
    (Nothing, Nothing, "account_locked", toJSON d, occ)
  LoginThrottled d@(LoginThrottledData _ _ occ) ->
    (Nothing, Nothing, "login_throttled", toJSON d, occ)
  PasskeyRegistered d@(PasskeyRegisteredData uid _ occ) ->
    (Just (userIdToUUID uid), Nothing, "passkey_registered", toJSON d, occ)
  PasskeyRemoved d@(PasskeyRemovedData uid _ occ) ->
    (Just (userIdToUUID uid), Nothing, "passkey_removed", toJSON d, occ)
  MfaChallenged d@(MfaChallengedData uid _ occ) ->
    (Just (userIdToUUID uid), Nothing, "mfa_challenged", toJSON d, occ)
  MfaSucceeded d@(MfaSucceededData uid sid occ) ->
    (Just (userIdToUUID uid), Just (sessionIdToUUID sid), "mfa_succeeded", toJSON d, occ)
  MfaFailed d@(MfaFailedData mUid _ occ) ->
    (fmap userIdToUUID mUid, Nothing, "mfa_failed", toJSON d, occ)
  -- For impersonation events the subject (customer) is the row's user_id; the actor
  -- (operator) and reason/ticket live inside the JSONB payload.
  ImpersonationStarted d ->
    (Just (userIdToUUID d.subjectUserId), Just (sessionIdToUUID d.sessionId), "impersonation_started", toJSON d, d.occurredAt)
  ImpersonationStopped d ->
    (Just (userIdToUUID d.subjectUserId), Just (sessionIdToUUID d.sessionId), "impersonation_stopped", toJSON d, d.occurredAt)
  ImpersonationActionBlocked d ->
    (Just (userIdToUUID d.subjectUserId), Just (sessionIdToUUID d.sessionId), "impersonation_action_blocked", toJSON d, d.occurredAt)
  ServiceTokenIssued d ->
    (Just (userIdToUUID d.userId), Just (sessionIdToUUID d.sessionId), "service_token_issued", toJSON d, d.occurredAt)
