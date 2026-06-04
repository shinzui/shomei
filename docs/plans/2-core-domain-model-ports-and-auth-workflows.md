---
id: 2
slug: core-domain-model-ports-and-auth-workflows
title: "Core domain model, ports, and auth workflows"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# Core domain model, ports, and auth workflows

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-2**, the second child plan of the MasterPlan
`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`. It hard-depends on **EP-1**
(`docs/plans/1-project-scaffolding-and-multi-package-build-foundation.md`), which produces the
compiling multi-package cabal workspace, the shared cabal `common` stanzas, and the
`Shomei.Prelude` custom prelude. EP-2 fills the `packages/shomei-core` package and owns
Integration Points **IP-2** (domain types + `Shomei.Id`), **IP-3** (port effect interfaces),
**IP-4** (`StoredSigningKey` + `SigningKeyStore`), and **IP-5** (`ShomeiConfig`). Every later
plan (EP-3 PostgreSQL, EP-4 JWT, EP-5 Servant, EP-6 server, EP-7 demos) consumes these.


## Purpose / Big Picture

After this change, `shomei-core` contains the complete, transport-agnostic heart of the
Shōmei authentication toolkit: every domain type (with safe smart constructors), the typed
identifiers, the error vocabulary, the runtime configuration, the **ports** (the abstract
interfaces to the outside world, expressed as `effectful` effects), and the **auth workflows**
(signup, login, refresh-token rotation with reuse detection, logout, and token verification)
written purely against those ports. No database, no JWT library, no HTTP — just the rules of
the system.

The observable outcome is a **green pure test suite** that drives the real workflows through
an in-memory interpreter of every port and proves the security-critical behaviors end to end:
a user can sign up and then log in with the same credentials; a refresh rotates the token and
marks the old one used; **presenting an already-used refresh token is detected as theft and
revokes the whole token family and the session**; logout revokes the session; password
verification fails closed; and login with an unknown email returns the *same* generic error
as a wrong password (no account-existence leak). Concretely, after this plan a developer can
run `cabal test shomei-core` and see all tasty test cases pass, with zero infrastructure
running.

Definitions used throughout (so a reader new to the codebase is not lost):

- **Port** — an abstract capability the core needs from the outside world (e.g. "store a
  user", "hash a password", "tell me the current time"). The core depends only on the *shape*
  of the capability, never on a concrete implementation. We express each port as an
  `effectful` dynamic effect.
- **`effectful` effect** — a value of kind `Effect` declared as a GADT, registered as
  dynamically dispatched via `type instance DispatchOf E = Dynamic`. Each constructor is one
  operation; a thin `send`-based "smart constructor" exposes it as an ordinary function
  `(E :> es) => ... -> Eff es a`. An **interpreter** (`interpret`/`interpret_`) supplies the
  behavior; production interpreters live in adapter packages (EP-3/EP-4), and an in-memory
  interpreter for tests lives here.
- **Smart constructor** — a function that builds a value while enforcing invariants the raw
  constructor cannot (e.g. `mkEmail :: Text -> Either AuthError Email` normalizes and rejects
  bad input). The raw data constructor is not exported, so invalid values are unrepresentable
  outside the module.
- **TypeID** — a globally-unique, sortable identifier that is a UUIDv7 with a human-readable
  type prefix (e.g. `user_01h…`). We use `mmzk-typeid`'s `KindID`, where the prefix is a
  type-level string, so `UserId` and `SessionId` are distinct types that cannot be confused.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `shomei-core.cabal` build-depends and exposed-modules updated for EP-2 deps
  (mmzk-typeid, uuid, http-api-data, containers, time, aeson, text, lens, generic-lens,
  bytestring, base64, effectful, effectful-core, plus test deps). (2026-06-03; exposed-modules
  scoped to the M1 set for incremental builds — Port.*/Workflow/test-suite re-added in M2/M3.)
- [x] M1: `Shomei.Id` compiles (TypeID identifiers + orphan http-api-data instances). (2026-06-03)
- [x] M1: `Shomei.Error` compiles (`AuthError`, `TokenError`, `PasswordPolicyViolation`). (2026-06-03)
- [x] M1: `Shomei.Domain.*` modules compile (User, Email, Password, Credential, Session,
  RefreshToken, Token, Claims, Event, SigningKey, plus the `New*` and `*Command` records). (2026-06-03)
- [x] M1: `Shomei.Config` compiles (`ShomeiConfig`, `defaultShomeiConfig`, transport/check
  enums, default TTLs). Acceptance: `cabal build shomei-core`. (2026-06-03; 15 modules, exit 0)
- [x] M2: `Shomei.Port.*` modules compile (UserStore, CredentialStore, SessionStore,
  RefreshTokenStore, PasswordHasher, TokenSigner, TokenVerifier, AuthEventPublisher,
  SigningKeyStore, Clock, TokenGen) with `send` smart constructors. (2026-06-03)
- [x] M2: `Shomei.Port.InMemory` compiles (in-memory `World` + interpreter for every port).
  (2026-06-03; `cabal build shomei-core` exit 0, zero warnings)
- [x] M3: `Shomei.Workflow` compiles (signup, login, refresh, logout, verifyToken). (2026-06-03)
- [x] M3: `test-suite shomei-core-test` written and passing. Acceptance:
  `cabal test shomei-core` green with all cases passing. (2026-06-03; all 7 cases OK, zero
  warnings; `cabal build all` also green)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`OverloadedRecordDot` only solves `HasField` when the field is in scope.** With
  `DuplicateRecordFields`, accessing `nu.email` for `nu :: NewUser` fails unless the
  record is imported with its fields (`NewUser (..)`), not just the type (`NewUser`). The
  error is `GHC-39999: Could not deduce HasField "email" NewUser Email`. Fix: import every
  record whose fields are read via `.field` with `(..)`. This bit `Shomei.Port.InMemory`
  for `NewUser`/`NewSession`/`NewRefreshToken`/`StoredSigningKey`.

- **Generic-lens `#field` needs `Generic` on the focused record.** The in-memory `World`
  initially lacked `deriving stock (Generic)`, so `#users %~ …` failed with
  `No instance for 'Generic World'`. Added the derive.

- **`-Wall` flags the "import the prelude everywhere" convention.** Seven port-effect
  modules use no `Shomei.Prelude` name (only base `Maybe`/`Either`/`Bool`/`(.)`, which come
  from the still-implicit base `Prelude`), so `-Wunused-imports` reported the
  `Shomei.Prelude` import as redundant in each. See Decision Log for the resolution.

- **The standard `Prelude` is still implicitly imported alongside `Shomei.Prelude`.**
  `Shomei.Prelude` does not enable `NoImplicitPrelude`, so base names (`show`, `Either`,
  `Int`, `Maybe`, `(.)`, …) remain available; the custom prelude only *adds* names. This is
  why modules that use only base names do not need to import `Shomei.Prelude` at all.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model the core ports as `effectful` dynamic effects (GADT + `DispatchOf = Dynamic`
  + `send` smart constructors), not the spec's tagless-final `class Monad m => UserStore m`.
  Rationale: Inherited from the MasterPlan's kickoff decision; matches house style (kizashi's
  `AppEffects`) and gives one interpretable effect stack with IO and in-memory interpreters.
  The spec's typeclass method sets translate 1:1 to effect constructors.
  Date: 2026-06-03

- Decision: Identifiers are `mmzk-typeid` `KindID` TypeIDs (`user`, `session`, `refresh_token`,
  `credential` prefixes), exposed from `Shomei.Id`, with orphan `FromHttpApiData`/
  `ToHttpApiData` instances living in core.
  Rationale: Self-describing IDs; the prefix makes `UserId`/`SessionId` distinct types.
  mmzk-typeid ships `FromJSON`/`ToJSON` but not http-api-data, and EP-5's Servant `Capture`s
  need them; `http-api-data` is a pure dependency so it is acceptable in the transport-agnostic
  core. Diverges from the spec's raw `newtype UserId = UserId UUID`.
  Date: 2026-06-03

