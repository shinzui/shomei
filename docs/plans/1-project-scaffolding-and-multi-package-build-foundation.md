---
id: 1
slug: project-scaffolding-and-multi-package-build-foundation
title: "Project scaffolding and multi-package build foundation"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# Project scaffolding and multi-package build foundation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan executes, the Shōmei repository is a buildable, multi-package Cabal
workspace. A developer who runs `nix develop` lands in a shell with GHC 9.12.4,
`cabal-install`, HLS, `fourmolu`, and `cabal-fmt` ready, can type `cabal build all` and
see all seven packages compile without errors, and can run `just build` as a shorthand.
The shared `Shomei.Prelude` module lives in `shomei-core` and is importable by every
other package. Formatting via `nix fmt` (treefmt) is wired and runs clean on the new
sources. Every subsequent plan (EP-2 through EP-8) therefore has a buildable skeleton to
add into, rather than starting from scratch.

This plan has no upstream dependencies: it is the foundation that all other plans depend
on. It corresponds to Integration Points IP-1 (Shomei.Prelude) and IP-8 (cabal.project +
common stanzas) in the MasterPlan.


## Progress

- [x] M1 — Create `cabal.project` at repo root (2026-06-03)
- [x] M1 — Create `shomei-core/shomei-core.cabal` (full common stanzas, Shomei.Prelude + placeholder) (2026-06-03)
- [x] M1 — Create `shomei-jwt/shomei-jwt.cabal` (2026-06-03)
- [x] M1 — Create `shomei-postgres/shomei-postgres.cabal` (2026-06-03)
- [x] M1 — Create `shomei-migrations/shomei-migrations.cabal` (2026-06-03)
- [x] M1 — Create `shomei-servant/shomei-servant.cabal` (2026-06-03)
- [x] M1 — Create `shomei-server/shomei-server.cabal` (2026-06-03)
- [x] M1 — Create `shomei-client/shomei-client.cabal` (2026-06-03)
- [x] M1 — Create trivial placeholder source files for all packages (2026-06-03)
- [x] M1 — Verify `nix develop -c cabal build all` is green (2026-06-03)
- [x] M2 — Create `shomei-core/src/Shomei/Prelude.hs` with full content (2026-06-03)
- [x] M2 — Create `shomei-jwt/src/Shomei/JWT/Placeholder.hs` importing `Shomei.Prelude` (2026-06-03)
- [x] M2 — Verify cross-package prelude import compiles (2026-06-03; `cabal repl shomei-jwt` shows `exampleText :: Text`)
- [x] M3 — Create `flake.module.nix` from example, adding `cabal-install`, `fourmolu`, `cabal-fmt` (2026-06-03; also wires treefmt — see Surprises/Decision Log)
- [x] M3 — Create minimal `Justfile` with `build` and stub `create-database` (2026-06-03)
- [x] M3 — Verify `nix develop -c fourmolu --version` (2026-06-03; fourmolu 0.19.0.1, cabal-fmt 0.1.12, cabal 3.16.1.0)
- [x] M3 — Verify `nix fmt` runs clean (2026-06-03; idempotent — second run reports 0 changed)
- [x] M3 — Verify `just build` succeeds (2026-06-03)
- [x] All milestones — Commit with required git trailers (2026-06-03; commits `fe883c6` docs, `c1d58f0` scaffold)


## Surprises & Discoveries

- **`nix fmt` was NOT wired out of the box; the plan's M3 assumption was wrong.** The
  seihou-generated `flake.nix` imports only `./nix/haskell.nix` and `./flake.module.nix`
  (when present). It does **not** import `./nix/treefmt.nix`, and `treefmt-nix` is not a
  top-level flake input. So `nix fmt` failed with:

  ```text
  error: flake 'git+file:///Users/shinzui/Keikaku/bokuno/shomei' does not provide
  attribute 'formatter.aarch64-darwin'
  ```

  `nix/treefmt.nix` cannot simply be imported either, because it references
  `inputs.treefmt-nix.flakeModule`, and `treefmt-nix` only exists transitively (under
  `haskell-nix-dev.inputs.treefmt-nix`), not as a root input. Evidence:

  ```text
  $ nix flake metadata --json | jq '.locks.nodes.root.inputs|keys[]'
  flake-parts
  haskell-nix-dev
  nixpkgs
  $ nix flake metadata --json | jq '... haskell-nix-dev ... .inputs|keys[]'
  flake-utils
  nixpkgs
  treefmt-nix
  ```

  Resolution (see Decision Log): wire treefmt entirely from the unmanaged
  `flake.module.nix` by importing
  `inputs.haskell-nix-dev.inputs.treefmt-nix.flakeModule` and inlining the formatter
  config — no edits to any seihou-managed file and no new top-level flake input.

- **treefmt formats the whole tree, including seihou-managed Nix files.** The first
  `nix fmt` reformatted `nix/pre-commit.nix` (a seihou-managed file we must not change),
  which also broke idempotence. Fixed by excluding `nix/*` and `flake.nix` from treefmt
  via `settings.global.excludes`. After this, `nix fmt && nix fmt` is clean (second run:
  `formatted 0 files (0 changed)`).

- **Tool versions differ from the plan's guesses (harmless).** The plan guessed fourmolu
  `0.16.x`; the pinned nixpkgs provides fourmolu `0.19.0.1` (ghc-lib-parser 9.12.3),
  cabal-fmt `0.1.12`, and cabal `3.16.1.0`. The fourmolu 0.19 default style (4-space
  indent, `{- | -}` haddock blocks, leading-comma import/export lists) reformatted all the
  hand-written sources in this plan; that formatter output is now the source of truth.

