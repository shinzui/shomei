-- | The @example-project-service@ executable: a downstream service that verifies Shōmei
-- JWTs locally against a JWKS fetched (and TTL-cached) from the auth service.
--
-- Environment:
--
-- * @SHOMEI_JWKS_URL@   the auth service's JWKS document URL (required), e.g.
--                       @http:\/\/localhost:8080\/.well-known\/jwks.json@.
-- * @DOWNSTREAM_PORT@    TCP port to listen on (default 8090).
-- * @SHOMEI_ISSUER@\/@SHOMEI_AUDIENCE@  must match what the auth service signs with
--                       (defaults @shomei@ \/ @shomei-clients@).
module Main (main) where

import Data.Text qualified as Text
import Downstream.Service (downstreamApplication, newJwksCache)
import Network.HTTP.Client qualified as HTTP
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Config (defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import System.Environment (getEnv, lookupEnv)
import Text.Read (readMaybe)

main :: IO ()
main = do
  jwksUrl <- getEnv "SHOMEI_JWKS_URL"
  port <- maybe 8090 id . (>>= readMaybe) <$> lookupEnv "DOWNSTREAM_PORT"
  iss <- maybe "shomei" id <$> lookupEnv "SHOMEI_ISSUER"
  aud <- maybe "shomei-clients" id <$> lookupEnv "SHOMEI_AUDIENCE"
  mgr <- HTTP.newManager HTTP.defaultManagerSettings
  cache <- newJwksCache mgr jwksUrl 900 -- 15-minute refetch TTL
  let cfg = defaultShomeiConfig (Issuer (Text.pack iss)) (Audience (Text.pack aud))
  putStrLn ("[example-project-service] listening on :" <> show port)
  Warp.run port (downstreamApplication cache cfg)
