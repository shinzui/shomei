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
| `SHOMEI_SIGNING_ALG` | JWT signing algorithm for keys generated on first boot: `ES256` \| `RS256` | `ES256` |
| `SHOMEI_KEY_REFRESH_INTERVAL` | seconds between background reloads of signing-key material, so `keys activate`/`keys revoke` reach a running server; `0` disables the periodic reload (`SIGHUP` still reloads) | `60` |
| `SHOMEI_PASSWORD_MIN_LENGTH` / `SHOMEI_PASSWORD_MAX_LENGTH` | accepted password length bounds | `12` / `256` |
| `SHOMEI_PASSWORD_REJECT_COMMON` | reject passwords from the built-in common-password dictionary | `true` |
| `SHOMEI_PASSWORD_REJECT_CONTEXTUAL` | reject passwords equal to the login email/local-part/display name | `true` |
| `SHOMEI_PASSWORD_BREACH_CHECK` | enable HIBP k-anonymity breached-password checks | `false` |
| `SHOMEI_PASSWORD_BREACH_FAIL_CLOSED` | reject passwords when the breach check cannot be reached | `false` |
| `SHOMEI_PASSWORD_BREACH_TIMEOUT_MS` | breach-check timeout | `1000` |
| `SHOMEI_WEBAUTHN_RP_ID` | passkey relying-party domain (no scheme/port) | `localhost` |
| `SHOMEI_WEBAUTHN_RP_NAME` | human RP name shown by the authenticator | `Shōmei` |
| `SHOMEI_WEBAUTHN_ORIGINS` | allowed page origins (comma-separated) | `http://localhost:8080` |
| `SHOMEI_WEBAUTHN_USER_VERIFICATION` | `required` \| `preferred` \| `discouraged` | `preferred` |
| `SHOMEI_WEBAUTHN_ATTESTATION` | `none` \| `direct` | `none` |
| `SHOMEI_WEBAUTHN_CEREMONY_TIMEOUT` / `SHOMEI_WEBAUTHN_PENDING_TTL` | ceremony timeout / pending-ceremony TTL (seconds) | `300` |
| `SHOMEI_WEBAUTHN_MFA_REQUIRED` | require MFA for accounts that have a passkey | `true` |
| `SHOMEI_SERVICE_TOKEN_ENABLED` | enable `POST /auth/service-token` | `false` |
| `SHOMEI_SERVICE_TOKEN_TTL` | service-token access-token lifetime, seconds | `300` |
| `SHOMEI_SERVICE_ACCOUNTS_JSON` | JSON array of service account objects: `accountId`, `userId`, `secretSha256`, `allowedScopes` | unset |
| `DATABASE_URL` | connection string used by `shomei-admin` | — |

`SHOMEI_SERVICE_ACCOUNTS_JSON` replaces the configured service-account list when set. Example:

```json
[
  {
    "accountId": "connector:kawa",
    "userId": "user_...",
    "secretSha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "allowedScopes": ["kawa:ingest"]
  }
]
```

### Dhall config file

The schema is `config/shomei-types.dhall`; a worked example is `config/shomei.example.dhall`.
Copy it to `config/shomei.dhall` (gitignored, holds secrets), edit, and point the server at it:

```bash
SHOMEI_CONFIG=config/shomei.dhall PG_CONNECTION_STRING=… cabal run exe:shomei-server
```

Every field is optional; an absent field falls back to the default, and any `SHOMEI_*` env var
overrides the file. Fields: `issuer`, `audience`, `databaseUrl`, `port`, `accessTokenTtlSeconds`,
`refreshTokenTtlSeconds`, `sessionTtlSeconds`, `publicBaseUrl`, `emailVerificationRequired`,
`rateLimitEnabled`, `maxFailedLoginsPerAccount`, `perIpRequestsPerMinute`, `metricsEnabled`,
`requestLoggingEnabled`, `gracefulShutdownTimeoutSeconds`, password policy fields
`passwordMinLength`, `passwordMaxLength`, `passwordRejectCommon`, `passwordRejectContextual`,
`passwordBreachCheckEnabled`, `passwordBreachCheckFailClosed`,
`passwordBreachCheckTimeoutMs`, the WebAuthn keys `webauthnRpId`, `webauthnRpName`,
`webauthnOrigins`, `webauthnUserVerification`, `webauthnAttestation`,
`webauthnCeremonyTimeoutSeconds`, `webauthnPendingCeremonyTtlSeconds`,
`webauthnMfaRequired`, `signingAlgorithm`, and `serviceToken` (see
[passkeys.md](passkeys.md) for WebAuthn and [service-tokens.md](service-tokens.md) for service
accounts).

## The `shomei-admin` CLI

```text
shomei-admin migrate                              # apply pending migrations
shomei-admin keys generate [--alg ES256|RS256]    # mint a pending key (default ES256), print its kid
shomei-admin keys activate <kid>                  # promote pending → active (old key auto-retires)
shomei-admin keys retire <kid>                    # active → retired (still trusted in JWKS)
shomei-admin keys revoke <kid>                    # → revoked (removed from JWKS, distrusted)
shomei-admin keys list                            # kid / status / timestamps
shomei-admin users create --email … --password … [--display-name …]
```

