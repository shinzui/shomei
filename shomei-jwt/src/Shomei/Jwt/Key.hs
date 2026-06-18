-- | Generating ES256 signing keys and converting them to/from the
-- storage-agnostic 'StoredSigningKey' record (MasterPlan IP-4).
--
-- A key's @kid@ is its RFC 7638 JWK thumbprint (the SHA-256 hash of the key's
-- canonical JSON, Base64URL-unpadded), so the same public key always yields the
-- same @kid@ and two distinct keys cannot collide. This module is the only place
-- in Shōmei that converts between the opaque JWK JSON stored in
-- 'StoredSigningKey' and a live @jose@ 'JWK'.
module Shomei.Jwt.Key
  ( generateSigningKey,
    generateSigningKeyFor,
    toStoredSigningKey,
    toStoredSigningKeyFor,
    fromStoredSigningKey,
    keyKid,
  )
where

import Crypto.Hash (Digest)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.JOSE.JWA.JWK (Crv (P_256))
import Crypto.JOSE.JWK
  ( JWK,
    KeyMaterialGenParam (ECGenParam, RSAGenParam),
    KeyUse (Sig),
    asPublicKey,
    genJWK,
    jwkKid,
    jwkUse,
    thumbprint,
  )
import Data.Aeson qualified as Aeson
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Shomei.Domain.SigningKey
  ( SigningAlgorithm (ES256, RS256),
    SigningKeyStatus (KeyActive),
    StoredSigningKey (..),
    signingAlgorithmToText,
  )
import Shomei.Prelude

-- | Generate a fresh signing key for the requested algorithm, marked for
-- signature use, with its @kid@ set to its RFC 7638 thumbprint (Base64URL,
-- unpadded). @ES256@ → a P-256 EC key; @RS256@ → a 2048-bit RSA key (256 bytes,
-- comfortably above jose's 2040-bit minimum).
generateSigningKeyFor :: SigningAlgorithm -> IO JWK
generateSigningKeyFor alg = do
  k0 <- genJWK (genParam alg)
  let tp = view thumbprint k0 :: Digest SHA256
      kid = Text.decodeUtf8 (convertToBase Base64URLUnpadded tp :: ByteString)
  pure (k0 & jwkUse ?~ Sig & jwkKid ?~ kid)
  where
    genParam ES256 = ECGenParam P_256
    genParam RS256 = RSAGenParam 256 -- 256 bytes == 2048-bit modulus

-- | Generate a fresh ES256 (P-256) signing key. Back-compat alias defined in
-- terms of 'generateSigningKeyFor'.
generateSigningKey :: IO JWK
generateSigningKey = generateSigningKeyFor ES256

-- | The @kid@ stored on a key (empty if absent — 'generateSigningKey' always sets it).
keyKid :: JWK -> Text
keyKid k = fromMaybe "" (k ^. jwkKid)

-- | Convert a live 'JWK' to the storage-agnostic record. Serializes the full
-- key (with the private @"d"@) to 'privateKeyJwk' and the public-only projection
-- to 'publicKeyJwk'.
toStoredSigningKey :: UTCTime -> JWK -> StoredSigningKey
toStoredSigningKey t k =
  let pub = fromMaybe k (k ^. asPublicKey)
      enc = Text.decodeUtf8 . BSL.toStrict . Aeson.encode
   in StoredSigningKey
        { keyId = keyKid k,
          algorithm = "ES256",
          publicKeyJwk = enc pub,
          privateKeyJwk = enc k,
          status = KeyActive,
          createdAt = t,
          activatedAt = Just t,
          retiredAt = Nothing
        }

-- | Like 'toStoredSigningKey' but records the actual algorithm of the key. New
-- code that generates RS256 keys uses this; 'toStoredSigningKey' stays the ES256
-- convenience so existing callers are unaffected.
toStoredSigningKeyFor :: SigningAlgorithm -> UTCTime -> JWK -> StoredSigningKey
toStoredSigningKeyFor alg t k =
  (toStoredSigningKey t k) {algorithm = signingAlgorithmToText alg}

-- | Parse a stored key's full (private) JWK JSON back into a live 'JWK'.
fromStoredSigningKey :: StoredSigningKey -> Either Text JWK
fromStoredSigningKey sk =
  case Aeson.eitherDecodeStrict (Text.encodeUtf8 sk.privateKeyJwk) of
    Left err -> Left (Text.pack err)
    Right k -> Right k
