---
id: 14
slug: audit-log-retrieval-api-and-cli
title: "Audit log retrieval API and CLI"
kind: exec-plan
created_at: 2026-06-17T14:11:57Z
intention: "intention_01kvayjq71ek8v4e6vw4jkxtys"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Audit log retrieval API and CLI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-7** of MasterPlan 2
(`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`). All of
MasterPlan 1 and the precondition stated in that MasterPlan are assumed Complete: the
`shomei-server` boots against PostgreSQL, the `shomei-admin` CLI exists with `migrate`,
`keys`, and `users` subcommands, and the audit-event *write* path already persists events
to the `shomei_auth_events` table. This plan adds the **read** path.


## Purpose / Big Picture

Shōmei ("証明", proof / authentication) already *records* a structured audit trail. Every
security-significant action — a successful or failed login, a session start or revocation, a
refresh-token rotation or detected reuse, an email verification, a password reset or change, a
suspension or deletion, an account lockout or login throttle — is written as a row in the
PostgreSQL table `shomei_auth_events` (one row per event, with a denormalized `user_id` /
`session_id`, an `event_type` string, a JSONB `payload`, and a `created_at` timestamp). The
code that does this is the `AuthEventPublisher` effect and its PostgreSQL interpreter.

The problem this plan solves: **there is no way to read that trail back out.** Today an
operator who wants to answer "show me everything that happened to user X", "list every
account lockout in the last 24 hours", or "did refresh-token reuse get detected on this
session" has to open a `psql` shell and hand-write SQL against an internal table. That is
error-prone, easy to get wrong under pressure during an incident, and not something you can
hand to a downstream team.

After this plan, two retrieval surfaces exist over the same shared query layer:

1. A **command-line surface** for the operator who already runs `shomei-admin`:

   ```text
   shomei-admin audit events [--user UUID] [--session UUID] [--type T ...]
                             [--since TS] [--until TS] [--limit N] [--json]
   shomei-admin audit user <UUID>        # shortcut: full timeline for one account
   shomei-admin audit session <UUID>     # shortcut: one session's lifecycle
   shomei-admin audit count [filters]    # how many events match
   ```

2. An **HTTP surface** for programmatic access, gated so only an administrator can read it:

   ```text
   GET /admin/audit/events?user=UUID&session=UUID&type=login_failed&type=account_locked
                          &since=2026-06-01T00:00:00Z&until=...&limit=50&before=CURSOR
   ```

You can see it working end-to-end: register a user and fail a login through the running
server, then run `shomei-admin audit events --type login_failed` and watch the failed-login
row print; or `curl` the HTTP endpoint with an admin token and get a JSON page of events back,
while the same `curl` with a non-admin token gets `403 Forbidden`.

The heart of this plan is a single **read/query layer** — a new effect
`AuthEventReader` in `shomei-core` and its PostgreSQL interpreter in `shomei-postgres` — that
both surfaces sit on top of. The CLI and the API are deliberately thin: they parse inputs,
call the query layer, and format outputs. This keeps the filtering, pagination, and
event-reconstruction logic in exactly one place, tested once.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Read/query layer (shomei-core effect + shomei-postgres interpreter): **DONE (2026-06-17)**

- [x] Add `reconstructAuthEvent :: Text -> Value -> Either String AuthEvent` to `shomei-core` (new module `Shomei.Domain.EventCodec`). **Covers all 24 constructors** (the vocabulary grew past the 16 the plan described — see Surprises).
- [x] Add a pure round-trip test proving every one of the **24** event constructors survives `project → toJSON → reconstruct` (`Shomei.Domain.EventCodecSpec`, wired into `shomei-core:shomei-core-test`; a count guard asserts coverage of all 24). 103 core tests pass.
- [x] Add the `AuthEventReader` effect (`shomei-core/src/Shomei/Effect/AuthEventReader.hs`) with `AuditEventQuery`, `AuditCursor`, `StoredAuthEvent`, `queryAuthEvents`, `countAuthEvents`, `emptyAuditQuery`, `maxAuditLimit`, `clampLimit`.
- [x] Add the PostgreSQL interpreter (`shomei-postgres/src/Shomei/Postgres/AuthEventReader.hs`): filtered, keyset-paginated SELECT + COUNT (Params-monoid encoder; `text[]` via `E.foldableArray`; applicative row decoder).
- [x] Wire `runAuthEventReaderPostgres` into the `shomei-postgres` test stack (both interpreter chains + `AppEffects`) and add `testAuditEventReader` (seed 5 events for two users, assert newest-first ordering, user/type/time filters, `count`, two-page keyset walk is disjoint+complete, one reconstruct check). 22 postgres tests pass.

Milestone 2 — HTTP API (`GET /admin/audit/events`): **DONE (2026-06-17)**

- [x] Add `AuthEventReader` to the servant (`Shomei.Servant.Seam.AppEffects`) and server (`Shomei.Server.App.AppEffects`) effect stacks; wire `runAuthEventReaderPostgres` into `runAppIO`. The `inject` bridge in `Shomei.Server.Boot` type-checks unchanged. Also added an in-memory `runAuthEventReader` to `Shomei.Effect.InMemory` so the hybrid servant-test stack interprets the new effect (see Decision Log: the event→envelope projection was hoisted to `Shomei.Domain.EventCodec.projectAuthEvent` as the single source of truth, and the PostgreSQL writer now delegates to it).
- [x] Add DTOs (`AuditEventResponse`, `AuditEventsPage`) + `storedToResponse` and the opaque cursor codec (`encodeCursor`/`decodeCursor`, `"<iso8601>;<uuid>"`) to `shomei-servant/src/Shomei/Servant/DTO.hs`. Added `uuid` to the servant cabal.
- [x] Add the `auditEvents` route to `ShomeiAPI` (QueryParam/QueryParams), the admin-gated `auditEventsH` + total `buildQuery` (malformed UUID/timestamp/cursor → 400), and wire `auditEvents = auditEventsH env` into `shomeiServer`.
- [x] Servant integration tests: admin token → 200 with a non-empty trail; non-admin → 403; no token → 401; `?type=login_succeeded` filters; `?user=not-a-uuid` → 400; `?limit=1` + follow `nextCursor` walks disjoint pages. `shomei-servant-test` passes.

Milestone 3 — CLI (`shomei-admin audit ...`): **DONE (2026-06-17)**

- [x] Add `Shomei.Admin.Audit` module (`shomei-server/app/Shomei/Admin/Audit.hs`) + the `audit` subcommand group wired into `app/Admin.hs`; added to the `executable shomei-admin` AND `shomei-admin-test` `other-modules`, with `aeson`+`uuid` added to both stanzas.
- [x] Implement `events`/`user`/`session`/`count` over `runAuditReader` (the `runAuthEventReaderPostgres` stack); default tab-separated output (`created_at⇥event_type⇥user_id⇥session_id⇥event_id`), `--json` for NDJSON (envelope + raw payload); a bad UUID/timestamp aborts with a clear stderr message. Added `testAuditQuery` to `shomei-admin-test` (seed via the real publisher → read back, type filter, count); all 4 admin tests pass. Live-verified against the dev socket Postgres: `audit count` 31, `audit count --type login_failed` 8, tab + `--json|jq` output, and `--user 501` correctly rejected as an invalid UUID.

Milestone 4 — Docs, runbook, and limitations: **DONE (2026-06-17)**

