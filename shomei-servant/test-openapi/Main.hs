{-# OPTIONS_GHC -Wno-missing-signatures -Wno-orphans #-}

-- | EP-27 M4 — OpenAPI 3.1 conformance for the served tree, 'Shomei.Servant.Api.ShomeiRoutes'.
--
-- Three layers:
--
--   1. 'validateEveryToJSON' — for every JSON body type in the API, generate
--      arbitrary values and check their 'ToJSON' encoding validates against the
--      generated 'ToSchema'. This is what catches schema/JSON drift, including
--      the hand-written 'LoginResponse' @oneOf@ and the free-form 'Value' fields.
--
--   2. Smoke assertions on the assembled 'shomeiOpenApi': the @openapi@ version
--      is @3.1.0@ and the document covers the expected number of paths.
--
--   3. EP-3: the error surface. Every documented error code exists in the runtime
--      'problemCatalog' at the documented status, so the spec cannot promise a code or a
--      status the server never sends; and the document 'Shomei.Servant.Error.problemBody'
--      actually writes for every catalog entry validates against the published @Problem@
--      schema, so the two halves of the envelope cannot drift apart. Plus the hygiene
--      invariants a generated client depends on: no @204@ carries content, no response
--      description is empty, every request body is required, and every authenticated
--      operation documents its @401@.
--
-- The 'Arbitrary' and 'Show' instances for the DTOs live here (orphans, test
-- only) so the production library carries no test dependency.
module Main (main) where

import Control.Monad (filterM)
import Data.Aeson (Result (..), ToJSON (..), Value (..), decode, eitherDecode, encode, fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAsciiLower, isDigit)
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Kind (Type)
import Data.List (nub, sort)
import Data.Maybe (isJust)
import Data.OpenApi (NamedSchema (..), Schema, ToSchema (..), validateJSON)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Type.Equality ((:~:) (Refl))
import GHC.TypeLits (Nat)
import Servant.API (NamedRoutes, NoContent (..), Verb, type (:>))
import Servant.API.MultiVerb (MultiVerb, Respond, RespondAs, WithHeaders)
import Servant.Health (ProbeResponses, ProbeStatus (..))
import Servant.OpenApi.Test (validateEveryToJSON)
import Servant.Server (ServerError (..))
import Shomei.Account.Admin.Api
import Shomei.Account.Api
import Shomei.Account.Dto
import Shomei.Account.User.Dto
import Shomei.Audit.Api
import Shomei.Audit.Dto
import Shomei.Authorization.Api
import Shomei.Mfa.Api
import Shomei.Mfa.Dto
import Shomei.OAuth.Api
import Shomei.Passkey.Api
import Shomei.Passkey.Dto
import Shomei.Servant.Api (OpenApiRoute, ShomeiRoutes)
import Shomei.Servant.Error (ProblemDetails (..), ProblemSpec (..), detailOccurrence, noProblemOccurrence, problemBody, problemCatalog, problemDetails, problemTypeFor, toProblemError)
import Shomei.Servant.OAuth (OAuthErrorResponse (..), TokenResponse (..))
import Shomei.Servant.OpenApi (shomeiOpenApi)
import Shomei.Session.Admin.Api
import Shomei.Session.Api
import Shomei.Session.Dto
import Shomei.SigningKey.Api
import System.Directory (doesFileExist)
import Test.Hspec
import Test.QuickCheck (Arbitrary (..), chooseInt, oneof)
import Test.QuickCheck.Instances ()

-- | @logout@ answers @204@ with @Set-Cookie@ headers. Servant models a header-carrying empty
-- response as a JSON-typed 'NoContent' body ('NoContentVerb' cannot carry headers), so
-- 'validateEveryToJSON' needs to generate and encode one. Test-only orphans; the wire response
-- is a genuine @204@ with no body.
instance Arbitrary NoContent where
  arbitrary = pure NoContent

-- Encoded as an empty object so it validates against the empty schema below. Nothing is
-- serialized on the wire: a 204 carries no body, and servant renders 'NoContent' as "".
instance ToJSON NoContent where
  toJSON NoContent = Object mempty

instance ToSchema NoContent where
  declareNamedSchema _ = pure (NamedSchema (Just "NoContent") mempty)

instance Arbitrary ProbeStatus where
  arbitrary = ProbeStatus <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary ProblemDetails where
  arbitrary =
    ProblemDetails
      <$> pure "https://example.test/problems/example"
      <*> arbitrary
      <*> chooseInt (100, 599)
      <*> arbitrary
      <*> pure (Just "/requests/example")
      <*> arbitrary
      <*> arbitrary

instance Arbitrary OAuthErrorResponse where
  arbitrary = OAuthErrorResponse <$> arbitrary <*> arbitrary

data OutcomeModel = SingleOutcome | MultiOutcome

type ResponseModel :: Type -> OutcomeModel
type family ResponseModel route where
  ResponseModel (_ :> route) = ResponseModel route
  ResponseModel (MultiVerb method content responses result) = 'MultiOutcome
  ResponseModel (Verb method status content body) = 'SingleOutcome

type ResponseOwnsStatus :: Nat -> Type -> Bool
type family ResponseOwnsStatus status response where
  ResponseOwnsStatus status (Respond status description body) = 'True
  ResponseOwnsStatus status (Respond other description body) = 'False
  ResponseOwnsStatus status (RespondAs content status description body) = 'True
  ResponseOwnsStatus status (RespondAs content other description body) = 'False
  ResponseOwnsStatus status (WithHeaders headers result response) = ResponseOwnsStatus status response

type ResponsesOwnStatus :: Nat -> [Type] -> Bool
type family ResponsesOwnStatus status responses where
  ResponsesOwnStatus status '[] = 'False
  ResponsesOwnStatus status (response ': responses) = Or (ResponseOwnsStatus status response) (ResponsesOwnStatus status responses)

type Or :: Bool -> Bool -> Bool
type family Or left right where
  Or 'True right = 'True
  Or 'False right = right

type OperationOwnsStatus :: Nat -> Type -> Bool
type family OperationOwnsStatus status route where
  OperationOwnsStatus status (_ :> route) = OperationOwnsStatus status route
  OperationOwnsStatus status (MultiVerb method content responses result) = ResponsesOwnStatus status responses

type Classified route =
  ( ResponseModel route :~: 'MultiOutcome,
    OperationOwnsStatus 503 route :~: 'True
  )

accountWitnesses =
  ( (Refl, Refl) :: Classified SignupRoute,
    (Refl, Refl) :: Classified VerifyEmailRequestRoute,
    (Refl, Refl) :: Classified VerifyEmailConfirmRoute,
    (Refl, Refl) :: Classified PasswordResetRequestRoute,
    (Refl, Refl) :: Classified PasswordResetConfirmRoute,
    (Refl, Refl) :: Classified PasswordChangeRoute,
    (Refl, Refl) :: Classified MeRoute,
    (Refl, Refl) :: Classified ListUsersRoute,
    (Refl, Refl) :: Classified GetUserRoute,
    (Refl, Refl) :: Classified SuspendUserRoute,
    (Refl, Refl) :: Classified ReinstateUserRoute,
    (Refl, Refl) :: Classified DeleteUserRoute,
    (Refl, Refl) :: Classified AdminPasswordResetRoute
  )

sessionWitnesses =
  ( (Refl, Refl) :: Classified LoginRoute,
    (Refl, Refl) :: Classified RefreshRoute,
    (Refl, Refl) :: Classified LogoutRoute,
    (Refl, Refl) :: Classified CurrentSessionRoute,
    (Refl, Refl) :: Classified ListSessionsRoute,
    (Refl, Refl) :: Classified RevokeSessionsRoute,
    (Refl, Refl) :: Classified RevokeSessionRoute
  )

passkeyWitnesses =
  ( (Refl, Refl) :: Classified RegisterBeginRoute,
    (Refl, Refl) :: Classified RegisterCompleteRoute,
    (Refl, Refl) :: Classified ListPasskeysRoute,
    (Refl, Refl) :: Classified RemovePasskeyRoute,
    (Refl, Refl) :: Classified PasskeyLoginBeginRoute,
    (Refl, Refl) :: Classified PasskeyLoginCompleteRoute
  )

mfaWitnesses =
  ( (Refl, Refl) :: Classified MfaCompleteRoute,
    (Refl, Refl) :: Classified TotpEnrollRoute,
    (Refl, Refl) :: Classified TotpVerifyRoute,
    (Refl, Refl) :: Classified TotpDeleteRoute,
    (Refl, Refl) :: Classified RecoveryCodesGenerateRoute,
    (Refl, Refl) :: Classified RecoveryCodesCountRoute
  )

otherMultiWitnesses =
  ( (Refl, Refl) :: Classified AuditEventsRoute,
    (Refl, Refl) :: Classified GrantRoleRoute,
    (Refl, Refl) :: Classified RevokeRoleRoute,
    (Refl, Refl) :: Classified AuthorizeRoute,
    (Refl, Refl) :: Classified TokenRoute,
    (Refl, Refl) :: Classified UserinfoRoute,
    (Refl, Refl) :: Classified IntrospectRoute,
    (Refl, Refl) :: Classified RevokeRoute,
    (Refl, Refl) :: Classified OidcDiscoveryRoute
  )

ordinaryWitnesses =
  ( Refl :: ResponseModel JwksRoute :~: 'SingleOutcome,
    Refl :: ResponseModel OpenApiRoute :~: 'SingleOutcome
  )

health503Witness :: ResponsesOwnStatus 503 ProbeResponses :~: 'True
health503Witness = Refl

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  problemCatalogDocument <- runIO do
    let candidates = ["docs/user/problem-details.md", "../docs/user/problem-details.md"]
    existing <- filterM doesFileExist candidates
    case existing of
      path : _ -> TextIO.readFile path
      [] -> fail "docs/user/problem-details.md not found"

  describe "OpenAPI 3.1 schema: ToJSON matches ToSchema" $
    validateEveryToJSON (Proxy :: Proxy (NamedRoutes ShomeiRoutes))

  describe "strict authentication request decoding" $ do
    it "requires methods on the MFA login-response arm" $
      (eitherDecode "{\"status\":\"mfa_required\",\"ceremonyId\":\"c\",\"options\":{}}" :: Either String LoginResponse)
        `shouldSatisfy` isLeft

    it "rejects the removed flat MFA completion shape" $
      (eitherDecode "{\"ceremonyId\":\"c\",\"totpCode\":\"123456\"}" :: Either String MfaCompleteRequest)
        `shouldSatisfy` isLeft

    it "rejects extra proof arms in a tagged MFA proof" $
      (eitherDecode "{\"type\":\"totp\",\"code\":\"123456\",\"assertion\":{}}" :: Either String MfaProof)
        `shouldSatisfy` isLeft

  describe "shomeiOpenApi document" $ do
    it "declares OpenAPI version 3.1.0" $
      lookupTop "openapi" `shouldBe` Just (String "3.1.0")

    it "covers exactly 41 paths" $
      pathCount `shouldBe` 41

    it "covers the exact served method and path inventory" $
      sort (map fst operations) `shouldBe` expectedOperations

    -- 'ResponseModel' has no 'MultiVerb1' equation. Replacing any named route witness below
    -- with MultiVerb1 therefore makes this module fail to compile rather than silently pass.
    it "rejects MultiVerb1, keeps the exact ordinary allow-list, and gives every other JSON route an operation-owned 503" $
      accountWitnesses `seq`
        sessionWitnesses `seq`
          passkeyWitnesses `seq`
            mfaWitnesses `seq`
              otherMultiWitnesses `seq`
                ordinaryWitnesses `seq`
                  health503Witness `seq`
                    True `shouldBe` True

  describe "EP-4: /oauth/token speaks RFC 6749 behind a problem-details edge throttle" $ do
    it "declares the OAuthErrorResponse schema" $
      (lookupTop "components" >>= field "schemas" >>= field "OAuthErrorResponse") `shouldSatisfy` isJust

    -- Handler-owned failures stay in the shape a stock OAuth2 client parses. The sole exception
    -- is 429: the edge limiter answers before routing and therefore uses the shared problem
    -- document (with Retry-After), exactly as the runtime middleware does.
    it "documents only the edge 429 as problem+json on /oauth/token" $
      [ Key.toText status
      | (path, Object item) <- KM.toList paths,
        path == "/oauth/token",
        (_, Object op) <- KM.toList item,
        (status, resp) <- responsesOf op,
        isProblemResponse resp
      ]
        `shouldBe` ["429"]

    it "documents the protocol-owned error statuses" $
      responseStatusesAt "/oauth/token" `shouldBe` ["200", "400", "401", "404", "429", "500", "503"]

  describe "EP-5: the OIDC discovery document is on the OAuth side of the envelope boundary" $ do
    -- Reached by OIDC tooling, so its "provider disabled" refusal must be a shape that tooling
    -- parses. The OIDC route's protocol response list is the sole source of the alternative.
    it "documents no problem+json response on /.well-known/openid-configuration" $
      [ Key.toText status
      | (path, Object item) <- KM.toList paths,
        path == "/.well-known/openid-configuration",
        (_, Object op) <- KM.toList item,
        (status, resp) <- responsesOf op,
        isProblemResponse resp
      ]
        `shouldBe` []

    it "documents the 404 it answers when the provider is disabled" $
      "404" `shouldSatisfy` (`elem` responseStatusesAt "/.well-known/openid-configuration")

  describe "EP-5: /oauth/userinfo authenticates inside the OAuth envelope" $ do
    it "requires bearer authentication" $
      (requiresBearer <$> lookup "get /oauth/userinfo" operations) `shouldBe` Just True

    it "documents only OAuth JSON failures, never application problems" $
      [ Key.toText status
      | (path, Object item) <- KM.toList paths,
        path == "/oauth/userinfo",
        (_, Object op) <- KM.toList item,
        (status, resp) <- responsesOf op,
        isProblemResponse resp
      ]
        `shouldBe` []

  describe "EP-5: /oauth/authorize speaks RFC 6749, and only its no-redirect failures are statuses" $ do
    it "documents no problem+json response on /oauth/authorize" $
      [ Key.toText status
      | (path, Object item) <- KM.toList paths,
        path == "/oauth/authorize",
        (_, Object op) <- KM.toList item,
        (status, resp) <- responsesOf op,
        isProblemResponse resp
      ]
        `shouldBe` []

    -- Every OTHER authorize failure -- bad response_type, PKCE policy, disallowed scope -- is a
    -- 302 back to the validated redirect_uri, so it is not a status this operation declares.
    it "documents only protocol statuses rather than redirect query error values" $
      responseStatusesAt "/oauth/authorize" `shouldBe` ["302", "400", "401", "404", "500", "503"]

  describe "EP-3: the error surface cannot drift from the runtime catalog" $ do
    it "declares the ProblemDetails schema with the RFC 9457 profile members" $
      problemRequired `shouldBe` ["code", "retryable", "status", "title", "type"]

    -- The published schema and the bytes the server writes come from different code
    -- (`problemSchema` in OpenApi.hs, `problemBody` in Error.hs). Validate the real runtime
    -- document of every catalog entry, with and without a `detail`, against the schema as it
    -- appears in the serialized document — the artifact a client generator actually reads.
    it "validates the real runtime document of every catalog entry against the published Problem schema" $
      [ (problemCode p, isJust detail, errs)
      | p <- problemCatalog,
        detail <- [Nothing, Just "a request-specific explanation"],
        let occurrence = maybe noProblemOccurrence detailOccurrence detail,
        let errs = validateJSON mempty publishedProblemSchema (problemBody p occurrence),
        not (null errs)
      ]
        `shouldBe` []

    it "keeps body status, type, code, title, and retryability synchronized" $
      [ p.problemCode
      | p <- problemCatalog,
        let body = problemDetails p noProblemOccurrence,
        body.status /= errHTTPCode p.problemStatus
          || body.problemType /= problemTypeFor p.problemCode
          || body.code /= p.problemCode
          || body.title /= p.problemTitle
          || body.retryable /= p.problemRetryable
      ]
        `shouldBe` []

    it "uses a URI-safe code alphabet and a one-to-one type/code mapping" $ do
      [p.problemCode | p <- problemCatalog, Text.any (\c -> not (isAsciiLower c || isDigit c || c == '_')) p.problemCode] `shouldBe` []
      length (nub (map (problemTypeFor . problemCode) problemCatalog))
        `shouldBe` length (nub (map problemCode problemCatalog))

    it "documents an explicit public anchor for every code" $
      [p.problemCode | p <- problemCatalog, not (Text.isInfixOf ("id=\"" <> p.problemCode <> "\"") problemCatalogDocument)]
        `shouldBe` []

    it "renders matching RFC 9457 bodies and media types at the pre-handler boundary" $
      [ p.problemCode
      | p <- problemCatalog,
        let rendered = toProblemError p noProblemOccurrence,
        lookup "Content-Type" rendered.errHeaders /= Just "application/problem+json"
          || (decode rendered.errBody :: Maybe ProblemDetails) /= Just (problemDetails p noProblemOccurrence)
      ]
        `shouldBe` []

    it "decodes unknown RFC 9457 extension members" $
      (eitherDecode "{\"type\":\"https://example.test/problem\",\"title\":\"Example\",\"status\":400,\"code\":\"example\",\"retryable\":false,\"future\":true}" :: Either String ProblemDetails)
        `shouldSatisfy` either (const False) (const True)

    it "documents a 401 on every operation that requires a bearer token" $
      [key | (key, op) <- operations, requiresBearer op, not (declares "401" op)] `shouldBe` []

  describe "EP-3: spec hygiene a generated client depends on" $ do
    it "puts no content on a 204" $
      [key | (key, op) <- operations, responseHasContent "204" op] `shouldBe` []

    it "gives every response a non-empty description" $
      [key <> " " <> status | (key, op) <- operations, status <- emptyDescriptions op] `shouldBe` []

    it "marks every request body required" $
      [key | (key, op) <- operations, Just body <- [KM.lookup "requestBody" op], not (isRequired body)] `shouldBe` []
  where
    decoded :: KM.KeyMap Value
    decoded = case decode (encode shomeiOpenApi) of
      Just (Object o) -> o
      _ -> error "shomeiOpenApi did not encode to a JSON object"

    lookupTop k = KM.lookup k decoded

    paths = case lookupTop "paths" of
      Just (Object ps) -> ps
      _ -> error "shomeiOpenApi has no paths object"

    pathCount = KM.size paths

    problemSchemaJson = case lookupTop "components" >>= field "schemas" >>= field "ProblemDetails" of
      Just v -> v
      Nothing -> error "shomeiOpenApi has no components.schemas.ProblemDetails"

    -- Round-tripped through the serialized document on purpose: this is the schema a client
    -- generator reads, not the Haskell value that produced it.
    publishedProblemSchema :: Schema
    publishedProblemSchema = case fromJSON problemSchemaJson of
      Success s -> s
      Error e -> error ("components.schemas.Problem does not decode as a Schema: " <> e)

    problemRequired = case field "required" problemSchemaJson of
      Just (Array xs) -> sort [t | String t <- toList xs]
      _ -> error "shomeiOpenApi has no components.schemas.Problem.required"

    -- Every (method, path) operation object in the document, labelled for failure messages.
    operations :: [(Text, KM.KeyMap Value)]
    operations =
      [ (Key.toText method <> " " <> Key.toText path, op)
      | (path, Object item) <- KM.toList paths,
        (method, Object op) <- KM.toList item,
        method `elem` operationMethods
      ]

    operationMethods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    expectedOperations =
      sort
        [ "delete /v1/admin/sessions/{sessionId}",
          "delete /v1/admin/users/{userId}",
          "delete /v1/admin/users/{userId}/roles/{role}",
          "delete /v1/admin/users/{userId}/sessions",
          "delete /v1/auth/passkeys/{passkeyId}",
          "delete /v1/auth/totp",
          "get /.well-known/jwks.json",
          "get /.well-known/openid-configuration",
          "get /health/live",
          "get /health/ready",
          "get /oauth/authorize",
          "get /oauth/userinfo",
          "get /openapi.json",
          "get /v1/admin/audit/events",
          "get /v1/admin/users",
          "get /v1/admin/users/{userId}",
          "get /v1/admin/users/{userId}/sessions",
          "get /v1/auth/me",
          "get /v1/auth/passkeys",
          "get /v1/auth/recovery-codes",
          "get /v1/auth/session",
          "post /oauth/introspect",
          "post /oauth/revoke",
          "post /oauth/token",
          "post /v1/admin/users/{userId}/password-reset",
          "post /v1/admin/users/{userId}/reinstate",
          "post /v1/admin/users/{userId}/suspend",
          "post /v1/auth/login",
          "post /v1/auth/login/passkey/begin",
          "post /v1/auth/login/passkey/complete",
          "post /v1/auth/logout",
          "post /v1/auth/mfa/complete",
          "post /v1/auth/passkeys/register/begin",
          "post /v1/auth/passkeys/register/complete",
          "post /v1/auth/password-reset/confirm",
          "post /v1/auth/password-reset/request",
          "post /v1/auth/password/change",
          "post /v1/auth/recovery-codes",
          "post /v1/auth/refresh",
          "post /v1/auth/signup",
          "post /v1/auth/totp/enroll",
          "post /v1/auth/totp/verify",
          "post /v1/auth/verify-email/confirm",
          "post /v1/auth/verify-email/request",
          "put /v1/admin/users/{userId}/roles/{role}"
        ]

    responsesOf op = case KM.lookup "responses" op of
      Just (Object rs) -> [(status, r) | (status, Object r) <- KM.toList rs]
      _ -> []

    isProblemResponse resp = KM.member "application/problem+json" (contentOf resp)

    responseStatusesAt wanted =
      sort
        [ Key.toText status
        | (path, Object item) <- KM.toList paths,
          path == wanted,
          (_, Object op) <- KM.toList item,
          (status, _) <- responsesOf op
        ]

    contentOf resp = case KM.lookup "content" resp of
      Just (Object c) -> c
      _ -> KM.empty

    requiresBearer op = case KM.lookup "security" op of
      Just (Array xs) -> not (null xs)
      _ -> False

    declares status op = any ((== Key.fromText status) . fst) (responsesOf op)

    responseHasContent status op =
      or [KM.member "content" r | (s, r) <- responsesOf op, s == Key.fromText status]

    emptyDescriptions op =
      [ Key.toText status
      | (status, r) <- responsesOf op,
        KM.lookup "description" r `elem` [Nothing, Just (String "")]
      ]

    isRequired body = field "required" body == Just (Bool True)

    field :: Text -> Value -> Maybe Value
    field k = \case
      Object o -> KM.lookup (Key.fromText k) o
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- Show instances (needed by validateEveryToJSON for counterexamples)
-- ---------------------------------------------------------------------------

deriving stock instance Show SignupRequest

deriving stock instance Show SignupResponse

deriving stock instance Show LoginRequest

deriving stock instance Show LoginResponse

deriving stock instance Show RefreshRequest

deriving stock instance Show VerifyEmailRequest

deriving stock instance Show ConfirmEmailVerificationRequest

deriving stock instance Show PasswordResetRequest

deriving stock instance Show ConfirmPasswordResetRequest

deriving stock instance Show ChangePasswordRequest

deriving stock instance Show TokenPairResponse

deriving stock instance Show UserResponse

deriving stock instance Show SessionResponse

deriving stock instance Show AdminUserResponse

deriving stock instance Show AdminUsersPage

deriving stock instance Show MfaCompleteRequest

deriving stock instance Show MfaProof

deriving stock instance Show TotpEnrollResponse

deriving stock instance Show TotpVerifyRequest

deriving stock instance Show TotpRemoveRequest

deriving stock instance Show RecoveryCodesResponse

deriving stock instance Show RecoveryCodesCountResponse

deriving stock instance Show PasskeyRegisterBeginResponse

deriving stock instance Show PasskeyRegisterCompleteRequest

deriving stock instance Show PasskeyResponse

deriving stock instance Show PasskeyLoginBeginResponse

deriving stock instance Show PasskeyLoginCompleteRequest

deriving stock instance Show AuditEventResponse

deriving stock instance Show AuditEventsPage

-- ---------------------------------------------------------------------------
-- Arbitrary instances (Text/Value come from quickcheck-instances)
-- ---------------------------------------------------------------------------

instance Arbitrary SignupRequest where
  arbitrary = SignupRequest <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary UserResponse where
  arbitrary = UserResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary TokenPairResponse where
  arbitrary = TokenPairResponse <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary SignupResponse where
  arbitrary = SignupResponse <$> arbitrary <*> arbitrary

instance Arbitrary LoginRequest where
  arbitrary = LoginRequest <$> arbitrary <*> arbitrary

instance Arbitrary LoginResponse where
  arbitrary =
    oneof
      [ LoginCompleteResponse <$> arbitrary <*> arbitrary,
        LoginMfaRequiredResponse <$> arbitrary <*> arbitrary <*> arbitrary
      ]

instance Arbitrary RefreshRequest where
  arbitrary = RefreshRequest <$> arbitrary

instance Arbitrary VerifyEmailRequest where
  arbitrary = VerifyEmailRequest <$> arbitrary

instance Arbitrary ConfirmEmailVerificationRequest where
  arbitrary = ConfirmEmailVerificationRequest <$> arbitrary

instance Arbitrary PasswordResetRequest where
  arbitrary = PasswordResetRequest <$> arbitrary

instance Arbitrary ConfirmPasswordResetRequest where
  arbitrary = ConfirmPasswordResetRequest <$> arbitrary <*> arbitrary

instance Arbitrary ChangePasswordRequest where
  arbitrary = ChangePasswordRequest <$> arbitrary <*> arbitrary

instance Arbitrary MfaCompleteRequest where
  arbitrary = MfaCompleteRequest <$> arbitrary <*> arbitrary

instance Arbitrary MfaProof where
  arbitrary = oneof [PasskeyProof <$> arbitrary, TotpProof <$> arbitrary, RecoveryCodeProof <$> arbitrary]

instance Arbitrary TotpEnrollResponse where
  arbitrary = TotpEnrollResponse <$> arbitrary <*> arbitrary

instance Arbitrary TotpVerifyRequest where
  arbitrary = TotpVerifyRequest <$> arbitrary

instance Arbitrary TotpRemoveRequest where
  arbitrary = TotpRemoveRequest <$> arbitrary <*> arbitrary

instance Arbitrary RecoveryCodesResponse where
  arbitrary = RecoveryCodesResponse <$> arbitrary

instance Arbitrary RecoveryCodesCountResponse where
  arbitrary = RecoveryCodesCountResponse <$> arbitrary

instance Arbitrary PasskeyRegisterBeginResponse where
  arbitrary = PasskeyRegisterBeginResponse <$> arbitrary <*> arbitrary

instance Arbitrary PasskeyRegisterCompleteRequest where
  arbitrary = PasskeyRegisterCompleteRequest <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary PasskeyResponse where
  arbitrary = PasskeyResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary PasskeyLoginBeginResponse where
  arbitrary = PasskeyLoginBeginResponse <$> arbitrary <*> arbitrary

instance Arbitrary PasskeyLoginCompleteRequest where
  arbitrary = PasskeyLoginCompleteRequest <$> arbitrary <*> arbitrary

instance Arbitrary TokenResponse where
  arbitrary = TokenResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary SessionResponse where
  arbitrary = SessionResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary AdminUserResponse where
  arbitrary = AdminUserResponse <$> arbitrary <*> arbitrary

instance Arbitrary AdminUsersPage where
  arbitrary = AdminUsersPage <$> arbitrary <*> arbitrary

instance Arbitrary AuditEventResponse where
  arbitrary =
    AuditEventResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary AuditEventsPage where
  arbitrary = AuditEventsPage <$> arbitrary <*> arbitrary
