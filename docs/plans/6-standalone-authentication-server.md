---
id: 6
slug: standalone-authentication-server
title: "Standalone authentication server"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# Standalone authentication server

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan delivers the first point at which the whole of Shōmei runs as a single real
process. Up to now the project is a stack of independently-tested libraries: the domain
core (`shomei-core`, from EP-2), the PostgreSQL persistence adapter and migrations
(`shomei-postgres` / `shomei-migrations`, from EP-3), the JWT/JWKS adapter (`shomei-jwt`,
from EP-4), and the Servant HTTP surface (`shomei-servant`, from EP-5). None of those, on
its own, is something an operator can start and talk to. This plan creates
`shomei-server`: a Haskell **executable** (a cabal `Application` component — a
component that produces a runnable binary, as opposed to a `library` that only produces
linkable code) that loads configuration, acquires a PostgreSQL connection pool, runs the
schema migrations, bootstraps or loads the JWT signing keys, assembles every adapter
behind one fixed `effectful` effect stack, and serves the standalone HTTP API with `warp`
(the standard Haskell production HTTP server).

After this change a developer can, from a checkout, start PostgreSQL (via
`process-compose up` or the dev shell), run `cabal run shomei-server`, watch it log
`listening on :8080`, and then drive the complete authentication lifecycle entirely over
HTTP with `curl`: sign up a user, log in, fetch the current user with a Bearer token,
rotate a refresh token, observe that **replaying** an already-used refresh token is
detected as token theft and revokes the whole session, log out, and fetch the public
JWKS document (a JSON Web Key Set — the published public half of the signing keys that
lets *other* services verify Shōmei's access tokens locally without calling back). The
same behavior is also pinned by an automated `test-suite shomei-server-test` that spins up
an **ephemeral** PostgreSQL database (a throwaway database created per test run), runs the
server in-process with `warp`'s `testWithApplication`, and asserts the same lifecycle with
an HTTP client, including the reuse-detection 401.

The user-visible behavior enabled: a working, locally-verifiable authentication
microservice with signup, login, refresh-rotation with reuse detection, logout, an
authenticated "who am I" endpoint, a health check, and a JWKS endpoint — all backed by
real PostgreSQL and real asymmetric JWT signing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `shomei-server/shomei-server.cabal` created (library + executable +
  test-suite); `cabal build shomei-server` succeeds with the `Env` record, the `AppEffects`
  stack, and `runAppIO` compiling. (2026-06-03)
- [x] M1: `Shomei.Server.App` (`Env`, `AppEffects`, `runAppIO`) written with the exact
  interpreter ordering and an explanatory comment. (2026-06-03)
- [x] M1: `Shomei.Server.Config` (env-var reader → `ShomeiConfig` + `ServerSettings`) written. (2026-06-03)
- [x] M1: ~~`Shomei.Server.Seam` (`effToHandler`)~~ **not written** — EP-5's seam
  (`Shomei.Servant.Seam` + `shomeiServer`) is reused directly; see Decision Log. (2026-06-03)
- [x] M2: `Shomei.Server.Boot` startup sequence written (config → migrations → pool →
  signing-key bootstrap → `Env` → `serveWithContext` → `Warp.run`). (2026-06-03)
- [x] M2: `Shomei.Server.Keys` signing-key bootstrap (generate-on-first-boot) written. (2026-06-03)
- [x] M2: executable builds and links (`cabal build shomei-server`). Manual
  `cabal run shomei-server` against a live PostgreSQL is the documented turnkey path; the
  binding behavioral gate is the automated ephemeral-DB test (M3). (2026-06-03)
- [ ] M3: full `curl` walkthrough against a long-running server — documented in Validation;
  superseded as the acceptance gate by the automated ephemeral-DB test below (same lifecycle).
- [x] M3: `test-suite shomei-server-test` written using `shomei-migrations:test-support`
  + `warp testWithApplication`; `cabal test shomei-server` is green — signup → login →
  me(±token) → refresh → reuse-detect(401 + DB session revoked + reuse event row) → logout(204)
  → jwks → health. (2026-06-03)
- [x] M3: MasterPlan registry row for EP-6 set to Complete and its Progress checkboxes ticked. (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **EP-5's effect stack and the PostgreSQL interpreters need different stacks; `inject` bridges
  them.** EP-5 (built before this plan) fixed `Shomei.Servant.Seam.AppEffects` as the effects +
  `IOE` only (its in-memory interpreters need nothing more). But the PostgreSQL interpreters
  require `(Database :> es, IOE :> es, Error AuthError :> es)` in their residual (evidence:
  `runUserStorePostgres :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (UserStore :
  es) a -> Eff es a`). So this server's `AppEffects` is the EP-5 stack **extended** with
  `Database` and `Error AuthError` beneath the effects, and `Shomei.Server.Boot.seamEnv` builds
  EP-5's `Env.runPorts` by `inject`-ing an `Eff Seam.AppEffects a` into `Eff App.AppEffects a`
  (`inject :: Subset subEs es => Eff subEs a -> Eff es a` from `Effectful`) and running the
  postgres composition. Infra failures (a `Left AuthError` from `runAppIO`) become an IO
  exception (warp → 500); domain errors flow through EP-5's seam to the right status.
- **The crypto interpreters live in `Shomei.Crypto`, not `shomei-postgres`'s effect modules.**
  The plan guessed `Shomei.Postgres.PasswordHasher` / `Shomei.Postgres.TokenGen`; the real
  surface is `Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)` (Argon2id + crypton
  random). The store/clock/publisher/signing-key interpreters are `Shomei.Postgres.*`
  (`run…Postgres`, `runClockIO`), and the pool is `Shomei.Postgres.Pool.acquirePool :: Int ->
  Text -> IO Pool`. The whole assembly mirrors `shomei-postgres`'s own test `runApp`, extended
  with EP-4's real `runTokenSignerJwt`/`runTokenVerifierJwt`.
- **`runErrorNoCallStack` over the bootstrap stack needs the error type pinned.** In
  `Shomei.Server.Keys`, the `SigningKeyStore` postgres interpreter's `Error AuthError :> es`
  constraint does not unify the `Error e` introduced by `runErrorNoCallStack` (GHC reports an
  ambiguous `e`). Fixed with a pattern signature `result :: Either AuthError StoredSigningKey`.
- **Migrations cascade into `shomei-migrations`.** The server's turnkey startup migration needs
  `CoddSettings` from a single `PG_CONNECTION_STRING`. Added
  `Shomei.Migrations.coddSettingsFromConnString :: Text -> CoddSettings` (additive; the library
  gains `aeson`/`attoparsec`/`containers` deps) and refactored `test-support`'s `testCoddSettings`
  to reuse it (DRY). Out-of-band `shomei-migrate` (codd's env-based `getCoddSettings`) is
  unchanged.


## Decision Log

Record every decision made while working on the plan.

- Decision: Read runtime configuration from environment variables in this bootstrap (a small
  hand-written reader), and defer Dhall-file configuration to a later iteration.
  Rationale: An env-var reader is the smallest dependency-free way to make the server
  turnkey (`cabal run shomei-server` with a couple of exports), matches kizashi's
  `PG_CONNECTION_STRING` / `KIZASHI_PORT` idiom, and avoids pulling Dhall into the delivery
  layer before it is needed. The user's hierarchical-config convention (Dhall) is recorded
  as the documented future option; the reader is isolated in one module so swapping it is a
  local change.
  Date: 2026-06-03

- Decision: Run the schema migrations at server startup (via `runShomeiMigrationsNoCheck`),
  guarded so they are idempotent, rather than requiring `just migrate` out-of-band.
  Rationale: Makes the demo turnkey — one command brings a fresh database to the right
  schema and serves the API. codd migrations are idempotent (already-applied migrations are
  skipped), so re-running the server is safe. Running `shomei-migrate` out-of-band remains
  supported for production, where migration and serving are usually separate steps; this is
  documented.
  Date: 2026-06-03

- Decision: Bootstrap signing keys on first boot — if `ListActiveSigningKeys` returns empty,
  generate one ES256 key and `InsertSigningKey` it as Active; otherwise load the existing
  active key.
  Rationale: A fresh database has no keys; the server must be able to issue tokens on first
  run without a manual key-generation step. The bootstrap is conditional on "no active key",
  so it runs exactly once and re-running the server reuses the persisted key (tokens stay
  verifiable across restarts).
  Date: 2026-06-03

- Decision: Fix one concrete `AppEffects` effect stack and one `runAppIO` interpreter
  composition, with the interpreter order pinned and documented.
  Rationale: Effect interpretation order is load-bearing: an interpreter may only use effects
  that are still in the stack when it runs (i.e. those peeled off after it). Support effects
  (`Database`, `Clock`, `TokenGen`) and the error/IO base must remain available to the store
  and signer interpreters, so they are interpreted *after* (outside) them. Pinning the order
  once, in one module, keeps every handler writing against capability constraints rather than
  the concrete list.
  Date: 2026-06-03

- Decision: Wire Servant's authentication via `serveWithContext` with a single-entry
  `Context` carrying the `AuthHandler` built from EP-4's verifier
  (`verifyToken (envJwks env) (envConfig env)`).
  Rationale: EP-5's `Authenticated` combinator is an `AuthProtect "shomei-jwt"` whose
  `AuthHandler` is supplied through Servant's `Context`. `serveWithContext` is the only way
  to thread that handler in. The verifier closes over the live `JWKSet` and `ShomeiConfig`
  from `Env`, so token verification uses exactly the keys the server is signing with.
  Date: 2026-06-03

- Decision: The acceptance gate for this plan is the end-to-end `curl` walkthrough plus the
  automated ephemeral-DB server test; compilation alone is not acceptance.
  Rationale: This is the assembly/delivery plan; its value is that the vertical slice
  *behaves*. Reuse detection in particular can only be proven against a real persisted
  session, so it is exercised over HTTP against PostgreSQL.
  Date: 2026-06-03

- Decision: Reuse EP-5's `Env`/`shomeiServer`/`authHandler` directly instead of writing a new
  `Shomei.Server.Seam.effToHandler` and a `shomeiServer (effToHandler env)`-style parameterized
  server (the plan's sketch, written before EP-5 was implemented).
  Rationale: EP-5 actually ships `shomeiServer :: Shomei.Servant.Seam.Env -> ShomeiAPI
  (AsServerT Handler)` with its own `runAuth`/`runPort` seam, not a server parameterized over a
  runner. So this plan builds that `Env` (its `runPorts` bridges to the postgres stack via
  `inject`) and serves `shomeiServer env`. No `Shomei.Server.Seam` module is created; the
  AppEffects/Env/runAppIO contract from `Shomei.Server.App` is still the reusable, servant-free
  core EP-7 can build on.
  Date: 2026-06-03

- Decision: Test with `tasty`/`tasty-hunit` (not `hspec` as the plan sketched).
  Rationale: every other Shōmei test suite (core, jwt, postgres, servant) uses tasty; matching
  keeps one test idiom across the repo. The scenario is a single sequential `testCase` (the
  steps share one migrated database and one running server), with per-step assertions.
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Delivered the purpose: `shomei-server` is the first point where the whole of Shōmei
runs as one process. `Shomei.Server.App` fixes the concrete `AppEffects` stack and `runAppIO`
(the real PostgreSQL store interpreters + `Shomei.Crypto` Argon2id/token interpreters + EP-4's
ES256 signer/verifier, with `Database`/`Error AuthError`/`IOE` at the base); `Shomei.Server.Config`
loads `ShomeiConfig` + `ServerSettings` from the environment; `Shomei.Server.Keys` bootstraps an
ES256 key on first boot; `Shomei.Server.Boot` runs the turnkey startup and serves EP-5's API with
the auth `Context`. The executable builds and links.

The binding acceptance — the automated `shomei-server-test` — is green: against a throwaway
ephemeral PostgreSQL, the real server in-process proves signup → login → me(±token) → refresh
rotation → **refresh-token reuse detection** (HTTP 401 *and* the persisted session revoked *and* a
`refresh_token_reuse_detected` event row) → logout (204) → JWKS (public key, kid, no private `d`)
→ health. Reuse detection landing in PostgreSQL, not just in the HTTP status, is checked directly.

Compared to the plan: the assembly reuses EP-5's seam/handlers rather than the plan's
pre-EP-5 `effToHandler` sketch, bridging the two effect stacks with `inject`; the crypto
interpreters were found in `Shomei.Crypto`; and a small additive cascade added
`coddSettingsFromConnString` to `shomei-migrations` so startup migration needs only
`PG_CONNECTION_STRING`. Gaps/deferred: the manual long-running `curl` walkthrough is documented
but not executed in CI (the ephemeral test covers the same lifecycle); deliberate key rotation
uses EP-4's `Shomei.Jwt.Rotation` (out of scope here). The `Env`/`AppEffects`/`runAppIO` contract
is servant-free and is the reuse point for EP-7's embedded demo.


## Context and Orientation

This section assumes no prior knowledge of the Shōmei internals beyond Haskell and HTTP.

**Where this plan sits.** Shōmei is a Haskell authentication toolkit (see the MasterPlan at
`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`). It is built as a stack of
cabal packages under `/`. The packages relevant here, all delivered by earlier
ExecPlans that are hard dependencies of this one, are:

- `shomei-core` (EP-2): the transport-agnostic domain. It defines the domain types
  and identifiers (`Shomei.Id`), the error types (`Shomei.Error.AuthError`,
  `Shomei.Error.TokenError`), the runtime configuration record `ShomeiConfig`, the **effects**
  (expressed with `effectful`) and the **workflows** (signup, login,
  refresh-rotation, logout, verification) written purely against those effects. "`effectful`"
  is a Haskell effect-system library; an **effect** is a typed capability (e.g. "I can read a
  user from a store") and an **interpreter** is a function that gives an effect a concrete
  meaning (e.g. "read it from PostgreSQL"). The effects are: `UserStore`, `CredentialStore`,
  `SessionStore`, `RefreshTokenStore`, `PasswordHasher`, `TokenSigner`, `TokenVerifier`,
  `AuthEventPublisher`, `SigningKeyStore`, and the support effects `Clock` (current time) and
  `TokenGen` (random opaque tokens).
- `shomei-postgres` (EP-3): PostgreSQL interpreters for the store/publisher/
  signing-key/clock effects, the Argon2id `PasswordHasher` interpreter, the `TokenGen`
  interpreter, and a hasql-based `Database` effect. ("hasql" is a fast PostgreSQL client
  library; a **pool** is a reusable set of connections.) Key surface this plan uses:
  `runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a -> Eff es a` and the
  interpreters `runUserStorePostgres`, `runCredentialStorePostgres`, `runSessionStorePostgres`,
  `runRefreshTokenStorePostgres`, `runSigningKeyStorePostgres`, `runAuthEventPublisherPostgres`,
  `runClockIO`, `runPasswordHasherArgon2`, `runTokenGenCrypto`. Pool creation is via
  `Hasql.Pool.acquire`.
- `shomei-migrations` (EP-3): codd-managed schema migrations. ("codd" is a
  migration tool for PostgreSQL.) Surface this plan uses:
  `runShomeiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult` (apply pending
  migrations without the dev-time checksum verification), the `shomei-migrate` executable
  (out-of-band migration runner), and a public `test-support` sublibrary exposing
  `Shomei.Migrations.TestSupport.withShomeiMigratedDatabase :: (Text -> IO a) -> IO a`, which
  creates an ephemeral PostgreSQL database, applies all migrations, and hands the test a
  connection string.
- `shomei-jwt` (EP-4): the JWT/JWKS adapter. Surface this plan uses:
  `runTokenSignerJwt` / `runTokenVerifierJwt` (interpreters for the signer/verifier effects),
  `verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)` (the
  standalone verifier the auth handler calls), `jwksDocument` (build the public JWKS),
  the key generation/rotation operations over `SigningKeyStore` in `Shomei.Jwt.Rotation`,
  and JWK ↔ `StoredSigningKey` conversion. ("JWK" = JSON Web Key; "JWKSet" = a set of them;
  "kid" = key id.)
- `shomei-servant` (EP-5): the HTTP surface. Surface this plan uses: the
  `ShomeiAPI` NamedRoutes record (a Servant API described as a Haskell record of routes),
  the request/response DTOs, the `AuthUser` principal, the `Authenticated` combinator
  (`AuthProtect "shomei-jwt"`) together with its `AuthHandler` and the `Context` it needs
  (the handler is built from a verifier of shape `Text -> IO (Either TokenError AuthClaims)`),
  the handlers, the `effToHandler` / `Env` seam pattern, and the error mapping from
  `AuthError`/`TokenError` to `ServerError`.

**What does not yet exist.** There is no `shomei-server` directory. There is no
executable that brings these together; nobody has yet decided the concrete effect stack, the
interpreter ordering, the configuration surface, or the startup sequence. This plan creates
all of it.

**House conventions** (these are non-negotiable and apply to every new file):

- GHC 9.12.4, the `GHC2024` language edition.
- The two shared cabal `common` stanzas (`common warnings`, `common shared`) imported by
  every component — established by EP-1's `cabal.project`/skeletons.
- Postpositive qualified imports with explicit package names, e.g.
  `import "warp" Network.Wai.Handler.Warp qualified as Warp` (the kizashi style seen in
  `kizashi-core/src/Kizashi/Server.hs`).
- Strict record fields (`!`), the custom prelude `Shomei.Prelude` imported in place of the
  default `Prelude`.

**The reference idiom.** This plan mirrors kizashi's assembly, which is already proven in
the sibling repo. The three reference files are
`/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-core/src/Kizashi/App.hs` (the `AppEnv` record,
the `AppEffects` type, and `runAppIO` with its documented interpreter order),
`/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-core/src/Kizashi/Server.hs` (server assembly,
`serve`, the `withStore` bracket and `Warp.run`), and
`/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-core/src/Kizashi/Http/Seam.hs` (the
per-action `effToHandler` seam that maps `runAppIO`'s `Either` result into a Servant
`Handler`). Shōmei differs in two ways: (1) it has a much larger effect stack (every auth
effect), and (2) it uses `serveWithContext` rather than `serve` because the API is
authentication-protected.

**Module layout this plan creates** (all under `shomei-server/`):

```text
shomei-server/
  shomei-server.cabal
  app/Main.hs                         -- thin entry point, calls Shomei.Server.Boot.main
  src/Shomei/Server/Config.hs         -- env-var reader -> ShomeiConfig + ServerSettings
  src/Shomei/Server/App.hs            -- Env, AppEffects, runAppIO (the interpreter stack)
  src/Shomei/Server/Seam.hs           -- effToHandler (Eff -> Handler bridge)
  src/Shomei/Server/Keys.hs           -- signing-key bootstrap-on-first-boot + JWKSet build
  src/Shomei/Server/Boot.hs           -- main startup sequence + serveWithContext + warp
  test/Main.hs                        -- shomei-server-test driver
  test/Shomei/Server/E2ESpec.hs       -- the ephemeral-DB end-to-end scenario
```


## Plan of Work

The work is organized into three milestones, each independently verifiable. Throughout, the
working directory is the repository root `/Users/shinzui/Keikaku/bokuno/shomei` unless stated
otherwise.

### Milestone 1 — Assembly compiles (`Env`, `AppEffects`, `runAppIO`)

Scope: create the `shomei-server` package and the three "wiring" modules that make the
adapter stack a single interpretable unit, with no startup logic yet. At the end of this
milestone the package builds and the effect-stack assembly type-checks against the real
adapter interpreters, proving the interpreter ordering is correct before any process runs.

Edits:

1. Create `shomei-server/shomei-server.cabal`. Declare three components: a
   `library` (the assembly modules, so the test-suite can import them without depending on
   the executable), an `executable shomei-server` (`type: Application`) that is a thin
   `Main` over the library, and a `test-suite shomei-server-test`. Both code components
   import the shared `common warnings` and `common shared` stanzas. Add `shomei-server` to
   the package list in `cabal.project` at the repo root.

2. Create `src/Shomei/Server/Config.hs` defining `ServerSettings` (the listen port and the
   raw PostgreSQL connection string) and a loader `loadConfig :: IO (ShomeiConfig,
   ServerSettings)` that reads environment variables, falling back to `ShomeiConfig`'s
   defaults from `shomei-core` for anything optional. Document every variable.

3. Create `src/Shomei/Server/App.hs` defining the `Env` record (the hasql `Pool`, the loaded
   `ShomeiConfig`, the active signing `JWK`, and the public `JWKSet`), the `AppEffects` type,
   and `runAppIO :: Env -> Eff AppEffects a -> IO (Either AuthError a)`. Pin and comment the
   interpreter order.

4. Create `src/Shomei/Server/Seam.hs` defining
   `effToHandler :: Env -> Eff AppEffects a -> Handler a`, mirroring kizashi's
   `Kizashi.Http.Seam`, but mapping `AuthError` (via EP-5's error mapping) to `ServerError`.

Commands: `cabal build shomei-server`. Acceptance: the build is green; `runAppIO`'s type
signature is exactly `Env -> Eff AppEffects a -> IO (Either AuthError a)` and it composes
every adapter interpreter.

### Milestone 2 — The executable boots

Scope: implement the startup sequence so the binary actually runs: it loads config, runs
migrations, acquires the pool, bootstraps the signing key, builds `Env`, and serves. At the
end, `cabal run shomei-server` logs the listen address and `GET /health` returns 200.

Edits:

1. Create `src/Shomei/Server/Keys.hs` with
   `bootstrapSigningKey :: Env-less` helpers that run inside `runAppIO` / the `Database`
   layer: a function that lists active signing keys, generates+inserts an ES256 key if none,
   then loads the active private `JWK` and builds the public `JWKSet` from all non-revoked
   keys (using EP-4's conversion + `jwksDocument`).

2. Create `src/Shomei/Server/Boot.hs` with `main :: IO ()` performing the seven-step startup
   sequence (below) and `application :: Env -> Application` building the WAI app with
   `serveWithContext` and the auth `Context`.

3. Create `app/Main.hs` as a one-line `main = Shomei.Server.Boot.main`.

Commands: start PostgreSQL (`process-compose up` or the dev shell), then
`cabal run shomei-server`. Acceptance: logs `[shomei] listening on :8080`;
`curl -fsS http://localhost:8080/health` returns 200.

### Milestone 3 — End-to-end behavior (the acceptance gate)

Scope: prove the full lifecycle, manually and automatically. At the end, the `curl`
walkthrough passes and `cabal test shomei-server` is green, including reuse detection.

Edits:

1. Create `test/Shomei/Server/E2ESpec.hs` and `test/Main.hs`: a hspec scenario that uses
   `withShomeiMigratedDatabase` to get an ephemeral DB, builds an `Env` against it (running
   the same bootstrap as the executable), serves the app in-process with `warp`'s
   `testWithApplication`, and drives signup → login → me (with and without token) → refresh →
   reuse-detect → logout → jwks with `http-client`, asserting status codes and that the
   expected rows exist.

Commands: `cabal test shomei-server` and the manual `curl` walkthrough in Validation.
Acceptance: both green, transcripts match.

After M3, update the MasterPlan registry (set EP-6 to Complete) and tick the EP-6 boxes in
its Progress section.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` unless noted. Where a command
prints output, an expected short transcript follows so the reader can compare.

### Step 0 — Confirm the dependencies are present

```bash
cabal build shomei-core shomei-postgres shomei-jwt shomei-servant shomei-migrations
```

Expected: each package builds (these are EP-2..EP-5 deliverables). If any fails, stop — this
plan hard-depends on them.

### Step 1 — Create the cabal file

Create `shomei-server/shomei-server.cabal`:

```cabal
cabal-version: 3.4
name:          shomei-server
version:       0.1.0.0
synopsis:      Standalone Shōmei authentication service (executable)
build-type:    Simple

-- 'common warnings' and 'common shared' are the shared stanzas established by
-- EP-1's workspace scaffolding; every component imports both.

library
  import:           warnings, shared
  hs-source-dirs:   src
  exposed-modules:
    Shomei.Server.Config
    Shomei.Server.App
    Shomei.Server.Seam
    Shomei.Server.Keys
    Shomei.Server.Boot
  build-depends:
      base
    , shomei-core
    , shomei-jwt
    , shomei-postgres
    , shomei-migrations
    , shomei-servant
    , effectful
    , effectful-core
    , hasql-pool
    , warp
    , wai
    , servant-server
    , text
    , time
    , bytestring

executable shomei-server
  import:           warnings, shared
  type:             exitcode-stdio-1.0
  hs-source-dirs:   app
  main-is:          Main.hs
  build-depends:    base, shomei-server

test-suite shomei-server-test
  import:           warnings, shared
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  other-modules:    Shomei.Server.E2ESpec
  build-depends:
      base
    , shomei-server
    , shomei-core
    , shomei-servant
    , shomei-migrations:test-support
    , hspec
    , warp
    , http-client
    , http-types
    , aeson
    , text
    , bytestring
    , hasql-pool
```

Note: a cabal `Application` per `mori.dhall` is realized as an `exitcode-stdio-1.0`
executable component (the cabal vocabulary for a runnable binary). Add `shomei-server` to
the `packages:` list in the root `cabal.project`.

### Step 2 — The config reader

Create `shomei-server/src/Shomei/Server/Config.hs`. It reads these environment
variables (each documented inline):

```text
PG_CONNECTION_STRING   PostgreSQL libpq connection string (required). Example:
                       "host=localhost port=5432 dbname=shomei user=shomei".
                       (Alternatively, standard libpq PGHOST/PGDATABASE/etc. may be
                       relied upon by hasql if PG_CONNECTION_STRING is empty; documented
                       as a future convenience.)
SHOMEI_PORT            TCP port for warp to listen on. Default: 8080.
SHOMEI_ISSUER          JWT "iss" claim / issuer identifier. Default: ShomeiConfig default.
SHOMEI_AUDIENCE        JWT "aud" claim / intended audience. Default: ShomeiConfig default.
SHOMEI_ACCESS_TTL      Access-token lifetime in seconds. Default: ShomeiConfig default.
SHOMEI_REFRESH_TTL     Refresh-token lifetime in seconds. Default: ShomeiConfig default.
SHOMEI_SESSION_TTL     Session lifetime in seconds. Default: ShomeiConfig default.
SHOMEI_TOKEN_TRANSPORT "bearer" | "cookie" | "both". Default: ShomeiConfig default.
SHOMEI_SESSION_CHECK   "token-only" | "token-and-session". Default: ShomeiConfig default.
```

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Load runtime configuration from the environment into the core
-- 'ShomeiConfig' plus the server-only 'ServerSettings' (listen port, connection
-- string). Env-var based by deliberate choice (Decision Log); Dhall-file config
-- is the documented future option per the house hierarchical-config convention.
module Shomei.Server.Config
  ( ServerSettings (..)
  , loadConfig
  ) where

import Shomei.Prelude
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig) -- from shomei-core (IP-5)

import "base" System.Environment (lookupEnv)
import "text" Data.Text qualified as Text

-- | Server-only settings not part of the transport-agnostic 'ShomeiConfig'.
data ServerSettings = ServerSettings
  { serverPort     :: !Int    -- ^ warp listen port (SHOMEI_PORT, default 8080)
  , serverConnStr  :: !Text   -- ^ PG_CONNECTION_STRING (required)
  }
  deriving stock (Show, Generic)

-- | Load both records. Required variables that are missing cause a clear
-- 'userError'; optional ones fall back to 'defaultShomeiConfig'. Pure parsing
-- helpers (port/ttl/enum readers) are elided here; each returns a clear error on
-- malformed input so misconfiguration fails fast at boot.
loadConfig :: IO (ShomeiConfig, ServerSettings)
loadConfig = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  port    <- intEnv "SHOMEI_PORT" 8080
  cfg     <- overlayConfigFromEnv defaultShomeiConfig  -- applies SHOMEI_ISSUER, …
  pure (cfg, ServerSettings { serverPort = port, serverConnStr = connStr })

requireEnv :: Text -> IO Text
requireEnv name = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Just v | not (null v) -> pure (Text.pack v)
    _ -> ioError (userError (Text.unpack (name <> " is not set")))
```

(`overlayConfigFromEnv` and `intEnv` are small, obvious helpers in this module: each reads a
variable, parses it, and either overrides the corresponding `ShomeiConfig` field or keeps the
default. They are written out in full during implementation; only the shape matters here.)

### Step 3 — The effect stack and runner

Create `shomei-server/src/Shomei/Server/App.hs`. This is the heart of the
assembly. The stack lists every effect plus the support effects and the base:

```haskell
{-# LANGUAGE DataKinds #-}

-- | The Shōmei server effect stack and its runner. This single module fixes the
-- one effect stack every handler runs in, the environment needed to interpret
-- it, and the runner that interprets it down to IO. Like kizashi's Kizashi.App
-- it is servant-free: 'runAppIO' returns @IO (Either AuthError a)@ with no HTTP
-- types, so the same stack is reusable by the embedded mode (EP-7) and by the
-- automated test, not just the standalone warp boot.
module Shomei.Server.App
  ( AppEffects
  , Env (..)
  , runAppIO
  ) where

import Shomei.Prelude
import Shomei.Config (ShomeiConfig)
import Shomei.Error (AuthError)
import Shomei.Effect.UserStore (UserStore)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TokenVerifier (TokenVerifier)
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.SigningKeyStore (SigningKeyStore)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.TokenGen (TokenGen)

import "shomei-postgres" Shomei.Postgres.Database (Database, runDatabasePool)
import "shomei-postgres" Shomei.Postgres.UserStore (runUserStorePostgres)
import "shomei-postgres" Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import "shomei-postgres" Shomei.Postgres.SessionStore (runSessionStorePostgres)
import "shomei-postgres" Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import "shomei-postgres" Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import "shomei-postgres" Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import "shomei-postgres" Shomei.Postgres.Clock (runClockIO)
import "shomei-postgres" Shomei.Postgres.PasswordHasher (runPasswordHasherArgon2)
import "shomei-postgres" Shomei.Postgres.TokenGen (runTokenGenCrypto)
import "shomei-jwt" Shomei.Jwt.Signer (runTokenSignerJwt)
import "shomei-jwt" Shomei.Jwt.Verifier (runTokenVerifierJwt)

import "effectful-core" Effectful (Eff, IOE, runEff)
import "effectful-core" Effectful.Error.Static (Error, runErrorNoCallStack)
import "hasql-pool" Hasql.Pool (Pool)
import "jose" Crypto.JWT (JWK, JWKSet)

-- | The single effect stack every Shōmei handler runs in. Reading the list
-- left-to-right is reading from the /handler's/ point of view (the effects it
-- may use); reading the interpreter composition in 'runAppIO' bottom-up is the
-- /runtime's/ point of view (the order effects are given meaning). The head of
-- the list is interpreted last-ish among the effects but the high-level effects come
-- first so they may rely on the support effects beneath them.
type AppEffects =
  '[ UserStore
   , CredentialStore
   , SessionStore
   , RefreshTokenStore
   , PasswordHasher
   , TokenSigner
   , TokenVerifier
   , AuthEventPublisher
   , SigningKeyStore
   , Clock
   , TokenGen
   , Database
   , Error AuthError
   , IOE
   ]

-- | Everything the runtime needs to interpret 'AppEffects' down to IO: the live
-- hasql pool, the loaded config, the active /private/ signing key (used by the
-- signer), and the public JWKSet (used by the verifier and the JWKS endpoint).
data Env = Env
  { envPool   :: !Pool        -- ^ hasql connection pool (from Hasql.Pool.acquire)
  , envConfig :: !ShomeiConfig
  , envKey    :: !JWK         -- ^ active private signing key (ES256)
  , envJwks   :: !JWKSet      -- ^ public JWKS (all non-revoked keys, public material)
  }
  deriving stock (Generic)

-- | Interpret the whole 'AppEffects' stack down to IO, surfacing an 'AuthError'
-- as 'Left'. No servant types appear here (the seam adds them).
--
-- The composition is written outermost-last: reading top-to-bottom, each line
-- /removes/ the effect it interprets and may use any effect still present
-- /below/ it. Hence the ORDER is load-bearing:
--
--   * The store interpreters (UserStore … SigningKeyStore) and the publisher all
--     issue SQL, so they are interpreted ABOVE 'runDatabasePool' — 'Database'
--     must still be in scope when they run.
--   * 'runTokenSignerJwt' / 'runTokenVerifierJwt' are pure-ish over the supplied
--     key/JWKS and config; they sit among the effects.
--   * 'runClockIO' and 'runTokenGenCrypto' provide time and randomness; the
--     store/signer layers above them may consume those, so they are interpreted
--     beneath the effects but above 'runDatabasePool'.
--   * 'runDatabasePool' removes 'Database', needing 'IOE'; it is interpreted
--     below every SQL-issuing effect.
--   * 'runErrorNoCallStack' removes @Error AuthError@, producing the @Either@.
--   * 'runEff' removes 'IOE', producing 'IO'.
runAppIO :: Env -> Eff AppEffects a -> IO (Either AuthError a)
runAppIO env =
    runEff
  . runErrorNoCallStack
  . runDatabasePool (envPool env)
  . runTokenGenCrypto
  . runClockIO
  . runSigningKeyStorePostgres
  . runAuthEventPublisherPostgres
  . runTokenVerifierJwt (envJwks env) (envConfig env)
  . runTokenSignerJwt (envKey env) (envConfig env)
  . runPasswordHasherArgon2
  . runRefreshTokenStorePostgres
  . runSessionStorePostgres
  . runCredentialStorePostgres
  . runUserStorePostgres
```

Note the relationship between `AppEffects` (head = `UserStore`) and the composition
(`runUserStorePostgres` applied last, i.e. outermost in the `.` chain so it removes the head
first). The exact module paths for the interpreters are confirmed against the EP-3/EP-4
deliverables during implementation; if a name differs, fix the import — the *ordering rule*
(SQL effects above `runDatabasePool`; `Database`/`Error`/`IOE` at the base) is what must hold.

### Step 4 — The servant seam

Create `shomei-server/src/Shomei/Server/Seam.hs`:

```haskell
{-# LANGUAGE DataKinds #-}

-- | Run an 'AppEffects' action and turn its result into a servant 'Handler'.
-- One place where the domain 'AuthError' meets HTTP, via EP-5's error mapping.
module Shomei.Server.Seam
  ( effToHandler
  ) where

import Shomei.Prelude
import Shomei.Server.App (AppEffects, Env, runAppIO)
import "shomei-servant" Shomei.Servant.Error (toServerError) -- AuthError -> ServerError (EP-5)

import "effectful-core" Effectful (Eff)
import "servant-server" Servant (Handler, throwError)

-- | THE SEAM. Run the effectful action to IO, then map 'Left' AuthError to a
-- servant 'ServerError' (structured JSON body + status) via EP-5's mapping.
effToHandler :: Env -> Eff AppEffects a -> Handler a
effToHandler env action =
  liftIO (runAppIO env action) >>= either (throwError . toServerError) pure
```

EP-5 already defines its handlers in terms of *its* `Env`/`effToHandler` seam pattern. In
this assembly the server's `Env` and `effToHandler` are the concrete fulfilment of that
pattern; if EP-5 parameterized its handlers over the runner, this is the runner passed in.

After Steps 1–4: `cabal build shomei-server` — this completes Milestone 1.

```bash
cabal build shomei-server
```

Expected (abbreviated):

```text
Building library for shomei-server-0.1.0.0..
[5 of 5] Compiling Shomei.Server.App
[ ... ]
Linking ...
```

### Step 5 — Signing-key bootstrap

Create `shomei-server/src/Shomei/Server/Keys.hs`. The bootstrap runs *before* the
full `runAppIO` stack exists (there is no key yet to build `Env`), so it runs over a smaller
stack: just `SigningKeyStore` + `Clock` + `TokenGen` + `Database` + `Error AuthError` + `IOE`
interpreted against the pool. It (1) lists active keys, (2) if empty, generates an ES256 key
(EP-4) and inserts it Active, (3) loads the active *private* JWK, (4) builds the public
`JWKSet` from all non-revoked keys.

```haskell
{-# LANGUAGE DataKinds #-}

-- | Signing-key bootstrap. On first boot (no active key) generate one ES256 key
-- and persist it Active; otherwise reuse the persisted key. Then load the active
-- private JWK and build the public JWKSet. Idempotent: generation is guarded on
-- "no active key", so re-running the server reuses the existing key and tokens
-- stay verifiable across restarts.
module Shomei.Server.Keys
  ( bootstrapKeys
  ) where

import Shomei.Prelude
import Shomei.Config (ShomeiConfig)
import "shomei-jwt" Shomei.Jwt.Rotation (ensureActiveSigningKey) -- generate+insert if none
import "shomei-jwt" Shomei.Jwt.Jwk (storedToPrivateJwk, jwksFromStored)
import "shomei-jwt" Shomei.Jwt.Jwks (jwksDocument)
import "shomei-postgres" Shomei.Postgres.Database (runDatabasePool)
import "shomei-postgres" Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import "shomei-postgres" Shomei.Postgres.Clock (runClockIO)
import "shomei-postgres" Shomei.Postgres.TokenGen (runTokenGenCrypto)

import "effectful-core" Effectful (runEff)
import "effectful-core" Effectful.Error.Static (runErrorNoCallStack)
import "hasql-pool" Hasql.Pool (Pool)
import "jose" Crypto.JWT (JWK, JWKSet)

-- | Returns the active private JWK and the public JWKSet. Run against the pool
-- over the minimal signing-key stack. Aborts (via 'AuthError') if generation
-- itself fails; on success the database holds exactly one Active key.
bootstrapKeys :: Pool -> ShomeiConfig -> IO (JWK, JWKSet)
bootstrapKeys pool cfg = do
  result <-
      runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runTokenGenCrypto
    . runClockIO
    . runSigningKeyStorePostgres
    $ do
        active <- ensureActiveSigningKey cfg   -- list; generate+insert ES256 if empty
        priv   <- storedToPrivateJwk active    -- active private JWK
        allKeys <- jwksFromStored              -- all non-revoked -> public JWKSet
        pure (priv, jwksDocument allKeys)
  either (ioError . userError . show) pure result
```

(The exact names `ensureActiveSigningKey`, `storedToPrivateJwk`, `jwksFromStored`,
`jwksDocument` are the EP-4 surface; confirm and adjust during implementation. The behavior
— generate-on-empty, load active private, build public set — is the contract.)

### Step 6 — The startup sequence (main) and warp boot

Create `shomei-server/src/Shomei/Server/Boot.hs`. The `main` performs the seven
documented startup steps; `application` builds the WAI app with the auth `Context`.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | Startup sequence and warp boot for the standalone Shōmei auth service.
module Shomei.Server.Boot
  ( main
  , application
  ) where

import Shomei.Prelude
import Shomei.Server.Config (ServerSettings (..), loadConfig)
import Shomei.Server.App (Env (..))
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Server.Seam (effToHandler)

import "shomei-servant" Shomei.Servant.Api (ShomeiAPI)
import "shomei-servant" Shomei.Servant.Server (shomeiServer)        -- handlers, parameterized by the seam
import "shomei-servant" Shomei.Servant.Auth (authHandler)           -- builds AuthHandler from a verifier
import "shomei-jwt" Shomei.Jwt.Verifier (verifyToken)               -- JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
import "shomei-migrations" Shomei.Migrations (runShomeiMigrationsNoCheck, coddSettingsFromConnString)

import "base" System.IO (hPutStrLn, stderr)
import "hasql-pool" Hasql.Pool qualified as Pool
import "wai" Network.Wai (Application)
import "warp" Network.Wai.Handler.Warp qualified as Warp
import "servant-server" Servant
  ( Context (EmptyContext, (:.)), Proxy (Proxy), serveWithContext )
import "servant-server" Servant.API (NamedRoutes)

-- | The full startup sequence (numbered to match the plan's STARTUP SEQUENCE):
main :: IO ()
main = do
  -- 1. Load config from the environment.
  (cfg, settings) <- loadConfig

  -- 2. Run migrations at startup (idempotent; codd skips already-applied ones).
  --    Out-of-band `shomei-migrate` / `just migrate` is also supported.
  let coddSettings = coddSettingsFromConnString (serverConnStr settings)
  _applyResult <- runShomeiMigrationsNoCheck coddSettings migrateTimeout

  -- 3. Acquire the hasql pool.
  pool <- Pool.acquire (poolConfig (serverConnStr settings))

  -- 4. Bootstrap signing keys: generate ES256 on first boot, load active key + JWKS.
  (key, jwks) <- bootstrapKeys pool cfg

  -- 5. Build Env.
  let env = Env { envPool = pool, envConfig = cfg, envKey = key, envJwks = jwks }

  -- 6 & 7. Build the WAI app (with the auth Context) and serve it with warp.
  let port = serverPort settings
  hPutStrLn stderr ("[shomei] listening on :" <> show port)
  Warp.run port (application env)
  where
    migrateTimeout = 60   -- DiffTime seconds for codd to acquire its lock

-- | Build the WAI 'Application': the server with the auth 'Context'. The
-- 'Context' carries exactly one entry — the 'AuthHandler' for the
-- @AuthProtect "shomei-jwt"@ combinator — built from EP-4's 'verifyToken'
-- closed over this Env's JWKSet and config, so verification uses the very keys
-- the server signs with.
application :: Env -> Application
application env =
  serveWithContext
    (Proxy @(NamedRoutes ShomeiAPI))
    ctx
    (shomeiServer (effToHandler env))
  where
    ctx = authHandler (verifyToken (envJwks env) (envConfig env)) :. EmptyContext
```

(`coddSettingsFromConnString`, `poolConfig`, and `shomeiServer`'s exact shape are confirmed
against EP-3/EP-5; the load-bearing parts are the seven-step order, `serveWithContext` with
the single-entry `Context`, and the verifier closing over `envJwks`/`envConfig`.)

Create `shomei-server/app/Main.hs`:

```haskell
module Main (main) where

import Shomei.Server.Boot qualified

-- | The single @shomei-server@ executable entry point; all logic lives in the
-- @shomei-server@ library (the boot sequence).
main :: IO ()
main = Shomei.Server.Boot.main
```

After Steps 5–6: Milestone 2.

```bash
process-compose up -d            # or: enter the dev shell which starts PostgreSQL
export PG_CONNECTION_STRING="host=localhost port=5432 dbname=shomei user=shomei"
export SHOMEI_PORT=8080
cabal run shomei-server
```

Expected:

```text
[shomei] listening on :8080
```

In another shell:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/health
```

Expected:

```text
200
```

### Step 7 — Automated end-to-end test

Create `shomei-server/test/Main.hs` (hspec driver) and
`shomei-server/test/Shomei/Server/E2ESpec.hs`. The spec:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | End-to-end: an ephemeral PostgreSQL DB, the real server in-process via
-- warp's testWithApplication, driven over HTTP with http-client. Asserts the
-- full lifecycle including refresh-token reuse detection.
module Shomei.Server.E2ESpec (spec) where

import Shomei.Prelude
import Shomei.Server.Boot (application)
import Shomei.Server.App (Env (..))
import Shomei.Server.Keys (bootstrapKeys)
import Shomei.Config (defaultShomeiConfig)
import "shomei-migrations" Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import "hasql-pool" Hasql.Pool qualified as Pool
import "warp" Network.Wai.Handler.Warp (testWithApplication)
import "http-client" Network.HTTP.Client
import "http-types" Network.HTTP.Types.Status (statusCode)
import "hspec" Test.Hspec

-- | Build an Env against the ephemeral DB (same bootstrap as the executable),
-- serve it in-process, run the HTTP scenario.
spec :: Spec
spec = around withServer $ do
  describe "auth lifecycle over HTTP against PostgreSQL" $ do
    it "signup -> login -> me -> refresh -> reuse-detect -> logout -> jwks" $ \baseUrl -> do
      -- POST /auth/signup  => 200/201, capture {accessToken, refreshToken}
      -- POST /auth/login   => 200, token pair
      -- GET  /auth/me with Bearer => 200; without Bearer => 401
      -- POST /auth/refresh => 200 NEW pair
      -- POST /auth/refresh with OLD refresh => 401 (reuse detected; session revoked)
      -- POST /auth/refresh with the NEW refresh again => 401 (session now revoked)
      -- POST /auth/logout with Bearer => 204
      -- GET  /.well-known/jwks.json => 200 with active kid, no private material
      -- GET  /health => 200
      pendingWith "fill assertions during implementation"
  where
    withServer act =
      withShomeiMigratedDatabase $ \connStr -> do
        pool <- Pool.acquire (poolConfigForTest connStr)
        (key, jwks) <- bootstrapKeys pool defaultShomeiConfig
        let env = Env { envPool = pool, envConfig = defaultShomeiConfig
                      , envKey = key, envJwks = jwks }
        testWithApplication (pure (application env)) $ \port ->
          act ("http://localhost:" <> show port)
```

The `pendingWith` placeholder is replaced with concrete `http-client` requests and
`shouldBe` assertions during implementation. Crucially the test must also assert, after the
reuse-detection 401, that querying the `shomei.shomei_sessions` row for the session shows it
revoked and that the `shomei.shomei_auth_events` table contains a reuse/theft event — i.e.
prove reuse detection landed in PostgreSQL, not just in the HTTP status.

```bash
cabal test shomei-server
```

Expected:

```text
auth lifecycle over HTTP against PostgreSQL
  signup -> login -> me -> refresh -> reuse-detect -> logout -> jwks [✔]

Finished in 0.0000 seconds
1 example, 0 failures
```


## Validation and Acceptance

Acceptance is behavioral, not "it compiles". Two gates: the manual `curl` walkthrough and the
automated test.

### Manual curl walkthrough

Start PostgreSQL and the server (Step 6), with `PG_CONNECTION_STRING` and `SHOMEI_PORT` set,
then run the following in order. The exact JSON shapes come from EP-5's DTOs; the
`accessToken`/`refreshToken` values are illustrative.

1. Signup:

```bash
curl -fsS -X POST http://localhost:8080/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"email":"nadeem@example.com","password":"correct horse battery staple","displayName":"Nadeem"}'
```

Expected (HTTP 200 or 201):

```json
{
  "user": { "id": "user_01j...", "email": "nadeem@example.com", "displayName": "Nadeem" },
  "token": { "accessToken": "eyJhbGciOiJFUzI1NiIs...", "refreshToken": "rt_8f3c...", "expiresIn": 900 }
}
```

2. Login with the same credentials:

```bash
curl -fsS -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"nadeem@example.com","password":"correct horse battery staple"}'
```

Expected (HTTP 200): a token pair of the same shape as `token` above.

3. The authenticated "who am I". With a valid Bearer token (HTTP 200):

```bash
ACCESS="eyJhbGciOiJFUzI1NiIs..."
curl -fsS http://localhost:8080/auth/me -H "Authorization: Bearer $ACCESS"
```

```json
{ "id": "user_01j...", "email": "nadeem@example.com", "displayName": "Nadeem" }
```

Without a token (HTTP 401):

```bash
curl -isS http://localhost:8080/auth/me | head -1
```

```text
HTTP/1.1 401 Unauthorized
```

4. Refresh rotation, then reuse detection (the headline check). First rotate (HTTP 200,
   returns a NEW access+refresh):

```bash
OLD_REFRESH="rt_8f3c..."
curl -fsS -X POST http://localhost:8080/auth/refresh \
  -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$OLD_REFRESH\"}"
```

```json
{ "accessToken": "eyJ...NEW...", "refreshToken": "rt_NEW...", "expiresIn": 900 }
```

Now replay the OLD refresh token — this must be detected as theft (HTTP 401), and it must
revoke the whole session:

```bash
curl -isS -X POST http://localhost:8080/auth/refresh \
  -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$OLD_REFRESH\"}" | head -1
```

```text
HTTP/1.1 401 Unauthorized
```

Prove the session is now revoked: even the NEW refresh token now fails (HTTP 401), because
reuse revoked the session, not just the one token:

```bash
NEW_REFRESH="rt_NEW..."
curl -isS -X POST http://localhost:8080/auth/refresh \
  -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$NEW_REFRESH\"}" | head -1
```

```text
HTTP/1.1 401 Unauthorized
```

5. Logout (HTTP 204):

```bash
curl -isS -X POST http://localhost:8080/auth/logout -H "Authorization: Bearer $ACCESS" | head -1
```

```text
HTTP/1.1 204 No Content
```

After logout, behavior depends on the configured session-check mode (IP-5
`sessionCheckMode`):

- With **VerifyTokenOnly** (the access token is verified by signature/expiry alone, the
  session table is not consulted), `GET /auth/me` with the still-unexpired `$ACCESS`
  continues to return 200 until the access token expires — logout revokes the *session*
  (so *refresh* fails) but does not retroactively invalidate already-issued, still-valid
  access tokens. This is the standard JWT trade-off and the default for the standalone
  microservice (downstream services verify locally and cannot consult Shōmei's session
  table).
- With **VerifyTokenAndSession**, the `Authenticated` combinator additionally checks the
  session is live, so `GET /auth/me` returns 401 immediately after logout.

Document which mode is active in the run. Either way, after logout the refresh token is
revoked:

```bash
curl -isS -X POST http://localhost:8080/auth/refresh \
  -H 'Content-Type: application/json' -d "{\"refreshToken\":\"$NEW_REFRESH\"}" | head -1
```

```text
HTTP/1.1 401 Unauthorized
```

6. JWKS — the public key set, no private material (HTTP 200):

```bash
curl -fsS http://localhost:8080/.well-known/jwks.json
```

```json
{ "keys": [ { "kty": "EC", "crv": "P-256", "kid": "k_01j...", "use": "sig", "alg": "ES256", "x": "...", "y": "..." } ] }
```

There must be `x`/`y` (public coordinates) and a `kid`, and there must be **no** `d`
(the private scalar).

7. Health (HTTP 200):

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/health
```

```text
200
```

### HTTP transcripts

Signup request/response (the seam-level view):

```http
POST /auth/signup HTTP/1.1
Host: localhost:8080
Content-Type: application/json

{"email":"nadeem@example.com","password":"correct horse battery staple","displayName":"Nadeem"}

HTTP/1.1 201 Created
Content-Type: application/json

{"user":{"id":"user_01j...","email":"nadeem@example.com","displayName":"Nadeem"},"token":{"accessToken":"eyJ...","refreshToken":"rt_8f3c...","expiresIn":900}}
```

Reuse-detection 401:

```http
POST /auth/refresh HTTP/1.1
Host: localhost:8080
Content-Type: application/json

{"refreshToken":"rt_8f3c..."}

HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error":"refresh_token_reuse_detected","message":"Refresh token already used; session revoked"}
```

### Automated test

```bash
cabal test shomei-server
```

Acceptance: green, and the spec asserts (a) every status code in the walkthrough, and (b)
that after the reuse 401 the `shomei.shomei_sessions` row is revoked and a reuse event row
exists in `shomei.shomei_auth_events`. This is what makes "reuse detection works end-to-end
against PostgreSQL" a checked fact rather than a claim.

### Note on embedded mode (EP-7)

The same assembly supports the embedded deployment model. Because `Shomei.Server.App`
(`Env`, `AppEffects`, `runAppIO`) is servant-free and `application` is just a function
`Env -> Application`, a host Servant app in EP-7 can build its own `Env`, reuse the exact
interpreter stack, and either mount `shomeiServer (effToHandler env)` as a sub-API or call
the workflows directly via `runAppIO`. Nothing about the standalone server's effect stack is
specific to running it as its own process; the difference between standalone and embedded is
only *who owns `main` and the warp boot*.


## Idempotence and Recovery

Every startup step is safe to repeat:

- **Migrations** are idempotent. codd records applied migrations and skips them, so running
  the server (or `shomei-migrate`) repeatedly applies only new migrations. If a migration
  fails, the server aborts before serving; fix the migration and re-run — no partial-serve
  state is reachable.
- **Signing-key bootstrap** runs only when there is no active key
  (`ensureActiveSigningKey`'s generate-on-empty guard). On the second and subsequent boots
  the active key is loaded, not regenerated, so previously-issued tokens stay verifiable and
  the published JWKS is stable across restarts. To rotate deliberately, use EP-4's rotation
  operations (out of scope here).
- **Re-running the server** is safe: it reloads config, reapplies (no-op) migrations,
  re-acquires a fresh pool, loads the existing key, and serves. Stopping it releases the pool
  on normal exit; an abrupt kill leaves no inconsistent on-disk state because PostgreSQL is
  the only durable store and all writes are transactional through hasql.
- **Recovery from a wedged database** (e.g. wrong `PG_CONNECTION_STRING`): the server fails
  fast at Step 1/2/3 with a clear error (missing env var, migration error, or pool-acquire
  error) before binding the port, so there is never a half-up server.
- **The automated test** uses a throwaway ephemeral database per run
  (`withShomeiMigratedDatabase`), so it cannot pollute or be polluted by a developer's local
  database, and reruns are independent.


## Interfaces and Dependencies

Libraries and packages, and why each is used:

- `shomei-core` — `ShomeiConfig` (IP-5), the effects (IP-3), domain types (IP-2),
  `AuthError`. The server consumes the config and assembles interpreters of the effects.
- `shomei-postgres` — the `Database` effect + `runDatabasePool`, the store/publisher/
  signing-key/clock interpreters, the Argon2 `PasswordHasher`, the `TokenGen` interpreter.
  The persistence half of the stack (IP-3/IP-7).
- `shomei-migrations` (+ its `test-support` sublibrary) — `runShomeiMigrationsNoCheck` for
  startup migrations (IP-7) and `withShomeiMigratedDatabase` for the test's ephemeral DB.
- `shomei-jwt` — `runTokenSignerJwt`/`runTokenVerifierJwt`, `verifyToken` (for the auth
  `Context`), `jwksDocument`, the rotation/generation + JWK↔StoredSigningKey conversion used
  by the key bootstrap (IP-4).
- `shomei-servant` — `ShomeiAPI` (IP-6), `shomeiServer`, the `Authenticated` combinator's
  `authHandler`/`Context`, and the `AuthError`→`ServerError` mapping used by the seam.
- `effectful`/`effectful-core` — the effect system the whole stack is built on.
- `hasql-pool` — `Pool` and `Hasql.Pool.acquire` for the connection pool.
- `warp`/`wai`/`servant-server` — the production HTTP server, the WAI `Application` type, and
  `serveWithContext`.
- `text`, `time`, `bytestring` — config parsing, `DiffTime` for the migrate timeout, raw I/O.
- Test only: `hspec`, `http-client`, `http-types`, `aeson`.

Types, interfaces, and function signatures that must exist at the end of each milestone (full
module paths):

End of Milestone 1:

```haskell
-- Shomei.Server.Config
data ServerSettings = ServerSettings { serverPort :: !Int, serverConnStr :: !Text }
loadConfig :: IO (ShomeiConfig, ServerSettings)

-- Shomei.Server.App
type AppEffects =
  '[ UserStore, CredentialStore, SessionStore, RefreshTokenStore, PasswordHasher
   , TokenSigner, TokenVerifier, AuthEventPublisher, SigningKeyStore, Clock
   , TokenGen, Database, Error AuthError, IOE ]
data Env = Env { envPool :: !Pool, envConfig :: !ShomeiConfig, envKey :: !JWK, envJwks :: !JWKSet }
runAppIO :: Env -> Eff AppEffects a -> IO (Either AuthError a)

-- Shomei.Server.Seam
effToHandler :: Env -> Eff AppEffects a -> Handler a
```

End of Milestone 2:

```haskell
-- Shomei.Server.Keys
bootstrapKeys :: Pool -> ShomeiConfig -> IO (JWK, JWKSet)

-- Shomei.Server.Boot
main :: IO ()
application :: Env -> Application
```

End of Milestone 3:

```haskell
-- Shomei.Server.E2ESpec
spec :: Spec
```

Consumption of integration points (from the MasterPlan): this plan consumes **IP-3** (the
effects — it assembles their PostgreSQL/JWT interpreters into one stack), **IP-5**
(`ShomeiConfig` — it loads and threads it), **IP-6** (`ShomeiAPI`, DTOs, `AuthUser` — it
serves them), and **IP-7** (the schema — it runs the migrations). It is the **integration
point for all adapters**: EP-3, EP-4, and EP-5 first run together here, behind one HTTP
process. The effect-stack ordering and the `Env` record defined here are also the contract
EP-7 reuses for the embedded demo.
