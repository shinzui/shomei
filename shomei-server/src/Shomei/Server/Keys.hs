{- | Signing-key bootstrap.

On first boot (no active key) generate one ES256 key and persist it Active; otherwise
reuse the persisted key. Then load the active /private/ JWK and build the public
'JWKSet'. Idempotent: generation is guarded on "no active key", so re-running the server
reuses the existing key and previously-issued tokens stay verifiable across restarts.

Runs over a minimal stack — just 'SigningKeyStore' + 'Clock' + 'Database' +
@Error AuthError@ + 'IOE' against the pool — because it must run /before/ the full
'Shomei.Server.App.Env' exists (there is no key yet to build it).
-}
module Shomei.Server.Keys (
    bootstrapKeys,
) where

import Shomei.Prelude

import Data.Text qualified as Text

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool (Pool)
import Crypto.JOSE.JWK (JWK, JWKSet)

import Shomei.Domain.SigningKey (SigningAlgorithm, StoredSigningKey)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SigningKeyStore (SigningKeyStore, insertSigningKey, listActiveSigningKeys)
import Shomei.Error (AuthError)

import Shomei.Jwt.Jwks (KeySet (..), keySetPublicJwks)
import Shomei.Jwt.Key (fromStoredSigningKey, generateSigningKeyFor, toStoredSigningKeyFor)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)

{- | Return the active /private/ signing key and the public 'JWKSet' (built from the
active key). Generates+persists a key for the requested 'SigningAlgorithm' on first
boot; otherwise loads the existing active key (regardless of @alg@, since generation
is guarded on "no active key" — changing the configured algorithm after a key exists
has no effect until you rotate).
-}
bootstrapKeys :: SigningAlgorithm -> Pool -> IO (JWK, JWKSet)
bootstrapKeys alg pool = do
    result :: Either AuthError StoredSigningKey <-
        runEff
            . runErrorNoCallStack
            . runDatabasePool pool
            . runClockIO
            . runSigningKeyStorePostgres
            $ ensureActiveKey alg
    stored <- either (ioError . userError . show) pure result
    jwk <- either (ioError . userError . Text.unpack) pure (fromStoredSigningKey stored)
    pure (jwk, keySetPublicJwks (KeySet jwk []))

-- | List the active keys; if none, generate one key for @alg@ and insert it Active.
ensureActiveKey :: (SigningKeyStore :> es, Clock :> es, IOE :> es) => SigningAlgorithm -> Eff es StoredSigningKey
ensureActiveKey alg = do
    active <- listActiveSigningKeys
    case active of
        (k : _) -> pure k
        [] -> do
            t <- now
            jwk <- liftIO (generateSigningKeyFor alg)
            let sk = toStoredSigningKeyFor alg t jwk
            insertSigningKey sk
            pure sk
