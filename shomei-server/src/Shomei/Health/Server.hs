-- | Production liveness and readiness policy for the standalone service.
module Shomei.Health.Server
  ( HealthPolicy (..),
    defaultHealthPolicy,
    buildHealthChecks,
    buildHealthChecksWith,
  )
where

import Control.Concurrent.MVar (modifyMVar, newMVar)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Servant.Health (ProbeCheck)
import Servant.Health.Check
  ( boolCheck,
    newFailureTracker,
    safeCheck,
    sequenceChecks,
    withProbeTimeout,
  )
import Shomei.Error (AuthError)
import Shomei.Server.App (Env, runAppIO)
import Shomei.SigningKey.Domain (StoredSigningKey)
import Shomei.SigningKey.Store (listActiveSigningKeys)

data HealthPolicy = HealthPolicy
  { readinessTimeoutMicros :: !Int,
    readinessCacheMicros :: !Int
  }
  deriving stock (Eq, Show)

defaultHealthPolicy :: HealthPolicy
defaultHealthPolicy =
  HealthPolicy
    { readinessTimeoutMicros = 2_000_000,
      readinessCacheMicros = 1_000_000
    }

-- | Production checks backed by the standalone server's interpreter stack.
buildHealthChecks :: Env -> IO (ProbeCheck, ProbeCheck)
buildHealthChecks env = buildHealthChecksWith defaultHealthPolicy (runAppIO env listActiveSigningKeys)

-- | Construct the two tracked checks once at startup. The injected query is the service-owned
-- IO bridge for @listActiveSigningKeys@: a typed execution failure is reported as @postgres@,
-- while a successful empty result is reported as @signing-key@.
buildHealthChecksWith :: HealthPolicy -> IO (Either AuthError [StoredSigningKey]) -> IO (ProbeCheck, ProbeCheck)
buildHealthChecksWith policy runSigningKeyQuery = do
  trackLiveness <- newFailureTracker
  trackReadiness <- newFailureTracker
  cachedReadiness <-
    cachedFor policy.readinessCacheMicros
      . withProbeTimeout policy.readinessTimeoutMicros "postgres"
      . sequenceChecks
      $ [ safeCheck "postgres" do
            runSigningKeyQuery >>= \case
              Left _ -> boolCheck "postgres" (pure False)
              Right keys -> boolCheck "signing-key" (pure (not (null keys)))
        ]
  let liveness =
        trackLiveness
          . withProbeTimeout 2_000_000 "liveness"
          . safeCheck "liveness"
          $ boolCheck "liveness" (pure True)
      readiness = trackReadiness cachedReadiness
  pure (liveness, readiness)

-- | Cache one readiness verdict for a short monotonic-time window. Holding the MVar while the
-- check runs makes cache refresh single-flight: concurrent probes share one dependency query.
cachedFor :: Int -> ProbeCheck -> IO ProbeCheck
cachedFor micros check
  | micros <= 0 = pure check
  | otherwise = do
      cache <- newMVar Nothing
      let windowNanos = fromIntegral micros * 1_000 :: Word64
      pure $ modifyMVar cache \stored -> do
        now <- getMonotonicTimeNSec
        case stored of
          Just (observedAt, verdict)
            | now >= observedAt,
              now - observedAt < windowNanos ->
                pure (stored, verdict)
          _ -> do
            verdict <- check
            observedAt <- getMonotonicTimeNSec
            pure (Just (observedAt, verdict), verdict)
