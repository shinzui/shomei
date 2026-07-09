-- | Loading signing-key material, and refreshing it on a live server.
--
-- 'loadKeyMaterial' is __the__ stored→live load path: it reads every publishable key
-- (active + retired) and assembles the three things the runtime needs — the private key
-- that signs new tokens, the public key set the verifier trusts, and the precomputed JWKS
-- document served at @\/.well-known\/jwks.json@. 'bootstrapKeys' wraps it with first-boot
-- key generation; 'reloadKeys' wraps it with the swap-or-keep-last-good policy the
-- periodic refresh and the @SIGHUP@ handler both use.
--
-- Publishing retired keys alongside the active one is what makes rotation zero-downtime:
-- a token signed moments before @shomei-admin keys activate@ keeps verifying until it
-- expires, here and at every downstream that fetches the JWKS.
--
-- Private key material may be encrypted at rest (see "Shomei.Jwt.KeyProtection"). Only the
-- __signer__ is decrypted; the verifier key set and the published JWKS are built from the
-- public column, so a missing or wrong key-encryption key can never break verification of
-- outstanding tokens — only the minting of new ones.
--
-- Runs over a minimal stack — just 'SigningKeyStore' + 'Clock' + 'Database' +
-- @Error AuthError@ + 'IOE' against the pool — because it must run /before/ the full
-- 'Shomei.Server.App.Env' exists (there is no key yet to build it).
module Shomei.Server.Keys
  ( LoadedKeys (..),
    loadKeyMaterial,
    bootstrapKeys,
    reloadKeys,
    publishedKids,
    loadKekFromEnv,
    loadNamedKekFromEnv,
  )
where

import Crypto.JOSE.JWK (JWK, JWKSet)
import Data.Aeson (Value (Object))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import Data.Ord (Down (Down))
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool (Pool)
import Shomei.Domain.SigningKey (SigningAlgorithm, SigningKeyStatus (KeyActive), StoredSigningKey (..))
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SigningKeyStore
  ( SigningKeyStore,
    insertSigningKey,
    listActiveSigningKeys,
    listPublishableSigningKeys,
  )
import Shomei.Error (AuthError)
import Shomei.Jwt.Jwks (KeySet (..), jwksDocument, keySetPublicJwks)
import Shomei.Jwt.Key (generateSigningKeyFor, keyKid, toStoredSigningKeyFor)
import Shomei.Jwt.KeyProtection
  ( KeyDecryptError (..),
    KeyEncryptionKey,
    decryptStoredSigningKey,
    isEncryptedPrivateJwk,
    keyEncryptionKeyFromBase64,
    protectStoredSigningKey,
    publicJwkFromStored,
  )
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Prelude
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

-- | Read @SHOMEI_KEY_ENCRYPTION_KEY@ (32 bytes, base64).
loadKekFromEnv :: IO (Maybe KeyEncryptionKey)
loadKekFromEnv = loadNamedKekFromEnv "SHOMEI_KEY_ENCRYPTION_KEY"

-- | Read a KEK from the named environment variable. Absent or empty yields 'Nothing';
-- present but malformed is fatal, because a half-configured secret is worse than none — the
-- process would start, fail to decrypt, and look like a database problem.
loadNamedKekFromEnv :: String -> IO (Maybe KeyEncryptionKey)
loadNamedKekFromEnv name = do
  raw <- lookupEnv name
  case raw of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just v -> either (fatal . Text.unpack) (pure . Just) (keyEncryptionKeyFromBase64 (Text.pack v))
  where
    fatal reason = ioError (userError (name <> " " <> reason))

-- | Everything derived from the signing-key table in one load: the private key that signs
-- new tokens, the public key set the verifier trusts, and the precomputed JWKS document.
-- Swapped atomically on reload — readers see the old or the new record, never a mixture.
data LoadedKeys = LoadedKeys
  { signingKey :: !JWK,
    verifierJwks :: !JWKSet,
    jwksBody :: !Value
  }

