---
id: 34
slug: expired-data-sweeper-retention-windows-and-supporting-indexes
title: "Expired-Data Sweeper, Retention Windows, and Supporting Indexes"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/6-operational-and-performance-hardening.md"
---

# Expired-Data Sweeper, Retention Windows, and Supporting Indexes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-2** of MasterPlan 6
(`docs/masterplans/6-operational-and-performance-hardening.md`, "Operational and Performance
Hardening"). It gives Shōmei its first data-hygiene story: a supervised background sweeper
that deletes expired and dead rows in bounded batches, configurable retention windows for the
two forensic append-only tables, a `shomei-admin sweep` subcommand for cron-style operation,
and a schema migration adding the `expires_at` indexes the sweeper needs while dropping four
dead single-column `status` indexes that only cost write amplification today. This plan also
defines the **supervised-background-thread idiom** that later plans (notably the Security
MasterPlan's key-reload thread, `docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`)
are expected to reuse.


## Purpose / Big Picture

Today **nothing in Shōmei ever deletes anything**. Six tables grow without bound:
`shomei_refresh_tokens` gains one row per token refresh forever (a session refreshed every
five minutes for a month leaves ~8,600 dead rows, and every one of them fattens the recursive
family-revocation CTE that reuse detection runs); `shomei_sessions` accumulates expired and
revoked sessions; `shomei_auth_events` and `shomei_login_attempts` are append-only by design
but have no retention policy at all; expired email-verification and password-reset tokens
linger; and abandoned WebAuthn ceremonies pile up even though a bulk-delete port operation
(`deleteExpiredCeremonies`) was built for them — it has **zero callers**. Worse, if a sweeper
were naively added today it would sequential-scan most of those tables, because only
`shomei_webauthn_pending_ceremonies` has an `expires_at` index.

After this plan, an operator can see rows disappear: start the server, let it run, and the
sweeper logs one structured line per cycle (`{"msg":"sweep","table":"shomei_refresh_tokens",
"deleted":124,…}`); or run `shomei-admin sweep` once from a cron job and read the same
counts on stdout. Seeding a database with expired rows and running one sweep deletes exactly
the rows past their grace period and nothing newer, `EXPLAIN` on the sweep predicates shows
index scans on the new `expires_at` indexes, and the audit list endpoint's keyset pagination
gets a matching composite index. Retention for `shomei_auth_events` and
`shomei_login_attempts` becomes explicit configuration with documented compliance caveats.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: new codd migration `…-shomei-sweeper-indexes.sql` created via `just new-migration`,
      adding `expires_at` indexes (sessions, refresh tokens, verification tokens, reset
      tokens), the composite audit index `(created_at DESC, event_id DESC)`, and dropping the
      four dead single-column `status` indexes plus the superseded
      `shomei_auth_events_created_at_idx`.
- [ ] M1: migration applies cleanly to a fresh database (`just create-database`) and to an
      already-migrated database (idempotent `IF EXISTS`/`IF NOT EXISTS` forms).
- [ ] M2: `Shomei.Postgres.Maintenance` module with batched-delete statements and
      `sweepOnce :: Pool -> SweepConfig -> UTCTime -> IO SweepReport`.
- [ ] M2: `shomei-postgres` integration test: seed expired + fresh rows, run `sweepOnce`,
      assert exact deletion counts and survivors.
- [ ] M3: `Shomei.Server.Supervisor` module defining `supervisedLoop` (the reusable idiom:
      catch-crash, log JSON line, exponential backoff restart).
- [ ] M3: sweeper thread forked in `Shomei.Server.Boot.main`, interval + retention windows in
      `ServerSettings` (Dhall fields + `SHOMEI_SWEEP_*` env vars), off-switch honored.
- [ ] M3: per-cycle structured log line verified against the running server.
- [ ] M4: `shomei-admin sweep` subcommand (runs `sweepOnce`, prints the report, exits 0).
- [ ] M4: retention windows and compliance caveats documented in `docs/user/`.
- [ ] Validation: seeded-rows scenario transcript + `EXPLAIN` output captured in Outcomes.
- [ ] `nix fmt` clean; `cabal build all` / `cabal test all` green; MasterPlan 6 Progress and
      registry updated; supervision idiom cross-referenced for plan 29.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship **both** an in-server background sweeper thread (default on) and a
  `shomei-admin sweep` CLI subcommand, with the thread as the turnkey default and the CLI for
  operators who prefer external scheduling (cron, Kubernetes CronJob) — who then set
  `SHOMEI_SWEEP_ENABLED=false` on the server.
  Rationale: Shōmei's posture is turnkey single-instance (the server already self-migrates on
  boot), so hygiene must work with zero extra deployment machinery; but fleet operators
  rightly distrust in-process maintenance and want observable, schedulable jobs. Both call the
  same `sweepOnce` function, so there is one implementation and two triggers. Running both
  concurrently is harmless (deletes are idempotent; batches just find fewer rows).
  Date: 2026-07-07

- Decision: The sweeper issues its own **batched SQL in a new `Shomei.Postgres.Maintenance`
  module** (plain `hasql` statements with `LIMIT`ed subselects) instead of growing each store
  port with sweep operations.
  Rationale: Sweeping is an infrastructure maintenance concern, not a domain operation; no
  workflow will ever call it, so widening seven core ports (and every in-memory test
  interpreter) buys nothing. Batched deletes need `DELETE … WHERE ctid IN (SELECT ctid …
  LIMIT n)` shapes that exist only for lock-time bounding — pure SQL plumbing. The one
  existing port operation (`deleteExpiredCeremonies` in
  `shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs` lines ~51–52) is left in place for
  API compatibility but the sweeper uses its own batched variant; note the near-duplication
  in a comment referencing this decision.
  Date: 2026-07-07

- Decision: Refresh tokens are swept **via their parent session** (delete tokens whose session
  expired or was revoked more than the grace period ago, then delete those sessions), never by
  their own `expires_at` alone.
  Rationale: Two constraints force this. First, `shomei_refresh_tokens.parent_token_id` is a
  self-referencing foreign key with no `ON DELETE` action, so deleting an old expired parent
  while a newer child row survives violates the constraint — but all members of a rotation
  family share one `session_id`, and PostgreSQL checks `NO ACTION` foreign keys at end of
  statement, so deleting a whole session's tokens in one statement is always consistent.
  Second, reuse detection depends on *used* tokens still existing (a presented used token is
  the reuse signal); deleting them early would silently downgrade reuse to "invalid token".
  Sweeping only sessions that are dead past a grace period (default 30 days) keeps the entire
  detection window intact: by then every token in the family is unusable anyway.
  Date: 2026-07-07

- Decision: Retention defaults — `shomei_login_attempts`: **90 days**;
  `shomei_auth_events`: **disabled** (retain indefinitely) until the operator sets a window;
  dead sessions/refresh tokens: **30 days** grace; expired verification/reset tokens and
  lockout rows: **7 days** grace; expired pending ceremonies: **1 hour** grace.
  Rationale: Login attempts exist for windowed brute-force counting (a 15-minute window) plus
  short-term forensics; 90 days is generous and bounds the biggest write-rate table. Audit
  events are the compliance record — the only conservative default is "keep everything", and
  deleting audit data must be an explicit operator decision (documented caveat: regulations
  like SOC 2 / PCI often require ≥ 1 year; GDPR may require the opposite; Shōmei cannot pick
  for you). One-time tokens are worthless minutes after expiry; 7 days is pure debugging
  slack. Ceremonies are worthless seconds after expiry; 1 hour keeps live debugging possible.
  Date: 2026-07-07

- Decision: The supervision idiom is `supervisedLoop`: run an `IO ()` cycle in `forever`,
  catch `SomeException` per cycle, log a structured `{"level":"error","msg":"background task
  crashed",…}` line to stderr, back off exponentially (5 s doubling to a 5 min cap, reset
  after a clean cycle), and never propagate — the thread survives until process exit; it is
  **not** respawned by a monitor thread and it never kills the server.
  Rationale: For periodic maintenance, "log loudly and retry with backoff" is the whole
  requirement; a supervisor hierarchy (async/withAsync trees, restart intensity budgets) is
  Erlang cosplay for a thread whose failure mode is "the database was briefly down". Never
  crashing the server matters because sweep failure is strictly less bad than downtime. The
  MasterPlan designates this plan as the owner of the idiom; plan 29's key-reload thread
  reuses `Shomei.Server.Supervisor.supervisedLoop` rather than inventing a second pattern.
  Date: 2026-07-07

- Decision: Drop the four single-column `status` indexes
  (`shomei_sessions_status_idx`, `shomei_refresh_tokens_status_idx`,
  `shomei_email_verification_tokens_status_idx`, `shomei_password_reset_tokens_status_idx`)
  and the now-superseded `shomei_auth_events_created_at_idx` in the same migration that adds
  the new indexes.
  Rationale: Each `status` column holds 3–4 distinct values and no query in the codebase
  filters by status alone (verified by grepping the `preparable` statements in
  `shomei-postgres/src/Shomei/Postgres/*.hs`: status always appears alongside an id-equality
  predicate that an existing PK/unique/FK index already serves). They are pure write
  amplification on the hottest write paths. The audit composite `(created_at DESC, event_id
  DESC)` strictly subsumes the old single-column `created_at` index for the reader's
  `ORDER BY created_at DESC, event_id DESC` keyset query.
  Date: 2026-07-07

- Decision: Sweep configuration lives in `ServerSettings`
  (`shomei-server/src/Shomei/Server/Config.hs`), not core `ShomeiConfig`.
  Rationale: Same reasoning as plan 33's pool settings: retention is a deployment/storage
  concern with no domain meaning; `ShomeiConfig` stays infrastructure-free. Fields are
  append-only per MasterPlan 6's Integration Points (plans 33 and 35 add their own fields to
  the same records).
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Haskell workspace
(GHC 9.12.4, GHC2024). Everything builds inside `nix develop` with `cabal build all`, tests
run with `cabal test all`, formatting is `nix fmt`, and the dev database is created/migrated
idempotently with `just create-database`. The pieces this plan touches:

**Migrations.** Schema changes are *codd* migrations: plain SQL files named
`YYYY-MM-DD-HH-MM-SS-<slug>.sql` in `shomei-migrations/sql-migrations/`, each beginning with
`-- codd: in-txn` and `SET search_path TO shomei, pg_catalog;`. They are embedded into the
`shomei-migrations` library **at compile time** by a Template Haskell `embedDir` splice in
`shomei-migrations/src/Shomei/Migrations.hs` — a new `.sql` file is invisible until that
module recompiles, which is why the `just migrate` recipe touches
`shomei-migrations/shomei-migrations.cabal` first, and why `just new-migration
name=<slug>` is the way to scaffold one (it stamps the UTC timestamp and the header). The
server applies embedded migrations on boot; `shomei-admin migrate` applies them out-of-band.

**Current index reality** (from reading the migration files): only
`shomei_webauthn_pending_ceremonies` has an `expires_at` index. `shomei_sessions`,
`shomei_refresh_tokens`, `shomei_email_verification_tokens`, and
`shomei_password_reset_tokens` each have a single-column `status` index that nothing queries
by itself. `shomei_auth_events` has single-column indexes on `user_id`, `session_id`,
`event_type`, `created_at`; the audit reader
(`shomei-postgres/src/Shomei/Postgres/AuthEventReader.hs`, `selectStmt` around line 149)
paginates with `ORDER BY created_at DESC, event_id DESC` and a row-comparison keyset predicate
`(created_at, event_id) < ($6, $7)` — which wants a composite `(created_at DESC, event_id
DESC)` index. `shomei_account_lockouts` already has a `locked_until` index.

