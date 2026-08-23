-- | Production liveness and readiness policy for the standalone service.
module Shomei.Health.Server (buildHealthChecks, buildHealthChecksWith) where

import Servant.Health (ProbeCheck, ProbeVerdict (..))
import Servant.Health.Check
  ( boolCheck,
    newFailureTracker,
    safeCheck,
    sequenceChecks,
    withProbeTimeout,
  )
import Shomei.Error (AuthError)
import Shomei.Prelude
import Shomei.Server.App (Env, runAppIO)
import Shomei.SigningKey.Domain (StoredSigningKey)
import Shomei.SigningKey.Store (listActiveSigningKeys)

-- | Production checks backed by the standalone server's interpreter stack.
buildHealthChecks :: Env -> IO (ProbeCheck, ProbeCheck)
buildHealthChecks env = buildHealthChecksWith (runAppIO env listActiveSigningKeys)

-- | Construct the two tracked checks once at startup. The injected query is the service-owned
-- IO bridge for @listActiveSigningKeys@: a typed execution failure is reported as @postgres@,
-- while a successful empty result is reported as @signing-key@.
buildHealthChecksWith :: IO (Either AuthError [StoredSigningKey]) -> IO (ProbeCheck, ProbeCheck)
buildHealthChecksWith runSigningKeyQuery = do
  trackLiveness <- newFailureTracker
  trackReadiness <- newFailureTracker
  let liveness =
        trackLiveness
          . withProbeTimeout 2_000_000 "liveness"
          . safeCheck "liveness"
          $ boolCheck "liveness" (pure True)
      readiness =
        trackReadiness . sequenceChecks $
          [ safeCheck "postgres" do
              runSigningKeyQuery >>= \case
                Left _ -> boolCheck "postgres" (pure False)
                Right keys -> boolCheck "signing-key" (pure (not (null keys)))
          ]
  pure (liveness, readiness)
