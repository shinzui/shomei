-- | 'currentJwks' publishes every /publishable/ key — the active one plus the
-- retired-but-still-trusted ones — and never a pending or revoked key. Driven over the
-- in-memory 'SigningKeyStore' interpreter.
module Shomei.Jwt.RotationSpec (tests) where

import Data.Aeson (Value (Array, Object, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.Foldable (toList)
import Data.IORef (newIORef)
import Data.List (sort)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (runEff)
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Effect.InMemory (emptyWorld, runSigningKeyStore)
import Shomei.Effect.SigningKeyStore (insertSigningKey)
import Shomei.Jwt.Key (generateSigningKey, keyKid, toStoredSigningKey)
import Shomei.Jwt.Rotation (currentJwks)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Rotation"
    [ testCase "currentJwks publishes active + retired, not pending or revoked" $ do
        activeK <- generateSigningKey
        retiredK <- generateSigningKey
        pendingK <- generateSigningKey
        revokedK <- generateSigningKey
        ref <- newIORef (emptyWorld epoch)
        doc <- runEff . runSigningKeyStore ref $ do
          sequence_
            [ insertSigningKey ((toStoredSigningKey epoch k) {status = st})
            | (k, st) <-
                [ (activeK, KeyActive),
                  (retiredK, KeyRetired),
                  (pendingK, KeyPending),
                  (revokedK, KeyRevoked)
                ]
            ]
          currentJwks
        published <- kidsOf doc
        sort published @?= sort [keyKid activeK, keyKid retiredK]
        -- named individually so a failure says which lifecycle state leaked
        assertAbsent "pending" (keyKid pendingK) published
        assertAbsent "revoked" (keyKid revokedK) published
    ]
  where
    epoch = UTCTime (fromGregorian 2026 7 8) 0
    assertAbsent label kid published
      | kid `elem` published = assertFailure (label <> " key " <> show kid <> " must not be published")
      | otherwise = pure ()

-- | The @kid@ of each key in a JWKS document's @"keys"@ array.
kidsOf :: ByteString -> IO [Text]
kidsOf doc =
  case Aeson.decode doc of
    Just (Object top) ->
      case KM.lookup (Key.fromText "keys") top of
        Just (Array arr) ->
          pure [k | Object o <- toList arr, Just (String k) <- [KM.lookup (Key.fromText "kid") o]]
        _ -> assertFailure "JWKS has no \"keys\" array" >> pure []
    _ -> assertFailure "JWKS is not a JSON object" >> pure []
