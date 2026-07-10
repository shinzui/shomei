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
import Shomei.Crypto (Argon2Params, HashingLimiter, runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Domain.Password (PasswordPolicy (breachCheckTimeoutMs))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.AuthEventReader (AuthEventReader)
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork)
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher, runClaimsEnricherNull)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore)
import Shomei.Effect.Notifier (Notifier)
import Shomei.Effect.OAuthClientStore (OAuthClientStore)
import Shomei.Effect.OAuthCodeStore (OAuthCodeStore)
import Shomei.Effect.PasskeyStore (PasskeyStore)
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.PasswordResetTokenStore (PasswordResetTokenStore)
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore)
import Shomei.Effect.RecoveryCodeStore (RecoveryCodeStore)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.RoleStore (RoleStore)
import Shomei.Effect.ServiceAccountStore (ServiceAccountStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.SigningKeyStore (SigningKeyStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TokenVerifier (TokenVerifier)
import Shomei.Effect.TotpCredentialStore (TotpCredentialStore)
import Shomei.Effect.UserStore (UserStore)
import Shomei.Effect.VerificationTokenStore (VerificationTokenStore)
import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)
import Shomei.Error (AuthError)
import Shomei.Jwt.KeyProtection (KeyEncryptionKey)
import Shomei.Jwt.Sign (runTokenSignerJwt)
import Shomei.Jwt.Verify (runTokenVerifierJwt)
import Shomei.Notify (runNotifierFromConfig)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.AuthEventReader (runAuthEventReaderPostgres)
import Shomei.Postgres.AuthUnitOfWork (runAuthUnitOfWorkPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.LoginAttemptStore (runLoginAttemptStorePostgres)
import Shomei.Postgres.OAuthClientStore (runOAuthClientStorePostgres)
import Shomei.Postgres.OAuthCodeStore (runOAuthCodeStorePostgres)
import Shomei.Postgres.PasskeyStore (runPasskeyStorePostgres)
import Shomei.Postgres.PasswordResetTokenStore (runPasswordResetTokenStorePostgres)
import Shomei.Postgres.PendingCeremonyStore (runPendingCeremonyStorePostgres)
import Shomei.Postgres.RecoveryCodeStore (runRecoveryCodeStorePostgres)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.RoleStore (runRoleStorePostgres)
import Shomei.Postgres.ServiceAccountStore (runServiceAccountStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.TotpCredentialStore (TotpEncryptionKey, runTotpCredentialStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Postgres.VerificationTokenStore (runVerificationTokenStorePostgres)
import Shomei.Prelude
import Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp)
import Shomei.Server.Keys (LoadedKeys (..))
import Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary)

-- | The single effect stack the assembled server interprets. The high-level ports
-- come first (the handler's view); 'Database', @Error AuthError@, and 'IOE' sit beneath
-- them because the store/publisher/signing-key interpreters issue SQL through 'Database'
-- and surface failures through @Error AuthError@.
type AppEffects =
  '[ UserStore,
     RoleStore,
     CredentialStore,
     SessionStore,
     RefreshTokenStore,
     AuthUnitOfWork,
     VerificationTokenStore,
     PasswordResetTokenStore,
     LoginAttemptStore,
     PasskeyStore,
     PendingCeremonyStore,
     ServiceAccountStore,
     OAuthClientStore,
     OAuthCodeStore,
     TotpCredentialStore,
     RecoveryCodeStore,
     Notifier,
     ClaimsEnricher,
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
    -- | the AES-256-GCM key that encrypts stored TOTP secrets (EP-7), loaded from
    --     @SHOMEI_TOTP_ENCRYPTION_KEY@. Deliberately not part of 'ShomeiConfig' (a secret). When
    --     TOTP is disabled this is a dummy key: enrollment is refused, so the store is
    --     unreachable, but the interpreter-stack shape stays fixed.
    envTotpKey :: !TotpEncryptionKey,
    -- | shared TLS manager for the HIBP breach-check interpreter (EP-3)
    envHttpManager :: !Manager,
    -- | Argon2id cost parameters for hashing new passwords. Verification reads the parameters
    --     embedded in each stored hash, so this only affects hashes written from now on.
    envArgon2Params :: !Argon2Params,
    -- | bounds how many Argon2 derivations run at once, process-wide
    envHashingLimiter :: !HashingLimiter
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
    . runPasswordHasherCrypto env.envHashingLimiter env.envArgon2Params
    . runPasswordBreachCheckerHibp env.envHttpManager breachTimeoutMs
    . runWebAuthnCeremonyLibrary (webauthnConfig env.envConfig)
    -- The standalone server adds no claims of its own. An embedding host swaps this for its
    -- own 'ClaimsEnricher' interpreter where it builds 'Shomei.Servant.Seam.Env'.
    . runClaimsEnricherNull
    . runNotifierFromConfig env.envHttpManager env.envConfig
    . runRecoveryCodeStorePostgres
    . runTotpCredentialStorePostgres env.envTotpKey
    . runOAuthCodeStorePostgres
    . runOAuthClientStorePostgres
    . runServiceAccountStorePostgres
    . runPendingCeremonyStorePostgres
    . runPasskeyStorePostgres
    . runLoginAttemptStorePostgres
    . runPasswordResetTokenStorePostgres
    . runVerificationTokenStorePostgres
    . runAuthUnitOfWorkPostgres
    . runRefreshTokenStorePostgres
    . runSessionStorePostgres
    . runCredentialStorePostgres
    . runRoleStorePostgres
    . runUserStorePostgres
    $ action
  where
    policy :: PasswordPolicy
    policy = env.envConfig.passwordPolicy
    breachTimeoutMs :: Int
    breachTimeoutMs = policy.breachCheckTimeoutMs
