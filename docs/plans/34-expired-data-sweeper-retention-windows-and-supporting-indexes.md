---
id: 34
slug: expired-data-sweeper-retention-windows-and-supporting-indexes
title: "Expired-Data Sweeper, Retention Windows, and Supporting Indexes"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/6-operational-and-performance-hardening.md"
intention: intention_01kx2hqr6beeashgwvg5zwxtgc
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

- [x] M1 (2026-07-09): new codd migration
      `shomei-migrations/sql-migrations/2026-07-09-13-51-07-sweeper-indexes-and-retention.sql`
      created via `just new-migration sweeper-indexes-and-retention`, adding `expires_at`
      indexes (sessions, verification tokens, reset tokens), the partial
      `shomei_sessions_revoked_at_idx`, `shomei_login_attempts_occurred_at_idx`, the composite
      audit index `(created_at DESC, event_id DESC)`, and dropping the four dead single-column
      `status` indexes plus the superseded `shomei_auth_events_created_at_idx`. Two deviations
      from the original index list are recorded in the Decision Log (no refresh-token
      `expires_at` index; added a partial sessions `revoked_at` index).
- [x] M1 (2026-07-09): migration applies cleanly (`just migrate` → `[1 found]`, applied in
      9 ms) and is idempotent (`IF EXISTS`/`IF NOT EXISTS` forms; codd additionally records
      the applied filename and will not re-run it).
- [x] M2 (2026-07-09): `Shomei.Postgres.Maintenance` module with batched-delete statements and
      `sweepOnce :: Pool -> SweepConfig -> UTCTime -> IO (Either UsageError SweepReport)`,
      plus `emptySweepReport`, `sweepReportCounts`, `sweepReportTotal`. The refresh-token
      statement batches by *session*, not by row — see Surprises & Discoveries.
- [x] M2 (2026-07-09): `shomei-postgres` integration test: five cases (exact deletion counts +
      survivors; idempotent second sweep; audit retention on/off; batch loop drains 25 rows at
      `batchSize = 10`; a rotation family is never split at `batchSize = 1`). Full suite green
      at 31/31.
- [x] M3 (2026-07-09): `Shomei.Server.Supervisor` module defining `supervisedLoop` (the reusable
      idiom: catch-crash, log JSON line, exponential backoff restart, rethrow async exceptions),
      plus `supervisedLoopMicros` so the behavior is unit-testable in milliseconds, and
      `logJsonLine`.
- [x] M3 (2026-07-09): sweeper thread forked in `Shomei.Server.Boot.main` via `installSweeper`;
      `SweepSettings` in `ServerSettings` (Dhall fields + `SHOMEI_SWEEP_*` env vars), off-switch
      honored, config validated. The pre-existing key-reload loop was moved onto
      `supervisedLoop`, as the TODO in its comment asked.
- [x] M3 (2026-07-09): per-cycle structured log line verified against the running server (first
      cycle nonzero, second all zeros — transcript in Outcomes).
- [x] M3 (2026-07-09): three supervisor unit tests (crash is retried; backoff resets after a
      clean cycle; an async exception stops the loop) and three config assertions (defaults,
      env overrides incl. "0 means forever", non-positive values rejected).
- [x] M4 (2026-07-09): `shomei-admin sweep` subcommand (`Shomei.Admin.Sweep`) — runs `sweepOnce`,
      prints the aligned report, exits 0; exits 1 with the database error on `Left`. Admin
      integration test seeds a database and asserts the counts.
- [x] M4 (2026-07-09): retention windows and compliance caveats documented in
      `docs/user/deployment.md` (new "Data retention and the sweeper" section, env-var table
      rows, Dhall field list) and cross-referenced from `docs/user/security.md`.
- [x] Validation (2026-07-09): seeded-rows scenario transcript + `EXPLAIN` output captured in
      Outcomes, including the counterfactual proving the partial `revoked_at` index is
      load-bearing.
