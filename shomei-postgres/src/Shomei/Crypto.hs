-- | Argon2id password hashing, opaque-token generation, and SHA-256 token hashing, plus
-- the @effectful@ interpreters for the 'PasswordHasher' and 'TokenGen' ports. These live
-- here (not in @shomei-core@) because they need @crypton@/@ram@ — infrastructure we keep
-- out of the transport-agnostic core.
module Shomei.Crypto
  ( Argon2Params (..),
    defaultArgon2Params,
    argon2WarningFloor,
    hashPasswordArgon2id,
    verifyPasswordArgon2id,
    dummyHashFor,
    runPasswordHasherCrypto,
    generateOpaqueToken,
    hashRefreshToken,
    runTokenGenCrypto,
    sha256Hex,
  )
where

import Control.Exception (evaluate)
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
import Text.Read (readMaybe)

-- | The Argon2id cost parameters used to hash /new/ passwords.
--
-- Verification never consults this record: a stored hash carries the parameters it was made
-- with (see 'hashPasswordArgon2id'), so changing these values cannot invalidate a single
-- existing credential.
data Argon2Params = Argon2Params
  { -- | memory cost in KiB
    memoryKiB :: !Int,
    -- | time cost (passes over memory)
    iterations :: !Int,
    -- | lanes
    parallelism :: !Int
  }
  deriving stock (Show, Eq, Generic)

-- | 64 MiB, 3 iterations, 1 lane: at or above every OWASP-recommended Argon2id configuration,
-- and the values every Shōmei release has shipped.
defaultArgon2Params :: Argon2Params
defaultArgon2Params =
  Argon2Params
    { memoryKiB = 64 * 1024,
      iterations = 3,
      parallelism = 1
    }

-- | The parameters implied by the legacy @argon2id$salt$hash@ format, which recorded none.
-- They are the only values that format was ever produced with, so a legacy hash re-derives
-- correctly with exactly these.
--
-- CRITICAL: crypton's 'Argon2.defaultOptions' is Argon2i with iterations = 1 — too weak and
-- the wrong variant for password storage. Set Argon2id and raise the cost explicitly.
legacyArgonOptions :: Argon2.Options
legacyArgonOptions = toOptions defaultArgon2Params

toOptions :: Argon2Params -> Argon2.Options
toOptions p =
  Argon2.Options
    { Argon2.iterations = fromIntegral p.iterations,
      Argon2.memory = fromIntegral p.memoryKiB,
      Argon2.parallelism = fromIntegral p.parallelism,
      Argon2.variant = Argon2.Argon2id,
      Argon2.version = Argon2.Version13
    }

-- | @Nothing@ when the parameters meet the recommended floor, otherwise the reason they do
-- not. The floor (19 MiB, 2 iterations, 1 lane) is the weakest OWASP-endorsed Argon2id
-- configuration. Callers warn; they do not refuse to start, because test rigs and
-- resource-starved development environments legitimately want cheap hashing.
argon2WarningFloor :: Argon2Params -> Maybe Text
argon2WarningFloor p
  | p.memoryKiB < 19456 || p.iterations < 2 || p.parallelism < 1 =
      Just
        ( "configured Argon2 parameters are below the recommended floor (m="
            <> Text.pack (show p.memoryKiB)
            <> "KiB,t="
            <> Text.pack (show p.iterations)
            <> ",p="
            <> Text.pack (show p.parallelism)
            <> "); passwords hashed with them are weaker"
        )
  | otherwise = Nothing

saltLen, hashLen :: Int
saltLen = 16
hashLen = 32

-- | @Version13@ is 0x13 == 19; the number that appears in the @v=@ field.
phcVersion :: Int
phcVersion = 19

-- | crypton's Argon2 'hash' returns a 'CryptoFailable' (it only fails on invalid params).
deriveArgon2 :: Argon2.Options -> ByteString -> ByteString -> ByteString
deriveArgon2 opts pw salt =
  case Argon2.hash opts pw salt hashLen of
    CryptoPassed digest -> digest
    CryptoFailed e -> error ("Argon2 hashing failed: " <> show e)

b64enc :: ByteString -> Text
b64enc b = TE.decodeUtf8 (convertToBase Base64 b)

b64dec :: Text -> Either String ByteString
b64dec t = convertFromBase Base64 (TE.encodeUtf8 t)

-- | Encode a hash in the self-describing PHC-style string format:
-- @$argon2id$v=19$m=65536,t=3,p=1$\<b64 salt\>$\<b64 digest\>@.
--
-- (Base64 here is padded, unlike the strict PHC specification's unpadded alphabet. Nothing
-- outside Shōmei reads these strings, and @=@ never collides with the @$@ separator.)
phcEncode :: Argon2Params -> ByteString -> ByteString -> Text
phcEncode p salt digest =
  "$argon2id$v="
    <> Text.pack (show phcVersion)
    <> "$m="
    <> Text.pack (show p.memoryKiB)
    <> ",t="
    <> Text.pack (show p.iterations)
    <> ",p="
    <> Text.pack (show p.parallelism)
    <> "$"
    <> b64enc salt
    <> "$"
    <> b64enc digest

