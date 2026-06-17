---
id: 21
slug: common-and-context-specific-weak-password-rejection
title: "Common and Context-Specific Weak Password Rejection"
kind: exec-plan
created_at: 2026-06-17T18:08:56Z
intention: "intention_01kvbc26dhenstms0kx006ceds"
master_plan: "docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md"
---

# Common and Context-Specific Weak Password Rejection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This ExecPlan (EP-2) adds two purely local, offline password checks to the Shōmei
authentication core so that obviously weak passwords are rejected before an account is
ever created or a password is ever changed.

After this change, a user who tries to sign up, change their password, or complete a
password reset with a password that is either (a) a well-known common password (for
example `password123`, `qwerty`, `iloveyou`) or (b) essentially their own identity
(their email local-part, their full email address, or their display name) is rejected
with a clear policy-violation error instead of having that password accepted.

You can see it working two ways. First, at the pure level: calling
`validatePassword policy context (PlainPassword "password")` returns
`Left PasswordTooCommon`, and `validatePassword policy context (PlainPassword "alice")`
when the context email is `alice@example.com` returns `Left PasswordResemblesIdentity`,
while a strong unrelated password such as `correct horse battery staple` returns
`Right ()`. Second, at the workflow level: running `signup` over the in-memory test
harness with a common password returns `Left (WeakPassword PasswordTooCommon)`, and with
a password equal to the email local-part returns
`Left (WeakPassword PasswordResemblesIdentity)`. At the HTTP layer these both surface as
the existing `400 weak_password` response (the Servant mapping already collapses all
`WeakPassword _` variants to one response — see Context).

Both checks are individually toggleable. They are gated by two boolean policy flags that
the foundation plan EP-1 adds to `PasswordPolicy`: `rejectCommonPasswords` (default
`True`) and `rejectContextualPasswords` (default `True`). With either flag set to
`False`, the corresponding check is skipped, so an operator who wants the old behavior
can opt out.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Pre-flight: confirm EP-1 (`docs/plans/20-configurable-password-policy-end-to-end.md`)
      is Complete and that `rejectCommonPasswords` and `rejectContextualPasswords` exist
      on `PasswordPolicy` in `shomei-core/src/Shomei/Domain/Password.hs`.
- [ ] M1: Add `PasswordResemblesIdentity` constructor to `PasswordPolicyViolation` in
      `shomei-core/src/Shomei/Error.hs`; grep the repo for every match site; verify the
      Servant mapping covers it; `cabal build all` clean (no non-exhaustive warnings).
- [ ] M2: Create `shomei-core/data/common-passwords.txt`; add the `file-embed` dependency
      and `data` source to `shomei-core/shomei-core.cabal`; create
      `shomei-core/src/Shomei/Domain/CommonPasswords.hs` exporting `isCommonPassword`;
      add the pure `Shomei.Domain.PasswordSpec` test module and register it in `Main.hs`.
- [ ] M3: Add `PasswordContext`; change `validatePassword` to be context-aware; thread
      context through `signup`, `changePassword`, and `confirmPasswordReset`; add
      workflow-level tests; run `cabal test all` and fix any newly-failing fixtures.
- [ ] Final: full `cabal build all` and `cabal test all` green; Decision Log, Surprises,
      and Outcomes updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Reuse the existing `PasswordTooCommon` constructor for the common-password
  check and add exactly one new constructor, `PasswordResemblesIdentity`, for the
  contextual check.
  Rationale: `PasswordTooCommon` already exists in `PasswordPolicyViolation` but is never
  produced today; this plan makes it real. Appending one constructor keeps the sum type
  append-only and avoids churn for the sibling HIBP plan
  (`docs/plans/22-...-hibp-...`), which will separately append `PasswordBreached`.
  Date: 2026-06-17

- Decision: Matching semantics — Common: case-insensitive exact membership in the bundled
  dictionary, comparing the trimmed-and-lowercased password against trimmed-and-lowercased
  dictionary entries. This is exact list membership, NOT a substring scan.
  Rationale: Exact membership is fast (set lookup), predictable, and free of false
  positives. Substring scanning a 10k-entry list would reject legitimate passphrases that
  merely contain a common word.
  Date: 2026-06-17

- Decision: Matching semantics — Contextual: reject when the trimmed-and-lowercased
  password is exactly equal to any of: the email local-part (text before the first `@`),
  the full email address, or the display name. No substring or suffix rules in the first
  cut.
  Rationale: A conservative, clearly-testable equality rule avoids false positives (a
  containment rule risks rejecting a long passphrase that happens to contain a short
  display name). The rule is documented and easy to extend later if needed.
  Date: 2026-06-17

- Decision: `confirmPasswordReset` will load the user via `UserStore`/`findUserById
  tok.userId` so contextual checks apply consistently across all three call sites; the
  workflow gains a `UserStore :> es` constraint.
  Rationale: Consistency — a reset should reject an identity-derived password just like
  signup and change do. The token already carries `tok.userId`, and `UserStore` is an
  existing in-process effect, so the cost is one extra lookup, not a network call.
  Date: 2026-06-17

