-- | MFA, TOTP, and recovery-code HTTP adapters.
module Shomei.Mfa.Handler (mfaServer) where

import Data.Time (addUTCTime)
import Servant (Handler)
import Servant.Server.Generic (AsServerT)
import Shomei.Account.Handler (loadUser)
import Shomei.Authorization.Claims.Domain (AuthClaims (..))
import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..))
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Id (parseId)
import Shomei.Mfa.Api (MfaApi (..))
import Shomei.Mfa.Dto
import Shomei.Mfa.RecoveryCode.Store (countUnusedRecoveryCodes)
import Shomei.Mfa.Result
import Shomei.Mfa.Totp.Workflow qualified as Totp
import Shomei.Mfa.Workflow qualified as Mfa
import Shomei.Prelude
import Shomei.Servant.Application (ApplicationHandler, port, rejectProblem, runApplicationHandler, workflow)
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Cookie (tokenCookies)
import Shomei.Servant.Error (detailOccurrence, noProblemOccurrence, pcBadRequest, pcReauthenticationRequired)
import Shomei.Servant.Result (cookieResponse)
import Shomei.Servant.Seam (Env (..))
import Shomei.Session.Dto (tokenPairToResponse)
import Shomei.Time.Store (now)

mfaServer :: Env -> MfaApi (AsServerT Handler)
mfaServer env =
  MfaApi
    { complete = completeH env,
      totpEnroll = totpEnrollH env,
      totpVerify = totpVerifyH env,
      totpDelete = totpDeleteH env,
      recoveryCodesGenerate = recoveryCodesGenerateH env,
      recoveryCodesCount = recoveryCodesCountH env
    }

completeH :: Env -> MfaCompleteRequest -> Handler MfaCompleteResult
completeH env request = runApplicationHandler do
  ceremonyId <-
    either
      (const (rejectProblem pcBadRequest (detailOccurrence "invalid ceremonyId")))
      pure
      (parseId request.ceremonyId)
  (_, tokens) <- workflow env (Mfa.completeMfa env.config ceremonyId (mfaCompletionOf request))
  pure (cookieResponse env.config (tokenCookies env.config tokens) (tokenPairToResponse env.config tokens))

totpEnrollH :: Env -> AuthUser -> Handler TotpEnrollResult
totpEnrollH env authUser = runApplicationHandler do
  denyUnderDelegation env "totp_enroll" authUser
  user <- loadUser env authUser
  Totp.TotpEnrollment {secretBase32, otpauthUri} <- workflow env (Totp.enrollTotp env.config user)
  pure TotpEnrollResponse {secret = secretBase32, otpauthUri}

totpVerifyH :: Env -> AuthUser -> TotpVerifyRequest -> Handler TotpVerifyResult
totpVerifyH env authUser request = runApplicationHandler do
  user <- loadUser env authUser
  workflow env (Totp.verifyTotpEnrollment env.config user request.code)

totpDeleteH :: Env -> AuthUser -> TotpRemoveRequest -> Handler TotpDeleteResult
totpDeleteH env authUser request = runApplicationHandler do
  denyUnderDelegation env "totp_remove" authUser
  user <- loadUser env authUser
  workflow env (Totp.removeTotp env.config user (totpRemovalProofOf request))

recoveryCodesGenerateH :: Env -> AuthUser -> Handler RecoveryCodesGenerateResult
recoveryCodesGenerateH env authUser = runApplicationHandler do
  denyUnderDelegation env "recovery_codes_generate" authUser
  requireFreshAuth env authUser
  user <- loadUser env authUser
  codes <- workflow env (Totp.regenerateRecoveryCodes env.config user)
  pure RecoveryCodesResponse {codes}

recoveryCodesCountH :: Env -> AuthUser -> Handler RecoveryCodesCountResult
recoveryCodesCountH env authUser = runApplicationHandler do
  remaining <- port env (countUnusedRecoveryCodes authUser.authUserId)
  pure RecoveryCodesCountResponse {remaining}

requireFreshAuth :: Env -> AuthUser -> ApplicationHandler ()
requireFreshAuth env user = do
  timestamp <- port env now
  let window = env.config.impersonationConfig.actorFreshnessWindow
  when (timestamp > addUTCTime window user.authClaims.issuedAt) $
    rejectProblem pcReauthenticationRequired noProblemOccurrence
