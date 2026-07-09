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
| `SHOMEI_DB_POOL_SIZE` | PostgreSQL connections the server holds open. Must be positive; the boot fails otherwise | `10` |
| `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` | how long a request waits for a free pooled connection before failing. Must be positive | `10000` |
| `SHOMEI_ISSUER` | JWT `iss` | `shomei` |
| `SHOMEI_AUDIENCE` | JWT `aud` | `shomei-clients` |
| `SHOMEI_ACCESS_TTL` / `SHOMEI_REFRESH_TTL` / `SHOMEI_SESSION_TTL` | token/session lifetimes (seconds) | config defaults |
| `SHOMEI_TOKEN_TRANSPORT` | `bearer` \| `cookie` \| `both`. `cookie`/`both` set `HttpOnly` cookies and accept them as credentials; `bearer` neither sets nor accepts them | `bearer` |
| `SHOMEI_COOKIE_SECURE` | mark Shōmei's cookies `Secure` (HTTPS only; browsers exempt localhost) | `true` |
| `SHOMEI_COOKIE_SAMESITE` | `strict` \| `lax` \| `none` | `lax` |
| `SHOMEI_CSRF_ALLOWED_ORIGINS` | **set this in production.** Comma-separated origins allowed to make cookie-authenticated *mutating* requests, e.g. `https://app.example.com`. Anything else gets `403 csrf_rejected` | `http://localhost:8080` |
| `SHOMEI_SESSION_CHECK` | `token-only` \| `token-and-session` | `token-only` |
| `SHOMEI_SIGNING_ALG` | JWT signing algorithm for keys generated on first boot: `ES256` \| `RS256` | `ES256` |
| `SHOMEI_KEY_REFRESH_INTERVAL` | seconds between background reloads of signing-key material, so `keys activate`/`keys revoke` reach a running server; `0` disables the periodic reload (`SIGHUP` still reloads) | `60` |
| `SHOMEI_NOTIFIER_LOG_SECRETS` | **development only.** Log the full password-reset / verification link, raw token included, instead of a SHA-256 prefix. Anyone who can read the log can then take over an account | `false` |
| `SHOMEI_KEY_ENCRYPTION_KEY` | 32 bytes, base64. Envelope-encrypts signing keys at rest. Unset means keys are stored in plaintext (a warning is logged) | unset |
| `SHOMEI_KEY_ENCRYPTION_KEY_OLD` | the previous KEK; read only by `shomei-admin keys rewrap` | unset |
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
| `SHOMEI_SWEEP_ENABLED` | run the background expired-data sweeper in-process. Set `false` if you schedule `shomei-admin sweep` externally | `true` |
| `SHOMEI_SWEEP_INTERVAL_SECONDS` | seconds between sweep cycles. Must be positive | `3600` |
| `SHOMEI_SWEEP_BATCH_SIZE` | rows deleted per statement (sessions per statement, for refresh tokens). Must be positive | `1000` |
| `SHOMEI_SWEEP_DEAD_SESSION_GRACE_DAYS` | grace before an expired/revoked session and its refresh-token family are deleted | `30` |
| `SHOMEI_SWEEP_ONE_TIME_TOKEN_GRACE_DAYS` | grace before expired verification/reset tokens and elapsed lockouts are deleted | `7` |
| `SHOMEI_SWEEP_CEREMONY_GRACE_MINUTES` | grace before expired WebAuthn ceremonies are deleted | `60` |
| `SHOMEI_LOGIN_ATTEMPT_RETENTION_DAYS` | maximum age of `shomei_login_attempts` rows. Must be positive | `90` |
| `SHOMEI_AUTH_EVENT_RETENTION_DAYS` | maximum age of audit events. **Unset, `0`, or negative retains the audit trail forever** | unset |
| `SHOMEI_ARGON2_MEMORY_KIB` | Argon2id memory cost, KiB, for **newly hashed** passwords. Must be positive | `65536` (64 MiB) |
| `SHOMEI_ARGON2_ITERATIONS` | Argon2id time cost for newly hashed passwords. Must be positive | `3` |
| `SHOMEI_ARGON2_PARALLELISM` | Argon2id lanes for newly hashed passwords. Must be positive | `1` |
| `SHOMEI_HASHING_MAX_CONCURRENCY` | how many Argon2 hashes may run at once, process-wide. Must be positive | `2` |
| `SHOMEI_RTS_OPTS` | GHC runtime options the container entrypoint passes as `+RTS … -RTS`. Empty string passes none. **Do not use `GHCRTS`** — it leaks into `dhall-to-json` and breaks config loading | `-N<cpu-quota> [-A64m] --nonmoving-gc` |
| `SHOMEI_CGROUP_ROOT` | where the entrypoint looks for the CPU quota. A test seam; leave unset | `/sys/fs/cgroup` |
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

