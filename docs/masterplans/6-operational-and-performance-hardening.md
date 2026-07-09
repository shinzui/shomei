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
| 2 | Expired-Data Sweeper, Retention Windows, and Supporting Indexes | docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md | None | None | Not Started |
| 3 | Bound Argon2 Hashing Concurrency and Container-Aware Runtime Tuning | docs/plans/35-bound-argon2-hashing-concurrency-and-container-aware-runtime-tuning.md | None | None | Not Started |
| 4 | Middleware Hardening: Rate-Limiter Eviction, Metrics Accuracy, and Warp Settings | docs/plans/36-middleware-hardening-rate-limiter-eviction-metrics-accuracy-and-warp-settings.md | None | None | Not Started |
| 5 | Resilient Downstream JWKS Cache Template | docs/plans/37-resilient-downstream-jwks-cache-template.md | None | None | Not Started |

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

Migrations directory (`shomei-migrations/sql-migrations/`): EP-2 adds `expires_at`/retention
indexes and drops the dead single-column `status` indexes. No other plan in this MasterPlan
adds migrations, but the Interop MasterPlan adds new tables concurrently; codd migrations are
timestamped files, so parallel additions do not conflict as long as each plan runs
`just create-database` (or `shomei-admin migrate`) against a fresh database in its validation
steps.

Metrics module (`shomei-server/src/Shomei/Server/Observability/Metrics.hs`): EP-4 fixes the
in-flight gauge; EP-3's load test reads these metrics for acceptance. EP-4's fix is
independent, but if EP-3 runs its load test first it should expect the gauge drift EP-4 fixes.


## Progress

- [x] EP-1: Pool size and acquisition timeout configurable (`SHOMEI_DB_POOL_SIZE`, Dhall field)
- [x] EP-1: Login workflow tail batched into transactions; round-trips measured before/after (11 → 7)
- [x] EP-1: Refresh workflow batched (mark-used + child insert + events in one transaction) (5 → 3)
- [x] EP-1: `clearAccountLockout` made conditional (no unconditional DELETE per login)
- [ ] EP-2: Supervised background-sweeper thread with per-table delete batches
- [ ] EP-2: `expires_at` indexes added; dead `status` indexes dropped; audit composite index decision recorded
- [ ] EP-2: Retention windows for `shomei_auth_events` and `shomei_login_attempts` (config + docs)
- [ ] EP-3: Semaphore bounding concurrent Argon2 hashing; parameters configurable
- [ ] EP-3: Container-aware RTS flags in Dockerfile/entrypoint; deployment docs updated
- [ ] EP-3: Concurrent-login load test demonstrating bounded latency impact on the hot path
- [ ] EP-4: Rate-limiter bucket eviction (idle sweep) and contention note
- [ ] EP-4: In-flight gauge exception-safe; Warp `setOnException` routed to structured logger
- [ ] EP-5: Example JWKS cache rewritten: lock-free reads, single-flight refresh, refresh-ahead, stale-on-error
- [ ] EP-5: `docs/user/client-and-examples.md` updated to describe the pattern as the recommended template


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