- Decision: Use `Data.Set Text` from `containers` (already a dependency) for the
  dictionary rather than `Data.HashSet` from `unordered-containers`.
  Rationale: `containers` is already in `shomei-core` build-depends;
  `unordered-containers` is not. `Data.Set` membership is O(log n) which is more than
  fast enough for a one-time per-request check, and it avoids adding a dependency.
  Date: 2026-06-17

- Decision: Bundle a starter `common-passwords.txt` with a few hundred well-known entries
  and leave a prominent header comment instructing the operator to replace/extend it with
  a full top-10k list (e.g. SecLists `10-million-password-list-top-10000`).
  Rationale: The implementing agent cannot reliably fetch a remote list; a curated starter
  list makes the feature functional and testable immediately, and the header documents how
  to harden it for production.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the codebase.

Shōmei is a transport-agnostic authentication toolkit written in Haskell (GHC 9.12.4),
organized as a Cabal workspace. It is built with `cabal build all` and tested with
`cabal test all`. The relevant package is `shomei-core`, whose tests are run with
`cabal test shomei-core:shomei-core-test`. The test framework is `tasty` with
`tasty-hunit`.

The effect system is `effectful` (dynamic dispatch). Workflows are functions that take a
`ShomeiConfig` and a command, run inside `runErrorNoCallStack do { ... }`, and use
`throwError` to short-circuit with an `AuthError`. Effects appear as constraints of the
form `UserStore :> es`, `PasswordHasher :> es`, and so on. You do not need to understand
`effectful` deeply; you only need to add the threading of a new argument and (in one
place) add one effect constraint.

Key files and what lives in them:

- `shomei-core/src/Shomei/Domain/Password.hs` — the password types and the pure policy
  validator. `PlainPassword` is `newtype PlainPassword = PlainPassword Text` with a
  redacting `Show` and deliberately no JSON instances (so secrets are never logged or
  serialized). `PasswordPolicy` is the record of policy knobs. `validatePassword` is the
  pure function this plan makes context-aware. NOTE: this module is where EP-1 adds the
  `rejectCommonPasswords` and `rejectContextualPasswords` boolean fields; verify they
  exist before starting (see Pre-flight in Concrete Steps).

- `shomei-core/src/Shomei/Error.hs` — the error vocabulary. `PasswordPolicyViolation` is
  the reason a password failed the policy check, and `AuthError` wraps it with the
  `WeakPassword PasswordPolicyViolation` constructor. Today `PasswordPolicyViolation` has
  `PasswordTooShort Int`, `PasswordTooLong Int`, `PasswordTooCommon`, and
  `PasswordMissingRequiredClass Text`. It derives `(Generic, Eq, Show)` and anyclass
  `(FromJSON, ToJSON)`.

- `shomei-core/src/Shomei/Config.hs` — `ShomeiConfig` carries the `passwordPolicy` field;
  it re-exports `PasswordPolicy` from `Shomei.Domain.Password`. Workflows read
  `cfg.passwordPolicy`.

- `shomei-core/src/Shomei/Domain/Email.hs` — `Email` is a normalized email newtype;
  `mkEmail` trims and lowercases; `emailText :: Email -> Text` recovers the raw text. The
  email is already lowercased, which matters for the contextual comparison.

- `shomei-core/src/Shomei/Domain/User.hs` — `User` has fields `email :: !Email` and
  `displayName :: !(Maybe Text)`. These supply the contextual values for change/reset.

- `shomei-core/src/Shomei/Workflow.hs` — contains `signup`. Around line 110-114, after
  building `email` it currently calls
  `either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.password)`.
  The `SignupCommand` carries `cmd.email :: Email`, `cmd.password :: PlainPassword`, and
  `cmd.displayName :: Maybe Text`.

- `shomei-core/src/Shomei/Workflow/Account.hs` — contains `changePassword` (around line
  196-207) and `confirmPasswordReset` (around line 171-182). `changePassword` currently
  validates `cmd.newPassword` BEFORE looking up the user; `confirmPasswordReset` validates
  at the top and then looks up the reset token `tok` (which carries `tok.userId`) but does
  NOT load the user and does not have a `UserStore` constraint today.

- `shomei-servant/src/Shomei/Servant/Error.hs` — the single mapping from `AuthError` to
  servant's `ServerError`. The relevant line is
  `WeakPassword _ -> json err400 "weak_password" "Password does not meet policy"`. This is
  a uniform wildcard branch over ALL `PasswordPolicyViolation` variants, so a newly added
  constructor is automatically covered with no code change required — but this MUST be
  verified by grepping (see M1).

- `shomei-core/test/` — the test tree. `Main.hs` is the tasty entry point that assembles
  a `testGroup` from each spec's `tests`. `shomei-core/test/Shomei/WorkflowSpec.hs` and
  `shomei-core/test/Shomei/AccountSpec.hs` build a fresh `IORef World` via
  `emptyWorld fixedTime`, run workflows with `runInMemory ref`, and inspect state with
  `readIORef`. Shared fixtures include `aliceEmail` (`alice@example.com`), `strongPw`
  (`PlainPassword "correct horse battery staple"`), helper `expectRight`, and (in
  WorkflowSpec) `ctxFor`. The in-memory `PasswordHasher` fake hashes to
  `"argon2-fake:" <> pw`.