- [x] `docs/security.md` gained a "Reading the audit trail (EP-7)" section (CLI + HTTP surfaces, keyset semantics, the admin-role limitation, and an operator runbook transcript for investigating a brute-force attempt). `docs/api.md` gained a "Audit log (EP-7)" section documenting `GET /admin/audit/events`. EP-3's plan doc (`docs/plans/10-…`) gained a forward note pointing to EP-7 as the read counterpart.
- [x] Updated MasterPlan 2's Exec-Plan Registry (EP-7 → Complete), Progress (four EP-7 items ticked), Surprises & Discoveries (24-constructor vocabulary; projection hoist), and Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **2026-06-17 — the `AuthEvent` vocabulary has grown from 16 to 24 constructors.** The plan
  was authored against a 16-arm `AuthEvent`; the live `shomei-core/src/Shomei/Domain/Event.hs`
  now also has `PasskeyRegistered`, `PasskeyRemoved`, `MfaChallenged`, `MfaSucceeded`,
  `MfaFailed`, `ImpersonationStarted`, `ImpersonationStopped`, and `ImpersonationActionBlocked`
  (added by later MasterPlan-3 work). Their `event_type` strings are taken verbatim from the
  writer (`projectAuthEvent`): `passkey_registered`, `passkey_removed`, `mfa_challenged`,
  `mfa_succeeded`, `mfa_failed`, `impersonation_started`, `impersonation_stopped`,
  `impersonation_action_blocked`. `reconstructAuthEvent` handles all 24, and the round-trip
  spec asserts coverage of all 24 (`testConstructorCount`) so a future 25th constructor fails
  the test loudly. This is read-only and backward compatible; no migration.

- **2026-06-17 — `hasql`'s `Decoders.Row` is `Applicative`, not `Monad`, in the installed
  version (`hasql >=1.10`).** The plan's `storedRowDecoder` used `do`-notation; that failed
  with `No instance for 'Monad D.Row'`. Rewrote it as a positional applicative
  (`mk <$> col <*> col <*> …`) with a `mk` helper that reorders the SELECT columns
  (`event_id, user_id, session_id, event_type, payload, created_at`) into the `StoredAuthEvent`
  field order. The `text[]` filter encoder is `E.foldableArray (E.nonNullable E.text)`
  (confirmed against the registered `hasql` source via `mori`).

- **2026-06-17 — `runAuthEventReaderPostgres` needs no `IOE` constraint.** Unlike the write
  interpreter (which `liftIO`s a random UUID), the reader goes entirely through the `Database`
  effect, so its constraint is `(Database :> es, Error AuthError :> es)` — a minor narrowing of
  the signature the plan documented (`+ IOE :> es`). It still composes into any stack that also
  provides `IOE` (e.g. the server/test chains), so no wiring changed. Recorded in the Decision
  Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Reconstruct typed events on read by dispatching on the `event_type` text column,
  rather than changing the write path to serialize the whole tagged `AuthEvent`.
  Rationale: The existing writer (`Shomei.Postgres.AuthEventPublisher.projectAuthEvent`)
  stores only the inner `*Data` record as the JSONB `payload` (via `toJSON d`), with the
  constructor identity captured separately in the `event_type` column. A naive
  `fromJSON payload :: Result AuthEvent` therefore cannot work — the payload is not the
  tagged sum. Reconstructing by `event_type` is fully backward compatible with every row
  already in the table and requires no migration.
  Date: 2026-06-17

- Decision: The query-layer filters use raw `UUID` (not the typed `UserId` / `SessionId`
  newtypes) for the user and session predicates, and `StoredAuthEvent` carries the
  denormalized `user_id` / `session_id` as `Maybe UUID`.
  Rationale: These columns are denormalized identifiers used only for filtering and display;
  the fully-typed identifiers already live inside the reconstructed event. Using `UUID`
  avoids needing inverse constructors (`UUID -> UserId`) that may not exist, and matches what
  the CLI/API receive on the wire (a UUID string).
  Date: 2026-06-17

- Decision: Pagination is **keyset** (a.k.a. seek) pagination on `(created_at, event_id)`
  descending, not `OFFSET`.
  Rationale: The table has an index on `created_at`; keyset pagination stays efficient as the
  table grows and is stable under concurrent inserts (no row skipping/duplication that
  `OFFSET` suffers). The cursor is the `(created_at, event_id)` of the last row returned.
  Date: 2026-06-17

- Decision: The HTTP endpoint is gated by `requireRole (Role "admin")` (the existing authz
  guard), but this plan does NOT add a mechanism to grant a user the admin role. The CLI is
  the fully-working operator retrieval path today; the API is verified via tests that mint
  admin-roled tokens directly (the pattern already used in `shomei-servant/test/Main.hs`).
  Rationale: Shōmei's login/signup workflows do not currently issue roles in tokens, so there
  is no production path to obtain an admin token. Adding a role-granting flow is a separate
  concern and out of scope here. Gating the endpoint correctly now means it is safe and
  immediately usable the moment such a flow exists. This limitation is documented for
  operators in Milestone 4.
  Date: 2026-06-17

- Decision: Default `limit` is 50, hard-capped at 1000. Requests above the cap are clamped
  (not rejected).
  Rationale: Prevents an unbounded scan from one careless query while keeping the interface
  forgiving. Both surfaces share the same clamp inside the query layer.
  Date: 2026-06-17

- Decision: Hoist the event→envelope projection into `shomei-core`
  (`Shomei.Domain.EventCodec.projectAuthEvent :: AuthEvent -> (Maybe UUID, Maybe UUID, Text,
  Value, UTCTime)`) as the single source of truth, and have the PostgreSQL writer
  (`Shomei.Postgres.AuthEventPublisher`) delegate to it (it keeps generating the row's
  `event_id`). The round-trip spec now pins `project → reconstruct` for all 24 constructors.
  Rationale: Milestone 2 needs an in-memory `AuthEventReader` for the servant test's hybrid
  stack, which must project the `World`'s typed event log into `StoredAuthEvent` rows
  identically to the writer. Rather than duplicate the 24-case mapping in two places (which
  could drift), one core function is shared by the writer, the in-memory reader, and the
  round-trip test. This is additive — `projectAuthEvent` was previously private to the writer,
  the `event_type` strings are unchanged, and no effect-stack entry was reordered or removed
  (IP-9). Verified: `shomei-postgres-test` (incl. `testPublishEvent`) still green.
  Date: 2026-06-17

- Decision: The `runAuthEventReader` in-memory interpreter assigns each event a synthetic,
  insertion-ordered `event_id` (`UUID.fromWords 0 0 0 i`) because the `World` event log stores
  only the typed `AuthEvent`, not the random `event_id` the SQL writer generates.
  Rationale: The reader's keyset order is `(created_at, event_id) DESC`; the in-memory test's
  fixed clock makes every event share `created_at`, so a deterministic, monotone-with-insertion
  `event_id` is needed for a stable total order and correct cursor pagination. This only affects
  the in-memory test path; the PostgreSQL interpreter (proven in M1) uses the real `event_id`.
  Date: 2026-06-17

- Decision: `runAuthEventReaderPostgres` is constrained `(Database :> es, Error AuthError :> es)`
  — no `IOE` — narrowing the signature the plan documented.
  Rationale: Reads go entirely through the `Database` effect; there is no `liftIO`. It still
  composes into the server/test chains (which also provide `IOE`). Avoids a
  `-Wredundant-constraints` warning. (Also recorded in Surprises & Discoveries.)
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### 2026-06-17 — EP-7 complete

Against the original purpose (read the audit trail back out without hand-written SQL), the plan
is **fully delivered**. The trail is now readable through one shared query layer with two thin
surfaces on top:

- **Query layer (M1).** `Shomei.Effect.AuthEventReader` (effect) + `runAuthEventReaderPostgres`
  (filtered, keyset-paginated `SELECT`/`COUNT`, read-only) + `Shomei.Domain.EventCodec`
  (`reconstructAuthEvent` and the hoisted `projectAuthEvent`). A pure round-trip spec pins all
  **24** `AuthEvent` constructors and a PostgreSQL interpreter test proves filters, ordering,
  count, and a disjoint+complete keyset walk.
