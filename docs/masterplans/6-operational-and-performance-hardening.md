---
id: 6
slug: operational-and-performance-hardening
title: "Operational and Performance Hardening"
kind: master-plan
created_at: 2026-07-07T17:22:07Z
intention: intention_01kx2hqr6beeashgwvg5zwxtgc
---

# Operational and Performance Hardening

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A July 2026 performance review (findings restated in full inside each child plan) confirmed
that Shōmei's authenticated hot path is already excellent — pure in-memory ES256 verification,
~0.1–0.2 ms CPU, zero database hits, all 63 SQL statements prepared, token lookups on unique
indexes — but found that the parts *around* that hot path are not production-shaped: login
costs ~11 sequential connection-pool checkouts with no transactions, the pool size is
hardcoded to 10, Argon2id runs as an `unsafe` FFI call that can stall garbage collection
process-wide for the ~50–150 ms of each hash while transiently allocating 64 MiB per
concurrent login, none of the six growing tables is ever cleaned up (refresh tokens grow one
row per refresh, forever), the in-process rate limiter never evicts per-IP buckets, the
in-flight metrics gauge drifts on exceptions, deployment sets no GHC RTS flags so a container
with a 2-CPU quota on a 32-core host runs 32 capabilities, and the downstream JWKS-cache
example — the template every downstream service will copy — serializes all requests through
one `MVar` and has no stale-on-error behavior.

After this initiative: login and refresh each execute in one or two database round-trips
inside real transactions; pool size and acquisition timeout are configuration; at most a small
configured number of Argon2 hashes run concurrently and the deploy artifacts ship
container-aware RTS defaults; every expirable table is swept on a schedule with the indexes
that sweep needs, and `shomei_auth_events` / `shomei_login_attempts` have documented retention;
the rate limiter evicts idle buckets and the metrics gauge survives exceptions; and the
downstream example demonstrates lock-free JWKS reads with single-flight refresh, refresh-ahead,
and stale-on-error.

Out of scope: anything that changes a security property (the refresh compare-and-swap guard
lives in `docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md`),
new API surface, micro-optimizations the review rated Low with no operational consequence
(Text/ByteString hops, effectful dispatch overhead), and horizontal-scaling work such as a
distributed rate limiter (single-instance posture is documented and retained).


## Decomposition Strategy

Work streams follow the review's impact clusters, each independently benchmarkable or
observable: database round-trips (EP-1), storage growth (EP-2), CPU/GC scheduling (EP-3),
middleware behavior under load (EP-4), and the downstream consumption template (EP-5). Each
plan's outcome is verifiable in isolation — round-trip counts via statement logging, sweeper
behavior via seeded expired rows, GC stalls via a concurrent-login load test, bucket eviction
via the limiter's own state, cache behavior via the example's tests — and no plan needs
another's code to compile.

EP-1 deliberately excludes the `status='active'` compare-and-swap semantics (owned by the
Security MasterPlan's EP-1, an integration point below) and owns everything else about
round-trips: transaction composition via the currently-unused
`Database.runTransaction` (`shomei-postgres/src/Shomei/Postgres/Database.hs`), the
conditional-write cleanup (`clearAccountLockout` issued unconditionally on every login), and
pool configurability, which is grouped here because pool sizing only becomes tunable-with-
confidence once the per-login checkout count drops.

EP-2 pairs the sweeper with its supporting `expires_at` indexes and retention windows because
shipping either alone is a trap: a sweeper without indexes sequential-scans the very tables it
is meant to keep small.

EP-5 is a separate plan even though it only touches `examples/` because the review found the
example is the de-facto client library for downstream services — its `MVar` pattern will be
copied into production services verbatim.

An alternative decomposition folding EP-4's grab-bag (rate limiter, metrics, logging, Warp
settings) into EP-3 was rejected: EP-3 is a focused scheduling/RTS change with a load-test
acceptance gate, while EP-4 is several small independent fixes; merging them would couple
unrelated verification strategies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Transactional Auth Workflows and Configurable Connection Pool | docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md | None | None | Complete |
| 2 | Expired-Data Sweeper, Retention Windows, and Supporting Indexes | docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md | None | None | Complete |
| 3 | Bound Argon2 Hashing Concurrency and Container-Aware Runtime Tuning | docs/plans/35-bound-argon2-hashing-concurrency-and-container-aware-runtime-tuning.md | None | None | Complete |
| 4 | Middleware Hardening: Rate-Limiter Eviction, Metrics Accuracy, and Warp Settings | docs/plans/36-middleware-hardening-rate-limiter-eviction-metrics-accuracy-and-warp-settings.md | None | None | Complete |
| 5 | Resilient Downstream JWKS Cache Template | docs/plans/37-resilient-downstream-jwks-cache-template.md | None | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

