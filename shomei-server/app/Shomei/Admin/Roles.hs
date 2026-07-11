-- | @shomei-admin roles@ (MasterPlan 7 EP-1, extended by EP-9): declare roles, wire permissions
-- onto them, and grant them (optionally for a bounded window) to users — all without the HTTP
-- server running. This is the bootstrap path for the very first administrator: the @\/admin@
-- surface is gated on the @admin@ role, so something outside HTTP has to grant it.
--
-- @
-- shomei-admin roles define       \<NAME\> [--description TEXT]
-- shomei-admin roles list-defined
-- shomei-admin roles allow        \<ROLE\> \<PERMISSION\>
-- shomei-admin roles disallow     \<ROLE\> \<PERMISSION\>
-- shomei-admin roles show         \<ROLE\>
-- shomei-admin roles grant  --user \<user_… | UUID\> --role NAME [--expires-in \<dur\> | --expires-at \<ISO8601\>]
-- shomei-admin roles revoke --user \<user_… | UUID\> --role NAME
-- shomei-admin roles list   --user \<user_… | UUID\>
-- @
--
-- Granting a role that is not in the registry fails loudly (exit 1) rather than minting a role
-- no gate will ever check — that is what @roles define@ exists for. Likewise @allow@ refuses a
-- permission on an undefined role.
--
-- @define@, @list-defined@, @allow@, @disallow@, and @show@ talk to the
-- 'Shomei.Effect.RoleStore.RoleStore' port directly: catalog metadata (including permission
-- wiring) is not a security event, so they publish no audit event. @grant@ and @revoke@ go
-- through 'Shomei.Workflow.Roles', which audits them as @role_granted@ / @role_revoked@ with a
-- @NULL@ actor (there is no authenticated admin on the box); a time-bound grant records its
-- expiry in the @role_granted@ payload.
module Shomei.Admin.Roles
  ( RolesCommand (..),
    GrantExpiry (..),
    rolesParser,
    runRoles,
  )
where

