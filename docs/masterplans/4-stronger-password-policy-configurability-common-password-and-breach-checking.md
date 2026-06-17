---
id: 4
slug: stronger-password-policy-configurability-common-password-and-breach-checking
title: "Stronger Password Policy: Configurability, Common-Password and Breach Checking"
kind: master-plan
created_at: 2026-06-17T18:08:47Z
intention: "intention_01kvbc26dhenstms0kx006ceds"
---

# Stronger Password Policy: Configurability, Common-Password and Breach Checking

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shōmei is an authentication toolkit. Today its password policy is intentionally minimal:
the pure function `validatePassword` in `shomei-core/src/Shomei/Domain/Password.hs` enforces
only a minimum length (12) and a maximum length (256). Passwords are hashed with Argon2id
(`shomei-postgres/src/Shomei/Crypto.hs`) and brute-force attempts are throttled by the
existing rate-limit and account-lockout machinery. There are two error constructors,
`PasswordTooCommon` and `PasswordMissingRequiredClass`, declared in
`shomei-core/src/Shomei/Error.hs` but never produced — they were reserved for exactly the
work this initiative delivers.

After this initiative, an operator of Shōmei can:

1. Tune the password policy from configuration — minimum and maximum length plus the new
   checks below — through a Dhall config file (`$SHOMEI_CONFIG`) and through `SHOMEI_*`
   environment variables, with the same defaults → file → env precedence the rest of the
   config already uses.
