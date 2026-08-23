-- | MFA, TOTP, and recovery-code HTTP adapters.
module Shomei.Mfa.Handler (mfaServer) where

import Data.Time (addUTCTime)
import Servant (Handler, NoContent (..), throwError)
import Servant.Server.Generic (AsServerT)
import Shomei.Account.Handler (loadUser)
import Shomei.Authorization.Claims.Domain (AuthClaims (..))
import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..))
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Id (idText, parseId)
import Shomei.Mfa.Api (MfaApi (..))
import Shomei.Mfa.Dto
import Shomei.Mfa.RecoveryCode.Store (countUnusedRecoveryCodes)
import Shomei.Mfa.Totp.Workflow qualified as Totp
import Shomei.Mfa.Workflow qualified as Mfa
import Shomei.Prelude
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Cookie (WithCookies, applyCookies, tokenCookies)
import Shomei.Servant.Error (pcBadRequest, pcReauthenticationRequired, toProblemError)
import Shomei.Servant.Seam (Env (..), runAuth, runPort)
import Shomei.Session.Dto (TokenPairResponse, tokenPairToResponse)
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

completeH :: Env -> MfaCompleteRequest -> Handler (WithCookies TokenPairResponse)
completeH env request = do
  ceremonyId <-
    either
      (const (throwError (toProblemError pcBadRequest (Just "invalid ceremonyId"))))
      pure
      (parseId request.ceremonyId)
  (_, tokens) <- runAuth env (Mfa.completeMfa env.config ceremonyId (mfaCompletionOf request))
  pure (applyCookies env.config (tokenCookies env.config tokens) (tokenPairToResponse env.config tokens))

totpEnrollH :: Env -> AuthUser -> Handler TotpEnrollResponse
totpEnrollH env authUser = do
  denyUnderDelegation env "totp_enroll" authUser
  user <- loadUser env authUser
  Totp.TotpEnrollment {secretBase32, otpauthUri} <- runAuth env (Totp.enrollTotp env.config user)
  pure TotpEnrollResponse {secret = secretBase32, otpauthUri}

totpVerifyH :: Env -> AuthUser -> TotpVerifyRequest -> Handler NoContent
totpVerifyH env authUser request = do
  user <- loadUser env authUser
  runAuth env (Totp.verifyTotpEnrollment env.config user request.code)
  pure NoContent

totpDeleteH :: Env -> AuthUser -> TotpRemoveRequest -> Handler NoContent
totpDeleteH env authUser request = do
  denyUnderDelegation env "totp_remove" authUser
  user <- loadUser env authUser
  runAuth env (Totp.removeTotp env.config user (totpRemovalProofOf request))
  pure NoContent

recoveryCodesGenerateH :: Env -> AuthUser -> Handler RecoveryCodesResponse
recoveryCodesGenerateH env authUser = do
  denyUnderDelegation env "recovery_codes_generate" authUser
  requireFreshAuth env authUser
  user <- loadUser env authUser
  codes <- runAuth env (Totp.regenerateRecoveryCodes env.config user)
  pure RecoveryCodesResponse {codes}

recoveryCodesCountH :: Env -> AuthUser -> Handler RecoveryCodesCountResponse
recoveryCodesCountH env authUser = do
  remaining <- runPort env (countUnusedRecoveryCodes authUser.authUserId)
  pure RecoveryCodesCountResponse {remaining}

requireFreshAuth :: Env -> AuthUser -> Handler ()
requireFreshAuth env user = do
  timestamp <- runPort env now
  let window = env.config.impersonationConfig.actorFreshnessWindow
  when (timestamp > addUTCTime window user.authClaims.issuedAt) $
    throwError (toProblemError pcReauthenticationRequired Nothing)
