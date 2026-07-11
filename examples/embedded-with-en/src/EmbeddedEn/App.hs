-- | The embedded deployment model with authorization: a host Servant app that mounts the
-- whole Shōmei auth API (as @embedded-servant-app@ does) and adds business routes
-- @\/projects\/:id@ (GET/PUT) whose handlers map the authenticated Shōmei user to an en
-- subject and call en's fail-closed guard.
--
-- Shōmei establishes /who is calling/ (the 'Authenticated' combinator produces the
-- 'AuthUser'); en decides /what they may do/ ('requireProjectPermission' checks the relation
-- graph). The two share one signing key and verifier because the mounted auth routes reuse
-- the real @shomei-server@ assembly — a token minted by @\/v1\/auth\/login@ is accepted here.
module EmbeddedEn.App
  ( AppAPI,
    Project (..),
    ProjectUpdate (..),
    GrantRequest (..),
    GrantResponse (..),
    embeddedEnApplication,
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.IORef (IORef)
import Data.Text (Text)
import GHC.Generics (Generic)
import Network.Wai (Application)
import Servant
  ( Capture,
    Get,
    Handler,
    JSON,
    NamedRoutes,
    Post,
    Proxy (Proxy),
    Put,
    ReqBody,
    ServerError,
    err400,
    err503,
    errBody,
    errHeaders,
    serveWithContext,
    throwError,
    type (:<|>) ((:<|>)),
    type (:>),
  )

import En.Revision (ConsistencyToken (..))
import En.Schema (RelationName (..))
import En.Tuple (Tuple)

import EmbeddedEn.Authz
  ( EnEnv,
    grantRelation,
    mkEnEnv,
    projectRef,
    requireProjectPermission,
    subjectForUser,
  )
import Shomei.Servant.API (ShomeiRoutes)
import Shomei.Servant.Auth (AuthUser, Authenticated)
import Shomei.Servant.Handlers (shomeiRoutes)
import Shomei.Server.App (Env)
import Shomei.Server.Boot (authContext, seamEnv)

-- | A trivial demo business resource the host owns.
data Project = Project
  { projectId :: !Text,
    projectName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

-- | The @PUT@ body: the new project name.
newtype ProjectUpdate = ProjectUpdate
  { projectName :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON)

-- | The demo grant body: grant the caller @relation@ (@viewer@ or @editor@) on
-- @project:projectId@.
data GrantRequest = GrantRequest
  { projectId :: !Text,
    relation :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON)

-- | The demo grant response: what was granted, on which object, and en's consistency token
-- for the write (what a real host would carry into an @AtLeastAsFresh@ follow-up check).
data GrantResponse = GrantResponse
  { granted :: !Text,
    object :: !Text,
    consistencyToken :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

-- | The host API: the whole Shōmei route tree (already carrying @\/v1@ on its application
-- routes and serving @\/.well-known\/jwks.json@, @\/health@, @\/ready@ at the root), plus the
-- en-guarded business routes and the demo grant route.
type AppAPI =
  NamedRoutes ShomeiRoutes
    :<|> Authenticated :> "projects" :> Capture "id" Text :> Get '[JSON] Project
    :<|> Authenticated :> "projects" :> Capture "id" Text :> ReqBody '[JSON] ProjectUpdate :> Put '[JSON] Project
    :<|> Authenticated :> "demo" :> "grants" :> ReqBody '[JSON] GrantRequest :> Post '[JSON] GrantResponse

-- | Serve 'AppAPI', reusing @shomei-server@'s assembly and auth 'Context', with en running
-- over the shared tuple 'IORef'.
embeddedEnApplication :: Env -> IORef [Tuple] -> Application
embeddedEnApplication env tuples =
  serveWithContext
    (Proxy @AppAPI)
    (authContext senv)
    (shomeiRoutes senv :<|> getProject enEnv :<|> putProject enEnv :<|> grantHandler enEnv)
  where
    senv = seamEnv env
    enEnv = mkEnEnv tuples

-- | @GET \/projects\/:id@: readable by a @viewer@ or an @editor@ (the schema's @view@ union).
getProject :: EnEnv -> AuthUser -> Text -> Handler Project
getProject enEnv user pid = do
  requireProjectPermission enEnv (subjectForUser user) (RelationName "view") (projectRef pid)
  pure (Project {projectId = pid, projectName = "Project " <> pid})

-- | @PUT \/projects\/:id@: writable only by an @editor@ (the schema's @edit@ permission).
putProject :: EnEnv -> AuthUser -> Text -> ProjectUpdate -> Handler Project
putProject enEnv user pid upd = do
  requireProjectPermission enEnv (subjectForUser user) (RelationName "edit") (projectRef pid)
  pure (Project {projectId = pid, projectName = upd.projectName})

-- | @POST \/demo\/grants@: write a relation tuple for the CALLER's own subject, so the
-- transcript can flip 403→200 in one process. A production host never lets a caller grant
-- itself access; see 'grantRelation'.
grantHandler :: EnEnv -> AuthUser -> GrantRequest -> Handler GrantResponse
grantHandler enEnv user req = do
  rel <- case req.relation of
    "viewer" -> pure (RelationName "viewer")
    "editor" -> pure (RelationName "editor")
    _ -> throwError badRelation
  result <- liftIO (grantRelation enEnv (subjectForUser user) req.projectId rel)
  case result of
    Right (ConsistencyToken token) ->
      pure
        GrantResponse
          { granted = req.relation,
            object = "project:" <> req.projectId,
            consistencyToken = token
          }
    Left _ -> throwError grantFailed

badRelation :: ServerError
badRelation =
  err400
    { errBody = "{\"code\":\"invalid_relation\",\"message\":\"relation must be viewer or editor\"}",
      errHeaders = [("Content-Type", "application/json")]
    }

grantFailed :: ServerError
grantFailed =
  err503
    { errBody = "{\"code\":\"authorization_backend_unavailable\",\"message\":\"the authorization backend failed; retry later\"}",
      errHeaders = [("Content-Type", "application/json")]
    }
