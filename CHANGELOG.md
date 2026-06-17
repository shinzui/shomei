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
