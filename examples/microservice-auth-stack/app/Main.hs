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
-- * @DOWNSTREAM_JWKS_TTL_SECONDS@  how long a fetched JWKS is considered fresh
--                       (default 900). A background refresh is kicked at 80% of it.
-- * @DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS@  how long the last good JWKS keeps serving
--                       while refreshes fail (default 86400). Past it, requests get 503.
module Main (main) where

import Data.Text qualified as Text
import Downstream.Audit (newFileAuditSink)
import Downstream.Service (downstreamApplicationWithAuditSink, newJwksCache, newJwksManager)
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (ShomeiConfig (..), SigningKeyConfig (..), defaultShomeiConfig)
import Shomei.SigningKey.Verify.Jwt (VerifierSettings (..), validateVerifierSettings, verifierSettingsFromConfig)
import System.Environment (getEnv, lookupEnv)
import Text.Read (readMaybe)

main :: IO ()
main = do
  jwksUrl <- getEnv "SHOMEI_JWKS_URL"
  port <- maybe 8090 id . (>>= readMaybe) <$> lookupEnv "DOWNSTREAM_PORT"
  iss <- maybe "shomei" id <$> lookupEnv "SHOMEI_ISSUER"
  aud <- maybe "shomei-clients" id <$> lookupEnv "SHOMEI_AUDIENCE"
  maximumLifetime <- positiveEnv "DOWNSTREAM_MAX_TOKEN_LIFETIME_SECONDS" 1800
  legacyUntil <- optionalPositiveEnv "SHOMEI_LEGACY_ACTOR_UNTIL_UNIX"
  ttl <- maybe 900 fromInteger . (>>= readMaybe) <$> lookupEnv "DOWNSTREAM_JWKS_TTL_SECONDS"
  maxStale <- maybe 86400 fromInteger . (>>= readMaybe) <$> lookupEnv "DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS"
  mgr <- newJwksManager jwksUrl
  cache <- newJwksCache mgr jwksUrl ttl maxStale
  let base = defaultShomeiConfig (Issuer (Text.pack iss)) (Audience (Text.pack aud))
      cfg = base {signingKeyConfig = base.signingKeyConfig {legacyActorUntilUnix = legacyUntil}}
      verifier = (verifierSettingsFromConfig cfg) {maxTokenLifetime = fromIntegral maximumLifetime}
  either (ioError . userError . Text.unpack) pure (validateVerifierSettings verifier)
  auditPath <- maybe "downstream-audit.ndjson" id <$> lookupEnv "DOWNSTREAM_AUDIT_FILE"
  sink <- newFileAuditSink auditPath
  putStrLn ("[example-project-service] listening on :" <> show port)
  Warp.run port (downstreamApplicationWithAuditSink cache verifier sink)

positiveEnv :: String -> Int -> IO Int
positiveEnv name fallback = maybe fallback id <$> optionalPositiveEnv name

optionalPositiveEnv :: String -> IO (Maybe Int)
optionalPositiveEnv name =
  lookupEnv name >>= \case
    Nothing -> pure Nothing
    Just raw -> case readMaybe raw of
      Just value | value > 0 -> pure (Just value)
      _ -> ioError (userError (name <> " must be a positive finite integer"))
