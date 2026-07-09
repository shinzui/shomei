-- | Key rotation and the live published JWKS, written against the
-- 'SigningKeyStore' and 'Clock' port effects only (no IO key storage of its own).
--
-- Rotation is intentionally simple: generate a new active key, insert it, and mark
-- the previously-active key 'KeyRetired'. The published JWKS includes every publishable
-- key ('KeyActive' and 'KeyRetired'), so tokens signed just before rotation keep
-- verifying until they expire (zero-downtime rotation).
module Shomei.Jwt.Rotation
  ( rotateSigningKey,
    rotateSigningKeyFor,
    rotateSigningKeyForWith,
    currentJwks,
  )
where

import Crypto.JOSE.JWK (JWK)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (rights)
import Effectful (Eff, IOE, (:>))
import Shomei.Domain.SigningKey
  ( SigningAlgorithm (ES256),
    SigningKeyStatus (KeyRetired),
    StoredSigningKey (..),
  )
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SigningKeyStore
  ( SigningKeyStore,
    insertSigningKey,
    listActiveSigningKeys,
    listPublishableSigningKeys,
    updateSigningKeyStatus,
  )
import Shomei.Jwt.Jwks (jwksDocument)
import Shomei.Jwt.Key (generateSigningKeyFor, toStoredSigningKeyFor)
import Shomei.Jwt.KeyProtection (KeyEncryptionKey, protectStoredSigningKey, publicJwkFromStored)
import Shomei.Prelude

-- | Generate a new active key and retire whatever was active. Returns the new
-- live 'JWK' (so the caller can sign with it immediately).
rotateSigningKey ::
  (IOE :> es, SigningKeyStore :> es, Clock :> es) =>
  Eff es JWK
rotateSigningKey = rotateSigningKeyFor ES256

-- | Like 'rotateSigningKey' but generates a key for the requested algorithm, so an
-- operator can rotate onto RS256 (or back to ES256). 'rotateSigningKey' is the ES256
-- alias kept for back-compat.
--
-- Stores the new private key in __plaintext__. A deployment that encrypts signing keys at
-- rest must call 'rotateSigningKeyForWith' with its key-encryption key instead, or it will
-- write a plaintext row into an otherwise-encrypted table.
rotateSigningKeyFor ::
  (IOE :> es, SigningKeyStore :> es, Clock :> es) =>
  SigningAlgorithm ->
  Eff es JWK
rotateSigningKeyFor = rotateSigningKeyForWith Nothing

-- | 'rotateSigningKeyFor', encrypting the new private key under @mKek@ before it is
-- persisted (see "Shomei.Jwt.KeyProtection"). 'Nothing' stores plaintext.
rotateSigningKeyForWith ::
  (IOE :> es, SigningKeyStore :> es, Clock :> es) =>
  Maybe KeyEncryptionKey ->
  SigningAlgorithm ->
  Eff es JWK
rotateSigningKeyForWith mKek alg = do
  t <- now
  priorActive <- listActiveSigningKeys
  newJwk <- liftIO (generateSigningKeyFor alg)
  protected <- liftIO (protectStoredSigningKey mKek (toStoredSigningKeyFor alg t newJwk))
  insertSigningKey protected
  forM_ priorActive \k -> updateSigningKeyStatus k.keyId KeyRetired t
  pure newJwk

-- | Build the published JWKS from every publishable key: the active key(s) plus the
-- retired-but-still-trusted ones, so tokens signed just before a rotation keep verifying
-- until they expire. @pending@ and @revoked@ keys are excluded by the store's
-- 'listPublishableSigningKeys' contract.
--
-- Reads the __public__ column only, so it needs no key-encryption key and works unchanged
-- against a table whose private material is encrypted at rest.
currentJwks ::
  (SigningKeyStore :> es) =>
  Eff es BSL.ByteString
currentJwks = do
  keys <- listPublishableSigningKeys
  pure (jwksDocument (rights (map publicJwkFromStored keys)))
