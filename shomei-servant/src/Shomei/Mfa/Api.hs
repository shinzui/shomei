-- | Multi-factor authentication HTTP routes.
module Shomei.Mfa.Api (MfaApi (..)) where

import Servant.API
import Shomei.Mfa.Dto
  ( MfaCompleteRequest,
    RecoveryCodesCountResponse,
    RecoveryCodesResponse,
    TotpEnrollResponse,
    TotpRemoveRequest,
    TotpVerifyRequest,
  )
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Cookie (WithCookies)
import Shomei.Servant.PreHandler (CsrfProtected)
import Shomei.Session.Dto (TokenPairResponse)

data MfaApi mode = MfaApi
  { complete :: mode :- "mfa" :> "complete" :> ReqBody '[JSON] MfaCompleteRequest :> Post '[JSON] (WithCookies TokenPairResponse),
    totpEnroll :: mode :- "totp" :> "enroll" :> Authenticated :> CsrfProtected :> Post '[JSON] TotpEnrollResponse,
    totpVerify :: mode :- "totp" :> "verify" :> Authenticated :> CsrfProtected :> ReqBody '[JSON] TotpVerifyRequest :> Post '[JSON] NoContent,
    totpDelete :: mode :- "totp" :> Authenticated :> CsrfProtected :> ReqBody '[JSON] TotpRemoveRequest :> Verb 'DELETE 204 '[JSON] NoContent,
    recoveryCodesGenerate :: mode :- "recovery-codes" :> Authenticated :> CsrfProtected :> Post '[JSON] RecoveryCodesResponse,
    recoveryCodesCount :: mode :- "recovery-codes" :> Authenticated :> Get '[JSON] RecoveryCodesCountResponse
  }
  deriving stock (Generic)
