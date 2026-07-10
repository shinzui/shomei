-- | The single error vocabulary of the HTTP surface, and the one function that renders it.
--
-- Every failure Shōmei returns — from a workflow, from the auth handler, from an authorization
-- combinator, from Servant's own request parser, from the rate-limit middleware — is an
-- __RFC 7807 problem document__ served as @application/problem+json@:
--
-- @
-- {"type":"about:blank","title":"Token is invalid","status":401,"code":"token_invalid"}
-- @
--
-- @type@ is always @about:blank@ (Shōmei hosts no error-documentation URLs). @title@ is stable
-- human text. @status@ mirrors the HTTP status. @code@ is the __machine key__ a client switches
-- on, and carries the same strings the pre-7807 @{"error":…}@ shape used. An optional @detail@
-- member carries request-specific text (a parse message, an offending role name).
--
-- 'ProblemSpec' constants are the single source shared by the runtime mapping here and by the
-- OpenAPI error documentation in "Shomei.Servant.OpenApi", so a status or title cannot drift
-- between what the server sends and what the spec promises.
--
-- Two deliberate exemptions:
--
--   * @GET \/ready@'s 503 carries a structured 'Shomei.Servant.DTO.ReadyResponse' probe body,
--     not a problem document. It is a status report, not an error.
--   * The future @POST \/oauth\/token@ endpoint must use RFC 6749 §5.2's
--     @{"error":"invalid_grant",…}@ shape, which OAuth2 clients require. That surface belongs
--     to MasterPlan 7 EP-4 and is exempt from this envelope.
--
-- Never leaks internal detail: 'InvalidCredentials', 'UserNotActive', and 'AccountLocked' all
-- collapse to the same generic @401 invalid_login@ so account existence and status are not
-- disclosed, and 'InternalAuthError' carries no detail to the client.
module Shomei.Servant.Error
  ( -- * The envelope
    ProblemSpec (..),
    toProblemError,
    problemBody,
    problemHeaders,

    -- * The catalog
    problemCatalog,
    authErrorToServerError,

    -- * Servant's built-in failures
    shomeiErrorFormatters,

    -- * Specs with an 'AuthError' counterpart
    --
    -- Exported in full so "Shomei.Servant.OpenApi" can name them in its route→codes
    -- table: the spec's documented status and title are then literally the ones the
    -- server sends.
    pcInvalidEmail,
    pcInvalidLoginId,
    pcWeakPassword,
    pcEmailTaken,
    pcLoginIdTaken,
    pcInvalidLogin,
    pcTooManyRequests,
    pcSessionNotFound,
    pcSessionExpired,
    pcSessionRevoked,
    pcRefreshTokenInvalid,
    pcRefreshTokenExpired,
    pcTokenReuse,
    pcVerificationTokenInvalid,
    pcPasswordResetTokenInvalid,
    pcEmailAlreadyVerified,
    pcEmailNotVerified,
    pcTokenInvalid,
    pcPasskeyNotFound,
    pcCeremonyNotFound,
    pcWebAuthnFailed,
    pcMfaFailed,
    pcImpersonationForbidden,
    pcImpersonationTargetInvalid,
    pcImpersonationActionBlocked,
    pcServiceTokenDisabled,
    pcServiceAccountInvalid,
    pcServiceTokenScopeDenied,
    pcServiceTokenActorInvalid,
    pcUserNotFound,
    pcRoleNotDefined,
    pcInternal,

    -- * HTTP-layer specs (no 'AuthError' counterpart)
    pcMissingToken,
    pcTokenInvalidAuth,
    pcMissingRole,
    pcMissingScope,
    pcCsrfRejected,
    pcBadRequest,
    pcBodyParseError,
    pcNotFound,
    pcMethodNotAllowed,

    -- * Statuses Servant does not ship
    err422,
    err429,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Network.HTTP.Types.Header (Header)
import Servant
  ( ErrorFormatters (..),
    ServerError (..),
    defaultErrorFormatters,
    err400,
    err401,
    err403,
    err404,
    err405,
    err409,
    err500,
  )
import Shomei.Domain.Claims (Role (..))
import Shomei.Error (AuthError (..))
import Shomei.Prelude

-- ---------------------------------------------------------------------------
-- Statuses Servant does not ship
-- ---------------------------------------------------------------------------

-- | HTTP 429 Too Many Requests.
err429 :: ServerError
err429 =
  ServerError
    { errHTTPCode = 429,
      errReasonPhrase = "Too Many Requests",
      errBody = "",
      errHeaders = []
    }

-- | HTTP 422 Unprocessable Content.
err422 :: ServerError
err422 =
  ServerError
    { errHTTPCode = 422,
      errReasonPhrase = "Unprocessable Content",
      errBody = "",
      errHeaders = []
    }

-- ---------------------------------------------------------------------------
-- The envelope
-- ---------------------------------------------------------------------------

-- | One stable error kind: the machine 'problemCode', the HTTP status (carried as the Servant
-- base error it renders from), and the human 'problemTitle'.
--
-- These constants are the SINGLE SOURCE shared by 'authErrorToServerError' below and by the
-- OpenAPI error documentation, so the two cannot disagree about a status or a title.
data ProblemSpec = ProblemSpec
  { problemCode :: !Text,
    -- | the Servant base error; only its status and reason phrase are used
    problemStatus :: !ServerError,
    problemTitle :: !Text
  }

-- | The problem document for a spec, with an optional @detail@.
problemBody :: ProblemSpec -> Maybe Text -> Aeson.Value
problemBody spec mDetail =
  Aeson.object
    ( [ "type" Aeson..= ("about:blank" :: Text),
        "title" Aeson..= spec.problemTitle,
        "status" Aeson..= spec.problemStatus.errHTTPCode,
        "code" Aeson..= spec.problemCode
      ]
        <> maybe [] (\d -> ["detail" Aeson..= d]) mDetail
    )

-- | The response headers a problem document carries at a given status.
--
-- A 401 advertises the scheme the client should use (RFC 6750 §3); a 429 tells the client how
-- long to wait. The token bucket refills continuously, so 60 seconds is an honest upper bound
-- for a full per-minute budget rather than an exact wait.
problemHeaders :: ProblemSpec -> [Header]
problemHeaders spec =
  ("Content-Type", "application/problem+json")
    : case spec.problemStatus.errHTTPCode of
      401 -> [("WWW-Authenticate", "Bearer")]
      429 -> [("Retry-After", "60")]
      _ -> []

-- | Render a spec as an RFC 7807 'ServerError'. 'Nothing' omits the @detail@ member.
toProblemError :: ProblemSpec -> Maybe Text -> ServerError
toProblemError spec mDetail =
  spec.problemStatus
    { errBody = Aeson.encode (problemBody spec mDetail),
      errHeaders = problemHeaders spec
    }

-- ---------------------------------------------------------------------------
-- Servant's own request-parsing failures
-- ---------------------------------------------------------------------------

-- | Replace Servant's plain-text 400/404 bodies with problem documents.
--
-- __Servant's 405 is not reachable from here.__ @ErrorFormatters@ has exactly four hooks —
-- body-parse, url-parse, header-parse, and not-found — while a method mismatch raises a
-- hardcoded @err405@ (empty body) inside @Servant.Server.Internal.methodCheck@. The
-- 'Shomei.Servant.Middleware.problemMiddleware' WAI layer converts that one.
shomeiErrorFormatters :: ErrorFormatters
shomeiErrorFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = \_typeRep _req msg ->
        toProblemError pcBodyParseError (Just (Text.pack msg)),
      urlParseErrorFormatter = \_typeRep _req msg ->
        toProblemError pcBadRequest (Just (Text.pack msg)),
      headerParseErrorFormatter = \_typeRep _req msg ->
        toProblemError pcBadRequest (Just (Text.pack msg)),
      notFoundErrorFormatter = \_req -> toProblemError pcNotFound Nothing
    }

