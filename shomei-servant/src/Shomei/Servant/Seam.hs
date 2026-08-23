-- | The seam between the @effectful@ port stack and servant's 'Handler' (style A,
-- per-action — mirroring kizashi's @Kizashi.Http.Seam.effToHandler@).
--
-- 'AppEffects' is the canonical Shōmei port stack: the fixed, ordered effect list that
-- every interpreter assembly (the in-memory test stack here, the PostgreSQL + JWT stack
-- in EP-6) must provide a runner for. 'Env' carries that runner ('runPorts'), the
-- 'ShomeiConfig' and the precomputed public JWKS document for the @jwks@ route.
-- 'verifyRequestToken' derives HTTP authentication from that runner and configuration, so
-- @sessionCheckMode = VerifyTokenAndSession@ cannot be bypassed by assembly wiring. 'runAuth'
-- runs a workflow that
-- already yields @Either AuthError@ and maps a 'Left' to the matching 'ServerError';
-- 'runPort' runs a plain port action whose result the handler branches on itself.
module Shomei.Servant.Seam
  ( AppEffects,
    Env (..),
    verifyRequestToken,
    runAuth,
    runPort,
    runPortChecked,
  )
where

import Data.Aeson (Value)
import Effectful (Eff, IOE)
import Servant (Handler, throwError)
import Shomei.Account.Credential.Store (CredentialStore)
import Shomei.Account.Notification.Store (Notifier)
import Shomei.Account.Password.Breach.Store (PasswordBreachChecker)
import Shomei.Account.Password.Hash.Store (PasswordHasher)
import Shomei.Account.PasswordReset.Store (PasswordResetTokenStore)
import Shomei.Account.User.Store (UserStore)
import Shomei.Account.Verification.Store (VerificationTokenStore)
import Shomei.Audit.Publisher.Store (AuthEventPublisher)
import Shomei.Audit.Reader.Store (AuthEventReader)
import Shomei.Authorization.Claims.Domain (AuthClaims)
import Shomei.Authorization.Claims.Store (ClaimsEnricher)
import Shomei.Authorization.Role.Store (RoleStore)
import Shomei.Config (ShomeiConfig)
import Shomei.Error (AuthError)
import Shomei.Mfa.RecoveryCode.Store (RecoveryCodeStore)
import Shomei.Mfa.Totp.Store (TotpCredentialStore)
import Shomei.OAuth.AuthorizationCode.Store (OAuthCodeStore)
import Shomei.OAuth.Client.Store (OAuthClientStore)
import Shomei.Passkey.Ceremony.Port (WebAuthnCeremony)
import Shomei.Passkey.Ceremony.Store (PendingCeremonyStore)
import Shomei.Passkey.Store (PasskeyStore)
import Shomei.Prelude
import Shomei.Servant.Error (authErrorToServerError)
import Shomei.ServiceAccount.Store (ServiceAccountStore)
import Shomei.Session.Authentication.Workflow qualified as Wf
import Shomei.Session.LoginAttempt.Domain (AccountKey)
import Shomei.Session.LoginAttempt.Store (LoginAttemptStore)
import Shomei.Session.RefreshToken.Store (RefreshTokenStore)
import Shomei.Session.Store (SessionStore)
import Shomei.Session.Token.Domain (AccessToken (..))
import Shomei.Session.Token.Generator (TokenGen)
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork)
import Shomei.SigningKey.Signer (TokenSigner)
import Shomei.SigningKey.Store (SigningKeyStore)
import Shomei.SigningKey.Verifier (TokenVerifier)
import Shomei.Time.Store (Clock)

-- | The canonical, ordered Shōmei port stack. Its order matches EP-2's
-- @Shomei.Test.InMemory.runInMemory@ so the same workflows run unchanged over the
-- in-memory and the real (EP-6) interpreter assemblies.
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
     IOE
   ]

-- | The runtime environment threaded to every handler.
data Env = Env
  { -- | the port-interpreter runner (in-memory in tests; postgres+jwt in EP-6)
    runPorts :: !(forall a. Eff AppEffects a -> IO (Either AuthError a)),
    config :: !ShomeiConfig,
    -- | the precomputed public JWKS document served at @\/.well-known\/jwks.json@. An
    --     'IO' getter rather than a 'Value' because the standalone server swaps its key
    --     material on rotation (a 'readIORef'); tests pass @pure@ of a static document.
    --     The document stays precomputed either way — no per-request re-encoding.
    jwksJson :: !(IO Value),
    -- | derive the abuse store's hashed account key from the principal's login-id text (SH-25:
    --     the abuse key tracks the login identifier you actually authenticate with, not the email).
    --     The server supplies a SHA-256 hash; tests may supply a trivial mapping.
    accountKeyOf :: !(Text -> AccountKey)
  }

-- | Verify a presented access token the way the seam's configuration says to.
--
-- This is the only way Shōmei's HTTP layer verifies a token, and it is derived rather than
-- supplied: 'runPorts' already interprets 'TokenVerifier', 'SessionStore' and 'Clock', which is
-- exactly what 'Shomei.Session.Authentication.Workflow.verifyToken' needs. The session check requested by
-- @sessionCheckMode = VerifyTokenAndSession@ therefore runs against the same stores the login and
-- refresh workflows write to.
--
-- Under the default @VerifyTokenOnly@ the workflow returns after the JWT check and issues no
-- query. Under @VerifyTokenAndSession@ it performs one session lookup per authenticated request.
verifyRequestToken :: Env -> Text -> IO (Either AuthError AuthClaims)
verifyRequestToken env raw = do
  result <- runPorts env (Wf.verifyToken (config env) (AccessToken raw))
  pure (result >>= id)

-- | Run a workflow that yields @Either AuthError a@: a 'Right' flows through; a
-- 'Left' becomes the matching 'ServerError'.
runAuth :: Env -> Eff AppEffects (Either AuthError a) -> Handler a
runAuth env action = do
  result <- liftIO (runPorts env action)
  either (throwError . authErrorToServerError) pure (result >>= id)

-- | Run a plain port action to its value; the caller branches on the result.
runPort :: Env -> Eff AppEffects a -> Handler a
runPort env action = do
  result <- liftIO (runPorts env action)
  either (throwError . authErrorToServerError) pure result

-- | Run a port action while retaining its typed dependency/internal failure for a
-- route-local total mapping (currently used by readiness).
runPortChecked :: Env -> Eff AppEffects a -> Handler (Either AuthError a)
runPortChecked env action = liftIO (runPorts env action)