- Decision: `PlainPassword` has a redacting `Show` instance (`show = const "PlainPassword
  <redacted>"`) and no `ToJSON`/`FromJSON` that would emit the secret; it is never logged,
  serialized, or persisted.
  Rationale: The spec's hard security requirement. A derived `Show` would leak the password in
  traces and error messages.
  Date: 2026-06-03

- Decision: `login` returns the single generic `InvalidCredentials` error for both an unknown
  email and a wrong password, and only performs password verification after the credential is
  found.
  Rationale: Spec requirement: do not reveal whether an account exists. (A constant-time hash
  comparison and a dummy-verify-on-missing-account hardening pass are deferred to the adapter
  interpreter in EP-3; the workflow contract here is the generic-error guarantee.)
  Date: 2026-06-03

- Decision: Reuse detection in `refresh` triggers when the persisted token's status is `Used`
  (or `Revoked`): revoke the entire refresh-token family, revoke the session, publish
  `RefreshTokenReuseDetected`, and return the `RefreshTokenReuseDetected` error.
  Rationale: Spec's "treat as possible token theft and revoke the session". Family revocation
  is keyed off the presented token's id so the interpreter can walk parent/child links.
  Date: 2026-06-03

- Decision: Signing keys cross the `SigningKeyStore` port as a storage-agnostic
  `StoredSigningKey` whose key material is opaque `Text` (JWK JSON); `shomei-core` never
  imports `jose`.
  Rationale: Inherited IP-4 decision; preserves the transport-agnostic core. Only `shomei-jwt`
  (EP-4) converts `StoredSigningKey` ↔ `jose` `JWK`. Note: the `StoredSigningKey` field names
  use `publicKeyJwk`/`privateKeyJwk` here (JWK JSON), while the spec's SQL columns are named
  `public_key_pem`/`private_key_pem_encrypted` — EP-3 maps between them.
  Date: 2026-06-03

- Decision: Provide an in-memory interpreter (`Shomei.Port.InMemory`) for every port, backing
  the pure test suite; no DB/JWT in EP-2 tests.
  Rationale: Lets the workflows be validated as behavior (not just compilation) with zero
  infrastructure, which is the demonstrable outcome of this plan. `TokenSigner`/`TokenVerifier`
  get trivial deterministic fakes here; real signing is EP-4.
  Date: 2026-06-03

- Decision (during implementation): Use `generic-lens` `#field` lenses for record *updates*
  in `Shomei.Port.InMemory` (e.g. `tok & #status .~ RefreshTokenRevoked`), and derive
  `Generic` on the `World` record.
  Rationale: With `DuplicateRecordFields`, ordinary record-update syntax (`tok { status = … }`)
  is ambiguous across the many records that share a `status` field. The `#field` lens is
  type-directed and unambiguous, and is the house style. Reads still use `OverloadedRecordDot`
  (`tok.status`); fresh records use explicit constructors.
  Date: 2026-06-03

- Decision (during implementation): Drop the `import Shomei.Prelude` line from the seven
  port-effect modules that reference no `Shomei.Prelude` name (UserStore, CredentialStore,
  PasswordHasher, TokenSigner, TokenVerifier, AuthEventPublisher, TokenGen); keep it where a
  prelude name (`UTCTime`/`Text`) is actually used (SessionStore, RefreshTokenStore,
  SigningKeyStore, Clock) and in all domain/workflow/interpreter modules.
  Rationale: The common stanza enables `-Wall` (hence `-Wunused-imports`), and an unused
  `Shomei.Prelude` import produces a warning. The "import the prelude in every module"
  convention exists to keep base `Prelude`'s partial functions out and to share the house
  re-exports; a module that uses only base names (`Maybe`/`Either`/`Bool`/`(.)`) from the
  still-implicit base `Prelude` violates neither intent. Warning-free `-Wall` builds take
  precedence here. Domain modules and the workflow keep importing `Shomei.Prelude`.
  Date: 2026-06-03

- Decision (during implementation): The in-memory `TokenSigner`/`TokenVerifier` fakes
  round-trip `AuthClaims` through aeson JSON (`encode` / `eitherDecode`), so `verifyToken`
  would work end-to-end against them even though the seven EP-2 acceptance cases do not
  exercise it.
  Rationale: A faithful fake (sign then verify yields the original claims) is more useful to
  later plans and tests than a constant stub, at negligible cost.
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Achieved (2026-06-03).** `shomei-core` now holds the complete transport-agnostic heart of
Shōmei: TypeID identifiers (`Shomei.Id`), the error vocabulary (`Shomei.Error`), all domain
types with smart constructors (`Shomei.Domain.*`), the runtime config (`Shomei.Config`), the
eleven port effects (`Shomei.Port.*`, IP-3) with `send` smart constructors, the storage-agnostic
`StoredSigningKey` (IP-4), an in-memory interpreter for every port (`Shomei.Port.InMemory`), and
the five auth workflows (`Shomei.Workflow`). `cabal build shomei-core` and `cabal build all` are
green with zero warnings, and `cabal test shomei-core` passes all seven behavioral cases that
prove the security-critical properties: signup→login round-trip, refresh rotation with the old
token marked Used, **reuse detection that revokes the whole token family and the session**,
logout revocation, fail-closed password verification, and the no-account-existence-leak generic
error. The suite uses only the in-memory interpreter — no DB, JWT, or network.

**Faithfulness to the contract.** The exported signatures match the plan's IP-2/IP-3/IP-4/IP-5
contracts that EP-3/EP-4/EP-5 consume. The only deviations are internal and documented in the
Decision Log (generic-lens for record updates; dropping the unused `Shomei.Prelude` import from
seven trivial port modules to satisfy `-Wall`; an aeson-round-trip `TokenSigner`/`TokenVerifier`
fake). No port *signature* changed, so no cascade to adapter plans is required.

**For the next contributor.** EP-3 (PostgreSQL) and EP-4 (JWT) implement the same port effects
against real infrastructure; the in-memory interpreter here is the executable reference for the
expected behavior (especially `RevokeRefreshTokenFamily`'s parent-link walk and the
fail-closed/no-leak login rules). Importing a domain record for `.field` access requires `(..)`
(the `OverloadedRecordDot`/`DuplicateRecordFields` discovery in Surprises). The `Shomei.Domain.Event`
constructors deliberately share names with `AuthError`/status constructors, so import that module
qualified.


## Context and Orientation

The repository is the Shōmei monorepo at `/Users/shinzui/Keikaku/bokuno/shomei`. The package
identity is declared in `mori.dhall` (run `mori show --full` to see it): six packages under
`packages/`, with `shomei-core` as the transport-agnostic root that every other package
depends on. EP-1 creates the cabal workspace (`cabal.project`, `with-compiler: ghc-9.12.4`),
the shared cabal `common` stanzas, and `packages/shomei-core/` with its `shomei-core.cabal`
and the `Shomei.Prelude` module. **This plan assumes EP-1 has landed**: `cabal build all`
already succeeds and `Shomei.Prelude` already exists and re-exports base/text/aeson/time/lens
plus `eventAesonOptions`.

House build conventions (mandatory, established by EP-1 and reused verbatim here):

- GHC **9.12.4**, language edition **GHC2024**, `cabal-version: 3.0`.
- Each `.cabal` imports two shared stanzas via `import: warnings, shared`:
  - `common warnings` enables `-Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints`.
  - `common shared` sets `default-extensions: DeriveAnyClass, DuplicateRecordFields,
    BlockArguments, MultilineStrings, OverloadedLabels, OverloadedRecordDot, OverloadedStrings,
    PackageImports, QualifiedDo, TemplateHaskell`.