### Sizing the connection pool

`SHOMEI_DB_POOL_SIZE` bounds how many requests can touch PostgreSQL at once; a request that
finds every connection busy waits up to `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` and then fails.
Token verification on the authenticated hot path is pure in-memory work and takes no connection
at all, so the pool only has to cover the write workflows (signup, login, refresh, logout) plus
`shomei-admin`. Size it against the database's own `max_connections` budget shared across every
replica, not against request concurrency, and prefer shedding load with a short acquisition
timeout over queueing behind a saturated pool.

### Password hashing cost and concurrency

Passwords are hashed with **Argon2id** at 64 MiB / 3 iterations / 1 lane, which is at or above
every OWASP-recommended configuration. `SHOMEI_ARGON2_*` changes the cost for **newly hashed**
passwords only: every stored hash records the parameters it was made with, so retuning the cost
never invalidates an existing credential, and old and new hashes coexist indefinitely. Below
19 MiB / 2 iterations the server logs a prominent warning at boot but still starts — test rigs
legitimately want cheap hashing.

`SHOMEI_HASHING_MAX_CONCURRENCY` (default 2) bounds how many hashes run at once, and it matters
more than it looks. The Argon2 implementation is reached through an *unsafe* foreign call, which
cannot be interrupted: for the ~100 ms a hash takes, that capability reaches no
garbage-collection safepoint. GHC's default collector is stop-the-world and must synchronize
every capability, so **one password hash can stall every other request in the process**, including
ones that never touch a password. Each hash also transiently allocates its full memory cost, so
ten concurrent logins would spike ~640 MB.

Two concurrent hashes still sustain roughly 13–40 logins/second — far above any single-instance
deployment's login rate — while bounding the transient allocation at ~128 MiB. Raise it if you
have CPU and memory headroom and measure a login-throughput ceiling; the failure mode of
too-small is queued logins, and of too-large is global GC stalls.

### GHC runtime options in containers

The container entrypoint (`deploy/entrypoint.sh`) starts the server as:

```sh
exec shomei-server +RTS -N<cpu-quota> -A64m --nonmoving-gc -RTS   # when a CPU quota exists
exec shomei-server +RTS -N<nproc> --nonmoving-gc -RTS             # when it does not
```

**Why not just let GHC decide?** `-N` sizes GHC's capability count from the CPU affinity mask.
An affinity mask reflects *cpuset* pinning, but not CFS *bandwidth* quotas — and `docker --cpus`
and Kubernetes CPU **limits** are CFS quotas. A container limited to 2 CPUs on a 32-core node
therefore starts 32 capabilities, and every stop-the-world collection has to synchronize all 32
across 2 CPUs' worth of actual scheduling. The entrypoint reads the quota from
`/sys/fs/cgroup/cpu.max` (cgroup v2) or `cpu.cfs_quota_us`/`cpu.cfs_period_us` (v1), rounds up,
and falls back to `nproc` when there is no quota.

`--nonmoving-gc` makes old-generation collection run concurrently with the mutator, removing the
long global pauses that turn a pinned Argon2 hash into p99 latency.

`-A64m` enlarges each capability's nursery, so young-generation collections — each a
stop-the-world sync that may queue behind a pinned hash — happen less often. **It is applied
only when a CPU quota bounds the capability count**, because `-A` is *per capability*: at a
2-CPU quota it costs ~128 MiB, but on an unconstrained 10-core host it cost 726 MB of extra
resident memory (230 MB → 956 MB) with no reproducible latency benefit in our measurements.

**Why `+RTS` and not `GHCRTS`?** `GHCRTS` is inherited by *every* GHC-compiled program in the
environment. `shomei-server` shells out to `dhall-to-json` to render `$SHOMEI_CONFIG`, and
`dhall-to-json` is built without `-threaded`/`-rtsopts`, so it exits 1 on `-N4` and the server
never boots. `+RTS` is consumed by the server's own runtime and never reaches a child.

