-- | The embedded deployment model: a host Servant application that mounts the whole
-- Shōmei auth API under @\/auth@ and adds its own business route @\/projects@ guarded by the
-- same 'Authenticated' combinator.
--
-- The host reuses the /real/ adapter assembly from @shomei-server@ — the same `Env`, the
-- same `seamEnv`/`authContext`, and the same `shomeiServer` handlers — so the mounted auth
-- routes and the app's own guard share one signing key, one verifier, and one effect stack.
-- A token minted by @\/auth\/login@ is therefore accepted by @\/projects@.
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
import Shomei.Servant.API (ShomeiAPI)
import Shomei.Servant.Auth (AuthUser, Authenticated)
import Shomei.Servant.Handlers (shomeiServer)
import Shomei.Server.App (Env)
import Shomei.Server.Boot (authContext, seamEnv)

-- | A trivial demo business type the host app owns.
data Project = Project
  { projectId :: !Text,
    projectName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The host application's API: every Shōmei auth route (they already live under
-- @\/auth@ in 'ShomeiAPI', so they are mounted directly, not under an extra prefix), plus
-- an app-owned @\/projects@ route guarded by the same 'Authenticated' combinator.
type AppAPI =
  NamedRoutes ShomeiAPI
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
    (shomeiServer senv :<|> projectsHandler :<|> serveDirectoryWebApp wwwDir)
  where
    senv = seamEnv env

-- | The @\/projects@ handler. It receives the 'AuthUser' the 'Authenticated' guard produced.
projectsHandler :: AuthUser -> Handler [Project]
projectsHandler _user =
  pure [Project {projectId = "proj_demo_1", projectName = "Shōmei Demo Project"}]
