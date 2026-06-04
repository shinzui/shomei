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
    | TokenInvalid TokenError
    | InternalAuthError Text
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
