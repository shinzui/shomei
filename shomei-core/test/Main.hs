module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Shomei.AccountSpec qualified
import Shomei.LockoutSpec qualified
import Shomei.WebAuthnCeremonySpec qualified
import Shomei.WorkflowSpec qualified

main :: IO ()
main =
    defaultMain
        ( testGroup
            "shomei-core-test"
            [ Shomei.WorkflowSpec.tests
            , Shomei.AccountSpec.tests
            , Shomei.LockoutSpec.tests
            , Shomei.WebAuthnCeremonySpec.tests
            ]
        )
