-- | @shomei-admin users create@ (EP-4, M3): seed a user account without the HTTP API by
-- driving the existing 'Shomei.Workflow.signup' through the full PostgreSQL interpreter stack
-- (with a trivial 'TokenSigner' fake — the CLI does not need a real access token).
module Shomei.Admin.Users
  ( createUserAction,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Crypto (Argon2Params, HashingLimiter, newHashingLimiter, runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.LoginId (loginIdFromEmail, loginIdText)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork)
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher, runClaimsEnricherNull)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.PasswordBreachChecker (BreachResult (..), PasswordBreachChecker (..))
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.RoleStore (RoleStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.UserStore (UserStore)
import Shomei.Error (AuthError)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.AuthUnitOfWork (runAuthUnitOfWorkPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.RoleStore (runRoleStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Workflow (signup)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

createUserAction :: AdminEnv -> Text -> Text -> Maybe Text -> IO ()
createUserAction env emailArg pwArg mDisplay = do
  email <- either (\e -> die ("invalid email: " <> show e)) pure (mkEmail emailArg)
  let cmd =
        SignupCommand
          { loginId = loginIdFromEmail email,
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

runTokenSignerFake :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFake = interpret_ \case
  SignAccessToken _ -> pure (AccessToken "admin-cli-token")

-- | The admin CLI does not perform the network breach check (mirroring its fake signer): it is
-- an operator-trusted seeding path, so every password is treated as not-breached. The HTTP HIBP
-- interpreter lives in 'Shomei.Server.BreachChecker' and is used only by the running server.
runPasswordBreachCheckerNoCheck :: Eff (PasswordBreachChecker : es) a -> Eff es a
runPasswordBreachCheckerNoCheck = interpret_ \case
  CheckPasswordBreached _ -> pure NotBreached

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