All five plans are mutually independent and can proceed in parallel; there are no hard
dependencies inside this MasterPlan.

Two cross-MasterPlan orderings matter. First, EP-1 layers transactions over the refresh
workflow whose mark-used statement is being converted to a compare-and-swap by the Security
MasterPlan's EP-1 (`docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`);
whichever lands second must preserve the other's statement shape in
`shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs` (see Integration Points). Second,
EP-3's RTS guidance (`--nonmoving-gc`) partially mitigates the same GC-stall problem its
semaphore fix addresses; they ship together in one plan precisely so the load test evaluates
the combination.

EP-2's sweeper and the Security MasterPlan's EP-2 (JWKS hot reload) both add periodic
background work to `shomei-server` boot; they should converge on one supervision idiom for
forked maintenance threads rather than inventing two.


## Integration Points

Refresh workflow statements
(`shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`, `shomei-core/src/Shomei/Workflow.hs`):
involved plans are this MasterPlan's EP-1 and the Security MasterPlan's EP-1, which owns the
compare-and-swap (`UPDATE … SET status='used' WHERE … AND status='active' RETURNING`) semantics.
This plan's EP-1 owns transaction composition (which statements share one `runTransaction`).
The CAS statement must remain a single conditional UPDATE inside whatever transaction EP-1
builds; EP-1 must treat "0 rows updated" as the reuse signal rather than re-reading.

Server boot and background threads (`shomei-server/src/Shomei/Server/Boot.hs`): involved plans
EP-2 (sweeper thread), EP-3 (hashing semaphore created at boot and threaded into the
interpreter environment), EP-4 (Warp settings, `setOnException`), and the Security
MasterPlan's EP-2 (key-reload thread). EP-2 defines the supervised-background-thread idiom
(fork, log-on-crash, restart-or-die policy); later plans reuse it. Config additions from all
plans land additively in `Shomei.Server.Config`/`ServerSettings`
(`shomei-server/src/Shomei/Server/Config.hs`), each plan adding its own fields with defaults.

Migrations directory (`shomei-migrations/sql-migrations/`): EP-2 added `expires_at`/retention
indexes and dropped the dead single-column `status` indexes (migration
`2026-07-09-13-51-07-sweeper-indexes-and-retention.sql`). No other plan in this MasterPlan
adds migrations, but the Interop MasterPlan adds new tables concurrently; codd migrations are
timestamped files, so parallel additions do not conflict as long as each plan runs
`just create-database` (or `shomei-admin migrate`) against a fresh database in its validation
steps. **Scaffolding the `.sql` file is not sufficient**: a new migration is embedded by a
compile-time Template Haskell splice, and the `just migrate` recipe's `touch` of the `.cabal`
does not force a recompile. Append a comment line above `embeddedFiles` in
`shomei-migrations/src/Shomei/Migrations.hs` — otherwise `just migrate` reports `[0 found]` and
applies nothing while exiting 0.

Metrics module (`shomei-server/src/Shomei/Server/Observability/Metrics.hs`): EP-4 fixes the
in-flight gauge; EP-3's load test reads these metrics for acceptance. EP-4's fix is
independent, but if EP-3 runs its load test first it should expect the gauge drift EP-4 fixes.


## Progress

