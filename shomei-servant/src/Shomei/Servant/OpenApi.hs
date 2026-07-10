{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | All instances here are orphans by design: 'ToSchema'/'ToParamSchema' and
-- 'HasOpenApi' belong to @openapi-hs@/@servant-openapi@, while the DTOs and the
-- custom combinators belong to Shōmei. Concentrating them in one module (rather
-- than scattering them across 'Shomei.Servant.DTO', 'Shomei.Servant.Auth', and
-- 'Shomei.Servant.Authz') keeps the OpenAPI dependency contained and the spec
-- assembly easy to find. The orphans are only ever resolved at the 'toOpenApi'
-- call site inside this module (and its executable/test), so there is no
-- incoherence risk. See EP-27 Decision Log.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The OpenAPI 3.1 description of 'Shomei.Servant.API.ShomeiRoutes', derived
-- directly from the Servant types (EP-27).
--
-- 'shomeiOpenApi' is the complete, enriched document; the @shomei-openapi@
-- executable serialises it to @docs/api/openapi.json@. The instances below are
-- everything @toOpenApi (Proxy \@(NamedRoutes ShomeiRoutes))@ needs to typecheck:
-- a 'ToSchema' per DTO, a free-form 'ToSchema' for aeson 'Value', a hand-written
-- 'ToSchema' for the tagged-union 'LoginResponse', a 'ToParamSchema' for the
-- 'PasskeyId' capture, and 'HasOpenApi' instances for the custom combinators.
module Shomei.Servant.OpenApi
  ( shomeiOpenApi,
    openApiValue,
  )
where

import Control.Lens
import Data.Aeson (Value (String), toJSON)
import Data.Char (isAlphaNum, toUpper)
import Data.HashMap.Strict.InsOrd qualified as IOHM
import Data.List (nub, sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isNothing)
import Data.OpenApi (ToParamSchema (..), ToSchema (..))
import Data.OpenApi qualified as O
import Data.Proxy (Proxy (..))
import Data.Text qualified as T
import GHC.TypeLits (Symbol)
import Servant.API
import Servant.OpenApi (HasOpenApi (..))
-- The status of a 'ProblemSpec' is carried as the Servant base error it renders from; only
-- 'errHTTPCode' is read here.
import Servant.Server (ServerError (errHTTPCode))
import Shomei.Id (PasskeyId, SessionId, UserId)
import Shomei.Servant.API (ShomeiRoutes)
import Shomei.Servant.Authz (RequireRole, RequireScope)
import Shomei.Servant.DTO
  ( AdminUserResponse,
    AdminUsersPage,
    AuditEventResponse,
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
import Shomei.Servant.Error
  ( ProblemSpec (..),
    pcBadRequest,
    pcBodyParseError,
    pcCeremonyNotFound,
    pcCsrfRejected,
    pcEmailAlreadyVerified,
    pcEmailNotVerified,
    pcEmailTaken,
    pcImpersonationActionBlocked,
    pcImpersonationForbidden,
    pcImpersonationTargetInvalid,
    pcInvalidEmail,
    pcInvalidLogin,
    pcInvalidLoginId,
    pcInvalidUserStatus,
    pcLoginIdTaken,
    pcMfaFailed,
    pcMissingRole,
    pcMissingToken,
    pcPasskeyNotFound,
    pcPasswordResetTokenInvalid,
    pcRefreshTokenExpired,
    pcRefreshTokenInvalid,
    pcRoleNotDefined,
    pcRoleNotGranted,
    pcSelfTargetForbidden,
    pcServiceAccountInvalid,
    pcServiceTokenActorInvalid,
    pcServiceTokenDisabled,
    pcServiceTokenScopeDenied,
    pcSessionExpired,
    pcSessionNotFound,
    pcTokenInvalidAuth,
    pcTokenReuse,
    pcTooManyRequests,
    pcUserHasNoEmail,
    pcUserNotFound,
    pcVerificationTokenInvalid,
    pcWeakPassword,
    pcWebAuthnFailed,
  )
import Shomei.Servant.OAuth (TokenResponse)
import Web.FormUrlEncoded (Form)

-- ---------------------------------------------------------------------------
-- ToSchema for every DTO
--
-- Each DTO derives @ToJSON@ with default options (no field-label modifier), so
-- the generic 'declareNamedSchema' default produces a schema that matches the
-- wire JSON. The M4 conformance test ('validateEveryToJSON') enforces this.
-- ---------------------------------------------------------------------------

instance ToSchema SignupRequest

instance ToSchema SignupResponse

instance ToSchema LoginRequest

instance ToSchema RefreshRequest

instance ToSchema VerifyEmailRequest

instance ToSchema ConfirmEmailVerificationRequest

instance ToSchema PasswordResetRequest

instance ToSchema ConfirmPasswordResetRequest

instance ToSchema ChangePasswordRequest

instance ToSchema TokenPairResponse

instance ToSchema UserResponse

instance ToSchema SessionResponse

instance ToSchema HealthResponse

instance ToSchema ReadyResponse

instance ToSchema MfaCompleteRequest

instance ToSchema PasskeyRegisterBeginResponse

instance ToSchema PasskeyRegisterCompleteRequest

instance ToSchema PasskeyResponse

instance ToSchema PasskeyLoginBeginResponse

instance ToSchema PasskeyLoginCompleteRequest

instance ToSchema ImpersonateRequest

instance ToSchema ImpersonateResponse

instance ToSchema ServiceTokenRequest

instance ToSchema ServiceTokenResponse

instance ToSchema AuditEventResponse

instance ToSchema AuditEventsPage

instance ToSchema AdminUserResponse

instance ToSchema AdminUsersPage

-- | EP-4's @POST \/oauth\/token@ (RFC 6749 §5.1). The wire keys are the RFC's snake_case names,
-- which the hand-written 'Aeson.ToJSON' in "Shomei.Servant.OAuth" emits, so this schema is
-- hand-written to match rather than derived. The conformance suite's 'validateEveryToJSON'
-- checks the two agree.
instance ToSchema TokenResponse where
  declareNamedSchema _ =
    pure $
      O.NamedSchema (Just "TokenResponse") $
        mempty
          & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
          & O.description ?~ "An OAuth2 access-token response (RFC 6749 §5.1)."
          & O.properties
            .~ IOHM.fromList
              [ ("access_token", O.Inline (stringSchema & O.description ?~ "The signed JWT access token.")),
                ("token_type", O.Inline (stringSchema & O.description ?~ "Always \"Bearer\".")),
                ("expires_in", O.Inline (mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiInteger & O.description ?~ "Token lifetime in seconds.")),
                ("scope", O.Inline (stringSchema & O.description ?~ "The space-delimited scopes actually granted."))
              ]
          & O.required .~ ["access_token", "token_type", "expires_in", "scope"]

-- | The @application\/x-www-form-urlencoded@ request body of @POST \/oauth\/token@.
--
-- The endpoint takes a raw 'Form' rather than a typed record, because it is a @grant_type@
-- dispatcher whose parameter set differs per grant (see "Shomei.Servant.API"). The schema is
-- therefore an open object of string values, with the parameters this deployment reads described
-- for a human reading the spec.
instance ToSchema Form where
  declareNamedSchema _ =
    pure $
      O.NamedSchema (Just "TokenRequestForm") $
        mempty
          & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
          & O.description
            ?~ "An RFC 6749 token request. `grant_type` selects the flow; the remaining \
               \parameters depend on it. For `client_credentials`: an optional space-delimited \
               \`scope`, plus `client_id`/`client_secret` when the client authenticates with \
               \`client_secret_post` rather than an `Authorization: Basic` header."
          & O.properties
            .~ IOHM.fromList
              [ ("grant_type", O.Inline (stringSchema & O.enum_ ?~ [String "client_credentials"])),
                ("scope", O.Inline stringSchema),
                ("client_id", O.Inline stringSchema),
                ("client_secret", O.Inline stringSchema)
              ]
          & O.required .~ ["grant_type"]
          & O.additionalProperties ?~ O.AdditionalPropertiesAllowed True

-- | Free-form JSON. Several DTOs carry an aeson 'Value' (opaque WebAuthn/JWKS
-- payloads), and @openapi-hs@ ships no 'ToSchema' for it. @additionalProperties:
-- true@ makes the schema accept any JSON: non-object values are unconstrained,
-- and object values may carry any properties. (A bare empty schema is *not*
-- enough — @openapi-hs@'s validator rejects unmentioned object properties unless
-- @additionalProperties@ explicitly permits them.)
instance ToSchema Value where
  declareNamedSchema _ =
    pure $
      O.NamedSchema (Just "AnyValue") $
        mempty & O.additionalProperties ?~ O.AdditionalPropertiesAllowed True

-- | 'LoginResponse' has a hand-written, @status@-tagged 'ToJSON' (a completed
-- login vs. an MFA challenge), so its schema is hand-written to match: a @oneOf@
-- of the two flat object shapes. Generic derivation would not reproduce the
-- custom JSON. This must agree with 'Shomei.Servant.DTO.LoginResponse''s
-- instances — the M4 conformance test checks it.
instance ToSchema LoginResponse where
  declareNamedSchema _ = do
    userRef <- O.declareSchemaRef (Proxy :: Proxy UserResponse)
    tokenRef <- O.declareSchemaRef (Proxy :: Proxy TokenPairResponse)
    optionsRef <- O.declareSchemaRef (Proxy :: Proxy Value)
    let stringProp = O.Inline (mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString)
        completeBranch =
          mempty
            & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.properties
              .~ IOHM.fromList
                [ ("status", stringProp),
                  ("user", userRef),
                  ("token", tokenRef)
                ]
            & O.required .~ ["status", "user", "token"]
        mfaBranch =
          mempty
            & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.properties
              .~ IOHM.fromList
                [ ("status", stringProp),
                  ("ceremonyId", stringProp),
                  ("options", optionsRef)
                ]
            & O.required .~ ["status", "ceremonyId", "options"]
    pure $
      O.NamedSchema (Just "LoginResponse") $
        mempty & O.oneOf ?~ [O.Inline completeBranch, O.Inline mfaBranch]

-- | Every Shōmei id is a @KindID@ (a UUIDv7 behind a type-level prefix); its wire/capture form
-- is the TypeID string, e.g. @user_01h455vb4pex5vsknk084sn02q@.
instance ToParamSchema PasskeyId where
  toParamSchema _ = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

instance ToParamSchema UserId where
  toParamSchema _ = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

instance ToParamSchema SessionId where
  toParamSchema _ = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

-- ---------------------------------------------------------------------------
-- HasOpenApi for the custom combinators (none ship in servant-openapi)
-- ---------------------------------------------------------------------------

-- | @Authenticated = AuthProtect "shomei-jwt"@: register an HTTP bearer-JWT
-- security scheme in @components@ and require it on every operation of the
-- sub-API.
instance (HasOpenApi sub) => HasOpenApi (AuthProtect "shomei-jwt" :> sub) where
  toOpenApi _ = requireBearer (Proxy :: Proxy sub)

-- | 'RequireRole' and 'RequireScope' authenticate the caller themselves (they run the same
-- 'Shomei.Servant.Auth.authHandler' 'Authenticated' does) and then check a claim. To a client
-- reading the spec that is the same contract — present a bearer token — plus a 403 if the
-- token lacks the role or scope. So both describe themselves exactly as 'Authenticated' does.
--
-- These must not be transparent pass-throughs: an operation carrying only 'RequireRole' would
-- otherwise be documented as unauthenticated, and generated clients would omit the token.
instance (HasOpenApi sub) => HasOpenApi (RequireRole (r :: Symbol) :> sub) where
  toOpenApi _ = requireBearer (Proxy :: Proxy sub)

instance (HasOpenApi sub) => HasOpenApi (RequireScope (s :: Symbol) :> sub) where
  toOpenApi _ = requireBearer (Proxy :: Proxy sub)

-- | Register the bearer-JWT security scheme and require it on every operation of @sub@.
requireBearer :: (HasOpenApi sub) => Proxy sub -> O.OpenApi
requireBearer p =
  toOpenApi p
    & O.components . O.securitySchemes
      <>~ O.SecurityDefinitions (IOHM.singleton "bearerAuth" bearerScheme)
    & O.allOperations . O.security
      %~ (O.SecurityRequirement (IOHM.singleton "bearerAuth" []) :)
  where
    bearerScheme =
      O.SecurityScheme
        (O.SecuritySchemeHttp (O.HttpSchemeBearer (Just "jwt")))
        (Just "JWT access token")

-- ---------------------------------------------------------------------------
-- The error surface, generated from the runtime catalog
-- ---------------------------------------------------------------------------

-- | The RFC 7807 document every Shōmei error is, as a @components.schemas@ entry.
--
-- Must agree with 'Shomei.Servant.Error.problemBody', which builds the runtime value. The
-- conformance suite pins the @required@ list.
problemSchema :: O.Schema
problemSchema =
  mempty
    & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
    & O.description
      ?~ "An RFC 7807 problem document. Every Shōmei error response has this shape, served as \
         \application/problem+json. Switch on `code`; `title` is stable human text and `detail`, \
         \when present, explains this particular occurrence."
    & O.properties
      .~ IOHM.fromList
        [ ("type", O.Inline (stringSchema & O.description ?~ "Always \"about:blank\": Shōmei hosts no error-documentation URLs.")),
          ("title", O.Inline (stringSchema & O.description ?~ "Stable human-readable summary of the error kind.")),
          ("status", O.Inline (mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiInteger & O.description ?~ "Mirrors the HTTP status code.")),
          ("code", O.Inline (stringSchema & O.description ?~ "The machine-readable error key. This is what a client switches on.")),
          ("detail", O.Inline (stringSchema & O.description ?~ "Human-readable explanation specific to this occurrence."))
        ]
    & O.required .~ ["type", "title", "status", "code"]

stringSchema :: O.Schema
stringSchema = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

-- | The HTTP methods Shōmei's routes use, as a selector for the matching 'O.PathItem' field. A
-- route→codes table entry names one operation, and a path may carry several
-- (@\/v1\/auth\/impersonate@ has POST and DELETE).
--
-- 'allMethods' must list every constructor: 'withErrorResponses' folds over it, so a method
-- missing here silently documents no errors at all for every route that uses it. EP-2's
-- @PUT …\/roles\/{role}@ was exactly that hole, caught by the conformance suite's
-- "documents a 401 on every bearer operation" check.
data Method = MGet | MPost | MPut | MDelete
  deriving stock (Eq, Show, Enum, Bounded)

allMethods :: [Method]
allMethods = [minBound .. maxBound]

methodLens :: Method -> Lens' O.PathItem (Maybe O.Operation)
methodLens = \case
  MGet -> O.get
  MPost -> O.post
  MPut -> O.put
  MDelete -> O.delete

-- | Which problem kinds each operation can produce, beyond the baseline every operation gets
-- from its own shape (see 'baselineSpecs').
--
-- This is the one hand-maintained part of the error documentation, and it is deliberately so:
-- deriving it would need effect-level tracking of which 'Shomei.Error.AuthError' each workflow
-- can throw. What cannot drift is the /content/ of each entry — the status and title come from
-- the same 'ProblemSpec' constant the runtime renders, so this table can be incomplete but never
-- wrong. The conformance suite checks every documented code against 'problemCatalog'.
--
-- The 429s are the rate limiter's, and they name exactly the five paths
-- 'Shomei.Server.Middleware.RateLimit.throttledPath' guards — a WAI layer the route types know
-- nothing about.
routeErrors :: [(FilePath, Method, [ProblemSpec])]
routeErrors =
  [ ( "/v1/auth/signup",
      MPost,
      [pcInvalidEmail, pcInvalidLoginId, pcWeakPassword, pcBadRequest, pcEmailTaken, pcLoginIdTaken, pcTooManyRequests]
    ),
    ("/v1/auth/login", MPost, [pcBadRequest, pcInvalidLogin, pcEmailNotVerified, pcTooManyRequests]),
    ( "/v1/auth/refresh",
      MPost,
      [ pcBadRequest,
        pcRefreshTokenInvalid,
        pcRefreshTokenExpired,
        pcTokenReuse,
        pcSessionExpired,
        pcCsrfRejected,
        pcEmailNotVerified,
        pcTooManyRequests
      ]
    ),
    ( "/v1/auth/service-token",
      MPost,
      [pcBadRequest, pcServiceTokenActorInvalid, pcServiceTokenDisabled, pcServiceAccountInvalid, pcServiceTokenScopeDenied]
    ),
    ("/v1/auth/verify-email/request", MPost, [pcTooManyRequests]),
    ("/v1/auth/verify-email/confirm", MPost, [pcVerificationTokenInvalid, pcEmailAlreadyVerified]),
    ("/v1/auth/password-reset/request", MPost, [pcTooManyRequests]),
    ("/v1/auth/password-reset/confirm", MPost, [pcPasswordResetTokenInvalid]),
    ("/v1/auth/password/change", MPost, [pcInvalidLogin]),
    ("/v1/auth/me", MGet, [pcUserNotFound]),
    ("/v1/auth/session", MGet, [pcSessionNotFound]),
    ("/v1/auth/passkeys/register/complete", MPost, [pcBadRequest, pcWebAuthnFailed, pcCeremonyNotFound]),
    -- A malformed capture is a 400, not a 404: servant's @Capture@ runs 'urlParseErrorFormatter',
    -- which this codebase points at 'pcBadRequest'. Verified against the running server.
    ("/v1/auth/passkeys/{passkeyId}", MDelete, [pcBadRequest, pcPasskeyNotFound]),
    ("/v1/auth/mfa/complete", MPost, [pcBadRequest, pcMfaFailed, pcEmailNotVerified, pcCeremonyNotFound]),
    ("/v1/auth/login/passkey/complete", MPost, [pcBadRequest, pcMfaFailed, pcEmailNotVerified, pcCeremonyNotFound]),
    ("/v1/auth/impersonate", MPost, [pcImpersonationTargetInvalid, pcImpersonationForbidden, pcImpersonationActionBlocked]),
    ("/v1/auth/impersonate", MDelete, [pcImpersonationTargetInvalid]),
    ("/v1/admin/audit/events", MGet, [pcBadRequest, pcMissingRole]),
    -- EP-2's admin surface. Every one of these is gated by 'Shomei.Servant.Authz.requireAdmin',
    -- whose refusal is the same @missing_role@ document 'RequireRole' raises, so 'pcMissingRole'
    -- appears throughout. The 401s and the body-parse 400s come from 'baselineSpecs', not here.
    ("/v1/admin/users", MGet, [pcBadRequest, pcMissingRole]),
    ("/v1/admin/users/{userId}", MGet, [pcMissingRole, pcUserNotFound]),
    ("/v1/admin/users/{userId}", MDelete, [pcMissingRole, pcSelfTargetForbidden, pcImpersonationActionBlocked, pcUserNotFound, pcInvalidUserStatus]),
    ("/v1/admin/users/{userId}/suspend", MPost, [pcMissingRole, pcSelfTargetForbidden, pcImpersonationActionBlocked, pcUserNotFound, pcInvalidUserStatus]),
    ("/v1/admin/users/{userId}/reinstate", MPost, [pcMissingRole, pcImpersonationActionBlocked, pcUserNotFound, pcInvalidUserStatus]),
    ("/v1/admin/users/{userId}/sessions", MGet, [pcMissingRole, pcUserNotFound]),
    ("/v1/admin/users/{userId}/sessions", MDelete, [pcMissingRole, pcImpersonationActionBlocked, pcUserNotFound]),
    ("/v1/admin/sessions/{sessionId}", MDelete, [pcMissingRole, pcImpersonationActionBlocked, pcSessionNotFound]),
    ("/v1/admin/users/{userId}/password-reset", MPost, [pcMissingRole, pcImpersonationActionBlocked, pcUserNotFound, pcUserHasNoEmail]),
    ("/v1/admin/users/{userId}/roles/{role}", MPut, [pcBadRequest, pcMissingRole, pcImpersonationActionBlocked, pcUserNotFound, pcRoleNotDefined]),
    ("/v1/admin/users/{userId}/roles/{role}", MDelete, [pcBadRequest, pcMissingRole, pcImpersonationActionBlocked, pcRoleNotGranted])
  ]

-- | What an operation can fail with by virtue of its /shape/, independent of the table.
--
-- An operation that requires a bearer token can always answer @401@ with no credential or a bad
-- one; an operation that takes a request body can always fail Servant's body parser. Both are
-- read off the generated document rather than restated per route, so a new authenticated route
-- documents its 401s the day it is added.
baselineSpecs :: O.Operation -> [ProblemSpec]
baselineSpecs op =
  [spec | not (null (op ^. O.security)), spec <- [pcMissingToken, pcTokenInvalidAuth]]
    <> [pcBodyParseError | has (O.requestBody . _Just) op]

-- | The paths exempt from the problem-details envelope: they answer RFC 6749 §5.2 error objects,
-- because that is what stock OAuth2 \/ OIDC clients parse.
--
-- __Any new @\/oauth\/*@ or OIDC route must be added here__, with the statuses it can actually
-- emit. Otherwise 'baselineSpecs' documents it with a @problem+json@ response it cannot produce
-- (silently, for a route with a request body — no other conformance check inspects a non-problem
-- response). Plan 43's token-exchange grant lands on @\/oauth\/token@ and needs no new entry.
--
-- Note @\/oauth\/userinfo@ is deliberately absent: it is guarded by the ordinary 'Authenticated'
-- combinator and its @401@s are the ordinary problem documents, not OAuth error objects.
oauthErrorResponsesByPath :: [(FilePath, [(Int, [T.Text])])]
oauthErrorResponsesByPath =
  [ -- @401@ is @invalid_client@ alone (and carries @WWW-Authenticate: Basic@); @400@ covers the
    -- request-shape and scope failures. @500@ is documented because a database outage must still
    -- answer in the OAuth shape rather than break the client's error parser.
    ( "/oauth/token",
      [ (400, ["invalid_request", "unsupported_grant_type", "invalid_scope"]),
        (401, ["invalid_client"]),
        (500, ["server_error"])
      ]
    ),
    -- A deployment with @oidcEnabled = false@ must not advertise; the refusal reaches OIDC
    -- tooling, so it speaks the OAuth error shape rather than the application envelope.
    ("/.well-known/openid-configuration", [(404, ["not_found"])]),
    -- @400@ is the no-redirect regime (unknown client, unregistered redirect_uri): every OTHER
    -- authorize failure is a @302@ carrying @error=@, and so is a success — which is why no 4xx
    -- here mentions @invalid_scope@ or @unsupported_response_type@. @401@ is the unauthenticated
    -- request when no @loginUrl@ is configured.
    ( "/oauth/authorize",
      [ (400, ["invalid_request"]),
        (401, ["login_required"]),
        (404, ["not_found"])
      ]
    )
  ]

oauthPaths :: [FilePath]
oauthPaths = map fst oauthErrorResponsesByPath

-- | The RFC 6749 §5.2 error object, as a @components.schemas@ entry.
--
-- Deliberately NOT the @Problem@ schema. Must agree with 'Shomei.Servant.OAuth.oauthError',
-- which builds the runtime value.
oauthErrorSchema :: O.Schema
oauthErrorSchema =
  mempty
    & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
    & O.description
      ?~ "An RFC 6749 §5.2 error response. Endpoints under /oauth/* speak the OAuth2 wire \
         \protocol, so they answer with this shape rather than the RFC 7807 problem document \
         \every other Shōmei endpoint returns. Switch on `error`."
    & O.properties
      .~ IOHM.fromList
        [ ("error", O.Inline (stringSchema & O.description ?~ "The machine-readable OAuth2 error code.")),
          ("error_description", O.Inline (stringSchema & O.description ?~ "Human-readable explanation."))
        ]
    & O.required .~ ["error"]

-- | The response object for one OAuth status, narrowing @error@ to the codes it can carry.
oauthErrorResponse :: [T.Text] -> O.Response
oauthErrorResponse codes =
  mempty
    & O.description
      .~ ("An RFC 6749 error response. The `error` member is one of: " <> T.intercalate ", " codes <> ".")
    & O.content .~ IOHM.singleton "application/json" (mempty & O.schema ?~ O.Inline narrowed)
  where
    narrowed =
      mempty
        & O.allOf ?~ [O.Ref (O.Reference "OAuthError")]
        & O.properties
          .~ IOHM.singleton "error" (O.Inline (stringSchema & O.enum_ ?~ map String codes))

-- | Attach a problem-document response per distinct status an operation can fail with — except
-- on 'oauthPaths', which get RFC 6749 error objects instead.
withErrorResponses :: O.OpenApi -> O.OpenApi
withErrorResponses doc =
  doc
    & O.components . O.schemas . at "Problem" ?~ problemSchema
    & O.components . O.schemas . at "OAuthError" ?~ oauthErrorSchema
    & O.paths %~ imap decoratePath
  where
    decoratePath path item
      | Just statuses <- lookup path oauthErrorResponsesByPath =
          -- Never fall through to the problem-details decoration: a body-carrying operation here
          -- would otherwise be documented with a problem+json 400 it cannot emit.
          foldl' (\acc m -> acc & methodLens m . _Just %~ decorateOAuthOp statuses) item allMethods
    decoratePath path item =
      foldl' (\acc m -> acc & methodLens m . _Just %~ decorateOp path m) item allMethods

    decorateOAuthOp statuses op =
      foldl' (\acc (status, codes) -> acc & at status ?~ O.Inline (oauthErrorResponse codes)) op statuses

    decorateOp path m op =
      foldl' addStatus op (byStatus (baselineSpecs op <> tabled path m))

    tabled path m = concat [specs | (p, m', specs) <- routeErrors, p == path, m' == m]

    addStatus op specs =
      op & at (statusOf (NE.head specs)) ?~ O.Inline (problemResponse (NE.toList specs))

    statusOf :: ProblemSpec -> Int
    statusOf = errHTTPCode . problemStatus

    -- One response per status; a status shared by several codes lists them all.
    byStatus :: [ProblemSpec] -> [NE.NonEmpty ProblemSpec]
    byStatus = NE.groupBy (\a b -> statusOf a == statusOf b) . sortOn statusOf

-- | The response object for one status: the 'Problem' schema, narrowed to the codes this
-- operation can actually return.
--
-- The narrowing rides in @properties.code.enum@ rather than a @x-error-codes@ vendor
-- extension, because @openapi-hs@'s 'O.Response' has no extensions field (see Surprises) —
-- and because an @enum@ is standard JSON Schema that a client generator can turn into a
-- sum type, which is better than an extension anyway.
problemResponse :: [ProblemSpec] -> O.Response
problemResponse specs =
  mempty
    & O.description .~ description
    & O.content .~ IOHM.singleton "application/problem+json" (mempty & O.schema ?~ O.Inline narrowed)
  where
    codes = nub [spec.problemCode | spec <- specs]
    description =
      "An RFC 7807 problem document. The `code` member is one of: "
        <> T.intercalate ", " codes
        <> "."
    narrowed =
      mempty
        & O.allOf ?~ [O.Ref (O.Reference "Problem")]
        & O.properties
          .~ IOHM.singleton "code" (O.Inline (stringSchema & O.enum_ ?~ map String codes))

-- ---------------------------------------------------------------------------
-- Spec hygiene: the bits servant-openapi cannot know
-- ---------------------------------------------------------------------------

-- | Three corrections servant-openapi's generic derivation cannot make on its own.
--
-- (a) A @204@, and a @200@\/@202@ whose body is servant's 'NoContent', is generated with a
-- @content@ map holding one media type and no schema. On a @204@ that is /invalid/ OpenAPI;
-- everywhere else it is noise that makes a generated client expect a body. Both are dropped.
--
-- (b) @description@ is REQUIRED on a response object, and servant-openapi leaves it @""@ for
-- every success response. Filled from the status.
--
-- (c) Every Shōmei request body is mandatory, but @requestBody.required@ defaults to @false@,
-- which tells a generated client the body may be omitted.
withSpecHygiene :: O.OpenApi -> O.OpenApi
withSpecHygiene =
  (O.allOperations . O.responses . O.responses %~ IOHM.mapWithKey fixResponse)
    . (O.allOperations . O.requestBody . _Just . O._Inline . O.required ?~ True)
  where
    fixResponse :: O.HttpStatusCode -> O.Referenced O.Response -> O.Referenced O.Response
    fixResponse code = over O._Inline (dropEmptyContent . fillDescription code)

    dropEmptyContent resp
      | all (isNothing . view O.schema) (IOHM.elems (resp ^. O.content)) = resp & O.content .~ mempty
      | otherwise = resp

    fillDescription code resp
      | T.null (resp ^. O.description) = resp & O.description .~ describeStatus code
      | otherwise = resp

    describeStatus = \case
      200 -> "Success."
      201 -> "Created."
      202 -> "Accepted: the request was validated; delivery happens out of band."
      204 -> "Success; no response body."
      n -> "Response " <> T.pack (show n) <> "."

-- ---------------------------------------------------------------------------
-- The assembled, enriched document
-- ---------------------------------------------------------------------------

-- | The complete, enriched OpenAPI 3.1 document for the Shōmei auth service, generated from
-- @Proxy (NamedRoutes ShomeiRoutes)@ — the served tree, so the documented paths are the ones a
-- client calls: application routes under @\/v1@, JWKS and the probes at the root.
shomeiOpenApi :: O.OpenApi
shomeiOpenApi =
  toOpenApi (Proxy :: Proxy (NamedRoutes ShomeiRoutes))
    & O.info . O.title .~ "Shōmei Authentication API"
    & O.info . O.version .~ "0.1.0.0"
    & O.info . O.description
      ?~ "Authentication, session, passkey, MFA, impersonation, and token API for the Shōmei auth service."
    & O.servers .~ [localServer]
    & withOperationIds
    & withErrorResponses
    & withSpecHygiene
  where
    localServer = ("http://localhost:8080" :: O.Server) & O.description ?~ "Local development server"

-- | 'shomeiOpenApi' as JSON, computed once per process. Served by @GET \/openapi.json@, so a
-- deployed instance describes the binary it is actually running rather than whatever
-- @docs\/api\/openapi.json@ was committed. The document includes @\/openapi.json@ itself.
openApiValue :: Value
openApiValue = toJSON shomeiOpenApi

-- | Assign a stable @operationId@ to every operation, derived from its HTTP
-- method and path (e.g. @GET \/v1\/auth\/me@ → @getAuthMe@). Operations clients
-- generate from these get readable method names. Mirrors the helper in
-- @servant-openapi@'s reference generator.
withOperationIds :: O.OpenApi -> O.OpenApi
withOperationIds = O.paths %~ imap setForPath
  where
    setForPath path =
      (O.get . _Just . O.operationId %~ orSet ("get" <> key))
        . (O.post . _Just . O.operationId %~ orSet ("create" <> key))
        . (O.put . _Just . O.operationId %~ orSet ("update" <> key))
        . (O.delete . _Just . O.operationId %~ orSet ("delete" <> key))
      where
        key = camel path
    orSet v = Just . maybe v id

-- | Turn a path like @"\/v1\/auth\/passkeys\/{passkeyId}"@ into @"AuthPasskeysPasskeyId"@.
--
-- The version segment is dropped: an @operationId@ names /what the operation does/, and
-- generated clients turn it into a method name. Folding @v1@ in would rename every method the
-- day the routes moved under @\/v1@, and rename them all again at @\/v2@ — churn that says
-- nothing about the operation. The path in @paths@ still carries the version, which is where a
-- client reads it from.
camel :: FilePath -> T.Text
camel = T.pack . concatMap capitalize . dropVersion . words . map keepAlnum
  where
    keepAlnum c = if isAlphaNum c then c else ' '
    capitalize [] = []
    capitalize (c : cs) = toUpper c : cs
    dropVersion ("v1" : rest) = rest
    dropVersion segments = segments
