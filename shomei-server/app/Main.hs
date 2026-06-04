{- | The single @shomei-server@ executable entry point; all logic lives in the
@shomei-server@ library (the boot sequence).
-}
module Main (main) where

import Shomei.Server.Boot qualified as Boot

main :: IO ()
main = Boot.main
