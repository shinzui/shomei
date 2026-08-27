{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Regression tests for the verifier's trust boundary.
module Shomei.SigningKey.Verify.JwtSpec (tests) where

import Control.Lens ((&), (.~), (?~), (^.))
import Crypto.JOSE.Compact (encodeCompact)
import Crypto.JOSE.Error (runJOSE)
import Crypto.JOSE.Header (newHeaderParamProtected)
import Crypto.JOSE.JWA.JWS (Alg (ES256, HS256, RS256))
import Crypto.JOSE.JWK (JWK, asPublicKey, fromOctets)
import Crypto.JOSE.JWS (newJWSHeaderProtected)
import Crypto.JOSE.JWS qualified as JWS
import Crypto.JWT
  ( Audience (Audience),
    ClaimsSet,
    JWTError,
    SignedJWT,
    StringOrURI,
    addClaim,
    claimAud,
    signClaims,
  )
import Data.Aeson (Object, Result (Error, Success), Value (Number, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Shomei.Authorization.Claims.Domain (AuthClaims (..), mkExtraClaims)
import Shomei.Error (TokenError (..))
import Shomei.Session.Token.Domain (AccessToken (AccessToken))
import Shomei.SigningKey.Domain qualified as Domain
import Shomei.SigningKey.Key.Jwt (generateSigningKey, generateSigningKeyFor, keyKid)
import Shomei.SigningKey.Sign.Jwt (claimsFromAuth, signAccessToken)
import Shomei.SigningKey.TestSupport (mkClaims, mkClaimsWith, publicJwks, testConfig)
import Shomei.SigningKey.Verify.Jwt (verifyToken)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Verify"
    [ testCase "accepts an iat within the configured 30-second skew" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaimsWith testConfig (addUTCTime 10 now) (addUTCTime 3600 now)
        wire <- signAccessOrFail jwk claims
        result <- verifyToken (publicJwks jwk []) testConfig wire
        case result of
          Right _ -> pure ()
          Left err -> assertFailure ("expected the token to verify, got " <> show err),
      testCase "rejects an iat beyond the configured skew" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaimsWith testConfig (addUTCTime 120 now) (addUTCTime 3600 now)
        wire <- signAccessOrFail jwk claims
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left (TokenOtherError "iat in the future"),
      testCase "rejects a string-valued roles claim as malformed" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signClaimsOrFail jwk (claimsFromAuth claims & addClaim "roles" (String "admin"))
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left TokenMalformed,
      testCase "rejects a multi-element audience even when one value matches" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        let audienceValues = [sou "shomei-clients", sou "other"]
        wire <- signClaimsOrFail jwk (claimsFromAuth claims & claimAud ?~ Audience audienceValues)
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left TokenAudienceInvalid,
      testCase "mints integral iat and exp values" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signAccessOrFail jwk claims
        payload <- decodeSegment 1 wire
        assertIntegralNumber "iat" payload
        assertIntegralNumber "exp" payload,
      testCase "drops nbf and jti from the extension claim bag" $ do
        let extras = mkExtraClaims (KeyMap.fromList [("nbf", Number 1), ("jti", String "forged")])
        assertBool "nbf must be reserved" (not (KeyMap.member "nbf" extras))
        assertBool "jti must be reserved" (not (KeyMap.member "jti" extras)),
      testCase "reports an unknown kid without trying other keys" $ do
        signingKey <- generateSigningKey
        publishedKey <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signAccessOrFail signingKey claims
        result <- verifyToken (publicJwks publishedKey []) testConfig wire
        result @?= Left (TokenKeyNotFound (Just (keyKid signingKey))),
      testCase "reports a missing kid even when the signature key is published" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signClaimsWithHeaderOrFail jwk ES256 Nothing (Just "at+jwt") (claimsFromAuth claims)
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left (TokenKeyNotFound Nothing),
      testCase "rejects typ JWT on an access token" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signClaimsWithHeaderOrFail jwk ES256 (Just (keyKid jwk)) (Just "JWT") (claimsFromAuth claims)
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left (TokenOtherError "typ JWT is not at+jwt"),
      testCase "temporarily accepts an access token with no typ" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signClaimsWithHeaderOrFail jwk ES256 (Just (keyKid jwk)) Nothing (claimsFromAuth claims)
        result <- verifyToken (publicJwks jwk []) testConfig wire
        case result of
          Right _ -> pure ()
          Left err -> assertFailure ("expected the typ-less compatibility token to verify, got " <> show err),
      testCase "mints access-token typ at+jwt" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signAccessOrFail jwk claims
        header <- decodeSegment 0 wire
        KeyMap.lookup "typ" header @?= Just (String "at+jwt"),
      testCase "rejects alg none" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        realWire <- signAccessOrFail jwk claims
        let payload = Text.splitOn "." realWire !! 1
            header = Aeson.object ["alg" Aeson..= String "none", "kid" Aeson..= String (keyKid jwk)]
            headerSegment = Text.decodeUtf8 (convertToBase Base64URLUnpadded (BSL.toStrict (Aeson.encode header)) :: ByteString)
            wire = Text.intercalate "." [headerSegment, payload, ""]
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left TokenSignatureInvalid,
      testCase "rejects HS256 signed with public-key bytes" $ do
        jwk <- generateSigningKey
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        let publicKey = fromMaybe jwk (jwk ^. asPublicKey)
            hmacKey = fromOctets (BSL.toStrict (Aeson.encode publicKey))
        wire <- signClaimsWithHeaderOrFail hmacKey HS256 (Just (keyKid jwk)) (Just "at+jwt") (claimsFromAuth claims)
        result <- verifyToken (publicJwks jwk []) testConfig wire
        result @?= Left TokenSignatureInvalid,
      testCase "rejects RS256 under an EC kid" $ do
        ecKey <- generateSigningKey
        rsaKey <- generateSigningKeyFor Domain.RS256
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        wire <- signClaimsWithHeaderOrFail rsaKey RS256 (Just (keyKid ecKey)) (Just "at+jwt") (claimsFromAuth claims)
        result <- verifyToken (publicJwks ecKey []) testConfig wire
        result @?= Left TokenSignatureInvalid
    ]

sou :: Text -> StringOrURI
sou = fromString . Text.unpack

signAccessOrFail :: JWK -> AuthClaims -> IO Text
signAccessOrFail jwk claims = do
  result <- signAccessToken jwk claims
  case result of
    Left err -> assertFailure ("signing failed: " <> show err)
    Right (AccessToken wire) -> pure wire

signClaimsOrFail :: JWK -> ClaimsSet -> IO Text
signClaimsOrFail jwk = signClaimsWithHeaderOrFail jwk ES256 (Just (keyKid jwk)) Nothing

signClaimsWithHeaderOrFail :: JWK -> Alg -> Maybe Text -> Maybe Text -> ClaimsSet -> IO Text
signClaimsWithHeaderOrFail jwk algorithm headerKid headerType claims = do
  let header =
        newJWSHeaderProtected algorithm
          & JWS.kid
            .~ fmap newHeaderParamProtected headerKid
          & JWS.typ
            .~ fmap newHeaderParamProtected headerType
  result <- runJOSE @JWTError do
    signed <- signClaims jwk header claims
    pure (encodeCompact (signed :: SignedJWT))
  case result of
    Left err -> assertFailure ("signing claims failed: " <> show err)
    Right wire -> pure (Text.decodeUtf8 (BSL.toStrict wire))

decodeSegment :: Int -> Text -> IO Object
decodeSegment index wire = do
  let segment = Text.encodeUtf8 (Text.splitOn "." wire !! index)
  raw <-
    either (assertFailure . ("segment base64url decode failed: " <>)) pure $
      (convertFromBase Base64URLUnpadded segment :: Either String ByteString)
  maybe (assertFailure "segment is not a JSON object") pure (Aeson.decodeStrict raw)

assertIntegralNumber :: Text -> Object -> IO ()
assertIntegralNumber name payload = case KeyMap.lookup (fromString (Text.unpack name)) payload of
  Just value@(Number _) -> case Aeson.fromJSON value :: Result Integer of
    Success _ -> pure ()
    Error err -> assertFailure (Text.unpack name <> " is not integral: " <> err)
  other -> assertFailure (Text.unpack name <> " must be a JSON number, got " <> show other)
