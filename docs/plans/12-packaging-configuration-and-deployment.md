---
id: 12
slug: packaging-configuration-and-deployment
title: "Packaging, configuration, and deployment"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Packaging, configuration, and deployment

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei ("証明", Japanese for *proof* / *certificate*) is a Haskell authentication
toolkit. By the time this plan runs, Shōmei already has a working authentication server
(`shomei-server`, an executable that signs/verifies JWTs, persists users and sessions in
PostgreSQL, and serves a small HTTP API), and an operations command-line tool
(`shomei-admin`, which runs database migrations and generates/rotates the JWT signing
keys). Up to now, both of those programs are configured by setting individual shell
environment variables one at a time, must be started by hand, and the database, the
server, and the key-generation steps must each be wired up manually. There is no single
file that captures "this is how my deployment is configured," no container you can ship,
and no continuous-integration pipeline that proves the build and tests stay green.

After this plan, an operator gains four concrete, demonstrable abilities:

1. **One typed configuration file.** A single
   [Dhall](https://dhall-lang.org) file (Dhall is a small, strongly-typed configuration
   language — think "JSON with types, functions, and imports") at `config/shomei.dhall`
   describes *every* runtime setting: the database connection, the address and effect the
   server listens on, the JWT issuer/audience, all the token lifetimes, the password
   policy, the rate-limit and account-lockout policy, the email/SMTP settings, and the
   log level. Environment variables override any value in that file, so the same image
   can be reconfigured at deploy time without rebuilding. Both `shomei-server` and
   `shomei-admin` read configuration through *the same loader*, so they can never
   disagree about what the configuration means. After this plan, running
   `shomei-server` with `SHOMEI_CONFIG=config/shomei.dhall` boots a fully-configured
   server, and running it with no config file at all still boots using built-in defaults
   plus whatever environment variables are set.

2. **A reproducible container image.** `nix build .#dockerImage` produces an OCI image (OCI
   = Open Container Initiative, the standard format that Docker and Podman both run)
   containing the `shomei-server` and `shomei-admin` binaries. When that image starts, its
   entrypoint script *first* applies any pending database migrations and *ensures an active
   signing key exists* (generating and activating one if the database has none), and *then*
   starts the server. This is exactly why this plan depends on the `shomei-admin` CLI: the
   entrypoint calls it.

3. **A one-command local stack.** `docker compose up` brings up PostgreSQL and
   `shomei-server` together, wired by configuration, with health checks so the server only
   starts serving once the database is ready and only reports "ready" once it can answer
   requests. After `docker compose up`, you can `curl` a real signup and login against
   `http://localhost:8080` and get back tokens.

4. **A green CI pipeline.** A GitHub Actions workflow builds every package, runs the full
   test suite (including the integration tests that spin up a throwaway PostgreSQL), and
   fails if the code is not formatted — all inside the project's Nix environment, so CI uses
   the exact same toolchain as a developer's laptop.

The user-visible outcome is therefore: Shōmei goes from "runs on my laptop if I export the
right variables in the right order" to "configure it in one typed file, build one image,
bring up the whole stack with one command, and keep it honest with CI."


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Typed Dhall + env configuration loader. DONE & VERIFIED (2026-06-10).**
  - [x] **Deviation:** did NOT add the heavy `dhall` Haskell library. Instead the loader renders
        the Dhall file to JSON with the `dhall-to-json` CLI (provided by the toolchain/container)
        and decodes it with `aeson`. Rationale in the Decision Log; keeps EP-5 dependency-light.
        Only `process` was added to `shomei-server`.
  - [x] Extended `Shomei.Server.Config` with a flat all-optional `FileConfig`, the `loadConfig`
        loader (defaults → Dhall file at `$SHOMEI_CONFIG` → `SHOMEI_*`/`PG_CONNECTION_STRING`
        env), and the precedence rules. `loadConfigFromEnv` kept as the env-only entry point.
  - [x] Created `config/shomei-types.dhall` (schema), `config/shomei.example.dhall` (committed),
        and gitignored `config/shomei.dhall`.
  - [x] `test-suite shomei-server-config-test` proves a Dhall file is loaded and an env var
        overrides it. Green.
- [~] **M2 — Reproducible OCI image via the Nix flake. AUTHORED, NOT BUILT IN THIS SANDBOX.**
  - [x] Added `packages.dockerImage` (`dockerTools.buildLayeredImage` with `shomei-server` +
        `shomei-admin` + `dhall-to-json`) and the entrypoint to `flake.module.nix`; the flake
        still evaluates and `nix develop` works.
  - [ ] `nix build .#dockerImage` / `docker load` / `docker run` not executed here (needs a
        Nix+Docker build environment; heavy). Verify in CI or a deploy host.
  - [x] Provided the plain `Dockerfile` as the documented secondary (non-reproducible) path.
- [~] **M3 — `docker compose` stack. AUTHORED & SYNTAX-VALIDATED, NOT RUN LIVE.**
  - [x] `docker-compose.yaml` (postgres + shomei-server) with a `/ready` healthcheck and
        `depends_on … condition: service_healthy`; `docker compose config` validates it.
        `deploy/entrypoint.sh` (migrate → ensure active key → exec server) passes `sh -n`.
  - [ ] `docker compose up` + a live `curl` transcript not run here (no built image in sandbox).
- [x] **M4 — CI pipeline. AUTHORED (2026-06-10).**
  - [x] `.github/workflows/ci.yaml`: Nix install + cache, `cabal build all`, `cabal test all`,
        `nix fmt -- --fail-on-change`. (Runs on GitHub Actions; not executed in this sandbox.)
- [x] **Versioning / release note.** Added `CHANGELOG.md` with the MasterPlan 2 summary and a
      date-based pre-1.0 → semantic-versioning policy.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-10: **Deviated from the `dhall` Haskell library to `dhall-to-json` + `aeson`.** The
  `dhall` library is a heavy dependency (megaparsec + a large closure) and is not in the project's
  `mori` registry; building it from Hackage was slow/uncertain. The `dhall-to-json` CLI is already
  in the toolchain (`nix develop`), so `loadConfig` shells out to it to render the file to JSON,
  then decodes with `aeson` into a flat all-optional `FileConfig`. This keeps the config typed on
  disk (the Dhall type alias) and dependency-light in Haskell (only `process` added). The flat
  scalar shape also sidesteps Dhall-union vs `NominalDiffTime` JSON-encoding mismatches. Evidence:
  `dhall-to-json --file config/shomei.example.dhall` renders clean JSON and
  `shomei-server-config-test` passes (file load + env override).
- 2026-06-10: **The OCI image and `docker compose` stack are authored but were not built/run in
  the development sandbox.** Docker is present (28.4.0) but a reproducible `nix build .#dockerImage`
  (or a from-scratch Haskell Dockerfile reproducing the pinned `source-repository-package`s) is a
  heavy build not run here. The `flake.module.nix` addition keeps the flake evaluating and
  `nix develop` working; `docker compose config` validates the compose file and `sh -n` validates
  the entrypoint. Full verification (`nix build .#dockerImage` → `docker compose up` → `curl`
  signup/login) is deferred to CI or a deploy host.


## Decision Log

Record every decision made while working on the plan.

