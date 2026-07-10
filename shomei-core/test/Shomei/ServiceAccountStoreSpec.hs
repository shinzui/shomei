{-# LANGUAGE DataKinds #-}

-- | Pure tests for the in-memory 'Shomei.Effect.ServiceAccountStore' interpreter
-- ('Shomei.Effect.InMemory.runServiceAccountStore').
--
-- They prove the persistence contract EP-4's @client_credentials@ grant builds on, against the
-- fake 'World': an account can be created and found by its client id; its secret can be rotated
-- (the new hash is what a later lookup sees, and @rotated_at@ is stamped); it can be revoked
-- (status flips, @revoked_at@ is stamped, and the row survives so the lookup still resolves);
-- and the listing is newest-first. No database is involved — the same behavior is re-proven
-- against real PostgreSQL by @shomei-postgres@'s integration test.
--
-- Each case runs its port actions inside 'runInMemory' and asserts on the returned values in
-- 'IO', which is how the sibling 'Shomei.PasskeyStoreSpec' is written.
module Shomei.ServiceAccountStoreSpec (tests) where

import Control.Monad.IO.Class (MonadIO)
import Data.IORef (IORef, newIORef)
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Domain.Claims (Scope (..))
import Shomei.Domain.ServiceAccount
  ( NewServiceAccount (..),
    ServiceAccount (..),
    ServiceAccountStatus (..),
  )
import Shomei.Effect.InMemory (World, emptyWorld, runInMemory)
import Shomei.Effect.ServiceAccountStore
  ( createServiceAccount,
    findServiceAccountByClientId,
    listServiceAccounts,
    revokeServiceAccount,
    rotateServiceAccountSecret,
  )
import Shomei.Id (ServiceAccountDbId, UserId, genServiceAccountDbId, genUserId, idText)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ServiceAccountStore (in-memory)"
    [ testCase "create then find by client id" createAndFind,
      testCase "find by an unknown client id returns Nothing" findUnknown,
      testCase "rotate replaces the hash and stamps rotated_at" rotateSecret,
      testCase "revoke flips status, stamps revoked_at, and keeps the row" revoke,
      testCase "list is newest-first" listNewestFirst
    ]

-- Field accessors: OverloadedRecordDot is unreliable for these DuplicateRecordFields
-- records (MasterPlan 3 discovery), so read them by record-pattern matching.

saStatus :: ServiceAccount -> ServiceAccountStatus
saStatus ServiceAccount {status} = status

saSecretHash :: ServiceAccount -> Text
saSecretHash ServiceAccount {secretHash} = secretHash

saRotatedAt :: ServiceAccount -> Maybe UTCTime
saRotatedAt ServiceAccount {rotatedAt} = rotatedAt

saRevokedAt :: ServiceAccount -> Maybe UTCTime
saRevokedAt ServiceAccount {revokedAt} = revokedAt

saClientId :: ServiceAccount -> Text
saClientId ServiceAccount {clientId} = clientId

saAllowedScopes :: ServiceAccount -> Set Scope
saAllowedScopes ServiceAccount {allowedScopes} = allowedScopes

saId :: ServiceAccount -> ServiceAccountDbId
saId ServiceAccount {serviceAccountId} = serviceAccountId

saDisplayName :: ServiceAccount -> Text
saDisplayName ServiceAccount {displayName} = displayName

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 7 10) 0

newWorld :: IO (IORef World)
newWorld = newIORef (emptyWorld t0)

ingestScope :: Set Scope
ingestScope = Set.singleton (Scope "kawa:ingest")

-- | Build a 'NewServiceAccount' whose @client_id@ is its id's TypeID text, exactly as the CLI
-- does. Runs in any 'MonadIO' so it can be called straight from an 'Eff' block.
mkNew :: (MonadIO m) => UserId -> UTCTime -> Text -> m NewServiceAccount
mkNew uid createdAt displayName = do
  said <- genServiceAccountDbId
  pure
    NewServiceAccount
      { serviceAccountId = said,
        clientId = idText said,
        userId = uid,
        secretHash = "hash-one",
        displayName,
        allowedScopes = ingestScope,
        createdAt
      }

createAndFind :: IO ()
createAndFind = do
  ref <- newWorld
  (created, found) <- runInMemory ref do
    uid <- genUserId
    new <- mkNew uid t0 "rei connector"
    created <- createServiceAccount new
    found <- findServiceAccountByClientId (saClientId created)
    pure (created, found)
  saStatus created @?= ServiceAccountActive
  saRotatedAt created @?= Nothing
  saRevokedAt created @?= Nothing
  saAllowedScopes created @?= ingestScope
  fmap saId found @?= Just (saId created)

findUnknown :: IO ()
findUnknown = do
  ref <- newWorld
  found <- runInMemory ref (findServiceAccountByClientId "svcacct_nope")
  assertBool "unknown client id must not resolve" (isNothing found)

rotateSecret :: IO ()
rotateSecret = do
  ref <- newWorld
  let rotatedTime = addUTCTime 3600 t0
  found <- runInMemory ref do
    uid <- genUserId
    new <- mkNew uid t0 "rei connector"
    created <- createServiceAccount new
    rotateServiceAccountSecret (saId created) "hash-two" rotatedTime
    findServiceAccountByClientId (saClientId created)
  fmap saSecretHash found @?= Just "hash-two"
  fmap saRotatedAt found @?= Just (Just rotatedTime)
  -- Rotation does not revoke.
  fmap saStatus found @?= Just ServiceAccountActive

revoke :: IO ()
revoke = do
  ref <- newWorld
  let revokedTime = addUTCTime 7200 t0
  found <- runInMemory ref do
    uid <- genUserId
    new <- mkNew uid t0 "rei connector"
    created <- createServiceAccount new
    revokeServiceAccount (saId created) revokedTime
    -- The row survives revocation: the grant workflow must be able to see that this client
    -- exists and is revoked, so it can refuse it exactly as it refuses a wrong secret.
    findServiceAccountByClientId (saClientId created)
  fmap saStatus found @?= Just ServiceAccountRevoked
  fmap saRevokedAt found @?= Just (Just revokedTime)

listNewestFirst :: IO ()
listNewestFirst = do
  ref <- newWorld
  accounts <- runInMemory ref do
    uid <- genUserId
    older <- mkNew uid t0 "older"
    newer <- mkNew uid (addUTCTime 60 t0) "newer"
    _ <- createServiceAccount older
    _ <- createServiceAccount newer
    listServiceAccounts
  map saDisplayName accounts @?= ["newer", "older"]
