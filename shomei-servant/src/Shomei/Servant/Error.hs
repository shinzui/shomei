-- | The single error vocabulary of the HTTP surface, and the one function that renders it.
--
-- Every failure Shōmei returns — from a workflow, from the auth handler, from an authorization
-- combinator, from Servant's own request parser, from the rate-limit middleware — is an
-- __RFC 9457 problem document__ served as @application/problem+json@:
--
-- @
-- {"type":"https://github.com/shinzui/shomei/blob/master/docs/user/problem-details.md#token_invalid",
--  "title":"Token is invalid","status":401,"code":"token_invalid","retryable":false}
-- @
--
-- @type@ is the stable, dereferenceable primary identifier. @title@ is stable human text,
-- @status@ mirrors the HTTP status, and @code@ and @retryable@ are Shōmei extensions. Optional
-- @detail@ and @instance@ members describe a safe occurrence.
--
-- 'ProblemSpec' constants are the single source shared by the runtime mapping here and by the
-- OpenAPI error documentation in "Shomei.Servant.OpenApi", so a status or title cannot drift
-- between what the server sends and what the spec promises.
--
-- Two deliberate exemptions:
--
--   * health probe failures use the structured 'Servant.Health.ProbeResult' body,
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
    ProblemDetails (..),
    ProblemJSON,
    ProblemSpec (..),
    ProblemOccurrence (..),
    noProblemOccurrence,
    detailOccurrence,
    bearerOccurrence,
    retryAfterOccurrence,
    problemTypeFor,
    problemDetails,
    toProblemError,
    problemBody,
    problemHeaders,

    -- * The catalog
    problemCatalog,
    authErrorProblem,
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
    pcTotpDisabled,
    pcTotpAlreadyEnrolled,
    pcTotpEnrollmentNotFound,
    pcTotpCodeInvalid,
    pcRecoveryCodeInvalid,
    pcReauthenticationRequired,
    pcImpersonationForbidden,
    pcImpersonationTargetInvalid,
    pcImpersonationActionBlocked,
    pcUserNotFound,
    pcRoleNotDefined,
    pcInvalidUserStatus,
    pcUserHasNoEmail,
    pcDependencyUnavailable,
    pcInternal,

    -- * HTTP-layer specs (no 'AuthError' counterpart)
    pcMissingToken,
    pcTokenInvalidAuth,
    pcMissingRole,
    pcMissingScope,
    pcMissingPermission,
    pcCsrfRejected,
    pcBadRequest,
    pcBodyParseError,
    pcNotFound,
    pcMethodNotAllowed,
    pcSelfTargetForbidden,
    pcRoleNotGranted,

    -- * Statuses Servant does not ship
    err422,
    err429,
  )
where

import Control.Lens
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, eitherDecode, genericParseJSON, genericToJSON)
import Data.Aeson qualified as Aeson
import Data.HashMap.Strict.InsOrd.Compat qualified as IOHM
import Data.OpenApi (NamedSchema (..), ToSchema (..))
import Data.OpenApi qualified as O
import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Media (MediaType)
import Network.HTTP.Types.Header (Header)
import Numeric.Natural (Natural)
import Servant
  ( Accept (..),
    ErrorFormatters (..),
    MimeRender (..),
    MimeUnrender (..),
    ServerError (..),
    defaultErrorFormatters,
    err400,
    err401,
    err403,
    err404,
    err405,
    err409,
    err500,
    err503,
  )
import Shomei.Authorization.Claims.Domain (Role (..))
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

-- | RFC 9457 body plus Shōmei's stable extension members.
data ProblemDetails = ProblemDetails
  { problemType :: !Text,
    title :: !Text,
    status :: !Int,
    detail :: !(Maybe Text),
    problemInstance :: !(Maybe Text),
    code :: !Text,
    retryable :: !Bool
  }
  deriving stock (Eq, Show, Generic)

problemJsonOptions :: Options
problemJsonOptions =
  defaultOptions
    { fieldLabelModifier = \case
        "problemType" -> "type"
        "problemInstance" -> "instance"
        field -> field,
      omitNothingFields = True
    }

instance ToJSON ProblemDetails where
  toJSON = genericToJSON problemJsonOptions

instance FromJSON ProblemDetails where
  parseJSON = genericParseJSON problemJsonOptions

-- | The fixed media type for application errors.
data ProblemJSON

instance Accept ProblemJSON where
  contentType _ = "application/problem+json" :: MediaType

instance MimeRender ProblemJSON ProblemDetails where
  mimeRender _ = Aeson.encode

