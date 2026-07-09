-- The @AuthServerData@ instance is an unavoidable orphan (the family and @AuthProtect@
-- belong to servant; the principal type is the core's 'AuthClaims') — the standard
-- generalized-auth pattern. Silence the orphan warning for this module.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The downstream service of the microservice deployment model: it verifies Shōmei's
-- JWTs /locally/, never calling the auth service per request.
--
-- This module is the recommended template for downstream services; copy it. Its 'JwksCache'
-- is shaped for production, not for brevity:
--
-- * __Lock-free reads.__ The hot path is one 'readIORef' and one clock read. Request threads
--   never contend on a lock to verify a token.
-- * __Single-flight refresh.__ At most one JWKS fetch is in flight at a time, however many
--   requests arrive.
-- * __Refresh-ahead.__ The refetch is kicked at 80% of the entry's TTL and runs in the
--   background, so a healthy auth service means no request ever waits on a fetch. The only
--   synchronous fetch is the cold start, before the first successful fetch.
-- * __Stale-on-error.__ If the auth service is unreachable, the last good key set keeps
--   serving requests (each failed refresh logs one line to stderr). Shōmei rotates keys on
--   operator action and keeps retired keys published, so a key set fetched hours ago still
--   verifies correctly-issued tokens.
-- * __Fail closed.__ Staleness is nonetheless bounded: past @maxStaleness@ (default 24 h)
--   'currentJwks' throws 'JwksUnavailable' and the auth handler answers @503@, not @401@.
--   The token was never judged invalid; the verifier is impaired.
-- * __@Cache-Control: max-age@ is honored__ when the JWKS response carries it.
--
-- Each request's Bearer token is verified offline with @shomei-jwt@'s 'verifyToken' against
-- the cached keys. This service deliberately does not depend on @shomei-postgres@ and has no
-- database.
module Downstream.Service
  ( JwksCache,
    newJwksCache,
    currentJwks,
    JwksUnavailable (..),
    downstreamApplication,
    Project (..),
    DownstreamAPI,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, putMVar, tryTakeMVar, withMVar)
import Control.Exception (Exception, finally, throwIO, try)
import Crypto.JOSE.JWK (JWKSet)
import Data.Aeson (eitherDecode)
import Data.ByteString.Char8 qualified as BS8
import Data.Char (toLower)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (NominalDiffTime, diffUTCTime)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (ResponseHeaders, hCacheControl)
import Network.HTTP.Types.Status (statusCode, statusIsSuccessful)
import Network.Wai (Application, Request, requestHeaders)
import Servant
  ( Context (EmptyContext, (:.)),
    Get,
    Handler,
    JSON,
    err401,
    err503,
    errBody,
    serveWithContext,
    throwError,
    type (:>),
  )
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Server.Experimental.Auth
  ( AuthHandler,
    AuthServerData,
    mkAuthHandler,
  )
import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Claims (AuthClaims)
import Shomei.Jwt.Verify (verifyToken)
import Shomei.Prelude hiding (Context)
import System.IO (stderr)

-- | One cached fetch result. 'effectiveTtl' is the configured TTL unless the JWKS response
-- carried @Cache-Control: max-age@, which then wins.
data CacheEntry = CacheEntry
  { entryJwks :: !JWKSet,
    fetchedAt :: !UTCTime,
    effectiveTtl :: !NominalDiffTime
  }

-- | A cache of the auth service's public 'JWKSet' with a lock-free read path.
data JwksCache = JwksCache
  { cacheMgr :: !HTTP.Manager,
    cacheUrl :: !String,
    configuredTtl :: !NominalDiffTime,
    maxStaleness :: !NominalDiffTime,
    -- | Lock-free read path: every request does one 'readIORef', nothing else. A whole-entry
    -- swap is safe because 'CacheEntry' is immutable.
    cacheEntry :: !(IORef (Maybe CacheEntry)),
    -- | Single-flight guard: full @()@ means no refresh is running. Deliberately not the
    -- data holder — a held lock must never make readers wait. The one thread that wins
    -- 'tryTakeMVar' becomes the refresher; everyone else proceeds on the old value.
    refreshLock :: !(MVar ())
  }

-- | Thrown (and mapped to HTTP 503) when no key set within 'maxStaleness' exists: either the
-- cold-start fetch failed, or every refresh has failed for longer than the staleness bound.
newtype JwksUnavailable = JwksUnavailable String
  deriving stock (Show)
  deriving anyclass (Exception)

-- | Fraction of an entry's TTL after which a background refresh is kicked. Early enough to
-- absorb a slow fetch, late enough not to refetch wastefully — so a healthy auth service
-- never lets an entry actually expire, and the latency cliff at TTL never occurs.
refreshAheadFactor :: NominalDiffTime
refreshAheadFactor = 0.8

-- | Build a cache against the auth service's JWKS URL.
--
-- @newJwksCache mgr url ttl maxStale@ refreshes an entry once it is older than @0.8 * ttl@
-- and refuses to serve one older than @maxStale@.
newJwksCache :: HTTP.Manager -> String -> NominalDiffTime -> NominalDiffTime -> IO JwksCache
newJwksCache mgr url ttl maxStale = do
  entry <- newIORef Nothing
  lock <- newMVar ()
  pure
    JwksCache
      { cacheMgr = mgr,
        cacheUrl = url,
        configuredTtl = ttl,
        maxStaleness = maxStale,
        cacheEntry = entry,
        refreshLock = lock
      }

-- | The cached 'JWKSet'. This is the ONLY place the downstream service contacts the auth
-- service, and it never does so on the request thread except at cold start.
--
-- Throws 'JwksUnavailable' when the first fetch fails, or when the cached set is older than
-- 'maxStaleness'.
currentJwks :: JwksCache -> IO JWKSet
currentJwks cache = do
  now <- getCurrentTime
  mEntry <- readIORef cache.cacheEntry
  case mEntry of
    Nothing -> coldStart cache
    Just entry ->
      let age = diffUTCTime now entry.fetchedAt
       in if age < refreshAheadFactor * entry.effectiveTtl
            then pure entry.entryJwks
            else refreshWindow cache entry age

-- | No key set has ever been fetched. Block on the lock, re-check (another thread may have
-- filled the cache while we waited), then fetch synchronously. There is nothing stale to
-- serve, so failure is fatal to this request.
coldStart :: JwksCache -> IO JWKSet
coldStart cache =
  withMVar cache.refreshLock \() -> do
    mEntry <- readIORef cache.cacheEntry
    case mEntry of
      Just entry -> pure entry.entryJwks
      Nothing -> do
        res <- fetchJwks cache.cacheMgr cache.cacheUrl
        case res of
          Left err -> throwIO (JwksUnavailable ("initial JWKS fetch failed: " <> err))
          Right (jwks, hdrs) -> do
            now <- getCurrentTime
            atomicWriteIORef cache.cacheEntry (Just (mkEntry cache now jwks hdrs))
            pure jwks

-- | The entry is past its refresh-ahead point. Kick a background refresh if nobody else is
-- refreshing, then answer from the entry in hand — unless it has aged past the hard bound,
-- in which case fail closed.
refreshWindow :: JwksCache -> CacheEntry -> NominalDiffTime -> IO JWKSet
refreshWindow cache entry age = do
  mLock <- tryTakeMVar cache.refreshLock
  forM_ mLock \() ->
    void (forkIO (refreshOnce cache age `finally` putMVar cache.refreshLock ()))
  if age < cache.maxStaleness
    then pure entry.entryJwks
    else
      throwIO
        ( JwksUnavailable
            ( "last good JWKS is "
                <> show (round age :: Int)
                <> "s old, past the "
                <> show cache.maxStaleness
                <> " staleness bound"
            )
        )

-- | One background refresh. Failure is not fatal: the existing entry keeps serving, so the
-- auth service being down does not take this service down. It does get one log line.
refreshOnce :: JwksCache -> NominalDiffTime -> IO ()
refreshOnce cache age = do
  res <- fetchJwks cache.cacheMgr cache.cacheUrl
  case res of
    Right (jwks, hdrs) -> do
      now <- getCurrentTime
      atomicWriteIORef cache.cacheEntry (Just (mkEntry cache now jwks hdrs))
    Left err ->
      -- One strict write, not hPutStrLn: stderr is unbuffered, so a per-character write
      -- interleaves with anything else logging concurrently.
      BS8.hPut
        stderr
        ( BS8.pack
            ( "[downstream] jwks refresh failed (serving stale, age "
                <> show (round age :: Int)
                <> "s): "
                <> err
                <> "\n"
            )
        )

mkEntry :: JwksCache -> UTCTime -> JWKSet -> ResponseHeaders -> CacheEntry
mkEntry cache now jwks hdrs =
  CacheEntry
    { entryJwks = jwks,
      fetchedAt = now,
      effectiveTtl = fromMaybe cache.configuredTtl (parseMaxAge hdrs)
    }

-- | Fetch and parse the JWKS, /returning/ failures rather than throwing: the refresh path
-- must not use exceptions for control flow. Note @parseRequest@ does not check the status
-- code, so we do.
fetchJwks :: HTTP.Manager -> String -> IO (Either String (JWKSet, ResponseHeaders))
fetchJwks mgr url = do
  res <- try @HTTP.HttpException do
    req <- HTTP.parseRequest url
    HTTP.httpLbs req mgr
  pure case res of
    Left err -> Left (describeHttpError err)
    Right resp
      | not (statusIsSuccessful (HTTP.responseStatus resp)) ->
          Left ("JWKS fetch returned HTTP " <> show (statusCode (HTTP.responseStatus resp)))
      | otherwise -> case eitherDecode (HTTP.responseBody resp) of
          Right jwks -> Right (jwks, HTTP.responseHeaders resp)
          Left err -> Left ("JWKS parse failed: " <> err)

-- | Render an 'HTTP.HttpException' as one line.
--
-- Neither 'show' nor 'displayException' will do: @HttpExceptionRequest@ pretty-prints the
-- entire 'HTTP.Request' record over some twenty lines, which would turn each refresh failure
-- into a twenty-line stderr dump. The request is not news — the cache only ever fetches one
-- URL — so drop it and keep the cause.
describeHttpError :: HTTP.HttpException -> String
describeHttpError = \case
  HTTP.InvalidUrlException url reason -> "invalid JWKS URL " <> url <> ": " <> reason
  HTTP.HttpExceptionRequest _req content -> unwords (words (show content))

-- | When the key publisher states a freshness lifetime, obey it — that is the JWKS-over-HTTPS
-- convention, and it makes this template correct against non-Shōmei issuers.
--
-- Shōmei's own server does __not__ currently send @Cache-Control@ on
-- @\/.well-known\/jwks.json@; adding it server-side is a possible follow-up. This branch
-- therefore lies dormant against a Shōmei auth service and the configured TTL applies.
--
-- The scan is lenient: @Cache-Control@ is a comma-separated directive list, directive names
-- are case-insensitive, and anything unparsable means "use the configured TTL".
parseMaxAge :: ResponseHeaders -> Maybe NominalDiffTime
parseMaxAge hdrs = do
  raw <- lookup hCacheControl hdrs
  scan (BS8.map toLower raw)
  where
    scan bs
      | BS8.null bs = Nothing
      | Just rest <- BS8.stripPrefix "max-age=" bs =
          case BS8.readInt rest of
            Just (n, _) | n >= 0 -> Just (fromIntegral n)
            _ -> Nothing
      | otherwise = scan (BS8.drop 1 bs)

-- | A trivial business resource this downstream service owns.
data Project = Project
  { projectId :: !Text,
    projectName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

-- | This service's own protected API. The combinator is a LOCAL @AuthProtect@ whose
-- 'AuthHandler' verifies the JWT offline using the fetched JWKS; there is no Shōmei
-- dependency beyond the verifier and the config/claims types.
type DownstreamAPI =
  AuthProtect "downstream-jwt" :> "projects" :> Get '[JSON] [Project]

type instance AuthServerData (AuthProtect "downstream-jwt") = AuthClaims

-- | The downstream WAI app: serve @\/projects@ behind the local-verification guard, using
-- the supplied JWKS cache and the 'ShomeiConfig' carrying the issuer/audience the auth
-- service signs with (so local verification matches).
downstreamApplication :: JwksCache -> ShomeiConfig -> Application
downstreamApplication cache cfg =
  serveWithContext (Proxy @DownstreamAPI) (localAuthHandler cache cfg :. EmptyContext) projectsHandler

-- | The local guard: pull @Authorization: Bearer <jwt>@ and verify with the cached JWKS —
-- no call back to the auth service.
--
-- The two failure modes are distinct on the wire. A token we can judge and reject is @401@.
-- A token we cannot judge — no sufficiently fresh key material — is @503@: answering @401@
-- there would make clients discard perfectly good sessions during an auth-service outage.
localAuthHandler :: JwksCache -> ShomeiConfig -> AuthHandler Request AuthClaims
localAuthHandler cache cfg = mkAuthHandler \req -> do
  jwt <- case lookup "Authorization" (requestHeaders req) of
    Just v | Just b <- Text.stripPrefix "Bearer " (Text.decodeUtf8 v) -> pure b
    _ -> throwError err401 {errBody = "missing bearer token"}
  jwks <- liftIO (try @JwksUnavailable (currentJwks cache))
  case jwks of
    Left _ -> throwError err503 {errBody = "verification keys unavailable"}
    Right keys -> do
      res <- liftIO (verifyToken keys cfg jwt)
      case res of
        Right claims -> pure claims
        Left _ -> throwError err401 {errBody = "invalid token (local verification failed)"}

projectsHandler :: AuthClaims -> Handler [Project]
projectsHandler _claims =
  pure [Project {projectId = "proj_ms_1", projectName = "Downstream-verified Project"}]
