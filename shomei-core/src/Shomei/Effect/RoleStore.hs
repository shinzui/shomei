{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The role port: the declared role catalog (the "registry", @shomei_roles@), the durable
-- "user has role" facts (@shomei_role_grants@), and the role→permission definitions
-- (@shomei_role_permissions@).
--
-- Roles are flat: a grant is a @(user, role)@ pair with no project, organization, or resource
-- scope. A role implies a set of flat verb-noun /permissions/ (EP-9), resolved to the union
-- across a subject's roles at token mint. This is Shōmei's tier-1 authorization story —
-- self-contained, requiring no second system, and sufficient to gate Shōmei's own @\/admin@
-- surface. Fine-grained, relationship-derived authorization ("editor of /this/ project", live
-- revocation, caveats) is deliberately out of scope; see @docs\/user\/security.md@ for the
-- two-tier boundary.
module Shomei.Effect.RoleStore
  ( RoleStore (..),
    RoleDefinition (..),
    defineRole,
    listDefinedRoles,
    grantRole,
    revokeRole,
    listRolesForUser,
    allowPermission,
    disallowPermission,
    listPermissionsForRole,
    permissionsForRoles,
  )
where

import Data.Set (Set)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Claims (Permission, Role)
import Shomei.Id (UserId)
import Shomei.Prelude

-- | One row of the role registry (the @shomei_roles@ table): a role an operator has declared
-- grantable, with an optional human description.
data RoleDefinition = RoleDefinition
  { role :: !Role,
    description :: !(Maybe Text),
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data RoleStore :: Effect where
  -- | Declare a role in the registry. Returns 'True' if newly defined, 'False' if it already
  -- existed (idempotent; the description of an existing role is NOT updated).
  DefineRole :: Role -> Maybe Text -> UTCTime -> RoleStore m Bool
  -- | The full registry, sorted by role name. Deployments have few roles; no paging.
  ListDefinedRoles :: RoleStore m [RoleDefinition]
  -- | Record a grant, with an optional expiry ('Nothing' = does not expire). Returns 'True' when
  -- state changed: a new grant, or an existing grant whose expiry differs (re-granting updates
  -- the expiry — upsert). Callers publish the audit event only on 'True'.
  GrantRole :: UserId -> Role -> Maybe UserId -> Maybe UTCTime -> UTCTime -> RoleStore m Bool
  -- | Remove a grant. Returns 'True' if a grant was removed.
  RevokeRole :: UserId -> Role -> RoleStore m Bool
  -- | The subject's roles as of the given instant: grants whose @expires_at@ is at or before it
  -- are excluded. Callers pass the mint timestamp.
  ListRolesForUser :: UserId -> UTCTime -> RoleStore m (Set Role)
  -- | Attach a permission to a role. 'True' = newly attached, 'False' = already present.
  AllowPermission :: Role -> Permission -> UTCTime -> RoleStore m Bool
  -- | Detach a permission from a role. 'True' = something was detached.
  DisallowPermission :: Role -> Permission -> RoleStore m Bool
  -- | The permissions attached to a single role, sorted.
  ListPermissionsForRole :: Role -> RoleStore m (Set Permission)
  -- | The union of permissions across a role set — one query, used by the mint path.
  PermissionsForRoles :: Set Role -> RoleStore m (Set Permission)

type instance DispatchOf RoleStore = Dynamic

defineRole :: (RoleStore :> es) => Role -> Maybe Text -> UTCTime -> Eff es Bool
defineRole r desc ts = send (DefineRole r desc ts)

listDefinedRoles :: (RoleStore :> es) => Eff es [RoleDefinition]
listDefinedRoles = send ListDefinedRoles

grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> Maybe UTCTime -> UTCTime -> Eff es Bool
grantRole uid r by expiry ts = send (GrantRole uid r by expiry ts)

revokeRole :: (RoleStore :> es) => UserId -> Role -> Eff es Bool
revokeRole uid r = send (RevokeRole uid r)

listRolesForUser :: (RoleStore :> es) => UserId -> UTCTime -> Eff es (Set Role)
listRolesForUser uid asOf = send (ListRolesForUser uid asOf)

allowPermission :: (RoleStore :> es) => Role -> Permission -> UTCTime -> Eff es Bool
allowPermission r p ts = send (AllowPermission r p ts)

disallowPermission :: (RoleStore :> es) => Role -> Permission -> Eff es Bool
disallowPermission r p = send (DisallowPermission r p)

listPermissionsForRole :: (RoleStore :> es) => Role -> Eff es (Set Permission)
listPermissionsForRole = send . ListPermissionsForRole

permissionsForRoles :: (RoleStore :> es) => Set Role -> Eff es (Set Permission)
permissionsForRoles = send . PermissionsForRoles