- Postpositive qualified imports: `import Data.Text qualified as Text`.
- Records: strict `!` fields, the entity-id field first, **no field prefixes** (we rely on
  `DuplicateRecordFields` + `OverloadedRecordDot`), `deriving stock (Generic, Eq, Show)`,
  `deriving anyclass (FromJSON, ToJSON)`, and `deriving newtype (...)` for newtypes.
- Lens `#field` access (from `generic-lens`) requires `import "generic-lens"
  Data.Generics.Labels ()` **per module** that uses `#label`; this orphan is **never** added to
  the prelude.
- The custom prelude `Shomei.Prelude` is imported in **every** module of the package.

Key files this plan creates or edits, all under `/Users/shinzui/Keikaku/bokuno/shomei`:

```text
packages/shomei-core/shomei-core.cabal                    (edit: deps + exposed-modules + test-suite)
packages/shomei-core/src/Shomei/Id.hs                     (new)
packages/shomei-core/src/Shomei/Error.hs                  (new)
packages/shomei-core/src/Shomei/Domain/User.hs            (new)
packages/shomei-core/src/Shomei/Domain/Email.hs           (new)
packages/shomei-core/src/Shomei/Domain/Password.hs        (new)
packages/shomei-core/src/Shomei/Domain/Credential.hs      (new)
packages/shomei-core/src/Shomei/Domain/Session.hs         (new)
packages/shomei-core/src/Shomei/Domain/RefreshToken.hs    (new)
packages/shomei-core/src/Shomei/Domain/Token.hs           (new)
packages/shomei-core/src/Shomei/Domain/Claims.hs          (new)
packages/shomei-core/src/Shomei/Domain/Event.hs           (new)
packages/shomei-core/src/Shomei/Domain/SigningKey.hs      (new)
packages/shomei-core/src/Shomei/Domain/Command.hs         (new)
packages/shomei-core/src/Shomei/Config.hs                 (new)
packages/shomei-core/src/Shomei/Port/UserStore.hs         (new)
packages/shomei-core/src/Shomei/Port/CredentialStore.hs   (new)
packages/shomei-core/src/Shomei/Port/SessionStore.hs      (new)
packages/shomei-core/src/Shomei/Port/RefreshTokenStore.hs (new)
packages/shomei-core/src/Shomei/Port/PasswordHasher.hs    (new)
packages/shomei-core/src/Shomei/Port/TokenSigner.hs       (new)
packages/shomei-core/src/Shomei/Port/TokenVerifier.hs     (new)
packages/shomei-core/src/Shomei/Port/AuthEventPublisher.hs(new)
packages/shomei-core/src/Shomei/Port/SigningKeyStore.hs   (new)
packages/shomei-core/src/Shomei/Port/Clock.hs             (new)
packages/shomei-core/src/Shomei/Port/TokenGen.hs          (new)
packages/shomei-core/src/Shomei/Port/InMemory.hs          (new)
packages/shomei-core/src/Shomei/Workflow.hs               (new)
packages/shomei-core/test/Main.hs                         (new)
packages/shomei-core/test/Shomei/WorkflowSpec.hs          (new)
```

The authoritative field lists come from `docs/initial-spec.md` (sections "Core Domain Model",
"Auth Claims", "Core Ports", "Commands", "Events", "Errors", "Configuration"). The only
deliberate adaptation is replacing every `newtype XId = XId UUID` with the corresponding
`Shomei.Id` TypeID. The `mmzk-typeid` source consulted for the `KindID` API lives on disk at
`/Users/shinzui/Keikaku/hub/haskell/mmzk-typeid-project/mmzk-typeid/src/Data/KindID/V7.hs`
(found via `mori registry show mmzk-typeid --full`); the relevant exports are `genKindID`,
`getUUID`, `decorateKindID`, `toText`, and `parseText`.

Constraint (inherited, non-negotiable): `shomei-core` must **not** depend on servant, wai,
hasql, postgresql, jose, or any HTTP/JWT library. Allowed dependencies are base, text, aeson,
time, containers, lens, generic-lens, mmzk-typeid, uuid, http-api-data, effectful/
effectful-core, bytestring, and base64 (for token text). `http-api-data` is permitted because
it is pure (no transport); the orphan instances it requires live in `Shomei.Id`.


## Plan of Work

The work proceeds in three independently verifiable milestones, each ending in a concrete
build/test command.

### Milestone M1 — Identifiers, domain types, errors, config compile

Scope: everything data-shaped. Add the EP-2 build-depends and exposed-modules to
`packages/shomei-core/shomei-core.cabal`. Create `Shomei.Id` (TypeID identifiers + orphan
http-api-data instances). Create `Shomei.Error` (`AuthError`, `TokenError`,
`PasswordPolicyViolation`). Create the `Shomei.Domain.*` modules (one concern per module) with
their smart constructors. Create `Shomei.Config` (`ShomeiConfig`, the transport/check enums,
`defaultShomeiConfig`, and the default TTLs). At the end of M1, `packages/shomei-core`
type-checks with no ports and no workflows yet. Acceptance: `cabal build shomei-core`
succeeds.

### Milestone M2 — Port effects + in-memory interpreters compile

Scope: the abstract boundary. Create the eleven `Shomei.Port.*` effect modules, each a GADT
`Effect` with `type instance DispatchOf E = Dynamic` and one `send`-based smart constructor per
operation, matching the exact method sets below. Then create `Shomei.Port.InMemory`: a mutable
`World` record holding maps for users, credentials, sessions, and refresh tokens (plus signing
keys and a published-event log), and an `interpret`/`interpret_`-based handler for every port
backed by an `IORef World` (or the `effectful` `State` effect). At the end of M2, the ports and
interpreters compile but are not yet exercised. Acceptance: `cabal build shomei-core`
succeeds.

### Milestone M3 — Workflows implemented; pure in-memory tests pass

Scope: the behavior. Create `Shomei.Workflow` with `signup`, `login`, `refresh`, `logout`, and
`verifyToken`, each a function over the port effects returning `Eff es (Either AuthError ...)`,
implemented per the spec's "Workflows" section. Then create the tasty test suite
(`test/Main.hs` + `test/Shomei/WorkflowSpec.hs`) that runs the workflows through
`Shomei.Port.InMemory.runInMemory` and asserts the round-trip, rotation, reuse-detection,
logout, fail-closed, and generic-error behaviors. At the end of M3, the security-critical
behaviors are demonstrated. Acceptance: `cabal test shomei-core` is green.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop` (the dev shell EP-1 provides). Create the source files exactly as specified in
"Interfaces and Dependencies" below.

### Step 1 — Edit the cabal file (M1)

Add the EP-2 dependencies, the new library modules, and the test-suite to
`packages/shomei-core/shomei-core.cabal`. The `library` stanza gains:

```cabal
library
  import:           warnings, shared
  hs-source-dirs:   src
  default-language: GHC2024
  build-depends:
    , aeson
    , base
    , base64
    , bytestring
    , containers
    , effectful
    , effectful-core
    , generic-lens
    , http-api-data
    , lens
    , mmzk-typeid
    , text
    , time
    , uuid
  exposed-modules:
    Shomei.Prelude
    Shomei.Id
    Shomei.Error
    Shomei.Config
    Shomei.Domain.User
    Shomei.Domain.Email
    Shomei.Domain.Password
    Shomei.Domain.Credential
    Shomei.Domain.Session
    Shomei.Domain.RefreshToken
    Shomei.Domain.Token
    Shomei.Domain.Claims
    Shomei.Domain.Event
    Shomei.Domain.SigningKey
    Shomei.Domain.Command
    Shomei.Port.UserStore
    Shomei.Port.CredentialStore
    Shomei.Port.SessionStore
    Shomei.Port.RefreshTokenStore
    Shomei.Port.PasswordHasher
    Shomei.Port.TokenSigner
    Shomei.Port.TokenVerifier
    Shomei.Port.AuthEventPublisher
    Shomei.Port.SigningKeyStore
    Shomei.Port.Clock
    Shomei.Port.TokenGen
    Shomei.Port.InMemory
    Shomei.Workflow
