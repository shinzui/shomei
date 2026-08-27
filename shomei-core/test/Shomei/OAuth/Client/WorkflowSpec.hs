-- | Policy tests for OAuth client registration.
module Shomei.OAuth.Client.WorkflowSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..), Scope (..))
import Shomei.Authorization.Scope.Domain (adminScope, tokenExchangeSubjectScope)
import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Id (genOAuthClientId, idText)
import Shomei.OAuth.Client.Domain (ClientType (ConfidentialClient), NewOAuthClient (..))
import Shomei.OAuth.Client.Workflow (ClientRegistrationError (..), registerOAuthClient)
import Shomei.Test.InMemory (World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.OAuth.Client.Workflow"
    [ testCase "all built-in privilege scopes are refused" refusesBuiltIns,
      testCase "the configured impersonation scope is refused" refusesConfiguredImpersonation,
      testCase "ordinary capability scopes are registered" acceptsCapabilities
    ]

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 27) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

newClient :: Set.Set Scope -> IO NewOAuthClient
newClient allowedScopes = do
  oauthClientId <- genOAuthClientId
  pure
    NewOAuthClient
      { oauthClientId,
        clientId = idText oauthClientId,
        secretHash = Just "digest",
        clientType = ConfidentialClient,
        displayName = "test client",
        redirectUris = ["https://client.example.com/callback"],
        allowedScopes,
        createdAt = t0
      }

register :: ShomeiConfig -> Set.Set Scope -> IO (Either ClientRegistrationError (), World)
register config scopes = do
  ref <- newIORef (emptyWorld t0)
  candidate <- newClient scopes
  result <- fmap (const ()) <$> runInMemory ref (registerOAuthClient config candidate)
  world <- readIORef ref
  pure (result, world)

refusesBuiltIns :: IO ()
refusesBuiltIns =
  mapM_
    ( \scope -> do
        (result, world) <- register cfg (Set.singleton scope)
        result @?= Left (PrivilegeScopesRefused (Set.singleton scope))
        Map.size world.oauthClients @?= 0
    )
    [cfg.impersonationConfig.impersonateScope, adminScope, tokenExchangeSubjectScope]

refusesConfiguredImpersonation :: IO ()
refusesConfiguredImpersonation = do
  let configured = Scope "support:act-as"
      custom = cfg {impersonationConfig = cfg.impersonationConfig {impersonateScope = configured}}
  (result, world) <- register custom (Set.singleton configured)
  result @?= Left (PrivilegeScopesRefused (Set.singleton configured))
  Map.size world.oauthClients @?= 0

acceptsCapabilities :: IO ()
acceptsCapabilities = do
  let scopes = Set.fromList [Scope "openid", Scope "kawa:read"]
  (result, world) <- register cfg scopes
  case result of
    Left err -> assertFailure ("ordinary scopes were refused: " <> show err)
    Right () -> pure ()
  Map.size world.oauthClients @?= 1
