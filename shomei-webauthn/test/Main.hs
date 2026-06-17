module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Shomei.WebAuthn.CeremonySpec qualified

main :: IO ()
main = defaultMain (testGroup "shomei-webauthn-test" [Shomei.WebAuthn.CeremonySpec.tests])
