---
id: 30
slug: login-timing-oracle-fix-email-verification-enforcement-and-notifier-token-redaction
title: "Login Timing-Oracle Fix, Email-Verification Enforcement, and Notifier Token Redaction"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md"
---

# Login Timing-Oracle Fix, Email-Verification Enforcement, and Notifier Token Redaction

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. This plan groups three small, independent
workflow-level fixes from the July 2026 security review — none needs a schema change or an
API-shape change, and together they make three documented behaviors actually true:

1. **Close the login timing oracle.** `docs/user/security.md` promises "no
   account-existence leakage": a wrong password and an unknown account both return the same
   generic `401 invalid_login`. The *bytes* are identical, but the *time* is not: the
   wrong-password path runs Argon2id — a deliberately expensive password hash tuned here to
   3 iterations × 64 MiB, costing roughly 50–150 ms — while the unknown-account path skips
   hashing entirely and fails in microseconds. An attacker who measures response time can
   therefore enumerate which login identifiers exist. Fix: the miss paths verify the
   presented password against a fixed, well-formed *dummy* Argon2id hash, so every failed
   login pays the same hashing cost.
2. **Make `emailVerificationRequired` real.** The configuration flag
   `notifierConfig.emailVerificationRequired` exists, is documented, is parsed from both
   the Dhall config file and the environment — and is consumed by nothing. Operators who
   set it believe unverified accounts cannot log in; in reality nothing changes. Fix: when
   the flag is set, token issuance is refused for accounts whose email is present but
   unverified (`emailVerifiedAt = Nothing`) — at password login, at refresh, and at the
   passkey login paths — with a distinct `403 email_not_verified` error.
3. **Stop logging live one-time tokens.** The built-in development notifier
   (`LogNotifier`) writes the complete password-reset / email-verification link — including
   the raw one-time token — to the server log. Anyone with log access can take over any
   account mid-reset. Fix: log only an 8-hex-character SHA-256 prefix of the token (enough
   to correlate with the database's stored hash trail) plus metadata; an explicit opt-in
   (`SHOMEI_NOTIFIER_LOG_SECRETS=true`) restores full links for local development.

This plan also folds in one documentation task the MasterPlan assigned here: recording in
`docs/user/security.md` that signup *deliberately* discloses account existence
(`409 email_taken` / `login_id_taken`) while the reset/verify request flows remain blind
`202`s — an accepted asymmetry, not an oversight.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] (a) `dummyPasswordHash` constant generated with production Argon2id parameters and
      committed to `Shomei.Domain.Password` with provenance comment. (2026-07-08)
- [x] (a) `login` miss paths (no credential; credential without user; inactive user) verify
      against the dummy hash before failing; core tests with a counting hasher pass. (2026-07-08)
- [x] (b) `EmailNotVerified` added to `AuthError` and mapped to `403 email_not_verified`. (2026-07-08)
- [x] (b) Enforcement in `login` (password path), `refresh`, `Mfa.completeMfa`, and
      `Mfa.completePasswordlessLogin`; core tests pass (blocked unverified, allowed
      verified, allowed no-email, unblocked after confirmation). (2026-07-08)
- [x] (b) Servant error-mapping covered; servant E2E extended with an
      `emailVerificationRequired` scenario. (2026-07-08)
- [x] (c) `NotifierConfig.logRawTokens` added (default `False`);
      `SHOMEI_NOTIFIER_LOG_SECRETS` env override wired in `Shomei.Server.Config`. (2026-07-08)
- [x] (c) `Shomei.Notify.renderNotification` redacts (SHA-256 8-hex prefix, no link) unless
      `logRawTokens`; unit tests assert the raw token never appears in redacted output. (2026-07-08)
- [x] Docs: `docs/user/security.md` — timing-equalization note, `emailVerificationRequired`
      semantics, notifier redaction, signup-existence asymmetry paragraph;
      `docs/user/api.md` — `403 email_not_verified` on the affected endpoints;
      `docs/user/deployment.md`/`docs/user/notifications.md` — the new env flag. (2026-07-08)
- [x] `cabal build all` and `cabal test all` green; living sections updated; Outcomes
      written. (2026-07-08)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The malformed-hash short-circuit is real and dramatic; the dummy is indistinguishable from
  a real hash.** Measured in `cabal repl shomei-postgres` on this machine:

  ```text
  dummy     0.101408s result=False
  malformed 0.000009s result=False
  real      0.183407s result=False
  ```

  The 0.18 s is first-call warm-up; re-measured with the order swapped, steady state is
  `real 0.093s` / `dummy 0.095s` — indistinguishable, which is the whole point. A malformed
  constant would answer in 9 µs and silently reopen the oracle the constant exists to close.
  This is why `dummyPasswordHash`'s haddock carries a MUST about format validity.

- **The plan's `TimingSpec` design was validated by running it against the unfixed code**, as
  the plan asked. Before the fix, two of the four cases fail with `counter == 0`:

  ```text
  unknown login id still verifies a password (dummy hash): FAIL  expected: 1
  wrong password verifies exactly once:                    OK
  suspended account still verifies a password:             FAIL  expected: 1
  successful login verifies exactly once:                  OK
  ```

  Note the suspended-account case fails too — confirming the Decision Log's judgment that the
  finding's "unknown login id" framing understated the oracle.

