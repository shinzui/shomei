# Shōmei Deployment

## Configuration

`shomei-server` and `shomei-admin` load configuration with this precedence (lowest to highest,
twelve-factor — env always wins):

1. built-in defaults (`defaultShomeiConfig`);
2. a typed **Dhall file** at `$SHOMEI_CONFIG` (if set), rendered with `dhall-to-json` and decoded;
3. individual environment variables.

### Environment variables

JWT issuer and audience values use RFC 7519's StringOrURI shape: an arbitrary string is valid,
but any value containing `:` must parse as a URI. The server validates both values at boot.

| Variable | Meaning | Default |
|---|---|---|
| `PG_CONNECTION_STRING` | libpq connection string (required for the server) | — |
| `SHOMEI_CONFIG` | path to a Dhall config file (optional) | unset |
| `SHOMEI_PORT` | warp listen port | `8080` |
| `SHOMEI_TRUSTED_PROXIES` | comma-separated proxy addresses or CIDR blocks whose `X-Forwarded-For` chain may supply client identity | empty (trust nobody) |
| `SHOMEI_PROXY_PROTOCOL` | warp PROXY protocol v1 mode: `none` or `required` | `none` |
| `SHOMEI_RATE_LIMIT_ENABLED` | master switch for the account failure budgets and WAI client-IP token bucket | `true` |
| `SHOMEI_MAX_FAILED_LOGINS_PER_ACCOUNT` | failed credential proofs allowed per account within the lockout window; must be positive | `5` |
| `SHOMEI_MAX_FAILED_LOGINS_PER_IP` | failed credential proofs allowed per client IP within the lockout window; must be positive | `20` |
| `SHOMEI_PER_IP_REQUESTS_PER_MINUTE` | sustained WAI request-bucket refill for marked proof routes; must be positive | `60` |
| `SHOMEI_PER_IP_BURST` | WAI request-bucket capacity for marked proof routes; must be positive | `60` |
| `SHOMEI_LOCKOUT_WINDOW_SECONDS` | rolling failure-count window; must be positive | `900` |
| `SHOMEI_LOCKOUT_DURATION_SECONDS` | account lockout duration after the threshold is reached; must be positive | `900` |
| `SHOMEI_DB_POOL_SIZE` | PostgreSQL connections the server holds open. Must be positive; the boot fails otherwise | `10` |
| `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` | how long a request waits for a free pooled connection before failing. Must be positive | `10000` |
| `SHOMEI_DB_STATEMENT_TIMEOUT_MS` | maximum duration of one PostgreSQL statement or an idle transaction. Must be non-negative; `0` disables both guards | `30000` |
| `SHOMEI_ISSUER` | JWT `iss` | `shomei` |
| `SHOMEI_AUDIENCE` | JWT `aud` | `shomei-clients` |
| `SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS` | seconds of tolerance the verifier grants `exp`/`nbf`/`iat` (inherited by downstream hosts using `shomei-jwt`'s `verifyToken`); must be non-negative | `30` |
| `SHOMEI_ACCESS_TTL` / `SHOMEI_REFRESH_TTL` / `SHOMEI_SESSION_TTL` | token/session lifetimes (seconds) | config defaults |
| `SHOMEI_TOKEN_TRANSPORT` | `bearer` \| `cookie` \| `both`. `cookie`/`both` set `HttpOnly` cookies and accept them as credentials; `bearer` neither sets nor accepts them | `bearer` |
| `SHOMEI_COOKIE_SECURE` | mark Shōmei's cookies `Secure` (HTTPS only; browsers exempt localhost) | `true` |
| `SHOMEI_COOKIE_SAMESITE` | `strict` \| `lax` \| `none` | `lax` |
| `SHOMEI_CSRF_ALLOWED_ORIGINS` | **set this in production.** Comma-separated origins allowed to make cookie-authenticated *mutating* requests, e.g. `https://app.example.com`. Anything else gets `403 csrf_rejected` | `http://localhost:8080` |
| `SHOMEI_SESSION_CHECK` | `token-only` \| `token-and-session` | `token-only` |
| `SHOMEI_SIGNING_ALG` | JWT signing algorithm for keys generated on first boot: `ES256` \| `RS256` | `ES256` |
| `SHOMEI_KEY_REFRESH_INTERVAL` | seconds between background reloads of signing-key material, so `keys activate`/`keys revoke` reach a running server; `0` disables the periodic reload (`SIGHUP` still reloads) | `60` |
| `SHOMEI_NOTIFIER_LOG_SECRETS` | **development only.** Log the full password-reset / verification link, raw token included, instead of a SHA-256 prefix. Anyone who can read the log can then take over an account | `false` |
| `SHOMEI_NOTIFIER_QUEUE_SIZE` | maximum notifications held for the background delivery worker. Must be positive; a full queue drops new work with a `queue_full` audit reason instead of blocking a request | `1024` |
| `SHOMEI_SMTP_PASSWORD` | SMTP authentication password; carried outside printable `ShomeiConfig` | unset |
| `SHOMEI_WEBHOOK_SECRET` | secret used to sign webhook deliveries; carried outside printable `ShomeiConfig` | unset |
| `SHOMEI_WEBHOOK_ALLOW_INSECURE` | **lab only.** Allow an `http://` notification receiver; production webhooks must use HTTPS | `false` |
| `SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH` | **lab only.** Allow SMTP credentials over `smtpTlsMode=plain`; production authentication must use STARTTLS or implicit TLS | `false` |
| `SHOMEI_EMAIL_VERIFICATION_REQUIRED` | require a verified email before subsequent token issuance (the initial signup session is still issued) | `false` |
| `SHOMEI_KEY_ENCRYPTION_KEY` | **Required.** 32 bytes, base64; envelope-encrypts every signing key at rest | — |
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
| `SHOMEI_MFA_REQUIRE_SECOND_FACTOR` | require MFA for accounts with an enrolled factor | `true` |
| `SHOMEI_MACHINE_TOKEN_TTL` | `client_credentials` and token-exchange access-token lifetime, seconds | `300` |
| `SHOMEI_SWEEP_ENABLED` | run the background expired-data sweeper in-process. Set `false` if you schedule `shomei-admin sweep` externally | `true` |
| `SHOMEI_SWEEP_INTERVAL_SECONDS` | seconds between sweep cycles. Must be positive | `3600` |
| `SHOMEI_SWEEP_BATCH_SIZE` | rows deleted per statement (sessions per statement, for refresh tokens). Must be positive | `1000` |
| `SHOMEI_SWEEP_DEAD_SESSION_GRACE_DAYS` | grace before an expired/revoked session and its refresh-token family are deleted | `30` |
| `SHOMEI_SWEEP_ONE_TIME_TOKEN_GRACE_DAYS` | grace before expired verification/reset tokens and elapsed lockouts are deleted | `7` |
| `SHOMEI_SWEEP_CEREMONY_GRACE_MINUTES` | grace before expired WebAuthn ceremonies are deleted | `60` |
| `SHOMEI_LOGIN_ATTEMPT_RETENTION_DAYS` | maximum age of `shomei_login_attempts` rows. Must be positive | `90` |
| `SHOMEI_AUTH_EVENT_RETENTION_DAYS` | maximum age of audit events. **Unset, `0`, or negative retains the audit trail forever** | unset |
| `SHOMEI_ARGON2_MEMORY_KIB` | Argon2id memory cost, KiB, for **newly hashed** passwords. Must be at least `max(8, 8 × parallelism)` and fit in 32 bits | `65536` (64 MiB) |
| `SHOMEI_ARGON2_ITERATIONS` | Argon2id time cost for newly hashed passwords. Must be at least 1 and fit in 32 bits | `3` |
| `SHOMEI_ARGON2_PARALLELISM` | Argon2id lanes for newly hashed passwords. Must be at least 1, fit in 32 bits, and have at least 8 KiB of memory per lane | `1` |
| `SHOMEI_HASHING_MAX_CONCURRENCY` | how many Argon2 hashes may run at once, process-wide. Must be positive | `2` |
| `SHOMEI_RTS_OPTS` | GHC runtime options the container entrypoint passes as `+RTS … -RTS`. Empty string passes none. **Do not use `GHCRTS`** — it leaks into `dhall-to-json` and breaks config loading | `-N<cpu-quota> [-A64m] --nonmoving-gc` |
| `SHOMEI_CGROUP_ROOT` | where the entrypoint looks for the CPU quota. A test seam; leave unset | `/sys/fs/cgroup` |
| `DATABASE_URL` | connection string used by `shomei-admin` | — |

### Sizing the connection pool

`SHOMEI_DB_POOL_SIZE` bounds how many requests can touch PostgreSQL at once; a request that
finds every connection busy waits up to `SHOMEI_DB_POOL_ACQUISITION_TIMEOUT_MS` and then fails.
Token verification on the authenticated hot path is pure in-memory work and takes no connection
under the default `SHOMEI_SESSION_CHECK=token-only`; `token-and-session` adds one session read per
authenticated request, so size for it if you enable it. Otherwise the pool only has to cover the
write workflows (signup, login, refresh, logout) plus `shomei-admin`. Size it against the database's
own `max_connections` budget shared across every replica, not against request concurrency, and
prefer shedding load with a short acquisition timeout over queueing behind a saturated pool.

Every new pooled connection sets PostgreSQL's `statement_timeout` and
`idle_in_transaction_session_timeout` from `SHOMEI_DB_STATEMENT_TIMEOUT_MS`. The 30-second default
is deliberately well above Shōmei's indexed single-row and bounded-batch statements, while still
releasing a slot held by a lock wait, runaway plan, or leaked transaction. Set `0` only when the
database or an embedding host supplies an equivalent bound. The in-process sweeper uses one
additional dedicated connection, so budget `SHOMEI_DB_POOL_SIZE + 1` per server replica when it is
enabled.

### PostgreSQL version

Shōmei migrations run through pg-migrate's compatibility contract
(`mori://shinzui/pg-migrate/docs/compatibility`). The runner reads the server's major version
before initializing or changing the migration ledger and returns `UnsupportedPostgresVersion`
unless that major is PostgreSQL 17 or 18. Shōmei's integration suites run on PostgreSQL 17.

Migration `0035-status-checks-and-case-insensitive-identity.sql` adds eleven `CHECK` constraints
and four expression indexes. Each `ADD CONSTRAINT` validates the existing table while holding the
required table lock, and each unique index scans its source table. This is negligible for a fresh
0.1.0.0 installation; on a populated host, inspect and repair out-of-vocabulary status values and
case-variant login/email collisions first, then schedule the migration for a maintenance window
sized for those scans.

Migration `0036-unique-password-credential-per-user.sql` makes the workflow's one-credential-per-
user assumption a unique index. Before upgrading a populated database, this query must return no
rows:

```sql
SELECT user_id, count(*)
FROM shomei.shomei_password_credentials
GROUP BY user_id
HAVING count(*) > 1;
```

Resolve any duplicates before migration. Building the index takes a `SHARE` lock on
`shomei_password_credentials` for its duration, so schedule the upgrade accordingly on a large
credential table.

### Migration composition and authoring

An embedding application should compose `shomeiMigrationComponent` with its own pg-migrate
components in one explicitly ordered `MigrationPlan`. pg-migrate uses one dedicated connection for
the complete plan, so Shōmei migrations do not rely on or permanently change the connection's
ambient namespace. Every Shōmei-owned relation is written with its `shomei.` schema qualifier, and
every transactional file contains exactly this temporary lookup path:

```sql
SET LOCAL search_path = pg_catalog, pg_temp;
```

`SET LOCAL` ends automatically when that migration commits or rolls back. Keeping `pg_catalog`
first also makes built-in types, functions, operators, and collations deterministic. Do not replace
it with ordinary `SET`, add `shomei` to the path, or depend on a host-provided path.

Qualify a `CREATE INDEX` statement's table target, not the new index name. PostgreSQL places the
index in the table's schema and does not accept a schema-qualified new index name:

```sql
CREATE INDEX IF NOT EXISTS shomei_sessions_user_id_idx
  ON shomei.shomei_sessions (user_id);
```

Use a nontransactional migration only for one statement PostgreSQL forbids inside a transaction,
with pg-migrate's leading `-- pg-migrate: no-transaction` directive. Such a file cannot use
`SET LOCAL` and must not mutate `search_path`; schema-qualify every non-built-in object directly.

Create and validate migrations through the repository recipes:

```bash
just new-migration add-something
just migration-check
```

The scaffold recipe inserts the canonical transactional header atomically after pg-migrate creates
the manifest entry and SQL file. The check validates pg-migrate's manifest contract and Shōmei's
namespace policy. [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md)
is the current durable policy; older plans that show an ordinary session `SET` are historical.

### Password hashing cost and concurrency

Passwords are hashed with **Argon2id** at 64 MiB / 3 iterations / 1 lane, which is at or above
every OWASP-recommended configuration. `SHOMEI_ARGON2_*` changes the cost for **newly hashed**
passwords only: every stored hash records the parameters it was made with, so retuning the cost
never invalidates an existing credential, and old and new hashes coexist indefinitely. Below
19 MiB / 2 iterations the server logs a prominent warning at boot but still starts — test rigs
legitimately want cheap hashing.

The server validates the implementation's hard limits before opening its database pool, then runs
one real trial derivation. A setting rejected by crypton's C core or by the machine's allocator
therefore causes the server to refuse to boot, naming the configured `m`, `t`, and `p` values,
instead of turning every later signup or password change into a server error. `shomei-admin users create` applies the same pure
limits, Dhall password policy, and HIBP breach-check policy as the server before it writes the
bootstrap account.

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

### Behind a reverse proxy

`shomei-server` serves plaintext HTTP; it does not include `warp-tls`. Production deployments
normally terminate TLS at a reverse proxy. The public URL must still use HTTPS because
`cookieSecure` and the browser `Origin` check describe the public connection, not the proxy-to-
Shōmei hop.

By default Shōmei trusts no forwarded header. Every request is therefore attributed to the TCP
peer, which is the proxy in this topology. The default `maxFailedLoginsPerIp` policy then shares
one twenty-failure, fifteen-minute budget across every user. Set `SHOMEI_TRUSTED_PROXIES` to the
exact proxy address or subnet so Shōmei can walk `X-Forwarded-For` from the right and select the
rightmost untrusted client. If that is impossible, raise `SHOMEI_MAX_FAILED_LOGINS_PER_IP` and
enforce an equivalent limit at the proxy. [ADR-15](../adr/0015-forwarded-client-identity-requires-an-explicit-trusted-proxy.md)
records the fail-closed trust policy and rightmost-untrusted rule.

For a proxy on loopback, an nginx deployment can use:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location /metrics {
    allow 10.0.0.0/8;
    deny all;
    proxy_pass http://127.0.0.1:8080;
}
```

```bash
SHOMEI_TRUSTED_PROXIES=127.0.0.1/32 shomei-server
```

The same settings are available as the Dhall keys `trustedProxies` and `proxyProtocol`.
`SHOMEI_PROXY_PROTOCOL=required` is the alternative for a TCP proxy such as HAProxy configured
with `send-proxy`. Warp reads only PROXY protocol v1. Required means every connection must carry
the header, including orchestrator HTTP probes; Shōmei deliberately does not expose warp's
optional mode because accepting both forms lets a direct client spoof its address.

### Dhall config file

The schema is `config/shomei-types.dhall`; it is the authoritative list of file keys and their
types. A worked example is `config/shomei.example.dhall`. Copy it to `config/shomei.dhall`
(gitignored, holds secrets), edit, and point the server at it:

```bash
SHOMEI_CONFIG=config/shomei.dhall PG_CONNECTION_STRING=… cabal run exe:shomei-server
```

Every field is optional; an absent field falls back to the built-in default, and any `SHOMEI_*`
environment variable overrides the file. Construct a partial, type-checked configuration with
record completion; values you set are wrapped in `Some`:

```dhall
let Shomei = ./shomei-types.dhall

in  Shomei::{
    databaseUrl = Some "host=localhost dbname=shomei",
    port = Some 8080,
    webauthnOrigins = Some [ "http://localhost:8080" ]
  }
```

Adding a later optional key to the schema does not require existing completed files to mention it.
The configuration test compares the schema's keys with the loader's `FileConfig`, so either side
changing alone fails the suite. Common policy keys include `notifierTransport`, `oidcEnabled`, and
`defaultRoles`; the schema is authoritative for the complete set. See [passkeys.md](passkeys.md) for WebAuthn and
[machine-tokens.md](machine-tokens.md) for service accounts.

There is deliberately **no** Dhall key for `SHOMEI_NOTIFIER_LOG_SECRETS`,
`SHOMEI_WEBHOOK_ALLOW_INSECURE`, `SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH`, or
`SHOMEI_KEY_ENCRYPTION_KEY`: these are secrets or security-posture escape switches, and must be
explicit per-process decisions rather than lines that linger in a committed file.

## The `shomei-admin` CLI

```text
shomei-admin migrate                              # apply pending migrations
shomei-admin keys generate [--alg ES256|RS256]    # mint a pending key (default ES256), print its kid
shomei-admin keys activate <kid>                  # promote pending → active (old key auto-retires)
shomei-admin keys retire <kid>                    # active → retired (still trusted in JWKS)
shomei-admin keys revoke <kid>                    # → revoked (removed from JWKS, distrusted)
shomei-admin keys list                            # kid / status / timestamps
shomei-admin keys rewrap                          # re-encrypt under a new SHOMEI_KEY_ENCRYPTION_KEY
shomei-admin users create --email … [--password-file PATH] [--display-name …] [--email-verified]
shomei-admin audit events|user|session|count …     # read the security audit trail
shomei-admin sweep [flags]                        # delete expired/dead rows once, then exit
```

A fresh deployment runbook: `migrate` → `keys generate` → `keys activate <kid>` → optionally
`users create`. The container entrypoint (`deploy/entrypoint.sh`) does the first three
automatically.

`users create` reads the password from stdin by default (with echo disabled when stdin is a
terminal), or from `--password-file PATH`. It removes one trailing line ending and refuses an
empty secret. The password never appears in the process argument list. Use `--email-verified`
for a bootstrap administrator whose address has already been established out of band:

```bash
printf '%s\n' "$BOOTSTRAP_PASSWORD" |
  shomei-admin users create --email admin@example.com --email-verified
```

The command loads `SHOMEI_CONFIG` plus the same core `SHOMEI_*` overrides as the server, including
password length, common/contextual-password rejection, breach checking, and default roles.

Activation retires the previous active key and promotes the selected pending key in one database
transaction. PostgreSQL's `shomei_signing_keys_one_active` index refuses a second active row; if
another activation wins concurrently, the CLI asks you to run `keys list` and retry. `keys list`
prints `created=`, `activated=`, `retired=`, and `revoked=` timestamps for every row.
Database failures are reduced to a connection/acquisition/statement category and, for server
statement failures, SQLSTATE; SQL text, parameters, and key envelopes are never printed.

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

Shōmei requires `SHOMEI_KEY_ENCRYPTION_KEY` and stores every private signing key as an `enc:v1:`
envelope. Missing or malformed KEK material is a startup error. Generate and store the KEK before
the first server or `keys generate` invocation:

```bash
# 1. Generate a KEK and store it in your secret manager. Back it up separately from the
#    database — losing it loses the signing keys, with no recovery path.
head -c 32 /dev/urandom | base64

export SHOMEI_KEY_ENCRYPTION_KEY='<base64 value from the secret manager>'
shomei-admin keys generate
```

The server and `shomei-admin keys generate` both require the KEK. The server rejects any signing
key row without the encrypted envelope. The pure status transitions — `activate`, `retire`,
`revoke`, `list` — never touch key material and need nothing.

**Rotating the KEK.** Rows are few, so a rewrap takes milliseconds:

```bash
export SHOMEI_KEY_ENCRYPTION_KEY_OLD="$OLD_KEK"
export SHOMEI_KEY_ENCRYPTION_KEY="$NEW_KEK"
shomei-admin keys rewrap               # → rewrapped 3 key(s)
```

`rewrap` decrypts every row in memory before writing any of them, so a wrong
`SHOMEI_KEY_ENCRYPTION_KEY_OLD` aborts with `no rows were modified` — a half-rewrapped table
would be readable by neither KEK. Afterwards, deploy the new KEK to the servers and restart them; the public
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
   hits `/health/ready`.

The server reaches the database over `PG_CONNECTION_STRING` (the Unix socket), so there is no
host/port to configure and nothing to clash with. Then, from another shell:

```bash
curl -s -X POST localhost:8080/v1/auth/signup -H 'content-type: application/json' \
  -d '{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'
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
`gracefulShutdownTimeoutSeconds`), closes the notifier queue and gives its queued/in-flight
deliveries the same bounded drain window, then closes the connection pools and exits 0. A plain
`Dockerfile` is provided as the documented, non-reproducible secondary path. Point the container
at your own managed PostgreSQL with `PG_CONNECTION_STRING`.

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
default — a background thread, every `SHOMEI_SWEEP_INTERVAL_SECONDS` — on a dedicated
one-connection pool, so a long drain never occupies request capacity. That connection counts
toward PostgreSQL's `max_connections` budget and is released on graceful shutdown; the pool's
idleness timeout closes it between hourly cycles. The task logs one structured JSON line per cycle
on stderr:

```json
{"level":"info","msg":"sweep","refresh_tokens":3,"sessions":1,"verification_tokens":0,"reset_tokens":0,"ceremonies":1,"authorization_codes":0,"lockouts":0,"login_attempts":0,"role_grants":0,"auth_events":0,"duration_ms":48.3}
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
authorization_codes: 0
lockouts:            0
login_attempts:      0
role_grants:         0
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
| `shomei_webauthn_pending_ceremonies` | expired longer ago than the grace period | 60 minutes |
| `shomei_oauth_authorization_codes` | expired longer ago than the ceremony grace | 60 minutes |
| `shomei_account_lockouts` | the lock elapsed longer ago than the grace period | 7 days |
| `shomei_login_attempts` | older than the retention window | 90 days |
| `shomei_role_grants` | `expires_at` passed longer ago than the one-time-token grace (forever grants are never touched) | 7 days |
| `shomei_auth_events` | older than the retention window | **never** (opt-in) |

Two of these deserve explanation.

**Refresh tokens are swept via their session, never on their own expiry.** Reuse detection
recognizes a replayed token by finding its `used` row still in the table; deleting those rows
early would silently downgrade "token reuse — revoke the whole family" to "unknown token". The
30-day grace on dead sessions keeps the entire detection window intact, because by then every
token in the family is unusable anyway. Lowering `SHOMEI_SWEEP_DEAD_SESSION_GRACE_DAYS` below
your refresh-token TTL narrows that window; do not.

**Lockout rows are written only when an account locks.** The running failure count is not stored in
`shomei_account_lockouts` at all — it is counted from `shomei_login_attempts` inside the lockout
window on every failure — so a lockout row always carries a `locked_until`, and the sweeper deletes
it once that instant is a grace period in the past. A successful login clears an elapsed lock
immediately; the sweeper is only hygiene.

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
never takes the server down, and `GET /health/live` keeps answering throughout.

## Operations

- **Liveness** `GET /health/live` (restart decisions); **readiness**
  `GET /health/ready` (traffic gating). Both return the servant-health
  `{"status","check","failingSince"}` shape at 200 or 503.
- **Metrics** `GET /metrics` (Prometheus) is unauthenticated and internal. Deny it on the public
  virtual host and allow only the monitoring network, as in the reverse-proxy example above.
- **Logs** are one structured JSON line per request on stdout, each with an `X-Request-Id`
  correlation id that is also returned to the client. Background tasks (the sweeper, key
  reloads) log JSON lines on stderr.
- **Data retention** is handled by the sweeper; audit-event deletion is opt-in (see above).
- **Key rotation** is zero-downtime — see [security.md](security.md).

## CI

`.github/workflows/ci.yaml` runs `cabal build all`, `cabal test all`, and
`nix fmt -- --fail-on-change` on every push and pull request, all inside the Nix dev shell.
