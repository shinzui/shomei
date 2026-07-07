---
id: 36
slug: middleware-hardening-rate-limiter-eviction-metrics-accuracy-and-warp-settings
title: "Middleware Hardening: Rate-Limiter Eviction, Metrics Accuracy, and Warp Settings"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/6-operational-and-performance-hardening.md"
---

# Middleware Hardening: Rate-Limiter Eviction, Metrics Accuracy, and Warp Settings

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-4** of MasterPlan 6
(`docs/masterplans/6-operational-and-performance-hardening.md`, "Operational and Performance
Hardening"). It is four small, independent fixes to the WAI middleware layer of
`shomei-server`, each with its own milestone and its own test: (1) the in-process rate
limiter finally evicts idle per-IP buckets instead of growing forever; (2) the in-flight
requests gauge stops leaking permanently when a handler throws; (3) each request-log line is
written as one strict write instead of a lazy multi-chunk write; (4) warp gets explicit
settings — exceptions routed to the structured logger, a server name, and a request-body size
cap for the JSON API.


## Purpose / Big Picture

Three latent operational bugs and one gap live in `shomei-server`'s HTTP middleware today.
The per-IP token-bucket rate limiter stores one bucket per distinct client IP in a single
in-memory map and **never removes any** — an internet-facing instance leaks memory linearly
in the number of IPs that ever touched a throttled endpoint (a slow scan of the IPv4 space
is an unbounded-memory denial-of-service primitive). The Prometheus
`http_requests_in_flight` gauge is incremented before the handler runs and decremented only
on the success path, so every handler exception permanently inflates it — after a week of
sporadic 500s the gauge reads a fiction, and dashboards/alerts built on it lie. Every request
log line is written with a lazy `BL.hPut`, which under concurrency can interleave chunks of
two lines (corrupting the one-JSON-object-per-line contract downstream log pipelines rely
on) and serializes all requests through the stdout handle lock chunk by chunk. And warp runs
with near-default settings: an exception escaping a handler is printed by warp's default
handler as unstructured text to stderr — invisible to anyone tailing the JSON log stream —
and nothing caps request body sizes.

After this plan, each defect is observably gone: a test drives thousands of distinct IPs
through the limiter and asserts the bucket map stays bounded (and a live server's limiter
does not grow when probed); a test throws from a handler and asserts the exported gauge
returns to `0`; a test writes hundreds of log lines from concurrent threads through the real
emit path and asserts every line parses as one JSON object; and killing a handler on a live
server produces a structured `{"level":"error","msg":"unhandled exception",…}` line on
stdout while an oversized request body is refused with HTTP 413 before reaching a handler.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: amortized idle-bucket eviction in
      `shomei-server/src/Shomei/Server/Middleware/RateLimit.hs` (prune fully-refilled buckets
      every `sweepEvery` throttled requests, inside the existing STM transaction).
- [ ] M1: `bucketCount` accessor + `newRateLimiterWith` test seam exported; unit tests: idle
      buckets evicted, active (non-refilled) buckets retained, bounded-size property.
- [ ] M1: STM-contention note added to the module haddock (single-TVar, single-instance
      posture, sharding as the future escape hatch).
- [ ] M2: exception-safe in-flight gauge in
      `shomei-server/src/Shomei/Server/Observability/Metrics.hs` (`onException` decrement).
- [ ] M2: test: a throwing handler leaves `http_requests_in_flight 0` in `exportMetrics`.
- [ ] M3: strict single-write log emission in
      `shomei-server/src/Shomei/Server/Observability/Logging.hs`
      (`renderLogLine` pure + one `BS.hPut`); control characters stripped in plain format.
- [ ] M3: concurrency test: 200 threads × 5 lines through a shared temp-file `Handle`, every
      line parses as a single JSON object.
- [ ] M4: `setOnException` routed to a structured error line; `setServerName`;
      request-body cap middleware (413 above 1 MiB) inserted into the stack; final middleware
      order recorded here.
- [ ] M4: unit test of the exception logger's output shape; live transcript of a killed
      handler producing the structured line; 413 transcript.
- [ ] `nix fmt` clean; `cabal build all` / `cabal test all` green; MasterPlan 6 Progress and
      registry updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep the limiter's algorithm (token bucket) and its configuration shape
  (`RateLimitConfig` in `shomei-core/src/Shomei/Config.hs`) untouched; add eviction only.
  Rationale: MasterPlan 6 scopes this plan to hardening, not redesign; the bucket math is
  correct and the config is public API surface other docs reference.
  Date: 2026-07-07

- Decision: Evict by **piggybacking on `takeToken`** (an amortized prune of the whole map
  every `sweepEvery` = 4096 throttled requests, inside the same `atomically`), not with a
  periodic background thread.
  Rationale: A thread would want the supervised-thread idiom that plan 34 owns
  (`Shomei.Server.Supervisor.supervisedLoop`), creating an ordering dependency between two
  plans the MasterPlan declares independent; piggybacking needs no thread, no clock reads
  beyond the one `takeToken` already has, and costs O(map size) once per 4096 requests —
  amortized O(1). The trade-off (an idle server never prunes because no requests arrive) is
  harmless: no requests means no *new* buckets either, so the map cannot grow while unpruned.
  If plan 34's idiom is already merged when this lands, we still keep piggybacking — fewer
  moving parts — and note the alternative here.
  Date: 2026-07-07

- Decision: A bucket is evictable exactly when it is **fully refilled at prune time**
  (`nowSecs - lastRefill >= (capacity - tokens) / refillPerSec`), making eviction
  *semantically lossless*: a missing bucket and a full bucket are indistinguishable, because
  `takeToken` treats an absent key as a fresh full bucket.
  Rationale: This is the rare eviction policy with zero behavior change — no request that
  would have been throttled is admitted and vice versa — so it needs no tuning knob and no
  new config field, and the eviction test can assert exact equivalence rather than
  approximations.
  Date: 2026-07-07

- Decision: Fix the gauge with `Control.Exception.onException` around the
  application call (decrement-on-exception), keeping the normal-path decrement in the
  response continuation where the latency observation already lives.
  Rationale: The middleware must decrement exactly once whether the inner app (a) responds
  normally (continuation runs, then nothing throws after), or (b) throws before/instead of
  responding (`onException` runs, continuation never did). A full `bracket` would risk
  double-decrement since the "release" cannot see whether the continuation already ran;
  `onException` + last-statement-continuation is the minimal exact-once structure. The
  latency histogram and request counter intentionally still skip exception-aborted requests
  (they produced no response status to label); only the gauge must be exception-exact.
  Date: 2026-07-07

- Decision: Log lines become a pure `renderLogLine` returning one **strict** `ByteString`
  (newline included) written with a single `BS.hPut`; the plain (non-JSON) format also strips
  control characters from rendered values.
  Rationale: One strict `hPut` holds the handle lock once per line and cannot interleave with
  another thread's line (lazy `BL.hPut` writes chunk-by-chunk under the lock, but the
  buffered handle may flush between chunks of a line under LineBuffering when a chunk
  contains the eventual newline — and it takes/releases per chunk, a throughput ceiling).
  Making rendering pure also makes the "exactly one line, valid JSON" property directly
  testable. Control-char stripping in `LogPlain` closes a theoretical injection hole the
  JSON encoder already closes by escaping.
  Date: 2026-07-07

