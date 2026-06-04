---
id: 10
slug: observability-structured-logging-metrics-and-health-probes
title: "Observability: structured logging, metrics, and health probes"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Observability: structured logging, metrics, and health probes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-3** of MasterPlan 2
(`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`,
"Production Hardening, Account Lifecycle, and Adoption"). It makes Shōmei **observable and
operable**: a running operator can see what the server is doing (structured logs with a
correlation id per request), measure it (Prometheus metrics), tell whether it is healthy
enough to receive traffic (a readiness probe distinct from the existing liveness probe),
and stop it cleanly (graceful shutdown that drains in-flight requests). It contributes to
four of the MasterPlan's Integration Points: **IP-3** (append an observability sub-record to
`ShomeiConfig`), **IP-4** (the WAI middleware stack ordering in `shomei-server`), **IP-5**
(the `GET /ready` and `GET /metrics` route/endpoint additions), and **IP-8** (the
`cabal.project` dependency block for the Prometheus and logging libraries).


## Purpose / Big Picture

Today (before this change), if you start `shomei-server` and send it requests, you get almost
nothing back as an operator: no per-request log line you can correlate across a distributed
trace, no numeric metrics to graph or alert on, no machine-checkable signal that the process
is ready to serve traffic (only a bare liveness `GET /health`), and no clean way to stop the
process without potentially cutting an in-flight request mid-write. This plan closes that gap.

After this change, an operator can:

- **Read structured JSON logs with a correlation id per request.** Every HTTP request the
  server handles emits exactly one JSON log line to standard output, for example
  `{"level":"info","msg":"request","request_id":"req_01h…","method":"POST","path":"/auth/login","status":200,"duration_ms":12.4,"client_ip":"127.0.0.1"}`.
  The **request id** (also called a *correlation id*: a short unique string that ties together
  all log lines and downstream calls produced while handling one request) is generated if the
  client did not supply one, or echoed from an incoming `X-Request-Id` request header if it
  did, and it is returned to the client in an `X-Request-Id` response header so the client can
  quote it in a bug report. **No password, token, cookie, or `Authorization` header value
  ever appears in a log line** — this is a hard rule, called out again under "Logging hygiene".

- **Scrape Prometheus metrics.** A new `GET /metrics` endpoint returns the standard
  Prometheus text exposition format (a plain-text list of `metric_name{labels} value` lines)
  describing how many HTTP requests the server has handled, how long they took (a latency
  histogram), how many are in flight right now, plus a few **domain counters** — logins
  succeeded, logins failed, and tokens issued — derived from Shōmei's existing audit-event
  stream. **Prometheus** is the de-facto open-source metrics system: a separate server
  periodically fetches (`scrapes`) this endpoint and stores the numbers as time series you can
  graph and alert on. We expose the endpoint; running Prometheus itself is out of scope.

- **Gate traffic on a readiness probe.** A new `GET /ready` endpoint returns HTTP 200 only
  when the server can actually serve authentication traffic: the PostgreSQL connection pool
  answers a trivial query **and** at least one active signing key is loadable. If the database
  is down or no active key exists, `/ready` returns HTTP 503 (Service Unavailable). This is
  distinct from the existing liveness `GET /health`, which returns 200 as long as the process
  is alive (even if the database is temporarily unreachable). An orchestrator such as
  Kubernetes or a load balancer uses *readiness* to decide whether to send this instance
  traffic, and *liveness* to decide whether to restart it. (These terms are defined in plain
  language under "Liveness versus readiness".)

- **Stop the server cleanly.** When the process receives a `SIGTERM` or `SIGINT` signal
  (the signals an orchestrator or `Ctrl-C` sends to ask a process to stop), the server stops
  accepting new connections, lets the requests already in flight finish, closes the PostgreSQL
  connection pool, logs a shutdown line, and exits with status 0 — rather than dropping
  connections abruptly.

The observable outcome, milestone by milestone: you can `curl` the running server and watch a
correlation-id-bearing JSON log line appear (M1); `curl localhost:PORT/metrics` and see real
Prometheus exposition output including a login counter that increments when you log in (M2);
stop PostgreSQL and watch `/ready` flip to 503 while `/health` stays 200, then restart it and
watch `/ready` return to 200 (M3); and send the server `SIGTERM` during a slow request and
watch that request complete, the pool close, and the process exit cleanly (M4).

Definitions used throughout (so a reader new to the codebase is not lost):

- **WAI** — the *Web Application Interface*, the standard Haskell type for an HTTP application:
  `type Application = Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived`. It
  is provided by the `wai` package. A WAI `Application` is what the web server runs.
- **warp** — the production HTTP server (from the `warp` package) that *runs* a WAI
  `Application`. You hand `warp` a `Settings` value and an `Application`, and it listens on a
  effect and serves requests.
- **Middleware** — a wrapper around a WAI `Application` with type
  `type Middleware = Application -> Application`. A middleware sees every request before the
  inner application does and every response after, so it is the natural place to add logging,
  metrics, request ids, and rate limiting. Middlewares compose by ordinary function
  application: `outer (inner app)`. The **outermost** middleware is the one whose code runs
  first on the way in and last on the way out — it wraps everything else.
- **Servant** — the type-level web-framework library Shōmei uses to declare its API as a
  Haskell type (`ShomeiAPI`) and serve it. MasterPlan 1's EP-5 (`shomei-servant`) defines that
  type and EP-6 (`shomei-server`) turns it into a WAI `Application` and runs it under warp.
- **Prometheus exposition format** — the plain-text format `GET /metrics` returns, one metric
  sample per line, e.g. `http_requests_total{method="POST",status="200"} 42`.
- **effectful effect interface** — Shōmei's core expresses its capabilities (store a user,
  tell the time, publish an audit event) as `effectful` *dynamic effects*: a GADT of
  operations plus a `send`-based smart constructor, given meaning by an *interpreter*. See
  `shomei-core/src/Shomei/Effect/Clock.hs` for the smallest example. This plan adds no core
  logging effect by default; observability lives in the HTTP/server layer.


## Precondition and Orientation

**This plan executes only after MasterPlan 1 is Complete.** MasterPlan 2's "Precondition"
section states this globally: every child plan assumes MasterPlan 1's EP-1 through EP-7 have
landed — in particular that `shomei-server` boots against PostgreSQL, serves the `ShomeiAPI`
(`POST /auth/signup`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `GET /auth/me`,
`/auth/session`, `GET /.well-known/jwks.json`, `GET /health`), signs/verifies ES256 JWTs, and
publishes JWKS. As of the 2026-06-04 package-layout refactor, this precondition is satisfied:
the real `shomei-servant` and `shomei-server` packages live at the repository root and
`cabal build all` / `cabal test all` pass. This plan extends those real modules: the WAI
`Application` assembly in `shomei-server/src/Shomei/Server/App.hs` and
`shomei-server/src/Shomei/Server/Boot.hs`, the warp entry point in
`shomei-server/app/Main.hs`, the `ShomeiAPI` NamedRoutes record in
`shomei-servant/src/Shomei/Servant/API.hs`, and the existing `/health` route.

What already exists today and is stable (so this plan can rely on it):

- The multi-package Cabal workspace at the repository root
  `/Users/shinzui/Keikaku/bokuno/shomei`, driven by `cabal.project`, with `with-compiler:
  ghc-9.12.4`. The seven packages are `shomei-core`, `shomei-jwt`, `shomei-postgres`,
  `shomei-migrations`, `shomei-servant`, `shomei-server`, `shomei-client`.
- The custom prelude `shomei-core/src/Shomei/Prelude.hs`, imported in every module
  (re-exports `Text`, `UTCTime`, `getCurrentTime`, the aeson class surface, lens, `liftIO`,
  etc.). The house build conventions are described under "House conventions" below.
- The runtime config record `ShomeiConfig` in `shomei-core/src/Shomei/Config.hs`
  (issuer, audience, TTLs, password policy, token transport, signing-key config, session-check
  mode) plus `defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig`. This plan **appends**
  an observability sub-record to it (IP-3).
