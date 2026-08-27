---
type: Review
title: shomei-postgres interpreters, transactions, hashing, and the sweeper
description: >-
  Every statement is parameterized, every documented compare-and-swap is one conditional
  RETURNING statement, and the hot paths are indexed, but HashPassword's Argon2 thunk escapes
  the hashing limiter and is forced while a pool connection is held, the TOTP and passkey
  counter updates are unconditional, the reset and change tails are not transactional, and
  boot admits Argon2 parameters that make every derivation throw — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-5
subject: mori://shinzui/shomei/packages/shomei-postgres
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
  - security
  - correctness
  - performance
  - operability
  - test-coverage
  - documentation
context: >-
  One reader agent read every interpreter under src/, the port GADTs in shomei-core each one
  implements (with their doc comments, to compare promised and delivered atomicity), the
  UnitOfWork interpreter, and the pool, hashing, and sweeper wiring in Shomei.Server.Boot and
  Config; it read hasql 1.10, hasql-pool 1.4, hasql-transaction 1.2, crypton 1.1.4
  (Argon2 bindings and the C validate_inputs), and memory 0.18 constEq in source. The
  test suite was read by inventory plus the CAS, round-trip-budget, race, and limiter
  sections. The review of record re-read the hashing interpreter and credential store
  before grading the top finding. The shomei-postgres suite passed at the commit on an
  ephemeral PostgreSQL 17.10.
---

# shomei-postgres interpreters, transactions, hashing, and the sweeper

## Verdict

Changes requested. The persistence layer delivers the atomicity the workflows assume where the
July hardening put it: the refresh-token `markUsedStmt` is `UPDATE … WHERE … AND status =
'active' RETURNING` lifted unchanged into a READ COMMITTED transaction with the child insert and
event; verification and reset tokens, authorization codes, recovery codes, and pending
ceremonies are each one conditional statement; lockout counts derive from an append-only log
with an `ON CONFLICT` upsert. No statement interpolates an identifier, sort direction, or user
text — the audit reader's optional filters and `event_type` list are bound as `$n IS NULL OR`
predicates and a `text[]` parameter, and the `"SELECT " <> selectCols` concatenations are
compile-time constants. Argon2 verification re-derives with the parameters embedded in the stored
PHC string, compares with `constEq`, and is forced with `evaluate` inside the permit; the dummy
path derives against a hash carrying the configured parameters.

The findings are the places where a newer store copied the read-then-write shape instead of the
CAS shape, one thunk that slipped past the limiter, and a boot check that is weaker than the C
library it fronts.

## Findings

**1. High — `HashPassword`'s derivation escapes the limiter and runs inside `Pool.use`.**
`hashPasswordArgon2id` returns `pure (PasswordHash (phcEncode params salt digest))` with
`digest` a lazy `deriveArgon2` thunk (`src/Shomei/Account/Password/Hash/Postgres.hs:168-173`);
the `HashPassword` arm is `withHashingPermit limiter (hashPasswordArgon2id params pw)` with no
`evaluate`, while both `Verify*` arms have one (`:290-298`); `PasswordHash` is a non-strict newtype
over `Text`. The 64 MiB, ~100 ms derivation is therefore forced when hasql serializes
`passwordHashText pwHash` for `insertCredentialStmt` or `updatePasswordHashStmt` — on the request
thread, inside `runSession`, holding one of ten pooled connections, in an `unsafe` FFI call that
pins a capability. N concurrent signups or password changes hold N connections for the hash
duration and allocate N × 64 MiB with no bound; at N ≥ 10 every other request queues to the
acquisition timeout and gets `503`. The regression test forks eight `hashPassword` calls and
asserts a peak of two permits but never forces the returned hash (`test/Main.hs:1878-1896`), so
it passes with the escape. The exact forcing point inside hasql was inferred from the lazy row
tuple at `src/Shomei/Account/Credential/Postgres.hs:37-38`, not traced into the engine. Remedy:
`evaluate` the PHC text inside the permit; make the test force its results and assert on
wall-clock overlap.

