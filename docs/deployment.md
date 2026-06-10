# Shōmei Deployment

## Configuration

`shomei-server` and `shomei-admin` load configuration with this precedence (lowest to highest,
twelve-factor — env always wins):

1. built-in defaults (`defaultShomeiConfig`);
2. a typed **Dhall file** at `$SHOMEI_CONFIG` (if set), rendered with `dhall-to-json` and decoded;
3. individual environment variables.

### Environment variables

| Variable | Meaning | Default |
|---|---|---|
| `PG_CONNECTION_STRING` | libpq connection string (required for the server) | — |
| `SHOMEI_CONFIG` | path to a Dhall config file (optional) | unset |
| `SHOMEI_PORT` | warp listen port | `8080` |
| `SHOMEI_ISSUER` | JWT `iss` | `shomei` |
| `SHOMEI_AUDIENCE` | JWT `aud` | `shomei-clients` |
| `SHOMEI_ACCESS_TTL` / `SHOMEI_REFRESH_TTL` / `SHOMEI_SESSION_TTL` | token/session lifetimes (seconds) | config defaults |
| `SHOMEI_TOKEN_TRANSPORT` | `bearer` \| `cookie` \| `both` | `bearer` |
| `SHOMEI_SESSION_CHECK` | `token-only` \| `token-and-session` | `token-only` |
| `DATABASE_URL` | connection string used by `shomei-admin` | — |

### Dhall config file

The schema is `config/shomei-types.dhall`; a worked example is `config/shomei.example.dhall`.
Copy it to `config/shomei.dhall` (gitignored, holds secrets), edit, and point the server at it:

```bash
SHOMEI_CONFIG=config/shomei.dhall PG_CONNECTION_STRING=… cabal run shomei-server
```

Every field is optional; an absent field falls back to the default, and any `SHOMEI_*` env var
overrides the file. Fields: `issuer`, `audience`, `databaseUrl`, `port`, `accessTokenTtlSeconds`,
`refreshTokenTtlSeconds`, `sessionTtlSeconds`, `publicBaseUrl`, `emailVerificationRequired`,
`rateLimitEnabled`, `maxFailedLoginsPerAccount`, `perIpRequestsPerMinute`, `metricsEnabled`,
`requestLoggingEnabled`, `gracefulShutdownTimeoutSeconds`.

## The `shomei-admin` CLI

```text
shomei-admin migrate                              # apply pending migrations
shomei-admin keys generate                        # mint a pending ES256 key, print its kid
shomei-admin keys activate <kid>                  # promote pending → active (old key auto-retires)
shomei-admin keys retire <kid>                    # active → retired (still trusted in JWKS)
shomei-admin keys revoke <kid>                    # → revoked (removed from JWKS, distrusted)
shomei-admin keys list                            # kid / status / timestamps
shomei-admin users create --email … --password … [--display-name …]
```

A fresh deployment runbook: `migrate` → `keys generate` → `keys activate <kid>` → optionally
`users create`. The container entrypoint (`deploy/entrypoint.sh`) does the first three
automatically.

## Container image

The reproducible image is built from the Nix flake:

```bash
nix build .#dockerImage          # produces ./result, a loadable image tarball
docker load < result             # loads shomei-server:latest
```

`flake.module.nix` defines it with `dockerTools.buildLayeredImage` (the server, the admin CLI,
and `dhall-to-json`). A plain `Dockerfile` is provided as the documented, non-reproducible
secondary path.

> Verification status: the OCI image build and a live `docker compose up` were authored but not
> executed in the development sandbox; run them on a Nix+Docker build host or in CI to validate.

## `docker compose`

`docker-compose.yaml` brings up PostgreSQL plus the server. The server only starts once
PostgreSQL is healthy, and its own healthcheck hits `/ready` (DB reachable + active key):

```bash
nix build .#dockerImage && docker load < result
docker compose up
# then:
curl -s -X POST localhost:8080/auth/signup -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"correct horse battery staple"}'
```

`docker stop` sends SIGTERM; the server drains in-flight requests (up to
`gracefulShutdownTimeoutSeconds`), closes the connection pool, and exits 0.

## Operations

- **Liveness** `GET /health` (restart decisions); **readiness** `GET /ready` (traffic gating).
- **Metrics** `GET /metrics` (Prometheus); scrape it from your monitoring stack.
- **Logs** are one structured JSON line per request on stdout, each with an `X-Request-Id`
  correlation id that is also returned to the client.
- **Key rotation** is zero-downtime — see [security.md](security.md).

## CI

`.github/workflows/ci.yaml` runs `cabal build all`, `cabal test all`, and
`nix fmt -- --fail-on-change` on every push and pull request, all inside the Nix dev shell.
