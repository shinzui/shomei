{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- \| The OpenAPI 3.1 description of 'Shomei.Servant.Api.ShomeiRoutes', derived
-- directly from the Servant types (EP-27).
--
-- 'shomeiOpenApi' is the complete, enriched document; the @shomei-openapi@
-- executable serialises it to @docs/api/openapi.json@. The instances below are
-- everything @toOpenApi (Proxy \@(NamedRoutes ShomeiRoutes))@ needs to typecheck:
-- a 'ToSchema' per DTO, a free-form 'ToSchema' for aeson 'Value', a hand-written
-- 'ToSchema' for the tagged-union 'LoginResponse', a 'ToParamSchema' for the
-- 'PasskeyId' capture, and 'HasOpenApi' instances for the custom combinators.

-- | All instances here are orphans by design: 'ToSchema'/'ToParamSchema' and
-- 'HasOpenApi' belong to @openapi-hs@/@servant-openapi-hs@, while the DTOs and the
-- custom combinators belong to Shōmei. Concentrating them in one module (rather
-- than scattering them across concept DTO modules, 'Shomei.Servant.Auth', and
-- 'Shomei.Servant.Authz') keeps the OpenAPI dependency contained and the spec
-- assembly easy to find. The orphans are only ever resolved at the 'toOpenApi'
-- call site inside this module (and its executable/test), so there is no
-- incoherence risk. See EP-27 Decision Log.
module Shomei.Servant.OpenApi
  ( shomeiOpenApi,
    openApiValue,
  )
where

import Control.Lens
import Data.Aeson (Value (String), toJSON)
import Data.Char (isAlphaNum, toUpper)
-- openapi-hs 5 vendors the insertion-ordered map it used to take from
-- insert-ordered-containers; the OpenAPI record fields are keyed by this type.
import Data.HashMap.Strict.InsOrd.Compat qualified as IOHM
import Data.Maybe (isNothing)
import Data.OpenApi (ToParamSchema (..), ToSchema (..))
import Data.OpenApi qualified as O
import Data.OpenApi.Declare (runDeclare)
import Data.Proxy (Proxy (..))
import Data.Text qualified as T
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Servant.API
import Servant.API.MultiVerb (DescHeader, OptHeader)
import Servant.OpenApi (HasOpenApi (..))
import Servant.OpenApi.Internal (IsSwaggerResponseList (..), ToResponseHeader (..))
import Shomei.Account.Dto
  ( ChangePasswordRequest,
    ConfirmEmailVerificationRequest,
    ConfirmPasswordResetRequest,
    PasswordResetRequest,
    SignupRequest,
    SignupResponse,
    VerifyEmailRequest,
  )
import Shomei.Account.User.Dto (AdminStatusFilter, AdminUserResponse, AdminUsersPage, UserPageCursor, UserResponse)
import Shomei.Audit.Dto
  ( AuditEventResponse,
    AuditEventsPage,
    AuditPageCursor,
    AuditSessionId,
    AuditTimestamp,
    AuditUserId,
  )
import Shomei.Id (PasskeyId, SessionId, UserId)
import Shomei.Mfa.Dto
  ( MfaCompleteRequest,
    MfaProof,
    RecoveryCodesCountResponse,
    RecoveryCodesResponse,
    TotpEnrollResponse,
    TotpRemoveRequest,
    TotpVerifyRequest,
  )
import Shomei.Passkey.Dto
  ( PasskeyLoginBeginResponse,
    PasskeyLoginCompleteRequest,
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
  )
import Shomei.Servant.Api (ShomeiRoutes)
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Authz (RequireAdmin, RequirePermission, RequireRole, RequireScope)
import Shomei.Servant.OAuth (TokenResponse)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses, RateLimited)
import Shomei.Servant.Result
  ( AuthenticationPreHandlerResponses,
    AuthorizationPreHandlerResponses,
    CsrfPreHandlerResponses,
    RateLimitPreHandlerResponses,
  )
import Shomei.Session.Dto (LoginRequest, LoginResponse, RefreshRequest, SessionResponse, TokenPairResponse)
import Web.FormUrlEncoded (Form)

-- servant-openapi-hs 5.1 understands MultiVerb and WithHeaders, but its released header
-- renderer only recognizes Servant's plain 'Header'. Bridge MultiVerb's public descriptive and
-- optional header wrappers here so the exact served proxy remains the source of the document.
instance (KnownSymbol name, KnownSymbol description, ToParamSchema a) => ToResponseHeader (DescHeader name description a) where
  toResponseHeader _ =
    ( T.pack (symbolVal (Proxy @name)),
      mempty
        & O.description ?~ T.pack (symbolVal (Proxy @description))
        & O.schema ?~ O.Inline (toParamSchema (Proxy @a))
    )

instance (ToResponseHeader header) => ToResponseHeader (OptHeader header) where
  toResponseHeader _ = toResponseHeader (Proxy @header)

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

instance ToSchema MfaCompleteRequest

instance ToSchema TotpEnrollResponse

