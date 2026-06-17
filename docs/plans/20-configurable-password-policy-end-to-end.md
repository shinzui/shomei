---
id: 20
slug: configurable-password-policy-end-to-end
title: "Configurable Password Policy End-to-End"
kind: exec-plan
created_at: 2026-06-17T18:08:56Z
intention: "intention_01kvbc26dhenstms0kx006ceds"
master_plan: "docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md"
---

# Configurable Password Policy End-to-End

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change an operator can tune Shōmei's password policy without recompiling: the
length bounds (`minLength`, `maxLength`) and five new policy flags become overridable through
a Dhall configuration file and through `SHOMEI_*` environment variables, on top of built-in
defaults. Concretely, a deployer can set `passwordMinLength = 16` in their Dhall file, or
export `SHOMEI_PASSWORD_MIN_LENGTH=20`, and the running server's
`cfg.passwordPolicy.minLength` will reflect that value with the documented precedence
(env beats file beats default).

This plan (EP-1) is the **foundation** for two sibling plans and deliberately stops short of
giving the new flags any teeth:

- `docs/plans/21-common-and-context-specific-weak-password-rejection.md` (EP-2) will consume
  `rejectCommonPasswords` and `rejectContextualPasswords`.
- `docs/plans/22-compromised-password-breach-checking-via-hibp-k-anonymity.md` (EP-3) will
  consume `breachCheckEnabled`, `breachCheckFailClosed`, and `breachCheckTimeoutMs`.

The parent MasterPlan is
`docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md`.

**Honest framing — the new flags are inert scaffolding in EP-1.** Adding
`rejectCommonPasswords`, `rejectContextualPasswords`, `breachCheckEnabled`,
`breachCheckFailClosed`, and `breachCheckTimeoutMs` to the policy record makes them *parse*
and *merge* through the whole config pipeline, but **they do not yet gate any password
check** — `validatePassword` still only enforces length. EP-2 and EP-3 give the flags
behavior. A novice should not conclude they broke something when, e.g., flipping
`rejectCommonPasswords` to `True` changes nothing about which passwords are accepted; that is
expected in EP-1. EP-1's own observable win is purely the configuration plumbing for the two
length fields (whose behavior already exists) and the wiring of the five flags so the later
plans have a place to read them.

We add **all** flags up front (not just the lengths) so that EP-2 and EP-3 require no further
changes to the `PasswordPolicy` record, the `FileConfig` shape, the Dhall schema, or the env
overlay — they only add the *logic* that reads fields EP-1 already delivers.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Extend `PasswordPolicy` with the five new fields and update `defaultPasswordPolicy`
      in `shomei-core/src/Shomei/Domain/Password.hs`; fix every construction site; confirm
      `validatePassword` is unchanged.
- [ ] M1: `cabal build all` is green and the existing `shomei-core` test suite passes.
- [ ] M2: Add the seven new optional fields to `FileConfig` in
      `shomei-server/src/Shomei/Server/Config.hs`.
- [ ] M2: Add the matching keys to `config/shomei-types.dhall` and `config/shomei.example.dhall`.
- [ ] M2: Add the `passwordPolicy = cfg0.passwordPolicy { … }` overlay block in `baseFromFile`.
- [ ] M3: Add `boolEnv` and `intEnvMaybe` helpers and the `passwordPolicy` env overlay in
      `overlayCoreFromEnv`.
- [ ] M3: Extend `shomei-server/test/Shomei/Server/ConfigSpec.hs` to prove default → file → env
      precedence for a password field.
- [ ] M3: `cabal test all` is green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add all five new policy flags in EP-1 even though three of them are unused until
  EP-3 and two until EP-2.
  Rationale: One schema/record/env migration instead of three. EP-2 and EP-3 then add only
  behavior, never plumbing, which keeps each sibling plan small and avoids repeated
  closed-schema migrations to the Dhall files.
  Date: 2026-06-17

- Decision: Default `rejectCommonPasswords = True` and `rejectContextualPasswords = True`,
  but `breachCheckEnabled = False` and `breachCheckFailClosed = False`.
  Rationale: Local, offline checks (common/contextual password rejection) are safe to enable
  by default. Breach checking makes a network call to an external service (HIBP), so it is
  off by default and, when later turned on, fails *open* by default so a third-party outage
  cannot lock users out. These defaults only change observable behavior once EP-2/EP-3 land;
  in EP-1 they are recorded values with no effect.
  Date: 2026-06-17

- Decision: `breachCheckTimeoutMs` default is `1000` (one second).
  Rationale: A conservative per-request budget for the future HIBP call that EP-3 will honor.
  Inert in EP-1.
  Date: 2026-06-17

