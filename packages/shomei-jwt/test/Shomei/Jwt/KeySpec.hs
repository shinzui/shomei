{- | Scenario (a): a generated ES256 key round-trips through 'StoredSigningKey'
without losing its @kid@.
-}
module Shomei.Jwt.KeySpec (tests) where

import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Domain.SigningKey (StoredSigningKey (..))
import Shomei.Jwt.Key (fromStoredSigningKey, generateSigningKey, keyKid, toStoredSigningKey)

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
        ]