-- | Load all publishable keys and assemble 'LoadedKeys'. A corrupt key row (one whose
-- stored JWK JSON does not parse, or whose ciphertext does not authenticate) fails the
-- whole load rather than being skipped silently: publishing a key set that is missing a key
-- downstreams may still hold tokens for is exactly the outage this module exists to prevent.
--
-- @mKek@ is needed only to decrypt the signer. Pass 'Nothing' when no
-- @SHOMEI_KEY_ENCRYPTION_KEY@ is configured; if any row is nonetheless encrypted, the load
-- fails with a message naming the variable rather than serving a server that cannot sign.
loadKeyMaterial :: Maybe KeyEncryptionKey -> Pool -> IO (Either Text LoadedKeys)
loadKeyMaterial mKek pool = do
  result :: Either AuthError [StoredSigningKey] <-
    runEff
      . runErrorNoCallStack
      . runDatabasePool pool
      . runClockIO
      . runSigningKeyStorePostgres
      $ listPublishableSigningKeys
  pure (either (Left . Text.pack . show) (assembleKeys mKek) result)

-- | Assemble the loaded rows. The signer is the active key with the greatest
-- @activatedAt@ ('Nothing' sorting lowest) — several simultaneously-active keys are
-- reachable only by hand-editing the table, and "newest activation wins" matches operator
-- intent. Every publishable key is published and trusted, the signer included.
--
-- Public material comes from @public_key_jwk@ and needs no key-encryption key; only the
-- signer's @private_key_jwk@ is decrypted.
assembleKeys :: Maybe KeyEncryptionKey -> [StoredSigningKey] -> Either Text LoadedKeys
assembleKeys mKek stored = do
  publics <- traverse toPublic stored
  signerRow <- maybe (Left "no active signing key") Right (newestActive stored)
  signerJwk <- first (decryptError signerRow) (decryptStoredSigningKey mKek signerRow)
  -- The signer's own row is in 'stored', so its public projection is in 'publics'.
  signerPub <-
    maybe (Left ("signing key " <> signerRow.keyId <> " has no public material")) Right $
      lookup signerRow.keyId [(sk.keyId, jwk) | (sk, jwk) <- publics]
  let others = [jwk | (sk, jwk) <- publics, sk.keyId /= signerRow.keyId]
  pure
    LoadedKeys
      { signingKey = signerJwk,
        verifierJwks = keySetPublicJwks (KeySet signerPub others),
        jwksBody = decodeJwks (jwksDocument (signerPub : others))
      }
  where
    toPublic sk = (\jwk -> (sk, jwk)) <$> first (publicError sk) (publicJwkFromStored sk)
    publicError sk err = "signing key " <> sk.keyId <> " has unparseable public JWK JSON: " <> err
    decryptError sk = \case
      KeyEncryptedButNoKek ->
        "signing keys are encrypted at rest but SHOMEI_KEY_ENCRYPTION_KEY is not set"
      KeyDecryptFailed ->
        "signing key "
          <> sk.keyId
          <> " did not decrypt: SHOMEI_KEY_ENCRYPTION_KEY is wrong, or the row was tampered with"
      MalformedEncryptedKey reason ->
        "signing key " <> sk.keyId <> " has a malformed encrypted private key: " <> reason
      KeyJsonInvalid reason ->
        "signing key " <> sk.keyId <> " has unparseable private JWK JSON: " <> reason
    newestActive rows =
      listToMaybe (sortOn (Down . (.activatedAt)) [sk | sk <- rows, sk.status == KeyActive])
    -- jwksDocument emits a JWKSet object, so the decode cannot fail; the fallback keeps
    -- the total signature rather than partially matching on it.
    decodeJwks = fromMaybe (Object KM.empty) . Aeson.decode

-- | Establish key material at boot. Generates and persists one active key for @alg@ on
-- first boot (guarded on "no active key", so restarts reuse the existing key and
-- previously-issued tokens stay verifiable); then loads via 'loadKeyMaterial'. Unlike a
-- reload, a failure here is fatal: there is no previous material to fall back on.
--
-- Also enforces the at-rest-encryption boot policy. Encrypted rows with no KEK abort the
-- boot (the load itself fails, naming the variable); plaintext rows only warn, so upgrading
-- an existing deployment never breaks — encryption stays opt-in until an operator runs
-- @shomei-admin keys encrypt-at-rest@.
bootstrapKeys :: Maybe KeyEncryptionKey -> SigningAlgorithm -> Pool -> IO LoadedKeys
bootstrapKeys mKek alg pool = do
  result :: Either AuthError [StoredSigningKey] <-
    runEff
      . runErrorNoCallStack
      . runDatabasePool pool
      . runClockIO
      . runSigningKeyStorePostgres
      $ ensureActiveKey mKek alg >> listPublishableSigningKeys
  rows <- either (ioError . userError . show) pure result
  warnAboutProtection mKek rows
  loaded <- loadKeyMaterial mKek pool
  either (ioError . userError . Text.unpack) pure loaded

