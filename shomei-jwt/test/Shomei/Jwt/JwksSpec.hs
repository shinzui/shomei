-- | Scenario (g), JWKS-shape half: 'jwksDocument' for two keys is valid JSON
-- with a top-level @"keys"@ array of two objects carrying the correct @kid@s and
-- no private @"d"@ field. The kid-selection half (sign with A, verify against
-- {A, B}) lives in 'Shomei.Jwt.SignVerifySpec' because it needs the signer.
module Shomei.Jwt.JwksSpec (tests) where

import Data.Aeson (Value (Array, Object, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Text (Text)
import Shomei.Jwt.Jwks (jwksDocument)
import Shomei.Jwt.Key (generateSigningKey, keyKid)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Jwks"
    [ testCase "publishes public-only JWKS with the right kids" $ do
        a <- generateSigningKey
        b <- generateSigningKey
        objs <- keysArray (jwksDocument [a, b])
        length objs @?= 2
        assertBool "no private d field" (not (any (KM.member (Key.fromText "d")) objs))
        sort (kidsOf objs) @?= sort [keyKid a, keyKid b]
    ]

-- | Decode a JWKS document and return the objects in its @"keys"@ array.
keysArray :: ByteString -> IO [KM.KeyMap Value]
keysArray doc =
  case Aeson.decode doc of
    Just (Object top) ->
      case KM.lookup (Key.fromText "keys") top of
        Just (Array arr) -> pure [o | Object o <- toList arr]
        _ -> assertFailure "JWKS has no \"keys\" array" >> pure []
    _ -> assertFailure "JWKS is not a JSON object" >> pure []

-- | Extract the @"kid"@ string of each key object.
kidsOf :: [KM.KeyMap Value] -> [Text]
kidsOf objs = [k | o <- objs, Just (String k) <- [KM.lookup (Key.fromText "kid") o]]