- **`Shomei.Effect.InMemory` did not export `runTokenSigner`/`runTokenVerifier`,** although its
  module haddock advertises the individual interpreters precisely so an assembly can compose a
  hybrid stack. `TimingSpec` needs them to rebuild `runInMemory` with a counting hasher in the
  `PasswordHasher` slot, so both are now exported. Any future spec that swaps one interpreter
  can do the same.

- **`Shomei.Workflow` had to add `NotifierConfig (..)` to its `Shomei.Config` import** before
  `cfg.notifierConfig.emailVerificationRequired` would resolve — the `DuplicateRecordFields` /
  `HasField` interaction this repo has hit before (MasterPlan 3, EP-1). Dot access on a record
  needs that record's field selectors in scope, not just its type.

- **There is no `SHOMEI_EMAIL_VERIFICATION_REQUIRED` environment variable.** The flag is
  settable only through the Dhall config file's `emailVerificationRequired` key (and the library
  API). An early draft of the security.md paragraph invented the env var; it was corrected after
  `rg -n "EMAIL_VERIFICATION" --type haskell` found nothing. Adding one would be a reasonable
  follow-up but is out of scope here.

- **`docs/user/notifications.md` contained a claim the redaction falsified:** "your only
  built-in option is to scrape the structured log line (it carries the recipient, the confirm
  link, and the expiry)". That paragraph now describes the redacted line and points at
  `SHOMEI_NOTIFIER_LOG_SECRETS`. Grep for downstream docs before changing a log format.

- **The hash-prefix correlation was verified against a live database**, not just asserted:

  ```text
  raw token from log:        7Hu0OCrgi1FvA6ql4NJHgzWhBcxqFiUBdbwMMMIHbjQ
  sha256 hex prefix:         f8eb15bb          <- what the redacted log line prints
  stored token_hash:         -OsVu7iiat44pDezxBOuDEnEwtHmKX3dO1tRAFgHZIc
  sha256 of raw as b64url:   -OsVu7iiat44pDezxBOuDEnEwtHmKX3dO1tRAFgHZIc
  ```

  Same digest, two encodings — so an operator can tie a redacted log line to its row.


## Decision Log

Record every decision made while working on the plan.

- Decision: The timing fix is validated with an **effect-level invocation counter** (a test
  interpreter that counts `VerifyPassword` calls), not wall-clock assertions.
  Rationale: the security property is "every failed login performs exactly one password
  verification", which the counter asserts deterministically. A wall-clock test of Argon2id
  (50–150 ms) is inherently flaky in CI and adds seconds per run. The real-cost equivalence
  follows from the counter property plus the fact that the dummy hash uses the production
  parameters — verified once by hand (a note in Surprises & Discoveries) rather than by a
  permanent flaky test.
  Date: 2026-07-07

- Decision: The dummy hash is a **constant** `dummyPasswordHash :: PasswordHash` in
  `shomei-core/src/Shomei/Domain/Password.hs`, generated once (instructions in Concrete
  Steps) with the exact Argon2id parameters from
  `shomei-postgres/src/Shomei/Crypto.hs` (`argonOptions`: Argon2id, iterations 3, memory
  64 MiB, parallelism 1) over a throwaway random password that is then discarded.
  Rationale: `PasswordHash` is an opaque `Text` newtype owned by the core, so the core may
  carry the value without importing crypto; the *format* (`argon2id$<b64salt>$<b64hash>`)
  must be well-formed because `verifyPasswordArgon2id` short-circuits (returns `False`
  without hashing) on a malformed string — a malformed dummy would silently reintroduce the
  oracle. Generating per-boot instead was rejected: it adds a startup dependency and gains
  nothing (the value is public-safe; nobody knows a preimage, and even a known preimage
  only lets an attacker *match* the dummy timing, which is already the goal). The in-memory
  fake hasher (`Shomei.Effect.InMemory.runPasswordHasher`) needs no change: it compares
  tags and returns `False` for the dummy, which is correct — in tests only the *invocation*
  is observed.
  Date: 2026-07-07

- Decision: Also dummy-verify on the two other early-exit login paths: a credential row
  whose user row is missing, and (before throwing `UserNotActive`) an inactive user.
  Rationale: the finding names the unknown-login-id path, but any pre-hash exit is the same
  oracle shape; a suspended account exiting in microseconds leaks "exists but suspended"
  through the same `401`. One extra `verifyPassword` call on rare paths is free.
  Date: 2026-07-07

- Decision: `emailVerificationRequired` blocks issuance with a **distinct**
  `EmailNotVerified` error → `403 {"error":"email_not_verified"}`, not the generic
  `InvalidCredentials`.
  Rationale: weighing enumeration leakage — on every gated path the account's existence is
  already confirmed to the caller (correct password at login; a valid refresh token at
  refresh; a verified passkey assertion at the passkey paths), so a distinct error leaks
  nothing new, while a generic 401 would strand legitimate users with no way to know they
  must click the verification link. 403 (not 401) because the credential was *correct*;
  the account is simply not yet eligible.
  Date: 2026-07-07

- Decision: The gate applies only to accounts that **have** an email
  (`user.email = Just _`); login-id-only accounts (Shōmei supports optional email) are
  exempt.
  Rationale: an account with no email address can never complete email verification;
  gating it would permanently brick loginId-only deployments that also want the flag for
  their email accounts. Documented in `docs/user/security.md`.
  Date: 2026-07-07

