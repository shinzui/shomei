# Changelog for shomei-server

All notable changes to `shomei-server` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

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
