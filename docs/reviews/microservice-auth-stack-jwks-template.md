---
type: Review
title: microservice-auth-stack downstream verification template
description: >-
  The JWKS cache's documented properties — lock-free reads, single-flight refresh,
  refresh-ahead, stale-on-error, and a fail-closed staleness bound — hold and are tested, but
  the example's HTTP manager cannot speak TLS so the copy-me template only works over
  plaintext, an unclamped Cache-Control max-age disables the staleness bound, an unknown key
  never triggers a refresh, and the en recipe sends no API key — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-10
subject: mori://shinzui/shomei/packages/microservice-auth-stack
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - correctness
  - operability
  - documentation
context: >-
  The integration reader agent read app/Main.hs, src/Downstream/Service.hs, test/Main.hs,
  the README, the process-compose file, docs/user/client-and-examples.md, and — for the en
  recipe the README carries — en-client, en-servant's wire and response types, and en plan 33
  at en commit bf8ffa24b33de328ed7c6b19f02e9e3ad035d57f; it read http-client's Manager.hs
  and jose's JWKSet store in source. Nothing was run beyond the example's eight-case suite,
  which passed at the commit.
---

# microservice-auth-stack downstream verification template

## Verdict

Changes requested. This example matters more than an example usually does: `Service.hs:9`
says "copy it" and `client-and-examples.md:94` says it is "meant to be copied into your
service", so its defects become every downstream's defects, and a downstream's JWKS handling is
the trust root of the whole two-tier story. The cache itself is well built — lock-free reads,
single-flight refresh through `tryTakeMVar`, refresh-ahead at 0.8 of the TTL, stale-on-error with
one stderr line, a staleness bound that answers `503` rather than `401`, and seven tests that
prove each property against a fetch-counting stub. The problems are around it.

## Findings

**1. High — the manager cannot speak TLS.** `app/Main.hs:34` builds `HTTP.newManager
HTTP.defaultManagerSettings`, whose `managerTlsConnection` throws `TlsNotSupported`
(`http-client Network/HTTP/Client/Manager.hs:68`). `SHOMEI_JWKS_URL=https://…` fails every fetch,
so the only working configuration is `http://`. An on-path attacker between the downstream and
the auth service then serves a JWKS containing their own key and mints a token for any `sub`,
any `roles`, any `permissions` the downstream will accept. `shomei-server` (`Boot.hs:305`) and
`shomei-client` (`Client.hs:239-241`) both use `newTlsManager`. Remedy: `newTlsManager`, and a
sentence in `client-and-examples.md` that a plaintext JWKS is a full token-forgery vector.

**2. Medium — `Cache-Control: max-age` is honoured unclamped, and the staleness check is
reachable only from the refresh window.** `effectiveTtl` is taken verbatim from `max-age`
(`Service.hs:227, 276`), and `maxStaleness` is tested only inside `refreshWindow`, which is
entered only when `age ≥ 0.8 × effectiveTtl` (`:156-158, 186`). A `max-age ≥ maxStaleness / 0.8`
makes the entry permanent; combined with finding 1, one attacker response pins attacker keys for
the process lifetime; without an attacker, a CDN that adds a long `max-age` silently switches
off the documented 24-hour fail-closed guarantee, and `max-age=0` is a continuous fetch loop.
Remedy: clamp `effectiveTtl` to `maxStaleness`; evaluate `age ≥ maxStaleness` before the
refresh-ahead test.

**3. Medium — an unrecognized signing key never triggers a refresh.** Refresh is purely
age-driven; jose's `JWKSet` store ignores `kid` (`Crypto/JOSE/JWK/Store.hs:98-103`), so a token
signed by a key absent from the cached set fails as `TokenSignatureInvalid` → `401` and nothing
reacts. After `keys activate`, the new key reaches a downstream only when a request lands past
80 % of the entry TTL — 240 s against a real Shōmei (which sends `max-age=300`), 720 s at the
documented 900 s default — and every token minted meanwhile is refused by a healthy service,
against `security.md`'s "zero downtime" rotation. Pending keys are not published, so
pre-publication is not available as a workaround. The upside — no `kid`-triggered refresh storms
— must survive any fix. Remedy: on `TokenSignatureInvalid` with an entry older than a floor, one
rate-capped single-flight refresh and a single retry; consider publishing `pending` keys in
Shōmei's JWKS.

**4. Medium — the README's en recipe cannot work against any en-server since 2026-07-08.**
`runClientM (enClient.check request) enEnv` (`README.md:133`) sends no `Authorization` header and
en-client has no API-key support, while en-server requires `EN_API_KEYS_READ_WRITE` or
`EN_API_KEYS_READ_ONLY` bearer keys (en plan 33, complete; `en-server/app/Middleware.hs`). Every
check is `401`, which the recipe maps to `503` — fail-closed, so no bypass, but the "follow-up when
plan 33 ships" the README promises describes Shōmei-JWT verification, which en explicitly rejected
("shomei therefore stays an extension point, not a dependency"). Remedy: send a read-only en key;
rewrite README §4 and `authorization.md`'s "current en-side gaps" against en HEAD.

**5. Low — the runbook cannot boot as written.** `process-compose.yaml:23` hard-codes
`host=localhost port=5432` while the dev PostgreSQL is socket-only (`deployment.md:237-238`;
plan 47's own Surprises record the trap), and `SHOMEI_KEY_ENCRYPTION_KEY` is fatal when unset yet
appears in none of the example runbooks.

**6. Low — impersonation guidance is prose only.** The downstream returns `act` as `onBehalfOf`
in the response body (`Service.hs:341`), which is not an audit record; `authorization.md:93-95`
says the host must audit the operator.

**7. Info.** `client-and-examples.md:131-135` says Shōmei sends no `Cache-Control` on
`jwks.json`; it sends `public, max-age=300` (`SigningKey/Handler.hs:20`), so the documented
900 s TTL never applies. The `Authorization` header is decoded with the partial `Text.decodeUtf8`
(`Service.hs:318-320`) and 401s carry no `WWW-Authenticate`. The verifier inherits
`verifyToken`'s zero skew and full default `alg` set (REV-3).

## Verified holds

- Subject mapping is the TypeID text of the verified `sub` (`Service.hs:339-341`;
  `README.md:88-90`), matching `authorization.md`; the chain from `Sign/Jwt.hs:96-97` through
  `Verify/Jwt.hs:128-129` to `idText` is unbroken.
- Error mapping: any non-`Allowed` en decision → `403`; any other en result or transport
  failure → `503` (`README.md:135-138`); every wire name used exists at en HEAD.
- Cache properties: `Service.hs:150-152` (lock-free), `:183-185` (single-flight), `:122-123, 157`
  (refresh-ahead), `:201-220` (stale-on-error), `:186-197, 321-323` (bound → 503), `:268-278`
  (`Cache-Control` parsing); `test/Main.hs:134-213` including the 503-on-wire case; refresh does
  not use exceptions for control flow.
- Verification pins issuer and audience (`Verify/Jwt.hs:79-84`).

## Not examined

The example was not run against a live Shōmei or en; `www` assets are out of scope; the
`embedded-with-en` example's `cabal.project` drift (documented in REV-1) belongs to that example,
not this one.