**2. Medium — TOTP replay protection is read-then-write.**
`UPDATE shomei.shomei_totp_credentials SET last_used_counter = $2 WHERE totp_credential_id = $1`
(`src/Shomei/Mfa/Totp/Postgres.hs:226-235`) has no `last_used_counter < $2` guard; the
workflow compares against a value read one statement earlier. Two concurrent submissions of one
code both succeed. Same shape for the passkey `sign_counter`
(`src/Shomei/Passkey/Postgres.hs:207-220`). Remedy: `… AND (last_used_counter IS NULL OR
last_used_counter < $2) RETURNING`, port returns `Bool`, workflow treats `False` as replay.

**3. Medium — the password-reset and password-change tails are autocommit sequences.**
Consume CAS → `updatePasswordHash` → `revokeAllUserSessions` → `revokeAllUserRefreshTokens` →
event are four or five separate `runSession` checkouts
(`shomei-core/src/Shomei/Account/Lifecycle/Workflow.hs:202-207, 236-239`); only
`Session/UnitOfWork/Postgres.hs` uses `runTransaction`. A failure after the hash update leaves
stolen sessions alive for their absolute lifetime; a failure between consume and update burns
the one-time token without changing the password. Remedy: an `AuthUnitOfWork` operation lifting
the existing statements into one `Tx`, mirroring `RotateRefreshToken` (and keeping the Argon2
hash outside it).

**4. Medium — boot admits Argon2 parameters that make every derivation throw.** Config requires
each value to be positive only; the reference implementation requires `m_cost ≥ 8` and
`m_cost ≥ 8 × lanes` (`crypton/cbits/argon2/core.c:525-527`), and crypton turns a C rejection
into `error "argon2: hash: internal error"` (`Crypto/KDF/Argon2.hs:133`), which `deriveArgon2`
does not catch (`Hash/Postgres.hs:117-122`). `SHOMEI_ARGON2_PARALLELISM=16` with
`SHOMEI_ARGON2_MEMORY_KIB=64` boots with a warning and then answers `500` to every signup,
failing login, and password change. Remedy: validate `memoryKiB ≥ max 8 (8 × parallelism)` or
trial-hash at boot.

**5. Medium — `shomei_password_credentials.user_id` has no index**, so `updatePasswordHashStmt`
(`src/Shomei/Account/Credential/Postgres.hs:141-143`) sequentially scans the table on every
reset and change. Migration in REV-6.

**6. Low — signing-key status updates discard their timestamp.** `UpdateSigningKeyStatus kid st
_t` writes `status` only (`src/Shomei/SigningKey/Postgres.hs:45-47, 156`), so `rotateSigningKey`
never stamps `retired_at`, and nothing enforces one active key (REV-3, REV-6, REV-8).

**7. Low — the reuse-detection and logout tails are three separate autocommits**
(`Authentication/Workflow.hs:421-426, 443-447`); a failure between family revoke and session
revoke leaves a session active with its tokens revoked.

**8. Low — audit payload PII.** Emails, login ids, client IPs, and the raw identifier from a
failed login are persisted in JSONB with no retention by default
(`src/Shomei/Persistence/Maintenance/Postgres.hs:96`); no raw token, code, or secret is
(verified by field scan; `NotificationDeliveryFailed` excludes the token by construction —
though REV-8 shows the error text can carry one).

**9. Low — operational gaps.** No `statement_timeout` or `idle_in_transaction_session_timeout`
is set (`src/Shomei/Persistence/Pool/Postgres.hs:20-28` has no `initSession`); the sweeper drains
each table to zero on the request pool with no pause between batches
(`Maintenance/Postgres.hs:209-219`), so a first-time enable of audit retention on a large table
occupies one connection continuously; `Tx.transaction`'s retry on 40001/40P01 is an unbounded
`fix` loop.

**10. Info — minor interpreter inconsistencies.** `revokeSessionStmt` overwrites `revoked_at` on
a repeat revoke (the bulk variant guards `status = 'active'`); `User/Postgres.hs:181` uses database
`now()` for `updated_at` while every other write uses the app clock, and two stores call
`getCurrentTime` directly rather than the `Clock` port; `updatePasswordHashStmt` does not bump
`updated_at`; `DeleteExpiredAuthorizationCodes` is an unbatched delete that the sweeper does not
use.

