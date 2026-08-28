# Shōmei (証明)

Shōmei is a Haskell authentication and identity toolkit for building embedded Servant
authentication and standalone auth services from the same transport-agnostic core. It combines
account and session workflows, JWT infrastructure, PostgreSQL persistence, typed HTTP APIs, and
operational tooling without coupling the domain logic to any one deployment shape.

Shōmei provides:

- account signup, login, refresh, logout, email verification, and password reset/change;
- free-form, case-insensitive login identifiers, with email as an optional attribute and the
  default identifier for email-first clients;
- ES256 or RS256 access tokens, rotating refresh tokens, JWKS publication, and key rotation;
- passkeys and passwordless WebAuthn, TOTP, recovery codes, and multi-factor step-up;
- OAuth 2.0 client credentials and token exchange, plus an OpenID Connect authorization-code
  provider with PKCE;
- built-in roles, scopes, permissions, administration, audit logging, and delegated tokens;
- bearer and secure-cookie transports with CSRF protection, rate limiting, lockout, structured
  logs, Prometheus metrics, and health/readiness probes; and
- RFC 9457 problem responses, a generated OpenAPI 3.1 document, and a typed Haskell client.

## Deployment modes

- **Standalone service** — run `shomei-server` against PostgreSQL. Downstream services can verify
  its tokens locally from the published JWKS.
- **Embedded library** — mount the same `ShomeiRoutes` tree in a Servant application, reuse the
  core workflows, and protect host routes with `Authenticated`, `RequireRole`, `RequireScope`,
  `RequirePermission`, or `RequireAdmin`.

See the runnable [embedded Servant example](examples/embedded-servant-app) and
[microservice auth stack](examples/microservice-auth-stack) for both shapes.

## Packages

| Package | Role |
|---|---|
| `shomei-core` | Transport-agnostic domain types, effects, authentication/OAuth/MFA/authorization workflows, and an in-memory interpreter. No database, HTTP, or JWT dependency. |
| `shomei-jwt` | ES256/RS256 JWT signing and verification, claim handling, and JWKS generation using `jose`. |
| `shomei-webauthn` | WebAuthn ceremony interpreter for passkey enrollment, passwordless login, and MFA assertions. |
| `shomei-postgres` | `hasql` stores and publishers, connection pooling and transactional units of work, Argon2id password hashing, and SHA-256 token hashing. |
| `shomei-migrations` | Namespace-safe `pg-migrate` schema, an embeddable `MigrationComponent`, and the `shomei-migrate` CLI. |
| `shomei-servant` | The `ShomeiRoutes` API tree, DTOs, handlers, authentication/authorization combinators, RFC 9457 errors, and OpenAPI 3.1 generation. |
| `shomei-server` | The standalone Warp server, WAI middleware and background workers, configuration loader, and `shomei-admin` operations CLI. |
| `shomei-client` | Typed Haskell clients derived from `ShomeiRoutes` and `ApplicationApi`. |

## Quick start

The supported development environment is the Nix dev shell (`nix develop`, or automatically via
`direnv`). It supplies GHC 9.12.4, PostgreSQL, Cabal, formatters, and `process-compose`.

```bash
nix develop
cabal build all
cabal test all              # use --test-options='-j2' to ease ephemeral-pg load
```

Signing keys are encrypted at rest. Generate one key-encryption key for the local database, retain
it, and reuse it whenever you run Shōmei against that database:

```bash
head -c 32 /dev/urandom | base64
export SHOMEI_KEY_ENCRYPTION_KEY='<paste the generated value>'
process-compose up --no-server
```

The local stack starts socket-only PostgreSQL, creates and migrates the `shomei` database,
ensures an active ES256 signing key, and serves Shōmei at <http://localhost:8080>. The
`--no-server` flag keeps `process-compose`'s own API from claiming port 8080.

From another terminal in the same environment:

```bash
curl -s -X POST localhost:8080/v1/auth/signup \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'

curl -s -X POST localhost:8080/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice","password":"correct horse battery staple"}'
```

To manage a deployment directly with the operations CLI:

```bash
export DATABASE_URL="host=$PGHOST dbname=shomei user=$(id -un)"
cabal run shomei-admin -- migrate
cabal run shomei-admin -- keys generate          # prints a kid
cabal run shomei-admin -- keys activate <kid>
printf '%s\n' "$BOOTSTRAP_PASSWORD" | \
  cabal run shomei-admin -- users create --email admin@example.com --email-verified
```

`SHOMEI_KEY_ENCRYPTION_KEY` must also be present for `keys generate` and server startup. See the
[deployment guide](docs/user/deployment.md) before running Shōmei outside local development.

## Examples

- [Embedded Servant app](examples/embedded-servant-app) — mounts the complete auth API and protects
  host-owned routes with the same verifier; includes a browser passkey demo.
- [Microservice auth stack](examples/microservice-auth-stack) — verifies Shōmei JWTs offline in a
  downstream service using a refresh-ahead JWKS cache.
- [Embedded Shōmei + en](examples/embedded-with-en) — combines Shōmei authentication with
  relationship-based authorization in one process. It uses its own Cabal project and is built with
  `just build-embedded-with-en`.

## Documentation

Start with the [user documentation index](docs/user/index.md), or jump directly to:

- [Architecture](docs/user/architecture.md) — package layering, effects, interpreters, and the
  standalone/embedded boundary.
- [Deployment](docs/user/deployment.md) — configuration, migrations, containers, key rotation, and
  the operator runbook.
- [HTTP API](docs/user/api.md) and [Problem Details](docs/user/problem-details.md) — endpoint and
  error contracts.
- [Passkeys](docs/user/passkeys.md) and [TOTP & recovery codes](docs/user/mfa.md) — passwordless and
  multi-factor authentication.
- [OpenID Connect](docs/user/oidc.md) and [service tokens](docs/user/machine-tokens.md) — interactive
  and machine OAuth flows.
- [Authorization](docs/user/authorization.md) — built-in RBAC and composing Shōmei with **en** for
  relationship-based authorization.
- [Security](docs/user/security.md) — token/session handling, abuse protection, key storage,
  impersonation, and audit guarantees.
- [Notifications](docs/user/notifications.md) — account-lifecycle delivery through a custom
  `Notifier` interpreter.
- [Client and examples](docs/user/client-and-examples.md) and
  [OpenAPI client generation](docs/user/openapi-client-generation.md) — Haskell and generated client
  integration.

## License

MIT.