- **HTTP (M2).** Admin-gated `GET /admin/audit/events` with filters + opaque cursor pagination;
  integration-tested for admin→200, non-admin→403, no-token→401, type filter, bad-UUID→400, and
  a two-page cursor walk. An in-memory `AuthEventReader` was added to `Shomei.Effect.InMemory`
  so the hybrid servant test interprets the new effect.
- **CLI (M3).** `shomei-admin audit events|user|session|count` with tab-separated + `--json`
  output; integration-tested over real PostgreSQL and live-verified against the dev socket DB.
- **Docs (M4).** `docs/security.md` (runbook + limitation), `docs/api.md`, and a forward note in
  EP-3's plan.

**Engineering verification.** `cabal build all` and `cabal test all` green: `shomei-core-test`
(104 — +1 EventCodec round-trip group), `shomei-postgres-test` (22 — +1 reader test),
`shomei-servant-test` (audit assertions added to the e2e scenario), `shomei-admin-test`
(4 — +1 audit query). fourmolu clean. No schema migration (read-only). No new external
dependency (only `aeson`/`uuid`, already in the workspace, added to a couple of stanzas).

**Deviations from the plan, each recorded in the Decision Log.** (1) The `AuthEvent` vocabulary
had grown 16→24 constructors since the plan was authored; all 24 are handled. (2) `hasql`'s
`Decoders.Row` is `Applicative`-only in the installed version, so the row decoder is positional
rather than `do`-notation. (3) The event→envelope projection was hoisted into `shomei-core` as a
single source of truth shared by the writer, the in-memory reader, and the round-trip test
(rather than duplicated). (4) `runAuthEventReaderPostgres` needs no `IOE` constraint.

**Known limitation (by design).** The HTTP endpoint's `admin` role has no production grant path
yet (login/signup issue no roles), so the CLI is the working operator path and the endpoint is
verified via out-of-band-minted admin tokens. A role-granting mechanism is the natural
follow-up.


## Context and Orientation

This section assumes no prior knowledge of the repository. It names every file you will read
or change by full path, defines the terms of art, and shows the exact existing patterns you
will mirror.

### The repository at a glance

Shōmei is a Haskell authentication toolkit built as a multi-package Cabal project. The
packages relevant to this plan are:

- `shomei-core` — pure domain types and *effects*. An **effect** is an interface, defined with
  the `effectful` library, that describes an operation the domain needs without saying how it
  is implemented. Effects live under
  `shomei-core/src/Shomei/Effect/`. Domain data types live under
  `shomei-core/src/Shomei/Domain/`.
- `shomei-postgres` — *interpreters* for those effects backed by PostgreSQL. An **interpreter**
  is the concrete implementation of an effect; for example `runAuthEventPublisherPostgres`
  implements the `AuthEventPublisher` effect by inserting rows. Interpreters live under
  `shomei-postgres/src/Shomei/Postgres/`.
- `shomei-servant` — the HTTP API: the route type (`ShomeiAPI`), the request/response JSON
  types (DTOs), the authentication/authorization seam, and the handlers.
- `shomei-server` — the runnable server (`shomei-server` executable) and the operator CLI
  (`shomei-admin` executable). Both live in this one package.
- `shomei-migrations` — SQL migration files and a test-support helper that spins up an
  ephemeral migrated PostgreSQL for tests.

The `effectful` library models effects as a type-level list `Eff es a`, where `es` is the
set of effects available. An interpreter "peels" one effect off the front of the list. You do
not need a deep understanding of `effectful`; you will copy the existing patterns exactly.

### The custom prelude (read this before writing any module)

Every Shōmei module imports `Shomei.Prelude` (`shomei-core/src/Shomei/Prelude.hs`) **instead
of** the standard `Prelude`. The project builds with the GHC2024 language edition, which lets
a custom prelude replace the default. The prelude re-exports common names from `aeson`,
`base`, `lens`, `text`, and `time` using `PackageImports` so the originating package is
pinned. A recent refactor (commit `6bc8f52`, "limit package imports to prelude") removed
direct `import "aeson"/"base"/"text"` lines from ordinary modules in favor of going through
the prelude.

What this means for the modules you write: start every new module with

```haskell
import Shomei.Prelude
```

and then add any *additional* imports as ordinary qualified or explicit imports, e.g.
`import Data.Aeson qualified as Aeson`, `import Hasql.Decoders qualified as D`,
`import Data.Set qualified as Set`. The prelude already gives you `Text`, `UTCTime`,
`Generic`, `FromJSON`, `ToJSON`, `toJSON`, `fromJSON`, `fromMaybe`, `when`, `forM_`, etc.
Do not add `import Prelude` or `import "base" Prelude`.

The prelude also exports `eventAesonOptions`, but note: the event `*Data` records do **not**
currently use it — they derive `FromJSON`/`ToJSON` with default options. The payload JSON you
read back was written with those default options, so you must decode with the default
instances too (i.e. plain `fromJSON`), which is exactly what `reconstructAuthEvent` does.

### The audit-event write path you are mirroring

The event vocabulary is in `shomei-core/src/Shomei/Domain/Event.hs`. The top type is:

```haskell
data AuthEvent
    = UserRegistered UserRegisteredData
    | LoginSucceeded LoginSucceededData
    | LoginFailed LoginFailedData
    | SessionStarted SessionStartedData
    | SessionRevoked SessionRevokedData
    | RefreshTokenRotated RefreshTokenRotatedData
    | RefreshTokenReuseDetected RefreshTokenReuseDetectedData
    | EmailVerificationRequested EmailVerificationRequestedData
    | EmailVerified EmailVerifiedData
    | PasswordResetRequested PasswordResetRequestedData
    | PasswordResetCompleted PasswordResetCompletedData
    | PasswordChanged PasswordChangedData
    | UserSuspended UserSuspendedData
    | UserDeleted UserDeletedData
    | AccountLocked AccountLockedData
    | LoginThrottled LoginThrottledData
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

Each arm carries a `*Data` record (for example `LoginFailedData { email :: !Email,
occurredAt :: !UTCTime }`, `AccountLockedData { accountKey :: !AccountKey, clientIp ::
!ClientIp, failedCount :: !Int, lockedUntil :: !UTCTime, occurredAt :: !UTCTime }`). Every
`*Data` record has `deriving anyclass (FromJSON, ToJSON)` and every record contains an
`occurredAt :: !UTCTime` field. You do not need to enumerate the fields to implement this
plan, but you do need the full constructor-to-`event_type` mapping, which the write path
already defines.

The write interpreter is
`shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs`. Its `projectAuthEvent` function
maps each `AuthEvent` arm to a tuple `(Maybe UUID userId, Maybe UUID sessionId, Text
event_type, Value payload, UTCTime occurredAt)`, where `payload = toJSON d` for the inner
`*Data` record `d`. The 16 `event_type` strings (which you must reuse verbatim on read) are:

```text
user_registered                 login_succeeded            login_failed
session_started                 session_revoked            refresh_token_rotated
refresh_token_reuse_detected    email_verification_requested
email_verified                  password_reset_requested   password_reset_completed
password_changed                user_suspended             user_deleted
account_locked                  login_throttled
```

The insert statement (study it; you will mirror its `hasql` style for the SELECT):

```haskell
type AuthEventRow = (UUID, Maybe UUID, Maybe UUID, Text, Value, UTCTime)

insertAuthEventStmt :: Statement AuthEventRow ()
insertAuthEventStmt =
    preparable
        """
        INSERT INTO shomei.shomei_auth_events
          (event_id, user_id, session_id, event_type, payload, created_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """
        ( contrazip6
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nullable E.uuid))
            (E.param (E.nullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.jsonb))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult
```

### The table schema

From `shomei-migrations/sql-migrations/2026-06-03-00-00-06-shomei-auth-events.sql`:

```sql
SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_auth_events (
  event_id   uuid PRIMARY KEY,
  user_id    uuid NULL,
  session_id uuid NULL,
  event_type text NOT NULL,
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_auth_events_user_id_idx    ON shomei_auth_events (user_id);
CREATE INDEX IF NOT EXISTS shomei_auth_events_session_id_idx ON shomei_auth_events (session_id);
CREATE INDEX IF NOT EXISTS shomei_auth_events_event_type_idx ON shomei_auth_events (event_type);
CREATE INDEX IF NOT EXISTS shomei_auth_events_created_at_idx ON shomei_auth_events (created_at);
```

No schema change is required by this plan. The table is fully indexed for the filters we
expose. (If, during implementation, the keyset `ORDER BY created_at DESC, event_id DESC`
benefits from a composite index, that is an optional optimization — note it in Surprises &
Discoveries; do not add it pre-emptively.)

### The `hasql` decoder/encoder idiom

`hasql` is the PostgreSQL library in use. You write a `Statement input output` with
`preparable`, supplying a parameter **encoder** (`Hasql.Encoders`, aliased `E`) and a result
**decoder** (`Hasql.Decoders`, aliased `D`). A representative SELECT from
`shomei-postgres/src/Shomei/Postgres/UserStore.hs`:

```haskell
type UserRow = (UUID, Text, Maybe Text, Text, Maybe UTCTime, UTCTime, UTCTime)

userRowDecoder :: D.Row UserRow
userRowDecoder =
    (,,,,,,)
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

findUserByIdStmt :: Statement UUID (Maybe UserRow)
findUserByIdStmt =
    preparable
        "SELECT ... FROM shomei.shomei_users WHERE user_id = $1"
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe userRowDecoder)
```

Base decoders you need: `D.uuid`, `D.text`, `D.jsonb` (yields `Data.Aeson.Value`),
`D.timestamptz`, `D.int8`. Result wrappers: `D.rowList` (a list of rows), `D.rowMaybe`,
`D.singleRow`, `D.noResult`. Base encoders you need: `E.uuid`, `E.text`, `E.jsonb`,
`E.timestamptz`, plus a **text-array** encoder for the `type` filter (see the note in
Milestone 1 about confirming the exact array-encoder API for the installed `hasql` version).

To run a statement against the connection pool inside an interpreter, the existing code uses
`runSession (Session.statement input stmt)` from `Shomei.Postgres.Database` (the `Database`
effect). In the CLI, the existing `keys` handlers run a session directly with
`Hasql.Pool.use pool (Session.statement input stmt)`.

### The effect-stack wiring you must extend

The HTTP handlers run over a fixed effect list. In
`shomei-servant/src/Shomei/Servant/Seam.hs` there is a type `AppEffects` listing every effect a
handler may use (`UserStore`, `SessionStore`, …, `AuthEventPublisher`, `SigningKeyStore`,
`Clock`, `TokenGen`, `IOE`). The server provides the concrete interpreters in
`shomei-server/src/Shomei/Server/App.hs` (`runAppIO`) and bridges them in
`shomei-server/src/Shomei/Server/Boot.hs` (`seamEnv`/`runPorts`). The `shomei-postgres` test
suite (`shomei-postgres/test/Main.hs`) has its own `AppEffects` list and `runApp` interpreter
chain. **Adding the new `AuthEventReader` effect means adding it to each of these lists and
adding its interpreter to each chain.** All such sites are enumerated in Milestone 2 and
Milestone 1's test step. Mirror exactly how `AuthEventPublisher` already appears in each.

### The HTTP API and authz primitives

The route type is `ShomeiAPI` in `shomei-servant/src/Shomei/Servant/API.hs`, a record of
named routes (Servant `NamedRoutes`). Protected routes carry the `Authenticated` combinator
(`type Authenticated = AuthProtect "shomei-jwt"`), which injects an `AuthUser` value into the
handler. `AuthUser` (in `shomei-servant/src/Shomei/Servant/Auth.hs`) carries
`authRoles :: !(Set Role)` extracted from the verified JWT claims. Authorization guards are in
`shomei-servant/src/Shomei/Servant/Authz.hs`:

```haskell
requireRole :: Role -> AuthUser -> Handler ()
requireRole role u
    | role `Set.member` u.authRoles = pure ()
    | otherwise = throwError err403{errBody = "missing required role"}
```

`Role` is `newtype Role = Role Text` from `shomei-core/src/Shomei/Domain/Claims.hs`. The
existing test suite `shomei-servant/test/Main.hs` already demonstrates an admin-gated route
and mints a token whose claims include `roles = Set.fromList [Role "admin"]`; you will reuse
that exact technique to test the new endpoint.

DTOs (request/response JSON types) live in `shomei-servant/src/Shomei/Servant/DTO.hs` and use
`deriving stock (Generic)` + `deriving anyclass (FromJSON, ToJSON)`. Timestamps are rendered
as ISO-8601 strings with `iso8601Show` (see `SessionResponse`). There are no existing
query-parameter or pagination patterns in the API; this plan introduces the first ones using
Servant's `QueryParam`/`QueryParams` combinators.

### The CLI you are extending

The `shomei-admin` executable is defined in
`shomei-server/shomei-server.cabal` (`executable shomei-admin`, `main-is: Admin.hs`,
`hs-source-dirs: app`). Its entry point is `shomei-server/app/Admin.hs`, which uses
`optparse-applicative`. The command tree is a sum type dispatched by `hsubparser`:

```haskell
data Command = Migrate | Keys KeysCommand | Users UsersCommand

commandParser :: Parser Command
commandParser =
    hsubparser
        ( command "migrate" (info (pure Migrate) (progDesc "Apply pending database migrations"))
            <> command "keys"  (info (Keys  <$> keysParser)  (progDesc "Manage signing keys"))
            <> command "users" (info (Users <$> usersParser) (progDesc "Manage user accounts"))
        )
```

Subcommand handler modules live in `shomei-server/app/Shomei/Admin/` (`Env.hs`, `Keys.hs`,
`Users.hs`) and are listed under `other-modules` in the cabal stanza. `Shomei.Admin.Env`
loads configuration from environment variables (`DATABASE_URL`, `SHOMEI_ISSUER`,
`SHOMEI_AUDIENCE`) and acquires a `Hasql.Pool.Pool` via `acquirePool 4 connStr`. Output is
plain text to stdout (tab-separated columns for list commands, as in `keys list`); errors go
to stderr via a `die :: String -> IO a` helper that calls `exitFailure`.


## Plan of Work

The work is one shared query layer plus two thin surfaces, delivered in four milestones. Each
milestone is independently verifiable.

### Milestone 1 — The read/query layer

Scope: a new effect and its PostgreSQL interpreter, plus the pure event-reconstruction
function they depend on. At the end of this milestone, a test can seed events into an
ephemeral PostgreSQL and query them back — filtered, ordered newest-first, and paginated —
with every event reconstructed into its typed `AuthEvent` form. Nothing user-facing exists
yet; the proof is the new test suite passing.

Step 1.1 — Event reconstruction. Create
`shomei-core/src/Shomei/Domain/EventCodec.hs` exporting:

```haskell
reconstructAuthEvent :: Text -> Aeson.Value -> Either String AuthEvent
```

It dispatches on the `event_type` string and decodes the payload into the matching `*Data`
record, wrapping the result in the corresponding constructor. Use a small helper to turn an
Aeson `Result` into `Either String`:

```haskell
module Shomei.Domain.EventCodec (reconstructAuthEvent) where

import Shomei.Prelude
import Data.Aeson qualified as Aeson
import Shomei.Domain.Event

