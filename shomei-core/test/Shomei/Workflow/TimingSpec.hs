{-# LANGUAGE DataKinds #-}

-- | The login timing oracle: a failed login must perform the same password-hashing work no
-- matter /why/ it failed, or an attacker can enumerate accounts by measuring response time.
--
-- The security property under test is "every login attempt invokes the password hasher
-- exactly once". That is asserted with an invocation counter rather than a stopwatch:
-- Argon2id at the production parameters costs ~100 ms, so a wall-clock assertion would be
-- both slow and flaky, while the counter is exact.
--
-- Equal invocation counts imply equal cost because the two hashing operations a login can
-- reach — 'VerifyPassword' on a stored hash, and 'VerifyPasswordDummy' on the paths that have
-- no stored hash to check — are derived by the real interpreter
-- ('Shomei.Crypto.runPasswordHasherCrypto') with the /same/ Argon2 parameters. That is why
-- the dummy is a port operation rather than a constant hash: a constant would keep whatever
-- parameters it was baked with, and an operator retuning the cost would silently make misses
-- and hits take measurably different times again.
module Shomei.Workflow.TimingSpec (tests) where

import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail, loginIdText)
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
import Shomei.Domain.User (User (..), UserStatus (UserSuspended))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.InMemory
  ( World (..),
    emptyWorld,
    runAuthEventPublisher,
    runAuthUnitOfWork,
    runClock,
    runCredentialStore,
    runLoginAttemptStore,
    runNotifier,
    runClaimsEnricherNull,
    runPasskeyStore,
    runPasswordBreachCheckerFake,
    runPasswordResetTokenStore,
    runPendingCeremonyStore,
    runRecoveryCodeStore,
    runRefreshTokenStore,
    runSessionStore,
    runSigningKeyStore,
    runTokenGen,
    runTokenSigner,
    runTokenVerifier,
    runTotpCredentialStore,
    runRoleStore,
    runUserStore,
    runVerificationTokenStore,
    runWebAuthnCeremonyFake,
  )
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore)
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher)
import Shomei.Effect.Notifier (Notifier)
import Shomei.Effect.PasskeyStore (PasskeyStore)
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher (..))
import Shomei.Effect.PasswordResetTokenStore (PasswordResetTokenStore)
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore)
import Shomei.Effect.RecoveryCodeStore (RecoveryCodeStore)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.RoleStore (RoleStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.SigningKeyStore (SigningKeyStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TokenVerifier (TokenVerifier)
import Shomei.Effect.TotpCredentialStore (TotpCredentialStore)
import Shomei.Effect.UserStore (UserStore, updateUserStatus)
import Shomei.Effect.VerificationTokenStore (VerificationTokenStore)
import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)
import Shomei.Error (AuthError (InvalidCredentials, UserNotActive))
import Shomei.Workflow (login, signup)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.Workflow login timing"
    [ testCase "unknown login id still verifies a password (dummy hash)" do
        (result, hashCalls) <- withWorld \ref counter -> do
          runCounting ref counter (login cfg (ctxFor unknownEmail) (loginEmail unknownEmail strongPw))
        expectLeft InvalidCredentials result
        hashCalls @?= 1,
      testCase "wrong password verifies exactly once" do
        (result, hashCalls) <- afterSignup (\_ -> pure ()) (loginEmail aliceEmail wrongPw)
        expectLeft InvalidCredentials result
        hashCalls @?= 1,
      testCase "suspended account still verifies a password" do
        (result, hashCalls) <- afterSignup suspendEveryone (loginEmail aliceEmail strongPw)
        expectLeft UserNotActive result
        hashCalls @?= 1,
      testCase "successful login verifies exactly once" do
        (result, hashCalls) <- afterSignup (\_ -> pure ()) (loginEmail aliceEmail strongPw)
        case result of
          Right _ -> pure ()
          Left e -> assertFailure ("expected a successful login, got " <> show e)
        hashCalls @?= 1
    ]

-- Harness --------------------------------------------------------------------

-- | The 'runInMemory' effect list, which 'runCounting' must reproduce exactly.
type Ports =
  '[ UserStore,
     RoleStore,
     CredentialStore,
     SessionStore,
     RefreshTokenStore,
     AuthUnitOfWork,
     VerificationTokenStore,
     PasswordResetTokenStore,
     LoginAttemptStore,
     PasskeyStore,
     PendingCeremonyStore,
     TotpCredentialStore,
     RecoveryCodeStore,
     Notifier,
     ClaimsEnricher,
     WebAuthnCeremony,
     PasswordBreachChecker,
     PasswordHasher,
     TokenSigner,
     TokenVerifier,
     AuthEventPublisher,
     SigningKeyStore,
     Clock,
     TokenGen,
     IOE
   ]

