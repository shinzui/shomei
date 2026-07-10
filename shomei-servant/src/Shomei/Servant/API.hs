-- | The Shōmei HTTP API as a servant 'NamedRoutes' record (MasterPlan IP-6), plus
-- the embedded 'AppAPI' example proving the API and combinators compose inside a host
-- Servant application.
--
-- The served tree is 'ShomeiRoutes': every application route lives under @\/v1@, while
-- protocol and infrastructure endpoints keep unversioned root paths. 'ShomeiAPI' is the
-- application record alone, mountable anywhere a host likes.
--
-- Public routes (@signup@/@login@/@refresh@) carry no auth. Routes that need a
-- principal carry the 'Authenticated' combinator on the individual field, so only
-- those handlers receive a leading 'Shomei.Servant.Auth.AuthUser'. The @jwks@ route
-- returns an @aeson@ 'Value' (the public JWKS document, supplied at assembly time).
module Shomei.Servant.API
  ( ShomeiRoutes (..),
    shomeiRoutesAPI,
    ShomeiAPI (..),
    shomeiAPI,
    AppAPI,
    Project (..),
  )
where

import Data.Aeson (Value)
import Servant.API
import Shomei.Domain.User (User)
import Shomei.Id (PasskeyId, SessionId, UserId)
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Authz (RequireRole)
import Shomei.Servant.Cookie (WithCookies)
import Shomei.Servant.DTO
  ( AdminUserResponse,
    AdminUsersPage,
    AuditEventsPage,
    ChangePasswordRequest,
    ConfirmEmailVerificationRequest,
    ConfirmPasswordResetRequest,
    HealthResponse,
    ImpersonateRequest,
    ImpersonateResponse,
    LoginRequest,
    LoginResponse,
    MfaCompleteRequest,
    PasskeyLoginBeginResponse,
    PasskeyLoginCompleteRequest,
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
    PasswordResetRequest,
    ReadyResponse,
    RecoveryCodesCountResponse,
    RecoveryCodesResponse,
    RefreshRequest,
    ServiceTokenRequest,
    ServiceTokenResponse,
    SessionResponse,
    SignupRequest,
    SignupResponse,
    TokenPairResponse,
    TotpEnrollResponse,
    TotpRemoveRequest,
    TotpVerifyRequest,
    UserResponse,
    VerifyEmailRequest,
  )
import Shomei.Servant.OAuth (TokenResponse)
import Web.FormUrlEncoded (Form)

