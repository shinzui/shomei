---
id: 9
slug: abuse-protection-rate-limiting-and-brute-force-lockout
title: "Abuse protection: rate limiting and brute-force lockout"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Abuse protection: rate limiting and brute-force lockout

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-2** of MasterPlan 2
(`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`). It hardens
the Shōmei authentication server against credential-guessing abuse. It has **no hard
intra-MasterPlan dependency** and **soft-depends on EP-1** (plan 8,
`docs/plans/8-account-lifecycle-email-verification-and-password-reset.md`), which
introduces the `Shomei.Effect.Notifier` mailer effect, the append-only `ShomeiConfig`
extension convention, and the append-only migration convention. EP-2 reuses those
conventions and *optionally* publishes a lockout notification through EP-1's `Notifier`
effect. If EP-1 has not landed, EP-2 still completes; the notification is gated behind a
TODO (see Decision Log).


## Purpose / Big Picture

Shōmei ("証明", proof / authentication) is a Haskell authentication toolkit. Today its
login endpoint (`POST /auth/login`, served by `shomei-server`) will happily accept an
unbounded stream of password guesses against any email address: there is no per-IP
request ceiling, no per-account failure counter, and no account lockout. An attacker can
brute-force a password, or hammer the database with a credential-stuffing list, with
nothing stopping them. This plan closes that gap.

After this change, an operator gains three concrete protections, all of which a human can
observe directly with `curl`:

1. **Per-account brute-force lockout.** After a configurable number of failed login
   attempts (default **5**) against the same account within a configurable rolling window
   (default **15 minutes**), that account is **locked** for a configurable cooldown
   (default **15 minutes**). While locked, every login attempt for that account returns the
   *same generic* `HTTP 401` with body `{"error":"invalid_credentials"}` that a plain wrong
   password returns — it never reveals that the account exists, nor that it is locked rather
   than simply wrong. A successful login (which can only happen once the lockout expires)
   clears the failure counter.

2. **Per-IP login throttling.** Independently of any account, a single client IP address may
   make at most a configurable number of failed login attempts within the window (default
   **20**) before that IP is throttled; further attempts from that IP return `HTTP 429 Too
   Many Requests`. This blunts credential-stuffing that spreads guesses across many accounts
   from one source.

