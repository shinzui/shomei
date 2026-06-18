# Changelog

All notable changes to Shōmei are documented here. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versioning is date-based pre-1.0 and will move
to semantic versioning (`MAJOR.MINOR.PATCH`) and git tags (`vMAJOR.MINOR.PATCH`) at the first
tagged release.

## Unreleased

### Added — MasterPlan 2 (Production Hardening, Account Lifecycle, and Adoption)

- **Account lifecycle (EP-1):** email verification and password reset/change behind a pluggable
  `Notifier` effect. Shōmei emits each notification (recipient, one-time link/token, expiry) and
  ships a development log-only sender; it does not deliver email — operators forward the
  notification to their own provider (SendGrid, Resend, SES, an SMTP relay, …) via their own
  `Notifier` interpreter. A future `shomei-email` package may add in-tree senders.
- **Abuse protection (EP-2):** per-account brute-force lockout, per-IP failure throttle, and a
  per-IP request-rate WAI token bucket; all responses generic (no account-existence leak).
- **Observability (EP-3):** structured JSON request logs with correlation ids, a hand-rolled
  Prometheus `/metrics` endpoint, a `/ready` readiness probe distinct from `/health`, and
  graceful shutdown on SIGTERM/SIGINT.
- **Operational CLI (EP-4):** `shomei-admin` with `migrate`, `keys
  generate/activate/retire/revoke/list`, and `users create`; zero-downtime signing-key rotation
  (`pending → active → retired → revoked`) with overlapping-key JWKS verification.
- **Packaging & config (EP-5):** typed Dhall + environment configuration loader; a production
  OCI image via the Nix flake; a local `process-compose` stack (PostgreSQL on a Unix socket +
  the server) for development/test; and a CI pipeline.

### Changed — Generalized login identifier with optional email (SH-25)

- **The principal is now a free-form login identifier (`LoginId`), not the email.** A new
  `Shomei.Domain.LoginId` newtype (case-insensitive, trimmed, no `@`/dot requirement) is the
  unique handle a user signs up and logs in with; `email` becomes an **optional attribute** on
  `User`/`NewUser`/`Credential`. Callers can now sign up and log in as `agent-4815162342` with no
  email at all. Lookups key on the login id (`FindUserByLoginId` /
  `FindPasswordCredentialByLoginId`; `CreatePasswordCredential :: UserId -> LoginId -> Maybe Email
  -> PasswordHash`), while lookup-by-email is retained for the reset/verification paths.
- **Email-dependent behavior is preserved when an email is present:** password-reset and
  email-verification delivery, the "resembles identity" password rule, and the HIBP breach
  context all still consume the email; the WebAuthn passkey user-handle was always user-id-derived
  and is unaffected.
- **Database (expand/contract migrations):** `shomei_users` and `shomei_password_credentials`
  gain a `login_id text NOT NULL UNIQUE` column (backfilled from `email`), and `email` is relaxed
  to nullable with a partial unique index (`WHERE email IS NOT NULL`) so multiple NULL emails
  coexist. Migrations are idempotent and re-runnable.
- **HTTP wire (backward-compatible):** `SignupRequest`/`LoginRequest` accept optional
  `loginId`/`email` (at least one required); `UserResponse` carries `loginId` and a nullable
  `email`. An `email`-only request defaults `loginId` to the email text, so existing email-first
  clients are unchanged. New error codes `invalid_login_id` (`400`) and `login_id_taken` (`409`).

### Added — Configurable JWT signing algorithm and extensible custom claims (SH-24)

- **Selectable signing algorithm:** keys are **ES256** (ECDSA P-256) by default or **RS256**
  (RSASSA-PKCS1-v1_5), chosen via `SHOMEI_SIGNING_ALG` / the Dhall `signingAlgorithm` field /
  `shomei-admin keys generate --alg`. The choice drives key generation, the JWT header `alg`, and
  the published JWKS; the `kid` is unchanged so rotation and multi-key verification still work.
  RS256 is pinned explicitly (never the PSS variant `jose` would otherwise prefer for RSA keys).
- **Extensible custom claims:** a host service can attach arbitrary top-level JSON claims to every
  token via `AuthClaims.extraClaims` / `buildClaimsWith`; they round-trip through sign/verify.
  Reserved standard claims cannot be forged through the bag. Ordinary (empty-`extraClaims`) ES256
  tokens are byte-for-byte unchanged.
