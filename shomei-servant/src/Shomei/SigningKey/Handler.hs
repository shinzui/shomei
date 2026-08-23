-- | In-process discovery and signing-key HTTP adapters.
module Shomei.SigningKey.Handler (wellKnownServer) where

import Data.Aeson (Value)
import Servant (Handler, Header, Headers, addHeader)
import Servant.Server.Generic (AsServerT)
import Shomei.OAuth.Handler (oidcDiscoveryH)
import Shomei.Prelude
import Shomei.Servant.Seam (Env (..))
import Shomei.SigningKey.Api (WellKnownApi (..))

wellKnownServer :: Env -> WellKnownApi (AsServerT Handler)
wellKnownServer env =
  WellKnownApi
    { jwks = jwksH env,
      oidcDiscovery = oidcDiscoveryH env
    }

jwksH :: Env -> Handler (Headers '[Header "Cache-Control" Text] Value)
jwksH env = addHeader "public, max-age=300" <$> liftIO env.jwksJson