- Decision: `signup` still issues its initial token pair even when
  `emailVerificationRequired` is set; enforcement begins at the first *refresh* or
  *re-login*.
  Rationale: blocking at signup would change the `POST /auth/signup` response shape
  (`SignupResponse.token` is mandatory), a breaking wire change out of proportion to this
  plan. The exposure is bounded: the unverified window is one access-token lifetime
  (default 15 min) because the refresh gate closes silent renewal. This is the documented
  semantics ("verification is required to *keep* using the account"); a stricter
  no-token-at-signup mode can be a follow-up if operators ask.
  Date: 2026-07-07

- Decision: In `refresh`, the user row is looked up **only when the flag is enabled**, and
  a missing user row maps to `SessionNotFound`.
  Rationale: refresh currently never touches the user table; making every refresh pay an
  extra query for a feature most deployments leave off would be a gratuitous regression.
  A session whose user row is gone is corrupt state; `SessionNotFound` (404) is the
  existing least-leaking fit.
  Date: 2026-07-07

- Decision: Notifier redaction logs `Text.take 8 (sha256Hex token)` plus recipient and
  expiry, and drops the clickable link entirely; the escape hatch is a new
  `NotifierConfig.logRawTokens :: Bool` (default `False`), set only via
  `SHOMEI_NOTIFIER_LOG_SECRETS=true` (env) — deliberately *not* exposed in the Dhall file.
  Rationale: an 8-hex prefix (32 bits) is plenty for log correlation and useless for
  takeover (the token is 32 random bytes). The escape hatch is warranted because
  `LogNotifier`'s documented purpose is development, where the logged link is *how you
  complete the flow*; without it, dev signup/reset flows dead-end. Keeping it env-only
  makes it an explicit per-process decision that cannot linger silently in a committed
  config file. SHA-256 (via the existing `Shomei.Crypto.sha256Hex`) matches how one-time
  tokens are already hashed at rest, so the log prefix correlates with the stored
  `token_hash` column (both are SHA-256 of the token, hex vs base64url encodings — note
  this in the log-line docs).
  Date: 2026-07-07

- Decision: Signup existence disclosure (`409 email_taken` / `login_id_taken`) stays as-is
  and gets documented, per the MasterPlan Decision Log (2026-07-07).
  Rationale: standard signup UX; rated Low by the review; the deliberately non-enumerating
  reset/verify flows are unaffected. This plan only writes the paragraph.
  Date: 2026-07-07

- Decision: Export `runTokenSigner`/`runTokenVerifier` from `Shomei.Effect.InMemory`.
  Rationale: `TimingSpec` composes the `runInMemory` stack with one interpreter replaced, which
  is exactly the hybrid-assembly use the module's haddock already advertises for its other
  interpreters. These two were omitted from the export list by oversight.
  Date: 2026-07-08

- Decision: The redacted notifier line carries a trailing hint,
  `(set SHOMEI_NOTIFIER_LOG_SECRETS=true to log the full link in development)`.
  Rationale: as the plan's example specified. It repeats on every line, which is mild noise, but
  the alternative is a developer hitting a dead-ended signup flow with no idea why the link
  vanished. The hint is suppressed when the flag is on.
  Date: 2026-07-08

- Decision: `EmailVerificationSpec` is a new module rather than a group inside `WorkflowSpec` or
  `AccountSpec`.
  Rationale: it needs a second `ShomeiConfig` (the gated one) plus the passkey fixtures from
  `MfaSpec`, and it asserts one coherent feature across four workflows. Bolting that onto
  `WorkflowSpec` would have mixed two configs into a module whose fixtures assume one.
  Date: 2026-07-08

- Decision: Documented `emailVerificationRequired` as Dhall-file-only; did not add an env var.
  Rationale: none exists (verified). Adding `SHOMEI_EMAIL_VERIFICATION_REQUIRED` would be a
  sensible follow-up but is scope creep here, and inventing it in prose would have shipped a
  false doc. Recorded in Surprises & Discoveries.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**All three fixes delivered, each with the behavioral evidence the plan asked for.**

1. *Timing oracle closed.* Every failing login now performs exactly one Argon2id verification,
   asserted by an invocation counter on all four paths, and the dummy hash measures within 2 ms
   of a real one. The plan's insistence that the constant stay format-valid turned out to be the
   load-bearing detail: a malformed value short-circuits in 9 µs and would have reopened the
   oracle while looking like a fix. That risk is now pinned in the constant's haddock.

2. *`emailVerificationRequired` is real.* It gates login, refresh, MFA completion, and
   passwordless passkey login, returns a distinct `403 email_not_verified`, exempts email-less
   accounts, and — verified by the untouched suites — changes nothing when off.

3. *Tokens no longer leak into logs.* `LogNotifier` prints an 8-hex SHA-256 prefix; the full link
   returns only under `SHOMEI_NOTIFIER_LOG_SECRETS=true`. The prefix was confirmed against a real
   `token_hash` row, so the correlation the Decision Log promised actually works.

**Deviations from the plan, all recorded in the Decision Log:** `Shomei.Effect.InMemory` had to
export two more interpreters; `Shomei.Workflow` needed `NotifierConfig (..)` imported for dot
access; the email tests live in their own module; and `emailVerificationRequired` is documented as
Dhall-only because the env var the plan's docs task implied does not exist.

**Gaps and follow-ups, none blocking:**

- No `SHOMEI_EMAIL_VERIFICATION_REQUIRED` env var. Every other notifier/policy knob has one, so
  this is an inconsistency worth closing — a one-line `boolEnv` in `overlayCoreFromEnv`.
- Signup still issues a token pair for an unverified account (deliberate — changing it is a wire
  change). The exposure is one access-token lifetime. A stricter no-token-at-signup mode remains
  available if operators ask.
