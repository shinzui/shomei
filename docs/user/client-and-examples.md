# Client & Examples

Shōmei ships a typed Haskell client and two runnable example applications.

## Typed Haskell Client

The `shomei-client` package derives its client record from the same Servant `ShomeiAPI` type that
the server serves. Authenticated calls take a `Token`, which adds
`Authorization: Bearer <access-token>`.

It is a **bearer-mode** client: it does not set or read Shōmei's cookies, and bearer credentials
are accepted in every transport, so it works against a cookie-mode server too. Note that
`TokenPairResponse.accessToken`/`.refreshToken` are `Maybe Text` — a cookie-only server omits them
— so unwrap them when talking to a server you did not configure.

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
every request. It fetches Shōmei's JWKS, caches it, and verifies JWTs locally using the same
issuer and audience configured on the auth service.

Use this pattern for service boundaries: authenticate with Shōmei, pass bearer access tokens to
downstream services, and let each service enforce its own role/scope/business policy after local
verification.

```bash
SHOMEI_JWKS_URL=http://localhost:8080/.well-known/jwks.json \
SHOMEI_ISSUER=shomei \
SHOMEI_AUDIENCE=shomei-clients \
DOWNSTREAM_JWKS_TTL_SECONDS=900 \
DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS=86400 \
  cabal run example-project-service
```

### The JWKS cache is the recommended template

`examples/microservice-auth-stack/src/Downstream/Service.hs` is meant to be copied into your
service. Its `JwksCache` is shaped for production rather than for brevity, and carries these
guarantees:

- **Verification is offline.** The auth service is contacted only to refresh the key set — at
  most once per TTL window, never once per request.
- **Reads are lock-free.** Verifying a token costs one `readIORef` and one clock read. Request
  threads never contend on a lock, so a cache-hit workload does not serialize.
- **Refresh is single-flight.** However many requests arrive, at most one JWKS fetch is in
  flight. A burst of requests during an outage cannot become a retry storm.
- **Refresh happens ahead of expiry.** The refetch is kicked at 80% of the TTL and runs on a
  background thread. Requests are answered from the cached key set while it proceeds, so there
  is no latency cliff when the TTL lapses. The only synchronous fetch is the cold start, before
  the first successful fetch.
- **An auth-service outage does not take the downstream down.** When a refresh fails, the last
  good key set keeps serving requests and each failure logs one line to stderr:

  ```text
  [downstream] jwks refresh failed (serving stale, age 312s): JWKS fetch returned HTTP 500
  ```

  This is safe in the window where the auth service's keys are still trusted: Shōmei rotates
  keys on operator action and keeps retired keys published, so a key set fetched hours ago
  still verifies correctly-issued tokens.
- **Staleness is bounded, and the service fails closed.** Past
  `DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS`, serving stale keys would ignore key revocation
  indefinitely, so `currentJwks` throws `JwksUnavailable` and the auth handler answers **503**,
  not 401. The token was never judged invalid — the verifier is impaired, and a 401 would make
  clients discard perfectly good sessions.

Configuration:

| Variable | Default | Meaning |
|---|---|---|
| `DOWNSTREAM_JWKS_TTL_SECONDS` | `900` | How long a fetched key set is considered fresh. A background refresh starts at 80% of this. |
| `DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS` | `86400` | How long the last good key set keeps serving while refreshes fail. Past this, requests get 503. |

A `Cache-Control: max-age=N` header on the JWKS response overrides `DOWNSTREAM_JWKS_TTL_SECONDS`
for that entry, following the usual HTTP freshness semantics — so the template behaves correctly
against non-Shōmei issuers that publish one. Note that **Shōmei's own server does not currently
send `Cache-Control` on `/.well-known/jwks.json`**; adding it server-side is a possible follow-up,
and until then the configured TTL always applies.

The example's test suite (`examples/microservice-auth-stack/test/Main.hs`) asserts each of these
properties mechanically against a stub JWKS server that counts fetches and can be scripted to
stall or fail. If you change the cache, run it.
