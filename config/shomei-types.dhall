-- The typed schema for a Shōmei runtime configuration file (EP-5 / IP-6).
-- An operator's `config/shomei.dhall` should annotate itself with this type:
--     let Schema = ./shomei-types.dhall in ({ … } : Schema)
-- The server renders the file with `dhall-to-json` and decodes the result; every field maps
-- to a runtime setting. Secrets (database URL, etc.) live here, so the live file is gitignored.
{ issuer : Text
, audience : Text
, databaseUrl : Text
, port : Natural
, accessTokenTtlSeconds : Natural
, refreshTokenTtlSeconds : Natural
, sessionTtlSeconds : Natural
, publicBaseUrl : Text
, emailVerificationRequired : Bool
, rateLimitEnabled : Bool
, maxFailedLoginsPerAccount : Natural
, perIpRequestsPerMinute : Natural
, metricsEnabled : Bool
, requestLoggingEnabled : Bool
, gracefulShutdownTimeoutSeconds : Natural
}
