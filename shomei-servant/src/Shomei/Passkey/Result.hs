module Shomei.Passkey.Result
  ( RegisterBeginResponses,
    RegisterBeginResult,
    RegisterCompleteResponses,
    RegisterCompleteResult,
    ListPasskeysResponses,
    ListPasskeysResult,
    RemovePasskeyResponses,
    RemovePasskeyResult,
    PasskeyLoginBeginResponses,
    PasskeyLoginBeginResult,
    PasskeyLoginCompleteResponses,
    PasskeyLoginCompleteResult,
  )
where

import Shomei.Passkey.Dto
import Shomei.Servant.Result
import Shomei.Session.Dto (TokenPairResponse)

type RegisterBeginResponses = ApplicationResponses 200 "Passkey registration challenge" PasskeyRegisterBeginResponse

type RegisterBeginResult = ApplicationResult PasskeyRegisterBeginResponse

type RegisterCompleteResponses = ApplicationResponses 200 "Passkey registered" PasskeyResponse

type RegisterCompleteResult = ApplicationResult PasskeyResponse

type ListPasskeysResponses = ApplicationResponses 200 "Passkeys" [PasskeyResponse]

type ListPasskeysResult = ApplicationResult [PasskeyResponse]

type RemovePasskeyResponses = ApplicationEmptyResponses 204 "Passkey removed"

type RemovePasskeyResult = ApplicationResult ()

type PasskeyLoginBeginResponses = ApplicationResponses 200 "Passkey login challenge" PasskeyLoginBeginResponse

type PasskeyLoginBeginResult = ApplicationResult PasskeyLoginBeginResponse

type PasskeyLoginCompleteResponses = ApplicationCookieResponses 200 "Authenticated" TokenPairResponse

type PasskeyLoginCompleteResult = ApplicationResult (CookieResponse TokenPairResponse)