- [x] EP-1: Pool size and acquisition timeout configurable (`SHOMEI_DB_POOL_SIZE`, Dhall field)
- [x] EP-1: Login workflow tail batched into transactions; round-trips measured before/after (11 → 7)
- [x] EP-1: Refresh workflow batched (mark-used + child insert + events in one transaction) (5 → 3)
- [x] EP-1: `clearAccountLockout` made conditional (no unconditional DELETE per login)
- [x] EP-2: Supervised background-sweeper thread with per-table delete batches
- [x] EP-2: `expires_at` indexes added; dead `status` indexes dropped; audit composite index decision recorded
- [x] EP-2: Retention windows for `shomei_auth_events` and `shomei_login_attempts` (config + docs)
- [x] EP-2: `shomei-admin sweep` CLI trigger for operators who schedule maintenance externally
- [x] EP-3: Semaphore bounding concurrent Argon2 hashing; parameters configurable
- [x] EP-3: Argon2 hashes made self-describing (PHC format); legacy hashes still verify
- [x] EP-3: Login timing oracle closed — a `VerifyPasswordDummy` port operation replaces the
      hardcoded dummy hash, which configurable parameters would otherwise have desynchronized
- [x] EP-3: Container-aware RTS flags in Dockerfile/entrypoint; deployment docs updated
- [x] EP-3: Concurrent-login load test (`scripts/argon2-load-test.sh`) demonstrating bounded
      latency impact on the hot path (p50 degradation 1.83× → 1.09×, peak RSS 618 → 239 MB)
- [x] EP-4: Rate-limiter bucket eviction (idle sweep) and contention note
- [x] EP-4: In-flight gauge exception-safe; Warp `setOnException` routed to structured logger
- [x] EP-4: Log lines written as one strict `BS.hPut` (no interleaving); `setServerName`;
      1 MiB request-body cap answering 413
- [x] EP-5: Example JWKS cache rewritten: lock-free reads, single-flight refresh, refresh-ahead, stale-on-error
- [x] EP-5: Fail-closed 503 past a configurable max-staleness bound; `Cache-Control: max-age` honored
- [x] EP-5: Seven cache tests against a fetch-counting stub server; each property proved by mutation
- [x] EP-5: Live outage demonstration — auth service killed, downstream serves 200 past four TTL
      windows, then 503 past the staleness bound
- [x] EP-5: `docs/user/client-and-examples.md` updated to describe the pattern as the recommended template


## Surprises & Discoveries

- **The Security MasterPlan's EP-1 (`docs/plans/28-…`) had already landed when EP-1 began.**
  `markRefreshTokenUsed` already returns `Bool` and `markUsedStmt` is already the conditional
  `UPDATE … AND status='active' RETURNING`. The Integration Points contract below therefore
  resolved in its "28 landed first" direction: EP-1 lifted that statement into its rotation
  transaction verbatim, changing neither its WHERE clause nor its decoder, and reads "no row
  returned" as the reuse signal. Later plans touching
  `shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs` should know the statement now has
  two consumers: `runRefreshTokenStorePostgres` and `Shomei.Postgres.AuthUnitOfWork`.

- **EP-1 established a statement-sharing convention the later plans should follow.** Store
  interpreters now export their prepared `Statement` values (and row-type synonyms) so a
  transaction can lift them with `Hasql.Transaction.statement` instead of restating the SQL. If
  EP-2's sweeper or any later plan needs to compose existing statements, extend that pattern
  rather than copying SQL.

- **`Shomei.Servant.Seam.AppEffects` and `Shomei.Server.App.AppEffects` must stay in sync.** EP-1
  added `AuthUnitOfWork` to both at the same relative position (after `RefreshTokenStore`), plus
  the `shomei-postgres`, `shomei-servant`, `TimingSpec` and `shomei-admin` harness stacks. Any
  plan adding an effect must touch all six sites; the compiler finds them, but expect the sweep.

- **`cabal test all` is flaky in parallel on this machine, independent of any plan.** Several
  suites each start an ephemeral PostgreSQL cluster; concurrently they exceed the 60-second
  startup budget and fail with `Failed to start ephemeral PostgreSQL: TimeoutError`. Validate
  with `cabal test all -j1 --test-options="-j1"`. EP-2 through EP-5 should expect this.

