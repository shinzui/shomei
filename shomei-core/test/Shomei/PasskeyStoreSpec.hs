{-# LANGUAGE DataKinds #-}

{- | Pure tests for the in-memory 'Shomei.Effect.PasskeyStore' and
'Shomei.Effect.PendingCeremonyStore' interpreters
('Shomei.Effect.InMemory.runPasskeyStore' / 'runPendingCeremonyStore').

They prove the persistence contract EP-3/EP-4 build on, against the fake 'World':
a credential can be created and found three ways (by user, by credential id, by user
handle), its signature counter and last-used timestamp bumped, counted per user, and
deleted only by its owning user; and a pending ceremony is consumed exactly once and
never returned after it has expired. No database is involved — the same behavior is
re-proven against real PostgreSQL by @shomei-postgres@'s integration test.
-}
module Shomei.PasskeyStoreSpec (tests) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Shomei.Domain.Passkey (
    CeremonyKind (..),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
 )
import Shomei.Effect.InMemory (World, emptyWorld, runInMemory)
import Shomei.Effect.PasskeyStore (
    countPasskeysByUser,
    createPasskey,
    deletePasskey,
    findPasskeyByCredentialId,
    findPasskeysByUser,
    findPasskeysByUserHandle,
    updatePasskeySignCounter,
 )
import Shomei.Effect.PendingCeremonyStore (putPendingCeremony, takePendingCeremony)
import Shomei.Id (CeremonyId, PasskeyId, UserId, genCeremonyId, genUserId)

tests :: TestTree
tests =
    testGroup
        "PasskeyStore (in-memory)"
        [ testCase "create + find by user/credential-id/user-handle" createAndFind
        , testCase "update sign counter sets counter and last_used_at" updateSignCounter
        , testCase "count passkeys by user" countByUser
        , testCase "delete is scoped to the owning user" userScopedDelete
        , testGroup
            "PendingCeremony (in-memory)"
            [ testCase "put then take returns the row exactly once" consumeOnce
            , testCase "take of an expired ceremony returns Nothing" expiredTake
            ]
        ]

-- Field accessors: OverloadedRecordDot is unreliable for these DuplicateRecordFields
-- records (MasterPlan 3 discovery), so read via plain record-pattern matching.

pkPasskeyId :: PasskeyCredential -> PasskeyId
pkPasskeyId PasskeyCredential{passkeyId} = passkeyId

pkSignCounter :: PasskeyCredential -> SignatureCounter
pkSignCounter PasskeyCredential{signCounter} = signCounter

pkLastUsedAt :: PasskeyCredential -> Maybe UTCTime
pkLastUsedAt PasskeyCredential{lastUsedAt} = lastUsedAt

pkTransports :: PasskeyCredential -> [Text]
pkTransports PasskeyCredential{transports} = transports

pkLabel :: PasskeyCredential -> Maybe Text
pkLabel PasskeyCredential{label} = label

pkCreatedAt :: PasskeyCredential -> UTCTime
pkCreatedAt PasskeyCredential{createdAt} = createdAt

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

t1 :: UTCTime
t1 = addUTCTime 60 t0

cid1, uh1, pk1 :: ByteString
cid1 = "cred-1"
uh1 = "uh-1"
pk1 = "pk-1"

newWorld :: IO (IORef World)
newWorld = newIORef (emptyWorld t0)

-- | A 'NewPasskeyCredential' for the given user with the canned test bytes.
sampleNew :: UserId -> NewPasskeyCredential
sampleNew uid =
    NewPasskeyCredential
        { userId = uid
        , credentialId = WebAuthnCredentialId cid1
        , userHandle = UserHandle uh1
        , publicKey = PublicKeyBytes pk1
        , signCounter = SignatureCounter 0
        , transports = ["internal", "hybrid"]
        , label = Just "My YubiKey"
        , createdAt = t0
        }

-- | Like 'sampleNew' but with a distinct credential id (avoids ambiguous record-update syntax).
sampleNewWithCred :: UserId -> ByteString -> NewPasskeyCredential
sampleNewWithCred uid cidBytes =
    NewPasskeyCredential
        { userId = uid
        , credentialId = WebAuthnCredentialId cidBytes
        , userHandle = UserHandle uh1
        , publicKey = PublicKeyBytes pk1
        , signCounter = SignatureCounter 0
        , transports = ["internal", "hybrid"]
        , label = Just "My YubiKey"
        , createdAt = t0
        }

createAndFind :: IO ()
createAndFind = do
    ref <- newWorld
    uid <- genUserId
    (created, byUser, byCred, byHandle) <- runInMemory ref do
        created <- createPasskey (sampleNew uid)
        byUser <- findPasskeysByUser uid
        byCred <- findPasskeyByCredentialId (WebAuthnCredentialId cid1)
        byHandle <- findPasskeysByUserHandle (UserHandle uh1)
        pure (created, byUser, byCred, byHandle)
    -- the round-tripped metadata survives unchanged
    pkTransports created @?= ["internal", "hybrid"]
    pkLabel created @?= Just "My YubiKey"
    pkSignCounter created @?= SignatureCounter 0
    pkCreatedAt created @?= t0
    pkLastUsedAt created @?= Nothing
    -- all three lookups resolve to the same passkey
    map pkPasskeyId byUser @?= [pkPasskeyId created]
    fmap pkPasskeyId byCred @?= Just (pkPasskeyId created)
    map pkPasskeyId byHandle @?= [pkPasskeyId created]

updateSignCounter :: IO ()
updateSignCounter = do
    ref <- newWorld
    uid <- genUserId
    found <- runInMemory ref do
        created <- createPasskey (sampleNew uid)
        updatePasskeySignCounter (pkPasskeyId created) (SignatureCounter 7) t1
        findPasskeyByCredentialId (WebAuthnCredentialId cid1)
    fmap pkSignCounter found @?= Just (SignatureCounter 7)
    fmap pkLastUsedAt found @?= Just (Just t1)

countByUser :: IO ()
countByUser = do
    ref <- newWorld
    uid <- genUserId
    otherUid <- genUserId
    n <- runInMemory ref do
        _ <- createPasskey (sampleNew uid)
        -- a second passkey for the same user (distinct credential id)
        _ <- createPasskey (sampleNewWithCred uid "cred-2")
        -- a third for a different user
        _ <- createPasskey (sampleNewWithCred otherUid "cred-3")
        countPasskeysByUser uid
    n @?= 2

userScopedDelete :: IO ()
userScopedDelete = do
    ref <- newWorld
    uid <- genUserId
    otherUid <- genUserId
    (afterWrongUser, afterOwner) <- runInMemory ref do
        created <- createPasskey (sampleNew uid)
        let pid = pkPasskeyId created
        deletePasskey otherUid pid -- wrong user: no-op
        afterWrongUser <- findPasskeyByCredentialId (WebAuthnCredentialId cid1)
        deletePasskey uid pid -- owner: removes it
        afterOwner <- findPasskeyByCredentialId (WebAuthnCredentialId cid1)
        pure (afterWrongUser, afterOwner)
    assertBool "wrong-user delete leaves the passkey present" (maybe False (const True) afterWrongUser)
    assertBool "owner delete removes the passkey" (isNothing afterOwner)

samplePending :: CeremonyId -> UTCTime -> PendingCeremony
samplePending cid expiry =
    PendingCeremony
        { ceremonyId = cid
        , userId = Nothing
        , kind = RegistrationCeremony
        , optionsBlob = "{\"challenge\":\"abc\"}"
        , createdAt = t0
        , expiresAt = expiry
        }

consumeOnce :: IO ()
consumeOnce = do
    ref <- newWorld
    cid <- genCeremonyId
    (first, second) <- runInMemory ref do
        putPendingCeremony (samplePending cid (addUTCTime 300 t0))
        first <- takePendingCeremony cid t0
        second <- takePendingCeremony cid t0
        pure (first, second)
    assertBool "first take returns the ceremony" (maybe False (const True) first)
    assertBool "second take returns Nothing" (isNothing second)

expiredTake :: IO ()
expiredTake = do
    ref <- newWorld
    cid <- genCeremonyId
    (firstTake, afterTake) <- runInMemory ref do
        putPendingCeremony (samplePending cid (addUTCTime 60 t0))
        -- "now" is past expiry: returns Nothing and removes the stale row
        firstTake <- takePendingCeremony cid (addUTCTime 120 t0)
        afterTake <- takePendingCeremony cid (addUTCTime 120 t0)
        pure (firstTake, afterTake)
    assertBool "expired take returns Nothing" (isNothing firstTake)
    assertBool "subsequent take also Nothing" (isNothing afterTake)
