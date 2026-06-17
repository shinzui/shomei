{- | The seam between the @effectful@ port stack and servant's 'Handler' (style A,
per-action — mirroring kizashi's @Kizashi.Http.Seam.effToHandler@).

'AppEffects' is the canonical Shōmei port stack: the fixed, ordered effect list that
every interpreter assembly (the in-memory test stack here, the PostgreSQL + JWT stack
in EP-6) must provide a runner for. 'Env' carries that runner ('runPorts'), the
'ShomeiConfig', the token verifier the 'Shomei.Servant.Auth.authHandler' uses, and the
precomputed public JWKS document for the @jwks@ route. 'runAuth' runs a workflow that
already yields @Either AuthError@ and maps a 'Left' to the matching 'ServerError';
'runPort' runs a plain port action whose result the handler branches on itself.
-}
module Shomei.Servant.Seam (
    AppEffects,
    Env (..),
    runAuth,
    runPort,
    runPortChecked,
) where

import Shomei.Prelude

import Data.Aeson (Value)
import Control.Exception (SomeException, try)
import Effectful (Eff, IOE)

import Servant (Handler, throwError)

import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Claims (AuthClaims)
import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginAttempt (AccountKey)
import Shomei.Error (AuthError, TokenError)
import Shomei.Servant.Error (authErrorToServerError)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
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

{- | The canonical, ordered Shōmei port stack. Its order matches EP-2's
@Shomei.Effect.InMemory.runInMemory@ so the same workflows run unchanged over the
in-memory and the real (EP-6) interpreter assemblies.
-}
type AppEffects =
    '[ UserStore
     , CredentialStore
     , SessionStore
     , RefreshTokenStore
     , VerificationTokenStore
     , PasswordResetTokenStore
     , LoginAttemptStore
     , PasskeyStore
     , PendingCeremonyStore
     , Notifier
     , WebAuthnCeremony
     , PasswordBreachChecker
     , PasswordHasher
     , TokenSigner
     , TokenVerifier
     , AuthEventPublisher
     , SigningKeyStore
     , Clock
     , TokenGen
     , IOE
     ]

-- | The runtime environment threaded to every handler.
data Env = Env
    { runPorts :: !(forall a. Eff AppEffects a -> IO a)
    -- ^ the port-interpreter runner (in-memory in tests; postgres+jwt in EP-6)
    , config :: !ShomeiConfig
    , verifier :: !(Text -> IO (Either TokenError AuthClaims))
    -- ^ the token verifier the 'Shomei.Servant.Auth.authHandler' is built from
    , jwksJson :: !Value
    -- ^ the precomputed public JWKS document served at @\/.well-known\/jwks.json@
    , accountKeyOf :: !(Email -> AccountKey)
    {- ^ derive the abuse store's hashed account key from a normalized email (EP-2). The
    server supplies a SHA-256 hash; tests may supply a trivial mapping.
    -}
    }

{- | Run a workflow that yields @Either AuthError a@: a 'Right' flows through; a
'Left' becomes the matching 'ServerError'.
-}
runAuth :: Env -> Eff AppEffects (Either AuthError a) -> Handler a
runAuth env action = do
    result <- liftIO (runPorts env action)
    either (throwError . authErrorToServerError) pure result

-- | Run a plain port action to its value; the caller branches on the result.
runPort :: Env -> Eff AppEffects a -> Handler a
runPort env action = liftIO (runPorts env action)

{- | Run a port action, catching an infrastructure failure (which 'runPorts' surfaces as an IO
exception) as a 'Left' instead of letting it become a 500. Used by the @/ready@ readiness
probe so a database outage yields a clean 503 rather than a 500.
-}
runPortChecked :: Env -> Eff AppEffects a -> Handler (Either SomeException a)
runPortChecked env action = liftIO (try (runPorts env action))
