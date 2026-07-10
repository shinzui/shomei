-- | The audit / security event vocabulary.
--
-- 'AuthEvent' is the sum of everything worth recording for audit and intrusion
-- detection. Each arm carries a @*Data@ record with the relevant identifiers and the
-- @occurredAt@ timestamp. The 'Shomei.Effect.AuthEventPublisher' port publishes them; in
-- the bootstrap EP-3 persists them to the @shomei_auth_events@ table.
--
-- Note: several constructor names (e.g. 'SessionRevoked', 'RefreshTokenReuseDetected')
-- intentionally mirror 'Shomei.Error.AuthError' constructors and domain status
-- constructors. Consumers import this module qualified to disambiguate.
module Shomei.Domain.Event
  ( AuthEvent (..),
    UserRegisteredData (..),
    LoginSucceededData (..),
    LoginFailedData (..),
    SessionStartedData (..),
    SessionRevokedData (..),
    RefreshTokenRotatedData (..),
    RefreshTokenReuseDetectedData (..),
    EmailVerificationRequestedData (..),
    EmailVerifiedData (..),
    PasswordResetRequestedData (..),
    PasswordResetCompletedData (..),
    PasswordChangedData (..),
    UserSuspendedData (..),
    UserDeletedData (..),
    UserReinstatedData (..),
    AccountLockedData (..),
    LoginThrottledData (..),
    PasskeyRegisteredData (..),
    PasskeyRemovedData (..),
    MfaChallengedData (..),
    MfaSucceededData (..),
    MfaFailedData (..),
    ImpersonationStartedData (..),
    ImpersonationStoppedData (..),
    ImpersonationActionBlockedData (..),
    ServiceTokenIssuedData (..),
    RoleGrantedData (..),
    RoleRevokedData (..),
  )
where

import Data.Set (Set)
import Shomei.Config (ServiceAccountId)
import Shomei.Domain.Claims (Role, Scope)
import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginAttempt (AccountKey, ClientIp)
import Shomei.Domain.LoginId (LoginId)
import Shomei.Id (CeremonyId, PasskeyId, RefreshTokenId, SessionId, UserId)
import Shomei.Prelude

