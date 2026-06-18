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

All publishable packages are libraries in the cabal workspace
(`cabal.project`, GHC 9.12.4). Publish to Hackage in this **dependency order**
(dependencies first):

| # | package            | directory          | depends on (internal)                                  |
| - | ------------------ | ------------------ | ------------------------------------------------------ |
| 1 | `shomei-core`      | `shomei-core/`     | —                                                      |
| 2 | `shomei-migrations`| `shomei-migrations/`| —                                                     |
| 3 | `shomei-jwt`       | `shomei-jwt/`      | `shomei-core`                                          |
| 4 | `shomei-webauthn`  | `shomei-webauthn/` | `shomei-core`                                          |
| 5 | `shomei-postgres`  | `shomei-postgres/` | `shomei-core`                                          |
| 6 | `shomei-servant`   | `shomei-servant/`  | `shomei-core`                                          |
| 7 | `shomei-client`    | `shomei-client/`   | `shomei-core`, `shomei-servant`                        |
| 8 | `shomei-server`    | `shomei-server/`   | `shomei-core`, `shomei-jwt`, `shomei-migrations`, `shomei-postgres`, `shomei-servant`, `shomei-webauthn` |

Within a release, always restrict to the subset that actually changed, but
**preserve this relative order** for the ones you do publish.

### NOT released

- `examples/embedded-servant-app` — example/demo app, not a library.
- `examples/microservice-auth-stack` — example/demo app, not a library.

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
| `shinzui/ephemeral-pg` (fork)   | test-only pin                         | (tests only — not a runtime/upload blocker)            |

Before uploading a package, verify a **clean Hackage-only solve** for it (see
step 7). If a package is still blocked, **publish the unblocked packages and
stop** at the first blocked one; record what was skipped. As of the first
release, only `shomei-core` (and `shomei-servant` / `shomei-client`, assuming
their non-internal deps are all on Hackage) are candidates — verify, don't
assume.

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

## Release steps

> The project build/format/check commands used below:
> - format: `nix fmt` (treefmt → nixpkgs-fmt, fourmolu, cabal-fmt)
> - build:  `cabal build all`
> - test:   `cabal test all`
> - gate:   `nix flake check` (runs the treefmt check; add `--no-build` only if a
>   full rebuild is impractical, but prefer the full check before a release)
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

### 6. Format, build, test, and run the check gate

Run, in order, and **stop on any failure**:

```bash
nix fmt              # treefmt: fourmolu + cabal-fmt + nixpkgs-fmt
cabal build all
cabal test all       # all packages except shomei-migrations ship test-suites
nix flake check      # treefmt check (+ flake checks)
```

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

1. **Verify a Hackage-only solve** (the non-Hackage blocker gate). From a
   temporary location *outside* this workspace's `cabal.project` overrides, or
   with an isolated project, confirm the package resolves against Hackage only:

   ```bash
   cabal sdist <pkg>                       # produces dist-newstyle/sdist/<pkg>-<version>.tar.gz
   # sanity-check resolution against Hackage (no source-repository-package pins):
   cabal build <pkg> --package-db=clear --package-db=global \
     --project-file=/dev/null 2>&1 | tail -n 20   # or build the sdist in a scratch dir
   ```

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
  last). Never upload a dependent before its dependency's new version is live on
  Hackage.
- **Never skip the gates.** `nix fmt`, `cabal build all`, `cabal test all`, and
  `nix flake check` must all pass before any tag or upload.
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
