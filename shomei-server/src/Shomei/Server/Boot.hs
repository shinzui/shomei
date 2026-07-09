-- | Startup sequence and warp boot for the standalone Shōmei auth service.
--
-- 'main' runs the turnkey startup: load config → run migrations (idempotent) → acquire the
-- hasql pool → bootstrap the signing key → build the 'Env' → serve with warp. 'application'
-- builds the WAI app, reusing EP-5's 'Shomei.Servant.Handlers.shomeiServer' and the
-- @AuthProtect "shomei-jwt"@ 'Context'. EP-5's handlers run in the smaller servant port
-- stack ('Shomei.Servant.Seam.AppEffects'); they are bridged onto this server's larger
-- PostgreSQL stack ('Shomei.Server.App.AppEffects') with @inject@ inside the seam env's
-- runner. Infrastructure failures (a 'Left' from 'runAppIO') become an IO exception (warp
-- returns 500); domain failures flow through EP-5's seam to the right status.
module Shomei.Server.Boot
  ( main,
    application,
    buildEnv,
    seamEnv,
    authContext,
  )
where

-- 'Context' is hidden from the prelude (it re-exports lens's 'Context'); we mean
-- servant's 'Servant.Context' here.

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, catch)
import Control.Monad (forever)
import Data.IORef (newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (secondsToDiffTime)
import Effectful (Eff, inject)
import Hasql.Pool qualified as Pool
import Network.HTTP.Client.TLS (newTlsManager)
import Network.Wai (Application, Request)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
  ( Context (EmptyContext, (:.)),
    serveWithContext,
  )
import Servant.Server.Experimental.Auth (AuthHandler)
import Shomei.Config (ObservabilityConfig (..), ShomeiConfig (..), SigningKeyConfig (..), configSigningAlgorithm)
import Shomei.Crypto (sha256Hex)
import Shomei.Domain.LoginAttempt (AccountKey (..))
import Shomei.Jwt.Verify (verifyToken)
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Prelude hiding (Context)
import Shomei.Servant.API (shomeiAPI)
import Shomei.Servant.Auth (AuthUser, authHandler)
import Shomei.Servant.Handlers (shomeiServer)
import Shomei.Servant.Seam qualified as Seam
import Shomei.Server.App (Env (..), runAppIO)
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import Shomei.Server.Keys (LoadedKeys (..), bootstrapKeys, reloadKeys)
import Shomei.Server.Middleware.RateLimit (newRateLimiter, rateLimitMiddleware)
import Shomei.Server.Observability.Logging (requestLoggingMiddleware)
import Shomei.Server.Observability.Metrics (metricsEndpointMiddleware, metricsMiddleware, newMetrics)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Posix.Signals (installHandler, sigHUP, sigINT, sigTERM)
import System.Posix.Signals qualified as Signals

-- | The full turnkey startup sequence.
main :: IO ()
main = do
  -- Line-buffer stdout so each structured JSON log line is flushed immediately (when stdout
  -- is a pipe/file it would otherwise be block-buffered and logs would not appear promptly).
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  (cfg, settings) <- loadConfig
  env <- buildEnv cfg settings
  installKeyReload cfg env
  rl <- newRateLimiter cfg.rateLimitConfig
  metrics <- newMetrics
  let obs = cfg.observabilityConfig
      -- IP-4 realized middleware order (outermost first): EP-3 request-id + JSON logging,
      -- then EP-3 HTTP metrics, then EP-3's raw /metrics endpoint, then EP-2's rate limiter,
      -- then the Servant app. Logging is outermost so even a 429 is logged with a
      -- correlation id; metrics wrap the limiter so a throttled request is still counted.
      withMetrics =
        if obs.metricsEnabled
          then metricsMiddleware metrics . metricsEndpointMiddleware metrics
          else id
      stack =
        requestLoggingMiddleware obs
          . withMetrics
          . rateLimitMiddleware rl
      -- Graceful shutdown: SIGTERM (orchestrator stop) and SIGINT (Ctrl-C) trigger warp's
      -- shutdown action, which stops accepting new connections and waits up to the
      -- configured timeout for in-flight requests to finish. After warp returns we close the
      -- pool and exit 0.
      installShutdown closeSocket = do
        let stop sig = hPutStrLn stderr ("[shomei] received " <> sig <> "; draining in-flight requests") >> closeSocket
        _ <- installHandler sigTERM (Signals.Catch (stop "SIGTERM")) Nothing
        _ <- installHandler sigINT (Signals.Catch (stop "SIGINT")) Nothing
        pure ()
      warpSettings =
        Warp.setPort settings.serverPort
          . Warp.setGracefulShutdownTimeout (Just obs.gracefulShutdownTimeoutSeconds)
          $ Warp.setInstallShutdownHandler installShutdown Warp.defaultSettings
  hPutStrLn stderr ("[shomei] listening on :" <> show settings.serverPort)
  Warp.runSettings warpSettings (stack (application env))
  hPutStrLn stderr "[shomei] drain complete; closing connection pool"
  Pool.release env.envPool
  hPutStrLn stderr "[shomei] shutdown complete"

-- | Install the two triggers that refresh signing-key material on a running server, so
-- @shomei-admin keys activate@ / @keys revoke@ take effect with no restart: a periodic
-- background reload every @refreshIntervalSeconds@ (0 disables it), and a @SIGHUP@ handler
-- for a deterministic "apply now". Both call 'reloadKeys', which keeps the last good
-- material if a reload fails.
--
-- The background thread catches and logs per-cycle exceptions so one failure never kills
-- the loop, and it dies with the process (no shutdown plumbing needed). When
-- @docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md@ lands
-- @Shomei.Server.Supervisor.supervisedLoop@, this loop should move onto it — that plan
-- owns the supervised-background-thread idiom for @shomei-server@.
installKeyReload :: ShomeiConfig -> Env -> IO ()
installKeyReload cfg env = do
  when (interval > 0) (void (forkIO periodic))
  void (installHandler sigHUP (Signals.Catch onHup) Nothing)
  where
    interval = cfg.signingKeyConfig.refreshIntervalSeconds
    reload = reloadKeys env.envPool env.envKeys
    onHup = hPutStrLn stderr "[shomei] SIGHUP: reloading signing keys" >> reload
    periodic = forever do
      threadDelay (interval * 1_000_000)
      reload `catch` \(e :: SomeException) ->
        hPutStrLn stderr ("[shomei] periodic key reload raised: " <> show e)

-- | Run the schema migrations (idempotent), acquire the pool, and bootstrap the signing
-- key, yielding the assembled 'Env'. Shared by 'main' and by host applications that embed
-- the Shōmei API (the embedded demo builds its own 'Env' this way). Running
-- @shomei-migrate@ out-of-band is also supported for production.
buildEnv :: ShomeiConfig -> ServerSettings -> IO Env
buildEnv cfg settings = do
  _ <- runShomeiMigrationsNoCheck (coddSettingsFromConnString settings.serverConnStr) (secondsToDiffTime 60)
  pool <- acquirePool 10 settings.serverConnStr
  keys <- bootstrapKeys (configSigningAlgorithm cfg) pool
  keysRef <- newIORef keys
  mgr <- newTlsManager
  pure Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envHttpManager = mgr}