- [x] `nix fmt` clean; `cabal build all` green (0 errors); `cabal test all -j1
      --test-options="-j1"` fully green; MasterPlan 6 Progress and registry updated; supervision
      idiom cross-referenced for plan 29.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`just new-migration name=<slug>` (as written in this plan's Concrete Steps) is wrong.**
  The recipe takes the slug as a positional parameter, so the `name=` prefix is passed through
  as part of the string and rejected by the slug validator:

```text
$ just new-migration name=sweeper-indexes-and-retention
Invalid slug: name=sweeper-indexes-and-retention
error: recipe `new-migration` failed on line 33 with exit code 1
```

  The correct invocation is `just new-migration sweeper-indexes-and-retention`. This plan's
  Concrete Steps have been corrected.

- **Touching the `.cabal` does not force the `embedDir` splice to re-run.** The `migrate`
  recipe's `touch shomei-migrations/shomei-migrations.cabal` is a no-op for cabal, which
  hashes file *content* rather than mtime. A freshly scaffolded migration is therefore
  invisible — `just migrate` cheerfully reports `Looking for pending migrations... [0 found]`
  and exits 0, which looks like success:

```text
$ just migrate
Looking for pending migrations... [0 found]
Successfully applied all migrations to shomei
$ psql -d "$PGDATABASE" -tAc "SELECT indexname FROM pg_indexes WHERE schemaname='shomei' AND indexname LIKE '%expires_at%'"
shomei_webauthn_pending_ceremonies_expires_at_idx     -- only the pre-existing one
```

  The real convention is visible in `shomei-migrations/src/Shomei/Migrations.hs`: the comment
  block above `embeddedFiles` carries one line per migration wave, precisely so the module's
  *content* changes and GHC recompiles the splice. Adding such a line fixed it:

```text
[1 of 1] Compiling Main ... [Shomei.Migrations changed]
Looking for pending migrations... [1 found]
Applying 2026-07-09-13-51-07-sweeper-indexes-and-retention.sql (9ms)
```

  **Any later plan that adds a migration must append a comment line to that block.** This is
  the single most likely way for a contributor to silently ship a migration that never runs.

- **This plan's own M2 SQL for refresh tokens was unsafe, and would have failed in production
  the first time a rotation family straddled a batch boundary.** The specified shape was
  `DELETE FROM shomei_refresh_tokens WHERE ctid IN (SELECT rt.ctid … JOIN … LIMIT $2)`. Because
  `parent_token_id` is a self-referencing foreign key with **no `ON DELETE` action**, checked at
  end of statement, a row-bounded batch that deletes a parent while its child survives into the
  next batch violates the constraint. The plan's Decision Log asserted this was safe on the
  grounds that "all members of a rotation family share one `session_id`" — true, but irrelevant
  to a batch bounded by `LIMIT` on *rows*, which has no reason to respect family boundaries.
  Reduced to a minimal reproduction:

```text
CREATE TABLE rt (id uuid PRIMARY KEY, parent_id uuid NULL REFERENCES rt(id));
-- a 3-generation family t1 <- t2 <- t3, then a batch that takes only the first two:
DELETE FROM rt WHERE ctid IN (SELECT ctid FROM rt LIMIT 2);

ERROR:  23503: update or delete on table "rt" violates foreign key constraint
        "rt_parent_id_fkey" on table "rt"
DETAIL:  Key (id)=(...0002) is still referenced from table "rt".
```

  This would surface only under load — a family is split only when it happens to cross the
  1000-row boundary — which is the worst possible time to discover it. `deadSessionTokensStmt`
  therefore bounds itself by **session** (`WHERE rt.session_id IN (SELECT s.session_id … LIMIT
  $2)`), so every statement deletes whole families. Verified against the same reproduction:
  three passes at `LIMIT 1` yield `DELETE 3`, `DELETE 3`, `DELETE 0`, and the live session's
  token survives. The `shomei-postgres` test
  `maintenance sweep: a batch never splits a refresh-token rotation family` pins this with
  `batchSize = 1` across two families.

- **The drain loop's terminator must be "deleted zero rows", not "deleted fewer than
  `batchSize` rows"** (which this plan's M2 prose specified). Since the refresh-token statement
  bounds by sessions, one batch of a single session legitimately deletes three token rows — the
  `rowsAffected` count and the `LIMIT` are simply not commensurable. `deleted <= 0` is the only
  correct signal, and it is uniform across all eight statements.

- **`Shomei.Postgres.Maintenance` needs a progress guarantee that the naive predicate lacks.**
  Selecting dead sessions with `LIMIT $2` and deleting their tokens can pick a batch of sessions
  that have *already* had their tokens swept, delete zero rows, and terminate the loop while
  other dead sessions still hold tokens (there is no `ORDER BY`, so the same tokenless sessions
  can be returned every time). The statement therefore carries an
  `AND EXISTS (SELECT 1 FROM shomei_refresh_tokens rt2 WHERE rt2.session_id = s.session_id)`
  guard, which makes every non-terminal batch delete at least one row.

- **An index-usage demonstration is only meaningful at realistic selectivity, and this is easy
  to fake accidentally.** The first `EXPLAIN` run seeded 20 000 rows per table with 90% of them
  expired, and every sweep predicate came back `Seq Scan` — *correctly*, because a predicate
  matching 18 000 of 20 000 rows should not use an index. That is not the state a sweeper runs
  in: it runs hourly, so only a small minority of rows are newly sweepable. Reseeding 50 000
  rows with ~2% expired produced index scans everywhere. Anyone re-running this validation must
  seed a realistic expired *fraction*, not a realistic row count, or they will "discover" that
  the indexes they just added are useless.

- **`cabal run shomei-server` does not work** (this plan's M3 Concrete Steps specify it). The
  `shomei-server` package contains two executables, so the target is ambiguous:

```text
Error: [Cabal-7070]
The run command is for running a single executable at once. The target 'shomei-server' refers to
the package shomei-server-0.1.0.0 which includes
- executables: shomei-admin and shomei-server
```

  Use `cabal run shomei-server:exe:shomei-server` (and `…:exe:shomei-admin`).

- **Record dot access on a type whose fields are shared with another record needs the fields in
  scope.** `report.refreshTokensDeleted` in the admin test failed with `No instance for HasField
  "refreshTokensDeleted" SweepReport` until `SweepReport (..)` was imported (importing the type
  alone is not enough). Worth knowing before concluding, as an earlier plan did for
  `WebAuthnConfig`, that `HasField` is "unreliable under `DuplicateRecordFields`" — in this case
  it simply needed the import.

- **One unreproduced transient failure of `shomei-core-test`.** A single `cabal test all -j1
  --test-options="-j1"` run reported `Test suite shomei-core-test: FAIL` and (as `cabal test`
  halts on first failure) stopped there. It did not reproduce: two subsequent full runs exited 0
  with all twelve suites passing, and five isolated runs of `shomei-core-test` passed all 133
  tests. The failing output was not captured, so the cause is unknown; `shomei-core` is a pure
  package with no database, so this is *not* the ephemeral-PostgreSQL flakiness MasterPlan 6
  documents. Recorded rather than dismissed, in case a later plan sees it again.


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

- Decision: `deadSessionTokensStmt` batches by **session** (`WHERE rt.session_id IN (SELECT
  s.session_id … LIMIT $2)`), not by row via `ctid`, and the drain loop terminates on
  "zero rows deleted" rather than "fewer than `batchSize` rows deleted".
  Rationale: The row-bounded `ctid` shape this plan originally specified violates
  `shomei_refresh_tokens.parent_token_id`'s self-referencing `NO ACTION` foreign key whenever a
  batch boundary falls inside a rotation family (reproduction in Surprises & Discoveries).
  Batching by session makes every statement delete whole families, which is exactly the
  consistency argument the plan's Decision Log already relied on — it just does not follow from
  a `LIMIT` on rows. The consequence is that `rowsAffected` no longer relates to `batchSize`,
  so only `deleted <= 0` can terminate the loop. `batchSize` accordingly means "sessions per
  statement" for this one statement and "rows per statement" for the other seven; this is
  documented on the field.
  Date: 2026-07-09

- Decision: Add `RecordWildCards` to `shomei-postgres`'s `default-extensions` rather than
  spelling out all eight `SweepReport` fields at the construction site.
  Rationale: `sweepOnce` binds each count to a variable named exactly after its field, so
  `SweepReport {..}` is both shorter and harder to get wrong than a positional-looking list of
  eight `field = variable` lines, where a transposed pair would typecheck silently. Confirmed
  with the repository owner during implementation.
  Date: 2026-07-09

- Decision: The sweeper deliberately does **not** delete `shomei_account_lockouts` rows whose
  `locked_until` is NULL.
  Rationale: Those rows carry the running `failed_count` for an account that is not currently
  locked; deleting one resets a brute-force counter mid-attack. They are bounded by the number
  of accounts that have ever failed a login (and `clearAccountLockout` removes one on every
  successful login), so they are not a growth risk. Only elapsed locks are swept.
  Date: 2026-07-09

- Decision: **Do not** create `shomei_refresh_tokens_expires_at_idx`, despite this plan's
  original M1 index list naming it.
  Rationale: The plan's own Decision Log (above) settles that refresh tokens are swept via
  their parent session and *never* by their own `expires_at`. Grepping every `preparable`
  statement in `shomei-postgres/src` confirms `shomei_refresh_tokens.expires_at` appears only
  in INSERT column lists and SELECT projections — never in a `WHERE` predicate. The index
  would therefore have zero readers while adding write amplification to the single hottest
  write path in the system (one INSERT per token refresh). Creating it would commit exactly
  the sin this same migration cites when dropping the four dead `status` indexes.
  Date: 2026-07-09

- Decision: **Add** a partial index `shomei_sessions_revoked_at_idx ON shomei_sessions
  (revoked_at) WHERE status = 'revoked'`, which the original M1 index list omitted.
  Rationale: The session sweep predicate is a disjunction — `expires_at <= $1 OR (status =
  'revoked' AND revoked_at <= $1)`. A single index on `expires_at` cannot serve an `OR`; with
  only that index PostgreSQL must sequential-scan `shomei_sessions`, so this plan's own
  Validation step 2 ("the plan must show an index scan … for sessions") was unsatisfiable as
  originally specified. Indexing each branch lets the planner combine them with a `BitmapOr`.
  The index is partial because `revoked_at` is non-NULL only for revoked rows, which keeps it
  small — revoked sessions are the rare case. The second branch is load-bearing rather than
  redundant: a session revoked long ago can still carry a far-future `expires_at`, and only
  the `revoked_at` branch sweeps it promptly.
  Date: 2026-07-09

- Decision: Sweep configuration lives in `ServerSettings`
  (`shomei-server/src/Shomei/Server/Config.hs`), not core `ShomeiConfig`.
  Rationale: Same reasoning as plan 33's pool settings: retention is a deployment/storage
  concern with no domain meaning; `ShomeiConfig` stays infrastructure-free. Fields are
  append-only per MasterPlan 6's Integration Points (plans 33 and 35 add their own fields to
  the same records).
  Date: 2026-07-07

- Decision: `SHOMEI_AUTH_EVENT_RETENTION_DAYS=0` (or negative) means "retain forever", not
  "delete everything".
  Rationale: `authEventRetentionDays` is a `Maybe Int` whose `Nothing` means forever, and an
  environment variable cannot spell `Nothing`. Without this rule an operator who set a window in
  a Dhall file could never turn it back off from the environment. Choosing the *other* reading
  of `0` — "keep zero days of history" — would make a plausible typo irreversibly destroy the
  audit trail. Pinned by a config test.
  Date: 2026-07-09

- Decision: `supervisedLoop` re-throws asynchronous exceptions (anything wrapping
  `SomeAsyncException`, which covers `ThreadKilled` and `async`'s `AsyncCancelled`) instead of
  catching them as failed cycles.
  Rationale: A loop that catches everything is unkillable — `killThread` would be absorbed as a
  crash, backed off, and retried forever, hanging process shutdown. Pinned by the test
  `an async exception stops the loop`, which fails if someone later "simplifies" the handler.
  Date: 2026-07-09

- Decision: Export `supervisedLoopMicros` and test the supervision behavior with unit tests,
  instead of the manual sabotage/kill-test this plan's Validation section specified.
  Rationale: The production backoff (5 s → 300 s) makes a real-time test impractical, so the
  planned validation was a one-time manual ritual that would never run again. Parameterizing the
  durations lets the same code path be asserted in 0.1 s, on every `cabal test`, forever. The
  interval and backoff constants remain baked into the public `supervisedLoop`.
  Date: 2026-07-09

- Decision: Migrate the pre-existing signing-key reload thread onto `supervisedLoop` in this
  plan, rather than leaving it for plan 29.
  Rationale: The TODO comment in `Shomei.Server.Boot.installKeyReload` explicitly asked for it
  once this plan landed the idiom, and having two consumers proves the abstraction is general
  rather than a sweeper-shaped hole. Behavior change: the first reload now happens immediately at
  boot instead of after one interval. It is idempotent and `reloadKeys` keeps the last good
  material on failure, so this is harmless.
  Date: 2026-07-09

- Decision: Measure sweep-cycle duration with `GHC.Clock.getMonotonicTimeNSec`, while the sweep
  cutoff still comes from `getCurrentTime`.
  Rationale: Wall-clock time decides which rows are expired, but subtracting two wall-clock
  readings to get an elapsed duration is wrong across an NTP step and can log a negative
  `duration_ms`. The monotonic clock cannot go backwards. (It also avoids the float noise
  `realToFrac` on a `NominalDiffTime` produced: `5.244000000000001`.)
  Date: 2026-07-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-07-09).** Shōmei deletes data for the first time. The purpose stated at the top
of this plan — "an operator can see rows disappear" — is met by both triggers.

The server's background sweeper, run against a dev database seeded with a dead session, its
three-token rotation family, and an expired ceremony (`SHOMEI_SWEEP_INTERVAL_SECONDS=5`):

```text
[shomei] sweeper: every 5s, audit retention disabled (retain forever)
[shomei] listening on :8099
{"auth_events":0,"ceremonies":1,"duration_ms":48.302,"level":"info","lockouts":0,"login_attempts":0,"msg":"sweep","refresh_tokens":3,"reset_tokens":1,"sessions":1,"verification_tokens":1}
{"auth_events":0,"ceremonies":0,"duration_ms":5.244,"level":"info","lockouts":0,"login_attempts":0,"msg":"sweep","refresh_tokens":0,"reset_tokens":0,"sessions":0,"verification_tokens":0}
```

The first cycle removes exactly the graced-out rows; the second is a no-op, which is the
idempotence property the whole design rests on. The CLI trigger:

```text
$ DATABASE_URL=… shomei-admin sweep
refresh_tokens:      0
sessions:            0
verification_tokens: 0
reset_tokens:        0
ceremonies:          0
lockouts:            0
login_attempts:      0
auth_events:         0 (retention disabled)
$ echo $?
0
```

and with PostgreSQL unreachable it prints the usage error and exits 1, as specified.

**Index usage.** Against a throwaway migrated database with 50 000 rows per table and ~2% past
their cutoff (see Surprises for why the fraction, not the count, is what matters):

```text
-- verification tokens
Limit  (cost=0.29..201.91 rows=1000 width=6)
  ->  Index Scan using shomei_email_verification_tokens_expires_at_idx on shomei_email_verification_tokens
        Index Cond: (expires_at <= (now() - '7 days'::interval))

-- login attempts
Limit  (cost=0.29..176.36 rows=992 width=6)
  ->  Index Scan using shomei_login_attempts_occurred_at_idx on shomei_login_attempts
        Index Cond: (occurred_at <= (now() - '90 days'::interval))

-- audit keyset pagination
Limit  (cost=0.29..2.05 rows=50 width=24)
  ->  Index Only Scan using shomei_auth_events_created_event_idx on shomei_auth_events
```

The sessions sweep, whose `OR` predicate motivated the extra partial index, plans as intended:

```text
Bitmap Heap Scan on shomei_sessions s2
  Recheck Cond: ((expires_at <= …) OR ((revoked_at <= …) AND (status = 'revoked')))
  ->  BitmapOr
        ->  Bitmap Index Scan on shomei_sessions_expires_at_idx
        ->  Bitmap Index Scan on shomei_sessions_revoked_at_idx
```

Dropping `shomei_sessions_revoked_at_idx` and re-planning the same query collapses it to a
`Seq Scan on shomei_sessions`, which is the direct evidence that the index this plan added
beyond its original list is load-bearing rather than defensive.

**What was wrong with the plan as written.** Three of its specified artifacts were incorrect and
would have shipped bugs: the refresh-token batch SQL violates a foreign key under load; the
drain loop's termination condition cannot work with that statement; and the index list both
included a dead index and omitted one its own acceptance criteria required. All three are
recorded in Surprises & Discoveries with reproductions, and the plan body has been corrected so
a future reader implementing from it gets the right thing. The lesson worth carrying: a plan's
SQL is a hypothesis, and `parent_token_id`'s `NO ACTION` self-reference is the kind of schema
detail that invalidates a hypothesis silently and only under load.

**Deviation from the planned validation.** Validation step 3 asked for a manual kill-test —
sabotage a cycle with `error "boom"`, watch `backoff_s` go 5 then 10, then remove the sabotage —
and for stopping PostgreSQL under a running server. Both were replaced with three deterministic
unit tests over `supervisedLoopMicros` (`shomei-server/test/Shomei/Server/SupervisorSpec.hs`),
which assert the same properties in 0.1 s and, unlike a manual test, keep asserting them.
Notably the async-exception test would fail if someone "simplified" the loop by catching
`SomeException` without re-throwing — a change that looks harmless and would make the thread
unkillable. The `Left UsageError` path (database unreachable) was exercised through
`shomei-admin sweep` against a refused connection rather than by stopping the shared dev
PostgreSQL.

**Gaps.** `config/shomei-types.dhall` is a closed record type and still does not list the new
`sweep*` keys, so a config file annotated with that schema cannot use them (the loader accepts
them regardless — every field is optional at decode time). This is pre-existing and already
documented in `docs/user/deployment.md`; widening the schema is a separate, mechanical change.
`shomei_account_lockouts` rows with a NULL `locked_until` are intentionally never swept
(Decision Log), so that table is bounded by "accounts that have ever failed a login" rather than
by a retention window.

**Handoff to plan 29.** `Shomei.Server.Supervisor.supervisedLoop` is the shared idiom this plan
owed the Security MasterPlan's key-reload thread. It is already consumed by two call sites —
`installSweeper` and `installKeyReload`, the latter migrated off its bespoke `forever`/`catch`
loop as the TODO in its comment requested. Note that `supervisedLoop` runs its first cycle
immediately rather than sleeping first, which changed key-reload's behavior to perform one
(idempotent) reload right after `bootstrapKeys`.


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

Scaffold it (the recipe stamps the current UTC timestamp; the slug is **positional**, not
`name=<slug>`):

```bash
just new-migration sweeper-indexes-and-retention
```

Fill the generated file in `shomei-migrations/sql-migrations/` with the contents now committed
at `shomei-migrations/sql-migrations/2026-07-09-13-51-07-sweeper-indexes-and-retention.sql`:
two session indexes (`expires_at`, plus a partial `revoked_at WHERE status = 'revoked'` so the
sweep's `OR` predicate can be served by a `BitmapOr` instead of a sequential scan), an
`expires_at` index on each of the two one-time-token tables, an `occurred_at` index on
`shomei_login_attempts`, the composite `shomei_auth_events (created_at DESC, event_id DESC)`,
and five `DROP INDEX IF EXISTS` statements. See the two 2026-07-09 Decision Log entries for why
there is deliberately **no** `shomei_refresh_tokens_expires_at_idx` and why the partial
`revoked_at` index was added.

The login-attempts sweep predicate is age-only (`occurred_at <= cutoff`), which the existing
partial indexes (they lead on `account_key`/`client_ip`) cannot serve — hence the plain
`occurred_at` index.

Then apply and verify. **Important:** the `migrate` recipe's `touch` of the `.cabal` does *not*
force the compile-time `embedDir` splice to re-run (cabal hashes content, not mtime). Append a
one-line comment to the block above `embeddedFiles` in
`shomei-migrations/src/Shomei/Migrations.hs` — that is the repository's actual convention, and
without it `just migrate` reports `[0 found]` and silently applies nothing.

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
repeat-until-empty-batch loop per table: execute the batched delete with the table's cutoff,
read the affected-row count (`D.rowsAffected` decoder), add it to the report, and repeat until
the count is zero. (The terminator is *zero rows*, not *fewer than `batchSize` rows*: statement 1
below bounds itself by sessions, so a one-session batch can delete several token rows.) Each
batch is its own `Pool.use` session — deliberately *not* one big transaction, so locks stay
short and a crash mid-sweep loses nothing (deletes are idempotent). The statements, all
`preparable` multiline strings in this module (house style: schema-qualified, `$1` = cutoff
timestamp, `$2` = batch limit):

1. Dead-session refresh tokens (cutoff = now − `deadSessionGraceDays`). This batches by
   **session**, never by row: `parent_token_id` is a self-referencing foreign key with no
   `ON DELETE` action, checked at end of statement, so a row-bounded `LIMIT` batch that split a
   rotation family would raise a foreign-key violation (see Surprises & Discoveries for the
   reproduction). The `EXISTS` guard keeps every non-terminal batch deleting at least one row,
   so the drain loop cannot stall on already-swept sessions:

```sql
DELETE FROM shomei.shomei_refresh_tokens rt
WHERE rt.session_id IN (
  SELECT s.session_id
  FROM shomei.shomei_sessions s
  WHERE (s.expires_at <= $1 OR (s.status = 'revoked' AND s.revoked_at <= $1))
    AND EXISTS (
      SELECT 1 FROM shomei.shomei_refresh_tokens rt2
      WHERE rt2.session_id = s.session_id)
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

Add integration tests to the existing `shomei-postgres` test suite
(`shomei-postgres/test/Main.hs` pattern: `withShomeiMigratedDatabase`, `acquirePool 4 …`, plus
a new `execSql` helper wrapping `Hasql.Session.script` for multi-statement seeding). The shared
fixture (`seedSweepFixture`) puts one row on each side of every cutoff: two users; one session
expired 40 days ago carrying a three-generation rotation family; one session revoked 40 days
ago but with a far-future `expires_at` (this exercises the `revoked_at` branch of the sweep's
OR predicate, and the partial index added for it); one live session with 2 tokens; expired +
fresh verification/reset tokens; ceremonies expired 2 h ago, 30 min ago, and not yet; lockouts
elapsed 10 days ago, elapsed 1 day ago, and never locked; login attempts at 100 and 10 days;
auth events at 400 days and today.

Run `sweepOnce` with defaults and assert the report reads exactly `refreshTokensDeleted = 4,
sessionsDeleted = 2, verificationTokensDeleted = 1, resetTokensDeleted = 1, ceremoniesDeleted =
1, lockoutsDeleted = 1, loginAttemptsDeleted = 1, authEventsDeleted = 0`, and that the survivors
are still present (count queries, including that users are never swept). Run `sweepOnce` again
and assert `emptySweepReport` (idempotence). Run once more with `authEventRetentionDays = Just
365` and assert exactly the 400-day event went. Test the batch loop: seed 25 expired ceremonies,
`batchSize = 10`, assert `ceremoniesDeleted = 25` (three passes). Finally, pin the foreign-key
hazard: two dead sessions with rotation families of 3 and 2 tokens, `batchSize = 1`, assert
`refreshTokensDeleted = 5` and `sessionsDeleted = 2` — which only holds because the statement
batches by session.

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
just new-migration sweeper-indexes-and-retention
"$EDITOR" shomei-migrations/sql-migrations/*-sweeper-indexes-and-retention.sql
# Append a comment line above `embeddedFiles` so the embedDir splice recompiles:
"$EDITOR" shomei-migrations/src/Shomei/Migrations.hs
just migrate
psql -d "$PGDATABASE" -tc "SELECT indexname FROM pg_indexes WHERE schemaname='shomei' AND indexname LIKE '%expires_at%'"
```

Expected: three `…_expires_at_idx` names (sessions, verification tokens, reset tokens) plus the
pre-existing ceremonies one; and

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
# M3 — live check with a short interval. Note the qualified target: the shomei-server
# package holds two executables, so `cabal run shomei-server` is ambiguous and fails.
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
SHOMEI_SWEEP_INTERVAL_SECONDS=5 cabal run shomei-server:exe:shomei-server
```

Expected stderr within ~5 s (illustrative counts):

```json
{"level":"info","msg":"sweep","refresh_tokens":3,"sessions":1,"verification_tokens":0,"reset_tokens":0,"ceremonies":1,"lockouts":0,"login_attempts":0,"auth_events":0,"duration_ms":41}
```

```bash
# M4
DATABASE_URL="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shomei-server:exe:shomei-admin -- sweep
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

- Migration `shomei-migrations/sql-migrations/2026-07-09-13-51-07-sweeper-indexes-and-retention.sql`
  with the index set in M1: five expiry-family creates (`shomei_sessions_expires_at_idx`, the
  partial `shomei_sessions_revoked_at_idx`, `shomei_email_verification_tokens_expires_at_idx`,
  `shomei_password_reset_tokens_expires_at_idx`, `shomei_login_attempts_occurred_at_idx`), one
  composite audit create, and five drops.
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
