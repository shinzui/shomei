-- | PostgreSQL interpreter for the 'RoleStore' port: the @shomei_roles@ registry and the
-- @shomei_role_grants@ table.
--
-- @DefineRole@, @GrantRole@, and @RevokeRole@ report whether they changed anything by reading
-- @rowsAffected@; the @ON CONFLICT DO NOTHING@ clauses make them idempotent, so a caller
-- publishes an audit event only on a real state change.
--
-- Like 'Shomei.Postgres.AuthEventReader' this interpreter needs no @IOE :> es@ constraint: every
-- operation goes through the @Database@ effect with no @liftIO@.
module Shomei.Postgres.RoleStore
  ( runRoleStorePostgres,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
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
import Shomei.Domain.Claims (Role (..))
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
  GrantRole uid (Role r) by ts -> do
    let row = (userIdToUUID uid, r, userIdToUUID <$> by, ts)
    res <- runSession (Session.statement row grantRoleStmt)
    changed <$> either dbFail pure res
  RevokeRole uid (Role r) -> do
    res <- runSession (Session.statement (userIdToUUID uid, r) revokeRoleStmt)
    changed <$> either dbFail pure res
  ListRolesForUser uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) listRolesForUserStmt)
    Set.fromList . map Role <$> either dbFail pure res
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

-- | @rowsAffected@ is 0 when the user already held the role.
grantRoleStmt :: Statement (UUID, Text, Maybe UUID, UTCTime) Int64
grantRoleStmt =
  preparable
    """
    INSERT INTO shomei.shomei_role_grants (user_id, role, granted_by, granted_at)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (user_id, role) DO NOTHING
    """
    ( contrazip4
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.uuid))
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

listRolesForUserStmt :: Statement UUID [Text]
listRolesForUserStmt =
  preparable
    """
    SELECT role
    FROM shomei.shomei_role_grants
    WHERE user_id = $1
    ORDER BY role
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowList (D.column (D.nonNullable D.text)))
