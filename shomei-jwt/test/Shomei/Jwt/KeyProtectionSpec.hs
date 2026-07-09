-- | Envelope encryption of stored private signing keys. The properties that matter:
-- a round trip recovers the key; a wrong KEK, a tampered ciphertext, or a ciphertext moved
-- to another row's @kid@ all fail authentication indistinguishably; plaintext rows still
-- read (so a backfill can run under a live server); and encryption is idempotent.
module Shomei.Jwt.KeyProtectionSpec (tests) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Effectful (runEff)
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256, RS256), StoredSigningKey (..))
import Shomei.Effect.TokenSigner (signAccessToken)
import Shomei.Effect.TokenVerifier (verifyAccessToken)
import Shomei.Jwt.Key (generateSigningKeyFor, toStoredSigningKeyFor)
import Shomei.Jwt.KeyProtection
  ( KeyDecryptError (..),
    KeyEncryptionKey,
    decryptPrivateJwk,
    decryptStoredSigningKey,
    encryptPrivateJwk,
    isEncryptedPrivateJwk,
    keyEncryptionKeyFromBase64,
    protectStoredSigningKey,
    publicJwkFromStored,
  )
import Shomei.Jwt.Sign (runTokenSignerJwt)
import Shomei.Jwt.TestSupport (coreFields, mkClaims, publicJwks, testConfig)
import Shomei.Jwt.Verify (runTokenVerifierJwt)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "KeyProtection"
    [ testGroup "KEK parsing" kekParsing,
      testGroup "envelope" envelope,
      testGroup "stored keys" storedKeys
    ]

kekParsing :: [TestTree]
kekParsing =
  [ testCase "accepts 32 base64 bytes" do
      either (assertFailure . Text.unpack) (const (pure ())) (keyEncryptionKeyFromBase64 (kekText 32)),
    testCase "rejects a 31-byte key and says how to make one" do
      case keyEncryptionKeyFromBase64 (kekText 31) of
        Right _ -> assertFailure "a 31-byte KEK must be rejected"
        Left err -> do
          assertBool ("names the length: " <> Text.unpack err) ("31 bytes" `Text.isInfixOf` err)
          assertBool "gives the generation recipe" ("/dev/urandom" `Text.isInfixOf` err),
    testCase "rejects non-base64" do
      case keyEncryptionKeyFromBase64 "not base64 !!!" of
        Right _ -> assertFailure "invalid base64 must be rejected"
        Left err -> assertBool ("names base64: " <> Text.unpack err) ("base64" `Text.isInfixOf` err),
    testCase "tolerates surrounding whitespace (a trailing newline from `| base64`)" do
      either (assertFailure . Text.unpack) (const (pure ())) (keyEncryptionKeyFromBase64 (kekText 32 <> "\n"))
  ]

envelope :: [TestTree]
envelope =
  [ testCase "round-trips" do
      kek <- testKek 1
      enc <- encryptPrivateJwk kek "kid-a" plaintextJwk
      assertBool "is tagged as encrypted" (isEncryptedPrivateJwk enc)
      decryptPrivateJwk (Just kek) "kid-a" enc @?= Right plaintextJwk,
    testCase "plaintext passes through, with or without a KEK" do
      kek <- testKek 1
      assertBool "plaintext is not tagged" (not (isEncryptedPrivateJwk plaintextJwk))
      decryptPrivateJwk Nothing "kid-a" plaintextJwk @?= Right plaintextJwk
      decryptPrivateJwk (Just kek) "kid-a" plaintextJwk @?= Right plaintextJwk,
    testCase "an encrypted row without a KEK is refused, not silently skipped" do
      kek <- testKek 1
      enc <- encryptPrivateJwk kek "kid-a" plaintextJwk
      decryptPrivateJwk Nothing "kid-a" enc @?= Left KeyEncryptedButNoKek,
    testCase "the wrong KEK fails authentication" do
      kek <- testKek 1
      other <- testKek 2
      enc <- encryptPrivateJwk kek "kid-a" plaintextJwk
      decryptPrivateJwk (Just other) "kid-a" enc @?= Left KeyDecryptFailed,
    testCase "a flipped ciphertext byte fails authentication" do
      kek <- testKek 1
      enc <- encryptPrivateJwk kek "kid-a" plaintextJwk
      decryptPrivateJwk (Just kek) "kid-a" (tamper enc) @?= Left KeyDecryptFailed,
    testCase "a ciphertext moved to another row's kid fails (the AAD binding)" do
      -- This is what stops an attacker with write access from relabeling an old,
      -- compromised key as the active one.
      kek <- testKek 1
      enc <- encryptPrivateJwk kek "kid-a" plaintextJwk
      decryptPrivateJwk (Just kek) "kid-b" enc @?= Left KeyDecryptFailed,
    testCase "a structurally broken envelope is distinguished from a failed tag" do
      kek <- testKek 1
      case decryptPrivateJwk (Just kek) "kid-a" "enc:v1:nope" of
        Left (MalformedEncryptedKey _) -> pure ()
        other -> assertFailure ("expected MalformedEncryptedKey, got " <> show other),
    testCase "a short nonce is rejected" do
      kek <- testKek 1
      case decryptPrivateJwk (Just kek) "kid-a" "enc:v1:AAAA:AAAAAAAAAAAAAAAAAAAAAA" of
        Left (MalformedEncryptedKey msg) -> assertBool ("names the nonce: " <> Text.unpack msg) ("nonce" `Text.isInfixOf` msg)
        other -> assertFailure ("expected MalformedEncryptedKey, got " <> show other),
    testCase "encrypting the same plaintext twice yields different ciphertexts (fresh nonce)" do
      kek <- testKek 1
      a <- encryptPrivateJwk kek "kid-a" plaintextJwk
      b <- encryptPrivateJwk kek "kid-a" plaintextJwk
      assertBool "nonces must not repeat" (a /= b)
      decryptPrivateJwk (Just kek) "kid-a" a @?= Right plaintextJwk
      decryptPrivateJwk (Just kek) "kid-a" b @?= Right plaintextJwk
  ]

