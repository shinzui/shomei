---
name: release
description: >-
  Cut a release of the Shōmei Haskell packages and publish them to Hackage
  following the PVP. Versions each package independently, updates internal
  dependency bounds and per-package changelogs, runs the project's format /
  build / test / flake-check gates, tags each package (<pkg>-<version>), pushes,
  uploads to Hackage in dependency order, and creates per-package GitHub
  releases (plus a coordinated umbrella release for cross-package major changes).
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Release Shōmei to Hackage

This skill releases the Shōmei packages to
[Hackage](https://hackage.haskell.org/) following the Haskell **Package
Versioning Policy (PVP)**. It is **operator-driven** and irreversible at the
upload step — work through it deliberately, confirm before committing, and
**stop on the first failure**.

The optional argument (`major` | `minor` | `patch`) is the **default** bump
applied to every package selected for release. You still confirm the computed
version of each package before anything is written.

---

## Versioning strategy (PVP)

Hackage versions are **PVP** `A.B.C.D`:

- **`A.B`** — the major version. Bump for **breaking** API changes (anything
  that could break a dependent: removed/renamed exports, changed types or
  signatures, stricter constraints).
- **`C`** — the minor version. Bump for **backwards-compatible additions** (new
  exports, new modules) that don't break existing code.
- **`D`** — the patch version. Bump for changes that **don't affect the API**
  at all (internals, docs, bounds-only, performance).

So the `major | minor | patch` argument maps to PVP as:

| argument | bumps | example                |
| -------- | ----- | ---------------------- |
| `major`  | `A.B` | `0.1.0.0` → `0.2.0.0`  |
| `minor`  | `C`   | `0.1.0.0` → `0.1.1.0`  |
| `patch`  | `D`   | `0.1.0.0` → `0.1.0.1`  |

> Pre-1.0 note: while `A` is `0`, treat `B` as the "real" major. A breaking
> change goes `0.1.x.x` → `0.2.0.0`.

**Each package is versioned independently.** A given release may bump only a
subset of packages — only those with changes since their last
`<pkg>-<version>` tag. Do **not** bump a package that has no changes.

When a package's version changes, every other published package that depends
on it must have its **internal dependency bound** updated (see below).

---

## Packages

The eight publishable packages are the `shomei-*` entries in the cabal
workspace (`cabal.project`, GHC 9.12.4). Note that several ship **executables
and a public sublibrary** as well as a library — those components are part of
the uploaded tarball and their dependencies must resolve on Hackage too.

Publish in this **dependency order** (dependencies first). The "depends on"
column lists internal deps across **all** components, because step 4 bounds all
of them:

| # | package             | directory            | library deps                                                    | other-component deps (exe / test-suite)                                              |
| - | ------------------- | -------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 1 | `shomei-core`       | `shomei-core/`       | —                                                               | test: `shomei-core`                                                                    |
| 2 | `shomei-migrations` | `shomei-migrations/` | —                                                               | exe `shomei-migrate`, **public sublib `test-support`** → `shomei-migrations`            |
| 3 | `shomei-jwt`        | `shomei-jwt/`        | `shomei-core`                                                     | test: `shomei-core`                                                                    |
| 4 | `shomei-webauthn`   | `shomei-webauthn/`   | `shomei-core`                                                     | test: `shomei-core`                                                                    |
| 5 | `shomei-postgres`   | `shomei-postgres/`   | `shomei-core`                                                     | test: `shomei-core`, `shomei-migrations:test-support`                                  |
| 6 | `shomei-servant`    | `shomei-servant/`    | `shomei-core`                                                     | exe `shomei-openapi`; test: `shomei-core`, `shomei-jwt`                                |
| 7 | `shomei-server`     | `shomei-server/`     | `shomei-core`, `shomei-jwt`, `shomei-migrations`, `shomei-postgres`, `shomei-servant`, `shomei-webauthn` | exes `shomei-server`, `shomei-admin`; tests also use `shomei-migrations:test-support`  |
| 8 | `shomei-client`     | `shomei-client/`     | `shomei-core`, `shomei-servant`                                   | test: `shomei-core`, `shomei-jwt`, `shomei-postgres`, `shomei-server`, `shomei-migrations:test-support` |

> **`shomei-client` goes last, after `shomei-server`.** Its *library* only needs
> `shomei-core` + `shomei-servant`, but its **test-suite depends on
> `shomei-server`**. Since step 4 bounds test-suites too, uploading
> `shomei-client` before the matching `shomei-server` version is live would
> publish a tarball whose test-suite cannot resolve on Hackage.

> **`shomei-migrations:test-support` is a `visibility: public` sublibrary**, not
> a private test helper. It ships in the `shomei-migrations` tarball and is
> depended on by the test-suites of `shomei-postgres`, `shomei-server`, and
> `shomei-client`. Its own dependencies therefore gate the
> `shomei-migrations` upload (see the blocker table).

Within a release, always restrict to the subset that actually changed, but
**preserve this relative order** for the ones you do publish.

### NOT released

- `examples/embedded-servant-app` — example/demo app, not a library.
- `examples/microservice-auth-stack` — example/demo app, not a library.
- `examples/embedded-with-en` — example/demo app, not a library. It is also
  **absent from `cabal.project`'s `packages:` list** (it depends on `en-core`
  and `servant-health`, which the workspace does not pin), so `cabal build all`
  and `cabal test all` never touch it. Do not add it to the release set, and do
  not treat its absence from the workspace build as a regression.

