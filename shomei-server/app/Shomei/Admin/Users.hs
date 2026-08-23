-- | @shomei-admin users create@ (EP-4, M3): seed a user account without the HTTP API by
-- driving the existing 'Shomei.Session.Authentication.Workflow.signup' through the full PostgreSQL interpreter stack
-- (with a trivial 'TokenSigner' fake — the CLI does not need a real access token).
module Shomei.Admin.Users
  ( createUserAction,
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Shomei.Account.Credential.Postgres (runCredentialStorePostgres)
import Shomei.Account.Credential.Store (CredentialStore)
import Shomei.Account.Email.Domain (mkEmail)
import Shomei.Account.LoginId.Domain (loginIdText, mkLoginId)
import Shomei.Account.Password.Breach.Store (BreachResult (..), PasswordBreachChecker (..))
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.Password.Hash.Postgres (Argon2Params, HashingLimiter, newHashingLimiter, runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Account.Password.Hash.Store (PasswordHasher)
import Shomei.Account.User.Domain (User (..))
import Shomei.Account.User.Postgres (runUserStorePostgres)
import Shomei.Account.User.Store (UserStore)
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Audit.Publisher.Postgres (runAuthEventPublisherPostgres)
import Shomei.Audit.Publisher.Store (AuthEventPublisher)
import Shomei.Authorization.Claims.Domain (Role (..))
import Shomei.Authorization.Claims.Store (ClaimsEnricher, runClaimsEnricherNull)
import Shomei.Authorization.Role.Postgres (runRoleStorePostgres)
import Shomei.Authorization.Role.Store (RoleStore)
import Shomei.Authorization.Role.Workflow (undefinedDefaultRoles)
import Shomei.Config (ShomeiConfig (..))
import Shomei.Error (AuthError)
import Shomei.OAuth.IdToken.Domain (IdToken (..))
import Shomei.Persistence.Database.Postgres (Database, runDatabasePool)
import Shomei.Session.Authentication.Workflow (signup)
import Shomei.Session.Command (SignupCommand (..))
import Shomei.Session.Token.Domain (AccessToken (..))
import Shomei.Session.Token.Generator (TokenGen)
import Shomei.Session.UnitOfWork.Postgres (runAuthUnitOfWorkPostgres)
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork)
import Shomei.SigningKey.Signer (TokenSigner (..))
import Shomei.Time.Postgres (runClockIO)
import Shomei.Time.Store (Clock)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

createUserAction :: AdminEnv -> Text -> Text -> Maybe Text -> IO ()
createUserAction env emailArg pwArg mDisplay = do
  email <- either (\e -> die ("invalid email: " <> show e)) pure (mkEmail emailArg)
  loginId <- either (\e -> die ("invalid login id: " <> show e)) pure (mkLoginId emailArg)
  -- The server validates 'defaultRoles' against the registry at boot; the CLI has no boot, so it
  -- checks here. Without this, a typo in SHOMEI_DEFAULT_ROLES surfaces as a raw foreign-key
  -- violation from deep inside 'signup', after the user row has already been written.
  checkDefaultRoles env
  let cmd =
        SignupCommand
          { loginId = loginId,
            email = Just email,
            password = PlainPassword pwArg,
            displayName = mDisplay
          }
  -- The CLI hashes exactly one password, so a limiter of one is right and costs nothing.
  limiter <- newHashingLimiter 1
  outcome <- runSignup env.pool limiter env.argon2 (signup env.config cmd)
  case outcome of
    Left infra -> die ("infrastructure error: " <> show infra)
    Right (Left rejected) -> die ("signup rejected: " <> show rejected)
    Right (Right (user, _)) ->
      putStrLn ("created user " <> show user.userId <> " <" <> Text.unpack (loginIdText user.loginId) <> ">")

-- | Run a 'signup' over the PostgreSQL interpreters, with a fake signer.
--
-- 'signup' applies @config.defaultRoles@ (reading the real 'RoleStore' and auditing each grant
-- through the real publisher), so a user created here receives exactly the roles an HTTP signup
-- would — no special-casing. 'ClaimsEnricher' is the null interpreter because the token this
-- path mints is the discarded fake one.
runSignup ::
  Pool ->
  HashingLimiter ->
  Argon2Params ->
  Eff
    [ UserStore,
      RoleStore,
      CredentialStore,
      AuthUnitOfWork,
      PasswordBreachChecker,
      PasswordHasher,
      TokenSigner,
      ClaimsEnricher,
      AuthEventPublisher,
      Clock,
      TokenGen,
      Database,
      Error AuthError,
      IOE
    ]
    a ->
  IO (Either AuthError a)
runSignup pool limiter argon2 =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runTokenGenCrypto
    . runClockIO
    . runAuthEventPublisherPostgres
    . runClaimsEnricherNull
    . runTokenSignerFake
    . runPasswordHasherCrypto limiter argon2
    . runPasswordBreachCheckerNoCheck
    . runAuthUnitOfWorkPostgres
    . runCredentialStorePostgres
    . runRoleStorePostgres
    . runUserStorePostgres

-- | Refuse to create a user when @SHOMEI_DEFAULT_ROLES@ names a role missing from the registry,
-- with the same message the server prints at boot.
checkDefaultRoles :: AdminEnv -> IO ()
checkDefaultRoles env
  | Set.null env.config.defaultRoles = pure ()
  | otherwise = do
      outcome <-
        runEff
          . runErrorNoCallStack @AuthError
          . runDatabasePool env.pool
          . runRoleStorePostgres
          $ undefinedDefaultRoles env.config
      case outcome of
        Left e -> die ("could not validate defaultRoles: " <> show e)
        Right missing
          | Set.null missing -> pure ()
          | otherwise ->
              die
                ( "SHOMEI_DEFAULT_ROLES names undefined roles: "
                    <> Text.unpack (Text.intercalate ", " [r | Role r <- Set.toList missing])
                    <> " (define them first: shomei-admin roles define <name>)"
                )

runTokenSignerFake :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFake = interpret_ \case
  SignAccessToken _ -> pure (AccessToken "admin-cli-token")
  SignIdToken _ -> pure (IdToken "admin-cli-id-token")

-- | The admin CLI does not perform the network breach check (mirroring its fake signer): it is
-- an operator-trusted seeding path, so every password is treated as not-breached. The HTTP HIBP
-- interpreter lives in 'Shomei.Server.BreachChecker' and is used only by the running server.
runPasswordBreachCheckerNoCheck :: Eff (PasswordBreachChecker : es) a -> Eff es a
runPasswordBreachCheckerNoCheck = interpret_ \case
  CheckPasswordBreached _ -> pure NotBreached

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
