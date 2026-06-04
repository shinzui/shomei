{- | The server for 'ShomeiAPI': handlers run in servant's 'Handler', drive the EP-2
auth workflows through the 'Shomei.Servant.Seam' seam, and map results to DTOs.

@signup@/@login@ build a domain command from the request (parsing the email through
'mkEmail' so a malformed address is a @400@ before the workflow runs) and render the
resulting @(User, TokenPair)@. @me@/@session@ read the live record from the store
port (a verified principal whose row is missing is a @404@). @jwks@ returns the
precomputed public JWKS document from the 'Env'; @health@ is a static @200@.
-}
module Shomei.Servant.Handlers (
    shomeiServer,
) where

import Shomei.Prelude

import "aeson" Data.Aeson (Value)
import "text" Data.Text qualified as Text

import "servant-server" Servant (Handler, NoContent (..), err404, errBody, throwError)
import "servant-server" Servant.Server.Generic (AsServerT)

import Shomei.Domain.Command (
    LoginCommand (..),
    LogoutCommand (..),
    RefreshCommand (..),
    SignupCommand (..),
 )
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Port.SessionStore (findSessionById)
import Shomei.Port.UserStore (findUserById)
import Shomei.Workflow qualified as Wf

import Shomei.Servant.API (ShomeiAPI (..))
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.DTO (
    HealthResponse (..),
    LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    SessionResponse,
    SignupRequest (..),
    SignupResponse (..),
    TokenPairResponse,
    UserResponse,
    sessionToResponse,
    tokenPairToResponse,
    userToResponse,
 )
import Shomei.Servant.Error (authErrorToServerError)
import Shomei.Servant.Seam (Env (..), runAuth, runPort)

-- | Assemble the server record from the per-route handlers.
shomeiServer :: Env -> ShomeiAPI (AsServerT Handler)
shomeiServer env =
    ShomeiAPI
        { signup = signupH env
        , login = loginH env
        , refresh = refreshH env
        , logout = logoutH env
        , me = meH env
        , session = sessionH env
        , jwks = jwksH env
        , health = healthH
        }

signupH :: Env -> SignupRequest -> Handler SignupResponse
signupH env req = do
    email <- either (throwError . authErrorToServerError) pure (mkEmail req.email)
    let cmd =
            SignupCommand
                { email = email
                , password = PlainPassword req.password
                , displayName = mkDisplayName req.displayName
                }
    (user, pair) <- runAuth env (Wf.signup env.config cmd)
    pure SignupResponse{user = userToResponse user, token = tokenPairToResponse pair}

loginH :: Env -> LoginRequest -> Handler LoginResponse
loginH env req = do
    email <- either (throwError . authErrorToServerError) pure (mkEmail req.email)
    let cmd = LoginCommand{email = email, password = PlainPassword req.password}
    (user, pair) <- runAuth env (Wf.login env.config cmd)
    pure LoginResponse{user = userToResponse user, token = tokenPairToResponse pair}

refreshH :: Env -> RefreshRequest -> Handler TokenPairResponse
refreshH env req =
    tokenPairToResponse
        <$> runAuth env (Wf.refresh env.config (RefreshCommand{refreshToken = RefreshToken req.refreshToken}))

logoutH :: Env -> AuthUser -> Handler NoContent
logoutH env user = do
    runAuth env (Wf.logout env.config (LogoutCommand{sessionId = user.authSessionId}))
    pure NoContent

meH :: Env -> AuthUser -> Handler UserResponse
meH env user = do
    mUser <- runPort env (findUserById user.authUserId)
    case mUser of
        Just u -> pure (userToResponse u)
        Nothing -> throwError err404{errBody = "user not found"}

sessionH :: Env -> AuthUser -> Handler SessionResponse
sessionH env user = do
    mSession <- runPort env (findSessionById user.authSessionId)
    case mSession of
        Just s -> pure (sessionToResponse s)
        Nothing -> throwError err404{errBody = "session not found"}

jwksH :: Env -> Handler Value
jwksH env = pure env.jwksJson

healthH :: Handler HealthResponse
healthH = pure HealthResponse{status = "ok"}

mkDisplayName :: Text -> Maybe Text
mkDisplayName t
    | Text.null t = Nothing
    | otherwise = Just t
