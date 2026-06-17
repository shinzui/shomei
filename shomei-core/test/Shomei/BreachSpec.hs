module Shomei.BreachSpec (tests) where

import Shomei.Prelude

import Data.Text qualified as Text

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Effect.PasswordBreachChecker (parseHibpResponse, sha1PrefixSuffix)

tests :: TestTree
tests =
    testGroup
        "PasswordBreachChecker pure helpers"
        [ testCase "sha1PrefixSuffix of \"password\" has prefix 5BAA6" $
            fst (sha1PrefixSuffix (PlainPassword "password")) @?= "5BAA6"
        , testCase "sha1PrefixSuffix of \"password\" has the expected 35-char suffix" $
            snd (sha1PrefixSuffix (PlainPassword "password"))
                @?= "1E4C9B93F3F0682250B6CF8331B7EE68FD8"
        , testCase "sha1PrefixSuffix suffix is 35 chars" $
            Text.length (snd (sha1PrefixSuffix (PlainPassword "password"))) @?= 35
        , testCase "parseHibpResponse matches a present suffix with count > 0" $
            let (_, suffix) = sha1PrefixSuffix (PlainPassword "password")
                body = suffix <> ":12345\r\nDEADBEEF:0\r\n"
             in parseHibpResponse body suffix @?= True
        , testCase "parseHibpResponse match is case-insensitive on the suffix" $
            let (_, suffix) = sha1PrefixSuffix (PlainPassword "password")
                body = Text.toLower suffix <> ":7\r\n"
             in parseHibpResponse body suffix @?= True
        , testCase "parseHibpResponse ignores count 0 (padding)" $
            parseHibpResponse
                "ABCDEF1234567890ABCDEF1234567890ABCDE:0\r\n"
                "ABCDEF1234567890ABCDEF1234567890ABCDE"
                @?= False
        , testCase "parseHibpResponse returns False when suffix absent" $
            parseHibpResponse
                "0000000000000000000000000000000000000:9\r\n"
                "ABCDEF1234567890ABCDEF1234567890ABCDE"
                @?= False
        ]