- Decision: Warp gets `setOnException` (routed to a structured JSON error line, filtered by
  `defaultShouldDisplayException` so client disconnects stay quiet), `setServerName
  "shomei"`, and a **hand-rolled 1 MiB request-body cap middleware** that rejects
  `KnownLength`-bodies over the cap with 413 and passes chunked bodies through with a
  documented caveat.
  Rationale: Exceptions must land in the same stream operators already tail. warp has no
  built-in body-size setting (body limiting is a middleware concern); `wai-extra`'s
  `RequestSizeLimit` handles chunked bodies too but is not currently a dependency, and the
  house convention (see the hand-rolled logging/metrics decisions in
  `docs/plans/10-observability-structured-logging-metrics-and-health-probes.md`) is to avoid
  new dependencies for small testable code. Every legitimate Shōmei client sends
  `Content-Length` (JSON bodies of a few hundred bytes), so the `KnownLength` check covers
  the real API; the chunked caveat is recorded in the module haddock and below.
  Date: 2026-07-07

- Decision: Add an explicit STM-contention **note** (documentation, not code): the limiter is
  one `TVar (HashMap ip Bucket)` whose root every throttled request rewrites; under very high
  concurrency STM retries make it a serialization point. Accepted for the documented
  single-instance posture; the escape hatch (sharding the map by IP hash across N TVars) is
  named in the haddock for whoever needs it.
  Rationale: MasterPlan 6's Progress line for EP-4 explicitly pairs "eviction" with a
  "contention note"; actually sharding is a redesign out of hardening scope.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Haskell workspace