-- | The application API. @signup@/@login@/@refresh@/@logout@/@me@/@session@ live under
-- @\/auth@; the audit trail under @\/admin@. Every route here is versioned: 'ShomeiRoutes'
-- mounts the whole record under @\/v1@, so @signup@ answers at @\/v1\/auth\/signup@.
data ShomeiAPI mode = ShomeiAPI
  { -- | @201@: signup creates a user. No @Location@ header — the created resource is the
    --     response body (the user plus its first token pair), not a URL the caller can fetch.
    signup ::
      mode
        :- "auth"
          :> "signup"
          :> ReqBody '[JSON] SignupRequest
          :> Verb 'POST 201 '[JSON] (WithCookies SignupResponse),
    login ::
      mode
        :- "auth"
          :> "login"
          :> RemoteHost
          :> ReqBody '[JSON] LoginRequest
          :> Post '[JSON] (WithCookies LoginResponse),
    -- | The refresh token may arrive in the body or in the @shomei_refresh@ cookie. A
    --     cookie-borne token gets the same CSRF gate as any cookie-authenticated mutation, so
    --     this route reads @Origin@/@Referer@ itself — it carries no 'Authenticated' combinator
    --     to do it for them.
    refresh ::
      mode
        :- "auth"
          :> "refresh"
          :> Header "Cookie" Text
          :> Header "Origin" Text
          :> Header "Referer" Text
          :> ReqBody '[JSON] RefreshRequest
          :> Post '[JSON] (WithCookies TokenPairResponse),
    serviceToken ::
      mode
        :- "auth"
          :> "service-token"
          :> ReqBody '[JSON] ServiceTokenRequest
          :> Post '[JSON] ServiceTokenResponse,
    -- | @202@, honestly: the reply says nothing about the address, and the mail leaves the
    --     process later through the 'Shomei.Effect.Notifier.Notifier'. The unconditional
    --     response is also the anti-enumeration contract — an unknown address gets the same
    --     @202@ as a known one.
    verifyEmailRequest ::
      mode
        :- "auth"
          :> "verify-email"
          :> "request"
          :> ReqBody '[JSON] VerifyEmailRequest
          :> Verb 'POST 202 '[JSON] NoContent,
    -- | @200@: the token is consumed and the address marked verified inside this request.
    --     Nothing is pending, so @202@ would be a lie.
    verifyEmailConfirm ::
      mode
        :- "auth"
          :> "verify-email"
          :> "confirm"
          :> ReqBody '[JSON] ConfirmEmailVerificationRequest
          :> Verb 'POST 200 '[JSON] NoContent,
    -- | @202@ for the same two reasons as @verify-email\/request@.
    passwordResetRequest ::
      mode
        :- "auth"
          :> "password-reset"
          :> "request"
          :> ReqBody '[JSON] PasswordResetRequest
          :> Verb 'POST 202 '[JSON] NoContent,
    -- | @200@: the password is replaced inside this request.
    passwordResetConfirm ::
      mode
        :- "auth"
          :> "password-reset"
          :> "confirm"
          :> ReqBody '[JSON] ConfirmPasswordResetRequest
          :> Verb 'POST 200 '[JSON] NoContent,
    passwordChange ::
      mode
        :- "auth"
          :> "password"
          :> "change"
          :> Authenticated
          :> ReqBody '[JSON] ChangePasswordRequest
          :> PostNoContent,
    -- 204, but carrying Set-Cookie headers that clear the cookies, so 'PostNoContent'
    -- (which cannot carry headers) will not do.
    logout ::
      mode
        :- "auth"
          :> "logout"
          :> Authenticated
          :> Verb 'POST 204 '[JSON] (WithCookies NoContent),
    me ::
      mode
        :- "auth"
          :> Authenticated
          :> "me"
          :> Get '[JSON] UserResponse,
    session ::
      mode
        :- "auth"
          :> Authenticated
          :> "session"
          :> Get '[JSON] SessionResponse,
    passkeyRegisterBegin ::
      mode
        :- "auth"
          :> "passkeys"
          :> "register"
          :> "begin"
          :> Authenticated
          :> Post '[JSON] PasskeyRegisterBeginResponse,
    passkeyRegisterComplete ::
      mode
        :- "auth"
          :> "passkeys"
          :> "register"
          :> "complete"
          :> Authenticated
          :> ReqBody '[JSON] PasskeyRegisterCompleteRequest
          :> Post '[JSON] PasskeyResponse,
    passkeyList ::
      mode
        :- "auth"
          :> "passkeys"
          :> Authenticated
          :> Get '[JSON] [PasskeyResponse],
    passkeyDelete ::
      mode
        :- "auth"
          :> "passkeys"
          :> Authenticated
          :> Capture "passkeyId" PasskeyId
          :> Verb 'DELETE 204 '[JSON] NoContent,
    -- | Begin TOTP enrollment: mint a secret (shown once) for the authenticated caller. EP-7.
    totpEnroll ::
      mode
        :- "auth"
          :> "totp"
          :> "enroll"
          :> Authenticated
          :> Post '[JSON] TotpEnrollResponse,
    -- | Activate a pending TOTP enrollment with a first valid code.
    totpVerify ::
      mode
        :- "auth"
          :> "totp"
          :> "verify"
          :> Authenticated
          :> ReqBody '[JSON] TotpVerifyRequest
          :> Post '[JSON] NoContent,
    -- | Remove the TOTP factor, gated on proof of possession (a current code or a recovery code).
    totpDelete ::
      mode
        :- "auth"
          :> "totp"
          :> Authenticated
          :> ReqBody '[JSON] TotpRemoveRequest
          :> Verb 'DELETE 204 '[JSON] NoContent,
    -- | Generate a fresh set of single-use recovery codes (shown once), replacing any prior set.
    recoveryCodesGenerate ::
      mode
        :- "auth"
          :> "recovery-codes"
          :> Authenticated
          :> Post '[JSON] RecoveryCodesResponse,
    -- | How many unused recovery codes remain for the authenticated caller.
    recoveryCodesCount ::
      mode
        :- "auth"
          :> "recovery-codes"
          :> Authenticated
          :> Get '[JSON] RecoveryCodesCountResponse,
    -- | Finish a password-then-passkey step-up. Unauthenticated: completing the second
    --     factor is exactly how the caller obtains a session. (The challenge itself rides in the
    --     @mfa_required@ arm of @POST \/v1\/auth\/login@, so there is no @\/v1\/auth\/mfa\/begin@.)
    mfaComplete ::
      mode
        :- "auth"
          :> "mfa"
          :> "complete"
          :> ReqBody '[JSON] MfaCompleteRequest
          :> Post '[JSON] (WithCookies TokenPairResponse),
    -- | Begin a passwordless passkey login (no account named; the browser's discoverable
    --     credential picker chooses one). Unauthenticated.
    passkeyLoginBegin ::
      mode
        :- "auth"
          :> "login"
          :> "passkey"
          :> "begin"
          :> Post '[JSON] PasskeyLoginBeginResponse,
    -- | Finish a passwordless passkey login. Unauthenticated: the passkey IS the strong
    --     factor, so this returns a token pair directly (never an MFA challenge).
    passkeyLoginComplete ::
      mode
        :- "auth"
          :> "login"
          :> "passkey"
          :> "complete"
          :> ReqBody '[JSON] PasskeyLoginCompleteRequest
          :> Post '[JSON] (WithCookies TokenPairResponse),
    -- | @POST /v1/auth/impersonate@: exchange the caller's token for a short-lived delegated
    --     token acting on behalf of a target user. Authenticated; 'RemoteHost' supplies the
    --     client IP for the audit record.
    impersonate ::
      mode
        :- "auth"
          :> "impersonate"
          :> Authenticated
          :> RemoteHost
          :> ReqBody '[JSON] ImpersonateRequest
          :> Post '[JSON] ImpersonateResponse,
    -- | @DELETE /v1/auth/impersonate@: stop impersonating by revoking the delegated session
    --     named by the presented token. Authenticated.
    stopImpersonate ::
      mode
        :- "auth"
          :> "impersonate"
          :> Authenticated
          :> DeleteNoContent,
    -- | @GET /v1/admin/audit/events@ (EP-7): an admin-gated, filtered, keyset-paginated page
    --     of the audit trail. Repeated @?type=@ collects into a list; @?before=@ takes an
    --     opaque cursor from a previous page's @nextCursor@.
    --
    --     'Shomei.Servant.Authz.RequireRole' both authenticates the caller and demands the
    --     @admin@ role, so the handler carries no guard of its own — the type is the
    --     enforcement. Grant the role with @shomei-admin roles grant --user … --role admin@.
    auditEvents ::
      mode
        :- "admin"
          :> "audit"
          :> "events"
          :> RequireRole "admin"
          :> QueryParam "user" Text
          :> QueryParam "session" Text
          :> QueryParams "type" Text
          :> QueryParam "since" Text
          :> QueryParam "until" Text
          :> QueryParam "limit" Int
          :> QueryParam "before" Text
          :> Get '[JSON] AuditEventsPage,
    -- | The administrative surface (EP-2). Every route below carries plain 'Authenticated' and
    --     calls @Shomei.Servant.Authz.requireAdmin@ in its handler, rather than the
    --     'RequireRole' combinator the audit route uses: the gate is a /disjunction/ — the
    --     @admin@ role __or__ the @shomei:admin@ scope — and one type-level symbol cannot say
    --     that. A human administrator carries the role; a database-less service (a support
    --     console, a back-office job) carries the scope on a service token.
    --
    --     Every mutation additionally refuses a delegated (impersonation) token, and audits the
    --     refusal.
    adminListUsers ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> QueryParam "status" Text
          :> QueryParam "limit" Int
          :> QueryParam "before" Text
          :> Get '[JSON] AdminUsersPage,
    adminGetUser ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> Get '[JSON] AdminUserResponse,
    -- | Suspend an active user and revoke their sessions. @409@ if they are not active.
    adminSuspendUser ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "suspend"
          :> PostNoContent,
    -- | Return a suspended user to service. @409@ if they are not suspended.
    adminReinstateUser ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "reinstate"
          :> PostNoContent,
    -- | Soft-delete: the user's status becomes @deleted@ and their sessions are revoked. The row
    --     survives, because sessions, role grants and audit events reference it.
    adminDeleteUser ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> Verb 'DELETE 204 '[JSON] NoContent,
    adminListSessions ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "sessions"
          :> Get '[JSON] [SessionResponse],
    adminRevokeSessions ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "sessions"
          :> Verb 'DELETE 204 '[JSON] NoContent,
    adminRevokeSession ::
      mode
        :- "admin"
          :> "sessions"
          :> Authenticated
          :> Capture "sessionId" SessionId
          :> Verb 'DELETE 204 '[JSON] NoContent,
    -- | Trigger the ordinary password-reset flow for a user, by id. @409@ if they have no email.
    --     Unlike the public endpoint this may answer honestly: the caller is an authorized admin
    --     naming a user id, not a stranger probing an address.
    adminPasswordReset ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "password-reset"
          :> Verb 'POST 202 '[JSON] NoContent,
    -- | Grant a role. Idempotent: re-granting an existing role is still @204@.
    adminGrantRole ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "roles"
          :> Capture "role" Text
          :> Verb 'PUT 204 '[JSON] NoContent,
    -- | Revoke a role. @404@ if the user did not hold it.
    adminRevokeRole ::
      mode
        :- "admin"
          :> "users"
          :> Authenticated
          :> Capture "userId" UserId
          :> "roles"
          :> Capture "role" Text
          :> Verb 'DELETE 204 '[JSON] NoContent
  }
  deriving stock (Generic)

