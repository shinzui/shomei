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
    TotpEnrolledData (..),
    TotpRemovedData (..),
    RecoveryCodesGeneratedData (..),
    RecoveryCodeUsedData (..),
    ImpersonationStartedData (..),
    ImpersonationStoppedData (..),
    ImpersonationActionBlockedData (..),
    ServiceOnBehalfIssuedData (..),
    ServiceTokenIssuedData (..),
    RoleGrantedData (..),
    RoleRevokedData (..),
    ServiceAccountCreatedData (..),
    ServiceAccountSecretRotatedData (..),
    ServiceAccountRevokedData (..),
    OAuthClientCreatedData (..),
    OAuthClientRevokedData (..),
    OAuthCodeIssuedData (..),
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

-- | A user activated a TOTP second factor (EP-7): a confirmed credential now exists.
data TotpEnrolledData = TotpEnrolledData
  { userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A user removed their TOTP second factor (EP-7). Removal proves possession of the factor
-- (a current code) or its fallback (a recovery code), and is blocked under a delegated token.
data TotpRemovedData = TotpRemovedData
  { userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A fresh set of recovery codes was generated (EP-7), invalidating any previous set. 'count'
-- is how many were issued; the codes themselves are never in the payload (only their hashes are
-- ever persisted, and not here).
data RecoveryCodesGeneratedData = RecoveryCodesGeneratedData
  { userId :: !UserId,
    count :: !Int,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A recovery code was spent to complete an MFA challenge (EP-7). Single-use: the code cannot
-- complete a second challenge.
data RecoveryCodeUsedData = RecoveryCodeUsedData
  { userId :: !UserId,
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

-- | EP-6: a service account exchanged a user's access token for a narrowed, short-lived token that
-- acts on the user's behalf (RFC 8693 on-behalf-of). Carries the subject (the user, whose id is the
-- audit row's @user_id@ column), the actor (the service account's backing user, in @act@), the
-- delegated session, and the scopes actually granted after narrowing. The @token-exchange:subject@
-- gate scope is never among them.
data ServiceOnBehalfIssuedData = ServiceOnBehalfIssuedData
  { -- | the service account's TypeID text (@client_id@) that requested the exchange
    serviceAccountId :: !Text,
    -- | the service account's backing user, recorded in the issued token's @act@
    actorUserId :: !UserId,
    -- | the user the token now represents (@sub@)
    subjectUserId :: !UserId,
    sessionId :: !SessionId,
    scopes :: !(Set Scope),
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

-- | A database-backed service account was created (EP-4). 'serviceAccountId' is the TypeID text,
-- equal to 'clientId'; both are recorded so a reader need not know they coincide. The secret is
-- never in the payload — only its SHA-256 digest is ever persisted, and not here.
--
-- 'userId' is the account's backing @shomei_users@ row, and becomes the audit row's @user_id@
-- column, so @?user=@ filtering finds an account's whole lifecycle alongside the tokens it minted.
data ServiceAccountCreatedData = ServiceAccountCreatedData
  { serviceAccountId :: !Text,
    clientId :: !Text,
    userId :: !UserId,
    displayName :: !Text,
    allowedScopes :: !(Set Scope),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A service account's secret was replaced. The previous secret stops working immediately:
-- the model is single-secret, so an operator needing overlap creates a second account.
data ServiceAccountSecretRotatedData = ServiceAccountSecretRotatedData
  { serviceAccountId :: !Text,
    clientId :: !Text,
    userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A service account was revoked. Its row survives; every subsequent @client_credentials@
-- request answers @invalid_client@, indistinguishable from a wrong secret.
data ServiceAccountRevokedData = ServiceAccountRevokedData
  { serviceAccountId :: !Text,
    clientId :: !Text,
    userId :: !UserId,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | An OAuth2 \/ OIDC client was registered (EP-5). The secret is never in the payload — only
-- its SHA-256 digest is ever persisted, and not here. A public client has no secret at all.
--
-- Unlike a service account, an OAuth client has no backing user row, so these events carry no
-- @user_id@ and the audit row's @user_id@ column stays NULL: the client is not a principal, it
-- is a registered relying party.
data OAuthClientCreatedData = OAuthClientCreatedData
  { oauthClientId :: !Text,
    clientId :: !Text,
    clientType :: !Text,
    displayName :: !Text,
    redirectUris :: ![Text],
    allowedScopes :: !(Set Scope),
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | An OAuth client was revoked. Its row survives; every subsequent authorize request answers
-- @400 invalid_request@ without redirecting, and every token exchange answers @invalid_client@.
data OAuthClientRevokedData = OAuthClientRevokedData
  { oauthClientId :: !Text,
    clientId :: !Text,
    occurredAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | An authorization code was issued to a client for a user (EP-5). The code itself is never in
-- the payload — not even its hash: a code lives 60 seconds and naming it here would put a
-- short-lived credential's identifier in a long-lived table.
--
-- The row's @user_id@ is the subject the code was issued for, so @?user=@ finds the whole
-- authorization: the code, the session the exchange started, and the tokens it minted.
data OAuthCodeIssuedData = OAuthCodeIssuedData
  { clientId :: !Text,
    userId :: !UserId,
    scopes :: !(Set Scope),
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
  | TotpEnrolled TotpEnrolledData
  | TotpRemoved TotpRemovedData
  | RecoveryCodesGenerated RecoveryCodesGeneratedData
  | RecoveryCodeUsed RecoveryCodeUsedData
  | ImpersonationStarted ImpersonationStartedData
  | ImpersonationStopped ImpersonationStoppedData
  | ImpersonationActionBlocked ImpersonationActionBlockedData
  | ServiceOnBehalfIssued ServiceOnBehalfIssuedData
  | ServiceTokenIssued ServiceTokenIssuedData
  | RoleGranted RoleGrantedData
  | RoleRevoked RoleRevokedData
  | ServiceAccountCreated ServiceAccountCreatedData
  | ServiceAccountSecretRotated ServiceAccountSecretRotatedData
  | ServiceAccountRevoked ServiceAccountRevokedData
  | OAuthClientCreated OAuthClientCreatedData
  | OAuthClientRevoked OAuthClientRevokedData
  | OAuthCodeIssued OAuthCodeIssuedData
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
