-- | Behavioral tests for the EP-4 MFA step-up and passwordless login workflows
-- ('Shomei.Session.Authentication.Workflow.login' widened to 'LoginResult', and 'Shomei.Mfa.Workflow'), run entirely
-- through the in-memory interpreter ('Shomei.Test.InMemory.runInMemory') with EP-1's
-- deterministic fake 'Shomei.Passkey.Ceremony.Port'. No cryptography, no database, no network.
--
-- The fake accepts an assertion 'Data.Aeson.Value' that echoes the begin step's @challenge@ and
-- carries base64url @credentialId@/@userHandle@/@publicKey@ fields; 'acceptedAssertion' builds
-- one matching the seeded passkey.
module Shomei.Mfa.WorkflowSpec (tests) where

import Control.Monad (replicateM_)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Shomei.Account.Email.Domain (Email, emailText, mkEmail)
import Shomei.Account.LoginId.Domain (LoginId, mkLoginId)
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.User.Domain (User (..))
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Error (AuthError (InvalidCredentials, MfaAssertionInvalid, PendingCeremonyNotFound, TotpCodeInvalid))
import Shomei.Id (CeremonyId, genCeremonyId, genTotpCredentialId)
import Shomei.Mfa.Totp.Algorithm (TotpSecret (..), totpCode, totpCounter)
import Shomei.Mfa.Totp.Domain (NewTotpCredential (..))
import Shomei.Mfa.Totp.Store (confirmTotp, findTotpByUser, upsertTotpEnrollment)
import Shomei.Mfa.Totp.Workflow (TotpRemovalProof (..), removeTotp)
import Shomei.Mfa.Workflow (MfaCompletion (..), beginPasswordlessLogin, completeMfa, completePasswordlessLogin)
import Shomei.Passkey.Domain
  ( NewPasskeyCredential (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
  )
import Shomei.Passkey.Store (createPasskey)
import Shomei.Session.Authentication.Workflow (LoginResult (..), MfaChallenge (..), login, signup)
import Shomei.Session.Command (ClientContext (..), LoginCommand (..), ProofContext (..), SignupCommand (..))
import Shomei.Session.LoginAttempt.Domain (AccountKey (..), AccountLockout (..), ClientIp (..))
import Shomei.Session.LoginAttempt.Store (setAccountLockout)
import Shomei.Session.Token.Domain (AccessToken (..), TokenPair (..))
import Shomei.Test.InMemory (World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- Fixtures -------------------------------------------------------------------

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

-- | The default config requires a second factor when one is enrolled.
cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

proofContext :: ProofContext
proofContext = ProofContext {clientIp = ClientIp "test-ip", accountKeyOf = AccountKey}

mkEmail' :: Text -> Email
mkEmail' t = either (\e -> error ("bad test email: " <> show e)) id (mkEmail t)

ctxFor :: Email -> ClientContext
ctxFor e = ClientContext (ClientIp "test-ip") (AccountKey (emailText e))

-- The fixed bytes of the single seeded passkey.
seededCredId :: WebAuthnCredentialId
seededCredId = WebAuthnCredentialId "cred-1"

seededHandle :: UserHandle
seededHandle = UserHandle "uh-1"

seededKey :: PublicKeyBytes
seededKey = PublicKeyBytes "pk-1"

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- | Sign a user up and seed one passkey for them (directly through 'createPasskey').
seedUserWithPasskey :: IORef World -> IO ()
seedUserWithPasskey ref = do
  (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand {loginId = either (error . show) id (mkLoginId (emailText aliceEmail)), email = Just aliceEmail, password = strongPw, displayName = Just "Alice"}))
  let User {userId = uid} = user
  _ <-
    runInMemory
      ref
      ( createPasskey
          NewPasskeyCredential
            { userId = uid,
              credentialId = seededCredId,
              userHandle = seededHandle,
              publicKey = seededKey,
              signCounter = SignatureCounter 0,
              transports = [],
              label = Just "Test Key",
              createdAt = fixedTime
            }
      )
  pure ()

-- | An assertion JSON the fake accepts for the seeded passkey, echoing @challenge@.
acceptedAssertion :: Text -> Value
acceptedAssertion chal =
  object
    [ "challenge" .= chal,
      "credentialId" .= seededCredId,
      "userHandle" .= seededHandle,
      "publicKey" .= seededKey
    ]

-- | The @challenge@ baked into a begin step's options 'Value'.
challengeOf :: Value -> Maybe Text
challengeOf = parseMaybe (withObject "options" (\o -> o .: "challenge"))

-- | Assert a token pair carries a non-empty access token.
assertTokenPresent :: (User, TokenPair) -> IO ()
assertTokenPresent (_user, TokenPair (AccessToken at) _ _) =
  assertBool "access token present" (not (T.null at))

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Shomei.Mfa.Workflow"
    [ testNoPasskeyComplete,
      testMfaRequired,
      testCompleteMfa,
      testCeremonyHygiene,
      testBadAssertion,
      testBadPasskeysLock,
      testSecondFactorSuccessClearsLockout,
      testTotpRemovalFailuresLock,
      testPasswordless
    ]

testNoPasskeyComplete :: TestTree
testNoPasskeyComplete = testCase "no-passkey login yields LoginComplete with a token" do
  ref <- newIORef (emptyWorld fixedTime)
  _ <- expectRight =<< runInMemory ref (signup cfg (SignupCommand {loginId = either (error . show) id (mkLoginId (emailText aliceEmail)), email = Just aliceEmail, password = strongPw, displayName = Just "Alice"}))
  res <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (either (error . show) id (mkLoginId (emailText aliceEmail))) strongPw))
  case res of
    LoginComplete u pair -> assertTokenPresent (u, pair)
    MfaRequired _ -> assertFailure "expected LoginComplete (no passkey enrolled)"