Override with `SHOMEI_RTS_OPTS` (set it to the empty string to pass nothing). The RTS **rejects
unknown options and exits**, so a typo fails the container at boot rather than silently reverting
to defaults. Bare-metal and `cabal run` deployments are unaffected — they keep GHC's plain `-N`.

### Dhall config file

The schema is `config/shomei-types.dhall`; a worked example is `config/shomei.example.dhall`.
Copy it to `config/shomei.dhall` (gitignored, holds secrets), edit, and point the server at it:

```bash
SHOMEI_CONFIG=config/shomei.dhall PG_CONNECTION_STRING=… cabal run exe:shomei-server
```

Every field is optional; an absent field falls back to the default, and any `SHOMEI_*` env var
overrides the file. Fields: `issuer`, `audience`, `databaseUrl`, `port`, `dbPoolSize`,
`dbPoolAcquisitionTimeoutMs`, `accessTokenTtlSeconds`,
`refreshTokenTtlSeconds`, `sessionTtlSeconds`, `publicBaseUrl`, `emailVerificationRequired`,
`rateLimitEnabled`, `maxFailedLoginsPerAccount`, `perIpRequestsPerMinute`, `metricsEnabled`,
`requestLoggingEnabled`, `gracefulShutdownTimeoutSeconds`, password policy fields
`passwordMinLength`, `passwordMaxLength`, `passwordRejectCommon`, `passwordRejectContextual`,
`passwordBreachCheckEnabled`, `passwordBreachCheckFailClosed`,
`passwordBreachCheckTimeoutMs`, the WebAuthn keys `webauthnRpId`, `webauthnRpName`,
`webauthnOrigins`, `webauthnUserVerification`, `webauthnAttestation`,
`webauthnCeremonyTimeoutSeconds`, `webauthnPendingCeremonyTtlSeconds`,
`webauthnMfaRequired`, `signingAlgorithm`, `keyRefreshIntervalSeconds`, `tokenTransport`,
`cookieSecure`, `cookieSameSite`, `csrfAllowedOrigins`, the sweeper keys `sweepEnabled`,
`sweepIntervalSeconds`, `sweepBatchSize`, `sweepDeadSessionGraceDays`,
`sweepOneTimeTokenGraceDays`, `sweepCeremonyGraceMinutes`, `loginAttemptRetentionDays`,
`authEventRetentionDays`, the hashing keys `argon2MemoryKiB`, `argon2Iterations`,
`argon2Parallelism`, `hashingMaxConcurrency`, and `serviceToken` (see
[passkeys.md](passkeys.md) for WebAuthn and [service-tokens.md](service-tokens.md) for service
accounts).

> **Note.** `config/shomei-types.dhall` is a *closed* record type, so it does not yet list the
> newer keys (`signingAlgorithm`, `keyRefreshIntervalSeconds`, `tokenTransport`, `cookieSecure`,
> `cookieSameSite`, `csrfAllowedOrigins`, `dbPoolSize`, `dbPoolAcquisitionTimeoutMs`, the
> `sweep*` / `*RetentionDays` keys, and the `argon2*` / `hashingMaxConcurrency` keys). The
> loader accepts them regardless — every field is
> optional at decode time — but a file that annotates itself `: ./shomei-types.dhall` cannot use
> them until the schema is widened. Use the environment variables, or drop the annotation.

There is deliberately **no** Dhall key for `SHOMEI_NOTIFIER_LOG_SECRETS` or
`SHOMEI_KEY_ENCRYPTION_KEY`: both are secrets or secret-revealing switches, and must be explicit
per-process decisions rather than lines that linger in a committed file.

## The `shomei-admin` CLI

