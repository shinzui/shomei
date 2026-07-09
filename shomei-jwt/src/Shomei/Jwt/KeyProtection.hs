-- | Envelope encryption of stored signing-key private material (at-rest protection).
--
-- A signing key's private JWK is the most powerful secret in the system: whoever holds it
-- can forge a valid token for any user of any downstream service that trusts Shōmei's JWKS.
-- Stored in plaintext, a database read — or a backup, a dump, a misconfigured replica —
-- hands that power over. Here it is encrypted under a __key-encryption key__ (KEK) that
-- lives outside the database, in the process environment, so forging tokens requires the
-- database /and/ the application environment.
--
-- Format v1, held in the existing @private_key_jwk text@ column (no schema change):
--
-- > "enc:v1:" <> base64url(nonce, 12 bytes) <> ":" <> base64url(ciphertext <> tag)
--
-- Cipher: ChaCha20-Poly1305 (AEAD). The associated data is the key's @kid@, which binds
-- each ciphertext to its row: an attacker with database /write/ access cannot relabel an
-- old compromised key as the active one, because decryption under the new @kid@ fails.
--
-- Legacy plaintext rows are JWK JSON (they start with @{@) and are detected by the absence
-- of the @enc:v1:@ prefix, so encrypted and plaintext rows coexist during a backfill.
--
-- Operators wanting KMS/HSM-managed keys inject the KEK from their secret manager; that
-- integration sits above Shōmei and is out of scope here.
module Shomei.Jwt.KeyProtection
  ( KeyEncryptionKey,
    keyEncryptionKeyFromBase64,
    KeyDecryptError (..),
    isEncryptedPrivateJwk,
    encryptPrivateJwk,
    decryptPrivateJwk,
    protectStoredSigningKey,
    decryptStoredSigningKey,
    publicJwkFromStored,
  )
where

import Crypto.Cipher.ChaChaPoly1305 qualified as AEAD
import Crypto.Error (CryptoFailable (..))
import Crypto.JOSE.JWK (JWK)
import Crypto.MAC.Poly1305 qualified as Poly1305
import Crypto.Random (getRandomBytes)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base64, Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Shomei.Domain.SigningKey (StoredSigningKey (..))
import Shomei.Prelude

-- | The 32-byte key that encrypts stored private keys. Abstract, with no 'Show' and no
-- JSON instances: printing it anywhere would defeat the entire scheme, so make that a type
-- error rather than a code-review question.
newtype KeyEncryptionKey = KeyEncryptionKey BA.ScrubbedBytes

-- | Parse a KEK from base64 text (the value of @SHOMEI_KEY_ENCRYPTION_KEY@). Requires
-- exactly 32 decoded bytes. The 'Left' explains what was wrong and how to make a valid one;
-- callers prefix it with the variable they read.
keyEncryptionKeyFromBase64 :: Text -> Either Text KeyEncryptionKey
keyEncryptionKeyFromBase64 raw =
  case convertFromBase Base64 (TE.encodeUtf8 (Text.strip raw)) :: Either String ByteString of
    Left err -> Left (badKek ("it is not valid base64 (" <> Text.pack err <> ")"))
    Right bs
      | BS.length bs == 32 -> Right (KeyEncryptionKey (BA.convert bs))
      | otherwise -> Left (badKek ("it decodes to " <> tshow (BS.length bs) <> " bytes, not 32"))
  where
    badKek reason =
      "is not a valid key-encryption key: "
        <> reason
        <> ". Generate one with: head -c 32 /dev/urandom | base64"
    tshow = Text.pack . show

-- | Why a stored private key could not be turned back into a live 'JWK'.
data KeyDecryptError
  = -- | The row is encrypted but the process holds no KEK.
    KeyEncryptedButNoKek
  | -- | The @enc:v1:@ envelope is structurally broken (bad base64, wrong nonce length, …).
    MalformedEncryptedKey Text
  | -- | Authentication failed. Deliberately one constructor for a wrong KEK, a tampered
    -- ciphertext, and a ciphertext moved to another row: the caller learns only that it
    -- did not authenticate.
    KeyDecryptFailed
  | -- | Decryption succeeded but the recovered bytes are not a JWK.
    KeyJsonInvalid Text
  deriving stock (Eq, Show)

envelopePrefix :: Text
envelopePrefix = "enc:v1:"

-- | Is this stored @private_key_jwk@ an envelope rather than plaintext JWK JSON? Plaintext
-- JWKs are JSON objects, so the prefix is an unambiguous discriminator.
isEncryptedPrivateJwk :: Text -> Bool
isEncryptedPrivateJwk = Text.isPrefixOf envelopePrefix

-- | Encrypt a private JWK JSON string under @kek@, binding it to @kid@.
encryptPrivateJwk :: KeyEncryptionKey -> Text -> Text -> IO Text
encryptPrivateJwk (KeyEncryptionKey kek) kid jwkJson = do
  nonceBytes <- getRandomBytes 12 :: IO ByteString
  case aeadState kek nonceBytes kid of
    CryptoFailed e -> ioError (userError ("shomei: cannot initialize key encryption: " <> show e))
    CryptoPassed st0 -> do
      let (ciphertext, st1) = AEAD.encrypt (TE.encodeUtf8 jwkJson) st0
          tag = BA.convert (AEAD.finalize st1) :: ByteString
      pure (envelopePrefix <> b64 nonceBytes <> ":" <> b64 (ciphertext <> tag))

-- | Recover the private JWK JSON from a stored column value.
--
-- A plaintext value passes through unchanged whether or not a KEK is held, which is what
-- lets a backfill encrypt rows one at a time under a live server.
decryptPrivateJwk :: Maybe KeyEncryptionKey -> Text -> Text -> Either KeyDecryptError Text
decryptPrivateJwk mKek kid stored
  | not (isEncryptedPrivateJwk stored) = Right stored
  | otherwise = case mKek of
      Nothing -> Left KeyEncryptedButNoKek
      Just (KeyEncryptionKey kek) -> do
        (nonceBytes, body) <- parseEnvelope stored
        when (BS.length body < 16) (Left (MalformedEncryptedKey "ciphertext is shorter than its authentication tag"))
        let (ciphertext, tagBytes) = BS.splitAt (BS.length body - 16) body
        st0 <- cryptoOr (MalformedEncryptedKey "bad nonce or key size") (aeadState kek nonceBytes kid)
        expectedTag <- cryptoOr (MalformedEncryptedKey "bad authentication tag") (Poly1305.authTag tagBytes)
        let (plaintext, st1) = AEAD.decrypt ciphertext st0
        -- 'Auth's Eq is constant-time (Data.ByteArray.constEq).
        unless (AEAD.finalize st1 == expectedTag) (Left KeyDecryptFailed)
        first (KeyJsonInvalid . Text.pack . show) (TE.decodeUtf8' plaintext)

-- | Split @enc:v1:\<nonce\>:\<body\>@ into its decoded parts.
parseEnvelope :: Text -> Either KeyDecryptError (ByteString, ByteString)
parseEnvelope stored =
  case Text.splitOn ":" (Text.drop (Text.length envelopePrefix) stored) of
    [nonceB64, bodyB64] -> do
      nonceBytes <- decodeField "nonce" nonceB64
      body <- decodeField "ciphertext" bodyB64
      when (BS.length nonceBytes /= 12) (Left (MalformedEncryptedKey "nonce is not 12 bytes"))
      pure (nonceBytes, body)
    parts ->
      Left (MalformedEncryptedKey ("expected enc:v1:<nonce>:<ciphertext>, found " <> Text.pack (show (length parts)) <> " parts"))
  where
    decodeField what t =
      first
        (\err -> MalformedEncryptedKey (what <> " is not valid base64url (" <> Text.pack err <> ")"))
        (convertFromBase Base64URLUnpadded (TE.encodeUtf8 t) :: Either String ByteString)

-- | The AEAD state for @(kek, nonce, kid-as-AAD)@, shared by encrypt and decrypt so the two
-- can never disagree about the associated data.
aeadState :: BA.ScrubbedBytes -> ByteString -> Text -> CryptoFailable AEAD.State
aeadState kek nonceBytes kid = do
  nonce <- AEAD.nonce12 nonceBytes
  st <- AEAD.initialize kek nonce
  pure (AEAD.finalizeAAD (AEAD.appendAAD (TE.encodeUtf8 kid) st))

cryptoOr :: KeyDecryptError -> CryptoFailable a -> Either KeyDecryptError a
cryptoOr err = \case
  CryptoFailed _ -> Left err
  CryptoPassed a -> Right a

b64 :: ByteString -> Text
b64 bs = TE.decodeUtf8 (convertToBase Base64URLUnpadded bs)

-- | Encrypt a key's private material before it is persisted. Idempotent: an
-- already-encrypted record is returned unchanged, so a backfill can re-run safely. Without
-- a KEK the record passes through, which is how a KEK-less deployment keeps working.
--
-- @publicKeyJwk@ is never encrypted — publication and verification must not depend on the
-- KEK.
protectStoredSigningKey :: Maybe KeyEncryptionKey -> StoredSigningKey -> IO StoredSigningKey
protectStoredSigningKey Nothing sk = pure sk
protectStoredSigningKey (Just kek) sk
  | isEncryptedPrivateJwk sk.privateKeyJwk = pure sk
  | otherwise = do
      enc <- encryptPrivateJwk kek sk.keyId sk.privateKeyJwk
      pure sk {privateKeyJwk = enc}

-- | The single stored→live conversion for __private__ key material: decrypt if needed, then
-- parse. Every path that needs a signing key goes through here; nothing else may parse
-- @private_key_jwk@.
decryptStoredSigningKey :: Maybe KeyEncryptionKey -> StoredSigningKey -> Either KeyDecryptError JWK
decryptStoredSigningKey mKek sk = do
  jwkJson <- decryptPrivateJwk mKek sk.keyId sk.privateKeyJwk
  first (KeyJsonInvalid . Text.pack) (Aeson.eitherDecodeStrict (TE.encodeUtf8 jwkJson))

-- | Parse a key's __public__ material. Needs no KEK, by construction: the published JWKS and
-- the verifier key set are built from this, so a missing or wrong KEK can never break
-- verification of outstanding tokens — only signing.
publicJwkFromStored :: StoredSigningKey -> Either Text JWK
publicJwkFromStored sk =
  first Text.pack (Aeson.eitherDecodeStrict (TE.encodeUtf8 sk.publicKeyJwk))
