-- | SH-24 acceptance: an RS256 token carrying a custom claim round-trips through
-- the public JWKS verify path, the compact token's header/payload contents are proven
-- by decoding it, reserved keys cannot be forged via the extra bag, and the config
-- selector maps the algorithm text to the closed enum.
module Shomei.Jwt.RsaCustomClaimSpec (tests) where

import Crypto.JOSE.JWK (JWK)
import Data.Aeson (Object, Value (Bool, String), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (getCurrentTime)
import Shomei.Config (ShomeiConfig (..), SigningKeyConfig (..), configSigningAlgorithm)
import Shomei.Domain.Claims (AuthClaims (..), mkExtraClaims)
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256, RS256))
import Shomei.Domain.Token (AccessToken (AccessToken))
import Shomei.Id (idText)
import Shomei.Jwt.Key (generateSigningKeyFor, keyKid)
import Shomei.Jwt.Sign (signAccessToken)
import Shomei.Jwt.TestSupport (mkClaims, publicJwks, testConfig)
import Shomei.Jwt.Verify (verifyToken)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "RsaCustomClaim"
    [ testCase "RS256 token with a custom claim round-trips via JWKS" $ do
        jwk <- generateSigningKeyFor RS256
        t <- getCurrentTime
        base <- mkClaims testConfig t
        let bag =
              mkExtraClaims
                ( KeyMap.fromList
                    [ ("userId", String "u-123"),
                      ("impersonated", Bool False),
                      ("userInfo", object ["userRole" .= String "agent", "username" .= String "alice"])
                    ]
                )
            ac = base {extraClaims = bag}
        wire <- signOrFail jwk ac
        -- Prove the compact header says alg=RS256 with the right kid.
        hdr <- decodeSegment 0 wire
        KeyMap.lookup "alg" hdr @?= Just (String "RS256")
        KeyMap.lookup "kid" hdr @?= Just (String (keyKid jwk))
        -- Prove the payload carries the custom claim AND the standard claims.
        payload <- decodeSegment 1 wire
        KeyMap.lookup "userId" payload @?= Just (String "u-123")
        assertBool "sub present in payload" (KeyMap.member "sub" payload)
        assertBool "sid present in payload" (KeyMap.member "sid" payload)
        -- Verify through the public JWKS path; the custom bag is preserved.
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> do
            ac'.extraClaims @?= bag
            idText ac'.subject @?= idText base.subject
          Left e -> assertFailure ("verify failed: " <> show e),
      testCase "reserved keys cannot be forged via the extra bag" $ do
        jwk <- generateSigningKeyFor RS256
        t <- getCurrentTime
        base <- mkClaims testConfig t
        let ac = base {extraClaims = mkExtraClaims (KeyMap.fromList [("sub", String "attacker")])}
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> idText ac'.subject @?= idText base.subject
          Left e -> assertFailure ("verify failed: " <> show e),
      testCase "configSigningAlgorithm parses RS256 and falls back to ES256" $ do
        let rs = testConfig {signingKeyConfig = SigningKeyConfig {algorithm = "RS256", refreshIntervalSeconds = 60}}
            bad = testConfig {signingKeyConfig = SigningKeyConfig {algorithm = "nope", refreshIntervalSeconds = 60}}
        configSigningAlgorithm rs @?= RS256
        configSigningAlgorithm bad @?= ES256
    ]

-- | Sign claims, failing the test if signing errors; returns the compact token text.
signOrFail :: JWK -> AuthClaims -> IO Text
signOrFail jwk ac = do
  r <- signAccessToken jwk ac
  case r of
    Right (AccessToken w) -> pure w
    Left e -> assertFailure ("sign failed: " <> show e)

-- | Decode the @n@th dot-separated segment of a compact JWS: base64url-decode it
-- (unpadded) and parse the JSON object (segment 0 = header, 1 = payload).
decodeSegment :: Int -> Text -> IO Object
decodeSegment n wire = do
  let segs = Text.splitOn "." wire
  seg <- case drop n segs of
    (s : _) -> pure (Text.encodeUtf8 s)
    [] -> assertFailure ("no segment " <> show n <> " in token")
  raw <-
    either (assertFailure . ("base64url decode failed: " <>)) pure $
      (convertFromBase Base64URLUnpadded seg :: Either String ByteString)
  maybe (assertFailure "segment is not a JSON object") pure (Aeson.decodeStrict raw)
