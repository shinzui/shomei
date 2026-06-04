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
) where

import Shomei.Prelude

import Data.Time (secondsToDiffTime)
import "base" System.IO (hPutStrLn, stderr)
import "text" Data.Text qualified as Text

import "aeson" Data.Aeson (Value (Object), decode)
import "aeson" Data.Aeson.KeyMap qualified as KM
import "effectful-core" Effectful (Eff, inject)
import "wai" Network.Wai (Application)
import "warp" Network.Wai.Handler.Warp qualified as Warp

import "servant-server" Servant (
    Context (EmptyContext, (:.)),
    serveWithContext,
 )

import Shomei.Jwt.Jwks (jwksDocument)
import Shomei.Jwt.Verify (verifyToken)
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)
import Shomei.Postgres.Pool (acquirePool)

import Shomei.Servant.API (shomeiAPI)
import Shomei.Servant.Auth (authHandler)
import Shomei.Servant.Handlers (shomeiServer)
import Shomei.Servant.Seam qualified as Seam

import Shomei.Server.App (Env (..), runAppIO)
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import Shomei.Server.Keys (bootstrapKeys)

-- | The full turnkey startup sequence.
main :: IO ()
main = do
    (cfg, settings) <- loadConfig
    -- Migrations at startup (idempotent; codd skips already-applied ones). Running
    -- @shomei-migrate@ out-of-band is also supported for production.
    _ <- runShomeiMigrationsNoCheck (coddSettingsFromConnString settings.serverConnStr) (secondsToDiffTime 60)
    pool <- acquirePool 10 settings.serverConnStr
    (key, jwks) <- bootstrapKeys pool
    let env = Env{envPool = pool, envConfig = cfg, envKey = key, envJwks = jwks}
    hPutStrLn stderr ("[shomei] listening on :" <> show settings.serverPort)
    Warp.run settings.serverPort (application env)

{- | Build the WAI 'Application': EP-5's server with the @AuthProtect "shomei-jwt"@
'Context', whose verifier closes over this 'Env's JWKSet and config so verification
uses exactly the keys the server signs with.
-}
application :: Env -> Application
application env = serveWithContext shomeiAPI ctx (shomeiServer senv)
  where
    senv = seamEnv env
    ctx = authHandler senv.verifier :. EmptyContext

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
        }
  where
    runPorts :: forall a. Eff Seam.AppEffects a -> IO a
    runPorts act =
        runAppIO env (inject act)
            >>= either (\e -> ioError (userError ("shomei infrastructure error: " <> Text.unpack (tshow e)))) pure
    tshow = Text.pack . show