data UserRegisteredData = UserRegisteredData
  { userId :: !UserId,
    loginId :: !LoginId,
    email :: !(Maybe Email),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data LoginSucceededData = LoginSucceededData
  { userId :: !UserId,
    sessionId :: !SessionId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data LoginFailedData = LoginFailedData
  { loginId :: !LoginId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SessionStartedData = SessionStartedData
  { sessionId :: !SessionId,
    userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | @revokedBy@ names the admin who revoked the session through the EP-2 admin API; it is
-- 'Nothing' for the self-service revocations (logout, refresh-token reuse detection, stopping an
-- impersonation). A missing key in a historical row decodes as 'Nothing', which is what those
-- rows mean.
data SessionRevokedData = SessionRevokedData
  { sessionId :: !SessionId,
    revokedBy :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RefreshTokenRotatedData = RefreshTokenRotatedData
  { sessionId :: !SessionId,
    oldTokenId :: !RefreshTokenId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RefreshTokenReuseDetectedData = RefreshTokenReuseDetectedData
  { sessionId :: !SessionId,
    refreshTokenId :: !RefreshTokenId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data EmailVerificationRequestedData = EmailVerificationRequestedData
  { userId :: !UserId,
    email :: !Email,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data EmailVerifiedData = EmailVerifiedData
  { userId :: !UserId,
    email :: !Email,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data PasswordResetRequestedData = PasswordResetRequestedData
  { userId :: !UserId,
    email :: !Email,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data PasswordResetCompletedData = PasswordResetCompletedData
  { userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data PasswordChangedData = PasswordChangedData
  { userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | @actor@ is the administrator who performed the lifecycle change. It is a 'Maybe' because a
-- future non-HTTP caller (a CLI, a migration) may have no acting principal — not because the
-- admin API ever omits it.
data UserSuspendedData = UserSuspendedData
  { userId :: !UserId,
    actor :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data UserDeletedData = UserDeletedData
  { userId :: !UserId,
    actor :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A suspended user was returned to service.
data UserReinstatedData = UserReinstatedData
  { userId :: !UserId,
    actor :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AccountLockedData = AccountLockedData
  { accountKey :: !AccountKey,
    clientIp :: !ClientIp,
    failedCount :: !Int,
    lockedUntil :: !UTCTime,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data LoginThrottledData = LoginThrottledData
  { clientIp :: !ClientIp,
    failedCount :: !Int,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data PasskeyRegisteredData = PasskeyRegisteredData
  { userId :: !UserId,
    passkeyId :: !PasskeyId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data PasskeyRemovedData = PasskeyRemovedData
  { userId :: !UserId,
    passkeyId :: !PasskeyId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A password login succeeded for an account with a passkey, so a WebAuthn
-- second factor is now demanded (no session issued yet). 'ceremonyId' is the
-- consume-once pending-MFA handle the client completes at @\/v1\/auth\/mfa\/complete@.
data MfaChallengedData = MfaChallengedData
  { userId :: !UserId,
    ceremonyId :: !CeremonyId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The WebAuthn second factor (or a passwordless passkey login) verified and a
-- session was issued.
data MfaSucceededData = MfaSucceededData
  { userId :: !UserId,
    sessionId :: !SessionId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A WebAuthn assertion failed verification at login/step-up. 'userId' is
-- 'Nothing' when the user could not be resolved (e.g. a passwordless assertion
-- naming an unknown credential).
data MfaFailedData = MfaFailedData
  { userId :: !(Maybe UserId),
    reason :: !Text,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | An operator started impersonating a subject: a delegated session was minted.
-- Carries both identities, the required reason, the optional support ticket id, and
-- the client IP for the audit trail.
data ImpersonationStartedData = ImpersonationStartedData
  { actorUserId :: !UserId,
    subjectUserId :: !UserId,
    sessionId :: !SessionId,
    reason :: !Text,
    ticketId :: !(Maybe Text),
    clientIp :: !(Maybe Text),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | An operator stopped impersonating: the delegated session was revoked.
data ImpersonationStoppedData = ImpersonationStoppedData
  { actorUserId :: !UserId,
    subjectUserId :: !UserId,
    sessionId :: !SessionId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A credential-changing action was refused because it arrived on a delegated token.
data ImpersonationActionBlockedData = ImpersonationActionBlockedData
  { actorUserId :: !UserId,
    subjectUserId :: !UserId,
    sessionId :: !SessionId,
    -- | e.g. @"password_change"@, @"passkey_register"@, @"passkey_remove"@
    action :: !Text,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data ServiceTokenIssuedData = ServiceTokenIssuedData
  { userId :: !UserId,
    sessionId :: !SessionId,
    accountId :: !ServiceAccountId,
    scopes :: !(Set Scope),
    actorId :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A role was granted to a user. 'grantedBy' is the acting admin, or 'Nothing' for a CLI
-- bootstrap grant and for a default role applied at signup (the "system" actor).
--
-- Role /definitions/ are not audit events: they are rare, low-sensitivity catalog metadata.
-- Grants and revocations — the security-relevant facts — are.
data RoleGrantedData = RoleGrantedData
  { userId :: !UserId,
    role :: !Role,
    grantedBy :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A role grant was removed. 'revokedBy' is 'Nothing' for a CLI revocation.
data RoleRevokedData = RoleRevokedData
  { userId :: !UserId,
    role :: !Role,
    revokedBy :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AuthEvent
  = UserRegistered UserRegisteredData
  | LoginSucceeded LoginSucceededData
  | LoginFailed LoginFailedData
  | SessionStarted SessionStartedData
  | SessionRevoked SessionRevokedData
  | RefreshTokenRotated RefreshTokenRotatedData
  | RefreshTokenReuseDetected RefreshTokenReuseDetectedData
  | EmailVerificationRequested EmailVerificationRequestedData
  | EmailVerified EmailVerifiedData
  | PasswordResetRequested PasswordResetRequestedData
  | PasswordResetCompleted PasswordResetCompletedData
  | PasswordChanged PasswordChangedData
  | UserSuspended UserSuspendedData
  | UserDeleted UserDeletedData
  | UserReinstated UserReinstatedData
  | AccountLocked AccountLockedData
  | LoginThrottled LoginThrottledData
  | PasskeyRegistered PasskeyRegisteredData
  | PasskeyRemoved PasskeyRemovedData
  | MfaChallenged MfaChallengedData
  | MfaSucceeded MfaSucceededData
  | MfaFailed MfaFailedData
  | ImpersonationStarted ImpersonationStartedData
  | ImpersonationStopped ImpersonationStoppedData
  | ImpersonationActionBlocked ImpersonationActionBlockedData
  | ServiceTokenIssued ServiceTokenIssuedData
  | RoleGranted RoleGrantedData
  | RoleRevoked RoleRevokedData
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
