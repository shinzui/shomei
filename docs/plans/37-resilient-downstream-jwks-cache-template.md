---
id: 37
slug: resilient-downstream-jwks-cache-template
title: "Resilient Downstream JWKS Cache Template"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/6-operational-and-performance-hardening.md"
---

# Resilient Downstream JWKS Cache Template

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-5** of MasterPlan 6
(`docs/masterplans/6-operational-and-performance-hardening.md`, "Operational and Performance
Hardening"). It rewrites the JWKS cache in `examples/microservice-auth-stack` — the example
every downstream service is told to copy — from a serialize-everything `MVar` into a
production-shaped cache: lock-free reads, single-flight refresh, refresh-ahead before expiry,
stale-on-error with a fail-closed staleness bound, a configurable TTL, and respect for a
`Cache-Control: max-age` response header when the JWKS endpoint sends one. It adds cache
tests to the example's test suite and upgrades `docs/user/client-and-examples.md` to present
the pattern as the recommended template with its properties spelled out.


## Purpose / Big Picture

A *downstream service* in Shōmei's microservice model verifies access tokens **locally**: it
fetches the auth service's JWKS (JSON Web Key Set — the public keys, published at
`/.well-known/jwks.json`) once, caches it, and verifies every request's JWT offline without
calling the auth service. The example implementing this,
`examples/microservice-auth-stack/src/Downstream/Service.hs`, is explicitly documented in
`docs/user/client-and-examples.md` as the pattern to copy — it is the de-facto client
library for downstream teams, which is why this plan exists even though it only touches
`examples/`.

The current cache is a trap in three ways. Reads serialize: `currentJwks` takes one global
`MVar` with `modifyMVar` on **every** request, so even a 100%-cache-hit workload funnels all
request threads through one lock. Refreshes block the world: when the TTL (hardcoded to 15
minutes in `examples/microservice-auth-stack/app/Main.hs`) lapses, every in-flight request
queues behind the full HTTP round-trip to the auth service. And an auth-service outage
becomes a downstream outage: on fetch failure the code throws (each queued request then
retries the fetch in turn — a serialized retry storm of 500s), and the perfectly good stale
key set is never served because key sets practically never change at 15-minute granularity.

After this plan, someone running the example can see: requests keep verifying at full speed
while a refresh is in flight (only one fetch happens — proven by a fetch-counting stub
server); the auth service can be *down* past the TTL and the downstream keeps serving 200s
from the stale key set while logging refresh failures; only after a hard staleness bound
(default 24 hours) does the downstream fail closed with 503; and the TTL is an environment
variable. The example's test suite proves each property mechanically, and the user docs
enumerate them so a team copying the file knows exactly what guarantees it carries.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `JwksCache` rewritten in
      `examples/microservice-auth-stack/src/Downstream/Service.hs`: `IORef` entry for
      lock-free reads, `MVar ()` try-lock for single-flight, refresh-ahead at 80% TTL,
      stale-on-error, `JwksUnavailable` fail-closed past max staleness, `Cache-Control:
      max-age` honored; `currentJwks` and the config record exported for tests.
- [ ] M1: `newJwksCache` signature extended (TTL + max staleness); `app/Main.hs` reads
      `DOWNSTREAM_JWKS_TTL_SECONDS` / `DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS`;
      `localAuthHandler` maps `JwksUnavailable` to 503 (still 401 for bad tokens).
- [ ] M2: stub JWKS server harness (fetch counter + scriptable ok/fail/delay modes) in the
      example's test suite.
- [ ] M2: cache tests green — cold-start single flight, cached reads fetch nothing,
      refresh-ahead without latency spike, stale-on-error, fail-closed after max staleness,
      single-flight under failure burst, `max-age` override.
- [ ] M2: pre-existing end-to-end test (valid/tampered/missing token against the real auth
      server) still green with the new cache.
- [ ] M3: `docs/user/client-and-examples.md` rewritten to present the cache as the
      recommended template with its property list, configuration, and the
      server-side `Cache-Control` follow-up note.
