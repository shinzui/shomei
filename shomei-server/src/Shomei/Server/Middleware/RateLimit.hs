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
module Shomei.Server.Middleware.RateLimit
  ( RateLimiter,
    newRateLimiter,
    rateLimitMiddleware,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (methodPost, status429)
import Network.Socket (SockAddr (..))
import Network.Wai (Middleware, Request, pathInfo, remoteHost, requestMethod, responseLBS)
import Shomei.Config (RateLimitConfig (..))

-- | One bucket per client IP: current token level + last-refill time (POSIX seconds).
data Bucket = Bucket
  { tokens :: !Double,
    lastRefill :: !Double
  }

data RateLimiter = RateLimiter
  { buckets :: !(TVar (HashMap ByteString Bucket)),
    -- | perIpBurst
    capacity :: !Double,
    -- | perIpRequestsPerMinute / 60
    refillPerSec :: !Double,
    enabled :: !Bool
  }

-- | Build a limiter from the configured policy. Buckets are created lazily per client IP.
newRateLimiter :: RateLimitConfig -> IO RateLimiter
newRateLimiter cfg = do
  tv <- newTVarIO HM.empty
  pure
    RateLimiter
      { buckets = tv,
        capacity = fromIntegral cfg.perIpBurst,
        refillPerSec = fromIntegral cfg.perIpRequestsPerMinute / 60,
        enabled = cfg.rateLimitEnabled
      }

-- | Try to take one token for @key@ at time @nowSecs@; 'True' = allowed, 'False' = rejected.
-- A new key starts with a full bucket.
takeToken :: RateLimiter -> ByteString -> Double -> IO Bool
takeToken rl key nowSecs = atomically do
  m <- readTVar rl.buckets
  let Bucket lvl t0 = HM.lookupDefault (Bucket rl.capacity nowSecs) key m
      refilled = min rl.capacity (lvl + (nowSecs - t0) * rl.refillPerSec)
  if refilled >= 1
    then do
      writeTVar rl.buckets (HM.insert key (Bucket (refilled - 1) nowSecs) m)
      pure True
    else do
      writeTVar rl.buckets (HM.insert key (Bucket refilled nowSecs) m)
      pure False

-- | The WAI middleware. Passes non-throttled paths straight through.
rateLimitMiddleware :: RateLimiter -> Middleware
rateLimitMiddleware rl app req respond
  | not rl.enabled || not (throttledPath req) = app req respond
  | otherwise = do
      nowSecs <- realToFrac <$> getPOSIXTime
      allowed <- takeToken rl (clientKey req) nowSecs
      if allowed then app req respond else respond tooMany
  where
    tooMany =
      responseLBS
        status429
        [("Content-Type", "application/json")]
        "{\"error\":\"too_many_requests\"}"

-- | The unauthenticated POST endpoints the limiter guards. Authenticated routes (which carry
-- a bearer token) are intentionally excluded.
throttledPath :: Request -> Bool
throttledPath req =
  requestMethod req == methodPost && pathInfo req `elem` unauthPaths
  where
    unauthPaths =
      [ ["auth", "login"],
        ["auth", "signup"],
        ["auth", "refresh"],
        ["auth", "verify-email", "request"],
        ["auth", "password-reset", "request"]
      ]

-- | The per-IP key: the client's host address WITHOUT the ephemeral source port (otherwise
-- each connection would get its own bucket). Behind a reverse proxy this is the proxy address; a
-- trusted @X-Forwarded-For@ policy is out of scope for this single-instance plan.
clientKey :: Request -> ByteString
clientKey req = case remoteHost req of
  SockAddrInet _ host -> Char8.pack (show host)
  SockAddrInet6 _ _ host _ -> Char8.pack (show host)
  other -> Char8.pack (show other)
