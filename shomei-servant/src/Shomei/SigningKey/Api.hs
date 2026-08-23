-- | Well-known discovery and signing-key routes.
module Shomei.SigningKey.Api (WellKnownApi (..), JwksRoute, OidcDiscoveryRoute) where

import Data.Aeson (Value)
import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.OAuth.Result (OidcDiscoveryResponses, OidcDiscoveryResult)
import Shomei.Prelude

type JwksRoute = "jwks.json" :> Get '[JSON] (Headers '[Header "Cache-Control" Text] Value)

type OidcDiscoveryRoute = "openid-configuration" :> MultiVerb 'GET '[JSON] OidcDiscoveryResponses OidcDiscoveryResult

data WellKnownApi mode = WellKnownApi
  { jwks :: mode :- JwksRoute,
    oidcDiscovery :: mode :- OidcDiscoveryRoute
  }
  deriving stock (Generic)
