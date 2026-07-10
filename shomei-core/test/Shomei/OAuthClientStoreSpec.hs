{-# LANGUAGE DataKinds #-}

-- | Pure tests for the in-memory 'Shomei.Effect.OAuthClientStore' interpreter
-- ('Shomei.Effect.InMemory.runOAuthClientStore').
--
-- They prove the persistence contract EP-5's authorization-code flow builds on, against the fake
-- 'World': a client can be created and found by its client id; a public client stores no secret
-- hash at all; a client can be revoked (status flips, @revoked_at@ is stamped, and the row
-- survives so the lookup still resolves and the authorize endpoint can refuse it); and the
-- listing is newest-first. The same behavior is re-proven against real PostgreSQL by
-- @shomei-postgres@'s integration test.
--
-- 'isRegisteredRedirectUri' is tested here too: it is the single rule that keeps
-- @GET \/oauth\/authorize@ from being an open redirector, and it is pure.
module Shomei.OAuthClientStoreSpec (tests) where

import Control.Monad.IO.Class (MonadIO)
import Data.IORef (IORef, newIORef)
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Domain.Claims (Scope (..))
import Shomei.Domain.OAuthClient
  ( ClientType (..),
    NewOAuthClient (..),
    OAuthClient (..),
    OAuthClientStatus (..),
    isRegisteredRedirectUri,
  )
import Shomei.Effect.InMemory (World, emptyWorld, runInMemory)
import Shomei.Effect.OAuthClientStore
  ( createOAuthClient,
    findOAuthClientByClientId,
    listOAuthClients,
    revokeOAuthClient,
  )
import Shomei.Id (OAuthClientId, genOAuthClientId, idText)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "OAuthClientStore (in-memory)"
    [ testCase "create then find by client id" createAndFind,
      testCase "a public client stores no secret hash" publicClientHasNoSecret,
      testCase "find by an unknown client id returns Nothing" findUnknown,
      testCase "revoke flips status, stamps revoked_at, and keeps the row" revoke,
      testCase "list is newest-first" listNewestFirst,
      testCase "a redirect uri matches only by exact string equality" redirectUriExactMatch
    ]

-- Field accessors: OverloadedRecordDot is unreliable for these DuplicateRecordFields
-- records (MasterPlan 3 discovery), so read them by record-pattern matching.

ocStatus :: OAuthClient -> OAuthClientStatus
ocStatus OAuthClient {status} = status

ocSecretHash :: OAuthClient -> Maybe Text
ocSecretHash OAuthClient {secretHash} = secretHash

ocRevokedAt :: OAuthClient -> Maybe UTCTime
ocRevokedAt OAuthClient {revokedAt} = revokedAt

ocClientId :: OAuthClient -> Text
ocClientId OAuthClient {clientId} = clientId

ocAllowedScopes :: OAuthClient -> Set Scope
ocAllowedScopes OAuthClient {allowedScopes} = allowedScopes

ocId :: OAuthClient -> OAuthClientId
ocId OAuthClient {oauthClientId} = oauthClientId

ocDisplayName :: OAuthClient -> Text
ocDisplayName OAuthClient {displayName} = displayName

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 7 10) 0

newWorld :: IO (IORef World)
newWorld = newIORef (emptyWorld t0)

openidScope :: Set Scope
openidScope = Set.singleton (Scope "openid")

callbackUri :: Text
callbackUri = "https://app.example.com/callback"

-- | Build a 'NewOAuthClient' whose @client_id@ is its id's TypeID text, exactly as the CLI does.
mkNew :: (MonadIO m) => ClientType -> UTCTime -> Text -> m NewOAuthClient
mkNew clientType createdAt displayName = do
  ocid <- genOAuthClientId
  pure
    NewOAuthClient
      { oauthClientId = ocid,
        clientId = idText ocid,
        secretHash = case clientType of
          ConfidentialClient -> Just "hash-one"
          PublicClient -> Nothing,
        clientType,
        displayName,
        redirectUris = [callbackUri],
        allowedScopes = openidScope,
        createdAt
      }

createAndFind :: IO ()
createAndFind = do
  ref <- newWorld
  (created, found) <- runInMemory ref do
    new <- mkNew ConfidentialClient t0 "grafana"
    created <- createOAuthClient new
    found <- findOAuthClientByClientId (ocClientId created)
    pure (created, found)
  ocStatus created @?= OAuthClientActive
  ocRevokedAt created @?= Nothing
  ocSecretHash created @?= Just "hash-one"
  ocAllowedScopes created @?= openidScope
  fmap ocId found @?= Just (ocId created)

-- | A public client is issued no secret, rather than one that is stored and never checked.
publicClientHasNoSecret :: IO ()
publicClientHasNoSecret = do
  ref <- newWorld
  found <- runInMemory ref do
    new <- mkNew PublicClient t0 "spa"
    created <- createOAuthClient new
    findOAuthClientByClientId (ocClientId created)
  fmap ocSecretHash found @?= Just Nothing

findUnknown :: IO ()
findUnknown = do
  ref <- newWorld
  found <- runInMemory ref (findOAuthClientByClientId "oauthclient_nope")
  assertBool "unknown client id must not resolve" (isNothing found)

revoke :: IO ()
revoke = do
  ref <- newWorld
  let revokedTime = addUTCTime 7200 t0
  found <- runInMemory ref do
    new <- mkNew ConfidentialClient t0 "grafana"
    created <- createOAuthClient new
    revokeOAuthClient (ocId created) revokedTime
    -- The row survives revocation: the authorize endpoint must be able to see that this client
    -- exists and is revoked, so it refuses without redirecting.
    findOAuthClientByClientId (ocClientId created)
  fmap ocStatus found @?= Just OAuthClientRevoked
  fmap ocRevokedAt found @?= Just (Just revokedTime)

listNewestFirst :: IO ()
listNewestFirst = do
  ref <- newWorld
  clients <- runInMemory ref do
    older <- mkNew ConfidentialClient t0 "older"
    newer <- mkNew PublicClient (addUTCTime 60 t0) "newer"
    _ <- createOAuthClient older
    _ <- createOAuthClient newer
    listOAuthClients
  map ocDisplayName clients @?= ["newer", "older"]

-- | Every near-miss here is an open-redirector attempt: a prefix match, a suffix match, a
-- traversal, and a trailing slash all name a target the operator never registered.
redirectUriExactMatch :: IO ()
redirectUriExactMatch = do
  ref <- newWorld
  client <- runInMemory ref (createOAuthClient =<< mkNew ConfidentialClient t0 "grafana")
  assertBool "the registered uri matches" (isRegisteredRedirectUri client callbackUri)
  mapM_
    (\uri -> assertBool ("must not match: " <> show uri) (not (isRegisteredRedirectUri client uri)))
    [ "https://app.example.com/callback/",
      "https://app.example.com/callback/../evil",
      "https://app.example.com/callback?x=1",
      "https://app.example.com.evil.test/callback",
      "https://evil.test/https://app.example.com/callback",
      "http://app.example.com/callback"
    ]
