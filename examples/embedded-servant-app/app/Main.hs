{- | The @embedded-servant-app@ executable: build the real Shōmei assembly and serve the
host 'AppAPI' (mounted auth routes + a guarded @\/projects@).
-}
module Main (main) where

import System.IO (hPutStrLn, stderr)
import Network.Wai.Handler.Warp qualified as Warp

import Embedded.App (embeddedApplication)
import Shomei.Server.Boot (buildEnv)
import Shomei.Server.Config (ServerSettings (..), loadConfig)

main :: IO ()
main = do
    (cfg, settings) <- loadConfig
    env <- buildEnv cfg settings
    hPutStrLn stderr ("[embedded-servant-app] listening on :" <> show settings.serverPort)
    Warp.run settings.serverPort (embeddedApplication env)