- `completeMfa`'s gate is nearly unreachable because `login` already gates before handing out a
  ceremony id. It is kept as defense in depth, at the cost of one redundant check.
- The dummy-hash equivalence rests on the constant matching `Shomei.Crypto.argonOptions`. If
  those parameters are ever retuned, the constant must be regenerated or failed logins get
  *cheaper* than real ones — re-opening the oracle in the other direction. Nothing enforces this
  today; a test that hashes a throwaway password and compares the cost parameters embedded in the
  two strings would.

**Lesson.** Two of the three fixes were "the code does not do what the documentation says", and
in both cases the doc was the more trustworthy artifact — it described the intended security
property precisely enough to test. The third (log redaction) then *falsified* a doc elsewhere in
the tree, which nothing would have caught but grep. Changing an output format means grepping the
docs for people who told users to read it.


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project built inside a Nix devshell. Packages
touched here: `shomei-core` (pure domain + workflows + *port effects*, the `effectful`
capabilities like `PasswordHasher`, with an in-memory test interpreter in
`shomei-core/src/Shomei/Effect/InMemory.hs`), `shomei-servant` (HTTP layer; error mapping),
and `shomei-server` (standalone server: config loading, the log notifier). Tests are tasty
+ tasty-hunit; core workflow tests run against the in-memory interpreters
(`shomei-core/test/Shomei/WorkflowSpec.hs` shows the style: fresh `World` in an `IORef`,
run workflows via `runInMemory`, assert on results and world state).

Exact current state (verified against the working tree):

**(a) The login workflow** — `login` in `shomei-core/src/Shomei/Workflow.hs` (lines
192–234). The relevant sequence (lines 207–213):

```haskell
mCred <- findPasswordCredentialByLoginId cmd.loginId
cred <- maybe (failLogin rl ctx cmd.loginId ts) pure mCred
mUser <- findUserById cred.userId
user <- maybe (failLogin rl ctx cmd.loginId ts) pure mUser
when (user.status /= UserActive) (throwError UserNotActive)
ok <- verifyPassword cmd.password cred.passwordHash
unless ok (failLogin rl ctx cmd.loginId ts)
```

`failLogin` (lines 240–267) records the attempt, publishes `LoginFailed`, maybe locks the
account, and throws the generic `InvalidCredentials`. Note that on the unknown-account
branch `verifyPassword` (the `PasswordHasher` effect) is never invoked — that is the
oracle. The production interpreter is `runPasswordHasherCrypto` in
`shomei-postgres/src/Shomei/Crypto.hs`: `verifyPasswordArgon2id` splits the stored text on
`"$"` expecting `["argon2id", saltB64, hashB64]`, re-derives with `argonOptions` (Argon2id,
iterations 3, memory 64 MiB, parallelism 1 — the module comments call this out as the
deliberate cost) and compares in constant time; **on any malformed stored text it returns
`False` without hashing** — which is why the dummy must be well-formed. The in-memory fake
(`runPasswordHasher` in `InMemory.hs`) tags plaintexts: verify is
`h == "argon2-fake:" <> pw`. `PasswordHash` is a `Text` newtype in
`shomei-core/src/Shomei/Domain/Password.hs`.

**(b) The dead flag** — `emailVerificationRequired :: Bool` is a field of `NotifierConfig`
in `shomei-core/src/Shomei/Config.hs` (line 74; default `False` in `defaultShomeiConfig`).
It is plumbed from the Dhall file in `shomei-server/src/Shomei/Server/Config.hs`
(`baseFromFile`, line ~171). `rg -n "emailVerificationRequired" --type haskell` confirms no
consumer exists outside config code. `login` checks only `user.status` (line 211); `User`
(`shomei-core/src/Shomei/Domain/User.hs`) carries `email :: Maybe Email` and
`emailVerifiedAt :: Maybe UTCTime` (set by `markUserEmailVerified` when
`confirmEmailVerification` in `shomei-core/src/Shomei/Workflow/Account.hs` succeeds).
Token-issuing paths that must be gated: `login`'s non-MFA tail and MFA branch decision
(`Workflow.hs` lines 227–234), `refresh` (`Workflow.hs` lines 269–324 — note it currently
has **no** `UserStore` constraint and never loads the user), and the two passkey completers
`completeMfa` / `completePasswordlessLogin` in `shomei-core/src/Shomei/Workflow/Mfa.hs`
(both already do `findUserById` and check `UserActive`, lines ~131–133 and ~196–198).
Errors: `AuthError` in `shomei-core/src/Shomei/Error.hs`; HTTP mapping
`authErrorToServerError` in `shomei-servant/src/Shomei/Servant/Error.hs`.

**(c) The leaking notifier** — `shomei-server/src/Shomei/Notify.hs` (lines 36–55).
`renderNotification` formats, for both `EmailVerificationRequested` and
`PasswordResetRequested`, a line like:

```text
[shomei:log] password_reset email=a@example.com link=http://localhost:8080/auth/password-reset/confirm?token=<RAW TOKEN> expires_at=...
```

`oneTimeTokenText` exposes the raw secret. `docs/user/security.md`'s "Logging hygiene"
section claims no token can appear in a log line — the *request* logger honors that, but
this notifier does not. `Shomei.Crypto.sha256Hex :: Text -> Text` (lowercase hex SHA-256,
in `shomei-postgres/src/Shomei/Crypto.hs`) is already imported by `shomei-server`
(`Boot.hs` uses it), so `Notify.hs` can use it directly. One-time tokens are stored
hashed: `hashOneTimeToken` in `Workflow/Account.hs` persists the SHA-256 (base64url) of
the token in the `token_hash` columns.

