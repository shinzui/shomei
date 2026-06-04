module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import Shomei.WorkflowSpec qualified

main :: IO ()
main = defaultMain (testGroup "shomei-core-test" [Shomei.WorkflowSpec.tests])