**The growing tables and their lifecycle columns.** `shomei_sessions(status, expires_at,
revoked_at)`; `shomei_refresh_tokens(status, expires_at, used_at, revoked_at,
parent_token_id REFERENCES shomei_refresh_tokens, session_id REFERENCES shomei_sessions)`;
`shomei_email_verification_tokens` / `shomei_password_reset_tokens` (`status, expires_at`);
`shomei_login_attempts(occurred_at)` (append-only, no status);
`shomei_auth_events(created_at)` (append-only); `shomei_webauthn_pending_ceremonies
(expires_at)`; `shomei_account_lockouts(locked_until)`. The one existing bulk-delete surface
is `DeleteExpiredCeremonies` in `shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs`
(lines ~51–52) with its statement `deleteExpiredStmt` in
`shomei-postgres/src/Shomei/Postgres/PendingCeremonyStore.hs` (lines ~136–143) — grep confirms
no caller anywhere.

**Server boot.** `Shomei.Server.Boot.main` (`shomei-server/src/Shomei/Server/Boot.hs`) loads
config (`loadConfig` in `src/Shomei/Server/Config.hs`, layered defaults → Dhall `FileConfig` →
`SHOMEI_*` env), builds the `Env` (pool, keys), assembles WAI middleware, and runs warp with
graceful shutdown. There is **no background thread of any kind today**; this plan forks the
first one, and therefore owns the idiom (see Decision Log). `Hasql.Pool.Pool` is in
`Env.envPool`, so the sweeper can share the server's pool.

