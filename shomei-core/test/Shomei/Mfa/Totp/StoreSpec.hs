{-# LANGUAGE DataKinds #-}

-- | Pure tests for the in-memory EP-7 stores
-- ('Shomei.Test.InMemory.runTotpCredentialStore' and 'runRecoveryCodeStore'), proving the
-- persistence contract the TOTP workflows build on against the fake 'World'. The same behavior
-- is re-proven against real PostgreSQL by @shomei-postgres@'s integration test (including the
-- AES-256-GCM round-trip, which the in-memory interpreter does not exercise).
module Shomei.Mfa.Totp.StoreSpec (tests) where

import Data.IORef (IORef, newIORef)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, (:>))
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.User.Domain (NewUser (..), User (..))
import Shomei.Account.User.Store (UserStore, createUser)
import Shomei.Id (genRecoveryCodeId, genTotpCredentialId, genUserId)
import Shomei.Id qualified as Id
import Shomei.Mfa.RecoveryCode.Store
  ( consumeRecoveryCode,
    countUnusedRecoveryCodes,
    replaceRecoveryCodes,
  )
import Shomei.Mfa.Totp.Algorithm (TotpSecret (..))
import Shomei.Mfa.Totp.Domain (NewRecoveryCode (..), NewTotpCredential (..), TotpCredential (..))
import Shomei.Mfa.Totp.Store
  ( confirmTotp,
    deleteTotpByUser,
    findTotpByUser,
    setTotpLastUsedCounter,
    upsertTotpEnrollment,
  )
import Shomei.Session.Authentication.Guard (AuthenticationGuard (..))
import Shomei.Test.InMemory (World, emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 7 10) 0

newWorld :: IO (IORef World)
newWorld = newIORef (emptyWorld t0)

rawSecret :: TotpSecret
rawSecret = TotpSecret "12345678901234567890"

tcConfirmedAt :: TotpCredential -> Maybe UTCTime
tcConfirmedAt TotpCredential {confirmedAt} = confirmedAt

tcLastUsedCounter :: TotpCredential -> Maybe Int64
tcLastUsedCounter TotpCredential {lastUsedCounter} = lastUsedCounter

tcSecret :: TotpCredential -> TotpSecret
tcSecret TotpCredential {secret} = secret

tests :: TestTree
tests =
  testGroup
    "TOTP + recovery-code stores (in-memory)"
    [ testCase "totp: enroll, find, confirm, counter, delete" totpRoundTrip,
      testCase "totp: re-enroll replaces the unconfirmed row" totpReenrollReplaces,
      testCase "recovery: replace-set, consume-once, count drops, regenerate replaces" recoveryCas
    ]

totpRoundTrip :: IO ()
totpRoundTrip = do
  ref <- newWorld
  (created, found0, advanced, replayed, older, found1, found2) <- runInMemory ref do
    u <- newUserId
    tcid <- genTotpCredentialId
    created <- either (error . show) pure =<< upsertTotpEnrollment (AuthenticationGuard 0 Nothing Nothing) NewTotpCredential {totpCredentialId = tcid, userId = u, secret = rawSecret, createdAt = t0}
    found0 <- findTotpByUser u
    confirmTotp u (AuthenticationGuard 0 Nothing Nothing) tcid t0
    advanced <- setTotpLastUsedCounter tcid 42
    replayed <- setTotpLastUsedCounter tcid 42
    older <- setTotpLastUsedCounter tcid 41
    found1 <- findTotpByUser u
    deleteTotpByUser u
    found2 <- findTotpByUser u
    pure (created, found0, advanced, replayed, older, found1, found2)
  tcSecret created @?= rawSecret
  fmap tcConfirmedAt found0 @?= Just Nothing
  (advanced, replayed, older) @?= (True, False, False)
  fmap (isJust . tcConfirmedAt) found1 @?= Just True
  fmap tcLastUsedCounter found1 @?= Just (Just 42)
  found2 @?= Nothing

totpReenrollReplaces :: IO ()
totpReenrollReplaces = do
  ref <- newWorld
  (found, secondId) <- runInMemory ref do
    u <- newUserId
    tcid1 <- genTotpCredentialId
    _ <- either (error . show) pure =<< upsertTotpEnrollment (AuthenticationGuard 0 Nothing Nothing) NewTotpCredential {totpCredentialId = tcid1, userId = u, secret = rawSecret, createdAt = t0}
    tcid2 <- genTotpCredentialId
    second <- either (error . show) pure =<< upsertTotpEnrollment (AuthenticationGuard 0 Nothing Nothing) NewTotpCredential {totpCredentialId = tcid2, userId = u, secret = TotpSecret "09876543210987654321", createdAt = t0}
    found <- findTotpByUser u
    pure (found, second.totpCredentialId)
  -- Only one credential per user: the re-enrollment's id is what a lookup now returns.
  fmap (.totpCredentialId) found @?= Just secondId

recoveryCas :: IO ()
recoveryCas = do
  ref <- newWorld
  (countBefore, firstConsume, secondConsume, countAfter, countAfterReplace, oldConsume) <- runInMemory ref do
    u <- newUserId
    ids <- mapM (const genRecoveryCodeId) [1 :: Int, 2, 3]
    let mk i h = NewRecoveryCode {recoveryCodeId = i, codeHash = h, createdAt = t0}
    replaceRecoveryCodes u (AuthenticationGuard 0 Nothing Nothing) t0 (zipWith mk ids ["h1", "h2", "h3"])
    countBefore <- countUnusedRecoveryCodes u
    firstConsume <- consumeRecoveryCode u "h1" t0
    secondConsume <- consumeRecoveryCode u "h1" t0
    countAfter <- countUnusedRecoveryCodes u
    ids2 <- mapM (const genRecoveryCodeId) [1 :: Int, 2]
    replaceRecoveryCodes u (AuthenticationGuard 0 Nothing Nothing) t0 (zipWith mk ids2 ["n1", "n2"])
    countAfterReplace <- countUnusedRecoveryCodes u
    oldConsume <- consumeRecoveryCode u "h2" t0
    pure (countBefore, firstConsume, secondConsume, countAfter, countAfterReplace, oldConsume)
  countBefore @?= 3
  firstConsume @?= True
  secondConsume @?= False
  countAfter @?= 2
  countAfterReplace @?= 2
  oldConsume @?= False

-- Store fixtures use real users so user-row serialization has the same preconditions as SQL.
newUserId :: (UserStore :> es, IOE :> es) => Eff es Id.UserId
newUserId = do
  unique <- genUserId
  let lid = either (error . show) id (mkLoginId (Id.idText unique))
  user <- createUser (NewUser lid Nothing Nothing)
  pure user.userId
