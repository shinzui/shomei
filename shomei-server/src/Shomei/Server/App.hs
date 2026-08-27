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
import Shomei.Account.Credential.Postgres (runCredentialStorePostgres)
import Shomei.Account.Credential.Store (CredentialStore)
import Shomei.Account.Notification.Store (Notifier)
import Shomei.Account.Password.Breach.Store (PasswordBreachChecker)
import Shomei.Account.Password.Domain (PasswordPolicy (breachCheckTimeoutMs))
import Shomei.Account.Password.Hash.Postgres (Argon2Params, HashingLimiter, runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Account.Password.Hash.Store (PasswordHasher)
import Shomei.Account.PasswordReset.Postgres (runPasswordResetTokenStorePostgres)
import Shomei.Account.PasswordReset.Store (PasswordResetTokenStore)
import Shomei.Account.User.Postgres (runUserStorePostgres)
import Shomei.Account.User.Store (UserStore)
import Shomei.Account.Verification.Postgres (runVerificationTokenStorePostgres)
import Shomei.Account.Verification.Store (VerificationTokenStore)
import Shomei.Audit.Publisher.Postgres (runAuthEventPublisherPostgres)
import Shomei.Audit.Publisher.Store (AuthEventPublisher)
import Shomei.Audit.Reader.Postgres (runAuthEventReaderPostgres)
import Shomei.Audit.Reader.Store (AuthEventReader)
import Shomei.Authorization.Claims.Store (ClaimsEnricher, runClaimsEnricherNull)
import Shomei.Authorization.Role.Postgres (runRoleStorePostgres)
import Shomei.Authorization.Role.Store (RoleStore)
import Shomei.Config (NotifierConfig (notifierTransport), ShomeiConfig (notifierConfig, passwordPolicy), webauthnConfig)
import Shomei.Error (AuthError)
import Shomei.Mfa.RecoveryCode.Postgres (runRecoveryCodeStorePostgres)
import Shomei.Mfa.RecoveryCode.Store (RecoveryCodeStore)
import Shomei.Mfa.Totp.Postgres (TotpEncryptionKey, runTotpCredentialStorePostgres)
import Shomei.Mfa.Totp.Store (TotpCredentialStore)
import Shomei.Notify (runNotifierEnqueue, transportChannel)
import Shomei.Notify.Queue (NotifierQueue)
import Shomei.OAuth.AuthorizationCode.Postgres (runOAuthCodeStorePostgres)
import Shomei.OAuth.AuthorizationCode.Store (OAuthCodeStore)
import Shomei.OAuth.Client.Postgres (runOAuthClientStorePostgres)
import Shomei.OAuth.Client.Store (OAuthClientStore)
import Shomei.Passkey.Ceremony.Port (WebAuthnCeremony)
import Shomei.Passkey.Ceremony.Postgres (runPendingCeremonyStorePostgres)
import Shomei.Passkey.Ceremony.Store (PendingCeremonyStore)
import Shomei.Passkey.Postgres (runPasskeyStorePostgres)
import Shomei.Passkey.Store (PasskeyStore)
import Shomei.Persistence.Database.Postgres (Database, runDatabasePool)
import Shomei.Prelude
import Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp)
import Shomei.Server.Keys (LoadedKeys (..))
import Shomei.ServiceAccount.Postgres (runServiceAccountStorePostgres)
import Shomei.ServiceAccount.Store (ServiceAccountStore)
import Shomei.Session.LoginAttempt.Postgres (runLoginAttemptStorePostgres)
import Shomei.Session.LoginAttempt.Store (LoginAttemptStore)
import Shomei.Session.Postgres (runSessionStorePostgres)
import Shomei.Session.RefreshToken.Postgres (runRefreshTokenStorePostgres)
import Shomei.Session.RefreshToken.Store (RefreshTokenStore)
import Shomei.Session.Store (SessionStore)
import Shomei.Session.Token.Generator (TokenGen)
import Shomei.Session.UnitOfWork.Postgres (runAuthUnitOfWorkPostgres)
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork)
import Shomei.SigningKey.Postgres (runSigningKeyStorePostgres)
import Shomei.SigningKey.Protection.Jwt (KeyEncryptionKey)
import Shomei.SigningKey.Sign.Jwt (runTokenSignerJwt)
import Shomei.SigningKey.Signer (TokenSigner)
import Shomei.SigningKey.Store (SigningKeyStore)
import Shomei.SigningKey.Verifier (TokenVerifier)
import Shomei.SigningKey.Verify.Jwt (runTokenVerifierJwt)
import Shomei.Time.Postgres (runClockIO)
import Shomei.Time.Store (Clock)
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
    -- | the key-encryption key used to decrypt the signer during reloads. It is deliberately
    --     not part of 'ShomeiConfig', which is 'Show'able and serializable.
    envKek :: !KeyEncryptionKey,
    -- | the AES-256-GCM key that encrypts stored TOTP secrets (EP-7), loaded from
    --     @SHOMEI_TOTP_ENCRYPTION_KEY@. Deliberately not part of 'ShomeiConfig' (a secret). When
    --     TOTP is disabled this is a dummy key: enrollment is refused, so the store is
    --     unreachable, but the interpreter-stack shape stays fixed.
    envTotpKey :: !TotpEncryptionKey,
    -- | shared TLS manager for the HIBP breach-check interpreter (EP-3)
    envHttpManager :: !Manager,
    -- | bounded notification queue; request handlers only enqueue, while the supervised
    --     server worker performs delivery outside request latency.
    envNotifierQueue :: !NotifierQueue,
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
    . runNotifierEnqueue
      env.envNotifierQueue
      (transportChannel env.envConfig.notifierConfig.notifierTransport)
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
