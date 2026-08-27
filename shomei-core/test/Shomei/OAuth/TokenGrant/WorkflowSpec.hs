{-# LANGUAGE DataKinds #-}

-- | Regression coverage for policy shared by the authorization-code grant and ordinary login.
module Shomei.OAuth.TokenGrant.WorkflowSpec (tests) where

import Data.Either (isRight)
import Data.IORef (newIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Account.Email.Domain (Email, mkEmail)
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.User.Domain (User (..))
import Shomei.Account.User.Store (markUserEmailVerified)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Id (genOAuthClientId, idText)
import Shomei.OAuth.AuthorizationCode.Domain (NewAuthorizationCode (..))
import Shomei.OAuth.AuthorizationCode.Store (putAuthorizationCode)
import Shomei.OAuth.Client.Domain (ClientType (ConfidentialClient), NewOAuthClient (..), OAuthClient (..))
import Shomei.OAuth.Client.Store (createOAuthClient)
import Shomei.OAuth.TokenGrant.Workflow
  ( ExchangeAuthorizationCode (..),
    TokenGrantError (..),
    exchangeAuthorizationCode,
  )
import Shomei.ServiceAccount.Secret (sha256Hex)
import Shomei.Session.Authentication.Workflow (signup)
import Shomei.Session.Command (SignupCommand (..))
import Shomei.Test.InMemory (emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.OAuth.TokenGrant.Workflow"
    [ testCase "authorization-code exchange refuses an unverified email when the gate is enabled" testUnverifiedEmail,
      testCase "authorization-code exchange accepts a verified email when the gate is enabled" testVerifiedEmail,
      testCase "authorization-code exchange exempts a login-id-only account from the email gate" testNoEmail
    ]

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

baseCfg :: ShomeiConfig
baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

gatedCfg :: ShomeiConfig
gatedCfg = baseCfg {notifierConfig = baseCfg.notifierConfig {emailVerificationRequired = True}}

callback :: Text
callback = "https://app.example.com/callback"

rawCode :: Text
rawCode = "authorization-code-for-email-gate"

testClientSecret :: Text
testClientSecret = "oauth-client-secret"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' = either (error . show) id . mkEmail

data PrincipalShape = UnverifiedEmail | VerifiedEmail | NoEmail

exchangeFor :: PrincipalShape -> IO (Either TokenGrantError ())
exchangeFor shape = do
  ref <- newIORef (emptyWorld fixedTime)
  clientId <- runInMemory ref do
    let email = case shape of
          NoEmail -> Nothing
          _ -> Just (mkEmail' "code-user@example.com")
        login = case shape of
          NoEmail -> "code-user"
          _ -> "code-user@example.com"
    loginId <- either (error . show) pure (mkLoginId login)
    signupResult <- signup baseCfg SignupCommand {loginId, email, password = strongPw, displayName = Just "Code User"}
    user <- either (error . show) (pure . fst) signupResult
    case shape of
      VerifiedEmail -> markUserEmailVerified user.userId fixedTime
      _ -> pure ()
    ocid <- genOAuthClientId
    client <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = ocid,
            clientId = idText ocid,
            secretHash = Just (sha256Hex testClientSecret),
            clientType = ConfidentialClient,
            displayName = "test client",
            redirectUris = [callback],
            allowedScopes = Set.empty,
            createdAt = fixedTime
          }
    putAuthorizationCode
      NewAuthorizationCode
        { codeHash = sha256Hex rawCode,
          clientId = client.clientId,
          redirectUri = callback,
          userId = user.userId,
          scopes = Set.empty,
          nonce = Nothing,
          codeChallenge = Nothing,
          authTime = fixedTime,
          createdAt = fixedTime,
          expiresAt = addUTCTime 60 fixedTime
        }
    pure client.clientId
  result <-
    runInMemory ref $
      exchangeAuthorizationCode
        gatedCfg
        ExchangeAuthorizationCode
          { clientId,
            clientSecret = Just testClientSecret,
            code = rawCode,
            redirectUri = callback,
            codeVerifier = Nothing
          }
  pure (() <$ result)

testUnverifiedEmail :: IO ()
testUnverifiedEmail = do
  result <- exchangeFor UnverifiedEmail
  result @?= Left (GrantInvalidGrant "the code's user has not verified their email")

testVerifiedEmail :: IO ()
testVerifiedEmail = do
  result <- exchangeFor VerifiedEmail
  assertBool "verified email should exchange" (isRight result)

testNoEmail :: IO ()
testNoEmail = do
  result <- exchangeFor NoEmail
  case result of
    Left err -> assertFailure ("login-id-only account was refused: " <> show err)
    Right () -> pure ()
