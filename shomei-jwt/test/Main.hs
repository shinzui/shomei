module Main (main) where

import Shomei.SigningKey.Interpreter.JwtSpec qualified as InterpreterSpec
import Shomei.SigningKey.Jwks.JwtSpec qualified as JwksSpec
import Shomei.SigningKey.Key.JwtSpec qualified as KeySpec
import Shomei.SigningKey.Protection.JwtSpec qualified as KeyProtectionSpec
import Shomei.SigningKey.Rotation.JwtSpec qualified as RotationSpec
import Shomei.SigningKey.Sign.IdTokenSpec qualified as IdTokenSpec
import Shomei.SigningKey.Sign.JwtSpec qualified as SignVerifySpec
import Shomei.SigningKey.Sign.RsaCustomClaimSpec qualified as RsaCustomClaimSpec
import Shomei.SigningKey.Verify.JwtSpec qualified as VerifySpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shomei-jwt"
      [ KeySpec.tests,
        KeyProtectionSpec.tests,
        SignVerifySpec.tests,
        IdTokenSpec.tests,
        JwksSpec.tests,
        InterpreterSpec.tests,
        RotationSpec.tests,
        RsaCustomClaimSpec.tests,
        VerifySpec.tests
      ]
