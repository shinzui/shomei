-- | The server for 'ShomeiAPI': handlers run in servant's 'Handler', drive the EP-2
-- auth workflows through the 'Shomei.Servant.Seam' seam, and map results to DTOs.
--
-- @signup@/@login@ build a domain command from the request (parsing the email through
-- 'mkEmail' so a malformed address is a @400@ before the workflow runs) and render the
-- resulting @(User, TokenPair)@. @me@/@session@ read the live record from the store
-- port (a verified principal whose row is missing is a @404@). @jwks@ returns the
-- precomputed public JWKS document from the 'Env'; @health@ is a static @200@.
--
-- 'shomeiRoutes' assembles the served tree ('Shomei.Servant.API.ShomeiRoutes'): the
-- application record under @\/v1@ plus the unversioned JWKS and probe handlers.
module Shomei.Servant.Handlers
  ( shomeiRoutes,
    shomeiServer,
  )
where

import Data.Aeson (Value, encode)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Network.HTTP.Types.Status (status400, status500)
import Network.Socket (SockAddr (..))
import Servant (Handler, Header, Headers, NoContent (..), ServerError (..), addHeader, err503, errBody, errHeaders, noHeader, throwError)
import Servant.Server.Generic (AsServerT)
import Shomei.Config (CookieConfig (..), ServiceAccountId (..), ShomeiConfig (..), transportUsesCookies)
import Shomei.Domain.Claims (AuthClaims (..), Role (..), Scope (..))
import Shomei.Domain.Command
  ( ClientContext (..),
    LoginCommand (..),
    LogoutCommand (..),
    RefreshCommand (..),
    SignupCommand (..),
  )
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (ClientIp (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail, loginIdText, mkLoginId)
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..), UserStatus (..))
import Shomei.Effect.AuthEventPublisher (publishAuthEvent)
import Shomei.Effect.AuthEventReader
  ( AuditCursor (..),
    AuditEventQuery (..),
    StoredAuthEvent (..),
    clampLimit,
    emptyAuditQuery,
    queryAuthEvents,
  )
import Shomei.Effect.Clock (now)
import Shomei.Effect.SessionStore (findSessionById, listSessionsForUser)
import Shomei.Effect.SigningKeyStore (listActiveSigningKeys)
import Shomei.Effect.UserStore
  ( UserCursor (..),
    UserListQuery (..),
    clampUserLimit,
    emptyUserListQuery,
    findUserById,
    listUsers,
  )
import Shomei.Error
  ( AuthError
      ( ImpersonationActionBlocked,
        ImpersonationTargetInvalid,
        OAuthClientInvalid,
        OAuthScopeInvalid,
        SessionNotFound,
        UserHasNoEmail,
        UserNotFound
      ),
  )
import Shomei.Id (PasskeyId, SessionId, UserId, idText, parseId)
import Shomei.Prelude
import Shomei.Servant.API (ShomeiAPI (..), ShomeiRoutes (..))
import Shomei.Servant.Auth (AuthUser (..), csrfRejected, originHeaderAllowed)
import Shomei.Servant.Authz (requireAdmin)
import Shomei.Servant.Cookie (WithCookies, applyCookies, clearedCookies, refreshTokenFromCookie, tokenCookies)
import Shomei.Servant.DTO
  ( AdminUserResponse,
    AdminUsersPage (..),
    AuditEventsPage (..),
    ChangePasswordRequest (..),
    ConfirmEmailVerificationRequest (..),
    ConfirmPasswordResetRequest (..),
    HealthResponse (..),
    ImpersonateRequest (..),
    ImpersonateResponse,
    LoginRequest (..),
    LoginResponse,
    MfaCompleteRequest (..),
    PasskeyLoginBeginResponse (..),
    PasskeyLoginCompleteRequest (..),
    PasskeyRegisterBeginResponse (..),
    PasskeyRegisterCompleteRequest (..),
    PasskeyResponse,
    PasswordResetRequest (..),
    ReadyResponse (..),
    RefreshRequest (..),
    ServiceTokenRequest (..),
    ServiceTokenResponse,
    SessionResponse,
    SignupRequest (..),
    SignupResponse (..),
    TokenPairResponse,
    UserResponse,
    VerifyEmailRequest (..),
    adminUserToResponse,
    decodeCursor,
    decodeUserCursor,
    encodeCursor,
    encodeUserCursor,
    impersonateToResponse,
    loginResultToResponse,
    passkeyToResponse,
    serviceTokenToResponse,
    sessionToResponse,
    storedToResponse,
    tokenPairToResponse,
    userToResponse,
  )
import Shomei.Servant.Error
  ( authErrorToServerError,
    pcBadRequest,
    pcRoleNotGranted,
    pcSelfTargetForbidden,
    pcSessionNotFound,
    pcUserNotFound,
    toProblemError,
  )
