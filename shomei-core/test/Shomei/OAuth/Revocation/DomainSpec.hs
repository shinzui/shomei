module Shomei.OAuth.Revocation.DomainSpec (tests) where

import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian)
import Shomei.Authorization.Claims.Domain (Scope (..))
import Shomei.Authorization.Scope.Domain (adminScope)
import Shomei.Id (UserId, genServiceAccountDbId, genSessionId, genUserId, idText)
import Shomei.OAuth.Revocation.Domain (RevocationCaller (..), mayRevokeSession)
import Shomei.ServiceAccount.Domain (ServiceAccount (..), ServiceAccountStatus (ServiceAccountActive))
import Shomei.Session.Domain (Session (..), SessionKind (InteractiveSession), SessionStatus (SessionActive))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.OAuth.Revocation.Domain"
    [ testCase "an OAuth client owns a session minted under its client_id" $ withPrincipals \_ _ session ->
        mayRevokeSession (RevokingOAuthClient "oauthclient_owner") session @?= True,
      testCase "an OAuth client does not own another client's session" $ withPrincipals \_ _ session ->
        mayRevokeSession (RevokingOAuthClient "oauthclient_other") session @?= False,
      testCase "a service account owns a session whose subject is its backing user" $ withPrincipals \account _ session ->
        mayRevokeSession (RevokingServiceAccount account) session {userId = account.userId, oauthClientId = Nothing} @?= True,
      testCase "a service account owns a delegated session whose actor is its backing user" $ withPrincipals \account subject session ->
        mayRevokeSession (RevokingServiceAccount account) session {userId = subject, actor = Just account.userId, oauthClientId = Nothing} @?= True,
      testCase "an ordinary service account cannot revoke an unrelated session" $ withPrincipals \account _ session ->
        mayRevokeSession (RevokingServiceAccount account) session @?= False,
      testCase "a service account holding shomei:admin may revoke every session" $ withPrincipals \account _ session ->
        mayRevokeSession (RevokingServiceAccount account {allowedScopes = Set.singleton adminScope}) session @?= True
    ]

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 27) 0

withPrincipals :: (ServiceAccount -> UserId -> Session -> IO ()) -> IO ()
withPrincipals assertion = do
  accountUser <- genUserId
  subjectUser <- genUserId
  sessionUser <- genUserId
  serviceAccountId <- genServiceAccountDbId
  sessionId <- genSessionId
  let account =
        ServiceAccount
          { serviceAccountId,
            clientId = idText serviceAccountId,
            userId = accountUser,
            secretHash = "digest",
            displayName = "caller",
            allowedScopes = Set.singleton (Scope "kawa:ingest"),
            status = ServiceAccountActive,
            createdAt = t0,
            rotatedAt = Nothing,
            revokedAt = Nothing
          }
      session =
        Session
          { sessionId,
            userId = sessionUser,
            status = SessionActive,
            createdAt = t0,
            expiresAt = t0,
            revokedAt = Nothing,
            actor = Nothing,
            oauthClientId = Just "oauthclient_owner",
            kind = InteractiveSession,
            grantedScopes = Set.empty,
            authenticatedAt = t0
          }
  assertion account subjectUser session
