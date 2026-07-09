-- | EP-27 M4 — OpenAPI 3.1 conformance for 'Shomei.Servant.API.ShomeiAPI'.
--
-- Two layers:
--
--   1. 'validateEveryToJSON' — for every JSON body type in the API, generate
--      arbitrary values and check their 'ToJSON' encoding validates against the
--      generated 'ToSchema'. This is what catches schema/JSON drift, including
--      the hand-written 'LoginResponse' @oneOf@ and the free-form 'Value' fields.
--
--   2. Smoke assertions on the assembled 'shomeiOpenApi': the @openapi@ version
--      is @3.1.0@ and the document covers the expected number of paths.
--
-- The 'Arbitrary' and 'Show' instances for the DTOs live here (orphans, test
-- only) so the production library carries no test dependency.
{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Data.Aeson (ToJSON (..), Value (..), decode, encode)
import Data.Aeson.KeyMap qualified as KM
import Data.Proxy (Proxy (..))
import Servant.API (NamedRoutes, NoContent (..))
import Data.OpenApi (NamedSchema (..), ToSchema (..))
import Servant.OpenApi.Test (validateEveryToJSON)
import Shomei.Servant.API (ShomeiAPI)
import Shomei.Servant.DTO
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
    validateEveryToJSON (Proxy :: Proxy (NamedRoutes ShomeiAPI))

  describe "shomeiOpenApi document" $ do
    it "declares OpenAPI version 3.1.0" $
      lookupTop "openapi" `shouldBe` Just (String "3.1.0")

    it "covers exactly 24 paths" $
      pathCount `shouldBe` 24
  where
    decoded :: KM.KeyMap Value
    decoded = case decode (encode shomeiOpenApi) of
      Just (Object o) -> o
      _ -> error "shomeiOpenApi did not encode to a JSON object"

    lookupTop k = KM.lookup k decoded

    pathCount = case lookupTop "paths" of
      Just (Object ps) -> KM.size ps
      _ -> error "shomeiOpenApi has no paths object"

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