- `shomei-migrations/src/Shomei/Migrations.hs` and `shomei-migrations/shomei-migrations.cabal`
  — the existing precedent for compile-time file embedding. The cabal depends on
  `file-embed >=0.0.15 && <0.0.17`, lists the embedded files under
  `extra-source-files: sql-migrations/*.sql`, and the module enables `TemplateHaskell` and
  imports `Data.FileEmbed (embedDir)`. EP-2 mirrors this approach for a single text file.

Terms used in this plan:

- "Common password" — a password appearing in a bundled dictionary (a plain-text file,
  one entry per line) of the most frequently used passwords. The check is exact membership
  of the normalized password in that set.

- "Contextual" / "identity-derived" password — a password that is essentially the user's
  own identity: the local-part of their email (the text before `@`), the full email, or
  their display name.

- "Dictionary" — the bundled `shomei-core/data/common-passwords.txt` file, embedded at
  compile time and parsed into a `Data.Set Text` of normalized (trimmed, lowercased)
  entries.

Relationship to sibling plans (reference only; do not edit them):

- Parent MasterPlan:
  `docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md`.
- HARD dependency: `docs/plans/20-configurable-password-policy-end-to-end.md` (EP-1) must
  be Complete first. EP-1 adds the `rejectCommonPasswords` and `rejectContextualPasswords`
  flags to `PasswordPolicy`; without them, this plan will not compile.
- SOFT relationship: `docs/plans/22-...-hibp-...` (EP-3) edits the same three workflow call
  sites and the same `PasswordPolicyViolation` sum type (it appends `PasswordBreached`).
  EP-2 is recommended to land FIRST to minimize merge friction.


## Plan of Work

The work is three milestones, each independently buildable and verifiable. Before M1, do
the pre-flight check that EP-1's policy fields exist.

### Milestone M1 — Add the `PasswordResemblesIdentity` violation and verify error mapping

Scope: append the new constructor to `PasswordPolicyViolation` in
`shomei-core/src/Shomei/Error.hs`, then prove nothing else breaks. At the end, the type
exists, the whole workspace compiles, and the Servant layer maps the new violation
correctly (it already does via the `WeakPassword _` wildcard, but this must be confirmed by
grep so a future per-constructor match is not silently missed).

Commands: `cabal build all`. Acceptance: clean build with no
`-Wincomplete-patterns`/non-exhaustive-match warnings anywhere `PasswordPolicyViolation` is
pattern-matched. Grep across the repo for `PasswordTooCommon` and
`PasswordMissingRequiredClass` to enumerate every match site; confirm each either uses a
wildcard or has been given a `PasswordResemblesIdentity` branch.

### Milestone M2 — Common-password dictionary module and pure tests

Scope: add `file-embed` to `shomei-core.cabal`, create the data file and the
`Shomei.Domain.CommonPasswords` module exposing `isCommonPassword :: Text -> Bool`, and add
the pure `Shomei.Domain.PasswordSpec` test module registered in `Main.hs`. At the end,
`isCommonPassword "password"` is `True`, `isCommonPassword "correct horse battery staple"`
is `False`, and the pure spec compiles and runs.

Commands: `cabal build shomei-core` then `cabal test shomei-core:shomei-core-test`.
Acceptance: the new `Shomei.Domain.PasswordSpec` group is present in the test output and
passes; the dictionary set is non-empty.

Note this milestone introduces `validatePassword`'s new signature only AFTER M3 changes it;
in M2 the pure spec exercises `isCommonPassword` directly and may also exercise the
still-old `validatePassword` for the length cases. It is cleaner to write the pure
`validatePassword` tests in M3 once the signature is final; in M2 just test
`isCommonPassword`.

### Milestone M3 — Context-aware validator threaded through the three workflows

Scope: introduce `PasswordContext`, rewrite `validatePassword` to take it, and update the
three call sites (`signup`, `changePassword`, `confirmPasswordReset`). Add the
`UserStore :> es` constraint and a `findUserById tok.userId` lookup to
`confirmPasswordReset`. Add the pure `validatePassword` cases to
`Shomei.Domain.PasswordSpec` and add workflow-level rejection tests. At the end, all three
workflows reject common and identity-derived passwords (subject to the policy flags) and a
strong password still succeeds.

Commands: `cabal build all` then `cabal test all`. Acceptance: pure spec covers
too-short, too-long, common -> `Left PasswordTooCommon`, identity -> `Left
PasswordResemblesIdentity`, strong -> `Right ()`, and that flags disabled let those
passwords through; workflow tests show `signup`/`changePassword`/`confirmPasswordReset`
returning `Left (WeakPassword PasswordTooCommon)` and `Left (WeakPassword
PasswordResemblesIdentity)`; the full suite is green after any fixture fixes.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`.

### Pre-flight: confirm EP-1 is Complete

Read `shomei-core/src/Shomei/Domain/Password.hs` and confirm `PasswordPolicy` contains both
fields. They must look like this (added by EP-1):

```haskell
data PasswordPolicy = PasswordPolicy
    { minLength :: !Int
    , maxLength :: !Int
    , rejectCommonPasswords :: !Bool
    , rejectContextualPasswords :: !Bool
    -- ... possibly other EP-1 fields ...
    }
