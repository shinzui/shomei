-- | Administrative authorization HTTP adapters.
module Shomei.Authorization.Handler (authorizationServer) where

import Data.Text qualified as Text
import Servant (Handler, NoContent (..), throwError)
import Servant.Server.Generic (AsServerT)
import Shomei.Authorization.Api (AuthorizationApi (..))
import Shomei.Authorization.Claims.Domain (Role (..))
import Shomei.Authorization.Role.Workflow qualified as Roles
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Error (pcBadRequest, pcRoleNotGranted, toProblemError)
import Shomei.Servant.Seam (Env, runAuth)

authorizationServer :: Env -> AuthorizationApi (AsServerT Handler)
authorizationServer env =
  AuthorizationApi
    { grantRole = grantRoleH env,
      revokeRole = revokeRoleH env
    }

grantRoleH :: Env -> AuthUser -> UserId -> Text -> Handler NoContent
grantRoleH env actor target roleText = do
  denyUnderDelegation env "admin_grant_role" actor
  role <- parseRole roleText
  _ <- runAuth env (Roles.grantRoleTo (Just actor.authUserId) Nothing target role)
  pure NoContent

revokeRoleH :: Env -> AuthUser -> UserId -> Text -> Handler NoContent
revokeRoleH env actor target roleText = do
  denyUnderDelegation env "admin_revoke_role" actor
  role <- parseRole roleText
  changed <- runAuth env (Roles.revokeRoleFrom (Just actor.authUserId) target role)
  unless changed (throwError (toProblemError pcRoleNotGranted Nothing))
  pure NoContent

parseRole :: Text -> Handler Role
parseRole value
  | Text.null trimmed = throwError (toProblemError pcBadRequest (Just "role must not be blank"))
  | otherwise = pure (Role trimmed)
  where
    trimmed = Text.strip value
