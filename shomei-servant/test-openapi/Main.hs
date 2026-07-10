-- | EP-27 M4 — OpenAPI 3.1 conformance for the served tree, 'Shomei.Servant.API.ShomeiRoutes'.
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
--      status the server never sends. Plus the hygiene invariants a generated client depends
--      on: no @204@ carries content, no response description is empty, every request body is
--      required, and every authenticated operation documents its @401@.
--
-- The 'Arbitrary' and 'Show' instances for the DTOs live here (orphans, test
-- only) so the production library carries no test dependency.
{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Data.Aeson (ToJSON (..), Value (..), decode, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.List (nub, sort)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Servant.API (NamedRoutes, NoContent (..))
import Data.OpenApi (NamedSchema (..), ToSchema (..))
import Servant.OpenApi.Test (validateEveryToJSON)
import Servant.Server (ServerError (errHTTPCode))
import Shomei.Servant.API (ShomeiRoutes)
import Shomei.Servant.DTO
import Shomei.Servant.Error (ProblemSpec (..), problemCatalog)
import Shomei.Servant.OpenApi (shomeiOpenApi)
import Test.Hspec
import Test.QuickCheck (Arbitrary (..), oneof)
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

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "OpenAPI 3.1 schema: ToJSON matches ToSchema" $
    validateEveryToJSON (Proxy :: Proxy (NamedRoutes ShomeiRoutes))

  describe "shomeiOpenApi document" $ do
    it "declares OpenAPI version 3.1.0" $
      lookupTop "openapi" `shouldBe` Just (String "3.1.0")

    it "covers exactly 25 paths" $
      pathCount `shouldBe` 25

  describe "EP-3: the error surface cannot drift from the runtime catalog" $ do
    it "declares the Problem schema with exactly the four required members" $
      problemRequired `shouldBe` ["code", "status", "title", "type"]

    it "documents only error codes that exist in problemCatalog" $
      filter (`notElem` catalogCodes) (map snd documentedCodes) `shouldBe` []

    it "documents each error code at a status the runtime actually sends it with" $
      filter (`notElem` catalogPairs) documentedCodes `shouldBe` []

    it "documents at least one error code for every 4xx it declares" $
      [key | (key, codes) <- errorResponses, null codes] `shouldBe` []

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

    problemRequired = case lookupTop "components" >>= field "schemas" >>= field "Problem" >>= field "required" of
      Just (Array xs) -> sort [t | String t <- toList xs]
      _ -> error "shomeiOpenApi has no components.schemas.Problem.required"

    -- Every (method, path) operation object in the document, labelled for failure messages.
    operations :: [(Text, KM.KeyMap Value)]
    operations =
      [ (Key.toText method <> " " <> Key.toText path, op)
        | (path, Object item) <- KM.toList paths,
          (method, Object op) <- KM.toList item
      ]

    -- Every problem-document response: its operation label + status, and the `code` enum it
    -- narrows the Problem schema to.
    errorResponses :: [(Text, [Text])]
    errorResponses =
      [ (key <> " " <> Key.toText status, codeEnum resp)
        | (key, op) <- operations,
          (status, resp) <- responsesOf op,
          isProblemResponse resp
      ]

    -- (status, code) as the document promises them. Status keys are always numeric here:
    -- nothing in this document uses `default` or a `4XX` range key.
    documentedCodes :: [(Int, Text)]
    documentedCodes =
      nub
        [ (statusInt status, code)
          | (_, op) <- operations,
            (status, resp) <- responsesOf op,
            isProblemResponse resp,
            code <- codeEnum resp
        ]

    statusInt status = case reads (Key.toString status) of
      [(n, "")] -> n
      _ -> error ("non-numeric response key: " <> Key.toString status)

    catalogCodes :: [Text]
    catalogCodes = nub (map problemCode problemCatalog)

    catalogPairs :: [(Int, Text)]
    catalogPairs = nub [(errHTTPCode (problemStatus p), problemCode p) | p <- problemCatalog]

    responsesOf op = case KM.lookup "responses" op of
      Just (Object rs) -> [(status, r) | (status, Object r) <- KM.toList rs]
      _ -> []

    isProblemResponse resp = KM.member "application/problem+json" (contentOf resp)

    contentOf resp = case KM.lookup "content" resp of
      Just (Object c) -> c
      _ -> KM.empty

    codeEnum resp =
      case KM.lookup "application/problem+json" (contentOf resp)
        >>= field "schema"
        >>= field "properties"
        >>= field "code"
        >>= field "enum" of
        Just (Array xs) -> [t | String t <- toList xs]
        _ -> []

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

deriving stock instance Show HealthResponse

deriving stock instance Show ReadyResponse

deriving stock instance Show MfaCompleteRequest

deriving stock instance Show PasskeyRegisterBeginResponse

deriving stock instance Show PasskeyRegisterCompleteRequest

deriving stock instance Show PasskeyResponse

deriving stock instance Show PasskeyLoginBeginResponse

deriving stock instance Show PasskeyLoginCompleteRequest

deriving stock instance Show ImpersonateRequest

deriving stock instance Show ImpersonateResponse

deriving stock instance Show ServiceTokenRequest

deriving stock instance Show ServiceTokenResponse

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
  arbitrary = LoginRequest <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary LoginResponse where
  arbitrary =
    oneof
      [ LoginCompleteResponse <$> arbitrary <*> arbitrary,
        LoginMfaRequiredResponse <$> arbitrary <*> arbitrary
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

instance Arbitrary ImpersonateRequest where
  arbitrary = ImpersonateRequest <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary ImpersonateResponse where
  arbitrary = ImpersonateResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary ServiceTokenRequest where
  arbitrary = ServiceTokenRequest <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary ServiceTokenResponse where
  arbitrary = ServiceTokenResponse <$> arbitrary <*> arbitrary

instance Arbitrary SessionResponse where
  arbitrary = SessionResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary HealthResponse where
  arbitrary = HealthResponse <$> arbitrary

instance Arbitrary ReadyResponse where
  arbitrary = ReadyResponse <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary AuditEventResponse where
  arbitrary =
    AuditEventResponse <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary AuditEventsPage where
  arbitrary = AuditEventsPage <$> arbitrary <*> arbitrary
