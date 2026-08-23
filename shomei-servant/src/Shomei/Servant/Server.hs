-- | Thin composition root for the exact server tree.
module Shomei.Servant.Server
  ( shomeiRoutes,
    applicationServer,
  )
where

import Servant (Handler)
import Servant.Health (ProbeCheck, healthServer)
import Servant.Server.Generic (AsServerT)
import Shomei.Account.Handler (accountServer, adminAccountServer)
import Shomei.Audit.Handler (auditServer)
import Shomei.Authorization.Handler (authorizationServer)
import Shomei.Mfa.Handler (mfaServer)
import Shomei.OAuth.Handler (oauthServer)
import Shomei.Passkey.Handler (passkeyServer)
import Shomei.Servant.Api (ApplicationApi (..), ShomeiRoutes (..))
import Shomei.Servant.OpenApi (openApiValue)
import Shomei.Servant.Seam (Env)
import Shomei.Session.Handler (adminSessionServer, sessionServer)
import Shomei.SigningKey.Handler (wellKnownServer)

shomeiRoutes :: Env -> ProbeCheck -> ProbeCheck -> ShomeiRoutes (AsServerT Handler)
shomeiRoutes env liveness readiness =
  ShomeiRoutes
    { application = applicationServer env,
      oauth = oauthServer env,
      wellKnown = wellKnownServer env,
      health = healthServer liveness readiness,
      openapi = pure openApiValue
    }

applicationServer :: Env -> ApplicationApi (AsServerT Handler)
applicationServer env =
  ApplicationApi
    { account = accountServer env,
      session = sessionServer env,
      passkey = passkeyServer env,
      mfa = mfaServer env,
      adminAccount = adminAccountServer env,
      adminSession = adminSessionServer env,
      authorization = authorizationServer env,
      audit = auditServer env
    }
