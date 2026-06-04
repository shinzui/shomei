module Main where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Shomei.Migrations (runShomeiMigrationsNoCheck)

main :: IO ()
main = do
    settings <- getCoddSettings
    _ <- runShomeiMigrationsNoCheck settings (secondsToDiffTime 5)
    pure ()