testMfaRequired :: TestTree
testMfaRequired = testCase "passkey + required second factor yields MfaRequired, no token" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  res <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (either (error . show) id (mkLoginId (emailText aliceEmail))) strongPw))
  case res of
    MfaRequired (MfaChallenge _cid opts _methods) ->
      assertBool "a challenge is present in the options" (challengeOf opts /= Nothing)
    LoginComplete _ _ -> assertFailure "expected MfaRequired (passkey enrolled, second factor required)"

testCompleteMfa :: TestTree
testCompleteMfa = testCase "completeMfa with a valid assertion yields a token pair" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  (cid, opts) <- loginExpectingChallenge ref
  chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
  done <- expectRight =<< runInMemory ref (completeMfa cfg proofContext cid (MfaPasskey (acceptedAssertion chal)))
  assertTokenPresent done

testCeremonyHygiene :: TestTree
testCeremonyHygiene = testCase "bogus or consumed ceremony is rejected (PendingCeremonyNotFound)" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  -- A ceremony id that was never stored.
  bogus <- genCeremonyId
  bad <- runInMemory ref (completeMfa cfg proofContext bogus (MfaPasskey (acceptedAssertion "x")))
  bad @?= Left PendingCeremonyNotFound
  -- A real challenge succeeds once; re-completing the now-consumed ceremony is a 404.
  (cid, opts) <- loginExpectingChallenge ref
  chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
  _ <- expectRight =<< runInMemory ref (completeMfa cfg proofContext cid (MfaPasskey (acceptedAssertion chal)))
  again <- runInMemory ref (completeMfa cfg proofContext cid (MfaPasskey (acceptedAssertion chal)))
  again @?= Left PendingCeremonyNotFound

testBadAssertion :: TestTree
testBadAssertion = testCase "completeMfa with an unknown credential fails with MfaAssertionInvalid" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  (cid, opts) <- loginExpectingChallenge ref
  chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
  let wrong =
        object
          [ "challenge" .= chal,
            "credentialId" .= WebAuthnCredentialId "cred-unknown",
            "userHandle" .= UserHandle "uh-x",
            "publicKey" .= PublicKeyBytes "pk-x"
          ]
  res <- runInMemory ref (completeMfa cfg proofContext cid (MfaPasskey wrong))
  res @?= Left MfaAssertionInvalid