-- | A 'Proxy' carrying the /application/ API type, for a host that mounts 'ShomeiAPI' at a
-- prefix of its own choosing. The standalone server serves 'shomeiRoutesAPI' instead.
shomeiAPI :: Proxy (NamedRoutes ShomeiAPI)
shomeiAPI = Proxy

-- | The served route tree (EP-3): application routes under @\/v1@; protocol and
-- infrastructure endpoints at unversioned root paths.
--
-- The split is deliberate and permanent. @\/.well-known\/*@ is where OAuth2\/OIDC tooling
-- looks by convention — versioning it would break the auto-configuration that makes Shōmei
-- consumable by stock middleware — and @\/health@\/@\/ready@ are deployment contracts a load
-- balancer is configured against, not API surface that evolves with the application. The
-- future @\/oauth\/*@ endpoints join them at the root for the same reason. @\/metrics@ is a
-- WAI middleware and never reaches Servant at all.
--
-- Everything else is versioned so the next breaking change has somewhere to go.
data ShomeiRoutes mode = ShomeiRoutes
  { v1 :: mode :- "v1" :> NamedRoutes ShomeiAPI,
    -- | The public JWKS document. 'Cache-Control' bounds how long a verifier may keep a
    --     revoked key's public half: key rotation is staged (@pending → active → retired →
    --     revoked@), so a retiring key stays /trusted/ for verification far longer than five
    --     minutes and a stale copy of this document can never reject a valid token.
    jwks ::
      mode
        :- ".well-known"
          :> "jwks.json"
          :> Get '[JSON] (Headers '[Header "Cache-Control" Text] Value),
    -- | The OpenAPI 3.1 document for whatever binary is answering, so a client generates
    --     against the deployment rather than against a spec file someone remembered to commit.
    --     Unversioned, like the rest of this record: it describes the @\/v1@ surface and the
    --     root endpoints alike, including itself.
    openapi :: mode :- "openapi.json" :> Get '[JSON] Value,
    -- | @GET \/.well-known\/openid-configuration@ (EP-5): the OIDC discovery document, from
    --     which stock relying-party middleware auto-configures itself. Unversioned because OIDC
    --     Core /defines/ this path relative to the issuer.
    --
    --     Answers @404@ with an RFC 6749-shaped body when @oauthConfig.oidcEnabled@ is off: a
    --     disabled provider must not advertise endpoints it will refuse to serve.
    oidcDiscovery ::
      mode
        :- ".well-known"
          :> "openid-configuration"
          :> Get '[JSON] Value,
    -- | @POST \/oauth\/token@ (EP-4): the standard OAuth2 token endpoint, RFC 6749. Unversioned
    --     and form-encoded, because that is where and how every stock OAuth2 client looks for it.
    --
    --     The @Authorization@ header is a plain optional header, deliberately __not__ the
    --     'Authenticated' combinator: the caller is not a bearer of a Shōmei token, it is an OAuth
    --     client authenticating with its own credentials (@client_secret_basic@). The body may
    --     instead carry @client_id@\/@client_secret@ (@client_secret_post@).
    --
    --     The request body is a raw 'Form' rather than a typed record because this endpoint is a
    --     /dispatcher/: each @grant_type@ reads its own parameters, and later grants
    --     (@authorization_code@ with its @code_verifier@, token exchange with its
    --     @subject_token@) would otherwise force a parameter union that changes shape every time
    --     a grant is added.
    --
    --     RFC 6749 §5.1 requires @Cache-Control: no-store@ on a successful token response; the
    --     'Headers' wrapper carries it and the conventional @Pragma: no-cache@.
    --
    --     __Errors here are RFC 6749 §5.2 objects, not problem documents__ — see
    --     "Shomei.Servant.OAuth". This is the one endpoint exempt from the application envelope.
    -- | @GET \/oauth\/authorize@ (EP-5): the authorization-code flow's browser leg, RFC 6749 §4.1.
    --
    --     The @Authorization@ and @Cookie@ headers are plain optional headers, deliberately
    --     __not__ the 'Authenticated' combinator: an unauthenticated request here must be
    --     /redirected/ to the host's login page, not answered with @401@. The handler runs the
    --     same verification core through 'Shomei.Servant.Auth.resolveAuthUser', so every credential
    --     transport reaches this route exactly as it reaches an 'Authenticated' one.
    --
    --     __Two validation regimes.__ An unknown or revoked @client_id@, or a @redirect_uri@ that
    --     is not registered, answers @400@ and __never redirects__ — redirecting an unvalidated
    --     URI would make this an open redirector, which is how authorization codes get harvested.
    --     Every other violation redirects to the (now validated) @redirect_uri@ with @error@,
    --     @error_description@, and the echoed @state@.
    oauthAuthorize ::
      mode
        :- "oauth"
          :> "authorize"
          :> Header "Authorization" Text
          :> Header "Cookie" Text
          :> QueryParam "response_type" Text
          :> QueryParam "client_id" Text
          :> QueryParam "redirect_uri" Text
          :> QueryParam "scope" Text
          :> QueryParam "state" Text
          :> QueryParam "nonce" Text
          :> QueryParam "code_challenge" Text
          :> QueryParam "code_challenge_method" Text
          :> Verb 'GET 302 '[JSON] (Headers '[Header "Location" Text, Header "Cache-Control" Text] NoContent),
    oauthToken ::
      mode
        :- "oauth"
          :> "token"
          :> Header "Authorization" Text
          -- 'RemoteHost' supplies the connection peer, which the RFC 8693 token-exchange grant
          -- (EP-6) records as the impersonation client IP; the other grants ignore it.
          :> RemoteHost
          :> ReqBody '[FormUrlEncoded] Form
          :> Post '[JSON] (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] TokenResponse),
    -- | @GET \/oauth\/userinfo@ (EP-5, OIDC Core §5.3): the bearer-protected claims endpoint.
    --     Uses the ordinary 'Authenticated' combinator, so its @401@s are the ordinary problem
    --     documents and both the bearer and (later) cookie transports work.
    oauthUserinfo ::
      mode
        :- "oauth"
          :> "userinfo"
          :> Authenticated
          :> Get '[JSON] Value,
    -- | @POST \/oauth\/introspect@ (EP-5, RFC 7662): a resource server asks whether a token is
    --     live. Client-authenticated (an OAuth client or an EP-4 service account). The answer is
    --     always @200@ — @{"active": false}@ for anything invalid, never an error, to stop probing
    --     — so its error shape is RFC 6749's, not the application envelope.
    oauthIntrospect ::
      mode
        :- "oauth"
          :> "introspect"
          :> Header "Authorization" Text
          :> ReqBody '[FormUrlEncoded] Form
          :> Post '[JSON] Value,
    -- | @POST \/oauth\/revoke@ (EP-5, RFC 7009): revoke a refresh or access token. Always @200@
    --     with an empty body, even for an unknown token; only a failed client authentication is an
    --     error (@401 invalid_client@).
    oauthRevoke ::
      mode
        :- "oauth"
          :> "revoke"
          :> Header "Authorization" Text
          :> ReqBody '[FormUrlEncoded] Form
          :> Post '[JSON] NoContent,
    health :: mode :- "health" :> Get '[JSON] HealthResponse,
    ready :: mode :- "ready" :> Get '[JSON] ReadyResponse
  }
  deriving stock (Generic)

-- | A 'Proxy' carrying the served route tree for 'Servant.serveWithContext'.
shomeiRoutesAPI :: Proxy (NamedRoutes ShomeiRoutes)
shomeiRoutesAPI = Proxy

-- | A stand-in host resource for the embeddability example.
newtype Project = Project {projectId :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Embeddability proof: mount the whole served Shōmei tree alongside a host route protected
-- by 'Authenticated', plus an admin route protected by 'RequireRole'. This type-checks to show
-- the API type and the combinators compose inside a host Servant app.
--
-- Mounting 'ShomeiRoutes' (rather than 'ShomeiAPI') is what a host normally wants: it brings
-- the @\/v1@ prefix, the JWKS document, and the probes along at the paths every Shōmei client,
-- verifier, and load balancer already expects. A host that wants only the application routes,
-- at a prefix of its own, mounts @NamedRoutes ShomeiAPI@ instead — but then the @\/v1@ segment
-- and the refresh cookie's @Path@ ('Shomei.Servant.Cookie') no longer agree, so it must set
-- @cookieTransport@ off or accept that cookie-mode refresh will not work.
--
-- Note that 'RequireRole' /replaces/ 'Authenticated' rather than accompanying it: it runs the
-- same 'Shomei.Servant.Auth.authHandler' from the Servant context, then checks the role, and
-- passes the resulting 'Shomei.Servant.Auth.AuthUser' to the handler. Both combinators enforce;
-- neither is documentation.
type AppAPI =
  NamedRoutes ShomeiRoutes
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
    :<|> RequireRole "admin" :> "admin" :> "users" :> Get '[JSON] [User]
