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

import "aeson" Data.Aeson qualified as Aeson

import "servant-server" Servant (
    ServerError (..),
    err400,
    err401,
    err404,
    err409,
    err500,
 )

import Shomei.Error (AuthError (..))

authErrorToServerError :: AuthError -> ServerError
authErrorToServerError = \case
    InvalidEmail -> json err400 "invalid_email" "Email is not valid"
    WeakPassword _ -> json err400 "weak_password" "Password does not meet policy"
    EmailAlreadyRegistered -> json err409 "email_taken" "Email is already registered"
    InvalidCredentials -> json err401 "invalid_login" "Invalid email or password"
    UserNotActive -> json err401 "invalid_login" "Invalid email or password"
    SessionNotFound -> json err404 "session_not_found" "Session not found"
    SessionExpired -> json err401 "session_expired" "Session expired"
    SessionRevoked -> json err401 "session_revoked" "Session revoked"
    RefreshTokenInvalid -> json err401 "token_invalid" "Refresh token is invalid"
    RefreshTokenExpired -> json err401 "token_expired" "Refresh token expired"
    RefreshTokenReuseDetected -> json err401 "token_reuse" "Refresh token reuse detected"
    TokenInvalid _ -> json err401 "token_invalid" "Token is invalid"
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
