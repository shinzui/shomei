{- | Reconstruct a typed 'AuthEvent' from the @(event_type, payload)@ columns the write
path stores in @shomei_auth_events@.

The write interpreter ('Shomei.Postgres.AuthEventPublisher.projectAuthEvent') stores only
the inner @*Data@ record as the JSONB @payload@ (via @toJSON d@), with the constructor
identity captured separately in the @event_type@ text column. A naive
@fromJSON payload :: Result AuthEvent@ therefore cannot work — the payload is not the
tagged sum. 'reconstructAuthEvent' dispatches on @event_type@ and decodes the payload into
the matching @*Data@ record, mirroring the write path's constructor-to-type mapping. It is
fully backward compatible with every row already in the table and requires no migration.

The @*Data@ records derive @FromJSON@/@ToJSON@ with default options (they do NOT use
'eventAesonOptions'), so the payload is decoded with the plain default instances — exactly
what was written.
-}
module Shomei.Domain.EventCodec (
    reconstructAuthEvent,
) where

import Shomei.Prelude

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text

import Shomei.Domain.Event

{- | Reconstruct a typed event. The @event_type@ strings are the exact ones the writer
emits (see 'Shomei.Postgres.AuthEventPublisher.projectAuthEvent'); keep the two in lockstep.
A 'Left' means either an unknown @event_type@ or a payload that does not decode into the
expected @*Data@ record.
-}
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
    other -> Left ("unknown event_type: " <> Text.unpack other)
  where
    parse :: (Aeson.FromJSON a) => Aeson.Value -> Either String a
    parse v = case Aeson.fromJSON v of
        Aeson.Success a -> Right a
        Aeson.Error e -> Left e
