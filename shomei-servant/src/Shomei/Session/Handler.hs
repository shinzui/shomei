-- | Session and administrative-session HTTP adapters.
module Shomei.Session.Handler
  ( sessionServer,
    adminSessionServer,
  )
where

import Data.Text qualified as Text
import Network.Socket (SockAddr (..))
import Servant (Handler, NoContent (..), noHeader, throwError)
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
import Shomei.Servant.Auth (AuthUser (..), csrfRejected, originHeaderAllowed)
import Shomei.Servant.Cookie
  ( WithCookies,
    applyCookies,
    clearedCookies,
    refreshTokenFromCookie,
    tokenCookies,
  )
import Shomei.Servant.Error
  ( authErrorToServerError,
    pcBadRequest,
    pcSessionNotFound,
    toProblemError,
  )
import Shomei.Servant.Seam (Env (..), runAuth, runPort)
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

loginH :: Env -> SockAddr -> LoginRequest -> Handler (WithCookies LoginResponse)
loginH env peer request = do
  loginId <- either (throwError . authErrorToServerError) pure (mkLoginId request.loginId)
  let command = LoginCommand {loginId, password = PlainPassword request.password}
      context =
        ClientContext
          { clientIp = ClientIp (clientIpText peer),
            accountKey = env.accountKeyOf (loginIdText loginId)
          }
  result <- runAuth env (Authentication.login env.config context command)
  pure case result of
    Authentication.LoginComplete _ pair ->
      applyCookies env.config (tokenCookies env.config pair) (loginResultToResponse env.config result)
    Authentication.MfaRequired _ -> noHeader (noHeader (loginResultToResponse env.config result))

refreshH :: Env -> Maybe Text -> Maybe Text -> Maybe Text -> RefreshRequest -> Handler (WithCookies TokenPairResponse)
refreshH env cookieHeader origin referer request = do
  presented <- case request.refreshToken of
    Just token -> pure token
    Nothing
      | transportUsesCookies env.config.tokenTransport,
        Just raw <- cookieHeader,
        Just token <- refreshTokenFromCookie raw -> do
          unless (originHeaderAllowed env.config.cookieConfig.allowedOrigins origin referer) (throwError csrfRejected)
          pure token
    Nothing -> throwError (toProblemError pcBadRequest (Just "refreshToken required"))
  pair <- runAuth env (Authentication.refresh env.config (RefreshCommand (RefreshToken presented)))
  pure (applyCookies env.config (tokenCookies env.config pair) (tokenPairToResponse env.config pair))

logoutH :: Env -> AuthUser -> Handler (WithCookies NoContent)
logoutH env user = do
  outcome <- runPort env (Authentication.logout env.config (LogoutCommand user.authSessionId))
  case outcome of
    Left SessionNotFound -> pure cleared
    Left err -> throwError (authErrorToServerError err)
    Right () -> pure cleared
  where
    cleared = applyCookies env.config (clearedCookies env.config) NoContent

currentSessionH :: Env -> AuthUser -> Handler SessionResponse
currentSessionH env user = do
  found <- runPort env (findSessionById user.authSessionId)
  maybe (throwError (toProblemError pcSessionNotFound Nothing)) (pure . sessionToResponse) found

adminListSessionsH :: Env -> AuthUser -> UserId -> Handler [SessionResponse]
adminListSessionsH env _ target = do
  _ <- requireExistingUser env target
  map sessionToResponse <$> runPort env (listSessionsForUser target)

adminRevokeSessionsH :: Env -> AuthUser -> UserId -> Handler NoContent
adminRevokeSessionsH env actor target = do
  denyUnderDelegation env "admin_revoke_sessions" actor
  _ <- requireExistingUser env target
  _ <- runAuth env (Admin.revokeUserSessions actor.authUserId target)
  pure NoContent

adminRevokeSessionH :: Env -> AuthUser -> SessionId -> Handler NoContent
adminRevokeSessionH env actor sessionId = do
  denyUnderDelegation env "admin_revoke_session" actor
  runAuth env (Admin.revokeOneSession actor.authUserId sessionId)
  pure NoContent

clientIpText :: SockAddr -> Text
clientIpText = \case
  SockAddrInet _ host -> Text.pack (show host)
  SockAddrInet6 _ _ host _ -> Text.pack (show host)
  other -> Text.pack (show other)