import Control.Monad (forM_)
import Data.Char (isDigit, isSpace)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Options.Applicative
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Domain.Claims (Permission (..), Role (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.RoleStore
  ( RoleDefinition (..),
    RoleStore,
    allowPermission,
    defineRole,
    disallowPermission,
    listDefinedRoles,
    listPermissionsForRole,
  )
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

-- | How a grant's expiry was specified on the command line, resolved to an absolute instant at
-- run time (see 'resolveExpiry'). The two forms are mutually exclusive.
data GrantExpiry
  = -- | @--expires-in \<n\>(s|m|h|d)@: relative to the CLI's clock at run time.
    ExpiresIn NominalDiffTime
  | -- | @--expires-at \<ISO8601 UTC\>@: an absolute instant.
    ExpiresAt UTCTime
  deriving stock (Eq, Show)

data RolesCommand
  = RolesDefine Text (Maybe Text)
  | RolesListDefined
  | RolesAllow Text Text
  | RolesDisallow Text Text
  | RolesShow Text
  | RolesGrant Text Text (Maybe GrantExpiry)
  | RolesRevoke Text Text
  | RolesList Text

rolesParser :: Parser RolesCommand
rolesParser =
  hsubparser
    ( command "define" (info defineOpts (progDesc "Declare a role so it can be granted"))
        <> command "list-defined" (info (pure RolesListDefined) (progDesc "Show the role registry"))
        <> command "allow" (info allowOpts (progDesc "Attach a permission to a role"))
        <> command "disallow" (info disallowOpts (progDesc "Detach a permission from a role"))
        <> command "show" (info showOpts (progDesc "Show a role and the permissions it implies"))
        <> command "grant" (info (RolesGrant <$> userOpt <*> roleOpt <*> optional expiryOpt) (progDesc "Grant a defined role to a user"))
        <> command "revoke" (info (RolesRevoke <$> userOpt <*> roleOpt) (progDesc "Revoke a role from a user"))
        <> command "list" (info (RolesList <$> userOpt) (progDesc "Show the roles granted to a user"))
    )
  where
    defineOpts =
      RolesDefine
        <$> (Text.pack <$> argument str (metavar "NAME"))
        <*> optional (Text.pack <$> strOption (long "description" <> metavar "TEXT" <> help "What the role is for"))
    allowOpts = RolesAllow <$> roleArg <*> permissionArg
    disallowOpts = RolesDisallow <$> roleArg <*> permissionArg
    showOpts = RolesShow <$> roleArg
    roleArg = Text.pack <$> argument str (metavar "ROLE")
    permissionArg = Text.pack <$> argument str (metavar "PERMISSION")
    userOpt =
      Text.pack
        <$> strOption (long "user" <> metavar "USER_ID" <> help "Typed id (user_…) or bare UUID")
    roleOpt =
      Text.pack <$> strOption (long "role" <> metavar "NAME" <> help "Role name")
    -- '--expires-in' and '--expires-at' are alternatives: supplying both leaves the second flag
    -- unconsumed and optparse reports an error, which is the mutually-exclusive behaviour we want.
    expiryOpt =
      (ExpiresIn <$> option durationReader (long "expires-in" <> metavar "DURATION" <> help "Grant expiry as <n>(s|m|h|d), e.g. 4h"))
        <|> (ExpiresAt <$> option iso8601Reader (long "expires-at" <> metavar "ISO8601" <> help "Grant expiry as an ISO8601 UTC instant"))

-- | @<n>(s|m|h|d)@ → 'NominalDiffTime'. A bare number, a bad unit, or trailing junk is rejected.
durationReader :: ReadM NominalDiffTime
durationReader =
  eitherReader \s ->
    maybe (Left ("expected <n>(s|m|h|d), e.g. 4h; got " <> show s)) Right (parseDuration s)

parseDuration :: String -> Maybe NominalDiffTime
parseDuration s = case span isDigit s of
  (digits@(_ : _), [unit]) -> do
    n <- readInteger digits
    mult <- case unit of
      's' -> Just 1
      'm' -> Just 60
      'h' -> Just 3600
      'd' -> Just 86400
      _ -> Nothing
    pure (fromInteger (n * mult))
  _ -> Nothing
  where
    readInteger ds = case reads ds of
      [(n, "")] -> Just (n :: Integer)
      _ -> Nothing

-- | An ISO8601 UTC timestamp → 'UTCTime' (e.g. @2026-07-11T21:00:00Z@).
iso8601Reader :: ReadM UTCTime
iso8601Reader =
  eitherReader \s ->
    maybe (Left ("expected an ISO8601 UTC instant, e.g. 2026-07-11T21:00:00Z; got " <> show s)) Right (iso8601ParseM s)

-- Execution ------------------------------------------------------------------

-- | Resolve a parsed 'GrantExpiry' to an absolute instant. @--expires-in@ is relative to the CLI's
-- clock now; @--expires-at@ is already absolute. 'Nothing' (no flag) means the grant never expires.
resolveExpiry :: Maybe GrantExpiry -> IO (Maybe UTCTime)
resolveExpiry Nothing = pure Nothing
resolveExpiry (Just (ExpiresAt t)) = pure (Just t)
resolveExpiry (Just (ExpiresIn d)) = Just . addUTCTime d <$> getCurrentTime

-- | The outcome of a permission-wiring command, so the boundary (IO) prints or dies without the
-- eff needing to.
data AllowOutcome = AllowRoleUndefined | NewlyAllowed | AlreadyAllowed

data DisallowOutcome = DisallowRoleUndefined | Detached | NotAttached

data ShowOutcome = ShowRoleUndefined | ShowRole RoleDefinition (Set.Set Permission)

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
  RolesAllow rawRole rawPerm -> do
    role <- parseRole rawRole
    perm <- parsePermission rawPerm
    outcome <- runOrDie env.pool (allowEff role perm)
    case outcome of
      AllowRoleUndefined -> dieAuthError (RoleNotDefined role)
      NewlyAllowed -> putStrLn ("allowed " <> permString perm <> " for role " <> roleString role)
      AlreadyAllowed -> putStrLn ("role " <> roleString role <> " already allowed " <> permString perm)
  RolesDisallow rawRole rawPerm -> do
    role <- parseRole rawRole
    perm <- parsePermission rawPerm
    outcome <- runOrDie env.pool (disallowEff role perm)
    case outcome of
      DisallowRoleUndefined -> dieAuthError (RoleNotDefined role)
      Detached -> putStrLn ("disallowed " <> permString perm <> " for role " <> roleString role)
      NotAttached -> putStrLn ("role " <> roleString role <> " did not allow " <> permString perm)
  RolesShow rawRole -> do
    role <- parseRole rawRole
    outcome <- runOrDie env.pool (showEff role)
    case outcome of
      ShowRoleUndefined -> dieAuthError (RoleNotDefined role)
      ShowRole d perms -> do
        putStrLn (roleString d.role <> maybe "" (\t -> " — " <> Text.unpack t) d.description)
        if Set.null perms
          then putStrLn "  (no permissions)"
          else forM_ (Set.toList perms) \p -> putStrLn ("  " <> permString p)
  RolesGrant rawUser rawRole mExpiry -> do
    uid <- parseUserRef rawUser
    role <- parseRole rawRole
    expiry <- resolveExpiry mExpiry
    outcome <- runOrDie env.pool (grantRoleTo Nothing expiry uid role)
    case outcome of
      Left e -> dieAuthError e
      Right True ->
        putStrLn
          ( "granted "
              <> roleString role
              <> " to "
              <> Text.unpack (idText uid)
              <> maybe "" (\t -> " (expires " <> iso8601Show t <> ")") expiry
          )
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

-- | Attach a permission to a role, refusing an undefined role first (the FK backstops it, but a
-- typed pre-check gives a clear message and matches the grant path's behaviour).
allowEff :: (RoleStore :> es, Clock :> es) => Role -> Permission -> Eff es AllowOutcome
allowEff role perm = do
  defined <- definedRoleNames
  if not (role `Set.member` defined)
    then pure AllowRoleUndefined
    else do
      ts <- now
      changed <- allowPermission role perm ts
      pure (if changed then NewlyAllowed else AlreadyAllowed)

disallowEff :: (RoleStore :> es) => Role -> Permission -> Eff es DisallowOutcome
disallowEff role perm = do
  defined <- definedRoleNames
  if not (role `Set.member` defined)
    then pure DisallowRoleUndefined
    else do
      changed <- disallowPermission role perm
      pure (if changed then Detached else NotAttached)

showEff :: (RoleStore :> es) => Role -> Eff es ShowOutcome
showEff role = do
  defs <- listDefinedRoles
  case [d | d <- defs, d.role == role] of
    [] -> pure ShowRoleUndefined
    (d : _) -> ShowRole d <$> listPermissionsForRole role

definedRoleNames :: (RoleStore :> es) => Eff es (Set.Set Role)
definedRoleNames = Set.fromList . map (.role) <$> listDefinedRoles

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

-- | Permission strings are trimmed and must be non-blank and contain no internal whitespace. The
-- @resource:verb@ shape is a documented convention, not enforced grammar — only blank/whitespace
-- strings are rejected.
parsePermission :: Text -> IO Permission
parsePermission raw =
  let trimmed = Text.strip raw
   in if Text.null trimmed || Text.any isSpace trimmed
        then die ("invalid permission: " <> show raw <> " (must be non-blank with no whitespace)")
        else pure (Permission trimmed)

roleString :: Role -> String
roleString (Role r) = Text.unpack r

permString :: Permission -> String
permString (Permission p) = Text.unpack p

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