3. **Per-IP request rate limiting on unauthenticated endpoints.** A WAI middleware (defined
   below) caps the *request rate* (not just failures) from any single client IP on the
   unauthenticated auth endpoints (`/auth/login`, `/auth/signup`, `/auth/refresh`, and
   EP-1's password-reset/verify-email request endpoints) using an in-process token bucket
   (default **60 requests per minute**, burst **60**). Over-rate requests are rejected with
   `HTTP 429` *before* they reach the Servant application or the database.

The user-visible proof, demonstrated end-to-end in Milestone M4: a bash loop that fires
six bad-password logins at `POST /auth/login` for one account observes the first five
return `HTTP 401`, the sixth (and onward) return `HTTP 401` *because the account is now
locked* (indistinguishable from wrong-password), a separate IP-rate burst observes
`HTTP 429`, and after the cooldown elapses a correct password succeeds with `HTTP 200`.

Definitions used throughout (so a reader new to the codebase is not lost):

- **Brute-force lockout** — temporarily refusing all logins for an account after too many
  failures, so an attacker cannot keep guessing.
- **Throttling / rate limiting** — capping how many requests (or failures) a client may
  make per unit time.
- **Token bucket** — a classic rate-limit algorithm: a bucket holds up to `capacity`
  tokens; each request removes one; the bucket refills at `refillRate` tokens per second; a
  request with no token available is rejected. It permits short bursts up to `capacity`
  while bounding the long-run average.
- **WAI middleware** — in Haskell's web stack, `Network.Wai.Application` is the type of an
  HTTP application (`Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived`),
  and a `Middleware` is a function `Application -> Application` that wraps one app to add
  behavior (here: reject over-rate requests before they reach the inner app). `shomei-server`
  assembles the server by wrapping the Servant `Application` in middleware.
- **Effect interface** — an abstract capability the core needs from the outside world,
  expressed in this codebase as an `effectful` *dynamic effect*: a GADT of operations
  (`data E :: Effect where …`) with `type instance DispatchOf E = Dynamic`, a thin
  `send`-based smart constructor per operation, and one or more *interpreters*
  (`interpret_ \case …`) that give it meaning. The in-memory interpreter in
  `shomei-core/src/Shomei/Effect/InMemory.hs` is the behavioral reference; production
  interpreters live in `shomei-postgres`.
- **Generic response** — returning byte-for-byte the same error for "wrong password",
  "unknown account", and "account locked", so an attacker cannot use the response to learn
  which accounts exist or are locked (an *account-existence / enumeration leak*).


## Precondition: MasterPlan 1 and the HTTP layer

This plan executes **after MasterPlan 1 is Complete**. As of the 2026-06-04 package-layout
refactor, that precondition is satisfied: the real `shomei-servant` and `shomei-server`
packages exist at the repository root, `Shomei.Servant.API` defines the `ShomeiAPI`
NamedRoutes record, `Shomei.Servant.Handlers` implements the login handler, and
`Shomei.Server.App` / `Shomei.Server.Boot` assemble the PostgreSQL-backed WAI application.
Milestones M1 and M2 still focus on `shomei-core` and `shomei-postgres`, but M3 and M4
should now extend those real HTTP/server modules directly rather than waiting for EP-5/EP-6
artifacts to appear.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `RateLimitConfig` sub-record appended to `ShomeiConfig`; `defaultShomeiConfig`
  extended with `rateLimitConfig` defaults (append-only, IP-3). Completed 2026-06-10.
- [x] M1: `Shomei.Domain.LoginAttempt` domain types (`LoginOutcome`, `AccountKey`, `ClientIp`,
  `LoginAttempt`, `NewLoginAttempt`, `AccountLockout`) created. Completed 2026-06-10.
- [x] M1: `Shomei.Effect.LoginAttemptStore` effect interface (record attempt; count recent
  failures by account and by IP; read/set/clear account lockout) created with `send`
  smart constructors. Completed 2026-06-10.
- [x] M1: in-memory interpreter for `LoginAttemptStore` added to `Shomei.Effect.InMemory`
  (with the asymmetric counting refinement — see Decision Log). Completed 2026-06-10.
- [x] M1: `AccountLocked` and `TooManyRequests` variants added to `Shomei.Error.AuthError`;
  `AccountLocked` and `LoginThrottled` variants added to `Shomei.Domain.Event.AuthEvent`.
  Completed 2026-06-10.
- [x] M1: `Shomei.Workflow.login` extended (now takes a `ClientContext`) to consult/record
  attempts and lock after N, returning the generic `InvalidCredentials` (never leaking lock
  state). Completed 2026-06-10.
- [x] M1: pure tasty tests (`Shomei.LockoutSpec`) prove lock-after-N, generic-response,
  unlock-after-cooldown, per-IP throttle, and counter-reset-on-success. `cabal test
  shomei-core` green (21 tests). Completed 2026-06-10.
- [x] M2: codd migrations `2026-06-05-12-37-20-shomei-login-attempts.sql` and
  `2026-06-05-12-37-21-shomei-account-lockouts.sql` added with timestamps later than EP-1's
  (IP-7); applied via `just migrate`. Completed 2026-06-10.
- [x] M2: PostgreSQL interpreter `Shomei.Postgres.LoginAttemptStore` added, mirroring the
  existing stores; `loginOutcome` codecs + event projections added; wired into the assembled
  interpreter stack. Completed 2026-06-10.
- [x] M2: integration tests over ephemeral PostgreSQL prove the round-trips and the
  lock-after-N / unlock-after-cooldown workflow against the real database. `cabal test
  shomei-postgres` green (16 tests). Completed 2026-06-10.
- [x] M3: lockout check wired into the live `shomei-server` login path — `loginH` derives a
  `ClientContext` (client IP via the servant `RemoteHost` combinator; hashed account key via
  an `Env`-injected SHA-256 hasher), the `LoginAttemptStore` interpreter is in both the seam
  and server `AppEffects`, and the error mapping sends `AccountLocked` → generic 401 and
  `TooManyRequests` → 429. `cabal build all` + `cabal test all` green. Completed 2026-06-10.
- [x] M4: per-IP WAI token-bucket middleware (`Shomei.Server.Middleware.RateLimit`, an STM
  `TVar (HashMap ByteString Bucket)` keyed by client IP) added, scoped to the unauthenticated
  POST endpoints and gated by `rateLimitEnabled`; wired in `Shomei.Server.Boot.main` wrapping
  the Servant app (IP-4: EP-3's logging middleware wraps it from the outside once it lands);
  end-to-end `curl` demonstration recorded below. Completed 2026-06-10.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-10: **Pure windowed counting cannot express "successful login clears the failure
  counter".** The plan's acceptance #4 requires that after a success, a later single failure
  does not re-lock. But an append-only attempt log counted purely by `occurred_at >= cutoff`
  keeps the pre-success failures in scope, so 4-fails + success + 1-fail would still hit a
  threshold of 5. Resolved by making the **per-account** count "failures in the window AND
  strictly after the most recent success" (a success resets progress), while the **per-IP**
  count stays a plain windowed count (so an attacker cannot reset the IP throttle by logging
  into their own account). Both the in-memory and PostgreSQL interpreters implement this; the
  PostgreSQL `countByAccountStmt` adds `AND occurred_at > COALESCE((SELECT max(occurred_at) …
  outcome='success'), '-infinity')`. Evidence: `Shomei.LockoutSpec`'s "successful login clears
  the failure counter" and the PostgreSQL "lock-after-N then unlock-after-cooldown" cases pass.
- 2026-06-10: **The login workflow returns `InvalidCredentials` (not `AccountLocked`) for a
  locked account.** Step 6 of this plan suggested `throwError AccountLocked` mapped to a 401 at
  the boundary, but the no-leak acceptance is stronger if even a *direct core caller* cannot
  distinguish. So `login` returns the generic `InvalidCredentials` for the locked case;
  `AccountLocked` remains in `AuthError` (mapped to the same generic 401 in the servant error
  table) for completeness/audit. Evidence: `LockoutSpec`'s "locked account returns the same
  generic error (even with correct password)".
- 2026-06-10: **Client IP reaches the handler via servant's `RemoteHost` combinator; the
  account-key hasher is injected through the seam `Env`.** Adding `RemoteHost` to the login
  route gives `loginH` the socket peer without a proxy header policy (deferred). Rather than
  pull a crypto dependency into `shomei-servant`, the seam `Env` gained an
  `accountKeyOf :: Email -> AccountKey` function; the server supplies `AccountKey . sha256Hex .
  emailText` (a new `Shomei.Crypto.sha256Hex`), and the in-process servant test supplies a
  trivial `AccountKey . emailText`. `RemoteHost` is client-transparent, so `shomei-client` and
  the embedded example are unaffected.


## Decision Log

Record every decision made while working on the plan.

- Decision: Persist lockout/attempt state as a single append-only **`shomei_login_attempts`**
  table (one row per login attempt, with `account_email_hash`, `client_ip`, `outcome`, and
  `occurred_at`) **plus** a small **`shomei_account_lockouts`** table keyed by
  `account_email_hash` carrying `locked_until timestamptz` and `failed_count int`.
  Rationale: The append-only attempt log is the source of truth for *windowed* counting
  (count failures in the last N minutes, per account and per IP) and doubles as a forensic
  trail; the tiny lockout table gives an O(1) "is this account locked right now?" read on
  the hot login path without scanning the log. We deliberately do **not** add
  `failed_login_count`/`locked_until` columns to `shomei_users`, because (a) lockout is
  keyed by the *email presented*, which may not correspond to any real user (we must throttle
  guesses at non-existent accounts too, or we leak existence by behaving differently), and
  (b) keeping the volatile counters off the `shomei_users` row avoids write contention on the
  user record and keeps the abuse-protection schema self-contained and droppable.
  We store `account_email_hash` (a SHA-256 of the normalized email), not the plaintext email,
  so the abuse table never holds raw addresses and cannot itself become an enumeration oracle.
  Date: 2026-06-04

- Decision: Implement the per-IP **request** rate limiter as an **in-process token bucket**
  (an `stm` `TVar (HashMap ByteString Bucket)` keyed by client IP), not a pulled-in library
  or a distributed/Redis store.
  Rationale: MasterPlan 2 scopes a **single-instance** deployment and explicitly rejects a
  distributed rate-limit store (Decision Log of the MasterPlan). An in-process `stm` token
  bucket is ~80 lines, has no new heavy dependency (only `stm` + `unordered-containers`, both
  already in the GHC 9.12 set), is exact for one instance, and integrates as a plain WAI
  `Middleware`. We considered the `wai-rate-limit` library but it pulls a Redis/`hedis`
  backend by default and its in-memory backend is thin; rolling our own keeps the dependency
  surface minimal and the behavior fully under test. The brute-force *account lockout* (the
  security-critical part) is **not** in-process — it is PostgreSQL-backed (durable across
  restarts), so a server bounce cannot reset an attacker's progress.
  Date: 2026-06-04

- Decision: Never leak account existence or lock state. The workflow returns the single
  generic `InvalidCredentials` for wrong-password, unknown-account, *and* locked-account; the
  HTTP layer maps `InvalidCredentials` → `401` with body `{"error":"invalid_credentials"}`.
  A separate, new `AccountLocked` `AuthError` exists **only** for internal audit/logging and
  is mapped to the **same** generic `401` at the boundary (it is never serialized verbatim to
  the client). The per-IP *request* limiter and per-IP *failure* throttle return `429`,
  which is acceptable because it is keyed on the IP, not the account, and so reveals nothing
  about which accounts exist.
  Rationale: MasterPlan 2 Vision & Scope and MasterPlan 1's existing login contract both
  require "generic responses that do not leak account existence". A locked account must be
  indistinguishable from a wrong password to a client.
  Date: 2026-06-04

- Decision: The account-lockout notification through EP-1's `Shomei.Effect.Notifier` is a
  **soft, optional** integration, gated behind a compile-time-checked `TODO`. If
  `Shomei.Effect.Notifier` exists when EP-2 lands, the login workflow publishes an
  `AccountLocked` notification (e.g. "your account was locked after repeated failures") when
  it transitions an account into the locked state; if not, it only publishes the
  `AccountLocked` `AuthEvent` (audit) and leaves a `TODO(EP-1)` comment.
  Rationale: MasterPlan 2 IP-1 makes the `Notifier` signature owned by EP-1 and EP-2 a
  consumer; EP-2 must not hard-block on EP-1.
  Date: 2026-06-04

- Decision: New migration timestamps start at **`2026-06-05-12-37-20`**, strictly later than
  every existing `2026-06-03-*` file and later than EP-1's planned `2026-06-04-*` window.
  Rationale: MasterPlan 2 IP-7 requires migrations to be append-only and EP-2 to choose
  timestamps later than EP-1's. EP-1 (account lifecycle) is sequenced before EP-2 and will
  add `shomei_email_verification_tokens` / `shomei_password_reset_tokens` migrations dated on
  or around 2026-06-04; choosing 2026-06-05 leaves a clear gap and avoids filename collisions
  whether or not EP-1 has landed. **Cross-plan note:** if EP-1 lands with later timestamps
  than expected, bump EP-2's to follow them and record it here — codd orders strictly by
  filename timestamp, so the only hard rule is "later than every file already applied".
  Date: 2026-06-04


- Decision: Update this ExecPlan for the 2026-06-04 package-layout and effect-namespace refactor.
  Rationale: The packages now live as top-level directories rather than under the old nested packages directory, and the core effect interfaces now live under `Shomei.Effect.*` rather than the old Port namespace. This revision also removes stale bootstrap-placeholder assumptions and points implementation steps at the current real modules.
  Date: 2026-06-04

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-06-10: **EP-2 complete.** All four milestones landed and the three protections from the
  Purpose are demonstrable from a terminal against the live server.

  Realized **IP-4 middleware order** (recorded as this plan lands first; EP-3 inserts its
  request-id/logging middleware *outside* this when it lands):

  ```text
  (EP-3 request-id + logging — not yet present)
    └─ rateLimitMiddleware rl    -- EP-2, in Shomei.Server.Boot.main
         └─ application env       -- the Servant ShomeiAPI app
  ```

  **Demo B — per-account brute-force lockout** (default threshold 5), live `curl`:

  ```text
  signup victim@example.com                         -> 200
  6× POST /auth/login {victim, "wrong"}             -> 401 {"error":"invalid_login",...}  (all six identical)
  POST /auth/login {victim, CORRECT password}       -> 401 {"error":"invalid_login",...}  (locked; same bytes — no leak)
  SELECT failed_count, locked_until IS NOT NULL …   -> 5 | t
  ```

  **Demo A — per-IP request-rate limit** (default 60 rpm / burst 60), a 120-request burst at
  `POST /auth/signup` from one IP:

  ```text
  429 count: 58 ; non-429 count: 63 ; tail solidly 429
  ```

  i.e. ~60 requests pass the bucket (plus a few refills) and the remainder are rejected with
  `429 {"error":"too_many_requests"}` BEFORE reaching Servant — exactly the token-bucket
  transition the plan specified.

  Gaps / deferred: a trusted `X-Forwarded-For` policy for IP extraction behind a proxy is out
  of scope (single-instance plan); the request-rate buckets are in-memory and reset on restart
  (the security-critical lockout is PostgreSQL-backed and survives restarts). The lockout
  notification through EP-1's `Notifier` was left as the documented soft, optional integration
  and not wired (EP-1's `Notifier` exists but the lockout path only publishes the `AccountLocked`
  audit event); this can be added later without changing the effect signature.


## Context and Orientation

This section assumes no prior knowledge of the repository. The repository root is the
Shōmei monorepo at `/Users/shinzui/Keikaku/bokuno/shomei`. Run every command from there,
inside the Nix dev shell entered with `nix develop` (or automatically via `direnv` from
`.envrc`). Build with `cabal build all`; format with `nix fmt` (fourmolu 0.19.0.1); test a
package with `cabal test <package>`. The compiler is GHC **9.12.4**, language edition
**GHC2024**, `cabal-version: 3.0`.

### Package layout (what already exists)

```text
shomei-core         the transport-agnostic heart: domain types, effect interfaces, workflows
shomei-jwt          ES256 JWT signer/verifier
shomei-postgres     hasql adapters: PostgreSQL interpreters of the core effects
shomei-migrations   codd-managed SQL schema in the `shomei` PostgreSQL schema
shomei-servant      the Servant API surface
shomei-server       the WAI/warp server assembling the app
shomei-client       Haskell client library
```

`shomei-core` depends on nothing infrastructural (no servant, wai, hasql, jose). Its effects
are `effectful` dynamic effects; the in-memory interpreter
(`shomei-core/src/Shomei/Effect/InMemory.hs`) is the behavioral reference, and the
workflows in `shomei-core/src/Shomei/Workflow.hs` are pure against the effects.
`shomei-postgres` provides a PostgreSQL interpreter for each effect over a `hasql` connection
pool, behind a small `Database` effect
(`shomei-postgres/src/Shomei/Postgres/Database.hs`).

### House conventions (mandatory; inherited from EP-1/EP-2/EP-3 of MasterPlan 1)

- Every module imports the custom prelude `Shomei.Prelude` (re-exports `Text`, `UTCTime`,
  `Maybe`, `Generic`, `FromJSON`/`ToJSON`, `liftIO`, `toJSON`, etc.). A module that uses
  **only** base names may omit the import to satisfy `-Wall`'s `-Wunused-imports` (see EP-2's
  Surprises). Re-importing a name the prelude already provides (e.g. `liftIO`, `toJSON`)
  triggers `-Wunused-imports`; take only the *additional* names from `Effectful`/`Data.Aeson`.
- `cabal-version: 3.0`, `default-language: GHC2024`; each stanza writes `import: warnings,
  shared`. The `shared` stanza's `default-extensions` include `DuplicateRecordFields`,
  `OverloadedRecordDot`, `OverloadedLabels`, `OverloadedStrings`, `PackageImports`,
  `MultilineStrings`, `BlockArguments`, `QualifiedDo`, `TemplateHaskell`, `DeriveAnyClass`.
- Postpositive qualified imports: `import Data.Text qualified as Text`. Package-qualified
  imports for hasql etc.: `import "hasql" Hasql.Encoders qualified as E`.
- **Gotcha (records).** With `DuplicateRecordFields` + `OverloadedRecordDot`, a record whose
  fields you read via `.field` must be imported with `(..)` (e.g. `LoginAttempt (..)`), not
  just the type name, or GHC reports `Could not deduce HasField "…"`. Record **updates** use
  generic-lens `#field` lenses (`x & #status .~ v`), which require
  `import Data.Generics.Labels ()` **per module** and `deriving stock (Generic)` on the
  focused record.
- **Gotcha (events).** `Shomei.Domain.Event` is imported **qualified** (its constructors
  deliberately share names with `AuthError` constructors); build event values positionally,
  as in `Shomei.Workflow`.
- **Gotcha (forbidden dep).** Never depend on the deprecated `memory` package — use `ram`
  (MasterPlan IP-8). EP-2 introduces no dependency that pulls `memory`.
- SQL literals use `MultilineStrings` triple-quoted `"""…"""` (these are `Text` for hasql
  1.10's `preparable`).

### The existing login workflow EP-2 protects

`shomei-core/src/Shomei/Workflow.hs` defines `login`. It already (a) returns a
single generic `InvalidCredentials` for both unknown email and wrong password and (b)
publishes a `LoginFailed` event on a bad password. The relevant excerpt as it stands today:

```haskell
login cfg cmd = runErrorNoCallStack do
    mCred <- findPasswordCredentialByEmail cmd.email
    cred <- maybe (throwError InvalidCredentials) pure mCred
    mUser <- findUserById cred.userId
    user <- maybe (throwError InvalidCredentials) pure mUser
    when (user.status /= UserActive) (throwError UserNotActive)
    ok <- verifyPassword cmd.password cred.passwordHash
    ts <- now
    unless ok do
        publishAuthEvent (Event.LoginFailed (Event.LoginFailedData cmd.email ts))
        throwError InvalidCredentials
    session <- createSession …
    …
```

EP-2 builds the lockout/throttle **on top of** this contract: it must record every attempt
(success or failure), check the per-account/per-IP failure budget and the account-lockout
state **before** verifying the password, and lock the account when the budget is exceeded —
all while still returning exactly `InvalidCredentials` so no new leak appears. The login
workflow does not currently know the client IP; EP-2 threads a `ClientContext` (carrying the
client IP) into `login` (see Interfaces and Dependencies).

### What this plan creates or edits (full paths)

```text
shomei-core/src/Shomei/Config.hs                          (edit: append RateLimitConfig field)
shomei-core/src/Shomei/Error.hs                           (edit: append AccountLocked, TooManyRequests)
shomei-core/src/Shomei/Domain/Event.hs                    (edit: append AccountLocked, LoginThrottled events)
shomei-core/src/Shomei/Domain/LoginAttempt.hs             (new)
shomei-core/src/Shomei/Effect/LoginAttemptStore.hs          (new)
shomei-core/src/Shomei/Effect/InMemory.hs                   (edit: add LoginAttemptStore interpreter)
shomei-core/src/Shomei/Workflow.hs                        (edit: throttle + lockout in login)
shomei-core/shomei-core.cabal                             (edit: expose new modules; test deps)
shomei-core/test/Shomei/LockoutSpec.hs                    (new)
shomei-core/test/Main.hs                                  (edit: register LockoutSpec)
shomei-migrations/sql-migrations/2026-06-05-12-37-20-shomei-login-attempts.sql   (new)
shomei-migrations/sql-migrations/2026-06-05-12-37-21-shomei-account-lockouts.sql (new)
shomei-postgres/src/Shomei/Postgres/LoginAttemptStore.hs  (new)
shomei-postgres/src/Shomei/Postgres/Codec.hs              (edit: loginOutcome <-> text)
shomei-postgres/shomei-postgres.cabal                     (edit: expose new module)
shomei-postgres/test/Main.hs                              (edit: add login-attempt-store cases)
shomei-server/src/Shomei/Server/Middleware/RateLimit.hs   (new — M4, requires EP-6)
shomei-server/src/Shomei/Server/App.hs                    (edit — M4, requires EP-6: insert middleware)
shomei-server/shomei-server.cabal                         (edit — M4: deps stm, unordered-containers)
cabal.project                                                      (edit — M4 only if a lib is added; default: none)
```


## Plan of Work

The work is four milestones. M1 and M2 are self-contained on the already-built core and
postgres packages and deliver the security-critical lockout behavior with full test
coverage. M3 and M4 wire that behavior into the HTTP server and add the per-IP request
limiter; both require MasterPlan 1 EP-5/EP-6 to have produced a real `shomei-servant` API
and `shomei-server` `Application`.

### Milestone M1 — config policy, lockout effect, in-memory interpreter, pure tests

Scope: everything that lives in `shomei-core` and needs no database. At the end of M1, the
core knows the rate-limit/lockout *policy*, has a `LoginAttemptStore` effect with an in-memory
interpreter, and the `login` workflow locks an account after N failures and unlocks after
the cooldown — all proven by a green `cabal test shomei-core`.

What will exist that did not before: a `RateLimitConfig` sub-record on `ShomeiConfig`; a
`Shomei.Domain.LoginAttempt` module; a `Shomei.Effect.LoginAttemptStore` effect + its
in-memory interpreter; `AccountLocked`/`TooManyRequests` `AuthError`s and
`AccountLocked`/`LoginThrottled` `AuthEvent`s; an extended `login` workflow; and a
`LockoutSpec` test module.

Commands to run: `cabal build shomei-core` then `cabal test shomei-core`. Acceptance: the
new lockout test cases pass and the seven pre-existing workflow cases still pass.

### Milestone M2 — codd migration, PostgreSQL interpreter, integration tests

Scope: durability. Add the two migrations and the PostgreSQL interpreter for
`LoginAttemptStore`, mirroring the existing stores in `shomei-postgres`. At the end
of M2, the same lockout behavior is proven against a real, throwaway PostgreSQL database
(via the `shomei-migrations:test-support` ephemeral-database helper that EP-3 of MasterPlan 1
built).

Commands: `just migrate` (applies the new migrations to the dev DB; `\dt shomei.*` now also
lists `shomei_login_attempts` and `shomei_account_lockouts`), then `cabal test
shomei-postgres`. Acceptance: a new "login attempt store over PostgreSQL" group passes, and
a workflow-over-PostgreSQL test reproduces lock-after-N and unlock-after-cooldown against the
real database.

### Milestone M3 — wire lockout into the login handler / generic responses

Scope: connect the workflow to the HTTP boundary. **Requires MasterPlan 1 EP-5/EP-6.** The
login handler in `shomei-server` (the function that EP-6 writes to serve `POST /auth/login`)
must (a) construct a `ClientContext` from the request's client IP and pass it to the extended
`login`, (b) assemble the `LoginAttemptStore` interpreter into the effect stack alongside the
existing store interpreters, and (c) map `AuthError` to HTTP: `InvalidCredentials` **and**
`AccountLocked` → generic `401 {"error":"invalid_credentials"}`; `TooManyRequests` → `429
{"error":"too_many_requests"}`. At the end of M3, the live server locks accounts and the
429/401 distinction is correct and leak-free.

Commands: start the server (EP-6's `cabal run shomei-server`), then a `curl` walkthrough
(below). Acceptance: locked account returns the same `401` as a wrong password; a per-IP
failure flood returns `429`.

### Milestone M4 — per-IP WAI rate-limit middleware + ordering + end-to-end demo

Scope: the request-rate ceiling and the demonstrable end-to-end story. **Requires EP-6.** Add
`Shomei.Server.Middleware.RateLimit` (an in-process `stm` token bucket keyed by client IP),
insert it into the `shomei-server` `Application` *inside* EP-3's request-ID/logging
middleware (so even rejected requests are logged with a correlation ID) and *outside* the
Servant app, and record the final middleware order (IP-4). Then run the headline bash/`curl`
demonstration. Acceptance: the demonstration transcript below reproduces exactly.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

### Step 1 (M1) — append `RateLimitConfig` to `ShomeiConfig`

Edit `shomei-core/src/Shomei/Config.hs`. This is an **append-only** extension per
MasterPlan 2 IP-3, quoted here:

> **IP-3 — `ShomeiConfig` extension (shared, append-only).** … **each plan adds its own
> named sub-record field to `ShomeiConfig` (e.g. `notifierConfig`, `rateLimitConfig`,
> `observabilityConfig`) and extends `defaultShomeiConfig` with that field's defaults; no
> plan rewrites another's field.** Each new field must be `Maybe` or carry a default so older
> config files still parse.

Add a `RateLimitConfig` type and a `rateLimitConfig` field. Export `RateLimitConfig (..)` and
`defaultRateLimitConfig` from the module's export list:

```haskell
data RateLimitConfig = RateLimitConfig
    { maxFailedLoginsPerAccount :: !Int
    -- ^ failures within 'lockoutWindow' before the account is locked (default 5)
    , maxFailedLoginsPerIp :: !Int
    -- ^ failures within 'lockoutWindow' from one IP before that IP is throttled (default 20)
    , lockoutWindow :: !NominalDiffTime
    -- ^ rolling window over which failures are counted (default 15 min)
    , lockoutDuration :: !NominalDiffTime
    -- ^ how long an account stays locked once tripped (default 15 min)
    , perIpRequestsPerMinute :: !Int
    -- ^ WAI token-bucket sustained rate per client IP (default 60)
    , perIpBurst :: !Int
    -- ^ WAI token-bucket capacity / burst per client IP (default 60)
    , rateLimitEnabled :: !Bool
    -- ^ master switch; False disables all EP-2 protections (default True)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultRateLimitConfig :: RateLimitConfig
defaultRateLimitConfig =
    RateLimitConfig
        { maxFailedLoginsPerAccount = 5
        , maxFailedLoginsPerIp = 20
        , lockoutWindow = 15 * 60
        , lockoutDuration = 15 * 60
        , perIpRequestsPerMinute = 60
        , perIpBurst = 60
        , rateLimitEnabled = True
        }
```

Then add the field to `ShomeiConfig` and to `defaultShomeiConfig`. Because every existing
field is non-`Maybe`, add `rateLimitConfig :: !RateLimitConfig` (it carries a total default,
satisfying IP-3's "carry a default" requirement — older JSON omitting the key will fail to
parse with the derived `FromJSON`, so if backward-compatible parsing of pre-EP-2 config files
is required, EP-5's loader supplies the default; record that the in-core derived instance is
strict). Concretely, in the record:

```haskell
    , sessionCheckMode :: !SessionCheckMode
    , rateLimitConfig :: !RateLimitConfig
    }
```

and in `defaultShomeiConfig`, after `sessionCheckMode = VerifyTokenOnly`:

```haskell
        , sessionCheckMode = VerifyTokenOnly
        , rateLimitConfig = defaultRateLimitConfig
        }
```

Build to confirm: `cabal build shomei-core` (exit 0).

### Step 2 (M1) — `Shomei.Domain.LoginAttempt`

Create `shomei-core/src/Shomei/Domain/LoginAttempt.hs`. It defines the abuse-domain
types: the outcome of an attempt, an account-key newtype (the *hash* of the normalized email,
so plaintext never reaches the abuse store), a persisted attempt, an input record, and the
account-lockout record.

```haskell
{- | Domain types for brute-force protection: a log of login attempts (keyed by a hashed
account identifier and a client IP) and a per-account lockout record. The account key is a
hash, never the plaintext email, so the abuse store cannot become an enumeration oracle.
-}
module Shomei.Domain.LoginAttempt (
    LoginOutcome (..),
    AccountKey (..),
    ClientIp (..),
    LoginAttempt (..),
    NewLoginAttempt (..),
    AccountLockout (..),
) where

import Shomei.Prelude

-- | Whether an attempt succeeded or failed. (We log both; success clears the counter.)
data LoginOutcome = LoginSuccess | LoginFailure
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | A SHA-256 (hex) of the normalized email presented at login. Opaque key for counting.
newtype AccountKey = AccountKey Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

-- | The client's source IP as text (e.g. "203.0.113.7"). Source of the per-IP throttle.
newtype ClientIp = ClientIp Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

-- | A persisted login attempt (one row in @shomei_login_attempts@).
data LoginAttempt = LoginAttempt
    { accountKey :: !AccountKey
    , clientIp :: !ClientIp
    , outcome :: !LoginOutcome
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | Input for recording an attempt (identical fields; no server-assigned columns).
data NewLoginAttempt = NewLoginAttempt
    { accountKey :: !AccountKey
    , clientIp :: !ClientIp
    , outcome :: !LoginOutcome
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | The lockout state for one account key (one row in @shomei_account_lockouts@).
data AccountLockout = AccountLockout
    { accountKey :: !AccountKey
    , failedCount :: !Int
    , lockedUntil :: !(Maybe UTCTime)
    , updatedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

### Step 3 (M1) — `Shomei.Effect.LoginAttemptStore`

Create `shomei-core/src/Shomei/Effect/LoginAttemptStore.hs`, an `effectful` dynamic
effect mirroring the shape of `Shomei.Effect.SessionStore`. It records attempts, counts recent
failures per account and per IP within a window, and reads / writes / clears the per-account
lockout.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The login-attempt store effect: the durable state behind brute-force lockout and per-IP
login throttling. Counting is windowed (failures since a cutoff time); lockout is keyed by
the hashed account identifier.
-}
module Shomei.Effect.LoginAttemptStore (
    LoginAttemptStore (..),
    recordLoginAttempt,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    setAccountLockout,
    clearAccountLockout,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.LoginAttempt (AccountKey, AccountLockout, ClientIp, NewLoginAttempt)

data LoginAttemptStore :: Effect where
    -- | Append one attempt to the log.
    RecordLoginAttempt :: NewLoginAttempt -> LoginAttemptStore m ()
    -- | Count failures for an account since the given cutoff (window start).
    CountRecentFailuresByAccount :: AccountKey -> UTCTime -> LoginAttemptStore m Int
    -- | Count failures from an IP since the given cutoff (window start).
    CountRecentFailuresByIp :: ClientIp -> UTCTime -> LoginAttemptStore m Int
    -- | Read the current lockout record for an account (if any).
    GetAccountLockout :: AccountKey -> LoginAttemptStore m (Maybe AccountLockout)
    -- | Upsert the lockout record (set failedCount / lockedUntil / updatedAt).
    SetAccountLockout :: AccountLockout -> LoginAttemptStore m ()
    -- | Clear the lockout record for an account (on successful login).
    ClearAccountLockout :: AccountKey -> LoginAttemptStore m ()

type instance DispatchOf LoginAttemptStore = Dynamic

recordLoginAttempt :: (LoginAttemptStore :> es) => NewLoginAttempt -> Eff es ()
recordLoginAttempt = send . RecordLoginAttempt

countRecentFailuresByAccount :: (LoginAttemptStore :> es) => AccountKey -> UTCTime -> Eff es Int
countRecentFailuresByAccount k t = send (CountRecentFailuresByAccount k t)

countRecentFailuresByIp :: (LoginAttemptStore :> es) => ClientIp -> UTCTime -> Eff es Int
countRecentFailuresByIp ip t = send (CountRecentFailuresByIp ip t)

getAccountLockout :: (LoginAttemptStore :> es) => AccountKey -> Eff es (Maybe AccountLockout)
getAccountLockout = send . GetAccountLockout

setAccountLockout :: (LoginAttemptStore :> es) => AccountLockout -> Eff es ()
setAccountLockout = send . SetAccountLockout

clearAccountLockout :: (LoginAttemptStore :> es) => AccountKey -> Eff es ()
clearAccountLockout = send . ClearAccountLockout
```

### Step 4 (M1) — in-memory interpreter

Edit `shomei-core/src/Shomei/Effect/InMemory.hs`. The reference interpreter is the
behavioral contract the PostgreSQL interpreter must match. Add two fields to `World`, a
`runLoginAttemptStore` interpreter, and stack it in `runInMemory`.

Add to the `World` record (after `tokenCounter`):

```haskell
    , loginAttempts :: ![LoginAttempt]
    -- ^ newest-first append-only attempt log
    , accountLockouts :: !(Map AccountKey AccountLockout)
```

Add their empty values in `emptyWorld` (`loginAttempts = []`, `accountLockouts = Map.empty`).
Import the new domain names with `(..)`:

```haskell
import Shomei.Domain.LoginAttempt (
    AccountKey,
    AccountLockout (..),
    LoginAttempt (..),
    LoginOutcome (..),
    NewLoginAttempt (..),
 )
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore (..))
```

Add the interpreter. Counting is "failures with `occurredAt >= cutoff`":

```haskell
runLoginAttemptStore :: (IOE :> es) => IORef World -> Eff (LoginAttemptStore : es) a -> Eff es a
runLoginAttemptStore ref = interpret_ \case
    RecordLoginAttempt na ->
        liftIO (modifyIORef' ref (#loginAttempts %~ (toAttempt na :)))
    CountRecentFailuresByAccount k cutoff ->
        liftIO (countWith (\a -> a.accountKey == k) cutoff <$> readIORef ref)
    CountRecentFailuresByIp ip cutoff ->
        liftIO (countWith (\a -> a.clientIp == ip) cutoff <$> readIORef ref)
    GetAccountLockout k ->
        liftIO ((Map.lookup k . (.accountLockouts)) <$> readIORef ref)
    SetAccountLockout lo ->
        liftIO (modifyIORef' ref (#accountLockouts %~ Map.insert lo.accountKey lo))
    ClearAccountLockout k ->
        liftIO (modifyIORef' ref (#accountLockouts %~ Map.delete k))
  where
    toAttempt na =
        LoginAttempt
            { accountKey = na.accountKey
            , clientIp = na.clientIp
            , outcome = na.outcome
            , occurredAt = na.occurredAt
            }
    countWith p cutoff w =
        length
            [ a | a <- w.loginAttempts, p a, a.outcome == LoginFailure, a.occurredAt >= cutoff
            ]
```

Add `LoginAttemptStore` to the `runInMemory` effect-list type and compose
`. runLoginAttemptStore ref` into the interpreter pipeline (place it adjacent to the other
store interpreters; order among independent store interpreters is irrelevant). Update the
exported `Eff [ … ]` list type accordingly.

### Step 5 (M1) — new `AuthError` and `AuthEvent` variants

Edit `shomei-core/src/Shomei/Error.hs`: append two constructors to `AuthError`
(append-only; existing variants and their order are unchanged):

```haskell
    | TokenInvalid TokenError
    | AccountLocked
    -- ^ INTERNAL audit signal; the HTTP layer maps it to the SAME generic 401 as
    --   InvalidCredentials so a locked account is indistinguishable from a wrong password.
    | TooManyRequests
    -- ^ per-IP failure throttle tripped; the HTTP layer maps it to 429.
    | InternalAuthError Text
```

Edit `shomei-core/src/Shomei/Domain/Event.hs`: add two `*Data` records and two
`AuthEvent` constructors (append-only). Export the new `*Data` types in the module header.

```haskell
data AccountLockedData = AccountLockedData
    { accountKey :: !AccountKey
    , clientIp :: !ClientIp
    , failedCount :: !Int
    , lockedUntil :: !UTCTime
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data LoginThrottledData = LoginThrottledData
    { clientIp :: !ClientIp
    , failedCount :: !Int
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

and in the `AuthEvent` sum:

```haskell
    | AccountLocked AccountLockedData
    | LoginThrottled LoginThrottledData
```

This requires importing `AccountKey`/`ClientIp` from `Shomei.Domain.LoginAttempt`. Add the
matching projection arms to `Shomei.Postgres.AuthEventPublisher.projectAuthEvent` in M2 (the
PostgreSQL event table already stores `(user_id?, session_id?, event_type, payload,
occurredAt)`; these two events carry no user/session id, so both ids are `Nothing` and the
hashed account / IP live inside the JSON payload).

### Step 6 (M1) — extend the `login` workflow

Edit `shomei-core/src/Shomei/Workflow.hs`. The goal: before verifying the password,
check the account-lockout state and the per-IP failure budget; after a failure, record it and
lock the account if the per-account budget is exhausted; on success, clear the lockout. The
client IP and the hashing of the email are inputs the workflow does not compute itself — they
arrive in a small `ClientContext` value the caller (handler/tests) supplies, and the email is
hashed by the caller into an `AccountKey` so the core never needs a crypto dependency.

Add a `ClientContext` to `Shomei.Domain.Command` (or a new `Shomei.Domain.ClientContext`
module; default: extend `Command`) carrying the request's `ClientIp` and the precomputed
`AccountKey` for the presented email:

```haskell
data ClientContext = ClientContext
    { clientIp :: !ClientIp
    , accountKey :: !AccountKey
    }
    deriving stock (Generic, Show)
```

Change `login`'s signature to take the context and add `LoginAttemptStore :> es`:

```haskell
login ::
    ( UserStore :> es
    , CredentialStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasswordHasher :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , LoginAttemptStore :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    ClientContext ->
    LoginCommand ->
    Eff es (Either AuthError (User, TokenPair))
```

The new control flow (prose, so the implementer understands the *why*; the exact code follows
the existing `runErrorNoCallStack do` style):

1. `ts <- now`. Compute `cutoff = addUTCTime (negate cfg.rateLimitConfig.lockoutWindow) ts`.
2. **Per-IP throttle, first** (cheapest, account-agnostic, leaks nothing): `ipFails <-
   countRecentFailuresByIp ctx.clientIp cutoff`. If `ipFails >= cfg.rateLimitConfig.maxFailedLoginsPerIp`,
   publish `Event.LoginThrottled` and `throwError TooManyRequests`. (Do **not** record this
   as a new failed attempt — that would let an attacker inflate their own counter to keep
   themselves throttled forever; throttling is a read-only gate.)
3. **Account lockout check:** `mLock <- getAccountLockout ctx.accountKey`. If `mLock` has a
   `lockedUntil` that is `> ts` (still locked), publish nothing new (or an audit
   `AccountLocked` re-touch is unnecessary) and `throwError AccountLocked`. The handler maps
   `AccountLocked` to the generic `401`, so this is leak-free.
4. Proceed with the existing credential/user lookup. **On any `InvalidCredentials` failure
   path** (unknown email, missing user, or wrong password), first record the failure and
   possibly lock, then throw. Factor a helper `failLogin ctx ts cfg` that:
   - records `NewLoginAttempt { accountKey = ctx.accountKey, clientIp = ctx.clientIp, outcome
     = LoginFailure, occurredAt = ts }` via `recordLoginAttempt`;
   - publishes the existing `Event.LoginFailed`;
   - `acctFails <- countRecentFailuresByAccount ctx.accountKey cutoff` (this now includes the
     just-recorded failure);
   - if `acctFails >= cfg.rateLimitConfig.maxFailedLoginsPerAccount`, compute `lockedUntil =
     addUTCTime cfg.rateLimitConfig.lockoutDuration ts`, `setAccountLockout (AccountLockout
     ctx.accountKey acctFails (Just lockedUntil) ts)`, publish `Event.AccountLocked`, and
     (optional, EP-1 soft dep) send a `Notifier` notification (gated `TODO(EP-1)`);
   - `throwError InvalidCredentials`.
   To keep the no-leak guarantee, **both** the unknown-account branch and the wrong-password
   branch call `failLogin` and throw `InvalidCredentials` — they must remain byte-for-byte
   identical at the boundary.
5. **On success** (`ok == True`): record `NewLoginAttempt { … outcome = LoginSuccess … }`,
   `clearAccountLockout ctx.accountKey`, then proceed exactly as today (create session, mint
   tokens, publish `LoginSucceeded` + `SessionStarted`).

> **Reset semantics (spelled out, per scope item 7).** A successful login **clears** the
> lockout row (`clearAccountLockout`), zeroing the account's progress. Independently, lockout
> is *time-bounded*: once `lockedUntil <= now`, step 3 no longer throws, so the account is
> usable again even without an explicit clear (a stale lockout row with an elapsed
> `lockedUntil` is harmless and is overwritten on the next failure or removed on the next
> success). The windowed **failure count** also naturally decays: `countRecentFailures*`
> only counts attempts with `occurredAt >= cutoff`, so failures older than `lockoutWindow`
> stop contributing. There is no background job; expiry is purely read-time comparison.

Note that `signup`/`refresh`/`logout`/`verifyToken` are unchanged. Any caller of `login` in
existing tests must be updated to pass a `ClientContext` (the EP-2 reference workflow tests
in `WorkflowSpec.hs` were written for the old 2-argument `login`; update them to pass a
fixed test context, e.g. `ClientContext (ClientIp "test-ip") (AccountKey "test-key")`, and
add a `LoginAttemptStore` to their interpreter stack — which `runInMemory` now provides).

### Step 7 (M1) — cabal wiring and the pure test

Edit `shomei-core/shomei-core.cabal`: add to `exposed-modules`:

```cabal
    Shomei.Domain.LoginAttempt
    Shomei.Effect.LoginAttemptStore
```

The library's existing `build-depends` already cover everything the new modules use (`text`,
`containers`, `time`, `effectful`, `generic-lens`). No new library dependency is needed in
`shomei-core`.

Add the test module `other-modules: Shomei.LockoutSpec` to the `test-suite shomei-core-test`
stanza. Create `shomei-core/test/Shomei/LockoutSpec.hs` with tasty-hunit cases that
drive the extended `login` through `runInMemory`. Register `Shomei.LockoutSpec.tests` in
`shomei-core/test/Main.hs`'s `testGroup`.

The cases (each provisions a fresh `IORef (emptyWorld t0)` and seeds one user + credential
via `signup`, then exercises `login`):

```text
account locks after N failed logins:
  - run (maxFailedLoginsPerAccount) bad-password logins; the Nth (and N+1th) return Left.
  - assert getAccountLockout returns a Just with lockedUntil > t0.
locked account returns the SAME generic error as a wrong password:
  - assert the locked-account Left equals InvalidCredentials (NOT AccountLocked) at the
    workflow boundary — i.e. login never surfaces AccountLocked to its own Either result
    EXCEPT via the internal throw that the handler maps; in the workflow we choose to return
    Left InvalidCredentials for the locked case too, so this assertion is `== Left
    InvalidCredentials`. (See Decision Log: AccountLocked is mapped to the same 401; the
    workflow returns InvalidCredentials so even a direct core caller cannot distinguish.)
unknown email and wrong password are indistinguishable AND both count toward lockout:
  - N bad logins against an email with no account still lock that key; both branches return
    Left InvalidCredentials.
account unlocks after the cooldown elapses:
  - lock the account; advance the in-memory clock (#clock .~ t0 + lockoutDuration + 1s) so
    `now` returns a post-cooldown time; a correct-password login now succeeds (Right) and
    the lockout row is cleared.
successful login clears the failure counter:
  - make (N-1) bad logins (one short of lock); a correct login succeeds and
    getAccountLockout returns Nothing afterward; a subsequent single bad login does NOT lock.
per-IP failure throttle trips at maxFailedLoginsPerIp across DIFFERENT accounts:
  - from one ClientIp, fail logins against maxFailedLoginsPerIp distinct emails; the next
    login from that IP returns Left TooManyRequests, while the SAME attempt from a different
    Ip returns the ordinary Left InvalidCredentials.
```

> Implementation note: to "advance the clock", reuse the in-memory `World.clock` field —
> `Now` reads it. Write the new time into the `IORef` between workflow calls
> (`modifyIORef' ref (#clock .~ later)`), exactly as the lockout test needs. To distinguish
> the locked case at the test level, inspect the `World.accountLockouts` map and the returned
> `Either`, not a special error.

Acceptance for M1: `cabal build shomei-core` exits 0, then:

```bash
cabal test shomei-core
```

Expected tasty transcript (abridged; the seven pre-existing cases plus the new group):

```text
shomei-core-test
  Shomei.Workflow
    signup then login round-trips:                              OK
    … (the other six pre-existing cases) …                      OK
  Shomei.Lockout
    account locks after N failed logins:                        OK
    locked account returns the same generic error:              OK
    unknown email and wrong password indistinguishable:         OK
    account unlocks after the cooldown elapses:                 OK
    successful login clears the failure counter:                OK
    per-IP failure throttle trips across different accounts:    OK

All 13 tests passed (0.00s)
```

### Step 8 (M2) — the codd migrations

Create the two SQL files under `shomei-migrations/sql-migrations/`. The timestamps
are **later than every existing `2026-06-03-*` file and later than EP-1's `2026-06-04-*`
window** (IP-7; see Decision Log). Each file begins with the codd directive `-- codd: in-txn`
(run inside a transaction), then pins the search path, then idempotent DDL — exactly like the
existing migrations (see `2026-06-03-18-44-57-shomei-auth-events.sql`). Identifier/hash keys
are `text` (the account key is a hash, not a TypeID UUID), counts are `int`, timestamps are
`timestamptz`.

`2026-06-05-12-37-20-shomei-login-attempts.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_login_attempts (
  attempt_id  uuid PRIMARY KEY,
  account_key text NOT NULL,
  client_ip   text NOT NULL,
  outcome     text NOT NULL,
  occurred_at timestamptz NOT NULL
);

-- Windowed counting reads "failures since cutoff" by account and by IP, so index both
-- (key, occurred_at) pairs; partial on failures keeps the index small and hot.
CREATE INDEX IF NOT EXISTS shomei_login_attempts_account_failures_idx
  ON shomei_login_attempts (account_key, occurred_at)
  WHERE outcome = 'failure';

CREATE INDEX IF NOT EXISTS shomei_login_attempts_ip_failures_idx
  ON shomei_login_attempts (client_ip, occurred_at)
  WHERE outcome = 'failure';
```

`2026-06-05-12-37-21-shomei-account-lockouts.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_account_lockouts (
  account_key  text PRIMARY KEY,
  failed_count int NOT NULL,
  locked_until timestamptz NULL,
  updated_at   timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_account_lockouts_locked_until_idx
  ON shomei_account_lockouts (locked_until);
```

Apply them to the dev DB (the recipe `touch`es the migrations `.cabal` so `embedDir`
re-embeds the new files — see EP-3 of MasterPlan 1):

```bash
just migrate
```

Confirm the tables exist:

```bash
psql -c '\dt shomei.*'
```

Expected (abridged): the listing now includes `shomei_login_attempts` and
`shomei_account_lockouts` alongside the six pre-existing tables.

### Step 9 (M2) — the PostgreSQL interpreter

Add `loginOutcome` codecs to `shomei-postgres/src/Shomei/Postgres/Codec.hs`:

```haskell
loginOutcomeToText :: LoginOutcome -> Text
loginOutcomeToText = \case
    LoginSuccess -> "success"
    LoginFailure -> "failure"

loginOutcomeFromText :: Text -> Either Text LoginOutcome
loginOutcomeFromText = \case
    "success" -> Right LoginSuccess
    "failure" -> Right LoginFailure
    t -> Left ("unknown login outcome: " <> t)
```

Create `shomei-postgres/src/Shomei/Postgres/LoginAttemptStore.hs`, mirroring
`Shomei.Postgres.SessionStore` (same `Database`/`Error AuthError`/`IOE` constraints, the same
`runSession`/`dbFail` pattern, hasql `preparable` statements, and the
`contravariant-extras` `contrazipN` encoders). Sketch of the interpreter and the statements:

```haskell
runLoginAttemptStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (LoginAttemptStore : es) a ->
    Eff es a
runLoginAttemptStorePostgres = interpret_ \case
    RecordLoginAttempt na -> do
        aid <- liftIO UUIDv4.nextRandom
        let AccountKey k = na.accountKey
            ClientIp ip = na.clientIp
            row = (aid, k, ip, loginOutcomeToText na.outcome, na.occurredAt)
        res <- runSession (Session.statement row insertAttemptStmt)
        either dbFail (const (pure ())) res
    CountRecentFailuresByAccount (AccountKey k) cutoff -> do
        res <- runSession (Session.statement (k, cutoff) countByAccountStmt)
        either dbFail (pure . fromIntegral) res
    CountRecentFailuresByIp (ClientIp ip) cutoff -> do
        res <- runSession (Session.statement (ip, cutoff) countByIpStmt)
        either dbFail (pure . fromIntegral) res
    GetAccountLockout k@(AccountKey kt) -> do
        res <- runSession (Session.statement kt findLockoutStmt)
        row <- either dbFail pure res
        pure (fmap (rebuildLockout k) row)
    SetAccountLockout lo -> do
        let AccountKey k = lo.accountKey
            row = (k, fromIntegral lo.failedCount, lo.lockedUntil, lo.updatedAt)
        res <- runSession (Session.statement row upsertLockoutStmt)
        either dbFail (const (pure ())) res
    ClearAccountLockout (AccountKey k) -> do
        res <- runSession (Session.statement k deleteLockoutStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
```

The statements (note `count(*)` decodes as `int8` → `D.int8`, then `fromIntegral`; the upsert
uses `ON CONFLICT (account_key) DO UPDATE`):

```sql
-- insertAttemptStmt
INSERT INTO shomei.shomei_login_attempts
  (attempt_id, account_key, client_ip, outcome, occurred_at)
VALUES ($1, $2, $3, $4, $5)

-- countByAccountStmt
SELECT count(*) FROM shomei.shomei_login_attempts
WHERE account_key = $1 AND outcome = 'failure' AND occurred_at >= $2

-- countByIpStmt
SELECT count(*) FROM shomei.shomei_login_attempts
WHERE client_ip = $1 AND outcome = 'failure' AND occurred_at >= $2

-- findLockoutStmt
SELECT failed_count, locked_until, updated_at
FROM shomei.shomei_account_lockouts WHERE account_key = $1

-- upsertLockoutStmt
INSERT INTO shomei.shomei_account_lockouts
  (account_key, failed_count, locked_until, updated_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (account_key) DO UPDATE
  SET failed_count = EXCLUDED.failed_count,
      locked_until = EXCLUDED.locked_until,
      updated_at = EXCLUDED.updated_at

-- deleteLockoutStmt
DELETE FROM shomei.shomei_account_lockouts WHERE account_key = $1
```

Add the new projection arms for `AccountLocked`/`LoginThrottled` to
`Shomei.Postgres.AuthEventPublisher.projectAuthEvent` (both with `Nothing` user/session ids;
the hashed account and IP live in the JSON payload), e.g.:

```haskell
    Event.AccountLocked d@(Event.AccountLockedData _ _ _ _ occ) ->
        (Nothing, Nothing, "account_locked", toJSON d, occ)
    Event.LoginThrottled d@(Event.LoginThrottledData _ _ occ) ->
        (Nothing, Nothing, "login_throttled", toJSON d, occ)
```

Expose `Shomei.Postgres.LoginAttemptStore` in `shomei-postgres/shomei-postgres.cabal`
(`exposed-modules`). The library already depends on `hasql`, `contravariant-extras`, `uuid`,
`effectful`, and `shomei-core`; no new dependency is needed. Build: `cabal build
shomei-postgres` (exit 0).

### Step 10 (M2) — integration tests over ephemeral PostgreSQL

Edit `shomei-postgres/test/Main.hs` (the existing tasty suite that uses
`withShomeiMigratedDatabase` from `shomei-migrations:test-support` to provision a fresh
throwaway PostgreSQL per test, acquires a `hasql` pool against its connection string, and runs
the interpreters). Add a "login attempt store over PostgreSQL" group that mirrors the M1 pure
cases but against the real database:

```text
record + count windowed failures by account and by IP:
  - record several failures; assert countRecentFailuresByAccount/ByIp return the expected
    counts for a recent cutoff and 0 for a cutoff in the future.
upsert + read + clear an account lockout:
  - setAccountLockout then getAccountLockout returns the same record; clearAccountLockout
    then getAccountLockout returns Nothing.
workflow over PostgreSQL: lock-after-N then unlock-after-cooldown:
  - assemble the full interpreter stack (the existing store interpreters +
    runLoginAttemptStorePostgres + a stub TokenSigner as in the existing workflow tests),
    seed a user via signup, fire N bad logins (each with a fixed ClientContext), assert the
    Nth returns Left and shomei_account_lockouts has a row with locked_until set; then call
    login with a ClientContext whose `now` (via a Clock that returns a post-cooldown time)
    is past locked_until and a correct password — assert Right and the lockout row is gone.
```

Acceptance for M2:

```bash
cabal test shomei-postgres
```

Expected: the pre-existing nine cases plus the new login-attempt group all pass; the
transcript shows the lock-after-N / unlock-after-cooldown scenario passing against PostgreSQL.

### Step 11 (M3) — wire lockout into the login handler (requires EP-6)

**Precondition:** MasterPlan 1 EP-5/EP-6 have produced a real `shomei-servant` API and a
`shomei-server` login handler. If `shomei-server/src/Shomei/Server/App.hs` (or
whatever module EP-6 names as the WAI assembly) and the login handler do not yet exist, stop
and record in Progress that M3 is blocked on EP-6.

Once they exist, edit the login handler EP-6 wrote (the function serving `POST /auth/login`)
to:

1. Derive a `ClientContext` from the incoming request: take the client IP (see M4 for how to
   extract it correctly behind a proxy), and compute `accountKey = AccountKey
   (sha256Hex (emailText normalizedEmail))`. The SHA-256 helper lives in
   `Shomei.Crypto` (the `shomei-postgres` crypto module, which already depends on `crypton`);
   if the handler cannot import `shomei-postgres`, add a tiny `sha256Hex :: Text -> Text` to
   `Shomei.Crypto` and re-export it, or compute the hash in the server's own crypto helper.
   The key must be derived from the **normalized** email (run it through `mkEmail` first) so
   the same address always maps to the same key.
2. Call the extended `login cfg ctx cmd` (Step 6) instead of the old `login cfg cmd`.
3. Assemble `runLoginAttemptStorePostgres` into the effect stack alongside the existing
   store interpreters (the same place EP-6 stacks `runUserStorePostgres` etc.).
4. Map the `AuthError` result to HTTP. The mapping must be **leak-free**:

```text
InvalidCredentials  -> 401  {"error":"invalid_credentials"}
AccountLocked       -> 401  {"error":"invalid_credentials"}   (SAME bytes as above)
TooManyRequests     -> 429  {"error":"too_many_requests"}
UserNotActive       -> 401  {"error":"invalid_credentials"}   (existing behavior; do not leak)
…                   -> (existing mappings)
```

Acceptance for M3 (`curl` against the running server; the email below has 5 failed attempts
configured as the lock threshold):

```bash
# 5 wrong-password attempts: each returns 401 invalid_credentials
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST http://localhost:8080/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"email":"victim@example.com","password":"wrong"}'
done
# 6th attempt — now LOCKED — still returns the SAME generic 401, not a distinct status/body:
curl -s -w "\n%{http_code}\n" \
  -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"victim@example.com","password":"wrong"}'
# Even the CORRECT password is refused while locked, with the identical 401:
curl -s -w "\n%{http_code}\n" \
  -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"victim@example.com","password":"correct-horse"}'
```

Expected: the first five print `401`; the sixth prints `{"error":"invalid_credentials"}` then
`401`; the correct-password-while-locked call prints the **same** body and `401` (proving no
leak). After `lockoutDuration` elapses, the correct password returns `200` with a token pair.

### Step 12 (M4) — per-IP WAI token-bucket middleware + ordering + demo (requires EP-6)

Create `shomei-server/src/Shomei/Server/Middleware/RateLimit.hs`: an in-process
`stm` token bucket keyed by client IP, exposed as a WAI `Middleware`. It uses only `stm`,
`unordered-containers`, `wai`, `http-types`, and `time` (all in the GHC 9.12 set; **no new
`cabal.project` source-repository-package is required** — see Decision Log and IP-8). Shape:

```haskell
module Shomei.Server.Middleware.RateLimit (
    RateLimiter,
    newRateLimiter,
    rateLimitMiddleware,
) where

import Shomei.Prelude

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.ByteString (ByteString)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HM
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (status429)
import Network.Wai (Middleware, Request, Response, remoteHost, responseLBS)
import Network.Socket (SockAddr (..))

-- One bucket per client IP: current token level + last-refill time (POSIX seconds).
data Bucket = Bucket { tokens :: !Double, lastRefill :: !Double }

data RateLimiter = RateLimiter
    { buckets :: !(TVar (HashMap ByteString Bucket))
    , capacity :: !Double       -- perIpBurst
    , refillPerSec :: !Double    -- perIpRequestsPerMinute / 60
    }

newRateLimiter :: Int -> Int -> IO RateLimiter
newRateLimiter perMinute burst = do
    tv <- newTVarIO HM.empty
    pure RateLimiter
        { buckets = tv
        , capacity = fromIntegral burst
        , refillPerSec = fromIntegral perMinute / 60
        }

-- Try to take one token for `key` at time `nowSecs`; True = allowed, False = rejected.
takeToken :: RateLimiter -> ByteString -> Double -> IO Bool
takeToken rl key nowSecs = atomically do
    m <- readTVar (rl.buckets)
    let Bucket lvl t0 = HM.lookupDefault (Bucket (rl.capacity) nowSecs) key m
        refilled = min (rl.capacity) (lvl + (nowSecs - t0) * rl.refillPerSec)
    if refilled >= 1
        then do
            writeTVar (rl.buckets) (HM.insert key (Bucket (refilled - 1) nowSecs) m)
            pure True
        else do
            writeTVar (rl.buckets) (HM.insert key (Bucket refilled nowSecs) m)
            pure False

rateLimitMiddleware :: RateLimiter -> Middleware
rateLimitMiddleware rl app req respond = do
    nowSecs <- realToFrac <$> getPOSIXTime
    allowed <- takeToken rl (clientKey req) nowSecs
    if allowed then app req respond else respond tooMany
  where
    tooMany = responseLBS status429
        [("Content-Type", "application/json")]
        "{\"error\":\"too_many_requests\"}"

-- Extract the client IP key. WARNING: behind a reverse proxy, `remoteHost` is the proxy.
-- If EP-6/EP-5 establishes a trusted X-Forwarded-For policy, read the left-most trusted
-- entry instead; default (no proxy) uses the socket peer.
clientKey :: Request -> ByteString
clientKey req = case remoteHost req of
    SockAddrInet _ ha   -> packIPv4 ha
    SockAddrInet6 _ _ a _ -> packIPv6 a
    other               -> encodeUtf8 (tshow other)
```

> The `packIPv4`/`packIPv6`/`tshow` helpers are tiny; implement them with `Data.IP` or by
> `show`ing the address — exactness of the textual form does not matter, only that the same
> peer maps to the same stable key. **Scope it to unauthenticated endpoints**: either mount
> the middleware only on the `/auth/*` and password-reset/verify request paths (inspect
> `Network.Wai.pathInfo` and pass other paths straight to `app`), or apply it to the whole
> app — default: limit to the unauthenticated POST endpoints so authenticated traffic
> bearing a valid token is not throttled. Use `cfg.rateLimitConfig.rateLimitEnabled` to make
> the whole middleware a no-op when disabled.

**Middleware ordering (IP-4), quoted from MasterPlan 2:**

> **IP-4 — WAI middleware stack in `shomei-server`.** … Rule: document and agree the
> **ordering** — the outermost layer must be EP-3's request-ID + logging middleware (so every
> request, including those EP-2 rejects with HTTP 429, is logged with a correlation ID), then
> EP-2's rate limiter, then the Servant application. The plan that lands second must insert
> its middleware into the existing stack without removing the other's; record the final order
> in this section as each lands.

Therefore, in `shomei-server/src/Shomei/Server/App.hs`, the assembled application
must read (outermost first):

```text
requestIdAndLoggingMiddleware   -- EP-3 (observability), OUTERMOST; may not exist yet
  └─ rateLimitMiddleware rl      -- EP-2 (this plan)
       └─ metricsMiddleware?     -- EP-3 may place /metrics here; coordinate, do not remove
            └─ servantApp        -- the Servant ShomeiAPI Application
```

Because EP-2 and EP-3 run in **parallel**, write the insertion so it works whether EP-3 has
landed or not:

- **If EP-3 has landed** (a request-ID/logging `Middleware` already wraps the app in
  `App.hs`), insert `rateLimitMiddleware rl` **immediately inside** it — i.e. change
  `loggingMw (servantApp …)` to `loggingMw (rateLimitMiddleware rl (servantApp …))`. Do
  **not** remove or reorder `loggingMw`.
- **If EP-3 has not landed** (no logging middleware yet), wrap the Servant app directly:
  `rateLimitMiddleware rl (servantApp …)`, and leave a comment
  `-- EP-3 (observability) must wrap THIS expression from the outside (IP-4).` so EP-3 inserts
  its middleware around, not inside, the rate limiter.

Record the realized order in this section once both have landed (update the diagram above to
reflect the actual `App.hs`).

Add `stm` and `unordered-containers` to `shomei-server/shomei-server.cabal`'s
`build-depends`. Verify they build on GHC 9.12.4 (they are in the snapshot; no `allow-newer`
or `source-repository-package` is needed — so **no `cabal.project` block is appended** for
EP-2, consistent with IP-8's "or none, if implemented in-process").

**End-to-end demonstration (the headline acceptance):**

```bash
# (A) Per-IP REQUEST rate limit: with perIpRequestsPerMinute=60/burst=60, a 70-request
#     burst from one IP shows the tail rejected with 429 BEFORE reaching Servant.
echo "== request-rate burst =="
for i in $(seq 1 70); do
  curl -s -o /dev/null -w "%{http_code} " \
    -X POST http://localhost:8080/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"email":"a@example.com","password":"x"}'
done; echo

# (B) Per-account brute-force lockout: 6 bad-password logins; the 6th is locked but returns
#     the SAME generic 401 as a wrong password.
echo "== account lockout =="
for i in $(seq 1 6); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST http://localhost:8080/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"email":"victim@example.com","password":"wrong"}'
done
```

Expected transcript shape:

```text
== request-rate burst ==
200 200 200 … 200 429 429 429 …      (first ~60 pass the limiter, the rest are 429)
== account lockout ==
401
401
401
401
401
401                                   (the 6th is LOCKED, still a generic 401)
```

(Section (A)'s `200`s assume the credentials reach Servant and return its normal login
failure status; the point of (A) is the transition to `429` once the bucket empties, proving
the limiter rejects before Servant. If EP-6 returns `401` for those failures, the pre-limit
codes will be `401` and the post-limit codes `429` — the observable is the switch to `429`.)


## Validation and Acceptance

Validation is behavioral, not "it compiles". The acceptance criteria, each with concrete
input and observable output:

1. **Lock-after-N (pure, M1).** With `maxFailedLoginsPerAccount = 5`, five wrong-password
   `login` calls against one seeded account leave `World.accountLockouts` holding a record
   with `lockedUntil = Just (t0 + 15min)`; the 5th and 6th calls return `Left
   InvalidCredentials`. Command: `cabal test shomei-core`.

2. **No leak (pure, M1).** The locked-account `login` and the unknown-email `login` both
   return *exactly* `Left InvalidCredentials` (identical constructor) — never `Left
   AccountLocked`. A direct core caller cannot distinguish wrong-password, no-account, and
   locked.

3. **Unlock-after-cooldown (pure, M1).** After locking, advancing the in-memory clock past
   `lockedUntil` and presenting the correct password returns `Right (user, pair)` and clears
   the lockout row.

4. **Counter reset on success (pure, M1).** Four failures (one short of the lock threshold)
   followed by a correct login succeed and clear the counter; a single later failure does not
   lock.

5. **Per-IP failure throttle (pure, M1).** Twenty failures from one `ClientIp` spread across
   distinct emails cause the next attempt from that IP to return `Left TooManyRequests`, while
   the same attempt from a different IP returns the ordinary `Left InvalidCredentials`.

6. **Same behaviors over PostgreSQL (M2).** `cabal test shomei-postgres` reproduces 1–4
   against a throwaway PostgreSQL database, and `psql -c '\dt shomei.*'` lists
   `shomei_login_attempts` and `shomei_account_lockouts`.

7. **Generic HTTP responses (M3).** Against the live server, a locked account and a
   wrong-password attempt return byte-identical `401 {"error":"invalid_credentials"}`; a
   per-IP failure flood returns `429 {"error":"too_many_requests"}`.

8. **Per-IP request rate limit (M4).** A burst exceeding `perIpBurst` from one IP transitions
   to `429` before reaching Servant; the demonstration transcript above reproduces.

9. **Middleware ordering (M4).** Even a `429`-rejected request is logged with a correlation
   ID (once EP-3 has landed), proving EP-3's logging middleware is outermost.


## Idempotence and Recovery

All M1 source edits are idempotent: re-applying them overwrites the same files with the same
content; `cabal build`/`cabal test` only recompile what changed (recover a stale cache with
`cabal clean && cabal build shomei-core`). The config, error, and event edits are purely
additive (new field, new constructors), so re-running them is safe and never removes existing
variants.

The migrations are **append-only and immutable** (IP-7): once `just migrate` has applied
`2026-06-05-12-37-20-…` and `…-01-…`, codd records them and never re-runs them; re-running
`just migrate` is a no-op for already-applied files. The DDL itself is idempotent
(`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`), so even a manual re-apply
against a partially-migrated database is safe. **Never edit an applied migration** — to change
the schema, add a *new* migration with a later timestamp. If a migration fails midway, it runs
in a transaction (`-- codd: in-txn`), so it rolls back atomically; fix the SQL and re-run
`just migrate`. The integration tests provision a **fresh throwaway** PostgreSQL per test
(`withShomeiMigratedDatabase`), so there is no shared state to clean up between runs and a
failed test leaves the dev database untouched.

The in-process rate limiter (M4) holds state only in memory; restarting the server resets the
request buckets (acceptable — the *security-critical* lockout is PostgreSQL-backed and
survives restarts). If a config change is needed, edit `RateLimitConfig` (or, post-EP-5, the
Dhall/env config) and restart; no migration or data change is involved. To disable all EP-2
protections in an emergency, set `rateLimitEnabled = False` (the middleware becomes a no-op
and the workflow skips the throttle/lockout gates) and restart.


## Interfaces and Dependencies

Libraries used and why. **`shomei-core` (M1):** no new dependency — the new modules use only
already-present `text`, `containers`, `time`, `effectful`, `generic-lens`. **`shomei-postgres`
(M2):** no new dependency — the interpreter reuses `hasql`, `contravariant-extras`, `uuid`,
`effectful`, `shomei-core`, and (for `RecordLoginAttempt`'s id) `uuid`'s `Data.UUID.V4`,
exactly as the existing stores do. **`shomei-server` (M4):** add `stm` and
`unordered-containers` (both in the GHC 9.12 snapshot; no `allow-newer`, no
`source-repository-package`, no `mori.dhall` change), plus the already-present `wai`,
`http-types`, `time`. Forbidden everywhere: the deprecated `memory` package (use `ram`); EP-2
introduces nothing that pulls it.

The signatures that must exist at the end of each milestone (full module paths):

End of **M1** (`shomei-core`):

```haskell
-- Shomei.Config
data RateLimitConfig = RateLimitConfig
  { maxFailedLoginsPerAccount :: !Int, maxFailedLoginsPerIp :: !Int
  , lockoutWindow :: !NominalDiffTime, lockoutDuration :: !NominalDiffTime
  , perIpRequestsPerMinute :: !Int, perIpBurst :: !Int, rateLimitEnabled :: !Bool }
defaultRateLimitConfig :: RateLimitConfig
-- ShomeiConfig gains: rateLimitConfig :: !RateLimitConfig (defaulted in defaultShomeiConfig)

-- Shomei.Domain.LoginAttempt
data LoginOutcome = LoginSuccess | LoginFailure
newtype AccountKey = AccountKey Text
newtype ClientIp   = ClientIp Text
data LoginAttempt     = LoginAttempt { accountKey, clientIp, outcome, occurredAt }
data NewLoginAttempt  = NewLoginAttempt { accountKey, clientIp, outcome, occurredAt }
data AccountLockout   = AccountLockout { accountKey, failedCount, lockedUntil, updatedAt }

-- Shomei.Domain.Command (or Shomei.Domain.ClientContext)
data ClientContext = ClientContext { clientIp :: !ClientIp, accountKey :: !AccountKey }

-- Shomei.Effect.LoginAttemptStore
data LoginAttemptStore :: Effect where
  RecordLoginAttempt           :: NewLoginAttempt -> LoginAttemptStore m ()
  CountRecentFailuresByAccount :: AccountKey -> UTCTime -> LoginAttemptStore m Int
  CountRecentFailuresByIp      :: ClientIp   -> UTCTime -> LoginAttemptStore m Int
  GetAccountLockout            :: AccountKey -> LoginAttemptStore m (Maybe AccountLockout)
  SetAccountLockout            :: AccountLockout -> LoginAttemptStore m ()
  ClearAccountLockout          :: AccountKey -> LoginAttemptStore m ()
-- + send smart constructors recordLoginAttempt / countRecentFailuresByAccount / … / clearAccountLockout

-- Shomei.Error: AuthError gains AccountLocked, TooManyRequests
-- Shomei.Domain.Event: AuthEvent gains AccountLocked AccountLockedData, LoginThrottled LoginThrottledData

-- Shomei.Workflow
login ::
  ( UserStore :> es, CredentialStore :> es, SessionStore :> es, RefreshTokenStore :> es
  , PasswordHasher :> es, TokenSigner :> es, AuthEventPublisher :> es
  , LoginAttemptStore :> es, Clock :> es, TokenGen :> es ) =>
  ShomeiConfig -> ClientContext -> LoginCommand -> Eff es (Either AuthError (User, TokenPair))

-- Shomei.Effect.InMemory: runInMemory's effect list gains LoginAttemptStore; runLoginAttemptStore added
```

End of **M2** (`shomei-postgres`):

```haskell
-- Shomei.Postgres.LoginAttemptStore
runLoginAttemptStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (LoginAttemptStore : es) a -> Eff es a

-- Shomei.Postgres.Codec: loginOutcomeToText / loginOutcomeFromText
```

End of **M4** (`shomei-server`, requires EP-6):

```haskell
-- Shomei.Server.Middleware.RateLimit
data RateLimiter
newRateLimiter      :: Int -> Int -> IO RateLimiter          -- perMinute, burst
rateLimitMiddleware :: RateLimiter -> Network.Wai.Middleware
```

Cross-plan dependency notes. EP-2 **consumes** MasterPlan 1's `ShomeiConfig` (extends it,
IP-3), the `shomei` schema and codd migration convention (IP-7), and (M3/M4) EP-5/EP-6's
Servant API and WAI assembly (IP-4, IP-5). EP-2 **soft-consumes** EP-1's `Shomei.Effect.Notifier`
(IP-1, optional, gated). EP-2 **coordinates** with EP-3 on middleware ordering (IP-4: EP-3
outermost) and on appending its own `cabal.project` block if any (IP-8: EP-2 adds none). The
two open coordination risks to watch: (1) **IP-4 ordering** — EP-3's logging middleware must
wrap EP-2's rate limiter; the M4 step is written to insert correctly whether EP-3 has landed
or not, but the final realized order in `App.hs` must be recorded here once both land. (2)
**IP-7 timestamps** — EP-2's `2026-06-05-*` migrations must remain strictly later than every
file EP-1 actually applies; if EP-1 lands with later timestamps than its planned `2026-06-04-*`
window, bump EP-2's and note it in the Decision Log.


## Revision Notes

2026-06-04: Updated after the package-layout refactor and MasterPlan audit. Package paths now
refer to top-level directories, effect modules use `Shomei.Effect.*`, and the plan now assumes
the real `shomei-servant` and `shomei-server` modules exist.
