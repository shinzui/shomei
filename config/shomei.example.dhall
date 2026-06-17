-- Example Shōmei runtime configuration. Copy to `config/shomei.dhall`, edit, and point the
-- server/admin at it with `SHOMEI_CONFIG=config/shomei.dhall`. Environment variables
-- (PG_CONNECTION_STRING, SHOMEI_PORT, SHOMEI_ISSUER, …) override anything set here.
let Schema = ./shomei-types.dhall

in    { issuer = "shomei"
      , audience = "shomei-clients"
      , databaseUrl = "host=localhost dbname=shomei user=shomei password=shomei"
      , port = 8080
      , accessTokenTtlSeconds = 900
      , refreshTokenTtlSeconds = 2592000
      , sessionTtlSeconds = 2592000
      , publicBaseUrl = "http://localhost:8080"
      , emailVerificationRequired = False
      , rateLimitEnabled = True
      , maxFailedLoginsPerAccount = 7
      , perIpRequestsPerMinute = 60
      , metricsEnabled = True
      , requestLoggingEnabled = True
      , gracefulShutdownTimeoutSeconds = 30
      -- Password policy (MasterPlan 4). Local common/contextual checks default on; the
      -- network HIBP breach check is opt-in and, when enabled, fails open by default.
      , passwordMinLength = 12
      , passwordMaxLength = 256
      , passwordRejectCommon = True
      , passwordRejectContextual = True
      , passwordBreachCheckEnabled = False
      , passwordBreachCheckFailClosed = False
      , passwordBreachCheckTimeoutMs = 1000
      -- WebAuthn / passkeys. The localhost defaults work for local development; in production
      -- set webauthnRpId to your registrable domain and webauthnOrigins to your exact page
      -- origin(s). See docs/passkeys.md.
      , webauthnRpId = "localhost"
      , webauthnRpName = "Shōmei"
      , webauthnOrigins = [ "http://localhost:8080" ]
      , webauthnUserVerification = "preferred"
      , webauthnAttestation = "none"
      , webauthnCeremonyTimeoutSeconds = 300
      , webauthnPendingCeremonyTtlSeconds = 300
      , webauthnMfaRequired = True
      }
    : Schema
