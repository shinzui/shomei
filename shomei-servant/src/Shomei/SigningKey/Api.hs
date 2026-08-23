-- | Well-known discovery and signing-key routes.
module Shomei.SigningKey.Api (WellKnownApi (..)) where

import Data.Aeson (Value)
import Servant.API
import Shomei.Prelude

data WellKnownApi mode = WellKnownApi
  { jwks :: mode :- "jwks.json" :> Get '[JSON] (Headers '[Header "Cache-Control" Text] Value),
    oidcDiscovery :: mode :- "openid-configuration" :> Get '[JSON] Value
  }
  deriving stock (Generic)