(GHC 9.12.4, GHC2024). Work inside `nix develop`; `cabal build all`, `cabal test all`,
`nix fmt`; dev database via `just create-database` (only the live transcripts need it — the
new tests in this plan are database-free).

**WAI and middleware, in one paragraph.** A WAI `Application` is
`Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived` — the handler receives
the request and a `respond` continuation. A `Middleware` is `Application -> Application`; the
server's stack is assembled in `Shomei.Server.Boot.main`
(`shomei-server/src/Shomei/Server/Boot.hs`, lines ~70–97) as, outermost first:
`requestLoggingMiddleware` → `metricsMiddleware` → `metricsEndpointMiddleware` →
`rateLimitMiddleware` → the Servant application. The same function builds `warpSettings`
(lines ~92–95: port, graceful-shutdown timeout, shutdown handler — nothing else) and runs
`Warp.runSettings warpSettings (stack (application env))`.

**The rate limiter** (`shomei-server/src/Shomei/Server/Middleware/RateLimit.hs`, ~112
lines). State: `buckets :: TVar (HashMap ByteString Bucket)` with
`Bucket { tokens :: Double, lastRefill :: Double }` (POSIX seconds), plus pure fields
`capacity` (= configured `perIpBurst`), `refillPerSec` (= `perIpRequestsPerMinute / 60`),
`enabled`. `takeToken rl key nowSecs` (lines ~62–73) runs one `atomically`: look up the key
(absent ⇒ fresh full bucket), refill by elapsed time capped at capacity, take a token or
refuse, **`HM.insert` the updated bucket back either way** — so both allowed and refused
requests write the map, and refused probes from new IPs still *create* buckets. Nothing ever
deletes an entry; `grep -n "HM.delete\|filter" RateLimit.hs` confirms. The middleware only
throttles unauthenticated POST paths (`/auth/login`, `/auth/signup`, `/auth/refresh`,
`/auth/verify-email/request`, `/auth/password-reset/request`) keyed by peer IP without port.

**The metrics registry** (`shomei-server/src/Shomei/Server/Observability/Metrics.hs`).
Hand-rolled `IORef`s; `metricsMiddleware` (lines ~87–97) does `bumpInt m.inFlight 1`, reads
the clock, then calls `app req \res -> do received <- respond res; …; bumpInt m.inFlight
(-1); …` — the decrement lives **only inside the response continuation**, so an exception
thrown by the inner application before it responds (for example the infrastructure path:
`Shomei.Server.Boot.seamEnv`'s `runPorts` raises `ioError` on a database failure, which flies
through the middleware to warp) skips the decrement forever. `exportMetrics` renders the
Prometheus text body; the `Metrics` record's fields are not exported (tests observe via
`exportMetrics`).

**The request logger** (`shomei-server/src/Shomei/Server/Observability/Logging.hs`).
`emit` (lines ~71–77) does `BL.hPut stdout (render fmt fields <> "\n")` — a **lazy**
ByteString write — after `Shomei.Server.Boot.main` set stdout to `LineBuffering`. `LogPlain`
rendering filters only the `"` character from values. Request-ids are already sanitized
(`resolveRequestId`), and HTTP request lines cannot contain raw newlines, so today's fields
are newline-free in practice — the strict-write fix is about atomicity and throughput, plus
defense in depth.