reconstructAuthEvent :: Text -> Aeson.Value -> Either String AuthEvent
reconstructAuthEvent etype payload = case etype of
    "user_registered"              -> UserRegistered              <$> parse payload
    "login_succeeded"              -> LoginSucceeded              <$> parse payload
    "login_failed"                 -> LoginFailed                 <$> parse payload
    "session_started"              -> SessionStarted              <$> parse payload
    "session_revoked"              -> SessionRevoked              <$> parse payload
    "refresh_token_rotated"        -> RefreshTokenRotated         <$> parse payload
    "refresh_token_reuse_detected" -> RefreshTokenReuseDetected   <$> parse payload
    "email_verification_requested" -> EmailVerificationRequested  <$> parse payload
    "email_verified"               -> EmailVerified               <$> parse payload
    "password_reset_requested"     -> PasswordResetRequested      <$> parse payload
    "password_reset_completed"     -> PasswordResetCompleted      <$> parse payload
    "password_changed"             -> PasswordChanged             <$> parse payload
    "user_suspended"               -> UserSuspended               <$> parse payload
    "user_deleted"                 -> UserDeleted                 <$> parse payload
    "account_locked"               -> AccountLocked               <$> parse payload
    "login_throttled"              -> LoginThrottled              <$> parse payload
    other                          -> Left ("unknown event_type: " <> Text.unpack other)
  where
    parse :: Aeson.FromJSON a => Aeson.Value -> Either String a
    parse v = case Aeson.fromJSON v of
        Aeson.Success a -> Right a
        Aeson.Error e   -> Left e
```

(You will need `import Data.Text qualified as Text` for `Text.unpack`, and
`import Data.Aeson qualified as Aeson` for `Result(..)`/`fromJSON`. Add `Shomei.Domain.EventCodec`
to `shomei-core/shomei-core.cabal`'s `exposed-modules`.)

Step 1.2 — Round-trip test. Add a pure test (no database) that, for a representative value of
each of the 16 constructors, computes the same `(event_type, payload)` projection the writer
uses and asserts `reconstructAuthEvent event_type payload == Right originalEvent`. The
writer's `projectAuthEvent` is currently not exported; the simplest robust check is to assert
`reconstructAuthEvent ty (toJSON dataRecord) == Right (Constructor dataRecord)` for each arm,
using the same `event_type` strings listed above. Put this in the existing `shomei-core` test
suite if one exists, otherwise add a small `tasty`/`tasty-hunit` suite to
`shomei-core.cabal`. This test is the primary guard against the payload/`event_type` mapping
drifting from the writer.

Step 1.3 — The effect. Create `shomei-core/src/Shomei/Effect/AuthEventReader.hs`, mirroring the
structure of `Shomei.Effect.AuthEventPublisher` (a `data ... :: Effect where` GADT,
`type instance DispatchOf ... = Dynamic`, and `send`-based helper functions):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

module Shomei.Effect.AuthEventReader (
    AuthEventReader (..),
    AuditEventQuery (..),
    AuditCursor (..),
    StoredAuthEvent (..),
    emptyAuditQuery,
    maxAuditLimit,
    clampLimit,
    queryAuthEvents,
    countAuthEvents,
) where

import Shomei.Prelude
import Data.UUID (UUID)
import Data.Aeson (Value)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

-- | A keyset-pagination cursor: the (created_at, event_id) of the last row seen.
data AuditCursor = AuditCursor
    { cursorCreatedAt :: !UTCTime
    , cursorEventId :: !UUID
    }
    deriving stock (Eq, Show)

-- | Filters for an audit-event query. An empty 'queryEventTypes' means "all types".
data AuditEventQuery = AuditEventQuery
    { queryUserId :: !(Maybe UUID)
    , querySessionId :: !(Maybe UUID)
    , queryEventTypes :: ![Text]
    , querySince :: !(Maybe UTCTime)  -- inclusive lower bound on created_at
    , queryUntil :: !(Maybe UTCTime)  -- exclusive upper bound on created_at
    , queryLimit :: !Int              -- clamp with 'clampLimit' before use
    , queryBefore :: !(Maybe AuditCursor)
    }
    deriving stock (Eq, Show)

-- | One row of the audit trail: the envelope columns plus the reconstructed event.
data StoredAuthEvent = StoredAuthEvent
    { storedEventId :: !UUID
    , storedEventType :: !Text
    , storedUserId :: !(Maybe UUID)
    , storedSessionId :: !(Maybe UUID)
    , storedCreatedAt :: !UTCTime
    , storedPayload :: !Value
    }
    deriving stock (Eq, Show)

emptyAuditQuery :: AuditEventQuery
emptyAuditQuery = AuditEventQuery Nothing Nothing [] Nothing Nothing 50 Nothing

maxAuditLimit :: Int
maxAuditLimit = 1000

clampLimit :: Int -> Int
clampLimit n = max 1 (min maxAuditLimit n)

data AuthEventReader :: Effect where
    QueryAuthEvents :: AuditEventQuery -> AuthEventReader m [StoredAuthEvent]
    CountAuthEvents :: AuditEventQuery -> AuthEventReader m Int

type instance DispatchOf AuthEventReader = Dynamic

queryAuthEvents :: (AuthEventReader :> es) => AuditEventQuery -> Eff es [StoredAuthEvent]
queryAuthEvents = send . QueryAuthEvents

countAuthEvents :: (AuthEventReader :> es) => AuditEventQuery -> Eff es Int
countAuthEvents = send . CountAuthEvents
```

Note `StoredAuthEvent` carries the raw `storedPayload :: Value` rather than a reconstructed
`AuthEvent`. Reconstruction is the caller's choice via `reconstructAuthEvent` (Step 1.1); the
interpreter never fails on a row it cannot type. This keeps the storage read decoupled from
JSON shape and means an unrecognized future `event_type` still lists (with its raw payload)
instead of breaking the whole query. The CLI and API use `reconstructAuthEvent` only where
they want typed access; for display they can pass the payload through directly.

Add `Shomei.Effect.AuthEventReader` to `shomei-core.cabal`'s `exposed-modules`.

Step 1.4 — The PostgreSQL interpreter. Create
`shomei-postgres/src/Shomei/Postgres/AuthEventReader.hs` exporting
`runAuthEventReaderPostgres`, mirroring `runAuthEventPublisherPostgres` (it requires
`Database :> es`, `IOE :> es`, `Error AuthError :> es`, uses `interpret_`, and runs sessions
with `runSession`). Build one parameterized SELECT that handles every optional filter with
the `($n IS NULL OR col = $n)` idiom, applies the keyset predicate, orders newest-first, and
limits. Use one `COUNT(*)` statement with the same filters (but no ordering/limit/cursor) for
`CountAuthEvents`.

The SELECT (note the casts so a NULL parameter type-checks):

```sql
SELECT event_id, user_id, session_id, event_type, payload, created_at
FROM shomei.shomei_auth_events
WHERE ($1::uuid        IS NULL OR user_id    = $1)
  AND ($2::uuid        IS NULL OR session_id = $2)
  AND (cardinality($3::text[]) = 0 OR event_type = ANY($3))
  AND ($4::timestamptz IS NULL OR created_at >= $4)
  AND ($5::timestamptz IS NULL OR created_at <  $5)
  AND ($6::timestamptz IS NULL OR (created_at, event_id) < ($6, $7))
ORDER BY created_at DESC, event_id DESC
LIMIT $8
```

Parameters in order: `user (Maybe UUID)`, `session (Maybe UUID)`, `types ([Text])`,
`since (Maybe UTCTime)`, `until (Maybe UTCTime)`, `beforeCreatedAt (Maybe UTCTime)`,
`beforeEventId (Maybe UUID)`, `limit (Int64)`. Derive `beforeCreatedAt`/`beforeEventId` from
`queryBefore`: `Nothing` → both `Nothing`; `Just (AuditCursor t e)` → `(Just t, Just e)`.
Clamp the limit with `clampLimit` and convert to `Int64` for `E.int8`.

Build the encoder with the **`Hasql.Encoders.Params` monoid** idiom (robust for any arity —
no dependence on a `contrazipN` of the right size). Each field projects out of a parameter
tuple/record and is combined with `<>`:

```haskell
import Hasql.Encoders qualified as E
import Hasql.Decoders qualified as D
import Data.Functor.Contravariant ((>$<))

-- parameter bundle: (user, session, types, since, until, beforeTs, beforeId, limit)
type QueryParams =
    (Maybe UUID, Maybe UUID, [Text], Maybe UTCTime, Maybe UTCTime, Maybe UTCTime, Maybe UUID, Int64)

queryEncoder :: E.Params QueryParams
queryEncoder =
       ((\(a,_,_,_,_,_,_,_) -> a) >$< E.param (E.nullable E.uuid))
    <> ((\(_,b,_,_,_,_,_,_) -> b) >$< E.param (E.nullable E.uuid))
    <> ((\(_,_,c,_,_,_,_,_) -> c) >$< E.param (E.nonNullable textArray))
    <> ((\(_,_,_,d,_,_,_,_) -> d) >$< E.param (E.nullable E.timestamptz))
    <> ((\(_,_,_,_,e,_,_,_) -> e) >$< E.param (E.nullable E.timestamptz))
    <> ((\(_,_,_,_,_,f,_,_) -> f) >$< E.param (E.nullable E.timestamptz))
    <> ((\(_,_,_,_,_,_,g,_) -> g) >$< E.param (E.nullable E.uuid))
    <> ((\(_,_,_,_,_,_,_,h) -> h) >$< E.param (E.nonNullable E.int8))
```

`textArray` is the text-array encoder. **Confirm the exact name for the installed `hasql`
version before coding it** — depending on version it is either `E.foldableArray
(E.nonNullable E.text)` or the longhand
`E.array (E.dimension foldl' (E.element (E.nonNullable E.text)))`. Per the project's
dependency-lookup convention, run `mori registry show hasql --full` (or
`mori registry docs hasql`) and read the `Hasql.Encoders` source to pick the correct
combinator rather than guessing. Apply the same check for the decoder side if needed
(`D.jsonb` yields `Aeson.Value`, which is what we want).

The row decoder produces a `StoredAuthEvent` directly:

```haskell
storedRowDecoder :: D.Row StoredAuthEvent
storedRowDecoder =
    StoredAuthEvent
        <$> D.column (D.nonNullable D.uuid)        -- event_id
        <*> ???                                     -- see note: event_type comes 4th in SELECT
```

Because the SELECT column order is `event_id, user_id, session_id, event_type, payload,
created_at` but the `StoredAuthEvent` field order is `eventId, eventType, userId, sessionId,
createdAt, payload`, decode positionally into a tuple matching the SELECT and then build the
record, to avoid confusion:

```haskell
storedRowDecoder :: D.Row StoredAuthEvent
storedRowDecoder = do
    eid   <- D.column (D.nonNullable D.uuid)
    uid   <- D.column (D.nullable D.uuid)
    sid   <- D.column (D.nullable D.uuid)
    etype <- D.column (D.nonNullable D.text)
    pl    <- D.column (D.nonNullable D.jsonb)
    cat   <- D.column (D.nonNullable D.timestamptz)
    pure StoredAuthEvent
        { storedEventId = eid, storedEventType = etype
        , storedUserId = uid, storedSessionId = sid
        , storedCreatedAt = cat, storedPayload = pl
        }
```

(`D.Row` has a `Monad` instance, so the `do`-notation above works and is clearer than a
positional applicative for a record whose field order differs from the column order.) Use
`D.rowList storedRowDecoder` for the query result and
`D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8))` for the count.

The interpreter skeleton:

```haskell
runAuthEventReaderPostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (AuthEventReader : es) a -> Eff es a
runAuthEventReaderPostgres = interpret_ \case
    QueryAuthEvents q -> do
        res <- runSession (Session.statement (toParams q) selectStmt)
        either (throwError . InternalAuthError . ("database error: " <>) . tshow) pure res
    CountAuthEvents q -> do
        res <- runSession (Session.statement (toParams q) countStmt)
        either (throwError . InternalAuthError . ("database error: " <>) . tshow) pure res
```

where `toParams :: AuditEventQuery -> QueryParams` clamps the limit and splits the cursor.
`tshow` and the `InternalAuthError` error constructor are the same ones the write
interpreter uses (`Shomei.Postgres.Codec.tshow`, `Shomei.Error.AuthError`). Add
`Shomei.Postgres.AuthEventReader` to `shomei-postgres.cabal`'s `exposed-modules`.

Step 1.5 — Interpreter tests. In `shomei-postgres/test/Main.hs`, add `AuthEventReader` to the
test `AppEffects` list and `runAuthEventReaderPostgres` to the `runApp` interpreter chain
(place it adjacent to `runAuthEventPublisherPostgres`). Add tests using the existing `withDb`
/ `runApp` / `expectApp` helpers that: publish a known sequence of events for two different
users/sessions; then assert `queryAuthEvents emptyAuditQuery` returns them newest-first;
filtering by `queryUserId` returns only that user's rows; filtering by `queryEventTypes
["login_failed"]` returns only failed logins; a `querySince`/`queryUntil` window excludes
out-of-range rows; and keyset pagination (`queryLimit = 2`, then re-query with `queryBefore`
set to the last returned row's cursor) walks the whole set without gaps or repeats. For at
least one row, assert `reconstructAuthEvent (storedEventType r) (storedPayload r)` returns
`Right` the expected typed event.

Acceptance for Milestone 1:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
cabal test shomei-core:test shomei-postgres:shomei-postgres-test
```

Both suites pass, including the new round-trip and interpreter tests. (Adjust the
`shomei-core` test target name to whatever the cabal file defines; if `shomei-core` has no
test suite yet, the round-trip test may instead be added to `shomei-postgres`'s suite, which
already depends on `shomei-core`.)

### Milestone 2 — The HTTP API

Scope: a new admin-gated endpoint `GET /admin/audit/events` that returns a JSON page of audit
events with filtering and keyset pagination. At the end, a `curl` with an admin token returns
events; without the admin role it returns 403; without any token, 401. Proof: new
integration tests in `shomei-servant/test/Main.hs`.

Step 2.1 — Extend the effect stacks. Add `AuthEventReader` to the `AppEffects` type in
`shomei-servant/src/Shomei/Servant/Seam.hs` (place it next to `AuthEventPublisher`). Then add
the interpreter `runAuthEventReaderPostgres` to the server's interpreter chain in
`shomei-server/src/Shomei/Server/App.hs` (`runAppIO`), again adjacent to the existing
`runAuthEventPublisherPostgres`. No change to `Boot.hs` is needed beyond the stack already
flowing through `runPorts`, but verify the bridge in `seamEnv`/`runPorts` still type-checks
(the injected stacks must match). Build `shomei-server` to confirm the stacks line up.

Step 2.2 — DTOs and the cursor codec. In `shomei-servant/src/Shomei/Servant/DTO.hs` add:

```haskell
data AuditEventResponse = AuditEventResponse
    { eventId :: !Text          -- UUID rendered as text
    , eventType :: !Text
    , userId :: !(Maybe Text)
    , sessionId :: !(Maybe Text)
    , createdAt :: !Text         -- iso8601Show
    , payload :: !Value          -- the raw event payload, passed through
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

data AuditEventsPage = AuditEventsPage
    { events :: ![AuditEventResponse]
    , nextCursor :: !(Maybe Text)  -- opaque; pass back as ?before= to get the next page
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

storedToResponse :: StoredAuthEvent -> AuditEventResponse
storedToResponse s = AuditEventResponse
    { eventId    = UUID.toText (storedEventId s)
    , eventType  = storedEventType s
    , userId     = UUID.toText <$> storedUserId s
    , sessionId  = UUID.toText <$> storedSessionId s
    , createdAt  = Text.pack (iso8601Show (storedCreatedAt s))
    , payload    = storedPayload s
    }
```

