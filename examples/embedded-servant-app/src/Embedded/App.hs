-- | The embedded deployment model: a host Servant application that mounts the whole
-- Shōmei auth API and adds its own business route @\/projects@ guarded by the same
-- 'Authenticated' combinator.
--
-- The host reuses the /real/ adapter assembly from @shomei-server@ — the same `Env`, the
-- same `seamEnv`/`authContext`, and the same `shomeiRoutes` handlers — so the mounted auth
-- routes and the app's own guard share one signing key, one verifier, and one effect stack.
-- A token minted by @\/v1\/auth\/login@ is therefore accepted by @\/projects@.
module Embedded.App
  ( AppAPI,
    Project (..),
    embeddedApplication,
    embeddedApplicationWith,
  )
where

import Data.Text qualified as Text
import Network.Wai (Application)
import Servant
  ( Get,
    JSON,
    NamedRoutes,
    Raw,
    serveWithContext,
    type (:<|>) ((:<|>)),
    type (:>),
  )
import Servant.Health (ProbeCheck)
import Servant.Server (Handler)
import Servant.Server.StaticFiles (serveDirectoryWebApp)
import Shomei.Authorization.Claims.Domain (AuthClaims (..))
import Shomei.Id (idText)
import Shomei.Prelude
import Shomei.Servant.Api (ShomeiRoutes)
import Shomei.Servant.Auth (AuthUser (..), Authenticated)
import Shomei.Servant.Server (shomeiRoutes)
import Shomei.Server.App (Env)
import Shomei.Server.Boot (authContext, seamEnv)
import System.IO (hPutStrLn, stderr)

-- | A trivial demo business type the host app owns.
data Project = Project
  { projectId :: !Text,
    projectName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The host application's API: the whole Shōmei route tree ('ShomeiRoutes' already carries
-- the @\/v1@ prefix on its application routes and serves @\/.well-known\/jwks.json@,
-- @\/health\/{live,ready}@ at the root, so it is mounted directly, not under an extra prefix),
-- plus an app-owned @\/projects@ route guarded by the same 'Authenticated' combinator.
type AppAPI =
  NamedRoutes ShomeiRoutes
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
    :<|> Raw -- static passkey-demo assets from ./www, served last so it cannot shadow the typed routes

-- | Serve 'AppAPI' reusing @shomei-server@'s assembly and auth 'Context', serving the static
-- passkey-demo assets from the default @www@ directory (resolved relative to the process CWD).
embeddedApplication :: Env -> ProbeCheck -> ProbeCheck -> Application
embeddedApplication = embeddedApplicationWith "www"

-- | As 'embeddedApplication', but with the static-assets directory given explicitly (the
-- executable reads it from @SHOMEI_DEMO_WWW@ so the demo can be launched from any directory).
embeddedApplicationWith :: FilePath -> Env -> ProbeCheck -> ProbeCheck -> Application
embeddedApplicationWith wwwDir env liveness readiness =
  serveWithContext
    (Proxy @AppAPI)
    (authContext senv)
    (shomeiRoutes senv liveness readiness :<|> projectsHandler :<|> serveDirectoryWebApp wwwDir)
  where
    senv = seamEnv env

-- | The @\/projects@ handler. It receives the 'AuthUser' the 'Authenticated' guard produced.
projectsHandler :: AuthUser -> Handler [Project]
projectsHandler user = do
  forM_ user.authClaims.actor \operator ->
    liftIO
      ( hPutStrLn
          stderr
          ( "[embedded-servant-app] delegated request sub="
              <> Text.unpack (idText user.authUserId)
              <> " act="
              <> Text.unpack (idText operator)
          )
      )
  pure [Project {projectId = "proj_demo_1", projectName = "Shōmei Demo Project"}]
