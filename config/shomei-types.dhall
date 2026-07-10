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
-- Roles granted to every new user at signup (MasterPlan 7 EP-1). Empty for none. Each name
-- must already exist in the `shomei_roles` registry (`shomei-admin roles define <name>`) or
-- the server refuses to start. Overridable with SHOMEI_DEFAULT_ROLES (comma-separated).
, defaultRoles : List Text
-- Password policy (MasterPlan 4). Length bounds plus toggles for the local common/contextual
-- checks (EP-2) and the opt-in HIBP breach check (EP-3).
, passwordMinLength : Natural
, passwordMaxLength : Natural
, passwordRejectCommon : Bool
, passwordRejectContextual : Bool
, passwordBreachCheckEnabled : Bool
, passwordBreachCheckFailClosed : Bool
, passwordBreachCheckTimeoutMs : Natural
-- WebAuthn / passkey relying-party identity and ceremony policy (MasterPlan 3).
, webauthnRpId : Text                       -- registrable domain, e.g. "auth.example.com"
, webauthnRpName : Text                      -- human label shown by the authenticator
, webauthnOrigins : List Text                -- allowed page origins, e.g. [ "https://auth.example.com" ]
, webauthnUserVerification : Text            -- "required" | "preferred" | "discouraged"
, webauthnAttestation : Text                 -- "none" | "direct"
, webauthnCeremonyTimeoutSeconds : Natural   -- browser ceremony timeout
, webauthnPendingCeremonyTtlSeconds : Natural -- how long a begun ceremony stays valid server-side
, webauthnMfaRequired : Bool                 -- require the second factor for accounts with any enrolled factor
-- TOTP second factor (MasterPlan 7 EP-7). Disabled by default. When enabled, the environment
-- variable SHOMEI_TOTP_ENCRYPTION_KEY (base64 of 32 bytes) MUST be set — it is a secret and so is
-- never in this file — or the server refuses to start. Generate one with: openssl rand -base64 32.
, totpEnabled : Bool
, totpEnrollmentTtlSeconds : Natural          -- how long an unconfirmed enrollment stays activatable
-- OIDC provider surface (MasterPlan 7 EP-5). Disabled by default. When enabled, `issuer` above
-- MUST be this deployment's public http(s) base URL: every endpoint in the published discovery
-- document is derived from it, and the server refuses to start otherwise.
-- `oauthLoginUrl` is the host's own login page; an unauthenticated GET /oauth/authorize is
-- redirected there with the original authorize URL in a `return_to` query parameter. `None Text`
-- makes such a request a 401 instead. Shōmei ships no login UI. See docs/user/oidc.md.
, oidcEnabled : Bool
, oauthLoginUrl : Optional Text
, oauthAuthorizationCodeTtlSeconds : Natural  -- single-use authorization code lifetime
, oauthIdTokenTtlSeconds : Natural            -- ID token lifetime
-- Service-token issuance. Disabled by default; each configured account maps an operator-chosen
-- account id to an existing Shōmei user id, a SHA-256 hex secret hash, and coarse allowed scopes.
, serviceToken :
    { enabled : Bool
    , ttlSeconds : Natural
    , accounts :
        List
          { accountId : Text
          , userId : Text
          , secretSha256 : Text
          , allowedScopes : List Text
          }
    }
}
