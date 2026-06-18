module Main (main) where

import Shomei.Jwt.InterpreterSpec qualified as InterpreterSpec
import Shomei.Jwt.JwksSpec qualified as JwksSpec
import Shomei.Jwt.KeySpec qualified as KeySpec
import Shomei.Jwt.RsaCustomClaimSpec qualified as RsaCustomClaimSpec
import Shomei.Jwt.SignVerifySpec qualified as SignVerifySpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shomei-jwt"
      [ KeySpec.tests,
        SignVerifySpec.tests,
        JwksSpec.tests,
        InterpreterSpec.tests,
        RsaCustomClaimSpec.tests
      ]
