-- | Multi-factor authentication HTTP routes.
module Shomei.Mfa.Api
  ( MfaApi (..),
    MfaCompleteRoute,
    TotpEnrollRoute,
    TotpVerifyRoute,
    TotpDeleteRoute,
    RecoveryCodesGenerateRoute,
    RecoveryCodesCountRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Mfa.Dto
  ( MfaCompleteRequest,
    TotpRemoveRequest,
    TotpVerifyRequest,
  )
import Shomei.Mfa.Result
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)

type MfaCompleteRoute = "mfa" :> "complete" :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] MfaCompleteRequest :> MultiVerb 'POST ApplicationContentTypes MfaCompleteResponses MfaCompleteResult

type TotpEnrollRoute = "totp" :> "enroll" :> Authenticated :> CsrfProtected :> MultiVerb 'POST ApplicationContentTypes TotpEnrollResponses TotpEnrollResult

type TotpVerifyRoute = "totp" :> "verify" :> Authenticated :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] TotpVerifyRequest :> MultiVerb 'POST ApplicationContentTypes TotpVerifyResponses TotpVerifyResult

type TotpDeleteRoute = "totp" :> Authenticated :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] TotpRemoveRequest :> MultiVerb 'DELETE ApplicationContentTypes TotpDeleteResponses TotpDeleteResult

type RecoveryCodesGenerateRoute = "recovery-codes" :> Authenticated :> CsrfProtected :> MultiVerb 'POST ApplicationContentTypes RecoveryCodesGenerateResponses RecoveryCodesGenerateResult

type RecoveryCodesCountRoute = "recovery-codes" :> Authenticated :> MultiVerb 'GET ApplicationContentTypes RecoveryCodesCountResponses RecoveryCodesCountResult

data MfaApi mode = MfaApi
  { complete :: mode :- MfaCompleteRoute,
    totpEnroll :: mode :- TotpEnrollRoute,
    totpVerify :: mode :- TotpVerifyRoute,
    totpDelete :: mode :- TotpDeleteRoute,
    recoveryCodesGenerate :: mode :- RecoveryCodesGenerateRoute,
    recoveryCodesCount :: mode :- RecoveryCodesCountRoute
  }
  deriving stock (Generic)
