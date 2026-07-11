-- | The audited role-granting workflows: the single code path the @shomei-admin roles@ CLI and
-- (later) the admin HTTP API both drive, so a grant is recorded identically whichever entry
-- point performs it.
--
-- 'grantRoleTo' refuses a role absent from the registry ('Shomei.Error.RoleNotDefined'), which
-- is what turns @roles grant --role adminn@ from a silent no-op grant into a loud failure. The
-- PostgreSQL foreign key on @shomei_role_grants.role@ enforces the same invariant one layer
-- down, for code that bypasses this workflow.
--
-- These functions treat a 'Role' as opaque text and do NOT validate its /shape/. Trimming and
-- rejecting blank role names belongs to the boundary layers — the CLI parser and the HTTP
-- handlers — exactly as @mkEmail@ / @mkLoginId@ validate before a workflow ever runs.
module Shomei.Workflow.Roles
  ( grantRoleTo,
    revokeRoleFrom,
    rolesOf,
    applyDefaultRoles,
    undefinedDefaultRoles,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Effectful (Eff, (:>))
import Shomei.Config (ShomeiConfig (..))
import Shomei.Domain.Claims (Role)
import Shomei.Domain.Event qualified as Event
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.RoleStore
  ( RoleDefinition (..),
    RoleStore,
    grantRole,
    listDefinedRoles,
    listRolesForUser,
    revokeRole,
  )
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId)
import Shomei.Prelude

-- | Grant a role to a user, publishing 'Event.RoleGranted' only when the store reports a state
-- change (so re-running a grant does not spam the audit trail).
--
-- The first argument is the granting actor: 'Nothing' for a CLI bootstrap grant, where no
-- authenticated admin principal exists yet. The second is an optional expiry (EP-9): 'Nothing'
-- grants the role indefinitely, @Just t@ makes the grant stop appearing in tokens minted at or
-- after @t@. Re-granting an already-held role whose expiry /differs/ updates the window (upsert)
-- and reports @True@; an identical re-grant reports @False@ and stays audit-silent.
--
-- @Right True@ = state changed (newly granted, or expiry updated); @Right False@ = the user
-- already held the role with the same expiry.
grantRoleTo ::
  ( UserStore :> es,
    RoleStore :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  Maybe UserId ->
  Maybe UTCTime ->
  UserId ->
  Role ->
  Eff es (Either AuthError Bool)
grantRoleTo actor expiry subject role = do
  mUser <- findUserById subject
  case mUser of
    Nothing -> pure (Left UserNotFound)
    Just _ -> do
      defined <- definedRoleNames
      if not (role `Set.member` defined)
        then pure (Left (RoleNotDefined role))
        else do
          ts <- now
          changed <- grantRole subject role actor expiry ts
          when changed do
            publishAuthEvent (Event.RoleGranted (Event.RoleGrantedData subject role actor expiry ts))
          pure (Right changed)

-- | Revoke a role from a user. No registry check: revoking an existing grant must always work,
-- whatever the registry says today.
--
-- @Right True@ = a grant was removed; @Right False@ = there was nothing to revoke.
revokeRoleFrom ::
  ( UserStore :> es,
    RoleStore :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  Maybe UserId ->
  UserId ->
  Role ->
  Eff es (Either AuthError Bool)
revokeRoleFrom actor subject role = do
  mUser <- findUserById subject
  case mUser of
    Nothing -> pure (Left UserNotFound)
    Just _ -> do
      ts <- now
      changed <- revokeRole subject role
      when changed do
        publishAuthEvent (Event.RoleRevoked (Event.RoleRevokedData subject role actor ts))
      pure (Right changed)

-- | The roles currently granted to a user (as of now: expired grants are excluded).
rolesOf ::
  (UserStore :> es, RoleStore :> es, Clock :> es) =>
  UserId ->
  Eff es (Either AuthError (Set Role))
rolesOf subject = do
  mUser <- findUserById subject
  case mUser of
    Nothing -> pure (Left UserNotFound)
    Just _ -> do
      ts <- now
      Right <$> listRolesForUser subject ts

-- | Grant every configured default role to a freshly created user. Called by
-- @Shomei.Workflow.signup@ immediately after @createUser@, so the first access token the new
-- user receives already carries them. Each application is audited as 'Event.RoleGranted' with
-- no acting admin, exactly like a CLI bootstrap grant.
--
-- This deliberately skips the user-existence and registry checks 'grantRoleTo' performs:
-- @signup@ just created the user, and boot validated the roles against the registry (see
-- 'undefinedDefaultRoles'), which is append-only — so a boot-validated role cannot later vanish.
applyDefaultRoles ::
  (RoleStore :> es, AuthEventPublisher :> es) =>
  ShomeiConfig ->
  UserId ->
  UTCTime ->
  Eff es ()
applyDefaultRoles cfg subject ts =
  forM_ (Set.toList cfg.defaultRoles) \role -> do
    changed <- grantRole subject role Nothing Nothing ts
    when changed do
      publishAuthEvent (Event.RoleGranted (Event.RoleGrantedData subject role Nothing Nothing ts))

-- | The configured 'defaultRoles' missing from the registry. A nonempty result means the config
-- names roles nothing will ever check, and the process should refuse to serve.
--
-- The standalone server calls this at boot and exits naming the offending roles. An __embedding
-- host that sets @defaultRoles@ should call it wherever it assembles its ports__, for the same
-- reason: validating here rather than at each signup keeps the hot path free of catalog reads
-- and turns a config typo into an immediate startup failure instead of a stream of 500s.
undefinedDefaultRoles :: (RoleStore :> es) => ShomeiConfig -> Eff es (Set Role)
undefinedDefaultRoles cfg
  | Set.null cfg.defaultRoles = pure Set.empty
  | otherwise = do
      defined <- definedRoleNames
      pure (cfg.defaultRoles `Set.difference` defined)

definedRoleNames :: (RoleStore :> es) => Eff es (Set Role)
definedRoleNames = Set.fromList . map (.role) <$> listDefinedRoles
