{- | Scenario (h): the @effectful@ interpreters. Inside an 'Eff' computation,
'runTokenSignerJwt' mints a token and 'runTokenVerifierJwt' verifies it; the
recovered claims equal the originals.
-}
module Shomei.Jwt.InterpreterSpec (tests) where

import Data.Time (getCurrentTime)
import Effectful (runEff)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Shomei.Jwt.Key (generateSigningKey)
import Shomei.Jwt.Sign (runTokenSignerJwt)
import Shomei.Jwt.Verify (runTokenVerifierJwt)
import Shomei.Port.TokenSigner (signAccessToken)
import Shomei.Port.TokenVerifier (verifyAccessToken)

import Shomei.Jwt.TestSupport (coreFields, mkClaims, publicJwks, testConfig)

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
