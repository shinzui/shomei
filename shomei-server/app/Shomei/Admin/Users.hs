-- | @shomei-admin users create@ (EP-4, M3): seed a user account without the HTTP API by
-- driving the existing 'Shomei.Session.Authentication.Workflow.signup' through the full PostgreSQL interpreter stack
-- (with a trivial 'TokenSigner' fake — the CLI does not need a real access token).
module Shomei.Admin.Users
  ( createUserAction,
  )
where

import Control.Monad (when)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Shomei.Account.Credential.Postgres (runCredentialStorePostgres)
import Shomei.Account.Credential.Store (CredentialStore)
import Shomei.Account.Email.Domain (mkEmail)
import Shomei.Account.LoginId.Domain (loginIdText, mkLoginId)
import Shomei.Account.Password.Breach.Store (PasswordBreachChecker)
import Shomei.Account.Password.Domain (PasswordPolicy (..), PlainPassword (..))
import Shomei.Account.Password.Hash.Postgres (Argon2Params, HashingLimiter, newHashingLimiter, runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Account.Password.Hash.Store (PasswordHasher)
import Shomei.Account.User.Domain (User (..))
import Shomei.Account.User.Postgres (runUserStorePostgres)
import Shomei.Account.User.Store (UserStore, markUserEmailVerified)
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
import Shomei.Id (UserId)
import Shomei.OAuth.IdToken.Domain (IdToken (..))
import Shomei.Persistence.Database.Postgres (Database, runDatabasePool)
import Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp)
import Shomei.Session.Authentication.Workflow (signup)
import Shomei.Session.Command (SignupCommand (..))
import Shomei.Session.Token.Domain (AccessToken (..))
import Shomei.Session.Token.Generator (TokenGen)
import Shomei.Session.UnitOfWork.Postgres (runAuthUnitOfWorkPostgres)
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork)
import Shomei.SigningKey.Signer (TokenSigner (..))
import Shomei.Time.Postgres (runClockIO)
import Shomei.Time.Store (Clock, now)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

createUserAction :: AdminEnv -> Text -> PlainPassword -> Maybe Text -> Bool -> IO ()
createUserAction env emailArg password mDisplay verified = do
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
            password = password,
            displayName = mDisplay
          }
  -- The CLI hashes exactly one password, so a limiter of one is right and costs nothing.
  limiter <- newHashingLimiter 1
  manager <- newTlsManager
  outcome <-
    runSignup
      env.pool
      limiter
      env.argon2
      manager
      env.config.passwordPolicy.breachCheckTimeoutMs
      (signup env.config cmd)
  case outcome of
    Left infra -> die ("infrastructure error: " <> show infra)
    Right (Left rejected) -> die ("signup rejected: " <> show rejected)
    Right (Right (user, _)) -> do
      when verified do
        verifiedResult <- runMarkEmailVerified env.pool user.userId
        either (die . ("could not mark email verified: " <>) . show) pure verifiedResult
      putStrLn
        ( "created user "
            <> show user.userId
            <> " <"
            <> Text.unpack (loginIdText user.loginId)
            <> ">"
            <> if verified then " (email verified)" else ""
        )

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
  Manager ->
  Int ->
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
runSignup pool limiter argon2 manager breachTimeoutMs =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runTokenGenCrypto
    . runClockIO
    . runAuthEventPublisherPostgres
    . runClaimsEnricherNull
    . runTokenSignerFake
    . runPasswordHasherCrypto limiter argon2
    . runPasswordBreachCheckerHibp manager breachTimeoutMs
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

runMarkEmailVerified :: Pool -> UserId -> IO (Either AuthError ())
runMarkEmailVerified pool uid =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runClockIO
    . runUserStorePostgres
    $ do
      ts <- now
      markUserEmailVerified uid ts

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
