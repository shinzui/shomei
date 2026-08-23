-- | Account-owned HTTP routes.
module Shomei.Account.Api (AccountApi (..)) where

import Servant.API
import Shomei.Account.Dto
  ( ChangePasswordRequest,
    ConfirmEmailVerificationRequest,
    ConfirmPasswordResetRequest,
    PasswordResetRequest,
    SignupRequest,
    SignupResponse,
    VerifyEmailRequest,
  )
import Shomei.Account.User.Dto (UserResponse)
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Cookie (WithCookies)
import Shomei.Servant.PreHandler (CsrfProtected, RateLimited)

data AccountApi mode = AccountApi
  { signup :: mode :- "signup" :> RateLimited :> ReqBody '[JSON] SignupRequest :> Verb 'POST 201 '[JSON] (WithCookies SignupResponse),
    verifyEmailRequest :: mode :- "verify-email" :> "request" :> RateLimited :> ReqBody '[JSON] VerifyEmailRequest :> Verb 'POST 202 '[JSON] NoContent,
    verifyEmailConfirm :: mode :- "verify-email" :> "confirm" :> ReqBody '[JSON] ConfirmEmailVerificationRequest :> Post '[JSON] NoContent,
    passwordResetRequest :: mode :- "password-reset" :> "request" :> RateLimited :> ReqBody '[JSON] PasswordResetRequest :> Verb 'POST 202 '[JSON] NoContent,
    passwordResetConfirm :: mode :- "password-reset" :> "confirm" :> ReqBody '[JSON] ConfirmPasswordResetRequest :> Post '[JSON] NoContent,
    passwordChange :: mode :- "password" :> "change" :> Authenticated :> CsrfProtected :> ReqBody '[JSON] ChangePasswordRequest :> PostNoContent,
    me :: mode :- Authenticated :> "me" :> Get '[JSON] UserResponse
  }
  deriving stock (Generic)