**Warp settings** (`Boot.hs` lines ~92–95): `setPort`, `setGracefulShutdownTimeout`,
`setInstallShutdownHandler` only. No `setOnException` (warp's default prints
`hPutStrLn stderr` prose), no `setServerName` (default advertises warp's version), no body
bound anywhere in the stack. Relevant warp API (package `warp`, module
`Network.Wai.Handler.Warp`): `setOnException :: (Maybe Request -> SomeException -> IO ()) ->
Settings -> Settings`, `defaultShouldDisplayException :: SomeException -> Bool` (False for
routine client-abort exceptions), `setServerName :: ByteString -> Settings`.

**Where tests live.** `shomei-server` has test-suite `shomei-server-test`
(`shomei-server/test/Main.hs`, which currently drives `Shomei.Server.E2ESpec`) plus
`shomei-server-config-test` and `shomei-admin-test`. This plan adds a database-free spec
module `shomei-server/test/Shomei/Server/MiddlewareSpec.hs`, registered in the
`shomei-server-test` stanza's `other-modules` and invoked from `test/Main.hs`. The suite
already depends on `tasty`/`tasty-hunit`-style helpers — mirror whatever `Main.hs` uses
(check its imports before writing the spec).


## Plan of Work

Four milestones. Order is free; the listed order goes riskiest-first. Each milestone is a
self-contained diff with its own test and leaves `cabal test all` green.

### Milestone M1 — rate-limiter eviction

Scope: eviction inside `takeToken`, two test seams, tests, and the contention note. At the
end the bucket map is provably bounded and limiter behavior is otherwise bit-identical.

Edit `shomei-server/src/Shomei/Server/Middleware/RateLimit.hs`:

- Add to `RateLimiter`: `sweepCounter :: !(TVar Int)` and `sweepEvery :: !Int`.
  `newRateLimiter` sets `sweepEvery = 4096`; add
  `newRateLimiterWith :: Int -> RateLimitConfig -> IO RateLimiter` (documented as a test
  seam) that sets it explicitly, and implement `newRateLimiter = newRateLimiterWith 4096`.
- Add `bucketCount :: RateLimiter -> IO Int` (`HM.size <$> readTVarIO rl.buckets`).
- In `takeToken`, inside the existing `atomically` block, after the insert: increment
  `sweepCounter`; when it reaches `sweepEvery`, reset it to 0 and replace the map with
  `HM.filter (not . fullyRefilled) m'` where

```haskell
-- A bucket that would refill to full is indistinguishable from an absent one
-- (takeToken treats a missing key as a fresh full bucket), so pruning it is lossless.
fullyRefilled :: Bucket -> Bool
fullyRefilled (Bucket lvl t0) =
  lvl + (nowSecs - t0) * rl.refillPerSec >= rl.capacity
```

  Keep the just-touched key's fresh bucket out of the prune only if it is itself not full
  (the formula already handles it: a just-drained bucket is not fully refilled).
- Extend the module haddock with the contention note from the Decision Log (single global
  `TVar`; every throttled request rewrites the root; acceptable single-instance; shard by IP
  hash if this ever profiles hot) and with the eviction invariant.

Tests in `MiddlewareSpec.hs` (pure — `takeToken` takes the clock as an argument, so no real
time is involved; `takeToken` and the seams must be exported): with
`perIpBurst = 3`, `perIpRequestsPerMinute = 60` (refill 1/s), `sweepEvery = 8`:

1. *Idle buckets are evicted:* touch IPs `ip1…ip8` once each at `t=0` (8 calls — the 8th
   triggers the sweep at a moment everything is ≥ 3 s from full? no: at `t=0` each bucket
   holds 2 of 3 tokens, not full, nothing evicted — assert `bucketCount == 8`); then at
   `t=100` touch `ip9` eight times (all buckets from `t=0` have long since refilled; the
   sweep on the 8th call prunes them) — assert `bucketCount == 1` (only `ip9`, which is
   mid-refill).
2. *Eviction is lossless:* drain `ipA` to refusal at `t=0` (4 calls), force a sweep via 8
   `ipB` calls still at `t=0`, then assert `takeToken … "ipA" 0` still refuses — the drained
   bucket survived the sweep because it was not fully refilled.
3. *Bounded size:* loop 10,000 distinct IPs, one call each, all at increasing timestamps
   spaced 10 s apart (so predecessors are fully refilled); assert `bucketCount ≤ sweepEvery
   + 1` at the end.

### Milestone M2 — exception-exact in-flight gauge

Scope: the `onException` fix and its test.

Edit `metricsMiddleware` in `Shomei.Server.Observability.Metrics`:

```haskell
metricsMiddleware :: Metrics -> Middleware
metricsMiddleware m app req respond = do
  bumpInt m.inFlight 1
  start <- getPOSIXTime
  ( app req \res -> do
      received <- respond res
      end <- getPOSIXTime
      bumpInt m.inFlight (-1)
      observeDuration m (realToFrac (end - start))
      recordRequest m req (statusCode (responseStatus res))
      pure received
    )
    `onException` bumpInt m.inFlight (-1)
```

(`onException` from `Control.Exception`.) The decrement runs exactly once: on the normal path
inside the continuation (after which nothing in this middleware can throw), or via
`onException` when the inner app or `respond` throws before the continuation's decrement
executed. Import list gains `Control.Exception (onException)`.

Test in `MiddlewareSpec.hs` (no server needed — call the middleware directly): build
`newMetrics`; let `boomApp _req _respond = throwIO (ErrorCall "boom")`; call
`metricsMiddleware m boomApp defaultRequest (\_ -> undefined)` and catch the `ErrorCall`;
then `exportMetrics m` and assert the body contains the line
`http_requests_in_flight 0`. Also the positive case: a normal app that responds 200 —
gauge back to 0, `http_requests_total{method="GET",status="200"} 1` present.
(`defaultRequest` comes from `Network.Wai`; the throwing case never uses the respond
continuation, so `undefined` is safe and keeps the test honest.)

### Milestone M3 — one strict write per log line

Scope: pure rendering, single write, control-char defense, concurrency test.

Edit `Shomei.Server.Observability.Logging`:

- Add and export `renderLogLine :: LogFormat -> [(Key, Value)] -> ByteString` — the existing
  `render` logic made pure and strict (`BL.toStrict` of the aeson encoding for `LogJson`;
  the intercalated key=value text for `LogPlain`, with `Text.filter (\c -> c >= ' ')`
  applied to each rendered value so no control character — including `\n` — survives),
  with the trailing `"\n"` appended.
- Add `emitLine :: Handle -> ByteString -> IO ()` = `BS.hPut h` (one call), and rewrite
  `emit fmt fields = emitLine stdout (renderLogLine fmt fields)`. `Data.ByteString` is
  already imported qualified as `BS`.

Tests in `MiddlewareSpec.hs`:

1. *Line shape:* for both formats and a field list containing a value with an embedded
   `"\n"` and a `"\""`, `renderLogLine` output ends with exactly one `\n` and contains no
   other `\n`; the `LogJson` output (minus newline) round-trips through
   `Data.Aeson.decodeStrict` as a JSON object.
2. *Concurrent integrity:* open a temp file `Handle` (`openTempFile`, `LineBuffering` to
   match production), fork 200 threads each writing 5 distinct rendered JSON lines through
   `emitLine`, join via `MVar`s, `hClose`, read the file back: exactly 1000 lines, and every
   line `decodeStrict`s to an object carrying its thread/sequence markers; the multiset of
   (thread, seq) pairs is complete.

### Milestone M4 — warp settings and the body cap

Scope: `setOnException`, `setServerName`, the 413 middleware, the recorded stack order, and
live transcripts.

- In `Shomei.Server.Observability.Logging`, add and export
  `logServerError :: Maybe Request -> SomeException -> IO ()`: renders (via `renderLogLine
  LogJson`) fields `level="error"`, `msg="unhandled exception"`, `error=show e`, plus
  `method`/`path` when the `Request` is present, and `emitLine stdout` — the same stream and
  shape as request lines, so pipelines pick it up unchanged.
- In `Boot.main`'s `warpSettings` (lines ~92–95), add:

```haskell
. Warp.setServerName "shomei"
. Warp.setOnException
    (\mreq e -> when (Warp.defaultShouldDisplayException e) (logServerError mreq e))
```

- New module `shomei-server/src/Shomei/Server/Middleware/BodyLimit.hs` exporting
  `bodyLimitMiddleware :: Int64 -> Middleware`: if `requestBodyLength req` is
  `KnownLength n` with `n >` the cap, respond immediately
  `413 {"error":"payload_too_large"}` (JSON content-type) without touching the body;
  otherwise pass through. Haddock records the chunked-transfer caveat (a chunked body
  bypasses the cap; Shōmei's JSON clients always send Content-Length; adopting `wai-extra`'s
  `RequestSizeLimit` is the upgrade path if that ever matters). Cap constant: 1 MiB
  (`1024 * 1024`), applied in `Boot.main`'s stack between metrics and the rate limiter.
- Record the final composed order in this plan and in the `Boot.main` comment:
  `requestLoggingMiddleware . metricsMiddleware . metricsEndpointMiddleware .
  bodyLimitMiddleware 1MiB . rateLimitMiddleware . application` (logging outermost per
  MasterPlan 2's IP-4 contract, which this plan must not break; the body cap sits inside
  metrics so 413s are counted and logged, and outside the limiter so oversized floods don't
  drain token buckets).

Tests and transcripts: unit-test `bodyLimitMiddleware` directly (a `defaultRequest` with
`requestBodyLength = KnownLength (2*1024*1024)` gets 413 and the inner app is never called —
detect via an `IORef Bool`; a small known length passes through); unit-test
`logServerError`'s rendered line decodes as JSON with `level == "error"`. Live: see Concrete
Steps for the killed-handler and oversized-body transcripts.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

Step 1 (M1–M3 code + spec module). Create
`shomei-server/test/Shomei/Server/MiddlewareSpec.hs`, add it to the `shomei-server-test`
stanza's `other-modules` in `shomei-server/shomei-server.cabal`, call it from
`shomei-server/test/Main.hs`. Then per milestone:

```bash
cabal build shomei-server
cabal test shomei-server-test
```

Expected excerpt once M1–M3 are in:

```text
  middleware hardening
    rate limiter: idle buckets evicted after sweep:        OK
    rate limiter: drained bucket survives sweep (lossless): OK
    rate limiter: 10k one-shot IPs stay bounded:            OK
    metrics: throwing handler leaves in-flight at 0:        OK
    metrics: normal request counted and gauge returns to 0: OK
    logging: renderLogLine is one valid JSON line:          OK
    logging: 200 concurrent writers, 1000 intact lines:     OK
    body limit: 2MiB Content-Length rejected 413:           OK
    onException logger renders structured error JSON:       OK
```

Step 2 (M4 live transcripts; requires the dev database):

```bash
just create-database
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shomei-server > server.log 2>server.err &
sleep 2
# 413: oversized body (2 MiB of JSON) on a throttled JSON route
head -c 2097153 /dev/zero | tr '\0' 'a' > /tmp/big.json
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/auth/login \
  -H 'Content-Type: application/json' --data-binary @/tmp/big.json
```

Expected: `413`, and `server.log` shows the request line with `"status":413`.

```bash
# structured exception line: make the DB unreachable mid-flight, then hit a DB-backed route
pg_ctl stop -D "$PGDATA" 2>/dev/null || process-compose down postgres  # dev-stack-appropriate stop
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/auth/login \
  -H 'Content-Type: application/json' -d '{"email":"a@b.c","password":"xxxxxxxxxxxx"}'
grep 'unhandled exception' server.log | tail -1
```

Expected: `500` from curl, and one JSON line like

```json
{"level":"error","msg":"unhandled exception","method":"POST","path":"/auth/login","error":"user error (shomei infrastructure error: ...)"}
```

on **stdout** (`server.log`), not prose on stderr. Restart PostgreSQL afterwards. Check the
server header while it is up: `curl -sI localhost:8080/health | grep -i '^server:'` prints
`Server: shomei`.

Step 3: `nix fmt`, `cabal build all`, `cabal test all`; update this plan's living sections
and MasterPlan 6's Progress/registry.


## Validation and Acceptance

Acceptance is the union of the four milestone behaviors, each independently checkable:

1. **Limiter:** the three M1 tests pass; on a live server,
   hammering `/auth/login` from one IP still throttles exactly as before this plan
   (429 after the burst, recovering at the configured rate) — no user-visible change.
2. **Gauge:** the M2 tests pass; on a live server, after the killed-handler transcript above,
   `curl -s localhost:8080/metrics | grep http_requests_in_flight` prints
   `http_requests_in_flight 0` once the request has completed — before this plan the same
   sequence left it at `1` forever (worth reproducing once on the pre-plan build to see the
   defect, then confirming the fix).
3. **Logging:** the M3 tests pass; `grep -c '^{' server.log` equals the number of requests
   made (every line is a JSON object, none interleaved).
4. **Warp:** the transcripts above — 413 on a 2 MiB body, `Server: shomei`, structured
   `unhandled exception` JSON on stdout with the request's method/path.
5. `cabal test all` fully green and `nix fmt` clean.


## Idempotence and Recovery

All four changes are pure source edits with no schema, config-format, or wire-format impact;
re-running any build/test step is safe, and each milestone can be reverted independently
(they touch disjoint code except for the two `Logging.hs` milestones M3/M4, which are
additive to one another). The live transcripts stop and restart the dev PostgreSQL — that
stack is disposable (`just create-database` rebuilds it), but do not run those steps against
a database you care about. If the eviction sweep ever misbehaved in production, the
mitigation is the existing master switch `rateLimitEnabled = false` (config/env), which
bypasses the limiter entirely — availability over throttling.


## Interfaces and Dependencies

No new dependencies: `stm`, `wai`, `warp`, `http-types`, `aeson`, `bytestring`,
`unordered-containers`, and `base`'s `Control.Exception` are already in
`shomei-server`'s build-depends (verify `unordered-containers` is listed — `RateLimit.hs`
already imports `Data.HashMap.Strict`, so it is).

