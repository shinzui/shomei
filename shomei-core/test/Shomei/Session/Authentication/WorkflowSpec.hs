-- | Behavioral tests for the auth workflows, run entirely through the in-memory port
-- interpreter ('Shomei.Test.InMemory.runInMemory'). No PostgreSQL, no JWT library, no
-- network: a green run proves the security-critical workflow logic in isolation.
--
-- Each case builds a fresh 'World' in an 'IORef' (so there is no cross-test
-- contamination) and runs one or more workflows against it, then asserts on the returned
-- 'Either' and, for state-changing cases, on the 'World' read back from the 'IORef'.
module Shomei.Session.Authentication.WorkflowSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Account.Email.Domain (Email, emailText, mkEmail)
import Shomei.Account.LoginId.Domain (LoginId, loginIdText, mkLoginId)
import Shomei.Account.Password.Domain (PasswordPolicy (..), PlainPassword (..))
import Shomei.Account.User.Domain (User (..))
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Authorization.Claims.Domain (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Config (SessionCheckMode (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Error
  ( AuthError (InvalidCredentials, RefreshTokenReuseDetected, WeakPassword),
    PasswordPolicyViolation (PasswordResemblesIdentity, PasswordTooCommon),
  )
-- Qualified: 'Shomei.Error.SessionExpired' (an 'AuthError') and
-- 'Shomei.Session.Domain.SessionExpired' (a 'SessionStatus') share a name.
import Shomei.Error qualified as Err
import Shomei.Session.Authentication.Workflow (LoginResult (..), Refreshed (..), login, logout, refresh, refreshFrom, signup, verifyToken)
import Shomei.Session.Command (ClientContext (..), LoginCommand (..), LogoutCommand (..), RefreshCommand (..), RefreshOrigin (..), SignupCommand (..))
import Shomei.Session.Domain (Session (..), SessionStatus (..))
import Shomei.Session.LoginAttempt.Domain (AccountKey (..), ClientIp (..))
import Shomei.Session.RefreshToken.Domain (PersistedRefreshToken (..), RefreshTokenStatus (..))
import Shomei.Session.RefreshToken.Store (markRefreshTokenUsed)
import Shomei.Session.Token.Domain (TokenPair (..))
import Shomei.Session.Workflow (SessionOptions (..), issueSessionWith)
import Shomei.Test.InMemory (World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
  SignupCommand {loginId = either (error . show) id (mkLoginId (emailText e)), email = Just e, password = pw, displayName = dn}

-- | An email-first login command keyed on the email-derived login id.
loginEmail :: Email -> PlainPassword -> LoginCommand
loginEmail e pw = LoginCommand {loginId = either (error . show) id (mkLoginId (emailText e)), password = pw}

-- | A fixed client context per login id: a constant test IP and the login-id text as the
-- account key (mirroring how the HTTP layer derives the abuse key from the principal).
ctxForLogin :: LoginId -> ClientContext
ctxForLogin l = ClientContext (ClientIp "test-ip") (AccountKey (loginIdText l))

-- | The email-keyed convenience: derive the login id from the email, then the context.
ctxFor :: Email -> ClientContext
ctxFor email = ctxForLogin (either (error . show) id (mkLoginId (emailText email)))

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- | Move the in-memory clock to @fixedTime + delta@. The interpreters read 'World.clock' on
-- every 'Shomei.Time.Store.now', so this is how a test travels forward in time.
advanceTo :: IORef World -> NominalDiffTime -> IO ()
advanceTo ref delta = modifyIORef' ref \w -> w {clock = addUTCTime delta fixedTime}

-- | A config whose refresh tokens outlive the session, so a token minted at signup is still
-- unexpired when the session's absolute deadline passes. Without it the two deadlines
-- coincide and 'SessionExpired' would be masked by 'RefreshTokenExpired'.
longTokenCfg :: ShomeiConfig
longTokenCfg = cfg {refreshTokenTTL = 61 * 24 * 60 * 60}

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Shomei.Session.Authentication.Workflow"
    [ testSignupLogin,
      testSignupLoginByIdentifierNoEmail,
      testRefreshRotates,
      testBespokeRefreshRejectsOAuthSession,
      testRefreshRejectsExpiredSession,
      testSlidingRefreshStillDiesAtDeadline,
      testVerifyTokenRejectsExpiredSession,
      testMarkUsedIsCompareAndSwap,
      testReuseDetected,
      testReuseRevokesSession,
      testLogoutRevokes,
      testFailClosed,
      testNoAccountLeak,
      testSignupRejectsCommon,
      testSignupRejectsIdentity
    ]

-- | A policy with a small minimum length so identity-derived passwords (e.g. "alice",
-- shorter than the default 12) reach the contextual check instead of failing on length.
smallMinCfg :: ShomeiConfig
smallMinCfg = cfg {passwordPolicy = cfg.passwordPolicy {minLength = 4}}

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
        SignupCommand {loginId = agentLogin, email = Nothing, password = strongPw, displayName = Nothing}
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
  originalClaims <- expectRight =<< runInMemory ref (verifyToken cfg pair.accessToken)
  advanceTo ref 60
  pair2 <- expectRight =<< runInMemory ref (refresh cfg (RefreshCommand pair.refreshToken))
  refreshedClaims <- expectRight =<< runInMemory ref (verifyToken cfg pair2.accessToken)
  assertBool "rotated token differs from the original" (pair2.refreshToken /= pair.refreshToken)
  refreshedClaims.authTime @?= originalClaims.authTime
  refreshedClaims.issuedAt @?= addUTCTime 60 originalClaims.issuedAt
  w <- readIORef ref
  let toks = Map.elems w.refreshTokens
  assertBool "exactly one token is marked Used" (length (filter (\t -> t.status == RefreshTokenUsed) toks) == 1)
  assertBool "the rotated token links to its parent" (any (\t -> isJust t.parentTokenId) toks)

testBespokeRefreshRejectsOAuthSession :: TestTree
testBespokeRefreshRejectsOAuthSession = testCase "bespoke refresh refuses a client-bound session without spending its token" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
  let granted = Set.fromList [Scope "openid", Scope "kawa:read"]
  (_, oauthPair, _) <-
    runInMemory
      ref
      ( issueSessionWith
          cfg
          SessionOptions
            { oauthClientId = Just "oauthclient_test",
              extraScopes = granted
            }
          user
          fixedTime
      )
  result <- runInMemory ref (refresh cfg (RefreshCommand oauthPair.refreshToken))
  result @?= Left Err.RefreshTokenInvalid
  wrongClient <- runInMemory ref (refreshFrom (OAuthClientRefresh "oauthclient_other") cfg (RefreshCommand oauthPair.refreshToken))
  case wrongClient of
    Left err -> err @?= Err.RefreshTokenInvalid
    Right _ -> assertFailure "a different OAuth client rotated the session"
  world <- readIORef ref
  assertBool
    "the refused binding mismatch leaves every token active"
    (all ((== RefreshTokenActive) . (.status)) (Map.elems world.refreshTokens))
  refreshed <-
    expectRight
      =<< runInMemory ref (refreshFrom (OAuthClientRefresh "oauthclient_test") cfg (RefreshCommand oauthPair.refreshToken))
  refreshed.grantedScopes @?= granted
  claims <- expectRight =<< runInMemory ref (verifyToken cfg refreshed.tokens.accessToken)
  claims.scopes @?= granted

testRefreshRejectsExpiredSession :: TestTree
testRefreshRejectsExpiredSession = testCase "refresh rejects a session past its absolute expiry" do
  ref <- newIORef (emptyWorld fixedTime)
  (_, pair) <- expectRight =<< runInMemory ref (signup longTokenCfg (signupEmail aliceEmail strongPw Nothing))
  advanceTo ref (longTokenCfg.sessionTTL + 1)
  res <- runInMemory ref (refresh longTokenCfg (RefreshCommand pair.refreshToken))
  res @?= Left Err.SessionExpired

testSlidingRefreshStillDiesAtDeadline :: TestTree
testSlidingRefreshStillDiesAtDeadline = testCase "sliding refresh still dies at the session deadline" do
  ref <- newIORef (emptyWorld fixedTime)
  (_, pair) <- expectRight =<< runInMemory ref (signup longTokenCfg (signupEmail aliceEmail strongPw Nothing))
  -- Two successful rotations well inside the 30-day session lifetime.
  pair1 <- rotateAt ref (10 * day) pair.refreshToken
  pair2 <- rotateAt ref (20 * day) pair1.refreshToken
  -- Every *rotated* token is capped at the session deadline, so refreshing buys no extra
  -- lifetime. (The token minted at signup is uncapped — see this plan's Surprises.)
  w <- readIORef ref
  session <- case Map.elems w.sessions of
    (s : _) -> pure s
    [] -> assertFailure "expected a session"
  let rotated = filter (isJust . (.parentTokenId)) (Map.elems w.refreshTokens)
  length rotated @?= 2
  assertBool
    "no rotated refresh token expires after the session"
    (all (\t -> t.expiresAt <= session.expiresAt) rotated)
  -- Past the deadline the freshest token still cannot buy another rotation.
  advanceTo ref (longTokenCfg.sessionTTL + 1)
  res <- runInMemory ref (refresh longTokenCfg (RefreshCommand pair2.refreshToken))
  res @?= Left Err.SessionExpired
  where
    day = 24 * 60 * 60 :: NominalDiffTime
    rotateAt ref delta tok = do
      advanceTo ref delta
      expectRight =<< runInMemory ref (refresh longTokenCfg (RefreshCommand tok))

testVerifyTokenRejectsExpiredSession :: TestTree
testVerifyTokenRejectsExpiredSession = testCase "verifyToken (token+session) rejects an expired session" do
  let checkCfg = longTokenCfg {sessionCheckMode = VerifyTokenAndSession}
  ref <- newIORef (emptyWorld fixedTime)
  (_, pair) <- expectRight =<< runInMemory ref (signup checkCfg (signupEmail aliceEmail strongPw Nothing))
  ok <- runInMemory ref (verifyToken checkCfg pair.accessToken)
  assertBool "the fresh access token verifies" (isRight ok)
  advanceTo ref (checkCfg.sessionTTL + 1)
  res <- runInMemory ref (verifyToken checkCfg pair.accessToken)
  res @?= Left Err.SessionExpired
  where
    isRight = either (const False) (const True)

testMarkUsedIsCompareAndSwap :: TestTree
testMarkUsedIsCompareAndSwap = testCase "mark-used CAS: the second sequential mark returns False" do
  ref <- newIORef (emptyWorld fixedTime)
  _ <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
  w <- readIORef ref
  rid <- case Map.keys w.refreshTokens of
    (r : _) -> pure r
    [] -> assertFailure "expected a refresh token to exist after signup"
  first <- runInMemory ref (markRefreshTokenUsed rid fixedTime)
  second <- runInMemory ref (markRefreshTokenUsed rid fixedTime)
  first @?= True
  second @?= False

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
