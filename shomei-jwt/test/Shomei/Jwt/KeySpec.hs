{- | Scenario (a): a generated ES256 key round-trips through 'StoredSigningKey'
without losing its @kid@.
-}
module Shomei.Jwt.KeySpec (tests) where

import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (getCurrentTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Domain.SigningKey (SigningAlgorithm (RS256), StoredSigningKey (..))
import Shomei.Jwt.Jwks (jwksDocument)
import Shomei.Jwt.Key (
    fromStoredSigningKey,
    generateSigningKey,
    generateSigningKeyFor,
    keyKid,
    toStoredSigningKey,
    toStoredSigningKeyFor,
 )

tests :: TestTree
tests =
    testGroup
        "Key"
        [ testCase "round-trips a key with stable kid" $ do
            jwk <- generateSigningKey
            t <- getCurrentTime
            let stored = toStoredSigningKey t jwk
            assertBool "kid is non-empty" (not (Text.null stored.keyId))
            case fromStoredSigningKey stored of
                Left err -> assertFailure ("decode failed: " <> Text.unpack err)
                Right jwk' -> keyKid jwk' @?= stored.keyId
        , testCase "generates an RS256 key recorded as RS256 with a kid and an RSA JWKS" $ do
            jwk <- generateSigningKeyFor RS256
            t <- getCurrentTime
            let sk = toStoredSigningKeyFor RS256 t jwk
            sk.algorithm @?= "RS256"
            assertBool "kid is non-empty" (not (Text.null sk.keyId))
            let doc = jwksDocument [jwk]
            assertBool
                "JWKS contains an RSA key"
                ("\"kty\":\"RSA\"" `Text.isInfixOf` Text.decodeUtf8 (BSL.toStrict doc))
        ]