Must exist at the end:

- `Shomei.Server.Middleware.RateLimit` additionally exporting `takeToken`,
  `bucketCount :: RateLimiter -> IO Int`, and
  `newRateLimiterWith :: Int -> RateLimitConfig -> IO RateLimiter`; eviction invariant and
  contention note in the haddock; `newRateLimiter` behavior unchanged for callers.
- `Shomei.Server.Observability.Metrics.metricsMiddleware` exception-exact per M2 (public
  signature unchanged).
- `Shomei.Server.Observability.Logging` additionally exporting
  `renderLogLine :: LogFormat -> [(Key, Value)] -> ByteString`,
  `emitLine :: Handle -> ByteString -> IO ()`, and
  `logServerError :: Maybe Request -> SomeException -> IO ()`.
- `Shomei.Server.Middleware.BodyLimit.bodyLimitMiddleware :: Int64 -> Middleware` (new
  module in `shomei-server.cabal`'s `exposed-modules`).
- `Shomei.Server.Boot.main` composing the recorded stack order and the extended
  `warpSettings` (`setOnException`, `setServerName`).
- `shomei-server/test/Shomei/Server/MiddlewareSpec.hs` wired into `shomei-server-test`.

Cross-plan notes (MasterPlan 6 Integration Points): plan 35's load test reads
`/metrics` — after this plan the in-flight gauge is trustworthy under failures; plan 34 owns
the supervised-thread idiom — this plan deliberately avoids needing it (see Decision Log);
the middleware order contract with the observability plan
(`docs/plans/10-observability-structured-logging-metrics-and-health-probes.md`, logging
outermost) is preserved and re-recorded here.
