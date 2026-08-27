# Changelog for shomei-core

All notable changes to `shomei-core` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- **Breaking:** `configSigningAlgorithm` now returns `Either Text SigningAlgorithm`; embedding
  applications must reject invalid hand-built signing configuration instead of receiving an
  implicit `ES256` fallback.
- **Breaking:** login-attempt recording, TOTP/passkey counters, user-status changes, session
  revocation, and credential-reset tails now expose compare-and-swap or transactional operations.
  Single-use transitions report whether they won, login failures are recorded and counted
  atomically, and password reset/change revokes every affected session in the same unit of work.
- **Breaking:** `StoredSigningKey` gains `revokedAt`, and `SigningKeyStore` gains the atomic
  `ReplaceActiveSigningKey` operation. The in-memory interpreter stamps every lifecycle timestamp.
- **Breaking:** `SigningKeyConfig` gains `allowedClockSkewSeconds`; the reserved custom-claim set
  now also excludes `nbf` and `jti`.
- **Breaking:** `Session` and `NewSession` now carry a `kind` that records whether the session was
  established interactively, by `client_credentials`, or by delegation.
- OAuth authorize accepts only a live interactive session and refuses machine, delegated, or
  explicit-actor credentials.
- RFC 8693 exchange and impersonation always verify the presented session; impersonation also
  requires an active operator account.
- Authorization-code exchange now honours `emailVerificationRequired`.
- OAuth sessions persist their granted scopes; refresh preserves them and refuses a minting-client
  mismatch, including use through the bespoke refresh workflow.
- OAuth-client registration and authorize refuse reserved privilege scopes while service accounts
  remain their intended holders.
- Authorization-code rows bind to their minted sessions; replay revokes the session and refresh
  family and emits `oauth_code_replayed`. The core revocation policy models client and
  service-account ownership plus the `shomei:admin` escape hatch.

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
