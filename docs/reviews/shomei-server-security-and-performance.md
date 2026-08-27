---
type: Review
title: shomei-server runtime, middleware, key loading, notifiers, and the admin CLI
description: >-
  Key loading, reload, envelope handling, logging hygiene, HIBP k-anonymity, outbound TLS,
  and the supervisor all hold, but an SMTP DATA-stage rejection persists the raw reset token
  to stderr and the audit trail, per-IP defences collapse behind a proxy, the notifier runs
  synchronously on the request path, chunked bodies bypass the cap, the Prometheus method
  label is unbounded, and the embedding entry point ships none of the runtime stack — so
  changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-8
subject: mori://shinzui/shomei/packages/shomei-server
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - operability
  - performance
  - correctness
  - design
  - documentation
context: >-
  One reader agent read every module under src/ and app/, the server, admin, health, config,
  middleware, notify, and supervisor test suites (the admin suite's second half by grep), the
  Dhall type file, Dockerfile, entrypoint, process-compose file, and deployment.md; it read
  warp 3.4.15, wai 3.2.5, http-client-tls 0.4.0, crypton-connection 0.4.6, smtp-mail 0.5.0.1,
  mime-mail 0.5.2, hasql-pool 1.4.2.3, and servant-health in source, and rendered a sample
  message with runghc to confirm where the reset link sits inside an SMTP failure string. The
  review of record re-read Notify.hs and smtp-mail's tryCommand before grading the top finding.
  The five shomei-server suites (120 cases) passed at the commit.
---

# shomei-server runtime, middleware, key loading, notifiers, and the admin CLI

## Verdict

Changes requested. The key material path is as documented and tested: the KEK is base64,
stripped, exactly 32 bytes or fatal; it lives in a `ScrubbedBytes` newtype with no `Show`; a
wrong KEK, a tampered envelope, and a relabelled row collapse to one `KeyDecryptFailed`; signer,
verifier key set, and JWKS body are one immutable `LoadedKeys` swapped atomically in one `IORef`
and re-read per request; reload keeps last-good material and readiness fails when no active key
exists; only the signer needs the KEK. Request logs carry method, path, status, duration,
request id, and client IP and nothing else, written as one strict `hPut`; the client-supplied
request id is sanitized; `setOnException` routes to the structured logger; the rate-limiter's
eviction is lossless and bounded; the in-flight gauge is exception-safe; HIBP sends a five-hex
prefix with padding; outbound TLS validates certificates with the system store and STARTTLS
aborts rather than downgrades; the supervisor backs off and rethrows async exceptions; RTS flags
are passed with `+RTS … -RTS`, never `GHCRTS`. The defaults are conservative everywhere the
documentation says they are.

The findings are where an operational edge meets a security promise.

## Findings

**1. High — an SMTP relay that rejects at the DATA stage persists the live one-time token.**
smtp-mail's `tryCommand` fails with `"Unexpected reply to: " ++ show cmd` and for the final
command `cmd = DATA <whole rendered message>` (`smtp-mail-0.5.0.1 Network/Mail/SMTP.hs:167-177,
319-323`; `Command` derives `Show`). `deliverSmtp` catches it (`src/Shomei/Notify.hs:194-201`),
`truncateError` keeps the first 500 characters (`:325-333`), and `publishDeliveryFailed` prints
that to stderr and persists it as `NotificationDeliveryFailed.errorText` (`:287-323`). With the
documented example addresses the rendered exception is 620 characters and `token=` begins at
368, so the full 43-character reset token is inside the cap. Greylisting (451) and content or
size rejections (550/552/554) at DATA are routine. Anyone with log access,
`shomei-admin audit --json`, or `GET /v1/admin/audit/events` then holds an account-takeover token
for its TTL, against `notifications.md:204-207`'s "never the token". `NotifySpec` covers only a
refused connection. Remedy: never persist `displayException` of a transport error verbatim — map
to a reason code, or strip after `Unexpected reply to: DATA`; add a NotifySpec case for a `451` at
DATA.

**2. High — behind a reverse proxy the per-IP defences collapse into one bucket.** `clientKey`
is `remoteHost` (`src/Shomei/Server/Middleware/RateLimit.hs:174-181`) and the login handler's
`ClientIp` is the same peer; nothing reads a forwarded header (grep). The binary serves plaintext
only (no `warp-tls` dependency) and `cookieSecure` defaults on, so production sits behind a TLS
terminator where every client shares one address: twenty wrong passwords from anyone make every
login answer `429` for the window, sustained by twenty requests per fifteen minutes, and the WAI
bucket throttles the whole user base at 60/min. `docs/capabilities/abuse-protection.md:75-78`
states the collapse; `deployment.md` (no match for proxy, forwarded, or TLS) and
`security.md:230-245` do not, and external TLS termination is documented nowhere in `docs/user`.
Remedy: `SHOMEI_TRUSTED_PROXIES` with rightmost-untrusted `X-Forwarded-For` (or warp's PROXY
protocol) applied before both the limiter and the handlers; until then, a loud note.

**3. High — the embedding entry point ships none of the runtime stack.** Key reload, the
sweeper, the rate limiter, the body cap, metrics, request logging, `defaultRoles` validation, and
graceful shutdown are installed in `Boot.main` only (`src/Shomei/Server/Boot.hs:86-148`);
`Boot.application` is `problemMiddleware` plus `serveWithContext` (`:370-374`), and both embedded
examples use exactly that. An embedding host therefore keeps trusting a revoked signing key
until restart, buffers unbounded bodies, and has no request-rate limit, while `security.md`'s
"takes effect on a live server with no restart" reads as if it applied. The only embedder
guidance is a Haddock at `Boot.hs:180-181`. Remedy: export an `installHostBackgroundTasks` and
`hostMiddleware` (or make `application` take the stack), use them in the examples, and add an
embedding checklist to `client-and-examples.md`.

**4. Medium — synchronous SMTP and webhook delivery on the request thread.** The notifier is
interpreted inside the request's `runAppIO` (`src/Shomei/Server/App.hs:184`); SMTP has a 10 s
timeout (`Notify.hs:207-223`) and the webhook up to three attempts of 5 s with backoff
(`:371-404`, about 20 s worst case). `password-reset/request` and `verify-email/request` block
that long for a registered address and return immediately for an unknown one — an existence
oracle by time, against `security.md:190-193` — and 60 req/min/IP of 20 s requests pins handler
threads. `E2ESpec.hs:215` states the delivery is synchronous. Remedy: a bounded background worker
(fire-and-forget already tolerates loss); a fixed-cost miss path.

**5. Medium — chunked request bodies bypass the 1 MiB cap.** Only `KnownLength n > limit` is
refused (`src/Shomei/Server/Middleware/BodyLimit.hs:38-41`); `MiddlewareSpec.hs:293-298` pins the
bypass as a documented caveat; Servant reads the whole body before aeson parses it and warp has
no body limit. Remedy: meter `requestBody` (the `wai-extra` `RequestSizeLimit` shape).

**6. Medium — the `http_requests_total{method=…}` label is attacker-controlled, unescaped, and
unbounded.** `method = decodeLatin1 (requestMethod req)` keys a `Map.insertWith`
(`src/Shomei/Server/Observability/Metrics.hs:112-116`) and is emitted raw (`:193-200`); warp
accepts any bytes before the first space as the method. N distinct methods are N permanent
series; a method containing `"` or `}` corrupts the exposition and blacks out the scrape.
`/metrics` is unauthenticated. Remedy: whitelist methods (else `other`), escape per the
exposition format, document `/metrics` as internal.

**7. Medium — SMTP password and webhook secret live inside the `Show`/`ToJSON` `ShomeiConfig`**
(`shomei-core/src/Shomei/Config.hs:170-199, 418-449`; injected at `src/Shomei/Server/Config.hs:779,
832`), the record `security.md:183-184` says is kept secret-free because it is logged. Nothing in
the tree shows or encodes it today; `Seam.Env.config` is handed to every embedding host. Remedy:
move both to `Env` beside the KEK and TOTP key, or a redacting newtype.

**8. Medium — the throttled-path list is literal and partial, and `RateLimited` enforces
nothing.** Five paths are throttled (`RateLimit.hs:162-172`); `login/passkey/begin|complete`,
`mfa/complete`, the confirm routes, and `/oauth/token|introspect|revoke` are not;
`shomei-servant`'s `RateLimited` marker routes straight through. `login/passkey/begin` inserts a
pending-ceremony row per unauthenticated request. `api.md:197` says `/oauth/token` is not
rate-limited. Remedy: derive the list from the API type or make the combinator real.

**9. Low — `shomei-admin users create --password` takes the secret on argv** (visible in `ps`
and shell history), hashes with the server's Argon2 parameters but enforces the *default*
password policy rather than the Dhall-configured one, skips the breach check, and leaves the
email unverified, so with `emailVerificationRequired` on the bootstrap user cannot log in
(`app/Admin.hs:88-92`; `app/Shomei/Admin/Users.hs:147-152`; `Admin/Env.hs:41-51`).

**10. Low — the Dhall path silently weakens two WebAuthn policies on typos**
(`parseUserVerification`/`parseAttestation` default to `preferred`/`none` on unrecognized text,
`Server/Config.hs:984-997`, where the env path errors) **and unknown Dhall keys are ignored**
(`FileConfig` derives `FromJSON` without `rejectUnknownFields`, `:260-261`), so `cookieSecue =
False` is accepted without a word.

**11. Low — env secrets are not trimmed.** `SHOMEI_SMTP_PASSWORD`, `SHOMEI_WEBHOOK_SECRET`, and
`PG_CONNECTION_STRING` go through `textEnvMaybe` without `strip` (`Server/Config.hs:1025-1030`)
while the KEK and TOTP key are stripped; a mounted secret's trailing newline silently breaks SMTP
auth or the HMAC, and delivery is fire-and-forget.

**12. Low — webhook posture.** `http://` receivers are accepted (`Server/Config.hs:888-890`);
the HMAC covers the body only, with no timestamp, so a captured POST replays indefinitely
(`Notify.hs:409-411`); `newTlsManager` honours `http_proxy`/`https_proxy` from the environment
silently. `smtpTlsMode = plain` with credentials is accepted without a warning.

**13. Low — wall-clock time drives the token bucket and the latency histogram**
(`RateLimit.hs:145`; `Metrics.hs:103, 106`) while logging and shutdown use the monotonic clock; a
backward NTP step over-throttles and a forward step refills every bucket.

**14. Low — `/health/ready` runs an untimed, unthrottled pool checkout and query per
unauthenticated GET** (`src/Shomei/Health/Server.hs:29-40`; `withProbeTimeout` wraps liveness
only); a hung database makes readiness hang for the 10 s acquisition timeout rather than answer
`503` promptly.

**15. Low — two error bodies escape the RFC 9457 envelope**: the 413 from the body cap
(`{"error":"payload_too_large"}`, `application/json`) and warp's plain-text 500 for escaped
exceptions (no `setOnExceptionResponse`).

**16. Info — configuration surface.** `config/shomei-types.dhall` (49 keys) lags `FileConfig`
(70 keys) by twenty, including `tokenTransport`, `cookieSecure`, `cookieSameSite`, and
`csrfAllowedOrigins`; `rateLimitEnabled`, `perIpBurst`, `maxFailedLoginsPerIp`, `lockoutWindow`,
and `lockoutDuration` have no env var and the last three no Dhall key either, so the per-IP
counter that finding 2 makes dangerous cannot be tuned; `deployment.md:141-158`'s Dhall list
omits the notifier, TOTP, OIDC, OAuth, and `defaultRoles` keys.

**17. Info — smaller observations.** `keys activate` is two autocommit statements
(`app/Shomei/Admin/Keys.hs:76-79`) and `keys rewrap`'s write pass is not one transaction
(`:105-114`); `assembleKeys` tolerates several active keys by newest `activated_at`. The audit CLI
accepts and prints bare UUIDs only while the roles CLI accepts TypeIDs — the exact
copy-paste trap `authorization.md` warns en integrators about. Every request line is
`level=info`, including 401/429/500. HIBP failures are entirely silent. `Admin/Keys.hs:168-171`
prints the raw hasql `UsageError` (SQL plus encrypted envelopes) to stderr. `buildEnv` applies
migrations on every boot in addition to the entrypoint (pg-migrate's advisory lock serializes
replicas). Warp has no connection cap and binds `*4` with no `setHost`.

## Verified holds

- Middleware order logging → metrics → `/metrics` → body cap → limiter → app
  (`Boot.hs:114-122, 145`).
- Logging: fields at `Logging.hs:72-82`; `rawPathInfo` excludes the query; escaping `:93-100`;
  one `hPut` `:104-105`; request id sanitized to `[A-Za-z0-9_.:-]` ≤ 64 (`:141-152`); health
  paths skipped; `MiddlewareSpec.hs:192-275`.
- `setOnException` → structured JSON filtered by `defaultShouldDisplayException`;
  `setServerName "shomei"`; SIGTERM/SIGINT graceful drain then pool release (`Boot.hs:127-148`).
- 429 is `application/problem+json` with `Retry-After: 60`; eviction every 4096 calls, lossless,
  bounded under IP spraying (`RateLimit.hs:82-83, 118-138`; `MiddlewareSpec.hs:85-123`); key
  excludes the port; oversized bodies refused before draining a bucket.
- In-flight gauge decremented in `finally`; path never a label (`Metrics.hs:86-110`).
- KEK and envelope: `Protection/Jwt.hs:52-81, 103-116`; `Keys.hs:78-86, 138-146`;
  `ConfigSpec.hs:307-317`; atomic swap `Keys.hs:91-95, 196`; reload and SIGHUP `Boot.hs:219-226`;
  last-good `Keys.hs:190-207`; first boot writes encrypted, plaintext rows refused; rewrap
  decrypt-all-first (`Admin/Keys.hs:105-126`, tested).
- HIBP: five-hex prefix, `Add-Padding: true`, per-call timeout, any failure →
  `BreachCheckUnavailable`, nothing about the password logged (`BreachChecker.hs:39-61`).
- Outbound TLS: crypton-connection's default `TLSSettingsSimple False False False` validates
  with the system CA store; smtp-mail's STARTTLS path requires `220` or fails; AUTH failure text
  carries no credentials.
- Notifier secrets and `SHOMEI_NOTIFIER_LOG_SECRETS` are env-only; the log sender prints an
  8-hex SHA-256 prefix; webhook signature is HMAC-SHA256 over the exact bytes (tested).
- Supervisor: sync exceptions logged with 5 s → 300 s backoff reset on success; async rethrown;
  interval ≥ 1 s (`Supervisor.hs:64-103`).
- hasql failures never cross into responses or logs un-collapsed; boot validates pool, sweep,
  Argon2, hashing, notifier completeness, OIDC issuer, and default roles.
- RTS: `+RTS -N<quota> [-A64m] --nonmoving-gc -RTS` from cgroup v1/v2 in
  `deploy/entrypoint.sh:28-92`; Dockerfile sets no RTS env.
- Admin: service-account and OAuth-client secrets are 32 random bytes printed once with only the
  SHA-256 stored; public clients get no secret; `roles grant`/`allow` refuse undefined roles;
  `users create` validates default roles before writing; `Env` and `TotpEncryptionKey` have no
  `Show`.

## Defaults assessed

`cookieSecure` true, `SameSite=Lax`, bearer transport, `VerifyTokenOnly`, 15 min / 30 d / 30 d
token and session TTLs, 24 h / 1 h one-time tokens, lockout 5 / 15 min / 15 min, ES256 with 60 s
reload, email verification off, `logRawTokens` false, `requireSecondFactor` true, TOTP and OIDC
off, machine tokens 5 min, impersonation 30 min / 5 min freshness, pool 10 / 10 s, Argon2
64 MiB / 3 / 1 with a 19 MiB warning floor, hashing concurrency 2, sweeper hourly in batches of
1000 with audit retention off — all acceptable. Weak: `maxFailedLoginsPerIp` 20 with no reset and
no tuning knob (unsafe behind a proxy); the 60/60 bucket shared behind a proxy; synchronous
notifier timeouts; the `Content-Length`-only body cap; `/metrics` unauthenticated; WebAuthn and
CSRF origin defaults that are right for dev and must be overridden in production, which the
docs say but the boot does not check.

## Not examined

`test/Admin/Main.hs` lines ~420–912 (by grep only); `deploy/entrypoint-test.sh`,
`scripts/argon2-load-test.sh`, and the Nix flake beyond how the binary is run; servant handler
bodies (REV-7); Servant/aeson buffering of chunked bodies (asserted from the API, not re-read);
`http-client`'s `responseTimeout` coverage of DNS and connect; codd-era migration locking
(replaced by pg-migrate, REV-6).