- [ ] `nix fmt` clean; `cabal build all` / `cabal test all` green; MasterPlan 6 Progress and
      registry updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Reads are an `IORef` (`readIORef`, no lock); mutation goes through a separate
  `MVar ()` used **only** as a try-lock (`tryTakeMVar`) for single-flight refresh, plus a
  blocking path for the cold start.
  Rationale: The read path is the per-request hot path of every downstream service; `IORef`
  reads are wait-free and a whole-`JWKSet` swap via `atomicWriteIORef` is safe because the
  value is immutable. The refresh lock is deliberately *not* the data holder (the original
  design's mistake): a held lock must never make readers wait. `tryTakeMVar` gives
  "exactly one refresher, everyone else proceeds on the old value" in four lines — no STM,
  no async machinery a copier must audit.
  Date: 2026-07-07

- Decision: Refresh-ahead triggers at **80% of the effective TTL**; requests never
  synchronously wait for a refresh except at cold start (empty cache) or past the hard
  staleness bound.
  Rationale: Kicking the background fetch at 0.8×TTL means a healthy auth service always
  finishes refreshing before expiry, so the latency cliff at TTL simply never occurs. 80% is
  the conventional refresh-ahead factor (large enough to avoid wasteful early refetches,
  early enough to absorb slow fetches); it is a named constant, not configuration — a copier
  can change one number.
  Date: 2026-07-07

- Decision: Stale-on-error with a **default hard max staleness of 24 hours**, configurable
  (`DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS`), after which `currentJwks` throws
  `JwksUnavailable` and the auth handler answers **503** (not 401).
  Rationale: Serving stale keys is safe in exactly the window where the auth service's keys
  are still trusted: Shōmei rotates keys on operator action and old keys remain published
  while retired, so a set fetched hours ago still verifies correctly-issued tokens. But
  serving *forever*-stale keys would ignore key revocation indefinitely — an unbounded
  security exposure — so staleness must have a ceiling; 24 hours matches the "rotation is an
  operator-day event, revocation is an emergency" posture and is loudly configurable. 503
  (service unavailable) is honest: the token was not judged invalid; the verifier is
  impaired. A 401 would trigger clients to discard perfectly good sessions.
  Date: 2026-07-07

- Decision: Honor `Cache-Control: max-age=N` from the JWKS response as the *effective TTL for
  that entry* when present (overriding the configured TTL); note in code and docs that the
  Shōmei server does **not currently send** `Cache-Control` on
  `/.well-known/jwks.json`, and adding it server-side is a possible follow-up that this plan
  must not implement (no server changes in an examples-scoped plan).
  Rationale: When the key publisher states a freshness lifetime, the consumer should obey
  it — that is the JWKS-over-HTTPS convention (RFC 8414 ecosystem practice), and it makes the
  template correct against non-Shōmei issuers too. Parsing is a lenient scan for `max-age=`
  in the header; absent or unparsable means "use the configured TTL".
  Date: 2026-07-07

- Decision: Keep everything in the example package (no new library, no changes to
  `shomei-jwt`/`shomei-client`), and test `currentJwks` **directly** against a scriptable
  stub warp server rather than only through the HTTP auth path.
  Rationale: The MasterPlan scopes EP-5 to the template; its value is a single copyable file.
  Direct tests of the exported `currentJwks` make the concurrency properties assertable
  (fetch counts, latency bounds) without JWT plumbing; the existing end-to-end test already
  covers the auth path against the real server and stays as-is.
  Date: 2026-07-07

- Decision: Timing-sensitive tests use short TTLs (1 s) with generous margins and
  poll-with-deadline assertions instead of exact sleeps.
  Rationale: The properties under test are inherently temporal. One-second TTLs with
  ±300 ms margins and "eventually within 3 s" polling keep the suite fast and robust on
  loaded CI machines; any residual flake gets recorded in Surprises with the margin bumped.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Haskell workspace
(GHC 9.12.4, GHC2024); build/test with `cabal build all` / `cabal test all` inside
`nix develop`, format with `nix fmt`. The example package this plan lives in is
`examples/microservice-auth-stack/` (in the root `cabal.project`), with three components:

- **library** (`src/Downstream/Service.hs`, the only module): the downstream service. It
  depends on `shomei-core` (config/claims types), `shomei-jwt` (`Shomei.Jwt.Verify.verifyToken
  :: JWKSet -> ShomeiConfig -> Text -> IO (Either …)` — offline JWT verification),
  `http-client`, `jose`, `servant-server`, `wai`. Deliberately **no** database and no
  `shomei-postgres`.
- **executable** `example-project-service` (`app/Main.hs`): reads `SHOMEI_JWKS_URL`
  (required), `DOWNSTREAM_PORT` (default 8090), `SHOMEI_ISSUER`/`SHOMEI_AUDIENCE`; line 29
  hardcodes the cache TTL: `cache <- newJwksCache mgr jwksUrl 900`.
- **test-suite** `microservice-auth-stack-test` (`test/Main.hs`): tasty + tasty-hunit; boots
  the *real* `shomei-server` over an ephemeral migrated PostgreSQL
  (`Shomei.Migrations.TestSupport.withShomeiMigratedDatabase`) plus the downstream app
  in-process via `Network.Wai.Handler.Warp.testWithApplication`, then asserts valid → 200,
  tampered → 401, missing → 401. It already depends on `warp`, `http-client`, `http-types`,
  `tasty`, `tasty-hunit` — everything the new stub-server tests need.

The current cache (`src/Downstream/Service.hs`, lines ~52–85):

```haskell
data JwksCache = JwksCache
  { cacheMgr :: !HTTP.Manager,
    cacheUrl :: !String,
    cacheTtl :: !NominalDiffTime,
    cacheState :: !(MVar (Maybe (JWKSet, UTCTime)))
  }

currentJwks :: JwksCache -> IO JWKSet
currentJwks cache = do
  now <- getCurrentTime
  modifyMVar cache.cacheState \st ->
    case st of
      Just (jwks, fetchedAt) | diffUTCTime now fetchedAt < cache.cacheTtl -> pure (st, jwks)
      _ -> do
        jwks <- fetchJwks cache.cacheMgr cache.cacheUrl
        pure (Just (jwks, now), jwks)
```

Read the defects off the code: `modifyMVar` on the hit path (every request through one
lock); the miss path holds the lock across `fetchJwks`'s full HTTP round-trip (all requests
block); `fetchJwks` throws `ioError` on failure, `modifyMVar` restores the state *unchanged*
— same expired timestamp — so the next request repeats the fetch (the serialized retry
storm), and the stale `jwks` value in hand is discarded rather than served. `currentJwks` is
called from `localAuthHandler` (lines ~112–121), which currently maps any verification
failure to 401; `currentJwks` is **not exported** today.

