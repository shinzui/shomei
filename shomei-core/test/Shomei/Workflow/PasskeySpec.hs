{-# LANGUAGE DataKinds #-}

{- | Pure tests for the EP-3 passkey enrollment workflows ('Shomei.Workflow.Passkey'),
driven over EP-2's in-memory stores and EP-1's deterministic fake 'WebAuthnCeremony'
interpreter via 'Shomei.Effect.InMemory.runInMemory'. No HTTP, no cryptography.

The fake's @completeRegistrationCeremony@ accepts a credential JSON whose @challenge@
echoes the begin step's options blob and returns the credential id / user handle / public
key carried in that JSON, so each test extracts the challenge from the begin response and
crafts a matching credential. The same behavior is re-proven over HTTP by the
@shomei-servant@ end-to-end test.
-}
module Shomei.Workflow.PasskeySpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Passkey (
    PasskeyCredential (..),
    PublicKeyBytes (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
 )
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.User (NewUser (..), User (..))
import Shomei.Error (AuthError (..))
import Shomei.Effect.InMemory (World, emptyWorld, runInMemory)
import Shomei.Effect.UserStore (createUser)
import Shomei.Effect.WebAuthnCeremony (WebAuthnError (..))
import Shomei.Id (PasskeyId, UserId, genCeremonyId, genUserId)
import Shomei.Workflow.Passkey (
    beginPasskeyRegistration,
    completePasskeyRegistration,
    listPasskeys,
    removePasskey,
 )

tests :: TestTree
tests =
    testGroup
        "Shomei.Workflow.Passkey"
        [ testCase "begin then complete stores a passkey; list returns it; remove deletes it" enrollListRemove
        , testCase "wrong-user complete is rejected" wrongUserComplete
        , testCase "absent ceremony is rejected" absentCeremony
        , testCase "an already-consumed ceremony is rejected on the second complete" consumedCeremony
        , testCase "a credential the verifier rejects yields WebAuthnCeremonyError" rejectedCredential
        ]

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

aliceEmail :: Email
aliceEmail = case mkEmail "alice@example.com" of
    Right e -> e
    Left err -> error ("bad test email: " <> show err)

newWorld :: IO (IORef World)
newWorld = newIORef (emptyWorld t0)

seedUser :: IORef World -> IO UserId
seedUser ref = runInMemory ref do
    User{userId} <- createUser NewUser{loginId = loginIdFromEmail aliceEmail, email = Just aliceEmail, displayName = Just "Ada"}
    pure userId

-- Field accessors (OverloadedRecordDot is unreliable for these EP-1 records).
pkPasskeyId :: PasskeyCredential -> PasskeyId
pkPasskeyId PasskeyCredential{passkeyId} = passkeyId

pkLabel :: PasskeyCredential -> Maybe Text
pkLabel PasskeyCredential{label} = label

-- | The challenge the fake baked into a begin step's options JSON (we echo it back).
challengeOf :: Value -> Text
challengeOf v = case parseMaybe (withObject "options" (.: "challenge")) v of
    Just c -> c
    Nothing -> error "challengeOf: no challenge in options"

cid1, uh1, pk1 :: ByteString
cid1 = "passkey-cred-1"
uh1 = "passkey-uh-1"
pk1 = "passkey-pk-1"

-- | A credential JSON the fake accepts: it echoes the challenge and carries base64url bytes.
credentialJson :: Text -> Value
credentialJson chal =
    object
        [ "challenge" .= chal
        , "credentialId" .= WebAuthnCredentialId cid1
        , "userHandle" .= UserHandle uh1
        , "publicKey" .= PublicKeyBytes pk1
        ]

mustRight :: (Show e) => Either e a -> IO a
mustRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

enrollListRemove :: IO ()
enrollListRemove = do
    ref <- newWorld
    uid <- seedUser ref
    (cid, opts) <- mustRight =<< runInMemory ref (beginPasskeyRegistration cfg uid)
    pk <- mustRight =<< runInMemory ref (completePasskeyRegistration cfg uid cid (credentialJson (challengeOf opts)) (Just "YubiKey"))
    pkLabel pk @?= Just "YubiKey"
    -- list returns exactly the enrolled passkey
    listed <- runInMemory ref (listPasskeys uid)
    map pkPasskeyId listed @?= [pkPasskeyId pk]
    -- remove deletes it
    _ <- mustRight =<< runInMemory ref (removePasskey uid (pkPasskeyId pk))
    listed2 <- runInMemory ref (listPasskeys uid)
    map pkPasskeyId listed2 @?= []

wrongUserComplete :: IO ()
wrongUserComplete = do
    ref <- newWorld
    uid <- seedUser ref
    otherUid <- genUserId
    (cid, opts) <- mustRight =<< runInMemory ref (beginPasskeyRegistration cfg uid)
    result <- runInMemory ref (completePasskeyRegistration cfg otherUid cid (credentialJson (challengeOf opts)) Nothing)
    result @?= Left PendingCeremonyNotFound

absentCeremony :: IO ()
absentCeremony = do
    ref <- newWorld
    uid <- seedUser ref
    bogusCid <- genCeremonyId
    result <- runInMemory ref (completePasskeyRegistration cfg uid bogusCid (credentialJson "anything") Nothing)
    result @?= Left PendingCeremonyNotFound

consumedCeremony :: IO ()
consumedCeremony = do
    ref <- newWorld
    uid <- seedUser ref
    (cid, opts) <- mustRight =<< runInMemory ref (beginPasskeyRegistration cfg uid)
    _ <- mustRight =<< runInMemory ref (completePasskeyRegistration cfg uid cid (credentialJson (challengeOf opts)) Nothing)
    -- the ceremony was consumed by the first complete; a second is rejected
    again <- runInMemory ref (completePasskeyRegistration cfg uid cid (credentialJson (challengeOf opts)) Nothing)
    again @?= Left PendingCeremonyNotFound

rejectedCredential :: IO ()
rejectedCredential = do
    ref <- newWorld
    uid <- seedUser ref
    (cid, _opts) <- mustRight =<< runInMemory ref (beginPasskeyRegistration cfg uid)
    -- a credential whose challenge does not match the ceremony fails verification
    result <- runInMemory ref (completePasskeyRegistration cfg uid cid (credentialJson "not-the-challenge") Nothing)
    result @?= Left (WebAuthnCeremonyError WebAuthnChallengeMismatch)
