-- | Unit tests for the EP-4 @client_credentials@ grant over database-backed service accounts,
-- run against the in-memory interpreters with a fixed clock and a fake signer.
--
-- The security-relevant property these pin down: an unknown @client_id@, a wrong secret, a
-- revoked account, and an inactive backing user all yield exactly 'OAuthClientInvalid'. A caller
-- must not be able to tell them apart.
module Shomei.Workflow.ClientCredentialsSpec (tests) where

import Data.Aeson (eitherDecode)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Config (ServiceAccountId (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginId (LoginId, mkLoginId)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..))
import Shomei.Domain.ServiceAccount (NewServiceAccount (..), ServiceAccount (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..), UserStatus (UserSuspended))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Effect.ServiceAccountStore (createServiceAccount, revokeServiceAccount)
import Shomei.Effect.UserStore (updateUserStatus)
import Shomei.Error (AuthError (..))
import Shomei.Id (ServiceAccountDbId, UserId, genServiceAccountDbId, idText)
import Shomei.Prelude
import Shomei.Workflow (signup)
import Shomei.Workflow.ClientCredentials (ClientCredentialsGrant (..), GrantedToken (..), grantClientCredentials)
import Shomei.Workflow.ServiceToken (sha256Hex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

baseCfg :: ShomeiConfig
baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

clientSecret' :: Text
clientSecret' = "test-secret"

ingestScope, signalScope, egressScope :: Scope
ingestScope = Scope "kawa:ingest"
signalScope = Scope "signal:raise"
egressScope = Scope "channel:egress"

allowedScopes' :: Set Scope
allowedScopes' = Set.fromList [ingestScope, signalScope]

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

decodeAccess :: AccessToken -> IO AuthClaims
decodeAccess (AccessToken t) =
  either
    (\e -> assertFailure ("could not decode access token: " <> e))
    pure
    (eitherDecode (TLE.encodeUtf8 (TL.fromStrict t)))

mkLoginId' :: Text -> LoginId
mkLoginId' t = either (\e -> error ("bad test login id: " <> show e)) id (mkLoginId t)

-- | The backing user every service account needs: 'AuthClaims.subject' is a 'UserId', and a
-- session cannot exist without one.
seedUser :: IORef World -> Text -> IO User
seedUser ref name = do
  let loginId = mkLoginId' name
      email = either (\e -> error ("bad test email: " <> show e)) id (mkEmail (name <> "@example.com"))
  (user, _) <-
    expectRight
      =<< runInMemory
        ref
        (signup baseCfg SignupCommand {loginId, email = Just email, password = strongPw, displayName = Just name})
  pure user

-- | Seed an active service account whose @client_id@ is its id's TypeID text.
seedAccount :: IORef World -> UserId -> IO ServiceAccount
seedAccount ref uid = runInMemory ref do
  said <- genServiceAccountDbId
  createServiceAccount
    NewServiceAccount
      { serviceAccountId = said,
        clientId = idText said,
        userId = uid,
        secretHash = sha256Hex clientSecret',
        displayName = "rei connector",
        allowedScopes = allowedScopes',
        createdAt = fixedTime
      }

saClientId :: ServiceAccount -> Text
saClientId ServiceAccount {clientId} = clientId

saId :: ServiceAccount -> ServiceAccountDbId
saId ServiceAccount {serviceAccountId} = serviceAccountId

-- | A grant request naming the given account, with the correct secret and no @scope@ parameter.
grantFor :: ServiceAccount -> ClientCredentialsGrant
grantFor account =
  ClientCredentialsGrant
    { clientId = saClientId account,
      clientSecret = clientSecret',
      requestedScopes = Nothing
    }

-- | Seed a user and an account, then run one grant against them.
withAccount :: (ServiceAccount -> ClientCredentialsGrant) -> IO (IORef World, Either AuthError GrantedToken)
withAccount mkGrant = do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  account <- seedAccount ref serviceUser.userId
  res <- runInMemory ref (grantClientCredentials baseCfg (mkGrant account))
  pure (ref, res)

tests :: TestTree
tests =
  testGroup
    "Shomei.Workflow.ClientCredentials"
    [ testOmittedScopeGrantsAll,
      testRequestedScopeSubset,
      testUnknownClient,
      testWrongSecret,
      testRevokedAccount,
      testInactiveBackingUser,
      testScopeOutsideAllowList,
      testEmptyScopeSet,
      testNoRefreshToken,
      testFailureDoesNotMint
    ]

testOmittedScopeGrantsAll :: TestTree
testOmittedScopeGrantsAll = testCase "an omitted scope parameter grants every allowed scope" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  account <- seedAccount ref serviceUser.userId
  granted <- expectRight =<< runInMemory ref (grantClientCredentials baseCfg (grantFor account))
  granted.grantedScopes @?= allowedScopes'
  -- the default TTL for machine tokens, shared with the config-defined path
  granted.expiresIn @?= 300
  claims <- decodeAccess granted.accessToken
  claims.subject @?= serviceUser.userId
  claims.scopes @?= allowedScopes'
  claims.expiresAt @?= addUTCTime 300 fixedTime
  -- client_credentials is not a delegation: there is no actor on behalf of whom it acts
  claims.actor @?= Nothing

testRequestedScopeSubset :: TestTree
testRequestedScopeSubset = testCase "a requested subset is granted, and echoed back" do
  (_, res) <- withAccount \a -> (grantFor a) {requestedScopes = Just (Set.singleton ingestScope)}
  granted <- expectRight res
  granted.grantedScopes @?= Set.singleton ingestScope
  claims <- decodeAccess granted.accessToken
  claims.scopes @?= Set.singleton ingestScope

testUnknownClient :: TestTree
testUnknownClient = testCase "an unknown client id is invalid_client" do
  (_, res) <- withAccount \a -> (grantFor a) {clientId = "svcacct_does_not_exist"}
  fmap (const ()) res @?= Left OAuthClientInvalid

testWrongSecret :: TestTree
testWrongSecret = testCase "a wrong secret is invalid_client, indistinguishable from an unknown client" do
  (_, res) <- withAccount \a -> (grantFor a) {clientSecret = "wrong"}
  fmap (const ()) res @?= Left OAuthClientInvalid

testRevokedAccount :: TestTree
testRevokedAccount = testCase "a revoked account is invalid_client, indistinguishable from a wrong secret" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  account <- seedAccount ref serviceUser.userId
  _ <- runInMemory ref (revokeServiceAccount (saId account) fixedTime)
  res <- runInMemory ref (grantClientCredentials baseCfg (grantFor account))
  fmap (const ()) res @?= Left OAuthClientInvalid

testInactiveBackingUser :: TestTree
testInactiveBackingUser = testCase "an inactive backing user is invalid_client" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  account <- seedAccount ref serviceUser.userId
  _ <- runInMemory ref (updateUserStatus serviceUser.userId UserSuspended)
  res <- runInMemory ref (grantClientCredentials baseCfg (grantFor account))
  fmap (const ()) res @?= Left OAuthClientInvalid

testScopeOutsideAllowList :: TestTree
testScopeOutsideAllowList = testCase "a scope outside allowed_scopes is invalid_scope" do
  (_, res) <- withAccount \a -> (grantFor a) {requestedScopes = Just (Set.singleton egressScope)}
  fmap (const ()) res @?= Left OAuthScopeInvalid

testEmptyScopeSet :: TestTree
testEmptyScopeSet = testCase "an explicitly empty scope parameter is invalid_scope, not 'grant nothing'" do
  (_, res) <- withAccount \a -> (grantFor a) {requestedScopes = Just Set.empty}
  fmap (const ()) res @?= Left OAuthScopeInvalid

testNoRefreshToken :: TestTree
testNoRefreshToken = testCase "the minted session carries no refresh token" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  account <- seedAccount ref serviceUser.userId
  granted <- expectRight =<< runInMemory ref (grantClientCredentials baseCfg (grantFor account))
  world <- readIORef ref
  let forSession = filter (\PersistedRefreshToken {sessionId} -> sessionId == granted.sessionId) (Map.elems world.refreshTokens)
  assertBool "client_credentials session has no refresh token" (null forSession)
  -- exactly one ServiceTokenIssued, naming the account by its client id
  assertBool
    "ServiceTokenIssued published once for the client id"
    (length (filter (matchesIssued (saClientId account)) world.publishedEvents) == 1)
  where
    matchesIssued cid = \case
      Event.ServiceTokenIssued d -> (d ^. #accountId) == ServiceAccountId cid && isNothing (d ^. #actorId)
      _ -> False

testFailureDoesNotMint :: TestTree
testFailureDoesNotMint = testCase "a failed grant creates no session and publishes no event" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  account <- seedAccount ref serviceUser.userId
  before <- readIORef ref
  res <- runInMemory ref (grantClientCredentials baseCfg ((grantFor account) {clientSecret = "wrong"}))
  fmap (const ()) res @?= Left OAuthClientInvalid
  after <- readIORef ref
  length after.sessions @?= length before.sessions
  assertBool "no ServiceTokenIssued event on failure" (not (any isServiceTokenIssued after.publishedEvents))
  where
    isServiceTokenIssued = \case
      Event.ServiceTokenIssued _ -> True
      _ -> False