storedKeys :: [TestTree]
storedKeys =
  [ testCase "protect → decrypt → sign → verify round-trips an ES256 key" (protectAndUse ES256),
    testCase "protect → decrypt → sign → verify round-trips an RS256 key" (protectAndUse RS256),
    testCase "protecting is idempotent: an encrypted row is returned unchanged" do
      kek <- testKek 1
      stored <- storedKeyFor ES256
      once <- protectStoredSigningKey (Just kek) stored
      twice <- protectStoredSigningKey (Just kek) once
      -- Not merely "still decrypts": the bytes must be identical, or a re-run of the
      -- backfill would rewrite every row (and burn a nonce) for nothing.
      twice.privateKeyJwk @?= once.privateKeyJwk,
    testCase "protecting without a KEK leaves the row alone" do
      stored <- storedKeyFor ES256
      unprotected <- protectStoredSigningKey Nothing stored
      unprotected.privateKeyJwk @?= stored.privateKeyJwk
      assertBool "still plaintext" (not (isEncryptedPrivateJwk unprotected.privateKeyJwk)),
    testCase "the public column is never encrypted, and parses without a KEK" do
      kek <- testKek 1
      stored <- storedKeyFor ES256
      protected <- protectStoredSigningKey (Just kek) stored
      protected.publicKeyJwk @?= stored.publicKeyJwk
      assertBool "private material is encrypted" (isEncryptedPrivateJwk protected.privateKeyJwk)
      case publicJwkFromStored protected of
        Right _ -> pure ()
        Left err -> assertFailure ("public key must parse with no KEK: " <> Text.unpack err),
    testCase "decryptStoredSigningKey reports a decryptable-but-invalid payload distinctly" do
      kek <- testKek 1
      stored <- storedKeyFor ES256
      enc <- encryptPrivateJwk kek stored.keyId "not json at all"
      case decryptStoredSigningKey (Just kek) stored {privateKeyJwk = enc} of
        Left (KeyJsonInvalid _) -> pure ()
        other -> assertFailure ("expected KeyJsonInvalid, got " <> show (() <$ other))
  ]

-- | Generate a key, store it, encrypt it, recover it, and prove the recovered key still
-- signs a token that verifies against the published public key.
protectAndUse :: SigningAlgorithm -> IO ()
protectAndUse alg = do
  kek <- testKek 1
  stored <- storedKeyFor alg
  protected <- protectStoredSigningKey (Just kek) stored
  assertBool "private material is encrypted at rest" (isEncryptedPrivateJwk protected.privateKeyJwk)
  signer <- case decryptStoredSigningKey (Just kek) protected of
    Right jwk -> pure jwk
    Left err -> assertFailure ("decrypt failed: " <> show err)
  pub <- either (assertFailure . Text.unpack) pure (publicJwkFromStored protected)
  -- Claims are minted against the real clock: the verifier checks expiry, so a fixed epoch
  -- would make this test start failing an hour into the day it was written.
  now <- getCurrentTime
  claims <- mkClaims testConfig now
  tok <- runEff (runTokenSignerJwt signer testConfig (signAccessToken claims))
  result <- runEff (runTokenVerifierJwt (publicJwks pub []) testConfig (verifyAccessToken tok))
  case result of
    Right recovered -> coreFields recovered @?= coreFields claims
    Left e -> assertFailure ("a token signed with the decrypted key must verify: " <> show e)

storedKeyFor :: SigningAlgorithm -> IO StoredSigningKey
storedKeyFor alg = do
  jwk <- generateSigningKeyFor alg
  pure (toStoredSigningKeyFor alg epoch jwk)

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 7 8) 0

-- | A deterministic, distinct KEK per seed byte.
testKek :: Int -> IO KeyEncryptionKey
testKek seed = either (assertFailure . Text.unpack) pure (keyEncryptionKeyFromBase64 (kekTextFrom (toEnum (0x40 + seed))))

kekText :: Int -> Text
kekText n = TE.decodeUtf8 (convertToBase Base64 (BS.replicate n 0x2a))

kekTextFrom :: Char -> Text
kekTextFrom c = TE.decodeUtf8 (convertToBase Base64 (BS8.replicate 32 c))

-- | A JWK-shaped plaintext; the envelope does not care that it is well-formed.
plaintextJwk :: Text
plaintextJwk = "{\"kty\":\"EC\",\"crv\":\"P-256\",\"d\":\"private-scalar\"}"

-- | Flip the last character of the base64url ciphertext.
tamper :: Text -> Text
tamper enc = Text.init enc <> if Text.last enc == 'A' then "B" else "A"
