-- | Administrative authorization HTTP adapters.
module Shomei.Authorization.Handler (authorizationServer) where

import Data.Text qualified as Text
import Servant (Handler)
import Servant.Server.Generic (AsServerT)
import Shomei.Authorization.Api (AuthorizationApi (..))
import Shomei.Authorization.Claims.Domain (Role (..))
import Shomei.Authorization.Result
import Shomei.Authorization.Role.Workflow qualified as Roles
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Application (ApplicationHandler, rejectProblem, runApplicationHandler, workflow)
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Error (detailOccurrence, noProblemOccurrence, pcBadRequest, pcRoleNotGranted)
import Shomei.Servant.Seam (Env)

authorizationServer :: Env -> AuthorizationApi (AsServerT Handler)
authorizationServer env =
  AuthorizationApi
    { grantRole = grantRoleH env,
      revokeRole = revokeRoleH env
    }

grantRoleH :: Env -> AuthUser -> UserId -> Text -> Handler GrantRoleResult
grantRoleH env actor target roleText = runApplicationHandler do
  denyUnderDelegation env "admin_grant_role" actor
  role <- parseRole roleText
  void $ workflow env (Roles.grantRoleTo (Just actor.authUserId) Nothing target role)

revokeRoleH :: Env -> AuthUser -> UserId -> Text -> Handler RevokeRoleResult
revokeRoleH env actor target roleText = runApplicationHandler do
  denyUnderDelegation env "admin_revoke_role" actor
  role <- parseRole roleText
  changed <- workflow env (Roles.revokeRoleFrom (Just actor.authUserId) target role)
  unless changed (rejectProblem pcRoleNotGranted noProblemOccurrence)

parseRole :: Text -> ApplicationHandler Role
parseRole value
  | Text.null trimmed = rejectProblem pcBadRequest (detailOccurrence "role must not be blank")
  | otherwise = pure (Role trimmed)
  where
    trimmed = Text.strip value
