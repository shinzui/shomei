---
id: 8
slug: account-lifecycle-email-verification-and-password-reset
title: "Account lifecycle: email verification and password reset"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Account lifecycle: email verification and password reset

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-1** of MasterPlan 2,
`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`. It owns
Integration Points **IP-1** (the `Shomei.Effect.Notifier` mailer effect) and **IP-2** (the new
single-use-token domain types and their stores), and contributes to **IP-3** (extend
`ShomeiConfig`, append-only), **IP-5** (new `ShomeiAPI` routes), and **IP-7** (new codd
migrations). Those Integration Points are quoted verbatim in the relevant sections below so
this plan is self-contained.


## Purpose / Big Picture

Shōmei ("証明", *proof* / *authentication*) is a Haskell authentication toolkit. After
MasterPlan 1, a developer can run a server that lets a user sign up, log in, refresh tokens,
log out, fetch their profile, and verify JWTs against a published JWKS. But the bootstrap
deliberately omitted the rest of the **account lifecycle**: there is no way to *verify an
email address*, no way to *reset a forgotten password*, and no way for a logged-in user to
*change their password*. This plan fills that gap, end-to-end and demonstrable with `curl`.

After this change, the following becomes possible, and is provable from a terminal:

- A new user signs up, then asks Shōmei to verify their email
  (`POST /auth/verify-email/request`). Because the toolkit ships with a **development
  log-only notifier**, the verification link (containing a one-time token) is printed to the
  server's logs instead of being emailed. The user copies the token out of the logs and
  confirms it (`POST /auth/verify-email/confirm`); their account is now marked verified
  (a `email_verified_at` timestamp is set).
- A user who has forgotten their password requests a reset
  (`POST /auth/password-reset/request`). The response is **always the same generic 202**,
  whether or not the email belongs to a real account, so an attacker cannot use this endpoint
  to discover which emails are registered. If the account exists, a reset link with a
  one-time token is printed to the logs. The user confirms it with a new password
  (`POST /auth/password-reset/confirm`); the password is changed **and every one of that
  user's existing sessions and refresh tokens is revoked**, so any stolen session is
  immediately useless. The old refresh token is now rejected.
- A logged-in user changes their password (`POST /auth/password/change`, authenticated with
  their access token), supplying their current password and a new one. On success their other
  sessions are revoked.

These flows are delivered behind a **notification effect** (`Shomei.Effect.Notifier`) so the
toolkit bakes in no particular email provider. **Shōmei does not send email itself:** it
*emits* a `Notification` (recipient, one-time link/token, expiry) and ships a development
log-only sender that writes the link to the server log. An operator delivers it by supplying
their own `Notifier` interpreter that forwards the notification to their existing provider
(SendGrid, Resend, SES, an SMTP relay, …); a future `shomei-email` package may add in-tree
senders. (Email *sending* was originally planned as a production SMTP sender; it was descoped
on 2026-06-17 — see the Decision Log.)

The user-visible outcome is therefore: a complete, secure account lifecycle that an operator
can demonstrate with a sequence of `curl` calls (signup → verify-email request shows a link
in the logs → confirm → password-reset request → confirm → old session rejected), backed by a
green pure test suite and a green PostgreSQL integration suite that prove the security-critical
properties (single-use tokens, generic non-leaking responses, session revocation on reset).

### Precondition: MasterPlan 1 must be Complete

This plan is written to be executed **after** MasterPlan 1
(`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`) is Complete. As of the
2026-06-04 package-layout refactor, that precondition is satisfied: `shomei-jwt`,
`shomei-servant`, `shomei-server`, and `shomei-client` are real top-level packages, not
placeholders, and `cabal build all` plus `cabal test all` pass. The HTTP and server-wiring
parts of this plan (Milestones M3 and M4) now extend existing artifacts: the `ShomeiAPI`
NamedRoutes record in `shomei-servant/src/Shomei/Servant/API.hs`, the handlers in
`shomei-servant/src/Shomei/Servant/Handlers.hs`, and the server assembly in
`shomei-server/src/Shomei/Server/App.hs` and `shomei-server/src/Shomei/Server/Boot.hs`.
Where this plan says "add a route" or "wire an interpreter", it means extend those real
modules while keeping `cabal build all` and the relevant test suites green.

### Definitions used throughout

So a reader new to the codebase is not lost:

- **Effect interface** — an abstract capability the core needs from the outside world
  (e.g. "store a token", "send a notification"). The core depends only on the *shape* of
  the capability, never on a concrete implementation. Each interface is an `effectful`
  *dynamic effect* exposed from `Shomei.Effect.*`.
- **`effectful` dynamic effect** — a GADT of kind `Effect` with
  `type instance DispatchOf E = Dynamic`, one constructor per operation, and a thin
  `send`-based *smart constructor* per operation exposing it as
  `(E :> es) => ... -> Eff es a`. An **interpreter** (`interpret_`) supplies the behaviour.
  Production interpreters live in adapter packages; an in-memory interpreter for tests lives
  in `shomei-core/src/Shomei/Effect/InMemory.hs`.
- **Smart constructor** — a function that builds a value while enforcing invariants the raw
  data constructor cannot (e.g. `mkEmail :: Text -> Either AuthError Email`). The raw
  constructor is not exported, so invalid values are unrepresentable outside the module.
- **Opaque token** — a long random secret string handed to the client. The server stores
  **only its hash**, never the raw token, so a database leak does not reveal usable tokens.
  This is exactly how `shomei-core/src/Shomei/Domain/RefreshToken.hs` already treats
  refresh tokens; the new verification and reset tokens copy that pattern precisely.
- **Single-use token** — an opaque token that may be consumed at most once. After it is used
  (confirmed) it transitions to a `consumed` status and any later presentation is rejected.
  It also carries a TTL (time-to-live) and is rejected once expired.
- **TypeID / `KindID`** — a globally-unique sortable identifier (a UUIDv7) with a
  human-readable type prefix, from the `mmzk-typeid` library. `Shomei.Id` defines
  `UserId = KindID "user"`, `SessionId = KindID "session"`, etc. This plan adds
  `VerificationTokenId = KindID "verification_token"` and
  `PasswordResetTokenId = KindID "password_reset_token"`. The underlying UUID is stored in a
  native PostgreSQL `uuid` column.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### Milestone M1 — Notifier effect, one-time-token domain + effects + in-memory interpreter, account workflows, pure tests

- [x] M1.1 Add `VerificationTokenId` and `PasswordResetTokenId` to
      `shomei-core/src/Shomei/Id.hs` (new `KindID` prefixes + UUID converters +
      `gen…` helpers). Completed 2026-06-04.
- [x] M1.2 Create `shomei-core/src/Shomei/Domain/OneTimeToken.hs` (shared opaque
      single-use-token shape: `OneTimeToken`, `OneTimeTokenHash`, `OneTimeTokenStatus`).
      Completed 2026-06-04.
- [x] M1.3 Create `shomei-core/src/Shomei/Domain/VerificationToken.hs`
      (`PersistedVerificationToken`, `NewVerificationToken`). Completed 2026-06-04.
- [x] M1.4 Create `shomei-core/src/Shomei/Domain/PasswordResetToken.hs`
      (`PersistedPasswordResetToken`, `NewPasswordResetToken`). Completed 2026-06-04.
- [x] M1.5 Create `shomei-core/src/Shomei/Domain/Notification.hs`
      (`Notification` sum: `EmailVerificationRequested` / `PasswordResetRequested`).
      Completed 2026-06-04.
- [x] M1.6 Create `shomei-core/src/Shomei/Effect/Notifier.hs` (the IP-1 effect).
      Completed 2026-06-04.
- [x] M1.7 Create `shomei-core/src/Shomei/Effect/VerificationTokenStore.hs`.
      Completed 2026-06-04.
- [x] M1.8 Create `shomei-core/src/Shomei/Effect/PasswordResetTokenStore.hs`.
      Completed 2026-06-04.
- [x] M1.9 Extend `Shomei.Domain.User` with `emailVerifiedAt :: Maybe UTCTime`; extend
      `Shomei.Effect.UserStore` with `MarkUserEmailVerified`. Completed 2026-06-04.
- [x] M1.10 Add new `AuthError` variants (`VerificationTokenInvalid`,
      `PasswordResetTokenInvalid`, `EmailAlreadyVerified`) to `Shomei.Error`. Completed
      2026-06-04.
- [x] M1.11 Add new `AuthEvent` variants + `*Data` records
      (`EmailVerificationRequested`, `EmailVerified`, `PasswordResetRequested`,
      `PasswordResetCompleted`) to `Shomei.Domain.Event`. Completed 2026-06-04.
- [x] M1.12 Extend `Shomei.Config` with a `NotifierConfig` sub-record (append-only, IP-3):
      `emailVerificationRequired :: Bool`, token TTLs, `notifierTransport`, base URL.
      Completed 2026-06-04.
- [x] M1.13 Create `shomei-core/src/Shomei/Workflow/Account.hs` with
      `requestEmailVerification`, `confirmEmailVerification`, `requestPasswordReset`,
      `confirmPasswordReset`, `changePassword`. Completed 2026-06-04.
- [x] M1.14 Extend `Shomei.Effect.InMemory` (`World` + interpreters) for the two new stores +
      the `Notifier` (list interpreter) + `MarkUserEmailVerified`. Completed 2026-06-04.
- [x] M1.15 Update `shomei-core/shomei-core.cabal` exposed-modules + test other-modules.
      Completed 2026-06-04.
- [x] M1.16 Write `shomei-core/test/Shomei/AccountSpec.hs` and register it; acceptance
      `cabal test shomei-core` green with the new account cases. Completed 2026-06-04.

### Milestone M2 — codd migrations + PostgreSQL interpreters + integration tests

- [x] M2.1 Add migration `…-shomei-users-email-verified.sql` (add
      `email_verified_at timestamptz NULL` to `shomei_users`). Completed 2026-06-04.
- [x] M2.2 Add migration `…-shomei-email-verification-tokens.sql`. Completed 2026-06-04.
- [x] M2.3 Add migration `…-shomei-password-reset-tokens.sql`. Completed 2026-06-04.
- [x] M2.4 Extend `Shomei.Postgres.UserStore` mapping for `email_verified_at` +
      `MarkUserEmailVerified`. Completed 2026-06-04.
- [x] M2.5 Create `shomei-postgres/src/Shomei/Postgres/VerificationTokenStore.hs`.
      Completed 2026-06-04.
- [x] M2.6 Create `shomei-postgres/src/Shomei/Postgres/PasswordResetTokenStore.hs`.
      Completed 2026-06-04.
- [x] M2.7 Extend `Shomei.Postgres.Codec` with one-time-token status codecs. Completed
      2026-06-04.
- [x] M2.8 Update `shomei-postgres/shomei-postgres.cabal` exposed-modules. Completed
      2026-06-04.
- [x] M2.9 Extend `shomei-postgres/test/Main.hs` with token round-trip and
      account-workflow-over-PostgreSQL tests; acceptance `cabal test shomei-postgres` green.
      Completed 2026-06-04.
- [x] M2.10 Run `just migrate`; `\d shomei.shomei_email_verification_tokens` and the reset
      table exist; `shomei_users` has the new column. Completed 2026-06-04.

### Milestone M3 — ShomeiAPI routes + handlers + DTOs + config wiring

