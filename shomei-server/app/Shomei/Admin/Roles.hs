-- | @shomei-admin roles@ (MasterPlan 7 EP-1): declare roles and grant them to users, without
-- the HTTP server running. This is the bootstrap path for the very first administrator — the
-- @\/admin@ surface is gated on the @admin@ role, so something outside HTTP has to grant it.
--
-- @
-- shomei-admin roles define       \<NAME\> [--description TEXT]
-- shomei-admin roles list-defined
-- shomei-admin roles grant  --user \<user_… | UUID\> --role NAME
-- shomei-admin roles revoke --user \<user_… | UUID\> --role NAME
-- shomei-admin roles list   --user \<user_… | UUID\>
-- @
--
-- Granting a role that is not in the registry fails loudly (exit 1) rather than minting a role
-- no gate will ever check — that is what @roles define@ exists for.
--
-- @define@ and @list-defined@ talk to the 'Shomei.Effect.RoleStore.RoleStore' port directly:
-- catalog metadata is not a security event, so they publish no audit event. @grant@ and
-- @revoke@ go through 'Shomei.Workflow.Roles', which audits them as @role_granted@ /
-- @role_revoked@ with a @NULL@ actor (there is no authenticated admin on the box).
module Shomei.Admin.Roles
  ( RolesCommand (..),
    rolesParser,
    runRoles,
  )
where

import Control.Monad (forM_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Options.Applicative
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Domain.Claims (Role (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.RoleStore (RoleDefinition (..), RoleStore, defineRole, listDefinedRoles)
import Shomei.Effect.UserStore (UserStore)
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId, idText, parseId, userIdFromUUID)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.RoleStore (runRoleStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Workflow.Roles (grantRoleTo, revokeRoleFrom, rolesOf)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The command tree -----------------------------------------------------------

data RolesCommand
  = RolesDefine Text (Maybe Text)
  | RolesListDefined
  | RolesGrant Text Text
  | RolesRevoke Text Text
  | RolesList Text

rolesParser :: Parser RolesCommand
rolesParser =
  hsubparser
    ( command "define" (info defineOpts (progDesc "Declare a role so it can be granted"))
        <> command "list-defined" (info (pure RolesListDefined) (progDesc "Show the role registry"))
        <> command "grant" (info (RolesGrant <$> userOpt <*> roleOpt) (progDesc "Grant a defined role to a user"))
        <> command "revoke" (info (RolesRevoke <$> userOpt <*> roleOpt) (progDesc "Revoke a role from a user"))
        <> command "list" (info (RolesList <$> userOpt) (progDesc "Show the roles granted to a user"))
    )
  where
    defineOpts =
      RolesDefine
        <$> (Text.pack <$> argument str (metavar "NAME"))
        <*> optional (Text.pack <$> strOption (long "description" <> metavar "TEXT" <> help "What the role is for"))
    userOpt =
      Text.pack
        <$> strOption (long "user" <> metavar "USER_ID" <> help "Typed id (user_…) or bare UUID")
    roleOpt =
      Text.pack <$> strOption (long "role" <> metavar "NAME" <> help "Role name")

-- Execution ------------------------------------------------------------------

runRoles :: AdminEnv -> RolesCommand -> IO ()
runRoles env = \case
  RolesDefine rawRole mDesc -> do
    role <- parseRole rawRole
    fresh <- runOrDie env.pool do
      ts <- now
      defineRole role mDesc ts
    putStrLn
      if fresh
        then "defined role " <> roleString role
        else "role " <> roleString role <> " was already defined"
  RolesListDefined -> do
    defs <- runOrDie env.pool listDefinedRoles
    forM_ defs \d ->
      putStrLn (roleString d.role <> maybe "" (\t -> " — " <> Text.unpack t) d.description)
  RolesGrant rawUser rawRole -> do
    uid <- parseUserRef rawUser
    role <- parseRole rawRole
    outcome <- runOrDie env.pool (grantRoleTo Nothing uid role)
    case outcome of
      Left e -> dieAuthError e
      Right True -> putStrLn ("granted " <> roleString role <> " to " <> Text.unpack (idText uid))
      Right False -> putStrLn ("user already had role " <> roleString role)
  RolesRevoke rawUser rawRole -> do
    uid <- parseUserRef rawUser
    role <- parseRole rawRole
    outcome <- runOrDie env.pool (revokeRoleFrom Nothing uid role)
    case outcome of
      Left e -> dieAuthError e
      Right True -> putStrLn ("revoked " <> roleString role <> " from " <> Text.unpack (idText uid))
      Right False -> putStrLn "no such grant"
  RolesList rawUser -> do
    uid <- parseUserRef rawUser
    outcome <- runOrDie env.pool (rolesOf uid)
    case outcome of
      Left e -> dieAuthError e
      Right roles -> forM_ (Set.toList roles) (putStrLn . roleString)

-- | Render the typed errors the role workflows can return, each with the fix.
dieAuthError :: AuthError -> IO a
dieAuthError = \case
  UserNotFound -> die "user not found"
  RoleNotDefined (Role r) ->
    die
      ( "role not defined: "
          <> Text.unpack r
          <> " (define it first: shomei-admin roles define "
          <> Text.unpack r
          <> ")"
      )
  other -> die ("unexpected error: " <> show other)

-- | A user reference is either the typed id rendered by the API (@user_01ABC…@) or the bare
-- UUID the audit columns speak. Operators paste whichever they have in front of them.
parseUserRef :: Text -> IO UserId
parseUserRef raw =
  case parseId raw of
    Right uid -> pure uid
    Left _ ->
      case UUID.fromText raw of
        Just uuid -> pure (userIdFromUUID uuid)
        Nothing -> die ("--user must be a typed id (user_…) or a UUID, got " <> Text.unpack raw)

-- | Role names are trimmed and must be non-blank. Validating at the boundary keeps the
-- workflow free of shape checks (it treats a 'Role' as opaque text).
parseRole :: Text -> IO Role
parseRole raw =
  let trimmed = Text.strip raw
   in if Text.null trimmed
        then die "role name must not be blank"
        else pure (Role trimmed)

roleString :: Role -> String
roleString (Role r) = Text.unpack r

-- | The minimal chain the role commands need, mirroring @Shomei.Admin.Users.runSignup@.
-- @UserStore@ is present because 'grantRoleTo' resolves the subject before granting.
runRolesEff ::
  Pool ->
  Eff '[UserStore, RoleStore, AuthEventPublisher, Clock, Database, Error AuthError, IOE] a ->
  IO (Either AuthError a)
runRolesEff pool =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runClockIO
    . runAuthEventPublisherPostgres
    . runRoleStorePostgres
    . runUserStorePostgres

runOrDie ::
  Pool ->
  Eff '[UserStore, RoleStore, AuthEventPublisher, Clock, Database, Error AuthError, IOE] a ->
  IO a
runOrDie pool act = do
  res <- runRolesEff pool act
  either (\e -> die ("database error: " <> show e)) pure res

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
