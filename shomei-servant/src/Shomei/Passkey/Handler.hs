-- | Passkey registration, listing, removal, and passwordless-login HTTP adapters.
module Shomei.Passkey.Handler (passkeyServer) where

import Data.Text (Text)
import Network.Socket (SockAddr)
import Servant (Handler)
import Servant.Server.Generic (AsServerT)
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Id (CeremonyId, PasskeyId, idText, parseId)
import Shomei.Mfa.Workflow qualified as Mfa
import Shomei.Passkey.Api (PasskeyApi (..))
import Shomei.Passkey.Dto
import Shomei.Passkey.Result
import Shomei.Passkey.Workflow qualified as Passkey
import Shomei.Servant.Application (ApplicationHandler, port, rejectProblem, runApplicationHandler, workflow)
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.ClientIp (clientIpText)
import Shomei.Servant.Cookie (tokenCookies)
import Shomei.Servant.Error (detailOccurrence, pcBadRequest)
import Shomei.Servant.Result (cookieResponse)
import Shomei.Servant.Seam (Env (..))
import Shomei.Session.Command (ProofContext (..))
import Shomei.Session.Dto (tokenPairToResponse)
import Shomei.Session.LoginAttempt.Domain (ClientIp (..))

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

registerBeginH :: Env -> AuthUser -> Handler RegisterBeginResult
registerBeginH env user = runApplicationHandler do
  denyUnderDelegation env "passkey_register" user
  (ceremonyId, options) <- workflow env (Passkey.beginPasskeyRegistration env.config user.authUserId)
  pure PasskeyRegisterBeginResponse {ceremonyId = idText ceremonyId, options}

registerCompleteH :: Env -> AuthUser -> PasskeyRegisterCompleteRequest -> Handler RegisterCompleteResult
registerCompleteH env user request = runApplicationHandler do
  denyUnderDelegation env "passkey_register" user
  ceremonyId <- parseCeremonyId request.ceremonyId
  passkey <- workflow env (Passkey.completePasskeyRegistration env.config user.authUserId ceremonyId request.credential request.label)
  pure (passkeyToResponse passkey)

listH :: Env -> AuthUser -> Handler ListPasskeysResult
listH env user = runApplicationHandler (map passkeyToResponse <$> port env (Passkey.listPasskeys user.authUserId))

removeH :: Env -> AuthUser -> PasskeyId -> Handler RemovePasskeyResult
removeH env user passkeyId = runApplicationHandler do
  denyUnderDelegation env "passkey_remove" user
  workflow env (Passkey.removePasskey user.authUserId passkeyId)

loginBeginH :: Env -> Handler PasskeyLoginBeginResult
loginBeginH env = runApplicationHandler do
  (ceremonyId, options) <- workflow env (Mfa.beginPasswordlessLogin env.config)
  pure PasskeyLoginBeginResponse {ceremonyId = idText ceremonyId, options}

loginCompleteH :: Env -> SockAddr -> PasskeyLoginCompleteRequest -> Handler PasskeyLoginCompleteResult
loginCompleteH env peer request = runApplicationHandler do
  ceremonyId <- parseCeremonyId request.ceremonyId
  let pctx = ProofContext {clientIp = ClientIp (clientIpText peer), accountKeyOf = env.accountKeyOf}
  (_, tokens) <- workflow env (Mfa.completePasswordlessLogin env.config pctx ceremonyId request.assertion)
  pure (cookieResponse env.config (tokenCookies env.config tokens) (tokenPairToResponse env.config tokens))

parseCeremonyId :: Text -> ApplicationHandler CeremonyId
parseCeremonyId requestId =
  either (const (rejectProblem pcBadRequest (detailOccurrence "invalid ceremonyId"))) pure (parseId requestId)
