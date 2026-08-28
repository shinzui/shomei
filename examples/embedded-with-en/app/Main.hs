-- | The @embedded-with-en@ executable: build the real Shōmei assembly, create the shared
-- en tuple store, and serve the host 'AppAPI' (mounted auth routes + en-guarded
-- @\/projects@ + the demo grant route).
module Main (main) where

import Data.IORef (newIORef)
import EmbeddedEn.App (embeddedEnApplication)
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Config (ObservabilityConfig (..), ShomeiConfig (..))
import Shomei.Health.Server (buildHealthChecks)
import Shomei.Servant.Api (shomeiThrottledRoutes)
import Shomei.Server.Boot (HostBackgroundTasks (..), buildEnv, hostMiddleware, installHostBackgroundTasks)
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import Shomei.Server.Middleware.RateLimit (newRateLimiterFor)
import Shomei.Server.Observability.Metrics (newMetrics)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  (cfg, settings) <- loadConfig
  env <- buildEnv cfg settings
  (liveness, readiness) <- buildHealthChecks env
  backgroundTasks <- installHostBackgroundTasks cfg settings env
  limiter <- newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig
  metrics <- newMetrics
  -- The tuple store is a process-lifetime 'IORef' shared by every request, so a grant
  -- written by one request is visible to the next. It starts empty (no grants), and
  -- restarting the process resets all en state — say so in the README.
  tuples <- newIORef []
  hPutStrLn stderr ("[embedded-with-en] shomei auth mounted; en project schema compiled; listening on :" <> show settings.serverPort)
  Warp.run settings.serverPort (hostMiddleware cfg settings limiter metrics (embeddedEnApplication env liveness readiness tuples))
  stopHostBackgroundTasks backgroundTasks cfg.observabilityConfig.gracefulShutdownTimeoutSeconds
