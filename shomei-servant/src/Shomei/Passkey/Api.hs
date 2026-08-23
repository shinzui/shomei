-- | Passkey-owned registration, management, and passwordless-login routes.
module Shomei.Passkey.Api (PasskeyApi (..)) where

import Servant.API
import Shomei.Id (PasskeyId)
import Shomei.Passkey.Dto
  ( PasskeyLoginBeginResponse,
    PasskeyLoginCompleteRequest,
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
  )
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Cookie (WithCookies)
import Shomei.Servant.PreHandler (CsrfProtected)
import Shomei.Session.Dto (TokenPairResponse)

data PasskeyApi mode = PasskeyApi
  { registerBegin :: mode :- "passkeys" :> "register" :> "begin" :> Authenticated :> CsrfProtected :> Post '[JSON] PasskeyRegisterBeginResponse,
    registerComplete :: mode :- "passkeys" :> "register" :> "complete" :> Authenticated :> CsrfProtected :> ReqBody '[JSON] PasskeyRegisterCompleteRequest :> Post '[JSON] PasskeyResponse,
    list :: mode :- "passkeys" :> Authenticated :> Get '[JSON] [PasskeyResponse],
    remove :: mode :- "passkeys" :> Authenticated :> CsrfProtected :> Capture "passkeyId" PasskeyId :> Verb 'DELETE 204 '[JSON] NoContent,
    loginBegin :: mode :- "login" :> "passkey" :> "begin" :> Post '[JSON] PasskeyLoginBeginResponse,
    loginComplete :: mode :- "login" :> "passkey" :> "complete" :> ReqBody '[JSON] PasskeyLoginCompleteRequest :> Post '[JSON] (WithCookies TokenPairResponse)
  }
  deriving stock (Generic)