instance MimeUnrender ProblemJSON ProblemDetails where
  mimeUnrender _ = eitherDecode

instance ToSchema ProblemDetails where
  declareNamedSchema _ = pure (NamedSchema (Just "ProblemDetails") problemDetailsSchema)

problemDetailsSchema :: O.Schema
problemDetailsSchema =
  mempty
    & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
    & O.description ?~ "RFC 9457 Problem Details with Shomei code and retryability extensions."
    & O.properties
      .~ IOHM.fromList
        [ ("type", O.Inline (stringSchema & O.format ?~ "uri-reference")),
          ("title", O.Inline stringSchema),
          ("status", O.Inline (integerSchema & O.minimum_ ?~ 100 & O.maximum_ ?~ 599)),
          ("detail", O.Inline stringSchema),
          ("instance", O.Inline (stringSchema & O.format ?~ "uri-reference")),
          ("code", O.Inline stringSchema),
          ("retryable", O.Inline (mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiBoolean))
        ]
    & O.required .~ ["type", "title", "status", "code", "retryable"]
    & O.additionalProperties ?~ O.AdditionalPropertiesAllowed True

stringSchema :: O.Schema
stringSchema = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

integerSchema :: O.Schema
integerSchema = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiInteger

-- | One stable error kind shared by handler results and pre-handler rendering.
--
-- These constants are the SINGLE SOURCE shared by 'authErrorToServerError' below and by the
-- OpenAPI error documentation, so the two cannot disagree about a status or a title.
data ProblemSpec = ProblemSpec
  { problemCode :: !Text,
    -- | the Servant base error; only its status and reason phrase are used
    problemStatus :: !ServerError,
    problemTitle :: !Text,
    problemRetryable :: !Bool
  }

problemSpec :: Text -> ServerError -> Text -> ProblemSpec
problemSpec problemCode problemStatus problemTitle =
  ProblemSpec {problemCode, problemStatus, problemTitle, problemRetryable = False}

retryableProblemSpec :: Text -> ServerError -> Text -> ProblemSpec
retryableProblemSpec problemCode problemStatus problemTitle =
  ProblemSpec {problemCode, problemStatus, problemTitle, problemRetryable = True}

