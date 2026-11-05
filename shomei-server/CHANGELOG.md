# Changelog for shomei-server

All notable changes to `shomei-server` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- Explicit lab overrides for HTTP webhooks and plaintext SMTP credentials now emit fixed secret-free boot warnings. The notification guide documents inherited outbound HTTP proxy settings.

- Signing-key CLI transactions use finite database retry/deadline defaults. Activation revalidates and locks the pending source row before retiring the old key; injected activation/rewrap write failures roll back wholly. Key assembly fails closed on multiple active rows even after index bypass.

- Audit CLI accepts canonical user/session TypeIDs and legacy UUID filters and emits canonical user/session IDs. HIBP failures have an injectable query/report boundary and a tested bounded, secret-free diagnostic.

- **Breaking:** ServerSettings gains bind host, finite connection limit (1024) and slow-client timeout (30 seconds). Standalone and embedded Warp hosts use shared `hostWarpSettings`; excess connections close immediately and all close paths restore capacity. Dhall/environment settings are synchronized.
- Container entrypoint delegates migration and active-key bootstrap to shared server boot. Request severity is error for 5xx, warn for 429 and info otherwise.

- **Breaking:** PostgreSQL assembly uses the managed `Shomei.Persistence.Pool.Postgres.Pool` and its `UsageError`, `use` and `release` operations. Interrupted/failed sessions discard their connection and restore capacity; the external pool dependency is removed.

- Machine and delegated mints atomically enforce the configurable active principal ceiling (default 1000), preserving existing sessions after lowering the cap. Expiry frees capacity; finite sweeper retention bounds ordinary history by issuance rate and retention.

- **Breaking:** database transactions use the bounded statement wrapper; session bulk revocation returns winning IDs and the audited unit of work returns a count. Administrative session HTTP listing returns a keyset page (default 50, maximum 200). Server transaction limits default to three attempts/five seconds.

- Enforce finite new-write identity, display-name, passkey-label and role/scope budgets; preserve legacy identity authentication and snapshots. Login passwords over 256 code points fail before credential proof accounting. PostgreSQL adds migration 0039; see `docs/user/input-limits.md`.

- Expose finite actor migration settings through `SHOMEI_LEGACY_ACTOR_UNTIL_UNIX` and
  `SHOMEI_EMIT_LEGACY_ACTOR` with matching Dhall fields. Follow the coordinated token upgrade guide.

- Expose the passkey enrollment ceiling through `SHOMEI_MAX_PASSKEYS_PER_USER` and Dhall
  `maxPasskeysPerUser` (default 20, accepted range 1–100).

- Add `shomei-admin totp migrate-envelopes --check|--offline`; shared server startup refuses
  legacy TOTP envelopes. See the MFA guide for the required offline upgrade and rollback steps.
- Require released `smtp-mail >=0.5.0.2`, which fixes the `getHostName` import conflict with
  `network >=3.2.10`.

- `SHOMEI_REMEMBERED_SESSION_TTL` and the Dhall field `rememberedSessionTtlSeconds` set the
  lifetime of a remembered session.

## 0.2.0.0 — 2026-08-27

- **Breaking:** secure cookie transport now uses `__Host-shomei_session` and
  `__Secure-shomei_refresh`. Existing browser sessions are logged out once; development deployments
  with `cookieSecure = false` retain the bare names.
- Unknown-length request bodies are metered while consumed and receive a Problem Details 413 when
  they cross the cap. Warp parser failures and escaped synchronous exceptions now use the same
  public 400/413/500 envelope, and hostile authentication-header bytes cannot escape UTF-8 decoding.
- Prometheus method labels now use a fixed eight-value vocabulary with correctly escaped values,
  elapsed-time accounting uses monotonic clocks, and readiness is bounded to two seconds with a
  one-second single-flight cache.
- `shomei-admin users create` reads passwords from stdin or `--password-file`, loads the
  deployment's Dhall password and HIBP breach policy, and can explicitly mark a bootstrap email
  verified. PostgreSQL diagnostics retain only a safe category and optional SQLSTATE; breach-check
  outages log one classified reason.
- **Breaking:** `SmtpConfig` and `WebhookConfig` no longer carry credentials. The server loads
  stripped secrets into non-printable runtime types, requires HTTPS webhooks and encrypted SMTP
  authentication unless env-only lab flags opt out, and signs webhooks over
  `<X-Shomei-Timestamp>.<raw body>` for receiver replay windows.
- Notification delivery now runs on a supervised bounded in-memory queue, keeping SMTP/webhook
  latency out of request handling. Queue capacity is configurable, overflow is audited without
  blocking, and graceful shutdown drains queued work before releasing the database pool.
- Notification delivery failures persist only stable reason codes; transport exceptions,
  rendered messages, webhook response bodies, and request URLs never reach logs or audit rows.
- Configuration adds `dbStatementTimeoutMs` / `SHOMEI_DB_STATEMENT_TIMEOUT_MS` (30 seconds by
  default), and the in-process sweeper uses a dedicated one-connection pool.
- **Breaking:** the Dhall schema now exports `{ Type, default }` with every loader key optional;
  annotated files use `Shomei::{ field = Some value }`. A test keeps schema and loader fields equal.
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