Define an opaque cursor string format `"<iso8601Z>;<uuid>"` and two total functions
`encodeCursor :: AuditCursor -> Text` and `decodeCursor :: Text -> Maybe AuditCursor`. The
`nextCursor` of a page is `encodeCursor` of the last event's `(createdAt, eventId)` when the
page is full (i.e. exactly `limit` rows were returned), otherwise `Nothing`. Put the cursor
codec wherever is cleanest — a small `Shomei.Servant.AuditCursor` module or inside `DTO.hs`.
(`iso8601Show`/`iso8601ParseM` come from `Data.Time.Format.ISO8601`; `UUID.toText`/`fromText`
from `Data.UUID`.)

Step 2.3 — The route. In `shomei-servant/src/Shomei/Servant/API.hs`, add a field to the
`ShomeiAPI` record:

```haskell
auditEvents :: mode
    :- "admin" :> "audit" :> "events"
        :> Authenticated
        :> QueryParam  "user"    Text
        :> QueryParam  "session" Text
        :> QueryParams "type"    Text
        :> QueryParam  "since"   Text
        :> QueryParam  "until"   Text
        :> QueryParam  "limit"   Int
        :> QueryParam  "before"  Text
        :> Get '[JSON] AuditEventsPage
```

(`QueryParams "type"` — plural — collects repeated `?type=…&type=…` into a list.)

Step 2.4 — The handler. In `shomei-servant/src/Shomei/Servant/Handlers.hs` add
`auditEventsH` and wire it into `shomeiServer`:

```haskell
auditEventsH ::
    Env -> AuthUser
    -> Maybe Text -> [Text] ... -> Maybe Text  -- the query params, in route order
    -> Handler AuditEventsPage
auditEventsH env user mUser mSession types mSince mUntil mLimit mBefore = do
    requireRole (Role "admin") user
    q <- either (\msg -> throwError err400{errBody = encodeUtf8L msg}) pure
            (buildQuery mUser mSession types mSince mUntil mLimit mBefore)
    rows <- runPort env (queryAuthEvents q)
    let resp = map storedToResponse rows
        full = length rows == clampLimit (queryLimit q)
        next = if full then encodeCursor . lastCursor <$> lastMay rows else Nothing
    pure (AuditEventsPage resp next)
```

`buildQuery` parses the textual params into an `AuditEventQuery`: parse `user`/`session` with
`UUID.fromText` (a malformed UUID is a 400), parse `since`/`until`/`before` (an unparseable
timestamp or cursor is a 400), default `limit` to 50, and clamp. Keep `buildQuery` total and
return `Left errorMessage` on any parse failure so the handler maps it to `err400`. Reuse the
existing JSON-error helper style from `shomei-servant/src/Shomei/Servant/Error.hs` for the
body if convenient. Add the `auditEvents = auditEventsH env` field to the `shomeiServer`
record assembly.

Step 2.5 — Tests. In `shomei-servant/test/Main.hs`, following the existing admin-route test
(which mints a token with `roles = Set.fromList [Role "admin"]`), add tests that: seed a few
audit events (publish them through the same effect stack the test harness already wires, or
insert directly), then call `GET /admin/audit/events` with an admin token and assert 200 with
the expected events and ordering; call it with a non-admin token and assert 403; call it with
no token and assert 401; call it with `?type=login_failed` and assert filtering; and call it
with `?limit=1` twice (second time passing the returned `nextCursor` as `?before=`) and assert
pagination walks the set.

Acceptance for Milestone 2:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
cabal build shomei-server
cabal test shomei-servant:test
```

The servant test suite passes including the new audit-endpoint tests. For a manual check
against a running server, see Validation and Acceptance below.

### Milestone 3 — The CLI

Scope: a new `audit` subcommand group on `shomei-admin`. At the end, an operator can list and
filter the audit trail and get tab-separated or JSON output. Proof: running the commands
against a database that has events prints them.

Step 3.1 — The handler module. Create `shomei-server/app/Shomei/Admin/Audit.hs`. It takes the
`AdminEnv` (which already holds the `Hasql.Pool.Pool`) and runs the read interpreter directly
over a minimal effect stack, mirroring how `Shomei.Admin.Users` runs `runSignup`:

```haskell
runAuditReader ::
    Pool -> Eff '[AuthEventReader, Database, Error AuthError, IOE] a -> IO (Either AuthError a)
runAuditReader pool =
    runEff . runErrorNoCallStack . runDatabasePool pool . runAuthEventReaderPostgres
