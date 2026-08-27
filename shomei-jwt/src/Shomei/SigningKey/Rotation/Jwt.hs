-- | Key rotation and the live published JWKS, written against the
-- 'SigningKeyStore' and 'Clock' port effects only (no IO key storage of its own).
--
-- Rotation is intentionally simple: generate a new active key, insert it, and mark
-- the previously-active key 'KeyRetired'. The published JWKS includes every publishable
-- key ('KeyActive' and 'KeyRetired'), so tokens signed just before rotation keep
-- verifying until they expire (zero-downtime rotation).
module Shomei.SigningKey.Rotation.Jwt
  ( rotateSigningKey,
    currentJwks,
  )
where

import Crypto.JOSE.JWK (JWK)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (rights)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Shomei.Prelude
import Shomei.SigningKey.Domain (SigningAlgorithm)
import Shomei.SigningKey.Jwks.Jwt (jwksDocument)
import Shomei.SigningKey.Key.Jwt (generateSigningKeyFor, toStoredSigningKeyFor)
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey, protectStoredSigningKey, publicJwkFromStored)
import Shomei.SigningKey.Store
  ( SigningKeyStore,
    listPublishableSigningKeys,
    replaceActiveSigningKey,
  )
import Shomei.Time.Store (Clock, now)

-- | Generate and encrypt a new active key, then retire whatever was active. Returns the live
-- 'JWK' so the caller can sign with it immediately.
rotateSigningKey ::
  (IOE :> es, SigningKeyStore :> es, Clock :> es) =>
  KeyEncryptionKey ->
  SigningAlgorithm ->
  Eff es JWK
rotateSigningKey kek alg = do
  t <- now
  newJwk <- liftIO (generateSigningKeyFor alg)
  stored <- liftIO (either (ioError . userError . Text.unpack) pure (toStoredSigningKeyFor alg t newJwk))
  protected <- liftIO (protectStoredSigningKey kek stored)
  replaceActiveSigningKey protected t
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
