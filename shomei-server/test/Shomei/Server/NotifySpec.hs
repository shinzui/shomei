-- | The 'LogNotifier' must not write a usable one-time token to the log. These tests pin
-- both halves of that contract: the default redacted line carries no raw token and no
-- @token=@ URL parameter, and the @logRawTokens@ escape hatch restores the full dev link.
module Shomei.Server.NotifySpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Crypto (sha256Hex)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Notify (renderNotification)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

-- | A token whose text is distinctive enough that a substring check is meaningful.
rawToken :: Text.Text
rawToken = "s3cr3t-one-time-token-do-not-log-me"

tests :: TestTree
tests =
  testGroup
    "Notify"
    [ testCase "redacts the one-time token by default" do
        email <- testEmail
        let out = render False (PasswordResetRequested email (OneTimeToken rawToken) expires)
        assertBool
          ("raw token must not appear in: " <> out)
          (not (Text.unpack rawToken `isInfixOf` out))
        assertBool
          ("no ?token= URL parameter in: " <> out)
          (not ("?token=" `isInfixOf` out))
        assertBool
          ("hash prefix must appear in: " <> out)
          (("token_sha256=" <> Text.unpack expectedPrefix) `isInfixOf` out)
        assertBool "kind is labelled" ("password_reset" `isInfixOf` out),
      testCase "logs the full link when logRawTokens is set" do
        email <- testEmail
        let out = render True (EmailVerificationRequested email (OneTimeToken rawToken) expires)
        assertBool
          ("full link expected in: " <> out)
          (("/v1/auth/verify-email/confirm?token=" <> Text.unpack rawToken) `isInfixOf` out)
        assertBool "no hash prefix in raw mode" (not ("token_sha256=" `isInfixOf` out))
    ]
  where
    expires = UTCTime (fromGregorian 2026 7 8) 0
    expectedPrefix = Text.take 8 (sha256Hex rawToken)
    render raw n = renderNotification (notifierCfg raw) n
    notifierCfg raw =
      (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")).notifierConfig
        {logRawTokens = raw}

testEmail :: IO Email
testEmail = either (\e -> assertFailure ("bad email: " <> show e)) pure (mkEmail "a@example.com")