-- | Nudge the operator toward at-rest encryption, in whichever direction they are missing.
-- (The dangerous case — encrypted rows and no KEK — is not a warning: 'loadKeyMaterial'
-- refuses outright.)
--
-- Only publishable rows are examined, because those are what the loader reads. A @pending@
-- or @revoked@ row could be encrypted without triggering the warning; it would surface at
-- the next @keys activate@.
warnAboutProtection :: Maybe KeyEncryptionKey -> [StoredSigningKey] -> IO ()
warnAboutProtection mKek rows = case mKek of
  Nothing
    | not (any encrypted rows) ->
        warn "signing keys are stored unencrypted; set SHOMEI_KEY_ENCRYPTION_KEY and run 'shomei-admin keys encrypt-at-rest' to protect them"
  Just _
    | any (not . encrypted) rows ->
        warn "some signing keys are still stored unencrypted; run 'shomei-admin keys encrypt-at-rest' to protect them"
  _ -> pure ()
  where
    encrypted sk = isEncryptedPrivateJwk sk.privateKeyJwk
    warn msg = hPutStrLn stderr ("[shomei] warning: " <> msg)

-- | Generate and insert an active key for @alg@ when the store has no active key. The new
-- key is encrypted before it is persisted whenever a KEK is configured, so a fresh
-- deployment never writes a plaintext private key.
ensureActiveKey :: (SigningKeyStore :> es, Clock :> es, IOE :> es) => Maybe KeyEncryptionKey -> SigningAlgorithm -> Eff es ()
ensureActiveKey mKek alg = do
  active <- listActiveSigningKeys
  when (null active) do
    t <- now
    jwk <- liftIO (generateSigningKeyFor alg)
    protected <- liftIO (protectStoredSigningKey mKek (toStoredSigningKeyFor alg t jwk))
    insertSigningKey protected

-- | Reload key material and swap it in. On failure keep the last good material and log to
-- stderr: an operator mistake mid-rotation (say, retiring the only active key) must not
-- take the server down — it can still verify everything it issued and still sign with the
-- stale key, which downstreams still trust. The @\/ready@ probe fails meanwhile, so
-- orchestration notices.
--
-- Safe from any thread: a plain 'writeIORef' of an immutable record, so a concurrent
-- request sees the old or the new material in full, never a mixture.
reloadKeys :: Maybe KeyEncryptionKey -> Pool -> IORef LoadedKeys -> IO ()
reloadKeys mKek pool ref = do
  before <- readIORef ref
  loadKeyMaterial mKek pool >>= either warn (swap before)
  where
    swap before after = do
      writeIORef ref after
      -- Only announce a reload that changed something, so the steady-state log stays quiet
      -- at one reload per refresh interval.
      when (kidsOf before /= kidsOf after) do
        hPutStrLn stderr $
          "[shomei] signing keys reloaded: active="
            <> Text.unpack (keyKid after.signingKey)
            <> " published="
            <> Text.unpack (Text.intercalate "," (publishedKids after))
    warn reason =
      hPutStrLn stderr ("[shomei] key reload failed: " <> Text.unpack reason <> "; keeping previous key material")
    kidsOf ks = (keyKid ks.signingKey, publishedKids ks)

-- | The @kid@ of every key in the published JWKS document, in document order.
publishedKids :: LoadedKeys -> [Text]
publishedKids ks = case ks.jwksBody of
  Object top | Just (Aeson.Array arr) <- KM.lookup "keys" top -> mapMaybe kidOf (toList arr)
  _ -> []
  where
    kidOf (Object k) | Just (Aeson.String kid) <- KM.lookup "kid" k = Just kid
    kidOf _ = Nothing
