module Shomei.Domain.PasswordSpec (tests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Shomei.Domain.CommonPasswords (commonPasswordCount, isCommonPassword)

tests :: TestTree
tests =
    testGroup
        "Shomei.Domain.PasswordSpec"
        [ testCase "dictionary is non-empty" $
            assertBool "expected a non-empty common-password dictionary" (commonPasswordCount > 0)
        , testCase "a known common password is detected" $
            isCommonPassword "password" @?= True
        , testCase "case and whitespace are normalized" $
            isCommonPassword "  PASSWORD  " @?= True
        , testCase "a strong passphrase is not common" $
            isCommonPassword "correct horse battery staple" @?= False
        ]