- **`nix fmt` with no arguments reformats the entire repository**, producing import-order churn in
  files a plan never touched. Pass explicit paths (`nix fmt -- <files>`) to keep a plan's diff
  focused.

- **A concurrent session's `git commit` swept EP-1's uncommitted working tree into an unrelated,
  already-pushed docs commit (`cd7deec`), which carries MasterPlan 5's trailers.** Nothing was
  lost and the history was deliberately left un-rewritten. The practical lesson for EP-2 through
  EP-5: commit each milestone as soon as it is green rather than accumulating a large
  uncommitted tree, and check `git log` before assuming your work is still uncommitted.

- **Adding a migration requires editing `shomei-migrations/src/Shomei/Migrations.hs`, not just
  dropping a `.sql` file in.** The `migrate` recipe's `touch` of the `.cabal` does not force the
  compile-time `embedDir` splice to re-run — cabal hashes content, not mtime — so a new migration
  is silently invisible and `just migrate` reports `[0 found]` and exits 0. The repository's real
  convention is the comment block above `embeddedFiles`, which carries one line per migration
  wave precisely so the module's content changes. **Any plan in any MasterPlan that adds a
  migration must append a line there.** This is the single most likely way to ship a migration
  that never runs.

- **`Shomei.Server.Supervisor.supervisedLoop` now exists and has two consumers.** EP-2 owns it, as
  the Integration Points below promised. `installSweeper` and `installKeyReload` (migrated off its
  bespoke `forever`/`catch` loop) both use it. The Security MasterPlan's EP-2
  (`docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`) should import it
  rather than invent a second pattern, and EP-4 of this MasterPlan should use it if it adds a
  periodic rate-limiter eviction task. Two behaviors to know: the first cycle runs **immediately**
  (no initial sleep), and asynchronous exceptions are re-thrown so the thread stays killable —
  a loop that catches `SomeException` indiscriminately would hang process shutdown.
  `supervisedLoopMicros` is exported so the crash/backoff path is unit-testable in milliseconds.

- **`ServerSettings` grew `serverSweep :: SweepSettings`, and its `FileConfig` gained eight
  optional Dhall fields.** EP-3 and EP-5 adding their own fields remains additive as planned.
  One trap: `FileConfig` and `SweepSettings` deliberately share field names, so *record update*
  syntax on either is a `-Wambiguous-fields` warning; construct the record in full (naming the
  constructor) instead. `config/shomei-types.dhall` is a closed record type and still does not
  list the new keys — pre-existing, documented, and unchanged by EP-2.

- **`cabal run shomei-server` is ambiguous** (the package holds both `shomei-server` and
  `shomei-admin`). Use `cabal run shomei-server:exe:shomei-server`. EP-3's load test will hit
  this.

- **EP-2's plan contained three real defects that were only found by running things**, the worst
  being a batched `DELETE ... WHERE ctid IN (SELECT ... LIMIT n)` over `shomei_refresh_tokens`
  that violates the `parent_token_id` self-referencing `NO ACTION` foreign key whenever a batch
  boundary splits a rotation family — a bug that surfaces only under load. Later plans in this
  MasterPlan should treat their own specified SQL as a hypothesis and check the schema's foreign
  keys before trusting it. Details and reproductions are in plan 34's Surprises & Discoveries.

- **Never set `GHCRTS` for `shomei-server`.** EP-3's plan specified exporting it from the
  container entrypoint; doing so breaks the server at boot whenever `$SHOMEI_CONFIG` is set,
  because `Shomei.Server.Config.loadDhallFile` shells out to `dhall-to-json`, which inherits
  `GHCRTS` and is built without `-threaded`/`-rtsopts` (`the flag -N4 requires the program to be
  built with -threaded`). RTS options must be passed as `+RTS … -RTS` on the server's own command
  line — `deploy/entrypoint.sh` now does, and `deploy/entrypoint-test.sh` pins it. This applies to
  any future plan touching deployment.

