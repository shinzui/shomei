-- | Concurrency regression tests for the compare-and-swap token-state transitions.
--
-- Every one of these cases would pass trivially if the workflows were run sequentially; what
-- they prove is that /simultaneous/ presentations of the same single-use secret cannot both
-- succeed. They run many green threads against one shared 'IORef' 'World' — the in-memory
-- interpreters mutate it with 'Data.IORef.atomicModifyIORef'', which gives the same
-- "inspect and transition in one indivisible step" guarantee that PostgreSQL's row lock gives
-- the @UPDATE … WHERE status = 'active' RETURNING@ statements.
--
-- Reverting either CAS (in "Shomei.Test.InMemory") to a plain @modifyIORef'@ plus an
-- unconditional adjust makes these tests fail with two or more winners.
module Shomei.Session.Authentication.ConcurrencySpec (tests) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Either (partitionEithers)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Shomei.Account.Email.Domain (Email, emailText, mkEmail)
-- Qualified: several 'AuthError' constructors share names with 'SessionStatus' constructors.

import Shomei.Account.Lifecycle.Workflow
  ( ConfirmPasswordReset (..),
    RequestPasswordReset (..),
    confirmPasswordReset,
    requestPasswordReset,
  )
import Shomei.Account.LoginId.Domain (loginIdText, mkLoginId)
import Shomei.Account.Notification.Domain (Notification (..))
import Shomei.Account.OneTimeToken.Domain (OneTimeToken)
import Shomei.Account.Password.Domain (PasswordHash (..), PlainPassword (..))
import Shomei.Account.Password.Hash.Store (PasswordHasher (..))
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Error qualified as Err
import Shomei.Session.Authentication.Workflow (login, refresh, signup)
import Shomei.Session.Command (ClientContext (..), LoginCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Session.Domain (Session (..), SessionStatus (..))
import Shomei.Session.LoginAttempt.Domain (AccountKey (..), AccountLockout (..), ClientIp (..))
import Shomei.Session.RefreshToken.Domain (PersistedRefreshToken (..), RefreshToken)
import Shomei.Session.Token.Domain (TokenPair (..))
import Shomei.Test.InMemory (World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | How many threads race for one token, and how many times the whole scenario is repeated
-- to shake different schedulings out of the runtime.
racers, rounds :: Int
racers = 100
rounds = 10

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

strongPw, newPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"
newPw = PlainPassword "correct horse battery staple two"

mkEmail' :: Text -> Email
mkEmail' t = case mkEmail t of
  Right e -> e
  Left err -> error ("bad test email: " <> show err)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

tests :: TestTree
tests =
  testGroup
    "Shomei.Session.Authentication.Workflow.Concurrency"
    [ testConcurrentRefreshHasOneWinner,
      testConcurrentPasswordResetHasOneWinner,
      testConcurrentWrongPasswordsRespectTheBudget
    ]

signupCmd :: Email -> SignupCommand
signupCmd e =
  SignupCommand {loginId = either (error . show) id (mkLoginId (emailText e)), email = Just e, password = strongPw, displayName = Nothing}

-- | Sign up, then hand back the refresh token every racer will present.
signupThenRace :: IORef World -> IO RefreshToken
signupThenRace ref = do
  (_, pair) <- expectRight =<< runInMemory ref (signup cfg (signupCmd aliceEmail))
  pure pair.refreshToken

-- | Sign up and request a password reset, then hand back the raw one-time token from the
-- notification the in-memory 'Shomei.Account.Notification.Store' captured.
resetRequestedWorld :: IORef World -> IO OneTimeToken
resetRequestedWorld ref = do
  _ <- expectRight =<< runInMemory ref (signup cfg (signupCmd aliceEmail))
  _ <- expectRight =<< runInMemory ref (requestPasswordReset cfg (RequestPasswordReset aliceEmail))
  w <- readIORef ref
  case w.sentNotifications of
    PasswordResetRequested {token = raw} : _ -> pure raw
    _ -> assertFailure "expected a password-reset notification carrying a token"

testConcurrentRefreshHasOneWinner :: TestTree
testConcurrentRefreshHasOneWinner =
  testCase (show racers <> " concurrent refreshes: exactly one winner") do
    mapM_ (const oneRound) [1 .. rounds]
  where
    oneRound = do
      ref <- newIORef (emptyWorld fixedTime)
      tok <- signupThenRace ref
      results <- mapConcurrently (const (runInMemory ref (refresh cfg (RefreshCommand tok)))) [1 .. racers]
      let (failures, winners) = partitionEithers results
      length winners @?= 1
      -- A loser either lost the compare-and-swap, or arrived after another loser had already
      -- revoked the family (reuse), or after the session itself was revoked. All three are
      -- 401s; none is a rotation.
      assertBool
        ("unexpected failure among losers: " <> show failures)
        (all (`elem` [Err.RefreshTokenReuseDetected, Err.SessionRevoked]) failures)
      w <- readIORef ref
      -- The presented token forked no second branch: at most one child was ever created.
      let children = filter (isJust . (.parentTokenId)) (Map.elems w.refreshTokens)
      assertBool ("token family forked into " <> show (length children) <> " children") (length children <= 1)
      -- Losers exist (99 of them), so the theft response fired: the session is revoked.
      assertBool
        "session was not revoked by the reuse response"
        (all (\s -> s.status == SessionRevoked) (Map.elems w.sessions))

testConcurrentPasswordResetHasOneWinner :: TestTree
testConcurrentPasswordResetHasOneWinner =
  testCase (show racers <> " concurrent password-reset confirms: exactly one winner") do
    mapM_ (const oneRound) [1 .. rounds]
  where
    oneRound = do
      ref <- newIORef (emptyWorld fixedTime)
      raw <- resetRequestedWorld ref
      results <-
        mapConcurrently
          (const (runInMemory ref (confirmPasswordReset cfg (ConfirmPasswordReset raw newPw))))
          [1 .. racers]
      let (failures, winners) = partitionEithers results
      length winners @?= 1
      assertBool
        ("unexpected failure among losers: " <> show failures)
        (all (== Err.PasswordResetTokenInvalid) failures)
      -- The sharper assertion: the password was changed exactly once, not 100 times.
      w <- readIORef ref
      length (filter isCompleted w.publishedEvents) @?= 1
    isCompleted (Event.PasswordResetCompleted _) = True
    isCompleted _ = False

-- | Count stored-hash and dummy-hash verification separately while preserving the deterministic
-- fake hash format used by 'runInMemory'. The distinction proves that the account budget bounds
-- real guesses even though every request still pays one Argon2-equivalent operation.
countingPasswordHasher ::
  (PasswordHasher :> es, IOE :> es) =>
  IORef Int ->
  IORef Int ->
  Eff es a ->
  Eff es a
countingPasswordHasher realCalls dummyCalls = interpose \_env -> \case
  HashPassword (PlainPassword pw) -> pure (PasswordHash ("argon2-fake:" <> pw))
  VerifyPassword (PlainPassword pw) (PasswordHash h) -> do
    liftIO (atomicModifyIORef' realCalls \n -> (n + 1, ()))
    pure (h == "argon2-fake:" <> pw)
  VerifyPasswordDummy _ ->
    liftIO (atomicModifyIORef' dummyCalls \n -> (n + 1, ()))

testConcurrentWrongPasswordsRespectTheBudget :: TestTree
testConcurrentWrongPasswordsRespectTheBudget =
  testCase (show racers <> " concurrent wrong passwords: at most 3 real verifications, one lock") do
    ref <- newIORef (emptyWorld fixedTime)
    realCalls <- newIORef 0
    dummyCalls <- newIORef 0
    let raceCfg =
          cfg
            { rateLimitConfig =
                cfg.rateLimitConfig
                  { maxFailedLoginsPerAccount = 3,
                    maxFailedLoginsPerIp = racers + 1
                  }
            }
        lid = either (error . show) id (mkLoginId (emailText aliceEmail))
        ctx = ClientContext (ClientIp "10.0.0.9") (AccountKey (loginIdText lid))
        wrongLogin = login raceCfg ctx (LoginCommand lid (PlainPassword "wrong password"))
    _ <-
      expectRight
        =<< runInMemory
          ref
          (countingPasswordHasher realCalls dummyCalls (signup raceCfg (signupCmd aliceEmail)))
    writeIORef realCalls 0
    writeIORef dummyCalls 0

    results <-
      mapConcurrently
        (const (runInMemory ref (countingPasswordHasher realCalls dummyCalls wrongLogin)))
        [1 .. racers]
    assertBool ("unexpected result among wrong-password racers: " <> show results) (all (== Left Err.InvalidCredentials) results)
    real <- readIORef realCalls
    dummy <- readIORef dummyCalls
    assertBool ("real verifications exceeded the budget: " <> show real) (real <= 3)
    real + dummy @?= racers
    w <- readIORef ref
    length (filter isAccountLocked w.publishedEvents) @?= 1
    assertBool "account was not locked" (isJust (Map.lookup ctx.accountKey w.accountLockouts >>= (.lockedUntil)))
  where
    isAccountLocked (Event.AccountLocked _) = True
    isAccountLocked _ = False