- The audit-event stream: `shomei-core/src/Shomei/Domain/Event.hs` defines
  `AuthEvent` (the sum `UserRegistered | LoginSucceeded | LoginFailed | SessionStarted |
  SessionRevoked | RefreshTokenRotated | RefreshTokenReuseDetected | PasswordChanged |
  UserSuspended | UserDeleted`, each carrying a `*Data` record), and
  `shomei-core/src/Shomei/Effect/AuthEventPublisher.hs` defines the `AuthEventPublisher`
  effect with one operation `PublishAuthEvent :: AuthEvent -> AuthEventPublisher m ()` and a
  `publishAuthEvent` smart constructor. EP-3 (MasterPlan 1) already persists these to
  `shomei_auth_events`; this plan additionally **observes** them to feed domain metric counters.
- The PostgreSQL layer: `shomei-postgres/src/Shomei/Postgres/Database.hs` defines the
  `Database` effect (`RunSession`, `RunTransaction`) and `runDatabasePool :: Pool -> …`;
  `shomei-postgres/src/Shomei/Postgres/Pool.hs` defines
  `acquirePool :: Int -> Text -> IO Pool`. The server holds a `Hasql.Pool.Pool`. The readiness
  probe (M3) runs a trivial query through this pool.
- The signing-key effect: `Shomei.Effect.SigningKeyStore` (in `shomei-core`) exposes
  `ListActiveSigningKeys :: SigningKeyStore m [StoredSigningKey]`; an "active signing key
  exists" check (M3) asks whether that list is non-empty.

This plan **must not** add logging or metrics dependencies to `shomei-core`. The core is
deliberately transport-agnostic (no `wai`, no `warp`, no servant, no `jose`, no `hasql`).
Observability is an HTTP/transport concern, so it lives in `shomei-servant` (the
readiness DTO/route lives with the rest of the API there) and `shomei-server` (all
the WAI middleware, the warp launch, the metrics registry, the signal handlers). The single
*possible* exception is discussed under the Decision Log: a thin logging *effect* in core is
acceptable only if we want core workflows to emit log lines, but the default and the choice
here is **to keep all logging in the HTTP layer** and not add a core logging effect, because the
per-request structured log is produced entirely from WAI `Request`/`Response` data.

### Liveness versus readiness (plain language)

A **liveness** probe answers "is this process alive and not wedged?" If it fails, the right
response is to **restart** the process. Shōmei's existing `GET /health` is a liveness probe:
it returns 200 with a small body as long as the process can answer at all. It deliberately
does **not** check the database, because a brief database blip should not cause an orchestrator
to kill and restart an otherwise-fine server.

A **readiness** probe answers "should this instance receive traffic *right now*?" If it fails,
the right response is to **stop routing requests** to it (but not restart it) until it
recovers. Shōmei's new `GET /ready` is a readiness probe: it returns 200 only when the
PostgreSQL pool answers a trivial `SELECT 1` **and** at least one active signing key is
loadable (because a server that cannot reach its database or has no key to sign tokens with
cannot actually serve `/auth/login`). When either check fails, `/ready` returns 503, the load
balancer takes this instance out of rotation, and traffic is steered to healthy instances or
queued until this one recovers — all without a disruptive restart.

### House conventions (apply to every Shōmei module this plan touches)

These are established by MasterPlan 1's EP-1/EP-2/EP-3 and reused verbatim:

- GHC **9.12.4**, language edition **GHC2024**, `cabal-version: 3.0`.
- Each `.cabal` stanza writes `imeffect: warnings, shared`. The `warnings` stanza enables
  `-Wall` and friends; the `shared` stanza sets `default-extensions: DeriveAnyClass,
  DuplicateRecordFields, BlockArguments, MultilineStrings, OverloadedLabels,
  OverloadedRecordDot, OverloadedStrings, PackageImports, QualifiedDo, TemplateHaskell`.
- Postpositive qualified imports (`import Data.Text qualified as Text`) and
  `PackageImports` (`import "wai" Network.Wai`).
- Records use strict `!` fields, no field prefixes (we rely on `DuplicateRecordFields` +
  `OverloadedRecordDot`), `deriving stock (Generic, Eq, Show)` and
  `deriving anyclass (FromJSON, ToJSON)` where serialized.
- **Gotcha (read records imported with `(..)`):** with `DuplicateRecordFields` +
  `OverloadedRecordDot`, reading `cfg.observability` via `.field` requires the record's type to
  be imported **with its fields** — `import Shomei.Config (ShomeiConfig (..))` — not just the
  bare type. Otherwise GHC errors with `Could not deduce HasField "observability"…`.
- **Gotcha (record updates):** ordinary record-update syntax is ambiguous across the many
  records that share field names; use `generic-lens` `#field` lenses
  (`cfg & #observability .~ obs`) and add `import "generic-lens" Data.Generics.Labels ()` to any
  module that uses a `#label`.
- **Gotcha (`Event` qualified):** `Shomei.Domain.Event`'s constructors deliberately share names
  with `AuthError` and domain status constructors, so import that module **qualified** (e.g.
  `import Shomei.Domain.Event qualified as Event`) when you pattern-match `AuthEvent`.