```

(`Shomei.Prelude` is listed because EP-1 already created it; keep its line. Drop the EP-1
placeholder module if one exists.) Append the test-suite stanza (mirrors kizashi's layout):

```cabal
test-suite shomei-core-test
  import:           warnings, shared
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  default-language: GHC2024
  ghc-options:      -threaded -rtsopts -with-rtsopts=-N
  other-modules:
    Shomei.WorkflowSpec
  build-depends:
    , base
    , containers
    , effectful
    , effectful-core
    , shomei-core
    , tasty
    , tasty-hunit
    , text
    , time
```

Verify the dependency solver is satisfied:

```bash
cabal build --dry-run shomei-core
```

Expected: the plan resolves, listing `mmzk-typeid`, `effectful`, `http-api-data`, `base64`,
etc., with no "unknown package" or version-conflict errors.

### Step 2 — Create `Shomei.Id`, `Shomei.Error`, the domain modules, and `Shomei.Config` (M1)

Create each file from "Interfaces and Dependencies". Then build:

```bash
cabal build shomei-core
```

Expected (abridged):

```text
Building library for shomei-core-0.1.0.0...
[ 1 of 16] Compiling Shomei.Id
[ 2 of 16] Compiling Shomei.Error
...
[16 of 16] Compiling Shomei.Config
```

M1 acceptance: this command exits 0.

### Step 3 — Create the `Shomei.Port.*` modules and `Shomei.Port.InMemory` (M2)

Create the eleven port modules and the interpreter module, then build:

```bash
cabal build shomei-core
```

Expected: compiles the eleven `Shomei.Port.*` modules and `Shomei.Port.InMemory`, exits 0.
M2 acceptance.

### Step 4 — Create `Shomei.Workflow` and the test suite (M3)

Create `Shomei.Workflow`, `test/Main.hs`, and `test/Shomei/WorkflowSpec.hs`. Run:

```bash
cabal test shomei-core
```

Expected tasty transcript:

```text
shomei-core-test
  Shomei.Workflow
    signup then login round-trips:                              OK
    refresh rotates token and old token becomes Used:           OK
    presenting an already-used refresh token detects reuse:     OK
    reuse detection revokes the session:                        OK
    logout revokes the session:                                 OK
    password verification fails closed on wrong password:       OK
    unknown email yields the same generic error as wrong pass:  OK

All 7 tests passed (0.00s)
```

M3 acceptance: `cabal test shomei-core` exits 0 with all cases passing.


## Validation and Acceptance

Validation is behavioral, not just "it compiles". The acceptance criteria, each with concrete
input and observable output:

1. **Signup then login round-trip.** `signup defaultShomeiConfig (SignupCommand email pw
   (Just "Nadeem"))` returns `Right (user, pair)` with `user.email == mkEmail "…"` normalized
   and a non-empty `pair.accessToken`/`pair.refreshToken`. A subsequent `login
   defaultShomeiConfig (LoginCommand email pw)` returns `Right (user', pair')` with
   `user'.userId == user.userId`. Observable: both `Either` values are `Right`; the user ids
   match.

2. **Refresh rotates and the old token becomes Used.** Given `pair` from signup,
   `refresh defaultShomeiConfig (RefreshCommand pair.refreshToken)` returns `Right pair2` with
   `pair2.refreshToken /= pair.refreshToken`. Inspecting the in-memory `World`, the persisted
   row for the original token now has `status == RefreshTokenUsed` and the new row has
   `parentTokenId == Just <old id>`. Observable: the returned token differs; the world shows
   the status transition.

3. **Reuse detection.** After step 2, calling `refresh` *again with the original
   `pair.refreshToken`* returns `Left RefreshTokenReuseDetected`. The world shows the entire
   refresh-token family `status == RefreshTokenRevoked` and the session `status ==
   SessionRevoked`; a `RefreshTokenReuseDetected` event is in the published-event log.
   Observable: the `Left` value and the revocations.

4. **Logout revokes.** `logout defaultShomeiConfig (LogoutCommand sid)` returns `Right ()`; the
   session `status == SessionRevoked` and all its refresh tokens are revoked; a `SessionRevoked`
   event is published. Observable: the world state and the event log.

5. **Fail-closed password verification.** `login defaultShomeiConfig (LoginCommand email
   wrongPw)` returns `Left InvalidCredentials` and publishes a `LoginFailed` event.

6. **No account-existence leak.** `login defaultShomeiConfig (LoginCommand unknownEmail pw)`
   returns *exactly* `Left InvalidCredentials` — the same value as case 5 — and performs no
   password verification on a non-existent credential. Observable: identical `Left`
   constructors for the unknown-email and wrong-password cases.

These are encoded as tasty-hunit assertions in `test/Shomei/WorkflowSpec.hs`. The exact
command is `cabal test shomei-core`; the expected transcript is in Concrete Steps, Step 4. The
suite uses **only** the in-memory interpreter — no PostgreSQL, no JWT library, no network — so a
green run proves the workflows' logic in isolation.


## Idempotence and Recovery

