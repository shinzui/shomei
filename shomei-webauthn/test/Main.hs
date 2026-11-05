module Main (main) where

import Shomei.WebAuthn.CeremonySpec qualified
import Shomei.WebAuthn.WorkflowSpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "shomei-webauthn-test" [Shomei.WebAuthn.CeremonySpec.tests, Shomei.WebAuthn.WorkflowSpec.tests])