- **EP-3 changed `shomei-core`'s `PasswordHasher` port**, which EP-1 of MasterPlan 6 did not
  anticipate. `VerifyPasswordDummy :: PlainPassword -> PasswordHasher m ()` was added and
  `Shomei.Domain.Password.dummyPasswordHash` was **deleted**. Any plan writing a `PasswordHasher`
  interpreter (including in-memory fakes) must handle the new constructor; the compiler finds
  them. The reason is a security property: making Argon2 parameters configurable desynchronizes
  any *constant* dummy hash from the configured cost, reopening the account-enumeration timing
  oracle (a miss would cost 102 ms against a hit's 19 ms at the OWASP floor). Detail in plan 35's
  Surprises & Discoveries.

- **`Env` (`shomei-server/src/Shomei/Server/App.hs`) now has six construction sites**, not the
  five EP-3's plan listed: `Boot.buildEnv`, `shomei-server/test/Shomei/Server/E2ESpec.hs`,
  `shomei-client/test/Main.hs`, `examples/embedded-servant-app/test/Main.hs`,
  `examples/microservice-auth-stack/test/Main.hs`, plus `AdminEnv` in
  `shomei-server/test/Admin/Main.hs`. EP-3 added `envArgon2Params` and `envHashingLimiter` to all
  of them. Note `cabal build all` does **not** build test suites here, so a cross-cutting change
  compiles green while the test modules are broken; use `cabal build all --enable-tests`.

- **Test suites now hash passwords with cheap Argon2 parameters** (`m=8192,t=1,p=1`) via a local
  `testArgon2Params`. EP-4 and EP-5 should not "fix" this back to the defaults: at ~100 ms per
  hash the production parameters dominated six suites' runtime for no coverage benefit.

- **EP-4's plan prescribed the wrong fix for the in-flight gauge, and the prescription was the
  only wrong thing in it.** `onException` plus a decrement inside the response continuation
  double-decrements whenever the application throws *after* its continuation returned (an async
  exception during graceful shutdown), drifting the gauge negative — a worse failure than the
  positive drift it replaced, because a negative gauge is legal Prometheus and looks fine.
  `finally`, with no decrement in the continuation, is exactly-once. This is the second time in
  this MasterPlan that a plan's specified code was itself the defect (EP-2's batched `DELETE`
  violating a foreign key was the first). **Later plans should treat prescribed code as a
  hypothesis and prove each fix by reverting it and watching its test go red** — EP-4 did this
  for all four milestones, and it is what caught the double-decrement.

- **The live `/metrics` in-flight gauge reads `1`, not `0`, and always will.** `metricsMiddleware`
  wraps `metricsEndpointMiddleware`, so a scrape counts itself. EP-3's load test reads these
  metrics: expect `1`, and read *stability* rather than zero as the health signal.

- **`Shomei.Server.Boot.main`'s WAI stack gained a fourth middleware.** Outermost first:
  `requestLoggingMiddleware` → `metricsMiddleware` → `metricsEndpointMiddleware` →
  `bodyLimitMiddleware 1MiB` → `rateLimitMiddleware` → the Servant application. The 1 MiB cap
  rejects `Content-Length`-declared bodies only; chunked bodies pass through by design.
  `Shomei.Server.Observability.Logging` now also exports `renderLogLine`, `emitLine`,
  `logServerError` and `serverErrorLine` — EP-5 and any plan wanting a structured line on stdout
  should use `emitLine`/`renderLogLine` rather than a fresh `BL.hPut` (note
  `Shomei.Server.Supervisor.logJsonLine` remains the **stderr** equivalent for background tasks).

- **Restarting this repo's dev PostgreSQL after `pg_ctl stop` needs explicit flags.** A second,
  unrelated PostgreSQL holds TCP 5432 on this machine, and the dev cluster's default
  `listen_addresses` collides with it, so a plain `pg_ctl start -D "$PGDATA"` fails with
  `could not create any TCP/IP sockets`. The dev cluster is reached over its unix socket; restart
  it with `pg_ctl start -D "$PGDATA" -o "-c listen_addresses='' -k $PGHOST"`.

