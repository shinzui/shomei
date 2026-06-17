{- | Pure, in-memory tests for the EP-2 brute-force lockout and per-IP failure throttle
('Shomei.Workflow.login' abuse protection). Every case runs through
'Shomei.Effect.InMemory.runInMemory' with no database or network, and asserts both the
returned 'Either' and the resulting lockout state read back from the 'World'.

The test config tightens the thresholds (3 failures per account, 5 per IP) so the loops are
short; the windowed-counting and cooldown semantics are otherwise the production defaults.
-}
module Shomei.LockoutSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..), defaultRateLimitConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, emailText, mkEmail)
import Shomei.Domain.LoginAttempt (AccountKey (..), AccountLockout (..), ClientIp (..))
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Error (AuthError (..))
import Shomei.Workflow (login, signup)

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

-- | Tightened thresholds: lock after 3 per-account failures, throttle after 5 per-IP failures.
cfg :: ShomeiConfig
cfg =
    (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients"))
        { rateLimitConfig =
            defaultRateLimitConfig
                { maxFailedLoginsPerAccount = 3
                , maxFailedLoginsPerIp = 5
                }
        }

ip1, ip2 :: ClientIp
ip1 = ClientIp "10.0.0.1"
ip2 = ClientIp "10.0.0.2"

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

keyOf :: Email -> AccountKey
keyOf e = AccountKey (emailText e)

ctxOf :: ClientIp -> Email -> ClientContext
ctxOf ip e = ClientContext ip (keyOf e)

badLogin :: IORef World -> ClientIp -> Email -> IO (Either AuthError ())
badLogin ref ip e = fmap (const ()) <$> runInMemory ref (login cfg (ctxOf ip e) (LoginCommand (loginIdFromEmail e) wrongPw))

goodLogin :: IORef World -> ClientIp -> Email -> IO (Either AuthError ())
goodLogin ref ip e = fmap (const ()) <$> runInMemory ref (login cfg (ctxOf ip e) (LoginCommand (loginIdFromEmail e) strongPw))

advanceClock :: IORef World -> UTCTime -> IO ()
advanceClock ref t = modifyIORef' ref (\w -> w{clock = t})

seedAlice :: IORef World -> IO ()
seedAlice ref = do
    r <- runInMemory ref (signup cfg (SignupCommand{loginId = loginIdFromEmail aliceEmail, email = Just aliceEmail, password = strongPw, displayName = Just "Alice"}))
    case r of
        Right _ -> pure ()
        Left e -> assertFailure ("seed signup failed: " <> show e)

isLocked :: World -> AccountKey -> Bool
isLocked w k = case Map.lookup k w.accountLockouts of
    Just lo -> maybe False (> t0) lo.lockedUntil
    Nothing -> False

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Shomei.Lockout"
        [ testLocksAfterN
        , testLockedSameGenericError
        , testUnknownAndWrongIndistinguishable
        , testUnlockAfterCooldown
        , testSuccessClearsCounter
        , testPerIpThrottle
        ]

testLocksAfterN :: TestTree
testLocksAfterN = testCase "account locks after N failed logins" do
    ref <- newIORef (emptyWorld t0)
    seedAlice ref
    r1 <- badLogin ref ip1 aliceEmail
    r2 <- badLogin ref ip1 aliceEmail
    r3 <- badLogin ref ip1 aliceEmail
    r1 @?= Left InvalidCredentials
    r2 @?= Left InvalidCredentials
    r3 @?= Left InvalidCredentials
    w <- readIORef ref
    assertBool "alice's account is locked after 3 failures" (isLocked w (keyOf aliceEmail))
    case Map.lookup (keyOf aliceEmail) w.accountLockouts of
        Just lo -> lo.lockedUntil @?= Just (addUTCTime (15 * 60) t0)
        Nothing -> assertFailure "expected a lockout row for alice"

testLockedSameGenericError :: TestTree
testLockedSameGenericError = testCase "locked account returns the same generic error (even with correct password)" do
    ref <- newIORef (emptyWorld t0)
    seedAlice ref
    _ <- badLogin ref ip1 aliceEmail
    _ <- badLogin ref ip1 aliceEmail
    _ <- badLogin ref ip1 aliceEmail
    -- Even the CORRECT password is refused while locked, with the identical generic error.
    locked <- goodLogin ref ip1 aliceEmail
    locked @?= Left InvalidCredentials

testUnknownAndWrongIndistinguishable :: TestTree
testUnknownAndWrongIndistinguishable = testCase "unknown email and wrong password are indistinguishable and both count toward lockout" do
    ref <- newIORef (emptyWorld t0)
    seedAlice ref
    -- Failures against an email with NO account still lock that key and return the generic error.
    u1 <- badLogin ref ip1 unknownEmail
    u2 <- badLogin ref ip1 unknownEmail
    u3 <- badLogin ref ip1 unknownEmail
    u1 @?= Left InvalidCredentials
    u3 @?= Left InvalidCredentials
    -- A wrong password against the real account returns the identical generic error.
    wrong <- badLogin ref ip2 aliceEmail
    wrong @?= u2
    w <- readIORef ref
    assertBool "the unknown-email key is locked after 3 failures" (isLocked w (keyOf unknownEmail))

testUnlockAfterCooldown :: TestTree
testUnlockAfterCooldown = testCase "account unlocks after the cooldown elapses" do
    ref <- newIORef (emptyWorld t0)
    seedAlice ref
    _ <- badLogin ref ip1 aliceEmail
    _ <- badLogin ref ip1 aliceEmail
    _ <- badLogin ref ip1 aliceEmail
    wLocked <- readIORef ref
    assertBool "alice is locked immediately after the failures" (isLocked wLocked (keyOf aliceEmail))
    -- Advance the clock past lockedUntil (lockoutDuration default = 15 min) and the window.
    advanceClock ref (addUTCTime (16 * 60) t0)
    ok <- goodLogin ref ip1 aliceEmail
    ok @?= Right ()
    w <- readIORef ref
    assertBool "the lockout row is cleared after a successful login" (not (Map.member (keyOf aliceEmail) w.accountLockouts))

testSuccessClearsCounter :: TestTree
testSuccessClearsCounter = testCase "successful login clears the failure counter" do
    ref <- newIORef (emptyWorld t0)
    seedAlice ref
    -- One short of the lock threshold (2 of 3), then a correct login.
    _ <- badLogin ref ip1 aliceEmail
    _ <- badLogin ref ip1 aliceEmail
    ok <- goodLogin ref ip1 aliceEmail
    ok @?= Right ()
    wAfter <- readIORef ref
    assertBool "no lockout row after the successful login" (not (Map.member (keyOf aliceEmail) wAfter.accountLockouts))
    -- A subsequent single failure must NOT lock (the success reset the counter).
    _ <- badLogin ref ip1 aliceEmail
    w <- readIORef ref
    assertBool "a single failure after a success does not lock" (not (isLocked w (keyOf aliceEmail)))

testPerIpThrottle :: TestTree
testPerIpThrottle = testCase "per-IP failure throttle trips across different accounts" do
    ref <- newIORef (emptyWorld t0)
    -- Fail logins against 5 distinct (unregistered) emails from one IP: 5 failures, none of
    -- which individually locks an account, but together they trip the per-IP throttle (5).
    let spread = map (\u -> mkEmail' (u <> "@example.com")) ["u1", "u2", "u3", "u4", "u5"]
    results <- traverse (badLogin ref ip1) spread
    assertBool "the 5 spread failures each return the generic error" (all (== Left InvalidCredentials) results)
    -- The next attempt from the SAME IP is throttled.
    throttled <- badLogin ref ip1 (mkEmail' "u6@example.com")
    throttled @?= Left TooManyRequests
    -- The SAME attempt from a DIFFERENT IP returns the ordinary generic error, not 429.
    other <- badLogin ref ip2 (mkEmail' "u6@example.com")
    other @?= Left InvalidCredentials
