# Changelog for shomei-postgres

All notable changes to `shomei-postgres` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- Password hashes are fully evaluated inside the configured concurrency-limiter permit, before
  a credential store acquires a database connection; Argon2 implementation rejections now surface
  as the typed `Argon2Failure` exception.
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