- **`http-client`'s `parseRequest` installs no `checkResponse`, so non-2xx responses do not
  throw.** `parseRequest` builds on `defaultRequest`, whose `checkResponse` is `\_ _ -> return
  ()`; only `parseUrlThrow` / `setRequestCheckStatus` install `throwErrorStatusCodes`. EP-5's
  `fetchJwks` (and the code it replaced) would therefore have reported an auth-service `500` as
  a *JWKS parse failure*. Any plan in any MasterPlan fetching over `HTTP.parseRequest` — note
  `Env.envHttpManager` is threaded through the server — must check `statusIsSuccessful` itself.

- **`displayException` on an `HttpException` is not one line.** `HttpExceptionRequest` carries
  the whole `Request` and its `Show` pretty-prints the record over ~20 lines, so a single log
  call becomes a 20-line stderr dump. EP-5 added a local `describeHttpError` that drops the
  request and collapses the cause's whitespace. Relevant to `Shomei.Server.Supervisor.logJsonLine`
  and anything else that logs a caught exception: log `show`n exceptions only after normalizing
  whitespace, or the structured-logging invariant EP-4 established silently breaks.

- **"Prescribed code is a hypothesis" now has three instances, and the third was invisible to
  tests.** EP-2's batched `DELETE` violated a foreign key; EP-4's `onException` gauge fix
  double-decremented; EP-5's "emit one warning line to stderr" emitted twenty, and *no test could
  have caught it* — the tests assert on fetch counts and status codes, never on log output. Only
  the live demonstration found it. The lesson generalizes past "prove each fix by reverting it":
  a plan's acceptance criteria bound what its tests can see, so any plan whose deliverable
  includes operator-facing output should look at that output once, by hand.

- **An unrelated `ssh` tunnel holds TCP 8080 on this machine.** EP-5's first demonstration run
  health-checked `localhost:8080` and got an answer *after* killing the auth service. Any plan
  running the server by hand should pick a port and confirm with
  `lsof -nP -iTCP:<port> -sTCP:LISTEN` rather than trusting the 8080 default.


## Follow-up work (recorded for a later plan)

These are open questions this MasterPlan surfaced but did not resolve. They are recorded here,
outside any child plan, so a follow-up initiative can pick them up.

**Tail latency is unmeasured, and the review's central performance claim is therefore
unsubstantiated.** The whole premise of EP-3 — that an Argon2 hash pinned in an unsafe foreign
call stalls unrelated requests through stop-the-world GC — predicts a p95/p99 effect.
`scripts/argon2-load-test.sh` cannot resolve one: the load generator shares the host with the
server and forks a `curl` per request, and three runs of an identical configuration produced p99
degradation factors of 20.9×, 34.2× and 62.5×. What *is* stable is median degradation (1.83× →
1.09× with the limiter) and peak RSS (618 → 239 MB). A follow-up needs a separate
load-generation machine and a connection-reusing client before any tail claim can be made.

**The RTS guidance is unvalidated.** Two of the three flags were not shown to help. On an
unconstrained host `--nonmoving-gc` was neutral and `-A64m` cost 726 MB of resident memory
(230 → 956 MB) for no reproducible latency gain, which is why the entrypoint now applies `-A64m`
only under a CPU quota. Their justification is the container case, and no Docker daemon was
available. Also unverified: that GHC 9.12.4's `-N` really does ignore CFS bandwidth quotas. If it
does not, `deploy/entrypoint.sh`'s quota arithmetic is redundant (though not wrong).

**`hashingMaxConcurrency = 2` is a fixed default in a world of varying core counts.** On a 10-core
host it caps login throughput at 18.8/s against an unbounded 33.4/s; on a 1-CPU container it may
still admit one hash too many. Deriving it from the capability count (or from `-N`) is worth
investigating, together with whether the memory bound or the GC bound is the binding constraint.