-- ---------------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------------

-- Specs with an 'AuthError' counterpart. Every code/status/title triple below is the one the
-- pre-7807 mapping used, so a client that switched on the old @error@ key ports by reading
-- @code@ instead.

pcInvalidEmail, pcInvalidLoginId, pcWeakPassword :: ProblemSpec
pcInvalidEmail = ProblemSpec "invalid_email" err400 "Email is not valid"
pcInvalidLoginId = ProblemSpec "invalid_login_id" err400 "Login identifier is not valid"
pcWeakPassword = ProblemSpec "weak_password" err400 "Password does not meet policy"

pcEmailTaken, pcLoginIdTaken :: ProblemSpec
pcEmailTaken = ProblemSpec "email_taken" err409 "Email is already registered"
pcLoginIdTaken = ProblemSpec "login_id_taken" err409 "Login identifier is already registered"

-- | The single generic answer for a wrong password, an unknown account, and a locked account.
pcInvalidLogin :: ProblemSpec
pcInvalidLogin = ProblemSpec "invalid_login" err401 "Invalid email or password"

pcTooManyRequests :: ProblemSpec
pcTooManyRequests = ProblemSpec "too_many_requests" err429 "Too many requests"

pcSessionNotFound, pcSessionExpired, pcSessionRevoked :: ProblemSpec
pcSessionNotFound = ProblemSpec "session_not_found" err404 "Session not found"
pcSessionExpired = ProblemSpec "session_expired" err401 "Session expired"
pcSessionRevoked = ProblemSpec "session_revoked" err401 "Session revoked"