import Shomei.Servant.OAuth qualified as OAuth
-- No cycle: "Shomei.Servant.OpenApi" imports only API/DTO/Authz/Id, never this module.
import Shomei.Servant.OpenApi (openApiValue)
import Shomei.Servant.Seam (Env (..), runAuth, runPort, runPortChecked)
import Shomei.Workflow qualified as Wf
import Shomei.Workflow.Account qualified as Account
import Shomei.Workflow.Admin qualified as Admin
import Shomei.Workflow.ClientCredentials qualified as ClientCredentials
import Shomei.Workflow.Impersonation qualified as Imp
import Shomei.Workflow.Mfa qualified as Mfa
import Shomei.Workflow.Passkey qualified as Passkey
import Shomei.Workflow.Roles qualified as Roles
import Shomei.Workflow.ServiceToken qualified as ServiceToken
import Web.FormUrlEncoded (Form)

-- | Assemble the served route tree: the application record mounted under @\/v1@, plus the
-- unversioned JWKS document and the liveness\/readiness probes.
shomeiRoutes :: Env -> ShomeiRoutes (AsServerT Handler)
shomeiRoutes env =
  ShomeiRoutes
    { v1 = shomeiServer env,
      jwks = jwksH env,
      openapi = pure openApiValue,
      oauthToken = oauthTokenH env,
      health = healthH,
      ready = readyH env
    }

-- | Assemble the application server record from the per-route handlers.
shomeiServer :: Env -> ShomeiAPI (AsServerT Handler)
shomeiServer env =
  ShomeiAPI
    { signup = signupH env,
      login = loginH env,
      refresh = refreshH env,
      serviceToken = serviceTokenH env,
      verifyEmailRequest = verifyEmailRequestH env,
      verifyEmailConfirm = verifyEmailConfirmH env,
      passwordResetRequest = passwordResetRequestH env,
      passwordResetConfirm = passwordResetConfirmH env,
      passwordChange = passwordChangeH env,
      logout = logoutH env,
      me = meH env,
      session = sessionH env,
      passkeyRegisterBegin = passkeyRegisterBeginH env,
      passkeyRegisterComplete = passkeyRegisterCompleteH env,
      passkeyList = passkeysListH env,
      passkeyDelete = passkeyDeleteH env,
      mfaComplete = mfaCompleteH env,
      passkeyLoginBegin = passkeyLoginBeginH env,
      passkeyLoginComplete = passkeyLoginCompleteH env,
      impersonate = impersonateH env,
      stopImpersonate = stopImpersonateH env,
      auditEvents = auditEventsH env,
      adminListUsers = adminListUsersH env,
      adminGetUser = adminGetUserH env,
      adminSuspendUser = adminSuspendUserH env,
      adminReinstateUser = adminReinstateUserH env,
      adminDeleteUser = adminDeleteUserH env,
      adminListSessions = adminListSessionsH env,
      adminRevokeSessions = adminRevokeSessionsH env,
      adminRevokeSession = adminRevokeSessionH env,
      adminPasswordReset = adminPasswordResetH env,
      adminGrantRole = adminGrantRoleH env,
      adminRevokeRole = adminRevokeRoleH env
    }

signupH :: Env -> SignupRequest -> Handler (WithCookies SignupResponse)
signupH env req = do
  (loginId, mEmail) <- resolvePrincipal req.loginId req.email
  let cmd =
        SignupCommand
          { loginId = loginId,
            email = mEmail,
            password = PlainPassword req.password,
            displayName = mkDisplayName req.displayName
          }
  (user, pair) <- runAuth env (Wf.signup env.config cmd)
  pure $
    applyCookies env.config (tokenCookies env.config pair) $
      SignupResponse {user = userToResponse user, token = tokenPairToResponse env.config pair}

loginH :: Env -> SockAddr -> LoginRequest -> Handler (WithCookies LoginResponse)
loginH env peer req = do
  (loginId, _mEmail) <- resolvePrincipal req.loginId req.email
  let cmd = LoginCommand {loginId = loginId, password = PlainPassword req.password}
      ctx =
        ClientContext
          { clientIp = ClientIp (clientIpText peer),
            accountKey = env.accountKeyOf (loginIdText loginId)
          }
  result <- runAuth env (Wf.login env.config ctx cmd)
  -- The mfa_required arm issued no token, so there is nothing to put in a cookie.
  pure case result of
    Wf.LoginComplete _ pair ->
      applyCookies env.config (tokenCookies env.config pair) (loginResultToResponse env.config result)
    Wf.MfaRequired _ -> noHeader (noHeader (loginResultToResponse env.config result))

