-- | Scenario (h): the @effectful@ interpreters. Inside an 'Eff' computation,
-- 'runTokenSignerJwt' mints a token and 'runTokenVerifierJwt' verifies it; the
-- recovered claims equal the originals.
module Shomei.SigningKey.Interpreter.JwtSpec (tests) where

import Data.Time (getCurrentTime)
import Effectful (runEff)
import Shomei.SigningKey.Key.Jwt (generateSigningKey)
import Shomei.SigningKey.Sign.Jwt (runTokenSignerJwt)
import Shomei.SigningKey.Signer (signAccessToken)
import Shomei.SigningKey.TestSupport (coreFields, mkClaims, publicJwks, testConfig)
import Shomei.SigningKey.Verifier (verifyAccessToken)
import Shomei.SigningKey.Verify.Jwt (runTokenVerifierJwt)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Interpreter"
    [ testCase "sign-then-verify in Eff round-trips" $ do
        jwk <- generateSigningKey
        t <- getCurrentTime
        ac <- mkClaims testConfig t
        tok <- runEff (runTokenSignerJwt jwk testConfig (signAccessToken ac))
        res <- runEff (runTokenVerifierJwt (publicJwks jwk []) testConfig (verifyAccessToken tok))
        case res of
          Right ac' -> coreFields ac' @?= coreFields ac
          Left e -> assertFailure ("verify failed: " <> show e)
    ]