All steps are safe to repeat. Creating the source files is idempotent: re-running the edits
overwrites the same files with the same content. `cabal build` and `cabal test` are naturally
idempotent and only recompile what changed; a stale-cache failure recovers with
`cabal clean && cabal build shomei-core`. The cabal-file edit is additive (new deps,
exposed-modules, and a test-suite); if the solver fails on a missing package, recover by
confirming the package set in `nix develop` (EP-1's `flake.nix`) provides it — none of the EP-2
deps are exotic (all are on the GHC 9.12 snapshot). No external state is mutated: there is no
database, no migration, and no files outside `packages/shomei-core/`. If a workflow test fails,
the in-memory `World` is reconstructed fresh per test case (each test calls `runInMemory` with a
new empty world), so there is no cross-test contamination to clean up.


## Interfaces and Dependencies

Libraries used and why: **mmzk-typeid** (typed `KindID` identifiers — `mori.dhall` already
lists it), **uuid** (the underlying `UUID` stored in Postgres by EP-3), **http-api-data**
(`FromHttpApiData`/`ToHttpApiData` for EP-5's Servant captures; pure, so allowed in core),
**effectful**/**effectful-core** (the port effects and their interpreters), **containers**
(`Set Scope`/`Set Role`, and the in-memory `Map` stores), **aeson** (JSON instances for DTOs in
EP-5), **time** (`UTCTime`/`NominalDiffTime`), **lens** + **generic-lens** (`#field` access),
**bytestring** + **base64** (opaque token text), **text** (the workhorse string type).
**tasty**/**tasty-hunit** (test suite). Forbidden: servant, wai, hasql, postgresql, jose.

The signatures below are the **contract other plans consume**. EP-2 **owns** IP-2 (domain
types + `Shomei.Id`), IP-3 (the port effects), IP-4 (`StoredSigningKey` + `SigningKeyStore`),
and IP-5 (`ShomeiConfig`). Adapter plans must implement the port effects exactly and may not
change a signature without a Decision Log entry here.

### IP-2 — `Shomei.Id` (identifiers)

This is the exact module (uses the mmzk-typeid `Data.KindID.V7` API verified on disk):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Shomei.Id
  ( UserId, SessionId, RefreshTokenId, CredentialId
  , genUserId, genSessionId, genRefreshTokenId, genCredentialId
  , idText, parseId
  , userIdToUUID, userIdFromUUID
  , sessionIdToUUID, sessionIdFromUUID
  , refreshTokenIdToUUID, refreshTokenIdFromUUID
  , credentialIdToUUID, credentialIdFromUUID
  ) where

import Shomei.Prelude
import Data.Text qualified as Text
import Data.UUID (UUID)
import Data.KindID.V7 (KindID, getUUID, decorateKindID)
import Data.KindID.V7 qualified as KindID
import Data.KindID.Class (ToPrefix (..), ValidPrefix)
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

type UserId         = KindID "user"
type SessionId      = KindID "session"
type RefreshTokenId = KindID "refresh_token"
type CredentialId   = KindID "credential"

genUserId :: MonadIO m => m UserId
genUserId = KindID.genKindID @"user"

genSessionId :: MonadIO m => m SessionId
genSessionId = KindID.genKindID @"session"

genRefreshTokenId :: MonadIO m => m RefreshTokenId
genRefreshTokenId = KindID.genKindID @"refresh_token"

genCredentialId :: MonadIO m => m CredentialId
genCredentialId = KindID.genKindID @"credential"

idText :: (ToPrefix p, ValidPrefix (PrefixSymbol p)) => KindID p -> Text
idText = KindID.toText

parseId :: forall p. (ToPrefix p, ValidPrefix (PrefixSymbol p)) => Text -> Either Text (KindID p)
parseId t = case KindID.parseText @p t of
  Left e  -> Left (Text.pack (show e))
  Right k -> Right k

userIdToUUID :: UserId -> UUID
userIdToUUID = getUUID
userIdFromUUID :: UUID -> UserId
userIdFromUUID = decorateKindID

sessionIdToUUID :: SessionId -> UUID
sessionIdToUUID = getUUID
sessionIdFromUUID :: UUID -> SessionId
sessionIdFromUUID = decorateKindID

refreshTokenIdToUUID :: RefreshTokenId -> UUID
refreshTokenIdToUUID = getUUID
refreshTokenIdFromUUID :: UUID -> RefreshTokenId
refreshTokenIdFromUUID = decorateKindID

credentialIdToUUID :: CredentialId -> UUID
credentialIdToUUID = getUUID
credentialIdFromUUID :: UUID -> CredentialId
credentialIdFromUUID = decorateKindID

instance (ToPrefix p, ValidPrefix (PrefixSymbol p)) => FromHttpApiData (KindID p) where
  parseUrlPiece = parseId

instance (ToPrefix p, ValidPrefix (PrefixSymbol p)) => ToHttpApiData (KindID p) where
  toUrlPiece = idText
```

mmzk-typeid ships `FromJSON`/`ToJSON` for `KindID`; it does **not** ship http-api-data
instances (hence the orphans, needed by EP-5's servant `Capture`s). The underlying UUID is
stored in Postgres (EP-3) via `getUUID`/`decorateKindID`.

### IP-2 — `Shomei.Error`

```haskell
module Shomei.Error
  ( AuthError (..)
  , TokenError (..)
  , PasswordPolicyViolation (..)
  ) where

import Shomei.Prelude

data PasswordPolicyViolation
  = PasswordTooShort Int            -- minimum length required
  | PasswordTooLong Int             -- maximum length allowed
  | PasswordTooCommon
  | PasswordMissingRequiredClass Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TokenError
  = TokenMalformed
  | TokenSignatureInvalid
  | TokenExpired
  | TokenIssuerInvalid
  | TokenAudienceInvalid
  | TokenOtherError Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AuthError
  = InvalidEmail
  | WeakPassword PasswordPolicyViolation
  | EmailAlreadyRegistered
  | InvalidCredentials
  | UserNotActive
  | SessionNotFound
  | SessionExpired
  | SessionRevoked
  | RefreshTokenInvalid
  | RefreshTokenExpired
  | RefreshTokenReuseDetected
  | TokenInvalid TokenError
  | InternalAuthError Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

### IP-2 — domain modules (signatures the contract guarantees)

`Shomei.Domain.User`:

```haskell
data UserStatus = UserActive | UserSuspended | UserDeleted
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data User = User
  { userId      :: !UserId
  , email       :: !Email
  , displayName :: !(Maybe Text)
  , status      :: !UserStatus
  , createdAt   :: !UTCTime
  , updatedAt   :: !UTCTime
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data NewUser = NewUser
  { email       :: !Email
  , displayName :: !(Maybe Text)
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.Email` — `newtype Email` with a redaction-free derived `Show` and the smart
constructor (raw constructor not exported):

```haskell
module Shomei.Domain.Email (Email, mkEmail, emailText) where

import Shomei.Prelude
import Shomei.Error (AuthError (..))
import Data.Text qualified as Text

newtype Email = Email Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

emailText :: Email -> Text
emailText (Email t) = t

-- Trim whitespace; lowercase the whole address (initial impl); reject invalid shape.
-- Does NOT collapse gmail dots or plus-addressing.
mkEmail :: Text -> Either AuthError Email
mkEmail raw =
  let t = Text.toLower (Text.strip raw)
   in if isValidShape t then Right (Email t) else Left InvalidEmail
  where
    isValidShape t = case Text.splitOn "@" t of
      [local, domain] ->
        not (Text.null local)
          && not (Text.null domain)
          && Text.isInfixOf "." domain
          && not (Text.isInfixOf " " t)
      _ -> False
```

`Shomei.Domain.Password` — `PlainPassword` (redacting `Show`, no JSON), `PasswordHash`,
`PasswordPolicy`, and the pure validator:

```haskell
module Shomei.Domain.Password
  ( PlainPassword (..), PasswordHash (..)
  , PasswordPolicy (..), defaultPasswordPolicy, validatePassword
  ) where

import Shomei.Prelude
import Shomei.Error (PasswordPolicyViolation (..))
import Data.Text qualified as Text

-- Never logged, serialized, or persisted: redacting Show, no FromJSON/ToJSON.
newtype PlainPassword = PlainPassword Text
  deriving stock (Generic)
instance Show PlainPassword where show _ = "PlainPassword <redacted>"

newtype PasswordHash = PasswordHash Text
  deriving stock (Generic)
  deriving newtype (Eq, Show, FromJSON, ToJSON)

data PasswordPolicy = PasswordPolicy
  { minLength :: !Int
  , maxLength :: !Int
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

defaultPasswordPolicy :: PasswordPolicy
defaultPasswordPolicy = PasswordPolicy { minLength = 12, maxLength = 256 }

validatePassword :: PasswordPolicy -> PlainPassword -> Either PasswordPolicyViolation ()
validatePassword policy (PlainPassword pw)
  | Text.length pw < policy.minLength = Left (PasswordTooShort policy.minLength)
  | Text.length pw > policy.maxLength = Left (PasswordTooLong policy.maxLength)
  | otherwise                         = Right ()
```

`Shomei.Domain.Credential`:

```haskell
data Credential = PasswordCredential
  { credentialId :: !CredentialId
  , userId       :: !UserId
  , email        :: !Email
  , passwordHash :: !PasswordHash
  , createdAt    :: !UTCTime
  , updatedAt    :: !UTCTime
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.Session`:

```haskell
data SessionStatus = SessionActive | SessionRevoked | SessionExpired
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data Session = Session
  { sessionId :: !SessionId
  , userId    :: !UserId
  , status    :: !SessionStatus
  , createdAt :: !UTCTime
  , expiresAt :: !UTCTime
  , revokedAt :: !(Maybe UTCTime)
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data NewSession = NewSession
  { userId    :: !UserId
  , createdAt :: !UTCTime
  , expiresAt :: !UTCTime
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.RefreshToken`:

```haskell
newtype RefreshToken     = RefreshToken Text     deriving stock (Generic) deriving newtype (Eq, Show, FromJSON, ToJSON)
newtype RefreshTokenHash = RefreshTokenHash Text deriving stock (Generic) deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data RefreshTokenStatus
  = RefreshTokenActive | RefreshTokenUsed | RefreshTokenRevoked | RefreshTokenExpired
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data PersistedRefreshToken = PersistedRefreshToken
  { refreshTokenId :: !RefreshTokenId
  , sessionId      :: !SessionId
  , tokenHash      :: !RefreshTokenHash
  , parentTokenId  :: !(Maybe RefreshTokenId)
  , status         :: !RefreshTokenStatus
  , createdAt      :: !UTCTime
  , expiresAt      :: !UTCTime
  , usedAt         :: !(Maybe UTCTime)
  , revokedAt      :: !(Maybe UTCTime)
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data NewRefreshToken = NewRefreshToken
  { sessionId     :: !SessionId
  , tokenHash     :: !RefreshTokenHash
  , parentTokenId :: !(Maybe RefreshTokenId)
  , createdAt     :: !UTCTime
  , expiresAt     :: !UTCTime
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.Token`:

```haskell
newtype AccessToken = AccessToken Text deriving stock (Generic) deriving newtype (Eq, Show, FromJSON, ToJSON)

data TokenPair = TokenPair
  { accessToken  :: !AccessToken
  , refreshToken :: !RefreshToken
  , expiresIn    :: !NominalDiffTime
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.Claims`:

```haskell
newtype Issuer   = Issuer Text   deriving stock (Generic) deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)
newtype Audience = Audience Text deriving stock (Generic) deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)
newtype Scope    = Scope Text    deriving stock (Generic) deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)
newtype Role     = Role Text     deriving stock (Generic) deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data AuthClaims = AuthClaims
  { subject   :: !UserId
  , sessionId :: !SessionId
  , issuer    :: !Issuer
  , audience  :: !Audience
  , issuedAt  :: !UTCTime
  , expiresAt :: !UTCTime
  , scopes    :: !(Set Scope)
  , roles     :: !(Set Role)
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.SigningKey` (IP-4):

```haskell
data SigningKeyStatus = KeyPending | KeyActive | KeyRetired | KeyRevoked
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data StoredSigningKey = StoredSigningKey
  { keyId        :: !Text       -- the kid
  , algorithm    :: !Text       -- e.g. "ES256"
  , publicKeyJwk :: !Text       -- opaque JWK JSON; core never imports jose
  , privateKeyJwk:: !Text       -- opaque JWK JSON
  , status       :: !SigningKeyStatus
  , createdAt    :: !UTCTime
  , activatedAt  :: !(Maybe UTCTime)
  , retiredAt    :: !(Maybe UTCTime)
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.Event` — the `AuthEvent` sum, each arm carrying a `*Data` record. The records
carry the relevant identifiers and timestamps (e.g. `UserRegisteredData { userId, email,
occurredAt }`, `LoginFailedData { email, occurredAt }`, `RefreshTokenReuseDetectedData
{ sessionId, refreshTokenId, occurredAt }`); all derive `(Generic, Eq, Show)` + `(FromJSON,
ToJSON)`:

```haskell
data AuthEvent
  = UserRegistered UserRegisteredData
  | LoginSucceeded LoginSucceededData
  | LoginFailed LoginFailedData
  | SessionStarted SessionStartedData
  | SessionRevoked SessionRevokedData
  | RefreshTokenRotated RefreshTokenRotatedData
  | RefreshTokenReuseDetected RefreshTokenReuseDetectedData
  | PasswordChanged PasswordChangedData
  | UserSuspended UserSuspendedData
  | UserDeleted UserDeletedData
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

`Shomei.Domain.Command`:

```haskell
data SignupCommand = SignupCommand
  { email :: !Email, password :: !PlainPassword, displayName :: !(Maybe Text) }
  deriving stock (Generic, Show)

data LoginCommand = LoginCommand { email :: !Email, password :: !PlainPassword }
  deriving stock (Generic, Show)

newtype RefreshCommand = RefreshCommand { refreshToken :: RefreshToken }
  deriving stock (Generic, Show)

newtype LogoutCommand = LogoutCommand { sessionId :: SessionId }
  deriving stock (Generic, Show)
```

(Commands carry `PlainPassword`, so they get a `Show` only via the redacting `PlainPassword`
instance and no `ToJSON`/`FromJSON` for the password-bearing ones; the DTO layer in EP-5
maps requests to these.)

### IP-5 — `Shomei.Config`

```haskell
module Shomei.Config
  ( ShomeiConfig (..), TokenTransport (..), SessionCheckMode (..)
  , SigningKeyConfig (..), defaultShomeiConfig
  , defaultAccessTokenTTL, defaultRefreshTokenTTL, defaultSessionTTL
  ) where

import Shomei.Prelude
import Shomei.Domain.Claims (Issuer (..), Audience (..))
import Shomei.Domain.Password (PasswordPolicy, defaultPasswordPolicy)

data TokenTransport = BearerToken | HttpOnlyCookie | BearerAndCookie
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data SessionCheckMode = VerifyTokenOnly | VerifyTokenAndSession
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

newtype SigningKeyConfig = SigningKeyConfig { algorithm :: Text }
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data ShomeiConfig = ShomeiConfig
  { issuer           :: !Issuer
  , audience         :: !Audience
  , accessTokenTTL   :: !NominalDiffTime
  , refreshTokenTTL  :: !NominalDiffTime
  , sessionTTL       :: !NominalDiffTime
  , passwordPolicy   :: !PasswordPolicy
  , tokenTransport   :: !TokenTransport
  , signingKeyConfig :: !SigningKeyConfig
  , sessionCheckMode :: !SessionCheckMode
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

defaultAccessTokenTTL, defaultRefreshTokenTTL, defaultSessionTTL :: NominalDiffTime
defaultAccessTokenTTL  = 15 * 60            -- 15 minutes
defaultRefreshTokenTTL = 30 * 24 * 60 * 60  -- 30 days
defaultSessionTTL      = 30 * 24 * 60 * 60  -- 30 days

defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig
defaultShomeiConfig iss aud = ShomeiConfig
  { issuer = iss, audience = aud
  , accessTokenTTL = defaultAccessTokenTTL
  , refreshTokenTTL = defaultRefreshTokenTTL
  , sessionTTL = defaultSessionTTL
  , passwordPolicy = defaultPasswordPolicy
  , tokenTransport = BearerToken
  , signingKeyConfig = SigningKeyConfig { algorithm = "ES256" }
  , sessionCheckMode = VerifyTokenOnly
  }
```

### IP-3 — port effects (the `effectful` idiom)

Every port follows this exact shape. Three full modules are shown; the rest are identical in
form. **`UserStore`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

module Shomei.Port.UserStore
  ( UserStore (..)
  , createUser, findUserById, findUserByEmail, updateUserStatus
  ) where

import Shomei.Prelude
import Effectful (Eff, Effect, (:>), Dispatch (..), DispatchOf)
import Effectful.Dispatch.Dynamic (send)
import Shomei.Id (UserId)
import Shomei.Domain.User (User, NewUser, UserStatus)
import Shomei.Domain.Email (Email)

data UserStore :: Effect where
  CreateUser       :: NewUser -> UserStore m User
  FindUserById     :: UserId -> UserStore m (Maybe User)
  FindUserByEmail  :: Email -> UserStore m (Maybe User)
  UpdateUserStatus :: UserId -> UserStatus -> UserStore m ()

type instance DispatchOf UserStore = Dynamic

createUser :: (UserStore :> es) => NewUser -> Eff es User
createUser = send . CreateUser

findUserById :: (UserStore :> es) => UserId -> Eff es (Maybe User)
findUserById = send . FindUserById

findUserByEmail :: (UserStore :> es) => Email -> Eff es (Maybe User)
findUserByEmail = send . FindUserByEmail

updateUserStatus :: (UserStore :> es) => UserId -> UserStatus -> Eff es ()
updateUserStatus uid st = send (UpdateUserStatus uid st)
```

**`RefreshTokenStore`** (the most operation-rich store):

```haskell
data RefreshTokenStore :: Effect where
  CreateRefreshToken         :: NewRefreshToken -> RefreshTokenStore m PersistedRefreshToken
  FindRefreshTokenByHash     :: RefreshTokenHash -> RefreshTokenStore m (Maybe PersistedRefreshToken)
  MarkRefreshTokenUsed       :: RefreshTokenId -> UTCTime -> RefreshTokenStore m ()
  RevokeRefreshTokenFamily   :: RefreshTokenId -> UTCTime -> RefreshTokenStore m ()
  RevokeSessionRefreshTokens :: SessionId -> UTCTime -> RefreshTokenStore m ()
type instance DispatchOf RefreshTokenStore = Dynamic

createRefreshToken         :: (RefreshTokenStore :> es) => NewRefreshToken -> Eff es PersistedRefreshToken
createRefreshToken          = send . CreateRefreshToken
findRefreshTokenByHash     :: (RefreshTokenStore :> es) => RefreshTokenHash -> Eff es (Maybe PersistedRefreshToken)
findRefreshTokenByHash      = send . FindRefreshTokenByHash
markRefreshTokenUsed       :: (RefreshTokenStore :> es) => RefreshTokenId -> UTCTime -> Eff es ()
markRefreshTokenUsed i t    = send (MarkRefreshTokenUsed i t)
revokeRefreshTokenFamily   :: (RefreshTokenStore :> es) => RefreshTokenId -> UTCTime -> Eff es ()
revokeRefreshTokenFamily i t= send (RevokeRefreshTokenFamily i t)
revokeSessionRefreshTokens :: (RefreshTokenStore :> es) => SessionId -> UTCTime -> Eff es ()
revokeSessionRefreshTokens s t = send (RevokeSessionRefreshTokens s t)
```

**`TokenGen`** (support effect — opaque token generation + hashing; the implementation note for
EP-3/EP-6 is crypton `getRandomBytes 32` base64url-encoded for the token and SHA-256 for the
hash, but the *effect* lives in core and the test interpreter is deterministic):

```haskell
data TokenGen :: Effect where
  GenerateOpaqueToken :: TokenGen m RefreshToken
  HashRefreshToken    :: RefreshToken -> TokenGen m RefreshTokenHash
type instance DispatchOf TokenGen = Dynamic

generateOpaqueToken :: (TokenGen :> es) => Eff es RefreshToken
generateOpaqueToken = send GenerateOpaqueToken
hashRefreshToken :: (TokenGen :> es) => RefreshToken -> Eff es RefreshTokenHash
hashRefreshToken = send . HashRefreshToken
```

The remaining eight ports follow the identical pattern. Their constructors and `send` smart
constructors:

- `Shomei.Port.CredentialStore` — `CreatePasswordCredential :: UserId -> Email -> PasswordHash
  -> CredentialStore m Credential`; `FindPasswordCredentialByEmail :: Email -> CredentialStore m
  (Maybe Credential)`; `UpdatePasswordHash :: UserId -> PasswordHash -> CredentialStore m ()`.
- `Shomei.Port.SessionStore` — `CreateSession :: NewSession -> SessionStore m Session`;
  `FindSessionById :: SessionId -> SessionStore m (Maybe Session)`; `RevokeSession :: SessionId
  -> UTCTime -> SessionStore m ()`; `RevokeAllUserSessions :: UserId -> UTCTime -> SessionStore m
  ()`.
- `Shomei.Port.PasswordHasher` — `HashPassword :: PlainPassword -> PasswordHasher m
  PasswordHash`; `VerifyPassword :: PlainPassword -> PasswordHash -> PasswordHasher m Bool`.
- `Shomei.Port.TokenSigner` — `SignAccessToken :: AuthClaims -> TokenSigner m AccessToken`.
- `Shomei.Port.TokenVerifier` — `VerifyAccessToken :: AccessToken -> TokenVerifier m (Either
  TokenError AuthClaims)`.
- `Shomei.Port.AuthEventPublisher` — `PublishAuthEvent :: AuthEvent -> AuthEventPublisher m ()`.
- `Shomei.Port.SigningKeyStore` — `ListActiveSigningKeys :: SigningKeyStore m [StoredSigningKey]`;
  `FindSigningKeyByKid :: Text -> SigningKeyStore m (Maybe StoredSigningKey)`; `InsertSigningKey
  :: StoredSigningKey -> SigningKeyStore m ()`; `UpdateSigningKeyStatus :: Text ->
  SigningKeyStatus -> UTCTime -> SigningKeyStore m ()`.
- `Shomei.Port.Clock` — `Now :: Clock m UTCTime`; smart constructor `now :: (Clock :> es) => Eff
  es UTCTime`.

### In-memory interpreters — `Shomei.Port.InMemory`

A single mutable `World` holds every store's state plus the published-event log. The module
exposes `emptyWorld`, the per-port handlers, and a `runInMemory` convenience that stacks all the
port interpreters over `IOE` against a shared `IORef World`. The interpreters use `interpret_`
(first-order, no `LocalEnv`) and read/modify the `IORef`. Sketch:

```haskell
data World = World
  { users          :: !(Map UserId User)
  , credsByEmail   :: !(Map Email Credential)
  , sessions       :: !(Map SessionId Session)
  , refreshTokens  :: !(Map RefreshTokenId PersistedRefreshToken)
  , refreshByHash  :: !(Map RefreshTokenHash RefreshTokenId)
  , signingKeys    :: !(Map Text StoredSigningKey)
  , publishedEvents:: ![AuthEvent]            -- newest-first
  , clock          :: !UTCTime                -- fixed/advanceable test time
  , tokenCounter   :: !Int                    -- deterministic opaque tokens
  }

emptyWorld :: UTCTime -> World

runUserStore :: (IOE :> es) => IORef World -> Eff (UserStore : es) a -> Eff es a
runUserStore ref = interpret_ \case
  CreateUser nu -> liftIO do
    uid <- genUserId
    -- build User from nu, insert into users map, return it
    ...
  FindUserByEmail e -> liftIO (lookupUserByEmail e <$> readIORef ref)
  ...

-- Stacks every port interpreter; TokenSigner/TokenVerifier are deterministic fakes here
-- (sign = AccessToken (claims rendered to Text); verify round-trips that Text back to claims).
runInMemory :: IORef World -> Eff '[ UserStore, CredentialStore, SessionStore
                                   , RefreshTokenStore, PasswordHasher, TokenSigner
                                   , TokenVerifier, AuthEventPublisher, SigningKeyStore
                                   , Clock, TokenGen, IOE ] a
            -> IO a
runInMemory ref = runEff
  . runTokenGen ref . runClock ref . runSigningKeyStore ref
  . runAuthEventPublisher ref . runTokenVerifier . runTokenSigner
  . runPasswordHasher ref . runRefreshTokenStore ref . runSessionStore ref
  . runCredentialStore ref . runUserStore ref
```

Interpreter behaviors that matter for the tests: `PasswordHasher` hashes by tagging the plain
text (`PasswordHash ("argon2-fake:" <> pw)`) and verifies by equality (fails closed on
mismatch); `TokenGen` returns `RefreshToken ("rt-" <> show counter)` incrementing the counter
(so successive tokens differ) and hashes with a stable prefix; `RevokeRefreshTokenFamily` walks
`parentTokenId`/child links from the given id and sets every member to `RefreshTokenRevoked`;
`MarkRefreshTokenUsed` sets `status = RefreshTokenUsed` and `usedAt`; `Clock`'s `Now` returns
`world.clock`; `AuthEventPublisher` conses onto `publishedEvents`.

Effectful API referenced: `interpret_ :: EffectHandler_ e es -> Eff (e : es) a -> Eff es a`
(first-order handler), `send`, `runEff`, `IOE`. (If a workflow ever needs to short-circuit with
an error inside an interpreter, `Effectful.Error.Static`'s `runErrorNoCallStack`/`throwError`
are available, and `Effectful.State.Static.Local`'s `runState`/`get`/`put`/`modify` are an
alternative to the `IORef` if a pure-`State` stack is preferred — both ship with `effectful`.)

### Auth workflows — `Shomei.Workflow`

The exported signatures (the contract EP-5 drives):

```haskell
signup :: ( UserStore :> es, CredentialStore :> es, SessionStore :> es
          , RefreshTokenStore :> es, PasswordHasher :> es, TokenSigner :> es
          , AuthEventPublisher :> es, Clock :> es, TokenGen :> es )
       => ShomeiConfig -> SignupCommand -> Eff es (Either AuthError (User, TokenPair))

login :: ( UserStore :> es, CredentialStore :> es, SessionStore :> es
         , RefreshTokenStore :> es, PasswordHasher :> es, TokenSigner :> es
         , AuthEventPublisher :> es, Clock :> es, TokenGen :> es )
      => ShomeiConfig -> LoginCommand -> Eff es (Either AuthError (User, TokenPair))

refresh :: ( SessionStore :> es, RefreshTokenStore :> es, TokenSigner :> es
           , AuthEventPublisher :> es, Clock :> es, TokenGen :> es )
        => ShomeiConfig -> RefreshCommand -> Eff es (Either AuthError TokenPair)

logout :: ( SessionStore :> es, RefreshTokenStore :> es, AuthEventPublisher :> es
          , Clock :> es )
       => ShomeiConfig -> LogoutCommand -> Eff es (Either AuthError ())

verifyToken :: (TokenVerifier :> es, SessionStore :> es)
            => ShomeiConfig -> AccessToken -> Eff es (Either AuthError AuthClaims)
```

The full `signup` implementation:

```haskell
signup cfg cmd = runExceptT do
  email <- liftEither (mkEmail (emailText cmd.email))             -- normalize + validate shape
  case validatePassword cfg.passwordPolicy cmd.password of        -- password policy
    Left v  -> throwE (WeakPassword v)
    Right () -> pure ()
  existing <- lift (findUserByEmail email)                        -- uniqueness
  case existing of Just _ -> throwE EmailAlreadyRegistered; Nothing -> pure ()
  pwHash <- lift (hashPassword cmd.password)
  user   <- lift (createUser (NewUser { email = email, displayName = cmd.displayName }))
  _cred  <- lift (createPasswordCredential user.userId email pwHash)
  ts     <- lift now
  session <- lift (createSession (NewSession
              { userId = user.userId, createdAt = ts
              , expiresAt = addUTCTime cfg.sessionTTL ts }))
  rawToken <- lift generateOpaqueToken
  tokHash  <- lift (hashRefreshToken rawToken)
  _persist <- lift (createRefreshToken (NewRefreshToken
              { sessionId = session.sessionId, tokenHash = tokHash
              , parentTokenId = Nothing, createdAt = ts
              , expiresAt = addUTCTime cfg.refreshTokenTTL ts }))
  let claims = buildClaims cfg user.userId session.sessionId ts
  access <- lift (signAccessToken claims)
  lift (publishAuthEvent (UserRegistered (mkUserRegistered user ts)))
  lift (publishAuthEvent (SessionStarted (mkSessionStarted session ts)))
  pure (user, TokenPair { accessToken = access, refreshToken = rawToken
                        , expiresIn = cfg.accessTokenTTL })
  where
    runExceptT = ...  -- standard Either plumbing over Eff; see note below
```

The full `refresh` implementation (the security-critical rotation + reuse detection):

```haskell
refresh cfg cmd = do
  ts      <- now
  tokHash <- hashRefreshToken cmd.refreshToken
  mTok    <- findRefreshTokenByHash tokHash
  case mTok of
    Nothing  -> pure (Left RefreshTokenInvalid)
    Just tok -> case tok.status of
      -- REUSE DETECTED: an already-used (or revoked) token presented again => theft.
      RefreshTokenUsed    -> reuseDetected tok ts
      RefreshTokenRevoked -> reuseDetected tok ts
      RefreshTokenExpired -> pure (Left RefreshTokenExpired)
      RefreshTokenActive
        | tok.expiresAt <= ts -> pure (Left RefreshTokenExpired)
        | otherwise -> do
            mSession <- findSessionById tok.sessionId
            case mSession of
              Nothing -> pure (Left SessionNotFound)
              Just s | s.status /= SessionActive -> pure (Left SessionRevoked)
                     | otherwise -> do
                  markRefreshTokenUsed tok.refreshTokenId ts          -- old -> Used
                  rawNew  <- generateOpaqueToken                      -- rotate
                  newHash <- hashRefreshToken rawNew
                  _ <- createRefreshToken (NewRefreshToken
                         { sessionId = tok.sessionId, tokenHash = newHash
                         , parentTokenId = Just tok.refreshTokenId    -- family link
                         , createdAt = ts
                         , expiresAt = addUTCTime cfg.refreshTokenTTL ts })
                  let claims = buildClaims cfg s.userId s.sessionId ts
                  access <- signAccessToken claims
                  publishAuthEvent (RefreshTokenRotated (mkRotated tok ts))
                  pure (Right (TokenPair { accessToken = access, refreshToken = rawNew
                                         , expiresIn = cfg.accessTokenTTL }))
  where
    reuseDetected tok ts = do
      revokeRefreshTokenFamily tok.refreshTokenId ts                  -- kill the family
      revokeSession tok.sessionId ts                                  -- kill the session
      publishAuthEvent (RefreshTokenReuseDetected (mkReuse tok ts))
      pure (Left RefreshTokenReuseDetected)
```

`login` mirrors `signup`'s second half but starts by `findPasswordCredentialByEmail`; a missing
credential returns `Left InvalidCredentials` **without** any verify call; on a found credential
it loads the user, checks `status == UserActive` (else `UserNotActive`), `verifyPassword` (on
`False`, publish `LoginFailed` and return `Left InvalidCredentials`), then creates session +
refresh token + access token and publishes `LoginSucceeded` + `SessionStarted`. `logout`
revokes the session, revokes the session's refresh tokens, publishes `SessionRevoked`, and
returns `Right ()`. `verifyToken` calls `verifyAccessToken`; on `Left te` returns `Left
(TokenInvalid te)`; on `Right claims`, when `cfg.sessionCheckMode == VerifyTokenAndSession` it
additionally loads the session and rejects a non-active one, else returns `Right claims`.

Note on the `Either`-over-`Eff` plumbing: `signup`/`login` use an explicit short-circuit. The
simplest in-core approach (no extra deps) is a small local helper that threads `Either AuthError`
through a `do` block — implemented either with `Effectful.Error.Static`
(`runErrorNoCallStack @AuthError` around a body that `throwError`s) or with manual `case`
chaining as shown for `refresh`. The implementer picks one and uses it consistently; both
satisfy the signatures above. `buildClaims cfg uid sid ts` constructs `AuthClaims` with
`issuer`/`audience` from `cfg`, `issuedAt = ts`, `expiresAt = addUTCTime cfg.accessTokenTTL ts`,
and empty `scopes`/`roles` for the MVP.

### Test suite — `test/Main.hs` + `test/Shomei/WorkflowSpec.hs`

`Main.hs` is the tasty entry point:

```haskell
module Main (main) where
import Test.Tasty (defaultMain, testGroup)
import qualified Shomei.WorkflowSpec
main :: IO ()
main = defaultMain (testGroup "shomei-core-test" [Shomei.WorkflowSpec.tests])
```

`Shomei.WorkflowSpec` exposes `tests :: TestTree` with the seven cases from "Validation and
Acceptance". Each case builds a fresh `IORef World` via `emptyWorld someFixedTime`, runs the
relevant workflow(s) through `runInMemory`, and asserts on the returned `Either` and (for the
state-changing cases) on the post-run `World` read back from the `IORef`. No PostgreSQL, no
JWT, no network.

### Commit trailers

Commits for this plan use these trailers:

```text
MasterPlan: docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md
ExecPlan: docs/plans/2-core-domain-model-ports-and-auth-workflows.md
Intention: intention_01kt7xgv3pes2v675nr1pmzf6j
```