**11. Info — documentation.** `security.md:8-9` names `shomei-postgres/src/Shomei/Crypto.hs`
and the `argon2id$salt$hash` format; the module is `Account/Password/Hash/Postgres.hs` and only
PHC strings verify (`:177-191`). MasterPlan 6 still says "legacy hashes still verify" (rejected
without hashing since commit e566bcb) and 11→7 login round-trips (the pinned budget is 10,
`test/Main.hs:1247`). `deployment.md:313`'s sweep log example omits the `authorization_codes` and
`role_grants` keys; `:376-379` describes lockout rows with `NULL locked_until` that the workflow
never writes.

**12. Info — test coverage.** The only database-level race is
`testAuthorizationCodeConsumeIsAtomicUnderRace`; refresh CAS, one-time tokens, recovery codes,
and ceremonies are sequential double-call tests; nothing races the rotation transaction, the
counters, or the sweeper against live rotation.

## Verified holds

- Parameterization: every statement is `Hasql.Statement.preparable` with positional parameters;
  dynamic audit filters at `src/Shomei/Audit/Reader/Postgres.hs:89-102, 140-165`; role union
  `role = ANY ($1)`; sweeper SQL literal with `$1`/`$2`; pg-migrate's ledger quotes identifiers.
- CAS statements: refresh `:179-190` in the transaction at `UnitOfWork/Postgres.hs:85-96`
  (`BEGIN ISOLATION LEVEL READ COMMITTED READ WRITE`); verification and reset consume
  `:147-158` in each store; authorization code `:138-154` (raced in test); pending ceremony
  `DELETE … RETURNING` then expiry filter; recovery code `:84-98`; lockout `ON CONFLICT`.
- `PersistNewSession` is one transaction with ids generated before `BEGIN`; the `Transaction`
  monad has no `MonadIO`, so no notifier or HTTP call can run inside one; failure-path audit
  events are autocommit outside any transaction.
- Pool: size 10, acquisition 10 s, aging and idleness from hasql-pool defaults;
  `AcquisitionTimeoutUsageError` collapses to `DependencyUnavailable PostgreSQL` → `503`;
  `VerifyTokenAndSession` is exactly one checkout per request; every statement is server-prepared.
- Argon2 verify side: 64 MiB / 3 / 1 defaults; stored-parameter re-derivation so retuning never
  invalidates credentials; 16-byte salt and 32-byte digest from `getRandomBytes`; `constEq`;
  `evaluate` inside the permit; dummy hash with configured parameters; limiter blocks rather than
  fails.
- Opaque-token hashing: 32 random bytes → base64url(SHA-256), `token_hash UNIQUE` on all three
  tables; authorization codes `sha256Hex` as primary key; secrets SHA-256 hex with `constEq`.
- Sweeper: batches of 1000 by `ctid IN (… LIMIT n)`, one autocommit per batch, FK-safe order,
  30-day dead-session grace ≥ session TTL with child expiry capped at the session deadline, so no
  live token is ever referenced by a swept session; audit retention off by default; families
  never split (tested).
- Codec: KindID ↔ `uuid` lossless; microsecond `timestamptz` cannot flip an expiry decision
  because CAS predicates use the same truncated parameter.

## Index coverage

Covered: user by login id and by email (raw-text unique indexes; the app normalizes), user by
id, credential by login id and email, session by id and user, refresh token by hash, session,
parent, and id, login-attempt failures and successes by account key and failures by IP (partial
indexes matching the predicates), lockout by key, role grants by user and role, role permissions
by role, service account and OAuth client by client id, authorization code by hash, passkey by
credential id, user, and user handle, pending ceremony by id, TOTP by user, recovery codes by
user, audit keyset and single-column filters, and every sweeper predicate. Missing:
`shomei_password_credentials (user_id)` (finding 5); the admin users list keyset
`(created_at, user_id)`; OAuth client list order; signing keys by status (tiny table); a
composite `(user_id, created_at, event_id)` for per-user audit timelines on very large tables.

## Not examined

Test bodies at `test/Main.hs:1188-1445` and `:1915-2130` and the harness at `:250-555` were
skimmed; the exact point inside hasql where `Statement.serializer` runs relative to checkout;
`Connection.use` on async exceptions; the admin CLI's own SQL under `shomei-server/app`; hasql-pool
`Config/Setting.hs`; memory's C `memConstEqual`.