testBadPasskeysLock :: TestTree
testBadPasskeysLock = testCase "five bad passkey assertions lock the account" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  replicateM_ 5 do
    (cid, opts) <- loginExpectingChallenge ref
    chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
    let wrong =
          object
            [ "challenge" .= chal,
              "credentialId" .= WebAuthnCredentialId "cred-unknown",
              "userHandle" .= UserHandle "uh-x",
              "publicKey" .= PublicKeyBytes "pk-x"
            ]
    result <- runInMemory ref (completeMfa cfg proofContext cid (MfaPasskey wrong))
    result @?= Left MfaAssertionInvalid
  denied <- runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (either (error . show) id (mkLoginId (emailText aliceEmail))) strongPw))
  denied @?= Left InvalidCredentials

testSecondFactorSuccessClearsLockout :: TestTree
testSecondFactorSuccessClearsLockout = testCase "second-factor success clears an expired standing lockout" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  let key = AccountKey (emailText aliceEmail)
      expired = AccountLockout key 5 (Just fixedTime) fixedTime
  runInMemory ref (setAccountLockout expired)
  (cid, opts) <- loginExpectingChallenge ref
  chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
  _ <- expectRight =<< runInMemory ref (completeMfa cfg proofContext cid (MfaPasskey (acceptedAssertion chal)))
  w <- readIORef ref
  assertBool "the standing lockout row is cleared" (not (Map.member key w.accountLockouts))

testTotpRemovalFailuresLock :: TestTree
testTotpRemovalFailuresLock = testCase "wrong TOTP removal codes count and a locked account cannot remove the factor" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand {loginId = either (error . show) id (mkLoginId (emailText aliceEmail)), email = Just aliceEmail, password = strongPw, displayName = Just "Alice"}))
  tcid <- genTotpCredentialId
  let secret = TotpSecret "12345678901234567890"
      correct = totpCode 6 secret (totpCounter fixedTime)
      wrong = if correct == "000000" then "999999" else "000000"
  runInMemory ref do
    _ <- upsertTotpEnrollment NewTotpCredential {totpCredentialId = tcid, userId = user.userId, secret, createdAt = fixedTime}
    confirmTotp tcid fixedTime
  replicateM_ 5 do
    result <- runInMemory ref (removeTotp cfg proofContext user (RemoveWithCode wrong))
    result @?= Left TotpCodeInvalid
  lockedResult <- runInMemory ref (removeTotp cfg proofContext user (RemoveWithCode correct))
  lockedResult @?= Left TotpCodeInvalid
  remaining <- runInMemory ref (findTotpByUser user.userId)
  assertBool "the locked removal leaves the TOTP credential intact" (isJust remaining)

testPasswordless :: TestTree
testPasswordless = testCase "passwordless login resolves the user and mints tokens" do
  ref <- newIORef (emptyWorld fixedTime)
  seedUserWithPasskey ref
  (cid, opts) <- expectRight =<< runInMemory ref (beginPasswordlessLogin cfg)
  chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
  done <- expectRight =<< runInMemory ref (completePasswordlessLogin cfg proofContext cid (acceptedAssertion chal))
  assertTokenPresent done

-- | Log in (password) for the seeded user and expect an MFA challenge, returning its
-- ceremony id and options.
loginExpectingChallenge :: IORef World -> IO (CeremonyId, Value)
loginExpectingChallenge ref = do
  res <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (either (error . show) id (mkLoginId (emailText aliceEmail))) strongPw))
  case res of
    MfaRequired (MfaChallenge cid opts _methods) -> pure (cid, opts)
    LoginComplete _ _ -> assertFailure "expected MfaRequired"