```

If these fields are absent, STOP: EP-1 is not done and EP-2 cannot proceed. Do not add the
fields yourself — that is EP-1's responsibility.

### M1 — Add `PasswordResemblesIdentity`

Edit `shomei-core/src/Shomei/Error.hs`. Change the `PasswordPolicyViolation` declaration
from:

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

to:

```haskell
data PasswordPolicyViolation
    = -- | minimum length required
      PasswordTooShort Int
    | -- | maximum length allowed
      PasswordTooLong Int
    | -- | the password appears in the bundled common-password dictionary
      PasswordTooCommon
    | PasswordMissingRequiredClass Text
    | -- | the password is essentially the user's own identity (email local-part,
      -- full email, or display name)
      PasswordResemblesIdentity
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

Then enumerate every place the type is matched:

```bash
grep -rn "PasswordTooCommon\|PasswordMissingRequiredClass\|PasswordPolicyViolation\|WeakPassword" --include="*.hs" .
```

Expected: the only non-test pattern-match over the violation type is the wildcard in
`shomei-servant/src/Shomei/Servant/Error.hs` line ~42:

```haskell
    WeakPassword _ -> json err400 "weak_password" "Password does not meet policy"
```

Because this is a wildcard, `PasswordResemblesIdentity` is already covered — no edit
needed. Confirm there are no per-constructor matches anywhere (a per-constructor `case`
would otherwise emit a `-Wincomplete-patterns` warning, which the `-Wall` build promotes to
visible noise). Build:

```bash
cabal build all
```

Expected: clean build, no incomplete-pattern warnings touching `PasswordPolicyViolation`.

### M2 — Dictionary file, `file-embed` dependency, `CommonPasswords` module, pure spec

Create the data file `shomei-core/data/common-passwords.txt`. The first lines must be a
clearly-marked operator note (the `#` lines below are documentation only; the loader
ignores blank lines and lines starting with `#` — see the loader code), followed by the
starter entries, one per line, lowercased:

```text
# Shōmei bundled common-password dictionary (EP-2).
# Each non-blank, non-comment line is one common password, lowercased.
# THIS IS A STARTER LIST. For production, REPLACE or EXTEND it with a full
# top-10k list such as SecLists "10-million-password-list-top-10000"
# (https://github.com/danielmiessler/SecLists) and commit the larger file.
password
123456
123456789
12345678
12345
qwerty
abc123
password1
password123
iloveyou
admin
welcome
monkey
dragon
letmein
football
111111
123123
qwertyuiop
sunshine
master
000000
shadow
ashley
michael
superman
qazwsx
trustno1
hello
whatever
freedom
princess
starwars
login
passw0rd
zaq12wsx
baseball
000000
```

(The implementer may add more entries; the list above is a functional starter. Keep all
entries lowercased and trimmed.)

Edit `shomei-core/shomei-core.cabal`. Add the data file to the library's source inputs and
add the dependency. In the `library` stanza, add an `extra-source-files`/data line and add
`file-embed` to `build-depends`. Apply this diff:

```diff
@@ library
   import:          warnings, shared
   hs-source-dirs:  src
+  -- Embedded at compile time by Shomei.Domain.CommonPasswords via Template Haskell.
+  extra-source-files: data/common-passwords.txt
   exposed-modules:
     Shomei.Config
     Shomei.Domain.Claims
@@
     Shomei.Domain.Email
     Shomei.Domain.Event
+    Shomei.Domain.CommonPasswords
     Shomei.Domain.LoginAttempt
@@ build-depends:
     , containers
     , effectful
     , effectful-core
+    , file-embed       >=0.0.15 && <0.0.17
     , generic-lens
```

Note: `extra-source-files` is conventionally a top-level package field; if Cabal rejects
it inside the `library` stanza in this `cabal-version: 3.0` file, place it at the top level
of the package (as `shomei-migrations.cabal` does with `extra-source-files:
sql-migrations/*.sql`). Either way the file must be a declared source input so the
Template Haskell splice can read it and so `cabal sdist` includes it.

Create `shomei-core/src/Shomei/Domain/CommonPasswords.hs`:

```haskell
{- | The bundled common-password dictionary and the membership check.

The dictionary is embedded at COMPILE time from @data/common-passwords.txt@ via
Template Haskell ('embedStringFile'), parsed once into a 'Set' of normalized entries
(a top-level CAF), and queried by 'isCommonPassword'. Matching is case-insensitive
exact membership: the input is trimmed and lowercased, then looked up in the set. It is
NOT a substring scan.
-}
module Shomei.Domain.CommonPasswords (
    isCommonPassword,
    commonPasswordCount,
) where

import Shomei.Prelude

import Data.FileEmbed (embedStringFile)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text

-- | The raw embedded file contents (compile-time splice).
rawDictionary :: Text
rawDictionary = $(embedStringFile "data/common-passwords.txt")

{- | The dictionary as a set of normalized entries. Blank lines and lines beginning
with @#@ (comments / the operator note) are ignored. Built once as a CAF.
-}
commonPasswords :: Set Text
commonPasswords =
    Set.fromList
        [ normalized
        | line <- Text.lines rawDictionary
        , let normalized = Text.toLower (Text.strip line)
        , not (Text.null normalized)
        , not ("#" `Text.isPrefixOf` Text.strip line)
        ]

-- | Number of dictionary entries (used by tests to assert the set is non-empty).
commonPasswordCount :: Int
commonPasswordCount = Set.size commonPasswords

{- | Is the given password a known common password? Case-insensitive exact membership:
the input is trimmed and lowercased before lookup.
-}
isCommonPassword :: Text -> Bool
isCommonPassword pw = Text.toLower (Text.strip pw) `Set.member` commonPasswords
```

