-- | PostgreSQL interpreter for the 'RoleStore' port: the @shomei_roles@ registry, the
-- @shomei_role_grants@ table (with an optional expiry), and the @shomei_role_permissions@
-- role→permission definitions.
--
-- @DefineRole@, @GrantRole@, @RevokeRole@, @AllowPermission@, and @DisallowPermission@ report
-- whether they changed anything by reading @rowsAffected@; the @ON CONFLICT@ clauses make the
-- inserts idempotent, so a caller publishes an audit event only on a real state change. @GrantRole@
-- is an upsert guarded by @expires_at IS DISTINCT FROM@, so re-granting with a different expiry
-- still reports a change while an identical re-grant stays silent.
--
-- Like 'Shomei.Postgres.AuthEventReader' this interpreter needs no @IOE :> es@ constraint: every
-- operation goes through the @Database@ effect with no @liftIO@.
module Shomei.Postgres.RoleStore
  ( runRoleStorePostgres,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip5)
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.UUID (UUID)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.Claims (Permission (..), Role (..))
import Shomei.Effect.RoleStore (RoleDefinition (..), RoleStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (userIdToUUID)
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

runRoleStorePostgres ::
  (Database :> es, Error AuthError :> es) =>
  Eff (RoleStore : es) a ->
  Eff es a
runRoleStorePostgres = interpret_ \case
  DefineRole (Role r) desc ts -> do
    res <- runSession (Session.statement (r, desc, ts) defineRoleStmt)
    changed <$> either dbFail pure res
  ListDefinedRoles -> do
    res <- runSession (Session.statement () listDefinedRolesStmt)
    either dbFail pure res
  GrantRole uid (Role r) by expiry ts -> do
    let row = (userIdToUUID uid, r, userIdToUUID <$> by, expiry, ts)
    res <- runSession (Session.statement row grantRoleStmt)
    changed <$> either dbFail pure res
  RevokeRole uid (Role r) -> do
    res <- runSession (Session.statement (userIdToUUID uid, r) revokeRoleStmt)
    changed <$> either dbFail pure res
  ListRolesForUser uid asOf -> do
    res <- runSession (Session.statement (userIdToUUID uid, asOf) listRolesForUserStmt)
    Set.fromList . map Role <$> either dbFail pure res
  AllowPermission (Role r) (Permission p) ts -> do
    res <- runSession (Session.statement (r, p, ts) allowPermissionStmt)
    changed <$> either dbFail pure res
  DisallowPermission (Role r) (Permission p) -> do
    res <- runSession (Session.statement (r, p) disallowPermissionStmt)
    changed <$> either dbFail pure res
  ListPermissionsForRole (Role r) -> do
    res <- runSession (Session.statement r permissionsForRoleStmt)
    Set.fromList . map Permission <$> either dbFail pure res
  PermissionsForRoles roles -> do
    let names = map (\(Role r) -> r) (Set.toList roles)
    res <- runSession (Session.statement names permissionsForRolesStmt)
    Set.fromList . map Permission <$> either dbFail pure res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    changed :: Int64 -> Bool
    changed = (> 0)

roleDefinitionDecoder :: D.Row RoleDefinition
roleDefinitionDecoder =
  RoleDefinition
    <$> (Role <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)

-- | @rowsAffected@ is 0 when the role was already defined. The existing description is left
-- untouched — a re-definition is a no-op, not an update.
defineRoleStmt :: Statement (Text, Maybe Text, UTCTime) Int64
defineRoleStmt =
  preparable
    """
    INSERT INTO shomei.shomei_roles (role, description, created_at)
    VALUES ($1, $2, $3)
    ON CONFLICT (role) DO NOTHING
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.rowsAffected

listDefinedRolesStmt :: Statement () [RoleDefinition]
listDefinedRolesStmt =
  preparable
    """
    SELECT role, description, created_at
    FROM shomei.shomei_roles
    ORDER BY role
    """
    E.noParams
    (D.rowList roleDefinitionDecoder)

-- | Upsert. @rowsAffected@ is 0 only when an identical grant (same expiry) already existed: the
-- @IS DISTINCT FROM@ guard means a re-grant that changes the expiry still updates the row and
-- reports a change, so the workflow re-audits it, while an unchanged re-grant stays silent.
grantRoleStmt :: Statement (UUID, Text, Maybe UUID, Maybe UTCTime, UTCTime) Int64
grantRoleStmt =
  preparable
    """
    INSERT INTO shomei.shomei_role_grants (user_id, role, granted_by, expires_at, granted_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (user_id, role) DO UPDATE
      SET expires_at = EXCLUDED.expires_at,
          granted_by = EXCLUDED.granted_by,
          granted_at = EXCLUDED.granted_at
      WHERE shomei_role_grants.expires_at IS DISTINCT FROM EXCLUDED.expires_at
    """
    ( contrazip5
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.uuid))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.rowsAffected

-- | @rowsAffected@ is 0 when there was no such grant to remove.
revokeRoleStmt :: Statement (UUID, Text) Int64
revokeRoleStmt =
  preparable
    """
    DELETE FROM shomei.shomei_role_grants
    WHERE user_id = $1 AND role = $2
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.text)))
    D.rowsAffected

-- | Expiry-filtered as of $2: a grant whose @expires_at@ is at or before the instant is excluded.
-- A NULL @expires_at@ (forever) always passes.
listRolesForUserStmt :: Statement (UUID, UTCTime) [Text]
listRolesForUserStmt =
  preparable
    """
    SELECT role
    FROM shomei.shomei_role_grants
    WHERE user_id = $1 AND (expires_at IS NULL OR expires_at > $2)
    ORDER BY role
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    (D.rowList (D.column (D.nonNullable D.text)))

-- | @rowsAffected@ is 0 when the permission was already attached to the role.
allowPermissionStmt :: Statement (Text, Text, UTCTime) Int64
allowPermissionStmt =
  preparable
    """
    INSERT INTO shomei.shomei_role_permissions (role, permission, created_at)
    VALUES ($1, $2, $3)
    ON CONFLICT (role, permission) DO NOTHING
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.rowsAffected

-- | @rowsAffected@ is 0 when there was no such attachment to remove.
disallowPermissionStmt :: Statement (Text, Text) Int64
disallowPermissionStmt =
  preparable
    """
    DELETE FROM shomei.shomei_role_permissions
    WHERE role = $1 AND permission = $2
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
    D.rowsAffected

permissionsForRoleStmt :: Statement Text [Text]
permissionsForRoleStmt =
  preparable
    """
    SELECT permission
    FROM shomei.shomei_role_permissions
    WHERE role = $1
    ORDER BY permission
    """
    (E.param (E.nonNullable E.text))
    (D.rowList (D.column (D.nonNullable D.text)))

-- | The deduplicated union of permissions across a role set — one round trip on the mint path.
permissionsForRolesStmt :: Statement [Text] [Text]
permissionsForRolesStmt =
  preparable
    """
    SELECT DISTINCT permission
    FROM shomei.shomei_role_permissions
    WHERE role = ANY ($1)
    ORDER BY permission
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    (D.rowList (D.column (D.nonNullable D.text)))
