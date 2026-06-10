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

import "aeson" Data.Aeson (Value, encode)
import "network" Network.Socket (SockAddr (..))
import "text" Data.Text qualified as Text

import "servant-server" Servant (Handler, NoContent (..), ServerError (..), err404, err503, errBody, throwError)
import "servant-server" Servant.Server.Generic (AsServerT)

import Shomei.Domain.Command (
    ClientContext (..),
    LoginCommand (..),
    LogoutCommand (..),
    RefreshCommand (..),
    SignupCommand (..),
 )
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.LoginAttempt (ClientIp (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Effect.SessionStore (findSessionById)
import Shomei.Effect.SigningKeyStore (listActiveSigningKeys)
import Shomei.Effect.UserStore (findUserById)
import Shomei.Workflow qualified as Wf
import Shomei.Workflow.Account qualified as Account

import Shomei.Servant.API (ShomeiAPI (..))
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.DTO (
    ChangePasswordRequest (..),
    ConfirmEmailVerificationRequest (..),
    ConfirmPasswordResetRequest (..),
    HealthResponse (..),
    LoginRequest (..),
    LoginResponse (..),
    PasswordResetRequest (..),
    ReadyResponse (..),
    RefreshRequest (..),
    SessionResponse,
    SignupRequest (..),
    SignupResponse (..),
    TokenPairResponse,
    UserResponse,
    VerifyEmailRequest (..),
    sessionToResponse,
    tokenPairToResponse,
    userToResponse,
 )
import Shomei.Servant.Error (authErrorToServerError)
import Shomei.Servant.Seam (Env (..), runAuth, runPort, runPortChecked)

-- | Assemble the server record from the per-route handlers.
shomeiServer :: Env -> ShomeiAPI (AsServerT Handler)
shomeiServer env =
    ShomeiAPI
        { signup = signupH env
        , login = loginH env
        , refresh = refreshH env
        , verifyEmailRequest = verifyEmailRequestH env
        , verifyEmailConfirm = verifyEmailConfirmH env
        , passwordResetRequest = passwordResetRequestH env
        , passwordResetConfirm = passwordResetConfirmH env
        , passwordChange = passwordChangeH env
        , logout = logoutH env
        , me = meH env
        , session = sessionH env
        , jwks = jwksH env
        , health = healthH
        , ready = readyH env
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

loginH :: Env -> SockAddr -> LoginRequest -> Handler LoginResponse
loginH env peer req = do
    email <- either (throwError . authErrorToServerError) pure (mkEmail req.email)
    let cmd = LoginCommand{email = email, password = PlainPassword req.password}
        ctx =
            ClientContext
                { clientIp = ClientIp (clientIpText peer)
                , accountKey = env.accountKeyOf email
                }
    (user, pair) <- runAuth env (Wf.login env.config ctx cmd)
    pure LoginResponse{user = userToResponse user, token = tokenPairToResponse pair}

{- | The source IP of the request as text, used as the per-IP throttle key. Behind a reverse
proxy this is the proxy's address; a trusted @X-Forwarded-For@ policy would be layered in a
deployment that fronts the server with a proxy (out of scope here). The port is dropped so
all connections from one host share a key.
-}
clientIpText :: SockAddr -> Text
clientIpText = \case
    SockAddrInet _ host -> Text.pack (show host)
    SockAddrInet6 _ _ host _ -> Text.pack (show host)
    other -> Text.pack (show other)

refreshH :: Env -> RefreshRequest -> Handler TokenPairResponse
refreshH env req =
    tokenPairToResponse
        <$> runAuth env (Wf.refresh env.config (RefreshCommand{refreshToken = RefreshToken req.refreshToken}))

verifyEmailRequestH :: Env -> VerifyEmailRequest -> Handler NoContent
verifyEmailRequestH env req = do
    email <- either (throwError . authErrorToServerError) pure (mkEmail req.email)
    runAuth env (Account.requestEmailVerification env.config (Account.RequestEmailVerification email))
    pure NoContent

verifyEmailConfirmH :: Env -> ConfirmEmailVerificationRequest -> Handler NoContent
verifyEmailConfirmH env req = do
    runAuth env (Account.confirmEmailVerification env.config (Account.ConfirmEmailVerification (OneTimeToken req.token)))
    pure NoContent

passwordResetRequestH :: Env -> PasswordResetRequest -> Handler NoContent
passwordResetRequestH env req = do
    email <- either (throwError . authErrorToServerError) pure (mkEmail req.email)
    runAuth env (Account.requestPasswordReset env.config (Account.RequestPasswordReset email))
    pure NoContent

passwordResetConfirmH :: Env -> ConfirmPasswordResetRequest -> Handler NoContent
passwordResetConfirmH env req = do
    runAuth
        env
        ( Account.confirmPasswordReset
            env.config
            (Account.ConfirmPasswordReset (OneTimeToken req.token) (PlainPassword req.newPassword))
        )
    pure NoContent

passwordChangeH :: Env -> AuthUser -> ChangePasswordRequest -> Handler NoContent
passwordChangeH env user req = do
    runAuth
        env
        ( Account.changePassword
            env.config
            (Account.ChangePassword user.authUserId (PlainPassword req.currentPassword) (PlainPassword req.newPassword))
        )
    pure NoContent

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

{- | @GET /ready@ (EP-3): readiness, distinct from liveness @/health@. The single
'listActiveSigningKeys' call covers BOTH preconditions for serving auth: it hits PostgreSQL
(so a 'Left'/exception means the database is unreachable) and a non-empty result means an
active signing key exists. 200 only when both hold; otherwise 503 with a JSON body naming the
failed check, so a load balancer drains traffic. Liveness stays dependency-free.
-}
readyH :: Env -> Handler ReadyResponse
readyH env = do
    outcome <- runPortChecked env listActiveSigningKeys
    case outcome of
        Right keys
            | not (null keys) -> pure ReadyResponse{status = "ready", database = True, signingKey = True}
            | otherwise -> notReady ReadyResponse{status = "not_ready", database = True, signingKey = False}
        Left _ -> notReady ReadyResponse{status = "not_ready", database = False, signingKey = False}
  where
    notReady body =
        throwError
            err503
                { errBody = encode body
                , errHeaders = [("Content-Type", "application/json")]
                }

mkDisplayName :: Text -> Maybe Text
mkDisplayName t
    | Text.null t = Nothing
    | otherwise = Just t
