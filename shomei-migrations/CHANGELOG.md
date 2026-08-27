# Changelog for shomei-migrations

All notable changes to `shomei-migrations` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- Add the nullable, defaulted `shomei_sessions.kind` column for interactive, machine, and delegated
  session provenance without rewriting existing rows.
- Add `shomei_sessions.granted_scopes` for refresh-stable OAuth grants and nullable
  `shomei_oauth_authorization_codes.session_id` for consumed-code replay revocation.

## 0.1.0.0 — 2026-08-24

Initial release. Owns Shōmei's PostgreSQL schema.

- Embeds Shōmei's ordered SQL manifest at compile time with
  `pg-migrate-embed` and exposes it as a `pg-migrate` `MigrationComponent`,
  so an embedding host composes one migration plan instead of running two.
- Covers the full schema: users and credentials, sessions and refresh
  tokens, lifecycle tokens, login attempts and lockout state, roles and
  role permissions with expiring grants, service accounts, OAuth clients and
  authorization codes, encrypted TOTP secrets and hashed recovery codes,
  passkeys and pending ceremonies, audit events, and signing keys. Includes
  the expiry indexes the sweeper needs.
- Ships the `shomei-migrate` executable for standalone migration runs.
- Ships a public `test-support` sublibrary that provisions a fresh
  ephemeral PostgreSQL with the schema already applied.