- **Forbidden dependency:** no Shōmei package may depend on the deprecated `memory` package;
  use `ram` instead (MasterPlan 2 IP-8). Our new deps do not need `memory`, but verify
  transitively (the metrics library's `atomic-primops`/`hashable` chain is fine).
- Build everything with `cabal build all`; format with `nix fmt` (fourmolu 0.19.0.1); test with
  `cabal test`; all inside `nix develop`.


## The integration-point contracts this plan must honor

This plan coordinates with sibling plans through MasterPlan 2's Integration Points. Because the
plan must remain correct whether or not EP-2 (abuse protection) has landed, the relevant IP
text is quoted here so the implementer never has to leave this document.

### IP-3 — `ShomeiConfig` extension (shared, append-only)

MasterPlan 2 IP-3 states (quoted verbatim):

> `ShomeiConfig` lives in `shomei-core/src/Shomei/Config.hs` (MasterPlan 1's IP-5) and
> is extended by multiple plans here: **EP-1** adds notification/verification settings …;
> **EP-2** adds a rate-limit and lockout policy sub-record; **EP-3** adds an observability
> sub-record (log level/format, metrics toggle). Owner of the *type* remains `shomei-core`.
> Rule … : **each plan adds its own named sub-record field to `ShomeiConfig` (e.g.
> `notifierConfig`, `rateLimitConfig`, `observabilityConfig`) and extends `defaultShomeiConfig`
> with that field's defaults; no plan rewrites another's field.** Each new field must be `Maybe`
> or carry a default so older config files still parse.

This plan therefore adds **one** field `observability :: !ObservabilityConfig` to `ShomeiConfig`
and extends `defaultShomeiConfig` to populate it with defaults (see M4 and Interfaces). It does
not touch any other field. Because `ObservabilityConfig` is given a complete default and the
`FromJSON` derivation tolerates a missing object as long as we make the field optional-on-decode
(addressed in M4), older config files that lack an `observability` key still parse.

### IP-4 — WAI middleware stack ordering in `shomei-server`

MasterPlan 2 IP-4 states (quoted verbatim):

> The `Network.Wai.Application` assembled in `shomei-server` … gains middleware from
> two plans: **EP-2** adds rate-limit/throttling middleware; **EP-3** adds request-ID,
> structured-logging, and metrics middleware. Both wrap the same `Application`. Rule: document
> and agree the **ordering** — the outermost layer must be EP-3's request-ID + logging
> middleware (so every request, including those EP-2 rejects with HTTP 429, is logged with a
> correlation ID), then EP-2's rate limiter, then the Servant application. The plan that lands
> second must insert its middleware into the existing stack without removing the other's; record
> the final order in this section as each lands.

This plan owns the outermost layer. The composed order, written so it is correct whether EP-2
has landed or not, is specified under "Middleware ordering (the composed stack)" in the Plan of
Work, and the final landed order is recorded under "Surprises & Discoveries / Decision Log" as
each plan lands.

### IP-5 — `ShomeiAPI` route additions

MasterPlan 2 IP-5 states (quoted verbatim, EP-3-relevant part):

> The Servant `ShomeiAPI` NamedRoutes record in `shomei-servant` (MasterPlan 1's IP-6) is
> extended with new endpoints: … **EP-3** adds `GET /ready` (readiness, distinct from the
> existing liveness `GET /health`) and `GET /metrics` (Prometheus exposition — decide in EP-3
> whether this is a Servant route or raw WAI middleware; default: WAI middleware mounted before
> Servant so it need not go through the typed API). Owner of the record: `shomei-servant`. Rule:
> each plan adds its routes and corresponding handlers/DTOs; neither removes the other's …

This plan adds `GET /ready` to the `ShomeiAPI` NamedRoutes record (a typed route, because its
200/503 result is part of the API contract and benefits from Servant's type-safety and the
generated client), and mounts `GET /metrics` as **raw WAI middleware** before Servant (so the
Prometheus scrape bypasses the typed API and any auth — exactly the IP-5 default). The rationale
is in the Decision Log.

### IP-8 — `cabal.project` dependency block

MasterPlan 2 IP-8 states (quoted, EP-3-relevant part):

> **EP-3** [adds] a Prometheus client and structured-logging libraries … Rule: no Shōmei
> package may depend on the deprecated `memory` package (use `ram`) … Each plan must verify its
> new dependencies build on GHC 9.12.4 inside `nix develop` and add any required `allow-newer`
> entry in its own block.

This plan appends one clearly-delimited EP-3 block to `cabal.project` (see M1, Step 1) and
verifies the build under GHC 9.12.4.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Precondition check: `shomei-server` from MasterPlan 1 boots and serves `GET /health`.
- [ ] M1: EP-3 dependency block appended to `cabal.project` (Prometheus client + logging libs);
      `cabal build all` resolves and compiles on GHC 9.12.4.
- [ ] M1: request-ID + structured-JSON-logging WAI middleware written in
      `shomei-server/src/Shomei/Server/Observability/Logging.hs`, installed as the
      **outermost** layer of the server's WAI stack.
- [ ] M1: curl transcript captured showing one JSON log line per request carrying a
      `request_id`, the echoed/generated `X-Request-Id` response header, and **no** secret
      (password/token/`Authorization`) in the log.
- [ ] M2: Prometheus registry + HTTP metrics middleware
      (`shomei-server/src/Shomei/Server/Observability/Metrics.hs`) and the `GET
      /metrics` raw-WAI endpoint mounted before Servant.
- [ ] M2: domain counters (logins succeeded/failed, tokens issued) wired off the
      `AuthEventPublisher` stream via an observing interpreter wrapper.
- [ ] M2: curl transcript of `GET /metrics` showing HTTP + domain metrics, and the login
      counter incrementing after a `POST /auth/login`.
- [ ] M3: `GET /ready` route added to `ShomeiAPI` in `shomei-servant`, with a handler
      that checks the pool (`SELECT 1`) and an active signing key; `GET /health` unchanged.
- [ ] M3: transcript showing `/ready` → 503 with DB down, → 200 with DB up, and `/health` → 200
      throughout.
- [ ] M4: graceful shutdown wired in `shomei-server/app/Main.hs` (warp
      `setInstallShutdownHandler` / `setGracefulShutdownTimeout` + SIGTERM/SIGINT handlers that
      drain, close the pool, log, exit 0).
- [ ] M4: `ObservabilityConfig` appended to `ShomeiConfig` and threaded into the middleware
      assembly; `defaultShomeiConfig` extended; old configs still parse.
- [ ] M4: transcript of a SIGTERM during an in-flight slow request: the request completes, a
      shutdown log line appears, the pool closes, the process exits 0.
- [ ] `nix fmt` clean; `cabal build all` and `cabal test` green; Decision Log, Surprises, and
      Outcomes updated; IP-4 final composed order recorded.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. Record here, with short evidence snippets, any library-API surprises — e.g. the
exact `prometheus-client` registration API, the `wai-extra` `RequestLogger` customization
surface, or the warp shutdown-handler signature on the installed versions — and the final IP-4
middleware order once EP-2 has or has not landed.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement the request-ID + structured-JSON-logging middleware **by hand** as a thin
  `Network.Wai.Middleware`, rather than customizing `wai-extra`'s `RequestLogger`
  (`Network.Wai.Middleware.RequestLogger`) or adopting a heavyweight logging framework.
  Rationale: We need precise control over (a) the JSON field set (`request_id`, `method`,
  `path`, `status`, `duration_ms`, `client_ip`), (b) generating/echoing the `X-Request-Id`
  header and writing it back on the response, and (c) the hard guarantee that secrets never
  appear. `wai-extra`'s `RequestLogger` with a custom `OutputFormat`/`detailedLogJSON` can emit
  JSON but bakes in fields (including request headers, which is exactly where the
  `Authorization` secret lives) and is awkward to bend to an echoed correlation id. A
  hand-rolled middleware is ~60 lines, depends only on `wai` + `aeson` + `uuid` (already in the
  workspace) + a tiny line-emitter, and makes the no-secrets rule auditable by construction
  (we only ever read `method`, `rawPathInfo`, the response status, the start/stop clock, and the
  peer address — never request/response bodies or sensitive headers). We still pull `wai-extra`
  in for its `Middleware` helpers and `Network.Wai.Middleware.RequestLogger` is available if a
  future plan wants it, but the structured line is ours.
  Date: 2026-06-04

- Decision: Use the `prometheus-client` library (the `metrics`/`Prometheus` modules) together
  with `wai-middleware-prometheus` for the HTTP instrumentation middleware and the
  `/metrics` exposition handler, and `prometheus-metrics-ghc` for the GHC RTS gauges (heap,
  GC). Mount `/metrics` as raw WAI middleware before Servant.
  Rationale: `prometheus-client` is the standard, maintained Haskell Prometheus client; it
  exposes a global default registry, `Counter`/`Gauge`/`Histogram` constructors with
  `register`, `incCounter`/`observe`/`incGauge`/`decGauge`, and `exportMetricsAsText` for the
  exposition body. `wai-middleware-prometheus` provides `prometheus :: PrometheusSettings ->
  Middleware` (auto HTTP counters/latency) and `metricsApp :: Application` for the `/metrics`
  route. If the exact module/function names differ on the installed version, the implementer
  records the real API in Surprises and adapts; the design (default registry + three HTTP
  metrics + three domain counters + GHC gauges + text exposition) is stable across versions.
  Date: 2026-06-04

- Decision: Expose `GET /metrics` as **raw WAI middleware mounted before Servant**, not as a
  Servant route; expose `GET /ready` as a **typed Servant route** added to `ShomeiAPI`.
  Rationale: IP-5's default is "WAI middleware mounted before Servant so it need not go through
  the typed API" for `/metrics` — the scrape must bypass auth and the typed request/response
  machinery and just return text/plain. `/ready`, by contrast, has a meaningful contract (200
  vs 503 with a small JSON body describing which checks passed) that belongs in the typed API
  and the generated `shomei-client`, and it must run *inside* the application where the pool and
  signing-key store are in scope; so it is a typed route. Both choices are exactly the IP-5
  defaults.
  Date: 2026-06-04

- Decision: `/ready` is 200 **iff** the PostgreSQL pool answers a trivial `SELECT 1` query
  **and** `ListActiveSigningKeys` returns a non-empty list; otherwise 503. The check has a short
  timeout so a hung database does not hang the probe.
  Rationale: These are exactly the two preconditions for serving the auth API: a reachable
  datastore and a key to sign tokens with. Liveness (`/health`) stays dependency-free so a
  transient DB blip does not trigger a restart loop; readiness owns the dependency checks so the
  load balancer drains traffic instead. The signing-key check reuses the existing
  `Shomei.Effect.SigningKeyStore` effect — no new query surface.
  Date: 2026-06-04

- Decision: Keep all observability in the HTTP layer (`shomei-servant` + `shomei-server`); do
  **not** add a logging effect to `shomei-core`.
  Rationale: MasterPlan 2's constraint and MasterPlan 1's transport-agnostic-core principle. The
  per-request structured log is produced entirely from WAI `Request`/`Response` values, which
  the core never sees; threading a logging effect through every core workflow would add a
  dependency and noise for no observable benefit at this milestone. Domain *metrics* are sourced
  by observing the existing `AuthEventPublisher` stream at the adapter boundary in
  `shomei-server`, again without touching core. If a later plan needs core-internal structured
  logging it can introduce a `Shomei.Effect.Logger` effect then and justify it; this plan does
  not.
  Date: 2026-06-04

- Decision: Domain counters (`shomei_logins_succeeded_total`, `shomei_logins_failed_total`,
  `shomei_tokens_issued_total`) are incremented by wrapping the `AuthEventPublisher` interpreter
  in `shomei-server` with an observing interpreter that bumps the Prometheus counter as a side
  effect of each `PublishAuthEvent`, rather than instrumenting handlers directly.
  Rationale: The audit-event stream already names exactly the moments we care about
  (`LoginSucceeded`, `LoginFailed`, and — for tokens issued — `SessionStarted`/`UserRegistered`/
  `RefreshTokenRotated`, each of which mints a token pair). Observing the stream keeps the metric
  definitions in one place, automatically stays correct if a new code path publishes the same
  event, and avoids scattering metric calls across handlers. "Tokens issued" counts the events
  that produce a fresh token pair (signup, login, refresh).
  Date: 2026-06-04

- Decision: The request id is a `mmzk-typeid`-style prefixed id rendered as `req_<uuid-v7-ish>`
  generated with `Data.UUID.V4.nextRandom` (the `uuid` package, already in the workspace), or,
  if the client sent an `X-Request-Id` header, the incoming value **after sanitization** (trim,
  cap length, allow only `[A-Za-z0-9_.:-]`) so a malicious client cannot inject newlines into a
  log line.
  Rationale: We must never let attacker-controlled header content break the one-line-per-request
  JSON invariant or forge a log entry (log injection). Sanitizing the echoed id closes that.
  Using `uuid`'s `nextRandom` avoids a new dependency (`uuid` is already used by `shomei-core`
  via `mmzk-typeid`). The `req_` prefix matches the house TypeID style.
  Date: 2026-06-04

- Decision: Graceful shutdown is implemented with warp's `setInstallShutdownHandler` plus a
  `System.Posix.Signals` handler for `sigTERM`/`sigINT` that fills a shared `MVar`/`TVar`,
  combined with `setGracefulShutdownTimeout` to bound the drain.
  Rationale: warp natively supports graceful shutdown: when the shutdown action fires it stops
  accepting new connections and waits (up to the configured timeout) for in-flight responses to
  finish. We install POSIX signal handlers so SIGTERM (the orchestrator's stop signal) and
  SIGINT (Ctrl-C) both trigger that action, then close the `hasql` pool and log a shutdown line.
  This is the standard warp pattern and needs no extra dependency beyond `unix` (already pulled
  transitively).
  Date: 2026-06-04


- Decision: Update this ExecPlan for the 2026-06-04 package-layout and effect-namespace refactor.
  Rationale: The packages now live as top-level directories rather than under the old nested packages directory, and the core effect interfaces now live under `Shomei.Effect.*` rather than the old Port namespace. This revision also removes stale bootstrap-placeholder assumptions and points implementation steps at the current real modules.
  Date: 2026-06-04

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation. At completion, state: the final IP-4 composed
middleware order as landed; whether EP-2 had landed first and how the insertion went; the exact
installed versions of the Prometheus and logging libraries and any API deviations from the
sketches in this plan; and a short before/after of what an operator can now see and do.)


## Plan of Work

The work proceeds in four independently verifiable milestones. M1 and M2 each end with a `curl`
transcript against the running server; M3 toggles the database to prove readiness; M4 sends a
signal to prove graceful shutdown and wires the config record. Each milestone leaves the server
buildable and runnable.

Throughout, the **seam** this plan extends is the WAI `Application` assembly in
`shomei-server`. MasterPlan 1's EP-6 produces, somewhere in `shomei-server`
(most likely `src/Shomei/Server/App.hs` and the `app/Main.hs` entry point), code shaped like:

```haskell
-- Illustrative shape of the MasterPlan-1 EP-6 assembly this plan extends.
-- The real module/function names may differ slightly; locate them by searching
-- shomei-server for `Warp.run`, `serveWithContext`, or `ShomeiAPI`.
shomeiApplication :: Env -> Application
shomeiApplication env =
    serveWithContext shomeiAPI ctx (shomeiServer env)

main :: IO ()
main = do
    env  <- buildEnv          -- pool, key store, config, interpreters
    Warp.run effect (shomeiApplication env)
```

This plan wraps `shomeiApplication` with middleware and replaces `Warp.run` with a settings-based
launch that installs shutdown handlers. If the function/module names differ, adapt — the seams
are "the WAI `Application` value handed to warp" and "the call that runs warp".

### Middleware ordering (the composed stack)

Per IP-4, the **outermost** layer is this plan's request-ID + logging middleware, so every
request — including any that EP-2's rate limiter rejects with HTTP 429 — is logged with a
correlation id. The metrics middleware sits just inside logging (so it measures latency
*including* time spent in the rate limiter and the app, which is what an operator wants), then —
if EP-2 has landed — EP-2's rate limiter, then the Servant application. Expressed as function
application (outermost listed first):

```haskell
-- Composed WAI stack. `.` is ordinary function composition of Middlewares.
-- Read top-to-bottom as outermost-to-innermost.
let stack =
        requestIdAndLogging cfg.observability   -- EP-3 (this plan): OUTERMOST, always logs
      . httpMetrics                             -- EP-3 (this plan): Prometheus HTTP metrics
      . metricsEndpoint                         -- EP-3 (this plan): serves GET /metrics, bypassing Servant
      -- . rateLimiter rlCfg                    -- EP-2 (abuse protection): inserted here WHEN it lands
   in stack (shomeiApplication env)
```

Two rules make this robust whether or not EP-2 has landed:

1. **If EP-2 has not landed:** the `rateLimiter` line simply does not exist; the stack is
   `requestIdAndLogging . httpMetrics . metricsEndpoint` around the Servant app. Everything in
   this plan is verifiable on its own.
2. **If EP-2 has landed first:** its rate-limiter middleware already wraps `shomeiApplication`.
   This plan **inserts** `requestIdAndLogging . httpMetrics . metricsEndpoint` *outside* it
   (to the left), without removing EP-2's line. The result is the IP-4-mandated order:
   logging is outermost, so a 429 from EP-2 is still logged with its correlation id; metrics
   wrap the rate limiter so a throttled request is still counted; `/metrics` is served before
   either the rate limiter or Servant sees it. Record the final landed order in the Decision Log
   / Outcomes.

The `metricsEndpoint` middleware is the small wrapper that, for `GET /metrics`, returns the
Prometheus text exposition directly and otherwise passes the request through; placing it inside
`httpMetrics` but outside the rate limiter means scraping `/metrics` is never throttled and never
hits Servant, exactly per the IP-5 default. (If EP-2 wants `/metrics` exempt from throttling
without relying on ordering, that is automatic here because `metricsEndpoint` short-circuits
before the rate limiter is reached.)

### Milestone M1 — request-ID + structured JSON logging, outermost

Scope: the correlation-id and structured-logging middleware, installed as the outermost WAI
layer. At the end of M1, every request to the running server emits exactly one JSON log line to
stdout containing a `request_id` (generated, or echoed and sanitized from an incoming
`X-Request-Id`), the request `method` and `path`, the response `status`, the `duration_ms`, and
the `client_ip`; the same id is returned in an `X-Request-Id` response header; and no secret
appears in any log line. Nothing about metrics, readiness, or shutdown yet.

What will exist that did not before:

- `shomei-server/src/Shomei/Server/Observability/Logging.hs` — the middleware and the
  JSON line type.
- The EP-3 dependency block in `cabal.project`.
- The middleware installed as the outermost wrapper in the server's WAI assembly.

Commands to run (from the repo root, inside `nix develop`): `cabal build all`; then start the
server (the MasterPlan-1 EP-6 way, e.g. `cabal run shomei-server`); then in another shell
`curl -i -X POST localhost:PORT/auth/login -H 'Content-Type: application/json' -d '{"email":"a@b.com","password":"hunter2hunter2"}'` and `curl -i -H 'X-Request-Id: my-trace-1' localhost:PORT/health`.

Acceptance: the server's stdout shows two JSON log lines. The first has a generated
`"request_id":"req_…"` and `"path":"/auth/login"`, `"method":"POST"`, a numeric `status`, a
numeric `duration_ms`, and a `client_ip`; the response carries a matching `X-Request-Id` header.
The second line has `"request_id":"my-trace-1"` (the echoed, sanitized incoming id) and
`"path":"/health"`. Grepping all log output for the password string `hunter2hunter2`, for any
`Authorization` value, and for any token returns nothing — proving no secret leaked.

### Milestone M2 — Prometheus `/metrics` with HTTP and domain metrics

Scope: a Prometheus metrics registry, an HTTP-metrics middleware (request count, latency
histogram, in-flight gauge), a `GET /metrics` exposition endpoint mounted as raw WAI middleware
before Servant, and three domain counters fed by observing the `AuthEventPublisher` stream. At
the end of M2, `curl localhost:PORT/metrics` returns Prometheus text exposition including the
HTTP metrics and the domain counters, and the login counter increments after a successful
`POST /auth/login`.

What will exist that did not before:

- `shomei-server/src/Shomei/Server/Observability/Metrics.hs` — registers the HTTP
  metrics and the three domain counters in the Prometheus default registry, exposes the
  `httpMetrics` and `metricsEndpoint` middlewares, and exposes `observeAuthEvent ::
  AuthEvent -> IO ()` that bumps the right counter.
- An observing wrapper around the `AuthEventPublisher` interpreter in the server's assembly so
  every published event also updates metrics. Concretely, where MasterPlan-1 EP-6 installs the
  PostgreSQL `runAuthEventPublisherPostgres` interpreter, wrap it so each `PublishAuthEvent ev`
  first calls `liftIO (observeAuthEvent ev)` then delegates to the real interpreter. (Either
  compose interpreters, or add a `runAuthEventPublisherObserving metrics inner` interpreter in
  this module.)
- `httpMetrics . metricsEndpoint` inserted into the WAI stack at the position shown above.

Commands: `cabal build all`; start the server; `curl -s localhost:PORT/metrics | head -40`;
then log in once with a valid credential (`curl -X POST localhost:PORT/auth/login …`) and
`curl -s localhost:PORT/metrics | grep shomei_logins_succeeded_total` and observe the value
went from `0` to `1`. Scrape again after a wrong-password attempt and observe
`shomei_logins_failed_total` increment.

Acceptance: `GET /metrics` returns HTTP 200 with `Content-Type: text/plain; version=0.0.4` and a
body containing at least `http_request_duration_seconds_bucket`, an in-flight gauge, and the
three `shomei_*_total` counters; the login counter increments by exactly one per successful
login, the failed counter per failed login, and the tokens-issued counter per token-minting
event. The `/metrics` scrape itself is not throttled and does not require auth.

### Milestone M3 — `/ready` (readiness) distinct from `/health` (liveness)

Scope: add `GET /ready` to the typed `ShomeiAPI` with a handler that returns 200 only when the
PostgreSQL pool answers `SELECT 1` **and** an active signing key is loadable, else 503; leave the
existing `GET /health` untouched. At the end of M3, you can stop PostgreSQL and watch `/ready`
return 503 while `/health` stays 200, then restart PostgreSQL and watch `/ready` return 200.

What will exist that did not before:

- A new route in the `ShomeiAPI` NamedRoutes record in `shomei-servant` (the same
  module that declares `/health`), named e.g. `ready`, of type
  `"ready" :> Get '[JSON] (Headers '[...] ReadinessReport)` or, to control the 503 status
  cleanly, returning Servant's `Union`/`WithStatus` (or throwing `err503` when not ready). The
  DTO `ReadinessReport { status :: Text, database :: Bool, signingKey :: Bool }` lives beside the
  existing health DTO in `shomei-servant` and follows the `SignupRequest`/`LoginRequest` JSON
  conventions.
- The handler in `shomei-server` implementing the two checks, wired to the pool and the
  `SigningKeyStore` interpreter.

The handler logic (in the server's handler module):

```haskell
-- Readiness: 200 iff DB answers SELECT 1 AND an active signing key exists.
readinessHandler :: Env -> Handler ReadinessReport
readinessHandler env = do
    dbOk  <- liftIO (checkDatabase env.pool)          -- runs `SELECT 1` with a short timeout
    keyOk <- liftIO (checkActiveSigningKey env)        -- ListActiveSigningKeys, non-empty?
    let report = ReadinessReport
            { status = if dbOk && keyOk then "ready" else "not_ready"
            , database = dbOk
            , signingKey = keyOk
            }
    if dbOk && keyOk
        then pure report
        else throwError err503 { errBody = encode report
                               , errHeaders = [("Content-Type","application/json")] }
```

`checkDatabase` runs a one-statement `Hasql.Session` of `SELECT 1` through the existing pool
(via `Hasql.Pool.use` or the `Database` effect's `runSession`) wrapped in a short
`System.Timeout.timeout` so a hung connection cannot hang the probe; a `Left UsageError` or a
timeout yields `False`. `checkActiveSigningKey` calls `ListActiveSigningKeys` and returns
`not (null keys)`.

Commands (assuming the dev DB is the `nix develop` PostgreSQL on the Unix socket in `$PGHOST`):
start the server; `curl -i localhost:PORT/ready` → 200; `curl -i localhost:PORT/health` → 200.
Then stop PostgreSQL (e.g. `process-compose` down for the `postgres` process, or `pg_ctl stop`);
`curl -i localhost:PORT/ready` → 503 with body `{"status":"not_ready","database":false,…}`;
`curl -i localhost:PORT/health` → still 200. Restart PostgreSQL; after a moment
`curl -i localhost:PORT/ready` → 200 again.

Acceptance: `/health` returns 200 throughout (process is alive); `/ready` returns 200 when both
checks pass and 503 when the DB is unreachable or no active key exists, with a JSON body naming
which check failed.

### Milestone M4 — graceful shutdown + `ObservabilityConfig`

Scope: (a) install graceful shutdown so SIGTERM/SIGINT stop new connections, drain in-flight
requests, close the pool, log, and exit 0; (b) append the `ObservabilityConfig` sub-record to
`ShomeiConfig` (IP-3) and thread it into the middleware assembly (it controls log level/format
and whether metrics are enabled), extending `defaultShomeiConfig`. At the end of M4, a SIGTERM
during a slow in-flight request lets that request finish, then the pool closes and the process
exits cleanly; and a config file lacking the new `observability` key still parses.

What will exist that did not before:

- `ObservabilityConfig` in `shomei-core/src/Shomei/Config.hs`, and a new
  `observability :: !ObservabilityConfig` field on `ShomeiConfig`, with defaults in
  `defaultShomeiConfig`.
- The warp launch in `shomei-server/app/Main.hs` rewritten from `Warp.run effect app` to
  a `Warp.runSettings settings app` with `setInstallShutdownHandler` + a SIGTERM/SIGINT handler
  + `setGracefulShutdownTimeout`, and a `finally`/`bracket` that closes the pool and logs.
- The middleware assembly reads `cfg.observability.logFormat`/`logLevel` to choose the logger
  behavior and `cfg.observability.metricsEnabled` to decide whether to install the metrics
  middleware and `/metrics` endpoint.

The shutdown wiring (in `app/Main.hs`):

```haskell
main :: IO ()
main = do
    env <- buildEnv
    shutdownVar <- newEmptyMVar :: IO (MVar ())
    let onTerm = void (tryPutMVar shutdownVar ())
    _ <- installHandler sigTERM (Catch onTerm) Nothing   -- System.Posix.Signals
    _ <- installHandler sigINT  (Catch onTerm) Nothing
    let settings =
            Warp.setPort port
          . Warp.setGracefulShutdownTimeout (Just 30)            -- seconds to drain
          . Warp.setInstallShutdownHandler (\closeSocket ->
                void (forkIO (takeMVar shutdownVar >> closeSocket)))
          $ Warp.defaultSettings
    Warp.runSettings settings (observabilityStack env)
        `finally` do
            logShutdownStarting env
            Hasql.Pool.release env.pool
            logShutdownComplete env
```

`setInstallShutdownHandler` hands warp a `closeSocket` action; we fork a thread that waits on the
shutdown `MVar` (filled by the signal handler) and then calls `closeSocket`, which makes warp
stop accepting new connections and begin draining. `setGracefulShutdownTimeout (Just 30)` bounds
the drain at 30 seconds. When `runSettings` returns (after draining), the `finally` closes the
pool and logs. (If warp's installed version uses a slightly different shutdown API, record the
real signature in Surprises and adapt; the behavior — stop accepting, drain, close pool, exit —
is the contract.)

Commands: start the server; in one shell start a deliberately slow request (e.g. a login against
a momentarily slow DB, or add a temporary slow route for the test, or simply a request you can
observe completing); in another shell `kill -TERM <server-pid>`. Observe: the in-flight request
returns its normal response; the server logs `shutdown starting`/`shutdown complete` JSON lines;
the pool closes; the process exits with status 0 (`echo $?` is 0 if you ran it foreground, or
the process simply disappears). A second `curl` started *after* the SIGTERM is refused
(connection refused), proving new connections are no longer accepted while old ones drain.

For the config half: with the server stopped, point it at a Dhall/JSON config that omits the
`observability` key (or supply `defaultShomeiConfig`'s value programmatically) and confirm it
still boots — the missing field falls back to the default. Then set
`observability.metricsEnabled = false` and confirm `GET /metrics` is no longer served (returns
404 from Servant) while logging still works.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside the Nix
dev shell (`nix develop`, or automatically via `direnv` from `.envrc`). Replace `PORT` with the
server's actual listen effect (the MasterPlan-1 default; discover it from the config or the
server's startup log).

### Step 0 — confirm the precondition

```bash
grep -n "Server stub" shomei-server/app/Main.hs || echo "OK: stub gone, MP1 EP-6 has landed"
```

If this prints the "Server stub" line, MasterPlan 1 is not complete; **stop**.

### Step 1 — append the EP-3 dependency block to `cabal.project` (M1)

Append a clearly-delimited block at the end of `cabal.project` (it already carries the
"each plan appends its own block; none rewrites another's" convention):

```cabal
-- ============================================================
-- EP-3 / MasterPlan 2 (observability): Prometheus client + WAI logging helpers.
-- Verified to build on GHC 9.12.4 in `nix develop`. No `memory` (uses `ram`).
-- ============================================================
-- (No source-repository-package needed if these resolve from the index/snapshot.
--  If a version bound needs relaxing on GHC 9.12.4, add an `allow-newer:` line HERE,
--  inside this EP-3 block, and record it in Surprises & Discoveries.)
```

Then add the dependencies to the consuming packages' `.cabal` files (not to `cabal.project`'s
`packages:` — that list is already complete). In
`shomei-server/shomei-server.cabal`, the `library`/`executable` `build-depends` gain:

```cabal
    , prometheus-client
    , prometheus-metrics-ghc
    , wai-middleware-prometheus
    , wai
    , wai-extra
    , warp
    , http-types
    , uuid
    , unix
    , bytestring
    , aeson
    , text
    , time
```

(Several — `wai`, `warp`, `http-types`, `aeson`, `text`, `time`, `bytestring` — are likely
already present from MasterPlan-1 EP-6; keep them deduplicated.) In
`shomei-servant/shomei-servant.cabal`, ensure `aeson`, `text`, and `servant` are
present for the `ReadinessReport` DTO and the `/ready` route (they will be from EP-5). Verify the
solver and the build:

```bash
cabal build all --dry-run
cabal build all
```

Expected: the plan resolves listing `prometheus-client`, `wai-middleware-prometheus`, etc., with
no version conflict on GHC 9.12.4, and `cabal build all` compiles. If a bound is too tight, add a
narrow `allow-newer:` inside the EP-3 block and note it in Surprises.

### Step 2 — write the logging middleware (M1)

Create `shomei-server/src/Shomei/Server/Observability/Logging.hs` per the signatures in
"Interfaces and Dependencies" and add it to `shomei-server.cabal`'s `exposed-modules`
(or `other-modules`). Install it as the **outermost** wrapper in the server's WAI assembly
(see "Middleware ordering"). Rebuild: `cabal build all`.

### Step 3 — run the server and capture the M1 transcript

```bash
cabal run shomei-server &      # or the MasterPlan-1 EP-6 launch command
SERVER_PID=$!
sleep 1
curl -i -X POST localhost:PORT/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"a@b.com","password":"hunter2hunter2"}'
curl -i -H 'X-Request-Id: my-trace-1' localhost:PORT/health
```

Expected server stdout (two lines; values illustrative):

```json
{"level":"info","msg":"request","request_id":"req_01h9zk…","method":"POST","path":"/auth/login","status":401,"duration_ms":8.7,"client_ip":"127.0.0.1"}
{"level":"info","msg":"request","request_id":"my-trace-1","method":"GET","path":"/health","status":200,"duration_ms":0.4,"client_ip":"127.0.0.1"}
```

Expected: the `POST /auth/login` response includes an `X-Request-Id:` header equal to the
generated `request_id`; the `/health` response includes `X-Request-Id: my-trace-1`. Prove no
secret leaked:

```bash
# Capture all server output to a file first (e.g. cabal run shomei-server >server.log 2>&1 &),
# then:
grep -c 'hunter2hunter2' server.log    # expect 0
grep -ci 'authorization'  server.log    # expect 0 (we never log the Authorization header)
```

### Step 4 — write the metrics module and wire domain counters (M2)

Create `shomei-server/src/Shomei/Server/Observability/Metrics.hs` (registry, HTTP
metrics, `/metrics` endpoint, `observeAuthEvent`). Insert `httpMetrics . metricsEndpoint` into
the WAI stack and wrap the `AuthEventPublisher` interpreter so each published event calls
`observeAuthEvent`. Rebuild and capture the M2 transcript:

```bash
curl -s localhost:PORT/metrics | head -40
# log in with a real credential, then:
curl -s localhost:PORT/metrics | grep shomei_logins_succeeded_total
```

Expected `/metrics` excerpt:

```text
# HELP http_request_duration_seconds The HTTP request latencies in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{handler="/auth/login",method="POST",status_code="200",le="0.05"} 1
...
# HELP shomei_logins_succeeded_total Successful logins.
# TYPE shomei_logins_succeeded_total counter
shomei_logins_succeeded_total 1
# HELP shomei_logins_failed_total Failed logins.
# TYPE shomei_logins_failed_total counter
shomei_logins_failed_total 0
# HELP shomei_tokens_issued_total Token pairs issued (signup/login/refresh).
# TYPE shomei_tokens_issued_total counter
shomei_tokens_issued_total 1
```

### Step 5 — add `/ready` and capture the M3 transcript

Add the `ready` route + `ReadinessReport` DTO to `shomei-servant` and the handler to
`shomei-server`; rebuild. Then:

```bash
curl -i localhost:PORT/ready    # expect HTTP/1.1 200 with {"status":"ready",...}
curl -i localhost:PORT/health   # expect HTTP/1.1 200
# stop PostgreSQL (process-compose down postgres, or pg_ctl stop):
curl -i localhost:PORT/ready    # expect HTTP/1.1 503 with {"status":"not_ready","database":false,...}
curl -i localhost:PORT/health   # expect HTTP/1.1 200 (still alive)
# restart PostgreSQL, wait a moment:
curl -i localhost:PORT/ready    # expect HTTP/1.1 200 again
```

### Step 6 — graceful shutdown and `ObservabilityConfig` (M4)

Rewrite the warp launch in `shomei-server/app/Main.hs` (Step's code under M4). Add
`ObservabilityConfig` to `shomei-core/src/Shomei/Config.hs` and extend
`defaultShomeiConfig`. Rebuild. Then demonstrate shutdown:

```bash
cabal run shomei-server >server.log 2>&1 &
SERVER_PID=$!
sleep 1
# start a slow in-flight request in the background (e.g. a curl you can watch finish):
( curl -s localhost:PORT/auth/login -H 'Content-Type: application/json' \
    -d '{"email":"real@user.com","password":"correcthorsebatterystaple"}' \
    -o slow-response.txt ; echo "slow request finished" ) &
sleep 0.2
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"; echo "server exit status: $?"
```

Expected: `slow request finished` prints (the in-flight request completed); `server.log` ends
with shutdown JSON lines such as:

```json
{"level":"info","msg":"shutdown_starting","request_id":null,"draining":true}
{"level":"info","msg":"shutdown_complete","pool_closed":true}
```

and `server exit status: 0`. A `curl` started after the `kill` is refused.


## Validation and Acceptance

Validation is behavioral. The acceptance criteria, each with concrete input and observable
output:

1. **Structured log with correlation id (M1).** Any request produces exactly one JSON line with
   the six fields (`request_id`, `method`, `path`, `status`, `duration_ms`, `client_ip`); an
   incoming `X-Request-Id` is echoed (sanitized) both into the log line and the response header;
   absent it, a fresh `req_…` id is generated and returned. Observable via the Step 3 transcript.

2. **No secrets in logs (M1).** `grep -c 'hunter2hunter2' server.log` and
   `grep -ci 'authorization' server.log` both return `0` after exercising login. The middleware
   reads only method, path, status, timing, and peer address — never bodies or sensitive headers.

3. **Prometheus exposition (M2).** `GET /metrics` returns 200 `text/plain; version=0.0.4` with
   HTTP request/latency/in-flight metrics and the three `shomei_*_total` counters; the
   succeeded/failed login counters and the tokens-issued counter increment by exactly one per
   corresponding event. Observable via the Step 4 transcript (counter value `0` → `1`).

4. **Readiness vs liveness (M3).** `/health` returns 200 while the process lives, independent of
   the database. `/ready` returns 200 only when the pool answers `SELECT 1` and an active signing
   key exists, and 503 (with a JSON body naming the failed check) otherwise. Observable via the
   Step 5 DB-down/DB-up transcript.

5. **Graceful shutdown (M4).** On SIGTERM, an in-flight request completes, the server stops
   accepting new connections, the pool closes, shutdown JSON lines are logged, and the process
   exits 0. Observable via the Step 6 transcript.

6. **Config is append-only and back-compatible (M4).** A config lacking the `observability` key
   still parses (the field defaults); `observability.metricsEnabled = false` disables `/metrics`
   and the metrics middleware while logging continues. `defaultShomeiConfig` includes the new
   field; no existing `ShomeiConfig` field changed.

7. **Build and format (all milestones).** `cabal build all` and `cabal test` are green; `nix fmt`
   reports no changes. `shomei-core` has gained **no** new dependency except the pure
   `ObservabilityConfig` type (no `wai`/`warp`/`prometheus` in core).

Where the server's existing test suite (MasterPlan-1 EP-6) uses `hspec-wai`/`tasty` against the
WAI `Application`, add tests that: assert an `X-Request-Id` response header is present and echoes
an incoming one; assert `GET /metrics` returns the exposition content-type and contains a known
metric name; assert `GET /ready` returns 200 against a migrated ephemeral DB (via
`shomei-migrations:test-support`'s `withShomeiMigratedDatabase`) with a seeded active signing key,
and 503 against a closed pool. These let `cabal test` prove the behavior without a manual server.


## Idempotence and Recovery

All steps are safe to repeat. Creating the source files is idempotent (re-running overwrites with
the same content). `cabal build`/`cabal test` recompile only what changed; a stale-cache failure
recovers with `cabal clean && cabal build all`. The `cabal.project` edit is additive (one EP-3
block); if the solver fails on a version bound, add a narrow `allow-newer:` inside that block and
record it in Surprises — do not touch other plans' blocks. The `ShomeiConfig` change is additive
(one new field with a default), so reverting M4 only requires removing that field and its
`defaultShomeiConfig` line. No database schema changes are made by this plan (readiness only runs
`SELECT 1`), so there is no migration to roll back. Installing signal handlers and replacing
`Warp.run` with `Warp.runSettings` is reversible by restoring the original `app/Main.hs`; the
server still serves the same routes either way. If the metrics default registry double-registers a
metric on a hot reload, that throws at startup — register each metric exactly once at process
start (top-level `unsafePerformIO`/`{-# NOINLINE #-}` CAF or a single `buildEnv` step), which is
the standard `prometheus-client` idiom and is safe across repeated server restarts (each is a
fresh process).


## Interfaces and Dependencies

Libraries used and why. **`prometheus-client`** — the metrics registry, counter/gauge/histogram
types, and `exportMetricsAsText`/`exportMetricsAsText` exposition (the de-facto Haskell Prometheus
client). **`wai-middleware-prometheus`** — ready-made HTTP-metrics middleware (`prometheus`) and a
`metricsApp`/`metricsEndpoint` for `GET /metrics`. **`prometheus-metrics-ghc`** — registers GHC
RTS gauges (heap live bytes, GC time) into the default registry. **`wai`** — the `Application`,
`Middleware`, `Request`/`Response` types the middleware operates on. **`wai-extra`** — `Middleware`
helpers (and `RequestLogger` is available, though we hand-roll the JSON line per the Decision
Log). **`warp`** — `runSettings`, `setInstallShutdownHandler`, `setGracefulShutdownTimeout`,
`setPort`, `defaultSettings`. **`http-types`** — `Status`, `statusCode`, header names.
**`uuid`** (`Data.UUID.V4.nextRandom`) — request-id generation (already in the workspace).
**`unix`** (`System.Posix.Signals`) — `installHandler`, `sigTERM`, `sigINT`. **`aeson`** — the
JSON log line and the `ReadinessReport` DTO. **`servant`/`servant-server`** — the typed `/ready`
route. **`hasql`/`hasql-pool`** — the readiness `SELECT 1` against the existing pool. Forbidden:
`memory` (use `ram`); any logging/metrics dependency in `shomei-core`.

The signatures below are the contract each milestone must satisfy. Use full module paths.

### `Shomei.Config` — `ObservabilityConfig` (IP-3, `shomei-core`)

Appended to `shomei-core/src/Shomei/Config.hs`. A pure data type only — no transport
dependency enters core.

```haskell
data LogLevel = LogDebug | LogInfo | LogWarn | LogError
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data LogFormat = LogJson | LogText
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data ObservabilityConfig = ObservabilityConfig
    { logLevel       :: !LogLevel
    , logFormat      :: !LogFormat
    , metricsEnabled :: !Bool
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultObservabilityConfig :: ObservabilityConfig
defaultObservabilityConfig = ObservabilityConfig
    { logLevel = LogInfo
    , logFormat = LogJson
    , metricsEnabled = True
    }
```

`ShomeiConfig` gains exactly one field — `observability :: !ObservabilityConfig` — added to the
record and to `defaultShomeiConfig` (`observability = defaultObservabilityConfig`). The module's
export list adds `ObservabilityConfig (..)`, `LogLevel (..)`, `LogFormat (..)`, and
`defaultObservabilityConfig`. To keep older config files parsing despite the new required field,
either give `ShomeiConfig` a hand-written `FromJSON` that defaults `observability` when absent, or
(simpler) decode the surrounding config so a missing `observability` object falls back to
`defaultObservabilityConfig`; record the chosen approach in the Decision Log when implemented.

### `Shomei.Server.Observability.Logging` (M1, `shomei-server`)

```haskell
module Shomei.Server.Observability.Logging
    ( requestIdAndLogging   -- the outermost middleware
    , RequestId (..)
    , generateRequestId
    , sanitizeRequestId
    , requestIdHeaderName    -- "X-Request-Id"
    ) where

import "wai" Network.Wai (Middleware, Request, Response, requestMethod, rawPathInfo, remoteHost, responseStatus, requestHeaders, mapResponseHeaders)
-- aeson, uuid, http-types, time, bytestring, text imports …

newtype RequestId = RequestId Text
    deriving stock (Generic) deriving newtype (Eq, Show)

-- | Generate a fresh `req_<uuid>` request id.
generateRequestId :: IO RequestId

-- | Trim, length-cap, and strip disallowed characters from a client-supplied id
--   so it cannot inject newlines or forge a log entry. Allowed: [A-Za-z0-9_.:-].
sanitizeRequestId :: Text -> RequestId

requestIdHeaderName :: HeaderName   -- "X-Request-Id"

-- | OUTERMOST middleware (IP-4). For each request: derive a RequestId (echo a
--   sanitized incoming X-Request-Id, else generate one); record a start time; run
--   the inner app; on the response, add the X-Request-Id header and emit ONE JSON
--   log line with request_id/method/path/status/duration_ms/client_ip. NEVER reads
--   request/response bodies or the Authorization/Cookie headers, so no secret leaks.
--   `ObservabilityConfig` selects level/format (json|text) and gates verbosity.
requestIdAndLogging :: ObservabilityConfig -> Middleware
```

The JSON line is built with aeson from a small record; `duration_ms` is
`realToFrac (diffUTCTime stop start) * 1000`; `client_ip` is rendered from `remoteHost req`. The
log line is written atomically (one `Data.ByteString.Char8.hPutStrLn stdout`/`hPut` so concurrent
requests never interleave a half-line).

### `Shomei.Server.Observability.Metrics` (M2, `shomei-server`)

```haskell
module Shomei.Server.Observability.Metrics
    ( httpMetrics        -- Middleware: request count, latency histogram, in-flight gauge
    , metricsEndpoint    -- Middleware: serves GET /metrics (text exposition), else passes through
    , observeAuthEvent   -- AuthEvent -> IO (): bump the right domain counter
    , registerMetrics    -- IO (): register all metrics in the default registry exactly once
    ) where

import "wai" Network.Wai (Middleware)
import qualified Prometheus
import qualified Network.Wai.Middleware.Prometheus as P
import Shomei.Domain.Event qualified as Event   -- AuthEvent imported QUALIFIED (house gotcha)

-- Domain counters (registered once in the Prometheus default registry):
--   shomei_logins_succeeded_total  <- Event.LoginSucceeded
--   shomei_logins_failed_total     <- Event.LoginFailed
--   shomei_tokens_issued_total     <- Event.SessionStarted / UserRegistered / RefreshTokenRotated
observeAuthEvent :: Prometheus.Counter -> Prometheus.Counter -> Prometheus.Counter -> Event.AuthEvent -> IO ()
```

`httpMetrics` is `wai-middleware-prometheus`'s `prometheus def` (or the version's equivalent),
which records `http_requests_total`, the `http_request_duration_seconds` histogram, and an
in-flight gauge. `metricsEndpoint` matches `GET /metrics` and returns
`Prometheus.exportMetricsAsText` as `text/plain; version=0.0.4`, otherwise delegates to the inner
app. `registerMetrics` registers the three domain counters and (via `prometheus-metrics-ghc`) the
GHC RTS gauges into the default registry exactly once at process start.

The server's assembly wraps its `AuthEventPublisher` interpreter so each `PublishAuthEvent ev`
also calls `observeAuthEvent succC failC tokC ev`. Concretely (effectful interpreter sketch):

```haskell
runAuthEventPublisherObserving
    :: (IOE :> es)
    => (Prometheus.Counter, Prometheus.Counter, Prometheus.Counter)
    -> Eff (AuthEventPublisher : es) a -> Eff (AuthEventPublisher : es) a
-- For each PublishAuthEvent ev: liftIO (observeAuthEvent ... ev) >> (delegate to inner)
```

or, more simply, compose at the value level by having the server's `publishAuthEvent` call site
run both the metric bump and the PostgreSQL publish.

### `ShomeiAPI` `/ready` route + `ReadinessReport` DTO (M3, `shomei-servant` + `shomei-server`)

In `shomei-servant` (the module that declares `ShomeiAPI` and `/health`):

```haskell
data ReadinessReport = ReadinessReport
    { status     :: !Text    -- "ready" | "not_ready"
    , database   :: !Bool
    , signingKey :: !Bool
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- Added to the ShomeiAPI NamedRoutes record, beside `health`:
--   ready :: mode :- "ready" :> Get '[JSON] ReadinessReport
-- The handler returns 200 with the report when ready, and throws `err503` with the
-- report as JSON body when not (so the 503 status is part of the HTTP contract).
```

In `shomei-server` the `readinessHandler` (sketched under M3) wires the two checks:
`checkDatabase :: Hasql.Pool.Pool -> IO Bool` (a short-`timeout`-wrapped `SELECT 1`) and
`checkActiveSigningKey :: Env -> IO Bool` (`ListActiveSigningKeys`, non-empty). `GET /health` is
untouched.

### warp shutdown wiring (M4, `shomei-server/app/Main.hs`)

Uses `Network.Wai.Handler.Warp` (`runSettings`, `defaultSettings`, `setPort`,
`setInstallShutdownHandler`, `setGracefulShutdownTimeout`) and `System.Posix.Signals`
(`installHandler`, `Catch`, `sigTERM`, `sigINT`); on shutdown it releases the `Hasql.Pool.Pool`
(`Hasql.Pool.release`) and logs. The full sketch is under Plan of Work / M4.


## Revision history

- 2026-06-04: Initial authoring. Fleshed out from the ExecPlan skeleton into a full,
  self-contained plan for MasterPlan 2 EP-3 (observability). Established the four milestones
  (structured logging + request id; Prometheus metrics; readiness vs liveness; graceful shutdown
  + `ObservabilityConfig`), quoted the IP-3/IP-4/IP-5/IP-8 contracts, fixed the
  outermost-logging middleware order (correct whether EP-2 has landed or not), chose a
  hand-rolled logging middleware (no-secrets by construction), `prometheus-client` +
  `wai-middleware-prometheus` for metrics with `/metrics` as raw WAI middleware and `/ready` as a
  typed Servant route, and pre-populated the Progress checklist and the initial Decision Log
  entries (logging-lib choice; metrics route-vs-middleware; readiness criteria). Reason:
  deliver an excellent, novice-runnable plan ready to execute the moment MasterPlan 1 lands.
- 2026-06-04: Updated after the package-layout refactor and MasterPlan audit. Package paths
  now refer to top-level directories, effect terminology no longer uses the old `Port`
  namespace, and the precondition points at the real server/Servant modules created by
  MasterPlan 1.