-- | Build the WAI 'Application': EP-5's server with the @AuthProtect "shomei-jwt"@
-- 'Context', whose verifier closes over this 'Env's JWKSet and config so verification
-- uses exactly the keys the server signs with.
application :: Env -> Application
application env = serveWithContext shomeiAPI (authContext senv) (shomeiServer senv)
  where
    senv = seamEnv env

-- | The single-entry Servant 'Context' carrying the @AuthProtect "shomei-jwt"@
-- 'AuthHandler', built from the seam env's verifier. A host app embedding 'ShomeiAPI'
-- serves with this same context.
authContext :: Seam.Env -> Context '[AuthHandler Request AuthUser]
authContext senv = authHandler senv.verifier :. EmptyContext

-- | Build EP-5's seam 'Seam.Env' from this server's assembly 'Env'. The port runner
-- bridges EP-5's smaller stack onto the PostgreSQL stack with @inject@; an
-- infrastructure 'Left' is raised as an IO exception (warp → 500).
seamEnv :: Env -> Seam.Env
seamEnv env =
  Seam.Env
    { Seam.runPorts = runPorts,
      Seam.config = env.envConfig,
      -- Both read the swappable key material, so a rotation applied by 'reloadKeys' takes
      -- effect on the next request without rebuilding the WAI application.
      Seam.verifier = \tok -> do
        keys <- readIORef env.envKeys
        verifyToken keys.verifierJwks env.envConfig tok,
      Seam.jwksJson = (.jwksBody) <$> readIORef env.envKeys,
      Seam.accountKeyOf = AccountKey . sha256Hex
    }
  where
    runPorts :: forall a. Eff Seam.AppEffects a -> IO a
    runPorts act =
      runAppIO env (inject act)
        >>= either (\e -> ioError (userError ("shomei infrastructure error: " <> Text.unpack (tshow e)))) pure
    tshow = Text.pack . show
