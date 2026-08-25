# Changelog for shomei-postgres

All notable changes to `shomei-postgres` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

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