-- | Resolve the @(LoginId, optional Email)@ principal from a request's optional @loginId@/
-- @email@ fields (the SH-25 compatibility rule). A /present/ email is parsed through 'mkEmail'
-- (malformed → 400). The login id is the explicit @loginId@ parsed through 'mkLoginId'
-- (malformed → 400), or, when absent, defaults to the email text; with neither field present the
-- request is a 400.
resolvePrincipal :: Maybe Text -> Maybe Text -> Handler (LoginId, Maybe Email)
resolvePrincipal mLoginId mEmailText = do
  mEmail <- traverse (either (throwError . authErrorToServerError) pure . mkEmail) mEmailText
  loginId <- case mLoginId of
    Just t -> either (throwError . authErrorToServerError) pure (mkLoginId t)
    Nothing -> case mEmail of
      Just e -> pure (loginIdFromEmail e)
      Nothing -> throwError (toProblemError pcBadRequest (Just "loginId or email required"))
  pure (loginId, mEmail)

-- | The source IP of the request as text, used as the per-IP throttle key. Behind a reverse
-- proxy this is the proxy's address; a trusted @X-Forwarded-For@ policy would be layered in a
-- deployment that fronts the server with a proxy (out of scope here). The port is dropped so
-- all connections from one host share a key.
clientIpText :: SockAddr -> Text
clientIpText = \case
  SockAddrInet _ host -> Text.pack (show host)
  SockAddrInet6 _ _ host _ -> Text.pack (show host)
  other -> Text.pack (show other)

-- | @POST /v1/auth/refresh@. The token comes from the body, or — in cookie transport — from the
-- @shomei_refresh@ cookie. A cookie-borne token gets the same CSRF gate as any other
-- cookie-authenticated mutation: the browser attaches it automatically, so a foreign page
-- could otherwise rotate a victim's session.
refreshH :: Env -> Maybe Text -> Maybe Text -> Maybe Text -> RefreshRequest -> Handler (WithCookies TokenPairResponse)
refreshH env mCookieHeader mOrigin mReferer req = do
  presented <- case req.refreshToken of
    Just t -> pure t
    Nothing
      | transportUsesCookies env.config.tokenTransport,
        Just raw <- mCookieHeader,
        Just t <- refreshTokenFromCookie raw -> do
          unless (originHeaderAllowed env.config.cookieConfig.allowedOrigins mOrigin mReferer) (throwError csrfRejected)
          pure t
    Nothing -> throwError (toProblemError pcBadRequest (Just "refreshToken required"))
  pair <- runAuth env (Wf.refresh env.config (RefreshCommand {refreshToken = RefreshToken presented}))
  pure (applyCookies env.config (tokenCookies env.config pair) (tokenPairToResponse env.config pair))

-- | @POST \/oauth\/token@ (EP-4): the OAuth2 token endpoint and its @grant_type@ dispatcher.
--
-- __Every failure here is rendered by 'OAuth.oauthError' in the RFC 6749 §5.2 shape__, never by
-- 'authErrorToServerError'. A stock OAuth2 client parses @error@\/@error_description@ by field
-- name; handing it a problem document would break it. This is the one endpoint exempt from the
-- application-wide envelope (see "Shomei.Servant.OAuth" and "Shomei.Servant.Error").
--
-- __This @case@ is the extension point for the sibling plans in this MasterPlan.__ Plan 42
-- (@docs\/plans\/42-oidc-provider-subset-…@) registers @authorization_code@ (with PKCE
-- verification) and @refresh_token@ here; plan 43
-- (@docs\/plans\/43-rfc-8693-token-exchange-endpoint.md@) registers
-- @urn:ietf:params:oauth:grant-type:token-exchange@. Both reuse 'OAuth.extractClientAuth' and
-- 'OAuth.oauthError' unchanged; only this dispatcher grows an arm.
oauthTokenH ::
  Env ->
  Maybe Text ->
  Form ->
  Handler (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] OAuth.TokenResponse)
oauthTokenH env mAuthHeader form =
  case OAuth.lookupParam "grant_type" form of
    Nothing -> throwError (OAuth.invalidRequest "grant_type is required")
    Just "client_credentials" -> clientCredentialsGrant env mAuthHeader form
    Just other -> throwError (OAuth.unsupportedGrantType other)

-- | RFC 6749 §4.4. Authenticate the client, read the optional @scope@, mint the token.
clientCredentialsGrant ::
  Env ->
  Maybe Text ->
  Form ->
  Handler (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] OAuth.TokenResponse)
