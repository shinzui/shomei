# Changelog for shomei-core

All notable changes to `shomei-core` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## 0.1.0.0 — 2026-08-24

Initial release. The transport-agnostic heart of the Shōmei authentication
toolkit.

- Domain model for accounts, sessions, credentials, and audit events. The
  principal is a free-form, case-insensitive `loginId` with email as an
  optional attribute; email-first callers keep working because `loginId`
  defaults to the email when only an email is supplied.
- `effectful` port interfaces for every side effect — user, credential,
  session, refresh-token, one-time-token, role, service-account, OAuth client
  and authorization-code, MFA, passkey, and signing-key stores, plus the
  clock, token generator, audit publisher/reader, notifier, and breach
  checker — with an in-memory interpreter (`Shomei.Test.InMemory`) for tests.
- Account lifecycle workflows: signup, login, refresh, logout, email
  verification, and password reset/change. One-time token consumption and
  refresh-token rotation are compare-and-swap operations, and the write tails
  are made atomic by an `AuthUnitOfWork` port.
- Password policy with configurable rules, context-aware validation,
  an embedded common-password dictionary, and a `PasswordBreached` violation
  backed by a `PasswordBreachChecker` port.
- Authorization: a role registry, role-permission tables, expiring role
  grants, claims enrichment from the role catalog at every mint, and a
  reserved `permissions` claim.
- OAuth 2.0 / OpenID Connect: authorization-code, refresh, and
  `client_credentials` grants, ID tokens, database-backed service accounts,
  and the RFC 8693 token-exchange (delegation and impersonation) workflow
  with an `act` actor claim.
- Multi-factor authentication: RFC 6238 TOTP, recovery codes, and the
  WebAuthn passkey ceremony port for enrollment, step-up, and passwordless
  login.
- Abuse protection: brute-force account lockout and per-IP/per-account
  throttling. Absolute session expiry is enforced in refresh and token
  verification, and login is free of an account-enumeration timing oracle.