```

Implement actions `auditEvents`, `auditUser`, `auditSession`, `auditCount` that build an
`AuditEventQuery`, call `queryAuthEvents`/`countAuthEvents`, and print results. Default output
is one tab-separated line per event: `created_at \t event_type \t user_id \t session_id \t
event_id`. With `--json`, print one JSON object per line (NDJSON) using `storedPayload` plus
the envelope fields — reuse a small encoder or build an Aeson object inline. On error, use the
existing `die` helper pattern (stderr + `exitFailure`).

Step 3.2 — The parser. In `shomei-server/app/Admin.hs`, add an `Audit AuditCommand`
constructor to `Command`, an `AuditCommand` sum type, an `auditParser :: Parser AuditCommand`
using `hsubparser` with `events`, `user`, `session`, and `count` subcommands (the `events`
and `count` subcommands take `--user`, `--session`, `--type` (repeatable), `--since`,
`--until`, `--limit`, and `--json` options; `user` and `session` take a positional `UUID`
argument). Wire `<> command "audit" (info (Audit <$> auditParser) (progDesc "Query the audit
log / security events"))` into `commandParser`, and add an `Audit cmd -> ...` case to the
top-level `run` dispatch that loads `AdminEnv` and calls the matching action. Add
`Shomei.Admin.Audit` to the `other-modules` of the `executable shomei-admin` stanza in
`shomei-server/shomei-server.cabal`.

Step 3.3 — Repeatable `--type`. `optparse-applicative` collects a repeatable option with
`many (strOption (long "type" <> ...))`. Parse `--since`/`--until` as ISO-8601 timestamps
(reuse the same parser as the API; on failure, `die` with a clear message). `--limit` is an
`option auto` defaulting to 50.

Acceptance for Milestone 3:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
cabal build shomei-admin
cabal run shomei-admin -- audit --help
```

`--help` lists `events`, `user`, `session`, `count`. A live end-to-end transcript is in
Validation and Acceptance below.

### Milestone 4 — Docs, runbook, and the admin-role limitation

Scope: make the new capability discoverable and record the one known limitation honestly. No
code behavior changes.

Step 4.1 — In `docs/security.md`, add a "Reading the audit trail" subsection near the existing
"Logging hygiene" material: explain that `shomei_auth_events` is append-only, that the CLI
(`shomei-admin audit …`) is the supported operator retrieval path, and that the HTTP endpoint
`GET /admin/audit/events` requires the `admin` role. State plainly the limitation: there is no
production flow yet to grant a user the `admin` role (login/signup do not issue roles), so the
HTTP endpoint is presently exercised only by tests and by deployments that mint admin tokens
out of band; the CLI is the path that works today for operators. Suggest the natural follow-up
(a role-granting admin command) without implementing it.

Step 4.2 — In `docs/plans/10-observability-structured-logging-metrics-and-health-probes.md`
(EP-3, which introduced the audit-event stream), add a short note pointing forward to this
plan (EP-7) as the retrieval surface, so a reader of the write side finds the read side.

Step 4.3 — Add an operator runbook transcript (in `docs/security.md` or wherever runbooks
live) showing: fail a login, then `shomei-admin audit events --type login_failed`, then
`shomei-admin audit user <uuid>`.

Step 4.4 — Update the MasterPlan
(`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`): add EP-7 to the
Exec-Plan Registry, tick the relevant Progress items, and note any cross-plan discoveries.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`.

Build everything and run the full test suite (the baseline you must keep green):

```bash
cabal build all
cabal test all
```

Per-milestone targeted builds/tests are listed in each milestone's acceptance block above.
The test suites that touch PostgreSQL (`shomei-postgres:shomei-postgres-test`,
`shomei-servant:test`) provision an ephemeral PostgreSQL automatically via
`shomei-migrations:test-support` (the `withShomeiMigratedDatabase` helper); no external
database setup is needed for tests.

Manual end-to-end against a real database requires `DATABASE_URL` to be set to a libpq
connection string, e.g.:

```bash
export DATABASE_URL='host=localhost dbname=shomei user=postgres'
cabal run shomei-admin -- migrate
cabal run shomei-admin -- audit events --limit 5
```

Expected `audit events` output once events exist (tab-separated; columns created_at,
event_type, user_id, session_id, event_id):

```text
2026-06-17T14:31:02Z    login_failed    -    -    7f3a...e1
2026-06-17T14:30:55Z    login_succeeded 2b9c...44   9d1e...07   3c0b...aa
```

## Validation and Acceptance

Milestone 1 is accepted when `cabal test shomei-postgres:shomei-postgres-test` passes with the
new interpreter tests, and the pure round-trip test proves all 16 event constructors survive
`toJSON → reconstructAuthEvent`. Demonstrate beyond compilation: the pagination test must show
that querying with `queryLimit = 2` and then re-querying with `queryBefore` set to the last
cursor returns the *next* two distinct rows (assert the event-id sets are disjoint and their
union is the full seeded set).

Milestone 2 is accepted when `cabal test shomei-servant:test` passes with: an admin-token
request to `GET /admin/audit/events` returning 200 and the seeded events newest-first; a
non-admin token returning 403; no token returning 401; a `?type=login_failed` request
returning only failed logins; and a two-page `?limit=1` + `?before=<nextCursor>` walk
returning disjoint pages. Manual HTTP check against a running server:

```bash
# in one shell
DATABASE_URL='host=localhost dbname=shomei user=postgres' cabal run shomei-server
# in another shell, with $TOKEN an admin-roled JWT (see note on the admin-role limitation)
curl -s -H "Authorization: Bearer $TOKEN" \
  'http://localhost:8080/admin/audit/events?type=login_failed&limit=10' | jq .
```

Expect a JSON object `{ "events": [ … ], "nextCursor": … }`. The same request with a
non-admin token returns HTTP 403 with body `missing required role`.

Milestone 3 is accepted when, against a database holding events, `shomei-admin audit events`,
`shomei-admin audit user <uuid>`, `shomei-admin audit session <uuid>`, and
`shomei-admin audit count` all print correct results, and `--json` emits valid NDJSON (pipe to
`jq -c .` to confirm each line parses).

Milestone 4 is accepted when `docs/security.md` documents the retrieval surfaces and the
admin-role limitation, and the MasterPlan registry lists EP-7.

The overall plan is accepted when `cabal build all && cabal test all` is green and the
end-to-end transcript in Concrete Steps reproduces.


## Idempotence and Recovery

This plan is purely additive and read-only with respect to data. It adds modules, one effect
effect, one interpreter, one HTTP route, one CLI subcommand group, and documentation; it changes
no existing behavior and requires no database migration. Re-running any build or test step is
safe. The query layer only issues `SELECT`/`COUNT` statements — there is no path by which the
CLI or API can mutate the audit table, by design (the audit trail is append-only and only the
existing `AuthEventPublisher` write interpreter inserts into it).

If a milestone's tests fail midway, the codebase remains buildable as long as each effect-stack
edit is completed as a unit: adding `AuthEventReader` to a stack list **and** its interpreter
to the matching chain must land together, or that package will not type-check. Commit at
milestone boundaries (and at clean sub-steps within a milestone) so a failed later step can be
reverted without losing earlier working state. Every commit must carry the three git trailers
(see Interfaces and Dependencies).


## Interfaces and Dependencies

Libraries already in the project that this plan uses: `effectful`/`effectful-core` (effect
effects and interpreters), `hasql` (SQL statements, encoders `Hasql.Encoders as E`, decoders
`Hasql.Decoders as D`, `Hasql.Session`, `Hasql.Statement.preparable`), `hasql-pool`
(`Hasql.Pool.Pool`, `use`), `aeson` (`Value`, `FromJSON`, `fromJSON`, `Result(..)`), `uuid`
(`Data.UUID` — `toText`, `fromText`), `time` (`UTCTime`,
`Data.Time.Format.ISO8601.iso8601Show`/`iso8601ParseM`), `servant`/`servant-server`
(`QueryParam`, `QueryParams`, `NamedRoutes`, `AuthProtect`), and `optparse-applicative`
(`hsubparser`, `command`, `strOption`, `many`, `option auto`, `argument`). No new dependency
is introduced; if the `hasql` text-array encoder name differs by version, that is resolved by
reading the installed `hasql` source via `mori` (see Step 1.4), not by adding a package.

New modules and the signatures that must exist at the end of each milestone:

End of Milestone 1:

- `Shomei.Domain.EventCodec.reconstructAuthEvent :: Text -> Aeson.Value -> Either String AuthEvent`
- `Shomei.Effect.AuthEventReader` exporting `AuthEventReader (..)`, `AuditEventQuery (..)`,
  `AuditCursor (..)`, `StoredAuthEvent (..)`, `emptyAuditQuery`, `maxAuditLimit`,
  `clampLimit`, `queryAuthEvents :: (AuthEventReader :> es) => AuditEventQuery -> Eff es
  [StoredAuthEvent]`, `countAuthEvents :: (AuthEventReader :> es) => AuditEventQuery -> Eff es
  Int`
- `Shomei.Postgres.AuthEventReader.runAuthEventReaderPostgres :: (Database :> es, IOE :> es,
  Error AuthError :> es) => Eff (AuthEventReader : es) a -> Eff es a`

End of Milestone 2:

- `AuthEventReader` present in `Shomei.Servant.Seam.AppEffects` and in the server's
  `runAppIO` interpreter chain (`Shomei.Server.App`).
- `Shomei.Servant.DTO.AuditEventResponse`, `Shomei.Servant.DTO.AuditEventsPage`,
  `storedToResponse`, and a cursor codec (`encodeCursor`/`decodeCursor`).
- `auditEvents` field on `ShomeiAPI` and `auditEventsH` wired into `shomeiServer`.

End of Milestone 3:

- `Shomei.Admin.Audit` (in `shomei-server/app/`) with `runAuditReader` and the `audit*`
  actions; `Audit AuditCommand` wired into `Admin.hs`'s `Command`/`commandParser`/`run`; the
  module listed in the `executable shomei-admin` `other-modules`.

Integration points with MasterPlan 2 (record these in the MasterPlan's Integration Points and
Exec-Plan Registry): this plan **consumes** the `shomei_auth_events` table and the event
vocabulary defined by EP-3 (Observability) and written by EP-2 (Abuse protection) and the
account-lifecycle flows of EP-1. It adds the read counterpart to EP-3's write-only event
stream. It extends the `shomei-admin` CLI introduced by EP-4 (Operational CLI) with a new
subcommand group, and the `ShomeiAPI`/authz seam from MasterPlan 1's EP-5 (Servant
integration). The shared effect-stack lists (`Shomei.Servant.Seam.AppEffects`,
`Shomei.Server.App`'s `runAppIO`, and the `shomei-postgres` test `AppEffects`) are the
concrete integration surface: EP-7 adds one entry (`AuthEventReader`) to each, mirroring
`AuthEventPublisher`.

Git trailers — every commit while implementing this plan must include all three:

```text
MasterPlan: docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md
ExecPlan: docs/plans/14-audit-log-retrieval-api-and-cli.md
Intention: intention_01kvayjq71ek8v4e6vw4jkxtys
```
