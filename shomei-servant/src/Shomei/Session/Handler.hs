-- | Session and administrative-session HTTP adapters.
module Shomei.Session.Handler
  ( sessionServer,
    adminSessionServer,
  )
where

import Data.Text qualified as Text
import Network.Socket (SockAddr (..))
import Servant (Handler)
import Servant.Server.Generic (AsServerT)
import Shomei.Account.Admin.Workflow qualified as Admin
import Shomei.Account.Handler (requireExistingUser)
import Shomei.Account.LoginId.Domain (loginIdText, mkLoginId)
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Config (CookieConfig (..), ShomeiConfig (..), transportUsesCookies)
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Error (AuthError (SessionNotFound))
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Shomei.Servant.Application (port, rejectAuth, rejectProblem, runApplicationHandler, workflow)
import Shomei.Servant.Auth (AuthUser (..), originHeaderAllowed)
import Shomei.Servant.Cookie
  ( clearedCookies,
    refreshTokenFromCookie,
    tokenCookies,
  )
import Shomei.Servant.Error
  ( detailOccurrence,
    noProblemOccurrence,
    pcBadRequest,
    pcCsrfRejected,
    pcSessionNotFound,
  )
import Shomei.Servant.Result (CookieResponse (..), cookieResponse)
import Shomei.Servant.Seam (Env (..))
import Shomei.Session.Admin.Api (AdminSessionApi (..))
import Shomei.Session.Api (SessionApi (..))
import Shomei.Session.Authentication.Workflow qualified as Authentication
import Shomei.Session.Command
  ( ClientContext (..),
    LoginCommand (..),
    LogoutCommand (..),
    RefreshCommand (..),
  )
import Shomei.Session.Dto
import Shomei.Session.LoginAttempt.Domain (ClientIp (..))
import Shomei.Session.RefreshToken.Domain (RefreshToken (..))
import Shomei.Session.Result
import Shomei.Session.Store (findSessionById, listSessionsForUser)

sessionServer :: Env -> SessionApi (AsServerT Handler)
sessionServer env =
  SessionApi
    { login = loginH env,
      refresh = refreshH env,
      logout = logoutH env,
      currentSession = currentSessionH env
    }

adminSessionServer :: Env -> AdminSessionApi (AsServerT Handler)
adminSessionServer env =
  AdminSessionApi
    { listSessions = adminListSessionsH env,
      revokeSessions = adminRevokeSessionsH env,
      revokeSession = adminRevokeSessionH env
    }

loginH :: Env -> SockAddr -> LoginRequest -> Handler LoginResult
loginH env peer request = runApplicationHandler do
  loginId <- either rejectAuth pure (mkLoginId request.loginId)
  let command = LoginCommand {loginId, password = PlainPassword request.password}
      context =
        ClientContext
          { clientIp = ClientIp (clientIpText peer),
            accountKey = env.accountKeyOf (loginIdText loginId)
          }
  result <- workflow env (Authentication.login env.config context command)
  pure case result of
    Authentication.LoginComplete _ pair ->
      cookieResponse env.config (tokenCookies env.config pair) (loginResultToResponse env.config result)
    Authentication.MfaRequired _ ->
      CookieResponse
        { cookieBody = loginResultToResponse env.config result,
          sessionCookieHeader = Nothing,
          refreshCookieHeader = Nothing
        }

refreshH :: Env -> Maybe Text -> Maybe Text -> Maybe Text -> RefreshRequest -> Handler RefreshResult
refreshH env cookieHeader origin referer request = runApplicationHandler do
  presented <- case request.refreshToken of
    Just token -> pure token
    Nothing
      | transportUsesCookies env.config.tokenTransport,
        Just raw <- cookieHeader,
        Just token <- refreshTokenFromCookie raw -> do
          unless (originHeaderAllowed env.config.cookieConfig.allowedOrigins origin referer) (rejectProblem pcCsrfRejected noProblemOccurrence)
          pure token
    Nothing -> rejectProblem pcBadRequest (detailOccurrence "refreshToken required")
  pair <- workflow env (Authentication.refresh env.config (RefreshCommand (RefreshToken presented)))
  pure (cookieResponse env.config (tokenCookies env.config pair) (tokenPairToResponse env.config pair))

logoutH :: Env -> AuthUser -> Handler LogoutResult
logoutH env user = runApplicationHandler do
  outcome <- port env (Authentication.logout env.config (LogoutCommand user.authSessionId))
  case outcome of
    Left SessionNotFound -> pure cleared
    Left err -> rejectAuth err
    Right () -> pure cleared
  where
    cleared = cookieResponse env.config (clearedCookies env.config) ()

currentSessionH :: Env -> AuthUser -> Handler CurrentSessionResult
currentSessionH env user = runApplicationHandler do
  found <- port env (findSessionById user.authSessionId)
  maybe (rejectProblem pcSessionNotFound noProblemOccurrence) (pure . sessionToResponse) found

adminListSessionsH :: Env -> AuthUser -> UserId -> Handler ListSessionsResult
adminListSessionsH env _ target = runApplicationHandler do
  _ <- requireExistingUser env target
  map sessionToResponse <$> port env (listSessionsForUser target)

adminRevokeSessionsH :: Env -> AuthUser -> UserId -> Handler RevokeSessionsResult
adminRevokeSessionsH env actor target = runApplicationHandler do
  denyUnderDelegation env "admin_revoke_sessions" actor
  _ <- requireExistingUser env target
  void $ workflow env (Admin.revokeUserSessions actor.authUserId target)

adminRevokeSessionH :: Env -> AuthUser -> SessionId -> Handler RevokeSessionResult
adminRevokeSessionH env actor sessionId = runApplicationHandler do
  denyUnderDelegation env "admin_revoke_session" actor
  workflow env (Admin.revokeOneSession actor.authUserId sessionId)

clientIpText :: SockAddr -> Text
clientIpText = \case
  SockAddrInet _ host -> Text.pack (show host)
  SockAddrInet6 _ _ host _ -> Text.pack (show host)
  other -> Text.pack (show other)
