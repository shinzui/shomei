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
      , totpEnabled = False
      , totpEnrollmentTtlSeconds = 900
      -- Roles every new user receives at signup. Define them first with
      -- `shomei-admin roles define <name>`; the server refuses to start if a name here is not
      -- in the registry. The empty list (the default) grants nothing.
      , defaultRoles = [] : List Text
      -- OIDC provider. Keep disabled until `issuer` above is this deployment's real public
      -- base URL (e.g. "https://auth.example.com") — the server refuses to start otherwise,
      -- because every endpoint in the discovery document is derived from it. Register clients
      -- with `shomei-admin oauth-clients create`. See docs/user/oidc.md.
      , oidcEnabled = False
      , oauthLoginUrl = None Text
      , oauthAuthorizationCodeTtlSeconds = 60
      , oauthIdTokenTtlSeconds = 900
      -- Service-token issuance for machine callers. Keep disabled until you create a Shōmei
      -- user for each account and replace the placeholder id/hash/scope values.
      , serviceToken =
          { enabled = False
          , ttlSeconds = 300
          , accounts =
              [ { accountId = "connector:example"
                , userId = "user_00000000000000000000000000"
                , secretSha256 = "0000000000000000000000000000000000000000000000000000000000000000"
                , allowedScopes = [ "kawa:ingest" ]
                }
              ]
          }
      }
    : Schema
