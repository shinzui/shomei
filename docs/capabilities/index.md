---
okf_version: "0.2"
title: "Shōmei Capabilities"
type: capability-index
description: "What Shōmei provides today, one concept per capability, each with a stable CAP-N handle, an explicit compatibility promise, and evidence a reader can open."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
mori: shinzui/shomei
links:
  - README.md
  - docs/user/index.md
  - CHANGELOG.md
---

# Shōmei Capabilities

This directory is a typed [Open Knowledge Format](https://github.com/shinzui/okf) bundle
describing **what Shōmei does today**, for someone deciding whether to depend on it. Each
concept is one capability with a stable `CAP-N` handle, the release it arrived in, the
compatibility promise it carries, and evidence a reader can open and check.

It is written for any consumer of Shōmei — a Haskell service embedding the library, a
non-Haskell service verifying its tokens, an operator running the standalone binary — not for
one particular downstream system.

## What belongs here

A capability is a **provision claim**: something this repository's code does today, that a
consumer can adopt on its own, backed by evidence.

- **Not here: things that don't exist yet.** Those are improvement requests in
  [`../improvement-requests/`](../improvement-requests/). There is deliberately no `planned`
  status in the profile.
- **Not here: things that only work when several projects cooperate.** The two-tier
  authorization story in [`../user/authorization.md`](../user/authorization.md) — Shōmei for
  authentication, the sibling **en** ReBAC toolkit for fine-grained authorization — is the
  clearest example. Shōmei's half of it is [CAP-9](type-level-authorization-guards.md) and
  [CAP-10](built-in-rbac-roles-and-permissions.md); the composed claim belongs to the consuming
  repository as a use-case feature, because no single repository can prove it.
- **Granularity.** One capability is one thing a consumer can adopt *and* verify independently.
  The three OAuth grants are three records rather than one, because adopting machine tokens,
  browser SSO, and delegation are three separate decisions with separate configuration, stores,
  and evidence. The `shomei-admin` command families are one record, because nobody adopts a
  subcommand without the tool.

## Reading the fields

- `status` — whether a consumer can use it right now (`shipped` / `deprecated` / `withdrawn`).
- `stability` — the compatibility promise. **Shōmei has never cut a tagged release, so every
  capability here is `experimental`** and every `since` is `unreleased`: these exist on the
  default branch only, and the changelog's own "Breaking (pre-1.0 window)" entries are the
  evidence that the surface still moves. `since` becomes meaningful at the first tag.
- `packages` — what to add to `build-depends`, or which binary to run, to get it.
- `evidence` — artifacts proving the claim: tests, conformance suites, modules, examples,
  guides. `okf` does not check these paths (a path rule resolves only inside the bundle), so
  they were verified by hand.
- `requires` — capabilities this one builds on. Each entry is declared **twice**: in
  frontmatter, where it is typed, and as a body link, where it becomes a graph edge. `okf`
  derives edges from body links only.

## Index

| Handle | Capability | Packages |
|---|---|---|
| [CAP-1](transport-agnostic-auth-core.md) | Transport-agnostic authentication core | `shomei-core` |
| [CAP-2](password-account-lifecycle.md) | Password account lifecycle | `shomei-core`, `shomei-postgres` |
| [CAP-3](session-refresh-rotation.md) | Sessions with refresh-token rotation and reuse detection | `shomei-core`, `shomei-postgres` |
| [CAP-4](jwt-access-tokens-and-jwks.md) | JWT access tokens with a published JWKS | `shomei-jwt`, `shomei-core` |
| [CAP-5](signing-key-rotation-and-encryption.md) | Zero-downtime signing-key rotation with encryption at rest | `shomei-jwt`, `shomei-postgres`, `shomei-server` |
| [CAP-6](postgresql-persistence-and-migrations.md) | PostgreSQL persistence with embedded, composable migrations | `shomei-postgres`, `shomei-migrations` |
| [CAP-7](embeddable-servant-auth-api.md) | Embeddable Servant auth API | `shomei-servant` |
| [CAP-8](cookie-and-bearer-token-transport.md) | Cookie, bearer, or dual token transport with CSRF defenses | `shomei-servant` |
| [CAP-9](type-level-authorization-guards.md) | Type-level authorization guards | `shomei-servant` |
| [CAP-10](built-in-rbac-roles-and-permissions.md) | Built-in RBAC: roles, permissions, and time-bound grants | `shomei-core`, `shomei-postgres`, `shomei-server` |
| [CAP-11](problem-details-and-openapi.md) | RFC 9457 problem details and a drift-checked OpenAPI 3.1 document | `shomei-servant` |
| [CAP-12](typed-haskell-client.md) | Typed Haskell client | `shomei-client` |
| [CAP-13](oauth2-client-credentials-machine-tokens.md) | OAuth2 client-credentials machine tokens | `shomei-core`, `shomei-postgres`, `shomei-servant` |
| [CAP-14](openid-connect-provider.md) | OpenID Connect provider | `shomei-core`, `shomei-postgres`, `shomei-servant` |
| [CAP-15](token-exchange-delegation.md) | RFC 8693 token exchange: on-behalf-of and impersonation | `shomei-core`, `shomei-servant` |
| [CAP-16](passkey-webauthn-login.md) | Passkey enrollment, step-up MFA, and passwordless login | `shomei-webauthn`, `shomei-core`, `shomei-postgres` |
| [CAP-17](totp-multi-factor-authentication.md) | TOTP multi-factor authentication with recovery codes | `shomei-core`, `shomei-postgres` |
| [CAP-18](admin-http-api.md) | Admin HTTP API | `shomei-servant`, `shomei-client` |
| [CAP-19](shomei-admin-operations-cli.md) | `shomei-admin` operations CLI | `shomei-server` |
| [CAP-20](standalone-auth-service.md) | Standalone authentication service | `shomei-server` |
| [CAP-21](abuse-protection.md) | Abuse protection: lockout, throttling, and rate limits | `shomei-core`, `shomei-server` |
| [CAP-22](observability-and-health-probes.md) | Observability: structured logs, metrics, and health probes | `shomei-server` |
| [CAP-23](audit-event-trail.md) | Audit event trail | `shomei-core`, `shomei-postgres`, `shomei-servant` |
| [CAP-24](account-notification-delivery.md) | Account-lifecycle notification delivery | `shomei-core`, `shomei-server` |

## Deliberately excluded

- **The two-tier authorization story with en** — a composition claim (see above). What Shōmei
  provides is the `RequirePermission` guard and the role→permission indirection; the example at
  `examples/embedded-with-en/` is cited as evidence for
  [CAP-9](type-level-authorization-guards.md), not as a capability of its own.
- **The example applications as products.** `examples/embedded-servant-app`,
  `examples/microservice-auth-stack`, and `examples/embedded-with-en` are evidence for the
  capabilities they demonstrate. The JWKS caching, single-flight, refresh-ahead, and
  stale-on-error logic in the microservice example is genuinely useful, but it lives in an
  example, not in a package a consumer can depend on.
- **`examples/embedded-servant-app/www/`'s browser glue.** Cited as evidence for
  [CAP-16](passkey-webauthn-login.md); there is no packaged browser SDK.

## Validation

```sh
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
```

[`profile.dhall`](profile.dhall) pins the shared `coordination.capabilities` profile from
[okf-profiles v0.9.0](https://github.com/shinzui/okf-profiles) by Dhall semantic hash, so this
catalog and every other capability catalog in the portfolio are governed by one definition.
