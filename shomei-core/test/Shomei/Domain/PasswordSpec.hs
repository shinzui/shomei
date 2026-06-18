module Shomei.Domain.PasswordSpec (tests) where

import Shomei.Domain.CommonPasswords (commonPasswordCount, isCommonPassword)
import Shomei.Domain.Password
  ( PasswordContext (..),
    PasswordPolicy (..),
    PlainPassword (..),
    defaultPasswordPolicy,
    validatePassword,
  )
import Shomei.Error (PasswordPolicyViolation (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

aliceCtx :: PasswordContext
aliceCtx = PasswordContext {contextEmail = Just "alice@example.com", contextDisplayName = Just "Alice"}

-- | The default policy (rejectCommonPasswords=True, rejectContextualPasswords=True) but with a
-- small minLength so the length guard does not pre-empt the common/contextual checks under test.
basePolicy :: PasswordPolicy
basePolicy = defaultPasswordPolicy {minLength = 4}

tests :: TestTree
tests =
  testGroup
    "Shomei.Domain.PasswordSpec"
    [ testCase "dictionary is non-empty" $
        assertBool "expected a non-empty common-password dictionary" (commonPasswordCount > 0),
      testCase "a known common password is detected" $
        isCommonPassword "password" @?= True,
      testCase "case and whitespace are normalized" $
        isCommonPassword "  PASSWORD  " @?= True,
      testCase "a strong passphrase is not common" $
        isCommonPassword "correct horse battery staple" @?= False,
      testCase "too short" $
        validatePassword defaultPasswordPolicy aliceCtx (PlainPassword "short")
          @?= Left (PasswordTooShort defaultPasswordPolicy.minLength),
      testCase "common password rejected" $
        validatePassword basePolicy aliceCtx (PlainPassword "password123")
          @?= Left PasswordTooCommon,
      testCase "email local-part rejected" $
        validatePassword basePolicy aliceCtx (PlainPassword "alice")
          @?= Left PasswordResemblesIdentity,
      testCase "full email rejected" $
        validatePassword basePolicy aliceCtx (PlainPassword "alice@example.com")
          @?= Left PasswordResemblesIdentity,
      testCase "display name rejected" $
        validatePassword basePolicy aliceCtx (PlainPassword "Alice")
          @?= Left PasswordResemblesIdentity,
      testCase "strong unrelated password accepted" $
        validatePassword basePolicy aliceCtx (PlainPassword "correct horse battery staple")
          @?= Right (),
      testCase "flags off let common and contextual through" $ do
        let off = basePolicy {rejectCommonPasswords = False, rejectContextualPasswords = False}
        validatePassword off aliceCtx (PlainPassword "password123") @?= Right ()
        validatePassword off aliceCtx (PlainPassword "alice@example.com") @?= Right ()
    ]