-- | Safe occurrence-specific data and optional response headers.
data ProblemOccurrence = ProblemOccurrence
  { occurrenceDetail :: !(Maybe Text),
    instanceUri :: !(Maybe Text),
    wwwAuthenticate :: !(Maybe Text),
    retryAfterSeconds :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

noProblemOccurrence :: ProblemOccurrence
noProblemOccurrence = ProblemOccurrence Nothing Nothing Nothing Nothing

detailOccurrence :: Text -> ProblemOccurrence
detailOccurrence value = noProblemOccurrence {occurrenceDetail = Just value}

bearerOccurrence :: ProblemOccurrence
bearerOccurrence = noProblemOccurrence {wwwAuthenticate = Just "Bearer"}

retryAfterOccurrence :: Natural -> ProblemOccurrence
retryAfterOccurrence seconds = noProblemOccurrence {retryAfterSeconds = Just seconds}

problemTypeFor :: Text -> Text
problemTypeFor problemCode =
  "https://github.com/shinzui/shomei/blob/master/docs/user/problem-details.md#" <> problemCode

problemDetails :: ProblemSpec -> ProblemOccurrence -> ProblemDetails
problemDetails spec occurrence =
  ProblemDetails
    { problemType = problemTypeFor spec.problemCode,
      title = spec.problemTitle,
      status = spec.problemStatus.errHTTPCode,
      detail = occurrence.occurrenceDetail,
      problemInstance = occurrence.instanceUri,
      code = spec.problemCode,
      retryable = spec.problemRetryable
    }

problemBody :: ProblemSpec -> ProblemOccurrence -> Aeson.Value
problemBody spec = toJSON . problemDetails spec

-- | The response headers a problem document carries at a given status.
--
-- A 401 advertises the scheme the client should use (RFC 6750 §3); a 429 tells the client how
-- long to wait. The token bucket refills continuously, so 60 seconds is an honest upper bound
-- for a full per-minute budget rather than an exact wait.
problemHeaders :: ProblemOccurrence -> [Header]
problemHeaders occurrence =
  [("Content-Type", "application/problem+json")]
    <> foldMap (\value -> [("WWW-Authenticate", encodeUtf8 value)]) occurrence.wwwAuthenticate
    <> foldMap (\seconds -> [("Retry-After", showBytes seconds)]) occurrence.retryAfterSeconds
  where
    encodeUtf8 = TextEncoding.encodeUtf8
    showBytes = encodeUtf8 . Text.pack . show

-- | Render a spec as an RFC 7807 'ServerError'. 'Nothing' omits the @detail@ member.
toProblemError :: ProblemSpec -> ProblemOccurrence -> ServerError
toProblemError spec occurrence =
  spec.problemStatus
    { errBody = Aeson.encode (problemDetails spec occurrence),
      errHeaders = problemHeaders occurrence
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
        toProblemError pcBodyParseError (detailOccurrence (Text.pack msg)),
      urlParseErrorFormatter = \_typeRep _req msg ->
        toProblemError pcBadRequest (detailOccurrence (Text.pack msg)),
      headerParseErrorFormatter = \_typeRep _req msg ->
        toProblemError pcBadRequest (detailOccurrence (Text.pack msg)),
      notFoundErrorFormatter = \_req -> toProblemError pcNotFound noProblemOccurrence
    }

-- ---------------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------------

-- Specs with an 'AuthError' counterpart. Every code/status/title triple below is the one the
-- pre-7807 mapping used, so a client that switched on the old @error@ key ports by reading
-- @code@ instead.

pcInvalidEmail, pcInvalidLoginId, pcWeakPassword :: ProblemSpec
pcInvalidEmail = problemSpec "invalid_email" err400 "Email is not valid"
pcInvalidLoginId = problemSpec "invalid_login_id" err400 "Login identifier is not valid"
pcWeakPassword = problemSpec "weak_password" err400 "Password does not meet policy"

pcEmailTaken, pcLoginIdTaken :: ProblemSpec
pcEmailTaken = problemSpec "email_taken" err409 "Email is already registered"
pcLoginIdTaken = problemSpec "login_id_taken" err409 "Login identifier is already registered"

-- | The single generic answer for a wrong password, an unknown account, and a locked account.
pcInvalidLogin :: ProblemSpec
pcInvalidLogin = problemSpec "invalid_login" err401 "Invalid email or password"

pcTooManyRequests :: ProblemSpec
pcTooManyRequests = retryableProblemSpec "too_many_requests" err429 "Too many requests"

pcSessionNotFound, pcSessionExpired, pcSessionRevoked :: ProblemSpec
pcSessionNotFound = problemSpec "session_not_found" err404 "Session not found"
pcSessionExpired = problemSpec "session_expired" err401 "Session expired"
pcSessionRevoked = problemSpec "session_revoked" err401 "Session revoked"

pcRefreshTokenInvalid, pcRefreshTokenExpired, pcTokenReuse :: ProblemSpec
pcRefreshTokenInvalid = problemSpec "token_invalid" err401 "Token is invalid"
pcRefreshTokenExpired = problemSpec "token_expired" err401 "Refresh token expired"
pcTokenReuse = problemSpec "token_reuse" err401 "Refresh token reuse detected"

pcVerificationTokenInvalid, pcPasswordResetTokenInvalid, pcEmailAlreadyVerified :: ProblemSpec
pcVerificationTokenInvalid = problemSpec "verification_token_invalid" err400 "Verification token is invalid"
pcPasswordResetTokenInvalid = problemSpec "password_reset_token_invalid" err400 "Password reset token is invalid"
pcEmailAlreadyVerified = problemSpec "email_already_verified" err409 "Email is already verified"

-- | 403, not 401: the credential WAS correct; the account is simply not yet eligible.
pcEmailNotVerified :: ProblemSpec
pcEmailNotVerified = problemSpec "email_not_verified" err403 "Email address is not verified"

-- | The access token failed verification. Deliberately does not say why.
pcTokenInvalid :: ProblemSpec
pcTokenInvalid = problemSpec "token_invalid" err401 "Token is invalid"

pcPasskeyNotFound, pcCeremonyNotFound, pcWebAuthnFailed, pcMfaFailed :: ProblemSpec
pcPasskeyNotFound = problemSpec "passkey_not_found" err404 "Passkey not found"
pcCeremonyNotFound = problemSpec "ceremony_not_found" err404 "Registration ceremony not found or expired"
pcWebAuthnFailed = problemSpec "webauthn_verification_failed" err400 "Passkey registration could not be verified"
pcMfaFailed = problemSpec "mfa_failed" err401 "Multi-factor authentication failed"

-- | EP-7 TOTP / recovery-code failures. The invalid-code specs are 401s that deliberately do
-- not distinguish a wrong code from a replayed one from an absent credential.
pcTotpDisabled, pcTotpAlreadyEnrolled, pcTotpEnrollmentNotFound, pcTotpCodeInvalid, pcRecoveryCodeInvalid :: ProblemSpec
pcTotpDisabled = problemSpec "totp_disabled" err403 "TOTP is not enabled"
pcTotpAlreadyEnrolled = problemSpec "totp_already_enrolled" err409 "A TOTP credential is already enrolled"
pcTotpEnrollmentNotFound = problemSpec "totp_enrollment_not_found" err404 "No pending TOTP enrollment to verify"
pcTotpCodeInvalid = problemSpec "totp_code_invalid" err401 "TOTP code is invalid"
pcRecoveryCodeInvalid = problemSpec "recovery_code_invalid" err401 "Recovery code is invalid"

-- | EP-7: a sensitive self-service action (recovery-code regeneration) requires a recently issued
-- access token. Raised by the HTTP layer's freshness gate, not by an 'AuthError'.
pcReauthenticationRequired :: ProblemSpec
pcReauthenticationRequired = problemSpec "reauthentication_required" err403 "Recent authentication required for this action"

pcImpersonationForbidden, pcImpersonationTargetInvalid, pcImpersonationActionBlocked :: ProblemSpec
pcImpersonationForbidden = problemSpec "impersonation_forbidden" err403 "Not allowed to impersonate"
pcImpersonationTargetInvalid = problemSpec "impersonation_target_invalid" err400 "Invalid impersonation target"
pcImpersonationActionBlocked = problemSpec "impersonation_action_blocked" err403 "This action is not permitted while impersonating"

pcUserNotFound, pcRoleNotDefined, pcDependencyUnavailable, pcInternal :: ProblemSpec
pcUserNotFound = problemSpec "user_not_found" err404 "User not found"
pcRoleNotDefined = problemSpec "role_not_defined" err422 "Role not defined"
pcDependencyUnavailable = retryableProblemSpec "dependency_unavailable" err503 "Required dependency unavailable"
pcInternal = problemSpec "internal" err500 "Internal authentication error"

-- | EP-2's admin lifecycle. Both are 409s: the request was well-formed and authorized, but the
-- target's state refuses it.
pcInvalidUserStatus, pcUserHasNoEmail :: ProblemSpec
pcInvalidUserStatus = problemSpec "invalid_user_status" err409 "User is not in a state that allows this action"
pcUserHasNoEmail = problemSpec "user_has_no_email" err409 "User has no email address"

-- Specs raised by the HTTP layer, with no 'AuthError' counterpart.

-- | No credential was presented at all — distinct from one that failed verification.
pcMissingToken :: ProblemSpec
pcMissingToken = problemSpec "missing_token" err401 "Authentication required"

-- | The auth handler's invalid-token 401. Shares the @token_invalid@ code with 'pcTokenInvalid'
-- and, like it, deliberately does not distinguish expired from forged from malformed.
pcTokenInvalidAuth :: ProblemSpec
pcTokenInvalidAuth = problemSpec "token_invalid" err401 "Token is invalid"

pcMissingRole, pcMissingScope, pcMissingPermission, pcCsrfRejected :: ProblemSpec
pcMissingRole = problemSpec "missing_role" err403 "Missing required role"
pcMissingScope = problemSpec "missing_scope" err403 "Missing required scope"

-- | EP-9: the @RequirePermission@ combinator's 403 — the token's @permissions@ claim does not
-- contain the required capability. Distinct code from @missing_role@ so a client can tell a
-- role-gated route from a permission-gated one.
pcMissingPermission = problemSpec "missing_permission" err403 "Missing required permission"

pcCsrfRejected = problemSpec "csrf_rejected" err403 "Origin not allowed for cookie-authenticated request"

-- | A malformed or incomplete request the handler rejected; the @detail@ says what.
pcBadRequest :: ProblemSpec
pcBadRequest = problemSpec "bad_request" err400 "Bad request"

-- | Servant could not parse the JSON request body; the @detail@ carries the parse message.
pcBodyParseError :: ProblemSpec
pcBodyParseError = problemSpec "body_parse_error" err400 "Request body could not be parsed"

pcNotFound, pcMethodNotAllowed :: ProblemSpec
pcNotFound = problemSpec "not_found" err404 "Resource not found"
pcMethodNotAllowed = problemSpec "method_not_allowed" err405 "Method not allowed"

-- | EP-2: an administrator tried to suspend or delete their own account. Refused so a single
-- mistyped request cannot lock the last administrator out of a deployment; the @shomei-admin@ CLI
-- on the box remains the escape hatch for genuinely removing one.
pcSelfTargetForbidden :: ProblemSpec
pcSelfTargetForbidden = problemSpec "self_target_forbidden" err403 "An administrator cannot perform this action on their own account"

-- | EP-2: a role revocation named a role the user did not hold. A @404@ rather than a silent
-- success, so a typo in the role name is visible.
pcRoleNotGranted :: ProblemSpec
pcRoleNotGranted = problemSpec "role_not_granted" err404 "User does not hold that role"

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
    pcTotpDisabled,
    pcTotpAlreadyEnrolled,
    pcTotpEnrollmentNotFound,
    pcTotpCodeInvalid,
    pcRecoveryCodeInvalid,
    pcReauthenticationRequired,
    pcImpersonationForbidden,
    pcImpersonationTargetInvalid,
    pcImpersonationActionBlocked,
    pcUserNotFound,
    pcRoleNotDefined,
    pcInvalidUserStatus,
    pcUserHasNoEmail,
    pcDependencyUnavailable,
    pcInternal,
    pcMissingToken,
    pcTokenInvalidAuth,
    pcMissingRole,
    pcMissingScope,
    pcMissingPermission,
    pcCsrfRejected,
    pcBadRequest,
    pcBodyParseError,
    pcNotFound,
    pcMethodNotAllowed,
    pcSelfTargetForbidden,
    pcRoleNotGranted
  ]

