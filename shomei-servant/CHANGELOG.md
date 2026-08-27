# Changelog for shomei-servant

All notable changes to `shomei-servant` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

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
  through `Shomei.Workflow.verifyToken`, so `sessionCheckMode =
  VerifyTokenAndSession` genuinely re-reads the session on every request.
- Cookie token transport with CSRF defenses, alongside bearer tokens.
- OAuth/OIDC endpoints: discovery, `authorize`, `token` (authorization code,
  refresh, `client_credentials`, and RFC 8693 token exchange), `userinfo`,
  `introspect`, and `revoke`.
- An OpenAPI 3.1 document generated from the same types, served at
  `/openapi.json` and emitted by the `shomei-openapi` executable, with a
  conformance test suite.
