---
id: 22
slug: compromised-password-breach-checking-via-hibp-k-anonymity
title: "Compromised Password Breach Checking via HIBP k-Anonymity"
kind: exec-plan
created_at: 2026-06-17T18:08:56Z
intention: "intention_01kvbc26dhenstms0kx006ceds"
master_plan: "docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md"
---

# Compromised Password Breach Checking via HIBP k-Anonymity

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, an operator can opt in to rejecting passwords that appear in a known
public data breach. With the policy flag `breachCheckEnabled = True`, a user who tries to
sign up (or change/reset their password) with a password that has been seen in a breach —
the canonical example is the literal string `password` — is rejected with a new policy
violation, `PasswordBreached`, surfaced exactly like every other weak-password rejection.
With the flag off (the default), behavior is completely unchanged: no network call is made
and no password is ever consulted against an external service.

The check is privacy-preserving by construction. It queries the "Have I Been Pwned" (HIBP)
Pwned Passwords range API using **k-anonymity**: only the first **5 hex characters** of the
password's SHA-1 hash ever leave this process. The full hash and the plaintext never go on
the wire. The server downloads the bucket of all breached-hash suffixes sharing that prefix
and compares locally.

You can see it working two ways:

- A hermetic in-memory test: with the flag on and a fake breach set containing a password,
  `signup` returns `Left (WeakPassword PasswordBreached)`; with the flag off, the same
  password is accepted; with a clean password, signup succeeds.
- An optional manual check (NOT part of the default suite): point the production HIBP
  interpreter at the real API with the password `password` (SHA-1 prefix `5BAA6`) and observe
  a `Breached` result.

The check performs IO (an HTTPS request), so it CANNOT live inside the pure `validatePassword`
function. It is delivered as a new `effectful` dynamic-dispatch port, `PasswordBreachChecker`,
mirroring the existing `PasswordHasher` port, with a production HIBP interpreter, an in-memory
test fake, and an effectful guard appended to the three password-accepting workflows.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Pre-flight (2026-06-17): confirmed EP-1 fields `breachCheckEnabled`,
      `breachCheckFailClosed`, `breachCheckTimeoutMs` exist on `PasswordPolicy`
      (`shomei-core/src/Shomei/Domain/Password.hs:40-42`).
- [x] M1 (2026-06-17): added `PasswordBreached` to `PasswordPolicyViolation` in
      `shomei-core/src/Shomei/Error.hs`; confirmed servant mapping is the `WeakPassword _`
      wildcard (`shomei-servant/src/Shomei/Servant/Error.hs:43`) — no edit needed; the only
      other matches on the constructors are test expectations (not exhaustive cases);
      `cabal build all` green.
- [x] M2 (2026-06-17): created `Shomei.Effect.PasswordBreachChecker` (effect + `BreachResult`
      tri-state + `checkPasswordBreached` smart constructor); added pure helpers
      `sha1PrefixSuffix` and `parseHibpResponse`; added `World` fields `breachedPasswords` /
      `breachCheckAvailable` (seeded in `emptyWorld`) and `runPasswordBreachCheckerFake`; wired
      the fake into `runInMemory` (just before `PasswordHasher` in the list, just above
      `runPasswordHasher` in the chain); added `Shomei.BreachSpec` unit tests. Dep added to
      `shomei-core`: `crypton` (SHA-1) and `ram` (provides `Data.ByteArray.Encoding`). `cabal
      build all` + `shomei-core-test` (70 tests) green.
- [x] M3 (2026-06-17): added shared guard `Shomei.Workflow.Breach.enforceBreachPolicy`
      (new exposed-module); appended it after the pure validation in `signup`
      (`Shomei.Workflow`), `confirmPasswordReset`, and `changePassword`
      (`Shomei.Workflow.Account`), and added the `PasswordBreachChecker :> es` constraint to
      each. Added enabled/clean/disabled/fail-open/fail-closed signup tests plus one each for
      change & reset in `Shomei.AccountSpec`. `shomei-core-test`: 77 tests green.
- [x] M4 (2026-06-17): wrote `Shomei.Server.BreachChecker.runPasswordBreachCheckerHibp`
      (http-client + http-client-tls; SHA-1 via the shared `shomei-core` pure helper, so no
      crypton dep was needed in `shomei-server`); added `envHttpManager :: Manager` to
      `Shomei.Server.App.Env` (built via `newTlsManager` in `Shomei.Server.Boot.buildEnv`);
      wired `runPasswordBreachCheckerHibp` into `runAppIO` and added `PasswordBreachChecker` to
      BOTH `AppEffects` lists (`Shomei.Server.App`, `Shomei.Servant.Seam`). Updated every
      hand-composed harness/stack: the admin CLI (`Shomei.Admin.Users`, with a local
      always-`NotBreached` interpreter), the servant test, the postgres test (two stacks), and
      the `Env` constructions in the server-E2E / client / embedded / microservice tests. Full
      `cabal build all` and `cabal test all` green (all suites incl. DB-backed E2E).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M2 (2026-06-17): `Data.ByteArray.Encoding` is **not** provided by `crypton` or `memory` in
  this workspace — it comes from the `ram` package (a `memory` fork; `crypton` depends on it but
  does not re-export it). The plan's M2.1 note guessed `memory`; the correct dep is `ram`.
  Evidence: `shomei-postgres/shomei-postgres.cabal` already lists both `crypton` and `ram`, and
  GHC's "hidden package `ram-0.22.0`" error named it explicitly. `shomei-core` now lists
  `crypton` + `ram`.