Terms: *single-flight* — at most one refresh HTTP call in flight regardless of request
concurrency; *refresh-ahead* — refreshing before expiry so no request ever lands on an
expired cache; *stale-on-error* — serving the last good value when refresh fails;
*fail closed* — refusing (503) rather than accepting when no sufficiently-fresh key material
exists; *TTL* — time-to-live, the intended freshness lifetime; *JWKS* — the JSON Web Key Set
document of public verification keys.

The documentation to update is `docs/user/client-and-examples.md`, section "Microservice
Auth Stack" (currently ~15 lines describing the fetch-cache-verify flow generically).


## Plan of Work

### Milestone M1 — rewrite the cache

Scope: `src/Downstream/Service.hs` and `app/Main.hs`. At the end the example builds, the old
end-to-end test still passes, and the new behavior is in place (M2 proves it).

Replace the cache types and logic:

```haskell
-- | One cached fetch result. 'effectiveTtl' is the configured TTL unless the JWKS
-- response carried Cache-Control: max-age (which then wins, per HTTP semantics).
data CacheEntry = CacheEntry
  { entryJwks :: !JWKSet,
    fetchedAt :: !UTCTime,
    effectiveTtl :: !NominalDiffTime
  }

data JwksCache = JwksCache
  { cacheMgr :: !HTTP.Manager,
    cacheUrl :: !String,
    configuredTtl :: !NominalDiffTime,
    maxStaleness :: !NominalDiffTime,
    -- | Lock-free read path: every request does one readIORef, nothing else.
    cacheEntry :: !(IORef (Maybe CacheEntry)),
    -- | Single-flight guard: full () = no refresh running. NEVER held while readers wait;
    -- taken with tryTakeMVar by the one thread that becomes the refresher.
    refreshLock :: !(MVar ())
  }

-- | Thrown (and mapped to HTTP 503) when no key set newer than 'maxStaleness' exists.
data JwksUnavailable = JwksUnavailable String
  deriving stock (Show)
  deriving anyclass (Exception)

newJwksCache :: HTTP.Manager -> String -> NominalDiffTime -> NominalDiffTime -> IO JwksCache
```