- [x] M3.1 Add the five DTO records to `shomei-servant` (request/response JSON).
      Completed 2026-06-04.
- [x] M3.2 Add the five routes to the `ShomeiAPI` NamedRoutes record (IP-5). Completed
      2026-06-04.
- [x] M3.3 Add the five handlers driving `Shomei.Workflow.Account`. Completed 2026-06-04.
- [x] M3.4 Acceptance: `cabal build shomei-servant` green; handler unit/golden tests (if EP-5
      established a handler test harness) green. Completed 2026-06-04 with the in-process
      servant end-to-end account lifecycle test.

### Milestone M4 — server wiring + dev-log sender + curl walkthrough

- [x] M4.1a Create `shomei-server/src/Shomei/Notify.hs` with config-selected log-backed
      `Notifier` interpreters. Completed 2026-06-04.
- [-] M4.1b ~~Add a real SMTP sender~~ **DESCOPED 2026-06-17.** Shōmei is no longer responsible
      for sending email: the `Notifier` effect is the integration seam, the shipped server emits
      the notification and logs the link, and operators deliver it via their own interpreter (a
      future `shomei-email` package may add in-tree senders). The vestigial `SmtpNotifier`
      transport and `runNotifierSmtp` stub were removed from the code. See the Decision Log.
- [x] M4.2 Wire the two new store interpreters + the selected `Notifier` interpreter into the
      server assembly in `shomei-server`. Completed 2026-06-04.
- [-] M4.3 ~~Add the SMTP/email library block to `cabal.project` (IP-8).~~ **DESCOPED
      2026-06-17** with M4.1b — no email transport ships, so no new dependency is added.
- [x] M4.4 Acceptance: full `curl` walkthrough against the running server. Completed 2026-06-10
      — verified live against the dev PostgreSQL with the default log-only notifier. See the
      transcript and the 202-status note in Surprises & Discoveries.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-04: M1 could use the existing `TokenGen` effect exactly as planned by rewrapping
  `RefreshToken`/`RefreshTokenHash` text into `OneTimeToken`/`OneTimeTokenHash`; no new random
  byte or hashing implementation was needed. Evidence: `nix develop --command cabal test
  shomei-core` passed all 15 tests, including the new account-token cases.
- 2026-06-04: Touching `shomei-migrations/shomei-migrations.cabal` was not sufficient to
  force Cabal to re-run the `embedDir` splice during the test run; changing
  `shomei-migrations/src/Shomei/Migrations.hs` itself made the migration library rebuild and
  the codd transcript then reported 10 migrations. Evidence: the successful
  `nix develop --command cabal test shomei-postgres` run applied the three
  `2026-06-04-*` migrations in each throwaway database.
- 2026-06-04: No SMTP/email package was registered in the local `mori` registry for this
  project; `mori registry search smtp`, `mori registry search HaskellNet`, and
  `mori registry search mime-mail` returned no package source to audit. The server now has
  the `Shomei.Notify` assembly module and explicit `SmtpNotifier` selection path, but that
  selection is still log-backed until a vetted SMTP dependency is added.
- 2026-06-10: Re-checked the SMTP blocker before the live walkthrough — `mori registry search`
  for `smtp`, `mail`, and `HaskellNet` still return nothing. M4.1b/M4.3 remain blocked for the
  documented reason; the rest of EP-1 is acceptance-complete via the log-only notifier.
- 2026-06-17: **The SMTP blocker was resolved by removing the requirement, not by adding a
  dependency.** The user decided Shōmei should not send email at all — the `Notifier` effect is
  the integration seam and operators forward the emitted `Notification` to their own provider.
  The vestigial `SmtpNotifier` constructor (`Shomei.Config.NotifierTransport`) and the
  `runNotifierSmtp` stub (`shomei-server/src/Shomei/Notify.hs`) were deleted; `NotifierTransport
  = LogNotifier` is now the only built-in and `Shomei.Notify` exposes only `runNotifierLog`. The
  Dhall/env loader never wired SMTP fields, so no config change was needed. `cabal build all` /
  `cabal test all` are green (incl. the PostgreSQL account-workflow integration tests and the
  live client round-trip) and fourmolu is clean. EP-1 is now Complete.
- 2026-06-10: **All four account-lifecycle endpoints return HTTP `202 Accepted` with a
  `NoContent` body, including the two *confirm* endpoints** — not `200` as the original
  Validation transcript prose stated. This is intentional in the implementation
  (`shomei-servant/src/Shomei/Servant/API.hs` declares each as `Verb 'POST 202 '[JSON]
  NoContent`): the lifecycle surface uses one uniform "accepted" status across request and
  confirm so a confirm response carries no body an attacker could read and is
  indistinguishable in shape from a request response. The behaviour is correct — the live
  walkthrough proves the verification flip, the session revocation, and the generic
  no-leak responses regardless of the 202-vs-200 code. The Validation section below has been
  corrected to show `202`.
- 2026-06-10: Live walkthrough evidence (dev PostgreSQL, default log-only notifier), run from
  the repo root with the server started via `PG_CONNECTION_STRING="host=$PGHOST dbname=shomei
  user=$(id -un)" cabal run shomei-server`:

  ```text
  signup alice@example.com                         -> 200 (token + user)
  POST /auth/verify-email/request {alice}          -> 202 ; log: [shomei:log] email_verification email=alice@example.com link=…/auth/verify-email/confirm?token=<VTOKEN> …
  POST /auth/verify-email/confirm {VTOKEN}         -> 202 ; SELECT email_verified_at -> 2026-06-10 12:04:10 (non-null)
  POST /auth/password-reset/request {alice}        -> 202
  POST /auth/password-reset/request {nobody}       -> 202 (byte-identical; NO log line emitted for nobody@example.com)
  log: [shomei:log] password_reset email=alice@example.com link=…/auth/password-reset/confirm?token=<RTOKEN> …
  POST /auth/password-reset/confirm {RTOKEN,newpw} -> 202
  POST /auth/refresh {OLD_REFRESH from pre-reset login} -> 401 (all sessions revoked by the reset)
  POST /auth/login {alice, NEW password}           -> 200
  POST /auth/login {alice, OLD password}           -> 401
  ```

  This is EP-1's headline acceptance: a complete, secure account lifecycle observable from a
  terminal, with single-use tokens, generic non-leaking request responses, and full session
  revocation on reset.


## Decision Log

Record every decision made while working on the plan.

- Decision: The `Notifier` interpreters live in a module
  `shomei-server/src/Shomei/Notify.hs` inside the existing `shomei-server` package,
  **not** in a new `shomei-notify` package.
  Rationale: MasterPlan 2's IP-1 names this as the default ("a `Shomei.Notify` module inside
  `shomei-server` to avoid a new package"). A notification sender is an infrastructure concern
  that must stay out of the transport-agnostic `shomei-core` (the core only defines the
  `Notifier` *effect*). The server is the natural assembly point: it already constructs every
  other interpreter and reads `ShomeiConfig`. Avoiding an eighth package keeps `mori.dhall`
  unchanged. (This decision originally also defined a production *SMTP* interpreter here;
  **superseded 2026-06-17** — see the next entry. `Shomei.Notify` now ships only the log
  sender.)
  Date: 2026-06-04

- Decision: **Shōmei does not send email. The production SMTP sender is descoped entirely.**
  The `Shomei.Effect.Notifier` effect is the sole integration seam: the toolkit emits a
  `Notification` (recipient, one-time link/token, expiry) and `shomei-server` ships exactly one
  built-in interpreter — `runNotifierLog`, which writes the link to the server log
  (`Shomei.Config.NotifierTransport` collapses to the single constructor `LogNotifier`).
  Delivering the message is the operator's responsibility: they supply their own `Notifier`
  interpreter that forwards the `Notification` to their existing provider (SendGrid, Resend,
  SES, an SMTP relay, …). In-tree senders, if ever wanted, belong in a separate `shomei-email`
  package — not in `shomei-core`/`shomei-server`.
  Rationale: Sending email is an operator concern — virtually every deployment already has a
  provider. Baking a transport into the toolkit adds an unaudited dependency, a TLS/secrets
  surface, and ongoing maintenance for no real benefit, and it conflicted with the repo's
  dependency-lookup rule (no vetted SMTP package is registered in `mori`, which is exactly why
  M4.1b/M4.3 had been stuck). Shōmei's responsibility ends at emitting the notification. Code
  impact (verified `cabal build all` + `cabal test all` green, fourmolu clean): removed the
  `SmtpNotifier` constructor and `runNotifierSmtp`; the Dhall/env loader never wired SMTP
  fields, so no config change was needed. This removes EP-1's only remaining task, so EP-1 is
  now Complete.
  Date: 2026-06-17