**Term definitions.** A *batched delete* deletes at most N rows per statement so the row locks
and the transaction are short-lived, using PostgreSQL's physical row address: `DELETE FROM t
WHERE ctid IN (SELECT ctid FROM t WHERE <predicate> LIMIT n)` — `ctid` is a system column
identifying a row version; selecting it with a LIMIT and deleting by it is the standard
bounded-delete idiom. A *grace period* is extra time past logical expiry before a row becomes
sweepable, kept for forensics and to protect reuse detection. A *retention window* is the
maximum age of rows in an append-only table. *Keyset pagination* means paging with a
`(created_at, event_id) < (last_seen…)` predicate instead of OFFSET.

**Test infrastructure.** `shomei-migrations` ships a `test-support` sublibrary with
`Shomei.Migrations.TestSupport.withShomeiMigratedDatabase :: (Text -> IO a) -> IO a`, which
provisions an ephemeral migrated PostgreSQL and hands the connection string to the action —
the `shomei-postgres` and `shomei-server` test suites already use it; the new sweeper tests
do too.


## Plan of Work

Four milestones: the migration first (indexes are useful even before the sweeper exists), the
sweep engine second (pure library + tests, no threads), the supervised server thread third,
the CLI and documentation fourth.

### Milestone M1 — the index migration

Scope: one new codd migration; nothing else. At the end, a fresh `just create-database`
produces a schema where every sweep predicate and the audit keyset query are index-served and
the five dead indexes are gone.

Scaffold it (the recipe stamps the current UTC timestamp):

```bash
just new-migration name=sweeper-indexes-and-retention
```

Fill the generated file in `shomei-migrations/sql-migrations/` with:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Sweep-supporting indexes (EP-2 of the operational-hardening MasterPlan).
-- The sweeper deletes by expiry cutoffs; without these it would seq-scan.
CREATE INDEX IF NOT EXISTS shomei_sessions_expires_at_idx
  ON shomei_sessions (expires_at);
CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_expires_at_idx
  ON shomei_refresh_tokens (expires_at);
CREATE INDEX IF NOT EXISTS shomei_email_verification_tokens_expires_at_idx
  ON shomei_email_verification_tokens (expires_at);
CREATE INDEX IF NOT EXISTS shomei_password_reset_tokens_expires_at_idx
  ON shomei_password_reset_tokens (expires_at);
CREATE INDEX IF NOT EXISTS shomei_login_attempts_occurred_at_idx
  ON shomei_login_attempts (occurred_at);

-- Audit keyset pagination: ORDER BY created_at DESC, event_id DESC with a
-- (created_at, event_id) < ($cursor) predicate wants exactly this composite.
CREATE INDEX IF NOT EXISTS shomei_auth_events_created_event_idx
  ON shomei_auth_events (created_at DESC, event_id DESC);

-- Dead single-column status indexes: 3-4 distinct values, never queried alone,
-- pure write amplification. The composite above subsumes the old created_at index.
DROP INDEX IF EXISTS shomei_sessions_status_idx;
DROP INDEX IF EXISTS shomei_refresh_tokens_status_idx;
DROP INDEX IF EXISTS shomei_email_verification_tokens_status_idx;
DROP INDEX IF EXISTS shomei_password_reset_tokens_status_idx;
DROP INDEX IF EXISTS shomei_auth_events_created_at_idx;
```

