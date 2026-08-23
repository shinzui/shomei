-- | Passkey-owned registration, management, and passwordless-login routes.
module Shomei.Passkey.Api
  ( PasskeyApi (..),
    RegisterBeginRoute,
    RegisterCompleteRoute,
    ListPasskeysRoute,
    RemovePasskeyRoute,
    PasskeyLoginBeginRoute,
    PasskeyLoginCompleteRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Id (PasskeyId)
import Shomei.Passkey.Dto
  ( PasskeyLoginCompleteRequest,
    PasskeyRegisterCompleteRequest,
  )
import Shomei.Passkey.Result
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)

type RegisterBeginRoute = "passkeys" :> "register" :> "begin" :> Authenticated :> CsrfProtected :> MultiVerb 'POST ApplicationContentTypes RegisterBeginResponses RegisterBeginResult

type RegisterCompleteRoute = "passkeys" :> "register" :> "complete" :> Authenticated :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] PasskeyRegisterCompleteRequest :> MultiVerb 'POST ApplicationContentTypes RegisterCompleteResponses RegisterCompleteResult

type ListPasskeysRoute = "passkeys" :> Authenticated :> MultiVerb 'GET ApplicationContentTypes ListPasskeysResponses ListPasskeysResult

type RemovePasskeyRoute = "passkeys" :> Authenticated :> CsrfProtected :> PreHandlerResponses BadRequestPreHandlerResponses :> Capture "passkeyId" PasskeyId :> MultiVerb 'DELETE ApplicationContentTypes RemovePasskeyResponses RemovePasskeyResult

type PasskeyLoginBeginRoute = "login" :> "passkey" :> "begin" :> MultiVerb 'POST ApplicationContentTypes PasskeyLoginBeginResponses PasskeyLoginBeginResult

type PasskeyLoginCompleteRoute = "login" :> "passkey" :> "complete" :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] PasskeyLoginCompleteRequest :> MultiVerb 'POST ApplicationContentTypes PasskeyLoginCompleteResponses PasskeyLoginCompleteResult

data PasskeyApi mode = PasskeyApi
  { registerBegin :: mode :- RegisterBeginRoute,
    registerComplete :: mode :- RegisterCompleteRoute,
    list :: mode :- ListPasskeysRoute,
    remove :: mode :- RemovePasskeyRoute,
    loginBegin :: mode :- PasskeyLoginBeginRoute,
    loginComplete :: mode :- PasskeyLoginCompleteRoute
  }
  deriving stock (Generic)
