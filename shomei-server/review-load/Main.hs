{-# LANGUAGE ScopedTypeVariables #-}

-- | Isolated MasterPlan 9 workload. No caller-supplied database or HTTP target is accepted.
module Main (main) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (forM, forM_, replicateM_, unless, void)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.IORef (newIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID qualified as UUID
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (Header, statusCode, urlEncode)
import Network.Wai.Handler.Warp qualified as Warp
import Servant.Health (ProbeVerdict (Healthy))
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..), defaultArgon2Params, newHashingLimiter)
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (ObservabilityConfig (..), RateLimitConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Id (UserId, genUserId, idText, parseId, userIdToUUID)
import Shomei.Mfa.Totp.Postgres (totpEncryptionKeyFromBytes)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Notify (noNotifierSecrets)
import Shomei.Notify.Queue (newNotifierQueue)
import Shomei.Persistence.Database.Postgres (defaultTransactionRetryPolicy)
import Shomei.Persistence.Pool.Postgres (Pool, acquirePool)
import Shomei.Persistence.Pool.Postgres qualified as Pool
import Shomei.Servant.Api (shomeiThrottledRoutes)
import Shomei.Servant.CachedJson (cachedJsonBytes)
import Shomei.Servant.OpenApi (openApiDocument)
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application, hostMiddleware)
import Shomei.Server.Config (ProxyProtocolMode (..), ServerSettings (..), defaultSweepSettings)
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Server.Middleware.RateLimit (newRateLimiterFor)
import Shomei.Server.Middleware.TrustedProxy (emptyTrustedProxies)
import Shomei.Server.Observability.Metrics (newMetrics)
import Shomei.Server.Runtime (hostWarpSettings)
import Shomei.SigningKey.Domain (SigningAlgorithm (ES256))
import Shomei.SigningKey.Protection.Jwt (keyEncryptionKeyFromBase64)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (getArgs, setEnv)
import System.Exit (ExitCode (ExitSuccess), exitFailure)
import System.IO (hClose, hPutStrLn, openBinaryTempFile, stderr)
import System.Mem (performGC)
import System.Posix.Process (getProcessID)
import System.Process (readProcess, readProcessWithExitCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  (scenario, output) <- case args of
    ["--scenario", s, "--output", out] | s `elem` ["all", "sessions", "openapi", "argon2"] -> pure (s, out)
    _ -> hPutStrLn stderr "expected --scenario all|sessions|openapi|argon2 --output PATH; external targets are refused" >> exitFailure
  result <- timeout 180000000 (try @SomeException (workload scenario))
  case result of
    Just (Right report) -> LBS.writeFile output (encode report <> "\n")
    _ -> do
      LBS.writeFile output (encode (object ["scenario" .= scenario, "error_count" .= (1 :: Int), "result" .= ("failed_or_timed_out" :: Text)]) <> "\n")
      hPutStrLn stderr "isolated review workload failed; no credential-bearing exception is emitted"
      exitFailure

settings :: ServerSettings
settings =
  ServerSettings
    { serverPort = 0,
      serverBindHost = "127.0.0.1",
      serverMaxConnections = 1024,
      serverSlowClientTimeoutSeconds = 30,
      serverConnStr = "",
      serverTrustedProxies = emptyTrustedProxies,
      serverProxyProtocol = ProxyProtocolOff,
      serverDbPoolSize = 8,
      serverDbPoolAcquisitionTimeoutMs = 10000,
      serverDbStatementTimeoutMs = 30000,
      serverDbTransactionMaxAttempts = 3,
      serverDbTransactionDeadlineMs = 5000,
      serverNotifierQueueSize = 1024,
      serverWarnings = [],
      serverSweep = defaultSweepSettings,
      serverArgon2 = defaultArgon2Params,
      serverHashingMaxConcurrency = 2
    }

workload :: String -> IO Value
workload scenario = withShomeiMigratedDatabase \conn -> bracket (acquirePool 8 10 30000 conn) Pool.release \pool -> do
  started <- getMonotonicTimeNSec
  let base = defaultShomeiConfig (Issuer "review-fixture") (Audience "review-fixture")
      cfg = base {rateLimitConfig = base.rateLimitConfig {rateLimitEnabled = False}, observabilityConfig = base.observabilityConfig {requestLoggingEnabled = False, metricsEnabled = False}}
      kek = either (error . Text.unpack) id (keyEncryptionKeyFromBase64 "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
      totpKey = either (error . Text.unpack) id (totpEncryptionKeyFromBytes (BS.replicate 32 0))
  keys <- newIORef =<< bootstrapKeys kek ES256 pool
  manager <- HTTP.newManager (HTTP.managerSetProxy HTTP.noProxy HTTP.defaultManagerSettings {HTTP.managerResponseTimeout = HTTP.responseTimeoutMicro 5000000})
  hashing <- newHashingLimiter 2
  queue <- newNotifierQueue 1024
  limiter <- newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig
  metrics <- newMetrics
  runtime <- hostWarpSettings cfg settings Warp.defaultSettings
  let env =
        Env
          { envPool = pool,
            envDbRetryPolicy = defaultTransactionRetryPolicy,
            envConfig = cfg,
            envKeys = keys,
            envKek = kek,
            envHttpManager = manager,
            envNotifierSecrets = noNotifierSecrets,
            envNotifierQueue = queue,
            envArgon2Params = defaultArgon2Params,
            envHashingLimiter = hashing,
            envTotpKey = totpKey
          }
      app = hostMiddleware cfg settings limiter metrics (application env (pure Healthy) (pure Healthy))
  Warp.testWithApplicationSettings runtime (pure app) \port -> do
    let origin = "http://127.0.0.1:" <> show port
    hPutStrLn stderr "[review-load] session fixture and workload"
    sessions <- if scenario `elem` ["all", "sessions"] then sessionWork pool manager origin else pure Null
    hPutStrLn stderr "[review-load] repeated OpenAPI workload"
    openapi <- if scenario `elem` ["all", "openapi"] then openApiWork manager origin else pure Null
    hPutStrLn stderr "[review-load] bounded Argon2 workload"
    argon2 <- if scenario `elem` ["all", "argon2"] then argonWork origin else pure Null
    ended <- getMonotonicTimeNSec
    pure
      ( object
          [ "scenario" .= scenario,
            "target" .= ("isolated_loopback" :: Text),
            "error_count" .= (0 :: Int),
            "wall_ms" .= (fromIntegral (ended - started) / 1000000 :: Double),
            "configuration"
              .= object
                [ "argon2_memory_kib" .= defaultArgon2Params.memoryKiB,
                  "argon2_iterations" .= defaultArgon2Params.iterations,
                  "argon2_parallelism" .= defaultArgon2Params.parallelism,
                  "hashing_limit" .= (2 :: Int),
                  "rts_requested_capabilities" .= (2 :: Int),
                  "http_workers" .= (4 :: Int),
                  "rate_limit_enabled" .= False,
                  "max_connections" .= (1024 :: Int),
                  "total_deadline_seconds" .= (180 :: Int)
                ],
            "sessions" .= sessions,
            "openapi" .= openapi,
            "argon2" .= argon2
          ]
      )

failCheck :: Bool -> IO ()
failCheck condition = unless condition (ioError (userError "fixed workload acceptance failed"))

checked :: Either e a -> IO a
checked = either (const (ioError (userError "isolated fixture operation failed"))) pure

exec :: Pool -> Text -> IO ()
exec pool sql = checked =<< Pool.use pool (Session.script sql)

scalar :: Pool -> Text -> IO Int
scalar pool sql = fromIntegral <$> (checked =<< Pool.use pool (Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))))

