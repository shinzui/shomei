-- | Key rotation and the live published JWKS, written against the
-- 'SigningKeyStore' and 'Clock' port effects only (no IO key storage of its own).
--
-- Rotation is intentionally simple: generate a new active key, insert it, and mark
-- the previously-active key 'KeyRetired'. The published JWKS includes every publishable
-- key ('KeyActive' and 'KeyRetired'), so tokens signed just before rotation keep
-- verifying until they expire (zero-downtime rotation).
module Shomei.Jwt.Rotation
  ( rotateSigningKey,
    currentJwks,
  )
where

import Crypto.JOSE.JWK (JWK)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (rights)
import Effectful (Eff, IOE, (:>))
import Shomei.Domain.SigningKey
  ( SigningAlgorithm,
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

-- | Generate and encrypt a new active key, then retire whatever was active. Returns the live
-- 'JWK' so the caller can sign with it immediately.
rotateSigningKey ::
  (IOE :> es, SigningKeyStore :> es, Clock :> es) =>
  KeyEncryptionKey ->
  SigningAlgorithm ->
  Eff es JWK
rotateSigningKey kek alg = do
  t <- now
  priorActive <- listActiveSigningKeys
  newJwk <- liftIO (generateSigningKeyFor alg)
  protected <- liftIO (protectStoredSigningKey kek (toStoredSigningKeyFor alg t newJwk))
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
