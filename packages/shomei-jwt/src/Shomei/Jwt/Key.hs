{- | Generating ES256 signing keys and converting them to/from the
storage-agnostic 'StoredSigningKey' record (MasterPlan IP-4).

A key's @kid@ is its RFC 7638 JWK thumbprint (the SHA-256 hash of the key's
canonical JSON, Base64URL-unpadded), so the same public key always yields the
same @kid@ and two distinct keys cannot collide. This module is the only place
in Shōmei that converts between the opaque JWK JSON stored in
'StoredSigningKey' and a live @jose@ 'JWK'.
-}
module Shomei.Jwt.Key (
    generateSigningKey,
    toStoredSigningKey,
    fromStoredSigningKey,
    keyKid,
) where

import Shomei.Prelude

import Shomei.Domain.SigningKey (SigningKeyStatus (KeyActive), StoredSigningKey (..))

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import "crypton" Crypto.Hash (Digest)
import "crypton" Crypto.Hash.Algorithms (SHA256)
import "jose" Crypto.JOSE.JWA.JWK (Crv (P_256))
import "jose" Crypto.JOSE.JWK (
    JWK,
    KeyMaterialGenParam (ECGenParam),
    KeyUse (Sig),
    asPublicKey,
    genJWK,
    jwkKid,
    jwkUse,
    thumbprint,
 )
import "ram" Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertToBase)

{- | Generate a fresh ES256 (P-256) signing key, marked for signature use, with
its @kid@ set to its RFC 7638 thumbprint (Base64URL, unpadded).
-}
generateSigningKey :: IO JWK
generateSigningKey = do
    k0 <- genJWK (ECGenParam P_256)
    let tp = view thumbprint k0 :: Digest SHA256
        kid = Text.decodeUtf8 (convertToBase Base64URLUnpadded tp :: ByteString)
    pure (k0 & jwkUse ?~ Sig & jwkKid ?~ kid)

-- | The @kid@ stored on a key (empty if absent — 'generateSigningKey' always sets it).
keyKid :: JWK -> Text
keyKid k = fromMaybe "" (k ^. jwkKid)

{- | Convert a live 'JWK' to the storage-agnostic record. Serializes the full
key (with the private @"d"@) to 'privateKeyJwk' and the public-only projection
to 'publicKeyJwk'.
-}
toStoredSigningKey :: UTCTime -> JWK -> StoredSigningKey
toStoredSigningKey t k =
    let pub = fromMaybe k (k ^. asPublicKey)
        enc = Text.decodeUtf8 . BSL.toStrict . Aeson.encode
     in StoredSigningKey
            { keyId = keyKid k
            , algorithm = "ES256"
            , publicKeyJwk = enc pub
            , privateKeyJwk = enc k
            , status = KeyActive
            , createdAt = t
            , activatedAt = Just t
            , retiredAt = Nothing
            }

-- | Parse a stored key's full (private) JWK JSON back into a live 'JWK'.
fromStoredSigningKey :: StoredSigningKey -> Either Text JWK
fromStoredSigningKey sk =
    case Aeson.eitherDecodeStrict (Text.encodeUtf8 sk.privateKeyJwk) of
        Left err -> Left (Text.pack err)
        Right k -> Right k
