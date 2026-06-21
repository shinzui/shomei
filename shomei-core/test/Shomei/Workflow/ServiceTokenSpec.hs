module Shomei.Workflow.ServiceTokenSpec (tests) where

import Data.Aeson (eitherDecode)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Config (ServiceAccountConfig (..), ServiceAccountId (..), ServiceTokenConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginId (LoginId, mkLoginId)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..), UserStatus (UserSuspended))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Effect.UserStore (updateUserStatus)
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId, genUserId)
import Shomei.Prelude
import Shomei.Workflow (signup)
import Shomei.Workflow.ServiceToken (IssueServiceToken (..), issueServiceToken, sha256Hex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

baseCfg :: ShomeiConfig
baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

serviceAccount :: ServiceAccountId
serviceAccount = ServiceAccountId "connector:rei"

serviceSecret :: Text
serviceSecret = "test-secret"

ingestScope :: Scope
ingestScope = Scope "kawa:ingest"

signalScope :: Scope
signalScope = Scope "signal:raise"

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

seedUser :: IORef World -> Text -> IO User
seedUser ref name = do
  let loginId = mkLoginId' name
      emailText = name <> "@example.com"
      email = either (\e -> error ("bad test email: " <> show e)) id (mkEmail emailText)
  (user, _) <-
    expectRight
      =<< runInMemory
        ref
        ( signup
            baseCfg
            SignupCommand
              { loginId,
                email = Just email,
                password = strongPw,
                displayName = Just name
              }
        )
  pure user

enabledCfg :: UserId -> ShomeiConfig
enabledCfg uid =
  baseCfg
    & #serviceTokenConfig
    .~ ServiceTokenConfig
      { enabled = True,
        ttl = 300,
        accounts =
          [ ServiceAccountConfig
              { accountId = serviceAccount,
                userId = uid,
                secretHash = sha256Hex serviceSecret,
                allowedScopes = Set.fromList [ingestScope, signalScope]
              }
          ]
      }

mkCommand :: IssueServiceToken
mkCommand =
  IssueServiceToken
    { accountId = serviceAccount,
      secret = serviceSecret,
      scopes = Set.singleton ingestScope,
      actorId = Nothing
    }

tests :: TestTree
tests =
  testGroup
    "Shomei.Workflow.ServiceToken"
    [ testHappyPath,
      testDisabled,
      testUnknownAccount,
      testBadSecret,
      testDisallowedScope,
      testInactiveServiceUser,
      testInvalidActor,
      testEmptyScopes,
      testFailureDoesNotMint
    ]

testHappyPath :: TestTree
testHappyPath = testCase "allowed service account mints a scoped refresh-less token and audits success" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  actorUser <- seedUser ref "actor-user"
  issued <-
    expectRight
      =<< runInMemory
        ref
        ( issueServiceToken
            (enabledCfg (serviceUser ^. #userId))
            (mkCommand & #actorId ?~ (actorUser ^. #userId))
        )
  (issued ^. #expiresIn) @?= 300
  claims <- decodeAccess (issued ^. #accessToken)
  (claims ^. #subject) @?= serviceUser ^. #userId
  (claims ^. #actor) @?= Just (actorUser ^. #userId)
  (claims ^. #scopes) @?= Set.singleton ingestScope
  (claims ^. #expiresAt) @?= addUTCTime 300 fixedTime
  world <- readIORef ref
  let refsForSession = filter (\PersistedRefreshToken {sessionId} -> sessionId == (issued ^. #sessionId)) (Map.elems (world ^. #refreshTokens))
  assertBool "service token session has no refresh token" (null refsForSession)
  assertBool "ServiceTokenIssued published once" (length (filter matchesIssued (world ^. #publishedEvents)) == 1)
  where
    matchesIssued = \case
      Event.ServiceTokenIssued d ->
        (d ^. #accountId) == serviceAccount
          && (d ^. #scopes) == Set.singleton ingestScope
          && isJust (d ^. #actorId)
      _ -> False

testDisabled :: TestTree
testDisabled = testCase "disabled config is forbidden" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  let cfg = enabledCfg (serviceUser ^. #userId) & #serviceTokenConfig . #enabled .~ False
  res <- runInMemory ref (issueServiceToken cfg mkCommand)
  fmap (const ()) res @?= Left ServiceTokenDisabled

testUnknownAccount :: TestTree
testUnknownAccount = testCase "unknown account id is forbidden" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) (mkCommand & #accountId .~ ServiceAccountId "missing"))
  fmap (const ()) res @?= Left ServiceAccountNotFound

testBadSecret :: TestTree
testBadSecret = testCase "bad secret is forbidden" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) (mkCommand & #secret .~ "wrong"))
  fmap (const ()) res @?= Left ServiceAccountSecretInvalid

testDisallowedScope :: TestTree
testDisallowedScope = testCase "scope outside the allow-list is denied" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) (mkCommand & #scopes .~ Set.singleton (Scope "channel:egress")))
  fmap (const ()) res @?= Left ServiceTokenScopeDenied

testInactiveServiceUser :: TestTree
testInactiveServiceUser = testCase "inactive service-account user is invalid" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  _ <- runInMemory ref (updateUserStatus (serviceUser ^. #userId) UserSuspended)
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) mkCommand)
  fmap (const ()) res @?= Left ServiceTokenActorInvalid

testInvalidActor :: TestTree
testInvalidActor = testCase "unknown actor is invalid" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  actorId <- genUserId
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) (mkCommand & #actorId ?~ actorId))
  fmap (const ()) res @?= Left ServiceTokenActorInvalid

testEmptyScopes :: TestTree
testEmptyScopes = testCase "empty requested scope set is denied" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) (mkCommand & #scopes .~ Set.empty))
  fmap (const ()) res @?= Left ServiceTokenScopeDenied

testFailureDoesNotMint :: TestTree
testFailureDoesNotMint = testCase "failing requests create no session and publish no service-token event" do
  ref <- newIORef (emptyWorld fixedTime)
  serviceUser <- seedUser ref "connector-rei"
  before <- readIORef ref
  res <- runInMemory ref (issueServiceToken (enabledCfg (serviceUser ^. #userId)) (mkCommand & #secret .~ "wrong"))
  fmap (const ()) res @?= Left ServiceAccountSecretInvalid
  after <- readIORef ref
  length (after ^. #sessions) @?= length (before ^. #sessions)
  assertBool "no ServiceTokenIssued event on failure" (not (any isServiceTokenIssued (after ^. #publishedEvents)))
  where
    isServiceTokenIssued = \case
      Event.ServiceTokenIssued _ -> True
      _ -> False
