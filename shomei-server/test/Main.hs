module Main (main) where

import Shomei.Server.E2ESpec (tests)
import Test.Tasty (defaultMain)

main :: IO ()
main = defaultMain tests
