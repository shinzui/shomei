-- | The audited admin lifecycle workflows (EP-2): status transitions, session revocation, and
-- the actor recorded on every event.
--
-- These run on the in-memory interpreters, which implement the same semantics as the PostgreSQL
-- ones (@shomei-postgres/test/Main.hs@ pins the SQL side of listing and revocation).
module Shomei.Workflow.AdminSpec (tests) where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff)
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (LoginId, mkLoginId)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Session (Session (..), SessionStatus (SessionActive))
import Shomei.Domain.Session qualified as Session
import Shomei.Domain.User (User (..), UserStatus (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Effect.SessionStore (listSessionsForUser)
import Shomei.Effect.UserStore (findUserById)
import Shomei.Error (AuthError (..))
import Shomei.Id (genSessionId, genUserId)
import Shomei.Prelude
import Shomei.Workflow (LoginResult (..), login, signup)
import Shomei.Workflow.Admin (deleteUser, reinstateUser, revokeOneSession, revokeUserSessions, suspendUser)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.Workflow.Admin"
    [ testSuspendFlipsStatusRevokesSessionsAndRecordsActor,
      testStrictTransitions,
      testDeleteIsTerminal,
      testReinstateRestoresLogin,
      testRevokeUserSessionsCountsOnlyActiveOnes,
      testRevokeOneSessionRecordsActor,
      testMissingTargetsAreNotFound
    ]

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

aliceLogin :: LoginId
aliceLogin = either (\e -> error ("bad test login id: " <> show e)) id (mkLoginId "alice@example.com")

ctx :: ClientContext
ctx = ClientContext {clientIp = ClientIp "1.2.3.4", accountKey = AccountKey "k-alice"}

signupCmd :: SignupCommand
signupCmd =
  SignupCommand
    { loginId = aliceLogin,
      email = Just (either (\e -> error ("bad test email: " <> show e)) id (mkEmail "alice@example.com")),
      password = strongPw,
      displayName = Nothing
    }

loginCmd :: LoginCommand
loginCmd = LoginCommand {loginId = aliceLogin, password = strongPw}

orFail :: (Show e) => Either e a -> Eff es a
orFail = either (\e -> error ("workflow failed: " <> show e)) pure

withWorld :: (IORef World -> IO a) -> IO a
withWorld k = newIORef (emptyWorld (UTCTime (fromGregorian 2026 1 1) 0)) >>= k

-- | Suspension does three things at once, and all three are the point: the status flips, the
-- live sessions die, and the audit event names the administrator who did it. A suspension nobody
-- can be held responsible for is not an administrative action.
testSuspendFlipsStatusRevokesSessionsAndRecordsActor :: TestTree
testSuspendFlipsStatusRevokesSessionsAndRecordsActor =
  testCase "suspend: status flips, sessions die, the event names the actor" $ withWorld \ref -> do
    (targetId, suspended, admin, sessions) <- runInMemory ref do
      (user, _) <- orFail =<< signup cfg signupCmd
      admin <- genUserId
      _ <- orFail =<< suspendUser admin user.userId
      after <- findUserById user.userId
      sessions <- listSessionsForUser user.userId
      pure (user.userId, after, admin, sessions)
    fmap (.status) suspended @?= Just UserSuspended
    assertBool "no session is left active" (all ((/= SessionActive) . (.status)) sessions)

    published <- (.publishedEvents) <$> readIORef ref
    case [d | Event.UserSuspended d <- published] of
      [d] -> do
        d.actor @?= Just admin
        d.userId @?= targetId
      other -> assertFailure ("expected exactly one user_suspended event, got " <> show (length other))

-- | Suspending twice is a 'InvalidUserStatus', not a silent success: two administrators handling
-- one incident must be able to tell which of them changed the state.
testStrictTransitions :: TestTree
testStrictTransitions =
  testCase "wrong-state transitions are InvalidUserStatus, never silent" $ withWorld \ref -> do
    (doubleSuspend, reinstateActive) <- runInMemory ref do
      (user, _) <- orFail =<< signup cfg signupCmd
      admin <- genUserId
      _ <- orFail =<< suspendUser admin user.userId
      doubleSuspend <- suspendUser admin user.userId
      _ <- orFail =<< reinstateUser admin user.userId
      reinstateActive <- reinstateUser admin user.userId
      pure (doubleSuspend, reinstateActive)
    doubleSuspend @?= Left InvalidUserStatus
    reinstateActive @?= Left InvalidUserStatus

-- | Soft delete is terminal: a deleted user still exists (the audit trail references them) but
-- accepts no further transition.
testDeleteIsTerminal :: TestTree
testDeleteIsTerminal =
  testCase "delete is a soft, terminal state" $ withWorld \ref -> do
    (after, redelete, reinstate) <- runInMemory ref do
      (user, _) <- orFail =<< signup cfg signupCmd
      admin <- genUserId
      _ <- orFail =<< deleteUser admin user.userId
      after <- findUserById user.userId
      redelete <- deleteUser admin user.userId
      reinstate <- reinstateUser admin user.userId
      pure (after, redelete, reinstate)
    fmap (.status) after @?= Just UserDeleted
    redelete @?= Left InvalidUserStatus
    reinstate @?= Left InvalidUserStatus

-- | Reinstatement returns the account to service. The old sessions stay revoked — the user logs
-- in again, which is the whole point of having killed them.
testReinstateRestoresLogin :: TestTree
testReinstateRestoresLogin =
  testCase "a reinstated user can log in again; the killed sessions stay dead" $ withWorld \ref -> do
    (loginWhileSuspended, loginAfterReinstate, oldSessionStatuses) <- runInMemory ref do
      (user, _) <- orFail =<< signup cfg signupCmd
      admin <- genUserId
      _ <- orFail =<< suspendUser admin user.userId
      blocked <- login cfg ctx loginCmd
      _ <- orFail =<< reinstateUser admin user.userId
      allowed <- login cfg ctx loginCmd
      sessions <- listSessionsForUser user.userId
      -- The signup session, revoked by the suspension, must still be revoked.
      pure (blocked, allowed, [s.status | s <- drop 1 sessions])
    -- The workflow says UserNotActive; the HTTP layer collapses it to the generic invalid_login
    -- so the API never discloses account state to an unauthenticated caller.
    loginWhileSuspended @?= Left UserNotActive
    case loginAfterReinstate of
      Right (LoginComplete _ _) -> pure ()
      Right (MfaRequired _) -> assertFailure "unexpected MFA challenge"
      Left e -> assertFailure ("a reinstated user must log in, got " <> show e)
    assertBool "the pre-suspension session was not resurrected" (all (/= SessionActive) oldSessionStatuses)

-- | The count is the number of sessions this call actually ended, so an operator reading
-- "revoked 0 sessions" learns something true rather than "revoked 3" about three corpses.
testRevokeUserSessionsCountsOnlyActiveOnes :: TestTree
testRevokeUserSessionsCountsOnlyActiveOnes =
  testCase "revokeUserSessions counts only the sessions it ended" $ withWorld \ref -> do
    (firstCount, secondCount, admin) <- runInMemory ref do
      (user, _) <- orFail =<< signup cfg signupCmd
      admin <- genUserId
      _ <- orFail =<< login cfg ctx loginCmd -- a second live session
      first' <- orFail =<< revokeUserSessions admin user.userId
      second' <- orFail =<< revokeUserSessions admin user.userId
      pure (first', second', admin)
    firstCount @?= 2
    secondCount @?= 0

    published <- (.publishedEvents) <$> readIORef ref
    let adminRevocations = [d | Event.SessionRevoked d <- published, d.revokedBy == Just admin]
    length adminRevocations @?= 2

testRevokeOneSessionRecordsActor :: TestTree
testRevokeOneSessionRecordsActor =
  testCase "revokeOneSession revokes exactly one session and names the actor" $ withWorld \ref -> do
    (sessions, admin) <- runInMemory ref do
      (user, _) <- orFail =<< signup cfg signupCmd
      admin <- genUserId
      _ <- orFail =<< login cfg ctx loginCmd
      allSessions <- listSessionsForUser user.userId
      case allSessions of
        (newest : _) -> do
          _ <- orFail =<< revokeOneSession admin newest.sessionId
          pure ()
        [] -> error "expected two sessions"
      after <- listSessionsForUser user.userId
      pure (after, admin)
    map (.status) sessions @?= [Session.SessionRevoked, SessionActive]

    published <- (.publishedEvents) <$> readIORef ref
    [d.revokedBy | Event.SessionRevoked d <- published] @?= [Just admin]

testMissingTargetsAreNotFound :: TestTree
testMissingTargetsAreNotFound =
  testCase "a target that does not exist is UserNotFound / SessionNotFound" $ withWorld \ref -> do
    (suspendMissing, revokeMissing, revokeGhostSession) <- runInMemory ref do
      admin <- genUserId
      ghost <- genUserId
      ghostSession <- genSessionId
      suspendMissing <- suspendUser admin ghost
      -- revokeUserSessions on an unknown user is not an error: they have no sessions to end.
      revokeMissing <- revokeUserSessions admin ghost
      revokeGhostSession <- revokeOneSession admin ghostSession
      pure (suspendMissing, revokeMissing, revokeGhostSession)
    suspendMissing @?= Left UserNotFound
    revokeMissing @?= Right 0
    revokeGhostSession @?= Left SessionNotFound
