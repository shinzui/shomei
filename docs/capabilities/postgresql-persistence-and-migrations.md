---
title: "PostgreSQL persistence with embedded, composable migrations"
type: Capability
description: "Run every Shomei port on PostgreSQL through hasql, with the schema embedded at compile time as a pg-migrate component a host can compose into its own migration plan."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-postgres
  - shomei-migrations
interface:
  - Shomei.Persistence.Database.Postgres
  - Shomei.Persistence.Pool.Postgres
  - Shomei.Persistence.Maintenance.Postgres
  - Shomei.Migrations
  - Shomei.Migrations.TestSupport
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: Every store round-trips against a real PostgreSQL, the single-use consumes are compare-and-swap, two racing consumers produce exactly one winner, and the maintenance sweep deletes exactly the dead rows without splitting a refresh-token family.
  - kind: module
    resource: shomei-migrations/src/Shomei/Migrations.hs
    proves: The schema is embedded from an ordered manifest at compile time and exported as a MigrationComponent a host can compose with its own.
  - kind: module
    resource: shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs
    proves: A public sublibrary that stands an ephemeral migrated PostgreSQL up for a consumer's own tests.
  - kind: guide
    resource: docs/user/deployment.md
    proves: Migration commands, the retention sweeper's windows, and the operator runbook.
---

# PostgreSQL persistence with embedded, composable migrations

**Builds on:** [CAP-1 — transport-agnostic authentication core](transport-agnostic-auth-core.md).

`shomei-postgres` supplies a `hasql` interpreter for every port `shomei-core` declares — users,
credentials, sessions, refresh tokens, roles, passkeys, TOTP, service accounts, OAuth clients,
authorization codes, signing keys, audit events, login attempts, and the unit of work — plus
Argon2id password hashing and SHA-256 token hashing.

The schema lives in `shomei-migrations` and is **embedded at compile time** from an ordered
manifest, so a built binary never reads a migration directory at runtime. It is exported as a
composable component:

```haskell
import Shomei.Migrations (shomeiMigrationComponent)

-- One plan, one ledger, for Shomei's tables and your own.
plan = migrationPlan (shomeiMigrationComponent :| [myAppComponent])
```

A host that owns no migrations of its own can use `applyShomeiMigrations connStr` or the
`shomei-migrate` executable instead. Applying is idempotent.

Two things worth knowing about the interpreters:

- **Single-use really is single-use.** Consuming a refresh token, a verification token, a
  password-reset token, or an OAuth authorization code is a compare-and-swap; the test suite
  races two consumers and asserts exactly one wins.
- **Round-trip budgets are asserted.** A successful login costs exactly 10 database round-trips
  and a refresh exactly 5, enforced by a test, so an accidental N+1 shows up as a failure rather
  than as latency.

`Shomei.Persistence.Maintenance.Postgres` is the retention sweeper: it deletes expired sessions,
spent refresh tokens, dead one-time tokens, and — only when a retention window is configured —
old audit events. It works in batches, never splits a refresh-token rotation family across
batches, and a second sweep over a clean database is a no-op. Run it periodically in-process (the
standalone server forks it) or once with `shomei-admin sweep`.

## Limits

- **PostgreSQL only.** There is no second production interpreter set, and some behavior a
  consumer depends on — the compare-and-swap consumes above — is a property of these
  interpreters rather than of the ports.
- The schema occupies the `shomei` PostgreSQL schema and tracks applied migrations in
  `pg-migrate`'s own ledger. A host composing components shares that ledger; two plans over one
  database is not a supported topology.
- The test-support sublibrary stands up an **ephemeral** PostgreSQL per suite. It is heavy —
  Shōmei's own suites want `--test-options='-j2'` to keep the load reasonable.
- Audit-event retention is **opt-in**. With no window configured the sweeper deliberately leaves
  audit rows alone and the table grows without bound.
