{-# LANGUAGE DataKinds #-}

module Shomei.OAuth.Authorize.WorkflowSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Authorization.Claims.Domain (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Id (SessionId, UserId, genOAuthClientId, genSessionId, genUserId, idText)
import Shomei.OAuth.Authorize.Workflow
  ( AuthorizeError (..),
    AuthorizeParams (..),
    AuthorizeRefusal (..),
    IssuedCode,
    authorize,
  )
import Shomei.OAuth.Client.Domain (ClientType (ConfidentialClient), NewOAuthClient (..))
import Shomei.OAuth.Client.Store (createOAuthClient)
import Shomei.ServiceAccount.Secret (sha256Hex)
import Shomei.Session.Domain (NewSession (..), Session (..), SessionKind (..))
import Shomei.Session.Store (createSession, revokeSession)
import Shomei.Test.InMemory (World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.OAuth.Authorize.Workflow"
    [ testCase "interactive session is accepted" testInteractive,
      testCase "impersonation/delegated session is refused" (testKind DelegatedSession),
      testCase "on-behalf-of/delegated session is refused" (testKind DelegatedSession),
      testCase "client_credentials/machine session is refused" (testKind MachineSession),
      testCase "an act claim is refused before an unknown session is read" testActorBeforeSession,
      testCase "a revoked interactive session is refused" testRevoked,
      testCase "an expired interactive session is refused" testExpired,
      testCase "an unknown session is refused" testUnknown
    ]

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

callback :: Text
callback = "https://app.example.com/callback"

params :: AuthorizeParams
params =
  AuthorizeParams
    { responseType = Just "code",
      redirectUri = callback,
      scope = Just "openid",
      state = Nothing,
      nonce = Nothing,
      codeChallenge = Nothing,
      codeChallengeMethod = Nothing
    }

claimsFor :: UserId -> SessionId -> Maybe UserId -> AuthClaims
claimsFor uid sid actor =
  AuthClaims
    { subject = uid,
      sessionId = sid,
      issuer = Issuer "shomei",
      audience = Audience "shomei-clients",
      issuedAt = fixedTime,
      expiresAt = addUTCTime 900 fixedTime,
      scopes = Set.empty,
      roles = Set.empty,
      permissions = Set.empty,
      actor,
      extraClaims = mempty
    }

data SessionState = Live | Revoked | Expired | Missing

runAuthorize :: SessionKind -> SessionState -> Bool -> IO (Either AuthorizeError IssuedCode, World)
runAuthorize kind state carriesActor = do
  ref <- newIORef (emptyWorld fixedTime)
  result <- runInMemory ref do
    uid <- genUserId
    actor <- if carriesActor then Just <$> genUserId else pure Nothing
    session <-
      createSession
        NewSession
          { userId = uid,
            createdAt = fixedTime,
            expiresAt = case state of
              Expired -> fixedTime
              _ -> addUTCTime 3600 fixedTime,
            actor,
            oauthClientId = Nothing,
            kind
          }
    case state of
      Revoked -> revokeSession session.sessionId fixedTime
      _ -> pure ()
    sid <- case state of
      Missing -> genSessionId
      _ -> pure session.sessionId
    ocid <- genOAuthClientId
    client <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = ocid,
            clientId = idText ocid,
            secretHash = Just (sha256Hex "secret"),
            clientType = ConfidentialClient,
            displayName = "test",
            redirectUris = [callback],
            allowedScopes = Set.singleton (Scope "openid"),
            createdAt = fixedTime
          }
    authorize cfg client (claimsFor uid sid actor) params
  world <- readIORef ref
  pure (result, world)

expectRefusal :: AuthorizeRefusal -> (Either AuthorizeError IssuedCode, World) -> IO ()
expectRefusal expected (result, world) = do
  result @?= Left (AuthorizeLoginRequired expected)
  Map.size (oauthCodes world) @?= 0

testInteractive :: IO ()
testInteractive = do
  (result, world) <- runAuthorize InteractiveSession Live False
  case result of
    Left err -> assertFailure ("interactive authorize was refused: " <> show err)
    Right _ -> pure ()
  Map.size (oauthCodes world) @?= 1

testKind :: SessionKind -> IO ()
testKind kind = runAuthorize kind Live False >>= expectRefusal NonInteractiveCredential

testActorBeforeSession :: IO ()
testActorBeforeSession = runAuthorize InteractiveSession Missing True >>= expectRefusal NonInteractiveCredential

testRevoked :: IO ()
testRevoked = runAuthorize InteractiveSession Revoked False >>= expectRefusal SessionNotLive

testExpired :: IO ()
testExpired = runAuthorize InteractiveSession Expired False >>= expectRefusal SessionNotLive

testUnknown :: IO ()
testUnknown = runAuthorize InteractiveSession Missing False >>= expectRefusal SessionNotLive