These are excluded from versioning, tagging, and upload entirely.

### ⚠️ Non-Hackage dependency blockers (must check before upload)

`cabal.project` pins several upstream dependencies to **git repositories** via
`source-repository-package` because the needed versions are **not on Hackage**.
A package that depends (transitively) on any of these **cannot be uploaded to
Hackage** until the upstream version is published there — Hackage will reject a
package whose dependencies can't be resolved from Hackage. Treat this as a hard
gate per package:

| pin (cabal.project)             | not on Hackage because                | blocks (until upstream lands)                          |
| ------------------------------- | ------------------------------------- | ------------------------------------------------------ |
| `mzabani/codd`                  | `codd` is not published on Hackage    | `shomei-migrations`, `shomei-postgres`, `shomei-server`|
| `sumo/hs-jose` (jose 0.13, PR#137)| jose 0.13 not yet released          | `shomei-jwt`, `shomei-server`                          |
| `shinzui/webauthn` (fork)       | upstream constrains crypton<1.1, jose<0.12 at GHC 9.12 | `shomei-webauthn`, `shomei-server`        |
| `shinzui/ephemeral-pg` (fork)   | fork not published on Hackage         | `shomei-migrations` (its **public** `test-support` sublibrary depends on it) |

> **`ephemeral-pg` is not "tests only".** `shomei-migrations`' `test-support`
> sublibrary is declared `visibility: public` and depends on both
> `ephemeral-pg` and `codd`, so it ships in the tarball and its deps must
> resolve from Hackage. `shomei-migrations` is therefore blocked twice over.
> If you want `shomei-migrations` releasable before those land upstream, the
> options are: drop `test-support` from the released tarball, make it private
> (`visibility: private`) and move the consumers off it, or split it into its
> own unpublished package — a design change, not a release-time decision.

Before uploading a package, verify a **clean Hackage-only solve** for it (see
step 8). If a package is still blocked, **publish the unblocked packages and
stop** at the first blocked one; record what was skipped.

As of this writing the repo has **no tags and every package is still at
`0.1.0.0`**, so nothing has shipped yet. Blocker status by package — verify,
don't assume:

| package             | releasable? | blocked by                                                                          |
| ------------------- | ----------- | ----------------------------------------------------------------------------------- |
| `shomei-core`       | ✅ yes      | — the only package with no blocked dependency in any component                        |
| `shomei-jwt`        | ❌          | jose 0.13 (library)                                                                   |
| `shomei-webauthn`   | ❌          | webauthn fork (library)                                                               |
| `shomei-migrations` | ❌          | codd + ephemeral-pg (library **and** the public `test-support` sublibrary)             |
| `shomei-postgres`   | ❌          | codd (library); test-suite also pulls `shomei-migrations:test-support`                 |
| `shomei-servant`    | ❌          | library is clean, but its **test-suite depends on `shomei-jwt`**, which is blocked     |
| `shomei-server`     | ❌          | codd, jose 0.13, webauthn fork                                                         |
| `shomei-client`     | ❌          | library is clean, but its **test-suite depends on `shomei-server`/`shomei-postgres`/`shomei-jwt`/`shomei-migrations:test-support`**, all blocked |

So the honest answer today is: **only `shomei-core` can actually be published.**
`shomei-servant` and `shomei-client` have clean libraries and would become
releasable if their test-suites were dropped from the tarball or their blocked
test dependencies removed — otherwise they wait on the same upstreams as
everything else.

---

## Internal dependency bounds

Internal deps are currently declared **without version bounds** (e.g. just
`, shomei-core`). For a Hackage release, add and maintain **PVP caret bounds**
on every internal dependency of a published package, e.g.:

```cabal
build-depends:
    , shomei-core  ^>=0.1.0.0
    , shomei-jwt   ^>=0.1.0.0
```

`^>=A.B.C.D` means `>=A.B.C.D && <A.(B+1)` — it permits patch/minor bumps of
the dependency but not a major one. When you bump a package's `A.B`, update the
`^>=` bound in **every dependent** (per the table above) and bump those
dependents too (a changed bound is itself a release-worthy change).

> Apply internal bounds across **all** components that reference the dependency
> (library, executables, **and** test-suites), so a `cabal build all` /
> `nix flake check` stays consistent.

---

## Hackage metadata pre-flight (blocks the first release)

The cabal files were written for a workspace build, not for distribution. Run
`cabal check` in each package directory and fix what it reports **before** the
first upload of that package. The gaps as of this writing:

| gap | packages affected | why it matters |
| --- | ----------------- | -------------- |
| no `synopsis:` | `shomei-core`, `shomei-postgres`, `shomei-servant`, `shomei-webauthn` | Hackage lists the package with a blank one-liner |
| no `description:` | all except `shomei-core`, `shomei-migrations` | `cabal check`: *"will likely cause trouble when distributing"* |
| no `license-file:`, and **no LICENSE file exists anywhere in the repo** | all 8 (they declare `license: MIT` or `BSD-3-Clause`) | the tarball ships a license claim with no license text |
| no `homepage:` / `bug-reports:` | all 8 | should point at `https://github.com/shinzui/shomei` |
| no `extra-doc-files: CHANGELOG.md` | all 8 | **the per-package changelogs created in step 5 would not ship in the sdist** |
| missing **upper bounds** on nearly every external dependency | all 8 | a PVP release without upper bounds is exactly what PVP exists to prevent; `cabal check` flags `[missing-upper-bounds]` on every library |
| no `tested-with:` | all 8 | optional, but the project is GHC-9.12.4-only in practice |

Fixing these is a normal `chore(release):`-scoped change; it is a **`D` bump**
(metadata only, no API change) for any package that has already shipped, and
folds into the first release for those that have not.

---

## Release steps

> The project build/format/check commands used below:
> - format: `nix fmt` (treefmt → nixpkgs-fmt, fourmolu, cabal-fmt)
> - build:  `cabal build all`
> - test:   `cabal test all`
> - gate:   `nix flake check` (runs the treefmt check; add `--no-build` only if a
>   full rebuild is impractical, but prefer the full check before a release)
> - dist:   `cabal check` (per package directory — distribution-readiness)
>
> Commit messages follow **Conventional Commits** (see the repo's global
> guidance): `feat`, `fix`, `docs`, `refactor`, `chore`, etc., with a `!` /
> `BREAKING CHANGE:` footer for breaking changes.

### 1. Confirm the working tree is clean

```bash
git status --short
git fetch --all --tags
```

Stop if there are uncommitted changes unrelated to this release.

### 2. Determine what changed per package

For each candidate package, find the last release tag and the changes since:

```bash
# last tag for a package (per-package tag scheme: <pkg>-<version>)
git tag --list 'shomei-core-*' --sort=-v:refname | head -1

# changes to that package's directory since its last tag (or all history if none)
git log <last-tag>..HEAD --oneline -- shomei-core/
```

A package with **no commits touching its directory** since its last tag (and
no internal-bound bump forced by a dependency) is **not** released. Build the
list of packages-to-release from this.

> First release: no tags exist yet, so every selected package is a candidate;
> use full history (`git log --oneline -- <dir>/`) to write its first changelog.

### 3. Compute the PVP bump for each package

For each package-to-release, classify its changes (breaking → `A.B`, additive →
`C`, internal/bounds-only → `D`) and compute the new version. If the skill was
invoked with a `major|minor|patch` argument, use that as the **default** for
every package, but **override per-package** when the actual changes warrant a
larger bump (never a smaller one than the changes require).

Propagate: if a bumped package is a dependency of another published package,
that dependent needs at least a bounds bump (often `D`, or `A.B` if the upstream
bump was major and breaks the dependent's API).

Present the full proposed table — `package | old → new | reason` — and
**confirm with the user via AskUserQuestion before writing anything.**

### 4. Update cabal versions and internal bounds

For each package-to-release:

- Set `version:` in `<dir>/<pkg>.cabal` to the computed value.
- Update internal `^>=` bounds (step "Internal dependency bounds") in this
  package and in every dependent, across all components.

### 5. Update changelogs

Use **per-package** changelogs (independent versioning). For each
package-to-release:

- If `<dir>/CHANGELOG.md` does not exist yet, create it (these don't exist as
  of the first release). Header template:

  ```markdown
  # Changelog for <pkg>

  All notable changes to `<pkg>` are documented here. This project adheres to
  the [PVP](https://pvp.haskell.org/).

  ## <version> — YYYY-MM-DD

  - ...
  ```

- Otherwise, add a new `## <version> — YYYY-MM-DD` section at the top
  (move any "Unreleased" notes into it). Use ISO `YYYY-MM-DD` dates.
- Summarize the user-facing changes from step 2's `git log`.

Also update the **root `CHANGELOG.md`** "Unreleased" section: convert the
relevant entries into a dated roundup that names each package and its new
version (the root changelog stays the project-level overview).

> The root `CHANGELOG.md` header currently says versioning "will move to
> semantic versioning (`MAJOR.MINOR.PATCH`) and git tags (`vMAJOR.MINOR.PATCH`)
> at the first tagged release". That contradicts this skill: Shōmei versions
> **each package independently under PVP** with `<pkg>-<version>` tags, and
> there is no repo-wide `vX.Y.Z` tag. Rewrite that header as part of the first
> release.

### 6. Format, build, test, and run the check gate

Run, in order, and **stop on any failure**:

```bash
nix fmt              # treefmt: fourmolu + cabal-fmt + nixpkgs-fmt
cabal build all
cabal test all       # all packages except shomei-migrations ship test-suites
nix flake check      # treefmt check (+ flake checks)
```

Then run `cabal check` **in each package-to-release's directory** and stop on
anything under *"will likely cause trouble when distributing"*:

```bash
for p in shomei-core shomei-migrations shomei-jwt shomei-webauthn \
         shomei-postgres shomei-servant shomei-server shomei-client; do
  echo "### $p"; (cd "$p" && cabal check)
done
```

Note `cabal build all` / `cabal test all` cover only the packages listed in
`cabal.project` — `examples/embedded-with-en` is deliberately not among them.

### 7. Commit, tag, and push

Commit the release with a Conventional Commits message, e.g.:

```bash
git add -A
git commit -m "chore(release): shomei-core 0.2.0.0, shomei-jwt 0.1.1.0"
```

Create an **annotated, per-package tag** for each released package
(`<pkg>-<version>`):

```bash
git tag -a shomei-core-0.2.0.0 -m "shomei-core 0.2.0.0"
git tag -a shomei-jwt-0.1.1.0  -m "shomei-jwt 0.1.1.0"
```

Push commit and tags:

```bash
git push
git push --tags
```

### 8. Publish to Hackage (dependency order)

For each package-to-release, **in the dependency order from the Packages
table**, one at a time:

1. **Verify a Hackage-only solve** (the non-Hackage blocker gate). Build the
   sdist in a scratch directory that has **no `cabal.project`**, so none of the
   `source-repository-package` pins apply and the solver must find every
   dependency on Hackage:

   ```bash
   cabal sdist <pkg>        # -> dist-newstyle/sdist/<pkg>-<version>.tar.gz

   scratch=$(mktemp -d)
   tar -xzf dist-newstyle/sdist/<pkg>-<version>.tar.gz -C "$scratch"
   ( cd "$scratch/<pkg>-<version>" \
     && cabal build --dry-run --enable-tests all )   # must solve with no local project
   ```

   `--enable-tests` matters: test-suites ship in the tarball, and they are what
   pull `shomei-migrations:test-support` (and therefore `codd` /
   `ephemeral-pg`) into the solve.

   If the solve fails because of a pinned, not-yet-on-Hackage dependency
   (`codd`, jose 0.13, the webauthn fork), **skip this package and every
   package that depends on it**, note it as blocked, and continue only with
   independent unblocked packages.

2. **Upload the candidate** (review on Hackage first, optional), then publish:

   ```bash
   cabal upload dist-newstyle/sdist/<pkg>-<version>.tar.gz            # candidate (dry run)
   cabal upload --publish dist-newstyle/sdist/<pkg>-<version>.tar.gz  # FINAL, irreversible
   ```

3. **Upload Haddock docs** for the published version:

   ```bash
   cabal haddock <pkg> --haddock-for-hackage --enable-doc
   cabal upload --publish --documentation \
     dist-newstyle/<pkg>-<version>-docs.tar.gz
   ```

**If any upload fails, stop immediately.** Do **not** continue to packages that
depend on the failed one — a dependent uploaded against a missing dependency
version will be broken on Hackage.

### 9. Create GitHub releases

`gh` is available. Create a **per-package GitHub release** for each published
package, using its tag and changelog section as the body:

```bash
gh release create shomei-core-0.2.0.0 \
  --title "shomei-core 0.2.0.0" \
  --notes-file <(awk '/^## /{n++} n==1' shomei-core/CHANGELOG.md)
```

For a **major change that spans multiple packages**, *also* create one
**coordinated "umbrella" GitHub release** that summarizes the whole batch and
links each per-package tag. Use a date- or campaign-based tag for it (e.g.
`release-YYYY-MM-DD`) so it doesn't collide with the per-package tags:

```bash
git tag -a release-YYYY-MM-DD -m "Coordinated release YYYY-MM-DD"
git push origin release-YYYY-MM-DD
gh release create release-YYYY-MM-DD \
  --title "Shōmei release YYYY-MM-DD" \
  --notes "Cross-package release. Packages:
- shomei-core 0.2.0.0
- shomei-jwt 0.1.1.0
..."
```

### 10. Hand off

Summarize: which packages were published (and versions), which were skipped and
why (blockers), the tags created, the Hackage URLs, and the GitHub releases.

---

## Important

- **Confirm the per-package version bumps and changelog entries with the user
  (AskUserQuestion) before committing.** Nothing is written until ratified.
- **Always publish in dependency order** (`shomei-core` first; `shomei-server`
  then `shomei-client` last — see the Packages table note on why `shomei-client`
  trails `shomei-server`). Never upload a dependent before its dependency's new
  version is live on Hackage.
- **Never skip the gates.** `nix fmt`, `cabal build all`, `cabal test all`,
  `nix flake check`, and per-package `cabal check` must all pass before any tag
  or upload.
- **Respect the non-Hackage blockers.** Verify each package resolves against
  Hackage-only before `cabal upload --publish`. Skip blocked packages (and their
  dependents) rather than forcing an upload that can't resolve.
- **Stop on the first failure.** If a build, test, check, or upload fails, halt
  — do not continue publishing dependents.
- **`cabal upload --publish` is irreversible.** A published version can never be
  re-uploaded or deleted (only deprecated). Prefer a candidate upload + review
  for the first release of any package.
- Bump **internal `^>=` bounds in every dependent** whenever a dependency's
  version changes, and release those dependents too.