`currentJwks :: JwksCache -> IO JWKSet` becomes (write it exactly in this shape; the file is
a template and this logic is the deliverable):

1. `now <- getCurrentTime`, `mEntry <- readIORef cache.cacheEntry`.
2. **Cold start** (`Nothing`): `withMVar cache.refreshLock \() -> …` — re-read the `IORef`
   inside the lock (another thread may have filled it while we waited); if still empty,
   fetch **synchronously**; on success write the entry and return it; on failure rethrow
   wrapped in `JwksUnavailable` (there is nothing stale to serve at cold start). Blocking
   here is correct and only ever happens before the first successful fetch.
3. **Fresh** (`Just e`, `age < 0.8 * e.effectiveTtl` where `age = diffUTCTime now
   e.fetchedAt`): return `e.entryJwks`. This is the hot path: one `readIORef`, one clock
   read, no locks.
4. **Refresh window** (`age >= 0.8 * effectiveTtl`): attempt to become the refresher with
   `tryTakeMVar cache.refreshLock`; on `Just ()`, `forkIO` the refresh (fetch; on success
   parse an optional `Cache-Control: max-age=N` from the response headers into
   `effectiveTtl` — fall back to `configuredTtl` — and `atomicWriteIORef` the new entry; on
   failure emit one warning line to stderr, e.g. `[downstream] jwks refresh failed (serving
   stale, age 312s): <error>`; **always** `putMVar` the lock back in a `finally`). Whether or
   not we became the refresher: if `age < cache.maxStaleness`, return the current (possibly
   stale) `e.entryJwks`; otherwise `throwIO (JwksUnavailable …)` — fail closed.

`fetchJwks` changes to return the response headers alongside the parsed set (so step 4 can
read `Cache-Control`), and to *return* failures (`Either String`) rather than `ioError`, so
the refresh path never relies on exceptions for control flow; keep a small
`parseMaxAge :: [Header] -> Maybe NominalDiffTime` (case-insensitive header lookup, scan for
`max-age=` digits; anything unparsable → `Nothing`). Add the code comment required by the
Decision Log: the Shōmei server does not currently set `Cache-Control` on its JWKS endpoint;
this branch exists for issuers that do, and adding the header server-side is a documented
follow-up.

In `localAuthHandler`, wrap the `currentJwks` call: catch `JwksUnavailable` and throw
`err503 {errBody = "verification keys unavailable"}`; token failures keep returning 401
exactly as today. Export `currentJwks`, `CacheEntry`-free (keep the entry type internal),
`JwksUnavailable (..)`, and the extended `newJwksCache`.

In `app/Main.hs`: read `DOWNSTREAM_JWKS_TTL_SECONDS` (default 900) and
`DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS` (default 86400) with the same
`lookupEnv`/`readMaybe` pattern already used for `DOWNSTREAM_PORT`; pass both to
`newJwksCache`; extend the module haddock listing the new variables.

The library needs `http-types` for header names — check
`examples/microservice-auth-stack/microservice-auth-stack.cabal`'s library `build-depends`
(it is currently only in the test suite) and add it there if missing; no other dependency
changes.

### Milestone M2 — the stub server and the property tests

Scope: the example's test suite. At the end, `cabal test microservice-auth-stack-test` runs
the old end-to-end case plus a new "jwks cache resilience" group, all green.