A fresh deployment runbook: `migrate` → `keys generate` → `keys activate <kid>` → optionally
`users create`. The container entrypoint (`deploy/entrypoint.sh`) does the first three
automatically.

**Choosing the signing algorithm.** Keys are **ES256** (ECDSA P-256) by default; set
`SHOMEI_SIGNING_ALG=RS256` (or the Dhall `signingAlgorithm` field, or `keys generate --alg
RS256`) to mint **RS256** (RSASSA-PKCS1-v1_5) keys instead — required by verifiers that only
accept RS256. The choice shows up in the generated key, the JWT header's `alg`, and the
published JWKS. First-boot key generation is **guarded on "no active key"**, so changing
`SHOMEI_SIGNING_ALG` on an already-keyed database has no effect until you rotate: run
`keys generate --alg <desired>` then `keys activate <kid>` (zero-downtime — both keys publish
during the overlap). A running server applies the rotation at its next key reload — within
`SHOMEI_KEY_REFRESH_INTERVAL` seconds, or immediately on `kill -HUP <pid>` — with no restart.

## Local development/test stack (`process-compose`)

Locally — for development and testing — Shōmei does **not** use Docker or `docker compose`.
Everything runs inside the Nix dev shell against a local PostgreSQL bound to a **Unix-domain
socket** (no TCP port, so it never conflicts with any other Postgres on the machine). This is
the same pattern every service in the project uses.

```bash
nix develop                      # or rely on direnv (.envrc runs `use flake`)
process-compose up --no-server   # starts the whole local stack
```

The `--no-server` flag is required: process-compose's own REST API also defaults to TCP 8080
and would grab the port before `shomei-server` can bind it (process-compose aborts rather than
relocating). Disabling its API frees 8080 for the server; you drive the stack from the
foreground TUI (press `q`/Ctrl-C to stop).

`process-compose up --no-server` runs the processes in `process-compose.yaml`, in order:

1. `postgres` — a local PostgreSQL started with `pg_ctl … -o "--unix_socket_directories='$PGHOST'"
   -o "-c listen_addresses=''"`, i.e. socket-only. The dev shell (`nix/haskell.nix`) exports
   `PGHOST=$PWD/db`, `PGDATA`, `PGDATABASE=shomei`, and `PG_CONNECTION_STRING` (a `postgresql://`
   URI pointing at the socket directory).
2. `create_schema` — `just create-database`: creates the `shomei` database (over the socket) and
   applies all migrations. Idempotent.
3. `bootstrap_keys` — ensures an active signing key exists (via `shomei-admin keys
   list`/`generate`/`activate`); the algorithm is `SHOMEI_SIGNING_ALG` (default `ES256`).
   `shomei-admin` reads `DATABASE_URL`, which this step bridges from the dev shell's
   `PG_CONNECTION_STRING`.
4. `shomei-server` — `cabal run exe:shomei-server` (`exe:` disambiguates from the `shomei-admin`
   executable in the same package), reachable at `http://localhost:8080`; its readiness probe
   hits `/ready`.

The server reaches the database over `PG_CONNECTION_STRING` (the Unix socket), so there is no
host/port to configure and nothing to clash with. Then, from another shell:

```bash
curl -s -X POST localhost:8080/auth/signup -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"correct horse battery staple"}'
```

To reset to a pristine database: stop the stack (press `q`/Ctrl-C in the process-compose TUI —
with `--no-server` there is no API for `process-compose down`), `dropdb shomei`, then
`process-compose up --no-server` again — `create_schema` recreates and re-migrates it.

## Production container image

For deployment (a registry / Kubernetes), the reproducible image is built from the Nix flake:

```bash
nix build .#dockerImage          # produces ./result, a loadable image tarball
docker load < result             # loads shomei-server:latest
```

`flake.module.nix` defines it with `dockerTools.buildLayeredImage` (the server, the admin CLI,
and `dhall-to-json`). Its `deploy/entrypoint.sh` runs migrations, ensures an active signing key,
then `exec`s the server so SIGTERM (e.g. on pod termination) reaches it; the server drains
in-flight requests (up to `gracefulShutdownTimeoutSeconds`), closes the connection pool, and
exits 0. A plain `Dockerfile` is provided as the documented, non-reproducible secondary path.
Point the container at your own managed PostgreSQL with `PG_CONNECTION_STRING`.

> Verification status: the OCI image build was authored but not executed in the development
> sandbox; run `nix build .#dockerImage` on a Nix+Docker build host or in CI to validate.

## Operations

- **Liveness** `GET /health` (restart decisions); **readiness** `GET /ready` (traffic gating).
- **Metrics** `GET /metrics` (Prometheus); scrape it from your monitoring stack.
- **Logs** are one structured JSON line per request on stdout, each with an `X-Request-Id`
  correlation id that is also returned to the client.
- **Key rotation** is zero-downtime — see [security.md](security.md).

## CI

`.github/workflows/ci.yaml` runs `cabal build all`, `cabal test all`, and
`nix fmt -- --fail-on-change` on every push and pull request, all inside the Nix dev shell.
