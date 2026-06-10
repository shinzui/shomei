{- | @shomei-admin users create@ (EP-4, M3): seed a user account without the HTTP API by
driving the existing 'Shomei.Workflow.signup' through the full PostgreSQL interpreter stack
(with a trivial 'TokenSigner' fake — the CLI does not need a real access token).
-}
module Shomei.Admin.Users (
    createUserAction,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import "hasql-pool" Hasql.Pool (Pool)

import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (emailText, mkEmail)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..))
import Shomei.Error (AuthError)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.UserStore (UserStore)
import Shomei.Workflow (signup)

import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)

createUserAction :: AdminEnv -> Text -> Text -> Maybe Text -> IO ()
createUserAction env emailArg pwArg mDisplay = do
    email <- either (\e -> die ("invalid email: " <> show e)) pure (mkEmail emailArg)
    let cmd = SignupCommand{email = email, password = PlainPassword pwArg, displayName = mDisplay}
    outcome <- runSignup env.pool (signup env.config cmd)
    case outcome of
        Left infra -> die ("infrastructure error: " <> show infra)
        Right (Left rejected) -> die ("signup rejected: " <> show rejected)
        Right (Right (user, _)) ->
            putStrLn ("created user " <> show user.userId <> " <" <> Text.unpack (emailText user.email) <> ">")

-- | Run a 'signup' over the PostgreSQL interpreters, with a fake signer.
runSignup ::
    Pool ->
    Eff
        [ UserStore
        , CredentialStore
        , SessionStore
        , RefreshTokenStore
        , PasswordHasher
        , TokenSigner
        , AuthEventPublisher
        , Clock
        , TokenGen
        , Database
        , Error AuthError
        , IOE
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
        . runRefreshTokenStorePostgres
        . runSessionStorePostgres
        . runCredentialStorePostgres
        . runUserStorePostgres

runTokenSignerFake :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFake = interpret_ \case
    SignAccessToken _ -> pure (AccessToken "admin-cli-token")

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
