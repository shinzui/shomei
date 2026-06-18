-- | The @embedded-servant-app@ executable: build the real Shōmei assembly and serve the
-- host 'AppAPI' (mounted auth routes + a guarded @\/projects@).
module Main (main) where

import Data.Maybe (fromMaybe)
import Embedded.App (embeddedApplicationWith)
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Server.Boot (buildEnv)
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  (cfg, settings) <- loadConfig
  env <- buildEnv cfg settings
  -- The static passkey-demo assets live in this package's @www/@ directory; @SHOMEI_DEMO_WWW@
  -- overrides the path so the demo can be launched from anywhere (the default @www@ resolves
  -- relative to the process CWD).
  wwwDir <- fromMaybe "www" <$> lookupEnv "SHOMEI_DEMO_WWW"
  hPutStrLn stderr ("[embedded-servant-app] listening on :" <> show settings.serverPort)
  hPutStrLn stderr ("[embedded-servant-app] serving demo assets from " <> wwwDir)
  Warp.run settings.serverPort (embeddedApplicationWith wwwDir env)
