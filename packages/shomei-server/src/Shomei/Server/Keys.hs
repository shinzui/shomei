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

import "text" Data.Text qualified as Text

import "effectful-core" Effectful (Eff, IOE, runEff, (:>))
import "effectful-core" Effectful.Error.Static (runErrorNoCallStack)
import "hasql-pool" Hasql.Pool (Pool)
import "jose" Crypto.JOSE.JWK (JWK, JWKSet)

import Shomei.Domain.SigningKey (StoredSigningKey)
import Shomei.Error (AuthError)
import Shomei.Port.Clock (Clock, now)
import Shomei.Port.SigningKeyStore (SigningKeyStore, insertSigningKey, listActiveSigningKeys)

import Shomei.Jwt.Jwks (KeySet (..), keySetPublicJwks)
import Shomei.Jwt.Key (fromStoredSigningKey, generateSigningKey, toStoredSigningKey)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)

{- | Return the active /private/ signing key and the public 'JWKSet' (built from the
active key). Generates+persists an ES256 key on first boot; otherwise loads the
existing active key.
-}
bootstrapKeys :: Pool -> IO (JWK, JWKSet)
bootstrapKeys pool = do
    result :: Either AuthError StoredSigningKey <-
        runEff
            . runErrorNoCallStack
            . runDatabasePool pool
            . runClockIO
            . runSigningKeyStorePostgres
            $ ensureActiveKey
    stored <- either (ioError . userError . show) pure result
    jwk <- either (ioError . userError . Text.unpack) pure (fromStoredSigningKey stored)
    pure (jwk, keySetPublicJwks (KeySet jwk []))

-- | List the active keys; if none, generate one ES256 key and insert it Active.
ensureActiveKey :: (SigningKeyStore :> es, Clock :> es, IOE :> es) => Eff es StoredSigningKey
ensureActiveKey = do
    active <- listActiveSigningKeys
    case active of
        (k : _) -> pure k
        [] -> do
            t <- now
            jwk <- liftIO generateSigningKey
            let sk = toStoredSigningKey t jwk
            insertSigningKey sk
            pure sk
