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

import Control.Concurrent (forkIO)
import Data.Aeson ((.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (DiffTime, picosecondsToDiffTime, secondsToDiffTime)
import Effectful (Eff, inject, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Pool qualified as Pool
import Network.HTTP.Client.TLS (newTlsManager)
import Network.Wai (Application, Request)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
  ( Context (EmptyContext, (:.)),
    ErrorFormatters,
    serveWithContext,
  )
import Servant.Server.Experimental.Auth (AuthHandler)
import Shomei.Config (OAuthConfig (..), ObservabilityConfig (..), ShomeiConfig (..), SigningKeyConfig (..), TotpConfig (..), configSigningAlgorithm)
import Shomei.Crypto (Argon2Params (..), argon2WarningFloor, hashingLimit, newHashingLimiter, sha256Hex)
import Shomei.Domain.Claims (Issuer (..), Role (..))
import Shomei.Domain.LoginAttempt (AccountKey (..))
import Shomei.Error (AuthError)
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)
import Shomei.Postgres.Database (runDatabasePool)
import Shomei.Postgres.Maintenance (sweepOnce, sweepReportCounts)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.RoleStore (runRoleStorePostgres)
import Shomei.Postgres.TotpCredentialStore (TotpEncryptionKey, totpEncryptionKeyFromBase64, totpEncryptionKeyFromBytes)
-- '(.=)' is hidden from the prelude (it re-exports lens's state-setter of the same name);
-- we mean aeson's JSON pair constructor here.
import Shomei.Prelude hiding (Context, (.=))
import Shomei.Servant.API (shomeiRoutesAPI)
import Shomei.Servant.Auth (AuthUser, authHandler)
import Shomei.Servant.Error (shomeiErrorFormatters)
import Shomei.Servant.Handlers (shomeiRoutes)
import Shomei.Servant.Middleware (problemMiddleware)
import Shomei.Servant.Oidc (isAbsoluteHttpUrl)
import Shomei.Servant.Seam qualified as Seam
import Shomei.Server.App (Env (..), runAppIO)
import Shomei.Server.Config (ServerSettings (..), SweepSettings (..), loadConfig, toSweepConfig)
import Shomei.Server.Keys (LoadedKeys (..), bootstrapKeys, loadKekFromEnv, reloadKeys)
import Shomei.Server.Middleware.BodyLimit (bodyLimitMiddleware, defaultBodyLimitBytes)
import Shomei.Server.Middleware.RateLimit (newRateLimiter, rateLimitMiddleware)
import Shomei.Server.Observability.Logging (logServerError, requestLoggingMiddleware)
import Shomei.Server.Observability.Metrics (metricsEndpointMiddleware, metricsMiddleware, newMetrics)
import Shomei.Server.Supervisor (logJsonLine, supervisedLoop)
import Shomei.Workflow.Roles (undefinedDefaultRoles)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
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
  -- Warn, never refuse: a resource-starved dev box legitimately wants cheap hashing, but an
  -- operator must not weaken password storage without seeing it said out loud.
  traverse_
    (\w -> hPutStrLn stderr ("[shomei] WARNING: " <> Text.unpack w))
    (argon2WarningFloor settings.serverArgon2)
  validateOidcIssuer cfg
  env <- buildEnv cfg settings
  validateDefaultRoles cfg env
  installKeyReload cfg env
  installSweeper settings env
  rl <- newRateLimiter cfg.rateLimitConfig
  metrics <- newMetrics
  let obs = cfg.observabilityConfig
      -- IP-4 realized middleware order (outermost first): EP-3 request-id + JSON logging,
      -- then EP-3 HTTP metrics, then EP-3's raw /metrics endpoint, then EP-4's request-body
      -- cap, then EP-2's rate limiter, then the Servant app. Logging is outermost so even a
      -- 429 is logged with a correlation id; metrics wrap the limiter so a throttled request
      -- is still counted. The body cap sits inside metrics so its 413s are counted and logged
      -- like any other response, and outside the limiter so a flood of oversized bodies is
      -- refused without draining anyone's token bucket.
      withMetrics =
        if obs.metricsEnabled
          then metricsMiddleware metrics . metricsEndpointMiddleware metrics
          else id
      stack =
        requestLoggingMiddleware obs
          . withMetrics
          . bodyLimitMiddleware defaultBodyLimitBytes
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
      -- An exception escaping a handler must land on stdout as a structured line, next to the
      -- request lines, rather than as warp's default unstructured prose on stderr.
      -- 'Warp.defaultShouldDisplayException' filters the routine ones (a client hanging up
      -- mid-request is not an incident).
      onServerException mreq e =
        when (Warp.defaultShouldDisplayException e) (logServerError mreq e)
      warpSettings =
        Warp.setPort settings.serverPort
          . Warp.setGracefulShutdownTimeout (Just obs.gracefulShutdownTimeoutSeconds)
          . Warp.setServerName "shomei"
          . Warp.setOnException onServerException
          $ Warp.setInstallShutdownHandler installShutdown Warp.defaultSettings
  hPutStrLn stderr ("[shomei] listening on :" <> show settings.serverPort)
  Warp.runSettings warpSettings (stack (application env))
  hPutStrLn stderr "[shomei] drain complete; closing connection pool"
  Pool.release env.envPool
  hPutStrLn stderr "[shomei] shutdown complete"

-- | Refuse to start with the OIDC provider enabled and an issuer that is not an absolute
-- @http(s)@ URL.
--
-- The issuer doubles as the provider's public base URL: every endpoint in the discovery document
-- is derived from it, and ID tokens carry it as @iss@. With the default issuer @"shomei"@ the
-- document would advertise @shomei\/oauth\/token@ — a relative URL no client can fetch — and the
-- failure would surface as an inscrutable error inside someone else's OIDC library. Checked
-- before the pool is acquired, because it needs nothing but config.
validateOidcIssuer :: ShomeiConfig -> IO ()
validateOidcIssuer cfg =
  when (cfg.oauthConfig.oidcEnabled && not (isAbsoluteHttpUrl iss)) do
    hPutStrLn
      stderr
      ( "shomei-server: oidcEnabled is set but issuer is not an absolute http(s) URL: "
          <> show iss
          <> "\nThe OIDC issuer is also the base URL every published endpoint is derived from."
          <> "\nSet SHOMEI_ISSUER (or `issuer` in the config file) to this deployment's public"
          <> " base URL, e.g. https://auth.example.com"
      )
    exitFailure
  where
    iss = case cfg.issuer of Issuer t -> t

-- | Refuse to start when @defaultRoles@ names a role missing from the @shomei_roles@ registry.
--
-- Validating once here rather than on every signup keeps the hot path free of catalog reads and
-- turns a config typo into an immediate, obvious startup failure instead of a stream of 500s on
-- an endpoint nobody is watching. The registry is append-only, so a role validated here cannot
-- later disappear — which is why 'Shomei.Workflow.Roles.applyDefaultRoles' does not re-check.
--
-- An embedding host that sets @defaultRoles@ should call
-- 'Shomei.Workflow.Roles.undefinedDefaultRoles' the same way where it assembles its ports.
validateDefaultRoles :: ShomeiConfig -> Env -> IO ()
validateDefaultRoles cfg env = do
  outcome <-
    runEff
      . runErrorNoCallStack @AuthError
      . runDatabasePool env.envPool
      . runRoleStorePostgres
      $ undefinedDefaultRoles cfg
  case outcome of
    Left e -> die ("could not validate defaultRoles against the role registry: " <> show e)
    Right missing
      | Set.null missing -> pure ()
      | otherwise -> do
          let names = Text.intercalate ", " [r | Role r <- Set.toList missing]
              first' = case Set.toList missing of
                Role r : _ -> r
                [] -> "<role>"
          die
            ( "defaultRoles names undefined roles: "
                <> Text.unpack names
                <> "\ndefine them first: shomei-admin roles define "
                <> Text.unpack first'
            )
  where
    die msg = hPutStrLn stderr ("shomei-server: " <> msg) >> exitFailure

-- | Install the two triggers that refresh signing-key material on a running server, so
-- @shomei-admin keys activate@ / @keys revoke@ take effect with no restart: a periodic
-- background reload every @refreshIntervalSeconds@ (0 disables it), and a @SIGHUP@ handler
-- for a deterministic "apply now". Both call 'reloadKeys', which keeps the last good
-- material if a reload fails.
--
-- The periodic reload runs on 'supervisedLoop', the shared supervised-background-thread
-- idiom: a crash is logged and retried with backoff rather than killing the loop, and the
-- thread dies with the process. Note that 'supervisedLoop' runs its first cycle immediately,
-- so a reload happens right after 'bootstrapKeys' — harmless, since 'reloadKeys' is idempotent
-- and keeps the last good material on failure.
installKeyReload :: ShomeiConfig -> Env -> IO ()
installKeyReload cfg env = do
  when (interval > 0) (void (forkIO (supervisedLoop "key-reload" interval reload)))
  void (installHandler sigHUP (Signals.Catch onHup) Nothing)
  where
    interval = cfg.signingKeyConfig.refreshIntervalSeconds
    reload = reloadKeys env.envKek env.envPool env.envKeys
    onHup = hPutStrLn stderr "[shomei] SIGHUP: reloading signing keys" >> reload

-- | Fork the background expired-data sweeper, unless the operator disabled it in favor of
-- scheduling @shomei-admin sweep@ externally. It shares the server's connection pool.
--
-- A 'Left' from 'sweepOnce' means the database was unreachable or a statement failed. That is
-- an ordinary outcome for periodic maintenance, not a crash: it is logged and the loop sleeps
-- a normal interval rather than entering 'supervisedLoop''s backoff, which is reserved for
-- genuine exceptions.
installSweeper :: ServerSettings -> Env -> IO ()
installSweeper settings env =
  when sweep.sweepEnabled do
    hPutStrLn
      stderr
      ( "[shomei] sweeper: every "
          <> show sweep.sweepIntervalSeconds
          <> "s, audit retention "
          <> maybe "disabled (retain forever)" (\d -> show d <> " days") sweep.sweepAuthEventRetentionDays
      )
    void (forkIO (supervisedLoop "sweeper" sweep.sweepIntervalSeconds oneCycle))
  where
    sweep = settings.serverSweep
    oneCycle = do
      -- Wall-clock time decides which rows are expired; a monotonic clock measures how long
      -- the sweep took, so an NTP step cannot produce a negative duration.
      cutoffNow <- getCurrentTime
      startTick <- getMonotonicTimeNSec
      result <- sweepOnce env.envPool (toSweepConfig sweep) cutoffNow
      endTick <- getMonotonicTimeNSec
      logSweepCycle (durationMs startTick endTick) result

    durationMs startTick endTick =
      fromIntegral (endTick - startTick) / 1_000_000 :: Double

    logSweepCycle elapsed = \case
      Left err ->
        logJsonLine
          [ "level" .= ("error" :: Text),
            "msg" .= ("sweep failed" :: Text),
            "task" .= ("sweeper" :: Text),
            "error" .= Text.pack (show err),
            "duration_ms" .= elapsed
          ]
      Right report ->
        logJsonLine
          ( [ "level" .= ("info" :: Text),
              "msg" .= ("sweep" :: Text)
            ]
              <> [Key.fromText table .= deleted | (table, deleted) <- sweepReportCounts report]
              <> ["duration_ms" .= elapsed]
          )

-- | Run the schema migrations (idempotent), acquire the pool, and bootstrap the signing
-- key, yielding the assembled 'Env'. Shared by 'main' and by host applications that embed
-- the Shōmei API (the embedded demo builds its own 'Env' this way). Running
-- @shomei-migrate@ out-of-band is also supported for production.
buildEnv :: ShomeiConfig -> ServerSettings -> IO Env
buildEnv cfg settings = do
  _ <- runShomeiMigrationsNoCheck (coddSettingsFromConnString settings.serverConnStr) (secondsToDiffTime 60)
  hPutStrLn
    stderr
    ( "[shomei] db pool: size "
        <> show settings.serverDbPoolSize
        <> ", acquisition timeout "
        <> show settings.serverDbPoolAcquisitionTimeoutMs
        <> "ms"
    )
  pool <- acquirePool settings.serverDbPoolSize (millisToDiffTime settings.serverDbPoolAcquisitionTimeoutMs) settings.serverConnStr
  kek <- loadKekFromEnv
  totpKey <- loadTotpKeyFromEnv cfg
  keys <- bootstrapKeys kek (configSigningAlgorithm cfg) pool
  keysRef <- newIORef keys
  mgr <- newTlsManager
  limiter <- newHashingLimiter settings.serverHashingMaxConcurrency
  hPutStrLn
    stderr
    ( "[shomei] hashing concurrency "
        <> show (hashingLimit limiter)
        <> ", argon2 m="
        <> show settings.serverArgon2.memoryKiB
        <> "KiB,t="
        <> show settings.serverArgon2.iterations
        <> ",p="
        <> show settings.serverArgon2.parallelism
    )
  pure
    Env
      { envPool = pool,
        envConfig = cfg,
        envKeys = keysRef,
        envKek = kek,
        envHttpManager = mgr,
        envArgon2Params = settings.serverArgon2,
        envHashingLimiter = limiter,
        envTotpKey = totpKey
      }

-- | The AES-256-GCM key that encrypts stored TOTP secrets (EP-7), loaded from
-- @SHOMEI_TOTP_ENCRYPTION_KEY@ (base64 of exactly 32 bytes; generate one with
-- @openssl rand -base64 32@).
--
-- When TOTP is enabled and the variable is absent or malformed, the server refuses to boot with
-- a loud message — an enabled factor whose secrets cannot be encrypted is a silent data-loss
-- trap. When TOTP is disabled the store is unreachable (enrollment is refused), so a valid key is
-- optional; a dummy all-zero key keeps the interpreter-stack shape fixed. A key supplied while
-- disabled is still validated, so a typo is caught before it is switched on.
loadTotpKeyFromEnv :: ShomeiConfig -> IO TotpEncryptionKey
loadTotpKeyFromEnv cfg = do
  raw <- lookupEnv "SHOMEI_TOTP_ENCRYPTION_KEY"
  let enabled = cfg.totpConfig.totpEnabled
  case fmap Text.pack raw of
    Just t | not (Text.null (Text.strip t)) ->
      case totpEncryptionKeyFromBase64 t of
        Right k -> pure k
        Left err -> die ("SHOMEI_TOTP_ENCRYPTION_KEY " <> Text.unpack err)
    _
      | enabled -> die "SHOMEI_TOTP_ENCRYPTION_KEY is required when totpEnabled is set (generate one with: openssl rand -base64 32)"
      | otherwise -> either (die . Text.unpack) pure (totpEncryptionKeyFromBytes (BS.replicate 32 0))
  where
    die msg = hPutStrLn stderr ("[shomei] " <> msg) >> exitFailure

-- | Milliseconds to a 'DiffTime', exactly (a 'DiffTime' counts picoseconds, so this loses
-- nothing). Used for the pool's acquisition timeout, which config carries as an integer count
-- of milliseconds.
millisToDiffTime :: Int -> DiffTime
millisToDiffTime ms = picosecondsToDiffTime (fromIntegral ms * 1_000_000_000)

-- | Build the WAI 'Application': EP-5's server with the @AuthProtect "shomei-jwt"@
-- 'Context', whose verifier closes over this 'Env's JWKSet and config so verification
-- uses exactly the keys the server signs with.
--
-- The served tree is 'shomeiRoutesAPI' (EP-3): application routes under @\/v1@, JWKS and the
-- probes at unversioned root paths.
--
-- 'problemMiddleware' converts Servant's one un-formattable failure — the bare @405@ a method
-- mismatch raises below any 'ErrorFormatters' hook — into a problem document, so /every/ error
-- the process emits carries the same envelope.
application :: Env -> Application
application env = problemMiddleware (serveWithContext shomeiRoutesAPI (authContext senv) (shomeiRoutes senv))
  where
    senv = seamEnv env

-- | The Servant 'Context' carrying the @AuthProtect "shomei-jwt"@ 'AuthHandler' (built from the
-- seam env's verifier) and the 'ErrorFormatters' that render Servant's own body-parse,
-- url-parse, header-parse, and not-found failures as RFC 7807 problem documents. A host app
-- embedding 'ShomeiAPI' serves with this same context.
authContext :: Seam.Env -> Context '[AuthHandler Request AuthUser, ErrorFormatters]
authContext senv =
  authHandler senv
    :. shomeiErrorFormatters
    :. EmptyContext

-- | Build EP-5's seam 'Seam.Env' from this server's assembly 'Env'. The port runner
-- bridges EP-5's smaller stack onto the PostgreSQL stack with @inject@; an
-- infrastructure 'Left' is raised as an IO exception (warp → 500).
seamEnv :: Env -> Seam.Env
seamEnv env =
  Seam.Env
    { Seam.runPorts = runPorts,
      Seam.config = env.envConfig,
      -- The JWKS getter reads swappable key material, so a rotation applied by 'reloadKeys'
      -- takes effect on the next request without rebuilding the WAI application. Token
      -- verification now goes through 'Seam.runPorts'; 'runAppIO' also re-reads these keys.
      Seam.jwksJson = (.jwksBody) <$> readIORef env.envKeys,
      Seam.accountKeyOf = AccountKey . sha256Hex
    }
  where
    runPorts :: forall a. Eff Seam.AppEffects a -> IO a
    runPorts act =
      runAppIO env (inject act)
        >>= either (\e -> ioError (userError ("shomei infrastructure error: " <> Text.unpack (tshow e)))) pure
    tshow = Text.pack . show
