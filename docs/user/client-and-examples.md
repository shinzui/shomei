# Client & Examples

Shōmei ships a typed Haskell client and three runnable example applications.

## Typed Haskell Client

The `shomei-client` package derives its client record from the same Servant `ShomeiRoutes` type that
the server serves. Authenticated calls take a `Token`, which adds
`Authorization: Bearer <access-token>`.

It is a **bearer-mode** client: it does not set or read Shōmei's cookies, and bearer credentials
are accepted in every transport, so it works against a cookie-mode server too. Note that
`TokenPairResponse.accessToken`/`.refreshToken` are `Maybe Text` — a cookie-only server omits them
— so unwrap them when talking to a server you did not configure.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Shomei.Client qualified as Shomei
import Shomei.Account.Dto (SignupRequest (..))

main :: IO ()
main = do
  env <- Shomei.shomeiClientEnv "http://localhost:8080"
  result <-
    Shomei.signup
      env
      SignupRequest
        { loginId = "ada",
          email = Just "ada@example.com",
          password = "correct horse battery staple",
          displayName = "Ada"
        }
  case result of
    Left transportFailure -> print transportFailure
    Right (Shomei.ApplicationSuccess created) -> print created
    Right expectedFailure -> print expectedFailure
```

Every application wrapper returns a named route result inside `Either ClientError`: a declared
HTTP outcome such as `ApplicationConflict` or `ApplicationUnavailable` is a `Right` value, while
`ClientError` is reserved for transport, decoding, or contract violations. OAuth wrappers return
the corresponding `OAuthResult` protocol sum. Convenience wrappers cover account, session,
passkey/MFA, OAuth client credentials, and administration flows. For other fields, use the
exported `shomeiRoutesClient`/`shomeiClient` records with selectors from `Shomei.Servant.Api` and
the owning concept's `Api` module.

## Embedded Servant App

`examples/embedded-servant-app` mounts Shōmei's `/auth` routes inside a host Servant application
and protects host routes with Shōmei authentication. It also serves the browser passkey demo from
`examples/embedded-servant-app/www`.

```bash
cd examples/embedded-servant-app
export SHOMEI_KEY_ENCRYPTION_KEY="$(openssl rand -base64 32)"
PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" \
  cabal run embedded-servant-app
```

Open <http://localhost:8080/index.html> to exercise login, passkey enrollment, and MFA step-up in
a real browser.

### Embedding checklist

Mounting `ShomeiRoutes` supplies handlers, but the host process must also install the standalone
runtime contract. The route tree and `authContext` provide token verification using the keys loaded
at boot, CSRF origin checks, problem-detail errors, and database-backed account-failure policy. They
do not reload keys, run maintenance workers, or create the outer request edge. After `buildEnv`, an
embedding host must:

1. Call `installHostBackgroundTasks cfg settings env` once. This validates default roles, reloads
   signing keys periodically and on `SIGHUP`, sweeps expired state, and runs notification delivery.
2. Create the limiter with `newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig` and create
   metrics with `newMetrics`.
3. Wrap the host's **whole** `Application` in
   `hostMiddleware cfg settings limiter metrics`. This gives Shōmei and host-owned routes the same
   trusted-proxy identity, request IDs and logging, metrics, metered body cap, and per-client rate
   limiting.
4. After the HTTP server stops accepting requests, call
   `stopHostBackgroundTasks backgroundTasks gracefulShutdownTimeoutSeconds`. This drains queued
   notifications within the shutdown budget and releases the sweeper's private pool.

The essential assembly is:

```haskell
backgroundTasks <- installHostBackgroundTasks cfg settings env
limiter <- newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig
metrics <- newMetrics
Warp.run
  settings.serverPort
  (hostMiddleware cfg settings limiter metrics hostApplication)
stopHostBackgroundTasks
  backgroundTasks
  cfg.observabilityConfig.gracefulShutdownTimeoutSeconds
```

Do not wrap only the mounted Shōmei routes: doing so leaves host-owned routes outside the body,
rate-limit, logging, and metrics boundary. `RateLimited` and `CsrfProtected` describe responses in
the API contract; a documented `429` is truthful only when `hostMiddleware` is installed. The
limiter's derived paths assume `ShomeiRoutes` is mounted at the root, as both examples do. Also note
that the background installer owns the process-wide `SIGHUP` handler. The two embedded examples are
the executable reference.

## Embedded with en (authentication + authorization)

`examples/embedded-with-en` extends the embedded model with **fine-grained authorization**: it
mounts the whole Shōmei auth API and adds `GET/PUT /projects/:id` routes guarded by **en**, the
sibling Zanzibar-style ReBAC toolkit. Shōmei answers *who is calling*; en answers *what they may
do* (a relationship check against a small `project` schema). Its README walks a copy-pasteable
`403 → grant an editor tuple → 200` transcript. Start with
[Authorization](authorization.md) for the two-tier story and the identity-mapping conventions
this example pins.

## Microservice Auth Stack

`examples/microservice-auth-stack` demonstrates a downstream service that does not call Shōmei on
every request. It fetches Shōmei's JWKS, caches it, and verifies JWTs locally using the same
issuer and audience configured on the auth service.

Use this pattern for service boundaries: authenticate with Shōmei, pass bearer access tokens to
downstream services, and let each service enforce its own role/scope/business policy after local
verification.

```bash
SHOMEI_JWKS_URL=https://auth.example.com/.well-known/jwks.json \
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
  the age-driven refresh window or under the separately rate-capped unknown-key policy, never once
  per request.
- **Reads are lock-free.** Verifying a token costs one `readIORef` and one clock read. Request
  threads never contend on a lock, so a cache-hit workload does not serialize.
- **Refresh is single-flight.** However many requests arrive, at most one JWKS fetch is in
  flight. A burst of requests during an outage cannot become a retry storm.
- **A newly rotated key gets one bounded retry.** When verification reports an unknown `kid` and
  the cached set is at least five seconds old, one request synchronously refreshes and retries
  verification once. The trigger is globally capped at one fetch per 30 seconds, so arbitrary key
  IDs cannot create a fetch storm; malformed tokens and bad signatures never trigger it.
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

A positive `Cache-Control: max-age=N` header on the JWKS response supplies that entry's freshness
lifetime, but it is always clamped to `DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS`. `max-age=0` is ignored
rather than turning the cache into a fetch-per-request loop. Shōmei currently publishes
`Cache-Control: public, max-age=300`, so its effective freshness lifetime is 300 seconds; the local
staleness bound remains the final fail-closed policy.

`newJwksManager` selects a TLS-capable manager for `https://` URLs. Plaintext `http://` remains
available for loopback development only; using it for a non-loopback host logs a warning because an
on-path attacker could substitute the JWKS and forge accepted tokens. Production JWKS URLs must use
HTTPS.

The example's test suite (`examples/microservice-auth-stack/test/Main.hs`) asserts each of these
properties mechanically against a stub JWKS server that counts fetches and can be scripted to
stall or fail. If you change the cache, run it.