pcRefreshTokenInvalid, pcRefreshTokenExpired, pcTokenReuse :: ProblemSpec
pcRefreshTokenInvalid = ProblemSpec "token_invalid" err401 "Refresh token is invalid"
pcRefreshTokenExpired = ProblemSpec "token_expired" err401 "Refresh token expired"
pcTokenReuse = ProblemSpec "token_reuse" err401 "Refresh token reuse detected"

pcVerificationTokenInvalid, pcPasswordResetTokenInvalid, pcEmailAlreadyVerified :: ProblemSpec
pcVerificationTokenInvalid = ProblemSpec "verification_token_invalid" err400 "Verification token is invalid"
pcPasswordResetTokenInvalid = ProblemSpec "password_reset_token_invalid" err400 "Password reset token is invalid"
pcEmailAlreadyVerified = ProblemSpec "email_already_verified" err409 "Email is already verified"

-- | 403, not 401: the credential WAS correct; the account is simply not yet eligible.
pcEmailNotVerified :: ProblemSpec
pcEmailNotVerified = ProblemSpec "email_not_verified" err403 "Email address is not verified"

-- | The access token failed verification. Deliberately does not say why.
pcTokenInvalid :: ProblemSpec
pcTokenInvalid = ProblemSpec "token_invalid" err401 "Token is invalid"

pcPasskeyNotFound, pcCeremonyNotFound, pcWebAuthnFailed, pcMfaFailed :: ProblemSpec
pcPasskeyNotFound = ProblemSpec "passkey_not_found" err404 "Passkey not found"
pcCeremonyNotFound = ProblemSpec "ceremony_not_found" err404 "Registration ceremony not found or expired"
pcWebAuthnFailed = ProblemSpec "webauthn_verification_failed" err400 "Passkey registration could not be verified"
pcMfaFailed = ProblemSpec "mfa_failed" err401 "Multi-factor authentication failed"

pcImpersonationForbidden, pcImpersonationTargetInvalid, pcImpersonationActionBlocked :: ProblemSpec
pcImpersonationForbidden = ProblemSpec "impersonation_forbidden" err403 "Not allowed to impersonate"
pcImpersonationTargetInvalid = ProblemSpec "impersonation_target_invalid" err400 "Invalid impersonation target"
pcImpersonationActionBlocked = ProblemSpec "impersonation_action_blocked" err403 "This action is not permitted while impersonating"

pcServiceTokenDisabled, pcServiceAccountInvalid, pcServiceTokenScopeDenied, pcServiceTokenActorInvalid :: ProblemSpec
pcServiceTokenDisabled = ProblemSpec "service_token_disabled" err403 "Service-token issuance is disabled"
pcServiceAccountInvalid = ProblemSpec "service_account_invalid" err403 "Service account is invalid"
pcServiceTokenScopeDenied = ProblemSpec "service_token_scope_denied" err403 "Requested scopes are not allowed"
pcServiceTokenActorInvalid = ProblemSpec "service_token_actor_invalid" err400 "Invalid service-token actor"

pcUserNotFound, pcRoleNotDefined, pcInternal :: ProblemSpec
pcUserNotFound = ProblemSpec "user_not_found" err404 "User not found"
pcRoleNotDefined = ProblemSpec "role_not_defined" err422 "Role not defined"
pcInternal = ProblemSpec "internal" err500 "Internal authentication error"

-- Specs raised by the HTTP layer, with no 'AuthError' counterpart.

-- | No credential was presented at all — distinct from one that failed verification.
pcMissingToken :: ProblemSpec
pcMissingToken = ProblemSpec "missing_token" err401 "Authentication required"

-- | The auth handler's invalid-token 401. Shares the @token_invalid@ code with 'pcTokenInvalid'
-- and, like it, deliberately does not distinguish expired from forged from malformed.
pcTokenInvalidAuth :: ProblemSpec
pcTokenInvalidAuth = ProblemSpec "token_invalid" err401 "Token is invalid"

pcMissingRole, pcMissingScope, pcCsrfRejected :: ProblemSpec
pcMissingRole = ProblemSpec "missing_role" err403 "Missing required role"
pcMissingScope = ProblemSpec "missing_scope" err403 "Missing required scope"
pcCsrfRejected = ProblemSpec "csrf_rejected" err403 "Origin not allowed for cookie-authenticated request"

-- | A malformed or incomplete request the handler rejected; the @detail@ says what.
pcBadRequest :: ProblemSpec
pcBadRequest = ProblemSpec "bad_request" err400 "Bad request"

-- | Servant could not parse the JSON request body; the @detail@ carries the parse message.
pcBodyParseError :: ProblemSpec
pcBodyParseError = ProblemSpec "body_parse_error" err400 "Request body could not be parsed"

