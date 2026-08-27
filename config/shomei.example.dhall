-- Example Shōmei runtime configuration. Copy to `config/shomei.dhall`, edit, and point the
-- server/admin at it with `SHOMEI_CONFIG=config/shomei.dhall`. Every omitted field uses the
-- built-in default, and environment variables override values completed here.
let Shomei = ./shomei-types.dhall

in  Shomei::{
    , -- Prefer PG_CONNECTION_STRING for deployed secrets; this value is convenient locally.
      databaseUrl = Some
        "host=localhost dbname=shomei user=shomei password=shomei"
    , port = Some 8080
    , publicBaseUrl = Some "http://localhost:8080"
    , -- Default "log" writes verification/reset links to the server log. Use "smtp" for a
      -- provider relay or "webhook" for a signed JSON POST; their secrets stay in the environment.
      notifierTransport = Some
        "log"
    , -- The localhost values work for development. Production must use the exact relying-party
      -- domain and page origins served to the browser.
      webauthnRpId = Some
        "localhost"
    , webauthnOrigins = Some [ "http://localhost:8080" ]
    , -- Define roles before listing them here. The empty list grants no default roles.
      defaultRoles = Some
        ([] : List Text)
    , -- Keep OIDC disabled until issuer is this deployment's public HTTP(S) base URL.
      oidcEnabled = Some
        False
    }
