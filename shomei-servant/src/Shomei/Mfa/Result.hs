module Shomei.Mfa.Result
  ( MfaCompleteResponses,
    MfaCompleteResult,
    TotpEnrollResponses,
    TotpEnrollResult,
    TotpVerifyResponses,
    TotpVerifyResult,
    TotpDeleteResponses,
    TotpDeleteResult,
    RecoveryCodesGenerateResponses,
    RecoveryCodesGenerateResult,
    RecoveryCodesCountResponses,
    RecoveryCodesCountResult,
  )
where

import Shomei.Mfa.Dto
import Shomei.Servant.Result
import Shomei.Session.Dto (TokenPairResponse)

type MfaCompleteResponses = ApplicationCookieResponses 200 "Authenticated" TokenPairResponse

type MfaCompleteResult = ApplicationResult (CookieResponse TokenPairResponse)

type TotpEnrollResponses = ApplicationResponses 200 "TOTP enrollment" TotpEnrollResponse

type TotpEnrollResult = ApplicationResult TotpEnrollResponse

type TotpVerifyResponses = ApplicationEmptyResponses 200 "TOTP enrollment verified"

type TotpVerifyResult = ApplicationResult ()

type TotpDeleteResponses = ApplicationEmptyResponses 204 "TOTP removed"

type TotpDeleteResult = ApplicationResult ()

type RecoveryCodesGenerateResponses = ApplicationResponses 200 "Recovery codes" RecoveryCodesResponse

type RecoveryCodesGenerateResult = ApplicationResult RecoveryCodesResponse

type RecoveryCodesCountResponses = ApplicationResponses 200 "Recovery code count" RecoveryCodesCountResponse

type RecoveryCodesCountResult = ApplicationResult RecoveryCodesCountResponse