Confirm `embedStringFile`'s path is resolved relative to the package directory. The
`shomei-migrations` precedent uses `embedDir "sql-migrations"` with the directory under the
package root, so `embedStringFile "data/common-passwords.txt"` should likewise resolve
against the package root. If the build cannot find the file, switch to
`Data.FileEmbed.makeRelativeToProject "data/common-passwords.txt" >>= embedStringFile` (a
TH idiom that anchors the path at the directory containing the `.cabal` file).

Build the library:

```bash
cabal build shomei-core
```

Add the pure spec module `shomei-core/test/Shomei/Domain/PasswordSpec.hs`. In M2, populate
only the `isCommonPassword` cases; the `validatePassword` cases are added in M3 once the
signature is final. Skeleton:

```haskell
module Shomei.Domain.PasswordSpec (tests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Shomei.Domain.CommonPasswords (commonPasswordCount, isCommonPassword)

tests :: TestTree
tests =
    testGroup
        "Shomei.Domain.PasswordSpec"
        [ testCase "dictionary is non-empty" $
            assertBool "expected a non-empty common-password dictionary" (commonPasswordCount > 0)
        , testCase "a known common password is detected" $
            isCommonPassword "password" @?= True
        , testCase "case and whitespace are normalized" $
            isCommonPassword "  PASSWORD  " @?= True
        , testCase "a strong passphrase is not common" $
            isCommonPassword "correct horse battery staple" @?= False
        ]
```

Register the module in `shomei-core/shomei-core.cabal` test-suite `other-modules` and in
`shomei-core/test/Main.hs`:

```diff
@@ test-suite shomei-core-test
   other-modules:
     Shomei.AccountSpec
+    Shomei.Domain.PasswordSpec
     Shomei.LockoutSpec
```

```diff
@@ Main.hs
 import Shomei.AccountSpec qualified
+import Shomei.Domain.PasswordSpec qualified
 import Shomei.LockoutSpec qualified
@@
             [ Shomei.WorkflowSpec.tests
             , Shomei.AccountSpec.tests
+            , Shomei.Domain.PasswordSpec.tests
             , Shomei.LockoutSpec.tests
```

Run:

```bash
cabal test shomei-core:shomei-core-test
```

Expected (abbreviated): a `Shomei.Domain.PasswordSpec` group with all cases passing and the
rest of the suite unchanged and green.

### M3 — Context-aware `validatePassword` and workflow threading

Edit `shomei-core/src/Shomei/Domain/Password.hs`. Add the `PasswordContext` record, export
it, and rewrite `validatePassword`. New module head exports:

```haskell
module Shomei.Domain.Password (
    PlainPassword (..),
    PasswordHash (..),
    PasswordPolicy (..),
    PasswordContext (..),
    emptyPasswordContext,
    defaultPasswordPolicy,
    validatePassword,
) where
```

Add imports and definitions:

```haskell
import Shomei.Domain.CommonPasswords (isCommonPassword)

data PasswordContext = PasswordContext
    { contextEmail :: !(Maybe Text)
    -- ^ the user's email address (raw text), if known
    , contextDisplayName :: !(Maybe Text)
    -- ^ the user's display name, if any
    }
    deriving stock (Generic, Eq, Show)

-- | No identity context (length and common-password checks still apply).
emptyPasswordContext :: PasswordContext
emptyPasswordContext = PasswordContext{contextEmail = Nothing, contextDisplayName = Nothing}
```

Replace the validator. Check order: length (cheap, existing) first, then common (if
`policy.rejectCommonPasswords`), then contextual (if `policy.rejectContextualPasswords`):

```haskell
validatePassword ::
    PasswordPolicy -> PasswordContext -> PlainPassword -> Either PasswordPolicyViolation ()
validatePassword policy context (PlainPassword pw)
    | Text.length pw < policy.minLength = Left (PasswordTooShort policy.minLength)
    | Text.length pw > policy.maxLength = Left (PasswordTooLong policy.maxLength)
    | policy.rejectCommonPasswords && isCommonPassword pw = Left PasswordTooCommon
    | policy.rejectContextualPasswords && resemblesIdentity context pw = Left PasswordResemblesIdentity
    | otherwise = Right ()

{- | Does the password (trimmed, lowercased) exactly equal the user's email local-part,
full email, or display name (each trimmed, lowercased)? Exact equality only — no
substring rule, to avoid rejecting long passphrases that merely contain a short name.
-}
resemblesIdentity :: PasswordContext -> Text -> Bool
resemblesIdentity ctx pw =
    let p = Text.toLower (Text.strip pw)
        norm = Text.toLower . Text.strip
        emailCandidates = case ctx.contextEmail of
            Nothing -> []
            Just e -> let e' = norm e in [e', Text.takeWhile (/= '@') e']
        nameCandidates = maybe [] (\n -> [norm n]) ctx.contextDisplayName
     in not (Text.null p) && p `elem` (emailCandidates <> nameCandidates)
```