- Decision: A user's verified status is represented by a **nullable `email_verified_at
  timestamptz` column on `shomei_users`** (and `emailVerifiedAt :: Maybe UTCTime` on the
  `User` record), not a boolean and not a separate table.
  Rationale: A timestamp is strictly more informative than a boolean (`NULL` = unverified,
  a value = verified-at-that-instant, useful for audit) while answering the boolean question
  trivially (`emailVerifiedAt /= Nothing`). A column on the existing table avoids a join on
  every user read and a second entity to keep consistent; verification is a 1:1 attribute of
  the user, so a separate table would be over-normalized. This mirrors how `shomei_sessions`
  already carries a nullable `revoked_at` for an analogous "happened-at" fact. The migration
  is additive and defaulted (`NULL`), so existing rows and existing code still work.
  Date: 2026-06-04

- Decision: The two single-use token tables (`shomei_email_verification_tokens`,
  `shomei_password_reset_tokens`) follow the existing `shomei_refresh_tokens` design exactly:
  a native `uuid` primary key, a `user_id uuid` foreign key into `shomei_users`, a `token_hash
  text NOT NULL UNIQUE` (only the **hash** is stored), a `text` status (`active`/`consumed`/
  `revoked`/`expired`), and `created_at`/`expires_at`/`consumed_at` timestamps. They are
  modeled in Haskell by a shared `Shomei.Domain.OneTimeToken` shape reused by both
  `Shomei.Domain.VerificationToken` and `Shomei.Domain.PasswordResetToken`.
  Rationale: The opaque-token security property (store only the hash, single-use, TTL, status)
  is identical to refresh tokens, so reusing that exact, already-reviewed shape minimizes new
  surface and keeps the schema and interpreters uniform. Two separate tables (rather than one
  polymorphic `shomei_one_time_tokens` with a `purpose` column) keep foreign-key semantics and
  query plans simple and let each table evolve independently; the cost is a near-duplicate
  migration, which is cheap and append-only per IP-7.
  Date: 2026-06-04

- Decision: `requestPasswordReset` and `requestEmailVerification` (the *request* steps) never
  reveal whether the email belongs to a real account: the workflow returns a uniform success
  regardless, and only emits a notification when the account actually exists.
  Rationale: Consistent with MasterPlan 1's login generic-error rule (no account-existence
  leak). An attacker probing `POST /auth/password-reset/request` must not be able to
  distinguish "registered" from "not registered" by the response. The notification side effect
  is the only difference, and it is invisible to the requester.
  Date: 2026-06-04

- Decision: `confirmPasswordReset` and `changePassword`, on success, revoke **all** of the
  user's sessions and refresh tokens via `revokeAllUserSessions` (verified to exist in
  `shomei-core/src/Shomei/Effect/SessionStore.hs`) plus a per-user refresh-token sweep,
  and publish a `PasswordResetCompleted` / `PasswordChanged` event.
  Rationale: Resetting a forgotten password is the canonical "I may be compromised" action;
  invalidating every existing session is the expected, secure behaviour. The existing
  `SessionStore` effect already exposes `RevokeAllUserSessions :: UserId -> UTCTime ->
  SessionStore m ()`, so no new effect interface operation is needed for sessions. Refresh tokens are
  revoked per-session by iterating the user's sessions (the `RefreshTokenStore` already exposes
  `RevokeSessionRefreshTokens`); a dedicated `RevokeAllUserRefreshTokens` is added to the
  `RefreshTokenStore` effect to do this in one operation (see Interfaces and Dependencies).
  Date: 2026-06-04


- Decision: Update this ExecPlan for the 2026-06-04 package-layout and effect-namespace refactor.
  Rationale: The packages now live as top-level directories rather than under the old nested packages directory, and the core effect interfaces now live under `Shomei.Effect.*` rather than the old Port namespace. This revision also removes stale bootstrap-placeholder assumptions and points implementation steps at the current real modules.
  Date: 2026-06-04

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)

- 2026-06-04: Milestone M1 is complete. The core package now exposes the notifier effect,
  one-time-token domain records and store effects, `NotifierConfig`, account lifecycle
  workflows, and in-memory interpreters. `nix develop --command cabal test shomei-core`
  passes with 15 tests, including eight account lifecycle cases. M2 remains: migrations,
  PostgreSQL interpreters, and integration tests.
- 2026-06-04: Milestone M2 is complete. The migration package embeds the three new
  account-lifecycle migrations; PostgreSQL adapters now persist `email_verified_at`, email
  verification tokens, and password-reset tokens; and the PostgreSQL integration suite covers
  direct token round trips plus account verification and password reset workflows over a real
  ephemeral database. `nix develop --command cabal test shomei-postgres` passes with 14 tests,
  `nix develop --command cabal build all` passes, and `nix develop --command just migrate`
  applied the three new migrations to the local `shomei` database.
- 2026-06-04: Milestone M3 is complete and M4 is partially complete. `shomei-servant` exposes
  the five account-lifecycle HTTP routes, their DTOs, and handlers; `shomei-server` wires the
  PostgreSQL token stores and config-selected notifier interpreter. The servant in-process
  HTTP test now covers signup, email verification, password reset, login, refresh, JWKS, and
  role checks. `nix develop --command cabal test shomei-servant`,
  `nix develop --command cabal test shomei-server`, `nix develop --command cabal build all`,
  and `nix develop --command cabal test all` pass. Remaining M4 work is a real SMTP sender
  and the live-server `curl` walkthrough.
- 2026-06-10: **Milestone M4 is acceptance-complete except the production SMTP sender.** The
  full account lifecycle was demonstrated live (`curl`) against the dev PostgreSQL with the
  default log-only notifier: signup → verify-email request (link logged) → confirm (flips
  `email_verified_at`) → password-reset request (generic 202 for both a real and an unknown
  email, link logged only for the real one) → confirm (changes the password, revokes all
  sessions) → the pre-reset refresh token is rejected (401) → login with the new password
  succeeds, old password fails. `cabal build all` is green and the embedded migrations are
  applied. (At the time, the only remaining work was M4.1b/M4.3, the *real* SMTP sender,
  blocked on a vetted SMTP dependency — see the 2026-06-17 entry below.)

- 2026-06-17: **EP-1 is Complete.** Email sending was descoped (Decision Log, same date):
  Shōmei is not responsible for delivering email — it emits notifications through the
  `Notifier` effect and ships only the log sender, and operators deliver them. The vestigial
  `SmtpNotifier`/`runNotifierSmtp` code was removed (`NotifierTransport = LogNotifier` is the
  sole built-in; `Shomei.Notify` exposes only `runNotifierLog`). With M4.1b/M4.3 descoped and
  all user-visible behaviour delivered and proven (pure in-memory tests, PostgreSQL integration
  tests, and the live `curl` walkthrough), every milestone of EP-1 is satisfied. `cabal build
  all` / `cabal test all` are green and fourmolu is clean. Against the original Purpose, the
  outcome matches it exactly except that the account-lifecycle notifications are *emitted* for
  the operator to deliver rather than sent by Shōmei over SMTP — a deliberate scope narrowing,
  not a gap.


## Context and Orientation

This section assumes no prior knowledge of the repository or its tools.

### Where things are

The repository root is `/Users/shinzui/Keikaku/bokuno/shomei`. It is a multi-package Cabal
workspace (one `cabal.project` listing every top-level package directory). The packages
relevant to this plan:

- `shomei-core` — the transport-agnostic heart: domain types
  (`src/Shomei/Domain/*`), typed identifiers (`src/Shomei/Id.hs`), the error vocabulary
  (`src/Shomei/Error.hs`), the runtime config (`src/Shomei/Config.hs`), the effect interfaces
  (`src/Shomei/Effect/*`), the in-memory interpreter (`src/Shomei/Effect/InMemory.hs`), and the
  workflows (`src/Shomei/Workflow.hs`). It depends on no database, HTTP, or JWT library.
- `shomei-postgres` — `hasql` adapters: a `Database` effect over a connection pool
  (`src/Shomei/Postgres/Database.hs`), one interpreter module per effect group under
  `src/Shomei/Postgres/*`, shared codecs (`src/Shomei/Postgres/Codec.hs`), and `Shomei.Crypto`
  (Argon2id hashing + token generation).
- `shomei-migrations` — codd-managed SQL schema: timestamped files under
  `sql-migrations/`, embedded at compile time and applied via `codd`. A public `test-support`
  sublibrary provisions a fresh ephemeral PostgreSQL with the schema applied.
- `shomei-servant` — the Servant API: the `ShomeiAPI` NamedRoutes record, request/response
  DTOs, and handlers that drive `Shomei.Workflow`.
- `shomei-server` — the executable: it acquires the `hasql` pool, runs migrations,
  assembles every interpreter, loads `ShomeiConfig`, and serves the Servant `Application`.

The two completed reference plans that establish the house patterns this plan mirrors are
`docs/plans/2-core-domain-model-ports-and-auth-workflows.md` (EP-2: domain + effects +
workflows) and `docs/plans/3-postgresql-persistence-and-migrations.md` (EP-3: migrations +
PostgreSQL interpreters). Read them if any pattern below is unclear; this plan reuses their
conventions verbatim.

### House build conventions (mandatory, established by EP-1/EP-2/EP-3)

- GHC **9.12.4**, language edition **GHC2024**, `cabal-version: 3.0`. Build with
  `cabal build all`, test with `cabal test <pkg>`, format with `nix fmt` (fourmolu 0.19.0.1,
  4-space indent, leading-comma style) — **all inside `nix develop`** (entered automatically by
  `direnv` from `.envrc`, or manually with `nix develop`).
- Every `.cabal` stanza writes `import: warnings, shared`. The `shared` stanza's
  `default-extensions` include `DeriveAnyClass DuplicateRecordFields BlockArguments
  MultilineStrings OverloadedLabels OverloadedRecordDot OverloadedStrings PackageImports
  QualifiedDo TemplateHaskell` (and, in the postgres package, `DataKinds GADTs LambdaCase
  TypeFamilies`).
- Postpositive qualified imports: `import Data.Text qualified as Text`.
- The custom prelude `Shomei.Prelude` is imported in **every** module that uses one of its
  re-exports (`Text`, `UTCTime`, `Maybe`, `Generic`, aeson classes, `liftIO`, …). A module
  that uses only base names may omit it (EP-2 dropped it from seven trivial effect modules to
  satisfy `-Wall`/`-Wunused-imports`).
- Records: strict `!` fields, the entity-id field first, **no field prefixes** (rely on
  `DuplicateRecordFields` + `OverloadedRecordDot`), `deriving stock (Generic, Eq, Show)`,
  `deriving anyclass (FromJSON, ToJSON)`, `deriving newtype (...)` for newtypes.

### Three house gotchas you WILL hit (call them out, they bit EP-2/EP-3)

1. **`OverloadedRecordDot` only solves `HasField` when the field is in scope.** With
   `DuplicateRecordFields`, reading `x.field` for `x :: SomeRecord` fails
   (`GHC-39999: Could not deduce HasField "field" SomeRecord …`) unless `SomeRecord` is
   imported **with its fields**, i.e. `import … (SomeRecord (..))`, not just `(SomeRecord)`.
   So every record you read via `.field` must be imported with `(..)`.
2. **`Shomei.Domain.Event` is imported qualified.** Several of its constructors share names
   with `AuthError` / status constructors (e.g. `SessionRevoked`). Import it
   `import Shomei.Domain.Event qualified as Event` and build values as `Event.EmailVerified
   (Event.EmailVerifiedData …)`.
3. **Record UPDATES use generic-lens `#field` lenses, not record-update syntax.** With
   `DuplicateRecordFields`, `tok { status = … }` is ambiguous across records sharing a
   `status` field. Use `tok & #status .~ OneTimeTokenConsumed`, and add a per-module
   `import Data.Generics.Labels ()` (an orphan import, hence the empty import list). Reads
   still use `OverloadedRecordDot` (`tok.status`). The `World` record must
   `deriving stock (Generic)` for `#field` to work on it.

Never depend on the deprecated `memory` package; use `ram` (the postgres cabal already does).

### What already exists that this plan extends (verified against the working tree)

The opaque-token pattern this plan copies, from
`shomei-core/src/Shomei/Domain/RefreshToken.hs`:

```haskell
newtype RefreshToken = RefreshToken Text          -- the secret handed to the client
    deriving stock (Generic) deriving newtype (Eq, Show, FromJSON, ToJSON)
newtype RefreshTokenHash = RefreshTokenHash Text   -- the ONLY thing persisted
    deriving stock (Generic) deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)
data RefreshTokenStatus = RefreshTokenActive | RefreshTokenUsed | RefreshTokenRevoked | RefreshTokenExpired
```

The generation/hashing effect, from `shomei-core/src/Shomei/Effect/TokenGen.hs` — **reuse
this for the new tokens**, do not invent a new generator:

```haskell
data TokenGen :: Effect where
    GenerateOpaqueToken :: TokenGen m RefreshToken
    HashRefreshToken :: RefreshToken -> TokenGen m RefreshTokenHash
generateOpaqueToken :: (TokenGen :> es) => Eff es RefreshToken
hashRefreshToken    :: (TokenGen :> es) => RefreshToken -> Eff es RefreshTokenHash
```

The `TokenGen` effect produces a `RefreshToken`/`RefreshTokenHash` (both newtypes over `Text`).
This plan's one-time tokens reuse the *same* generator and rewrap the resulting `Text` into the
one-time-token newtypes (see `Shomei.Domain.OneTimeToken` below). This avoids adding a second
random-bytes/SHA-256 implementation: the production interpreter in
`shomei-postgres/src/Shomei/Crypto.hs` already implements `GenerateOpaqueToken`
(crypton `getRandomBytes 32`, base64url) and `HashRefreshToken` (SHA-256), and the test
interpreter in `Shomei.Effect.InMemory` emits `rt-0`, `rt-1`, … and hashes as `"hash:" <> t`.

The `User` record, from `shomei-core/src/Shomei/Domain/User.hs` (this plan adds
`emailVerifiedAt`):

```haskell
data User = User
    { userId :: !UserId, email :: !Email, displayName :: !(Maybe Text)
    , status :: !UserStatus, createdAt :: !UTCTime, updatedAt :: !UTCTime }
```

The `SessionStore` effect already has the revoke-all operation this plan needs, from
`shomei-core/src/Shomei/Effect/SessionStore.hs`:

```haskell
data SessionStore :: Effect where
    CreateSession :: NewSession -> SessionStore m Session
    FindSessionById :: SessionId -> SessionStore m (Maybe Session)
    RevokeSession :: SessionId -> UTCTime -> SessionStore m ()
    RevokeAllUserSessions :: UserId -> UTCTime -> SessionStore m ()
```

The migration naming convention, from
`shomei-migrations/sql-migrations/` — seven files exist today, the latest being
`2026-06-03-18-44-57-shomei-auth-events.sql`. New files use the same
`YYYY-MM-DD-HH-MM-SS-<slug>.sql` shape with **timestamps strictly later** than that, each
starting with `-- codd: in-txn` then `SET search_path TO shomei, pg_catalog;`. The `Justfile`
`new-migration` recipe scaffolds one with the current UTC timestamp; `just migrate` applies
them (it `touch`es the migrations `.cabal` first to force the compile-time `embedDir` re-embed).

### Quoted Integration Points this plan owns or contributes to

This plan implements the following Integration Points from MasterPlan 2. They are quoted so a
reader needs only this file.

**IP-1 (owned by this plan) —**
> A new dynamic `effectful` effect in
> `shomei-core/src/Shomei/Effect/Notifier.hs` with a smart constructor such as
> `sendNotification :: Notification -> Eff es ()`, where `Notification` is a core domain type
> (e.g. an `EmailVerificationRequested`/`PasswordResetRequested` sum carrying the recipient
> `Email`, a one-time link/token, and an expiry). Owner: **EP-1** (defines the effect, a
> `Notification` domain type, an in-memory/list interpreter for tests mirroring
> `Shomei.Effect.InMemory`, and a development "log only" interpreter in a `Shomei.Notify`
> module inside `shomei-server`).

(Updated 2026-06-17: MasterPlan 2's IP-1 originally also asked for an SMTP interpreter; email
sending was descoped — Shōmei ships no email-sending interpreter. The `Notifier` effect is the
seam an operator implements against, or a future `shomei-email` package provides. See the
Decision Log.)

**IP-2 (owned by this plan) —**
> Email-verification and password-reset tokens are opaque random tokens of which only the
> **hash** is persisted (exactly like the existing refresh tokens in
> `shomei-core/src/Shomei/Domain/RefreshToken.hs`), single-use, with a TTL and a
> status. Owner: **EP-1**, which adds `Shomei.Domain.VerificationToken` and
> `Shomei.Domain.PasswordResetToken` (or a unified `Shomei.Domain.OneTimeToken`) plus their
> `Shomei.Effect.*Store` effects and an in-memory interpreter, reusing the existing
> `Shomei.Effect.TokenGen` (`generateOpaqueToken`/`hashRefreshToken`) for generation and hashing.

**IP-3 (contributed; append-only) —**
> each plan adds its own named sub-record field to `ShomeiConfig` (e.g. `notifierConfig`,
> `rateLimitConfig`, `observabilityConfig`) and extends `defaultShomeiConfig` with that
> field's defaults; no plan rewrites another's field. Each new field must be `Maybe` or carry
> a default so older config files still parse.

**IP-5 (contributed) —**
> The Servant `ShomeiAPI` NamedRoutes record in `shomei-servant` is extended with new
> endpoints: **EP-1** adds `POST /auth/verify-email/request`, `POST /auth/verify-email/confirm`,
> `POST /auth/password-reset/request`, `POST /auth/password-reset/confirm`, and an
> authenticated `POST /auth/password/change` … the request/response DTOs follow the existing
> `SignupRequest`/`LoginRequest` JSON conventions.

**IP-7 (contributed; append-only) —**
> New PostgreSQL tables added under `shomei-migrations/sql-migrations/` following the
> existing timestamped naming convention (`YYYY-MM-DD-HH-MM-SS-<name>.sql`): **EP-1** adds
> `shomei_email_verification_tokens` and `shomei_password_reset_tokens`. Rule: each plan
> appends new migration files with later timestamps; migrations are immutable and append-only;
> all new tables live in the `shomei` schema and use native `uuid` identifier columns, `text`
> status enums, and `timestamptz` timestamps.


## Plan of Work

The work proceeds in four independently verifiable milestones. M1 and M2 depend only on the
already-complete EP-1/EP-2/EP-3 and can start now. M3 and M4 extend the not-yet-built
`shomei-servant` (MasterPlan 1 EP-5) and `shomei-server` (MasterPlan 1 EP-6) and must wait for
those to land.

### Milestone M1 — Notifier effect, one-time tokens, account workflows, pure tests

Scope: everything in `shomei-core`. At the end of M1, the core package contains the
`Notifier` effect (IP-1), the two single-use-token domain types and their store effects (IP-2),
the `Notification` domain type, the new error and event variants, the extended `User` with
`emailVerifiedAt`, the extended `ShomeiConfig` with a `NotifierConfig` sub-record (IP-3), the
five new account workflows, and an in-memory interpreter for every new effect interface. A new tasty test
suite drives the workflows through the in-memory interpreter and proves the security-critical
behaviours with **zero infrastructure**. Acceptance: `cabal test shomei-core` is green,
including the new `Shomei.AccountSpec` cases.

This milestone is built bottom-up: identifiers → domain types → effects → config/error/event →
workflows → in-memory interpreter → tests. The detailed module contents are in Interfaces and
Dependencies; the exact edits are in Concrete Steps.

### Milestone M2 — codd migrations, PostgreSQL interpreters, integration tests

Scope: `shomei-migrations` and `shomei-postgres`. At the end of M2, the
schema carries the new `email_verified_at` column and the two token tables; the PostgreSQL
`UserStore` maps the new column and the `MarkUserEmailVerified` operation; and there are
PostgreSQL interpreters for the two new store effects, mirroring
`Shomei.Postgres.RefreshTokenStore` exactly. A throwaway-PostgreSQL integration suite proves
each new effect interface round-trips against a real database and drives the new workflows end-to-end over
PostgreSQL (request verification → confirm flips `email_verified_at`; request reset → confirm
changes the password, marks the token consumed, and revokes all sessions; a second confirm of
the same token is rejected). Acceptance: `just migrate` applies the new migrations and the new
tables/column exist; `cabal test shomei-postgres` is green including the new cases.

### Milestone M3 — ShomeiAPI routes, handlers, DTOs, config wiring

Scope: `shomei-servant` (created by MasterPlan 1 EP-5). At the end of M3, the
`ShomeiAPI` NamedRoutes record has five new routes (IP-5), each with a request/response DTO
following the `SignupRequest`/`LoginRequest` JSON conventions and a handler that maps the DTO
to a `Shomei.Workflow.Account` command, runs it, and maps the result to an HTTP response.
Acceptance: `cabal build shomei-servant` is green; if EP-5 established a handler test harness,
its account-route cases pass.

This milestone **cannot start until MasterPlan 1 EP-5 has created `shomei-servant`'s
`ShomeiAPI` record and handler module.** The concrete steps name the files to extend by path
and describe what each addition looks like relative to the existing signup/login routes.

### Milestone M4 — server wiring, dev-log sender, curl walkthrough

Scope: `shomei-server` (created by MasterPlan 1 EP-6). At the end
of M4, the server assembles the two new store interpreters and the log-only `Notifier`
interpreter (the only built-in sender — Shōmei does not deliver email; see the Decision Log),
and the full account lifecycle is demonstrable with `curl`. Acceptance: the `curl` transcript in Validation and Acceptance runs
against the live server with the shown outputs — signup, verify-email request prints a link in
the logs, confirm marks the account verified, password-reset request prints a link, confirm
changes the password and revokes sessions, and the old refresh token is rejected.

This milestone **cannot start until MasterPlan 1 EP-6 has created `shomei-server`'s assembly.**


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop`. Create/modify the files exactly as specified in Interfaces and Dependencies.

### M1 steps

**Step M1-a — identifiers.** Edit `shomei-core/src/Shomei/Id.hs`: add the two new
`KindID` type synonyms, their `gen…` helpers, and their UUID converters (full listing in
Interfaces and Dependencies, "IP-2 — new identifiers"). Add the new names to the module export
list.

**Step M1-b — domain types.** Create
`shomei-core/src/Shomei/Domain/OneTimeToken.hs`,
`shomei-core/src/Shomei/Domain/VerificationToken.hs`,
`shomei-core/src/Shomei/Domain/PasswordResetToken.hs`, and
`shomei-core/src/Shomei/Domain/Notification.hs` (full listings below). Edit
`shomei-core/src/Shomei/Domain/User.hs` to add `emailVerifiedAt :: !(Maybe UTCTime)`
to both `User` and (do **not** add it to `NewUser` — a fresh user is always unverified).

**Step M1-c — effects.** Create `shomei-core/src/Shomei/Effect/Notifier.hs`,
`shomei-core/src/Shomei/Effect/VerificationTokenStore.hs`, and
`shomei-core/src/Shomei/Effect/PasswordResetTokenStore.hs`. Edit
`shomei-core/src/Shomei/Effect/UserStore.hs` to add the `MarkUserEmailVerified`
operation and its smart constructor. Edit
`shomei-core/src/Shomei/Effect/RefreshTokenStore.hs` to add
`RevokeAllUserRefreshTokens :: UserId -> UTCTime -> RefreshTokenStore m ()` and its smart
constructor (used by the reset/change workflows).

**Step M1-d — error/event/config.** Edit `shomei-core/src/Shomei/Error.hs` to add the
three new `AuthError` variants. Edit `shomei-core/src/Shomei/Domain/Event.hs` to add
the four new `*Data` records and `AuthEvent` arms. Edit
`shomei-core/src/Shomei/Config.hs` to add the `NotifierConfig` sub-record and the
`notifierConfig` field, extending `defaultShomeiConfig` (full listing below).

**Step M1-e — workflows.** Create
`shomei-core/src/Shomei/Workflow/Account.hs` with the five workflows (full listing
below). Note: `Shomei.Workflow` (the existing module) is unchanged; the account workflows live
in a new sub-module to keep the file readable, as MasterPlan 2 suggests.

**Step M1-f — in-memory interpreter.** Edit
`shomei-core/src/Shomei/Effect/InMemory.hs`: add three maps to `World`
(`verificationTokens`, `verificationByHash`, `passwordResetTokens`, `passwordResetByHash`) and
a `sentNotifications :: [Notification]` log; add interpreters `runVerificationTokenStore`,
`runPasswordResetTokenStore`, `runNotifier` (list interpreter); extend `runUserStore` with the
`MarkUserEmailVerified` case and `User`'s new field; extend `runRefreshTokenStore` with
`RevokeAllUserRefreshTokens`; and add the three new effects to the `runInMemory` effect-row and
interpreter stack.

**Step M1-g — cabal + tests.** Edit `shomei-core/shomei-core.cabal`: add the new
modules to `exposed-modules` and `Shomei.AccountSpec` to the test-suite's `other-modules`.
Create `shomei-core/test/Shomei/AccountSpec.hs` (cases listed in Validation and
Acceptance). Run:

```bash
cabal test shomei-core
```

Expected (abridged tasty transcript, new cases shown):

```text
shomei-core-test
  Shomei.Account
    request email verification emits a notification with a token:        OK
    confirm email verification flips emailVerifiedAt:                     OK
    confirming an already-consumed verification token is rejected:       OK
    request password reset for unknown email still returns success:      OK
    request password reset for unknown email emits NO notification:      OK
    confirm password reset changes password and revokes all sessions:    OK
    confirming an already-consumed reset token is rejected:              OK
    change password with wrong current password is rejected:             OK

All NN tests passed (0.00s)
```

M1 acceptance: `cabal test shomei-core` exits 0 with the new cases passing, and `nix fmt`
leaves the tree unchanged.

### M2 steps

**Step M2-a — migrations.** From the repo root inside `nix develop`, scaffold three migrations
with timestamps later than `2026-06-03-18-44-57`:

```bash
just new-migration name=shomei-users-email-verified
just new-migration name=shomei-email-verification-tokens
just new-migration name=shomei-password-reset-tokens
```

Each prints `Wrote shomei-migrations/sql-migrations/<ts>-<name>.sql`. Because
`new-migration` uses the current UTC time and today is `2026-06-04`, the generated timestamps
(e.g. `2026-06-04-…`) are automatically later than the seven existing `2026-06-03-…` files, so
codd orders them after the base schema. Fill each file with the SQL in Interfaces and
Dependencies ("IP-7 — migrations"). The users-email-verified migration uses
`ALTER TABLE … ADD COLUMN IF NOT EXISTS email_verified_at timestamptz NULL;`.

**Step M2-b — apply and verify.** Ensure PostgreSQL is running (the dev shell's
`process-compose` starts it; `just create-database` is idempotent). Then:

```bash
just migrate
psql -c '\d shomei.shomei_users'
psql -c '\dt shomei.*'
```

Expected: `\d shomei.shomei_users` shows the new `email_verified_at | timestamp with time
zone |` row; `\dt shomei.*` now lists `shomei_email_verification_tokens` and
`shomei_password_reset_tokens` alongside the original six tables.

**Step M2-c — codecs + interpreters.** Edit
`shomei-postgres/src/Shomei/Postgres/Codec.hs` to add
`oneTimeTokenStatusToText`/`oneTimeTokenStatusFromText`. Edit
`shomei-postgres/src/Shomei/Postgres/UserStore.hs`: widen `UserRow` to include
`Maybe UTCTime` (the `email_verified_at` column), thread it through `rebuildUser`/`mkUser`/the
`SELECT`/`INSERT` statements, and add the `MarkUserEmailVerified` case
(`UPDATE shomei.shomei_users SET email_verified_at = $2, updated_at = $2 WHERE user_id = $1`).
Create `shomei-postgres/src/Shomei/Postgres/VerificationTokenStore.hs` and
`shomei-postgres/src/Shomei/Postgres/PasswordResetTokenStore.hs`, each modeled
line-for-line on `Shomei.Postgres.RefreshTokenStore` (insert / find-by-hash / mark-consumed /
revoke-by-user). Add both modules to `shomei-postgres.cabal`'s `exposed-modules`. Build:

```bash
cabal build shomei-postgres
```

Expected: exits 0 with zero warnings.

**Step M2-d — integration tests.** Extend `shomei-postgres/test/Main.hs` with the new
round-trip and workflow-over-PostgreSQL cases (listed in Validation and Acceptance). Run:

```bash
cabal test shomei-postgres
```

Expected: green, with the new account cases in the transcript. M2 acceptance.

### M3 steps (after MasterPlan 1 EP-5 lands)

**Step M3-a — locate the EP-5 artifacts.** Find the module that defines the `ShomeiAPI`
NamedRoutes record (search `rg -n "ShomeiAPI" shomei-servant`) and the module that
defines its handlers and DTOs (e.g. `shomei-servant/src/Shomei/Servant/API.hs`,
`.../DTO.hs`, `.../Handlers.hs` — exact names are EP-5's; this plan extends whatever EP-5
created). Read how the existing `POST /auth/signup` route, its `SignupRequest`/`SignupResponse`
DTOs, and its handler are defined; the five new routes copy that structure.

**Step M3-b — DTOs.** Add five request DTOs and the needed response DTOs (full field lists in
Interfaces and Dependencies, "IP-5 — DTOs"), each `deriving anyclass (FromJSON, ToJSON)` with
the same JSON conventions EP-5 used for `SignupRequest`.

**Step M3-c — routes.** Add five fields to the `ShomeiAPI` NamedRoutes record (the four
unauthenticated `verify-email/request`, `verify-email/confirm`, `password-reset/request`,
`password-reset/confirm` routes return `202 Accepted`; `password/change` is guarded by the same
authentication combinator EP-5 uses for `GET /auth/me`).

**Step M3-d — handlers.** Add a handler per route. Each: parse/normalize the request, build the
matching `Shomei.Workflow.Account` argument, run the workflow in the handler's effect stack,
and translate `Either AuthError ()`/result to a response. The two *request* handlers always
return `202` (no account-existence leak); `confirm`/`change` map `AuthError` to the standard
error response EP-5 established. Build:

```bash
cabal build shomei-servant
```

Expected: exits 0. M3 acceptance.

### M4 steps (after MasterPlan 1 EP-6 lands)

**Step M4-a — sender.** Create `shomei-server/src/Shomei/Notify.hs` with the log-only
`Notifier` interpreter `runNotifierLog` (renders the notification to a one-line log message
including the one-time link). Provide
`runNotifierFromConfig :: ShomeiConfig -> Eff (Notifier : es) a -> Eff es a` that selects the
interpreter from `cfg.notifierConfig.notifierTransport` (only `LogNotifier` ships).
**No SMTP sender** — Shōmei does not deliver email; operators forward the emitted
`Notification` to their own provider via their own interpreter (descoped 2026-06-17, see the
Decision Log).

**Step M4-b — wiring.** In the `shomei-server` assembly (the module that stacks the PostgreSQL
interpreters behind the Servant app — find it via `rg -n "runDatabasePool|runUserStorePostgres"
shomei-server`), add `runVerificationTokenStorePostgres`,
`runPasswordResetTokenStorePostgres`, and the selected `Notifier` interpreter to the stack, in
the same position as the other store interpreters.

**Step M4-c — cabal.project (IP-8).** ~~Append an SMTP/email library block.~~ **DESCOPED
2026-06-17.** No email transport ships, so EP-1 adds **no** new dependency to `cabal.project`
or `shomei-server.cabal`. (An operator who implements their own `Notifier` interpreter adds
whatever client library they choose in *their* project; a future in-tree `shomei-email` package
would add its own.)

**Step M4-d — curl walkthrough.** Start the server (the command EP-6 documents, e.g.
`cabal run shomei-server`) and run the transcript in Validation and Acceptance. M4 acceptance.


## Validation and Acceptance

Validation is behavioural, not "it compiles". Acceptance is phrased as observable behaviour.

### M1 — pure in-memory tests (`shomei-core/test/Shomei/AccountSpec.hs`)

Each case constructs a fresh `World` via `emptyWorld <fixedTime>`, runs workflows through
`runInMemory`, and asserts on the returned `Either` and the resulting `World`. The cases,
with concrete inputs and observable outputs:

1. **Request email verification emits a notification.** After `signup` produces a user,
   `requestEmailVerification cfg (RequestEmailVerification user.email)` returns `Right ()`, and
   the `World`'s `sentNotifications` head is an `EmailVerificationRequested` carrying
   `user.email` and a non-empty one-time token; the `World`'s `verificationTokens` has exactly
   one `active` row whose `tokenHash` equals the hash of that token.
2. **Confirm flips `emailVerifiedAt`.** Taking the raw token from the emitted notification,
   `confirmEmailVerification cfg (ConfirmEmailVerification rawToken)` returns `Right ()`; the
   user row now has `emailVerifiedAt == Just <clock>` and the token row's status is
   `OneTimeTokenConsumed`.
3. **Replaying a consumed verification token is rejected.** Calling
   `confirmEmailVerification` a second time with the same `rawToken` returns
   `Left VerificationTokenInvalid` and does not change the user.
4. **Reset request for an unknown email still returns success.**
   `requestPasswordReset cfg (RequestPasswordReset <unknownEmail>)` returns `Right ()`
   (identical to the registered-email case's `Right ()`), so the response cannot distinguish
   the two.
5. **Reset request for an unknown email emits NO notification.** After case 4, the `World`'s
   `sentNotifications` is unchanged (length 0 for a fresh world) and `passwordResetTokens` is
   empty — proving the side effect is suppressed for non-existent accounts.
6. **Confirm reset changes the password and revokes all sessions.** Given a registered user
   with an active session, `requestPasswordReset` then
   `confirmPasswordReset cfg (ConfirmPasswordReset rawResetToken newPassword)` returns
   `Right ()`; the credential's `passwordHash` now verifies `newPassword`; **every** session
   for that user has status `SessionRevoked`; every refresh token for that user is
   `RefreshTokenRevoked`; the reset token is `OneTimeTokenConsumed`; and a
   `PasswordResetCompleted` event is in `publishedEvents`.
7. **Replaying a consumed reset token is rejected.** A second `confirmPasswordReset` with the
   same `rawResetToken` returns `Left PasswordResetTokenInvalid`.
8. **Change password with wrong current password is rejected.**
   `changePassword cfg (ChangePassword user.userId wrongCurrent newPassword)` returns
   `Left InvalidCredentials` and leaves the credential unchanged.

The exact command and expected transcript are in Concrete Steps, Step M1-g. The suite uses
**only** the in-memory interpreter — no DB, no SMTP, no network.

### M2 — PostgreSQL integration tests (extend `shomei-postgres/test/Main.hs`)

Each test provisions a fresh ephemeral PostgreSQL via `withShomeiMigratedDatabase` (from
`shomei-migrations:test-support`), acquires a `hasql` pool against its connection string, runs
the real interpreters, and asserts both the returned value and the database state (via direct
`SELECT`s). The new cases:

1. **Verification token round-trips.** Insert a `NewVerificationToken`, find it by hash, mark
   it consumed; a `SELECT status FROM shomei.shomei_email_verification_tokens` returns
   `consumed`.
2. **Reset token round-trips.** Same shape against `shomei_password_reset_tokens`.
3. **`MarkUserEmailVerified` sets the column.** After `markUserEmailVerified uid t`, a
   `SELECT email_verified_at FROM shomei.shomei_users WHERE user_id = …` returns `t`.
4. **Account verification over PostgreSQL.** Drive `signup` then `requestEmailVerification`
   then `confirmEmailVerification` through the PostgreSQL interpreters (with the in-test
   list-`Notifier` capturing the token); the user's `email_verified_at` is non-null and the
   token row is `consumed`.
5. **Password reset over PostgreSQL revokes sessions.** Drive `signup` then
   `requestPasswordReset` then `confirmPasswordReset`; assert the user's sessions are all
   `revoked` and the new password verifies, and that a second confirm with the same token
   yields `Left PasswordResetTokenInvalid`.

Acceptance: `cabal test shomei-postgres` is green and the transcript lists the new cases.

### M3/M4 — end-to-end `curl` walkthrough (the headline demonstration)

With the server running (M4) and the dev log-only notifier selected (the default), run this
sequence from a second terminal. Replace `localhost:8080` with whatever bind address EP-6
documents. The exact JSON envelope shapes come from EP-5's DTO conventions; the shapes below
follow the `SignupRequest`/`LoginRequest` precedent.

```bash
# 1. Sign up. Returns the user and a token pair (access + refresh).
curl -s -X POST localhost:8080/auth/signup \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'
```

Expected: HTTP 200 with a JSON body containing `"email":"alice@example.com"` and a
`"tokenPair"` (or EP-5's equivalent) with non-empty `accessToken` and `refreshToken`. Save the
`refreshToken` as `$OLD_REFRESH`.

```bash
# 2. Request email verification. Always 202; the link is logged, not returned.
curl -s -i -X POST localhost:8080/auth/verify-email/request \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com"}'
```

Expected: `HTTP/1.1 202 Accepted` with an empty or `{"status":"accepted"}` body. In the
**server logs** (the terminal running the server), a line like:

```text
[notify] email-verification for alice@example.com: https://app.example.com/verify-email?token=<RAW_TOKEN> (expires 2026-06-04T03:42:05Z)
```

Copy `<RAW_TOKEN>` into `$VTOKEN`.

```bash
# 3. Confirm verification with the token from the logs.
curl -s -i -X POST localhost:8080/auth/verify-email/confirm \
  -H 'content-type: application/json' \
  -d "{\"token\":\"$VTOKEN\"}"
```

Expected: `HTTP/1.1 202 Accepted` (the confirm endpoints share the lifecycle's uniform
`202 NoContent` status — see Surprises & Discoveries). A direct DB check confirms the flip:

```bash
psql -c "SELECT email_verified_at FROM shomei.shomei_users WHERE email='alice@example.com';"
```

Expected: one non-null timestamp.

```bash
# 4. Request a password reset. Always 202, even for unknown emails.
curl -s -i -X POST localhost:8080/auth/password-reset/request \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com"}'
# (Try an unknown email too — the response is byte-for-byte identical.)
curl -s -i -X POST localhost:8080/auth/password-reset/request \
  -H 'content-type: application/json' \
  -d '{"email":"nobody@example.com"}'
```

Expected: both return `HTTP/1.1 202 Accepted` with identical bodies. The logs show a reset
link **only** for `alice@example.com`; nothing is logged for `nobody@example.com`. Copy the
reset token into `$RTOKEN`.

```bash
# 5. Confirm the reset with a new password.
curl -s -i -X POST localhost:8080/auth/password-reset/confirm \
  -H 'content-type: application/json' \
  -d "{\"token\":\"$RTOKEN\",\"newPassword\":\"a different long passphrase here\"}"
```

Expected: `HTTP/1.1 202 Accepted` (uniform lifecycle status — see Surprises & Discoveries).

```bash
# 6. The OLD refresh token issued at signup is now rejected (reset revoked all sessions).
curl -s -i -X POST localhost:8080/auth/refresh \
  -H 'content-type: application/json' \
  -d "{\"refreshToken\":\"$OLD_REFRESH\"}"
```

Expected: a 4xx error (e.g. `HTTP/1.1 401 Unauthorized`) carrying the JSON encoding of
`SessionRevoked` or `RefreshTokenInvalid` — proving the reset invalidated the pre-existing
session. Logging back in with the **new** password succeeds:

```bash
curl -s -X POST localhost:8080/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"a different long passphrase here"}'
```

Expected: HTTP 200 with a fresh token pair. This end-to-end transcript is the headline
acceptance for the whole plan: a complete, secure account lifecycle observable from a terminal.


## Idempotence and Recovery

All M1/M3/M4 source edits are idempotent: re-applying them overwrites the same files with the
same content, and `cabal build`/`cabal test` only recompile what changed (recover a stale cache
with `cabal clean && cabal build shomei-core`).

The M2 migrations are the only stateful step and are written to be safe to re-run. Each uses
`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, and `ALTER TABLE … ADD COLUMN IF
NOT EXISTS`, and codd records which migrations it has applied so each runs at most once per
database; re-running `just migrate` is a no-op once applied. **Migrations are append-only and
immutable (IP-7): never edit a migration that may already be applied to any database.** If you
must change a token table's shape after it has shipped, add a new later-timestamped migration.
The `just migrate` recipe `touch`es the migrations `.cabal` before running so a newly added
`.sql` file is picked up by the compile-time `embedDir` splice; if a new migration "doesn't
apply", the usual cause is a stale embed — `cabal clean` then `just migrate` recovers it.

The ephemeral-PostgreSQL integration tests are self-contained: each test gets a brand-new
throwaway database (ephemeral-pg caches only the `initdb` cluster), so there is no cross-test
contamination and nothing to clean up. The dev database is never touched by the test suite.

If M3/M4 cannot start because MasterPlan 1 EP-5/EP-6 have not landed, M1 and M2 still stand
alone: the core types, effects, workflows, migrations, and PostgreSQL interpreters are complete
and tested, and the HTTP layer is purely additive on top.


## Interfaces and Dependencies

This section is the contract. New libraries: **none** — email sending was descoped (2026-06-17),
so EP-1 adds no SMTP/email library; everything reuses dependencies the packages already declare (`mmzk-typeid`, `uuid`, `effectful`,
`containers`, `aeson`, `time`, `text`, `hasql`, `contravariant-extras`, `crypton`, `ram`,
`tasty`, `tasty-hunit`). No Shōmei package may depend on the deprecated `memory` package.

### IP-2 — new identifiers (edit `shomei-core/src/Shomei/Id.hs`)

Add, mirroring the existing `UserId`/`RefreshTokenId` definitions:

```haskell
type VerificationTokenId = KindID "verification_token"
type PasswordResetTokenId = KindID "password_reset_token"

genVerificationTokenId :: (MonadIO m) => m VerificationTokenId
genVerificationTokenId = KindID.genKindID @"verification_token"

genPasswordResetTokenId :: (MonadIO m) => m PasswordResetTokenId
genPasswordResetTokenId = KindID.genKindID @"password_reset_token"

verificationTokenIdToUUID :: VerificationTokenId -> UUID
verificationTokenIdToUUID = getUUID
verificationTokenIdFromUUID :: UUID -> VerificationTokenId
verificationTokenIdFromUUID = decorateKindID

passwordResetTokenIdToUUID :: PasswordResetTokenId -> UUID
passwordResetTokenIdToUUID = getUUID
passwordResetTokenIdFromUUID :: UUID -> PasswordResetTokenId
passwordResetTokenIdFromUUID = decorateKindID
```

Add all six new names to the module's export list.

### IP-2 — the shared one-time-token shape (`shomei-core/src/Shomei/Domain/OneTimeToken.hs`, new)

This is the reusable opaque single-use-token shape, copied from `RefreshToken`'s design. Both
the verification and reset token modules reuse `OneTimeToken`, `OneTimeTokenHash`, and
`OneTimeTokenStatus`.

```haskell
{- | The shared shape of Shōmei's single-use, opaque tokens (email verification and
password reset). Like a refresh token, only the HASH is ever persisted; the raw
'OneTimeToken' is handed to the user once (in a link) and never stored. A token is
single-use: confirming it transitions its status to 'OneTimeTokenConsumed', after which
any replay is rejected. It also carries a TTL (the persisted row's @expiresAt@).
-}
module Shomei.Domain.OneTimeToken (
    OneTimeToken (..),
    OneTimeTokenHash (..),
    OneTimeTokenStatus (..),
) where

import Shomei.Prelude

-- | The opaque secret embedded in a verification/reset link. Never persisted.
newtype OneTimeToken = OneTimeToken Text
    deriving stock (Generic)
    deriving newtype (Eq, Show, FromJSON, ToJSON)

-- | The SHA-256 hash of a 'OneTimeToken'. The ONLY thing persisted.
newtype OneTimeTokenHash = OneTimeTokenHash Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data OneTimeTokenStatus
    = OneTimeTokenActive
    | OneTimeTokenConsumed
    | OneTimeTokenRevoked
    | OneTimeTokenExpired
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

Because `Shomei.Effect.TokenGen` produces a `RefreshToken`/`RefreshTokenHash` (newtypes over
`Text`), the workflows convert via the underlying `Text`: a freshly generated token
`RefreshToken t` becomes `OneTimeToken t`, and its hash `RefreshTokenHash h` becomes
`OneTimeTokenHash h`. Provide tiny converters in the workflow module (not exported) rather than
adding a second generator. This reuse is exactly what IP-2 mandates.

### IP-2 — verification token (`shomei-core/src/Shomei/Domain/VerificationToken.hs`, new)

```haskell
{- | An email-verification token row: which user it verifies, the stored hash, its TTL,
and its single-use status. Modeled on 'Shomei.Domain.RefreshToken.PersistedRefreshToken'.
-}
module Shomei.Domain.VerificationToken (
    PersistedVerificationToken (..),
    NewVerificationToken (..),
) where

import Shomei.Prelude

import Shomei.Domain.OneTimeToken (OneTimeTokenHash, OneTimeTokenStatus)
import Shomei.Id (UserId, VerificationTokenId)

data PersistedVerificationToken = PersistedVerificationToken
    { verificationTokenId :: !VerificationTokenId
    , userId :: !UserId
    , tokenHash :: !OneTimeTokenHash
    , status :: !OneTimeTokenStatus
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    , consumedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NewVerificationToken = NewVerificationToken
    { userId :: !UserId
    , tokenHash :: !OneTimeTokenHash
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

### IP-2 — password-reset token (`shomei-core/src/Shomei/Domain/PasswordResetToken.hs`, new)

Identical shape, distinct type and id (`password_reset_token_` prefix):

```haskell
module Shomei.Domain.PasswordResetToken (
    PersistedPasswordResetToken (..),
    NewPasswordResetToken (..),
) where

import Shomei.Prelude

import Shomei.Domain.OneTimeToken (OneTimeTokenHash, OneTimeTokenStatus)
import Shomei.Id (PasswordResetTokenId, UserId)

data PersistedPasswordResetToken = PersistedPasswordResetToken
    { passwordResetTokenId :: !PasswordResetTokenId
    , userId :: !UserId
    , tokenHash :: !OneTimeTokenHash
    , status :: !OneTimeTokenStatus
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    , consumedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NewPasswordResetToken = NewPasswordResetToken
    { userId :: !UserId
    , tokenHash :: !OneTimeTokenHash
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

### IP-1 — the `Notification` domain type (`shomei-core/src/Shomei/Domain/Notification.hs`, new)

```haskell
{- | A notification the system asks the outside world to deliver. Each variant carries the
recipient 'Email', the RAW one-time token (so the sender can build a link), and the
token's expiry. The core defines the shape; the @Shomei.Effect.Notifier@ effect carries it to
a sender. The shipped server's only built-in sender is the dev log-only one in
@shomei-server@'s @Shomei.Notify@; an operator forwards it to their own provider via their own
interpreter (Shōmei does not send email).
-}
module Shomei.Domain.Notification (
    Notification (..),
) where

import Shomei.Prelude

import Shomei.Domain.Email (Email)
import Shomei.Domain.OneTimeToken (OneTimeToken)

data Notification
    = EmailVerificationRequested
        { recipient :: !Email
        , token :: !OneTimeToken
        , expiresAt :: !UTCTime
        }
    | PasswordResetRequested
        { recipient :: !Email
        , token :: !OneTimeToken
        , expiresAt :: !UTCTime
        }
    deriving stock (Generic, Eq, Show)
```

Note: `Notification` carries a raw `OneTimeToken` (a secret) so it deliberately gets **no**
`ToJSON`/`FromJSON` instance — it is never serialized over the wire or persisted; it only
crosses the in-process `Notifier` effect to a sender. (`OneTimeToken` itself has JSON instances
for the DTO layer, but the `Notification` wrapper does not.)

### IP-1 — the Notifier effect (`shomei-core/src/Shomei/Effect/Notifier.hs`, new)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The notification effect (IP-1): hand a 'Notification' (an email-verification or
password-reset link) to a sender. The core defines only the shape; the one built-in sender —
the dev log-only interpreter — lives in @shomei-server@'s @Shomei.Notify@, and a
list-capturing interpreter for tests lives in @Shomei.Effect.InMemory@. Shōmei does not deliver
email: an operator forwards the 'Notification' to their own provider by supplying their own
interpreter of this effect.
-}
module Shomei.Effect.Notifier (
    Notifier (..),
    sendNotification,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Notification (Notification)

data Notifier :: Effect where
    SendNotification :: Notification -> Notifier m ()

type instance DispatchOf Notifier = Dynamic

sendNotification :: (Notifier :> es) => Notification -> Eff es ()
sendNotification = send . SendNotification
```

### IP-2 — the two store effects (new)

`shomei-core/src/Shomei/Effect/VerificationTokenStore.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

module Shomei.Effect.VerificationTokenStore (
    VerificationTokenStore (..),
    createVerificationToken,
    findVerificationTokenByHash,
    consumeVerificationToken,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.OneTimeToken (OneTimeTokenHash)
import Shomei.Domain.VerificationToken (NewVerificationToken, PersistedVerificationToken)
import Shomei.Id (VerificationTokenId)

data VerificationTokenStore :: Effect where
    CreateVerificationToken :: NewVerificationToken -> VerificationTokenStore m PersistedVerificationToken
    FindVerificationTokenByHash :: OneTimeTokenHash -> VerificationTokenStore m (Maybe PersistedVerificationToken)
    ConsumeVerificationToken :: VerificationTokenId -> UTCTime -> VerificationTokenStore m ()

type instance DispatchOf VerificationTokenStore = Dynamic

createVerificationToken :: (VerificationTokenStore :> es) => NewVerificationToken -> Eff es PersistedVerificationToken
createVerificationToken = send . CreateVerificationToken

findVerificationTokenByHash :: (VerificationTokenStore :> es) => OneTimeTokenHash -> Eff es (Maybe PersistedVerificationToken)
findVerificationTokenByHash = send . FindVerificationTokenByHash

consumeVerificationToken :: (VerificationTokenStore :> es) => VerificationTokenId -> UTCTime -> Eff es ()
consumeVerificationToken i t = send (ConsumeVerificationToken i t)
```

`shomei-core/src/Shomei/Effect/PasswordResetTokenStore.hs` is identical in form with
`PasswordResetTokenId`/`PersistedPasswordResetToken`/`NewPasswordResetToken` and the smart
constructors `createPasswordResetToken`, `findPasswordResetTokenByHash`,
`consumePasswordResetToken`.

### Extend `Shomei.Effect.UserStore` and `Shomei.Effect.RefreshTokenStore`

In `shomei-core/src/Shomei/Effect/UserStore.hs`, add to the GADT and exports:

```haskell
    MarkUserEmailVerified :: UserId -> UTCTime -> UserStore m ()
-- and the smart constructor:
markUserEmailVerified :: (UserStore :> es) => UserId -> UTCTime -> Eff es ()
markUserEmailVerified uid t = send (MarkUserEmailVerified uid t)
```

In `shomei-core/src/Shomei/Effect/RefreshTokenStore.hs`, add:

```haskell
    RevokeAllUserRefreshTokens :: UserId -> UTCTime -> RefreshTokenStore m ()
-- and the smart constructor:
revokeAllUserRefreshTokens :: (RefreshTokenStore :> es) => UserId -> UTCTime -> Eff es ()
revokeAllUserRefreshTokens uid t = send (RevokeAllUserRefreshTokens uid t)
```

This needs `UserId` imported in `RefreshTokenStore` (it already imports `SessionId`,
`RefreshTokenId` from `Shomei.Id`).

### Extend `Shomei.Domain.User`

Add `emailVerifiedAt :: !(Maybe UTCTime)` to the `User` record (NOT to `NewUser` — a fresh user
is always unverified). Every place that constructs a `User` (the in-memory and PostgreSQL
`CreateUser` interpreters) sets `emailVerifiedAt = Nothing`.

### IP-3 — extend `Shomei.Config` (append-only)

Add a new sub-record and a `notifierConfig` field; extend `defaultShomeiConfig`. Per the IP-3
rule, this is *additive* and defaulted so older config files still parse.

```haskell
-- Email sending is descoped (2026-06-17): the log sender is the only built-in, so this enum
-- has a single constructor. It stays an enum (not a bare flag) so a future built-in — e.g. a
-- `shomei-email` provider — can be added without reshaping NotifierConfig. The implemented
-- name is `LogNotifier` (this listing predates that rename).
data NotifierTransport = LogNotifier
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NotifierConfig = NotifierConfig
    { emailVerificationRequired :: !Bool
    -- ^ if True, the server requires a verified email for protected operations
    , verificationTokenTTL :: !NominalDiffTime
    , passwordResetTokenTTL :: !NominalDiffTime
    , notifierTransport :: !NotifierTransport
    , linkBaseUrl :: !Text
    -- ^ e.g. "https://app.example.com"; senders build links as <base>/verify-email?token=…
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- Add to ShomeiConfig:
--   , notifierConfig :: !NotifierConfig

defaultVerificationTokenTTL, defaultPasswordResetTokenTTL :: NominalDiffTime
defaultVerificationTokenTTL = 24 * 60 * 60   -- 24 hours
defaultPasswordResetTokenTTL = 60 * 60       -- 1 hour

defaultNotifierConfig :: NotifierConfig
defaultNotifierConfig = NotifierConfig
    { emailVerificationRequired = False
    , verificationTokenTTL = defaultVerificationTokenTTL
    , passwordResetTokenTTL = defaultPasswordResetTokenTTL
    , notifierTransport = LogNotifier
    , linkBaseUrl = "http://localhost:8080"
    }

-- In defaultShomeiConfig, add:  notifierConfig = defaultNotifierConfig
```

Export `NotifierConfig (..)`, `NotifierTransport (..)`, `defaultNotifierConfig`,
`defaultVerificationTokenTTL`, `defaultPasswordResetTokenTTL` from `Shomei.Config`.

### Extend `Shomei.Error`

Add three `AuthError` variants:

```haskell
    | VerificationTokenInvalid     -- unknown/consumed/revoked/expired verification token
    | PasswordResetTokenInvalid    -- unknown/consumed/revoked/expired reset token
    | EmailAlreadyVerified         -- requesting verification when already verified
```

`VerificationTokenInvalid`/`PasswordResetTokenInvalid` are deliberately generic (they do not
distinguish "unknown" from "expired") so a confirm endpoint cannot be used as an oracle.

### Extend `Shomei.Domain.Event`

Add four `*Data` records and `AuthEvent` arms (all `deriving (Generic, Eq, Show)` +
`(FromJSON, ToJSON)`), following the existing `*Data` style (carry the relevant ids + email +
`occurredAt`):

```haskell
data EmailVerificationRequestedData = EmailVerificationRequestedData
    { userId :: !UserId, email :: !Email, occurredAt :: !UTCTime } …
data EmailVerifiedData = EmailVerifiedData
    { userId :: !UserId, occurredAt :: !UTCTime } …
data PasswordResetRequestedData = PasswordResetRequestedData
    { email :: !Email, occurredAt :: !UTCTime } …   -- NB: no userId, to avoid leaking existence in logs
data PasswordResetCompletedData = PasswordResetCompletedData
    { userId :: !UserId, occurredAt :: !UTCTime } …

-- AuthEvent arms:
--   | EmailVerificationRequested EmailVerificationRequestedData
--   | EmailVerified EmailVerifiedData
--   | PasswordResetRequested PasswordResetRequestedData
--   | PasswordResetCompleted PasswordResetCompletedData
```

The PostgreSQL `AuthEventPublisher` interpreter (already in `shomei-postgres`) projects each
`AuthEvent` constructor to `(user_id?, session_id?, event_type, toJSON payload, occurredAt)`;
the new arms slot in there with `event_type` strings like `"email_verified"` (extend that
interpreter's projection function when M2 lands the new arms — `cabal build shomei-postgres`
will fail with a non-exhaustive-pattern warning-as-error until you do, which is the reminder).

### The five account workflows (`shomei-core/src/Shomei/Workflow/Account.hs`, new)

Each workflow is a function over the effect interfaces returning `Eff es (Either AuthError <result>)`,
following the patterns in `shomei-core/src/Shomei/Workflow.hs` (which to read first).
The command records (place them in `Shomei.Domain.Command` alongside the existing
`SignupCommand`/`LoginCommand`, or define them locally in the workflow module):

```haskell
newtype RequestEmailVerification = RequestEmailVerification { email :: Email }
newtype ConfirmEmailVerification = ConfirmEmailVerification { token :: OneTimeToken }
newtype RequestPasswordReset = RequestPasswordReset { email :: Email }
data ConfirmPasswordReset = ConfirmPasswordReset { token :: OneTimeToken, newPassword :: PlainPassword }
data ChangePassword = ChangePassword { userId :: UserId, currentPassword :: PlainPassword, newPassword :: PlainPassword }
```

Behavioural contract (the rules, in prose):

- **`requestEmailVerification cfg cmd`** — effects: `UserStore`, `TokenGen`,
  `VerificationTokenStore`, `Notifier`, `AuthEventPublisher`, `Clock`. Normalize the email,
  look up the user. If absent, return `Right ()` (no leak). If present and already verified
  (`emailVerifiedAt /= Nothing`), return `Right ()` (idempotent; optionally
  `Left EmailAlreadyVerified` if `emailVerificationRequired` — keep it `Right ()` for the MVP).
  Otherwise: `raw <- generateOpaqueToken`, `h <- hashRefreshToken raw`, create a
  `NewVerificationToken` (TTL from `cfg.notifierConfig.verificationTokenTTL`),
  `sendNotification (EmailVerificationRequested user.email (toOTT raw) expiry)`, publish
  `EmailVerificationRequested`, return `Right ()`.
- **`confirmEmailVerification cfg cmd`** — effects: `VerificationTokenStore`, `UserStore`,
  `AuthEventPublisher`, `Clock`. Hash the presented token, find the row. If absent, or status
  `/= OneTimeTokenActive`, or `expiresAt <= now`, return `Left VerificationTokenInvalid`.
  Otherwise: `consumeVerificationToken` the row, `markUserEmailVerified row.userId now`, publish
  `EmailVerified`, return `Right ()`.
- **`requestPasswordReset cfg cmd`** — effects: `UserStore`, `TokenGen`,
  `PasswordResetTokenStore`, `Notifier`, `AuthEventPublisher`, `Clock`. Same generic-response
  shape as `requestEmailVerification`: look up the user; on absence return `Right ()` and emit
  nothing; on presence mint a reset token (TTL `cfg.notifierConfig.passwordResetTokenTTL`),
  send `PasswordResetRequested`, publish `PasswordResetRequested`, return `Right ()`.
- **`confirmPasswordReset cfg cmd`** — effects: `PasswordResetTokenStore`, `UserStore`,
  `CredentialStore`, `PasswordHasher`, `SessionStore`, `RefreshTokenStore`,
  `AuthEventPublisher`, `Clock`. Validate the token exactly as confirm-verification (generic
  `Left PasswordResetTokenInvalid` on any failure). Validate the new password against
  `cfg.passwordPolicy` (`Left (WeakPassword …)` on failure). Then: hash the new password
  (`hashPassword`), `updatePasswordHash row.userId newHash`, `consumePasswordResetToken` the
  token, **`revokeAllUserSessions row.userId now`** and **`revokeAllUserRefreshTokens
  row.userId now`**, publish `PasswordResetCompleted`, return `Right ()`.
- **`changePassword cfg cmd`** — effects: `UserStore`, `CredentialStore`, `PasswordHasher`,
  `SessionStore`, `RefreshTokenStore`, `AuthEventPublisher`, `Clock`. Look up the user's
  credential; verify `currentPassword` against the stored hash (`Left InvalidCredentials` on
  mismatch — the generic credential error). Validate the new password against the policy. Then
  hash and `updatePasswordHash`, revoke all the user's sessions and refresh tokens, publish
  `PasswordChanged` (the existing event), return `Right ()`.

Use the existing `runErrorNoCallStack`/`throwError` short-circuit style from `Shomei.Workflow`
for the validation-heavy workflows, or explicit `case` analysis for the token-validation ones —
match whichever reads more clearly, as the existing module does. The unexported `toOTT`/`toOTTH`
converters rewrap `RefreshToken`/`RefreshTokenHash` `Text` into `OneTimeToken`/`OneTimeTokenHash`.

### In-memory interpreter additions (`Shomei.Effect.InMemory`)

Add to `World` (and `emptyWorld`):

```haskell
    , verificationTokens :: !(Map VerificationTokenId PersistedVerificationToken)
    , verificationByHash :: !(Map OneTimeTokenHash VerificationTokenId)
    , passwordResetTokens :: !(Map PasswordResetTokenId PersistedPasswordResetToken)
    , passwordResetByHash :: !(Map OneTimeTokenHash PasswordResetTokenId)
    , sentNotifications :: ![Notification]   -- newest-first
```

Add `runVerificationTokenStore`, `runPasswordResetTokenStore` (mirroring
`runRefreshTokenStore`: `Create…` allocates an id via `genVerificationTokenId`/
`genPasswordResetTokenId` and inserts into both maps; `Find…ByHash` looks up via the hash map;
`Consume…` adjusts status to `OneTimeTokenConsumed` and sets `consumedAt`), and `runNotifier`
(`SendNotification n -> modifyIORef' ref (#sentNotifications %~ (n :))`). Extend `runUserStore`'s
`CreateUser` to set `emailVerifiedAt = Nothing` and add the `MarkUserEmailVerified uid t`
case (`#users %~ Map.adjust (#emailVerifiedAt .~ Just t) uid`). Extend `runRefreshTokenStore`
with `RevokeAllUserRefreshTokens uid t` — but note: refresh-token rows are keyed by session, so
to revoke "all the user's" tokens, the interpreter must look up which sessions belong to the
user (`#sessions` map) and revoke tokens for those sessions. (The PostgreSQL version does this
with a `WHERE session_id IN (SELECT session_id FROM shomei.shomei_sessions WHERE user_id = $1)`
subquery — see below.) Add `Notifier`, `VerificationTokenStore`, `PasswordResetTokenStore` to
the `runInMemory` effect-row and interpreter stack.

### IP-7 — the three migrations (new files under `shomei-migrations/sql-migrations/`)

`<ts>-shomei-users-email-verified.sql` (additive column, defaulted NULL):

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

ALTER TABLE shomei_users
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz NULL;
```

`<ts>-shomei-email-verification-tokens.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_email_verification_tokens (
  verification_token_id uuid PRIMARY KEY,
  user_id               uuid NOT NULL REFERENCES shomei_users(user_id),
  token_hash            text NOT NULL UNIQUE,
  status                text NOT NULL,
  created_at            timestamptz NOT NULL,
  expires_at            timestamptz NOT NULL,
  consumed_at           timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_email_verification_tokens_user_id_idx
  ON shomei_email_verification_tokens (user_id);
CREATE INDEX IF NOT EXISTS shomei_email_verification_tokens_status_idx
  ON shomei_email_verification_tokens (status);
```

`<ts>-shomei-password-reset-tokens.sql` (identical shape, different table name):

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_password_reset_tokens (
  password_reset_token_id uuid PRIMARY KEY,
  user_id                 uuid NOT NULL REFERENCES shomei_users(user_id),
  token_hash              text NOT NULL UNIQUE,
  status                  text NOT NULL,
  created_at              timestamptz NOT NULL,
  expires_at              timestamptz NOT NULL,
  consumed_at             timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_password_reset_tokens_user_id_idx
  ON shomei_password_reset_tokens (user_id);
CREATE INDEX IF NOT EXISTS shomei_password_reset_tokens_status_idx
  ON shomei_password_reset_tokens (status);
```

### PostgreSQL interpreters (mirror `Shomei.Postgres.RefreshTokenStore`)

`shomei-postgres/src/Shomei/Postgres/VerificationTokenStore.hs` follows
`RefreshTokenStore.hs` exactly. The row type, the four statements, and the interpreter:

```haskell
type VerificationTokenRow = (UUID, UUID, Text, Text, UTCTime, UTCTime, Maybe UTCTime)

-- CreateVerificationToken: allocate id, INSERT 7 columns (use contrazip7).
-- FindVerificationTokenByHash: SELECT … WHERE token_hash = $1 (D.rowMaybe).
-- ConsumeVerificationToken: UPDATE … SET status = 'consumed', consumed_at = $2 WHERE verification_token_id = $1.
```

Use `oneTimeTokenStatusToText`/`oneTimeTokenStatusFromText` (added to `Shomei.Postgres.Codec`,
mapping `OneTimeTokenActive`→`"active"`, `OneTimeTokenConsumed`→`"consumed"`,
`OneTimeTokenRevoked`→`"revoked"`, `OneTimeTokenExpired`→`"expired"`), and the
`verificationTokenIdToUUID`/`…FromUUID` and `userIdToUUID`/`…FromUUID` converters. Map a
`Left UsageError` to `throwError (InternalAuthError …)` exactly as the refresh-token interpreter
does. `shomei-postgres/src/Shomei/Postgres/PasswordResetTokenStore.hs` is identical
with the reset id/types and the `shomei_password_reset_tokens` table.

The PostgreSQL `RevokeAllUserRefreshTokens` (added to
`shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`) is one statement:

```sql
UPDATE shomei.shomei_refresh_tokens
SET status = 'revoked', revoked_at = $2
WHERE session_id IN (SELECT session_id FROM shomei.shomei_sessions WHERE user_id = $1)
```

And `MarkUserEmailVerified` (added to
`shomei-postgres/src/Shomei/Postgres/UserStore.hs`):

```sql
UPDATE shomei.shomei_users SET email_verified_at = $2, updated_at = $2 WHERE user_id = $1
```

Widen `UserRow` to `(UUID, Text, Maybe Text, Text, Maybe UTCTime, UTCTime, UTCTime)` (the new
`email_verified_at` slot), add `D.column (D.nullable D.timestamptz)` to `userRowDecoder`, add it
to both `SELECT` column lists and the `INSERT` (use `contrazip7`, passing `Nothing` for the new
user), and set `emailVerifiedAt` in `rebuildUser`/`mkUser`.

### IP-5 — DTOs and routes (extend `shomei-servant`, after EP-5)

Request DTOs (each `deriving anyclass (FromJSON, ToJSON)` with EP-5's JSON conventions):

```haskell
newtype VerifyEmailRequestBody   = VerifyEmailRequestBody   { email :: Text }
newtype VerifyEmailConfirmBody   = VerifyEmailConfirmBody   { token :: Text }
newtype PasswordResetRequestBody = PasswordResetRequestBody { email :: Text }
data    PasswordResetConfirmBody = PasswordResetConfirmBody { token :: Text, newPassword :: Text }
data    PasswordChangeBody       = PasswordChangeBody       { currentPassword :: Text, newPassword :: Text }
```

(Passwords arrive as `Text` in the DTO and are wrapped into `PlainPassword` in the handler,
matching how EP-5 maps `SignupRequest.password`.) Add five fields to the `ShomeiAPI` NamedRoutes
record; the four request/confirm routes return `202 Accepted` (or EP-5's no-content response
type) and `password/change` is wrapped in EP-5's auth combinator (the one guarding
`GET /auth/me`), receiving the authenticated `UserId` from the access-token claims so the
handler builds `ChangePassword claims.subject …`.

### The `Notifier` sender (`shomei-server/src/Shomei/Notify.hs`, after EP-6)

```haskell
runNotifierLog        :: (IOE :> es) => NotifierConfig -> Eff (Notifier : es) a -> Eff es a
runNotifierFromConfig :: (IOE :> es) => ShomeiConfig  -> Eff (Notifier : es) a -> Eff es a
```

`runNotifierLog` renders each `Notification` to one log line that includes the full link
(`cfg.publicBaseUrl <> "/auth/verify-email/confirm?token=" <> rawToken` for verification,
`"/auth/password-reset/confirm?token=" <> rawToken` for reset) and the expiry — this is what
the curl walkthrough greps for. `runNotifierFromConfig` dispatches on
`cfg.notifierConfig.notifierTransport`, which has the single value `LogNotifier`.

**There is no SMTP sender** (email sending descoped 2026-06-17). Shōmei does not deliver email:
an operator who wants real delivery writes their own `Notifier` interpreter that forwards the
`Notification` to their provider (SendGrid, Resend, SES, an SMTP relay, …) and wires it into
their own server assembly in place of `runNotifierLog`; a future `shomei-email` package may
package such senders in-tree.


## Revision Notes

2026-06-04: Updated after the package-layout refactor and MasterPlan audit. Package paths now
refer to top-level directories, effect modules use `Shomei.Effect.*`, and the precondition
reflects that MasterPlan 1's JWT, Servant, server, client, and demo packages are implemented.

2026-06-17: **Descoped email sending; EP-1 marked Complete.** Per the user's decision, Shōmei is
not responsible for delivering email — the `Shomei.Effect.Notifier` effect is the integration
seam, the shipped server emits the notification and logs the link, and operators forward it to
their own provider; a future `shomei-email` package may add in-tree senders. Removed the
`SmtpNotifier` constructor and `runNotifierSmtp` stub from the code (`NotifierTransport =
LogNotifier` is the sole built-in; `Shomei.Notify` exposes only `runNotifierLog`). Updated
Purpose, Milestone M4 (M4.1b/M4.3 marked descoped), Progress, Surprises, the Decision Log
(original SMTP-module decision annotated + a new descoping decision), Outcomes & Retrospective,
the IP-1 quote, the Plan-of-Work/Concrete-Steps M4 prose, and the Interfaces contract
(`Notification`/`Notifier` doc comments, `NotifierTransport`, the sender signatures). `cabal
build all` / `cabal test all` are green and fourmolu is clean. This plan's parent MasterPlan
(`docs/masterplans/2-…`) was updated in lockstep.
