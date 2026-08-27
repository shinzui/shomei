-- | The signing-key lifecycle over the in-memory store: publication filters lifecycle
-- states, rotation replaces the active key atomically, and revocation removes trust.
module Shomei.SigningKey.Rotation.JwtSpec (tests) where

import Crypto.JOSE.JWK (JWKSet)
import Data.Aeson (Value (Array, Object, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (ByteString)
import Data.Foldable (toList, traverse_)
import Data.IORef (newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Effectful (runEff)
import Shomei.Error (TokenError (TokenKeyNotFound))
import Shomei.Session.Token.Domain (AccessToken (AccessToken))
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256), SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.SigningKey.Key.Jwt (generateSigningKey, keyKid, toStoredSigningKey)
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, keyEncryptionKeyFromBase64)
import Shomei.SigningKey.Rotation.Jwt (currentJwks, rotateSigningKey)
import Shomei.SigningKey.Sign.Jwt (signAccessToken)
import Shomei.SigningKey.Store (insertSigningKey, updateSigningKeyStatus)
import Shomei.SigningKey.TestSupport (mkClaims, testConfig)
import Shomei.SigningKey.Verify.Jwt (verifyToken)
import Shomei.Test.InMemory (World (..), emptyWorld, runClock, runSigningKeyStore)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Rotation"
    [ testCase "currentJwks publishes active + retired, not pending or revoked" $ do
        activeK <- generateSigningKey
        retiredK <- generateSigningKey
        pendingK <- generateSigningKey
        revokedK <- generateSigningKey
        stored <-
          either (assertFailure . show) pure $
            traverse
              (\(k, st) -> (\sk -> sk {status = st}) <$> toStoredSigningKey epoch k)
              [ (activeK, KeyActive),
                (retiredK, KeyRetired),
                (pendingK, KeyPending),
                (revokedK, KeyRevoked)
              ]
        ref <- newIORef (emptyWorld epoch)
        doc <- runEff . runSigningKeyStore ref $ do
          traverse_ insertSigningKey stored
          currentJwks
        published <- kidsOf doc
        sort published @?= sort [keyKid activeK, keyKid retiredK]
        assertAbsent "pending" (keyKid pendingK) published
        assertAbsent "revoked" (keyKid revokedK) published,
      testCase "rotation leaves one active key and publishes alg on both overlap keys" $ do
        oldJwk <- generateSigningKey
        old <- either (assertFailure . show) pure (toStoredSigningKey epoch oldJwk)
        kek <- testKek
        ref <- newIORef (emptyWorld epoch)
        newJwk <-
          runEff . runClock ref . runSigningKeyStore ref $ do
            insertSigningKey old
            rotateSigningKey kek ES256
        world <- readIORef ref
        let rows = Map.elems world.signingKeys
            activeRows = filter ((== KeyActive) . (.status)) rows
        fmap (.keyId) activeRows @?= [keyKid newJwk]
        oldAfter <- maybe (assertFailure "old key disappeared during rotation") pure (Map.lookup old.keyId world.signingKeys)
        newAfter <- maybe (assertFailure "new key was not stored during rotation") pure (Map.lookup (keyKid newJwk) world.signingKeys)
        oldAfter.status @?= KeyRetired
        oldAfter.retiredAt @?= Just epoch
        newAfter.activatedAt @?= Just epoch
        doc <- runEff . runSigningKeyStore ref $ currentJwks
        published <- kidsOf doc
        sort published @?= sort [old.keyId, keyKid newJwk]
        algs <- algsOf doc
        assertBool "every published overlap key has ES256 alg" (length algs == 2 && all (== "ES256") algs),
      testCase "revoking a key removes it from the verifier set" $ do
        jwk <- generateSigningKey
        stored <- either (assertFailure . show) pure (toStoredSigningKey epoch jwk)
        now <- getCurrentTime
        claims <- mkClaims testConfig now
        AccessToken wire <- signAccessToken jwk claims >>= either (assertFailure . show) pure
        ref <- newIORef (emptyWorld epoch)
        before <- runEff . runSigningKeyStore ref $ do
          insertSigningKey stored
          currentJwks
        beforeSet <- decodeJwkSet before
        verifyToken beforeSet testConfig wire >>= either (assertFailure . show) (const (pure ()))
        after <- runEff . runSigningKeyStore ref $ do
          updateSigningKeyStatus stored.keyId KeyRevoked epoch
          currentJwks
        afterSet <- decodeJwkSet after
        rejected <- verifyToken afterSet testConfig wire
        rejected @?= Left (TokenKeyNotFound (Just stored.keyId))
    ]
  where
    epoch = UTCTime (fromGregorian 2026 8 27) 0
    assertAbsent label kid published
      | kid `elem` published = assertFailure (label <> " key " <> show kid <> " must not be published")
      | otherwise = pure ()

kidsOf :: ByteString -> IO [Text]
kidsOf doc =
  case Aeson.decode doc of
    Just (Object top) ->
      case KM.lookup (Key.fromText "keys") top of
        Just (Array arr) ->
          pure [kid | Object o <- toList arr, Just (String kid) <- [KM.lookup (Key.fromText "kid") o]]
        _ -> assertFailure "JWKS has no \"keys\" array" >> pure []
    _ -> assertFailure "JWKS is not a JSON object" >> pure []

algsOf :: ByteString -> IO [Text]
algsOf doc =
  case Aeson.decode doc of
    Just (Object top) ->
      case KM.lookup (Key.fromText "keys") top of
        Just (Array arr) ->
          pure [alg | Object o <- toList arr, Just (String alg) <- [KM.lookup (Key.fromText "alg") o]]
        _ -> assertFailure "JWKS has no \"keys\" array" >> pure []
    _ -> assertFailure "JWKS is not a JSON object" >> pure []

decodeJwkSet :: ByteString -> IO JWKSet
decodeJwkSet = maybe (assertFailure "JWKS did not decode as JWKSet") pure . Aeson.decode

testKek :: IO KeyEncryptionKey
testKek =
  either (assertFailure . Text.unpack) pure $
    keyEncryptionKeyFromBase64 (Text.decodeUtf8 (convertToBase Base64 (BS.replicate 32 0x2a)))
