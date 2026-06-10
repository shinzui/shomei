module Shomei.AccountSpec (tests) where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..), OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
import Shomei.Domain.PasswordResetToken (PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (Session (..), SessionStatus (..))
import Shomei.Domain.User (User (..))
import Shomei.Domain.VerificationToken (PersistedVerificationToken (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Error (AuthError (InvalidCredentials, PasswordResetTokenInvalid, VerificationTokenInvalid))
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
        , testConfirmPasswordReset
        , testRejectConsumedReset
        , testChangePasswordWrongCurrent
        ]

testRequestEmailVerification :: TestTree
testRequestEmailVerification = testCase "request email verification emits a notification with a token" do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    result <- runInMemory ref (requestEmailVerification cfg (RequestEmailVerification user.email))
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

testConfirmPasswordReset :: TestTree
testConfirmPasswordReset = testCase "confirm password reset changes password and revokes all sessions" do
    (ref, user, raw) <- passwordResetRequestedWorld
    result <- runInMemory ref (confirmPasswordReset cfg (ConfirmPasswordReset raw newPw))
    result @?= Right ()
    w <- readIORef ref
    assertBool "password hash was updated" (any newHash (Map.elems w.credsByEmail))
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
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    result <- runInMemory ref (changePassword cfg (ChangePassword user.userId wrongPw newPw))
    result @?= Left InvalidCredentials
    w <- readIORef ref
    assertBool "password hash is unchanged" (all oldHash (Map.elems w.credsByEmail))
  where
    oldHash c = c.passwordHash == PasswordHash "argon2-fake:correct horse battery staple"

verificationRequestedWorld :: IO (IORef World, OneTimeToken)
verificationRequestedWorld = do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (requestEmailVerification cfg (RequestEmailVerification user.email))
    raw <- latestVerificationToken =<< readIORef ref
    pure (ref, raw)

passwordResetRequestedWorld :: IO (IORef World, User, OneTimeToken)
passwordResetRequestedWorld = do
    ref <- newIORef (emptyWorld fixedTime)
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    _ <- expectRight =<< runInMemory ref (login cfg (ClientContext (ClientIp "test-ip") (AccountKey "alice")) (LoginCommand aliceEmail strongPw))
    _ <- expectRight =<< runInMemory ref (requestPasswordReset cfg (RequestPasswordReset user.email))
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
