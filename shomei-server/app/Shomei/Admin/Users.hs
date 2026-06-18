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
import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.LoginId (loginIdFromEmail, loginIdText)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.PasswordBreachChecker (BreachResult (..), PasswordBreachChecker (..))
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.UserStore (UserStore)
import Shomei.Error (AuthError)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
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
  outcome <- runSignup env.pool (signup env.config cmd)
  case outcome of
    Left infra -> die ("infrastructure error: " <> show infra)
    Right (Left rejected) -> die ("signup rejected: " <> show rejected)
    Right (Right (user, _)) ->
      putStrLn ("created user " <> show user.userId <> " <" <> Text.unpack (loginIdText user.loginId) <> ">")

-- | Run a 'signup' over the PostgreSQL interpreters, with a fake signer.
runSignup ::
  Pool ->
  Eff
    [ UserStore,
      CredentialStore,
      SessionStore,
      RefreshTokenStore,
      PasswordBreachChecker,
      PasswordHasher,
      TokenSigner,
      AuthEventPublisher,
      Clock,
      TokenGen,
      Database,
      Error AuthError,
      IOE
    ]
    a ->
  IO (Either AuthError a)
runSignup pool =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runTokenGenCrypto
    . runClockIO
    . runAuthEventPublisherPostgres
    . runTokenSignerFake
    . runPasswordHasherCrypto
    . runPasswordBreachCheckerNoCheck
    . runRefreshTokenStorePostgres
    . runSessionStorePostgres
    . runCredentialStorePostgres
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
