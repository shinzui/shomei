---
type: Review
title: shomei-migrations schema and the pg-migrate embedding
description: >-
  All 28 migrations are idempotent, timestamptz-typed, search_path-safe under pg-migrate's
  dedicated connection, and impossible to leave out of the embedded manifest, but the schema
  lacks a unique index on password credentials by user, a partial unique index for the single
  active signing key, CHECK constraints on text statuses, and case-insensitive uniqueness, and
  the PostgreSQL 17/18 floor is undocumented — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-6
subject: mori://shinzui/shomei/packages/shomei-migrations
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - correctness
  - performance
  - operability
  - design
context: >-
  The persistence reader agent read all 28 SQL files, the manifest, Shomei.Migrations, the
  shomei-migrate executable, the test-support sublibrary, and pg-migrate 1.1.0.0 and
  pg-migrate-embed in source (runner transactions, advisory lock, ledger DDL, the
  no-transaction directive, manifest embedding checks, RecompilePlugin) to establish what the
  embedding guarantees. Index coverage was assessed against every statement in
  shomei-postgres. The migrations were applied by the shomei-postgres and shomei-server
  suites on an ephemeral PostgreSQL 17.10 at the commit.
---

# shomei-migrations schema and the pg-migrate embedding

## Verdict

Changes requested, all schema additions rather than corrections. The migrations are safe to
apply and to compose: every file after `0001` begins `SET search_path TO shomei, pg_catalog;`,
all references are unqualified and resolve into `shomei`, and the setting cannot leak because
pg-migrate runs on a dedicated connection released before the application pool is acquired and
its ledger uses fully qualified `"pgmigrate"."…"` names (a sibling project was bitten by exactly
this leak, so it was checked deliberately). Each migration runs as one transaction with the
ledger insert and a post-commit existence check, serialized by `pg_try_advisory_lock`. Every
`CREATE` is `IF NOT EXISTS`, backfills are guarded, nothing drops data, every timestamp is
`timestamptz`, audit rows have no FK and survive user deletion, role grants cascade, and every
other FK is `RESTRICT`, which is consistent with soft deletion. The hazard MasterPlan 6 recorded
— a migration invisible until listed — is gone: `embedMigrationManifest` fails compilation on an
unlisted, missing, or duplicate file, and the `RecompilePlugin` forces re-embedding.

## Findings

**1. Medium — no index on `shomei_password_credentials (user_id)`.** The FK at `0003:5` has no
supporting index and `0018`/`0019` add only login-id and email indexes; `UPDATE … WHERE user_id =
$1` on every password reset and change is a sequential scan. One credential per user is the
implicit invariant, so `CREATE UNIQUE INDEX … (user_id)` both fixes the scan and states it.
Related unindexed FK columns that matter only for hard deletes the soft-delete model never
performs: `shomei_webauthn_pending_ceremonies.user_id` (`0015:5`), `shomei_role_grants.granted_by`
(`0021:22`), `shomei_oauth_authorization_codes.user_id` (`0024:34`).

**2. Medium — "exactly one active signing key" is not a database invariant.** `0006` has no
`UNIQUE … WHERE status = 'active'`; the activation path is two autocommit statements (REV-8) and
`rotateSigningKey` inserts before retiring (REV-3). `CREATE UNIQUE INDEX shomei_signing_keys_one_active
ON shomei_signing_keys ((1)) WHERE status = 'active'` makes a second active key an error instead
of a newest-wins heuristic.

**3. Low — text statuses without `CHECK`, and case-insensitive uniqueness enforced only in the
application.** `status`/`kind`/`client_type`/`outcome` columns at `0002:7, 0004:6, 0005:8,
0006:10, 0009:7, 0010:7, 0011:7, 0015:6, 0022:31, 0023:32-33` accept any text; the unique
indexes at `0016:16-17` and `0017:12-14` are on raw `login_id`/`email` while the application
lowercases before every write and read. An out-of-band insert (a host application, `psql`) can
create `Alice@Example.com` beside `alice@example.com` or an unknown status, and the decoders then
fail the row with `InternalAuthError`. Haskell `toLower` and PostgreSQL `lower()` also differ for
some Unicode. Remedy: `CHECK (status IN (…))` per table; expression indexes on `lower(…)` or
`citext`.

**4. Low — index builds and backfills take locks a populated host will feel.** Every migration
runs in a transaction, so `CREATE INDEX CONCURRENTLY` is unavailable unless a file carries
`-- pg-migrate: no-transaction`; none does. `0016:8-17` updates every user row, sets `NOT NULL`,
and builds a unique index in one transaction; `0018:8-17` and the five plain `CREATE INDEX` in
`0020:12-32` follow. Fine for a fresh 0.1.0.0 install; a host composing these into a populated
database takes `SHARE` locks on `shomei_sessions`, `shomei_auth_events`, and
`shomei_login_attempts` and an `ACCESS EXCLUSIVE` full scan on `shomei_users`. Also, pg-migrate
refuses servers other than major 17 and 18 (`Runner/Connection.hs:37-42`) and `deployment.md`
states no version floor.

## Verified holds

- `search_path`: set per migration, resolved by pg-migrate's dedicated connection
  (`Runner/Connection.hs:20-28`), `applyShomeiMigrations` runs before `acquirePool`
  (`Boot.hs:284-300`); ledger fully qualified (`Ledger/Sql.hs:46-48, 483-552`).
- One transaction per migration with post-commit verification (`Runner.hs:288-321, 341-363`);
  advisory lock polled every 50 ms (`Runner/Lock.hs:26-64`).
- Embedding: unlisted `.sql` → `UnlistedSqlFiles` compile error; missing, duplicate, nested,
  non-`.sql`, and BOM'd entries rejected (`Embed/Manifest.hs:35-52, 74-86, 142-180`); every file a
  TH dependency plus `RecompilePlugin` (`Migrations.hs:2, 35`).
- Idempotency and guards: `IF NOT EXISTS`/`IF EXISTS` throughout; `WHERE login_id IS NULL`
  backfills (`0016:8-10`, `0018:8-10`); no destructive statement in 28 files.
- FK semantics: audit events no FK (`0007`); `shomei_role_grants.user_id ON DELETE CASCADE`
  (`0021:20`); all others `RESTRICT`; `parent_token_id` `NO ACTION` so families cannot be
  orphaned.
- Index coverage for every hot query and every sweeper predicate (table in REV-5), including the
  partial `(account_key, occurred_at) WHERE outcome = 'failure'` / `'success'` and
  `(client_ip, occurred_at)` indexes at `0011:13-24` that match the lockout counting shapes
  exactly, and the `(created_at DESC, event_id DESC)` audit keyset index at `0020:31-32`.

## Not examined

pg-migrate `Sql/Scanner.hs` directive parsing beyond the no-transaction directive,
`Definition.hs` beyond `sqlMigration`/`migrationComponentFromEmbeddedSql`, `Repair.hs`, and
`History.hs`; whether any host currently composes `shomeiMigrationComponent` with another
component.
