---
id: 33
slug: transactional-auth-workflows-and-configurable-connection-pool
title: "Transactional Auth Workflows and Configurable Connection Pool"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/6-operational-and-performance-hardening.md"
intention: intention_01kx2hqr6beeashgwvg5zwxtgc
---

# Transactional Auth Workflows and Configurable Connection Pool

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-1** of MasterPlan 6
(`docs/masterplans/6-operational-and-performance-hardening.md`, "Operational and Performance
Hardening"). It cuts the number of PostgreSQL round-trips a login and a token refresh cost,
makes the multi-statement write tails of those workflows atomic (all-or-nothing) by running
them inside real database transactions, stops issuing a pointless `DELETE` on every successful
login, and makes the connection-pool size and acquisition timeout operator-configurable
instead of hardcoded.


## Purpose / Big Picture

Today every database operation Shōmei performs is a separate checkout from the `hasql`
connection pool: one pool checkout, one SQL statement, one check-in. A single successful
password login issues **eleven** sequential round-trips (counted below, in "Context and
Orientation"), a token refresh issues **five**, and the pool they all contend for is hardcoded
to ten connections in `shomei-server/src/Shomei/Server/Boot.hs`. Beyond latency, the write
tails are not atomic: if the process dies between "insert session" and "insert refresh token",
the database holds a session with no token — junk data that nothing can ever use.

After this plan, an operator gains three things they can observe directly. First, a successful
login costs **seven** database round-trips and a refresh costs **three**, and the new
`shomei-server` test suite proves those exact counts with a counting `Database` interpreter
(the test fails if a future change silently adds a round-trip). Second, the session+token+audit
write tails of signup, login, MFA completion, and refresh each execute inside one
`BEGIN … COMMIT` transaction, so a crash mid-tail leaves no partial state — demonstrable with
PostgreSQL statement logging showing `BEGIN`/`COMMIT` around the tail. Third, the pool is
tunable: `SHOMEI_DB_POOL_SIZE=25` (or the Dhall field `dbPoolSize`) boots a 25-connection
pool, and `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` bounds how long a request waits for a free
connection; both are logged at boot so the operator can confirm the values took effect.

One thing this plan deliberately does **not** change: the *shape* of the statement that marks
a refresh token used. That statement is owned by the Security MasterPlan's EP-1
(`docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`), which
converts it to a compare-and-swap. The integration contract is restated in full under
"Context and Orientation" below.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `acquirePool` in `shomei-postgres/src/Shomei/Postgres/Pool.hs` extended to accept an
      acquisition timeout; signature change propagated to all seven call sites (2026-07-08).
- [x] M1: `ServerSettings` in `shomei-server/src/Shomei/Server/Config.hs` gains
      `serverDbPoolSize` and `serverDbPoolAcquisitionTimeoutMs` with defaults 10 / 10000
      (2026-07-08).
- [x] M1: `FileConfig` gains optional `dbPoolSize` / `dbPoolAcquisitionTimeoutMs` Dhall fields;
      env overrides `SHOMEI_DB_POOL_SIZE` / `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` wired in
      `overlayFromEnvBoth`, with non-positive values rejected there (2026-07-08).
- [x] M1: `Shomei.Server.Boot.buildEnv` uses the configured values; boot log line prints them
      (2026-07-08).
- [x] M1: `docs/user/deployment.md` documents both knobs, their defaults, the Dhall fields, and
      a pool-sizing note (2026-07-08).
- [x] M1: `cabal build all` green; `cabal test shomei-server-config-test` green with new cases
      for the Dhall fields, the env overrides, the defaults, and the non-positive rejection
      (2026-07-08).
- [ ] M1 (remaining): full `cabal test all` against a live database, and the boot transcript
      showing the configured pool values, captured into Outcomes.
- [ ] M2: `clearAccountLockout` call in `shomei-core/src/Shomei/Workflow.hs` made conditional
      on a lockout row actually existing (uses the `getAccountLockout` result already read).
- [ ] M2: workflow test asserting no `ClearAccountLockout` op is issued on a lockout-free login.
- [ ] M3: new core effect `Shomei.Effect.AuthUnitOfWork` with `PersistNewSession` and
      `RotateRefreshToken` operations; smart constructors exported.
- [ ] M3: PostgreSQL interpreter `Shomei.Postgres.AuthUnitOfWork` running each operation as one
      `runTransaction` (first-ever caller of `Database.RunTransaction`).
- [ ] M3: `Shomei.Workflow.Session.issueSession`, the signup tail in `Shomei.Workflow.signup`,
      and the refresh tail in `Shomei.Workflow.refresh` rewritten onto the new operations.
- [ ] M3: effect added to `Shomei.Servant.Seam.AppEffects` and
      `Shomei.Server.App.AppEffects`/`runAppIO`; all in-memory/test interpreters updated.
- [ ] M4: counting `Database` interpreter test proving login = 7 round-trips, refresh = 3.
- [ ] M4: statement-log transcript showing `BEGIN`/`COMMIT` around the login tail.
- [ ] `nix fmt` clean; Decision Log, Surprises, Outcomes updated; MasterPlan 6 Progress and
      registry row updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The Security MasterPlan's EP-1 (plan 28) has already landed.** This plan was written for a
  world where the mark-used statement might still be an unconditional `UPDATE` with a
  `D.noResult` decoder, and instructed the implementer to change only its decoder if so. That
  branch is moot: `markUsedStmt` in
  `shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs` is already the compare-and-swap,
  and the port operation already returns `Bool`:

  ```haskell
  MarkRefreshTokenUsed :: RefreshTokenId -> UTCTime -> RefreshTokenStore m Bool
  ```

  ```sql
  UPDATE shomei.shomei_refresh_tokens
  SET status = 'used', used_at = $2
  WHERE refresh_token_id = $1
    AND status = 'active'
  RETURNING refresh_token_id
  ```

  `Shomei.Workflow.refresh` already branches on `won <- markRefreshTokenUsed …` and takes the
  reuse path when it loses the race. Consequence for M3: the rotation transaction lifts
  `markUsedStmt` **verbatim** (statement text and `Maybe UUID` decoder untouched) via
  `Hasql.Transaction.statement`, and `RotationConflict` is exactly `Nothing` from that decoder.
  No decoder change, no re-read. The cross-MasterPlan boundary is honored by construction.

- **`shomei-core`'s in-memory `World` already models the CAS** (`casWorld` in
  `shomei-core/src/Shomei/Effect/InMemory.hs`), so the in-memory `AuthUnitOfWork` interpreter
  M3 adds can compose the existing store interpreters without inventing new atomicity.

- **A concurrent process committed and pushed this plan's M1 code under another plan's
  message.** Commit `cd7deec` ("docs: propagate the new transport and token shapes to the
  remaining user guides"), which carries MasterPlan 5's trailers and intention
  `intention_01kx25bwnqecss3zgjtj70zpce`, swept the uncommitted M1 working tree into itself:
  `Pool.hs`, `Boot.hs`, `Config.hs`, all `acquirePool` call sites, and this plan's own
  frontmatter. It was pushed to `origin/master` before the mix-up was noticed. Nothing was
  lost — the committed content matches what M1 intended — and per the operator's decision the
  history was left alone rather than rewritten (a force-push over a published commit). The
  remaining M1 work (the `ConfigSpec` cases and `docs/user/deployment.md`) is committed
  separately with this plan's correct trailers. The lesson for later milestones: commit each
  milestone promptly rather than accumulating a large uncommitted tree.

- **`nix fmt` formats the whole repository, not just changed files.** Running it after the M1
  edits reordered imports in a dozen untouched modules (`shomei-servant/*`,
  `Shomei/Server/App.hs`, `Shomei/Workflow/Session.hs`) that had drifted from the formatter's
  canonical output. Those reverts were discarded to keep this plan's diff focused; expect the
  same drift to reappear on any future `nix fmt` and revert it the same way.


## Decision Log

Record every decision made while working on the plan.

- Decision: Batch only the **write tails** (session + refresh token + audit events; mark-used +
  child token + audit event) into transactions, and leave the read-heavy front half of login
  (IP-failure count, lockout read, credential read, user read, passkey count) as individual
  sessions.
  Rationale: The tail is where atomicity matters (partial writes are junk data) and where the
  statements are unconditionally sequential, so it is the highest-value, lowest-risk cut: 11 →
  7 round-trips for login, 5 → 3 for refresh. The front half is a chain of *conditional* reads
  whose results steer control flow in the pure workflow; folding them into one transaction
  would force domain branching logic into SQL or into a transaction-scoped interpreter, a far
  more invasive change for a smaller win. It can be a follow-up plan if profiles justify it.
  Date: 2026-07-07

- Decision: Introduce a **new core effect** `Shomei.Effect.AuthUnitOfWork` carrying the two
  combined operations, rather than (a) adding cross-store operations to `SessionStore` /
  `RefreshTokenStore`, or (b) building a generic "transactional interpreter" that replays an
  arbitrary workflow segment inside one `hasql` session.
  Rationale: (a) would make `SessionStore` insert refresh tokens and audit events — a layering
  smell that also breaks the existing one-effect-one-table interpreters and their tests.
  (b) is architecturally seductive but unsound with `effectful` dynamic dispatch: interpreters
  are installed per-effect at assembly time and each `runSession` call checks out its own
  connection; making a *segment* of a workflow share one connection would require re-plumbing
  every store interpreter to read an ambient "current transaction" — a large, risky rewrite.
  A dedicated unit-of-work port is the incremental option: the workflows call one new
  operation, the PostgreSQL interpreter is the single place that composes statements into a
  `Transaction`, and every existing store interpreter is untouched.
  Date: 2026-07-07

- Decision: The `PersistNewSession` operation takes an **event-builder function**
  (`SessionId -> [AuthEvent]`) instead of a list of events.
  Rationale: The session id is generated inside the interpreter (as `CreateSession` does
  today, via `genSessionId`), but the audit events (`SessionStarted`, `LoginSucceeded`,
  `UserRegistered`) must carry that id. Passing a builder lets each caller (signup publishes
  `UserRegistered` + `SessionStarted`; login/MFA publish `LoginSucceeded` + `SessionStarted`)
  keep authoring its own events in the workflow layer while the interpreter fills in the id.
  Date: 2026-07-07

- Decision: Make `clearAccountLockout` conditional by **reusing the `getAccountLockout` read
  that `login` already performs**, not by converting the `DELETE` into a conditional statement.
  Rationale: `Shomei.Workflow.login` reads the lockout row near the top (when rate limiting is
  enabled) and then unconditionally issues `ClearAccountLockout` on success — a wasted DELETE
  round-trip on virtually every login, since lockouts are rare. Threading the already-fetched
  `Maybe AccountLockout` to the success path and deleting only when it is `Just` removes the
  round-trip with zero new SQL. When rate limiting is disabled no lockout can exist (lockouts
  are only ever written by the rate-limited failure path), so skipping the clear entirely in
  that branch is also safe.
  Date: 2026-07-07

- Decision: Pool size and acquisition timeout live in `ServerSettings`
  (`shomei-server/src/Shomei/Server/Config.hs`), not in the core `ShomeiConfig`.
  Rationale: `ShomeiConfig` is deliberately transport- and infrastructure-agnostic (it has no
  `hasql` types and no knowledge that PostgreSQL exists); the pool is a server deployment
  concern exactly like the listen port and connection string, which already live in
  `ServerSettings`. Defaults preserve today's behavior (size 10; hasql-pool's own 10-second
  acquisition default, expressed as 10000 ms).
  Date: 2026-07-07

- Decision: Measure round-trips with a **counting `Database` interpreter wrapper in the test
  suite** as the enforced acceptance, and use PostgreSQL `log_statement=all` only as a
  human-readable transcript for the plan record.
  Rationale: A test that wraps `runDatabasePool` and counts `RunSession`/`RunTransaction`
  dispatches is deterministic, runs in CI via `cabal test all`, and pins the exact budget
  (login = 7, refresh = 3) so regressions fail loudly. Statement logs prove the `BEGIN`/
  `COMMIT` wrapping to a human but are environment-dependent and unsuited to assertion.
  Date: 2026-07-07

- Decision: Restate and honor the cross-MasterPlan boundary on the mark-used statement: this
  plan **wraps** the `UPDATE` that marks a refresh token used inside the rotation transaction
  **without changing its WHERE clause or RETURNING shape**, and treats "0 rows updated" as the
  token-reuse signal without re-reading the row.
  Rationale: `docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`
  (Security MasterPlan EP-1) owns the compare-and-swap semantics
  (`UPDATE … SET status='used' WHERE … AND status='active' RETURNING …`). Two plans must not
  both own one statement. Whichever plan lands second preserves the other's work: if 28 has
  landed, this plan moves its CAS statement verbatim into the transaction; if 28 has not
  landed, this plan uses the current unconditional `UPDATE` (with a rows-affected decoder) and
  28 later tightens the WHERE clause in place.
  Date: 2026-07-07


- Decision: Validate the two pool knobs **once, after the env overlay** in `overlayFromEnvBoth`,
  rather than separately in `baseFromFile` and in the env readers.
  Rationale: The plan called for rejecting non-positive values but did not say where. A single
  post-overlay check covers every layer that can supply a value (default, Dhall file, env) with
  one code path, so a bad Dhall `dbPoolSize` fails the boot exactly as a bad
  `SHOMEI_DB_POOL_SIZE` does. The error names both the env var and the Dhall field, since the
  loader cannot tell which layer won. The acquisition timeout is rejected at zero as well as
  below it: a zero timeout fails every checkout, so it is not a survivable "disable" value.
  Date: 2026-07-08

- Decision: Exercise the new `ConfigSpec` cases **inline, at the end of the existing sequential
  test case**, instead of adding them as sibling `testCase`s in a `testGroup`.
  Rationale: Every one of these assertions mutates process-wide environment variables via
  `setEnv`/`unsetEnv`, and tasty runs the members of a test group concurrently by default. As
  siblings they would race — `poolRejectsNonPositive` setting `SHOMEI_DB_POOL_SIZE=0` while
  `poolDefaults` asserts the default is 10. Sequencing them inside one test case makes the
  ordering explicit and total.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**M1 (configurable pool) — complete.** `acquirePool` now takes an acquisition timeout;
`ServerSettings` carries `serverDbPoolSize` / `serverDbPoolAcquisitionTimeoutMs`, sourced from
defaults (10 / 10000 ms, reproducing the previously hardcoded behavior), then the Dhall fields
`dbPoolSize` / `dbPoolAcquisitionTimeoutMs`, then `SHOMEI_DB_POOL_SIZE` /
`SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS`. A non-positive value at any layer fails the boot with
an error naming both the variable and the Dhall field. `buildEnv` logs the values it acquired
the pool with. Evidence:

```text
$ cabal test shomei-server-config-test
Dhall file is loaded and env vars override it: OK (0.14s)
All 1 tests passed (0.14s)
```

The test case asserts the Dhall file's `dbPoolSize = 25` / `dbPoolAcquisitionTimeoutMs = 2500`
beat the defaults, that `SHOMEI_DB_POOL_SIZE=33` / `…TIMEOUT_MS=2000` then beat the file, that
an unset environment with no file yields 10 / 10000, and that `SHOMEI_DB_POOL_SIZE=0` and
`SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS=-1` each raise a `userError` naming the offending
variable.

Still outstanding for M1: the live boot transcript and a full `cabal test all` against a
running PostgreSQL, both of which need the dev database up. Milestones M2–M4 remain.


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Haskell Cabal
workspace (GHC 9.12.4, language edition GHC2024) building an authentication toolkit. The
packages relevant here:

- `shomei-core` — the transport-agnostic domain: workflows and *ports*. A **port** is an
  `effectful` *dynamic effect*: a GADT of operations (e.g. `CreateSession`) plus `send`-based
  smart constructors, given meaning later by an *interpreter*. Workflows like
  `Shomei.Workflow.login` are pure orchestrations over ports; they contain no SQL.
- `shomei-postgres` — the PostgreSQL interpreters. Each store port has one interpreter module
  (e.g. `Shomei.Postgres.SessionStore`) that turns operations into prepared `hasql` statements
  issued through the `Database` effect.
- `shomei-server` — the standalone warp server: config loading
  (`src/Shomei/Server/Config.hs`), the effect-stack assembly (`src/Shomei/Server/App.hs`), and
  boot (`src/Shomei/Server/Boot.hs`).
- `shomei-servant` — the Servant API and the *seam*: `Shomei.Servant.Seam.AppEffects` is the
  smaller effect list handlers are written against; `Shomei.Server.App.AppEffects` is the
  larger server list; `Shomei.Server.Boot.seamEnv` bridges them with `inject`.

Build and test everything from the repository root inside the Nix dev shell: `nix develop`
(or automatic via direnv), then `cabal build all` and `cabal test all`. The dev PostgreSQL
comes up with the process-compose stack; `just create-database` creates and migrates the dev
database idempotently. Format with `nix fmt`.

### The Database effect and the unused transaction door

`shomei-postgres/src/Shomei/Postgres/Database.hs` defines the whole database seam:

```haskell
data Database :: Effect where
  RunSession :: Session a -> Database m (Either UsageError a)
  RunTransaction :: Transaction a -> Database m (Either UsageError a)

runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a -> Eff es a
runDatabasePool pool = interpret_ \case
  RunSession sess -> liftIO (Pool.use pool sess)
  RunTransaction t -> liftIO (Pool.use pool (Tx.transaction Tx.ReadCommitted Tx.Write t))
```

`RunTransaction` already exists and already runs a `hasql-transaction` `Transaction` (read
committed, read-write, with automatic retry on serialization failures) — but a repo-wide
`grep -rn runTransaction` finds **zero call sites**. Every interpreter uses `runSession`, so
every single statement is its own `Pool.use` checkout. `Hasql.Transaction.statement ::
params -> Statement params a -> Transaction a` lifts an existing prepared `Statement` into a
`Transaction`, so composing the existing statements into one transaction requires no SQL
changes at all.

### Counting today's round-trips

A successful password login (`Shomei.Workflow.login`, `shomei-core/src/Shomei/Workflow.hs`
lines ~192–234, with its tail `issueSession` in
`shomei-core/src/Shomei/Workflow/Session.hs` lines ~81–107) issues, in order, with rate
limiting enabled (the default):

1. `countRecentFailuresByIp` — per-IP failure count (`LoginAttemptStore`).
2. `getAccountLockout` — lockout read (`LoginAttemptStore`).
3. `findPasswordCredentialByLoginId` — credential read (`CredentialStore`).
4. `findUserById` — user read (`UserStore`).
5. `recordLoginAttempt` — success-attempt insert (`LoginAttemptStore`).
6. `clearAccountLockout` — unconditional `DELETE FROM shomei.shomei_account_lockouts`
   (`Workflow.hs` line ~221), even though step 2 almost always found nothing.
7. `countPasskeysByUser` — MFA gate (`PasskeyStore`).
8. `createSession` — session insert (`SessionStore`).
9. `createRefreshToken` — refresh-token insert (`RefreshTokenStore`).
10. `publishAuthEvent LoginSucceeded` — event insert (`AuthEventPublisher`).
11. `publishAuthEvent SessionStarted` — event insert.

Eleven pool checkouts, strictly sequential (password verification and access-token signing are
CPU-only and cost no round-trip). A refresh (`Workflow.hs` lines ~269–324) issues five:
`findRefreshTokenByHash`, `findSessionById`, `markRefreshTokenUsed`, `createRefreshToken`,
`publishAuthEvent RefreshTokenRotated`. Steps 8–11 of login (and 3–5 of refresh) are pure
write tails with no intervening decisions — the natural transaction units.

### The pool is hardcoded

`shomei-server/src/Shomei/Server/Boot.hs` line ~109, inside `buildEnv`:

```haskell
pool <- acquirePool 10 settings.serverConnStr
```

`acquirePool` (`shomei-postgres/src/Shomei/Postgres/Pool.hs`) builds a `hasql-pool` config
from only a size and a connection string. `ServerSettings`
(`shomei-server/src/Shomei/Server/Config.hs` lines ~55–58) carries only `serverPort` and
`serverConnStr`. `hasql-pool`'s `Hasql.Pool.Config` DSL already exposes
`Config.acquisitionTimeout :: DiffTime -> Setting` (defaulting to 10 seconds), so adding the
timeout is one more list element. Config loading is layered (defaults → optional Dhall file
rendered by `dhall-to-json` into the flat all-`Maybe` `FileConfig` record → `SHOMEI_*` env
vars), and each layer must gain the two new knobs.

Other `acquirePool` call sites (test harnesses and `shomei-server/app/Shomei/Admin/Env.hs`,
all `acquirePool 4 …`) keep small fixed pools; only the server boot becomes configurable.

### The integration boundary with the Security MasterPlan (restated in full)

The statement that marks a refresh token used lives in
`shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs` (`markUsedStmt`, lines ~162–171).
Today it is an unconditional `UPDATE … SET status = 'used', used_at = $2 WHERE
refresh_token_id = $1` with a `D.noResult` decoder. The Security MasterPlan's EP-1
(`docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`) owns
converting it to a compare-and-swap: `UPDATE … SET status='used' … WHERE refresh_token_id = $1
AND status='active' RETURNING …`, where "0 rows updated" *is* the concurrent-reuse signal.
This plan's contract: it may **move** that statement inside the rotation transaction and
**read its row count**, but it must not alter the statement's WHERE clause or RETURNING list,
and it must treat 0 rows updated as reuse **without issuing a re-read**. Whichever plan lands
second preserves the other's statement shape.

### House conventions (apply to every module this plan touches)

Each `.cabal` stanza uses `import: warnings, shared` (the `shared` stanza sets the default
extensions: `DuplicateRecordFields`, `OverloadedRecordDot`, `OverloadedStrings`,
`BlockArguments`, `MultilineStrings`, etc.). Records use strict fields, no prefixes, `deriving
stock (Generic, Eq, Show)`. Reading `value.field` requires importing the record type with its
fields (`import Shomei.Config (ShomeiConfig (..))`). Import `Shomei.Domain.Event` qualified
(`as Event`) — its constructors collide with other domain names. SQL statements are
`preparable` multiline strings that always schema-qualify tables as `shomei.<table>`. No new
external dependencies are needed by this plan (`hasql-transaction >= 1.0` is already a
`shomei-postgres` dependency).


## Plan of Work

Four milestones, each leaving the tree green. M1 (pool config) and M2 (conditional lockout
clear) are small and independent; M3 (the unit-of-work effect) is the core of the plan; M4
(the round-trip budget test and transcript) proves the whole.

### Milestone M1 — configurable pool size and acquisition timeout

Scope: thread two new settings from Dhall/env through `ServerSettings` into `acquirePool`.
At the end, `SHOMEI_DB_POOL_SIZE=25 SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS=2000` boots a server
whose startup log prints `pool size 25, acquisition timeout 2000ms`, and unset variables
reproduce today's behavior exactly (size 10, timeout 10000 ms).

Edit `shomei-postgres/src/Shomei/Postgres/Pool.hs`: change the signature to

```haskell
-- | Acquire a pool of @size@ connections with the given acquisition timeout (how long
-- 'Pool.use' waits for a free connection before failing with 'AcquisitionTimeoutUsageError').
acquirePool :: Int -> DiffTime -> Text -> IO Pool
acquirePool size acquisitionTimeout connStr =
  Pool.acquire
    ( Config.settings
        [ Config.staticConnectionSettings (Settings.connectionString connStr),
          Config.size size,
          Config.acquisitionTimeout acquisitionTimeout
        ]
    )
```

(`DiffTime` comes from `Data.Time`; import it.) Update every call site to pass a timeout —
the production site in `Boot.buildEnv` uses the configured value; the fixed-size harness sites
(`shomei-server/app/Shomei/Admin/Env.hs`, `shomei-server/test/Shomei/Server/E2ESpec.hs`,
`shomei-server/test/Admin/Main.hs`, `shomei-postgres/test/Main.hs`,
`examples/embedded-servant-app/test/Main.hs`, `examples/microservice-auth-stack/test/Main.hs`)
pass `10` (seconds, i.e. `10 :: DiffTime`) to preserve the library default.

Edit `shomei-server/src/Shomei/Server/Config.hs`: add `serverDbPoolSize :: !Int` and
`serverDbPoolAcquisitionTimeoutMs :: !Int` to `ServerSettings`; add optional `dbPoolSize ::
!(Maybe Int)` and `dbPoolAcquisitionTimeoutMs :: !(Maybe Int)` to `FileConfig`; default them
(10 / 10000) in `baseDefaults` and `baseFromFile`; overlay `SHOMEI_DB_POOL_SIZE` and
`SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` in `overlayFromEnvBoth` with the existing `intEnv`
helper. Reject non-positive values with `ioError` (a zero-size pool deadlocks every request;
fail the boot loudly instead).

Edit `shomei-server/src/Shomei/Server/Boot.hs` `buildEnv`: replace `acquirePool 10 …` with the
configured values (milliseconds converted via `fromIntegral ms / 1000` into `DiffTime`, or
`picosecondsToDiffTime (fromIntegral ms * 1_000_000_000)` for exactness), and extend the
existing `[shomei] listening on :PORT` stderr boot logging with a line naming both values.

Document the two knobs (env var, Dhall field, default, meaning) in the configuration section
of the user docs (`docs/user/` — the file that documents `SHOMEI_PORT` /
`PG_CONNECTION_STRING`; locate it with `grep -rn "SHOMEI_PORT" docs/user`).

Acceptance: `cabal build all` and `cabal test all` pass; the boot transcript in Concrete Steps
shows the configured values; `shomei-server/test/Shomei/Server/ConfigSpec.hs` gains cases for
the two env overrides and the non-positive rejection.

### Milestone M2 — conditional lockout clear

Scope: stop issuing `DELETE FROM shomei.shomei_account_lockouts` on every successful login.
At the end, a login with no standing lockout performs no `ClearAccountLockout` operation, and
a login that *does* clear a real lockout still works (the existing lockout-lifecycle tests
keep passing).

In `shomei-core/src/Shomei/Workflow.hs` `login`: today `mLock <- getAccountLockout
ctx.accountKey` is read inside the `when rl.rateLimitEnabled` block (line ~205) and
`clearAccountLockout ctx.accountKey` is issued unconditionally on success (line ~221). Hoist
the lockout read result out of the `when` block — bind
`mLock <- if rl.rateLimitEnabled then getAccountLockout ctx.accountKey else pure Nothing`
before the throttle checks (keeping the throttle/locked checks otherwise byte-identical) — and
replace the unconditional clear with
`when (isJust mLock) (clearAccountLockout ctx.accountKey)`. This is behavior-preserving:
lockout rows are only ever written by the rate-limited failure path, so when rate limiting is
disabled or the read found nothing there is nothing to delete. Note the row read at step 2 may
have `lockedUntil` in the past (an expired lockout that was never cleaned); `isJust` still
triggers the clear then, which is exactly the old behavior for that case.

Add a workflow-level test (in the existing `shomei-core` test suite, alongside the current
login tests) using the in-memory interpreters: run a successful login with no prior failures
and assert the recorded operation trace contains no `ClearAccountLockout`; run the existing
lock-then-succeed scenario and assert the lockout is cleared. If the in-memory
`LoginAttemptStore` interpreter does not already record an op trace, wrap it with a small
`interpose`-free recording wrapper (an `IORef [Text]` appended to inside each case) — the same
technique M4 uses for counting.

### Milestone M3 — the `AuthUnitOfWork` port and transactional tails

Scope: a new core port with two combined operations, its PostgreSQL interpreter built on
`runTransaction`, and the three workflow tails rewritten onto it. At the end, signup, login,
MFA completion, and refresh perform their write tails as single transactions, and the full
test matrix (`cabal test all`) is green.

Create `shomei-core/src/Shomei/Effect/AuthUnitOfWork.hs` (add to `shomei-core.cabal`
`exposed-modules`). The port, with a helper record for the token half (the session id is not
known to the caller — the interpreter generates it, exactly as `CreateSession` does today):

```haskell
-- | The transactional unit-of-work port: multi-table write tails that must be atomic.
-- Interpreted against PostgreSQL as ONE transaction per operation; in-memory test
-- interpreters may compose the equivalent single-store operations.
module Shomei.Effect.AuthUnitOfWork
  ( AuthUnitOfWork (..),
    NewSessionToken (..),
    RotationOutcome (..),
    persistNewSession,
    rotateRefreshToken,
  )
where

-- | The refresh-token half of a new session, sans the session id (generated inside).
data NewSessionToken = NewSessionToken
  { tokenHash :: !RefreshTokenHash,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime
  }

-- | Result of an atomic rotation. 'RotationConflict' = the mark-used UPDATE hit 0 rows,
-- i.e. a concurrent request already consumed the token (the reuse signal; never re-read).
data RotationOutcome = Rotated !PersistedRefreshToken | RotationConflict

data AuthUnitOfWork :: Effect where
  -- | Insert session + refresh token + the events built from the generated session id,
  -- atomically. Returns the persisted session and token.
  PersistNewSession ::
    NewSession -> NewSessionToken -> (SessionId -> [AuthEvent]) ->
    AuthUnitOfWork m (Session, PersistedRefreshToken)
  -- | Mark the presented token used, insert its child, insert the rotation event,
  -- atomically. The mark-used statement's shape is owned by docs/plans/28 (see plan text).
  RotateRefreshToken ::
    RefreshTokenId -> NewRefreshToken -> AuthEvent ->
    AuthUnitOfWork m RotationOutcome
```

Create `shomei-postgres/src/Shomei/Postgres/AuthUnitOfWork.hs` exporting
`runAuthUnitOfWorkPostgres :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff
(AuthUnitOfWork : es) a -> Eff es a`. For `PersistNewSession`: generate the session id and
refresh-token id (as `Shomei.Postgres.SessionStore` / `RefreshTokenStore` do — reuse
`genSessionId` / `genRefreshTokenId` from `Shomei.Id`), generate the event ids, then build one
`Transaction` with `Hasql.Transaction.statement` over the **existing** prepared statements —
export `insertSessionStmt` from `Shomei.Postgres.SessionStore`, `insertRefreshTokenStmt` from
`Shomei.Postgres.RefreshTokenStore`, and the event-insert statement from
`Shomei.Postgres.AuthEventPublisher` (add them to those modules' export lists rather than
duplicating SQL; note the duplication risk in a comment at each export). Run it with
`runTransaction` and translate `Left UsageError` to `InternalAuthError` exactly as the store
interpreters do. For `RotateRefreshToken`: one `Transaction` of mark-used (see boundary note
below) + child insert + event insert; if the mark-used row count is 0, `Tx.condemn` is not
needed — simply return `RotationConflict` *without executing the inserts* (sequence the
transaction monadically: run mark-used first, inspect the count, and only then run the
inserts). **Boundary:** if plan 28 has landed, its CAS statement (WHERE includes
`AND status='active'`, RETURNING or rows-affected) is used verbatim; if not, change only the
*decoder* of the current `markUsedStmt` from `D.noResult` to `D.rowsAffected` (shape of the
SQL text unchanged) so the count is observable. Record which world you found in Surprises.

Rewire the workflows in `shomei-core`:

- `Shomei.Workflow.Session.issueSession`: replace the `createSession` / `createRefreshToken` /
  two `publishAuthEvent` calls with one `persistNewSession`, passing the builder
  `\sid -> [Event.LoginSucceeded …, Event.SessionStarted (… sid …)]`. Its constraint list
  swaps `SessionStore`/`RefreshTokenStore`/`AuthEventPublisher` for `AuthUnitOfWork` (keep
  `TokenSigner`/`TokenGen`).
- The inline signup tail in `Shomei.Workflow.signup` (same four calls, but publishing
  `UserRegistered` + `SessionStarted`): same replacement with its own builder.
- `Shomei.Workflow.refresh`: replace `markRefreshTokenUsed` + `createRefreshToken` +
  `publishAuthEvent RefreshTokenRotated` with one `rotateRefreshToken`; on
  `RotationConflict` return the same outcome the reuse path produces (`Left
  RefreshTokenReuseDetected` after the family/session revocation — mirror what the
  status-based `reuseDetected` branch does, since a lost race *is* concurrent reuse).
  The pre-checks (`findRefreshTokenByHash`, `findSessionById`, status/expiry checks) stay.

Then update every assembly and test harness that interprets the workflows: add
`AuthUnitOfWork` to `Shomei.Servant.Seam.AppEffects` and to
`Shomei.Server.App.AppEffects`, insert `runAuthUnitOfWorkPostgres` into `runAppIO` (above
`runDatabasePool`, beside the other store interpreters), and extend the in-memory interpreters
used by `shomei-core`'s and `shomei-servant`'s test suites with an interpreter that simply
composes the three underlying in-memory stores (atomicity is trivially true in memory). Find
them with `grep -rln "runSessionStoreInMemory\|SessionStore" shomei-core/test
shomei-servant/test shomei-postgres/test`. Old operations (`CreateSession`,
`CreateRefreshToken`, `MarkRefreshTokenUsed`, `PublishAuthEvent`) remain — other workflows
(logout, revocation, admin) still use them.

Acceptance: `cabal build all` and `cabal test all` green (the E2E suite exercises signup,
login, MFA, refresh against a real ephemeral PostgreSQL, so a broken transaction fails there).

### Milestone M4 — prove the round-trip budget and the atomicity

Scope: a counting interpreter test pinning the budgets, plus a captured statement-log
transcript. At the end, `cabal test all` includes a test named like
`"login costs 7 database round-trips"` that fails if the count drifts, and this plan's
Outcomes section carries a `BEGIN`/`COMMIT` transcript.

Add to the `shomei-server` test suite (`shomei-server/test/`, wired into the existing
`shomei-server-test` stanza) a spec that boots the real stack against an ephemeral migrated
database (`Shomei.Migrations.TestSupport.withShomeiMigratedDatabase`, as
`shomei-server/test/Shomei/Server/E2ESpec.hs` already does), but interposes a counting
`Database` interpreter: instead of calling `runDatabasePool` directly, interpret `Database`
with a wrapper that increments an `IORef Int` on every `RunSession` and `RunTransaction` and
delegates to `Pool.use`. Reset the counter, run one signup (to create the user), reset, run
`login` via the HTTP surface or directly via `runAppIO`-style assembly with the counting
interpreter, and assert the counter reads exactly **7**; same for refresh asserting **3**.
Also assert a lockout-free login issues no `DELETE` (combine with M2's trace test if more
convenient there).

For the human transcript: against the dev database, `ALTER SYSTEM SET log_statement = 'all'`
(or start the dev PostgreSQL with `-c log_statement=all`), run one login with `curl`, and
capture the log lines showing the tail as `BEGIN … INSERT shomei_sessions … INSERT
shomei_refresh_tokens … INSERT shomei_auth_events × 2 … COMMIT`. Paste the (redacted)
excerpt into Outcomes.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop`. The dev database must exist: `just create-database` (idempotent).

Step 1 (M1). Edit `Pool.hs`, `Config.hs`, `Boot.hs` as described, then:

```bash
cabal build all
cabal test shomei-server-config-test
```

Expected: both succeed. Boot check:

```bash
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
SHOMEI_DB_POOL_SIZE=25 SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS=2000 \
  cabal run shomei-server
```

Expected stderr (illustrative):

```text
[shomei] db pool: size 25, acquisition timeout 2000ms
[shomei] listening on :8080
```

Stop it with Ctrl-C. Re-run without the two variables and confirm `size 10, acquisition
timeout 10000ms`. Run once with `SHOMEI_DB_POOL_SIZE=0` and confirm the boot fails with a
clear error naming the variable.

Step 2 (M2). Edit `Workflow.hs`; add the trace test; then:

```bash
cabal test all
```

Expected: all suites pass, including the new "successful login without lockout issues no
ClearAccountLockout" case.

Step 3 (M3). Create the effect and interpreter modules, register them in
`shomei-core.cabal` / `shomei-postgres.cabal` `exposed-modules`, rewrite the three tails,
extend both `AppEffects` lists and `runAppIO`, update in-memory test interpreters. Build
incrementally per package to keep error batches small:

```bash
cabal build shomei-core && cabal build shomei-postgres && cabal build all
cabal test all
```

Expected: green. If the seam bridge complains about the effect order, remember
`Shomei.Servant.Seam.AppEffects` must be a sublist (in order) of
`Shomei.Server.App.AppEffects` for `inject` to typecheck — add `AuthUnitOfWork` at the same
relative position in both.

Step 4 (M4). Add the counting spec; run it:

```bash
cabal test shomei-server-test
```

Expected excerpt:

```text
  round-trip budget
    login costs 7 database round-trips:   OK
    refresh costs 3 database round-trips: OK
```

Capture the statement-log transcript against the dev stack, then finish:

```bash
nix fmt
cabal build all && cabal test all
```

Update this plan's living sections and MasterPlan 6's Progress checkboxes and registry Status.


## Validation and Acceptance

Behavioral acceptance, all observable without reading this plan's diffs:

1. **Pool configurability.** Booting with `SHOMEI_DB_POOL_SIZE=25
   SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS=2000` logs those values; booting without them logs
   `size 10 … 10000ms`; `SHOMEI_DB_POOL_SIZE=0` refuses to boot with an error naming the
   variable. The same two knobs work as Dhall fields `dbPoolSize` /
   `dbPoolAcquisitionTimeoutMs` in a `SHOMEI_CONFIG` file.
2. **Round-trip budget.** `cabal test shomei-server-test` contains passing assertions that a
   successful password login performs exactly 7 `Database` operations and a refresh exactly 3.
   Temporarily re-adding an unconditional `clearAccountLockout` makes the login case fail
   (8 ≠ 7) — a one-minute mutation check worth doing once.
3. **Atomicity.** With `log_statement=all`, one login shows the session, refresh-token, and
   both event inserts between a single `BEGIN`/`COMMIT` pair; one refresh shows mark-used +
   insert + event between one pair.
4. **No behavior change at the API.** The full `cabal test all` matrix (core workflow tests,
   postgres integration tests, servant tests, server E2E, both example suites) passes; signup,
   login, MFA step-up, refresh, reuse detection, and lockout lifecycle behave exactly as
   before from a client's point of view.


## Idempotence and Recovery

Every step is an ordinary source edit; re-running builds and tests is always safe. The plan
adds no migration and no destructive operation. `just create-database` is idempotent. If M3
goes sideways mid-rewrite, the old per-operation ports still exist and still work — the new
effect is purely additive until the moment a workflow's constraint list is switched, so you
can revert a single workflow to its previous body to get back to green (this is the
additive-then-subtract pattern; keep the tree compiling between workflow rewrites by switching
one workflow at a time: signup, then login/MFA via `issueSession`, then refresh). The
statement-log setting is reverted with `ALTER SYSTEM RESET log_statement; SELECT
pg_reload_conf();`.


## Interfaces and Dependencies

No new external dependencies. Libraries used: `hasql-pool` (`Hasql.Pool.Config.size`,
`Hasql.Pool.Config.acquisitionTimeout :: DiffTime -> Setting`), `hasql-transaction`
(`Hasql.Transaction.statement`, `Hasql.Transaction.Sessions.transaction` — already invoked by
`runDatabasePool`), `effectful` (dynamic dispatch, as everywhere).

Interfaces that must exist at the end:

- `Shomei.Postgres.Pool.acquirePool :: Int -> DiffTime -> Text -> IO Pool`.
- `Shomei.Server.Config.ServerSettings` with `serverDbPoolSize :: !Int` and
  `serverDbPoolAcquisitionTimeoutMs :: !Int`; env vars `SHOMEI_DB_POOL_SIZE`,
  `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS`; Dhall `FileConfig.dbPoolSize` /
  `dbPoolAcquisitionTimeoutMs`.
- `Shomei.Effect.AuthUnitOfWork` (in `shomei-core`) exporting `AuthUnitOfWork (..)`,
  `NewSessionToken (..)`, `RotationOutcome (..)`, `persistNewSession`, `rotateRefreshToken`
  with the signatures shown in M3.
- `Shomei.Postgres.AuthUnitOfWork.runAuthUnitOfWorkPostgres :: (Database :> es, IOE :> es,
  Error AuthError :> es) => Eff (AuthUnitOfWork : es) a -> Eff es a`.
- `Shomei.Workflow.Session.issueSession` and `Shomei.Workflow.{signup,login,refresh}` with
  `AuthUnitOfWork :> es` in place of the three per-op store constraints on their tails.
- `AuthUnitOfWork` present, at matching relative positions, in
  `Shomei.Servant.Seam.AppEffects` and `Shomei.Server.App.AppEffects`, interpreted in
  `Shomei.Server.App.runAppIO`.

Cross-plan interfaces honored: the mark-used statement shape (owned by
`docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`; this
plan only wraps it and reads its row count), and `ServerSettings`/`FileConfig` extension is
append-only (MasterPlan 6 Integration Points — plans 34 and 35 add their own fields).