2. Reject **common** passwords (those appearing in a bundled dictionary of the most
   frequently used passwords) and **context-specific** passwords (ones that are essentially
   the user's own email address or display name). These checks run locally with no network
   dependency.
3. Optionally reject **compromised** passwords — ones that appear in a known public breach —
   by querying the "Have I Been Pwned" (HIBP) Pwned Passwords range API using k-anonymity,
   so the user's password (and even its full hash) never leaves the service. The operator
   chooses whether this check is enabled and whether an unreachable HIBP service should fail
   open (allow the password) or fail closed (reject the password).

Each behavior is observable end-to-end: a signup, password change, or password reset
attempt with a too-common, identity-derived, or breached password is rejected with a clear
policy-violation error, and these checks can be toggled by editing a Dhall file or setting
an environment variable without recompiling.

In scope: the policy data model and its configuration plumbing; a local common/contextual
password check; an opt-in HIBP breach check with a swappable port and a test fake; wiring all
three checks into the three password-accepting workflows (signup, change password, confirm
password reset); and HTTP error mapping for the new violation kinds.

Explicitly out of scope (mentioned here so later contributors do not assume otherwise):
mandatory character-class composition rules (the NIST guidance this project follows
discourages them; the `PasswordMissingRequiredClass` constructor remains available but this
initiative does not turn it on); zxcvbn-style entropy scoring; password-history / reuse
prevention; periodic forced rotation; and a server-side pepper/HMAC over the hash. These were
considered during planning (see the original discussion that seeded this MasterPlan) and
deferred. They can become follow-on plans under a future MasterPlan.


## Decomposition Strategy

The initiative was decomposed by functional concern into three child ExecPlans, matching the
three requested items (configurability, common/contextual rejection, breach checking):

- **EP-1 (Plan 20) — Configurable Password Policy End-to-End.** The foundation. It extends
  the `PasswordPolicy` record with every new knob the other two plans need and wires those
  knobs through the full configuration pipeline (`FileConfig`, the Dhall schema and example,
  and `SHOMEI_*` environment overrides). It deliberately owns *all* configuration-surface
  edits so that EP-2 and EP-3 never have to touch `shomei-server/src/Shomei/Server/Config.hs`,
  the Dhall files, or the env-override code. The new flags it adds are inert scaffolding until
  EP-2 and EP-3 give them behavior — this is intentional and is the reason EP-1 is a hard
  dependency of both.

- **EP-2 (Plan 21) — Common and Context-Specific Weak Password Rejection.** Implements the
  two local (no-network) checks behind the `rejectCommonPasswords` and
  `rejectContextualPasswords` flags EP-1 introduces. This is pure-domain logic plus an
  embedded dictionary; it produces `PasswordTooCommon` and a new `PasswordResemblesIdentity`
  violation.

- **EP-3 (Plan 22) — Compromised Password Breach Checking via HIBP k-Anonymity.** Implements
  the opt-in network check behind the `breachCheckEnabled` / `breachCheckFailClosed` /
  `breachCheckTimeoutMs` flags EP-1 introduces. Because it performs IO (an HTTPS request), it
  cannot fold into the pure `validatePassword`; instead it introduces a new effect/port
  (`PasswordBreachChecker`) with a production HIBP interpreter and an in-memory test fake, and
  adds an effectful guard to the workflows. It produces a new `PasswordBreached` violation.

Why this split and not others. An earlier option was to let each of EP-2 and EP-3 add its own
config fields independently; this was rejected because both would then edit the same
`FileConfig` record, Dhall schema, and env-override function, creating guaranteed merge
conflicts on shared configuration files. Concentrating all configuration changes in EP-1
removes that coupling entirely. A second option was a single large plan; rejected because it
would exceed the ExecPlan size guidance (well over five milestones across pure-domain code,
configuration plumbing, a new effect with two interpreters, and HTTP wiring) and because the
breach check (network, opt-in) is genuinely independent from the local checks and should be
verifiable on its own.

EP-2 and EP-3 are independent in their core logic and can be implemented in parallel after
EP-1, but they share two small artifacts — the `PasswordPolicyViolation` sum type and the
three workflow call sites — so they carry an integration relationship (see Integration
Points) and a recommended ordering (EP-2 before EP-3) captured as a soft dependency.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Configurable Password Policy End-to-End | docs/plans/20-configurable-password-policy-end-to-end.md | None | None | Complete |
| EP-2 | Common and Context-Specific Weak Password Rejection | docs/plans/21-common-and-context-specific-weak-password-rejection.md | EP-1 | None | In Progress |
| EP-3 | Compromised Password Breach Checking via HIBP k-Anonymity | docs/plans/22-compromised-password-breach-checking-via-hibp-k-anonymity.md | EP-1 | EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 has no dependencies and must be implemented first. Both EP-2 and EP-3 have a **hard**
dependency on EP-1 because their code reads policy fields (`rejectCommonPasswords`,
`rejectContextualPasswords`, `breachCheckEnabled`, `breachCheckFailClosed`,
`breachCheckTimeoutMs`) that do not exist on the `PasswordPolicy` record until EP-1 adds them.
Without EP-1 their code would not compile.

After EP-1 is Complete, EP-2 and EP-3 can proceed in parallel: their substantive logic lives
in different modules (EP-2 in the pure domain layer and a new dictionary module; EP-3 in a new
effect, its interpreters, and the in-memory test stack). EP-3 carries a **soft** dependency on
EP-2 to express a recommended ordering rather than a hard block: both plans edit the same three
workflow functions (`signup`, `changePassword`, `confirmPasswordReset`) and both add a
constructor to the same `PasswordPolicyViolation` sum type. Landing EP-2 first means EP-3
rebases onto an already-reshaped validation call site (EP-2 changes the pure validation
signature to be context-aware; EP-3 only appends an effectful guard line), which minimizes
reconciliation. If the two are implemented truly concurrently, the second to land must
reconcile the shared call sites and the shared sum type per the Integration Points below — no
semantic conflict is expected, only textual.


## Integration Points

**IP-1 — The `PasswordPolicy` record and its configuration plumbing.** Defined and owned by
**EP-1**. Canonically declared in `shomei-core/src/Shomei/Domain/Password.hs` and re-exported
through `shomei-core/src/Shomei/Config.hs` (verify the exact definition/re-export site when
implementing; both modules name it). EP-1 extends it to exactly the following shape, and both
EP-2 and EP-3 consume these fields read-only — neither adds fields of its own:

```haskell
data PasswordPolicy = PasswordPolicy
    { minLength :: !Int
    , maxLength :: !Int
    , rejectCommonPasswords :: !Bool      -- consumed by EP-2
    , rejectContextualPasswords :: !Bool  -- consumed by EP-2
    , breachCheckEnabled :: !Bool         -- consumed by EP-3
    , breachCheckFailClosed :: !Bool      -- consumed by EP-3
    , breachCheckTimeoutMs :: !Int        -- consumed by EP-3
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

`defaultPasswordPolicy` (owned by EP-1) sets: `minLength = 12`, `maxLength = 256`,
`rejectCommonPasswords = True`, `rejectContextualPasswords = True`, `breachCheckEnabled = False`,
`breachCheckFailClosed = False`, `breachCheckTimeoutMs = 1000`. Rationale: the local checks are
free and have no external dependency, so they default on; the network check is opt-in and
defaults off and fail-open (availability over strictness) — see the Decision Log.

The corresponding flat configuration fields owned by EP-1 are: in
`shomei-server/src/Shomei/Server/Config.hs` the `FileConfig` record gains optional fields
`passwordMinLength :: !(Maybe Int)`, `passwordMaxLength :: !(Maybe Int)`,
`passwordRejectCommon :: !(Maybe Bool)`, `passwordRejectContextual :: !(Maybe Bool)`,
`passwordBreachCheckEnabled :: !(Maybe Bool)`, `passwordBreachCheckFailClosed :: !(Maybe Bool)`,
`passwordBreachCheckTimeoutMs :: !(Maybe Int)`; the Dhall schema
`config/shomei-types.dhall` and example `config/shomei.example.dhall` gain the matching keys
(`Natural` for the ints, `Bool` for the flags); and `overlayCoreFromEnv` gains overrides
`SHOMEI_PASSWORD_MIN_LENGTH`, `SHOMEI_PASSWORD_MAX_LENGTH`, `SHOMEI_PASSWORD_REJECT_COMMON`,
`SHOMEI_PASSWORD_REJECT_CONTEXTUAL`, `SHOMEI_PASSWORD_BREACH_CHECK`,
`SHOMEI_PASSWORD_BREACH_FAIL_CLOSED`, `SHOMEI_PASSWORD_BREACH_TIMEOUT_MS` (EP-1 adds a `boolEnv`
helper for the boolean ones). EP-2 and EP-3 do not touch any of these files.

**IP-2 — The `PasswordPolicyViolation` sum type.** Located in
`shomei-core/src/Shomei/Error.hs`. Today it is
`PasswordTooShort Int | PasswordTooLong Int | PasswordTooCommon | PasswordMissingRequiredClass Text`.
EP-2 starts producing the existing `PasswordTooCommon` constructor (dictionary hit) and **adds**
a new `PasswordResemblesIdentity` constructor (contextual hit). EP-3 **adds** a new
`PasswordBreached` constructor. Both additions are append-only to the sum type; whichever plan
lands second adds its constructor alongside the other's without altering it. The type derives
`Generic, Eq, Show, FromJSON, ToJSON` — keep those instances working.

**IP-3 — The three password-accepting workflow call sites.** `signup` in
`shomei-core/src/Shomei/Workflow.hs` (around lines 109–114) and `changePassword` (around
196–207) and `confirmPasswordReset` (around 158–182) in
`shomei-core/src/Shomei/Workflow/Account.hs`. Each currently validates with
`either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy <pw>)`. EP-2
changes the pure validation entry point to be context-aware (it threads the user's email and
display name into the check) and updates all three call sites. EP-3 appends an *effectful*
breach guard after the pure validation at all three call sites and adds a
`PasswordBreachChecker :> es` constraint to the three workflow signatures. The recommended
order (soft dependency) is EP-2 then EP-3 so EP-3 appends onto EP-2's reshaped call sites.

**IP-4 — Servant HTTP error mapping.** The Servant layer maps `AuthError` (and the nested
`WeakPassword PasswordPolicyViolation`) to HTTP responses in `shomei-servant/src/Shomei/Servant/Error.hs`
and/or `shomei-servant/src/Shomei/Servant/DTO.hs` (the implementer must confirm which module
pattern-matches on `PasswordPolicyViolation`). If the mapping enumerates violation
constructors, EP-2 must add cases for `PasswordResemblesIdentity` and EP-3 a case for
`PasswordBreached`; if it maps the whole `WeakPassword` group uniformly (e.g., all to HTTP 422),
no per-constructor change is needed. Each plan owns the mapping for the constructor it
introduces.

**IP-5 — The in-memory effect stack `runInMemory`.** Located in
`shomei-core/src/Shomei/Effect/InMemory.hs`. Only **EP-3** touches it: adding the
`PasswordBreachChecker` effect to the workflows means the effect must be added to the
`runInMemory` interpreter list (its large type signature and the composition chain) together
with a `runPasswordBreachCheckerFake` interpreter whose breached-set is seeded from the test
`World`. EP-1 and EP-2 do not modify the effect stack.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (2026-06-17): Extend `PasswordPolicy` record + `defaultPasswordPolicy` with the seven fields (IP-1).
- [x] EP-1 (2026-06-17): Wire fields through `FileConfig`, Dhall schema + example, and `baseFromFile` merge.
- [x] EP-1 (2026-06-17): Add `SHOMEI_PASSWORD_*` env overrides (reused existing `boolEnv`, added `intEnvMaybe`) and config tests proving precedence.
- [ ] EP-2: Embed common-password dictionary and implement the dictionary check (`PasswordTooCommon`).
- [ ] EP-2: Implement context-aware validation (`PasswordResemblesIdentity`) and thread context through the three workflows (IP-3).
- [ ] EP-2: Servant error mapping for new violation + tests (signup/change/reset reject common & identity-derived passwords).
- [ ] EP-3: Add `PasswordBreachChecker` effect + in-memory fake wired into `runInMemory` (IP-5).
- [ ] EP-3: Implement HIBP k-anonymity production interpreter (SHA-1 prefix range query, fail-open/closed, timeout).
- [ ] EP-3: Add effectful breach guard to the three workflows (IP-3), Servant mapping for `PasswordBreached`, and tests.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- During child-plan authoring (2026-06-17), the Servant error mapping (IP-4) was found to map
  the `WeakPassword _` group with a wildcard rather than enumerating each
  `PasswordPolicyViolation` constructor. Consequence: EP-2 (`PasswordResemblesIdentity`) and
  EP-3 (`PasswordBreached`) most likely need **no** Servant edit — the new constructors fall
  through the existing branch. Each plan still instructs the implementer to confirm and to add a
  test if the Servant suite asserts on violation rendering. This relaxes IP-4 from a likely edit
  to a verification step.

- EP-3 authoring found that the production effect-stack type alias `AppEffects` is **duplicated**
  in two places — `Shomei.Server.App` and `Shomei.Servant.Seam` — plus the test harnesses that
  compose fakes in `AppEffects` order. Adding the `PasswordBreachChecker` effect (IP-5) therefore
  touches more than `runInMemory`: both `AppEffects` definitions and the production stack
  assembly (`runAppIO`) must gain the effect in matching order. EP-3's plan accounts for this.

- EP-1 implementation (2026-06-17) found that a `boolEnv :: Text -> IO (Maybe Bool)` helper
  **already exists** in `shomei-server/src/Shomei/Server/Config.hs` (added for the WebAuthn env
  overlay; lowercases input, accepts `true`/`false`, errors otherwise). EP-1 therefore added only
  `intEnvMaybe` and reused the existing `boolEnv`; the plan's instruction to add `boolEnv` was
  correctly skipped (a duplicate definition would not compile). No effect on EP-2/EP-3, which add
  no env helpers, but noted so future config-plumbing work does not re-add it.

- EP-2 authoring flagged a test-design trap from the chosen defaults: `defaultPasswordPolicy`
  sets `minLength = 12`, so a would-be "common password" fixture shorter than 12 characters
  (e.g. `password123`, 11 chars) is rejected by the length check first and never reaches the
  common/contextual branch. EP-2 tests must use a small-`minLength` test policy to exercise the
  common and contextual checks in isolation.


## Decision Log

- Decision: Decompose into three child plans (EP-1 foundation/config, EP-2 local common+contextual
  checks, EP-3 opt-in HIBP breach check) rather than one plan or per-feature config edits.
  Rationale: keeps each plan within the ExecPlan size guidance, makes each independently
  verifiable, and — by giving EP-1 sole ownership of every configuration-surface edit — removes
  the merge-conflict coupling that per-feature config edits would create on `FileConfig`, the
  Dhall files, and the env-override function.
  Date: 2026-06-17

- Decision: EP-1 adds all seven `PasswordPolicy` fields up front, including ones whose behavior
  only arrives with EP-2/EP-3 (the flags are inert scaffolding until then).
  Rationale: concentrates the shared `PasswordPolicy` / config plumbing in one place (IP-1) so
  the later plans add behavior without re-touching shared configuration files; the inert-flag
  scaffold pattern is explicitly sanctioned for de-risking a coordinated extension.
  Date: 2026-06-17

- Decision: Default `rejectCommonPasswords` and `rejectContextualPasswords` to `True`;
  default `breachCheckEnabled` to `False` and `breachCheckFailClosed` to `False` (fail open).
  Rationale: the local checks are free, deterministic, and have no external dependency, so a
  secure-by-default posture turns them on; the HIBP check adds network latency and an external
  dependency, so it is opt-in, and when enabled it defaults to fail-open so an HIBP outage does
  not block all logins/signups — operators who prefer strictness set
  `breachCheckFailClosed = True`. Note: because EP-1 only wires the flags (no behavior), the
  defaults change observable behavior only when EP-2 lands; EP-2 must adjust any test fixture
  whose password happens to appear in the common-password dictionary.
  Date: 2026-06-17

- Decision: Use existing `PasswordTooCommon` for dictionary hits; add `PasswordResemblesIdentity`
  (EP-2) and `PasswordBreached` (EP-3) as new constructors (IP-2).
  Rationale: reuse the reserved constructor where it fits; distinct constructors for distinct
  failure modes give clear, actionable client errors without leaking whether/where a password
  was seen.
  Date: 2026-06-17

- Decision: Breach checking is introduced as a new `PasswordBreachChecker` effect/port with an
  effectful guard in the workflows, not folded into the pure `validatePassword`.
  Rationale: the HIBP check performs IO (an HTTPS request); the pure `Either`-returning
  `validatePassword` cannot perform IO, and mirroring the existing `PasswordHasher` port keeps
  the design swappable and gives tests an in-memory fake (IP-5).
  Date: 2026-06-17

- Decision: Defer character-class rules, entropy scoring, password history/reuse prevention,
  forced rotation, and a server-side pepper to possible future plans.
  Rationale: the requested scope is items 1, 2, and 4 (breach, common/contextual, configurability);
  the deferred items are independently valuable but out of scope here and would dilute the plans.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