- **A pre-existing, out-of-scope edit to `mori.dhall` is present in the working tree** (it
  adds `frasertweedale/hs-jose` and `jappeace/ram` to the dependency registry, matching the
  MasterPlan's EP-4 decisions). It was not made by this plan and EP-1 defers `mori.dhall`
  edits to EP-3/EP-7, so it was left unstaged and out of EP-1's commit.


## Decision Log

- Decision: Use `cabal.project` multi-package workspace rather than a single root `.cabal` file.
  Rationale: `mori.dhall` already declares six packages under `packages/<name>` with
  cross-package dependencies. A multi-package workspace is the idiomatic Cabal approach
  and the only design that scales. Each package can evolve, be published, or be tested
  independently.
  Date: 2026-06-03

- Decision: Repeat the `common warnings` and `common shared` stanzas in every `.cabal`
  file rather than factoring them into a shared include.
  Rationale: Cabal's `common` stanzas are per-file; there is no cross-file sharing
  mechanism without a preprocessor. The house convention (derived from kizashi) is
  explicit repetition. This keeps each `.cabal` self-contained and readable.
  Date: 2026-06-03

- Decision: Rely on `cabal build all` inside `nix develop` as the primary build path for
  the bootstrap; do not fix `packages.default = callCabal2nix "shomei" inputs.self {}`.
  Rationale: `callCabal2nix` assumes a single `.cabal` at the repo root. Fixing it for a
  multi-package workspace requires either `haskell.lib.buildFromCabalSdist` with a
  cabal-project, or building each package separately. That complexity belongs to a
  Nix-packaging plan, not the bootstrap. The dev shell (`nix develop`) already provides a
  full Haskell environment; `cabal build all` inside it is the standard workflow. The
  current `packages.default` attribute will fail for the multi-package layout — we leave
  it in place (it is seihou-managed and we must not edit `nix/haskell.nix`) but document
  that `nix build` is not supported until a later plan fixes or replaces it. Developers
  must use `nix develop` + `cabal build all`.
  Date: 2026-06-03

- Decision: Create the `shomei-migrations` package skeleton in EP-1 (EP-3 fills it).
  Rationale: `cabal.project` must list all packages from the start so that future
  `cabal build all` invocations include the migrations binary. Adding a new package later
  requires touching `cabal.project`, which EP-3 also touches for source-repository-package
  blocks — leaving the package out would create a confusing gap. The stub is trivial (one
  source file, one executable) and costs nothing.
  Date: 2026-06-03

- Decision: Add `cabal-install`, `fourmolu`, and `cabal-fmt` via `flake.module.nix` rather
  than editing `nix/haskell.nix`.
  Rationale: `nix/haskell.nix` is seihou-managed and must not be hand-edited. The
  `flake.module.nix` extension mechanism exists precisely for project-specific dev
  tooling. The example file shows the `haskellProject.extraDevPackages` option.
  Date: 2026-06-03

- Decision: Do not add treefmt/fourmolu/cabal-fmt configuration to `nix/treefmt.nix`;
  it already enables all three (`programs.nixpkgs-fmt.enable`, `programs.fourmolu.enable`,
  `programs.cabal-fmt.enable`). No further configuration is required.
  Date: 2026-06-03

- Decision (revised during implementation): Wire `nix fmt` (treefmt) from the unmanaged
  `flake.module.nix`, not by relying on `nix/treefmt.nix`.
  Rationale: The plan assumed `nix fmt` already worked because `nix/treefmt.nix` enables the
  three formatters. In reality `flake.nix` never imports `nix/treefmt.nix`, and `treefmt-nix`
  is not a top-level input, so `nix fmt` had no formatter (see Surprises). Importing
  `nix/treefmt.nix` directly is impossible (it needs `inputs.treefmt-nix`, which is only
  transitive). The fix reaches the treefmt flake module via
  `inputs.haskell-nix-dev.inputs.treefmt-nix.flakeModule` and inlines the same formatter
  config in `flake.module.nix`. This keeps every seihou-managed file untouched and adds no
  new top-level flake input. If seihou later wires treefmt in `flake.nix`, flake-parts
  module merging makes the duplicate import/config idempotent.
  Date: 2026-06-03

- Decision: Exclude `nix/*` and `flake.nix` from treefmt (`settings.global.excludes`).
  Rationale: treefmt formats the entire tree; the pinned nixpkgs-fmt version wanted to
  rewrite the seihou-managed `nix/pre-commit.nix`, which we must not edit, and that also
  broke `nix fmt` idempotence. seihou owns and formats its own Nix files; the project
  formatter should not fight it. After excluding them, `nix fmt && nix fmt` is clean.
  Date: 2026-06-03


## Outcomes & Retrospective

**Achieved (2026-06-03).** The empty repository is now a buildable seven-package Cabal
workspace. `nix develop -c cabal build all` (and `just build`) compiles all of
`shomei-core`, `shomei-jwt`, `shomei-postgres`, `shomei-migrations`, `shomei-servant`,
`shomei-server`, and `shomei-client`, and links the `shomei-server` and `shomei-migrate`
executables. The `Shomei.Prelude` module (IP-1) lives in `shomei-core` and is provably
importable across the package boundary — `cabal repl shomei-jwt` shows
`exampleText :: Text` evaluating to `"shomei-jwt placeholder"`. The `cabal.project` (IP-8)
pins GHC 9.12.4 and carries the labelled placeholder section for EP-3/EP-4 dependency
overrides. `flake.module.nix` adds `cabal-install`, `fourmolu`, and `cabal-fmt` to the dev
shell and wires `nix fmt`; the running stubs print their banners.

All six acceptance criteria pass: (1) workspace compiles; (2) prelude importable
cross-package; (3) dev tooling present (fourmolu 0.19.0.1, cabal-fmt 0.1.12, cabal
3.16.1.0); (4) `nix fmt` clean and idempotent; (5) `just build` works; (6) both stubs run.

**Deviations from the plan.** The single material deviation was that `nix fmt` was not
actually wired (the plan assumed it was). It was wired from the unmanaged
`flake.module.nix` using the transitively-available `treefmt-nix`, and seihou-managed Nix
files were excluded from treefmt to preserve idempotence (see Decision Log and Surprises).
No seihou-managed file (`flake.nix`, `nix/*.nix`) was edited.

**Known limitations (expected, documented).** `nix build` remains broken because
`nix/haskell.nix` uses `callCabal2nix "shomei" inputs.self {}`, which assumes a single root
`.cabal` file; `nix develop` + `cabal build all` is the supported workflow until a later
plan addresses Nix packaging. The fourmolu 0.19 default style is now the source-of-truth
formatting for all Haskell sources.

**For the next contributor (EP-2 onward).** Add domain modules to `shomei-core` importing
`Shomei.Prelude` (never `Prelude`). Do not modify `cabal.project` except through the
designated EP-3/EP-4 placeholder section. Run `nix fmt` before committing; it only touches
project sources now. The pre-existing `mori.dhall` edit (adding `hs-jose`/`ram`) is left in
the working tree for EP-3/EP-4 to own.


## Context and Orientation

**Glossary**

- *Shōmei (証明)* — the Haskell authentication toolkit being built. The name means
  "proof" or "certificate" in Japanese.
- *cabal workspace* — a directory containing a `cabal.project` file that lists multiple
  Cabal packages. All packages are built together with `cabal build all`.
- *common stanza* — a named block in a `.cabal` file (e.g. `common warnings`) that
  collects shared settings; other stanzas import it with `import: warnings`.
- *GHC2024* — a language edition bundled in GHC 9.10+. It enables many modern extensions
  by default: `DataKinds`, `DerivingStrategies`, `LambdaCase`, `ImportQualifiedPost`,
  `MonoLocalBinds`, and more. Setting `default-language: GHC2024` in a common stanza
  applies it project-wide.
- *seihou-managed* — files generated and maintained by the `seihou` toolchain
  (`flake.nix`, `nix/*.nix`). Do not hand-edit these files; changes will be overwritten
  on the next `seihou run`.
- *flake.module.nix* — the one file that is intentionally NOT managed by seihou. It is
  the conflict-free place for project-specific Nix customizations. It is imported
  automatically by `flake.nix` when it exists.
- *IP-1, IP-8* — Integration Points defined in the MasterPlan
  (`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`). IP-1 is the
  `Shomei.Prelude` module; IP-8 is the shared `cabal.project` + common stanza baseline.
- *treefmt* — a formatter runner (`nix fmt`) that applies `nixpkgs-fmt`, `fourmolu`, and
  `cabal-fmt` in one pass.

**Current repository state**

Working directory: `/Users/shinzui/Keikaku/bokuno/shomei`. Branch: `master`.

Key files already present:

| Path | Status | Notes |
|---|---|---|
| `flake.nix` | seihou-managed | imports `./nix/haskell.nix` and optional `./flake.module.nix` |
| `nix/haskell.nix` | seihou-managed | pins GHC 9.12.4; `packages.default = callCabal2nix "shomei"` (single-package assumption — see Decision Log) |
| `nix/treefmt.nix` | seihou-managed | enables `nixpkgs-fmt`, `fourmolu`, `cabal-fmt` via treefmt-nix |
| `nix/pre-commit.nix` | seihou-managed | git-hooks module; hooks section is currently empty |
| `flake.module.nix.example` | template | shows `haskellProject.extraDevPackages`; copy to `flake.module.nix` |
| `mori.dhall` | present | declares 6 packages with paths + inter-deps |
| `process-compose.yaml` | present | starts postgres; runs `just create-database` |
| `docs/initial-spec.md` | present | full technical spec (reference) |

Files this plan creates (none exist yet):

| Path | What it is |
|---|---|
| `cabal.project` | workspace root listing all 7 packages |
| `shomei-core/shomei-core.cabal` | core library cabal |
| `shomei-core/src/Shomei/Prelude.hs` | shared custom prelude (IP-1) |
| `shomei-core/src/Shomei/Core/Placeholder.hs` | trivial placeholder |
| `shomei-jwt/shomei-jwt.cabal` | jwt library cabal |
| `shomei-jwt/src/Shomei/JWT/Placeholder.hs` | imports Shomei.Prelude |
| `shomei-postgres/shomei-postgres.cabal` | postgres library cabal |
| `shomei-postgres/src/Shomei/Postgres/Placeholder.hs` | trivial placeholder |
| `shomei-migrations/shomei-migrations.cabal` | migrations executable cabal |
| `shomei-migrations/app/Main.hs` | stub migrate main |
| `shomei-servant/shomei-servant.cabal` | servant library cabal |
| `shomei-servant/src/Shomei/Servant/Placeholder.hs` | trivial placeholder |
| `shomei-server/shomei-server.cabal` | server executable cabal |
| `shomei-server/app/Main.hs` | banner-printing main |
| `shomei-server/src/Shomei/Server/Placeholder.hs` | trivial placeholder |
| `shomei-client/shomei-client.cabal` | client library cabal |
| `shomei-client/src/Shomei/Client/Placeholder.hs` | trivial placeholder |
| `flake.module.nix` | project-specific Nix additions (from example) |
| `Justfile` | `build` + stub `create-database` targets |

The inter-package dependency graph (from `mori.dhall`, plus migrations):

```text
shomei-core
  └── shomei-jwt          (→ core)
  └── shomei-postgres     (→ core)
  └── shomei-migrations   (→ core)   ← added in EP-1, filled by EP-3
  └── shomei-client       (→ core)
  └── shomei-servant      (→ core, jwt)
        └── shomei-server (→ core, jwt, postgres, servant)
```

**What `packages.default` does today and why it breaks**

`nix/haskell.nix` line 58:
```nix
packages.default = haskellPackages.callCabal2nix "shomei" inputs.self { };
```
`callCabal2nix` scans the flake source for a single `.cabal` file at its root. Once we
create `cabal.project` and subdirectory `.cabal` files (but no root `.cabal`), this
attribute will fail to evaluate. Because `nix/haskell.nix` is seihou-managed, we leave it
untouched. The consequence is that `nix build` is broken until a later plan addresses Nix
packaging. `nix develop` + `cabal build all` is the fully supported workflow for the
bootstrap phase.


## Plan of Work

### Milestone 1 — Workspace skeleton compiles

We create the cabal workspace from scratch. At the end of this milestone, `nix develop -c
cabal build all` succeeds and all seven packages are listed as built.

**Step 1: `cabal.project`**

Create `cabal.project` at the repo root. It lists all seven package directories and pins
the compiler. It also contains a clearly-labelled placeholder section for the
source-repository-package entries that later plans add: EP-3 (codd, ephemeral-pg) and EP-4
(jose pinned to PR #137, since the deprecated `memory`-based Hackage jose is forbidden — Shōmei
uses `ram`). Each plan appends its own block.

**Step 2: Seven `.cabal` files**

Each package gets a `.cabal` file with the two standard common stanzas (`warnings` and
`shared`) imported by every component. The `cabal-version: 3.0` and `default-language:
GHC2024` are set uniformly. Build-depends in each package match the dependency graph
above plus `base`.

For this milestone each package exposes exactly one trivial module so the graph compiles.
`shomei-core` exposes `Shomei.Core.Placeholder` (returning a string) and
`Shomei.Prelude` (which M2 will flesh out — for M1 it is a minimal re-export of `base`
that satisfies the module declaration without the full prelude content).
`shomei-server` additionally has an `executable shomei-server` component.
`shomei-migrations` has an `executable shomei-migrate` component (stub, EP-3 fills).

**Step 3: Trivial source files**

Each placeholder module contains only a package pragma, a module declaration, and a
single exported symbol (a string or `()`). This is enough for `cabal build all` to
succeed; actual logic comes in EP-2 through EP-8.

### Milestone 2 — Custom prelude + conventions wired

Replace the M1 stub of `Shomei.Prelude` with the full content (specified below). Add a
tiny module to `shomei-jwt` that imports `Shomei.Prelude` and uses `Text` to prove
cross-package use. Verify that `cabal build all` is still green after this swap. This
establishes IP-1 and the import convention used by all future modules.

### Milestone 3 — Dev tooling + formatting

Copy `flake.module.nix.example` to `flake.module.nix` and add `cabal-install`,
`fourmolu`, and `cabal-fmt` to `haskellProject.extraDevPackages`. Note that
`nix/treefmt.nix` already configures treefmt to run fourmolu and cabal-fmt — no changes
needed there. Create a minimal `Justfile` with two recipes: `build` (runs `cabal build
all`) and a stub `create-database` that `process-compose.yaml` expects. EP-3 will extend
`create-database` with real migration logic.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` unless otherwise noted.

---

### Milestone 1 steps

**1.1 — Create `cabal.project`**

```bash
mkdir -p shomei-core \
         shomei-jwt \
         shomei-postgres \
         shomei-migrations \
         shomei-servant \
         shomei-server \
         shomei-client
```

Create the file `cabal.project` with the following content:

```cabal
with-compiler: ghc-9.12.4

packages:
    shomei-core
    shomei-jwt
    shomei-postgres
    shomei-migrations
    shomei-servant
    shomei-server
    shomei-client

-- ============================================================
-- DEPENDENCY-OVERRIDE PLACEHOLDER — later plans add their own
-- source-repository-package / package / allow-newer blocks here.
-- Each plan appends its own block; none rewrites another's.
--
-- EP-3 (persistence) will add:
--
-- source-repository-package
--   type: git
--   location: https://github.com/shinzui/ephemeral-pg.git
--   tag: 304c160f25570ea5e225baf5024778c93f434b56
--
-- source-repository-package
--   type: git
--   location: https://github.com/shinzui/codd-project.git
--   tag: d176b3088f23ef2218c7a1f31835e8ee0c0601aa
--   subdir: codd
--
-- package codd
--   tests: False
--   benchmarks: False
--
-- allow-newer:
--   haxl:time
--
-- EP-4 (JWT) will add jose pinned to PR #137 (crypton >= 1.1.0 + ram,
-- NOT the Hackage memory-based 0.12 — memory is deprecated/forbidden here):
--
-- source-repository-package
--   type: git
--   location: https://github.com/sumo/hs-jose.git   -- or a shinzui/hs-jose fork
--   tag: 4726d077a13b24cd1d78fb94b2db5a86c79e3f0f
-- ============================================================
```

**1.2 — Create `shomei-core/shomei-core.cabal`**

```cabal
cabal-version: 3.0
name:          shomei-core
version:       0.1.0.0
synopsis:
    Transport-agnostic domain: types, commands, events, errors, and ports

