-- | Passkey registration, listing, removal, and passwordless-login HTTP adapters.
module Shomei.Passkey.Handler (passkeyServer) where

import Data.Text (Text)
import Servant (Handler, NoContent (..), throwError)
import Servant.Server.Generic (AsServerT)
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Id (CeremonyId, PasskeyId, idText, parseId)
import Shomei.Mfa.Workflow qualified as Mfa
import Shomei.Passkey.Api (PasskeyApi (..))
import Shomei.Passkey.Dto
import Shomei.Passkey.Workflow qualified as Passkey
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Cookie (WithCookies, applyCookies, tokenCookies)
import Shomei.Servant.Error (pcBadRequest, toProblemError)
import Shomei.Servant.Seam (Env (..), runAuth, runPort)
import Shomei.Session.Dto (TokenPairResponse, tokenPairToResponse)

passkeyServer :: Env -> PasskeyApi (AsServerT Handler)
passkeyServer env =
  PasskeyApi
    { registerBegin = registerBeginH env,
      registerComplete = registerCompleteH env,
      list = listH env,
      remove = removeH env,
      loginBegin = loginBeginH env,
      loginComplete = loginCompleteH env
    }

registerBeginH :: Env -> AuthUser -> Handler PasskeyRegisterBeginResponse
registerBeginH env user = do
  denyUnderDelegation env "passkey_register" user
  (ceremonyId, options) <- runAuth env (Passkey.beginPasskeyRegistration env.config user.authUserId)
  pure PasskeyRegisterBeginResponse {ceremonyId = idText ceremonyId, options}

registerCompleteH :: Env -> AuthUser -> PasskeyRegisterCompleteRequest -> Handler PasskeyResponse
registerCompleteH env user request = do
  denyUnderDelegation env "passkey_register" user
  ceremonyId <- parseCeremonyId request.ceremonyId
  passkey <- runAuth env (Passkey.completePasskeyRegistration env.config user.authUserId ceremonyId request.credential request.label)
  pure (passkeyToResponse passkey)

listH :: Env -> AuthUser -> Handler [PasskeyResponse]
listH env user = map passkeyToResponse <$> runPort env (Passkey.listPasskeys user.authUserId)

removeH :: Env -> AuthUser -> PasskeyId -> Handler NoContent
removeH env user passkeyId = do
  denyUnderDelegation env "passkey_remove" user
  runAuth env (Passkey.removePasskey user.authUserId passkeyId)
  pure NoContent

loginBeginH :: Env -> Handler PasskeyLoginBeginResponse
loginBeginH env = do
  (ceremonyId, options) <- runAuth env (Mfa.beginPasswordlessLogin env.config)
  pure PasskeyLoginBeginResponse {ceremonyId = idText ceremonyId, options}

loginCompleteH :: Env -> PasskeyLoginCompleteRequest -> Handler (WithCookies TokenPairResponse)
loginCompleteH env request = do
  ceremonyId <- parseCeremonyId request.ceremonyId
  (_, tokens) <- runAuth env (Mfa.completePasswordlessLogin env.config ceremonyId request.assertion)
  pure (applyCookies env.config (tokenCookies env.config tokens) (tokenPairToResponse env.config tokens))

parseCeremonyId :: Text -> Handler CeremonyId
parseCeremonyId requestId =
  either (const (throwError (toProblemError pcBadRequest (Just "invalid ceremonyId")))) pure (parseId requestId)
