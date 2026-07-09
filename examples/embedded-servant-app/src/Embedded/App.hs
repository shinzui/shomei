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

import Data.Aeson (FromJSON, ToJSON)
import Network.Wai (Application)
import Servant
  ( Get,
    JSON,
    NamedRoutes,
    Proxy (Proxy),
    Raw,
    serveWithContext,
    type (:<|>) ((:<|>)),
    type (:>),
  )
import Servant.Server (Handler)
import Servant.Server.StaticFiles (serveDirectoryWebApp)
import Shomei.Prelude
import Shomei.Servant.API (ShomeiRoutes)
import Shomei.Servant.Auth (AuthUser, Authenticated)
import Shomei.Servant.Handlers (shomeiRoutes)
import Shomei.Server.App (Env)
import Shomei.Server.Boot (authContext, seamEnv)

-- | A trivial demo business type the host app owns.
data Project = Project
  { projectId :: !Text,
    projectName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The host application's API: the whole Shōmei route tree ('ShomeiRoutes' already carries
-- the @\/v1@ prefix on its application routes and serves @\/.well-known\/jwks.json@,
-- @\/health@, @\/ready@ at the root, so it is mounted directly, not under an extra prefix),
-- plus an app-owned @\/projects@ route guarded by the same 'Authenticated' combinator.
type AppAPI =
  NamedRoutes ShomeiRoutes
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
    :<|> Raw -- static passkey-demo assets from ./www, served last so it cannot shadow the typed routes

-- | Serve 'AppAPI' reusing @shomei-server@'s assembly and auth 'Context', serving the static
-- passkey-demo assets from the default @www@ directory (resolved relative to the process CWD).
embeddedApplication :: Env -> Application
embeddedApplication = embeddedApplicationWith "www"

-- | As 'embeddedApplication', but with the static-assets directory given explicitly (the
-- executable reads it from @SHOMEI_DEMO_WWW@ so the demo can be launched from any directory).
embeddedApplicationWith :: FilePath -> Env -> Application
embeddedApplicationWith wwwDir env =
  serveWithContext
    (Proxy @AppAPI)
    (authContext senv)
    (shomeiRoutes senv :<|> projectsHandler :<|> serveDirectoryWebApp wwwDir)
  where
    senv = seamEnv env

-- | The @\/projects@ handler. It receives the 'AuthUser' the 'Authenticated' guard produced.
projectsHandler :: AuthUser -> Handler [Project]
projectsHandler _user =
  pure [Project {projectId = "proj_demo_1", projectName = "Shōmei Demo Project"}]
