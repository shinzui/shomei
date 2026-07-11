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
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Network.HTTP.Types.Status (status400, status401, status404, status500)
import Network.HTTP.Types.URI (renderSimpleQuery)
import Network.Socket (SockAddr (..))
import Servant (Handler, Header, Headers, NoContent (..), ServerError (..), addHeader, err503, errBody, errHeaders, noHeader, throwError)
import Servant.Server.Generic (AsServerT)
import Shomei.Config (CookieConfig (..), ImpersonationConfig (..), OAuthConfig (..), ServiceAccountId (..), ShomeiConfig (..), transportUsesCookies)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Role (..), Scope (..))
import Shomei.Domain.Command
  ( ClientContext (..),
    LoginCommand (..),
    LogoutCommand (..),
    RefreshCommand (..),
    SignupCommand (..),
  )
import Shomei.Domain.Email (Email, emailText, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.IdTokenClaims (IdToken (..))
import Shomei.Domain.LoginAttempt (ClientIp (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail, loginIdText, mkLoginId)
import Shomei.Domain.OAuthClient (OAuthClientStatus (..), isRegisteredRedirectUri)
import Shomei.Domain.OAuthClient qualified as OAuthClient
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (RefreshToken (..), RefreshTokenStatus (RefreshTokenActive))
import Shomei.Domain.ServiceAccount qualified as ServiceAccount
import Shomei.Domain.Session qualified as Session
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
import Shomei.Effect.OAuthClientStore (findOAuthClientByClientId)
import Shomei.Effect.RecoveryCodeStore (countUnusedRecoveryCodes)
import Shomei.Effect.RefreshTokenStore (findRefreshTokenByHash, revokeRefreshTokenFamily, revokeSessionRefreshTokens)
import Shomei.Effect.ServiceAccountStore (findServiceAccountByClientId)
import Shomei.Effect.SessionStore (findSessionById, listSessionsForUser, revokeSession)
import Shomei.Effect.SigningKeyStore (listActiveSigningKeys)
import Shomei.Effect.TokenGen (hashRefreshToken)
import Shomei.Effect.TokenVerifier (verifyAccessToken)
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
        ImpersonationForbidden,
        ImpersonationTargetInvalid,
        OAuthClientInvalid,
        OAuthGrantInvalid,
        OAuthRequestMalformed,
        OAuthScopeInvalid,
        SessionNotFound,
        UserHasNoEmail,
        UserNotFound
      ),
  )
import Shomei.Id (PasskeyId, SessionId, UserId, idText, parseId)
import Shomei.Prelude
import Shomei.Servant.API (ShomeiAPI (..), ShomeiRoutes (..))
import Shomei.Servant.Auth (AuthUser (..), cookiePolicyFromConfig, csrfRejected, originHeaderAllowed, resolveAuthUser)
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
    RecoveryCodesCountResponse (..),
    RecoveryCodesResponse (..),
    RefreshRequest (..),
    ServiceTokenRequest (..),
    ServiceTokenResponse,
    SessionResponse,
    SignupRequest (..),
    SignupResponse (..),
    TokenPairResponse,
    TotpEnrollResponse (..),
    TotpRemoveRequest (..),
    TotpVerifyRequest (..),
    UserResponse,
    VerifyEmailRequest (..),
    adminUserToResponse,
    mfaCompletionOf,
    totpRemovalProofOf,
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
    pcReauthenticationRequired,
    pcRoleNotGranted,
    pcSelfTargetForbidden,
    pcSessionNotFound,
    pcUserNotFound,
    toProblemError,
  )
import Shomei.Servant.OAuth qualified as OAuth
import Shomei.Servant.Oidc qualified as Oidc
-- No cycle: "Shomei.Servant.OpenApi" imports only API/DTO/Authz/Id, never this module.
import Shomei.Servant.OpenApi (openApiValue)
import Shomei.Servant.Seam (Env (..), runAuth, runPort, runPortChecked)
import Shomei.Workflow qualified as Wf
import Shomei.Workflow.Account qualified as Account
import Shomei.Workflow.Admin qualified as Admin
import Shomei.Workflow.ClientCredentials qualified as ClientCredentials
import Shomei.Workflow.Impersonation qualified as Imp
import Shomei.Workflow.Mfa qualified as Mfa
import Shomei.Workflow.Totp qualified as Totp
import Shomei.Workflow.OAuthAuthorize qualified as OAuthAuthorize
import Shomei.Workflow.OAuthTokenGrant qualified as OAuthTokenGrant
import Shomei.Workflow.Passkey qualified as Passkey
import Shomei.Workflow.Roles qualified as Roles
import Shomei.Workflow.ServiceToken qualified as ServiceToken
import Shomei.Workflow.TokenExchange qualified as TokenExchange
import Web.FormUrlEncoded (Form)