request :: HTTP.Manager -> String -> BS.ByteString -> [Header] -> Maybe Value -> IO (HTTP.Response LBS.ByteString)
request manager url method headers body = do
  req <- HTTP.parseRequest url
  HTTP.httpLbs
    req
      { HTTP.method = method,
        HTTP.requestHeaders = headers,
        HTTP.redirectCount = 0,
        HTTP.requestBody = maybe (HTTP.RequestBodyBS BS.empty) (HTTP.RequestBodyLBS . encode) body
      }
    manager

textAt :: [Text] -> Value -> IO Text
textAt [] (String text) = pure text
textAt (field : rest) (Object fields) = maybe (checked (Left ())) (textAt rest) (KM.lookup (Key.fromText field) fields)
textAt _ _ = checked (Left ())

sessionWork :: Pool -> HTTP.Manager -> String -> IO Value
sessionWork pool manager origin = do
  let password = "review-fixture-correct-horse-42" :: Text
      json = [("Content-Type", "application/json")]
  signup <- request manager (origin <> "/v1/auth/signup") "POST" json (Just (object ["loginId" .= ("review-admin" :: Text), "password" .= password, "displayName" .= ("Review" :: Text)]))
  failCheck (statusCode (HTTP.responseStatus signup) == 201)
  doc <- checked (eitherDecode (HTTP.responseBody signup))
  uidText <- textAt ["user", "userId"] doc
  uid :: UserId <- checked (parseId uidText)
  let uidSql = "'" <> UUID.toText (userIdToUUID uid) <> "'"
  exec pool ("INSERT INTO shomei.shomei_role_grants(user_id,role,granted_at) VALUES(" <> uidSql <> ",'admin',now())")
  login <- request manager (origin <> "/v1/auth/login") "POST" json (Just (object ["loginId" .= ("review-admin" :: Text), "password" .= password]))
  failCheck (statusCode (HTTP.responseStatus login) == 200)
  loginDoc <- checked (eitherDecode (HTTP.responseBody login))
  token <- textAt ["token", "accessToken"] loginDoc
  target <- genUserId
  let targetSql = "'" <> UUID.toText (userIdToUUID target) <> "'"
      headers = [("Authorization", "Bearer " <> Text.encodeUtf8 token)]
      path = origin <> "/v1/admin/users/" <> Text.unpack (idText target) <> "/sessions"
  exec pool ("INSERT INTO shomei.shomei_users(user_id,login_id,status,created_at,updated_at) VALUES(" <> targetSql <> ",'review-target','active',now(),now()); INSERT INTO shomei.shomei_sessions(session_id,user_id,status,kind,created_at,expires_at) SELECT gen_random_uuid()," <> targetSql <> ",'active','interactive',now(),now()+interval '1 day' FROM generate_series(1,10000)")
  started <- getMonotonicTimeNSec
  let walk cursor ids pages = do
        failCheck (pages < 64)
        let suffix = maybe "" (\value -> "&before=" <> BS8.unpack (urlEncode True (Text.encodeUtf8 value))) cursor
        response <- request manager (path <> "?limit=200" <> suffix) "GET" headers Nothing
        failCheck (statusCode (HTTP.responseStatus response) == 200)
        page <- checked (eitherDecode (HTTP.responseBody response))
        values <- case page of
          Object fields | Just (Array rows) <- KM.lookup "sessions" fields -> traverse (textAt ["sessionId"]) (toList rows)
          _ -> checked (Left ())
        failCheck (length values <= 200 && Set.size (Set.fromList values) == length values && Set.null (Set.intersection ids (Set.fromList values)))
        let nextIds = Set.union ids (Set.fromList values)
            next = case page of
              Object fields -> case KM.lookup "nextCursor" fields of
                Just (String c) -> Just c
                _ -> Nothing
              _ -> Nothing
        case next of
          Nothing -> pure (Set.size nextIds, pages + 1)
          Just c -> walk (Just c) nextIds (pages + 1)
  (total, pages) <- walk Nothing Set.empty (0 :: Int)
  failCheck (total == 10000 && pages == 51)
  revoked <- request manager path "DELETE" headers Nothing
  failCheck (statusCode (HTTP.responseStatus revoked) == 204)
  count <- scalar pool ("SELECT count(*) FROM shomei.shomei_sessions WHERE user_id=" <> targetSql <> " AND status='revoked'")
  audits <- scalar pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type='session_revoked'"
  failCheck (count == 10000 && audits == 10000)
  ended <- getMonotonicTimeNSec
  pure
    ( object
        [ "fixture_sessions" .= total,
          "page_size" .= (200 :: Int),
          "pages" .= pages,
          "revoked" .= count,
          "audit_events" .= audits,
          "old_unbounded_page_rows" .= (10000 :: Int),
          "current_max_page_rows" .= (200 :: Int),
          "bulk_unit_of_work_contract_calls" .= (1 :: Int),
          "wall_ms" .= (fromIntegral (ended - started) / 1000000 :: Double)
        ]
    )

