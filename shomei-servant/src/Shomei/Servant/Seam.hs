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
) where

import Shomei.Prelude

import "aeson" Data.Aeson (Value)
import "effectful-core" Effectful (Eff, IOE)

import "servant-server" Servant (Handler, throwError)

import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Claims (AuthClaims)
import Shomei.Error (AuthError, TokenError)
import Shomei.Servant.Error (authErrorToServerError)

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

{- | The canonical, ordered Shōmei port stack. Its order matches EP-2's
@Shomei.Effect.InMemory.runInMemory@ so the same workflows run unchanged over the
in-memory and the real (EP-6) interpreter assemblies.
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