Build/test commands (repository root, inside `nix develop`): `cabal build all`,
`cabal test all`, or per package (`cabal test shomei-core`, `cabal test shomei-servant`,
`cabal test shomei-server`). No database work is needed for this plan beyond what the
existing test harnesses provision themselves.

Coordination note: plan 28
(`docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`)
edits `refresh` (expiry guard, rotation CAS) and this plan adds an email-verification gate
to the same function; the hunks are disjoint (this plan's gate sits before rotation),
ordinary rebase discipline suffices.


## Plan of Work

Three independent fixes = three milestones, plus a docs milestone. Any order works;
(a) → (b) → (c) is suggested since (a) and (b) share test scaffolding in the core suite.

### Milestone M1 — equalize failed-login timing with a dummy Argon2id verification

Scope: after this milestone, every failed login — unknown identifier, dangling credential,
inactive user, wrong password — invokes the password hasher exactly once, and a counting
test proves it.

1. Generate the constant (see Concrete Steps for the exact one-liner) and add to
   `shomei-core/src/Shomei/Domain/Password.hs`:

   ```haskell
   -- | A fixed, well-formed Argon2id hash of a discarded random password, used to
   -- equalize the timing of failed logins: the unknown-account path verifies the
   -- presented password against THIS hash so it costs the same Argon2id work as the
   -- wrong-password path (closing an account-enumeration timing oracle).
   --
   -- Generated once with the production parameters in Shomei.Crypto.argonOptions
   -- (Argon2id, t=3, m=64MiB, p=1); the preimage was random and never recorded.
   -- MUST stay format-valid ("argon2id$<b64 salt>$<b64 hash>"): the Argon2id verifier
   -- returns False WITHOUT hashing on malformed input, which would silently reopen
   -- the oracle. There is deliberately no password that verifies against it in
   -- normal operation; its only job is to make the hasher do real work.
   dummyPasswordHash :: PasswordHash
   dummyPasswordHash = PasswordHash "argon2id$<b64salt>$<b64hash>"   -- paste generated value
   ```

   Export it from the module.

2. In `shomei-core/src/Shomei/Workflow.hs`, `login`: replace the three early exits so each
   burns one verification first. Import `dummyPasswordHash` from `Shomei.Domain.Password`
   (the module is already imported for `PasswordContext`/`validatePassword`; extend the
   import list):

   ```haskell
   mCred <- findPasswordCredentialByLoginId cmd.loginId
   cred <- maybe (failLoginTimed rl ctx cmd ts) pure mCred
   mUser <- findUserById cred.userId
   user <- maybe (failLoginTimed rl ctx cmd ts) pure mUser
   when (user.status /= UserActive) do
     _ <- verifyPassword cmd.password dummyPasswordHash
     throwError UserNotActive
   ok <- verifyPassword cmd.password cred.passwordHash
   unless ok (failLogin rl ctx cmd.loginId ts)
   ```

   where `failLoginTimed` is a small local helper (place it next to `failLogin`) that runs
   the dummy verification then delegates:

   ```haskell
   -- | 'failLogin' preceded by a dummy Argon2id verification, so an account-miss
   -- costs the same hashing work as a wrong password (anti-enumeration).
   failLoginTimed rl ctx cmd ts = do
     _ <- verifyPassword cmd.password dummyPasswordHash
     failLogin rl ctx cmd.loginId ts
   ```

   (add `PasswordHasher :> es` to its constraints; `login` already carries it).

3. Tests — new module `shomei-core/test/Shomei/Workflow/TimingSpec.hs` (register in
   `shomei-core.cabal` test `other-modules` and in `shomei-core/test/Main.hs`, mirroring
   `Shomei.Workflow.MfaSpec`). Build a *counting* hasher interpreter locally in the test:
   an `interpret_` wrapper matching the in-memory fake's behavior but incrementing an
   `IORef Int` on every `VerifyPassword` — then assemble a hybrid stack exactly like
   `runInMemory` but with this hasher in the `PasswordHasher` slot (the in-memory module
   exports its individual interpreters for precisely this kind of composition; copy the
   effect order from `Shomei.Effect.InMemory.runInMemory`). Cases:
   - unknown login id → result `Left InvalidCredentials`, counter `== 1`;
   - known id + wrong password → `Left InvalidCredentials`, counter `== 1`;
   - suspended user + any password → `Left InvalidCredentials` at the HTTP level
     (`UserNotActive` in core), counter `== 1`;
   - known id + correct password → `Right`, counter `== 1`.
   The first case **fails before the fix** (counter 0) — run it once against unfixed code
   and record that in Surprises & Discoveries.

4. One-time manual check (not a committed test, per the Decision Log): with the real
   hasher, measure both failure paths and confirm same-order timings; note the numbers in
   Surprises & Discoveries. Concrete Steps has the snippet.

Acceptance: `cabal test shomei-core` passes including `TimingSpec`; the counter cases
enumerate all four paths.

### Milestone M2 — enforce `emailVerificationRequired`

Scope: with the flag on, an account with an unverified email cannot obtain tokens by
password login, refresh, MFA completion, or passwordless passkey login; it can after
confirming verification. Flag off (default): zero behavior change.

1. Error: in `shomei-core/src/Shomei/Error.hs` add to `AuthError`:

   ```haskell
   | -- | Token issuance refused because runtime config requires a verified email and
     -- the account's email is present but unverified. Maps to 403. Deliberately
     -- distinct from 'InvalidCredentials': every path that can raise it has already
     -- proven account control (correct password / valid refresh token / verified
     -- passkey assertion), so no additional existence information leaks.
     EmailNotVerified
   ```

   In `shomei-servant/src/Shomei/Servant/Error.hs` add:
   `EmailNotVerified -> json err403 "email_not_verified" "Email address is not verified"`.

2. Shared guard: in `shomei-core/src/Shomei/Workflow/Session.hs` (the leaf module both
   `Workflow` and `Workflow.Mfa` already import) add and export:

   ```haskell
   -- | The emailVerificationRequired gate: called by every token-issuing path.
   -- Blocks only accounts that HAVE an email which is unverified; accounts without
   -- an email are exempt (they can never verify one). Pure Either so callers in
   -- both Error-effect and Either styles can use it.
   ensureEmailVerified :: ShomeiConfig -> User -> Either AuthError ()
   ensureEmailVerified cfg user
     | cfg.notifierConfig.emailVerificationRequired
         && isJust user.email
         && isNothing user.emailVerifiedAt =
         Left EmailNotVerified
     | otherwise = Right ()
   ```

   (import `NotifierConfig (..)` and `User (..)`; `isJust`/`isNothing` come from the
   prelude.)

3. Call sites:
   - `Shomei.Workflow.login`: after `clearAccountLockout` (password proven, success
     recorded) and *before* the MFA/issue branch, add
     `either throwError pure (ensureEmailVerified cfg user)`. Placing it before
     `prepareMfaChallenge` means an unverified account is not even offered an MFA ceremony.
   - `Shomei.Workflow.refresh`: inside the active-session branch, before rotation. Add
     `UserStore :> es` to the constraint list and (per the Decision Log) look the user up
     only when needed:

     ```haskell
     | otherwise -> do
         gate <-
           if cfg.notifierConfig.emailVerificationRequired
             then do
               mUser <- findUserById s.userId
               pure (maybe (Left SessionNotFound) (ensureEmailVerified cfg) mUser)
             else pure (Right ())
         case gate of
           Left e -> pure (Left e)
           Right () -> do
             {- existing rotation tail unchanged -}
     ```

     (`refresh` returns `Either` by explicit case analysis, so thread it as a value.)
   - `Shomei.Workflow.Mfa.completeMfa` and `completePasswordlessLogin`: immediately after
     their existing `when (userStatus /= UserActive) …` checks, add
     `either throwError pure (ensureEmailVerified cfg user)` (both run inside
     `runErrorNoCallStack`, so `throwError` is available).

4. Core tests — extend `shomei-core/test/Shomei/AccountSpec.hs` (it already exercises the
   verification flow) or add a dedicated group in `WorkflowSpec.hs`, using
   `cfg {notifierConfig = cfg.notifierConfig {emailVerificationRequired = True}}`:
   - signup (unverified) then login → `Left EmailNotVerified`;
   - signup then refresh the signup pair → `Left EmailNotVerified`;
   - request + confirm email verification (drive `requestEmailVerification`, pull the raw
     token out of `World.sentNotifications`, `confirmEmailVerification`) then login →
     `Right`;
   - a loginId-only signup (no email) logs in fine with the flag on;
   - flag off: unverified account logs in (regression anchor);
   - passwordless completion for an unverified account → `Left EmailNotVerified` (drive it
     the way `shomei-core/test/Shomei/Workflow/MfaSpec.hs` drives the fake WebAuthn
     ceremony).

5. HTTP test: extend the servant end-to-end scenario (`shomei-servant/test/Main.hs`,
   which composes hybrid in-memory + real-JWT stacks) with a short section: flag-on env,
   signup → login → expect `403` body `{"error":"email_not_verified",…}`; confirm
   verification; login → `200`.

Acceptance: `cabal test shomei-core shomei-servant` pass; with the flag off the whole
existing suite is untouched.

### Milestone M3 — redact one-time tokens in the log notifier

Scope: by default the dev notifier logs no usable secret; the opt-in restores today's
behavior verbatim.

1. Config: in `shomei-core/src/Shomei/Config.hs` add to `NotifierConfig`:

   ```haskell
   , -- | when True the LogNotifier writes the full one-time link (raw token) to the
     -- log — development convenience ONLY; default False logs a SHA-256 prefix.
     logRawTokens :: !Bool
   ```

   default `logRawTokens = False` in `defaultShomeiConfig`. Fix construction sites
   (`rg -n "NotifierConfig" --type haskell`; `Server/Config.hs` uses record *update*, so
   only literal constructions need the field).

2. Env wiring: in `shomei-server/src/Shomei/Server/Config.hs`, read
   `SHOMEI_NOTIFIER_LOG_SECRETS` with the existing `boolEnv` helper inside
   `overlayCoreFromEnv` and overlay
   `notifierConfig = base.notifierConfig {logRawTokens = fromMaybe … }`. Deliberately no
   Dhall-file field (Decision Log).

3. `shomei-server/src/Shomei/Notify.hs`: import `Shomei.Crypto (sha256Hex)` and
   `Data.Text qualified as Text` (already imported); rewrite `renderNotification` to
   branch on `cfg.logRawTokens` — `True` keeps today's exact format; `False` renders:

   ```text
   [shomei:log] password_reset email=a@example.com token_sha256=3f9a01bc expires_at=2026-07-08 12:00:00 UTC (set SHOMEI_NOTIFIER_LOG_SECRETS=true to log the full link in development)
   ```

   with `token_sha256 = Text.unpack (Text.take 8 (sha256Hex (oneTimeTokenText token)))`,
   and the same shape for `email_verification`. No URL is printed in redacted mode (a
   link minus its token is noise). Export `renderNotification` for tests.

4. Tests: in the `shomei-server` test suite (alongside
   `shomei-server/test/Shomei/Server/ConfigSpec.hs`, add `NotifySpec.hs` registered the
   same way): build a `Notification` with a known token text, render with
   `logRawTokens = False`, assert the output does **not** contain the token text, does
   contain the first 8 chars of `sha256Hex token`, and does not contain `"token="`; render
   with `True` and assert the full link is present (format regression). Also a ConfigSpec
   case: `SHOMEI_NOTIFIER_LOG_SECRETS=true` sets the field (use the suite's existing
   env-manipulation pattern).

Acceptance: `cabal test shomei-server` passes; a manual dev-server run (Concrete Steps)
shows the redacted line.

### Milestone M4 — documentation

Scope: make the docs match the new reality, including the folded-in asymmetry note.

- `docs/user/security.md`:
  - "No account-existence leakage": add that failure paths are also *timing*-equalized —
    an unknown identifier performs a dummy Argon2id verification so it costs the same as a
    wrong password.
  - New short subsection "Email verification enforcement": semantics of
    `emailVerificationRequired` (gates login/refresh/passkey issuance for accounts with an
    unverified email; email-less accounts exempt; signup's initial pair allowed, dies at
    first refresh; distinct `403 email_not_verified`, and why that is not an enumeration
    leak).
  - "Logging hygiene": note the notifier now logs only a SHA-256 prefix of one-time
    tokens, and the dev-only `SHOMEI_NOTIFIER_LOG_SECRETS` opt-in.
  - New paragraph (per the MasterPlan Decision Log): signup deliberately discloses
    existence via `409 email_taken`/`login_id_taken` — accepted product behavior for
    signup flows — while `verify-email/request` and `password-reset/request` remain
    blind `202`s; the asymmetry is intentional.
- `docs/user/api.md`: add `403 email_not_verified` to the outcomes of `POST /auth/login`,
  `POST /auth/refresh`, `POST /auth/mfa/complete`, `POST /auth/login/passkey/complete`
  ("when `emailVerificationRequired` is enabled and the account's email is unverified").
- `docs/user/notifications.md` (and/or `docs/user/deployment.md`): the redacted log-line
  format, the hash-prefix correlation note, and `SHOMEI_NOTIFIER_LOG_SECRETS`.

Acceptance: docs read correctly; `rg -n "email_not_verified" docs/user` finds the new
entries.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei`, inside `nix develop`.

Generate the dummy hash constant (M1 step 1) — run once, paste the printed value into
`Shomei.Domain.Password`, and do not record the random preimage:

```bash
cabal repl shomei-postgres
```

```text
ghci> import Shomei.Crypto
ghci> import Crypto.Random (getRandomBytes)
ghci> import Data.ByteArray.Encoding
ghci> import Data.Text.Encoding as TE
ghci> pw <- (TE.decodeUtf8 . convertToBase Base64URLUnpadded) <$> (getRandomBytes 32 :: IO Data.ByteString.ByteString)
ghci> hashPasswordArgon2id pw
PasswordHash "argon2id$D5v…$k2m…"     -- copy this whole text value
```

Sanity-check the constant after pasting (must be `False`, and must take Argon2id-time, not
microseconds — eyeball it in the repl):

```text
ghci> verifyPasswordArgon2id "any password at all" (PasswordHash "argon2id$D5v…$k2m…")
False
```

Build and test per milestone:

```bash
cabal build all
cabal test shomei-core          # M1, M2
cabal test shomei-servant       # M2 e2e section
cabal test shomei-server        # M3
cabal test all                  # final sweep
```

Compiler-driven sweeps after record/error changes:

```bash
rg -n "NotifierConfig" --type haskell        # M3 field addition fallout
rg -n "authErrorToServerError" --type haskell # confirm single mapping site
rg -n "emailVerificationRequired" --type haskell  # before: config-only; after: + workflow sites
```

Manual dev-server check for M3 (optional): `just create-database`, `cabal run
exe:shomei-server`, then `curl -s -X POST http://localhost:8080/auth/password-reset/request
-H 'Content-Type: application/json' -d '{"email":"<a signed-up email>"}'` and watch
stderr — expect the redacted `token_sha256=…` line; re-run the server with
`SHOMEI_NOTIFIER_LOG_SECRETS=true` and expect the full `link=…token=…` line.


## Validation and Acceptance

Acceptance is behavioral, per fix:

1. **Timing.** The `TimingSpec` counter cases pass: exactly one `VerifyPassword` per login
   attempt on all four paths (unknown id / dangling credential / inactive user / wrong
   password) and on success. Before the fix the unknown-id case counts zero — observe that
   once and record it. Manual repl timing shows the dummy verification costs the same
   order as a real one (both dominated by Argon2id at t=3/m=64MiB).
2. **Email verification.** With `emailVerificationRequired = True`: signup → login →
   `403 {"error":"email_not_verified","message":"Email address is not verified"}`; refresh
   of the signup pair → same 403; after driving the verification confirm flow, login →
   `200`. Accounts without an email and all flag-off deployments behave exactly as before
   (the untouched existing suites prove the latter).
3. **Redaction.** With defaults, requesting a password reset produces a log line
   containing `token_sha256=<8 hex>` and **no** substring of the raw token and no
   `token=` URL parameter; with `SHOMEI_NOTIFIER_LOG_SECRETS=true` the full link is
   logged (dev behavior preserved). The unit test asserts both by string containment on
   `renderNotification` output.
4. **Suite health.** `cabal test all` green.

Exact test commands: `cabal test shomei-core shomei-servant shomei-server`, then
`cabal test all`.

### Executed results (2026-07-08)

`cabal test all -j1`: 12 of 12 suites PASS.

**1. Timing.** `TimingSpec`, four cases, all green after the fix; against the unfixed workflow
the unknown-id and suspended-account cases report `expected: 1, got 0` (transcript in Surprises
& Discoveries). Manual repl measurement, steady state: real hash 93 ms, dummy hash 95 ms,
malformed hash 9 µs.

**2. Email verification.** `EmailVerificationSpec`, six cases:

```text
an unverified account cannot log in:                            OK
an unverified account cannot refresh the pair signup handed it: OK
verifying the email unblocks login:                             OK
an account with no email is exempt (it could never verify one): OK
with the flag off an unverified account logs in (the default):  OK
passwordless passkey login is gated too:                        OK
```

And over HTTP, in the servant end-to-end suite:

```text
emailVerificationRequired blocks login with 403 until the email is verified: OK
```

which asserts `403` + body `{"error":"email_not_verified"}` on both login and refresh, then
`200` after confirming the token. Flag-off behavior is proven by every other suite staying
green without modification.

**3. Redaction.** Unit tests assert the raw token is absent and the hash prefix present. Against
a live server:

```text
# default
[shomei:log] password_reset email=redact@example.com token_sha256=f6dd8191 expires_at=2026-07-09 03:44:27.031926 UTC (set SHOMEI_NOTIFIER_LOG_SECRETS=true to log the full link in development)

# SHOMEI_NOTIFIER_LOG_SECRETS=true
[shomei:log] password_reset email=redact@example.com link=http://localhost:8080/auth/password-reset/confirm?token=7Hu0OCrgi1FvA6ql4NJHgzWhBcxqFiUBdbwMMMIHbjQ expires_at=2026-07-09 03:44:40.317903 UTC
```

The prefix correlates with the stored hash (both SHA-256 of the token, hex vs base64url) —
checked against the `shomei_password_reset_tokens` row; see Surprises & Discoveries.

**4. Suite health.** Green.


## Idempotence and Recovery

Every change is an ordinary compiler-checked source edit; `cabal build`/`cabal test` re-run
safely, and record-field additions (`NotifierConfig.logRawTokens`) make the compiler list
any missed construction site. No schema migration, no data backfill, nothing to roll back
in a database.

The dummy-hash constant is generated once; regenerating it later is harmless (any
well-formed Argon2id value with the production parameters is equivalent) — just never
weaken it to a malformed string, and keep the doc comment explaining why.

All three behavior changes are safe to deploy incrementally and to toggle: the email gate
is fully governed by an existing config flag defaulting to off; the notifier redaction
defaults to safe and can be reverted per-process with the env flag; the timing fix has no
functional effect at all (failed logins still fail identically) beyond costing the same
time on every path. If the email gate must be disabled in an emergency, unset
`emailVerificationRequired` in config/env and restart — no code change needed.


## Interfaces and Dependencies

No new library dependencies anywhere (the SHA-256 helper and Argon2id code already exist in
`shomei-postgres`'s `Shomei.Crypto`, which `shomei-server` already depends on; the core
gains only a `Text` constant).

Definitions that must exist at the end (full module paths):

- `Shomei.Domain.Password.dummyPasswordHash :: PasswordHash` — well-formed
  `argon2id$…$…` value, exported, with the provenance/warning comment.
- `Shomei.Workflow.login` — unchanged signature; every failure path performs exactly one
  `verifyPassword` (via the local `failLoginTimed` helper and the inactive-user branch).
- `Shomei.Error.AuthError.EmailNotVerified`;
  `Shomei.Servant.Error.authErrorToServerError` maps it to
  `403 {"error":"email_not_verified"}`.
- `Shomei.Workflow.Session.ensureEmailVerified :: ShomeiConfig -> User -> Either AuthError ()`,
  called from `Shomei.Workflow.login`, `Shomei.Workflow.refresh` (whose constraints gain
  `UserStore :> es`), `Shomei.Workflow.Mfa.completeMfa`, and
  `Shomei.Workflow.Mfa.completePasswordlessLogin`.
- `Shomei.Config.NotifierConfig.logRawTokens :: Bool` (default `False`);
  `SHOMEI_NOTIFIER_LOG_SECRETS` handled in `Shomei.Server.Config.overlayCoreFromEnv`.
- `Shomei.Notify.renderNotification` exported; redacted output carries
  `token_sha256=<first 8 hex of Shomei.Crypto.sha256Hex token>`.

Relations to other plans: plan 28 edits `Shomei.Workflow.refresh` in disjoint hunks
(rotation atomicity vs. this plan's pre-rotation gate) — coordinate at rebase time. Plan 31
(`docs/plans/31-complete-cookie-token-transport-with-csrf-defenses.md`) touches login/refresh
at the HTTP layer only, not the core workflows. The MasterPlan's config integration point
applies: this plan only *adds* `NotifierConfig.logRawTokens` and must not rename existing
fields.