Build a stub JWKS server inside `test/Main.hs` (or a `test/CacheSpec.hs` module wired into
the suite): a plain WAI app closing over two `IORef`s — `fetchCount :: IORef Int` and
`mode :: IORef StubMode` with
`data StubMode = ServeOk | ServeOkMaxAge Int | Serve500 | ServeDelayed Int` — that, per
request, bumps the counter and answers according to the mode. The JWKS body it serves: fetch
one real document from the in-process auth server the suite already boots (simplest and
guaranteed-valid: `GET /.well-known/jwks.json` once during setup and replay the bytes), or
generate a key with `jose`'s `genJWK` — prefer the replay approach since the suite boots the
auth server anyway. Run the stub under `testWithApplication` exactly like the other apps.

The tests (each builds a fresh cache pointed at the stub; `ttl` means the value passed to
`newJwksCache`):

1. *Cold start is single-flight:* mode `ServeDelayed 300` (ms); 10 threads call
   `currentJwks` concurrently; join; assert all 10 succeeded with the same set and
   `fetchCount == 1`.
2. *Hits fetch nothing:* warm cache (ttl 900 s); 100 sequential + 20 concurrent
   `currentJwks`; `fetchCount` still 1.
3. *Refresh-ahead, no latency spike:* ttl 1 s; warm; sleep 850 ms; time one `currentJwks`
   call — assert it returns in < 100 ms (it must not wait on the refetch) and returns the
   old set; then poll up to 3 s until `fetchCount == 2` (the background refresh happened).
4. *Stale-on-error:* ttl 1 s, maxStaleness 60 s; warm; set `Serve500`; sleep 1200 ms;
   `currentJwks` succeeds with the old set (no exception); repeat 5 calls over ~1 s — all
   succeed.
5. *Failure burst stays single-flight:* continuing from 4, record `fetchCount`, fire 20
   concurrent `currentJwks`, and assert `fetchCount` grew by at most 2 (one in-flight
   refresher at a time; a second may start after the first releases).
6. *Fail closed past max staleness:* ttl 1 s, maxStaleness 3 s; warm; `Serve500`; sleep
   3.3 s; `currentJwks` throws `JwksUnavailable`; and through the HTTP surface, a
   `GET /projects` with a valid token now returns **503** (build the downstream app against
   this cache to check the handler mapping).
7. *`max-age` wins:* configured ttl 900 s but mode `ServeOkMaxAge 1`; warm; sleep 1.2 s;
   one `currentJwks`; poll until `fetchCount == 2` — the header-derived 1 s TTL triggered the
   refresh a configured-TTL cache would not have attempted.

Keep the pre-existing end-to-end test unchanged; it now exercises the new cache underneath
and must stay green.

### Milestone M3 — documentation

Scope: `docs/user/client-and-examples.md`, "Microservice Auth Stack" section. Rewrite it to
present `examples/microservice-auth-stack/src/Downstream/Service.hs` as **the recommended
template** for downstream verification, enumerating its properties in the operator's terms:
verification is offline (no per-request auth-service call); reads are lock-free (one
`readIORef` per request); refresh is single-flight and refresh-ahead (kicked at 80% of TTL,
so healthy operation never has a latency cliff); auth-service downtime does not take the
downstream down (stale keys served and logged, up to a hard bound); past
`DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS` (default 24 h) the service fails closed with 503;
`DOWNSTREAM_JWKS_TTL_SECONDS` (default 900) configures freshness; a `Cache-Control: max-age`
on the JWKS response overrides the TTL — with the explicit note that Shōmei's own JWKS
endpoint does not currently send `Cache-Control`, and that adding it is a possible
server-side follow-up outside this example. Keep the existing run instructions and add the
two new environment variables to the sample invocation.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. The test suite
provisions its own ephemeral PostgreSQL; no dev database needed.

```bash
# M1
cabal build microservice-auth-stack
```

Expected: compiles with no warnings (the workspace builds with -Wall and friends).

```bash
# M2
cabal test microservice-auth-stack-test
```

Expected excerpt:

```text
microservice demo: downstream local JWT verification
  valid token → 200 (offline), tampered → 401, none → 401: OK
  jwks cache resilience
    cold start is single-flight (10 callers, 1 fetch):     OK
    cache hits never fetch:                                OK
    refresh-ahead returns stale instantly, refetches once: OK
    stale-on-error keeps serving after auth-service death: OK
    failure burst stays single-flight:                     OK
    past max staleness the service fails closed (503):     OK
    Cache-Control max-age overrides the configured TTL:    OK
```