Note the login-attempts sweep predicate is age-only (`occurred_at < cutoff`), which the
existing partial indexes (they lead on `account_key`/`client_ip`) cannot serve — hence the
plain `occurred_at` index. Then apply and verify (the recipe touches the `.cabal` so the TH
splice re-embeds):

```bash
just migrate
psql -d "$PGDATABASE" -c "\di shomei.*expires_at*"
```

Acceptance: the new indexes list; `\di shomei.*status*` shows none of the four dropped names;
`cabal test all` (which provisions fresh ephemeral databases through the embedded migrations)
stays green. Concurrent-plan note: other in-flight plans add their own timestamped migrations;
timestamped filenames cannot collide, but always re-run `just create-database` after rebasing.

### Milestone M2 — the sweep engine (`sweepOnce`) and its tests

Scope: a pure-IO library function that performs one full sweep pass in bounded batches, plus
an integration test with seeded rows. No threads, no config plumbing yet — `SweepConfig` is an
ordinary record with a `defaultSweepConfig`.

Create `shomei-postgres/src/Shomei/Postgres/Maintenance.hs` (add to
`shomei-postgres.cabal` `exposed-modules`), exporting:

```haskell
data SweepConfig = SweepConfig
  { batchSize :: !Int,                        -- rows per DELETE statement (default 1000)
    deadSessionGraceDays :: !Int,             -- default 30
    oneTimeTokenGraceDays :: !Int,            -- default 7
    ceremonyGraceMinutes :: !Int,             -- default 60
    loginAttemptRetentionDays :: !Int,        -- default 90
    authEventRetentionDays :: !(Maybe Int)    -- default Nothing = retain forever
  }

data SweepReport = SweepReport
  { refreshTokensDeleted, sessionsDeleted, verificationTokensDeleted,
    resetTokensDeleted, ceremoniesDeleted, lockoutsDeleted,
    loginAttemptsDeleted, authEventsDeleted :: !Int }

defaultSweepConfig :: SweepConfig
sweepOnce :: Pool -> SweepConfig -> UTCTime -> IO (Either UsageError SweepReport)
```

`sweepOnce` runs, in order (order matters for the session/token foreign key), a
repeat-until-short-batch loop per table: execute the batched delete with the table's cutoff,
read the affected-row count (`D.rowsAffected` decoder), add it to the report, and repeat while
the count equals `batchSize`. Each batch is its own `Pool.use` session — deliberately *not*
one big transaction, so locks stay short and a crash mid-sweep loses nothing (deletes are
idempotent). The statements, all `preparable` multiline strings in this module (house style:
schema-qualified, `$1` = cutoff timestamp, `$2` = batch limit):

1. Dead-session refresh tokens (cutoff = now − `deadSessionGraceDays`):

```sql
DELETE FROM shomei.shomei_refresh_tokens
WHERE ctid IN (
  SELECT rt.ctid FROM shomei.shomei_refresh_tokens rt
  JOIN shomei.shomei_sessions s ON s.session_id = rt.session_id
  WHERE s.expires_at <= $1 OR (s.status = 'revoked' AND s.revoked_at <= $1)
  LIMIT $2)
```

2. Dead sessions themselves (same predicate, guarded by `NOT EXISTS` remaining tokens so a
   partially-swept family never strands a session-less token):

```sql
DELETE FROM shomei.shomei_sessions s
WHERE s.ctid IN (
  SELECT s2.ctid FROM shomei.shomei_sessions s2
  WHERE (s2.expires_at <= $1 OR (s2.status = 'revoked' AND s2.revoked_at <= $1))
    AND NOT EXISTS (SELECT 1 FROM shomei.shomei_refresh_tokens rt
                    WHERE rt.session_id = s2.session_id)
  LIMIT $2)
```

3.–4. Verification and reset tokens: `WHERE expires_at <= $1` (cutoff = now −
`oneTimeTokenGraceDays`), same ctid/LIMIT shape. 5. Pending ceremonies: `expires_at <= $1`
(cutoff = now − `ceremonyGraceMinutes`). 6. Lockouts: `locked_until IS NOT NULL AND
locked_until <= $1` (reuse the one-time-token grace). 7. Login attempts: `occurred_at <= $1`
(cutoff = now − `loginAttemptRetentionDays`). 8. Auth events, only when
`authEventRetentionDays` is `Just n`: `created_at <= $1`.

