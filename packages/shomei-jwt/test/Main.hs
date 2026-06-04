module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Shomei.Jwt.JwksSpec qualified as JwksSpec
import Shomei.Jwt.KeySpec qualified as KeySpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "shomei-jwt"
            [ KeySpec.tests
            , JwksSpec.tests
            ]