```text
shomei-admin migrate                              # apply pending migrations
shomei-admin keys generate [--alg ES256|RS256]    # mint a pending key (default ES256), print its kid
shomei-admin keys activate <kid>                  # promote pending → active (old key auto-retires)
shomei-admin keys retire <kid>                    # active → retired (still trusted in JWKS)
shomei-admin keys revoke <kid>                    # → revoked (removed from JWKS, distrusted)
shomei-admin keys list                            # kid / status / timestamps
shomei-admin keys encrypt-at-rest                 # encrypt plaintext private keys (idempotent)
shomei-admin keys rewrap                          # re-encrypt under a new SHOMEI_KEY_ENCRYPTION_KEY
shomei-admin users create --email … --password … [--display-name …]
shomei-admin audit events|user|session|count …     # read the security audit trail
shomei-admin sweep [flags]                        # delete expired/dead rows once, then exit
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

## Encrypting signing keys at rest

Without `SHOMEI_KEY_ENCRYPTION_KEY`, private signing keys sit in the database as plaintext, and
anyone who can read the database can forge tokens for every downstream service. See
[security.md](security.md#signing-key-encryption-at-rest) for the threat model and the scheme.

**Enabling it on an existing deployment.** Encrypted rows cannot be read by a binary that has
no KEK, so do the backfill *after* the binary you would roll back to is the one running:

```bash
# 1. Generate a KEK and store it in your secret manager. Back it up separately from the
#    database — losing it loses the signing keys, with no recovery path.
head -c 32 /dev/urandom | base64

# 2. Set SHOMEI_KEY_ENCRYPTION_KEY in the server's environment and restart. Nothing changes
#    yet: existing plaintext rows still read, and any NEW key is written encrypted.

# 3. Backfill. Idempotent, and safe against the running server: each row is one atomic
#    UPDATE, and a running server reads plaintext and encrypted rows alike.
shomei-admin keys encrypt-at-rest      # → encrypted 3 key(s), skipped 0 already-encrypted

# 4. Verify: no private scalar "d" is left anywhere in the table.
psql -d "$PGDATABASE" -tAc \
  "SELECT count(*) FROM shomei.shomei_signing_keys WHERE private_key_jwk LIKE '%\"d\"%'"   # → 0
```

From here on, a server started **without** the KEK refuses to boot rather than run unable to
sign. `shomei-admin` needs the KEK for `keys generate` (so the new key is written encrypted);
the pure status transitions — `activate`, `retire`, `revoke`, `list` — never touch key material
and need nothing.

**Rotating the KEK.** Rows are few, so a rewrap takes milliseconds:

```bash
export SHOMEI_KEY_ENCRYPTION_KEY_OLD="$OLD_KEK"
export SHOMEI_KEY_ENCRYPTION_KEY="$NEW_KEK"
shomei-admin keys rewrap               # → rewrapped 3 key(s)
```

`rewrap` decrypts every row in memory before writing any of them, so a wrong
`SHOMEI_KEY_ENCRYPTION_KEY_OLD` aborts with `no rows were modified` — a half-rewrapped table
would be readable by neither KEK. It also encrypts any row still in plaintext, so it subsumes
`encrypt-at-rest`. Afterwards, deploy the new KEK to the servers and restart them; the public
keys never changed, so **every outstanding token keeps verifying** across the rotation.

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
computes container-aware GHC RTS options (see [GHC runtime options in
containers](#ghc-runtime-options-in-containers)), then `exec`s the server so SIGTERM (e.g. on pod
termination) reaches it; the server drains in-flight requests (up to
`gracefulShutdownTimeoutSeconds`), closes the connection pool, and exits 0. A plain `Dockerfile`
is provided as the documented, non-reproducible secondary path. Point the container at your own
managed PostgreSQL with `PG_CONNECTION_STRING`.

The entrypoint's CPU-quota arithmetic is covered by `deploy/entrypoint-test.sh`, which runs the
real script against cgroup v1/v2 fixtures with stubbed binaries and needs no container runtime:

```bash
sh deploy/entrypoint-test.sh
```

> Verification status: the OCI image build was authored but not executed in the development
> sandbox; run `nix build .#dockerImage` on a Nix+Docker build host or in CI to validate.

## Data retention and the sweeper

Shōmei's tables grow with use: a row per refresh, per login attempt, per audit event. The
**sweeper** deletes rows that are past their expiry plus a grace period. It runs in-process by
default — a background thread, every `SHOMEI_SWEEP_INTERVAL_SECONDS` — and logs one structured
JSON line per cycle on stderr:

```json
{"level":"info","msg":"sweep","refresh_tokens":3,"sessions":1,"verification_tokens":0,"reset_tokens":0,"ceremonies":1,"lockouts":0,"login_attempts":0,"auth_events":0,"duration_ms":48.3}
```

If you would rather schedule maintenance yourself (cron, a Kubernetes CronJob), set
`SHOMEI_SWEEP_ENABLED=false` and run the CLI instead. Both call the same code, and running both
at once is harmless — every delete is idempotent, so a concurrent batch just finds fewer rows.

