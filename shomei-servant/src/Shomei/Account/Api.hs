-- | Account-owned HTTP routes.
module Shomei.Account.Api
  ( AccountApi (..),
    SignupRoute,
    VerifyEmailRequestRoute,
    VerifyEmailConfirmRoute,
    PasswordResetRequestRoute,
    PasswordResetConfirmRoute,
    PasswordChangeRoute,
    MeRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Account.Dto
  ( ChangePasswordRequest,
    ConfirmEmailVerificationRequest,
    ConfirmPasswordResetRequest,
    PasswordResetRequest,
    SignupRequest,
    VerifyEmailRequest,
  )
import Shomei.Account.Result
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses, RateLimited)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)

type SignupRoute = "signup" :> RateLimited :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] SignupRequest :> MultiVerb 'POST ApplicationContentTypes SignupResponses SignupResult

type VerifyEmailRequestRoute = "verify-email" :> "request" :> RateLimited :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] VerifyEmailRequest :> MultiVerb 'POST ApplicationContentTypes VerifyEmailRequestResponses VerifyEmailRequestResult

type VerifyEmailConfirmRoute = "verify-email" :> "confirm" :> RateLimited :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] ConfirmEmailVerificationRequest :> MultiVerb 'POST ApplicationContentTypes VerifyEmailConfirmResponses VerifyEmailConfirmResult

type PasswordResetRequestRoute = "password-reset" :> "request" :> RateLimited :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] PasswordResetRequest :> MultiVerb 'POST ApplicationContentTypes PasswordResetRequestResponses PasswordResetRequestResult

type PasswordResetConfirmRoute = "password-reset" :> "confirm" :> RateLimited :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] ConfirmPasswordResetRequest :> MultiVerb 'POST ApplicationContentTypes PasswordResetConfirmResponses PasswordResetConfirmResult

type PasswordChangeRoute = "password" :> "change" :> RateLimited :> Authenticated :> CsrfProtected :> RemoteHost :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] ChangePasswordRequest :> MultiVerb 'POST ApplicationContentTypes PasswordChangeResponses PasswordChangeResult

type MeRoute = Authenticated :> "me" :> MultiVerb 'GET ApplicationContentTypes MeResponses MeResult

data AccountApi mode = AccountApi
  { signup :: mode :- SignupRoute,
    verifyEmailRequest :: mode :- VerifyEmailRequestRoute,
    verifyEmailConfirm :: mode :- VerifyEmailConfirmRoute,
    passwordResetRequest :: mode :- PasswordResetRequestRoute,
    passwordResetConfirm :: mode :- PasswordResetConfirmRoute,
    passwordChange :: mode :- PasswordChangeRoute,
    me :: mode :- MeRoute
  }
  deriving stock (Generic)