- Decision: Mirror the existing `RateLimitConfig` config-plumbing pattern exactly rather than
  inventing a new shape for password policy.
  Rationale: `RateLimitConfig` already demonstrates the full pipeline (flat `FileConfig`
  fields → `baseFromFile` nested-record overlay → env overlay), so following it minimizes
  surprise and review burden.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the codebase. Shōmei is a Haskell authentication
toolkit built as a Cabal multi-package workspace on GHC 9.12.4. You build everything with
`cabal build all` and test with `cabal test all` (or a single suite, e.g.
`cabal test shomei-core:shomei-core-test`). The test framework is `tasty` + `tasty-hunit`.
There is a `Justfile` with a `build` recipe (`cabal build all`) but **no test recipe** — run
tests directly with `cabal`.

### The configuration pipeline

Runtime configuration flows through three layers, lowest precedence to highest (this is the
"twelve-factor" precedence model — code defaults at the bottom, a config file in the middle,
environment variables on top):

1. **Built-in defaults.** `defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig` in
   `shomei-core/src/Shomei/Config.hs` constructs a fully populated `ShomeiConfig`. Its
   `passwordPolicy` field is set to `defaultPasswordPolicy`.

2. **A Dhall config file.** If the `SHOMEI_CONFIG` environment variable points at a file, the
   loader in `shomei-server/src/Shomei/Server/Config.hs` shells out to the `dhall-to-json`
   CLI (not the heavyweight `dhall` Haskell library) to render the Dhall file to JSON, then
   decodes that JSON with `aeson`'s `eitherDecodeStrict'` into a flat record called
   `FileConfig`. Every `FileConfig` field is a `Maybe`, so a partial file is valid and absent
   keys fall back to defaults. The function `baseFromFile` overlays the present file values
   onto a fresh `defaultShomeiConfig`. **Term note:** "FromDhall via dhall-to-json + aeson"
   means we never call a Dhall Haskell decoder — Dhall becomes JSON on the command line, and
   JSON becomes `FileConfig` via the ordinary aeson Generic `FromJSON` instance.

3. **Environment variables.** `overlayFromEnvBoth` and `overlayCoreFromEnv` in the same
   server `Config.hs` read `SHOMEI_*` and `PG_CONNECTION_STRING` variables and overlay them
   on top of whatever the file/defaults produced.

**Term note — Dhall.** Dhall is a typed, non-Turing-complete configuration language. The
project ships a *type alias* file `config/shomei-types.dhall` (a record type) and an example
`config/shomei.example.dhall` that annotates itself against that type (`… : Schema`). When a
Dhall expression is annotated against a **closed record type**, the expression must supply
*exactly* the keys the type declares — no more, no fewer. This is the single most important
gotcha in this plan (see Idempotence and Recovery).

**Term note — k-anonymity** appears in the EP-3 sibling plan (breach checking against HIBP).
It is **not relevant to EP-1**; we only carry the timeout/flags as inert config.

### The files you will touch

- `shomei-core/src/Shomei/Domain/Password.hs` — the **canonical** declaration of
  `PasswordPolicy`, `defaultPasswordPolicy`, and `validatePassword`. This is the only place
  the record type is defined.
- `shomei-core/src/Shomei/Config.hs` — declares `ShomeiConfig` (which has a
  `passwordPolicy :: !PasswordPolicy` field) and `defaultShomeiConfig`. It **re-exports**
  `PasswordPolicy` only indirectly: it imports `PasswordPolicy` and `defaultPasswordPolicy`
  from `Shomei.Domain.Password` and uses them, but its own export list does *not* list
  `PasswordPolicy`. (Verified: `grep -rn "PasswordPolicy" shomei-core/src` shows the type
  defined in `Domain/Password.hs`, imported in `Config.hs` line 35, and used at line 220 only.)
  This module also defines `RateLimitConfig` and `defaultRateLimitConfig` — the **template**
  you mirror for password policy.
- `shomei-server/src/Shomei/Server/Config.hs` — the config loader: `FileConfig`,
  `loadConfig`, `baseFromFile`, `overlayFromEnvBoth`, `overlayCoreFromEnv`, and the env-parsing
  helpers (`textEnv`, `intEnv`, `ttlEnv`, `transportEnv`, `sessionCheckEnv`).
- `config/shomei-types.dhall` — the closed Dhall record **schema**.
- `config/shomei.example.dhall` — a committed example annotated `: Schema`.
- `shomei-server/test/Shomei/Server/ConfigSpec.hs` — the config-loader test
  (suite `shomei-server:shomei-server-config-test`; see `shomei-server/shomei-server.cabal`).

### Current shapes (verified)

The canonical declaration in `shomei-core/src/Shomei/Domain/Password.hs`:

```haskell
data PasswordPolicy = PasswordPolicy
    { minLength :: !Int
    , maxLength :: !Int
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultPasswordPolicy :: PasswordPolicy
defaultPasswordPolicy = PasswordPolicy{minLength = 12, maxLength = 256}

validatePassword :: PasswordPolicy -> PlainPassword -> Either PasswordPolicyViolation ()
validatePassword policy (PlainPassword pw)
    | Text.length pw < policy.minLength = Left (PasswordTooShort policy.minLength)
    | Text.length pw > policy.maxLength = Left (PasswordTooLong policy.maxLength)
    | otherwise = Right ()
```

`validatePassword` reads `policy` only through the `.minLength` / `.maxLength` accessors (it
does **not** pattern-match the constructor positionally), so adding fields leaves it
compiling and behaving identically. The **only** construction site for the record is
`defaultPasswordPolicy` itself (verified by `grep -rn "PasswordPolicy{" --include="*.hs"`,
which returns exactly that one line). There is no exhaustive positional pattern match on the
constructor anywhere. This is why M1 is low-risk, but you must still re-run the grep after
editing in case other plans land construction sites in the meantime.

The existing `RateLimitConfig` overlay in `baseFromFile`
(`shomei-server/src/Shomei/Server/Config.hs`) — the pattern to mirror:

```haskell
, rateLimitConfig =
    cfg0.rateLimitConfig
        { rateLimitEnabled = fromMaybe cfg0.rateLimitConfig.rateLimitEnabled fc.rateLimitEnabled
        , maxFailedLoginsPerAccount = fromMaybe cfg0.rateLimitConfig.maxFailedLoginsPerAccount fc.maxFailedLoginsPerAccount
        , perIpRequestsPerMinute = fromMaybe cfg0.rateLimitConfig.perIpRequestsPerMinute fc.perIpRequestsPerMinute
        }
```

Note that `baseFromFile` currently does **not** touch `passwordPolicy`, so it stays at default
when loading from a file. EP-1 adds the analogous `passwordPolicy = …` overlay.

The env helpers currently include `intEnv :: Text -> Int -> IO Int` (returns a value with a
default, and errors on a non-integer) and the `Maybe`-returning `ttlEnv`/`transportEnv`/
`sessionCheckEnv`. There is **no** `boolEnv` and **no** `Maybe Int` variant of `intEnv`; EP-1
adds both, following the `Maybe`-returning style used by `ttlEnv` (overlay-only fields return
`Maybe` so absent vars leave the base value untouched).

The existing ConfigSpec fixture writes a **partial, unannotated** Dhall record to
`/tmp/shomei-config-test.dhall` (a bare `{ … }`, not `… : Schema`). Because it is not
annotated against the closed schema, it is free to omit keys — that is why the test only sets
`issuer`, `databaseUrl`, `port`, `maxFailedLoginsPerAccount`, `metricsEnabled`. This matters:
the test fixture does **not** need every schema key, so EP-1's test edit only needs to add the
password key(s) it asserts on, not the full schema. The committed `config/shomei.example.dhall`,
by contrast, *is* annotated `: Schema` and therefore must gain every new schema key.


## Plan of Work

The work is three independently verifiable milestones. Each ends with a clean `cabal build all`
(M1) and/or `cabal test` run (M3), and each can be committed on its own.

### Milestone 1 — Extend the policy record (core only)

Scope: add the five new fields to `PasswordPolicy` and the matching values to
`defaultPasswordPolicy` in `shomei-core/src/Shomei/Domain/Password.hs`. Update any
construction site. At the end of M1, the core library and all existing core tests compile and
pass; `validatePassword` is byte-for-byte unchanged in behavior (length-only). Commands:
`cabal build all`, then `cabal test shomei-core:shomei-core-test`. Acceptance: build is green;
the existing core tests pass; `grep -rn "PasswordPolicy{" --include="*.hs"` shows every
construction site supplies all seven fields.

### Milestone 2 — File config + Dhall schema overlay

Scope: add the seven optional password fields to `FileConfig`
(`shomei-server/src/Shomei/Server/Config.hs`), add the matching keys to
`config/shomei-types.dhall` and `config/shomei.example.dhall`, and add the
`passwordPolicy = cfg0.passwordPolicy { … }` overlay block to `baseFromFile`. At the end of
M2, a Dhall file (annotated against the schema) that sets `passwordMinLength` flows into
`cfg.passwordPolicy.minLength`. Commands: `cabal build all`; optional manual smoke with
`dhall-to-json --file config/shomei.example.dhall`. Acceptance: build is green and
`dhall-to-json` renders `config/shomei.example.dhall` without a "missing field" / type error.

### Milestone 3 — Env overrides + precedence test

Scope: add `boolEnv` and `intEnvMaybe` helpers, add the `passwordPolicy = base.passwordPolicy
{ … }` overlay to `overlayCoreFromEnv` reading the seven `SHOMEI_PASSWORD_*` env vars, and
extend `shomei-server/test/Shomei/Server/ConfigSpec.hs` to prove default → file → env
precedence for at least one password field. Commands: `cabal test all` (or specifically
`cabal test shomei-server:shomei-server-config-test`). Acceptance: the new assertions pass —
the file value beats the default, and the env value beats the file value.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`.

> **Commit trailers (mandatory).** Every commit on this plan must carry these git trailers in
> the commit message footer:
>
> ```text
> MasterPlan: docs/masterplans/4-stronger-password-policy-configurability-common-password-and-breach-checking.md
> ExecPlan: docs/plans/20-configurable-password-policy-end-to-end.md
> Intention: intention_01kvbc26dhenstms0kx006ceds
> ```

### Step 1 (M1) — Extend `PasswordPolicy` and `defaultPasswordPolicy`

Edit `shomei-core/src/Shomei/Domain/Password.hs`. Replace the record and default:

```diff
 data PasswordPolicy = PasswordPolicy
     { minLength :: !Int
     , maxLength :: !Int
+    , rejectCommonPasswords :: !Bool      -- consumed by EP-2 (docs/plans/21-...)
+    , rejectContextualPasswords :: !Bool  -- consumed by EP-2 (docs/plans/21-...)
+    , breachCheckEnabled :: !Bool         -- consumed by EP-3 (docs/plans/22-...)
+    , breachCheckFailClosed :: !Bool      -- consumed by EP-3 (docs/plans/22-...)
+    , breachCheckTimeoutMs :: !Int        -- consumed by EP-3 (docs/plans/22-...)
     }
     deriving stock (Generic, Eq, Show)
     deriving anyclass (FromJSON, ToJSON)

 defaultPasswordPolicy :: PasswordPolicy
-defaultPasswordPolicy = PasswordPolicy{minLength = 12, maxLength = 256}
+defaultPasswordPolicy =
+    PasswordPolicy
+        { minLength = 12
+        , maxLength = 256
+        , rejectCommonPasswords = True
+        , rejectContextualPasswords = True
+        , breachCheckEnabled = False
+        , breachCheckFailClosed = False
+        , breachCheckTimeoutMs = 1000
+        }
```

Leave `validatePassword` untouched — it reads only `.minLength` / `.maxLength`. Then verify no
other construction site needs updating:

```bash
grep -rn "PasswordPolicy{" --include="*.hs" .
```

Expected: only the `defaultPasswordPolicy` line in
`shomei-core/src/Shomei/Domain/Password.hs` (now in the multi-line form). If any other site
appears, give it the five new fields too.

Build and run the core tests:

```bash
cabal build all
cabal test shomei-core:shomei-core-test
```

Expected tail:

```text
All N tests passed (…s)
```

### Step 2 (M2) — Add the seven optional fields to `FileConfig`

Edit `shomei-server/src/Shomei/Server/Config.hs`, inside the `FileConfig` record (after
`gracefulShutdownTimeoutSeconds`):

```diff
     , gracefulShutdownTimeoutSeconds :: !(Maybe Int)
+    , passwordMinLength :: !(Maybe Int)
+    , passwordMaxLength :: !(Maybe Int)
+    , passwordRejectCommon :: !(Maybe Bool)
+    , passwordRejectContextual :: !(Maybe Bool)
+    , passwordBreachCheckEnabled :: !(Maybe Bool)
+    , passwordBreachCheckFailClosed :: !(Maybe Bool)
+    , passwordBreachCheckTimeoutMs :: !(Maybe Int)
     }
     deriving stock (Show, Generic)
     deriving anyclass (FromJSON)
```

`FromJSON` is Generic-derived, so the new optional keys are decoded automatically; no manual
instance is needed.

### Step 3 (M2) — Add the keys to the Dhall schema and example

Edit `config/shomei-types.dhall` (the **closed** record type) — add the matching keys
(`Natural` for the three integers, `Bool` for the four flags):

```diff
 , gracefulShutdownTimeoutSeconds : Natural
+, passwordMinLength : Natural
+, passwordMaxLength : Natural
+, passwordRejectCommon : Bool
+, passwordRejectContextual : Bool
+, passwordBreachCheckEnabled : Bool
+, passwordBreachCheckFailClosed : Bool
+, passwordBreachCheckTimeoutMs : Natural
 }
```

Edit `config/shomei.example.dhall` (annotated `: Schema`, so it must supply every key) — add
example values consistent with the defaults:

```diff
       , gracefulShutdownTimeoutSeconds = 30
+      , passwordMinLength = 12
+      , passwordMaxLength = 256
+      , passwordRejectCommon = True
+      , passwordRejectContextual = True
+      , passwordBreachCheckEnabled = False
+      , passwordBreachCheckFailClosed = False
+      , passwordBreachCheckTimeoutMs = 1000
       }
     : Schema
```

Smoke-test the example renders against the schema (requires `dhall-to-json` on PATH):

```bash
dhall-to-json --file config/shomei.example.dhall
```

Expected: a JSON object printed to stdout that includes `"passwordMinLength": 12` and the new
keys; **no** "missing field" or type-mismatch error.

### Step 4 (M2) — Overlay password policy from the file in `baseFromFile`

Edit `shomei-server/src/Shomei/Server/Config.hs`. Add a `passwordPolicy` block to the `cfg`
record update inside `baseFromFile (Just fc)`, mirroring the `rateLimitConfig` block:

```diff
                 , rateLimitConfig =
                     cfg0.rateLimitConfig
                         { rateLimitEnabled = fromMaybe cfg0.rateLimitConfig.rateLimitEnabled fc.rateLimitEnabled
                         , maxFailedLoginsPerAccount = fromMaybe cfg0.rateLimitConfig.maxFailedLoginsPerAccount fc.maxFailedLoginsPerAccount
                         , perIpRequestsPerMinute = fromMaybe cfg0.rateLimitConfig.perIpRequestsPerMinute fc.perIpRequestsPerMinute
                         }
+                , passwordPolicy =
+                    cfg0.passwordPolicy
+                        { minLength = fromMaybe cfg0.passwordPolicy.minLength fc.passwordMinLength
+                        , maxLength = fromMaybe cfg0.passwordPolicy.maxLength fc.passwordMaxLength
+                        , rejectCommonPasswords = fromMaybe cfg0.passwordPolicy.rejectCommonPasswords fc.passwordRejectCommon
+                        , rejectContextualPasswords = fromMaybe cfg0.passwordPolicy.rejectContextualPasswords fc.passwordRejectContextual
+                        , breachCheckEnabled = fromMaybe cfg0.passwordPolicy.breachCheckEnabled fc.passwordBreachCheckEnabled
+                        , breachCheckFailClosed = fromMaybe cfg0.passwordPolicy.breachCheckFailClosed fc.passwordBreachCheckFailClosed
+                        , breachCheckTimeoutMs = fromMaybe cfg0.passwordPolicy.breachCheckTimeoutMs fc.passwordBreachCheckTimeoutMs
+                        }
```

You must also bring `PasswordPolicy (..)` into scope in this module. The current import list
imports `Shomei.Config (… RateLimitConfig (..), … ShomeiConfig (..), …)` and
`Shomei.Domain.Claims (Audience (..), Issuer (..))`. Add the password-policy import:

```diff
 import Shomei.Config (
     NotifierConfig (..),
     ObservabilityConfig (..),
     RateLimitConfig (..),
     SessionCheckMode (..),
     ShomeiConfig (..),
     TokenTransport (..),
     defaultShomeiConfig,
  )
 import Shomei.Domain.Claims (Audience (..), Issuer (..))
+import Shomei.Domain.Password (PasswordPolicy (..))
```

(`shomei-server` already depends on `shomei-core`, so no cabal change is required. Confirm by
`grep -n "shomei-core" shomei-server/shomei-server.cabal` if in doubt.)

Build:

```bash
cabal build all
```

Expected: clean build.

### Step 5 (M3) — Add `boolEnv` and `intEnvMaybe` helpers

Edit `shomei-server/src/Shomei/Server/Config.hs`. After the existing helpers add:

```haskell
-- | Read a boolean env var. Absent or empty → Nothing (leave the base value); "true"/"false"
-- → Just; anything else is a hard error (fail fast on misconfiguration).
boolEnv :: Text -> IO (Maybe Bool)
boolEnv name = do
    m <- lookupEnv (Text.unpack name)
    case m of
        Nothing -> pure Nothing
        Just "" -> pure Nothing
        Just "true" -> pure (Just True)
        Just "false" -> pure (Just False)
        Just other -> ioError (userError (Text.unpack name <> " must be true|false, got " <> other))

-- | Like 'intEnv' but overlay-only: absent/empty → Nothing, non-integer → error.
intEnvMaybe :: Text -> IO (Maybe Int)
intEnvMaybe name = do
    m <- lookupEnv (Text.unpack name)
    case m of
        Nothing -> pure Nothing
        Just "" -> pure Nothing
        Just s -> case readMaybe s of
            Just n -> pure (Just n)
            Nothing -> ioError (userError (Text.unpack name <> " must be an integer"))
```

`lookupEnv`, `readMaybe`, `Text.unpack`, and `ioError`/`userError` are already imported in this
module.

### Step 6 (M3) — Overlay password policy from env in `overlayCoreFromEnv`

Edit `overlayCoreFromEnv`. Read the seven env vars and add a `passwordPolicy` overlay:

```diff
 overlayCoreFromEnv :: ShomeiConfig -> IO ShomeiConfig
 overlayCoreFromEnv base = do
     acc <- ttlEnv "SHOMEI_ACCESS_TTL"
     ref <- ttlEnv "SHOMEI_REFRESH_TTL"
     ses <- ttlEnv "SHOMEI_SESSION_TTL"
     tr <- transportEnv
     sc <- sessionCheckEnv
+    pwMin <- intEnvMaybe "SHOMEI_PASSWORD_MIN_LENGTH"
+    pwMax <- intEnvMaybe "SHOMEI_PASSWORD_MAX_LENGTH"
+    pwRejCommon <- boolEnv "SHOMEI_PASSWORD_REJECT_COMMON"
+    pwRejCtx <- boolEnv "SHOMEI_PASSWORD_REJECT_CONTEXTUAL"
+    pwBreach <- boolEnv "SHOMEI_PASSWORD_BREACH_CHECK"
+    pwBreachFC <- boolEnv "SHOMEI_PASSWORD_BREACH_FAIL_CLOSED"
+    pwBreachTo <- intEnvMaybe "SHOMEI_PASSWORD_BREACH_TIMEOUT_MS"
     pure
         base
             { accessTokenTTL = fromMaybe base.accessTokenTTL acc
             , refreshTokenTTL = fromMaybe base.refreshTokenTTL ref
             , sessionTTL = fromMaybe base.sessionTTL ses
             , tokenTransport = fromMaybe base.tokenTransport tr
             , sessionCheckMode = fromMaybe base.sessionCheckMode sc
+            , passwordPolicy =
+                base.passwordPolicy
+                    { minLength = fromMaybe base.passwordPolicy.minLength pwMin
+                    , maxLength = fromMaybe base.passwordPolicy.maxLength pwMax
+                    , rejectCommonPasswords = fromMaybe base.passwordPolicy.rejectCommonPasswords pwRejCommon
+                    , rejectContextualPasswords = fromMaybe base.passwordPolicy.rejectContextualPasswords pwRejCtx
+                    , breachCheckEnabled = fromMaybe base.passwordPolicy.breachCheckEnabled pwBreach
+                    , breachCheckFailClosed = fromMaybe base.passwordPolicy.breachCheckFailClosed pwBreachFC
+                    , breachCheckTimeoutMs = fromMaybe base.passwordPolicy.breachCheckTimeoutMs pwBreachTo
+                    }
             }
```

The env var → field mapping (note `SHOMEI_PASSWORD_BREACH_CHECK` maps to `breachCheckEnabled`):

```text
SHOMEI_PASSWORD_MIN_LENGTH          int   -> minLength
SHOMEI_PASSWORD_MAX_LENGTH          int   -> maxLength
SHOMEI_PASSWORD_REJECT_COMMON       bool  -> rejectCommonPasswords
SHOMEI_PASSWORD_REJECT_CONTEXTUAL   bool  -> rejectContextualPasswords
SHOMEI_PASSWORD_BREACH_CHECK        bool  -> breachCheckEnabled
SHOMEI_PASSWORD_BREACH_FAIL_CLOSED  bool  -> breachCheckFailClosed
SHOMEI_PASSWORD_BREACH_TIMEOUT_MS   int   -> breachCheckTimeoutMs
```

### Step 7 (M3) — Extend the ConfigSpec precedence test

Edit `shomei-server/test/Shomei/Server/ConfigSpec.hs`. The existing fixture writes a
**partial, unannotated** Dhall record, so you only add the password key(s) you assert on
(you do *not* need the full schema here). Add `passwordMinLength` and `passwordRejectCommon`
to the fixture, and add assertions to `testLoadAndOverride`:

```diff
 dhallContents :: String
 dhallContents =
     "{ issuer = \"shomei-prod\""
         <> ", databaseUrl = \"host=fromfile dbname=shomei\""
         <> ", port = 8080"
         <> ", maxFailedLoginsPerAccount = 7"
         <> ", metricsEnabled = False"
+        <> ", passwordMinLength = 16"
+        <> ", passwordRejectCommon = False"
         <> " }"
```

The test imports `ShomeiConfig (..)` from `Shomei.Config`. `PasswordPolicy`'s field accessors
(`minLength`, `rejectCommonPasswords`) are reached through `cfg.passwordPolicy.minLength` using
`OverloadedRecordDot`, which only needs `PasswordPolicy`'s fields in scope; import it:

```diff
-import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..))
+import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..))
+import Shomei.Domain.Password (PasswordPolicy (..))
```

(If `cabal build` reports `PasswordPolicy` is not exported from `Shomei.Config`, import it from
`Shomei.Domain.Password` as shown — that is the canonical module. Confirm the test suite's
`build-depends` in `shomei-server/shomei-server.cabal` lists `shomei-core`; it does, since the
suite already uses `Shomei.Config`.)

Add the assertions inside `testLoadAndOverride`, after the existing file-vs-default checks and
the env-override block:

```diff
     -- File values beat the defaults (default maxFailedLoginsPerAccount is 5, metrics default True):
     settings.serverPort @?= 8080
     cfg.rateLimitConfig.maxFailedLoginsPerAccount @?= 7
+    -- File value beats the default password policy (default minLength is 12):
+    cfg.passwordPolicy.minLength @?= 16
+    cfg.passwordPolicy.rejectCommonPasswords @?= False
     -- PG_CONNECTION_STRING (env) overrides the file's databaseUrl:
     settings.serverConnStr @?= "host=fromenv dbname=shomei"
     -- An env var overrides the file's port:
     setEnv "SHOMEI_PORT" "9999"
     (_, settings2) <- loadConfig
     settings2.serverPort @?= 9999
+    -- An env var overrides the file's password min length (file says 16):
+    setEnv "SHOMEI_PASSWORD_MIN_LENGTH" "20"
+    (cfg3, _) <- loadConfig
+    cfg3.passwordPolicy.minLength @?= 20
+    unsetEnv "SHOMEI_PASSWORD_MIN_LENGTH"
     unsetEnv "SHOMEI_CONFIG"
     unsetEnv "SHOMEI_PORT"
     unsetEnv "PG_CONNECTION_STRING"
```

Run the test:

```bash
cabal test shomei-server:shomei-server-config-test
```

Expected tail:

```text
Dhall file is loaded and an env var overrides it: OK
All 1 tests passed (…s)
```

Then run everything:

```bash
cabal test all
```

Expected: all suites pass.


## Validation and Acceptance

Acceptance is expressed as observable behavior, not "it compiles."

**1. File overrides the default (minLength).** With `dhall-to-json` on PATH, create a config
file that sets the minimum length to 16:

```bash
cat > /tmp/shomei-acc.dhall <<'EOF'
let Schema = ./config/shomei-types.dhall
in  { issuer = "shomei"
    , audience = "shomei-clients"
    , databaseUrl = "host=localhost dbname=shomei"
    , port = 8080
    , accessTokenTtlSeconds = 900
    , refreshTokenTtlSeconds = 2592000
    , sessionTtlSeconds = 2592000
    , publicBaseUrl = "http://localhost:8080"
    , emailVerificationRequired = False
    , rateLimitEnabled = True
    , maxFailedLoginsPerAccount = 7
    , perIpRequestsPerMinute = 60
    , metricsEnabled = True
    , requestLoggingEnabled = True
    , gracefulShutdownTimeoutSeconds = 30
    , passwordMinLength = 16
    , passwordMaxLength = 256
    , passwordRejectCommon = True
    , passwordRejectContextual = True
    , passwordBreachCheckEnabled = False
    , passwordBreachCheckFailClosed = False
    , passwordBreachCheckTimeoutMs = 1000
    } : Schema
EOF
```

Loading config with `SHOMEI_CONFIG=/tmp/shomei-acc.dhall` (and a `PG_CONNECTION_STRING` set)
must yield `cfg.passwordPolicy.minLength == 16`. The automated form of this is the new
ConfigSpec assertion `cfg.passwordPolicy.minLength @?= 16`.

**2. Env overrides the file (minLength).** With the same file but additionally
`SHOMEI_PASSWORD_MIN_LENGTH=20` exported, loading config must yield
`cfg.passwordPolicy.minLength == 20`. The automated form is the new ConfigSpec assertion
`cfg3.passwordPolicy.minLength @?= 20`.

**3. The full test suite passes:**

```bash
cabal test all
```

Expected: every suite reports `OK` / `All N tests passed`, including
`shomei-server:shomei-server-config-test`.

**4. Inert-flag sanity (manual, optional).** Flipping `passwordRejectCommon` between `True`
and `False` in the Dhall file changes only `cfg.passwordPolicy.rejectCommonPasswords`; it does
**not** change which passwords `validatePassword` accepts (still length-only). This confirms
the EP-1 framing: the flags are wired but inert until EP-2/EP-3.


## Idempotence and Recovery

All edits are ordinary source edits and are safe to re-apply: re-running `cabal build all` /
`cabal test all` is idempotent, and the diffs above are written so re-applying them produces
the same file content. Creating `/tmp/*.dhall` fixtures simply overwrites.

**Primary failure mode — the closed-schema gotcha.** `config/shomei-types.dhall` is a
*closed* record type. Any `.dhall` file annotated `: Schema` must supply **exactly** the keys
the schema declares. If you add a key to `config/shomei-types.dhall` but forget it in
`config/shomei.example.dhall` (or any other `: Schema`-annotated file), `dhall-to-json` fails
with a type error such as:

```text
Error: Expression doesn't match annotation
{ + passwordMinLength : …
, …
}
```

Recovery: grep for every file that annotates against the schema and add the missing key:

```bash
grep -rln "shomei-types.dhall" config docs
grep -rln ": Schema" config
```

Add the new key to each such file. As of this plan the only annotated committed file is
`config/shomei.example.dhall`; the ConfigSpec test fixture is **unannotated** (a bare record)
and therefore is *not* affected by the closed-schema rule — it only needs the keys it asserts
on. If a future fixture annotates against the schema, it too must carry all keys.

An alternative escape hatch (not the chosen path) is to make the new keys `Optional` in the
Dhall schema (`Optional Natural`, etc.); the simpler, style-consistent path is to require them
everywhere, matching the existing schema fields.

If a milestone leaves the tree red, revert just that milestone's files
(`git checkout -- <path>`) — each milestone is independent, so M1 can stand without M2/M3.


## Interfaces and Dependencies

No new package dependencies are required — this is pure configuration plumbing built on
modules already in the dependency graph (`shomei-server` already depends on `shomei-core`,
which owns `Shomei.Domain.Password`; `aeson`, `System.Environment`, `System.Process`, and
`text` are already imported by the loader).

### Final `PasswordPolicy` type (`shomei-core/src/Shomei/Domain/Password.hs`)

```haskell
data PasswordPolicy = PasswordPolicy
    { minLength :: !Int
    , maxLength :: !Int
    , rejectCommonPasswords :: !Bool      -- consumed by EP-2 (docs/plans/21-...)
    , rejectContextualPasswords :: !Bool  -- consumed by EP-2 (docs/plans/21-...)
    , breachCheckEnabled :: !Bool         -- consumed by EP-3 (docs/plans/22-...)
    , breachCheckFailClosed :: !Bool      -- consumed by EP-3 (docs/plans/22-...)
    , breachCheckTimeoutMs :: !Int        -- consumed by EP-3 (docs/plans/22-...)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultPasswordPolicy :: PasswordPolicy
defaultPasswordPolicy =
    PasswordPolicy
        { minLength = 12
        , maxLength = 256
        , rejectCommonPasswords = True
        , rejectContextualPasswords = True
        , breachCheckEnabled = False
        , breachCheckFailClosed = False
        , breachCheckTimeoutMs = 1000
        }
```

`validatePassword :: PasswordPolicy -> PlainPassword -> Either PasswordPolicyViolation ()`
is **unchanged** (length-only).

### `FileConfig` additions (`shomei-server/src/Shomei/Server/Config.hs`)

```haskell
    , passwordMinLength :: !(Maybe Int)
    , passwordMaxLength :: !(Maybe Int)
    , passwordRejectCommon :: !(Maybe Bool)
    , passwordRejectContextual :: !(Maybe Bool)
    , passwordBreachCheckEnabled :: !(Maybe Bool)
    , passwordBreachCheckFailClosed :: !(Maybe Bool)
    , passwordBreachCheckTimeoutMs :: !(Maybe Int)
```

### New env-helper signatures (`shomei-server/src/Shomei/Server/Config.hs`)

```haskell
boolEnv :: Text -> IO (Maybe Bool)
intEnvMaybe :: Text -> IO (Maybe Int)
```

### Environment variables consumed (in `overlayCoreFromEnv`)

```text
SHOMEI_PASSWORD_MIN_LENGTH          (int)
SHOMEI_PASSWORD_MAX_LENGTH          (int)
SHOMEI_PASSWORD_REJECT_COMMON       (bool)
SHOMEI_PASSWORD_REJECT_CONTEXTUAL   (bool)
SHOMEI_PASSWORD_BREACH_CHECK        (bool -> breachCheckEnabled)
SHOMEI_PASSWORD_BREACH_FAIL_CLOSED  (bool)
SHOMEI_PASSWORD_BREACH_TIMEOUT_MS   (int)
```

### Dhall schema additions (`config/shomei-types.dhall` and `config/shomei.example.dhall`)

```dhall
, passwordMinLength : Natural
, passwordMaxLength : Natural
, passwordRejectCommon : Bool
, passwordRejectContextual : Bool
, passwordBreachCheckEnabled : Bool
, passwordBreachCheckFailClosed : Bool
, passwordBreachCheckTimeoutMs : Natural
```
