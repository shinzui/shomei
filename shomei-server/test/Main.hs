module Main (main) where

import Shomei.Server.E2ESpec qualified as E2ESpec
import Shomei.Server.NotifySpec qualified as NotifySpec
import Shomei.Server.SupervisorSpec qualified as SupervisorSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    (testGroup "shomei-server" [NotifySpec.tests, SupervisorSpec.tests, E2ESpec.tests])
