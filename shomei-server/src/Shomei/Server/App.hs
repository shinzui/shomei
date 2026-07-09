-- | The Shōmei server effect stack and its runner.
--
-- This single module fixes the one effect stack every server-side action runs in
-- ('AppEffects'), the environment needed to interpret it ('Env'), and the runner that
-- interprets it down to IO ('runAppIO'). It is servant-free: 'runAppIO' returns
-- @IO (Either AuthError a)@ with no HTTP types, so the same stack is reusable by the
-- automated test and (later) the embedded mode, not just the standalone warp boot.
--
-- The stack is the EP-5 servant port stack (@Shomei.Servant.Seam.AppEffects@) /extended/
-- with the two effects the PostgreSQL interpreters need beneath the ports: 'Database'
-- (the hasql layer the store interpreters issue SQL through) and @Error AuthError@ (the
-- channel the interpreters use to surface infrastructure failures). EP-5's handlers run in
-- the smaller stack and are bridged onto this one with @inject@ at assembly time
-- (see "Shomei.Server.Boot").
module Shomei.Server.App
  ( AppEffects,
    Env (..),
    runAppIO,
  )
where

import Data.IORef (IORef, readIORef)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Network.HTTP.Client (Manager)
import Shomei.Config (ShomeiConfig (passwordPolicy), webauthnConfig)
import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Domain.Password (PasswordPolicy (breachCheckTimeoutMs))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.AuthEventReader (AuthEventReader)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore)
import Shomei.Effect.Notifier (Notifier)
import Shomei.Effect.PasskeyStore (PasskeyStore)
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.PasswordResetTokenStore (PasswordResetTokenStore)
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.SigningKeyStore (SigningKeyStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TokenVerifier (TokenVerifier)
import Shomei.Effect.UserStore (UserStore)
import Shomei.Effect.VerificationTokenStore (VerificationTokenStore)
import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)
import Shomei.Error (AuthError)
import Shomei.Jwt.Sign (runTokenSignerJwt)
import Shomei.Jwt.Verify (runTokenVerifierJwt)
import Shomei.Notify (runNotifierFromConfig)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.AuthEventReader (runAuthEventReaderPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.LoginAttemptStore (runLoginAttemptStorePostgres)
import Shomei.Postgres.PasskeyStore (runPasskeyStorePostgres)
import Shomei.Postgres.PasswordResetTokenStore (runPasswordResetTokenStorePostgres)
import Shomei.Postgres.PendingCeremonyStore (runPendingCeremonyStorePostgres)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Postgres.VerificationTokenStore (runVerificationTokenStorePostgres)
import Shomei.Prelude
import Shomei.Jwt.KeyProtection (KeyEncryptionKey)
import Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp)
import Shomei.Server.Keys (LoadedKeys (..))
import Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary)

-- | The single effect stack the assembled server interprets. The high-level ports
-- come first (the handler's view); 'Database', @Error AuthError@, and 'IOE' sit beneath
-- them because the store/publisher/signing-key interpreters issue SQL through 'Database'
-- and surface failures through @Error AuthError@.
type AppEffects =
  '[ UserStore,
     CredentialStore,
     SessionStore,
     RefreshTokenStore,
     VerificationTokenStore,
     PasswordResetTokenStore,
     LoginAttemptStore,
     PasskeyStore,
     PendingCeremonyStore,
     Notifier,
     WebAuthnCeremony,
     PasswordBreachChecker,
     PasswordHasher,
     TokenSigner,
     TokenVerifier,
     AuthEventPublisher,
     AuthEventReader,
     SigningKeyStore,
     Clock,
     TokenGen,
     Database,
     Error AuthError,
     IOE
   ]

-- | Everything the runtime needs to interpret 'AppEffects' down to IO: the live hasql
-- pool, the loaded config, and the current signing-key material (the private signing key,
-- the verifier's public key set, and the served JWKS document).
--
-- The key material is held in an 'IORef' rather than inlined, because
-- 'Shomei.Server.Keys.reloadKeys' swaps it while the server runs — that is what makes
-- @shomei-admin keys activate@ take effect without a restart.
data Env = Env
  { envPool :: !Pool,
    envConfig :: !ShomeiConfig,
    envKeys :: !(IORef LoadedKeys),
    -- | the key-encryption key, when signing keys are encrypted at rest. Held so a reload
    --     can decrypt the signer; deliberately not part of 'ShomeiConfig', which is 'Show'able
    --     and serializable.
    envKek :: !(Maybe KeyEncryptionKey),
    -- | shared TLS manager for the HIBP breach-check interpreter (EP-3)
    envHttpManager :: !Manager
  }

-- | Interpret the whole 'AppEffects' stack down to IO, surfacing an infrastructure
-- 'AuthError' as 'Left'. The composition is written outermost-last: read right-to-left it
-- peels 'AppEffects' head-to-tail. The ORDER is load-bearing — every SQL-issuing port is
-- interpreted ABOVE 'runDatabasePool' (so 'Database' is still in scope when they run), and
-- @Error AuthError@/'IOE' sit at the base. This is the same shape as @shomei-postgres@'s
-- own test harness, extended with EP-4's real signer/verifier interpreters.
--
-- The key material is re-read once per invocation (one invocation ≈ one request's port
-- batch), so a reload that lands between requests is picked up without rebuilding the WAI
-- application; a request already in flight finishes with the material it started with.
runAppIO :: Env -> Eff AppEffects a -> IO (Either AuthError a)
runAppIO env action = do
  keys <- readIORef env.envKeys
  runEff
    . runErrorNoCallStack
    . runDatabasePool env.envPool
    . runTokenGenCrypto
    . runClockIO
    . runSigningKeyStorePostgres
    . runAuthEventReaderPostgres
    . runAuthEventPublisherPostgres
    . runTokenVerifierJwt keys.verifierJwks env.envConfig
    . runTokenSignerJwt keys.signingKey env.envConfig
    . runPasswordHasherCrypto
    . runPasswordBreachCheckerHibp env.envHttpManager breachTimeoutMs
    . runWebAuthnCeremonyLibrary (webauthnConfig env.envConfig)
    . runNotifierFromConfig env.envConfig
    . runPendingCeremonyStorePostgres
    . runPasskeyStorePostgres
    . runLoginAttemptStorePostgres
    . runPasswordResetTokenStorePostgres
    . runVerificationTokenStorePostgres
    . runRefreshTokenStorePostgres
    . runSessionStorePostgres
    . runCredentialStorePostgres
    . runUserStorePostgres
    $ action
  where
    policy :: PasswordPolicy
    policy = env.envConfig.passwordPolicy
    breachTimeoutMs :: Int
    breachTimeoutMs = policy.breachCheckTimeoutMs
