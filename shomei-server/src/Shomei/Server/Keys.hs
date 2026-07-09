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
-- Runs over a minimal stack — just 'SigningKeyStore' + 'Clock' + 'Database' +
-- @Error AuthError@ + 'IOE' against the pool — because it must run /before/ the full
-- 'Shomei.Server.App.Env' exists (there is no key yet to build it).
module Shomei.Server.Keys
  ( LoadedKeys (..),
    loadKeyMaterial,
    bootstrapKeys,
    reloadKeys,
    publishedKids,
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
import Shomei.Jwt.Key (fromStoredSigningKey, generateSigningKeyFor, keyKid, toStoredSigningKeyFor)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Prelude
import System.IO (hPutStrLn, stderr)

-- | Everything derived from the signing-key table in one load: the private key that signs
-- new tokens, the public key set the verifier trusts, and the precomputed JWKS document.
-- Swapped atomically on reload — readers see the old or the new record, never a mixture.
data LoadedKeys = LoadedKeys
  { signingKey :: !JWK,
    verifierJwks :: !JWKSet,
    jwksBody :: !Value
  }

-- | Load all publishable keys and assemble 'LoadedKeys'. A corrupt key row (one whose
-- stored JWK JSON does not parse) fails the whole load rather than being skipped
-- silently: publishing a key set that is missing a key downstreams may still hold tokens
-- for is exactly the outage this module exists to prevent.
loadKeyMaterial :: Pool -> IO (Either Text LoadedKeys)
loadKeyMaterial pool = do
  result :: Either AuthError [StoredSigningKey] <-
    runEff
      . runErrorNoCallStack
      . runDatabasePool pool
      . runClockIO
      . runSigningKeyStorePostgres
      $ listPublishableSigningKeys
  pure (either (Left . Text.pack . show) assembleKeys result)

-- | Assemble the loaded rows. The signer is the active key with the greatest
-- @activatedAt@ ('Nothing' sorting lowest) — several simultaneously-active keys are
-- reachable only by hand-editing the table, and "newest activation wins" matches operator
-- intent. Every publishable key is published and trusted, the signer included.
assembleKeys :: [StoredSigningKey] -> Either Text LoadedKeys
assembleKeys stored = do
  live <- traverse toLive stored
  signer <- maybe (Left "no active signing key") Right (newestActive live)
  let others = [jwk | (sk, jwk) <- live, sk.keyId /= fst signer]
      signerJwk = snd signer
  pure
    LoadedKeys
      { signingKey = signerJwk,
        verifierJwks = keySetPublicJwks (KeySet signerJwk others),
        jwksBody = decodeJwks (jwksDocument (signerJwk : others))
      }
  where
    toLive sk = (\jwk -> (sk, jwk)) <$> first (context sk) (fromStoredSigningKey sk)
    context sk err = "signing key " <> sk.keyId <> " has unparseable JWK JSON: " <> err
    newestActive live =
      case sortOn (Down . (.activatedAt) . fst) [p | p@(sk, _) <- live, sk.status == KeyActive] of
        ((sk, jwk) : _) -> Just (sk.keyId, jwk)
        [] -> Nothing
    -- jwksDocument emits a JWKSet object, so the decode cannot fail; the fallback keeps
    -- the total signature rather than partially matching on it.
    decodeJwks = fromMaybe (Object KM.empty) . Aeson.decode

-- | Establish key material at boot. Generates and persists one active key for @alg@ on
-- first boot (guarded on "no active key", so restarts reuse the existing key and
-- previously-issued tokens stay verifiable); then loads via 'loadKeyMaterial'. Unlike a
-- reload, a failure here is fatal: there is no previous material to fall back on.
bootstrapKeys :: SigningAlgorithm -> Pool -> IO LoadedKeys
bootstrapKeys alg pool = do
  result :: Either AuthError () <-
    runEff
      . runErrorNoCallStack
      . runDatabasePool pool
      . runClockIO
      . runSigningKeyStorePostgres
      $ ensureActiveKey alg
  either (ioError . userError . show) pure result
  loaded <- loadKeyMaterial pool
  either (ioError . userError . Text.unpack) pure loaded

-- | Generate and insert an active key for @alg@ when the store has no active key.
ensureActiveKey :: (SigningKeyStore :> es, Clock :> es, IOE :> es) => SigningAlgorithm -> Eff es ()
ensureActiveKey alg = do
  active <- listActiveSigningKeys
  when (null active) do
    t <- now
    jwk <- liftIO (generateSigningKeyFor alg)
    insertSigningKey (toStoredSigningKeyFor alg t jwk)

-- | Reload key material and swap it in. On failure keep the last good material and log to
-- stderr: an operator mistake mid-rotation (say, retiring the only active key) must not
-- take the server down — it can still verify everything it issued and still sign with the
-- stale key, which downstreams still trust. The @\/ready@ probe fails meanwhile, so
-- orchestration notices.
--
-- Safe from any thread: a plain 'writeIORef' of an immutable record, so a concurrent
-- request sees the old or the new material in full, never a mixture.
reloadKeys :: Pool -> IORef LoadedKeys -> IO ()
reloadKeys pool ref = do
  before <- readIORef ref
  loadKeyMaterial pool >>= either warn (swap before)
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