- Decision: The on-disk configuration schema is a single Dhall record at
  `config/shomei.dhall`, with a committed example `config/shomei.example.dhall` and a
  committed reusable type alias `config/shomei-types.dhall`; the local working copy
  `config/shomei.dhall` is gitignored.
  Rationale: MasterPlan 2's IP-6 explicitly says EP-5 "decides the on-disk schema and
  location (e.g. `config/shomei.dhall`)." A `config/` directory at the repo root is the
  conventional home and is easy to mount into a container as a volume. We do **not** reuse
  the existing `.seihou/config.dhall` placeholder: that file belongs to the `seihou`
  toolchain (it carries `git.repoName`, `nix.postgresql`, etc.) and is unrelated to runtime
  application configuration; co-opting it would conflate build-tooling config with runtime
  config. We commit `*.example.dhall` so the schema is discoverable and version-controlled,
  but gitignore the live `config/shomei.dhall` so an operator's real secrets (SMTP password,
  signing-key passphrase) never land in git.
  Date: 2026-06-04

- Decision: The configuration loader lives in
  `shomei-server/src/Shomei/Server/Config.hs` (module `Shomei.Server.Config`),
  the same module MasterPlan 1's EP-6 created for the env-only `loadConfig`.
  Rationale: MasterPlan 1's EP-6 already introduced `Shomei.Server.Config` with
  `ServerSettings` and `loadConfig :: IO (ShomeiConfig, ServerSettings)` reading
  environment variables. MasterPlan 2's IP-6 names EP-5 as the owner of the *full*
  configuration loader and says it must "supersede" any minimal env-only loader. Putting the
  Dhall loader in the *same module* (extending `ServerSettings` into the richer
  `DeploymentSettings`) means there is exactly one `loadConfig` and one place that knows the
  config contract. Both the `shomei-server` executable and the `shomei-admin` executable live
  in the `shomei-server` package (per MasterPlan 2's IP-8 default), so a module in
  that package is importable by both with no new package and no `mori.dhall` change.
  Date: 2026-06-04

- Decision: Environment variables override Dhall-file values; the Dhall file overrides
  built-in defaults. Precedence, lowest to highest: (1) `defaultShomeiConfig` /
  `defaultDeploymentSettings`; (2) the Dhall file at `$SHOMEI_CONFIG` (if set and present);
  (3) individual `SHOMEI_*` environment variables.
  Rationale: This is the standard twelve-factor precedence (env wins) and lets one immutable
  image be reconfigured per environment by setting env vars, while keeping a readable typed
  file as the source of truth for the bulk of settings. If `$SHOMEI_CONFIG` is unset, the
  loader skips the file entirely and uses defaults + env, so the server still boots with zero
  configuration files (preserving EP-6's turnkey behavior).
  Date: 2026-06-04

- Decision: Build the OCI image **from the Nix flake** using
  `pkgs.dockerTools.buildLayeredImage`, and provide a plain multi-stage `Dockerfile` only as
  a documented, secondary alternative.
  Rationale: The project is nix-first (GHC, cabal, HLS, formatters all come from the flake;
  see `flake.nix` / `nix/haskell.nix` / `flake.module.nix`). `dockerTools.buildLayeredImage`
  produces a byte-for-byte reproducible image from the exact same pinned dependency closure
  the dev shell uses, with no Docker daemon required to build it, and automatic layer
  deduplication. The plain `Dockerfile` is kept for operators without Nix, but is explicitly
  marked "not the reproducible path."
  Date: 2026-06-04

- Decision: The container entrypoint runs `shomei-admin migrate`, then ensures an active
  signing key (`shomei-admin keys list-active`; if empty, `shomei-admin keys generate &&
  shomei-admin keys activate <kid>`), and only then `exec`s `shomei-server`.
  Rationale: MasterPlan 2's Dependency Graph states the hard dependency EP-5 → EP-4 exists
  *precisely* because "the container image and `docker compose` stack run database migrations
  and ensure an active signing key exists at startup by invoking the `shomei-admin` CLI."
  Doing this in the entrypoint (rather than baking it into the server's own boot sequence)
  keeps migration/key-management an explicit, observable, operator-controllable step and
  matches the standard "init then serve" container pattern. `exec` replaces the shell with
  the server process so signals (SIGTERM on `docker stop`) reach the server for graceful
  shutdown.
  Date: 2026-06-04

- Decision: CI runs on **GitHub Actions** inside the project's Nix environment.
  Rationale: `mori` shows the repository as `shinzui/shomei`, a GitHub repository, so GitHub
  Actions is the native choice and needs no extra hosting. Running every step inside
  `nix develop` (via `cabal build all` / `cabal test all`) means CI uses the identical pinned
  GHC 9.12.4 toolchain as a developer laptop, eliminating "works on my machine" drift. The
  integration tests provision their *own* throwaway PostgreSQL through `ephemeral-pg`, so no
  GitHub service container is required for the database (recorded below).
  Date: 2026-06-04

- Decision: Versioning stays lightweight: the `version:` field in each `.cabal` file is the
  source of truth, a top-level `CHANGELOG.md` records human-readable changes, and a release
  is a git tag `vX.Y.Z`. No Hackage publication, no automated release tooling.
  Rationale: Shōmei is deployed as a container, not consumed from Hackage, so heavyweight
  release automation is unwarranted. A tag + changelog is enough to reproduce any deployed
  image (the flake pins all dependencies).
  Date: 2026-06-04


- Decision: Update this ExecPlan for the 2026-06-04 package-layout and effect-namespace refactor.
  Rationale: The packages now live as top-level directories rather than under the old nested packages directory, and the core effect interfaces now live under `Shomei.Effect.*` rather than the old Port namespace. This revision also removes stale bootstrap-placeholder assumptions and points implementation steps at the current real modules.
  Date: 2026-06-04

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes the reader knows nothing about this repository. It defines every term
and names every file by full path.

### What Shōmei is and where its pieces live

The repository root is `/Users/shinzui/Keikaku/bokuno/shomei`. Shōmei is a multi-package
Haskell project. A *package* is a unit of Haskell code with a `<name>.cabal` file describing
it. The packages live as top-level directories and are listed together in the root file
`cabal.project`, which also pins the compiler to GHC 9.12.4 (`with-compiler: ghc-9.12.4`).
The packages are: `shomei-core` (transport-agnostic domain types, effect interfaces, and the runtime
config record), `shomei-jwt` (JWT signing/verification), `shomei-postgres` (PostgreSQL
adapters), `shomei-migrations` (the database schema, applied via the `codd` migration tool),
`shomei-servant` (the HTTP API description), `shomei-server` (the executable server **and**,
per MasterPlan 2, the `shomei-admin` CLI), and `shomei-client` (a Haskell client). PostgreSQL
is the only external datastore.

You build everything with `cabal build all` and test with `cabal test all`; you format with
`nix fmt`; and all of these run inside a Nix *dev shell* entered by `nix develop` (or
automatically via `direnv`, since `.envrc` contains `use flake`). A Nix *flake* is a
pinned, reproducible description of a build environment; Shōmei's lives in `flake.nix` plus
the modules under `nix/` and the unmanaged `flake.module.nix`. The file `flake.nix` and the
files under `nix/` are *seihou-managed* (generated by the `seihou` toolchain) and **must not
be hand-edited** — changes are overwritten on the next `seihou run`. The one file that is
intentionally not seihou-managed, and is therefore the safe place to add project-specific Nix
wiring, is `flake.module.nix` at the repo root. This plan adds the container-image build to
`flake.module.nix`.

### Key files this plan reads or extends

- `cabal.project` (repo root): lists packages, pins GHC 9.12.4, and carries a clearly
  labelled "DEPENDENCY OVERRIDES — each plan appends its own block; none rewrites another's"
  section. EP-3 appended the `codd`/`ephemeral-pg` git pins; EP-4-of-MasterPlan-1 appended the
  `jose` pin. **This plan appends its own block for `dhall`** under the same comment.
- `shomei-core/src/Shomei/Config.hs`: defines `ShomeiConfig`, the runtime
  configuration *record* (a Haskell product type) the application reads at runtime. Its
  current fields are `issuer`, `audience`, `accessTokenTTL`, `refreshTokenTTL`, `sessionTTL`,
  `passwordPolicy`, `tokenTransport`, `signingKeyConfig`, and `sessionCheckMode`, plus a
  `defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig` smart constructor. MasterPlan 2
  calls this record "IP-3" and extends it append-only: **EP-1** adds a notifier/verification
  sub-record, **EP-2** a rate-limit/lockout sub-record, **EP-3** an observability sub-record.
  This plan's loader must populate whichever of those fields exist when it runs (see
  "Cross-plan config dependence" below).
- `shomei-server/src/Shomei/Server/Config.hs`: MasterPlan 1's EP-6 created this
  module with a `ServerSettings` record (the listen effect and the raw PostgreSQL connection
  string) and `loadConfig :: IO (ShomeiConfig, ServerSettings)` that reads environment
  variables and falls back to `ShomeiConfig`'s defaults. **This plan supersedes that env-only
  loader** with a Dhall + env loader in the same module, widening `ServerSettings` into a
  richer `DeploymentSettings`. Do not replace the module wholesale; preserve existing
  imports and exported names that `Shomei.Server.Boot`, the executable, and tests already use.
- `shomei-server/shomei-server.cabal`: currently declares a `library`, an
  `executable shomei-server`, and (per MasterPlan 2) an `executable shomei-admin`. This plan
  adds `dhall` to the library's `build-depends` and adds a config test-suite stanza.
- `.seihou/config.dhall`: an existing Dhall file used by the `seihou` build toolchain (it
  holds `git.repoName`, `nix.postgresql`, project description, etc.). **It is unrelated to
  runtime application configuration and this plan does not touch it.** It is mentioned only to
  explain why we create a *new* `config/shomei.dhall` rather than reusing it.
- `flake.nix`, `nix/haskell.nix`, `nix/treefmt.nix`: seihou-managed; do not edit. `flake.nix`
  imports `./nix/haskell.nix` and (if present) `./flake.module.nix`. `nix/haskell.nix`
  defines the dev shell and (in a way that is currently broken for a multi-package workspace —
  see below) a `packages.default`.
- `flake.module.nix`: the unmanaged customization file. Today it wires `nix fmt` (treefmt
  with `nixpkgs-fmt`, `fourmolu`, `cabal-fmt`) and adds `cabal-install`/`fourmolu`/`cabal-fmt`
  to the dev shell. **This plan adds the `dockerImage` package and the entrypoint here.**
- `Justfile`: a `just` task runner file with `build`, `create-database`, `migrate`, and
  `new-migration` recipes. This plan adds a few convenience recipes (`docker-build`,
  `compose-up`).
- `process-compose.yaml`: a *local-development* process orchestrator (starts a local
  PostgreSQL on a Unix socket and runs `just create-database`). It is **not** the deployment
  mechanism; this plan's `docker-compose.yaml` is the deployment mechanism. They serve
  different audiences (laptop dev vs. container deployment) and coexist.

### Terms of art used in this plan (each defined once, in plain language)

- **Dhall** — a small, strongly-typed, non-Turing-complete configuration language. A Dhall
  file evaluates to a value (here, a record). Unlike JSON/YAML it has a type system, so a
  typo in a field name or a wrong type is a *parse/type error*, not a silent
  misconfiguration. The Haskell library `dhall` reads a Dhall file and decodes it into a
  Haskell value via a `FromDhall` type-class instance.
- **`FromDhall` / `Decoder` / `genericAuto`** — `dhall`'s decoding machinery. `FromDhall a`
  means "a Dhall expression can be turned into a Haskell value of type `a`." `Decoder a` is a
  first-class decoder you can build by hand or derive. `genericAuto :: (Generic a, …) =>
  Decoder a` derives a record decoder from the Haskell record's field names. `auto ::
  FromDhall a => Decoder a` is the default decoder. The top-level entry points are
  `input :: Decoder a -> Text -> IO a` (decode in-memory Dhall text) and
  `inputFile :: FromDhall a => Decoder a -> FilePath -> IO a` (decode a file). These names are
  verified present in the installed `dhall` 1.42.3 (see Surprises once built).
- **OCI image / container** — a packaged filesystem + metadata that a container runtime
  (Docker, Podman) runs as an isolated process. "OCI" is the open standard format.
- **`dockerTools.buildLayeredImage`** — a Nix function (`pkgs.dockerTools`) that builds an OCI
  image tarball from a Nix package closure, splitting it into many cache-friendly layers,
  *without needing a running Docker daemon*. You load the result with `docker load <
  result`.
- **entrypoint** — the program a container runs on start. Ours is a shell script that
  migrates, ensures a signing key, then `exec`s the server.
- **`docker compose`** — a tool that reads a `docker-compose.yaml` describing several
  containers (here PostgreSQL + the server) and their wiring, and starts them together with
  `docker compose up`.
- **healthcheck / `/health` / `/ready`** — `/health` is a *liveness* probe (the process is
  up) and `/ready` is a *readiness* probe (the process can actually serve requests, e.g. its
  database is reachable). MasterPlan 2's EP-3 (observability) adds `/ready` distinct from the
  existing `/health`. A Docker *healthcheck* periodically curls one of these; `depends_on …
  condition: service_healthy` makes one container wait until another is healthy.
- **CI (continuous integration)** — an automated pipeline (here GitHub Actions) that builds
  and tests every push so regressions are caught early.
- **`ephemeral-pg`** — a Haskell test helper (already a dependency of `shomei-postgres`'s
  tests via `shomei-migrations:test-support`) that starts a throwaway PostgreSQL server
  in-process for the duration of a test. Because the integration tests provision their own
  database, CI does not need a separate database service.

### Preconditions (state them so a novice does not start too early)

This plan is **EP-5 of MasterPlan 2** (`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`).
Do not begin it until all of the following hold:

1. **MasterPlan 1 is Complete.** In particular `shomei-server` boots against PostgreSQL and
   serves the API (`POST /auth/signup`, `/auth/login`, `/auth/refresh`, `/auth/logout`,
   `GET /auth/me`, `GET /.well-known/jwks.json`, `GET /health`). This is stated once in the
   MasterPlan's Precondition section and applies globally.
2. **EP-4 (plan 11, `docs/plans/11-operational-cli-and-signing-key-rotation-tooling.md`) is
   Complete** — this is a **hard** dependency. The container entrypoint invokes the
   `shomei-admin` CLI it builds. The exact CLI contract this plan relies on is reproduced in
   "The `shomei-admin` CLI contract" below; if EP-4 ships different command spellings, update
   the entrypoint and that section and record it in the Decision Log.
3. **EP-1 / EP-2 / EP-3 (plans 8 / 9 / 10) are Complete** — these are **soft** dependencies.
   They extend `ShomeiConfig` (IP-3) with the notifier/SMTP, rate-limit/lockout, and
   observability sub-records that the loader must populate. The loader is written to populate
   whatever fields exist; if any of EP-1/EP-2/EP-3 has *not* landed, the loader simply omits
   that sub-record's wiring (and the example Dhall file omits that section), and a follow-up
   change adds it. See "Cross-plan config dependence."

### The `shomei-admin` CLI contract (consumed by this plan's entrypoint)

EP-4 (plan 11) is, at the time this plan is authored, an unfilled skeleton. MasterPlan 2
fixes its behavior: `shomei-admin` is an executable in `shomei-server` that "runs
migrations, signing-key generation/rotation/retirement, and bootstrap user creation," with a
signing-key lifecycle "pending → active → retired → revoked." This plan depends on exactly
these subcommands (full module/flag spellings to be confirmed against EP-4 when it lands;
record any difference in the Decision Log):

```text
shomei-admin migrate
    Apply all pending database migrations. Idempotent: a no-op if nothing is pending.
    Exit 0 on success.

shomei-admin keys list-active
    Print the key id (kid) of each currently-active signing key, one per line.
    Print nothing (and exit 0) if there is no active key.

shomei-admin keys generate
    Generate a new ES256 signing key in the "pending" state and print its kid to stdout.

shomei-admin keys activate <kid>
    Move the key <kid> from pending to active. Exit 0 on success.
```

All of these read their database connection (and any other settings) through **this plan's**
`loadConfig` (see IP-6), so the entrypoint can configure them with the same `SHOMEI_*`
environment variables it configures the server with.

### Why `nix build .#packages.default` is not the image path

`nix/haskell.nix` (seihou-managed, not editable) defines
`packages.default = haskellPackages.callCabal2nix "shomei" inputs.self {}`. `callCabal2nix`
assumes a *single* `.cabal` file at the repo root; Shōmei has a multi-package workspace with
no root `.cabal`, so `packages.default` fails to evaluate (documented in EP-1's Decision Log).
This plan does **not** fix `packages.default` (it is seihou-managed). Instead it builds the
binaries with Nix's Haskell package set assembled in `flake.module.nix` and wraps them in an
image there, under a *new* attribute `dockerImage`. The exact mechanism is specified in
Milestone 2, including the fallback if building the Haskell closure from the multi-package
project through Nix proves awkward (build inside the dev shell and copy the binaries in).

### Cross-plan config dependence (read carefully)

The loader's job is to produce the **fully-extended** `ShomeiConfig`. At authoring time the
record in `shomei-core/src/Shomei/Config.hs` has only MasterPlan 1's fields. EP-1,
EP-2, and EP-3 each append one named sub-record field (e.g. `notifierConfig`,
`rateLimitConfig`, `observabilityConfig`) with a default. The loader and the example Dhall
file must mirror the record *as it exists when this plan runs*. Concretely:

- The loader builds `ShomeiConfig` starting from `defaultShomeiConfig issuer audience` and
  overrides each field present in the Dhall file / env. For sub-records that EP-1/EP-2/EP-3
  added, it reads a corresponding nested Dhall record and an env-var family
  (`SHOMEI_RATELIMIT_*`, `SHOMEI_SMTP_*`, `SHOMEI_LOG_LEVEL`, …).
- If, when this plan executes, one of EP-1/EP-2/EP-3 has not yet landed, simply do not wire
  its sub-record (the field will not exist), omit its section from `config/shomei.example.dhall`,
  and add a Progress sub-item to wire it later. This keeps the plan honest and buildable
  regardless of the exact landing order of the soft dependencies.

The deployment-only settings (which are **not** part of `ShomeiConfig` because they are about
*where/how* to run, not auth semantics) are: the PostgreSQL connection URL, the bind host and
port, the path to the active signing key's source and its passphrase, and the config file
path itself. These live in this plan's new `DeploymentSettings` record.


## Plan of Work

The work is four milestones, each independently verifiable, plus a small versioning task.
Each milestone names exact files, exact commands, and the behavior to observe.

### Milestone 1 — Typed Dhall + environment configuration loader (owns IP-6)

**Scope.** Replace the env-only `loadConfig` from MasterPlan 1's EP-6 with a loader that
reads a typed Dhall file, then applies environment-variable overrides, producing the
fully-extended `ShomeiConfig` plus a `DeploymentSettings` record. Ship a committed example
Dhall file and a unit test that loads it and proves env overrides win.

**End state.** `Shomei.Server.Config.loadConfig :: IO (ShomeiConfig, DeploymentSettings)`
exists; `config/shomei.example.dhall` parses; `cabal test shomei-server-config-test` is
green, including an env-override case. Both `shomei-server` and `shomei-admin` call
`loadConfig`.

**The IP-6 contract, quoted from MasterPlan 2 (this plan owns it):**

> **IP-6 — Configuration loading (Dhall + environment).** A single typed configuration
> loader, owned by **EP-5**, that reads a Dhall file and/or environment variables and
> produces the fully-extended `ShomeiConfig` (IP-3) plus deployment-only settings (database
> URL, bind host/port, signing-key source). The repository already contains a
> `.seihou/config.dhall` placeholder; EP-5 decides the on-disk schema and location (e.g.
> `config/shomei.dhall`). Consumers: the `shomei-server` executable and the `shomei-admin`
> CLI (EP-4) should load configuration the same way, so EP-5's loader must be usable by EP-4's
> binary; if EP-4 lands first with a minimal env-only loader, EP-5 supersedes it with the
> Dhall-backed one and records the migration in the Decision Log.

**Work.**

1. **`cabal.project` — append the `dhall` block.** Under the existing "DEPENDENCY OVERRIDES
   — each plan appends its own block; none rewrites another's" comment, add an EP-5 block.
   `dhall` is on Hackage and (version 1.42.3, which `mori` shows on disk at
   `/Users/shinzui/Keikaku/hub/haskell/dhall-haskell-project/dhall-haskell/dhall`) declares
   `base >= 4.11 && < 5`, so it is GHC-9.12-compatible; no `source-repository-package` pin is
   needed. The block exists to (a) document EP-5's ownership and (b) hold any `allow-newer`
   the solver turns out to need. Do **not** rewrite any other plan's block.

2. **`shomei-server.cabal` — add `dhall` and a config test-suite.** Add `dhall` to the
   `library` stanza's `build-depends`. Add a new `test-suite shomei-server-config-test`
   (type `exitcode-stdio-1.0`, hspec or tasty per the repo's test convention) over
   `test/Shomei/Server/ConfigSpec.hs`, depending on `shomei-server`, `shomei-core`, `dhall`,
   `text`, and the chosen test framework.

3. **`Shomei.Server.Config` — the loader.** Edit
   `shomei-server/src/Shomei/Server/Config.hs`. Extend the existing module by defining:
   - `DeploymentSettings`, a record of the *deployment-only* settings (not auth semantics):
     `databaseUrl :: Text` (libpq/PostgreSQL connection string or URL), `bindHost :: Text`
     (default `"0.0.0.0"` in a container, `"127.0.0.1"` for local), `bindPort :: Int`
     (default `8080`, matching EP-6's `listening on :8080`), `poolSize :: Int` (hasql pool
     size, default `10`), `signingKeySource :: SigningKeySource`, and `configFile :: Maybe
     FilePath`.
   - `SigningKeySource`, describing where the active signing key comes from. Since EP-4 owns
     key generation/storage in PostgreSQL, the default is `SigningKeyFromDatabase` (the server
     reads the active key from the `shomei_signing_keys` table that EP-3 created); an optional
     `SigningKeyFromFile FilePath (Maybe Text)` variant names a PEM/JWK file and an optional
     decryption passphrase for operators who manage keys out-of-band. The passphrase is only
     ever read from an environment variable, never written to the committed example file.
   - A *file schema* type `FileConfig` whose shape mirrors the Dhall record one-to-one, with
     `FromDhall` derived via `genericAutoWith`. Every field in `FileConfig` is `Maybe` so a
     partial Dhall file (or none) is valid and missing fields fall back to defaults. Use
     `defaultInterpretOptions { fieldModifier = … }` only if the Dhall field names need to
     differ from the Haskell field names (default: keep them identical so no remapping is
     needed).
   - The loader:

     ```haskell
     -- | Load configuration with precedence (lowest to highest):
     --   1. built-in defaults (defaultShomeiConfig / defaultDeploymentSettings)
     --   2. the Dhall file at $SHOMEI_CONFIG, if set and present
     --   3. individual SHOMEI_* environment variables
     loadConfig :: IO (ShomeiConfig, DeploymentSettings)
     loadConfig = do
       fileCfg  <- loadFileConfig          -- reads $SHOMEI_CONFIG if set, else mempty
       envOver  <- readEnvOverrides         -- reads SHOMEI_* env vars
       pure (assembleShomeiConfig fileCfg envOver, assembleDeployment fileCfg envOver)
     ```

     where `loadFileConfig :: IO FileConfig` consults `lookupEnv "SHOMEI_CONFIG"`, and on
     `Just path` calls `Dhall.inputFile Dhall.auto path :: IO FileConfig` (with
     `Dhall.rootDirectory` set to the file's directory so relative Dhall imports resolve), and
     on `Nothing` returns an all-`Nothing` `FileConfig`. `readEnvOverrides` reads each
     `SHOMEI_*` variable with `lookupEnv` and parses it (`Int`/`NominalDiffTime`/`Bool` via
     `readMaybe`). `assembleShomeiConfig` and `assembleDeployment` fold defaults → file →
     env in that order.
   - **Keep EP-4's/EP-6's env-only path working (additive then retire).** Define
     `loadConfigFromEnv :: IO (ShomeiConfig, DeploymentSettings)` as `loadConfig` with
     `SHOMEI_CONFIG` ignored (file step skipped). If EP-4 shipped a function with a different
     name (e.g. EP-6's `loadConfig :: IO (ShomeiConfig, ServerSettings)`), keep that name as a
     thin shim that calls the new loader and projects `DeploymentSettings` back to
     `ServerSettings` (or, preferably, update EP-4/EP-6's callers to the new type in this same
     change and delete the shim — record which path you took in the Decision Log). The
     acceptance for "superseded, still working" is that **both** the `shomei-server` and
     `shomei-admin` `main`s call `loadConfig` and behave identically when given only env vars.

4. **The Dhall schema files under `config/`.**
   - `config/shomei-types.dhall` — a reusable Dhall *type alias* for the config record, so the
     example and any operator file can `let Config = ./shomei-types.dhall in …` and get
     editor/type checking. It declares the record type with every field optional
     (`Optional`), matching `FileConfig`.
   - `config/shomei.example.dhall` — a committed, fully-populated example using non-secret
     placeholder values (issuer `https://auth.example.com`, audience `example-api`, database
     URL `postgresql://shomei:shomei@localhost:5432/shomei`, effect `8080`, etc.). Secrets (SMTP
     password, signing-key passphrase) are shown as `env:SHOMEI_SMTP_PASSWORD as Text`
     comments or left `None Text`, never as literals.
   - `config/shomei.dhall` — the live operator copy; **gitignored** (add `config/shomei.dhall`
     to `.gitignore`). The example doubles as the starting point: `cp config/shomei.example.dhall
     config/shomei.dhall`.

5. **The test.** `test/Shomei/Server/ConfigSpec.hs`:
   - *File-load case:* set `SHOMEI_CONFIG=config/shomei.example.dhall`, call `loadConfig`,
     assert specific fields (issuer, audience, effect `8080`, the database URL, a token TTL).
   - *Env-override case:* with the same config file, additionally `setEnv "SHOMEI_PORT" "9999"`
     and `setEnv "SHOMEI_DATABASE_URL" "postgresql://override/db"`, call `loadConfig`, assert
     `bindPort == 9999` and `databaseUrl == "postgresql://override/db"` (env beats file).
   - *No-file case:* unset `SHOMEI_CONFIG`, call `loadConfig`, assert it returns the built-in
     defaults (port `8080`, default TTLs) — proving the turnkey path still works.
   Tests use `System.Environment` (`setEnv`/`unsetEnv`) and must reset env vars between cases
   (use `bracket` to restore), so they are order-independent and idempotent.

**Acceptance (M1).** From the repo root inside `nix develop`:

```bash
nix develop -c cabal test shomei-server-config-test
```

prints a passing test summary (three cases). And:

```bash
SHOMEI_CONFIG=config/shomei.example.dhall \
  nix develop -c cabal run shomei-server -- --print-config
```

prints the assembled config (if `shomei-server` grows a `--print-config` flag; otherwise the
test is the acceptance gate and this command is optional).

### Milestone 2 — Reproducible OCI image via the Nix flake

**Scope.** Produce an OCI image from the flake containing `shomei-server` and `shomei-admin`,
with an entrypoint that migrates, ensures an active signing key, then serves. Provide a plain
`Dockerfile` as an alternative.

**End state.** `nix build .#dockerImage` yields `./result` (an image tarball). `docker load <
result` then `docker run` (pointed at a PostgreSQL) shows the entrypoint applying migrations,
ensuring a key, and logging the listen address.

**Work.**

1. **The entrypoint script.** Create `deploy/entrypoint.sh` (committed, also embedded into the
   image):

   ```bash
   #!/usr/bin/env bash
   # Container entrypoint: prepare the database, ensure a signing key, then serve.
   # Configured entirely through SHOMEI_* environment variables and/or the Dhall file
   # at $SHOMEI_CONFIG, read by the same loader the binaries share (IP-6).
   set -euo pipefail

   echo "[entrypoint] applying database migrations…"
   shomei-admin migrate

   echo "[entrypoint] ensuring an active signing key exists…"
   if [ -z "$(shomei-admin keys list-active)" ]; then
     echo "[entrypoint] no active key; generating and activating one"
     kid="$(shomei-admin keys generate)"
     shomei-admin keys activate "$kid"
   else
     echo "[entrypoint] active signing key already present"
   fi

   echo "[entrypoint] starting shomei-server…"
   exec shomei-server
   ```

   Notes: `set -euo pipefail` aborts on any failure (so a failed migration stops the boot).
   `exec` replaces the shell with the server so `SIGTERM` from `docker stop` reaches the
   server for graceful shutdown. The script is idempotent: `shomei-admin migrate` is a no-op
   if nothing is pending, and the key block only generates a key when none is active.

2. **The Nix image build (primary path).** In `flake.module.nix`, inside `perSystem`, add a
   `packages.dockerImage` attribute built with `pkgs.dockerTools.buildLayeredImage`:

   ```nix
   # flake.module.nix (excerpt) — build a reproducible OCI image from the flake.
   perSystem = { pkgs, config, ... }:
     let
       # The shomei-server / shomei-admin binaries. Built from the project's Haskell
       # package set. If building the multi-package workspace through Nix is awkward
       # (callCabal2nix assumes a single root .cabal — see Context), fall back to the
       # dev-shell build (Milestone 2, step 4) and copy the binaries in via
       # dockerTools.buildLayeredImage's `contents`. Record the chosen path in Surprises.
       shomeiBins = config.packages.shomei or (pkgs.callPackage ./deploy/shomei-bins.nix { });

       entrypoint = pkgs.writeShellApplication {
         name = "shomei-entrypoint";
         runtimeInputs = [ shomeiBins pkgs.bash ];
         text = builtins.readFile ./deploy/entrypoint.sh;
       };
     in {
       packages.dockerImage = pkgs.dockerTools.buildLayeredImage {
         name = "shomei-server";
         tag = "latest";
         contents = [ shomeiBins entrypoint pkgs.cacert ];  # cacert: TLS roots for SMTP
         config = {
           Entrypoint = [ "${entrypoint}/bin/shomei-entrypoint" ];
           ExposedPorts = { "8080/tcp" = { }; };
           Env = [ "SHOMEI_PORT=8080" "SHOMEI_BIND_HOST=0.0.0.0" ];
         };
       };
     };
   ```

   `buildLayeredImage` builds the image from Nix's pinned closure with no Docker daemon. The
   exact attribute that names the Haskell binaries depends on how the project exposes them
   through Nix; the build will tell you. Verify the function name/arguments against the pinned
   nixpkgs (`pkgs.dockerTools.buildLayeredImage`) and record any deviation in Surprises.

3. **The plain `Dockerfile` (documented alternative).** Create `Dockerfile` at the repo root:

   ```dockerfile
   # Plain multi-stage build — NOT the reproducible path (that is `nix build .#dockerImage`).
   # Provided for operators without Nix. The builder stage compiles inside the GHC image; the
   # runtime stage is a slim Debian with just the binaries and the entrypoint.
   FROM haskell:9.12.4 AS build
   WORKDIR /src
   COPY . .
   RUN cabal update && cabal build all
   RUN mkdir -p /out && \
       cp "$(cabal list-bin shomei-server)" /out/ && \
       cp "$(cabal list-bin shomei-admin)"  /out/

   FROM debian:stable-slim AS runtime
   RUN apt-get update && apt-get install -y --no-install-recommends \
         libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
   COPY --from=build /out/shomei-server /usr/local/bin/
   COPY --from=build /out/shomei-admin  /usr/local/bin/
   COPY deploy/entrypoint.sh /usr/local/bin/shomei-entrypoint
   RUN chmod +x /usr/local/bin/shomei-entrypoint
   EXPOSE 8080
   ENV SHOMEI_PORT=8080 SHOMEI_BIND_HOST=0.0.0.0
   ENTRYPOINT ["/usr/local/bin/shomei-entrypoint"]
   ```

   Document in a comment that this path is *not* byte-for-byte reproducible (it depends on
   upstream Debian/Hackage state) and exists only for Nix-less environments. The `codd`/
   `ephemeral-pg`/`jose` git pins in `cabal.project` are fetched by `cabal` inside the builder.

4. **Fallback binary build (if the Nix Haskell build is awkward).** If exposing the
   multi-package workspace through Nix proves troublesome (because `callCabal2nix` assumes a
   single root `.cabal`), create `deploy/shomei-bins.nix` that builds the binaries by invoking
   `cabal` inside a fixed-output derivation, or simply have `dockerImage` copy binaries
   produced by `cabal build all` in the dev shell. State clearly which path you took and why
   in the Decision Log; the *primary* goal is a working, reproducible-as-possible image, and
   the `dockerTools` layering already guarantees the runtime layers are reproducible even if
   the compile step is staged.

**Acceptance (M2).** From the repo root:

```bash
nix build .#dockerImage
docker load < result
# start a throwaway postgres for the smoke test
docker run -d --name shomei-pg -e POSTGRES_USER=shomei -e POSTGRES_PASSWORD=shomei \
  -e POSTGRES_DB=shomei -p 5432:5432 postgres:16
docker run --rm --network host \
  -e SHOMEI_DATABASE_URL=postgresql://shomei:shomei@localhost:5432/shomei \
  shomei-server:latest 2>&1 | head -20
```

Expected (order matters — migrate, then key, then serve):

```text
[entrypoint] applying database migrations…
[entrypoint] ensuring an active signing key exists…
[entrypoint] no active key; generating and activating one
[entrypoint] starting shomei-server…
[shomei] listening on :8080
```

Re-running the same `docker run` is idempotent: the second time it prints
`[entrypoint] active signing key already present` and migrations are a no-op.

### Milestone 3 — `docker compose` stack with health/readiness gating

**Scope.** A `docker-compose.yaml` bringing up PostgreSQL + `shomei-server`, wired by env/
config, with healthchecks on `/health` (liveness) and `/ready` (readiness) and
`depends_on … condition: service_healthy` so the server waits for a healthy database. Prove a
real signup + login over `curl`.

**End state.** `docker compose up` yields a server reachable at `http://localhost:8080`;
`curl` of signup and login returns tokens.

**Work.** Create `docker-compose.yaml` at the repo root:

```yaml
# docker-compose.yaml — local/production-like stack: PostgreSQL + shomei-server.
# Brings the server up only after the database is healthy; reports the server healthy
# only once /ready answers (its DB is reachable and an active key is loaded).
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: shomei
      POSTGRES_PASSWORD: shomei
      POSTGRES_DB: shomei
    ports:
      - "5432:5432"
    healthcheck:
      # pg_isready exits 0 once PostgreSQL accepts connections.
      test: ["CMD-SHELL", "pg_isready -U shomei -d shomei"]
      interval: 5s
      timeout: 3s
      retries: 10
    volumes:
      - shomei-pgdata:/var/lib/postgresql/data

  shomei-server:
    image: shomei-server:latest        # produced by `nix build .#dockerImage` + `docker load`
    depends_on:
      postgres:
        condition: service_healthy      # wait for a healthy DB before the entrypoint runs
    environment:
      SHOMEI_DATABASE_URL: postgresql://shomei:shomei@postgres:5432/shomei
      SHOMEI_BIND_HOST: 0.0.0.0
      SHOMEI_PORT: "8080"
      SHOMEI_ISSUER: https://auth.example.com
      SHOMEI_AUDIENCE: example-api
    ports:
      - "8080:8080"
    healthcheck:
      # /ready is the readiness probe (EP-3): 200 only when the server can serve.
      test: ["CMD-SHELL", "curl -fsS http://localhost:8080/ready || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 20s                 # allow time for migrate + key bootstrap

volumes:
  shomei-pgdata:
```

Notes: the server image must contain `curl` for its own healthcheck — if the Nix image is
minimal, add `pkgs.curl` to `contents` in `flake.module.nix`, or use a healthcheck that
shells out to the server binary instead. The `start_period` gives the entrypoint time to run
migrations and bootstrap the key before failing health checks count against the container.
`/health` is used as the liveness signal (the process is up); `/ready` (EP-3) gates traffic.

Add convenience recipes to the `Justfile`:

```text
# Build the OCI image via Nix and load it into the local Docker daemon.
docker-build:
    nix build .#dockerImage
    docker load < result

# Bring up the full stack (PostgreSQL + shomei-server).
compose-up:
    docker compose up

# Tear it down and remove the database volume.
compose-down:
    docker compose down -v
```

**Acceptance (M3).** From the repo root:

```bash
just docker-build
docker compose up -d
# wait for the server to report ready
until curl -fsS http://localhost:8080/ready >/dev/null 2>&1; do sleep 2; done
```

then drive a real signup and login:

```bash
curl -fsS -X POST http://localhost:8080/auth/signup \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"correct horse battery staple"}'
```

Expected (a JSON body containing an access token and a refresh token; exact field names per
MasterPlan 1's `SignupRequest`/`LoginResponse` conventions):

```json
{"accessToken":"eyJ...","refreshToken":"...","tokenType":"Bearer"}
```

then:

```bash
curl -fsS -X POST http://localhost:8080/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com","password":"correct horse battery staple"}'
```

Expected: HTTP 200 with the same token-bearing JSON shape. Tear down with `docker compose
down -v`. The stack is reproducible: `docker compose up` from a clean volume always migrates,
bootstraps a key, and serves.

### Milestone 4 — CI pipeline (build + test + format check)

**Scope.** A GitHub Actions workflow that, inside the Nix environment, runs `cabal build all`,
`cabal test all` (including the `ephemeral-pg`-backed integration tests), and a format check.

**End state.** `.github/workflows/ci.yaml` exists and is green on push/PR.

**Work.** Create `.github/workflows/ci.yaml`:

```yaml
# .github/workflows/ci.yaml — build, test, and format-check Shōmei inside Nix.
name: CI

on:
  push:
    branches: [master]
  pull_request:

jobs:
  build-test-fmt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Install Nix with flakes enabled.
      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes

      # Cache the cabal store and dist-newstyle across runs to speed up builds.
      - uses: actions/cache@v4
        with:
          path: |
            ~/.cabal/store
            dist-newstyle
          key: cabal-${{ runner.os }}-${{ hashFiles('cabal.project', '**/*.cabal') }}
          restore-keys: cabal-${{ runner.os }}-

      - name: Build all packages
        run: nix develop -c cabal build all

      # The integration tests provision their OWN throwaway PostgreSQL via ephemeral-pg
      # (through shomei-migrations:test-support), so NO GitHub `services:` postgres is
      # needed. ephemeral-pg runs initdb + a per-test server inside the test process.
      - name: Run the test suites
        run: nix develop -c cabal test all

      # treefmt (`nix fmt`) wraps nixpkgs-fmt + fourmolu + cabal-fmt. --fail-on-change makes
      # CI fail if any file is not already formatted (it does not rewrite the tree in CI).
      - name: Format check
        run: nix fmt -- --fail-on-change
```

Notes: `ephemeral-pg` needs the `initdb`/`postgres` binaries at runtime; they are already in
the dev shell (`nix/haskell.nix` adds `pkgs.postgresql` to `baseDevPackages`), so running the
tests through `nix develop -c …` provides them — this is exactly why CI runs everything inside
the Nix shell. If `nix fmt -- --fail-on-change` is not the exact treefmt invocation the pinned
version supports, use `nix develop -c treefmt --fail-on-change` instead and record it in
Surprises. Confirm the `cachix/install-nix-action` version against the current marketplace and
bump if needed.

**Acceptance (M4).** Push a branch and open a PR; the `build-test-fmt` job goes green. Locally,
the same three commands succeed:

```bash
nix develop -c cabal build all
nix develop -c cabal test all
nix fmt -- --fail-on-change
```

### Versioning / release (lightweight)

Create `CHANGELOG.md` at the repo root following "Keep a Changelog" style (an `## [Unreleased]`
section plus dated released sections). The `version:` field in each package's `.cabal` (all
`0.1.0.0` today) is the source of truth. A release is: bump the `version:` fields, move
`Unreleased` entries under a new `## [X.Y.Z] - DATE` heading, commit, and tag `git tag vX.Y.Z`.
No Hackage upload, no automated release pipeline — the flake pins every dependency, so a tag
plus the committed `flake.lock` is enough to rebuild any released image.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` unless noted, inside the Nix dev
shell (entered by `nix develop`, or automatically via `direnv` from `.envrc`).

### Step 1 — append the `dhall` block to `cabal.project`

Edit `cabal.project`. Under the existing comment
`-- DEPENDENCY OVERRIDES — each plan appends its own block; none rewrites another's.`, append:

```cabal
-- ============================================================
-- EP-5 (packaging/config): the Dhall configuration loader uses the `dhall`
-- library. dhall 1.42.x is on Hackage and declares base < 5, so no git pin is
-- needed; this block exists to document EP-5's ownership and to hold any
-- allow-newer the solver requires on GHC 9.12.4. Add such entries HERE only.
-- ============================================================
```

Then confirm it solves and builds:

```bash
nix develop -c cabal build shomei-server
```

Expected: cabal downloads and builds `dhall` and its transitive deps, then `shomei-server`,
exit 0. If the solver complains about a transitive bound, add the minimal `allow-newer:`
under the EP-5 comment and re-run; record it in Surprises.

### Step 2 — extend `shomei-server.cabal`

Add `dhall` to the `library` `build-depends`, and add the config test-suite. Show the exact
diff you make so it is reproducible:

```cabal
library
  -- … existing fields …
  build-depends:
    , base             >=4.18 && <5
    , dhall
    , shomei-core
    , shomei-jwt
    , shomei-postgres
    , shomei-servant
    , text

test-suite shomei-server-config-test
  imeffect:         warnings, shared
  type:           exitcode-stdio-1.0
  main-is:        Main.hs
  hs-source-dirs: test
  other-modules:  Shomei.Server.ConfigSpec
  build-depends:
    , base
    , dhall
    , hspec
    , shomei-core
    , shomei-server
    , text
```

(Use the repo's established test framework; if MasterPlan 1's `shomei-server-test` used
`tasty`/`hspec`, match it.)

### Step 3 — write `Shomei.Server.Config`

Edit `shomei-server/src/Shomei/Server/Config.hs` per Milestone 1, work item 3. The
loader's public surface at the end of this step:

```haskell
module Shomei.Server.Config
  ( DeploymentSettings (..)
  , SigningKeySource (..)
  , loadConfig          -- IO (ShomeiConfig, DeploymentSettings)  -- Dhall + env
  , loadConfigFromEnv   -- IO (ShomeiConfig, DeploymentSettings)  -- env only (no file)
  , defaultDeploymentSettings
  ) where
```

### Step 4 — create the `config/` Dhall files and gitignore the live copy

```bash
mkdir -p config
# author config/shomei-types.dhall and config/shomei.example.dhall (see Milestone 1)
printf '\n# Local runtime config (never commit secrets)\nconfig/shomei.dhall\n' >> .gitignore
cp config/shomei.example.dhall config/shomei.dhall   # operator's working copy
```

### Step 5 — write the test and run it

Author `shomei-server/test/Shomei/Server/ConfigSpec.hs` (and a `test/Main.hs` runner)
per Milestone 1, work item 5, then:

```bash
nix develop -c cabal test shomei-server-config-test
```

Expected tail:

```text
Finished in 0.0123 seconds
3 examples, 0 failures
```

### Step 6 — entrypoint + Nix image

Author `deploy/entrypoint.sh` and the `flake.module.nix` `dockerImage` attribute (Milestone 2,
items 1–2), then:

```bash
nix build .#dockerImage
docker load < result
```

Expected: `docker load` prints `Loaded image: shomei-server:latest`.

### Step 7 — Dockerfile alternative

Author the root `Dockerfile` (Milestone 2, item 3). Smoke-build only when on a non-Nix host;
it is the documented alternative, not the primary path.

### Step 8 — compose stack + curl transcript

Author `docker-compose.yaml` and the `Justfile` recipes (Milestone 3), then run the M3
acceptance block and paste the real `curl` signup/login transcript into this section as
evidence once it passes.

### Step 9 — CI workflow

Author `.github/workflows/ci.yaml` (Milestone 4), push a branch, open a PR, and confirm green.

### Step 10 — CHANGELOG + version policy

Author `CHANGELOG.md` and confirm each `.cabal`'s `version:` field. No tag is created by this
plan unless the user asks for a release.


## Validation and Acceptance

Acceptance is behavioral, not "the code compiles." Each item below names inputs and the
output to observe.

1. **Config loader (M1).** `nix develop -c cabal test shomei-server-config-test` passes all
   three cases. The env-override case proves precedence: with
   `SHOMEI_CONFIG=config/shomei.example.dhall` and `SHOMEI_PORT=9999`, `loadConfig` returns
   `bindPort == 9999` (env beats the file's `8080`). The no-file case proves the turnkey path:
   with `SHOMEI_CONFIG` unset, `loadConfig` returns the built-in defaults.

2. **Shared loader (M1).** Both `shomei-server` and `shomei-admin` call `loadConfig`. Confirm
   by grepping the two `main`s; a quick behavioral check: run `shomei-admin migrate` with only
   `SHOMEI_DATABASE_URL` set and it connects to the right database (the same one
   `shomei-server` would), proving they share the loader.

3. **OCI image (M2).** `nix build .#dockerImage && docker load < result` loads
   `shomei-server:latest`. `docker run` against a PostgreSQL logs, in order, migration →
   key-ensure → `listening on :8080`. A second run logs `active signing key already present`
   (idempotent).

4. **Compose stack (M3).** `docker compose up` brings up both services; the server's
   healthcheck flips healthy only after `/ready` returns 200; a `curl` signup returns a token
   JSON body and a subsequent `curl` login returns HTTP 200 with tokens. This is the
   end-to-end proof the stack works.

5. **CI (M4).** The GitHub Actions `build-test-fmt` job is green: build, test (including the
   `ephemeral-pg` integration tests), and `nix fmt --fail-on-change` all succeed.


## Idempotence and Recovery

- **Config files.** Creating `config/*.dhall` and editing `cabal.project`/`shomei-server.cabal`
  are plain file edits; re-running the steps overwrites with identical content (a no-op for
  the build beyond a possible recompile). The live `config/shomei.dhall` is gitignored, so
  re-copying the example never clobbers committed state.
- **The loader.** `loadConfig` is pure-ish IO (reads a file + env); calling it repeatedly is
  safe and side-effect-free. Tests restore env vars with `bracket`, so re-running the suite is
  order-independent.
- **The entrypoint.** Idempotent by construction: `shomei-admin migrate` is a no-op when
  nothing is pending; the key block generates a key only when none is active. Restarting the
  container is safe.
- **The image build.** `nix build .#dockerImage` is reproducible; re-running yields the same
  image (same store path). `docker load` of the same tarball is a no-op.
- **The compose stack.** `docker compose up` is repeatable; `docker compose down -v` removes
  the database volume for a clean slate. If the server container crash-loops, inspect
  `docker compose logs shomei-server` — the most common cause is an unreachable database
  (check `SHOMEI_DATABASE_URL` and that postgres is healthy) or the entrypoint failing a
  migration (the logs name the failing migration).
- **CI.** The workflow is read-only with respect to the repo (it does not push). A failed run
  is safe to re-run; the cabal-store cache only speeds things up and never blocks correctness.
- **Recovery from a broken `flake.module.nix`.** If `nix build .#dockerImage` fails to
  evaluate, the Nix error names the offending line. Fix it and retry; the dev shell and
  `nix develop` remain usable because the image attribute is additive and does not touch the
  shell definition.


## Interfaces and Dependencies

### Libraries and tools

- **`dhall`** (Hackage, 1.42.x, `base < 5` → GHC-9.12-compatible) — typed config parsing.
  Entry points used: `Dhall.input :: Decoder a -> Text -> IO a`,
  `Dhall.inputFile :: FromDhall a => Decoder a -> FilePath -> IO a`, `Dhall.auto`,
  `Dhall.genericAutoWith`, `Dhall.defaultInterpretOptions`, the `Dhall.FromDhall` class, and
  `Dhall.InputSettings` with the `rootDirectory` lens (to resolve relative Dhall imports).
  Instances relied on: `FromDhall Text/Bool/Natural/Int/Double` and `FromDhall a => FromDhall
  (Maybe a)` (all confirmed present in the on-disk source).
- **`pkgs.dockerTools.buildLayeredImage`** (nixpkgs, via the flake) — reproducible OCI image
  build with no Docker daemon. `pkgs.writeShellApplication` — wraps `deploy/entrypoint.sh`
  with its `runtimeInputs` on `PATH`. `pkgs.cacert` — TLS root certificates (for the SMTP
  sender). Optionally `pkgs.curl` for the container healthcheck.
- **`docker` / `docker compose`** — runtime; only needed to *run* the image and stack, not to
  build the Nix image.
- **GitHub Actions** + `cachix/install-nix-action` — CI host and Nix installer.
- **`ephemeral-pg`** — already in the test stack (via `shomei-migrations:test-support`);
  provides each integration test its own throwaway PostgreSQL, so CI needs no DB service.

### Types and signatures that must exist at the end of each milestone

- End of **M1**, in `shomei-server/src/Shomei/Server/Config.hs`:

  ```haskell
  data DeploymentSettings = DeploymentSettings
    { databaseUrl      :: !Text
    , bindHost         :: !Text
    , bindPort         :: !Int
    , poolSize         :: !Int
    , signingKeySource :: !SigningKeySource
    , configFile       :: !(Maybe FilePath)
    }

  data SigningKeySource
    = SigningKeyFromDatabase
    | SigningKeyFromFile !FilePath !(Maybe Text)   -- path, optional passphrase (env-only)

  loadConfig          :: IO (ShomeiConfig, DeploymentSettings)
  loadConfigFromEnv   :: IO (ShomeiConfig, DeploymentSettings)
  defaultDeploymentSettings :: DeploymentSettings
  ```

  plus a private `FileConfig` record with `instance FromDhall FileConfig`, all fields
  `Maybe`, mirroring the Dhall schema in `config/shomei-types.dhall`.

- End of **M2**: a flake attribute `packages.dockerImage` (build with
  `nix build .#dockerImage`) and a committed `deploy/entrypoint.sh`.
- End of **M3**: a committed `docker-compose.yaml`; `docker compose up` serves the API.
- End of **M4**: a committed `.github/workflows/ci.yaml` that is green.

### Integration points

- **IP-6 (owned by this plan):** the single typed configuration loader. Contract: `loadConfig
  :: IO (ShomeiConfig, DeploymentSettings)` reading Dhall (`$SHOMEI_CONFIG`) then env
  (`SHOMEI_*`), used by *both* `shomei-server` and `shomei-admin`. This supersedes MasterPlan
  1 EP-6's / MasterPlan 2 EP-4's env-only loader; the env-only behavior remains available as
  `loadConfigFromEnv` (and `loadConfig` with `SHOMEI_CONFIG` unset).
- **IP-3 (consumed):** `ShomeiConfig` in `shomei-core/src/Shomei/Config.hs`. The
  loader populates the *fully-extended* record (MasterPlan-1 fields plus whichever of
  EP-1/EP-2/EP-3's sub-records have landed). It never edits the record type — `shomei-core`
  owns it.
- **IP-8 (consumed/extended):** `cabal.project`. This plan appends an EP-5 `dhall` block under
  the shared "each plan appends its own block" comment; it rewrites no other block.
- **EP-4 (`shomei-admin`) — hard dependency:** the entrypoint invokes `shomei-admin migrate`
  and `shomei-admin keys {list-active,generate,activate}`. The contract is reproduced in
  Context; reconcile against EP-4's actual spelling when it lands and record any change in the
  Decision Log.


## Revision Notes

- 2026-06-04 — Initial authoring. Fleshed out the skeleton into a full EP-5 plan: the typed
  Dhall+env config loader (IP-6) in `Shomei.Server.Config`, superseding MasterPlan 1 EP-6's
  env-only `loadConfig` while keeping `loadConfigFromEnv`; the reproducible OCI image via
  `pkgs.dockerTools.buildLayeredImage` in `flake.module.nix` with a migrate-then-ensure-key
  entrypoint (hard dependency on EP-4's `shomei-admin`); the `docker-compose.yaml` with
  `/health`/`/ready` gating; the GitHub Actions Nix CI workflow; and a lightweight
  versioning/changelog policy. Reasoning for every choice is recorded in the Decision Log.
  Verified the `dhall` 1.42.3 API surface (`input`/`inputFile`/`auto`/`genericAutoWith`/
  `FromDhall`) and `base < 5` bound against the on-disk source via `mori`. Noted the soft
  dependence on EP-1/EP-2/EP-3 for the fully-extended `ShomeiConfig` and the procedure if any
  has not yet landed.
- 2026-06-04 — Updated after the package-layout refactor and MasterPlan audit. Package paths
  now refer to top-level directories, package descriptions use effect-interface terminology,
  and the configuration milestone now extends the existing `Shomei.Server.Config` module
  instead of authoring it from scratch.