**`config/shomei-types.dhall` lags the loader.** It is a closed record type and now omits the
`sweep*`, `*RetentionDays`, `argon2*` and `hashingMaxConcurrency` keys, on top of the six keys
MasterPlan 5 already recorded. The loader accepts them all, but a file annotated
`: ./shomei-types.dhall` cannot use them. Widening the schema is mechanical and overdue.


## Decision Log

- Decision: Keep the refresh compare-and-swap out of EP-1 (owned by the Security MasterPlan)
  and make EP-1 responsible only for transaction composition and pool configuration.
  Rationale: The CAS is a security fix with independent urgency; two plans must not both own
  the same statement. Integration point documented in both MasterPlans.
  Date: 2026-07-07

- Decision: Ship the Argon2 semaphore and the RTS/container guidance as one plan (EP-3) rather
  than splitting code change from deployment change.
  Rationale: The acceptance criterion — bounded hot-path latency under concurrent logins — can
  only be evaluated with both in place; `--nonmoving-gc` alone changes the observed stall
  profile.
  Date: 2026-07-07

- Decision: Treat the downstream JWKS example as a first-class deliverable (EP-5) rather than
  a documentation footnote.
  Rationale: The review identified `examples/microservice-auth-stack` as the template
  downstream teams will copy; a serialized `MVar` read path and absent stale-on-error there
  becomes every consumer's incident.
  Date: 2026-07-07

- Decision: Do not build a distributed rate limiter or externalize lockout state in this
  initiative.
  Rationale: Single-instance posture is documented in `docs/user/security.md`; multi-instance
  coordination is a scaling initiative with different requirements, not a hardening fix.
  Date: 2026-07-07

- Decision: EP-3 was allowed to change `shomei-core`'s `PasswordHasher` port and delete
  `Shomei.Domain.Password.dummyPasswordHash`, despite this MasterPlan declaring "anything that
  changes a security property" out of scope.
  Rationale: The out-of-scope rule exists to stop this initiative from *altering* security
  properties. EP-3's configurable Argon2 parameters would have *broken* one — the login timing
  oracle — because verification cost follows the parameters embedded in the hash being verified,
  and the miss path verified a hardcoded 64 MiB constant. Preserving the existing guarantee is
  squarely in scope; shipping the knob without the fix would not have been. Measured: a miss would
  cost 102 ms against a hit's 19 ms at the OWASP floor. Confirmed with the repository owner before
  implementation.
  Date: 2026-07-09

- Decision: EP-3's load-test acceptance was rewritten to p50 degradation and peak RSS, with
  p95/p99 reported but not gating, and the tail-latency question recorded as follow-up work above.
  Rationale: The harness cannot resolve the tail (three runs of one configuration: p99 factors of
  20.9×, 34.2×, 62.5×), and gating on it would either block the plan on noise or bless a lucky run.
  The original throughput criterion assumed "the CPU work is identical", which is false when core
  count exceeds the concurrency bound. Confirmed with the repository owner, who asked that the open
  question live outside the child plan so a follow-up can pick it up.
  Date: 2026-07-09

- Decision: EP-4 replaced its own plan's `onException` gauge fix with `finally`, and moved the
  decrement out of the response continuation entirely.
  Rationale: The planned shape double-decrements when the application throws after its
  continuation returned, drifting the gauge negative. Recorded here rather than only in the child
  plan because the Integration Points note that EP-3's load test reads this gauge.
  Date: 2026-07-09

- Decision: EP-4 kept the piggybacked (amortized, in-`takeToken`) bucket eviction rather than
  adopting EP-2's `supervisedLoop`, as its Decision Log anticipated.
  Rationale: EP-2's idiom had indeed landed first, but eviction needs no thread and no clock read
  beyond the one `takeToken` already performs; a periodic thread would be strictly more moving
  parts for the same bound. `supervisedLoop` remains the right answer for work that must happen
  whether or not requests arrive — which eviction, by construction, does not.
  Date: 2026-07-09