pcNotFound, pcMethodNotAllowed :: ProblemSpec
pcNotFound = ProblemSpec "not_found" err404 "Resource not found"
pcMethodNotAllowed = ProblemSpec "method_not_allowed" err405 "Method not allowed"

-- | Every problem kind Shōmei can emit. The OpenAPI documentation is generated from this list,
-- and a conformance test asserts every documented code appears here.
--
-- Note that @token_invalid@ appears three times (an invalid access token, an invalid refresh
-- token, and the auth handler's rejection): the code is what clients switch on, and those three
-- are the same condition to a client. The titles differ because the causes do.
problemCatalog :: [ProblemSpec]
problemCatalog =
  [ pcInvalidEmail,
    pcInvalidLoginId,
    pcWeakPassword,
    pcEmailTaken,
    pcLoginIdTaken,
    pcInvalidLogin,
    pcTooManyRequests,
    pcSessionNotFound,
    pcSessionExpired,
    pcSessionRevoked,
    pcRefreshTokenInvalid,
    pcRefreshTokenExpired,
    pcTokenReuse,
    pcVerificationTokenInvalid,
    pcPasswordResetTokenInvalid,
    pcEmailAlreadyVerified,
    pcEmailNotVerified,
    pcTokenInvalid,
    pcPasskeyNotFound,
    pcCeremonyNotFound,
    pcWebAuthnFailed,
    pcMfaFailed,
    pcImpersonationForbidden,
    pcImpersonationTargetInvalid,
    pcImpersonationActionBlocked,
    pcServiceTokenDisabled,
    pcServiceAccountInvalid,
    pcServiceTokenScopeDenied,
    pcServiceTokenActorInvalid,
    pcUserNotFound,
    pcRoleNotDefined,
    pcInternal,
    pcMissingToken,
    pcTokenInvalidAuth,
    pcMissingRole,
    pcMissingScope,
    pcCsrfRejected,
    pcBadRequest,
    pcBodyParseError,
    pcNotFound,
    pcMethodNotAllowed
  ]

-- | The one mapping from a domain 'AuthError' to its wire representation.
authErrorToServerError :: AuthError -> ServerError
authErrorToServerError = \case
  InvalidEmail -> plain pcInvalidEmail
  InvalidLoginId -> plain pcInvalidLoginId
  WeakPassword _ -> plain pcWeakPassword
  EmailAlreadyRegistered -> plain pcEmailTaken
  LoginIdAlreadyRegistered -> plain pcLoginIdTaken
  InvalidCredentials -> plain pcInvalidLogin
  UserNotActive -> plain pcInvalidLogin
  AccountLocked -> plain pcInvalidLogin
  TooManyRequests -> plain pcTooManyRequests
  SessionNotFound -> plain pcSessionNotFound
  SessionExpired -> plain pcSessionExpired
  SessionRevoked -> plain pcSessionRevoked
  RefreshTokenInvalid -> plain pcRefreshTokenInvalid
  RefreshTokenExpired -> plain pcRefreshTokenExpired
  RefreshTokenReuseDetected -> plain pcTokenReuse
  VerificationTokenInvalid -> plain pcVerificationTokenInvalid
  PasswordResetTokenInvalid -> plain pcPasswordResetTokenInvalid
  EmailAlreadyVerified -> plain pcEmailAlreadyVerified
  EmailNotVerified -> plain pcEmailNotVerified
  TokenInvalid _ -> plain pcTokenInvalid
  PasskeyNotFound -> plain pcPasskeyNotFound
  PendingCeremonyNotFound -> plain pcCeremonyNotFound
  WebAuthnCeremonyError _ -> plain pcWebAuthnFailed
  MfaAssertionInvalid -> plain pcMfaFailed
  ImpersonationForbidden -> plain pcImpersonationForbidden
  ImpersonationTargetInvalid -> plain pcImpersonationTargetInvalid
  ImpersonationActionBlocked -> plain pcImpersonationActionBlocked
  ServiceTokenDisabled -> plain pcServiceTokenDisabled
  ServiceAccountNotFound -> plain pcServiceAccountInvalid
  ServiceAccountSecretInvalid -> plain pcServiceAccountInvalid
  ServiceTokenScopeDenied -> plain pcServiceTokenScopeDenied
  ServiceTokenActorInvalid -> plain pcServiceTokenActorInvalid
  UserNotFound -> plain pcUserNotFound
  -- The offending name is request-specific, so it belongs in 'detail', keeping 'title' stable
  -- for the OpenAPI catalog.
  RoleNotDefined (Role r) -> toProblemError pcRoleNotDefined (Just r)
  InternalAuthError _ -> plain pcInternal
  where
    plain spec = toProblemError spec Nothing
