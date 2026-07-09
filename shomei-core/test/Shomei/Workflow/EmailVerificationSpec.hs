-- | @emailVerificationRequired@ used to be a configuration flag that nothing read: an
-- operator could set it and unverified accounts would keep logging in. These tests pin the
-- behavior it now has — token issuance is refused for an account whose email is present but
-- unverified, on every path that mints tokens — and, just as importantly, that the flag off
-- (the default) changes nothing.
module Shomei.Workflow.EmailVerificationSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.IORef (IORef, newIORef, readIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail, loginIdText, mkLoginId)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken)
import Shomei.Domain.Passkey
  ( NewPasskeyCredential (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
  )
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Effect.PasskeyStore (createPasskey)
import Shomei.Error (AuthError (EmailNotVerified))
import Shomei.Workflow (login, refresh, signup)
import Shomei.Workflow.Account
  ( ConfirmEmailVerification (..),
    RequestEmailVerification (..),
    confirmEmailVerification,
    requestEmailVerification,
  )
import Shomei.Workflow.Mfa (beginPasswordlessLogin, completePasswordlessLogin)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "emailVerificationRequired"
    [ testCase "an unverified account cannot log in" do
        ref <- newIORef (emptyWorld fixedTime)
        _ <- expectRight =<< runInMemory ref (signup gatedCfg (signupEmail aliceEmail))
        result <- runInMemory ref (login gatedCfg (ctxFor aliceEmail) (loginEmail aliceEmail strongPw))
        expectBlocked result,
      testCase "an unverified account cannot refresh the pair signup handed it" do
        -- Signup still issues tokens (changing that would break the response shape), so the
        -- gate has to close at the first renewal or the account never expires.
        ref <- newIORef (emptyWorld fixedTime)
        (_, pair) <- expectRight =<< runInMemory ref (signup gatedCfg (signupEmail aliceEmail))
        result <- runInMemory ref (refresh gatedCfg (RefreshCommand pair.refreshToken))
        expectBlocked result,
      testCase "verifying the email unblocks login" do
        ref <- newIORef (emptyWorld fixedTime)
        _ <- expectRight =<< runInMemory ref (signup gatedCfg (signupEmail aliceEmail))
        _ <- expectRight =<< runInMemory ref (requestEmailVerification gatedCfg (RequestEmailVerification aliceEmail))
        raw <- verificationTokenOf ref
        _ <- expectRight =<< runInMemory ref (confirmEmailVerification gatedCfg (ConfirmEmailVerification raw))
        result <- runInMemory ref (login gatedCfg (ctxFor aliceEmail) (loginEmail aliceEmail strongPw))
        _ <- expectRight result
        pure (),
      testCase "an account with no email is exempt (it could never verify one)" do
        ref <- newIORef (emptyWorld fixedTime)
        let lid = mkLoginId' "alice"
        _ <- expectRight =<< runInMemory ref (signup gatedCfg (signupLoginId lid))
        result <- runInMemory ref (login gatedCfg (ctxForLogin lid) (LoginCommand lid strongPw))
        _ <- expectRight result
        pure (),
      testCase "with the flag off an unverified account logs in (the default)" do
        ref <- newIORef (emptyWorld fixedTime)
        _ <- expectRight =<< runInMemory ref (signup cfg (signupEmail aliceEmail))
        result <- runInMemory ref (login cfg (ctxFor aliceEmail) (loginEmail aliceEmail strongPw))
        _ <- expectRight result
        pure (),
      testCase "passwordless passkey login is gated too" do
        ref <- newIORef (emptyWorld fixedTime)
        seedUserWithPasskey ref
        (cid, opts) <- expectRight =<< runInMemory ref (beginPasswordlessLogin gatedCfg)
        chal <- maybe (assertFailure "no challenge in options") pure (challengeOf opts)
        result <- runInMemory ref (completePasswordlessLogin gatedCfg cid (acceptedAssertion chal))
        expectBlocked result
    ]

-- | A gated result must name 'EmailNotVerified' — not the generic 401. Every path that can
-- reach it has already proven account control, so the reason leaks nothing.
expectBlocked :: (Show a) => Either AuthError a -> IO ()
expectBlocked = \case
  Left EmailNotVerified -> pure ()
  Left e -> assertFailure ("expected EmailNotVerified, got " <> show e)
  Right a -> assertFailure ("expected EmailNotVerified, got a token pair: " <> show a)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- | The raw token from the most recent email-verification notification.
verificationTokenOf :: IORef World -> IO OneTimeToken
verificationTokenOf ref = do
  w <- readIORef ref
  case w.sentNotifications of
    EmailVerificationRequested {token = raw} : _ -> pure raw
    _ -> assertFailure "expected an email-verification notification"

seedUserWithPasskey :: IORef World -> IO ()
seedUserWithPasskey ref = do
  (user, _) <- expectRight =<< runInMemory ref (signup gatedCfg (signupEmail aliceEmail))
  let User {userId = uid} = user
  _ <-
    runInMemory
      ref
      ( createPasskey
          NewPasskeyCredential
            { userId = uid,
              credentialId = seededCredId,
              userHandle = seededHandle,
              publicKey = seededKey,
              signCounter = SignatureCounter 0,
              transports = [],
              label = Just "Test Key",
              createdAt = fixedTime
            }
      )
  pure ()

acceptedAssertion :: Text -> Value
acceptedAssertion chal =
  object
    [ "challenge" .= chal,
      "credentialId" .= seededCredId,
      "userHandle" .= seededHandle,
      "publicKey" .= seededKey
    ]

challengeOf :: Value -> Maybe Text
challengeOf = parseMaybe (withObject "options" (\o -> o .: "challenge"))

seededCredId :: WebAuthnCredentialId
seededCredId = WebAuthnCredentialId "cred-1"

seededHandle :: UserHandle
seededHandle = UserHandle "uh-1"

seededKey :: PublicKeyBytes
seededKey = PublicKeyBytes "pk-1"

-- Fixtures -------------------------------------------------------------------

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

-- | The same config with the gate switched on.
gatedCfg :: ShomeiConfig
gatedCfg = cfg {notifierConfig = cfg.notifierConfig {emailVerificationRequired = True}}

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' t = either (\e -> error ("bad test email: " <> show e)) id (mkEmail t)

mkLoginId' :: Text -> LoginId
mkLoginId' t = either (\e -> error ("bad test login id: " <> show e)) id (mkLoginId t)

signupEmail :: Email -> SignupCommand
signupEmail e =
  SignupCommand {loginId = loginIdFromEmail e, email = Just e, password = strongPw, displayName = Nothing}

signupLoginId :: LoginId -> SignupCommand
signupLoginId l =
  SignupCommand {loginId = l, email = Nothing, password = strongPw, displayName = Nothing}

loginEmail :: Email -> PlainPassword -> LoginCommand
loginEmail e pw = LoginCommand {loginId = loginIdFromEmail e, password = pw}

ctxForLogin :: LoginId -> ClientContext
ctxForLogin l = ClientContext (ClientIp "test-ip") (AccountKey (loginIdText l))

ctxFor :: Email -> ClientContext
ctxFor = ctxForLogin . loginIdFromEmail
