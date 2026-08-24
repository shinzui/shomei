-- | OAuth and OIDC protocol handlers. These endpoints deliberately retain
-- their protocol-defined error envelope instead of application Problem Details.
module Shomei.OAuth.Handler
  ( oauthServer,
    oidcDiscoveryH,
  )
where

import Control.Monad.Except (catchError)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Effectful (Eff)
import Network.HTTP.Types.Status (status400, status401, status404, status500, status503)
import Network.HTTP.Types.URI (renderSimpleQuery)
import Network.Socket (SockAddr (..))
import Servant (Handler, ServerError (..), throwError)
import Servant.Server.Generic (AsServerT)
import Shomei.Account.Email.Domain (emailText)
import Shomei.Account.User.Domain (User (..))
import Shomei.Account.User.Store (findUserById)
import Shomei.Authorization.Claims.Domain (Audience (..), AuthClaims (..), Issuer (..), Role (..), Scope (..))
import Shomei.Config (OAuthConfig (..), ShomeiConfig (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (idText)
import Shomei.OAuth.Api (OAuthApi (..))
import Shomei.OAuth.Authorize.Workflow qualified as OAuthAuthorize
import Shomei.OAuth.Client.Domain (OAuthClientStatus (..), isRegisteredRedirectUri)
import Shomei.OAuth.Client.Domain qualified as OAuthClient
import Shomei.OAuth.Client.Store (findOAuthClientByClientId)
import Shomei.OAuth.IdToken.Domain (IdToken (..))
import Shomei.OAuth.Result
import Shomei.OAuth.TokenExchange.Workflow qualified as TokenExchange
import Shomei.OAuth.TokenGrant.Workflow qualified as OAuthTokenGrant
import Shomei.Prelude
import Shomei.Servant.Auth (AuthUser (..), resolveAuthUser)
import Shomei.Servant.OAuth qualified as OAuth
import Shomei.Servant.Oidc qualified as Oidc
import Shomei.Servant.Seam (AppEffects, Env (..), runPortResult)
import Shomei.ServiceAccount.ClientCredentials.Workflow qualified as ClientCredentials
import Shomei.ServiceAccount.Domain qualified as ServiceAccount
import Shomei.ServiceAccount.Secret qualified as ServiceAccountSecret
import Shomei.ServiceAccount.Store (findServiceAccountByClientId)
import Shomei.Session.Domain qualified as Session
import Shomei.Session.RefreshToken.Domain (RefreshToken (..), RefreshTokenStatus (RefreshTokenActive))
import Shomei.Session.RefreshToken.Store (findRefreshTokenByHash, revokeRefreshTokenFamily, revokeSessionRefreshTokens)
import Shomei.Session.Store (findSessionById)
import Shomei.Session.Store qualified as SessionStore
import Shomei.Session.Token.Domain (AccessToken (..))
import Shomei.Session.Token.Generator (hashRefreshToken)
import Shomei.SigningKey.Verifier (verifyAccessToken)
import Shomei.Time.Store (now)
import Web.FormUrlEncoded (Form)

oauthServer :: Env -> OAuthApi (AsServerT Handler)
oauthServer env =
  OAuthApi
    { authorize = \a b c d e f g h i j -> typedOAuth (oauthAuthorizeH env a b c d e f g h i j),
      token = \authorization peer form -> typedOAuth (oauthTokenH env authorization peer form),
      userinfo = \user -> typedOAuth (oauthUserinfoH env user),
      introspect = \authorization form -> typedOAuth (oauthIntrospectH env authorization form),
      revoke = \authorization form -> typedOAuth (oauthRevokeH env authorization form)
    }

typedOAuth :: Handler a -> Handler (OAuthResult a)
typedOAuth action = (OAuthSuccess <$> action) `catchError` (pure . oauthServerErrorResult)

runOAuthPort :: Env -> Eff AppEffects a -> Handler a
runOAuthPort env action = runPortResult env action >>= either (throwError . oauthInfrastructureError) pure

oauthInfrastructureError :: AuthError -> ServerError
oauthInfrastructureError = \case
  DependencyUnavailable _ -> OAuth.oauthError status503 "temporarily_unavailable" "a required dependency is unavailable"
  _ -> OAuth.oauthError status500 "server_error" "the authorization server encountered an unexpected condition"

clientIpText :: SockAddr -> Text
clientIpText = \case
  SockAddrInet _ host -> Text.pack (show host)
  SockAddrInet6 _ _ host _ -> Text.pack (show host)
  other -> Text.pack (show other)

-- | @GET \/.well-known\/openid-configuration@ (EP-5).
--
-- With the provider disabled the answer is @404@ carrying an RFC 6749-shaped body, not a problem
-- document: a client that reaches this URL is OIDC tooling, and it must fail on a shape it can
-- parse. This is the same envelope boundary the @\/oauth\/*@ endpoints observe.
oidcDiscoveryH :: Env -> Handler OidcDiscoveryResult
oidcDiscoveryH env = typedOAuth (oidcDiscoveryValueH env)

oidcDiscoveryValueH :: Env -> Handler Value
oidcDiscoveryValueH env
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
  Handler AuthorizeRedirect
oauthAuthorizeH env mAuthHeader mCookie mResponseType mClientId mRedirectUri mScope mState mNonce mChallenge mChallengeMethod = do
  unless env.config.oauthConfig.oidcEnabled (throwError providerDisabled)

  -- (1) The no-redirect regime.
  clientId <- maybe (throwError (oauthBadRequest "client_id is required")) pure mClientId
  redirectUri <- maybe (throwError (oauthBadRequest "redirect_uri is required")) pure mRedirectUri
  client <-
    runOAuthPort env (findOAuthClientByClientId clientId)
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
  mUser <- liftIO (resolveAuthUser env mAuthHeader mCookie)
  case mUser of
    Nothing -> case env.config.oauthConfig.loginUrl of
      Just loginUrl -> redirectTo (loginUrl `withQuery` [("return_to", TE.encodeUtf8 (reconstructedAuthorizeUrl params clientId))])
      Nothing -> throwError (OAuth.oauthError status401 "login_required" "no authenticated user and no login URL is configured")
    Just user -> do
      outcome <- runOAuthPort env (OAuthAuthorize.authorize env.config client user.authClaims params)
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
    redirectTo loc = pure (AuthorizeRedirect loc "no-store")

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
  Handler TokenSuccess
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
  Handler TokenSuccess
clientCredentialsGrant env mAuthHeader form = do
  auth <- either throwError pure (OAuth.extractClientAuth mAuthHeader form)
  let grant =
        ClientCredentials.ClientCredentialsGrant
          { clientId = auth ^. #clientId,
            clientSecret = auth ^. #clientSecret,
            requestedScopes = OAuth.parseScopeParam form
          }
  outcome <- runOAuthPort env (ClientCredentials.grantClientCredentials env.config grant)
  granted <- either (throwError . oauthErrorFor) pure outcome
  -- Read through lens labels: 'GrantedToken' shares @accessToken@/@expiresIn@/@sessionId@ with
  -- Several grant result records share @accessToken@, so select the field through its label.
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
  pure (TokenSuccess body "no-store" "no-cache")

-- | RFC 6749 §4.1.3 with PKCE (RFC 7636). Redeem the code, mint access + refresh + (for @openid@)
-- an ID token.
authorizationCodeGrant ::
  Env ->
  Maybe Text ->
  Form ->
  Handler TokenSuccess
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
  outcome <- runOAuthPort env (OAuthTokenGrant.exchangeAuthorizationCode env.config grant)
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
  pure (TokenSuccess body "no-store" "no-cache")

-- | RFC 6749 §6, bound to the client that minted the session. Rotation and reuse detection are the
-- existing workflow's; this arm adds only the client check.
refreshTokenGrant ::
  Env ->
  Maybe Text ->
  Form ->
  Handler TokenSuccess
refreshTokenGrant env mAuthHeader form = do
  (clientId, mSecret) <- oauthClientCredentials mAuthHeader form
  presented <- requireParam "refresh_token" form
  let grant =
        OAuthTokenGrant.RefreshViaOAuth
          { clientId,
            clientSecret = mSecret,
            refreshToken = RefreshToken presented
          }
  outcome <- runOAuthPort env (OAuthTokenGrant.refreshViaOAuth env.config grant)
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
  pure (TokenSuccess body "no-store" "no-cache")

-- | RFC 8693 token exchange (EP-6): the third grant on @POST \/oauth\/token@. Two modes selected by
-- the parameters (see "Shomei.OAuth.TokenExchange.Workflow"):
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
  Handler TokenSuccess
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
  outcome <- runOAuthPort env (TokenExchange.exchangeToken env.config req)
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
  pure (TokenSuccess body "no-store" "no-cache")

-- | Resolve the /optional/ client authentication of a token-exchange request. Absent credentials →
-- 'Nothing' (impersonation mode). Present credentials must resolve to an active service account and
-- match its secret, else @401 invalid_client@ — a bad or unknown credential must never be mistaken
-- for "no credential" and silently downgraded to impersonation mode.
resolveExchangeClient :: Env -> Maybe Text -> Form -> Handler (Maybe ServiceAccount.ServiceAccount)
resolveExchangeClient env mAuthHeader form =
  case OAuth.extractClientAuth mAuthHeader form of
    Right auth -> do
      mAccount <- runOAuthPort env (findServiceAccountByClientId (auth ^. #clientId))
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

-- | @GET \/oauth\/userinfo@ (OIDC Core §5.3). The protocol-specific authentication combinator
-- turns a missing or invalid credential into OAuth @invalid_token@ rather than crossing into the
-- application Problem Details envelope.
--
-- Returns @sub@ (always), @roles@ and @scopes@ (from the presented token's claims, possibly empty
-- before EP-1's enrichment lands), and @email@\/@email_verified@ when the user row has them. The
-- roles\/scopes come from the verified claims, not a fresh store read: userinfo reports what /this
-- token/ carries, which is what a relying party correlating it with the ID token expects.
oauthUserinfoH :: Env -> AuthUser -> Handler Value
oauthUserinfoH env user = do
  mUser <- runOAuthPort env (findUserById user.authUserId)
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
        verified <- runOAuthPort env (verifyAccessToken (AccessToken presented))
        case verified of
          Left _ -> pure inactive
          Right claims -> do
            mSession <- runOAuthPort env (findSessionById claims.sessionId)
            now' <- runOAuthPort env now
            case mSession of
              Just s | sessionIsLive now' s -> pure (activeAccess claims s)
              -- The signature is fine but the session is gone or dead: to a resource server the
              -- token is not active, which is exactly what revocation must make observable.
              _ -> pure inactive

-- | Introspect a presented refresh token: hash it, look it up, and report from its status and its
-- session's liveness.
introspectRefresh :: Env -> Text -> Handler Value
introspectRefresh env presented = do
  tokHash <- runOAuthPort env (hashRefreshToken (RefreshToken presented))
  mTok <- runOAuthPort env (findRefreshTokenByHash tokHash)
  case mTok of
    Nothing -> pure inactive
    Just tok
      | (tok ^. #status) /= RefreshTokenActive -> pure inactive
      | otherwise -> do
          mSession <- runOAuthPort env (findSessionById (tok ^. #sessionId))
          now' <- runOAuthPort env now
          case mSession of
            Just s | sessionIsLive now' s -> pure (Aeson.object ["active" Aeson..= True, "token_type" Aeson..= ("refresh_token" :: Text)])
            _ -> pure inactive

-- | @POST \/oauth\/revoke@ (RFC 7009): revoke what we recognize, and always answer @200@.
--
-- A refresh token revokes its whole family and its session; an access token revokes its session
-- and that session's refresh tokens. Under the default @VerifyTokenOnly@ the stateless auth path
-- keeps accepting that JWT until @exp@; under @VerifyTokenAndSession@ its next use is refused with
-- @401 session_revoked@. An unknown token is not an error — RFC 7009 §2.2 forbids that, to stop
-- probing — so this only ever raises on a failed client authentication.
oauthRevokeH :: Env -> Maybe Text -> Form -> Handler ()
oauthRevokeH env mAuthHeader form = do
  authenticateOAuthCaller env mAuthHeader form
  case OAuth.lookupParam "token" form of
    Nothing -> pure ()
    Just presented -> do
      now' <- runOAuthPort env now
      tokHash <- runOAuthPort env (hashRefreshToken (RefreshToken presented))
      mTok <- runOAuthPort env (findRefreshTokenByHash tokHash)
      case mTok of
        -- A refresh token: revoke the family and the session it belongs to.
        Just tok -> do
          runOAuthPort env do
            revokeRefreshTokenFamily (tok ^. #refreshTokenId) now'
            SessionStore.revokeSession (tok ^. #sessionId) now'
          pure ()
        -- Otherwise try to read it as an access JWT and revoke its session.
        Nothing -> do
          verified <- runOAuthPort env (verifyAccessToken (AccessToken presented))
          case verified of
            Right claims -> do
              runOAuthPort env do
                SessionStore.revokeSession claims.sessionId now'
                revokeSessionRefreshTokens claims.sessionId now'
              pure ()
            -- Neither a known refresh token nor a valid access token: nothing to do, still 200.
            Left _ -> pure ()

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
    runOAuthPort env do
      mClient <- findOAuthClientByClientId clientId
      case mClient of
        Just client
          | Just h <- oauthClientSecretHash client,
            client ^. #status == OAuthClientActive ->
              pure (ServiceAccountSecret.verifyServiceSecret h secret)
        _ -> do
          mAccount <- findServiceAccountByClientId clientId
          pure (maybe False (serviceAccountAuthenticates secret) mAccount)
  unless ok (throwError OAuth.invalidClient)

-- | A service account authenticates iff it is active and its secret matches. Read through record
-- patterns because 'ServiceAccount' shares field names with 'User'.
serviceAccountAuthenticates :: Text -> ServiceAccount.ServiceAccount -> Bool
serviceAccountAuthenticates secret account =
  ServiceAccountSecret.verifyServiceSecret (saSecretHash account) secret
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