Now update the three call sites to pass a `PasswordContext`.

`shomei-core/src/Shomei/Workflow.hs`, in `signup` (around line 110-114). Build context from
the command's email and display name. The email is available as `cmd.email :: Email`, and
the local builds `email` from it; use `emailText cmd.email` for the raw text:

```diff
 signup cfg cmd = runErrorNoCallStack do
     email <- either throwError pure (mkEmail (emailText cmd.email))
-    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.password)
+    let pwContext =
+            PasswordContext
+                { contextEmail = Just (emailText email)
+                , contextDisplayName = cmd.displayName
+                }
+    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.password)
     existing <- findUserByEmail email
```

Ensure `Shomei.Workflow` imports `PasswordContext (..)` (or `PasswordContext`,
`contextEmail`, `contextDisplayName`) from `Shomei.Domain.Password`. It already imports
`validatePassword`; extend that import list.

`shomei-core/src/Shomei/Workflow/Account.hs`, in `changePassword` (around line 196-207).
The current code validates BEFORE looking up the user. Reorder so the user is loaded first,
then build context from `user.email`/`user.displayName`, then validate:

```diff
 changePassword cfg cmd = runErrorNoCallStack do
-    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.newPassword)
-    user <- maybe (throwError InvalidCredentials) pure =<< findUserById cmd.userId
+    user <- maybe (throwError InvalidCredentials) pure =<< findUserById cmd.userId
+    let pwContext =
+            PasswordContext
+                { contextEmail = Just (emailText user.email)
+                , contextDisplayName = user.displayName
+                }
+    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.newPassword)
     cred <- maybe (throwError InvalidCredentials) pure =<< findPasswordCredentialByEmail user.email
```

Reordering is safe: the only observable effect of moving validation after the user lookup
is that an unknown `userId` now returns `InvalidCredentials` before the password is
inspected — acceptable and arguably better, but note it in the Decision Log if any test
asserts on ordering. (No current test does.)

`shomei-core/src/Shomei/Workflow/Account.hs`, in `confirmPasswordReset` (around line
158-182). Add `UserStore :> es` to the constraint set and load the user from
`tok.userId` after resolving the token, then validate with context. The validation must
move to after the user is available:

```diff
 confirmPasswordReset ::
-    ( PasswordResetTokenStore :> es
+    ( UserStore :> es
+    , PasswordResetTokenStore :> es
     , CredentialStore :> es
     , PasswordHasher :> es
     , SessionStore :> es
     , RefreshTokenStore :> es
     , AuthEventPublisher :> es
     , Clock :> es
     , TokenGen :> es
     ) =>
     ShomeiConfig ->
     ConfirmPasswordReset ->
     Eff es (Either AuthError ())
 confirmPasswordReset cfg cmd = runErrorNoCallStack do
-    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.newPassword)
     ts <- now
     h <- hashOneTimeToken cmd.token
     tok <- maybe (throwError PasswordResetTokenInvalid) pure =<< findPasswordResetTokenByHash h
     either throwError pure (ensureUsableReset tok ts)
+    user <- maybe (throwError PasswordResetTokenInvalid) pure =<< findUserById tok.userId
+    let pwContext =
+            PasswordContext
+                { contextEmail = Just (emailText user.email)
+                , contextDisplayName = user.displayName
+                }
+    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.newPassword)
     newHash <- hashPassword cmd.newPassword
```

Ensure `Shomei.Workflow.Account` imports `findUserById` from the `UserStore` effect module
(it is already used by `changePassword`, so the import exists) and imports the
`PasswordContext` constructor and `emailText`. Resolving a missing user to
`PasswordResetTokenInvalid` keeps reset failures uniform and leaks nothing.

Now extend `shomei-core/test/Shomei/Domain/PasswordSpec.hs` with the pure
`validatePassword` cases. Use a small policy and context. The defaults from EP-1 enable
both flags; build a base policy explicitly so the test is self-documenting:

```haskell
import Shomei.Domain.Password (
    PasswordContext (..),
    PasswordPolicy (..),
    PlainPassword (..),
    defaultPasswordPolicy,
    validatePassword,
 )
import Shomei.Error (PasswordPolicyViolation (..))

aliceCtx :: PasswordContext
aliceCtx = PasswordContext{contextEmail = Just "alice@example.com", contextDisplayName = Just "Alice"}

basePolicy :: PasswordPolicy
basePolicy = defaultPasswordPolicy -- rejectCommonPasswords=True, rejectContextualPasswords=True
```

Cases to add to the `tests` list:

