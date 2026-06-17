{- | The single mapping from the domain 'AuthError' to servant's 'ServerError',
with a structured JSON body @{"error":<code>,"message":<text>}@.

Never leaks internal detail: 'InvalidCredentials' and 'UserNotActive' both collapse
to the same generic @401 "Invalid email or password"@ so account existence and
status are not disclosed, and 'InternalAuthError' carries no detail to the client.
-}
module Shomei.Servant.Error (
    authErrorToServerError,
) where

import Shomei.Prelude

import Data.Aeson qualified as Aeson

import Servant (
    ServerError (..),
    err400,
    err401,
    err403,
    err404,
    err409,
    err500,
 )

import Shomei.Error (AuthError (..))

{- | HTTP 429 Too Many Requests. Servant ships no @err429@ constant, so we build it from the
same shape as the other @errNNN@ values.
-}
err429 :: ServerError
err429 =
    ServerError
        { errHTTPCode = 429
        , errReasonPhrase = "Too Many Requests"
        , errBody = ""
        , errHeaders = []
        }

authErrorToServerError :: AuthError -> ServerError
authErrorToServerError = \case
    InvalidEmail -> json err400 "invalid_email" "Email is not valid"
    WeakPassword _ -> json err400 "weak_password" "Password does not meet policy"
    EmailAlreadyRegistered -> json err409 "email_taken" "Email is already registered"
    InvalidCredentials -> json err401 "invalid_login" "Invalid email or password"
    UserNotActive -> json err401 "invalid_login" "Invalid email or password"
    AccountLocked -> json err401 "invalid_login" "Invalid email or password"
    TooManyRequests -> json err429 "too_many_requests" "Too many requests"
    SessionNotFound -> json err404 "session_not_found" "Session not found"
    SessionExpired -> json err401 "session_expired" "Session expired"
    SessionRevoked -> json err401 "session_revoked" "Session revoked"
    RefreshTokenInvalid -> json err401 "token_invalid" "Refresh token is invalid"
    RefreshTokenExpired -> json err401 "token_expired" "Refresh token expired"
    RefreshTokenReuseDetected -> json err401 "token_reuse" "Refresh token reuse detected"
    VerificationTokenInvalid -> json err400 "verification_token_invalid" "Verification token is invalid"
    PasswordResetTokenInvalid -> json err400 "password_reset_token_invalid" "Password reset token is invalid"
    EmailAlreadyVerified -> json err409 "email_already_verified" "Email is already verified"
    TokenInvalid _ -> json err401 "token_invalid" "Token is invalid"
    PasskeyNotFound -> json err404 "passkey_not_found" "Passkey not found"
    PendingCeremonyNotFound -> json err404 "ceremony_not_found" "Registration ceremony not found or expired"
    WebAuthnCeremonyError _ -> json err400 "webauthn_verification_failed" "Passkey registration could not be verified"
    MfaAssertionInvalid -> json err401 "mfa_failed" "Multi-factor authentication failed"
    ImpersonationForbidden -> json err403 "impersonation_forbidden" "Not allowed to impersonate"
    ImpersonationTargetInvalid -> json err400 "impersonation_target_invalid" "Invalid impersonation target"
    ImpersonationActionBlocked -> json err403 "impersonation_action_blocked" "This action is not permitted while impersonating"
    InternalAuthError _ -> json err500 "internal" "Internal authentication error"
  where
    json base code msg =
        base
            { errBody =
                Aeson.encode
                    ( Aeson.object
                        [ "error" Aeson..= (code :: Text)
                        , "message" Aeson..= (msg :: Text)
                        ]
                    )
            , errHeaders = [("Content-Type", "application/json")]
            }
