{- | Behavioral tests for the EP-4 MFA step-up and passwordless login workflows
('Shomei.Workflow.login' widened to 'LoginResult', and 'Shomei.Workflow.Mfa'), run entirely
through the in-memory interpreter ('Shomei.Effect.InMemory.runInMemory') with EP-1's
deterministic fake 'Shomei.Effect.WebAuthnCeremony'. No cryptography, no database, no network.

The fake accepts an assertion 'Data.Aeson.Value' that echoes the begin step's @challenge@ and
carries base64url @credentialId@/@userHandle@/@publicKey@ fields; 'acceptedAssertion' builds
one matching the seeded passkey.
-}
module Shomei.Workflow.MfaSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.IORef (IORef, newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, emailText, mkEmail)
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.Passkey (
    NewPasskeyCredential (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
 )
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.InMemory (World, emptyWorld, runInMemory)
import Shomei.Effect.PasskeyStore (createPasskey)
import Shomei.Error (AuthError (MfaAssertionInvalid, PendingCeremonyNotFound))
import Shomei.Id (CeremonyId, genCeremonyId)
import Shomei.Workflow (LoginResult (..), MfaChallenge (..), login, signup)
import Shomei.Workflow.Mfa (beginPasswordlessLogin, completeMfa, completePasswordlessLogin)

-- Fixtures -------------------------------------------------------------------

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

-- | The default config has @webauthnConfig.mfaRequired = True@.
cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

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
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand{loginId = loginIdFromEmail aliceEmail, email = Just aliceEmail, password = strongPw, displayName = Just "Alice"}))
    let User{userId = uid} = user
    _ <-
        runInMemory
            ref
            ( createPasskey
                NewPasskeyCredential
                    { userId = uid
                    , credentialId = seededCredId
                    , userHandle = seededHandle
                    , publicKey = seededKey
                    , signCounter = SignatureCounter 0
                    , transports = []
                    , label = Just "Test Key"
                    , createdAt = fixedTime
                    }
            )
    pure ()

-- | An assertion JSON the fake accepts for the seeded passkey, echoing @challenge@.
acceptedAssertion :: Text -> Value
acceptedAssertion chal =
    object
        [ "challenge" .= chal
        , "credentialId" .= seededCredId
        , "userHandle" .= seededHandle
        , "publicKey" .= seededKey
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
        "Shomei.Workflow.Mfa"
        [ testNoPasskeyComplete
        , testMfaRequired
        , testCompleteMfa
        , testCeremonyHygiene
        , testBadAssertion
        , testPasswordless
        ]

testNoPasskeyComplete :: TestTree
testNoPasskeyComplete = testCase "no-passkey login yields LoginComplete with a token" do
    ref <- newIORef (emptyWorld fixedTime)
    _ <- expectRight =<< runInMemory ref (signup cfg (SignupCommand{loginId = loginIdFromEmail aliceEmail, email = Just aliceEmail, password = strongPw, displayName = Just "Alice"}))
    res <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (loginIdFromEmail aliceEmail) strongPw))
    case res of
        LoginComplete u pair -> assertTokenPresent (u, pair)
        MfaRequired _ -> assertFailure "expected LoginComplete (no passkey enrolled)"

testMfaRequired :: TestTree
testMfaRequired = testCase "passkey + mfaRequired login yields MfaRequired, no token" do
    ref <- newIORef (emptyWorld fixedTime)
    seedUserWithPasskey ref
    res <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (loginIdFromEmail aliceEmail) strongPw))
    case res of
        MfaRequired (MfaChallenge _cid opts) ->
            assertBool "a challenge is present in the options" (challengeOf opts /= Nothing)
        LoginComplete _ _ -> assertFailure "expected MfaRequired (passkey enrolled, mfaRequired on)"

testCompleteMfa :: TestTree
testCompleteMfa = testCase "completeMfa with a valid assertion yields a token pair" do
    ref <- newIORef (emptyWorld fixedTime)
    seedUserWithPasskey ref
    (cid, opts) <- loginExpectingChallenge ref
    chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
    done <- expectRight =<< runInMemory ref (completeMfa cfg cid (acceptedAssertion chal))
    assertTokenPresent done

testCeremonyHygiene :: TestTree
testCeremonyHygiene = testCase "bogus or consumed ceremony is rejected (PendingCeremonyNotFound)" do
    ref <- newIORef (emptyWorld fixedTime)
    seedUserWithPasskey ref
    -- A ceremony id that was never stored.
    bogus <- genCeremonyId
    bad <- runInMemory ref (completeMfa cfg bogus (acceptedAssertion "x"))
    bad @?= Left PendingCeremonyNotFound
    -- A real challenge succeeds once; re-completing the now-consumed ceremony is a 404.
    (cid, opts) <- loginExpectingChallenge ref
    chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
    _ <- expectRight =<< runInMemory ref (completeMfa cfg cid (acceptedAssertion chal))
    again <- runInMemory ref (completeMfa cfg cid (acceptedAssertion chal))
    again @?= Left PendingCeremonyNotFound

testBadAssertion :: TestTree
testBadAssertion = testCase "completeMfa with an unknown credential fails with MfaAssertionInvalid" do
    ref <- newIORef (emptyWorld fixedTime)
    seedUserWithPasskey ref
    (cid, opts) <- loginExpectingChallenge ref
    chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
    let wrong =
            object
                [ "challenge" .= chal
                , "credentialId" .= WebAuthnCredentialId "cred-unknown"
                , "userHandle" .= UserHandle "uh-x"
                , "publicKey" .= PublicKeyBytes "pk-x"
                ]
    res <- runInMemory ref (completeMfa cfg cid wrong)
    res @?= Left MfaAssertionInvalid

testPasswordless :: TestTree
testPasswordless = testCase "passwordless login resolves the user and mints tokens" do
    ref <- newIORef (emptyWorld fixedTime)
    seedUserWithPasskey ref
    (cid, opts) <- expectRight =<< runInMemory ref (beginPasswordlessLogin cfg)
    chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
    done <- expectRight =<< runInMemory ref (completePasswordlessLogin cfg cid (acceptedAssertion chal))
    assertTokenPresent done

-- | Log in (password) for the seeded user and expect an MFA challenge, returning its
-- ceremony id and options.
loginExpectingChallenge :: IORef World -> IO (CeremonyId, Value)
loginExpectingChallenge ref = do
    res <- expectRight =<< runInMemory ref (login cfg (ctxFor aliceEmail) (LoginCommand (loginIdFromEmail aliceEmail) strongPw))
    case res of
        MfaRequired (MfaChallenge cid opts) -> pure (cid, opts)
        LoginComplete _ _ -> assertFailure "expected MfaRequired"
