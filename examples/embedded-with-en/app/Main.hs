-- | The @embedded-with-en@ executable: build the real Shōmei assembly, create the shared
-- en tuple store, and serve the host 'AppAPI' (mounted auth routes + en-guarded
-- @\/projects@ + the demo grant route).
module Main (main) where

import Data.IORef (newIORef)
import EmbeddedEn.App (embeddedEnApplication)
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Server.Boot (buildEnv)
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  (cfg, settings) <- loadConfig
  env <- buildEnv cfg settings
  -- The tuple store is a process-lifetime 'IORef' shared by every request, so a grant
  -- written by one request is visible to the next. It starts empty (no grants), and
  -- restarting the process resets all en state — say so in the README.
  tuples <- newIORef []
  hPutStrLn stderr ("[embedded-with-en] shomei auth mounted; en project schema compiled; listening on :" <> show settings.serverPort)
  Warp.run settings.serverPort (embeddedEnApplication env tuples)