-- | Assemble the served route tree: the application record mounted under @\/v1@, plus the
-- unversioned JWKS document and the liveness\/readiness probes.
shomeiRoutes :: Env -> ShomeiRoutes (AsServerT Handler)
shomeiRoutes env =
  ShomeiRoutes
    { v1 = shomeiServer env,
      jwks = jwksH env,
      openapi = pure openApiValue,
      oidcDiscovery = oidcDiscoveryH env,
      oauthAuthorize = oauthAuthorizeH env,
      oauthToken = oauthTokenH env,
      oauthUserinfo = oauthUserinfoH env,
      oauthIntrospect = oauthIntrospectH env,
      oauthRevoke = oauthRevokeH env,
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
      totpEnroll = totpEnrollH env,
      totpVerify = totpVerifyH env,
      totpDelete = totpDeleteH env,
      recoveryCodesGenerate = recoveryCodesGenerateH env,
      recoveryCodesCount = recoveryCodesCountH env,
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

-- | @GET \/.well-known\/openid-configuration@ (EP-5).
--
-- With the provider disabled the answer is @404@ carrying an RFC 6749-shaped body, not a problem
-- document: a client that reaches this URL is OIDC tooling, and it must fail on a shape it can
-- parse. This is the same envelope boundary the @\/oauth\/*@ endpoints observe.
oidcDiscoveryH :: Env -> Handler Value
oidcDiscoveryH env
  | env.config.oauthConfig.oidcEnabled = pure (Oidc.discoveryDocument env.config)
  | otherwise =
      throwError
        ( OAuth.oauthError
            status404
            "not_found"
            "the OIDC provider is not enabled on this deployment"
        )

-- | @GET \/oauth\/authorize@ (EP-5): the authorization-code flow's browser leg (RFC 6749 §4.1).
--
-- __The order of the four steps below is the security property__, not a style choice.
--
--   1. Resolve @client_id@ to an /active/ client and require @redirect_uri@ to be one of its
--      registered URIs, compared byte for byte. Either failing is @400@ with __no redirect__: a
--      server that redirects to an unvalidated URI is an open redirector, and an attacker uses it
--      to have this endpoint deliver authorization codes to a host of their choosing. This is why
--      a test that wants an error for an unknown client must expect @400@ and never @302@.
--
--   2. Any other parameter violation redirects to the /now validated/ @redirect_uri@ carrying
--      @error@, @error_description@, and the echoed @state@ (RFC 6749 §4.1.2.1). The client, not
--      the user, is the one who can fix these.
--
--   3. No authenticated user: redirect to the operator's @loginUrl@ with the /reconstructed/
--      authorize URL in @return_to@. It is rebuilt from the parameters this handler validated,
--      never from anything the caller supplied, so the host cannot be talked into sending the
--      user back to somewhere else. With no @loginUrl@ configured, @401@ with an OAuth error body.
--      Shōmei persists no pending-authorize state: it all round-trips in that URL.
--
--   4. Authenticated: run the workflow and redirect with @code@, @state@, and @iss@.
oauthAuthorizeH ::
  Env ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Handler (Headers '[Header "Location" Text, Header "Cache-Control" Text] NoContent)
oauthAuthorizeH env mAuthHeader mCookie mResponseType mClientId mRedirectUri mScope mState mNonce mChallenge mChallengeMethod = do
  unless env.config.oauthConfig.oidcEnabled (throwError providerDisabled)

  -- (1) The no-redirect regime.
  clientId <- maybe (throwError (oauthBadRequest "client_id is required")) pure mClientId
  redirectUri <- maybe (throwError (oauthBadRequest "redirect_uri is required")) pure mRedirectUri
  client <-
    runPort env (findOAuthClientByClientId clientId)
      >>= maybe (throwError (oauthBadRequest "unknown client_id")) pure
  -- A revoked client is refused exactly as an unknown one is, and neither may redirect.
  unless (client ^. #status == OAuthClientActive) (throwError (oauthBadRequest "unknown client_id"))
  unless (isRegisteredRedirectUri client redirectUri) (throwError (oauthBadRequest "redirect_uri is not registered for this client"))

  let params =
        OAuthAuthorize.AuthorizeParams
          { responseType = mResponseType,
            redirectUri,
            scope = mScope,
            state = mState,
            nonce = mNonce,
            codeChallenge = mChallenge,
            codeChallengeMethod = mChallengeMethod
          }

  -- (3) Authenticate before running the workflow, so a request that is going to bounce to the
  -- login page never mints a code. The parameter errors in (2) are still reported first when they
  -- apply to an authenticated caller, because the workflow raises them.
  mUser <- liftIO (resolveAuthUser (cookiePolicyFromConfig env.config) env.verifier mAuthHeader mCookie)
  case mUser of
    Nothing -> case env.config.oauthConfig.loginUrl of
      Just loginUrl -> redirectTo (loginUrl `withQuery` [("return_to", TE.encodeUtf8 (reconstructedAuthorizeUrl params clientId))])
      Nothing -> throwError (OAuth.oauthError status401 "login_required" "no authenticated user and no login URL is configured")
    Just user -> do
      outcome <- runPort env (OAuthAuthorize.authorize env.config client user.authClaims params)
      case outcome of
        -- (2) The redirect regime: the client learns what it did wrong, at a URI we validated.
        Left e ->
          redirectTo
            ( redirectUri
                `withQuery` ( [ ("error", TE.encodeUtf8 (OAuthAuthorize.authorizeErrorCode e)),
                                ("error_description", TE.encodeUtf8 (OAuthAuthorize.authorizeErrorDescription e))
                              ]
                                <> stateParam mState
                            )
            )
        -- (4) RFC 9207: `iss` lets a client that talks to several providers detect a mix-up attack.
        Right issued ->
          redirectTo
            ( redirectUri
                `withQuery` ( [("code", TE.encodeUtf8 (issued ^. #code))]
                                <> stateParam (issued ^. #state)
                                <> [("iss", TE.encodeUtf8 (issuerText env.config.issuer))]
                            )
            )
  where
    providerDisabled =
      OAuth.oauthError status404 "not_found" "the OIDC provider is not enabled on this deployment"

    oauthBadRequest = OAuth.oauthError status400 "invalid_request"

    stateParam = foldMap (\s -> [("state", TE.encodeUtf8 s)])

    issuerText (Issuer t) = t

    -- `no-store` on every answer: a cached 302 would replay a one-time code out of the browser's
    -- history, and a cached error redirect would confuse a retry.
    redirectTo loc = pure (addHeader loc (addHeader "no-store" NoContent))

    -- Rebuilt from what this handler validated, never from a caller-supplied copy. The base is the
    -- issuer, which for an OIDC-enabled deployment IS the public base URL (boot enforces it).
    reconstructedAuthorizeUrl params clientId =
      (Oidc.oidcEndpointBase env.config <> "/oauth/authorize")
        `withQuery` ( [ ("client_id", TE.encodeUtf8 clientId),
                        ("redirect_uri", TE.encodeUtf8 params.redirectUri)
                      ]
                        <> optional "response_type" params.responseType
                        <> optional "scope" params.scope
                        <> optional "state" params.state
                        <> optional "nonce" params.nonce
                        <> optional "code_challenge" params.codeChallenge
                        <> optional "code_challenge_method" params.codeChallengeMethod
                    )

    optional k = foldMap (\v -> [(k, TE.encodeUtf8 v)])

-- | Append query parameters to a URL that may already carry some.
--
-- 'renderSimpleQuery' percent-encodes every key and value, which is what keeps a @state@ or
-- @return_to@ containing @&@ or @#@ from splicing extra parameters into the URL.
withQuery :: Text -> [(ByteString, ByteString)] -> Text
withQuery url params
  | null params = url
  | otherwise = url <> separator <> TE.decodeUtf8 (renderSimpleQuery False params)
  where
    separator = if Text.any (== '?') url then "&" else "?"

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
  SockAddr ->
  Form ->
  Handler (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] OAuth.TokenResponse)
oauthTokenH env mAuthHeader peer form =
  case OAuth.lookupParam "grant_type" form of
    Nothing -> throwError (OAuth.invalidRequest "grant_type is required")
    Just "client_credentials" -> clientCredentialsGrant env mAuthHeader form
    Just "authorization_code" -> authorizationCodeGrant env mAuthHeader form
    Just "refresh_token" -> refreshTokenGrant env mAuthHeader form
    Just "urn:ietf:params:oauth:grant-type:token-exchange" -> tokenExchangeGrant env mAuthHeader peer form
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
            scope = Text.unwords [s | Scope s <- Set.toList (granted ^. #grantedScopes)],
            -- Deliberately refresh-less: the credential dies at its TTL and the client asks again.
            refreshToken = Nothing,
            idToken = Nothing,
            issuedTokenType = Nothing
          }
  pure (addHeader "no-store" (addHeader "no-cache" body))

-- | RFC 6749 §4.1.3 with PKCE (RFC 7636). Redeem the code, mint access + refresh + (for @openid@)
-- an ID token.
authorizationCodeGrant ::
  Env ->
  Maybe Text ->
  Form ->
  Handler (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] OAuth.TokenResponse)
authorizationCodeGrant env mAuthHeader form = do
  (clientId, mSecret) <- oauthClientCredentials mAuthHeader form
  code <- requireParam "code" form
  redirectUri <- requireParam "redirect_uri" form
  let grant =
        OAuthTokenGrant.ExchangeAuthorizationCode
          { clientId,
            clientSecret = mSecret,
            code,
            redirectUri,
            codeVerifier = OAuth.lookupParam "code_verifier" form
          }
  outcome <- runPort env (OAuthTokenGrant.exchangeAuthorizationCode env.config grant)
  exchanged <- either (throwError . grantError) pure outcome
  let AccessToken access = exchanged ^. #tokens . #accessToken
      RefreshToken refresh = exchanged ^. #tokens . #refreshToken
      body =
        OAuth.TokenResponse
          { accessToken = access,
            tokenType = "Bearer",
            expiresIn = round env.config.accessTokenTTL,
            scope = Text.unwords [sc | Scope sc <- Set.toList (exchanged ^. #grantedScopes)],
            refreshToken = Just refresh,
            idToken = (\(IdToken t) -> t) <$> exchanged ^. #idToken,
            issuedTokenType = Nothing
          }
  pure (addHeader "no-store" (addHeader "no-cache" body))

-- | RFC 6749 §6, bound to the client that minted the session. Rotation and reuse detection are the
-- existing workflow's; this arm adds only the client check.
refreshTokenGrant ::
  Env ->
  Maybe Text ->
  Form ->
  Handler (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] OAuth.TokenResponse)
refreshTokenGrant env mAuthHeader form = do
  (clientId, mSecret) <- oauthClientCredentials mAuthHeader form
  presented <- requireParam "refresh_token" form
  let grant =
        OAuthTokenGrant.RefreshViaOAuth
          { clientId,
            clientSecret = mSecret,
            refreshToken = RefreshToken presented
          }
  outcome <- runPort env (OAuthTokenGrant.refreshViaOAuth env.config grant)
  pair <- either (throwError . grantError) pure outcome
  -- Read through lens labels: 'TokenPair' shares @accessToken@/@refreshToken@/@expiresIn@ with
  -- 'OAuth.TokenResponse' and 'ExchangedTokens', so dot access is ambiguous here.
  let AccessToken access = pair ^. #accessToken
      RefreshToken rotated = pair ^. #refreshToken
      body =
        OAuth.TokenResponse
          { accessToken = access,
            tokenType = "Bearer",
            expiresIn = round (pair ^. #expiresIn :: NominalDiffTime),
            -- The rotated token carries the session's scopes, which the access token already
            -- states; echoing the granted set would need a second claims read for no gain.
            scope = "",
            refreshToken = Just rotated,
            -- No ID token on refresh: the nonce and auth_time an ID token must carry belong to the
            -- authorize request, and Shōmei does not persist them past the code. A client that
            -- needs a fresh ID token runs the authorize flow again.
            idToken = Nothing,
            issuedTokenType = Nothing
          }
  pure (addHeader "no-store" (addHeader "no-cache" body))

-- | RFC 8693 token exchange (EP-6): the third grant on @POST \/oauth\/token@. Two modes selected by
-- the parameters (see "Shomei.Workflow.TokenExchange"):
--
--   * __impersonation__ — no client authentication; the operator's credential is the @actor_token@.
--   * __service on-behalf-of__ — the service authenticates as an EP-4 service account (client_secret_
--     basic\/post) and presents a user's access token as the @subject_token@.
--
-- Client authentication is /optional/ here, which is why this arm cannot reuse
-- 'oauthClientCredentials' (which demands it): absent credentials mean impersonation mode, present
-- credentials must resolve to an active service account or fail @401 invalid_client@. The @resource@
-- parameter is rejected; @audience@ is ignored (both documented in the plan).
tokenExchangeGrant ::
  Env ->
  Maybe Text ->
  SockAddr ->
  Form ->
  Handler (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] OAuth.TokenResponse)
tokenExchangeGrant env mAuthHeader peer form = do
  when (isJust (OAuth.lookupParam "resource" form)) $
    throwError (OAuth.invalidRequest "resource parameter not supported")
  mSvc <- resolveExchangeClient env mAuthHeader form
  subjectToken <- requireParam "subject_token" form
  subjectTokenType <- requireParam "subject_token_type" form
  let req =
        TokenExchange.ExchangeRequest
          { subjectToken,
            subjectTokenType,
            actorToken = OAuth.lookupParam "actor_token" form,
            actorTokenType = OAuth.lookupParam "actor_token_type" form,
            requestedScopes = OAuth.parseScopeParam form,
            requestedTokenType = OAuth.lookupParam "requested_token_type" form,
            reason = OAuth.lookupParam "reason" form,
            ticketId = OAuth.lookupParam "ticket_id" form,
            clientIp = Just (clientIpText peer),
            authenticatedService = mSvc
          }
  outcome <- runPort env (TokenExchange.exchangeToken env.config req)
  exchanged <- either (throwError . exchangeErrorFor) pure outcome
  let AccessToken access = exchanged ^. #accessToken
      body =
        OAuth.TokenResponse
          { accessToken = access,
            tokenType = "Bearer",
            expiresIn = round (exchanged ^. #expiresIn :: NominalDiffTime),
            scope = Text.unwords [s | Scope s <- Set.toList (exchanged ^. #grantedScopes)],
            -- Refresh-less by design: a delegated token cannot be silently renewed (both modes).
            refreshToken = Nothing,
            idToken = Nothing,
            -- RFC 8693 §2.2.1 requires this member; Shōmei's exchange only ever issues access tokens.
            issuedTokenType = Just TokenExchange.accessTokenType
          }
  pure (addHeader "no-store" (addHeader "no-cache" body))

-- | Resolve the /optional/ client authentication of a token-exchange request. Absent credentials →
-- 'Nothing' (impersonation mode). Present credentials must resolve to an active service account and
-- match its secret, else @401 invalid_client@ — a bad or unknown credential must never be mistaken
-- for "no credential" and silently downgraded to impersonation mode.
resolveExchangeClient :: Env -> Maybe Text -> Form -> Handler (Maybe ServiceAccount.ServiceAccount)
resolveExchangeClient env mAuthHeader form =
  case OAuth.extractClientAuth mAuthHeader form of
    Right auth -> do
      mAccount <- runPort env (findServiceAccountByClientId (auth ^. #clientId))
      case mAccount of
        Just acc | serviceAccountAuthenticates (auth ^. #clientSecret) acc -> pure (Just acc)
        _ -> throwError OAuth.invalidClient
    -- 'extractClientAuth' fails both when credentials are absent and when they are malformed. Only a
    -- fully absent credential (no Authorization header, no client_id/client_secret) is impersonation
    -- mode; anything partial is a malformed client attempt.
    Left _
      | isJust mAuthHeader
          || isJust (OAuth.lookupParam "client_id" form)
          || isJust (OAuth.lookupParam "client_secret" form) ->
          throwError OAuth.invalidClient
      | otherwise -> pure Nothing

-- | Render a token-exchange failure as its RFC 6749 §5.2 object. The impersonation guards
-- ('ImpersonationForbidden'\/'ImpersonationTargetInvalid') collapse to a generic @invalid_grant@ so
-- a stock caller learns nothing of Shōmei's impersonation policy internals.
exchangeErrorFor :: AuthError -> ServerError
exchangeErrorFor = \case
  OAuthClientInvalid -> OAuth.invalidClient
  OAuthScopeInvalid -> OAuth.oauthError status400 "invalid_scope" "the requested scope is empty, or exceeds what the account or subject may grant"
  OAuthRequestMalformed -> OAuth.oauthError status400 "invalid_request" "the token-exchange request is malformed"
  OAuthGrantInvalid -> OAuth.oauthError status400 "invalid_grant" "the subject or actor token is invalid"
  ImpersonationForbidden -> OAuth.oauthError status400 "invalid_grant" "the subject or actor token is invalid"
  ImpersonationTargetInvalid -> OAuth.oauthError status400 "invalid_grant" "the subject or actor token is invalid"
  -- Any other AuthError is an infrastructure failure (e.g. InternalAuthError): a 500 in the OAuth
  -- shape so the caller's error parser does not itself fail while handling the failure.
  _ -> OAuth.oauthError status500 "server_error" "the authorization server encountered an unexpected condition"

-- | Client credentials for the EP-5 grants, which admit __public__ clients (no secret at all)
-- alongside the @client_secret_basic@\/@client_secret_post@ methods 'OAuth.extractClientAuth'
-- covers.
--
-- A public client identifies itself with a bare @client_id@ body parameter. That is not
-- authentication and is not treated as such: what actually binds its authorize request to this
-- exchange is PKCE, which the workflow requires of it.
oauthClientCredentials :: Maybe Text -> Form -> Handler (Text, Maybe Text)
oauthClientCredentials mAuthHeader form =
  case OAuth.extractClientAuth mAuthHeader form of
    Right auth -> pure (auth ^. #clientId, Just (auth ^. #clientSecret))
    Left _ -> case (mAuthHeader, OAuth.lookupParam "client_id" form) of
      -- No Authorization header and a bare client_id: a public client.
      (Nothing, Just clientId) -> pure (clientId, Nothing)
      _ -> throwError OAuth.invalidClient

requireParam :: Text -> Form -> Handler Text
requireParam k form =
  maybe (throwError (OAuth.invalidRequest (k <> " is required"))) pure (OAuth.lookupParam k form)

-- | Render an EP-5 grant failure as its RFC 6749 §5.2 object.
grantError :: OAuthTokenGrant.TokenGrantError -> ServerError
grantError e = case OAuthTokenGrant.grantErrorCode e of
  "invalid_client" -> OAuth.invalidClient
  code -> OAuth.oauthError status400 code (OAuthTokenGrant.grantErrorDescription e)

-- | @GET \/oauth\/userinfo@ (OIDC Core §5.3). Bearer-protected by the ordinary 'Authenticated'
-- combinator, so its @401@s are the ordinary problem documents.
--
-- Returns @sub@ (always), @roles@ and @scopes@ (from the presented token's claims, possibly empty
-- before EP-1's enrichment lands), and @email@\/@email_verified@ when the user row has them. The
-- roles\/scopes come from the verified claims, not a fresh store read: userinfo reports what /this
-- token/ carries, which is what a relying party correlating it with the ID token expects.
oauthUserinfoH :: Env -> AuthUser -> Handler Value
oauthUserinfoH env user = do
  mUser <- runPort env (findUserById user.authUserId)
  let base =
        [ "sub" Aeson..= idText user.authUserId,
          "roles" Aeson..= [r | Role r <- Set.toList user.authRoles],
          "scopes" Aeson..= [s | Scope s <- Set.toList user.authScopes]
        ]
      emailFields u =
        foldMap (\e -> ["email" Aeson..= emailText e, "email_verified" Aeson..= isJust u.emailVerifiedAt]) u.email
  pure (Aeson.object (base <> maybe [] emailFields mUser))

-- | @POST \/oauth\/introspect@ (RFC 7662): session-aware token status for resource servers.
--
-- Client-authenticated (an OAuth client or an EP-4 service account). The response is @200@ in
-- every case: @{"active": false}@ for anything invalid, expired, or revoked — never an error,
-- because an introspection endpoint that distinguished failures would let a caller probe for valid
-- tokens. On success the fields the RFC defines are filled from the claims.
--
-- __It always consults the session store__, regardless of @sessionCheckMode@ (Decision Log): a
-- token is @active@ only if it verifies /and/ its @sid@ resolves to a live session. That is the
-- whole point of RFC 7662 — a resource server can see a revocation that stateless JWT verification
-- cannot — and it is what makes the revoke→introspect flip observable.
oauthIntrospectH :: Env -> Maybe Text -> Form -> Handler Value
oauthIntrospectH env mAuthHeader form = do
  authenticateOAuthCaller env mAuthHeader form
  case OAuth.lookupParam "token" form of
    Nothing -> pure inactive
    Just presented -> case OAuth.lookupParam "token_type_hint" form of
      -- The hint is advisory; we honor `refresh_token` because a refresh token is opaque and
      -- would never verify as a JWT, so without the hint it would always look inactive.
      Just "refresh_token" -> introspectRefresh env presented
      _ -> do
        verified <- runPort env (verifyAccessToken (AccessToken presented))
        case verified of
          Left _ -> pure inactive
          Right claims -> do
            mSession <- runPort env (findSessionById claims.sessionId)
            now' <- runPort env now
            case mSession of
              Just s | sessionIsLive now' s -> pure (activeAccess claims s)
              -- The signature is fine but the session is gone or dead: to a resource server the
              -- token is not active, which is exactly what revocation must make observable.
              _ -> pure inactive

-- | Introspect a presented refresh token: hash it, look it up, and report from its status and its
-- session's liveness.
introspectRefresh :: Env -> Text -> Handler Value
introspectRefresh env presented = do
  tokHash <- runPort env (hashRefreshToken (RefreshToken presented))
  mTok <- runPort env (findRefreshTokenByHash tokHash)
  case mTok of
    Nothing -> pure inactive
    Just tok
      | (tok ^. #status) /= RefreshTokenActive -> pure inactive
      | otherwise -> do
          mSession <- runPort env (findSessionById (tok ^. #sessionId))
          now' <- runPort env now
          case mSession of
            Just s | sessionIsLive now' s -> pure (Aeson.object ["active" Aeson..= True, "token_type" Aeson..= ("refresh_token" :: Text)])
            _ -> pure inactive

-- | @POST \/oauth\/revoke@ (RFC 7009): revoke what we recognize, and always answer @200@.
--
-- A refresh token revokes its whole family and its session; an access token revokes its session
-- and that session's refresh tokens (documented caveat: a stateless verifier keeps accepting the
-- JWT until @exp@). An unknown token is not an error — RFC 7009 §2.2 forbids that, to stop probing
-- — so this only ever raises on a failed client authentication.
oauthRevokeH :: Env -> Maybe Text -> Form -> Handler NoContent
oauthRevokeH env mAuthHeader form = do
  authenticateOAuthCaller env mAuthHeader form
  case OAuth.lookupParam "token" form of
    Nothing -> pure NoContent
    Just presented -> do
      now' <- runPort env now
      tokHash <- runPort env (hashRefreshToken (RefreshToken presented))
      mTok <- runPort env (findRefreshTokenByHash tokHash)
      case mTok of
        -- A refresh token: revoke the family and the session it belongs to.
        Just tok -> do
          runPort env do
            revokeRefreshTokenFamily (tok ^. #refreshTokenId) now'
            revokeSession (tok ^. #sessionId) now'
          pure NoContent
        -- Otherwise try to read it as an access JWT and revoke its session.
        Nothing -> do
          verified <- runPort env (verifyAccessToken (AccessToken presented))
          case verified of
            Right claims -> do
              runPort env do
                revokeSession claims.sessionId now'
                revokeSessionRefreshTokens claims.sessionId now'
              pure NoContent
            -- Neither a known refresh token nor a valid access token: nothing to do, still 200.
            Left _ -> pure NoContent

-- | Client-authenticate a caller of @\/oauth\/introspect@ or @\/oauth\/revoke@ against __either__ a
-- confidential OAuth client or an EP-4 service account, both of which legitimately introspect.
--
-- A failure is @401 invalid_client@, the same shape the token endpoint uses. Public OAuth clients
-- cannot introspect: they hold no secret, and an unauthenticated introspection endpoint is a
-- probing oracle.
authenticateOAuthCaller :: Env -> Maybe Text -> Form -> Handler ()
authenticateOAuthCaller env mAuthHeader form = do
  auth <- either throwError pure (OAuth.extractClientAuth mAuthHeader form)
  let clientId = auth ^. #clientId
      secret = auth ^. #clientSecret
  ok <-
    runPort env do
      mClient <- findOAuthClientByClientId clientId
      case mClient of
        Just client
          | Just h <- oauthClientSecretHash client,
            client ^. #status == OAuthClientActive ->
              pure (ServiceToken.verifyServiceSecret h secret)
        _ -> do
          mAccount <- findServiceAccountByClientId clientId
          pure (maybe False (serviceAccountAuthenticates secret) mAccount)
  unless ok (throwError OAuth.invalidClient)

-- | A service account authenticates iff it is active and its secret matches. Read through record
-- patterns because 'ServiceAccount' shares field names with 'User'.
serviceAccountAuthenticates :: Text -> ServiceAccount.ServiceAccount -> Bool
serviceAccountAuthenticates secret account =
  ServiceToken.verifyServiceSecret (saSecretHash account) secret
    && saStatus account == ServiceAccount.ServiceAccountActive
  where
    saSecretHash ServiceAccount.ServiceAccount {secretHash} = secretHash
    saStatus ServiceAccount.ServiceAccount {status} = status

-- | An OAuth client's secret hash, read through a record pattern.
oauthClientSecretHash :: OAuthClient.OAuthClient -> Maybe Text
oauthClientSecretHash OAuthClient.OAuthClient {secretHash} = secretHash

-- | @{"active": false}@, the one answer to every introspection failure.
inactive :: Value
inactive = Aeson.object ["active" Aeson..= False]

-- | Is this session usable right now — active and unexpired?
sessionIsLive :: UTCTime -> Session.Session -> Bool
sessionIsLive now' s = s.status == Session.SessionActive && s.expiresAt > now'

-- | The RFC 7662 active-response object for a verified access token whose session is live.
activeAccess :: AuthClaims -> Session.Session -> Value
activeAccess claims _s =
  Aeson.object
    ( [ "active" Aeson..= True,
        "token_type" Aeson..= ("Bearer" :: Text),
        "scope" Aeson..= Text.unwords [s | Scope s <- Set.toList claims.scopes],
        "sub" Aeson..= idText claims.subject,
        "sid" Aeson..= idText claims.sessionId,
        "iss" Aeson..= issuerClaimText claims.issuer,
        "aud" Aeson..= audienceClaimText claims.audience,
        "exp" Aeson..= (floor (utcTimeToPOSIXSeconds claims.expiresAt) :: Integer),
        "iat" Aeson..= (floor (utcTimeToPOSIXSeconds claims.issuedAt) :: Integer)
      ]
        -- `act` per the RFC 8693 convention when the token was delegated (impersonation).
        <> foldMap (\a -> ["act" Aeson..= Aeson.object ["sub" Aeson..= idText a]]) claims.actor
    )
  where
    issuerClaimText (Issuer t) = t
    audienceClaimText (Audience t) = t

-- | The OAuth-local error mapping. Deliberately not 'authErrorToServerError': that renders the
-- problem-details envelope, which this endpoint must not emit.
oauthErrorFor :: AuthError -> ServerError
oauthErrorFor = \case
  OAuthClientInvalid -> OAuth.invalidClient
  -- One description for both refusals the workflow can raise: an explicitly empty `scope=`, and a
  -- scope outside the account's allow-list. Saying only "exceeds the allowed scopes" would be a
  -- lie for the empty case, which a live transcript caught.
  OAuthScopeInvalid -> OAuth.oauthError status400 "invalid_scope" "the requested scope is empty, or exceeds the client's allowed scopes"
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
  (_user, pair) <- runAuth env (Mfa.completeMfa env.config cid (mfaCompletionOf req))
  pure (applyCookies env.config (tokenCookies env.config pair) (tokenPairToResponse env.config pair))

-- | Load the full 'User' behind an authenticated caller. A valid token whose user row is gone is
-- an internal inconsistency, surfaced as @404 user_not_found@.
loadUser :: Env -> AuthUser -> Handler User
loadUser env user = do
  mUser <- runPort env (findUserById user.authUserId)
  maybe (throwError (toProblemError pcUserNotFound Nothing)) pure mUser

-- | Require that the caller's access token was issued recently — within
-- @impersonationConfig.actorFreshnessWindow@ — reusing that window rather than adding a new knob.
-- The gate for regenerating recovery codes, which prints new secrets and invalidates the old set.
requireFreshAuth :: Env -> AuthUser -> Handler ()
requireFreshAuth env user = do
  ts <- runPort env now
  let window = env.config.impersonationConfig.actorFreshnessWindow
  when (ts > addUTCTime window user.authClaims.issuedAt) $
    throwError (toProblemError pcReauthenticationRequired Nothing)

-- | @POST /v1/auth/totp/enroll@: mint a TOTP secret (shown once) for the caller. Blocked under a
-- delegated token; refused when TOTP is disabled or a confirmed credential already exists.
totpEnrollH :: Env -> AuthUser -> Handler TotpEnrollResponse
totpEnrollH env authUser = do
  denyUnderImpersonation env "totp_enroll" authUser
  user <- loadUser env authUser
  Totp.TotpEnrollment {secretBase32, otpauthUri} <- runAuth env (Totp.enrollTotp env.config user)
  pure TotpEnrollResponse {secret = secretBase32, otpauthUri = otpauthUri}

-- | @POST /v1/auth/totp/verify@: activate a pending enrollment with a first valid code.
totpVerifyH :: Env -> AuthUser -> TotpVerifyRequest -> Handler NoContent
totpVerifyH env authUser req = do
  user <- loadUser env authUser
  runAuth env (Totp.verifyTotpEnrollment env.config user req.code)
  pure NoContent

-- | @DELETE /v1/auth/totp@: remove the factor, gated on proof of possession. Blocked under a
-- delegated token.
totpDeleteH :: Env -> AuthUser -> TotpRemoveRequest -> Handler NoContent
totpDeleteH env authUser req = do
  denyUnderImpersonation env "totp_remove" authUser
  user <- loadUser env authUser
  runAuth env (Totp.removeTotp env.config user (totpRemovalProofOf req))
  pure NoContent

-- | @POST /v1/auth/recovery-codes@: generate a fresh single-use set (shown once). Blocked under a
-- delegated token and gated on a freshly issued access token.
recoveryCodesGenerateH :: Env -> AuthUser -> Handler RecoveryCodesResponse
recoveryCodesGenerateH env authUser = do
  denyUnderImpersonation env "recovery_codes_generate" authUser
  requireFreshAuth env authUser
  user <- loadUser env authUser
  codes <- runAuth env (Totp.regenerateRecoveryCodes env.config user)
  pure RecoveryCodesResponse {codes = codes}

-- | @GET /v1/auth/recovery-codes@: how many unused recovery codes remain.
recoveryCodesCountH :: Env -> AuthUser -> Handler RecoveryCodesCountResponse
recoveryCodesCountH env authUser = do
  n <- runPort env (countUnusedRecoveryCodes authUser.authUserId)
  pure RecoveryCodesCountResponse {remaining = n}

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
  -- Expiry over HTTP is EP-9's plan-39 admin-route work; this EP-2 route grants indefinitely.
  _ <- runAuth env (Roles.grantRoleTo (Just user.authUserId) Nothing target role)
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
