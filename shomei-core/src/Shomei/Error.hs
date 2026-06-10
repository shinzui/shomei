{- | The error vocabulary of the authentication core.

'AuthError' is the single error type returned by every workflow. 'TokenError' is the
narrower set of JWT-verification failures (interpreted by EP-4's verifier and wrapped
in 'TokenInvalid'). 'PasswordPolicyViolation' is the reason a password failed the
policy check.
-}
module Shomei.Error (
    AuthError (..),
    TokenError (..),
    PasswordPolicyViolation (..),
) where

import Shomei.Prelude

data PasswordPolicyViolation
    = -- | minimum length required
      PasswordTooShort Int
    | -- | maximum length allowed
      PasswordTooLong Int
    | PasswordTooCommon
    | PasswordMissingRequiredClass Text
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
    | WeakPassword PasswordPolicyViolation
    | EmailAlreadyRegistered
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
    | {- | INTERNAL audit signal raised when a login hits a locked account; the HTTP layer
      maps it to the SAME generic 401 as 'InvalidCredentials' so a locked account is
      indistinguishable from a wrong password. (The 'Shomei.Workflow.login' workflow itself
      returns 'InvalidCredentials' for the locked case so even a direct core caller cannot
      distinguish; 'AccountLocked' exists for completeness and future internal use.)
      -}
      AccountLocked
    | -- | The per-IP failure throttle tripped; the HTTP layer maps it to 429.
      TooManyRequests
    | TokenInvalid TokenError
    | InternalAuthError Text
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
