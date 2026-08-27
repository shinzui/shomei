# Changelog for shomei-server

All notable changes to `shomei-server` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- **Breaking:** Dhall configuration rejects unknown fields and invalid WebAuthn policy names, and
  startup refuses empty WebAuthn origin sets. `SHOMEI_EMAIL_VERIFICATION_REQUIRED` now overlays the
  corresponding file setting.
- The server and `shomei-admin` refuse Argon2 costs that the implementation cannot represent or
  accept; server startup also performs one real derivation before acquiring a database pool.
- **Breaking:** configuration adds `allowedClockSkewSeconds` and validates issuer and audience as
  RFC 7519 StringOrURI values at boot.
- The admin CLI activates and rewraps signing keys transactionally, stamps `revoked_at`, and lists
  every lifecycle timestamp. The server refuses ambiguous multi-active key state.

Not yet published to Hackage: depends on `shomei-webauthn`, which is blocked
on a Hackage release of `webauthn` compatible with GHC 9.12.4 and `jose 0.13`.

Initial release contents:

- The `shomei-server` warp executable serving `ShomeiAPI` against PostgreSQL,
  with signing-key bootstrap, publication, and hot reload.
- WAI middleware stack: structured logging, Prometheus metrics, per-IP and
  per-account rate limiting, and request body limits.
- Health and readiness probes and graceful shutdown under a supervisor.
- Environment-driven configuration loader.
- HIBP breach checking enforced in the password workflows.
- The `shomei-admin` operations CLI: user and session administration,
  service-account and OAuth-client lifecycle, and zero-downtime signing-key
  rotation including encrypt-at-rest and rewrap.
- Password-reset and email-verification tokens are never logged.
