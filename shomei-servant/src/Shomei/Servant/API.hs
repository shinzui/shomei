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
    SessionResponse,
    ServiceTokenRequest,
    ServiceTokenResponse,
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
          :> Post '[JSON] SignupResponse,
    login ::
      mode
        :- "auth"
          :> "login"
          :> RemoteHost
          :> ReqBody '[JSON] LoginRequest
          :> Post '[JSON] LoginResponse,
    refresh ::
      mode
        :- "auth"
          :> "refresh"
          :> ReqBody '[JSON] RefreshRequest
          :> Post '[JSON] TokenPairResponse,
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
    logout ::
      mode
        :- "auth"
          :> "logout"
          :> Authenticated
          :> PostNoContent,
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
          :> Post '[JSON] TokenPairResponse,
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
          :> Post '[JSON] TokenPairResponse,
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
    --     opaque cursor from a previous page's @nextCursor@. The handler enforces the @admin@
    --     role with 'Shomei.Servant.Authz.requireRole' (no production flow grants that role yet
    --     — see the plan's Decision Log).
    auditEvents ::
      mode
        :- "admin"
          :> "audit"
          :> "events"
          :> Authenticated
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

-- | Embeddability proof: mount the whole Shōmei API under @\/auth@ alongside a host
-- route protected by 'Authenticated', plus an admin route documented with the
-- 'RequireRole' phantom combinator. This type-checking shows the API type and the
-- combinators compose inside a host Servant app. (It is illustrative — it is not
-- served here; 'RequireRole' has no 'HasServer' instance, so an actual admin route
-- uses the 'Shomei.Servant.Authz.requireRole' guard instead.)
type AppAPI =
  "auth" :> NamedRoutes ShomeiAPI
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
    :<|> RequireRole "admin" :> Authenticated :> "admin" :> "users" :> Get '[JSON] [User]