Add an integration test to the existing `shomei-postgres` test suite
(`shomei-postgres/test/Main.hs` pattern: `withShomeiMigratedDatabase`, `acquirePool 4 …`).
Seed via plain insert sessions: two users; one session expired 40 days ago with a chain of 3
refresh tokens, one active session with 2 tokens; expired + fresh verification/reset tokens;
an expired ceremony; login attempts at 100 days and 10 days; auth events at 400 days and
today. Run `sweepOnce` with defaults and assert the report reads exactly
`refreshTokensDeleted = 3, sessionsDeleted = 1, verificationTokensDeleted = 1,
resetTokensDeleted = 1, ceremoniesDeleted = 1, loginAttemptsDeleted = 1, authEventsDeleted =
0`, and that the survivors are still present (count queries). Run `sweepOnce` again and assert
an all-zero report (idempotence). Run once more with `authEventRetentionDays = Just 365` and
assert exactly the 400-day event went. Also test the batch loop: seed 25 expired ceremonies,
`batchSize = 10`, assert `ceremoniesDeleted = 25` (three batches).

### Milestone M3 — the supervised background thread in the server

Scope: the supervision idiom module and the sweeper thread wired into boot, with
configuration. At the end, a running server sweeps every interval and logs a structured line
per cycle, and a crash inside a cycle logs an error and retries with backoff instead of
taking anything down.

Create `shomei-server/src/Shomei/Server/Supervisor.hs` (add to `exposed-modules` — plan 29
will import it):

```haskell
-- | THE house idiom for supervised background threads (owned by plan 34; reused by the
-- key-reload thread of docs/plans/29-…). Runs @cycleAction@ forever, sleeping
-- @intervalSeconds@ between clean cycles. A crash (any SomeException) is caught, logged as a
-- structured JSON line on stderr, and retried after an exponential backoff (5s doubling to
-- 300s, reset on the next clean cycle). The loop never rethrows: a maintenance task must
-- never take the server down. Fork it with plain forkIO from Boot.main; it dies with the
-- process (maintenance needs no drain on shutdown because every cycle is idempotent).
supervisedLoop
  :: Text        -- ^ task name, appears in every log line
  -> Int         -- ^ interval between clean cycles, seconds
  -> IO ()       -- ^ one cycle
  -> IO ()
```

Implementation notes: `Control.Exception.try @SomeException`, but **rethrow** if the caught
exception is asynchronous `ThreadKilled`/`AsyncCancelled` (check with `fromException`) so
process shutdown is not fought; `threadDelay` takes microseconds — multiply carefully; emit
lines with a single strict `BS.hPutStr stderr` of an `aeson`-encoded object
(`{"level":"error","msg":"background task crashed","task":…,"error":…,"backoff_s":…}` and
`{"level":"info","msg":"sweep","table_counts":…,"duration_ms":…}` comes from the sweeper's
own cycle, below).

Extend `ServerSettings` (`shomei-server/src/Shomei/Server/Config.hs`) with `serverSweep ::
!SweepSettings` where `SweepSettings` carries `sweepEnabled :: !Bool` (default True),
`sweepIntervalSeconds :: !Int` (default 3600), and the six `SweepConfig` numbers with the M2
defaults. Add the matching optional `FileConfig` Dhall fields (`sweepEnabled`,
`sweepIntervalSeconds`, `sweepBatchSize`, `sweepDeadSessionGraceDays`,
`sweepOneTimeTokenGraceDays`, `sweepCeremonyGraceMinutes`, `loginAttemptRetentionDays`,
`authEventRetentionDays`) and env overrides `SHOMEI_SWEEP_ENABLED`,
`SHOMEI_SWEEP_INTERVAL_SECONDS`, `SHOMEI_LOGIN_ATTEMPT_RETENTION_DAYS`,
`SHOMEI_AUTH_EVENT_RETENTION_DAYS`, etc., using the existing `boolEnv`/`intEnvMaybe` helpers.
`authEventRetentionDays` is the one `Maybe`: absent everywhere means "retain forever".

In `Shomei.Server.Boot.main`, after `buildEnv` and before `Warp.runSettings`, when
`sweepEnabled`:

```haskell
_ <- forkIO $ supervisedLoop "sweeper" settings.serverSweep.sweepIntervalSeconds do
  started <- getCurrentTime
  result <- sweepOnce env.envPool (toSweepConfig settings.serverSweep) started
  logSweepCycle started result   -- one JSON line: counts or the UsageError
```

A `Left UsageError` from `sweepOnce` (database unreachable) is logged by `logSweepCycle` and
does **not** count as a crash — only exceptions trigger backoff. Acceptance: run the server
with `SHOMEI_SWEEP_INTERVAL_SECONDS=5` against a dev database seeded with expired rows and
watch the first cycle's log line report nonzero counts and the second report zeros; stop
PostgreSQL, watch cycles log the usage error while `/health` keeps answering; restart
PostgreSQL, watch cycles recover.

### Milestone M4 — `shomei-admin sweep` and documentation

Scope: the CLI trigger and the operator docs. `shomei-admin` lives in
`shomei-server/app/Admin.hs` with an optparse-applicative `hsubparser` command tree
(`migrate` / `keys` / `users` / `audit`) and per-command modules under
`shomei-server/app/Shomei/Admin/`. Add a `sweep` command: parser flags mirroring the
`SweepConfig` fields (`--batch-size`, `--dead-session-grace-days`, …,
`--auth-event-retention-days` as optional) with the M2 defaults; the runner loads the admin
env (`Shomei.Admin.Env.loadAdminEnv`, which already acquires a small pool), calls `sweepOnce`
once, prints the report as aligned `table: count` lines, exits 0 on `Right` and 1 with the
error on `Left`. Extend the `shomei-admin-test` suite with a seeded-database case mirroring
M2's (the suite already boots ephemeral databases).

