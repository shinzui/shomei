# Changelog for shomei-migrations

All notable changes to `shomei-migrations` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## 0.2.0.0 — 2026-08-27

- **Breaking:** every migration in the 36-file history was rewritten to schema-qualify each Shōmei
  relation and to use a transaction-local `SET LOCAL search_path = pg_catalog, pg_temp`, so Shōmei
  no longer leaks session namespace state into a host application that composes other migration
  components. The SQL bytes changed, so **`pg-migrate` checksums differ from `0.1.0.0`**: a database
  that already applied the `0.1.0.0` files will fail checksum verification and needs an operator
  remediation of its ledger rather than a plain upgrade.
- Enforce one password credential per user with
  `shomei_password_credentials_user_id_key`, which also indexes password update lookups.
- Add database `CHECK` constraints for persisted status, outcome, ceremony-kind, and OAuth-client
  vocabulary, plus case-insensitive unique indexes for user and password-credential login ids and
  email addresses.
- Add `shomei_signing_keys.revoked_at` and the partial unique index
  `shomei_signing_keys_one_active`; migration normalizes legacy multi-active rows before enforcing
  the invariant.
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
