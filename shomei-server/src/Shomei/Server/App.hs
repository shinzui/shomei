{- | The Shōmei server effect stack and its runner.

This single module fixes the one effect stack every server-side action runs in
('AppEffects'), the environment needed to interpret it ('Env'), and the runner that
interprets it down to IO ('runAppIO'). It is servant-free: 'runAppIO' returns
@IO (Either AuthError a)@ with no HTTP types, so the same stack is reusable by the
automated test and (later) the embedded mode, not just the standalone warp boot.

The stack is the EP-5 servant port stack (@Shomei.Servant.Seam.AppEffects@) /extended/
with the two effects the PostgreSQL interpreters need beneath the ports: 'Database'
(the hasql layer the store interpreters issue SQL through) and @Error AuthError@ (the
channel the interpreters use to surface infrastructure failures). EP-5's handlers run in
the smaller stack and are bridged onto this one with @inject@ at assembly time
(see "Shomei.Server.Boot").
-}
module Shomei.Server.App (
    AppEffects,
    Env (..),
    runAppIO,
) where

import Shomei.Prelude

import "effectful-core" Effectful (Eff, IOE, runEff)
import "effectful-core" Effectful.Error.Static (Error, runErrorNoCallStack)
import "hasql-pool" Hasql.Pool (Pool)
import "jose" Crypto.JOSE.JWK (JWK, JWKSet)

import Shomei.Config (ShomeiConfig)
import Shomei.Error (AuthError)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.SigningKeyStore (SigningKeyStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TokenVerifier (TokenVerifier)
import Shomei.Effect.UserStore (UserStore)

import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Jwt.Sign (runTokenSignerJwt)
import Shomei.Jwt.Verify (runTokenVerifierJwt)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)

{- | The single effect stack the assembled server interprets. The high-level ports
come first (the handler's view); 'Database', @Error AuthError@, and 'IOE' sit beneath
them because the store/publisher/signing-key interpreters issue SQL through 'Database'
and surface failures through @Error AuthError@.
-}
type AppEffects =
    '[ UserStore
     , CredentialStore
     , SessionStore
     , RefreshTokenStore
     , PasswordHasher
     , TokenSigner
     , TokenVerifier
     , AuthEventPublisher
     , SigningKeyStore
     , Clock
     , TokenGen
     , Database
     , Error AuthError
     , IOE
     ]

{- | Everything the runtime needs to interpret 'AppEffects' down to IO: the live hasql
pool, the loaded config, the active /private/ signing key (used by the signer), and the
public 'JWKSet' (used by the verifier and the JWKS endpoint).
-}
data Env = Env
    { envPool :: !Pool
    , envConfig :: !ShomeiConfig
    , envKey :: !JWK
    , envJwks :: !JWKSet
    }

{- | Interpret the whole 'AppEffects' stack down to IO, surfacing an infrastructure
'AuthError' as 'Left'. The composition is written outermost-last: read right-to-left it
peels 'AppEffects' head-to-tail. The ORDER is load-bearing — every SQL-issuing port is
interpreted ABOVE 'runDatabasePool' (so 'Database' is still in scope when they run), and
@Error AuthError@/'IOE' sit at the base. This is the same shape as @shomei-postgres@'s
own test harness, extended with EP-4's real signer/verifier interpreters.
-}
runAppIO :: Env -> Eff AppEffects a -> IO (Either AuthError a)
runAppIO env =
    runEff
        . runErrorNoCallStack
        . runDatabasePool env.envPool
        . runTokenGenCrypto
        . runClockIO
        . runSigningKeyStorePostgres
        . runAuthEventPublisherPostgres
        . runTokenVerifierJwt env.envJwks env.envConfig
        . runTokenSignerJwt env.envKey env.envConfig
        . runPasswordHasherCrypto
        . runRefreshTokenStorePostgres
        . runSessionStorePostgres
        . runCredentialStorePostgres
        . runUserStorePostgres
