-- | Concurrency regression tests for the compare-and-swap token-state transitions.
--
-- Every one of these cases would pass trivially if the workflows were run sequentially; what
-- they prove is that /simultaneous/ presentations of the same single-use secret cannot both
-- succeed. They run many green threads against one shared 'IORef' 'World' — the in-memory
-- interpreters mutate it with 'Data.IORef.atomicModifyIORef'', which gives the same
-- "inspect and transition in one indivisible step" guarantee that PostgreSQL's row lock gives
-- the @UPDATE … WHERE status = 'active' RETURNING@ statements.
--
-- Reverting either CAS (in "Shomei.Effect.InMemory") to a plain @modifyIORef'@ plus an
-- unconditional adjust makes these tests fail with two or more winners.
module Shomei.Workflow.ConcurrencySpec (tests) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Either (partitionEithers)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..), RefreshToken)
import Shomei.Domain.Session (Session (..), SessionStatus (..))
import Shomei.Domain.Token (TokenPair (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
-- Qualified: several 'AuthError' constructors share names with 'SessionStatus' constructors.
import Shomei.Error qualified as Err
import Shomei.Workflow (refresh, signup)
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

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' t = case mkEmail t of
  Right e -> e
  Left err -> error ("bad test email: " <> show err)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

tests :: TestTree
tests =
  testGroup
    "Shomei.Workflow.Concurrency"
    [ testConcurrentRefreshHasOneWinner
    ]

-- | Sign up, then present the resulting refresh token from 'racers' threads at once.
signupThenRace :: IORef World -> IO RefreshToken
signupThenRace ref = do
  (_, pair) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail))
  pure pair.refreshToken
  where
    signupEmail e =
      SignupCommand {loginId = loginIdFromEmail e, email = Just e, password = strongPw, displayName = Nothing}

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