instance ToSchema TotpVerifyRequest

instance ToSchema TotpRemoveRequest

instance ToSchema RecoveryCodesResponse

instance ToSchema RecoveryCodesCountResponse

instance ToSchema PasskeyRegisterBeginResponse

instance ToSchema PasskeyRegisterCompleteRequest

instance ToSchema PasskeyResponse

instance ToSchema PasskeyLoginBeginResponse

instance ToSchema PasskeyLoginCompleteRequest

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
                ("scope", O.Inline (stringSchema & O.description ?~ "The space-delimited scopes actually granted.")),
                ( "refresh_token",
                  O.Inline
                    ( stringSchema
                        & O.description
                          ?~ "The rotating opaque refresh token. Present for the authorization_code and \
                             \refresh_token grants; omitted for client_credentials, whose tokens are \
                             \deliberately refresh-less."
                    )
                ),
                ( "id_token",
                  O.Inline
                    ( stringSchema
                        & O.description
                          ?~ "The signed OIDC ID token. Present exactly when the granted scopes include \
                             \`openid`. Its `aud` is the client_id, not the API audience: it is a \
                             \statement to the client, never a bearer credential."
                    )
                ),
                ( "issued_token_type",
                  O.Inline
                    ( stringSchema
                        & O.description
                          ?~ "RFC 8693 §2.2.1: the issued token's type URN. Present only on a \
                             \token-exchange response, where it is always \
                             \`urn:ietf:params:oauth:token-type:access_token`; omitted on every \
                             \other grant."
                    )
                )
              ]
          -- The three optional members are omitted rather than null when they do not apply, so they
          -- are documented as not required.
          & O.required .~ ["access_token", "token_type", "expires_in", "scope"]