- M2 (2026-06-17): `cabal` test-component target is `shomei-core:shomei-core-test` (not
  `shomei-core:test` as the plan's commands wrote) — the component is named `shomei-core-test`.
- M4 (2026-06-17): the new `PasswordBreachChecker :> es` workflow constraint propagated to MANY
  more hand-composed stacks than the plan listed. Beyond `runInMemory`, the two `AppEffects`
  lists, and the production `runAppIO`, the following also had to gain the effect (each is a
  separately hand-written effect list / composition, NOT derived from a shared alias):
  the admin CLI's `runSignup` (`shomei-server/app/Shomei/Admin/Users.hs`); the **postgres**
  integration test's own `AppEffects` alias plus its `runAppWithNotifications` AND `runAppAtTime`
  compositions (`shomei-postgres/test/Main.hs`); and the `Env` record gained a field, so every
  `Env{...}` literal had to add `envHttpManager` — there are FIVE: `buildEnv` (Boot) plus the
  server-E2E, shomei-client, embedded-servant-app, and microservice-auth-stack test harnesses.
- M4 (2026-06-17): `crypton` was NOT needed in `shomei-server` — the SHA-1 hashing lives in the
  `shomei-core` pure helper `sha1PrefixSuffix`, which the interpreter imports, so the HIBP
  interpreter module imports no `Crypto.*` directly. Only `http-client` + `http-client-tls` were
  added to `shomei-server`. (The plan's M4.2 already flagged this as the likely outcome.)
- M4 (2026-06-17): selecting `env.envConfig.passwordPolicy.breachCheckTimeoutMs` via
  OverloadedRecordDot in `Shomei.Server.App` failed (`No instance for HasField "passwordPolicy"
  ...` / `"breachCheckTimeoutMs"`) because `App.hs` imports `ShomeiConfig`/`PasswordPolicy` as
  type-only; the field SELECTORS must be in scope for the HasField instance. Fixed by importing
  `ShomeiConfig (passwordPolicy)` and `PasswordPolicy (breachCheckTimeoutMs)` and binding the
  timeout in a typed `where` clause. (Other modules avoid this because they import the records
  with `(..)`.)
- M4 (2026-06-17): the admin CLI does not perform the network breach check; it uses a local
  always-`NotBreached` interpreter (`runPasswordBreachCheckerNoCheck`), mirroring its existing
  fake `TokenSigner`. See the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement breach checking as a new `effectful` port `PasswordBreachChecker`
  rather than folding it into the pure `validatePassword`.
  Rationale: the check performs an HTTPS request (IO); `validatePassword :: PasswordPolicy ->
  PlainPassword -> Either PasswordPolicyViolation ()` is pure and must stay pure so it can be
  exercised without effects. The IO guard is a separate effectful step that runs after the
  pure validation.
  Date: 2026-06-17

- Decision: The port returns a tri-state `BreachResult = NotBreached | Breached |
  BreachCheckUnavailable` instead of a `Bool`.
  Rationale: the policy must distinguish "HIBP says clean" from "HIBP could not be reached" so
  it can honor `breachCheckFailClosed`. A `Bool` cannot express the unreachable case.
  Date: 2026-06-17

- Decision: Default to fail-OPEN (`breachCheckFailClosed = False`) when HIBP is unreachable.
  Rationale: EP-1 sets the default to `False`; an outage of a third-party API must not block
  legitimate signups/password changes by default. Operators who prefer strictness can flip it.
  Date: 2026-06-17

- Decision: Place the production interpreter (`runPasswordBreachCheckerHibp`) in
  `shomei-server` (`shomei-server/src/Shomei/Server/App.hs` or a small new module), not in
  `shomei-postgres`.
  Rationale: outbound HTTP and the live effect-stack assembly (`runAppIO`) already live in
  `shomei-server`; only `crypton` needs adding there for SHA-1. (Implementer must confirm the
  assembly site before wiring.)
  Date: 2026-06-17

- Decision: Factor the HIBP line-parsing and the SHA-1 prefix/suffix split into PURE functions
  (`parseHibpResponse`, `sha1PrefixSuffix`) and unit-test those.
  Rationale: keeps the parsing logic hermetically testable without a network call; the
  production interpreter then becomes a thin IO shell around them.
  Date: 2026-06-17

- Decision: Exclude any test that actually hits `api.pwnedpasswords.com` from the default
  `cabal test all` run.
  Rationale: network-dependent tests are flaky and non-hermetic; the in-memory fake gives full
  behavioral coverage. A manual ghci snippet is documented for ad-hoc verification.
  Date: 2026-06-17

- Decision: The admin CLI (`shomei-admin users create`) does NOT perform the HIBP breach check;
  it wires a local `runPasswordBreachCheckerNoCheck` interpreter that always returns
  `NotBreached`.
  Rationale: the admin executable does not depend on `shomei-server` (where the HIBP interpreter
  lives) and we did not want to add a network dependency or a TLS manager to an operator-only
  seeding path. This mirrors the CLI's existing fake `TokenSigner`. Operators seeding users via
  the CLI are trusted; the running server still enforces the policy on the HTTP signup/change/
  reset paths. If CLI-side breach checking is wanted later, give the CLI a TLS manager and reuse
  `Shomei.Server.BreachChecker.runPasswordBreachCheckerHibp`.
  Date: 2026-06-17

- Decision: Construct the shared TLS `Manager` once at startup (`buildEnv`) and store it on
  `Env` (`envHttpManager`), passing it into `runPasswordBreachCheckerHibp` when the stack is
  assembled.
  Rationale: an HTTP `Manager` is meant to be long-lived and connection-pooling; building one per
  request would defeat keep-alive. `runAppIO` assembles the stack per call but closes over the
  one manager from `Env`, so all calls share it.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Delivered exactly the original purpose. An operator can now opt in to HIBP breach checking with
`breachCheckEnabled = True`; a signup/change/reset with a breached password is rejected with
`WeakPassword PasswordBreached`, surfaced as the same `400 weak_password` as every other policy
violation (the Servant wildcard covers it — no HTTP edit was needed). With the flag off (the
default) behavior is unchanged and no network call is made. The check is privacy-preserving by
construction: only the 5-char uppercase SHA-1 prefix leaves the process (`sha1PrefixSuffix`),
and an unreachable HIBP resolves to `BreachCheckUnavailable`, honored as fail-open by default or
fail-closed under `breachCheckFailClosed`.

The IO check lives in a new `effectful` port (`PasswordBreachChecker`) with a production HIBP
interpreter (`Shomei.Server.BreachChecker`) and an in-memory fake seeded from the test `World`,
exactly mirroring the `PasswordHasher` precedent. Pure parsing/hashing logic
(`parseHibpResponse`, `sha1PrefixSuffix`) is factored out and unit-tested hermetically. All
coverage is hermetic (no network); the real-API check remains a documented manual ghci snippet.

Outcome vs. plan: the design matched the plan; the only surprise was breadth, not shape — adding
one workflow constraint rippled into ~10 hand-composed effect stacks / `Env` literals across the
workspace (admin CLI, two postgres test stacks, five `Env{}` sites). The compiler's effect-order
and missing-handler errors made each site mechanical to find and fix. `crypton` was not needed in
`shomei-server` after all (SHA-1 is computed in the `shomei-core` helper). Full `cabal build all`
and `cabal test all` are green, including the DB-backed E2E suites.

No gaps against scope. Known intentional limitation: the admin CLI bypasses the breach check
(see Decision Log).


## Context and Orientation

This is **shomei**, a Haskell authentication toolkit built as a cabal workspace (GHC 9.12.4,
`cabal build all`, `cabal test all`; test framework tasty + tasty-hunit). The architecture is
ports-and-adapters using the `effectful` library with **dynamic dispatch**: each external
capability is an `Effect` (a "port"), and each port has one or more "interpreters" (adapters)
— a pure in-memory fake for tests and a production interpreter for the live stack.

Read this section as if you know nothing about the codebase.

### The effectful port pattern (the template you will copy)

The cleanest template is the password-hasher port at
`shomei-core/src/Shomei/Effect/PasswordHasher.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
module Shomei.Effect.PasswordHasher (PasswordHasher (..), hashPassword, verifyPassword) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Password (PasswordHash, PlainPassword)

data PasswordHasher :: Effect where
    HashPassword :: PlainPassword -> PasswordHasher m PasswordHash
    VerifyPassword :: PlainPassword -> PasswordHash -> PasswordHasher m Bool

type instance DispatchOf PasswordHasher = Dynamic

hashPassword :: (PasswordHasher :> es) => PlainPassword -> Eff es PasswordHash
hashPassword = send . HashPassword
verifyPassword :: (PasswordHasher :> es) => PlainPassword -> PasswordHash -> Eff es Bool
verifyPassword p h = send (VerifyPassword p h)
```

A port is: a GADT whose constructors are the operations; a `DispatchOf = Dynamic` instance;
and thin `send`-wrapping smart constructors used by the workflows.

The matching interpreters for `PasswordHasher`:

- In-memory fake — `shomei-core/src/Shomei/Effect/InMemory.hs`, `runPasswordHasher`:

```haskell
runPasswordHasher :: IORef World -> Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasher _ref = interpret_ \case
    HashPassword (PlainPassword pw) -> pure (PasswordHash ("argon2-fake:" <> pw))
    VerifyPassword (PlainPassword pw) (PasswordHash h) -> pure (h == "argon2-fake:" <> pw)
```

- Production — `shomei-postgres/src/Shomei/Crypto.hs`, `runPasswordHasherCrypto` (real
  Argon2id via `crypton`).

### The in-memory harness

`shomei-core/src/Shomei/Effect/InMemory.hs` holds a single mutable test world in an `IORef`:

```haskell
data World = World { users :: ...; clock :: !UTCTime; tokenCounter :: !Int; ... }
emptyWorld :: UTCTime -> World
```

`runInMemory :: IORef World -> Eff [ ...big ordered effect list..., IOE ] a -> IO a` composes
every fake interpreter via `runEff . runTokenGen ref . runClock ref . ... . runUserStore ref`.
**Critical invariant:** the order of effects in the type-level list must match the order of the
run-composition (head of the list is the OUTERMOST `.`-applied interpreter, applied last). The
compiler enforces this — a mismatch is a type error.

Tests build a fresh world (`ref <- newIORef (emptyWorld fixedTime)`), run a workflow through
`runInMemory ref`, and inspect results / `readIORef ref`. Existing fixtures in
`shomei-core/test/Shomei/AccountSpec.hs` include `aliceEmail`, `strongPw`, `expectRight`,
`fixedTime`, and `cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")`.

### The three password-accepting workflows

Passwords are validated at exactly three sites today:

- `signup` — `shomei-core/src/Shomei/Workflow.hs` (~lines 108-155). Validates with
  `either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.password)`.
- `confirmPasswordReset` — `shomei-core/src/Shomei/Workflow/Account.hs` (~lines 158-182).
  Validates `cmd.newPassword`.
- `changePassword` — `shomei-core/src/Shomei/Workflow/Account.hs` (~lines 184-207). Validates
  `cmd.newPassword`.

All three run inside `runErrorNoCallStack do { ... }` and use `throwError` from
`Effectful.Error.Static` (imported as `import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)`).
The `Error AuthError` effect is supplied by `runErrorNoCallStack`, so inside the `do` block
`throwError :: AuthError -> Eff es a` is available without it appearing in the workflow's own
constraint list (the constraint is discharged by `runErrorNoCallStack` at the top of each
workflow).

### The production stack assembly

The live effect stack is assembled in `shomei-server/src/Shomei/Server/App.hs`:

- `type AppEffects = '[ UserStore, ..., PasswordHasher, TokenSigner, ..., Database, Error AuthError, IOE ]`
  (lines ~75-97).
- `runAppIO :: Env -> Eff AppEffects a -> IO (Either AuthError a)` (lines ~117-139) composes
  the production interpreters, including `. runPasswordHasherCrypto`.

A **second** `AppEffects` list also exists in `shomei-servant/src/Shomei/Servant/Seam.hs`
(lines ~58-78) — the servant port stack used by the servant test harness. Both lists must gain
the new effect, in the same position relative to `PasswordHasher`, or the seam will not typecheck.

### crypton SHA-1 precedent

`crypton` (>= 1.1.0) provides SHA-1. `shomei-postgres/src/Shomei/Crypto.hs` already shows the
exact import idiom for hashing + hex (using SHA-256):

```haskell
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray.Encoding (Base (Base16, Base64, Base64URLUnpadded), convertFromBase, convertToBase)
...
sha256Hex t = TE.decodeUtf8 (convertToBase Base16 (hashWith SHA256 (TE.encodeUtf8 t)))
```

For HIBP we use `SHA1` instead of `SHA256` and uppercase the Base16 output.

### HIBP and k-anonymity, defined

**Have I Been Pwned (HIBP) Pwned Passwords** is a public service exposing a database of hashes
of passwords seen in breaches, with a count of how often each was seen. **k-anonymity** is a
query technique where you reveal only a short prefix that is shared by many records, so the
server cannot tell which record you wanted. Here the prefix is 5 hex chars of the SHA-1 hash;
the server returns all suffixes in that bucket; you match locally. Only the prefix is sent.

The exact algorithm to embed in the interpreter:

1. Compute SHA-1 of the **UTF-8 bytes** of the password. Render as an **UPPERCASE** hex string
   (40 hex chars).
2. Split into a **5-char prefix** and a **35-char suffix**.
3. HTTPS `GET https://api.pwnedpasswords.com/range/<PREFIX>` (prefix uppercase). Send header
   `Add-Padding: true` (HIBP pads the response with bogus zero-count entries to defeat
   response-size analysis). Set the request timeout from `breachCheckTimeoutMs`.
4. The response body is plain text, one entry per line, each `<SUFFIX>:<COUNT>` where SUFFIX is
   the remaining 35 uppercase hex chars and COUNT is the breach occurrence count. Lines use
   CRLF. Padding lines have COUNT 0 — ignore them.
5. If any line's SUFFIX matches our suffix (case-insensitive) with COUNT > 0, the password is
   breached.

The full SHA-1 hash never leaves the process — only the 5-char prefix is sent.

### Dependencies on sibling plans

- **HARD dependency: `docs/plans/20-configurable-password-policy-end-to-end.md` (EP-1).**
  EP-1 extends the `PasswordPolicy` record (in `shomei-core/src/Shomei/Domain/Password.hs`,
  re-exported via `shomei-core/src/Shomei/Config.hs`) with, among others:

  ```haskell
  breachCheckEnabled   :: !Bool   -- default False
  breachCheckFailClosed :: !Bool  -- default False  (fail OPEN by default)
  breachCheckTimeoutMs :: !Int    -- default 1000
  ```

  EP-3 READS these flags. EP-1 must be Complete first. As of writing this plan,
  `PasswordPolicy` only has `minLength`/`maxLength`:

  ```haskell
  data PasswordPolicy = PasswordPolicy { minLength :: ..., maxLength :: ... }
  defaultPasswordPolicy = PasswordPolicy{minLength = 12, maxLength = 256}
  ```

  **The implementer MUST verify the three `breachCheck*` fields exist before starting M3/M4.**
  If they do not, EP-1 is not yet landed — stop and land EP-1 first.

- **SOFT dependency (recommended ordering): `docs/plans/21-common-and-context-specific-weak-password-rejection.md` (EP-2).**
  EP-2 edits the same three workflow call sites and the same `PasswordPolicyViolation` sum
  type (it adds `PasswordResemblesIdentity`). EP-2 is recommended to land first; EP-3 then only
  APPENDS its effectful guard after the (now context-aware) pure validation. EP-3's guard is
  independent of EP-2's pure-validation reshaping, so it can be added regardless — but the
  call-site code may differ slightly depending on EP-2's changes. **Instruct: read the current
  workflow code and append the guard immediately after whatever pure validation already exists.**

Parent MasterPlan:
`docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md`.


## Plan of Work

The work is four milestones, each independently verifiable. The integration points (IPs) from
the MasterPlan map onto these milestones: IP-2 (violation type) → M1; the new port + fake +
pure helpers (IP-5 partial) → M2; the workflow guards (IP-3) → M3; the production interpreter +
stack wiring (IP-5 partial) → M4. IP-4 (servant mapping) is a confirmation in M1.

### Milestone M1 — add `PasswordBreached` and confirm error rendering

Scope: extend the violation sum type and verify the HTTP mapping. At the end, the new
constructor exists and the whole workspace compiles. Append `PasswordBreached` to
`PasswordPolicyViolation` in `shomei-core/src/Shomei/Error.hs`. Then confirm the servant
mapping: `shomei-servant/src/Shomei/Servant/Error.hs` maps `WeakPassword _` with a **wildcard**
to `400 weak_password`, so **no servant edit is required** — every violation, including the new
one, renders as `400 {"error":"weak_password","message":"Password does not meet policy"}`.
Verify there is no per-constructor match on `PasswordPolicyViolation` anywhere (grep) that the
compiler would flag as non-exhaustive.

Commands: `cabal build all`.

Acceptance: `cabal build all` succeeds; `grep` finds no non-wildcard exhaustive match on
`PasswordPolicyViolation` that omits `PasswordBreached`.

### Milestone M2 — the port, the pure helpers, the fake, and unit tests

Scope: create the `PasswordBreachChecker` effect with `BreachResult`; add two pure helpers
(`sha1PrefixSuffix`, `parseHibpResponse`); add the in-memory fake plus `World` fields; wire the
fake into `runInMemory`; add hermetic unit tests for the pure helpers. At the end, the port
exists, the fake is composed into the in-memory stack, and the pure parsing/hashing logic is
unit-tested.

The pure helpers should live in the effect module (so both the fake — for documentation — and
the production interpreter can import them, and the test can import them without pulling in
http-client). Put `BreachResult` in the same effect module.

Commands: `cabal build all`; `cabal test shomei-core:test`.

Acceptance: build green; new unit tests pass — `sha1PrefixSuffix "password"` yields prefix
`"5BAA6"`, and `parseHibpResponse` returns `True`/`False` correctly for crafted bodies.

### Milestone M3 — the effectful guard in the three workflows + behavioral tests

Scope: add a shared helper `enforceBreachPolicy` and call it in `signup`, `confirmPasswordReset`,
and `changePassword`, immediately after the existing pure validation. Add the
`PasswordBreachChecker :> es` constraint to each workflow's signature. Add workflow tests for:
enabled+breached → reject; enabled+clean → accept; disabled+breached → accept; fail-open and
fail-closed under simulated unavailability. At the end, the three workflows enforce the breach
policy through the in-memory fake.

Commands: `cabal build all`; `cabal test shomei-core:test`.

Acceptance: all the new behavioral tests pass (see Validation).

### Milestone M4 — the production HIBP interpreter and stack wiring

Scope: write `runPasswordBreachCheckerHibp` (real HTTPS via http-client-tls, SHA-1 via crypton),
add it to `runAppIO`, add `PasswordBreachChecker` to BOTH `AppEffects` lists
(`Shomei.Server.App`, `Shomei.Servant.Seam`), add the missing build-deps. At the end, the live
server enforces breach checking against the real HIBP API when the flag is on. Provide an
optional, manual integration check (NOT in the default suite).

Commands: `cabal build all`; `cabal test all` (still hermetic — no network).

Acceptance: workspace builds and the full hermetic suite passes; the optional manual ghci
snippet against the real API returns `Breached` for `password`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`.

### Step 0 — pre-flight

Confirm EP-1's fields exist:

```bash
grep -n "breachCheckEnabled\|breachCheckFailClosed\|breachCheckTimeoutMs" \
  shomei-core/src/Shomei/Domain/Password.hs
```

Expected: three matches. If zero, STOP and complete
`docs/plans/20-configurable-password-policy-end-to-end.md` first.

### Step M1.1 — add the violation constructor

Edit `shomei-core/src/Shomei/Error.hs`. Before:

```haskell
data PasswordPolicyViolation
    = -- | minimum length required
      PasswordTooShort Int
    | -- | maximum length allowed
      PasswordTooLong Int
    | PasswordTooCommon
    | PasswordMissingRequiredClass Text
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

After (append `PasswordBreached`; this is additive and the JSON instances are derived, so the
new constructor serializes as the string `"PasswordBreached"`):

```haskell
data PasswordPolicyViolation
    = -- | minimum length required
      PasswordTooShort Int
    | -- | maximum length allowed
      PasswordTooLong Int
    | PasswordTooCommon
    | PasswordMissingRequiredClass Text
    | -- | The password appears in a known public breach (HIBP). EP-3.
      PasswordBreached
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

### Step M1.2 — confirm the servant mapping (likely no edit)

```bash
grep -rn "PasswordTooCommon\|PasswordMissingRequiredClass\|PasswordPolicyViolation\|WeakPassword" \
  shomei-servant/src shomei-server/src
```

`shomei-servant/src/Shomei/Servant/Error.hs` contains
`WeakPassword _ -> json err400 "weak_password" "Password does not meet policy"` — a wildcard, so
`PasswordBreached` is already covered. **No edit needed.** If the grep reveals a per-constructor
match elsewhere, add a `PasswordBreached` arm rendering as 400/422 consistently with siblings.

```bash
cabal build all
```

Expected tail:

```text
... Linking ...
```

### Step M2.1 — create the effect module with `BreachResult` and pure helpers

Create `shomei-core/src/Shomei/Effect/PasswordBreachChecker.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The password-breach-checker port: decide whether a password appears in a known public
breach. Implemented in production by a HIBP k-anonymity range query (EP-3) and in tests by an
in-memory fake. Kept separate from the pure 'Shomei.Domain.Password.validatePassword' because
the production check performs IO.
-}
module Shomei.Effect.PasswordBreachChecker (
    PasswordBreachChecker (..),
    BreachResult (..),
    checkPasswordBreached,

    -- * Pure helpers (shared by the production interpreter and tests)
    sha1PrefixSuffix,
    parseHibpResponse,
) where

import Shomei.Prelude

import Crypto.Hash (SHA1 (..), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.Char (toUpper)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Password (PlainPassword (..))

-- | The outcome of a breach check; the third state lets policy choose fail-open vs fail-closed.
data BreachResult
    = NotBreached
    | Breached
    | BreachCheckUnavailable
    deriving stock (Eq, Show)

data PasswordBreachChecker :: Effect where
    CheckPasswordBreached :: PlainPassword -> PasswordBreachChecker m BreachResult

type instance DispatchOf PasswordBreachChecker = Dynamic

checkPasswordBreached :: (PasswordBreachChecker :> es) => PlainPassword -> Eff es BreachResult
checkPasswordBreached = send . CheckPasswordBreached

{- | Uppercase hex SHA-1 of the UTF-8 password, split into the 5-char k-anonymity prefix and
the 35-char suffix. @sha1PrefixSuffix "password" == ("5BAA6", "1E4C9B93F3F0682250B6CF8331B7EE68FD8")@.
-}
sha1PrefixSuffix :: PlainPassword -> (Text, Text)
sha1PrefixSuffix (PlainPassword pw) =
    let digest = hashWith SHA1 (TE.encodeUtf8 pw)
        hex = Text.map toUpper (TE.decodeUtf8 (convertToBase Base16 digest :: ByteString))
     in (Text.take 5 hex, Text.drop 5 hex)

{- | Given a HIBP range response body and our 35-char suffix, return whether any line matches
our suffix (case-insensitive) with a count > 0. Padding lines (count 0) are ignored. Lines may
use CRLF; @Text.lines@ plus a trailing @\r@ strip handles both.
-}
parseHibpResponse :: Text -> Text -> Bool
parseHibpResponse body suffix =
    let wantUpper = Text.toUpper suffix
        entry line =
            case Text.splitOn ":" (Text.dropWhileEnd (== '\r') line) of
                [s, c] -> Text.toUpper s == wantUpper && countPositive c
                _ -> False
        countPositive c = case Text.decimal' c of
            Just n -> n > (0 :: Integer)
            Nothing -> False
     in any entry (Text.lines body)
  where
    -- local safe decimal parse; avoids a hard dep on Data.Text.Read in this module's import set
    -- (the implementer may instead `import Data.Text.Read (decimal)` and adapt).
    decimal' = \t -> case reads (Text.unpack (Text.strip t)) of
        [(n, "")] -> Just n
        _ -> Nothing
```

Note for the implementer: `Text.decimal'` above is a tiny inline parser; if you prefer, import
`Data.Text.Read (decimal)` and write `either (const False) ((> 0) . fst) (decimal (Text.strip c))`.
Either is fine — keep `parseHibpResponse` pure and total. Confirm `Crypto.Hash` exposes `SHA1`
(it does, alongside `SHA256` already used in `Shomei.Crypto`).

Add the module to `shomei-core/shomei-core.cabal` `exposed-modules` (alphabetical, after
`Shomei.Effect.PasswordHasher`... actually before it; keep the list sorted):

```diff
     Shomei.Effect.Notifier
     Shomei.Effect.PasskeyStore
+    Shomei.Effect.PasswordBreachChecker
     Shomei.Effect.PasswordHasher
     Shomei.Effect.PasswordResetTokenStore
```

`shomei-core` already depends on `crypton`? Verify; `Shomei.Crypto` lives in `shomei-postgres`,
so `shomei-core` may NOT yet have `crypton`/`memory`. Check and add if missing:

```bash
grep -n "crypton\|memory" shomei-core/shomei-core.cabal
```

If absent, add to `shomei-core`'s library `build-depends`:

```diff
   build-depends:
     , aeson
     , base
+    , crypton
     , effectful
     , effectful-core
+    , memory
```

(`Data.ByteArray.Encoding` comes from `memory`. Confirm which package provides it in this
workspace — `crypton` re-exports some of it; if `Data.ByteArray.Encoding` resolves via
`crypton` alone, omit `memory`.)

### Step M2.2 — add `World` fields and the fake interpreter

Edit `shomei-core/src/Shomei/Effect/InMemory.hs`.

Add the import:

```diff
 import Shomei.Effect.PasswordHasher (PasswordHasher (..))
+import Shomei.Effect.PasswordBreachChecker (BreachResult (..), PasswordBreachChecker (..))
```

Add `Set` import (the existing imports use `Data.Map.Strict`; add `Data.Set`):

```diff
 import Data.Map.Strict (Map)
 import Data.Map.Strict qualified as Map
+import Data.Set (Set)
+import Data.Set qualified as Set
```

Add two fields to `World` (test seam: a set of breached plaintexts plus an availability flag to
simulate `BreachCheckUnavailable`):

```diff
     , ceremonyCounter :: !Int
     -- ^ deterministic WebAuthn ceremony challenges (fake interpreter)
+    , breachedPasswords :: !(Set Text)
+    -- ^ EP-3: plaintexts the breach-checker fake treats as breached
+    , breachCheckAvailable :: !Bool
+    -- ^ EP-3: when False the fake returns 'BreachCheckUnavailable' (test seam for fail-open/closed)
     }
```

Seed both in `emptyWorld`:

```diff
         , ceremonyCounter = 0
+        , breachedPasswords = Set.empty
+        , breachCheckAvailable = True
         }
```

Add the fake interpreter next to `runPasswordHasher`:

```haskell
runPasswordBreachCheckerFake :: (IOE :> es) => IORef World -> Eff (PasswordBreachChecker : es) a -> Eff es a
runPasswordBreachCheckerFake ref = interpret_ \case
    CheckPasswordBreached (PlainPassword pw) -> liftIO do
        w <- readIORef ref
        pure
            if not w.breachCheckAvailable
                then BreachCheckUnavailable
                else if Set.member pw w.breachedPasswords then Breached else NotBreached
```

Export it from the module's "Individual interpreters" list:

```diff
     runPasswordHasher,
+    runPasswordBreachCheckerFake,
```

### Step M2.3 — wire the fake into `runInMemory`

Add `PasswordBreachChecker` to the type-level list AND the composition chain, adjacent to
`PasswordHasher` / `runPasswordHasher`. **The list position and the chain position MUST match.**

Type signature diff:

```diff
         , WebAuthnCeremony
+        , PasswordBreachChecker
         , PasswordHasher
         , TokenSigner
```

Composition diff (head of list = applied last; `runPasswordBreachCheckerFake` goes immediately
ABOVE `runPasswordHasher` in `.`-chaining order to match its position just before
`PasswordHasher` in the list):

```diff
         . runWebAuthnCeremonyFake ref
+        . runPasswordBreachCheckerFake ref
         . runPasswordHasher ref
```

Build:

```bash
cabal build shomei-core
```

### Step M2.4 — unit tests for the pure helpers

Add a test module `shomei-core/test/Shomei/BreachSpec.hs` (and register it in the test
component's `other-modules` in `shomei-core/shomei-core.cabal`, and add its `testGroup` to the
test tree in `shomei-core/test/Main.hs`):

```haskell
module Shomei.BreachSpec (tests) where

import Shomei.Prelude

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Effect.PasswordBreachChecker (parseHibpResponse, sha1PrefixSuffix)

tests :: TestTree
tests =
    testGroup
        "PasswordBreachChecker pure helpers"
        [ testCase "sha1PrefixSuffix of \"password\" has prefix 5BAA6" $
            fst (sha1PrefixSuffix (PlainPassword "password")) @?= "5BAA6"
        , testCase "sha1PrefixSuffix suffix is 35 chars" $
            Text.length (snd (sha1PrefixSuffix (PlainPassword "password"))) @?= 35
        , testCase "parseHibpResponse matches a present suffix with count > 0" $
            let (_, suffix) = sha1PrefixSuffix (PlainPassword "password")
                body = suffix <> ":12345\r\nDEADBEEF:0\r\n"
             in parseHibpResponse body suffix @?= True
        , testCase "parseHibpResponse ignores count 0 (padding)" $
            parseHibpResponse "ABCDEF1234567890ABCDEF1234567890ABCDE:0\r\n" "ABCDEF1234567890ABCDEF1234567890ABCDE" @?= False
        , testCase "parseHibpResponse returns False when suffix absent" $
            parseHibpResponse "0000000000000000000000000000000000000:9\r\n" "ABCDEF1234567890ABCDEF1234567890ABCDE" @?= False
        ]
```

Wire into `shomei-core/test/Main.hs`:

```diff
+import Shomei.BreachSpec qualified as BreachSpec
 ...
   testGroup "shomei-core"
     [ ...
+    , BreachSpec.tests
     ]
```

```bash
cabal test shomei-core:test
```

Expected (excerpt):

```text
PasswordBreachChecker pure helpers
  sha1PrefixSuffix of "password" has prefix 5BAA6: OK
  ...
All N tests passed
```

### Step M3.1 — the shared guard helper

Add the helper. Recommended location: a small shared util. The simplest place that both
`Shomei.Workflow` and `Shomei.Workflow.Account` can import without a cycle is a new tiny module
`shomei-core/src/Shomei/Workflow/Breach.hs` (register in `exposed-modules`). Alternatively, if a
shared `Shomei.Workflow.Session`-style util module is already imported by both, add it there.

```haskell
{- | EP-3: the effectful breach-policy guard, appended to every password-accepting workflow
after the pure 'Shomei.Domain.Password.validatePassword' step. Honors the EP-1 policy flags:
no-op when disabled; rejects breached passwords; on an unreachable checker, fails open or
closed per 'breachCheckFailClosed'.
-}
module Shomei.Workflow.Breach (enforceBreachPolicy) where

import Shomei.Prelude

import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.Password (PasswordPolicy (..), PlainPassword)
import Shomei.Error (AuthError (..), PasswordPolicyViolation (..))
import Shomei.Effect.PasswordBreachChecker (BreachResult (..), PasswordBreachChecker, checkPasswordBreached)

enforceBreachPolicy ::
    (PasswordBreachChecker :> es, Error AuthError :> es) =>
    PasswordPolicy ->
    PlainPassword ->
    Eff es ()
enforceBreachPolicy policy pw
    | not policy.breachCheckEnabled = pure ()
    | otherwise = do
        r <- checkPasswordBreached pw
        case r of
            NotBreached -> pure ()
            Breached -> throwError (WeakPassword PasswordBreached)
            BreachCheckUnavailable ->
                if policy.breachCheckFailClosed
                    then throwError (WeakPassword PasswordBreached)
                    else pure ()
```

Note on the `Error AuthError :> es` constraint: inside the workflows, `runErrorNoCallStack`
introduces `Error AuthError` into `es` for the body, so calling `enforceBreachPolicy` there
satisfies the constraint. The workflow's OWN top-level signature does not need to list
`Error AuthError` (it lists `PasswordBreachChecker :> es` and discharges `Error AuthError` via
`runErrorNoCallStack`); `enforceBreachPolicy` is called from inside that `do` block where the
error effect is in scope. Confirm against the existing `throwError` usage in each workflow —
they already call `throwError` in the same block, so the constraint is satisfiable.

### Step M3.2 — call the guard in `signup`

Edit `shomei-core/src/Shomei/Workflow.hs`. Add the constraint:

```diff
     , PasswordHasher :> es
+    , PasswordBreachChecker :> es
     , TokenSigner :> es
```

Add imports:

```diff
 import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPassword)
+import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
 ...
 import Shomei.Workflow.Session (buildClaims, issueSession)
+import Shomei.Workflow.Breach (enforceBreachPolicy)
```

Append the guard right after the existing validation line:

```diff
     either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.password)
+    enforceBreachPolicy cfg.passwordPolicy cmd.password
     existing <- findUserByEmail email
```

### Step M3.3 — call the guard in `confirmPasswordReset` and `changePassword`

Edit `shomei-core/src/Shomei/Workflow/Account.hs`. Add imports:

```diff
 import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPassword)
+import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
 ...
+import Shomei.Workflow.Breach (enforceBreachPolicy)
```

In `confirmPasswordReset`, add the constraint and the guard:

```diff
     ( PasswordResetTokenStore :> es
     , CredentialStore :> es
     , PasswordHasher :> es
+    , PasswordBreachChecker :> es
     , SessionStore :> es
 ...
     either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.newPassword)
+    enforceBreachPolicy cfg.passwordPolicy cmd.newPassword
     ts <- now
```

In `changePassword`, add the constraint and the guard:

```diff
     ( UserStore :> es
     , CredentialStore :> es
     , PasswordHasher :> es
+    , PasswordBreachChecker :> es
     , SessionStore :> es
 ...
     either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.newPassword)
+    enforceBreachPolicy cfg.passwordPolicy cmd.newPassword
     user <- maybe (throwError InvalidCredentials) pure =<< findUserById cmd.userId
```

If EP-2 has reshaped the validation line, append `enforceBreachPolicy` AFTER whatever pure
validation now exists — the guard is independent of the pure check.

```bash
cabal build all
```

### Step M3.4 — behavioral workflow tests

Add tests (extend `shomei-core/test/Shomei/AccountSpec.hs` or add to `BreachSpec.hs` with an
in-memory harness section; they need `runInMemory`, `World`, `emptyWorld`). Build a config
variant with the flag on:

```haskell
import Data.Set qualified as Set
import Data.IORef (modifyIORef', newIORef)
import Shomei.Config (ShomeiConfig (..))
import Shomei.Domain.Password (PasswordPolicy (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Error (AuthError (..), PasswordPolicyViolation (..))
import Shomei.Workflow (signup)
import Shomei.Domain.Command (SignupCommand (..))

breachCfg :: ShomeiConfig
breachCfg = cfg{passwordPolicy = cfg.passwordPolicy{breachCheckEnabled = True}}

breachCfgFailClosed :: ShomeiConfig
breachCfgFailClosed =
    cfg{passwordPolicy = cfg.passwordPolicy{breachCheckEnabled = True, breachCheckFailClosed = True}}

pwnedPw :: PlainPassword
pwnedPw = PlainPassword "correct horse battery staple"  -- treated as breached by seeding the World
```

Tests (sketch — adapt to the existing tasty tree style):

```haskell
testCase "signup rejects a breached password when the check is enabled" $ do
    ref <- newIORef (emptyWorld fixedTime)
    modifyIORef' ref (\w -> w{breachedPasswords = Set.insert pw w.breachedPasswords})
    r <- runInMemory ref (signup breachCfg (SignupCommand aliceEmail pwnedPw Nothing))
    r @?= Left (WeakPassword PasswordBreached)
  where PlainPassword pw = pwnedPw

testCase "signup accepts a clean password when the check is enabled" $ do
    ref <- newIORef (emptyWorld fixedTime)   -- empty breach set
    r <- runInMemory ref (signup breachCfg (SignupCommand aliceEmail pwnedPw Nothing))
    assertBool "expected Right" (isRight r)

testCase "signup allows a breached password when the check is DISABLED" $ do
    ref <- newIORef (emptyWorld fixedTime)
    modifyIORef' ref (\w -> w{breachedPasswords = Set.insert pw w.breachedPasswords})
    r <- runInMemory ref (signup cfg (SignupCommand aliceEmail pwnedPw Nothing))  -- default cfg: flag off
    assertBool "expected Right" (isRight r)
  where PlainPassword pw = pwnedPw

testCase "fail-OPEN: unavailable checker allows the password" $ do
    ref <- newIORef (emptyWorld fixedTime)
    modifyIORef' ref (\w -> w{breachCheckAvailable = False})
    r <- runInMemory ref (signup breachCfg (SignupCommand aliceEmail pwnedPw Nothing))
    assertBool "expected Right" (isRight r)

testCase "fail-CLOSED: unavailable checker rejects the password" $ do
    ref <- newIORef (emptyWorld fixedTime)
    modifyIORef' ref (\w -> w{breachCheckAvailable = False})
    r <- runInMemory ref (signup breachCfgFailClosed (SignupCommand aliceEmail pwnedPw Nothing))
    r @?= Left (WeakPassword PasswordBreached)
```

Add analogous (at least one each) tests for `confirmPasswordReset` and `changePassword`
following the existing patterns in `AccountSpec.hs` (which already exercise both via the
in-memory harness — reuse the token-generation flow shown there).

```bash
cabal test shomei-core:test
```

### Step M4.1 — the production HIBP interpreter

Recommended placement: a new module `shomei-server/src/Shomei/Server/BreachChecker.hs` (or
inline in `App.hs`). Add it to `shomei-server`'s `exposed-modules`.

```haskell
{-# LANGUAGE DataKinds #-}

{- | EP-3 production interpreter for 'PasswordBreachChecker': a HIBP Pwned Passwords range
query using k-anonymity. Only the 5-char SHA-1 prefix leaves the process. Constructed once at
startup with a shared TLS 'Manager' and a fixed per-call timeout (from the policy), because the
interpreter is built once when the effect stack is assembled.
-}
module Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp) where

import Shomei.Prelude

import Control.Exception (SomeException, try)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)

import Network.HTTP.Client (
    Manager,
    Request (..),
    httpLbs,
    parseRequest,
    responseBody,
    responseTimeoutMicro,
 )
import Network.HTTP.Types.Header (hUserAgent)

import qualified Data.ByteString.Lazy as LBS

import Shomei.Effect.PasswordBreachChecker (
    BreachResult (..),
    PasswordBreachChecker (..),
    parseHibpResponse,
    sha1PrefixSuffix,
 )

{- | Build the interpreter from a shared TLS manager and a timeout in milliseconds (pass
@cfg.passwordPolicy.breachCheckTimeoutMs@ at assembly time).
-}
runPasswordBreachCheckerHibp ::
    (IOE :> es) => Manager -> Int -> Eff (PasswordBreachChecker : es) a -> Eff es a
runPasswordBreachCheckerHibp mgr timeoutMs = interpret_ \case
    CheckPasswordBreached plain -> liftIO do
        let (prefix, suffix) = sha1PrefixSuffix plain
        result <- try (queryRange mgr timeoutMs prefix) :: IO (Either SomeException Text)
        pure case result of
            Left _ -> BreachCheckUnavailable
            Right body -> if parseHibpResponse body suffix then Breached else NotBreached

queryRange :: Manager -> Int -> Text -> IO Text
queryRange mgr timeoutMs prefix = do
    base <- parseRequest ("https://api.pwnedpasswords.com/range/" <> Text.unpack prefix)
    let req =
            base
                { requestHeaders =
                    ("Add-Padding", "true")
                        : (hUserAgent, "shomei")
                        : requestHeaders base
                , responseTimeout = responseTimeoutMicro (timeoutMs * 1000)
                }
    resp <- httpLbs req mgr
    pure (TE.decodeUtf8 (LBS.toStrict (responseBody resp)))
```

Notes: `httpLbs` throws `HttpException` on transport errors and timeouts; the `try @SomeException`
catches both, yielding `BreachCheckUnavailable` (which the policy then resolves to allow/reject).
The timeout is baked in at construction from the config — acceptable because the stack is
assembled once per process.

### Step M4.2 — add build-deps to `shomei-server`

`shomei-server` already has `http-types`; it lacks `http-client`, `http-client-tls`, and
`crypton`. Edit the library `build-depends` in `shomei-server/shomei-server.cabal`:

```diff
   build-depends:
     , aeson
     , base                  >=4.18 && <5
     , bytestring
     , containers
+    , crypton
     , effectful
     , effectful-core
     , hasql-pool
+    , http-client
+    , http-client-tls
     , http-types
```

(`crypton` is needed transitively only if SHA-1 is computed here; it is computed in
`Shomei.Effect.PasswordBreachChecker.sha1PrefixSuffix` which lives in `shomei-core`, so the
SHA-1 dep is already satisfied via `shomei-core`. Add `crypton` to `shomei-server` only if the
interpreter module imports `Crypto.*` directly — in the code above it does NOT, so `crypton` may
be omitted from `shomei-server`. Add it only if a direct import appears.)

Add the new module to `exposed-modules`:

```diff
     Shomei.Server.App
+    Shomei.Server.BreachChecker
     Shomei.Server.Boot
```

### Step M4.3 — wire into `runAppIO` and both `AppEffects` lists

In `shomei-server/src/Shomei/Server/App.hs`, add `PasswordBreachChecker` to `AppEffects`
immediately before `PasswordHasher`:

```diff
      , WebAuthnCeremony
+     , PasswordBreachChecker
      , PasswordHasher
      , TokenSigner
```

The interpreter needs a TLS `Manager`. Construct one at startup with
`Network.HTTP.Client.TLS.newTlsManager` and add it to `Env` (e.g. `envHttpManager :: !Manager`),
or construct it where `runAppIO`'s caller assembles `Env`. Then add to the composition in
`runAppIO`, immediately above `runPasswordHasherCrypto`:

```diff
         . runPasswordHasherCrypto
+        . runPasswordBreachCheckerHibp env.envHttpManager (env.envConfig.passwordPolicy.breachCheckTimeoutMs)
         . runWebAuthnCeremonyLibrary (webauthnConfig env.envConfig)
```

Wait — order must match the list. Since `PasswordBreachChecker` sits BEFORE `PasswordHasher` in
the list (more outer), its interpreter is applied AFTER (later in the `.` chain) — i.e. it must
appear ABOVE `runPasswordHasherCrypto`:

```diff
         . runTokenSignerJwt env.envKey env.envConfig
+        . runPasswordBreachCheckerHibp env.envHttpManager env.envConfig.passwordPolicy.breachCheckTimeoutMs
         . runPasswordHasherCrypto
         . runWebAuthnCeremonyLibrary (webauthnConfig env.envConfig)
```

(Mirror the in-memory ordering: `PasswordBreachChecker` just before `PasswordHasher` in the
list, its `run` just above `runPasswordHasher*` in the chain. The compiler will reject a
mismatch.)

In `shomei-servant/src/Shomei/Servant/Seam.hs`, add `PasswordBreachChecker` to the `AppEffects`
list in the SAME position, and add the import `import Shomei.Effect.PasswordBreachChecker
(PasswordBreachChecker)`:

```diff
      , WebAuthnCeremony
+     , PasswordBreachChecker
      , PasswordHasher
```

The servant test harness (`shomei-servant/test/Main.hs`) and the server E2E harness
(`shomei-server/test/Shomei/Server/E2ESpec.hs`) build their stacks by composing the in-memory
fakes in the `AppEffects` order; they must add `. runPasswordBreachCheckerFake ref` in the
matching position so the harness composition still lines up with the extended `AppEffects`.
Grep for where each harness composes the fakes:

```bash
grep -rn "runPasswordHasher\b\|runWebAuthnCeremonyFake" shomei-servant/test shomei-server/test
```

Add `runPasswordBreachCheckerFake ref` just above `runPasswordHasher ref` in each. With
`breachCheckEnabled` defaulting to `False`, the fake is never consulted, so no servant test
behavior changes.

Also update `shomei-postgres/test/Main.hs` if it assembles a hybrid stack including
`PasswordHasher` (it imports `runPasswordHasherCrypto`); add the breach interpreter (the fake or
a no-op) in the matching slot to keep its stack aligned.

```bash
cabal build all
cabal test all
```

### Step M4.4 — optional manual integration check (NOT in the default suite)

In `cabal repl shomei-server` (requires network):

```haskell
:set -XOverloadedStrings
import Network.HTTP.Client.TLS (newTlsManager)
import Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp)
import Shomei.Effect.PasswordBreachChecker (checkPasswordBreached)
import Shomei.Domain.Password (PlainPassword (..))
import Effectful (runEff)
mgr <- newTlsManager
runEff (runPasswordBreachCheckerHibp mgr 2000 (checkPasswordBreached (PlainPassword "password")))
-- expected: Breached
runEff (runPasswordBreachCheckerHibp mgr 2000 (checkPasswordBreached (PlainPassword "an-extremely-unlikely-passphrase-9f3a2b")))
-- expected: NotBreached
```


## Validation and Acceptance

Acceptance is behavioral, exercised through the hermetic in-memory fake (no network):

- **Enabled + breached → rejected.** With `breachCheckEnabled = True` and the `World`'s
  `breachedPasswords` containing the password, `signup` (and `changePassword`,
  `confirmPasswordReset`) return `Left (WeakPassword PasswordBreached)`.
- **Enabled + clean → accepted.** With the flag on and the password NOT in the breach set,
  `signup` succeeds (`Right`).
- **Disabled → allowed.** With `breachCheckEnabled = False` (the default), a password in the
  breach set is accepted, proving the flag gates the check (and that the default suite's
  existing tests are unaffected).
- **Fail-open.** With the flag on and `breachCheckAvailable = False` (simulated unavailability)
  and `breachCheckFailClosed = False`, the password is allowed.
- **Fail-closed.** Same unavailability with `breachCheckFailClosed = True`, the password is
  rejected with `PasswordBreached`.
- **Pure-parser unit tests.** `sha1PrefixSuffix (PlainPassword "password")` has prefix `"5BAA6"`
  and a 35-char suffix; `parseHibpResponse` returns `True` for a present suffix with count > 0,
  `False` for count 0 (padding) and for an absent suffix.

Commands and expected results:

```bash
cabal build all
cabal test shomei-core:test
cabal test all
```

All suites pass with no network access. The optional manual ghci check in Step M4.4 returns
`Breached` for `password` and `NotBreached` for an unlikely passphrase — run it by hand only.

The change is effective beyond compilation because the workflow tests demonstrate the new
rejection path end-to-end through the workflow + port + fake, and the disabled-case test proves
the gating.


## Idempotence and Recovery

Every edit is additive and re-runnable:

- Adding `PasswordBreached` is appending a constructor; re-applying is a no-op once present.
- Creating the effect module, the fake, and the production interpreter are new-file creations;
  if a file already exists from a prior partial run, reconcile by diffing against the snippets
  here rather than overwriting blindly.
- Adding `World` fields and `runInMemory` wiring are localized diffs; re-applying the same diff
  is idempotent.

Risks and their safety nets:

- **Effect-order mismatch in `runInMemory` / `runAppIO` / `Seam.AppEffects`.** If the type-level
  list order and the `.`-composition order disagree, GHC raises a type error naming the
  offending effect — the compiler catches it; fix the position so the breach checker sits just
  before `PasswordHasher` in every list and just above its `run` in every chain.
- **Non-exhaustive pattern match on `PasswordPolicyViolation`.** Any per-constructor match that
  forgot `PasswordBreached` is a compiler warning/error (the project builds with warnings); the
  servant mapping uses a `WeakPassword _` wildcard, so it is already safe.
- **Network flakiness.** Mitigated structurally: the production interpreter is excluded from the
  default `cabal test all`; all automated coverage uses the in-memory fake. The manual ghci
  check is opt-in.
- **EP-1 not landed.** Step 0's grep is the gate; if the `breachCheck*` fields are absent, stop
  and land EP-1 first. The plan's M1 and M2.1 (the constructor + the port + pure helpers) do not
  depend on EP-1 and may be done early, but M3 (`enforceBreachPolicy` reads the flags) requires
  the fields.


## Interfaces and Dependencies

New and modified interfaces at the end of each milestone (full module paths):

- `Shomei.Error` (M1): adds `PasswordBreached` to `PasswordPolicyViolation`. Derived `Eq`,
  `Show`, `FromJSON`, `ToJSON` (renders as the string `"PasswordBreached"`).

- `Shomei.Effect.PasswordBreachChecker` (M2), exposed-module in `shomei-core`:

  ```haskell
  data BreachResult = NotBreached | Breached | BreachCheckUnavailable  -- Eq, Show
  data PasswordBreachChecker :: Effect where
      CheckPasswordBreached :: PlainPassword -> PasswordBreachChecker m BreachResult
  type instance DispatchOf PasswordBreachChecker = Dynamic
  checkPasswordBreached :: (PasswordBreachChecker :> es) => PlainPassword -> Eff es BreachResult
  sha1PrefixSuffix :: PlainPassword -> (Text, Text)        -- (5-char prefix, 35-char suffix), uppercase hex
  parseHibpResponse :: Text -> Text -> Bool                -- body -> our suffix -> breached?
  ```

- `Shomei.Effect.InMemory` (M2): `World` gains `breachedPasswords :: !(Set Text)` and
  `breachCheckAvailable :: !Bool` (both seeded in `emptyWorld`: empty set, `True`); new exported
  interpreter `runPasswordBreachCheckerFake :: (IOE :> es) => IORef World -> Eff
  (PasswordBreachChecker : es) a -> Eff es a`; `runInMemory`'s effect list and composition gain
  `PasswordBreachChecker` just before `PasswordHasher`.

- `Shomei.Workflow.Breach` (M3), new exposed-module in `shomei-core`:

  ```haskell
  enforceBreachPolicy ::
      (PasswordBreachChecker :> es, Error AuthError :> es) =>
      PasswordPolicy -> PlainPassword -> Eff es ()
  ```

- `Shomei.Workflow.signup`, `Shomei.Workflow.Account.changePassword`,
  `Shomei.Workflow.Account.confirmPasswordReset` (M3): each gains `PasswordBreachChecker :> es`
  in its constraint list and calls `enforceBreachPolicy cfg.passwordPolicy <pw>` after the pure
  validation.

- `Shomei.Server.BreachChecker` (M4), new exposed-module in `shomei-server`:

  ```haskell
  runPasswordBreachCheckerHibp ::
      (IOE :> es) => Manager -> Int -> Eff (PasswordBreachChecker : es) a -> Eff es a
  ```

- `Shomei.Server.App.AppEffects` and `Shomei.Servant.Seam.AppEffects` (M4): both gain
  `PasswordBreachChecker` (before `PasswordHasher`); `runAppIO` composes
  `runPasswordBreachCheckerHibp` just above `runPasswordHasherCrypto`; the test harnesses
  (`shomei-servant/test/Main.hs`, `shomei-server/test/Shomei/Server/E2ESpec.hs`, and
  `shomei-postgres/test/Main.hs` if applicable) compose `runPasswordBreachCheckerFake` in the
  matching slot.

Libraries:

- `crypton` (>= 1.1.0) — SHA-1 via `Crypto.Hash (SHA1, hashWith)`; hex via
  `Data.ByteArray.Encoding (Base (Base16), convertToBase)`. Used by the pure helper in
  `shomei-core`. Add `crypton` (and `memory` if `Data.ByteArray.Encoding` is not re-exported by
  `crypton` in this workspace) to `shomei-core`'s `build-depends` if absent.
- `http-client` + `http-client-tls` — the HTTPS GET and TLS `Manager` for the production
  interpreter, added to `shomei-server`'s `build-depends`.
- `http-types` — already present in `shomei-server`; provides `hUserAgent` etc.
- `containers` — `Data.Set` for the `World` breach field (already a `shomei-core` dep via
  `Data.Map.Strict`).
