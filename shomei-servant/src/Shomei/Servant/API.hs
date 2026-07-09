-- | The Shōmei HTTP API as a servant 'NamedRoutes' record (MasterPlan IP-6), plus
-- the embedded 'AppAPI' example proving the API and combinators compose inside a host
-- Servant application.
--
-- Public routes (@signup@/@login@/@refresh@) carry no auth. Routes that need a
-- principal carry the 'Authenticated' combinator on the individual field, so only
-- those handlers receive a leading 'Shomei.Servant.Auth.AuthUser'. The @jwks@ route
-- returns an @aeson@ 'Value' (the public JWKS document, supplied at assembly time).
module Shomei.Servant.API
  ( ShomeiAPI (..),
    shomeiAPI,
    AppAPI,
    Project (..),
  )
where

import Data.Aeson (Value)
import Servant.API
import Shomei.Domain.User (User)
import Shomei.Id (PasskeyId)
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Cookie (WithCookies)
import Shomei.Servant.Authz (RequireRole)
import Shomei.Servant.DTO
  ( AuditEventsPage,
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
    RefreshRequest,
    ServiceTokenRequest,
    ServiceTokenResponse,
    SessionResponse,
    SignupRequest,
    SignupResponse,
    TokenPairResponse,
    UserResponse,
    VerifyEmailRequest,
  )

-- | The standalone API. @signup@/@login@/@refresh@/@logout@/@me@/@session@ live
-- under @\/auth@; @jwks@ under @\/.well-known@; @health@ at @\/health@.
data ShomeiAPI mode = ShomeiAPI
  { signup ::
      mode
        :- "auth"
          :> "signup"
          :> ReqBody '[JSON] SignupRequest
          :> Post '[JSON] (WithCookies SignupResponse),
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
    verifyEmailRequest ::
      mode
        :- "auth"
          :> "verify-email"
          :> "request"
          :> ReqBody '[JSON] VerifyEmailRequest
          :> Verb 'POST 202 '[JSON] NoContent,
    verifyEmailConfirm ::
      mode
        :- "auth"
          :> "verify-email"
          :> "confirm"
          :> ReqBody '[JSON] ConfirmEmailVerificationRequest
          :> Verb 'POST 202 '[JSON] NoContent,
    passwordResetRequest ::
      mode
        :- "auth"
          :> "password-reset"
          :> "request"
          :> ReqBody '[JSON] PasswordResetRequest
          :> Verb 'POST 202 '[JSON] NoContent,
    passwordResetConfirm ::
      mode
        :- "auth"
          :> "password-reset"
          :> "confirm"
          :> ReqBody '[JSON] ConfirmPasswordResetRequest
          :> Verb 'POST 202 '[JSON] NoContent,
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
    -- | Finish a password-then-passkey step-up. Unauthenticated: completing the second
    --     factor is exactly how the caller obtains a session. (The challenge itself rides in the
    --     @mfa_required@ arm of @POST \/auth\/login@, so there is no @\/auth\/mfa\/begin@.)
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
    -- | @POST /auth/impersonate@: exchange the caller's token for a short-lived delegated
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
    -- | @DELETE /auth/impersonate@: stop impersonating by revoking the delegated session
    --     named by the presented token. Authenticated.
    stopImpersonate ::
      mode
        :- "auth"
          :> "impersonate"
          :> Authenticated
          :> DeleteNoContent,
    -- | @GET /admin/audit/events@ (EP-7): an admin-gated, filtered, keyset-paginated page
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
    jwks ::
      mode
        :- ".well-known"
          :> "jwks.json"
          :> Get '[JSON] Value,
    health ::
      mode
        :- "health"
          :> Get '[JSON] HealthResponse,
    ready ::
      mode
        :- "ready"
          :> Get '[JSON] ReadyResponse
  }
  deriving stock (Generic)

-- | A 'Proxy' carrying the API type for 'Servant.serveWithContext'.
shomeiAPI :: Proxy (NamedRoutes ShomeiAPI)
shomeiAPI = Proxy

-- | A stand-in host resource for the embeddability example.
newtype Project = Project {projectId :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Embeddability proof: mount the whole Shōmei API under @\/auth@ alongside a host route
-- protected by 'Authenticated', plus an admin route protected by 'RequireRole'. This
-- type-checks to show the API type and the combinators compose inside a host Servant app.
--
-- Note that 'RequireRole' /replaces/ 'Authenticated' rather than accompanying it: it runs the
-- same 'Shomei.Servant.Auth.authHandler' from the Servant context, then checks the role, and
-- passes the resulting 'Shomei.Servant.Auth.AuthUser' to the handler. Both combinators enforce;
-- neither is documentation.
type AppAPI =
  "auth" :> NamedRoutes ShomeiAPI
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
    :<|> RequireRole "admin" :> "admin" :> "users" :> Get '[JSON] [User]