description:
    shomei-core contains the domain model that does not depend on any
    transport, database, or JWT library. All other packages depend on it.

license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:          warnings, shared
    hs-source-dirs:  src
    exposed-modules:
        Shomei.Prelude
        Shomei.Core.Placeholder
    build-depends:
        base    >= 4.18 && < 5,
        aeson   >= 2.0,
        lens    >= 5.0,
        text    >= 2.0,
        time    >= 1.11,
```

Note: `GHC2024` already enables `DataKinds`, `DerivingStrategies`, `LambdaCase`,
`ImportQualifiedPost`, `MonoLocalBinds`, `ExplicitNamespaces`, `TypeAbstractions`, and
`ListTuplePuns` among others, so those need not appear in `default-extensions`.

**1.3 — Create `shomei-core/src/Shomei/Core/Placeholder.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

module Shomei.Core.Placeholder
  ( packageName
  ) where

packageName :: String
packageName = "shomei-core"
```

**1.4 — Create a stub `shomei-core/src/Shomei/Prelude.hs`** (M1 stub; M2
replaces with the full content)

```haskell
{-# LANGUAGE PackageImports #-}

-- | Shōmei shared prelude. Import this in every module instead of 'Prelude'.
-- This stub is replaced in Milestone 2 with the full re-export set.
module Shomei.Prelude
  ( module X
  ) where

import "base" GHC.Generics as X (Generic)
```

**1.5 — Create `shomei-jwt/shomei-jwt.cabal`**

```cabal
cabal-version: 3.0
name:          shomei-jwt
version:       0.1.0.0
synopsis:      JWT access-token signing/verification and JWKS publishing
license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:          warnings, shared
    hs-source-dirs:  src
    exposed-modules:
        Shomei.JWT.Placeholder
    build-depends:
        base        >= 4.18 && < 5,
        shomei-core,
```

**1.6 — Create `shomei-jwt/src/Shomei/JWT/Placeholder.hs`** (M1 stub; M2
replaces with the prelude-importing version)

```haskell
{-# LANGUAGE PackageImports #-}

module Shomei.JWT.Placeholder
  ( packageName
  ) where

packageName :: String
packageName = "shomei-jwt"
```

**1.7 — Create `shomei-postgres/shomei-postgres.cabal`**

```cabal
cabal-version: 3.0
name:          shomei-postgres
version:       0.1.0.0
synopsis:
    PostgreSQL implementations of the core store ports and audit-event publisher

license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security, Database

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:          warnings, shared
    hs-source-dirs:  src
    exposed-modules:
        Shomei.Postgres.Placeholder
    build-depends:
        base        >= 4.18 && < 5,
        shomei-core,
```

**1.8 — Create `shomei-postgres/src/Shomei/Postgres/Placeholder.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

module Shomei.Postgres.Placeholder
  ( packageName
  ) where

packageName :: String
packageName = "shomei-postgres"
```

**1.9 — Create `shomei-migrations/shomei-migrations.cabal`**

This package is not in `mori.dhall` (EP-3 adds it there); we create its skeleton now so
`cabal.project` is complete from day one. EP-3 will add the real migration logic and the
`source-repository-package` entries for codd and ephemeral-pg.

```cabal
cabal-version: 3.0
name:          shomei-migrations
version:       0.1.0.0
synopsis:      Database schema migrations for Shōmei (stub — see EP-3)
license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security, Database

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

executable shomei-migrate
    import:          warnings, shared
    hs-source-dirs:  app
    main-is:         Main.hs
    build-depends:
        base        >= 4.18 && < 5,
        shomei-core,
```

**1.10 — Create `shomei-migrations/app/Main.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

-- | Stub migration executable. EP-3 replaces this with real codd-based migration logic.
module Main (main) where

main :: IO ()
main = putStrLn "shomei-migrate: stub — EP-3 provides the real implementation"
```

**1.11 — Create `shomei-servant/shomei-servant.cabal`**

```cabal
cabal-version: 3.0
name:          shomei-servant
version:       0.1.0.0
synopsis:
    Servant combinators and handlers: Authenticated, RequireRole/RequireScope, ShomeiAPI

license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:          warnings, shared
    hs-source-dirs:  src
    exposed-modules:
        Shomei.Servant.Placeholder
    build-depends:
        base        >= 4.18 && < 5,
        shomei-core,
        shomei-jwt,
```

**1.12 — Create `shomei-servant/src/Shomei/Servant/Placeholder.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

module Shomei.Servant.Placeholder
  ( packageName
  ) where

packageName :: String
packageName = "shomei-servant"
```

**1.13 — Create `shomei-server/shomei-server.cabal`**

```cabal
cabal-version: 3.0
name:          shomei-server
version:       0.1.0.0
synopsis:      Standalone Shōmei authentication service
license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:          warnings, shared
    hs-source-dirs:  src
    exposed-modules:
        Shomei.Server.Placeholder
    build-depends:
        base        >= 4.18 && < 5,
        shomei-core,
        shomei-jwt,
        shomei-postgres,
        shomei-servant,

executable shomei-server
    import:          warnings, shared
    hs-source-dirs:  app
    main-is:         Main.hs
    build-depends:
        base            >= 4.18 && < 5,
        shomei-core,
        shomei-server,
```

**1.14 — Create `shomei-server/src/Shomei/Server/Placeholder.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

module Shomei.Server.Placeholder
  ( packageName
  ) where

packageName :: String
packageName = "shomei-server"
```

**1.15 — Create `shomei-server/app/Main.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

-- | Shōmei server entry point. EP-4 and EP-5 replace this with real server startup.
module Main (main) where

main :: IO ()
main = do
  putStrLn "Shōmei (証明) — authentication toolkit"
  putStrLn "Server stub: EP-4 wires the real Servant application."
```

**1.16 — Create `shomei-client/shomei-client.cabal`**

```cabal
cabal-version: 3.0
name:          shomei-client
version:       0.1.0.0
synopsis:      Haskell client for the standalone Shōmei auth service
license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security

common warnings
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wincomplete-record-updates
        -Wincomplete-uni-patterns
        -Wpartial-fields
        -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:          warnings, shared
    hs-source-dirs:  src
    exposed-modules:
        Shomei.Client.Placeholder
    build-depends:
        base        >= 4.18 && < 5,
        shomei-core,
```

**1.17 — Create `shomei-client/src/Shomei/Client/Placeholder.hs`**

```haskell
{-# LANGUAGE PackageImports #-}

module Shomei.Client.Placeholder
  ( packageName
  ) where

packageName :: String
packageName = "shomei-client"
```

**1.18 — Verify M1**

```bash
nix develop -c cabal build all
```

Expected tail of output (exact hashes will differ):

```text
Build profile: -w ghc-9.12.4 -O1
In order, the following will be built (use -v for more details):
 - shomei-core-0.1.0.0 (lib) (first run)
 - shomei-jwt-0.1.0.0 (lib) (first run)
 - shomei-postgres-0.1.0.0 (lib) (first run)
 - shomei-migrations-0.1.0.0 (exe:shomei-migrate) (first run)
 - shomei-servant-0.1.0.0 (lib) (first run)
 - shomei-server-0.1.0.0 (lib) (first run)
 - shomei-server-0.1.0.0 (exe:shomei-server) (first run)
 - shomei-client-0.1.0.0 (lib) (first run)
```

Then cabal exits 0 with no error output.

---

### Milestone 2 steps

**2.1 — Replace `shomei-core/src/Shomei/Prelude.hs` with the full prelude**

Replace the M1 stub entirely with:

```haskell
{-# LANGUAGE PackageImports #-}

-- | Shōmei shared prelude. Import this module in every Shōmei module instead of
-- importing 'Prelude' directly. Every import here uses PackageImports to pin the
-- originating package and avoid ambiguity when multiple packages re-export the same
-- name.
--
-- Usage:
--
-- > import Shomei.Prelude
--
-- Do NOT add @import "base" Prelude@ after this; GHC2024 hides the default Prelude
-- when you write a custom one.
module Shomei.Prelude
  ( module X
  , module Control.Lens
  , eventAesonOptions
  ) where

import "base" GHC.Generics as X (Generic)
import "base" Control.Monad as X
  (void, when, unless, guard, forM_, forM)
import "base" Data.Maybe as X
  (fromMaybe, isJust, isNothing, mapMaybe)
import "base" Data.Proxy as X (Proxy (..))
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "text" Data.Text as X (Text)
import "aeson" Data.Aeson as X
  ( FromJSON
  , ToJSON
  , parseJSON
  , toJSON
  , fromJSON
  , toEncoding
  , genericParseJSON
  , genericToJSON
  , genericToEncoding
  , Options (..)
  , SumEncoding (..)
  , defaultOptions
  , camelTo2
  )
import "time" Data.Time as X (UTCTime, getCurrentTime)
import "lens" Control.Lens

-- | Aeson 'Options' for event types: tagged objects with snake_case constructor
-- names and always-tagged single constructors.
--
-- Example: @data MyEvent = UserCreated { ... }@ serialises as
-- @{ "type": "user_created", "data": { ... } }@.
eventAesonOptions :: Options
eventAesonOptions =
  defaultOptions
    { sumEncoding = TaggedObject "type" "data"
    , constructorTagModifier = camelTo2 '_'
    , tagSingleConstructors = True
    }
```

**2.2 — Replace `shomei-jwt/src/Shomei/JWT/Placeholder.hs` to import the prelude**

This proves cross-package prelude use:

```haskell
{-# LANGUAGE PackageImports #-}

-- | JWT package placeholder. Imports 'Shomei.Prelude' to verify cross-package
-- prelude use. EP-6 replaces this with real JWT signing/verification.
module Shomei.JWT.Placeholder
  ( packageName
  , exampleText
  ) where

import Shomei.Prelude

packageName :: String
packageName = "shomei-jwt"

-- | A trivial use of 'Text' from 'Shomei.Prelude', proving the prelude is importable
-- across packages.
exampleText :: Text
exampleText = "shomei-jwt placeholder"
```

**2.3 — Verify M2**

```bash
nix develop -c cabal build all
```

Expected: exits 0. The build re-compiles `shomei-core` (prelude changed) and
`shomei-jwt` (new import), then all dependent packages.

---

### Milestone 3 steps

**3.1 — Create `flake.module.nix`**

Copy the example and add the Haskell dev tools. Note: `nix/treefmt.nix` already enables
`fourmolu` and `cabal-fmt` for formatting via `nix fmt`. What is NOT yet in the dev shell
is the `cabal-install` binary (the `haskell-nix-dev` shell may provide it — verify with
`which cabal` after `nix develop`; if absent, add it). We add all three explicitly to be
safe; Nix deduplicates them if already present.

```nix
# flake.module.nix — project-specific flake-parts customizations.
# seihou does NOT manage this file; it is safe to edit freely.
{ inputs, ... }:
{
  perSystem = { pkgs, config, ... }: {
    # Add cabal-install, fourmolu, and cabal-fmt to the dev shell.
    # nix/treefmt.nix already wires fourmolu and cabal-fmt for `nix fmt`;
    # adding them here also makes them available interactively in the shell.
    haskellProject.extraDevPackages = [
      pkgs.cabal-install
      pkgs.haskellPackages.fourmolu
      pkgs.haskellPackages.cabal-fmt
    ];
  };
}
```

**3.2 — Create `Justfile`**

```just
# Justfile — Shōmei project recipes.
# EP-3 extends create-database with real migration logic.

# Build all packages in the cabal workspace.
build:
    cabal build all

# Create the shomei database. Called by process-compose.yaml via:
#   create_schema: command: just create-database
# EP-3 replaces this stub with real schema creation and migration steps.
create-database:
    psql -c "CREATE DATABASE shomei;" || echo "Database already exists, skipping."
```

**3.3 — Verify M3: fourmolu available**

```bash
nix develop -c fourmolu --version
```

Expected output:

```text
fourmolu 0.16.x.x
```

(exact version depends on nixpkgs revision)

**3.4 — Verify M3: `nix fmt` runs clean**

```bash
nix fmt
```

Expected: formatter runs without error, exits 0. If fourmolu reports formatting diffs,
apply them (the formatter is deterministic; a second run must exit 0 with no changes).

**3.5 — Verify M3: `just build` works inside the dev shell**

```bash
nix develop -c just build
```

Expected output ends with the same build summary as M1.

**3.6 — Commit**

Each commit for this plan must include the three git trailers. The commit for completing
EP-1 foundations:

```bash
git add cabal.project \
        packages/ \
        flake.module.nix \
        Justfile
git commit -m "$(cat <<'EOF'
feat: scaffold multi-package cabal workspace and Shomei.Prelude

Creates cabal.project listing 7 packages, per-package .cabal files with
GHC2024 common stanzas, Shomei.Prelude (IP-1), trivial placeholder modules,
flake.module.nix for dev tooling, and a stub Justfile.

MasterPlan: docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md
ExecPlan: docs/plans/1-project-scaffolding-and-multi-package-build-foundation.md
Intention: intention_01kt7xgv3pes2v675nr1pmzf6j
EOF
)"
```


## Validation and Acceptance

### Acceptance criterion 1 — workspace compiles

**Input:** a fresh `nix develop` shell (no prior cabal cache required; cabal will
download and build deps on first run).

**Command:**

```bash
nix develop -c cabal build all 2>&1 | tail -20
```

**Expected output** (last lines, order may vary by cabal version):

```text
[1 of 1] Compiling Shomei.Core.Placeholder
[1 of 1] Compiling Shomei.Prelude
...
[1 of 1] Compiling Shomei.JWT.Placeholder
...
[1 of 1] Compiling Main  ( app/Main.hs, ... )
Linking .../shomei-server ...
Linking .../shomei-migrate ...
```

Exit code: 0. No `error:` lines in output.

### Acceptance criterion 2 — prelude is importable cross-package

**Command:**

```bash
nix develop -c cabal repl shomei-jwt
```

**REPL session:**

```text
ghci> import Shomei.JWT.Placeholder
ghci> exampleText
"shomei-jwt placeholder"
ghci> :type exampleText
exampleText :: Text
```

This proves that `Text` from `Shomei.Prelude` (re-exported from the `text` package) is
visible and correctly typed across the `shomei-core` → `shomei-jwt` package boundary.

### Acceptance criterion 3 — dev tooling is present

```bash
nix develop -c bash -c 'fourmolu --version && cabal-fmt --version && cabal --version'
```

Expected: three version lines, no errors.

### Acceptance criterion 4 — formatting is clean and idempotent

```bash
nix fmt && nix fmt
```

Expected: both runs exit 0 with no diff output. If the first run modifies files, the
second must be clean.

### Acceptance criterion 5 — just build works

```bash
nix develop -c just build
```

Expected: exits 0; same output as `cabal build all`.

### Acceptance criterion 6 — stubs run

```bash
nix develop -c cabal run shomei-server
```

Expected output:

```text
Shōmei (証明) — authentication toolkit
Server stub: EP-4 wires the real Servant application.
```

```bash
nix develop -c cabal run shomei-migrate
```

Expected output:

```text
shomei-migrate: stub — EP-3 provides the real implementation
```


## Idempotence and Recovery

**Creating files:** all `mkdir -p` and file-creation steps are safe to re-run. If a file
already exists with the correct content, overwriting it with the same content is a no-op
from cabal's perspective (timestamp changes may trigger a rebuild, which is harmless).

**`cabal build all`:** fully idempotent. Cabal caches build artifacts in
`dist-newstyle/`. Re-running always succeeds if the sources are valid. To force a clean
rebuild:

```bash
cabal clean && cabal build all
```

**`nix develop`:** the shell environment is deterministic. Exiting and re-entering the
shell is safe at any point.

**`nix fmt`:** fourmolu and cabal-fmt are deterministic; running twice produces no
changes after the first run. If the formatter modifies a file, inspect the diff (`git
diff`) to confirm it is purely cosmetic (whitespace, import ordering).

**Recovery from a bad `.cabal` file:** if `cabal build all` fails with a parse error,
the error message names the offending `.cabal` file and line. Fix the file, then re-run.
Cabal does not leave partial state that blocks recovery.

**Recovery from a bad `flake.module.nix`:** if `nix develop` fails to evaluate, the
error is a Nix evaluation error pointing to the offending line. Fix `flake.module.nix`
and retry. The previous dev shell (if already open) remains usable.

**`packages.default` breakage:** as documented in the Decision Log, `nix build` will
fail because `nix/haskell.nix` calls `callCabal2nix "shomei" inputs.self {}` and there
is no root `.cabal` file. This is an expected, documented limitation of the bootstrap
phase. Do not attempt to fix it by editing `nix/haskell.nix`. Recovery: use
`nix develop` + `cabal build all` as the canonical build path until a later plan
addresses Nix packaging.


## Interfaces and Dependencies

### Package graph and inter-package interfaces

| Package | Kind | Depends on | Key interface (EP-1) |
|---|---|---|---|
| `shomei-core` | library | — | `Shomei.Prelude`, `Shomei.Core.Placeholder` |
| `shomei-jwt` | library | `shomei-core` | `Shomei.JWT.Placeholder` |
| `shomei-postgres` | library | `shomei-core` | `Shomei.Postgres.Placeholder` |
| `shomei-migrations` | executable | `shomei-core` | `shomei-migrate` binary (stub) |
| `shomei-servant` | library | `shomei-core`, `shomei-jwt` | `Shomei.Servant.Placeholder` |
| `shomei-server` | library + exe | `shomei-core`, `shomei-jwt`, `shomei-postgres`, `shomei-servant` | `shomei-server` binary (stub) |
| `shomei-client` | library | `shomei-core` | `Shomei.Client.Placeholder` |

### GHC and extension baseline (IP-8)

- Compiler: GHC 9.12.4 (pinned in `cabal.project` via `with-compiler: ghc-9.12.4`).
- Cabal format: `cabal-version: 3.0`.
- Language edition: `GHC2024` (in `common shared`).
- Extensions enabled project-wide via `common shared`:
  `DeriveAnyClass`, `DuplicateRecordFields`, `BlockArguments`, `MultilineStrings`,
  `OverloadedLabels`, `OverloadedRecordDot`, `OverloadedStrings`, `PackageImports`,
  `QualifiedDo`, `TemplateHaskell`.
- Extensions enabled by GHC2024 (no need to list in `.cabal`):
  `DataKinds`, `DerivingStrategies`, `LambdaCase`, `ImportQualifiedPost`,
  `MonoLocalBinds`, `ExplicitNamespaces`, `TypeAbstractions`.
- Warning profile: `-Wall -Wcompat -Widentities -Wincomplete-record-updates
  -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints` (in `common
  warnings`).

### Coding conventions (enforced in EP-1 skeleton, required in all future modules)

- Qualified imports postpositive only: `import Data.Map.Strict qualified as Map`.
- Records: strict fields (`!`), entity-id field first, no field-name prefixes,
  explicit deriving strategies.
- Lens: `^.`, `.~`, `?~`, `%~`, `#field`. The orphan `import Data.Generics.Labels ()`
  is per-module, never in the prelude.
- `Shomei.Prelude` is imported in every module (not `Prelude`). No `import "base" Prelude`.

### Integration points owned by EP-1

- **IP-1 — `Shomei.Prelude`:** module lives at
  `shomei-core/src/Shomei/Prelude.hs`. All packages import it. Signature is
  fixed by this plan; later plans add nothing to it (they add domain modules, not prelude
  entries) unless the MasterPlan explicitly designates an IP update.
- **IP-8 — `cabal.project` + common stanzas:** the `cabal.project` file and the
  `common warnings` / `common shared` stanzas are established by this plan and must not
  be modified by other plans except through the designated EP-3 placeholder section.

### External library dependencies declared in EP-1

Each `.cabal` file in EP-1 declares only the dependencies needed for the placeholder
modules. Richer deps (e.g. `hasql`, `servant`, `jwt`, `crypton`) will be added by
EP-2 through EP-7 as those packages grow their actual implementations.

| Package | Declared deps in EP-1 |
|---|---|
| `shomei-core` | `base`, `aeson`, `lens`, `text`, `time` |
| `shomei-jwt` | `base`, `shomei-core` |
| `shomei-postgres` | `base`, `shomei-core` |
| `shomei-migrations` | `base`, `shomei-core` |
| `shomei-servant` | `base`, `shomei-core`, `shomei-jwt` |
| `shomei-server` (lib) | `base`, `shomei-core`, `shomei-jwt`, `shomei-postgres`, `shomei-servant` |
| `shomei-server` (exe) | `base`, `shomei-core`, `shomei-server` |
| `shomei-client` | `base`, `shomei-core` |

### Coordination with other plans

- **EP-3 (Persistence):** extends `cabal.project` by filling in the placeholder section
  (source-repository-package for codd and ephemeral-pg, `allow-newer: haxl:time`,
  `package codd` stanza). Adds `shomei-migrations` to `mori.dhall`. Extends the
  `Justfile`'s `create-database` recipe with real codd migration steps.
- **EP-2 (Domain model):** adds modules to `shomei-core` library, importing
  `Shomei.Prelude`. Does not touch `cabal.project`.
- **All other plans (EP-4 through EP-8):** add modules to their respective packages and
  expand `build-depends`. Do not modify `cabal.project` (unless EP-3 coordination is
  needed) or the common stanzas.
