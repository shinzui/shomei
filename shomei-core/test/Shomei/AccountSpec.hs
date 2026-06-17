module Shomei.AccountSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..), OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.Password (PasswordHash (..), PasswordPolicy (..), PlainPassword (..))
import Shomei.Domain.PasswordResetToken (PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (Session (..), SessionStatus (..))
import Shomei.Domain.User (User (..))
import Shomei.Domain.VerificationToken (PersistedVerificationToken (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Error (
    AuthError (InvalidCredentials, PasswordResetTokenInvalid, VerificationTokenInvalid, WeakPassword),
    PasswordPolicyViolation (PasswordBreached, PasswordResemblesIdentity, PasswordTooCommon),
 )
import Shomei.Workflow (login, signup)
import Shomei.Workflow.Account (
    ChangePassword (..),
    ConfirmEmailVerification (..),
    ConfirmPasswordReset (..),
    RequestEmailVerification (..),
    RequestPasswordReset (..),
    changePassword,
    confirmEmailVerification,
    confirmPasswordReset,
    requestEmailVerification,
    requestPasswordReset,
 )

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

newPw :: PlainPassword
newPw = PlainPassword "correct horse battery staple two"

wrongPw :: PlainPassword
wrongPw = PlainPassword "totally the wrong password"

mkEmail' :: Text -> Email
mkEmail' t = case mkEmail t of
    Right e -> e
    Left err -> error ("bad test email: " <> show err)

-- | An email-first signup command: login id defaults to the email text, email carried through.
signupEmail :: Email -> PlainPassword -> Maybe Text -> SignupCommand
signupEmail e pw dn =
    SignupCommand{loginId = loginIdFromEmail e, email = Just e, password = pw, displayName = dn}

-- | An email-first login command keyed on the email-derived login id.
loginEmail :: Email -> PlainPassword -> LoginCommand
loginEmail e pw = LoginCommand{loginId = loginIdFromEmail e, password = pw}

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

tests :: TestTree
tests =
    testGroup
        "Shomei.Account"
        [ testRequestEmailVerification
        , testConfirmEmailVerification
        , testRejectConsumedVerification
        , testUnknownPasswordResetSuccess
        , testUnknownPasswordResetNoNotification
        , testPasswordResetDeliversToEmail
        , testConfirmPasswordReset
        , testRejectConsumedReset
        , testChangePasswordWrongCurrent
        , testChangePasswordRejectsCommon
        , testChangePasswordRejectsIdentity
        , testConfirmResetRejectsCommon
        , testSignupRejectsBreached
        , testSignupAcceptsCleanWhenEnabled
        , testSignupAllowsBreachedWhenDisabled
        , testSignupFailOpen
        , testSignupFailClosed
        , testChangePasswordRejectsBreached
        , testConfirmResetRejectsBreached
        ]

-- EP-3 breach-check fixtures. The pure validation runs first, so the password used in these
-- tests ('strongPw'/'newPw') must clear the length/common/contextual checks and be rejected
-- only by the breach guard. The in-memory fake treats a plaintext as breached iff it is in the
-- World's 'breachedPasswords' set, and reports 'BreachCheckUnavailable' when
-- 'breachCheckAvailable' is False.

breachCfg :: ShomeiConfig
breachCfg = cfg{passwordPolicy = cfg.passwordPolicy{breachCheckEnabled = True}}

breachCfgFailClosed :: ShomeiConfig
breachCfgFailClosed =
    cfg{passwordPolicy = cfg.passwordPolicy{breachCheckEnabled = True, breachCheckFailClosed = True}}

seedBreached :: IORef World -> PlainPassword -> IO ()
seedBreached ref (PlainPassword pw) =
    modifyIORef' ref (\w -> w{breachedPasswords = Set.insert pw w.breachedPasswords})

markBreachCheckUnavailable :: IORef World -> IO ()
markBreachCheckUnavailable ref = modifyIORef' ref (\w -> w{breachCheckAvailable = False})

testSignupRejectsBreached :: TestTree
testSignupRejectsBreached = testCase "signup rejects a breached password when the check is enabled" do
    ref <- newIORef (emptyWorld fixedTime)
    seedBreached ref strongPw
    result <- runInMemory ref (signup breachCfg (signupEmail aliceEmail strongPw Nothing))
    fmap fst result @?= Left (WeakPassword PasswordBreached)

testSignupAcceptsCleanWhenEnabled :: TestTree
testSignupAcceptsCleanWhenEnabled = testCase "signup accepts a clean password when the check is enabled" do
    ref <- newIORef (emptyWorld fixedTime)
    result <- runInMemory ref (signup breachCfg (signupEmail aliceEmail strongPw Nothing))
    assertBool "expected Right" (isRightResult result)

testSignupAllowsBreachedWhenDisabled :: TestTree
testSignupAllowsBreachedWhenDisabled = testCase "signup allows a breached password when the check is disabled (default)" do
    ref <- newIORef (emptyWorld fixedTime)
    seedBreached ref strongPw
    result <- runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    assertBool "expected Right" (isRightResult result)

testSignupFailOpen :: TestTree
testSignupFailOpen = testCase "fail-open: an unreachable checker allows the password" do
    ref <- newIORef (emptyWorld fixedTime)
    seedBreached ref strongPw
    markBreachCheckUnavailable ref
    result <- runInMemory ref (signup breachCfg (signupEmail aliceEmail strongPw Nothing))
    assertBool "expected Right" (isRightResult result)

testSignupFailClosed :: TestTree
testSignupFailClosed = testCase "fail-closed: an unreachable checker rejects the password" do
    ref <- newIORef (emptyWorld fixedTime)
    markBreachCheckUnavailable ref
    result <- runInMemory ref (signup breachCfgFailClosed (signupEmail aliceEmail strongPw Nothing))
    fmap fst result @?= Left (WeakPassword PasswordBreached)

testChangePasswordRejectsBreached :: TestTree
testChangePasswordRejectsBreached = testCase "change password rejects a breached new password" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    seedBreached ref newPw
    result <- runInMemory ref (changePassword breachCfg (ChangePassword user.userId strongPw newPw))
    result @?= Left (WeakPassword PasswordBreached)

testConfirmResetRejectsBreached :: TestTree
testConfirmResetRejectsBreached = testCase "confirm password reset rejects a breached new password" do
    (ref, _, raw) <- passwordResetRequestedWorld
    seedBreached ref newPw
    result <- runInMemory ref (confirmPasswordReset breachCfg (ConfirmPasswordReset raw newPw))
    result @?= Left (WeakPassword PasswordBreached)

isRightResult :: Either e a -> Bool
isRightResult = either (const False) (const True)

-- | A policy with a small minimum length so identity-derived passwords (e.g. "alice")
-- reach the contextual check instead of failing the default length guard first.
smallMinCfg :: ShomeiConfig
smallMinCfg = cfg{passwordPolicy = cfg.passwordPolicy{minLength = 4}}

commonPw :: PlainPassword
commonPw = PlainPassword "passwordpassword" -- in the bundled dictionary, length >= 12

testChangePasswordRejectsCommon :: TestTree
testChangePasswordRejectsCommon = testCase "change password rejects a common new password" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    result <- runInMemory ref (changePassword cfg (ChangePassword user.userId strongPw commonPw))
    result @?= Left (WeakPassword PasswordTooCommon)

testChangePasswordRejectsIdentity :: TestTree
testChangePasswordRejectsIdentity = testCase "change password rejects an identity-derived new password" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup smallMinCfg (signupEmail aliceEmail strongPw Nothing))
    result <- runInMemory ref (changePassword smallMinCfg (ChangePassword user.userId strongPw (PlainPassword "alice")))
    result @?= Left (WeakPassword PasswordResemblesIdentity)

testConfirmResetRejectsCommon :: TestTree
testConfirmResetRejectsCommon = testCase "confirm password reset rejects a common new password" do
    (ref, _, raw) <- passwordResetRequestedWorld
    result <- runInMemory ref (confirmPasswordReset cfg (ConfirmPasswordReset raw commonPw))
    result @?= Left (WeakPassword PasswordTooCommon)

testRequestEmailVerification :: TestTree
testRequestEmailVerification = testCase "request email verification emits a notification with a token" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    result <- runInMemory ref (requestEmailVerification cfg (RequestEmailVerification aliceEmail))
    result @?= Right ()
    w <- readIORef ref
    case w.sentNotifications of
        EmailVerificationRequested{token = raw} : _ -> do
            assertBool "token is non-empty" (oneTimeRawNonEmpty raw)
            Map.size w.verificationTokens @?= 1
            assertBool "stored token hash matches notification token" (Map.member (expectedHash raw) w.verificationByHash)
        _ -> assertFailure "expected email-verification notification"

testConfirmEmailVerification :: TestTree
testConfirmEmailVerification = testCase "confirm email verification flips emailVerifiedAt" do
    (ref, raw) <- verificationRequestedWorld
    result <- runInMemory ref (confirmEmailVerification cfg (ConfirmEmailVerification raw))
    result @?= Right ()
    w <- readIORef ref
    assertBool "user is marked verified" (any (\u -> u.emailVerifiedAt == Just fixedTime) (Map.elems w.users))
    assertBool "token is consumed" (all (\t -> t.status == OneTimeTokenConsumed) (Map.elems w.verificationTokens))

testRejectConsumedVerification :: TestTree
testRejectConsumedVerification = testCase "confirming an already-consumed verification token is rejected" do
    (ref, raw) <- verificationRequestedWorld
    _ <- expectRight =<< runInMemory ref (confirmEmailVerification cfg (ConfirmEmailVerification raw))
    result <- runInMemory ref (confirmEmailVerification cfg (ConfirmEmailVerification raw))
    result @?= Left VerificationTokenInvalid

testUnknownPasswordResetSuccess :: TestTree
testUnknownPasswordResetSuccess = testCase "request password reset for unknown email still returns success" do
    ref <- newIORef (emptyWorld fixedTime)
    result <- runInMemory ref (requestPasswordReset cfg (RequestPasswordReset unknownEmail))
    result @?= Right ()

testUnknownPasswordResetNoNotification :: TestTree
testUnknownPasswordResetNoNotification = testCase "request password reset for unknown email emits no notification" do
    ref <- newIORef (emptyWorld fixedTime)
    _ <- expectRight =<< runInMemory ref (requestPasswordReset cfg (RequestPasswordReset unknownEmail))
    w <- readIORef ref
    w.sentNotifications @?= []
    Map.size w.passwordResetTokens @?= 0

testPasswordResetDeliversToEmail :: TestTree
testPasswordResetDeliversToEmail = testCase "password reset delivers to the email when present" do
    (ref, _, _) <- passwordResetRequestedWorld
    w <- readIORef ref
    case w.sentNotifications of
        PasswordResetRequested{email} : _ -> email @?= aliceEmail
        _ -> assertFailure "expected a password-reset notification addressed to the email"

testConfirmPasswordReset :: TestTree
testConfirmPasswordReset = testCase "confirm password reset changes password and revokes all sessions" do
    (ref, user, raw) <- passwordResetRequestedWorld
    result <- runInMemory ref (confirmPasswordReset cfg (ConfirmPasswordReset raw newPw))
    result @?= Right ()
    w <- readIORef ref
    assertBool "password hash was updated" (any newHash (Map.elems w.credsByLoginId))
    assertBool "sessions are revoked" (all (\s -> s.userId /= user.userId || s.status == SessionRevoked) (Map.elems w.sessions))
    assertBool "refresh tokens are revoked" (all (\t -> t.status == RefreshTokenRevoked) (Map.elems w.refreshTokens))
    assertBool "reset token is consumed" (all (\t -> t.status == OneTimeTokenConsumed) (Map.elems w.passwordResetTokens))
    assertBool "completion event was published" (any isCompleted w.publishedEvents)
  where
    newHash c = c.passwordHash == PasswordHash "argon2-fake:correct horse battery staple two"
    isCompleted (Event.PasswordResetCompleted _) = True
    isCompleted _ = False

testRejectConsumedReset :: TestTree
testRejectConsumedReset = testCase "confirming an already-consumed reset token is rejected" do
    (ref, _, raw) <- passwordResetRequestedWorld
    _ <- expectRight =<< runInMemory ref (confirmPasswordReset cfg (ConfirmPasswordReset raw newPw))
    result <- runInMemory ref (confirmPasswordReset cfg (ConfirmPasswordReset raw newPw))
    result @?= Left PasswordResetTokenInvalid

testChangePasswordWrongCurrent :: TestTree
testChangePasswordWrongCurrent = testCase "change password with wrong current password is rejected" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    result <- runInMemory ref (changePassword cfg (ChangePassword user.userId wrongPw newPw))
    result @?= Left InvalidCredentials
    w <- readIORef ref
    assertBool "password hash is unchanged" (all oldHash (Map.elems w.credsByLoginId))
  where
    oldHash c = c.passwordHash == PasswordHash "argon2-fake:correct horse battery staple"

verificationRequestedWorld :: IO (IORef World, OneTimeToken)
verificationRequestedWorld = do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (requestEmailVerification cfg (RequestEmailVerification aliceEmail))
    raw <- latestVerificationToken =<< readIORef ref
    pure (ref, raw)

passwordResetRequestedWorld :: IO (IORef World, User, OneTimeToken)
passwordResetRequestedWorld = do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (login cfg (ClientContext (ClientIp "test-ip") (AccountKey "alice")) (loginEmail aliceEmail strongPw))
    _ <- expectRight =<< runInMemory ref (requestPasswordReset cfg (RequestPasswordReset aliceEmail))
    raw <- latestResetToken =<< readIORef ref
    pure (ref, user, raw)

latestVerificationToken :: World -> IO OneTimeToken
latestVerificationToken w = case w.sentNotifications of
    EmailVerificationRequested{token = raw} : _ -> pure raw
    _ -> assertFailure "expected email-verification notification"

latestResetToken :: World -> IO OneTimeToken
latestResetToken w = case w.sentNotifications of
    PasswordResetRequested{token = raw} : _ -> pure raw
    _ -> assertFailure "expected password-reset notification"

oneTimeRawNonEmpty :: OneTimeToken -> Bool
oneTimeRawNonEmpty raw = expectedHash raw /= OneTimeTokenHash "hash:"

expectedHash :: OneTimeToken -> OneTimeTokenHash
expectedHash (OneTimeToken t) = OneTimeTokenHash ("hash:" <> t)
