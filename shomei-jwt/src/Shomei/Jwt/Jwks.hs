{- | The published JWKS (JSON Web Key Set) document and the 'KeySet' abstraction.

A JWKS is the public document a downstream verifier fetches: @{"keys":[ ... ]}@
containing the *public* projection of each signing key (no private @"d"@). EP-6
serves 'jwksDocument' at @GET /.well-known/jwks.json@.
-}
module Shomei.Jwt.Jwks (
    jwksDocument,
    KeySet (..),
    keySetPublicJwks,
) where

import Shomei.Prelude

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import "jose" Crypto.JOSE.JWK (JWK, JWKSet (JWKSet), asPublicKey)

-- | A live set of signing keys: the current active key plus any retired-but-valid keys.
data KeySet = KeySet
    { activeKey :: !JWK
    , previousKeys :: ![JWK]
    }

-- | All keys in a 'KeySet' (active first), as live JWKs.
keySetAll :: KeySet -> [JWK]
keySetAll ks = ks.activeKey : ks.previousKeys

-- | The public 'JWKSet' a verifier should use (private material stripped).
keySetPublicJwks :: KeySet -> JWKSet
keySetPublicJwks ks = JWKSet (mapMaybe publicOf (keySetAll ks))
  where
    publicOf k = k ^. asPublicKey

-- | Encode a list of keys as a published JWKS document (public material only).
jwksDocument :: [JWK] -> BSL.ByteString
jwksDocument keys = Aeson.encode (JWKSet (mapMaybe publicOf keys))
  where
    publicOf k = k ^. asPublicKey
