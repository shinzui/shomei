-- | The error vocabulary of the authentication core.
--
-- 'AuthError' is the single error type returned by every workflow. 'TokenError' is the
-- narrower set of JWT-verification failures (interpreted by EP-4's verifier and wrapped
-- in 'TokenInvalid'). 'PasswordPolicyViolation' is the reason a password failed the
-- policy check.
module Shomei.Error
  ( AuthError (..),
    TokenError (..),
    PasswordPolicyViolation (..),
  )
where

import Shomei.Effect.WebAuthnCeremony (WebAuthnError)
import Shomei.Prelude

data PasswordPolicyViolation
  = -- | minimum length required
    PasswordTooShort Int
  | -- | maximum length allowed
    PasswordTooLong Int
  | -- | the password appears in the bundled common-password dictionary
    PasswordTooCommon
  | PasswordMissingRequiredClass Text
  | -- | the password is essentially the user's own identity (email local-part,
    -- full email, or display name)
    PasswordResemblesIdentity
  | -- | the password appears in a known public breach (HIBP). EP-3.
    PasswordBreached
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TokenError
  = TokenMalformed
  | TokenSignatureInvalid
  | TokenExpired
  | TokenIssuerInvalid
  | TokenAudienceInvalid
  | TokenOtherError Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AuthError
  = InvalidEmail
  | -- | The supplied login identifier was empty or contained internal whitespace.
    InvalidLoginId
  | WeakPassword PasswordPolicyViolation
  | EmailAlreadyRegistered
  | -- | A user already exists with the requested login identifier (the principal
    -- collision check; the generic counterpart to 'EmailAlreadyRegistered').
    LoginIdAlreadyRegistered
  | InvalidCredentials
  | UserNotActive
  | SessionNotFound
  | SessionExpired
  | SessionRevoked
  | RefreshTokenInvalid
  | RefreshTokenExpired
  | RefreshTokenReuseDetected
  | VerificationTokenInvalid
  | PasswordResetTokenInvalid
  | EmailAlreadyVerified
  | -- | Token issuance was refused because runtime configuration requires a verified email
    -- and the account's email is present but unverified. Maps to 403.
    --
    -- Deliberately distinct from 'InvalidCredentials': every path that can raise it has
    -- already proven control of the account (a correct password, a valid refresh token, or
    -- a verified passkey assertion), so naming the reason leaks no existence information —
    -- while a generic 401 would strand a legitimate user with no idea they must click the
    -- verification link.
    EmailNotVerified
  | -- | INTERNAL audit signal raised when a login hits a locked account; the HTTP layer
    --       maps it to the SAME generic 401 as 'InvalidCredentials' so a locked account is
    --       indistinguishable from a wrong password. (The 'Shomei.Workflow.login' workflow itself
    --       returns 'InvalidCredentials' for the locked case so even a direct core caller cannot
    --       distinguish; 'AccountLocked' exists for completeness and future internal use.)
    AccountLocked
  | -- | The per-IP failure throttle tripped; the HTTP layer maps it to 429.
    TooManyRequests
  | TokenInvalid TokenError
  | -- | A WebAuthn registration verification failed (bad attestation, origin/challenge
    -- mismatch, or malformed credential JSON). The HTTP layer maps this to 400.
    WebAuthnCeremonyError WebAuthnError
  | -- | No passkey with the given id is owned by the requesting user. Maps to 404.
    PasskeyNotFound
  | -- | The pending ceremony was missing, already consumed, or expired. Maps to 404.
    PendingCeremonyNotFound
  | -- | A WebAuthn login/step-up assertion failed verification (bad signature, clone
    -- counter, user-not-present, or a credential not owned by the expected user). The
    -- HTTP layer maps this to a generic 401 so nothing about the failure leaks.
    MfaAssertionInvalid
  | -- | The caller may not start impersonation: they lack the @impersonate:user@ scope
    -- or their own access token is older than the freshness window. Maps to 403.
    ImpersonationForbidden
  | -- | The impersonation target is missing, not active, or is the caller themselves.
    -- Maps to 400.
    ImpersonationTargetInvalid
  | -- | A credential-changing action was attempted under a delegated (impersonation)
    -- token. Maps to 403.
    ImpersonationActionBlocked
  | -- | Service-token issuance is disabled in runtime configuration. Maps to 403.
    ServiceTokenDisabled
  | -- | No configured service account matched the presented id. Maps to 403.
    ServiceAccountNotFound
  | -- | The presented service-account secret did not match the configured SHA-256 hash. Maps to 403.
    ServiceAccountSecretInvalid
  | -- | The request asked for no scopes or for scopes outside the account's allow-list. Maps to 403.
    ServiceTokenScopeDenied
  | -- | The configured service-account user or requested actor user is missing or inactive. Maps to 400.
    ServiceTokenActorInvalid
  | InternalAuthError Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
