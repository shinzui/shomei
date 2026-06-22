# Client & Examples

Shōmei ships a typed Haskell client and two runnable example applications.

## Typed Haskell Client

The `shomei-client` package derives its client record from the same Servant `ShomeiAPI` type that
the server serves. Authenticated calls take a `Token`, which adds
`Authorization: Bearer <access-token>`.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Shomei.Client qualified as Shomei
import Shomei.Servant.DTO (LoginRequest (..), SignupRequest (..))

main :: IO ()
main = do
  env <- Shomei.shomeiClientEnv "http://localhost:8080"
  signedUp <-
    Shomei.signup
      env
      SignupRequest
        { loginId = Nothing,
          email = Just "ada@example.com",
          password = "correct horse battery staple",
          displayName = "Ada"
        }
  print signedUp
```

Convenience wrappers are exported for signup, login, refresh, logout, `me`, `session`, and the
passkey/MFA flows. For newer endpoints such as service-token issuance, impersonation, and audit
retrieval, use the exported `shomeiClient` record directly with selectors from
`Shomei.Servant.API`, or add a small wrapper following the existing module pattern.

## Embedded Servant App

`examples/embedded-servant-app` mounts Shōmei's `/auth` routes inside a host Servant application
and protects host routes with Shōmei authentication. It also serves the browser passkey demo from
`examples/embedded-servant-app/www`.

```bash
cd examples/embedded-servant-app
PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" \
  cabal run embedded-servant-app
```

Open <http://localhost:8080/index.html> to exercise login, passkey enrollment, and MFA step-up in
a real browser.

## Microservice Auth Stack

`examples/microservice-auth-stack` demonstrates a downstream service that does not call Shōmei on
every request. It fetches Shōmei's JWKS, caches it for a TTL, and verifies JWTs locally using the
same issuer and audience configured on the auth service.

```bash
SHOMEI_JWKS_URL=http://localhost:8080/.well-known/jwks.json \
SHOMEI_ISSUER=shomei \
SHOMEI_AUDIENCE=shomei-clients \
  cabal run example-project-service
```

Use this pattern for service boundaries: authenticate with Shōmei, pass bearer access tokens to
downstream services, and let each service enforce its own role/scope/business policy after local
verification.
