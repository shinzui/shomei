-- | Scenarios (b)–(f) and the kid-selection half of (g): a full sign/verify
-- round trip, and rejection of tampered, expired, wrong-audience, and wrong-issuer
-- tokens, plus key selection out of a multi-key JWKSet.
module Shomei.Jwt.SignVerifySpec (tests) where

import Crypto.JOSE.JWK (JWK)
import Data.Aeson (Object, Value (String))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Shomei.Config (defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), mkExtraClaims)
import Shomei.Domain.SigningKey (SigningAlgorithm (RS256))
import Shomei.Domain.Token (AccessToken (AccessToken))
import Shomei.Error (TokenError (..))
import Shomei.Id (genUserId, idText)
import Shomei.Jwt.Key (generateSigningKey, generateSigningKeyFor, keyKid)
import Shomei.Jwt.Sign (signAccessToken)
import Shomei.Jwt.TestSupport (coreFields, mkClaims, mkClaimsWith, publicJwks, testAudience, testConfig, testIssuer)
import Shomei.Jwt.Verify (verifyToken)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "SignVerify"
    [ testCase "round-trips all claims" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        assertClaims ac res,
      testCase "rejects a tampered token" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig (tamper wire)
        res @?= Left TokenSignatureInvalid,
      testCase "rejects an expired token" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaimsWith testConfig (addUTCTime (-3600) t) (addUTCTime (-1800) t)
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        res @?= Left TokenExpired,
      testCase "rejects a wrong audience" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        let cfgWrong = defaultShomeiConfig testIssuer (Audience "other-audience")
        res <- verifyToken (publicJwks jwk []) cfgWrong wire
        res @?= Left TokenAudienceInvalid,
      testCase "rejects a wrong issuer" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        let cfgWrong = defaultShomeiConfig (Issuer "https://evil.test") testAudience
        res <- verifyToken (publicJwks jwk []) cfgWrong wire
        res @?= Left TokenIssuerInvalid,
      testCase "selects the signing key by kid" $ do
        a <- generateSigningKey
        b <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail a ac
        res <- verifyToken (publicJwks a [b]) testConfig wire
        assertClaims ac res,
      testCase "round-trips the act (actor) claim on a delegated token" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        op <- genUserId
        base <- mkClaims testConfig t
        let ac = base {actor = Just op}
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> ac'.actor @?= Just op
          Left e -> assertFailure ("verify failed: " <> show e),
      testCase "omits the act claim when actor is Nothing" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> ac'.actor @?= Nothing
          Left e -> assertFailure ("verify failed: " <> show e),
      testCase "an RS256 key signs a token whose header alg is RS256" $ do
        jwk <- generateSigningKeyFor RS256
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        hdr <- decodeHeader wire
        KeyMap.lookup "alg" hdr @?= Just (String "RS256")
        KeyMap.lookup "kid" hdr @?= Just (String (keyKid jwk)),
      testCase "an RS256 token verifies via the RSA public JWKS" $ do
        jwk <- generateSigningKeyFor RS256
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        assertClaims ac res,
      testCase "an ES256 key still signs with header alg ES256" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        hdr <- decodeHeader wire
        KeyMap.lookup "alg" hdr @?= Just (String "ES256"),
      testCase "custom extra claims round-trip through sign/verify" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        base <- mkClaims testConfig t
        let extra =
              mkExtraClaims
                ( KeyMap.fromList
                    [ ("impersonated", Aeson.Bool False),
                      ("userId", String "u-123"),
                      ("userInfo", Aeson.object ["userRole" Aeson..= String "agent"])
                    ]
                )
            ac = base {extraClaims = extra}
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> ac'.extraClaims @?= extra
          Left e -> assertFailure ("verify failed: " <> show e),
      testCase "a custom sub in the extra bag cannot forge the subject" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        base <- mkClaims testConfig t
        let ac = base {extraClaims = mkExtraClaims (KeyMap.fromList [("sub", String "attacker")])}
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> idText ac'.subject @?= idText base.subject
          Left e -> assertFailure ("verify failed: " <> show e),
      -- The @permissions@ claim (EP-9) is managed like @roles@/@scopes@: the verify side reads it
      -- into the typed field and MUST strip it from the extra bag, or a consumer reading
      -- @extraClaims@ would see a duplicate it could mistake for a host claim.
      testCase "the permissions claim round-trips and never leaks into the extra bag" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        wire <- signOrFail jwk ac
        res <- verifyToken (publicJwks jwk []) testConfig wire
        case res of
          Right ac' -> do
            ac'.permissions @?= ac.permissions
            assertBool "permissions must not appear in extraClaims" (KeyMap.lookup "permissions" ac'.extraClaims == Nothing)
          Left e -> assertFailure ("verify failed: " <> show e)
    ]

-- | Decode the protected-header segment of a compact JWS (the part before the
-- first @.@): base64url-decode it (unpadded) and parse the JSON object.
decodeHeader :: Text -> IO Object
decodeHeader wire = do
  let seg = Text.encodeUtf8 (Text.takeWhile (/= '.') wire)
  raw <-
    either (assertFailure . ("header base64url decode failed: " <>)) pure $
      (convertFromBase Base64URLUnpadded seg :: Either String ByteString)
  maybe (assertFailure "header is not a JSON object") pure (Aeson.decodeStrict raw)

-- | Sign claims, failing the test if signing errors; returns the compact token text.
signOrFail :: JWK -> AuthClaims -> IO Text
signOrFail jwk ac = do
  r <- signAccessToken jwk ac
  case r of
    Right (AccessToken w) -> pure w
    Left e -> assertFailure ("sign failed: " <> show e)

-- | Assert a verification result holds the expected (stable) claim fields.
assertClaims :: AuthClaims -> Either TokenError AuthClaims -> Assertion
assertClaims expected = \case
  Right ac' -> coreFields ac' @?= coreFields expected
  Left e -> assertFailure ("verify failed: " <> show e)

-- | Flip one character in the signature (last) segment of a compact JWS, so the
-- header and payload still decode but the signature no longer verifies. (jose
-- decodes the payload before checking the signature, so corrupting the payload
-- would surface as a malformed token rather than a bad signature.)
tamper :: Text -> Text
tamper w = case reverse (Text.splitOn "." w) of
  (sig : leading) -> Text.intercalate "." (reverse (flip1 sig : leading))
  [] -> w
  where
    flip1 s = case Text.uncons s of
      Just (c, cs) -> Text.cons (if c == 'A' then 'B' else 'A') cs
      Nothing -> s