```haskell
        , testCase "too short" $
            validatePassword basePolicy aliceCtx (PlainPassword "short")
                @?= Left (PasswordTooShort basePolicy.minLength)
        , testCase "common password rejected" $
            validatePassword basePolicy aliceCtx (PlainPassword "password123")
                @?= Left PasswordTooCommon
        , testCase "email local-part rejected" $
            validatePassword basePolicy aliceCtx (PlainPassword "alice")
                @?= Left PasswordResemblesIdentity
        , testCase "full email rejected" $
            validatePassword basePolicy aliceCtx (PlainPassword "alice@example.com")
                @?= Left PasswordResemblesIdentity
        , testCase "display name rejected" $
            validatePassword basePolicy aliceCtx (PlainPassword "alice")
                @?= Left PasswordResemblesIdentity
        , testCase "strong unrelated password accepted" $
            validatePassword basePolicy aliceCtx (PlainPassword "correct horse battery staple")
                @?= Right ()
        , testCase "flags off let common and contextual through" $ do
            let off = basePolicy{rejectCommonPasswords = False, rejectContextualPasswords = False}
            validatePassword off aliceCtx (PlainPassword "password123") @?= Right ()
            validatePassword off aliceCtx (PlainPassword "alice@example.com") @?= Right ()
```

Note: pick test passwords whose LENGTH passes `minLength` (default 12) so the length check
does not pre-empt the common/contextual checks; `password123` is 11 characters, which is
SHORTER than the default `minLength` of 12 — it would return `PasswordTooShort` first. To
test the common branch in isolation, EITHER lower `minLength` in the test policy (e.g.
`basePolicy{minLength = 4}`) OR choose a common entry that is at least 12 characters. The
cleanest approach: use `basePolicy{minLength = 4}` for the common/contextual cases so the
length guard does not interfere. Update the snippets accordingly when implementing.

Add workflow-level tests. Put common-password and identity rejection tests for `signup`
in `shomei-core/test/Shomei/WorkflowSpec.hs` and for `changePassword`/`confirmPasswordReset`
in `shomei-core/test/Shomei/AccountSpec.hs`, reusing the existing harness. Pattern (signup
example), adding an `expectLeft` helper if one does not already exist:

```haskell
expectLeft :: (Show a) => Either e a -> (e -> IO ()) -> IO ()
expectLeft (Left e) k = k e
expectLeft (Right a) _ = assertFailure ("expected Left, got Right: " <> show a)

signupRejectsCommonPassword :: TestTree
signupRejectsCommonPassword = testCase "signup rejects a common password" $ do
    ref <- newIORef (emptyWorld fixedTime)
    res <- runInMemory ref (signup cfg (SignupCommand aliceEmail (PlainPassword "password123!extra") Nothing))
    res @?= Left (WeakPassword PasswordTooCommon)

signupRejectsIdentityPassword :: TestTree
signupRejectsIdentityPassword = testCase "signup rejects the email local-part as password" $ do
    ref <- newIORef (emptyWorld fixedTime)
    -- "alice" is shorter than minLength; either lower minLength via cfg or use a config
    -- whose policy has a small minLength for this test.
    res <- runInMemory ref (signup smallMinCfg (SignupCommand aliceEmail (PlainPassword "alice") Nothing))
    res @?= Left (WeakPassword PasswordResemblesIdentity)
```

Where the common-password used must satisfy `minLength`; pick a dictionary entry of
adequate length (add one such as `passwordpassword` to the dictionary) OR construct a
per-test `cfg` whose `passwordPolicy` has a small `minLength`. Define `smallMinCfg` in the
spec as `cfg{passwordPolicy = cfg.passwordPolicy{minLength = 4}}`. Mirror these for
`changePassword` and `confirmPasswordReset` using the existing reset-token fixtures in
`AccountSpec.hs`.

Build and test:

```bash
cabal build all
cabal test all
```

Fixture caveat (from the MasterPlan Decision Log): the EP-1 defaults flip
`rejectCommonPasswords` and `rejectContextualPasswords` to `True`. Verify the shared
fixtures still pass: `strongPw` is `"correct horse battery staple"` — confirmed NOT in the
starter dictionary and NOT derived from `alice@example.com` or any display name, so it
remains valid. If any other existing test password is in the dictionary or equals an
identity value, update that fixture to a strong unrelated password and note it in
Surprises. Run the full `cabal test all` and fix any fixture that newly fails.


## Validation and Acceptance

Acceptance is behavioral, not merely "it compiles."

Pure validator (run `cabal test shomei-core:shomei-core-test`):

- `validatePassword policy aliceCtx (PlainPassword "password123")` (with a policy whose
  `minLength` is small enough not to pre-empt) returns `Left PasswordTooCommon`.
- `validatePassword policy aliceCtx (PlainPassword "alice")` (email local-part of
  `alice@example.com`) returns `Left PasswordResemblesIdentity`; likewise the full email
  and the display name.
- `validatePassword policy aliceCtx (PlainPassword "correct horse battery staple")` returns
  `Right ()`.
- With `rejectCommonPasswords = False` and `rejectContextualPasswords = False`, the same
  common and identity passwords return `Right ()`, proving the flags gate behavior.

Workflow level (in-memory harness, same test command):

- `signup cfg (SignupCommand aliceEmail <common-pw> Nothing)` returns
  `Left (WeakPassword PasswordTooCommon)`.
- `signup smallMinCfg (SignupCommand aliceEmail (PlainPassword "alice") Nothing)` returns
  `Left (WeakPassword PasswordResemblesIdentity)`.
- `changePassword` and `confirmPasswordReset` with a common or identity-derived new
  password return the same `Left (WeakPassword ...)` values.