-- | Parse @m=65536,t=3,p=1@. Order is fixed: this reads only strings we produce.
parsePhcParams :: Text -> Maybe Argon2Params
parsePhcParams t = case Text.splitOn "," t of
  [m, i, p] ->
    Argon2Params
      <$> field "m=" m
      <*> field "t=" i
      <*> field "p=" p
  _ -> Nothing
  where
    field prefix raw = do
      rest <- Text.stripPrefix prefix raw
      n <- readMaybe (Text.unpack rest)
      -- crypton would reject these later with a CryptoFailed; refusing here keeps a malformed
      -- stored hash from crashing a login.
      if n > 0 then Just n else Nothing

-- | Hash a password with the given parameters, embedding them in the returned string so that
-- verification never has to guess. A later change to @params@ leaves this hash verifiable.
hashPasswordArgon2id :: Argon2Params -> Text -> IO PasswordHash
hashPasswordArgon2id params pw = do
  salt <- getRandomBytes saltLen :: IO ByteString
  let digest = deriveArgon2 (toOptions params) (TE.encodeUtf8 pw) salt
  pure (PasswordHash (phcEncode params salt digest))

-- | Re-derive the hash with the parameters the stored string carries, and compare in constant
-- time.
--
-- Two formats are accepted. The PHC-style string produced by 'hashPasswordArgon2id' splits
-- into @["", "argon2id", "v=19", "m=…,t=…,p=…", salt, digest]@ and re-derives with its own
-- parameters. The legacy @argon2id$salt$digest@ string, which recorded no parameters, splits
-- into three parts and re-derives with 'legacyArgonOptions'. Anything else — including a
-- PHC-shaped string with unparseable parameters — is 'False'.
--
-- A malformed hash therefore returns 'False' /without hashing/ (~9 µs versus ~100 ms). That
-- is a timing oracle if a real credential can ever be malformed; it cannot, because only this
-- module writes them.
verifyPasswordArgon2id :: Text -> PasswordHash -> Bool
verifyPasswordArgon2id pw (PasswordHash stored) =
  case Text.splitOn "$" stored of
    ["", "argon2id", version, paramsText, saltB64, hashB64]
      | version == "v=" <> Text.pack (show phcVersion),
        Just params <- parsePhcParams paramsText ->
          check (toOptions params) saltB64 hashB64
    ["argon2id", saltB64, hashB64] -> check legacyArgonOptions saltB64 hashB64
    _ -> False
  where
    check opts saltB64 hashB64
      | Right salt <- b64dec saltB64,
        Right want <- b64dec hashB64 =
          constEq (deriveArgon2 opts (TE.encodeUtf8 pw) salt) want
      | otherwise = False

-- | A well-formed hash carrying @params@, whose preimage is nobody's password.
--
-- Verifying against it costs exactly what verifying a real credential hashed with the same
-- parameters costs, which is the whole point: the login paths that never reach a stored hash
-- (unknown account, suspended user) burn this instead, so a miss and a wrong password are
-- indistinguishable by response time. The salt and digest are fixed constants — the digest is
-- not the Argon2 output of anything, and nothing is ever expected to verify against it.
--
-- Both must stay valid base64 of the right lengths: 'verifyPasswordArgon2id' returns 'False'
-- /without hashing/ on a malformed string, which would silently reopen the oracle this closes.
dummyHashFor :: Argon2Params -> PasswordHash
dummyHashFor params = PasswordHash (phcEncode params salt digest)
  where
    salt = TE.encodeUtf8 (Text.replicate saltLen "\x2a") -- 16 bytes of '*'
    digest = TE.encodeUtf8 (Text.replicate hashLen "\x2a") -- 32 bytes of '*'

-- | A lower-case hex SHA-256 of a UTF-8 'Text'. Used by the server to derive the abuse
-- store's account key from a normalized email, so the brute-force tables never hold plaintext
-- addresses (EP-2).
sha256Hex :: Text -> Text
sha256Hex t =
  TE.decodeUtf8 (convertToBase Base16 (hashWith SHA256 (TE.encodeUtf8 t)))

-- | Interpret the 'PasswordHasher' port with real Argon2id at @params@.
--
-- 'VerifyPassword' is forced with 'evaluate' rather than returned as a thunk. The pure
-- @verifyPasswordArgon2id@ is ~100 ms of work; left lazy it would be forced later, on whatever
-- thread first looked at the 'Bool' — possibly during response assembly, and certainly outside
-- any bound a caller installs around this interpreter.
runPasswordHasherCrypto :: (IOE :> es) => Argon2Params -> Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasherCrypto params = interpret_ \case
  HashPassword (PlainPassword pw) -> liftIO (hashPasswordArgon2id params pw)
  VerifyPassword (PlainPassword pw) hash -> liftIO (evaluate (verifyPasswordArgon2id pw hash))
  -- Derive against a dummy hash carrying the *configured* parameters, so this costs exactly
  -- what the 'VerifyPassword' above costs. Never a constant hash: its baked-in parameters
  -- would drift from the configured ones and reopen the login timing oracle.
  VerifyPasswordDummy (PlainPassword pw) ->
    liftIO (void (evaluate (verifyPasswordArgon2id pw (dummyHashFor params))))

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