-- | The one total mapping from a domain error to its application problem and occurrence.
-- Returned handler results and thrown pre-handler errors deliberately share this function.
authErrorProblem :: AuthError -> (ProblemSpec, ProblemOccurrence)
authErrorProblem = \case
  InvalidEmail -> plain pcInvalidEmail
  InvalidLoginId -> plain pcInvalidLoginId
  WeakPassword _ -> plain pcWeakPassword
  EmailAlreadyRegistered -> plain pcEmailTaken
  LoginIdAlreadyRegistered -> plain pcLoginIdTaken
  InvalidCredentials -> plain pcInvalidLogin
  UserNotActive -> plain pcInvalidLogin
  AccountLocked -> plain pcInvalidLogin
  TooManyRequests -> (pcTooManyRequests, retryAfterOccurrence 60)
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
  TotpDisabled -> plain pcTotpDisabled
  TotpAlreadyEnrolled -> plain pcTotpAlreadyEnrolled
  TotpEnrollmentNotFound -> plain pcTotpEnrollmentNotFound
  TotpCodeInvalid -> plain pcTotpCodeInvalid
  RecoveryCodeInvalid -> plain pcRecoveryCodeInvalid
  ImpersonationForbidden -> plain pcImpersonationForbidden
  ImpersonationTargetInvalid -> plain pcImpersonationTargetInvalid
  ImpersonationActionBlocked -> plain pcImpersonationActionBlocked
  -- EP-4's two OAuth errors are raised only by 'Shomei.ServiceAccount.ClientCredentials.Workflow', whose sole
  -- caller is @POST \/oauth\/token@ — and that handler renders them through
  -- 'Shomei.Servant.OAuth.oauthError' in the RFC 6749 §5.2 shape, never through this function
  -- (see the exemption in this module's header). These two arms exist so the @\case@ stays total,
  -- and map to generic application errors only to keep this conversion total.
  OAuthClientInvalid -> plain pcInvalidLogin
  OAuthScopeInvalid -> plain pcBadRequest
  -- EP-6's two token-exchange errors are, like EP-4's above, raised only by the
  -- @POST \/oauth\/token@ dispatcher (via 'Shomei.OAuth.TokenExchange.Workflow'), which renders them in
  -- the RFC 6749 §5.2 shape, never through this function. These arms keep the @\case@ total and
  -- reuse existing catalog specs (400s) rather than minting codes no route can emit.
  OAuthGrantInvalid -> plain pcBadRequest
  OAuthRequestMalformed -> plain pcBadRequest
  UserNotFound -> plain pcUserNotFound
  -- The offending name is request-specific, so it belongs in 'detail', keeping 'title' stable
  -- for the OpenAPI catalog.
  RoleNotDefined (Role r) -> (pcRoleNotDefined, detailOccurrence r)
  InvalidUserStatus -> plain pcInvalidUserStatus
  UserHasNoEmail -> plain pcUserHasNoEmail
  DependencyUnavailable _ -> plain pcDependencyUnavailable
  InternalAuthError _ -> plain pcInternal
  where
    plain spec = (spec, noProblemOccurrence)

-- | Render a domain error at a pre-handler boundary.
authErrorToServerError :: AuthError -> ServerError
authErrorToServerError err =
  let (spec, occurrence) = authErrorProblem err
   in toProblemError spec occurrence