-- | The @application\/x-www-form-urlencoded@ request body of @POST \/oauth\/token@.
--
-- The endpoint takes a raw 'Form' rather than a typed record, because it is a @grant_type@
-- dispatcher whose parameter set differs per grant (see "Shomei.Servant.Api"). The schema is
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
              [ ( "grant_type",
                  O.Inline
                    ( stringSchema
                        & O.enum_
                          ?~ [ String "client_credentials",
                               String "authorization_code",
                               String "refresh_token",
                               String "urn:ietf:params:oauth:grant-type:token-exchange"
                             ]
                    )
                ),
                ("scope", O.Inline stringSchema),
                ("client_id", O.Inline stringSchema),
                ("client_secret", O.Inline stringSchema),
                ("subject_token", O.Inline stringSchema),
                ("subject_token_type", O.Inline stringSchema),
                ("actor_token", O.Inline stringSchema),
                ("actor_token_type", O.Inline stringSchema),
                ("requested_token_type", O.Inline stringSchema)
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

-- | 'MfaProof' uses a hand-written discriminator and flat payload fields. Keep its schema
-- aligned with that exact representation rather than Generic's constructor encoding.
instance ToSchema MfaProof where
  declareNamedSchema _ = do
    assertionRef <- O.declareSchemaRef (Proxy :: Proxy Value)
    let stringProp = O.Inline stringSchema
        tagged tag payloadName payloadSchema =
          mempty
            & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.properties
              .~ IOHM.fromList
                [ ("type", O.Inline (stringSchema & O.enum_ ?~ [String tag])),
                  (payloadName, payloadSchema)
                ]
            & O.required .~ ["type", payloadName]
            & O.additionalProperties ?~ O.AdditionalPropertiesAllowed False
        passkeyBranch = tagged "passkey" "assertion" assertionRef
        totpBranch = tagged "totp" "code" stringProp
        recoveryBranch = tagged "recovery_code" "code" stringProp
    pure $
      O.NamedSchema (Just "MfaProof") $
        mempty & O.oneOf ?~ map O.Inline [passkeyBranch, totpBranch, recoveryBranch]

-- | 'LoginResponse' has a hand-written, @status@-tagged 'ToJSON' (a completed
-- login vs. an MFA challenge), so its schema is hand-written to match: a @oneOf@
-- of the two flat object shapes. Generic derivation would not reproduce the
-- custom JSON. This must agree with 'Shomei.Session.Dto.LoginResponse''s
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
        stringArrayProp =
          O.Inline
            ( mempty
                & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiArray
                & O.items ?~ O.OpenApiItemsObject stringProp
            )
        mfaBranch =
          mempty
            & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.properties
              .~ IOHM.fromList
                [ ("status", stringProp),
                  ("ceremonyId", stringProp),
                  ("options", optionsRef),
                  ("methods", stringArrayProp)
                ]
            & O.required .~ ["status", "ceremonyId", "options", "methods"]
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

instance ToParamSchema AuditUserId where
  toParamSchema _ = stringSchema

instance ToParamSchema AuditSessionId where
  toParamSchema _ = stringSchema

instance ToParamSchema AuditTimestamp where
  toParamSchema _ = stringSchema & O.format ?~ "date-time"

instance ToParamSchema AuditPageCursor where
  toParamSchema _ = stringSchema

instance ToParamSchema AdminStatusFilter where
  toParamSchema _ = stringSchema & O.enum_ ?~ ["active", "suspended", "deleted"]

instance ToParamSchema UserPageCursor where
  toParamSchema _ = stringSchema

-- ---------------------------------------------------------------------------
-- HasOpenApi for the custom combinators (none ship in servant-openapi-hs)
-- ---------------------------------------------------------------------------

-- | Register an HTTP bearer-JWT
-- security scheme in @components@ and require it on every operation of the
-- sub-API.
instance (HasOpenApi sub) => HasOpenApi (Authenticated :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @AuthenticationPreHandlerResponses) (requireBearer (Proxy :: Proxy sub))

-- | 'RequireRole' and 'RequireScope' authenticate the caller themselves (they run the same
-- 'Shomei.Servant.Auth.authHandler' 'Authenticated' does) and then check a claim. To a client
-- reading the spec that is the same contract — present a bearer token — plus a 403 if the
-- token lacks the role or scope. So both describe themselves exactly as 'Authenticated' does.
--
-- These must not be transparent pass-throughs: an operation carrying only 'RequireRole' would
-- otherwise be documented as unauthenticated, and generated clients would omit the token.
instance (HasOpenApi sub) => HasOpenApi (RequireRole (r :: Symbol) :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @AuthorizationPreHandlerResponses) (requireBearer (Proxy :: Proxy sub))

instance (HasOpenApi sub) => HasOpenApi (RequireScope (s :: Symbol) :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @AuthorizationPreHandlerResponses) (requireBearer (Proxy :: Proxy sub))

instance (HasOpenApi sub) => HasOpenApi (RequirePermission (p :: Symbol) :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @AuthorizationPreHandlerResponses) (requireBearer (Proxy :: Proxy sub))

instance (HasOpenApi sub) => HasOpenApi (RequireAdmin :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @AuthorizationPreHandlerResponses) (requireBearer (Proxy :: Proxy sub))

instance (HasOpenApi sub, IsSwaggerResponseList '[JSON] responses) => HasOpenApi (PreHandlerResponses responses :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @responses) (toOpenApi (Proxy :: Proxy sub))

instance (HasOpenApi sub) => HasOpenApi (CsrfProtected :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @CsrfPreHandlerResponses) (toOpenApi (Proxy :: Proxy sub))

instance (HasOpenApi sub) => HasOpenApi (RateLimited :> sub) where
  toOpenApi _ = addTypedResponses (Proxy @RateLimitPreHandlerResponses) (toOpenApi (Proxy :: Proxy sub))

-- | Add the responses a combinator can produce before its sub-handler runs. Operation-owned
-- alternatives are left-biased when a status overlaps, while otherwise-missing statuses and the
-- declared Problem Details schema are supplied from servant-openapi-hs's MultiVerb machinery.
addTypedResponses :: forall responses. (IsSwaggerResponseList '[JSON] responses) => Proxy responses -> O.OpenApi -> O.OpenApi
addTypedResponses _ spec =
  spec
    & O.components . O.schemas <>~ schemaDefinitions
    & O.allOperations . O.responses . O.responses
      %~ (`IOHM.union` (O.Inline <$> typedResponses))
  where
    (schemaDefinitions, typedResponses) =
      runDeclare (responseListSwagger @_ @'[JSON] @responses) mempty

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

stringSchema :: O.Schema
stringSchema = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

-- ---------------------------------------------------------------------------
-- Spec hygiene: the bits servant-openapi-hs cannot know
-- ---------------------------------------------------------------------------

-- | Three corrections servant-openapi-hs's generic derivation cannot make on its own.
--
-- (a) A @204@, and a @200@\/@202@ whose body is servant's 'NoContent', is generated with a
-- @content@ map holding one media type and no schema. On a @204@ that is /invalid/ OpenAPI;
-- everywhere else it is noise that makes a generated client expect a body. Both are dropped.
--
-- (b) @description@ is REQUIRED on a response object, and servant-openapi-hs leaves it @""@ for
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

    -- The catch-all renders the WIRE form of the key: 'O.HttpStatusCode' is a data type as of
    -- openapi-hs 4.1, so its 'show' would emit @StatusCode 500@ rather than @500@.
    describeStatus = \case
      200 -> "Success."
      201 -> "Created."
      202 -> "Accepted: the request was validated; delivery happens out of band."
      204 -> "Success; no response body."
      O.StatusCode n -> "Response " <> T.pack (show n) <> "."
      O.StatusRange r -> "Responses in the " <> rangeKey r <> " class."

    rangeKey = \case
      O.R1XX -> "1XX"
      O.R2XX -> "2XX"
      O.R3XX -> "3XX"
      O.R4XX -> "4XX"
      O.R5XX -> "5XX"

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
      ?~ "Authentication, session, passkey, MFA, delegation, and token API for the Shōmei auth service."
    & O.servers .~ [localServer]
    & withOperationIds
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
-- @servant-openapi-hs@'s reference generator.
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
