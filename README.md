# Shōmei (証明)

Shōmei is a Haskell authentication toolkit for building **embedded Servant auth** and
**standalone auth services** from the same transport-agnostic core. It issues and verifies
ES256 JSON Web Tokens, manages the full account lifecycle (signup, login, refresh, email
verification, password reset/change), and ships production hardening (brute-force lockout,
rate limiting), observability (structured logs, Prometheus metrics, health/readiness probes),
and operations tooling (a `shomei-admin` CLI with zero-downtime signing-key rotation).

## Two deployment modes

- **Standalone service** — run `shomei-server`, a warp HTTP server that serves the `ShomeiAPI`
  against PostgreSQL. Other services verify its tokens by fetching its published JWKS.
- **Embedded library** — mount the same `ShomeiAPI` (and the `Authenticated` /
  `RequireRole` combinators) inside your own Servant application, reusing the core workflows
  directly. See `examples/embedded-servant-app`.

## Packages

| Package | Role |
|---|---|
| `shomei-core` | Transport-agnostic heart: domain types, the `effectful` effect interfaces (ports), the auth workflows, and an in-memory interpreter. No database/HTTP/JWT dependency. |
| `shomei-jwt` | ES256 JWT signing/verification and the JWKS document (`jose`). |
| `shomei-postgres` | `hasql` adapters: a PostgreSQL interpreter for each port, plus Argon2id hashing and SHA-256 token hashing (`crypton`/`ram`). |
| `shomei-migrations` | `codd`-managed SQL schema in the `shomei` PostgreSQL schema. |
| `shomei-servant` | The `ShomeiAPI` `NamedRoutes` record, request/response DTOs, handlers, and the `Authenticated`/`RequireRole` combinators. |
| `shomei-server` | The warp executable (`shomei-server`), the `shomei-admin` operations CLI, the WAI middleware stack (logging, metrics, rate limiting), and the config loader. |
| `shomei-client` | A typed Haskell client derived from `ShomeiAPI`. |

## Quick start

Everything runs inside the Nix dev shell (`nix develop`, or automatically via `direnv`).

```bash
nix develop                 # enter the toolchain (GHC 9.12.4, cabal, formatters)
just create-database        # create + migrate the local dev database (idempotent)
cabal build all
cabal test all              # all suites (use --test-options='-j2' to ease ephemeral-pg load)
```

Run the standalone server against the dev database:

```bash
PG_CONNECTION_STRING="host=$PGHOST dbname=shomei user=$(id -un)" \
  cabal run shomei-server
# then, from another terminal:
curl -s -X POST localhost:8080/auth/signup -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'
```

Or use the operations CLI to bootstrap a deployment without the HTTP API:

```bash
export DATABASE_URL="host=$PGHOST dbname=shomei user=$(id -un)"
cabal run shomei-admin -- migrate
cabal run shomei-admin -- keys generate          # prints a kid
cabal run shomei-admin -- keys activate <kid>
cabal run shomei-admin -- users create --email admin@example.com --password '…'
```

## Documentation

- [docs/architecture.md](docs/architecture.md) — design, package layering, the ports & workflows pattern.
- [docs/api.md](docs/api.md) — every HTTP endpoint with request/response shapes and status codes.
- [docs/security.md](docs/security.md) — hashing, token handling, key rotation, abuse protection, the no-leak guarantees.
- [docs/notifications.md](docs/notifications.md) — sending account-lifecycle email through your own provider via a custom `Notifier` interpreter.
- [docs/deployment.md](docs/deployment.md) — configuration reference, the local `process-compose` stack, the production container image, and the operator runbook.

## License

MIT.