```bash
DATABASE_URL=… shomei-admin sweep
```

```text
refresh_tokens:      0
sessions:            0
verification_tokens: 0
reset_tokens:        0
ceremonies:          0
lockouts:            0
login_attempts:      0
auth_events:         0 (retention disabled)
```

It exits 0 on success and 1 with the database error if PostgreSQL is unreachable. Every flag
mirrors an environment variable (`--batch-size`, `--dead-session-grace-days`,
`--one-time-token-grace-days`, `--ceremony-grace-minutes`, `--login-attempt-retention-days`,
`--auth-event-retention-days`); `shomei-admin sweep --help` lists them with their defaults.

### What is deleted, and when

| Table | Deleted when | Default grace |
|---|---|---|
| `shomei_refresh_tokens` | their session expired or was revoked longer ago than the grace period | 30 days |
| `shomei_sessions` | expired, or revoked, longer ago than the grace period | 30 days |
| `shomei_email_verification_tokens` | expired longer ago than the grace period | 7 days |
| `shomei_password_reset_tokens` | expired longer ago than the grace period | 7 days |
| `shomei_account_lockouts` | the lock elapsed longer ago than the grace period | 7 days |
| `shomei_webauthn_pending_ceremonies` | expired longer ago than the grace period | 60 minutes |
| `shomei_login_attempts` | older than the retention window | 90 days |
| `shomei_auth_events` | older than the retention window | **never** (opt-in) |

Two of these deserve explanation.

**Refresh tokens are swept via their session, never on their own expiry.** Reuse detection
recognizes a replayed token by finding its `used` row still in the table; deleting those rows
early would silently downgrade "token reuse — revoke the whole family" to "unknown token". The
30-day grace on dead sessions keeps the entire detection window intact, because by then every
token in the family is unusable anyway. Lowering `SHOMEI_SWEEP_DEAD_SESSION_GRACE_DAYS` below
your refresh-token TTL narrows that window; do not.

**Rows in `shomei_account_lockouts` with no active lock are never swept.** They carry the
running failure count for an account that is not currently locked, and deleting one would reset
a brute-force counter mid-attack. They are bounded by the number of accounts that have ever
failed a login, and a successful login clears them.

### Audit-event retention is off by default

`shomei_auth_events` is the security audit trail, and it grows forever unless you say otherwise.
That is the only conservative default: Shōmei cannot know your obligations, and deleting audit
history is not something a default should do quietly.

Setting `SHOMEI_AUTH_EVENT_RETENTION_DAYS` (or the Dhall `authEventRetentionDays`) turns on
deletion. **Before you set it, check both directions.** Retention *floors* — SOC 2, PCI DSS, and
many sector regulators expect authentication logs to be retained for a year or more — and
retention *ceilings*: data-minimization regimes such as the GDPR expect personal data, which an
authentication event is, not to be kept longer than necessary for its purpose. These pull in
opposite directions and the resolution is specific to your jurisdiction, industry, and the
purpose you have documented. Take a backup before enabling it for the first time; the deletion
is not reversible.

A value of `0` or less means "retain forever", so an operator can turn deletion back off with an
environment variable alone, without editing a config file.

### If a sweep misbehaves

Set `SHOMEI_SWEEP_ENABLED=false` and restart. The system returns to its previous
grow-forever behavior; nothing else depends on the sweeper. A sweep that fails — most often
because PostgreSQL was briefly unreachable — logs the error and retries on the next cycle. It
never takes the server down, and `GET /health` keeps answering throughout.

## Operations

- **Liveness** `GET /health` (restart decisions); **readiness** `GET /ready` (traffic gating).
- **Metrics** `GET /metrics` (Prometheus); scrape it from your monitoring stack.
- **Logs** are one structured JSON line per request on stdout, each with an `X-Request-Id`
  correlation id that is also returned to the client. Background tasks (the sweeper, key
  reloads) log JSON lines on stderr.
- **Data retention** is handled by the sweeper; audit-event deletion is opt-in (see above).
- **Key rotation** is zero-downtime — see [security.md](security.md).

## CI

`.github/workflows/ci.yaml` runs `cabal build all`, `cabal test all`, and
`nix fmt -- --fail-on-change` on every push and pull request, all inside the Nix dev shell.
