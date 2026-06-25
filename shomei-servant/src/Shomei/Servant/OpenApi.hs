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

-- | The OpenAPI 3.1 description of 'Shomei.Servant.API.ShomeiAPI', derived
-- directly from the Servant types (EP-27).
--
-- 'shomeiOpenApi' is the complete, enriched document; the @shomei-openapi@
-- executable serialises it to @docs/api/openapi.json@. The instances below are
-- everything @toOpenApi (Proxy \@(NamedRoutes ShomeiAPI))@ needs to typecheck:
-- a 'ToSchema' per DTO, a free-form 'ToSchema' for aeson 'Value', a hand-written
-- 'ToSchema' for the tagged-union 'LoginResponse', a 'ToParamSchema' for the
-- 'PasskeyId' capture, and 'HasOpenApi' instances for the custom combinators.
module Shomei.Servant.OpenApi
  ( shomeiOpenApi,
  )
where

import Control.Lens
import Data.Aeson (Value)
import Data.Char (isAlphaNum, toUpper)
import Data.HashMap.Strict.InsOrd qualified as IOHM
import Data.OpenApi (ToParamSchema (..), ToSchema (..))
import Data.OpenApi qualified as O
import Data.Proxy (Proxy (..))
import Data.Text qualified as T
import GHC.TypeLits (Symbol)
import Servant.API
import Servant.OpenApi (HasOpenApi (..))
import Shomei.Id (PasskeyId)
import Shomei.Servant.API (ShomeiAPI)
import Shomei.Servant.Authz (RequireRole, RequireScope)
import Shomei.Servant.DTO
  ( AuditEventResponse,
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

-- | Free-form JSON. Several DTOs carry an aeson 'Value' (opaque WebAuthn/JWKS
-- payloads), and @openapi-hs@ ships no 'ToSchema' for it. The empty schema is
-- OpenAPI 3.1's "any JSON value", which is exactly right for these passthrough
-- fields.
instance ToSchema Value where
  declareNamedSchema _ = pure (O.NamedSchema (Just "AnyValue") mempty)

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

-- | 'PasskeyId' is a @KindID "passkey"@; its wire/capture form is a string.
instance ToParamSchema PasskeyId where
  toParamSchema _ = mempty & O.type_ ?~ O.OpenApiTypeSingle O.OpenApiString

-- ---------------------------------------------------------------------------
-- HasOpenApi for the custom combinators (none ship in servant-openapi)
-- ---------------------------------------------------------------------------

-- | @Authenticated = AuthProtect "shomei-jwt"@: register an HTTP bearer-JWT
-- security scheme in @components@ and require it on every operation of the
-- sub-API.
instance (HasOpenApi sub) => HasOpenApi (AuthProtect "shomei-jwt" :> sub) where
  toOpenApi _ =
    toOpenApi (Proxy :: Proxy sub)
      & O.components . O.securitySchemes
        <>~ O.SecurityDefinitions (IOHM.singleton "bearerAuth" bearerScheme)
      & O.allOperations . O.security
        %~ (O.SecurityRequirement (IOHM.singleton "bearerAuth" []) :)
    where
      bearerScheme =
        O.SecurityScheme
          (O.SecuritySchemeHttp (O.HttpSchemeBearer (Just "jwt")))
          (Just "JWT access token")

-- | 'RequireRole'/'RequireScope' are phantom (transparent to the schema). They
-- appear in the @AppAPI@ embedding example, not in 'ShomeiAPI' itself; the
-- instances are provided so the example can also be described later.
instance (HasOpenApi sub) => HasOpenApi (RequireRole (r :: Symbol) :> sub) where
  toOpenApi _ = toOpenApi (Proxy :: Proxy sub)

instance (HasOpenApi sub) => HasOpenApi (RequireScope (s :: Symbol) :> sub) where
  toOpenApi _ = toOpenApi (Proxy :: Proxy sub)

-- ---------------------------------------------------------------------------
-- The assembled, enriched document
-- ---------------------------------------------------------------------------

-- | The complete, enriched OpenAPI 3.1 document for the Shōmei auth service,
-- derived from 'ShomeiAPI'. Generated from @Proxy (NamedRoutes ShomeiAPI)@ — the
-- standalone contract @shomei-server@ actually serves.
shomeiOpenApi :: O.OpenApi
shomeiOpenApi =
  toOpenApi (Proxy :: Proxy (NamedRoutes ShomeiAPI))
    & O.info . O.title .~ "Shōmei Authentication API"
    & O.info . O.version .~ "0.1.0.0"
    & O.info . O.description
      ?~ "Authentication, session, passkey, MFA, impersonation, and token API for the Shōmei auth service."
    & O.servers .~ ["http://localhost:8080"]
    & withOperationIds

-- | Assign a stable @operationId@ to every operation, derived from its HTTP
-- method and path (e.g. @GET \/auth\/me@ → @getAuthMe@). Operations clients
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

-- | Turn a path like @"\/auth\/passkeys\/{passkeyId}"@ into @"AuthPasskeysPasskeyId"@.
camel :: FilePath -> T.Text
camel = T.pack . concatMap capitalize . words . map keepAlnum
  where
    keepAlnum c = if isAlphaNum c then c else ' '
    capitalize [] = []
    capitalize (c : cs) = toUpper c : cs
