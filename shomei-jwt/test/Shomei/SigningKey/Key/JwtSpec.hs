-- | Scenario (a): a generated ES256 key round-trips through 'StoredSigningKey'
-- without losing its @kid@.
module Shomei.SigningKey.Key.JwtSpec (tests) where

import Crypto.JOSE.JWK (fromOctets)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (getCurrentTime)
import Shomei.SigningKey.Domain (SigningAlgorithm (RS256), StoredSigningKey (..))
import Shomei.SigningKey.Jwks.Jwt (jwksDocument)
import Shomei.SigningKey.Key.Jwt
  ( fromStoredSigningKey,
    generateSigningKey,
    generateSigningKeyFor,
    keyKid,
    toStoredSigningKey,
    toStoredSigningKeyFor,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Key"
    [ testCase "round-trips a key with stable kid" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        stored <- either (assertFailure . Text.unpack) pure (toStoredSigningKey t jwk)
        assertBool "kid is non-empty" (not (Text.null stored.keyId))
        case fromStoredSigningKey stored of
          Left err -> assertFailure ("decode failed: " <> Text.unpack err)
          Right jwk' -> keyKid jwk' @?= stored.keyId,
      testCase "generates an RS256 key recorded as RS256 with a kid and an RSA JWKS" $ do
        jwk <- generateSigningKeyFor RS256
        t <- getCurrentTime
        sk <- either (assertFailure . Text.unpack) pure (toStoredSigningKeyFor RS256 t jwk)
        sk.algorithm @?= "RS256"
        assertBool "kid is non-empty" (not (Text.null sk.keyId))
        let doc = jwksDocument [jwk]
        assertBool
          "JWKS contains an RSA key"
          ("\"kty\":\"RSA\"" `Text.isInfixOf` Text.decodeUtf8 (BSL.toStrict doc)),
      testCase "refuses a key with no public projection" $ do
        t <- getCurrentTime
        let symmetric = fromOctets (BS8.pack "not-a-public-key")
        case toStoredSigningKey t symmetric of
          Left reason -> assertBool "error names the public-material boundary" ("refusing to store private material as public" `Text.isInfixOf` reason)
          Right _ -> assertFailure "a symmetric key must not be copied into public_key_jwk"
    ]
