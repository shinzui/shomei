-- | Argon2id password hashing, opaque-token generation, and SHA-256 token hashing, plus
-- the @effectful@ interpreters for the 'PasswordHasher' and 'TokenGen' ports. These live
-- here (not in @shomei-core@) because they need @crypton@/@ram@ — infrastructure we keep
-- out of the transport-agnostic core.
module Shomei.Crypto
  ( hashPasswordArgon2id,
    verifyPasswordArgon2id,
    runPasswordHasherCrypto,
    generateOpaqueToken,
    hashRefreshToken,
    runTokenGenCrypto,
    sha256Hex,
  )
where

import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.KDF.Argon2 qualified as Argon2
import Crypto.Random (getRandomBytes)
import Data.ByteArray (constEq, convert)
import Data.ByteArray.Encoding (Base (Base16, Base64, Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
import Shomei.Domain.RefreshToken (RefreshToken (..), RefreshTokenHash (..))
import Shomei.Effect.PasswordHasher (PasswordHasher (..))
import Shomei.Effect.TokenGen (TokenGen (..))
import Shomei.Prelude

-- CRITICAL: crypton's 'Argon2.defaultOptions' is Argon2i with iterations = 1 — too weak
-- and the wrong variant for password storage. Set Argon2id and raise the cost explicitly.
argonOptions :: Argon2.Options
argonOptions =
  Argon2.Options
    { Argon2.iterations = 3,
      Argon2.memory = 64 * 1024, -- KiB == 64 MiB
      Argon2.parallelism = 1,
      Argon2.variant = Argon2.Argon2id,
      Argon2.version = Argon2.Version13
    }

saltLen, hashLen :: Int
saltLen = 16
hashLen = 32

-- | crypton's Argon2 'hash' returns a 'CryptoFailable' (it only fails on invalid params).
deriveArgon2 :: ByteString -> ByteString -> ByteString
deriveArgon2 pw salt =
  case Argon2.hash argonOptions pw salt hashLen of
    CryptoPassed digest -> digest
    CryptoFailed e -> error ("Argon2 hashing failed: " <> show e)

-- | Returns @"argon2id$<b64 salt>$<b64 hash>"@.
hashPasswordArgon2id :: Text -> IO PasswordHash
hashPasswordArgon2id pw = do
  salt <- getRandomBytes saltLen :: IO ByteString
  let digest = deriveArgon2 (TE.encodeUtf8 pw) salt
      b64 b = TE.decodeUtf8 (convertToBase Base64 b)
  pure (PasswordHash ("argon2id$" <> b64 salt <> "$" <> b64 digest))

-- | Re-derive the hash from the stored salt and compare in constant time.
verifyPasswordArgon2id :: Text -> PasswordHash -> Bool
verifyPasswordArgon2id pw (PasswordHash stored) =
  case Text.splitOn "$" stored of
    ["argon2id", saltB64, hashB64]
      | Right salt <- b64dec saltB64,
        Right want <- b64dec hashB64 ->
          constEq (deriveArgon2 (TE.encodeUtf8 pw) salt) want
    _ -> False
  where
    b64dec t = convertFromBase Base64 (TE.encodeUtf8 t) :: Either String ByteString

-- | A lower-case hex SHA-256 of a UTF-8 'Text'. Used by the server to derive the abuse
-- store's account key from a normalized email, so the brute-force tables never hold plaintext
-- addresses (EP-2).
sha256Hex :: Text -> Text
sha256Hex t =
  TE.decodeUtf8 (convertToBase Base16 (hashWith SHA256 (TE.encodeUtf8 t)))

runPasswordHasherCrypto :: (IOE :> es) => Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasherCrypto = interpret_ \case
  HashPassword (PlainPassword pw) -> liftIO (hashPasswordArgon2id pw)
  VerifyPassword (PlainPassword pw) hash -> pure (verifyPasswordArgon2id pw hash)

-- | A fresh opaque refresh token: base64url of 32 random bytes (the secret handed to the
-- client; only its hash is stored — see 'hashRefreshToken').
generateOpaqueToken :: IO Text
generateOpaqueToken = do
  raw <- getRandomBytes 32 :: IO ByteString
  pure (TE.decodeUtf8 (convertToBase Base64URLUnpadded raw))

-- | SHA-256 of the opaque token, base64url-encoded: what we persist in @token_hash@.
hashRefreshToken :: Text -> Text
hashRefreshToken tok =
  TE.decodeUtf8
    (convertToBase Base64URLUnpadded (convert (hashWith SHA256 (TE.encodeUtf8 tok)) :: ByteString))

runTokenGenCrypto :: (IOE :> es) => Eff (TokenGen : es) a -> Eff es a
runTokenGenCrypto = interpret_ \case
  GenerateOpaqueToken -> liftIO (RefreshToken <$> generateOpaqueToken)
  HashRefreshToken (RefreshToken t) -> pure (RefreshTokenHash (hashRefreshToken t))
