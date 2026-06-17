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

import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), LogoutCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail, loginIdText, mkLoginId)
import Shomei.Domain.Password (PasswordPolicy (..), PlainPassword (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (Session (..), SessionStatus (..))
import Shomei.Domain.Token (TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Error (
    AuthError (InvalidCredentials, RefreshTokenReuseDetected, WeakPassword),
    PasswordPolicyViolation (PasswordResemblesIdentity, PasswordTooCommon),
 )
import Shomei.Workflow (LoginResult (..), login, logout, refresh, signup)

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

mkLoginId' :: Text -> LoginId
mkLoginId' t = case mkLoginId t of
    Right l -> l
    Left err -> error ("bad test login id: " <> show err)

-- | An email-first signup command: the principal login id defaults to the email text
-- (the compatibility rule), and the optional email is carried through.
signupEmail :: Email -> PlainPassword -> Maybe Text -> SignupCommand
signupEmail e pw dn =
    SignupCommand{loginId = loginIdFromEmail e, email = Just e, password = pw, displayName = dn}

-- | An email-first login command keyed on the email-derived login id.
loginEmail :: Email -> PlainPassword -> LoginCommand
loginEmail e pw = LoginCommand{loginId = loginIdFromEmail e, password = pw}

-- | A fixed client context per login id: a constant test IP and the login-id text as the
-- account key (mirroring how the HTTP layer derives the abuse key from the principal).
ctxForLogin :: LoginId -> ClientContext
ctxForLogin l = ClientContext (ClientIp "test-ip") (AccountKey (loginIdText l))

-- | The email-keyed convenience: derive the login id from the email, then the context.
ctxFor :: Email -> ClientContext
ctxFor = ctxForLogin . loginIdFromEmail

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Shomei.Workflow"
        [ testSignupLogin
        , testSignupLoginByIdentifierNoEmail
        , testRefreshRotates
        , testReuseDetected
        , testReuseRevokesSession
        , testLogoutRevokes
        , testFailClosed
        , testNoAccountLeak
        , testSignupRejectsCommon
        , testSignupRejectsIdentity
        ]

-- | A policy with a small minimum length so identity-derived passwords (e.g. "alice",
-- shorter than the default 12) reach the contextual check instead of failing on length.
smallMinCfg :: ShomeiConfig
smallMinCfg = cfg{passwordPolicy = cfg.passwordPolicy{minLength = 4}}

testSignupRejectsCommon :: TestTree
testSignupRejectsCommon = testCase "signup rejects a common password" do
    ref <- newIORef (emptyWorld fixedTime)
    -- "passwordpassword" is in the bundled dictionary and is long enough to pass minLength.
    res <- runInMemory ref (signup cfg (signupEmail aliceEmail (PlainPassword "passwordpassword") Nothing))
    res @?= Left (WeakPassword PasswordTooCommon)

testSignupRejectsIdentity :: TestTree
testSignupRejectsIdentity = testCase "signup rejects the email local-part as password" do
    ref <- newIORef (emptyWorld fixedTime)
    res <- runInMemory ref (signup smallMinCfg (signupEmail aliceEmail (PlainPassword "alice") Nothing))
    res @?= Left (WeakPassword PasswordResemblesIdentity)

testSignupLogin :: TestTree
testSignupLogin = testCase "signup then login round-trips" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, pair) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw (Just "Alice")))
    loginRes <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (loginEmail aliceEmail strongPw))
    (user2, pair2) <- case loginRes of
        LoginComplete u p -> pure (u, p)
        MfaRequired _ -> assertFailure "expected LoginComplete (alice has no passkey), got MfaRequired"
    user2.userId @?= user.userId
    assertBool "login issues a different refresh token" (pair2.refreshToken /= pair.refreshToken)

testSignupLoginByIdentifierNoEmail :: TestTree
testSignupLoginByIdentifierNoEmail = testCase "signup+login by identifier with no email" do
    ref <- newIORef (emptyWorld fixedTime)
    let agentLogin = mkLoginId' "agent-4815162342"
        signupCmd =
            SignupCommand{loginId = agentLogin, email = Nothing, password = strongPw, displayName = Nothing}
    (user, _pair) <- expectRight =<< runInMemory ref (signup cfg signupCmd)
    user.email @?= Nothing
    user.loginId @?= agentLogin
    loginRes <-
        expectRight =<< runInMemory ref (login cfg (ctxForLogin agentLogin) (LoginCommand agentLogin strongPw))
    case loginRes of
        LoginComplete u _ -> u.userId @?= user.userId
        MfaRequired _ -> assertFailure "expected LoginComplete (agent has no passkey), got MfaRequired"

testRefreshRotates :: TestTree
testRefreshRotates = testCase "refresh rotates token and old token becomes Used" do
    ref <- newIORef (emptyWorld fixedTime)
    (_, pair) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    pair2 <- expectRight =<< runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    assertBool "rotated token differs from the original" (pair2.refreshToken /= pair.refreshToken)
    w <- readIORef ref
    let toks = Map.elems w.refreshTokens
    assertBool "exactly one token is marked Used" (length (filter (\t -> t.status == RefreshTokenUsed) toks) == 1)
    assertBool "the rotated token links to its parent" (any (\t -> isJust t.parentTokenId) toks)

testReuseDetected :: TestTree
testReuseDetected = testCase "presenting an already-used refresh token detects reuse" do
    ref <- newIORef (emptyWorld fixedTime)
    (_, pair) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    reused <- runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
    reused @?= Left RefreshTokenReuseDetected

testReuseRevokesSession :: TestTree
testReuseRevokesSession = testCase "reuse detection revokes the session and family" do
    ref <- newIORef (emptyWorld fixedTime)
    (_, pair) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
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
    _ <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
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
    _ <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    result <- runInMemory ref (login cfg (ctxFor aliceEmail) (loginEmail aliceEmail wrongPw))
    result @?= Left InvalidCredentials
    w <- readIORef ref
    assertBool "a login-failed event was published" (any isFailed w.publishedEvents)
  where
    isFailed (Event.LoginFailed _) = True
    isFailed _ = False

testNoAccountLeak :: TestTree
testNoAccountLeak = testCase "unknown email yields the same generic error as a wrong password" do
    ref <- newIORef (emptyWorld fixedTime)
    _ <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    wrong <- runInMemory ref (login cfg (ctxFor aliceEmail) (loginEmail aliceEmail wrongPw))
    unknown <- runInMemory ref (login cfg (ctxFor unknownEmail) (loginEmail unknownEmail strongPw))
    wrong @?= unknown
    unknown @?= Left InvalidCredentials