Build acceptance:

```bash
cabal build all
cabal test all
```

Expected: a clean build with no incomplete-pattern warnings, and a green suite including
the new `Shomei.Domain.PasswordSpec` group and the new workflow rejection tests. Sample
abbreviated transcript:

```text
shomei-core-test
  Shomei.WorkflowSpec
    signup rejects a common password:                    OK
    signup rejects the email local-part as password:     OK
  Shomei.Domain.PasswordSpec
    dictionary is non-empty:                              OK
    common password rejected:                             OK
    email local-part rejected:                            OK
    strong unrelated password accepted:                   OK
    flags off let common and contextual through:          OK

All N tests passed
```

HTTP mapping: no Servant change is required because
`shomei-servant/src/Shomei/Servant/Error.hs` maps all `WeakPassword _` variants to
`400 weak_password`. If the servant test suite asserts on weak-password rendering, confirm
`PasswordResemblesIdentity` reaches that branch (grep `shomei-servant/test/` for
`weak_password`/`WeakPassword`; add or adjust an assertion if one exists).


## Idempotence and Recovery

All edits are deterministic source edits and are safe to re-apply: re-running them yields
the same files. The build and test commands are likewise re-runnable.

Risks and recovery:

- Non-exhaustive pattern match: if any `case` over `PasswordPolicyViolation` is added
  without a `PasswordResemblesIdentity` branch, the `-Wall` build surfaces an
  incomplete-pattern warning. Recovery: add the missing branch (or a wildcard). The grep in
  M1 enumerates all match sites up front.
- `file-embed` path resolution: if the splice cannot find `data/common-passwords.txt`,
  switch to `makeRelativeToProject` (see M2) and rebuild. The data file and its
  `extra-source-files` entry must both be present.
- Newly-failing fixtures: if a previously-valid test password is now rejected by the
  default-on flags, the failing test names the exact assertion; replace that fixture with a
  strong unrelated password and re-run `cabal test all`. The known shared fixture
  `strongPw` already passes.
- `confirmPasswordReset` constraint change: adding `UserStore :> es` requires the
  in-memory and any production interpreter stacks to provide `UserStore`. The in-memory
  `runInMemory` already provides every store (used by `changePassword`), so existing tests
  keep working; confirm any standalone caller of `confirmPasswordReset` already runs under
  `UserStore`.


## Interfaces and Dependencies

New dependency:

- `file-embed` (version bound `>=0.0.15 && <0.0.17`, matching the
  `shomei-migrations` package) added to `shomei-core`'s `library` `build-depends`, used for
  the compile-time `embedStringFile` splice. `containers` (already a dependency) supplies
  `Data.Set` for the dictionary; no `unordered-containers` is added.

New / changed module interfaces (full paths):

- `Shomei.Error` (`shomei-core/src/Shomei/Error.hs`): `PasswordPolicyViolation` gains the
  nullary constructor `PasswordResemblesIdentity` (append-only; derives unchanged).

- `Shomei.Domain.CommonPasswords` (`shomei-core/src/Shomei/Domain/CommonPasswords.hs`, new):

  ```haskell
  isCommonPassword :: Text -> Bool
  commonPasswordCount :: Int
  ```

- `Shomei.Domain.Password` (`shomei-core/src/Shomei/Domain/Password.hs`):

  ```haskell
  data PasswordContext = PasswordContext
      { contextEmail :: !(Maybe Text)
      , contextDisplayName :: !(Maybe Text)
      }

  emptyPasswordContext :: PasswordContext

  validatePassword ::
      PasswordPolicy -> PasswordContext -> PlainPassword -> Either PasswordPolicyViolation ()
  ```

- `Shomei.Workflow` (`shomei-core/src/Shomei/Workflow.hs`): `signup`'s type is unchanged;
  its body now builds a `PasswordContext` and passes it to `validatePassword`.

- `Shomei.Workflow.Account` (`shomei-core/src/Shomei/Workflow/Account.hs`):
  `changePassword`'s type is unchanged (body reordered to load user first).
  `confirmPasswordReset` gains a `UserStore :> es` constraint; its final signature is:

  ```haskell
  confirmPasswordReset ::
      ( UserStore :> es
      , PasswordResetTokenStore :> es
      , CredentialStore :> es
      , PasswordHasher :> es
      , SessionStore :> es
      , RefreshTokenStore :> es
      , AuthEventPublisher :> es
      , Clock :> es
      , TokenGen :> es
      ) =>
      ShomeiConfig ->
      ConfirmPasswordReset ->
      Eff es (Either AuthError ())
  ```

Dependency on prior plans: this plan requires
`docs/plans/20-configurable-password-policy-end-to-end.md` (EP-1) to be Complete so that
`PasswordPolicy.rejectCommonPasswords` and `PasswordPolicy.rejectContextualPasswords`
exist. It shares the `PasswordPolicyViolation` type and the three workflow call sites with
`docs/plans/22-...-hibp-...` (EP-3) and is recommended to land first.

Every commit on this plan must carry these git trailers:

```text
MasterPlan: docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md
ExecPlan: docs/plans/21-common-and-context-specific-weak-password-rejection.md
Intention: intention_01kvbc26dhenstms0kx006ceds
```