clientCredentialsGrant env mAuthHeader form = do
  auth <- either throwError pure (OAuth.extractClientAuth mAuthHeader form)
  let grant =
        ClientCredentials.ClientCredentialsGrant
          { clientId = auth ^. #clientId,
            clientSecret = auth ^. #clientSecret,
            requestedScopes = OAuth.parseScopeParam form
          }
  outcome <- runPort env (ClientCredentials.grantClientCredentials env.config grant)
  granted <- either (throwError . oauthErrorFor) pure outcome
  -- Read through lens labels: 'GrantedToken' shares @accessToken@/@expiresIn@/@sessionId@ with
  -- 'Shomei.Workflow.ServiceToken.IssuedServiceToken', so @granted.accessToken@ is ambiguous.
  let AccessToken token = granted ^. #accessToken
      body =
        OAuth.TokenResponse
          { accessToken = token,
            tokenType = "Bearer",
            expiresIn = round (granted ^. #expiresIn),
            scope = Text.unwords [s | Scope s <- Set.toList (granted ^. #grantedScopes)]
          }
  pure (addHeader "no-store" (addHeader "no-cache" body))

-- | The OAuth-local error mapping. Deliberately not 'authErrorToServerError': that renders the
-- problem-details envelope, which this endpoint must not emit.
oauthErrorFor :: AuthError -> ServerError
oauthErrorFor = \case
  OAuthClientInvalid -> OAuth.invalidClient
  OAuthScopeInvalid -> OAuth.oauthError status400 "invalid_scope" "requested scope exceeds the client's allowed scopes"
  -- No other AuthError is reachable from 'grantClientCredentials'. An infrastructure failure
  -- (a database outage surfacing as InternalAuthError) is a 500, still in the OAuth shape so a
  -- client's error parser does not itself fail while handling the failure.
  _ -> OAuth.oauthError status500 "server_error" "the authorization server encountered an unexpected condition"

serviceTokenH :: Env -> ServiceTokenRequest -> Handler ServiceTokenResponse
serviceTokenH env req = do
  when (null req.scopes) (throwError (toProblemError pcBadRequest (Just "scopes must not be empty")))
  actorId <- traverse parseActor req.actorId
  serviceTokenToResponse
    <$> runAuth
      env
      ( ServiceToken.issueServiceToken
          env.config
          ServiceToken.IssueServiceToken
            { accountId = ServiceAccountId req.accountId,
              secret = req.secret,
              scopes = Set.fromList (Scope <$> req.scopes),
              actorId = actorId
            }
      )
  where
    parseActor t =
      either (\_ -> throwError (toProblemError pcBadRequest (Just "invalid actorId"))) pure (parseId t)

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
  denyUnderImpersonation env "password_change" user
  runAuth
    env
    ( Account.changePassword
        env.config
        (Account.ChangePassword user.authUserId (PlainPassword req.currentPassword) (PlainPassword req.newPassword))
    )
  pure NoContent

-- | Refuse a request that arrives on a delegated (impersonation) token: any token whose
-- claims carry an @act@ actor is acting on behalf of someone and must not change credentials.
-- A blocked attempt is audited (with both ids and the action name) and returns HTTP 403.
--
-- TODO: when Shōmei grows further credential-changing endpoints (email change, account
-- deletion, TOTP enrollment), call this guard at the top of each of them too.
denyUnderImpersonation :: Env -> Text -> AuthUser -> Handler ()
denyUnderImpersonation env action user =
  case user.authClaims.actor of
    Nothing -> pure ()
    Just actorId -> do
      ts <- runPort env now
      runPort env $
        publishAuthEvent $
          Event.ImpersonationActionBlocked
            Event.ImpersonationActionBlockedData
              { actorUserId = actorId,
                subjectUserId = user.authUserId,
                sessionId = user.authSessionId,
                action = action,
                occurredAt = ts
              }
      throwError (authErrorToServerError ImpersonationActionBlocked)

-- | @POST /v1/auth/logout@, idempotent: a session that is already gone is success, not a
-- @404@. Retrying a logout after a network blip, or double-tapping the button, must not report
-- failure for having achieved exactly what the caller asked for. The cookies are cleared either
-- way, so a client whose session was revoked out from under it (by an admin, or by refresh-reuse
-- detection) can still log out cleanly.
--
-- Only 'SessionNotFound' is intercepted; every other 'AuthError' still maps through
-- 'authErrorToServerError'.
logoutH :: Env -> AuthUser -> Handler (WithCookies NoContent)
logoutH env user = do
  outcome <- runPort env (Wf.logout env.config (LogoutCommand {sessionId = user.authSessionId}))
  case outcome of
    Left SessionNotFound -> pure cleared
    Left err -> throwError (authErrorToServerError err)
    Right () -> pure cleared
  where
    cleared = applyCookies env.config (clearedCookies env.config) NoContent

meH :: Env -> AuthUser -> Handler UserResponse
meH env user = do
  mUser <- runPort env (findUserById user.authUserId)
  case mUser of
    Just u -> pure (userToResponse u)
    Nothing -> throwError (toProblemError pcUserNotFound Nothing)

sessionH :: Env -> AuthUser -> Handler SessionResponse
sessionH env user = do
  mSession <- runPort env (findSessionById user.authSessionId)
  case mSession of
    Just s -> pure (sessionToResponse s)
    Nothing -> throwError (toProblemError pcSessionNotFound Nothing)

passkeyRegisterBeginH :: Env -> AuthUser -> Handler PasskeyRegisterBeginResponse
passkeyRegisterBeginH env user = do
  denyUnderImpersonation env "passkey_register" user
  (cid, options) <- runAuth env (Passkey.beginPasskeyRegistration env.config user.authUserId)
  pure PasskeyRegisterBeginResponse {ceremonyId = idText cid, options = options}

passkeyRegisterCompleteH :: Env -> AuthUser -> PasskeyRegisterCompleteRequest -> Handler PasskeyResponse
passkeyRegisterCompleteH env user req = do
  denyUnderImpersonation env "passkey_register" user
  cid <- either (\_ -> throwError (toProblemError pcBadRequest (Just "invalid ceremonyId"))) pure (parseId req.ceremonyId)
  passkey <-
    runAuth
      env
      (Passkey.completePasskeyRegistration env.config user.authUserId cid req.credential req.label)
  pure (passkeyToResponse passkey)

passkeysListH :: Env -> AuthUser -> Handler [PasskeyResponse]
passkeysListH env user = do
  passkeys <- runPort env (Passkey.listPasskeys user.authUserId)
  pure (map passkeyToResponse passkeys)

passkeyDeleteH :: Env -> AuthUser -> PasskeyId -> Handler NoContent
passkeyDeleteH env user pid = do
  denyUnderImpersonation env "passkey_remove" user
  runAuth env (Passkey.removePasskey user.authUserId pid)
  pure NoContent

-- | @POST /v1/auth/mfa/complete@: finish a step-up begun by @POST /v1/auth/login@'s
-- @mfa_required@ arm. Unauthenticated — completing the second factor is how a session is
-- obtained. A malformed ceremony id is a 400 before the workflow runs; a missing/expired/
-- consumed ceremony is a 404 and a failed assertion a 401 (via 'authErrorToServerError').
mfaCompleteH :: Env -> MfaCompleteRequest -> Handler (WithCookies TokenPairResponse)
mfaCompleteH env req = do
  cid <- either (\_ -> throwError (toProblemError pcBadRequest (Just "invalid ceremonyId"))) pure (parseId req.ceremonyId)
  (_user, pair) <- runAuth env (Mfa.completeMfa env.config cid req.assertion)
  pure (applyCookies env.config (tokenCookies env.config pair) (tokenPairToResponse env.config pair))

-- | @POST /v1/auth/login/passkey/begin@: start a passwordless passkey login (no password).
passkeyLoginBeginH :: Env -> Handler PasskeyLoginBeginResponse
passkeyLoginBeginH env = do
  (cid, options) <- runAuth env (Mfa.beginPasswordlessLogin env.config)
  pure PasskeyLoginBeginResponse {ceremonyId = idText cid, options = options}

-- | @POST /v1/auth/login/passkey/complete@: finish a passwordless passkey login → token pair.
passkeyLoginCompleteH :: Env -> PasskeyLoginCompleteRequest -> Handler (WithCookies TokenPairResponse)
passkeyLoginCompleteH env req = do
  cid <- either (\_ -> throwError (toProblemError pcBadRequest (Just "invalid ceremonyId"))) pure (parseId req.ceremonyId)
  (_user, pair) <- runAuth env (Mfa.completePasswordlessLogin env.config cid req.assertion)
  pure (applyCookies env.config (tokenCookies env.config pair) (tokenPairToResponse env.config pair))

-- | @POST /v1/auth/impersonate@: exchange the caller's token for a short-lived delegated
-- token acting on behalf of 'req.userId'. A malformed target id is a 400 before the workflow
-- runs; the workflow enforces scope/freshness/target checks and audits the start.
impersonateH :: Env -> AuthUser -> SockAddr -> ImpersonateRequest -> Handler ImpersonateResponse
impersonateH env caller peer req = do
  target <-
    either (\_ -> throwError (authErrorToServerError ImpersonationTargetInvalid)) pure (parseId req.userId)
  (session, access) <-
    runAuth env $
      Imp.startImpersonation
        env.config
        Imp.StartImpersonation
          { actorClaims = caller.authClaims,
            targetUserId = target,
            reason = req.reason,
            ticketId = req.ticketId,
            clientIp = Just (clientIpText peer)
          }
  pure (impersonateToResponse session access)

-- | @DELETE /v1/auth/impersonate@: stop impersonating by revoking the delegated session named
-- by the presented token. A non-delegated token (no @act@ claim) is rejected by the workflow.
stopImpersonateH :: Env -> AuthUser -> Handler NoContent
stopImpersonateH env caller = do
  runAuth env (Imp.stopImpersonation caller.authClaims)
  pure NoContent

-- | @GET /v1/admin/audit/events@ (EP-7): admin-gated, filtered, keyset-paginated audit-trail
-- read. The query params arrive in route order.
--
-- There is no authorization check here: the route's @RequireRole "admin"@ combinator
-- authenticated the caller and rejected a non-admin with 403 before this handler ran. The
-- 'AuthUser' it produced is passed through and deliberately unused. A malformed param (bad
-- UUID, timestamp, or cursor) is a 400 via 'buildQuery'. 'nextCursor' is set only when the page
-- came back full (exactly the requested, clamped limit), so a caller paginates until it is
-- 'Nothing'.
auditEventsH ::
  Env ->
  AuthUser ->
  Maybe Text -> -- ?user=<uuid>
  Maybe Text -> -- ?session=<uuid>
  [Text] -> -- ?type=<t>&type=<t>…
  Maybe Text -> -- ?since=<iso8601>
  Maybe Text -> -- ?until=<iso8601>
  Maybe Int -> -- ?limit=<n>
  Maybe Text -> -- ?before=<cursor>
  Handler AuditEventsPage
auditEventsH env _user mUser mSession types mSince mUntil mLimit mBefore = do
  q <- either badRequest pure (buildQuery mUser mSession types mSince mUntil mLimit mBefore)
  rows <- runPort env (queryAuthEvents q)
  let full = length rows == clampLimit q.queryLimit
      next = if full then encodeCursor . lastCursor <$> lastMay rows else Nothing
  pure AuditEventsPage {events = map storedToResponse rows, nextCursor = next}
  where
    lastCursor s = AuditCursor {cursorCreatedAt = s.storedCreatedAt, cursorEventId = s.storedEventId}
    lastMay = \case
      [] -> Nothing
      xs -> Just (last xs)

-- | Parse the textual query params into an 'AuditEventQuery'. Total: any parse failure is a
-- 'Left' the handler maps to 400. The limit defaults to 50 and is clamped inside the query
-- layer; an empty @type@ list means "all types".
buildQuery ::
  Maybe Text ->
  Maybe Text ->
  [Text] ->
  Maybe Text ->
  Maybe Text ->
  Maybe Int ->
  Maybe Text ->
  Either Text AuditEventQuery
buildQuery mUser mSession types mSince mUntil mLimit mBefore = do
  user <- optUuid "user" mUser
  session <- optUuid "session" mSession
  since <- optTime "since" mSince
  until_ <- optTime "until" mUntil
  before <- optCursor mBefore
  pure
    emptyAuditQuery
      { queryUserId = user,
        querySessionId = session,
        queryEventTypes = types,
        querySince = since,
        queryUntil = until_,
        queryLimit = fromMaybe 50 mLimit,
        queryBefore = before
      }
  where
    optUuid :: Text -> Maybe Text -> Either Text (Maybe UUID)
    optUuid name = \case
      Nothing -> Right Nothing
      Just t -> maybe (Left ("invalid " <> name <> " parameter (expected a UUID)")) (Right . Just) (UUID.fromText t)
    optTime :: Text -> Maybe Text -> Either Text (Maybe UTCTime)
    optTime name = \case
      Nothing -> Right Nothing
      Just t -> maybe (Left ("invalid " <> name <> " parameter (expected an ISO-8601 timestamp)")) (Right . Just) (iso8601ParseM (Text.unpack t))
    optCursor :: Maybe Text -> Either Text (Maybe AuditCursor)
    optCursor = \case
      Nothing -> Right Nothing
      Just t -> maybe (Left "invalid before cursor") (Right . Just) (decodeCursor t)

-- ---------------------------------------------------------------------------
-- The administrative surface (EP-2)
--
-- Every handler below opens with 'requireAdmin'; every /mutating/ one follows with
-- 'denyUnderImpersonation', so an operator impersonating a customer cannot administer as that
-- customer. Reads are allowed under impersonation: looking is not laundering.
--
-- The workflows in "Shomei.Workflow.Admin" implement no policy of their own. The two policies
-- that live here, and only here, are the admin gate and the self-target refusal.
-- ---------------------------------------------------------------------------

-- | Refuse an administrator acting on their own account.
--
-- Suspending or deleting yourself is almost always a mistake, and the one case where it is not
-- (removing a compromised admin) is better served by another admin or by the CLI on the box —
-- which, unlike this API, cannot lock the last administrator out of their own deployment.
-- Revoking your own /sessions/ is allowed: that is a sensible response to a stolen laptop.
denySelfTarget :: AuthUser -> UserId -> Handler ()
denySelfTarget user target =
  when (target == user.authUserId) do
    throwError (toProblemError pcSelfTargetForbidden Nothing)

-- | @GET \/v1\/admin\/users@: a newest-first keyset page, optionally filtered by status.
adminListUsersH :: Env -> AuthUser -> Maybe Text -> Maybe Int -> Maybe Text -> Handler AdminUsersPage
adminListUsersH env user mStatus mLimit mBefore = do
  requireAdmin user
  q <- either badRequest pure (buildUserQuery mStatus mLimit mBefore)
  rows <- runPort env (listUsers q)
  let full = length rows == clampUserLimit q.queryLimit
      next = if full then encodeUserCursor . cursorOf <$> lastMay rows else Nothing
  pure AdminUsersPage {users = map userToResponse rows, nextCursor = next}
  where
    cursorOf u = UserCursor {cursorCreatedAt = u.createdAt, cursorUserId = u.userId}
    lastMay = \case
      [] -> Nothing
      xs -> Just (last xs)

-- | Parse the listing's query params. Total: every failure is a 'Left' the handler maps to 400.
buildUserQuery :: Maybe Text -> Maybe Int -> Maybe Text -> Either Text UserListQuery
buildUserQuery mStatus mLimit mBefore = do
  status <- traverse parseStatus mStatus
  before <- case mBefore of
    Nothing -> Right Nothing
    Just t -> maybe (Left "invalid before cursor") (Right . Just) (decodeUserCursor t)
  pure emptyUserListQuery {queryStatus = status, queryLimit = fromMaybe 50 mLimit, queryBefore = before}
  where
    parseStatus = \case
      "active" -> Right UserActive
      "suspended" -> Right UserSuspended
      "deleted" -> Right UserDeleted
      other -> Left ("invalid status parameter: " <> other <> " (expected active, suspended, or deleted)")

-- | @GET \/v1\/admin\/users\/{userId}@: the user plus their /persistent/ role grants — not
-- whatever an outstanding token of theirs happens to carry.
adminGetUserH :: Env -> AuthUser -> UserId -> Handler AdminUserResponse
adminGetUserH env user target = do
  requireAdmin user
  found <- requireExistingUser env target
  roles <- runAuth env (Roles.rolesOf target)
  pure (adminUserToResponse found roles)

adminSuspendUserH :: Env -> AuthUser -> UserId -> Handler NoContent
adminSuspendUserH env user target = do
  requireAdmin user
  denyUnderImpersonation env "admin_suspend" user
  denySelfTarget user target
  runAuth env (Admin.suspendUser user.authUserId target)
  pure NoContent

adminReinstateUserH :: Env -> AuthUser -> UserId -> Handler NoContent
adminReinstateUserH env user target = do
  requireAdmin user
  denyUnderImpersonation env "admin_reinstate" user
  runAuth env (Admin.reinstateUser user.authUserId target)
  pure NoContent

adminDeleteUserH :: Env -> AuthUser -> UserId -> Handler NoContent
adminDeleteUserH env user target = do
  requireAdmin user
  denyUnderImpersonation env "admin_delete" user
  denySelfTarget user target
  runAuth env (Admin.deleteUser user.authUserId target)
  pure NoContent

-- | Every session of the target, newest first, in every status: an admin investigating an
-- incident needs to see the revoked ones too.
adminListSessionsH :: Env -> AuthUser -> UserId -> Handler [SessionResponse]
adminListSessionsH env user target = do
  requireAdmin user
  _ <- requireExistingUser env target
  map sessionToResponse <$> runPort env (listSessionsForUser target)

-- | Revoke every active session of a user.
--
-- The existence check is not redundant: 'Admin.revokeUserSessions' answers @Right 0@ for a user
-- who does not exist (they have no sessions to end), which over HTTP would turn a typo'd user id
-- into a cheerful @204@. The sibling @GET@ already 404s; so does this.
adminRevokeSessionsH :: Env -> AuthUser -> UserId -> Handler NoContent
adminRevokeSessionsH env user target = do
  requireAdmin user
  denyUnderImpersonation env "admin_revoke_sessions" user
  _ <- requireExistingUser env target
  _ <- runAuth env (Admin.revokeUserSessions user.authUserId target)
  pure NoContent

-- | 404 unless the user exists; returns the row for handlers that need it.
requireExistingUser :: Env -> UserId -> Handler User
requireExistingUser env target = do
  mUser <- runPort env (findUserById target)
  maybe (throwError (authErrorToServerError UserNotFound)) pure mUser

adminRevokeSessionH :: Env -> AuthUser -> SessionId -> Handler NoContent
adminRevokeSessionH env user sid = do
  requireAdmin user
  denyUnderImpersonation env "admin_revoke_session" user
  runAuth env (Admin.revokeOneSession user.authUserId sid)
  pure NoContent

-- | @POST \/v1\/admin\/users\/{userId}\/password-reset@: drive the ordinary reset flow — the same
-- token table, the same 'Shomei.Effect.Notifier.Notifier' delivery, the same audit event — for a
-- user named by id.
--
-- Answers @409 user_has_no_email@ honestly when the target has no address. The public endpoint's
-- unconditional @202@ exists to stop strangers enumerating addresses; an authorized admin who
-- already holds the user id learns nothing from a real error.
adminPasswordResetH :: Env -> AuthUser -> UserId -> Handler NoContent
adminPasswordResetH env user target = do
  requireAdmin user
  denyUnderImpersonation env "admin_password_reset" user
  found <- requireExistingUser env target
  email <- maybe (throwError (authErrorToServerError UserHasNoEmail)) pure found.email
  runAuth env (Account.requestPasswordReset env.config (Account.RequestPasswordReset email))
  pure NoContent

-- | @PUT \/v1\/admin\/users\/{userId}\/roles\/{role}@. Idempotent, as a PUT to a set-membership
-- resource should be: re-granting a held role is @204@, and the workflow publishes no event for a
-- grant that changed nothing.
adminGrantRoleH :: Env -> AuthUser -> UserId -> Text -> Handler NoContent
adminGrantRoleH env user target rawRole = do
  requireAdmin user
  denyUnderImpersonation env "admin_grant_role" user
  role <- parseRole rawRole
  _ <- runAuth env (Roles.grantRoleTo (Just user.authUserId) target role)
  pure NoContent

-- | @DELETE \/v1\/admin\/users\/{userId}\/roles\/{role}@. @404@ when the user did not hold the
-- role: unlike the idempotent grant, "revoke something that was never there" is a request the
-- caller got wrong, and silently succeeding would hide a typo in the role name.
adminRevokeRoleH :: Env -> AuthUser -> UserId -> Text -> Handler NoContent
adminRevokeRoleH env user target rawRole = do
  requireAdmin user
  denyUnderImpersonation env "admin_revoke_role" user
  role <- parseRole rawRole
  changed <- runAuth env (Roles.revokeRoleFrom (Just user.authUserId) target role)
  unless changed do
    throwError (toProblemError pcRoleNotGranted Nothing)
  pure NoContent

-- | A captured role name, trimmed. Blank is a 400 rather than a lookup for the empty role.
parseRole :: Text -> Handler Role
parseRole raw
  | Text.null trimmed = badRequest ("role must not be blank" :: Text)
  | otherwise = pure (Role trimmed)
  where
    trimmed = Text.strip raw

badRequest :: Text -> Handler a
badRequest msg = throwError (toProblemError pcBadRequest (Just msg))

-- | @GET /.well-known/jwks.json@. Five minutes of caching bounds how long a revoked key's
-- public half lingers in a verifier's cache without ever risking a false rejection: a key
-- being rotated out stays trusted for verification long past five minutes (see the staged
-- lifecycle in @docs\/user\/security.md@), so a stale copy of this document is always a
-- superset of the keys currently signing.
jwksH :: Env -> Handler (Headers '[Header "Cache-Control" Text] Value)
jwksH env = addHeader "public, max-age=300" <$> liftIO env.jwksJson

healthH :: Handler HealthResponse
healthH = pure HealthResponse {status = "ok"}

-- | @GET /ready@ (EP-3): readiness, distinct from liveness @/health@. The single
-- 'listActiveSigningKeys' call covers BOTH preconditions for serving auth: it hits PostgreSQL
-- (so a 'Left'/exception means the database is unreachable) and a non-empty result means an
-- active signing key exists. 200 only when both hold; otherwise 503 with a JSON body naming the
-- failed check, so a load balancer drains traffic. Liveness stays dependency-free.
readyH :: Env -> Handler ReadyResponse
readyH env = do
  outcome <- runPortChecked env listActiveSigningKeys
  case outcome of
    Right keys
      | not (null keys) -> pure ReadyResponse {status = "ready", database = True, signingKey = True}
      | otherwise -> notReady ReadyResponse {status = "not_ready", database = True, signingKey = False}
    Left _ -> notReady ReadyResponse {status = "not_ready", database = False, signingKey = False}
  where
    notReady body =
      throwError
        err503
          { errBody = encode body,
            errHeaders = [("Content-Type", "application/json")]
          }

mkDisplayName :: Text -> Maybe Text
mkDisplayName t
  | Text.null t = Nothing
  | otherwise = Just t
