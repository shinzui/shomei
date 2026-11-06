# Changelog for shomei-servant

All notable changes to `shomei-servant` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## 0.3.0.0 — 2026-11-05

- **Breaking:** internal dependency bounds follow the 0.3 API series.

- **Breaking (Haskell route type only):** OpenApiRoute returns `CachedJson`; use `cachedJsonValue` for its parsed document. The URL, application/json media type, JSON schema and bytes are preserved. Shared standalone/embedded assembly now renders one forced byte representation per document version.

- **Breaking:** PostgreSQL assembly uses the managed `Shomei.Persistence.Pool.Postgres.Pool` and its `UsageError`, `use` and `release` operations. Interrupted/failed sessions discard their connection and restore capacity; the external pool dependency is removed.

- Machine and delegated mints atomically enforce the configurable active principal ceiling (default 1000), preserving existing sessions after lowering the cap. Expiry frees capacity; finite sweeper retention bounds ordinary history by issuance rate and retention.

- **Breaking:** database transactions use the bounded statement wrapper; session bulk revocation returns winning IDs and the audited unit of work returns a count. Administrative session HTTP listing returns a keyset page (default 50, maximum 200). Server transaction limits default to three attempts/five seconds.

- Enforce finite new-write identity, display-name, passkey-label and role/scope budgets; preserve legacy identity authentication and snapshots. Login passwords over 256 code points fail before credential proof accounting. PostgreSQL adds migration 0039; see `docs/user/input-limits.md`.

- Bearer scheme matching is case-insensitive and accepts multiple ASCII separator spaces.
  Invalid or duplicate Authorization credentials fail closed; a present malformed header
  cannot fall back to a session cookie. Missing and invalid credentials retain distinct challenges.
- Basic client authentication rejects malformed percent escapes before form decoding.

- **Breaking:** `LoginRequest`, `MfaCompleteRequest` and `PasskeyLoginCompleteRequest` gain an
  optional `remember`, and `TokenPairResponse` gains `remembered`, present in every token pair.

## 0.2.0.0 — 2026-08-27

- **Breaking:** requires `shomei-core ^>=0.2.0.0`.
- **Breaking:** secure cookie transport now emits and accepts `__Host-shomei_session` and
  `__Secure-shomei_refresh`, enforcing browser prefix invariants. Existing browser sessions are
  logged out once; deployments with `cookieSecure = false` retain the bare names.
- OIDC discovery handles invalid hand-built signing configuration without a partial fallback; the
  standalone server rejects that configuration before serving discovery.
- Duplicate signup login ids and email addresses consistently return their existing `409`
  problem codes, including PostgreSQL uniqueness races.
- `GET /oauth/authorize` now requires a live interactive session. Machine, delegated, and
  explicit-actor credentials receive `401 login_required` in the OAuth error shape with no
  redirect; dead sessions follow the unauthenticated login branch.
- The bespoke refresh endpoint refuses OAuth-client sessions; OAuth refresh retains and echoes the
  original granted scopes.
- Revocation enforces OAuth-client and service-account ownership (`shomei:admin` remains global),
  and UserInfo exposes email only under `email` and roles only under `profile`.
- `client_secret_basic` credentials are form-decoded, discovery advertises token exchange,
  introspection recognizes refresh tokens without a hint, and a missing UserInfo bearer challenge
  omits `error` as required by RFC 6750.

## 0.1.0.0 — 2026-08-24

*Editorial note, 2026-08-27: module names corrected to the ones shipped in 0.1.0.0; the entry
originally used pre-plan-48 names that never existed at release.*

Initial release. The HTTP layer of the Shōmei authentication toolkit.

- `ShomeiAPI` as a `NamedRoutes` record with typed `MultiVerb` results,
  organized by concept, covering signup, login, refresh, logout, email
  verification, password reset/change, MFA, passkeys, OAuth 2.0 and OpenID
  Connect, audit, and admin routes.
- Application routes live under `/v1`; the root keeps the health and
  readiness probes and the `.well-known` documents.
- Every error path returns an RFC 7807 `problem+json` envelope, backed by a
  documented error catalog.
- Enforcing auth combinators for guarding your own routes: `Authenticated`,
  `RequireRole`, `RequireScope`, and `RequirePermission`. Verification runs
  through `Shomei.Session.Authentication.Workflow.verifyToken`, so `sessionCheckMode =
  VerifyTokenAndSession` genuinely re-reads the session on every request.
- Cookie token transport with CSRF defenses, alongside bearer tokens.
- OAuth/OIDC endpoints: discovery, `authorize`, `token` (authorization code,
  refresh, `client_credentials`, and RFC 8693 token exchange), `userinfo`,
  `introspect`, and `revoke`.
- An OpenAPI 3.1 document generated from the same types, served at
  `/openapi.json` and emitted by the `shomei-openapi` executable, with a
  conformance test suite.