parallel :: [IO a] -> IO [a]
parallel actions =
  bracket
    ( forM actions \action -> do
        done <- newEmptyMVar
        worker <- forkIO (try @SomeException action >>= putMVar done)
        pure (worker, done)
    )
    (mapM_ (killThread . fst))
    (traverse (\(_, done) -> takeMVar done >>= either throwIO pure))

rssKiB :: IO Int
rssKiB = do
  performGC
  pid <- getProcessID
  raw <- readProcess "ps" ["-o", "rss=", "-p", show pid] ""
  maybe (checked (Left ())) pure (readMaybe raw)

openApiWork :: HTTP.Manager -> String -> IO Value
openApiWork manager origin = do
  let expected = cachedJsonBytes openApiDocument
      one = do
        response <- request manager (origin <> "/openapi.json") "GET" [] Nothing
        failCheck (statusCode (HTTP.responseStatus response) == 200 && HTTP.responseBody response == expected)
  one
  warm <- rssKiB
  started <- getMonotonicTimeNSec
  samples <- forM [1 .. 4 :: Int] \_ -> do
    void (parallel [replicateM_ count one | count <- [63, 63, 62, 62]])
    rssKiB
  ended <- getMonotonicTimeNSec
  -- Same process includes the bounded load generator. A fixed generous noise allowance
  -- catches retention proportional to 1000 document copies without treating RSS as exact.
  failCheck (maximum samples - warm < 32768)
  pure
    ( object
        [ "requests" .= (1000 :: Int),
          "workers" .= (4 :: Int),
          "error_count" .= (0 :: Int),
          "wire_bytes_per_response" .= LBS.length expected,
          "warm_rss_kib" .= warm,
          "batch_rss_kib" .= samples,
          "memory_growth_allowance_kib" .= (32768 :: Int),
          "observer_shares_process" .= True,
          "wall_ms" .= (fromIntegral (ended - started) / 1000000 :: Double)
        ]
    )

argonWork :: String -> IO Value
argonWork origin = bracket create removeFile \path -> do
  pid <- getProcessID
  forM_ [("LOAD_USERS", "4"), ("PROBE_COUNT", "100"), ("LOAD_SECONDS", "10"), ("SIGNUP_LOOPS", "0"), ("SERVER_PID", show pid), ("LOAD_JSON_OUTPUT", path)] (uncurry setEnv)
  (code, _, _) <- readProcessWithExitCode "sh" ["scripts/argon2-load-test.sh", origin] ""
  failCheck (code == ExitSuccess)
  checked . eitherDecode =<< LBS.readFile path
  where
    create = do
      directory <- getTemporaryDirectory
      (path, handle) <- openBinaryTempFile directory "shomei-review-argon2.json"
      hClose handle
      pure path