Manual demonstration (optional but worth one transcript for Outcomes): start the dev stack's
auth server, start the example (`SHOMEI_JWKS_URL=http://localhost:8080/.well-known/jwks.json
DOWNSTREAM_JWKS_TTL_SECONDS=30 cabal run example-project-service`), log a user in, call
`curl -H "Authorization: Bearer $TOKEN" localhost:8090/projects` → 200; **stop the auth
server**; keep calling past the 30 s TTL → still 200, with
`[downstream] jwks refresh failed (serving stale, …)` lines on the example's stderr.

```bash
# M3 + wrap-up
nix fmt
cabal build all && cabal test all
```

Then update this plan's living sections and MasterPlan 6's Progress checkboxes and registry
row.


## Validation and Acceptance

Acceptance is behavioral and mechanized:

1. All seven cache tests plus the pre-existing end-to-end test pass in
   `cabal test microservice-auth-stack-test`, and `cabal test all` stays green.
2. The single-flight property is quantitative: 10 concurrent cold-start callers produce
   exactly 1 fetch; a 20-caller failure burst grows the fetch count by at most 2.
3. The resilience story is demonstrable live (the manual transcript above): killing the auth
   service does not produce downstream 500s until the max-staleness bound, and the failure
   mode at that bound is 503, not 401.
4. The refresh-ahead property is a latency assertion: a request inside the refresh window
   returns in under 100 ms while the refetch proceeds in the background.
5. `docs/user/client-and-examples.md` names every property and both environment variables;
   a reader can copy `Downstream/Service.hs` and know its guarantees without reading this
   plan.


## Idempotence and Recovery

Everything here is source and docs in one example package plus one docs file — re-runnable,
independently revertible, no schema or config-format changes, no impact on any other package
(`shomei-server` and the libraries are untouched; verify with `git diff --stat` that only
`examples/microservice-auth-stack/` and `docs/user/client-and-examples.md` changed). The
timing-based tests are the only fragile part: if one flakes on a loaded machine, widen its
margin (Decision Log) and record it in Surprises rather than weakening the asserted
property. The manual demonstration stops only the *dev* auth server; the example's own state
is a process-lifetime cache, reset by restarting it.


## Interfaces and Dependencies

Dependencies: only the example package is touched; add `http-types` to its **library**
`build-depends` (already in the test suite's) for header handling. Everything else
(`http-client`, `jose`, `warp`, `tasty`, `tasty-hunit`, `shomei-jwt`, `shomei-core`) is
already declared.

Must exist at the end, all in
`examples/microservice-auth-stack/src/Downstream/Service.hs`:

- `newJwksCache :: HTTP.Manager -> String -> NominalDiffTime -> NominalDiffTime ->
  IO JwksCache` (manager, JWKS URL, configured TTL, max staleness).
- `currentJwks :: JwksCache -> IO JWKSet` — exported; lock-free hit path; single-flight
  refresh; refresh-ahead at 80% of the effective TTL; stale-on-error; throws
  `JwksUnavailable` only at cold-start failure or past max staleness.
- `JwksUnavailable (..)` (an `Exception`), mapped to `err503` in `localAuthHandler`;
  invalid tokens still map to `err401`.
- `downstreamApplication :: JwksCache -> ShomeiConfig -> Application` — signature unchanged
  (the template's public face stays copy-compatible).
- `app/Main.hs` honoring `DOWNSTREAM_JWKS_TTL_SECONDS` (default 900) and
  `DOWNSTREAM_JWKS_MAX_STALENESS_SECONDS` (default 86400).
- The test additions in `examples/microservice-auth-stack/test/` and the rewritten
  "Microservice Auth Stack" section of `docs/user/client-and-examples.md`.

Cross-plan note (MasterPlan 6): this plan is independent of EP-1–EP-4 and touches none of
their files. The one seam it *documents* but must not implement is the auth server sending
`Cache-Control` on `/.well-known/jwks.json` (a possible future plan; also adjacent to the
Security MasterPlan's JWKS hot-reload work in
`docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`, which changes how
the served set is assembled but not this example).
