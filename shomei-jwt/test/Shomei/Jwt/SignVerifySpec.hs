{- | Scenarios (b)–(f) and the kid-selection half of (g): a full sign/verify
round trip, and rejection of tampered, expired, wrong-audience, and wrong-issuer
tokens, plus key selection out of a multi-key JWKSet.
-}
module Shomei.Jwt.SignVerifySpec (tests) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

import Crypto.JOSE.JWK (JWK)

import Shomei.Config (defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..))
import Shomei.Domain.Token (AccessToken (AccessToken))
import Shomei.Error (TokenError (..))
import Shomei.Id (genUserId)
import Shomei.Jwt.Key (generateSigningKey)
import Shomei.Jwt.Sign (signAccessToken)
import Shomei.Jwt.Verify (verifyToken)

import Shomei.Jwt.TestSupport (coreFields, mkClaims, mkClaimsWith, publicJwks, testAudience, testConfig, testIssuer)

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
            assertClaims ac res
        , testCase "rejects a tampered token" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            ac <- mkClaims testConfig t
            wire <- signOrFail jwk ac
            res <- verifyToken (publicJwks jwk []) testConfig (tamper wire)
            res @?= Left TokenSignatureInvalid
        , testCase "rejects an expired token" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            ac <- mkClaimsWith testConfig (addUTCTime (-3600) t) (addUTCTime (-1800) t)
            wire <- signOrFail jwk ac
            res <- verifyToken (publicJwks jwk []) testConfig wire
            res @?= Left TokenExpired
        , testCase "rejects a wrong audience" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            ac <- mkClaims testConfig t
            wire <- signOrFail jwk ac
            let cfgWrong = defaultShomeiConfig testIssuer (Audience "other-audience")
            res <- verifyToken (publicJwks jwk []) cfgWrong wire
            res @?= Left TokenAudienceInvalid
        , testCase "rejects a wrong issuer" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            ac <- mkClaims testConfig t
            wire <- signOrFail jwk ac
            let cfgWrong = defaultShomeiConfig (Issuer "https://evil.test") testAudience
            res <- verifyToken (publicJwks jwk []) cfgWrong wire
            res @?= Left TokenIssuerInvalid
        , testCase "selects the signing key by kid" $ do
            a <- generateSigningKey
            b <- generateSigningKey
            t <- getCurrentTime
            ac <- mkClaims testConfig t
            wire <- signOrFail a ac
            res <- verifyToken (publicJwks a [b]) testConfig wire
            assertClaims ac res
        , testCase "round-trips the act (actor) claim on a delegated token" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            op <- genUserId
            base <- mkClaims testConfig t
            let ac = base{actor = Just op}
            wire <- signOrFail jwk ac
            res <- verifyToken (publicJwks jwk []) testConfig wire
            case res of
                Right ac' -> ac'.actor @?= Just op
                Left e -> assertFailure ("verify failed: " <> show e)
        , testCase "omits the act claim when actor is Nothing" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            ac <- mkClaims testConfig t
            wire <- signOrFail jwk ac
            res <- verifyToken (publicJwks jwk []) testConfig wire
            case res of
                Right ac' -> ac'.actor @?= Nothing
                Left e -> assertFailure ("verify failed: " <> show e)
        ]

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

{- | Flip one character in the signature (last) segment of a compact JWS, so the
header and payload still decode but the signature no longer verifies. (jose
decodes the payload before checking the signature, so corrupting the payload
would surface as a malformed token rather than a bad signature.)
-}
tamper :: Text -> Text
tamper w = case reverse (Text.splitOn "." w) of
    (sig : leading) -> Text.intercalate "." (reverse (flip1 sig : leading))
    [] -> w
  where
    flip1 s = case Text.uncons s of
        Just (c, cs) -> Text.cons (if c == 'A' then 'B' else 'A') cs
        Nothing -> s
