{- | Startup sequence and warp boot for the standalone Shōmei auth service.

'main' runs the turnkey startup: load config → run migrations (idempotent) → acquire the
hasql pool → bootstrap the signing key → build the 'Env' → serve with warp. 'application'
builds the WAI app, reusing EP-5's 'Shomei.Servant.Handlers.shomeiServer' and the
@AuthProtect "shomei-jwt"@ 'Context'. EP-5's handlers run in the smaller servant port
stack ('Shomei.Servant.Seam.AppEffects'); they are bridged onto this server's larger
PostgreSQL stack ('Shomei.Server.App.AppEffects') with @inject@ inside the seam env's
runner. Infrastructure failures (a 'Left' from 'runAppIO') become an IO exception (warp
returns 500); domain failures flow through EP-5's seam to the right status.
-}
module Shomei.Server.Boot (
    main,
    application,
    buildEnv,
    seamEnv,
    authContext,
) where

-- 'Context' is hidden from the prelude (it re-exports lens's 'Context'); we mean
-- servant's 'Servant.Context' here.
import Shomei.Prelude hiding (Context)

import Data.Time (secondsToDiffTime)
import "base" System.IO (hPutStrLn, stderr)
import "text" Data.Text qualified as Text

import "aeson" Data.Aeson (Value (Object), decode)
import "aeson" Data.Aeson.KeyMap qualified as KM
import "effectful-core" Effectful (Eff, inject)
import "wai" Network.Wai (Application, Request)
import "warp" Network.Wai.Handler.Warp qualified as Warp

import "servant-server" Servant (
    Context (EmptyContext, (:.)),
    serveWithContext,
 )
import "servant-server" Servant.Server.Experimental.Auth (AuthHandler)

import Shomei.Jwt.Jwks (jwksDocument)
import Shomei.Jwt.Verify (verifyToken)
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)
import Shomei.Postgres.Pool (acquirePool)

import Shomei.Servant.API (shomeiAPI)
import Shomei.Servant.Auth (AuthUser, authHandler)
import Shomei.Servant.Handlers (shomeiServer)
import Shomei.Servant.Seam qualified as Seam

import Shomei.Config (ShomeiConfig (..))
import Shomei.Crypto (sha256Hex)
import Shomei.Domain.Email (emailText)
import Shomei.Domain.LoginAttempt (AccountKey (..))
import Shomei.Server.App (Env (..), runAppIO)
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Server.Middleware.RateLimit (newRateLimiter, rateLimitMiddleware)

-- | The full turnkey startup sequence.
main :: IO ()
main = do
    (cfg, settings) <- loadConfig
    env <- buildEnv cfg settings
    rl <- newRateLimiter cfg.rateLimitConfig
    hPutStrLn stderr ("[shomei] listening on :" <> show settings.serverPort)
    -- IP-4 middleware order: EP-2's per-IP rate limiter wraps the Servant app here. EP-3's
    -- request-id + structured-logging middleware must wrap THIS expression from the OUTSIDE
    -- when it lands, so even a 429 the limiter returns is logged with a correlation id.
    Warp.run settings.serverPort (rateLimitMiddleware rl (application env))

{- | Run the schema migrations (idempotent), acquire the pool, and bootstrap the signing
key, yielding the assembled 'Env'. Shared by 'main' and by host applications that embed
the Shōmei API (the embedded demo builds its own 'Env' this way). Running
@shomei-migrate@ out-of-band is also supported for production.
-}
buildEnv :: ShomeiConfig -> ServerSettings -> IO Env
buildEnv cfg settings = do
    _ <- runShomeiMigrationsNoCheck (coddSettingsFromConnString settings.serverConnStr) (secondsToDiffTime 60)
    pool <- acquirePool 10 settings.serverConnStr
    (key, jwks) <- bootstrapKeys pool
    pure Env{envPool = pool, envConfig = cfg, envKey = key, envJwks = jwks}

{- | Build the WAI 'Application': EP-5's server with the @AuthProtect "shomei-jwt"@
'Context', whose verifier closes over this 'Env's JWKSet and config so verification
uses exactly the keys the server signs with.
-}
application :: Env -> Application
application env = serveWithContext shomeiAPI (authContext senv) (shomeiServer senv)
  where
    senv = seamEnv env

{- | The single-entry Servant 'Context' carrying the @AuthProtect "shomei-jwt"@
'AuthHandler', built from the seam env's verifier. A host app embedding 'ShomeiAPI'
serves with this same context.
-}
authContext :: Seam.Env -> Context '[AuthHandler Request AuthUser]
authContext senv = authHandler senv.verifier :. EmptyContext

{- | Build EP-5's seam 'Seam.Env' from this server's assembly 'Env'. The port runner
bridges EP-5's smaller stack onto the PostgreSQL stack with @inject@; an
infrastructure 'Left' is raised as an IO exception (warp → 500).
-}
seamEnv :: Env -> Seam.Env
seamEnv env =
    Seam.Env
        { Seam.runPorts = runPorts
        , Seam.config = env.envConfig
        , Seam.verifier = verifyToken env.envJwks env.envConfig
        , Seam.jwksJson = fromMaybe (Object KM.empty) (decode (jwksDocument [env.envKey]))
        , Seam.accountKeyOf = AccountKey . sha256Hex . emailText
        }
  where
    runPorts :: forall a. Eff Seam.AppEffects a -> IO a
    runPorts act =
        runAppIO env (inject act)
            >>= either (\e -> ioError (userError ("shomei infrastructure error: " <> Text.unpack (tshow e)))) pure
    tshow = Text.pack . show