-- | The in-memory fake hasher, counting every password-hashing operation — both
-- 'VerifyPassword' and 'VerifyPasswordDummy', because the two cost the same and the property
-- under test is that each login performs exactly one of them. Only the /invocation/ is
-- observed, never the result.
runCountingPasswordHasher :: (IOE :> es) => IORef Int -> Eff (PasswordHasher : es) a -> Eff es a
runCountingPasswordHasher counter = interpret_ \case
  HashPassword (PlainPassword pw) -> pure (PasswordHash ("argon2-fake:" <> pw))
  VerifyPassword (PlainPassword pw) (PasswordHash h) -> do
    liftIO (atomicModifyIORef' counter \n -> (n + 1, ()))
    pure (h == "argon2-fake:" <> pw)
  VerifyPasswordDummy _ -> liftIO (atomicModifyIORef' counter \n -> (n + 1, ()))

-- | 'Shomei.Effect.InMemory.runInMemory' with the counting hasher in the 'PasswordHasher'
-- slot. The interpreter order mirrors 'runInMemory'.
runCounting :: IORef World -> IORef Int -> Eff Ports a -> IO a
runCounting ref counter =
  runEff
    . runTokenGen ref
    . runClock ref
    . runSigningKeyStore ref
    . runAuthEventPublisher ref
    . runTokenVerifier
    . runTokenSigner
    . runCountingPasswordHasher counter
    . runPasswordBreachCheckerFake ref
    . runWebAuthnCeremonyFake ref
    . runClaimsEnricherNull
    . runNotifier ref
    . runRecoveryCodeStore ref
    . runTotpCredentialStore ref
    . runPendingCeremonyStore ref
    . runPasskeyStore ref
    . runLoginAttemptStore ref
    . runPasswordResetTokenStore ref
    . runVerificationTokenStore ref
    . runAuthUnitOfWork ref
    . runRefreshTokenStore ref
    . runSessionStore ref
    . runCredentialStore ref
    . runRoleStore ref
    . runUserStore ref

withWorld :: (IORef World -> IORef Int -> IO (Either AuthError a)) -> IO (Either AuthError (), Int)
withWorld act = do
  ref <- newIORef (emptyWorld fixedTime)
  counter <- newIORef 0
  result <- act ref counter
  calls <- readIORef counter
  pure (void result, calls)

-- | Sign Alice up, run @setup@ against the resulting world, reset the counter, then log in.
-- Resetting after signup is what makes the count "verifications performed by the login".
afterSignup :: (IORef World -> IO ()) -> LoginCommand -> IO (Either AuthError (), Int)
afterSignup setup cmd = do
  ref <- newIORef (emptyWorld fixedTime)
  counter <- newIORef 0
  signupResult <- runCounting ref counter (signup cfg (signupEmail aliceEmail strongPw))
  case signupResult of
    Left e -> do
      _ <- assertFailure ("signup failed: " <> show e)
      pure (Left e, 0)
    Right _ -> do
      setup ref
      writeIORef counter 0
      result <- runCounting ref counter (login cfg (ctxForLogin cmd.loginId) cmd)
      calls <- readIORef counter
      pure (void result, calls)

-- | Suspend every user in the world (the tests seed exactly one).
suspendEveryone :: IORef World -> IO ()
suspendEveryone ref = do
  w <- readIORef ref
  counter <- newIORef 0
  runCounting ref counter (mapM_ (\u -> updateUserStatus u.userId UserSuspended) (Map.elems w.users))

expectLeft :: AuthError -> Either AuthError a -> IO ()
expectLeft expected = \case
  Left e | e == expected -> pure ()
  Left e -> assertFailure ("expected " <> show expected <> ", got " <> show e)
  Right _ -> assertFailure ("expected " <> show expected <> ", got a successful login")

-- Fixtures -------------------------------------------------------------------

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

unknownEmail :: Email
unknownEmail = mkEmail' "nobody@example.com"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

wrongPw :: PlainPassword
wrongPw = PlainPassword "totally the wrong password"

mkEmail' :: Text -> Email
mkEmail' t = either (\e -> error ("bad test email: " <> show e)) id (mkEmail t)

signupEmail :: Email -> PlainPassword -> SignupCommand
signupEmail e pw =
  SignupCommand {loginId = loginIdFromEmail e, email = Just e, password = pw, displayName = Nothing}

loginEmail :: Email -> PlainPassword -> LoginCommand
loginEmail e pw = LoginCommand {loginId = loginIdFromEmail e, password = pw}

ctxForLogin :: LoginId -> ClientContext
ctxForLogin l = ClientContext (ClientIp "test-ip") (AccountKey (loginIdText l))

ctxFor :: Email -> ClientContext
ctxFor = ctxForLogin . loginIdFromEmail
