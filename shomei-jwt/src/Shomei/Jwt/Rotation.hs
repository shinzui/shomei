{- | Key rotation and the live published JWKS, written against the
'SigningKeyStore' and 'Clock' port effects only (no IO key storage of its own).

Rotation is intentionally simple: generate a new active key, insert it, and mark
the previously-active key 'KeyRetired'. The published JWKS includes every stored
key that is not 'KeyRevoked', so tokens signed just before rotation keep
verifying until they expire (zero-downtime rotation).
-}
module Shomei.Jwt.Rotation (
    rotateSigningKey,
    currentJwks,
) where

import Shomei.Prelude

import Shomei.Domain.SigningKey (
    SigningKeyStatus (KeyRetired, KeyRevoked),
    StoredSigningKey (..),
 )
import Shomei.Jwt.Jwks (jwksDocument)
import Shomei.Jwt.Key (fromStoredSigningKey, generateSigningKey, toStoredSigningKey)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SigningKeyStore (
    SigningKeyStore,
    insertSigningKey,
    listActiveSigningKeys,
    updateSigningKeyStatus,
 )

import Data.ByteString.Lazy qualified as BSL
import Data.Either (rights)
import Effectful (Eff, IOE, (:>))
import "jose" Crypto.JOSE.JWK (JWK)

{- | Generate a new active key and retire whatever was active. Returns the new
live 'JWK' (so the caller can sign with it immediately).
-}
rotateSigningKey ::
    (IOE :> es, SigningKeyStore :> es, Clock :> es) =>
    Eff es JWK
rotateSigningKey = do
    t <- now
    priorActive <- listActiveSigningKeys
    newJwk <- liftIO generateSigningKey
    insertSigningKey (toStoredSigningKey t newJwk)
    forM_ priorActive \k -> updateSigningKeyStatus k.keyId KeyRetired t
    pure newJwk

{- | Build the published JWKS from all stored keys that are not revoked.

Note: with the current 'listActiveSigningKeys' contract (which returns only
'KeyActive' keys), this publishes the active key(s); including retired-but-valid
keys is deferred until the store gains a non-revoked query (see Decision Log).
-}
currentJwks ::
    (SigningKeyStore :> es) =>
    Eff es BSL.ByteString
currentJwks = do
    keys <- listActiveSigningKeys
    let live = rights (map fromStoredSigningKey (filter notRevoked keys))
    pure (jwksDocument live)
  where
    notRevoked k = k.status /= KeyRevoked
