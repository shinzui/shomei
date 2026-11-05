# Changelog for shomei-postgres

All notable changes to `shomei-postgres` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- **Breaking:** user and credential interpreters require `Clock`; password change/reset stamp credential `updated_at` with the workflow transaction timestamp. Repeated session revocation preserves its original timestamp. Migration 0042 adds measured user-list and per-user audit indexes.

- **Breaking:** PostgreSQL assembly uses the managed `Shomei.Persistence.Pool.Postgres.Pool` and its `UsageError`, `use` and `release` operations. Interrupted/failed sessions discard their connection and restore capacity; the external pool dependency is removed.

- Machine and delegated mints atomically enforce the configurable active principal ceiling (default 1000), preserving existing sessions after lowering the cap. Expiry frees capacity; finite sweeper retention bounds ordinary history by issuance rate and retention.

- **Breaking:** database transactions use the bounded statement wrapper; session bulk revocation returns winning IDs and the audited unit of work returns a count. Administrative session HTTP listing returns a keyset page (default 50, maximum 200). Server transaction limits default to three attempts/five seconds.

- Enforce finite new-write identity, display-name, passkey-label and role/scope budgets; preserve legacy identity authentication and snapshots. Login passwords over 256 code points fail before credential proof accounting. PostgreSQL adds migration 0039; see `docs/user/input-limits.md`.

- **Breaking:** passkey enrollment locks the account, counts, and inserts in one transaction;
  callers pass a 1–100 ceiling and handle `PasskeyLimitReached`.

- **Upgrade required:** TOTP envelopes bind both row identifiers; normal reads reject legacy
  ciphertext. Apply migration 0038 and run the offline converter before starting new hosts.
- Add keyless envelope-version inspection and resumable conversion in batches of 100.
- Require `hasql-transaction >=1.2.1` for the explicit no-retry transaction primitive.

- The session store persists and reads `shomei_sessions.remembered`.

## 0.2.0.0 — 2026-08-27

- **Breaking:** requires `shomei-core ^>=0.2.0.0` and `shomei-migrations ^>=0.2.0.0`.
- **Breaking:** `acquirePool` accepts a statement-timeout argument and installs both
  `statement_timeout` and `idle_in_transaction_session_timeout` on every new connection.
- Password hashes are fully evaluated inside the configured concurrency-limiter permit, before
  a credential store acquires a database connection; Argon2 implementation rejections now surface
  as the typed `Argon2Failure` exception. Shared hard-floor validation and a real trial derivation
  let server and CLI boot paths reject unsupported costs before serving work.
- **Breaking:** interpreters implement the new atomic login-attempt, counter, user-status,
  revocation, and credential-tail ports. Per-account failure counting uses a transaction-scoped
  advisory lock; conditional updates and unit-of-work transactions expose exactly one winner.
- Unique identity violations retain their typed login/email conflict at the persistence boundary;
  unknown PostgreSQL write failures remain opaque dependency errors.
- **Breaking:** the signing-key interpreter persists `revoked_at`, stamps activation, retirement,
  and revocation times, and implements atomic active-key replacement in one transaction.
- Session-store and authentication-unit-of-work interpreters now write session provenance and
  read legacy `NULL` provenance as `interactive`.
- Sessions round-trip their OAuth granted scopes, and consumed authorization codes can bind and
  recover the session minted by their first exchange for replay response.

## 0.1.0.0 — 2026-08-24

Initial release. Production `hasql` interpreters for Shōmei's ports.

- A PostgreSQL interpreter for every store: users, credentials, sessions,
  refresh tokens, lifecycle tokens, login attempts, roles and grants,
  service accounts, OAuth clients and authorization codes, TOTP secrets and
  recovery codes, passkeys and pending ceremonies, and signing keys — plus
  the audit-event publisher and the read/query layer behind
  `GET /admin/audit/events`.
- Argon2id password hashing with configurable, self-describing parameters
  and a bound on how many hashes run concurrently, and SHA-256 token
  hashing.
- Connection pooling and a transactional unit of work, so the auth write
  tails commit atomically. One-time token consumption and refresh-token
  rotation are compare-and-swap.
- A batched sweep engine for expired data.
