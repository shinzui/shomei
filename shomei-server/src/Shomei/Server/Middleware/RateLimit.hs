-- | A per-IP request-rate limiter as a WAI 'Middleware' (EP-2, M4).
--
-- This is an in-process token bucket (an STM @TVar (HashMap ByteString Bucket)@ keyed by client
-- IP), deliberately NOT a distributed/Redis store: this plan targets a single-instance
-- deployment (see the MasterPlan Decision Log). Each bucket holds up to @capacity@ tokens and
-- refills at @refillPerSec@; a request with no token left is rejected with HTTP 429 BEFORE it
-- reaches the Servant application or the database. The limiter is scoped to the unauthenticated
-- POST endpoints (login/signup/refresh and EP-1's verify-email/password-reset request routes) so
-- authenticated traffic bearing a valid token is never throttled, and it is a no-op when
-- @rateLimitEnabled@ is False.
--
-- Distinct from the per-account brute-force lockout (which is PostgreSQL-backed and survives
-- restarts): this request-rate state is in-memory and resets on restart, which is acceptable
-- because it bounds raw request volume, not authentication failures.
--
-- == Bucket eviction (EP-4)
--
-- A bucket per client IP that is never removed is an unbounded-memory denial-of-service
-- primitive: a slow scan of the address space grows the map forever. Every @sweepEvery@
-- throttled requests, 'takeToken' therefore prunes — inside the same STM transaction it was
-- already running — every bucket that has refilled to capacity.
--
-- That policy is /semantically lossless/, which is why it needs no tuning knob: 'takeToken'
-- treats an absent key as a fresh full bucket, so a full bucket and a missing bucket are
-- indistinguishable to every subsequent request. No request that would have been throttled is
-- admitted, and none that would have been admitted is throttled. Cost is @O(size)@ once per
-- @sweepEvery@ calls, i.e. amortized @O(1)@. An idle server never prunes, which is harmless:
-- no requests means no new buckets either, so the map cannot grow while unpruned.
--
-- == Contention
--
-- All buckets live in one @TVar (HashMap ByteString Bucket)@ whose root pointer every
-- throttled request rewrites, so concurrent 'takeToken' transactions conflict and retry: the
-- limiter is a serialization point under very high concurrency. This is accepted for the
-- documented single-instance posture (throttled routes are the unauthenticated auth endpoints,
-- which are low-volume by construction, and each is about to spend ~100 ms in Argon2 anyway).
-- If it ever profiles hot, the escape hatch is to shard the map across N @TVar@s keyed by a
-- hash of the client IP; nothing outside this module observes the single-@TVar@ representation.
module Shomei.Server.Middleware.RateLimit
  ( RateLimiter,
    newRateLimiter,
    newRateLimiterWith,
    rateLimitMiddleware,
    throttledPath,
    takeToken,
    bucketCount,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (methodPost)
import Network.Socket (SockAddr (..))
import Network.Wai (Middleware, Request, pathInfo, remoteHost, requestMethod)
import Shomei.Config (RateLimitConfig (..))
import Shomei.Servant.Error (pcTooManyRequests)
import Shomei.Servant.Middleware (problemResponse)

-- | One bucket per client IP: current token level + last-refill time (POSIX seconds).
data Bucket = Bucket
  { tokens :: !Double,
    lastRefill :: !Double
  }

data RateLimiter = RateLimiter
  { buckets :: !(TVar (HashMap ByteString Bucket)),
    -- | Counts 'takeToken' calls since the last prune; see 'sweepEvery'.
    sweepCounter :: !(TVar Int),
    -- | Prune fully-refilled buckets every this many 'takeToken' calls (always >= 1).
    sweepEvery :: !Int,
    -- | perIpBurst
    capacity :: !Double,
    -- | perIpRequestsPerMinute / 60
    refillPerSec :: !Double,
    enabled :: !Bool
  }

-- | How many 'takeToken' calls pass between prunes. Large enough that the @O(size)@ prune is
-- lost in the noise of the Argon2 hash the throttled request is about to perform, small enough
-- that a scanning attacker cannot accumulate many buckets between sweeps.
defaultSweepEvery :: Int
defaultSweepEvery = 4096

-- | Build a limiter from the configured policy. Buckets are created lazily per client IP and
-- pruned once they refill (see the module haddock).
newRateLimiter :: RateLimitConfig -> IO RateLimiter
newRateLimiter = newRateLimiterWith defaultSweepEvery

-- | 'newRateLimiter' with the prune interval given explicitly. A test seam: production wants
-- 'newRateLimiter', but a test that had to issue 4096 requests to observe one prune would be
-- measuring the wrong thing. Values below 1 are clamped to 1.
newRateLimiterWith :: Int -> RateLimitConfig -> IO RateLimiter
newRateLimiterWith every cfg = do
  tv <- newTVarIO HM.empty
  counter <- newTVarIO 0
  pure
    RateLimiter
      { buckets = tv,
        sweepCounter = counter,
        sweepEvery = max 1 every,
        capacity = fromIntegral cfg.perIpBurst,
        refillPerSec = fromIntegral cfg.perIpRequestsPerMinute / 60,
        enabled = cfg.rateLimitEnabled
      }

-- | How many per-IP buckets the limiter is currently holding. Exposed so a test can assert the
-- map stays bounded; nothing in the server reads it.
bucketCount :: RateLimiter -> IO Int
bucketCount rl = HM.size <$> readTVarIO rl.buckets

-- | Try to take one token for @key@ at time @nowSecs@; 'True' = allowed, 'False' = rejected.
-- A new key starts with a full bucket.
--
-- Every @sweepEvery@ calls this also prunes fully-refilled buckets, in the same transaction.
-- The just-touched key survives its own sweep whenever it is not itself full — and when it is
-- full, dropping it changes nothing (see the module haddock's losslessness argument).
takeToken :: RateLimiter -> ByteString -> Double -> IO Bool
takeToken rl key nowSecs = atomically do
  m <- readTVar rl.buckets
  let Bucket lvl t0 = HM.lookupDefault (Bucket rl.capacity nowSecs) key m
      refilled = min rl.capacity (lvl + (nowSecs - t0) * rl.refillPerSec)
      allowed = refilled >= 1
      taken = if allowed then refilled - 1 else refilled
      updated = HM.insert key (Bucket taken nowSecs) m
  sinceSweep <- readTVar rl.sweepCounter
  if sinceSweep + 1 >= rl.sweepEvery
    then do
      writeTVar rl.sweepCounter 0
      writeTVar rl.buckets (HM.filter (not . fullyRefilled) updated)
    else do
      writeTVar rl.sweepCounter (sinceSweep + 1)
      writeTVar rl.buckets updated
  pure allowed
  where
    -- Would this bucket have refilled to capacity by now? Then it is indistinguishable from an
    -- absent key, and dropping it is observationally a no-op.
    fullyRefilled (Bucket lvl t0) = lvl + (nowSecs - t0) * rl.refillPerSec >= rl.capacity

-- | The WAI middleware. Passes non-throttled paths straight through.
rateLimitMiddleware :: RateLimiter -> Middleware
rateLimitMiddleware rl app req respond
  | not rl.enabled || not (throttledPath req) = app req respond
  | otherwise = do
      nowSecs <- realToFrac <$> getPOSIXTime
      allowed <- takeToken rl (clientKey req) nowSecs
      if allowed then app req respond else respond tooMany
  where
    -- The same RFC 7807 document every other error path returns, with @Retry-After@. This
    -- answers before Servant ever routes the request, so it cannot go through the handler
    -- error mapping — it shares the catalog constant instead.
    tooMany = problemResponse pcTooManyRequests Nothing

-- | The unauthenticated POST endpoints the limiter guards. Authenticated routes (which carry
-- a bearer token) are intentionally excluded.
--
-- The paths are matched literally, so they carry the @v1@ segment
-- 'Shomei.Servant.API.ShomeiRoutes' mounts the application routes under. A mismatch here does
-- not fail loudly — it silently lets every login attempt through — so any route move must
-- update this list.
throttledPath :: Request -> Bool
throttledPath req =
  requestMethod req == methodPost && pathInfo req `elem` unauthPaths
  where
    unauthPaths =
      [ ["v1", "auth", "login"],
        ["v1", "auth", "signup"],
        ["v1", "auth", "refresh"],
        ["v1", "auth", "verify-email", "request"],
        ["v1", "auth", "password-reset", "request"]
      ]

-- | The per-IP key: the client's host address WITHOUT the ephemeral source port (otherwise
-- each connection would get its own bucket). Behind a reverse proxy this is the proxy address; a
-- trusted @X-Forwarded-For@ policy is out of scope for this single-instance plan.
clientKey :: Request -> ByteString
clientKey req = case remoteHost req of
  SockAddrInet _ host -> Char8.pack (show host)
  SockAddrInet6 _ _ host _ -> Char8.pack (show host)
  other -> Char8.pack (show other)