Document in `docs/user/` (the operations page that documents `shomei-admin` and the env vars;
locate with `grep -rln "shomei-admin" docs/user`): what the sweeper deletes and when, every
knob with its default, the thread-vs-cron choice, and the compliance caveat paragraph for
`shomei_auth_events` retention (defaults to forever; deleting audit history is an explicit,
logged operator decision; check your regulatory retention floor *and* data-minimization
ceiling before setting it).


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`, with the dev stack's
PostgreSQL running and `just create-database` applied.

```bash
# M1
just new-migration name=sweeper-indexes-and-retention
"$EDITOR" shomei-migrations/sql-migrations/*-sweeper-indexes-and-retention.sql
just migrate
psql -d "$PGDATABASE" -tc "SELECT indexname FROM pg_indexes WHERE schemaname='shomei' AND indexname LIKE '%expires_at%'"
```

Expected: five `…_expires_at_idx` names plus the pre-existing ceremonies one; and

```bash
psql -d "$PGDATABASE" -tc "SELECT indexname FROM pg_indexes WHERE schemaname='shomei' AND indexname IN ('shomei_sessions_status_idx','shomei_refresh_tokens_status_idx','shomei_email_verification_tokens_status_idx','shomei_password_reset_tokens_status_idx','shomei_auth_events_created_at_idx')"
```

returns no rows.

```bash
# M2
cabal build shomei-postgres && cabal test shomei-postgres
```

Expected excerpt:

```text
  maintenance sweep
    deletes exactly the expired rows and spares the rest: OK
    second sweep is a no-op:                              OK
    batches until drained:                                OK
```

```bash
# M3 — live check with a short interval
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
SHOMEI_SWEEP_INTERVAL_SECONDS=5 cabal run shomei-server
```

Expected stderr within ~5 s (illustrative counts):

```json
{"level":"info","msg":"sweep","refresh_tokens":3,"sessions":1,"verification_tokens":0,"reset_tokens":0,"ceremonies":1,"lockouts":0,"login_attempts":0,"auth_events":0,"duration_ms":41}
```

```bash
# M4
cabal run shomei-admin -- sweep
```

Expected stdout:

```text
refresh_tokens:      0
sessions:            0
verification_tokens: 0
reset_tokens:        0
ceremonies:          0
lockouts:            0
login_attempts:      0
auth_events:         0 (retention disabled)
```

Finish with `nix fmt`, `cabal build all`, `cabal test all`, and the EXPLAIN capture below.


## Validation and Acceptance

1. **Deletion correctness.** The M2 seeded test passes: exactly the graced-out rows are
   deleted, survivors remain, a second sweep deletes zero, and audit events go only when a
   retention window is configured.
2. **Index usage.** Against a dev database with a few thousand seeded rows:

```bash
psql -d "$PGDATABASE" -c "EXPLAIN SELECT ctid FROM shomei.shomei_email_verification_tokens WHERE expires_at <= now() - interval '7 days' LIMIT 1000"
```

   The plan must show `Index Scan using shomei_email_verification_tokens_expires_at_idx` (or a
   bitmap scan on it), not `Seq Scan` — repeat for sessions, refresh-token join, login
   attempts, and the audit keyset query (`EXPLAIN SELECT … FROM shomei.shomei_auth_events
   ORDER BY created_at DESC, event_id DESC LIMIT 50` shows the composite index). Paste the
   excerpts into Outcomes. (On tiny tables the planner may still seq-scan; seed enough rows or
   `SET enable_seqscan = off` for the demonstration and say so.)
3. **Supervision.** With the server running and `SHOMEI_SWEEP_INTERVAL_SECONDS=5`: stopping
   PostgreSQL produces per-cycle error log lines while `curl localhost:8080/health` still
   returns 200; restarting PostgreSQL restores clean sweep lines — no restart of the server
   needed, no crash. Kill-test the idiom: temporarily make one cycle `error "boom"`, observe
   the structured crash line with `"backoff_s":5` then `10`, then remove the sabotage.
4. **CLI.** `shomei-admin sweep` on a seeded database prints the same counts M2's test
   asserts and exits 0; with PostgreSQL stopped it prints the usage error and exits 1.
5. **Nothing else regressed.** `cabal test all` fully green; a manual login/refresh flow
   against the dev server behaves unchanged (the sweeper never touches live rows).


## Idempotence and Recovery

The migration uses `IF NOT EXISTS`/`IF EXISTS` throughout, so re-applying to an
already-migrated database is safe; codd additionally records applied filenames and will not
re-run it. Dropping the dead indexes is instantly reversible (re-create with the definitions
recorded in "Context and Orientation") and risks no data. Every sweep statement is a bounded
idempotent delete: re-running a batch, a cycle, or the whole `sweepOnce` after a crash simply
finds fewer (or zero) rows. The thread and the CLI may run concurrently without coordination.
The one operation that destroys data an operator might want is auth-event deletion, which is
**off by default** and requires explicitly setting `authEventRetentionDays`; the docs instruct
taking ordinary backups before first enabling it. If a sweep misbehaves in production, set
`SHOMEI_SWEEP_ENABLED=false` and restart — the system merely returns to today's grow-forever
behavior.


## Interfaces and Dependencies

No new external dependencies: `hasql`/`hasql-pool` (statements + `Pool.use`), `aeson`
(log lines), `base` (`forkIO`, `threadDelay`, `Control.Exception`), `optparse-applicative`
(already used by `shomei-admin`).

Must exist at the end:

- Migration `shomei-migrations/sql-migrations/<ts>-sweeper-indexes-and-retention.sql` with the
  index set in M1 (five `expires_at`-family creates, one composite audit create, five drops).
- `Shomei.Postgres.Maintenance` exporting `SweepConfig (..)`, `SweepReport (..)`,
  `defaultSweepConfig :: SweepConfig`, and
  `sweepOnce :: Pool -> SweepConfig -> UTCTime -> IO (Either UsageError SweepReport)`.
- `Shomei.Server.Supervisor.supervisedLoop :: Text -> Int -> IO () -> IO ()` — **the** shared
  supervised-background-thread idiom (consumed later by
  `docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`; if plan 36
  chooses a periodic eviction task it also reuses this).
- `ServerSettings.serverSweep :: !SweepSettings` plus the Dhall/env knobs listed in M3
  (append-only extension of `ServerSettings`/`FileConfig`, shared with plans 33 and 35 per
  MasterPlan 6 Integration Points).
- `shomei-admin sweep` subcommand in `shomei-server/app/Admin.hs` (+ a
  `Shomei.Admin.Sweep` module beside the existing `Shomei.Admin.*`).
- Operator documentation of retention defaults and compliance caveats in `docs/user/`.
