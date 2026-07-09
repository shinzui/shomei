{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The role port: the declared role catalog (the "registry", @shomei_roles@) and the durable
-- "user has role" facts (@shomei_role_grants@).
--
-- Roles are flat: a grant is a @(user, role)@ pair with no project, organization, or resource
-- scope. This is Shōmei's tier-1 authorization story — self-contained, requiring no second
-- system, and sufficient to gate Shōmei's own @\/admin@ surface. Fine-grained,
-- relationship-derived authorization ("editor of /this/ project", live revocation, caveats) is
-- deliberately out of scope; see @docs\/user\/security.md@ for the two-tier boundary.
module Shomei.Effect.RoleStore
  ( RoleStore (..),
    RoleDefinition (..),
    defineRole,
    listDefinedRoles,
    grantRole,
    revokeRole,
    listRolesForUser,
  )
where

import Data.Set (Set)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Claims (Role)
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
  -- | Record a grant. Returns 'True' if the grant is new, 'False' if it already existed
  -- (idempotent; callers publish the audit event only on 'True').
  GrantRole :: UserId -> Role -> Maybe UserId -> UTCTime -> RoleStore m Bool
  -- | Remove a grant. Returns 'True' if a grant was removed.
  RevokeRole :: UserId -> Role -> RoleStore m Bool
  ListRolesForUser :: UserId -> RoleStore m (Set Role)

type instance DispatchOf RoleStore = Dynamic

defineRole :: (RoleStore :> es) => Role -> Maybe Text -> UTCTime -> Eff es Bool
defineRole r desc ts = send (DefineRole r desc ts)

listDefinedRoles :: (RoleStore :> es) => Eff es [RoleDefinition]
listDefinedRoles = send ListDefinedRoles

grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> UTCTime -> Eff es Bool
grantRole uid r by ts = send (GrantRole uid r by ts)

revokeRole :: (RoleStore :> es) => UserId -> Role -> Eff es Bool
revokeRole uid r = send (RevokeRole uid r)

listRolesForUser :: (RoleStore :> es) => UserId -> Eff es (Set Role)
listRolesForUser = send . ListRolesForUser