- Decision: EP-2 also migrated the existing signing-key reload thread onto its new
  `supervisedLoop`, rather than leaving that to the Security MasterPlan's EP-2 (plan 29).
  Rationale: A TODO comment in `Shomei.Server.Boot.installKeyReload` explicitly asked for the
  migration once this idiom landed, and a second consumer is what proves the abstraction is
  general rather than sweeper-shaped. Plan 29 therefore inherits a key-reload loop that is
  already supervised; it should extend that call site, not rebuild it. One behavior changed: the
  first key reload now happens immediately at boot rather than after one interval (idempotent,
  and `reloadKeys` keeps the last good material on failure).
  Date: 2026-07-09


## Outcomes & Retrospective

**All five child plans are Complete.** Measured against the Vision & Scope, every promise landed:

| Promise | Result |
|---|---|
| Login and refresh in real transactions, few round-trips | Login 11 → 7 checkouts, refresh 5 → 3, both transactional |
| Pool size and acquisition timeout are configuration | `SHOMEI_DB_POOL_SIZE` + Dhall fields |
| Bounded concurrent Argon2 hashing; container-aware RTS | Semaphore (default 2); `+RTS -N<quota>` from the cgroup |
| Every expirable table swept, with the indexes the sweep needs | Supervised sweeper, `expires_at` indexes, `shomei-admin sweep` |
| Retention for `shomei_auth_events` / `shomei_login_attempts` | Configurable windows, documented |
| Rate limiter evicts idle buckets; metrics gauge survives exceptions | Amortized eviction in `takeToken`; `finally` |
| Downstream example: lock-free reads, single-flight, refresh-ahead, stale-on-error | All four, plus fail-closed 503 and `Cache-Control` |

Two scope changes were taken deliberately and are in the Decision Log: EP-3 was allowed to change
`shomei-core`'s `PasswordHasher` port (configurable Argon2 parameters would otherwise have
*reopened* the login timing oracle — preserving a guarantee, not altering one), and EP-3's
load-test acceptance was rewritten from tail latency to p50 and peak RSS, because the harness
cannot resolve a tail. The unresolved questions that produced live in **Follow-up work** above,
outside any child plan: tail latency remains unmeasured, the RTS guidance remains unvalidated
against a real container, `hashingMaxConcurrency = 2` is a fixed default in a world of varying
core counts, and `config/shomei-types.dhall` still lags its loader.

**The decomposition held.** All five plans were mutually independent and none needed another's
code to compile, exactly as the Decomposition Strategy predicted. Both cross-MasterPlan orderings
resolved cleanly: the Security MasterPlan's EP-1 had already landed when EP-1 began, so the
compare-and-swap was lifted into the rotation transaction verbatim; and EP-2's `supervisedLoop`
acquired a second consumer (the key-reload thread) before the Security MasterPlan's EP-2 arrived
to claim it. The one prediction that missed was EP-4 adopting `supervisedLoop` for rate-limiter
eviction — it correctly declined, since eviction needs no thread.

**The recurring lesson is that a plan's specified code is a hypothesis, and its acceptance
criteria bound what its tests can see.** Three separate plans shipped a prescribed fix that was
itself the defect: EP-2's batched `DELETE` violated the `parent_token_id` foreign key whenever a
batch boundary split a rotation family; EP-4's `onException` gauge fix double-decremented on
async exceptions, drifting the gauge *negative* — legal Prometheus, and therefore worse than the
positive drift it replaced; EP-5's "emit one warning line" emitted twenty. The first two were
caught by reverting each fix and watching its test go red, a practice EP-4 introduced and EP-5
extended into systematic mutation testing (six mutations, each killing exactly its own test).
The third was caught by *neither*, because no test observed the log output — only running the
thing by hand did. A plan whose deliverable includes operator-facing behavior should exercise
that behavior once, manually, before it is called done.

The corollary for reviews: this initiative began from a performance review that was right about
every hot-path claim it could substantiate from reading, and wrong-by-omission about several
things only execution revealed. Reading found the `MVar`, the unbounded tables, the missing RTS
flags. Running found the foreign key, the gauge sign, the twenty-line log, the `parseRequest`
status hole, and — in EP-3 — that `GHCRTS` breaks the server at boot because `dhall-to-json`
inherits it.
