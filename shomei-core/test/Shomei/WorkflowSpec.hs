{- | Behavioral tests for the auth workflows, run entirely through the in-memory port
interpreter ('Shomei.Effect.InMemory.runInMemory'). No PostgreSQL, no JWT library, no
network: a green run proves the security-critical workflow logic in isolation.

Each case builds a fresh 'World' in an 'IORef' (so there is no cross-test
contamination) and runs one or more workflows against it, then asserts on the returned
'Either' and, for state-changing cases, on the 'World' read back from the 'IORef'.
-}
module Shomei.WorkflowSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (LoginCommand (..), LogoutCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (Session (..), SessionStatus (..))
import Shomei.Domain.Token (TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Error (AuthError (InvalidCredentials, RefreshTokenReuseDetected))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Workflow (login, logout, refresh, signup)

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
mkEmail' t = case mkEmail t of
    Right e -> e
    Left err -> error ("bad test email: " <> show err)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Shomei.Workflow"
        [ testSignupLogin
        , testRefreshRotates
        , testReuseDetected
        , testReuseRevokesSession
        , testLogoutRevokes
        , testFailClosed
        , testNoAccountLeak
        ]

testSignupLogin :: TestTree
testSignupLogin = testCase "signup then login round-trips" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, pair) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw (Just "Alice")))
    (user2, pair2) <- expectRight =<< runInMemory ref (login cfg (LoginCommand aliceEmail strongPw))
    user2.userId @?= user.userId
    assertBool "login issues a different refresh token" (pair2.refreshToken /= pair.refreshToken)

testRefreshRotates :: TestTree
testRefreshRotates = testCase "refresh rotates token and old token becomes Used" do
    ref <- newIORef (emptyWorld fixedTime)
    (_, pair) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    pair2 <- expectRight =<< runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    assertBool "rotated token differs from the original" (pair2.refreshToken /= pair.refreshToken)
    w <- readIORef ref
    let toks = Map.elems w.refreshTokens
    assertBool "exactly one token is marked Used" (length (filter (\t -> t.status == RefreshTokenUsed) toks) == 1)
    assertBool "the rotated token links to its parent" (any (\t -> isJust t.parentTokenId) toks)

testReuseDetected :: TestTree
testReuseDetected = testCase "presenting an already-used refresh token detects reuse" do
    ref <- newIORef (emptyWorld fixedTime)
    (_, pair) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    reused <- runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    reused @?= Left RefreshTokenReuseDetected

testReuseRevokesSession :: TestTree
testReuseRevokesSession = testCase "reuse detection revokes the session and family" do
    ref <- newIORef (emptyWorld fixedTime)
    (_, pair) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    _ <- runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    w <- readIORef ref
    assertBool "session is revoked" (all (\s -> s.status == SessionRevoked) (Map.elems w.sessions))
    assertBool "whole refresh-token family is revoked" (all (\t -> t.status == RefreshTokenRevoked) (Map.elems w.refreshTokens))
    assertBool "a reuse event was published" (any isReuse w.publishedEvents)
  where
    isReuse (Event.RefreshTokenReuseDetected _) = True
    isReuse _ = False

testLogoutRevokes :: TestTree
testLogoutRevokes = testCase "logout revokes the session" do
    ref <- newIORef (emptyWorld fixedTime)
    _ <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    w0 <- readIORef ref
    sid <- case Map.keys w0.sessions of
        (s : _) -> pure s
        [] -> assertFailure "expected a session to exist after signup"
    result <- runInMemory ref (logout cfg (LogoutCommand sid))
    result @?= Right ()
    w <- readIORef ref
    assertBool "session is revoked" (all (\s -> s.status == SessionRevoked) (Map.elems w.sessions))
    assertBool "session refresh tokens are revoked" (all (\t -> t.status == RefreshTokenRevoked) (Map.elems w.refreshTokens))
    assertBool "a session-revoked event was published" (any isRevoked w.publishedEvents)
  where
    isRevoked (Event.SessionRevoked _) = True
    isRevoked _ = False

testFailClosed :: TestTree
testFailClosed = testCase "password verification fails closed on wrong password" do
    ref <- newIORef (emptyWorld fixedTime)
    _ <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    result <- runInMemory ref (login cfg (LoginCommand aliceEmail wrongPw))
    result @?= Left InvalidCredentials
    w <- readIORef ref
    assertBool "a login-failed event was published" (any isFailed w.publishedEvents)
  where
    isFailed (Event.LoginFailed _) = True
    isFailed _ = False

testNoAccountLeak :: TestTree
testNoAccountLeak = testCase "unknown email yields the same generic error as a wrong password" do
    ref <- newIORef (emptyWorld fixedTime)
    _ <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    wrong <- runInMemory ref (login cfg (LoginCommand aliceEmail wrongPw))
    unknown <- runInMemory ref (login cfg (LoginCommand unknownEmail strongPw))
    wrong @?= unknown
    unknown @?= Left InvalidCredentials
