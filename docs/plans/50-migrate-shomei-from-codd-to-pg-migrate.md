---
id: 50
slug: migrate-shomei-from-codd-to-pg-migrate
title: "Migrate shomei from codd to pg-migrate"
kind: exec-plan
created_at: 2026-08-24T13:44:44Z
intention: "intention_01m0t088cce2dajvbdw4ppfbj1"
---

# Migrate shomei from codd to pg-migrate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shōmei owns a PostgreSQL schema. Today that schema is created and evolved by a library
called `codd` (`mzabani/codd`), which reads timestamped `.sql` files, orders them by the
timestamp in the filename, and records what it has applied in its own bookkeeping tables.
This plan replaces `codd` with `pg-migrate` (`shinzui/pg-migrate`, version 1.1.0.0), a
different PostgreSQL migration library with the same job but a different design: order is
declared in an explicit text file called a *manifest* rather than inferred from filenames,
migrations are grouped into named *components* that separate libraries can own and an
application composes into one *plan*, and the whole thing ships a reusable command-line
interface.

Three concrete things become possible after this change, and each is observable.

First, **`shomei-migrations`, `shomei-postgres`, and `shomei-server` become publishable to
Hackage.** Hackage refuses a package whose dependencies cannot be resolved from Hackage.
`codd` has never been published there, so `shomei-migrations`' `cabal.project` pins it to a
git commit, and every package that transitively depends on it is blocked. The repository's
own release runbook, `agents/skills/release/SKILL.md`, records this as a hard gate and
concludes that "only `shomei-core` can actually be published." All six `pg-migrate`
packages *are* on Hackage. So is `ephemeral-pg` 0.2.2.0, the other git pin blocking
`shomei-migrations`. Removing both pins is the difference between one publishable package
and most of the toolkit being publishable. Since a first release is being prepared right
now, this is the moment to do it.

Second, **operators and developers get a real migration CLI.** Today `shomei-migrate` is a
single-purpose binary that reads four `CODD_*` environment variables and applies
everything, printing nothing structured and checking nothing. After this change the same
binary name supports `plan`, `list`, `check`, `status`, `verify`, `up`, `repair`, and
`new`, each with a `--json` mode. You will be able to run `shomei-migrate status` against a
database and see exactly which migrations are applied and which are pending, before
changing anything.

Third, **an application can compose Shōmei's schema with its own.** `pg-migrate`'s
component model exists precisely so an independently versioned library can own its
migrations and an application can merge them with other libraries' migrations into one
ordered plan tracked by one ledger. `docs/user/authorization.md` currently warns readers
away from putting Shōmei and its sibling authorization project `en` in the same database,
giving as its first reason that "two codd migration ledgers in one database is unverified."
By exporting a `MigrationComponent`, `shomei-migrations` gives applications a supported way
to run Shōmei's schema alongside another `pg-migrate` component in a single plan and a
single ledger. This plan exports that value and updates the documentation; it does not
attempt the `en` integration itself.

There is no production data anywhere and no external consumer of Shōmei. That is what makes
this affordable: the migration files can be renumbered, their contents adjusted, and every
existing development database simply recreated from scratch. No history import, no
in-place remediation, no compatibility shim.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Baseline captured before any change (2026-08-24): 20 tables in schema `shomei`;
      43 rows in `codd.sql_migrations` for 28 files; SHA-256 of all 28 header-stripped
      SQL bodies recorded for the post-rename integrity check.
- [x] M1: restructure migration sources — rename 28 files into `shomei-migrations/migrations/shomei/`, strip `-- codd: in-txn` headers, write the manifest (2026-08-24)
- [x] M2: rewrite `Shomei.Migrations` on top of `pg-migrate` and `pg-migrate-embed`; update `shomei-migrations.cabal` (2026-08-24)
- [x] M3: replace the `shomei-migrate` executable with the `pg-migrate-cli` mount; rewrite the `migrate` and `new-migration` Justfile recipes (2026-08-24).
      Verified against a freshly created database: `plan` → 1 component / 28 migrations;
      `list` → 28 rows, all `kind=sql transaction=transactional`; `check` → exit 0;
      `status` → 28 pending; `up` → 28 `applied_now`; second `up` → 28 `already_applied`;
      `verify` → `verification ok`, exit 0. Ledger `pgmigrate.migrations` holds 28 applied
      rows; `\dn` shows exactly `pgmigrate`, `public`, `shomei` and **no** codd schema.
- [x] M4: move `Shomei.Migrations.TestSupport`, `Shomei.Server.Boot`, and `shomei-admin` onto the new API; make migration failure fatal at startup (2026-08-24)
- [x] M5 (part): drop the `codd` and `ephemeral-pg` `source-repository-package` pins and the
      `package codd` stanza from `cabal.project`. Pulled forward ahead of M4's build — see
      Surprises & Discoveries; M4 cannot link without it.
- [x] `cabal build all` clean and `cabal test all` green — all 13 suites PASS, exit 0
      (2026-08-24), including `shomei-postgres` (56), `shomei-server` (30),
      `shomei-admin` (25), `shomei-client`, and both examples, all of which provision real
      databases through `withShomeiMigratedDatabase`.
- [x] M5 (rest): Nix wiring, `mori.dhall`, `README.md`, `docs/user/`, `Dockerfile`, and the
      release skill (2026-08-24). Also updated three files the plan did not enumerate but
      which carried live `codd` references: `examples/embedded-with-en/cabal.project` (it
      mirrors the root pins and would otherwise hit the same `ephemeral-pg` conflict),
      `.github/workflows/ci.yaml`, and a stale comment in `shomei-postgres/test/Main.hs`.
- [x] Final: Hackage-only sdist solve verified (2026-08-24). `shomei-migrations` solves
      **completely from Hackage** with `--enable-tests`; the tarball ships all 28 `.sql`
      files and the `manifest`. `shomei-postgres` has no third-party blocker left and fails
      only on `unknown package: shomei-core`, which upload order resolves.
- [x] Migration failure proven fatal (2026-08-24) — Validation step 4, tested rather than
      assumed. Against a database whose ledger checksum was hand-corrupted:
      `shomei-migrate verify` exits **2**, `shomei-admin migrate` exits **1**, and
      `shomei-server` exits **1** printing
      `[shomei] FATAL: schema migration failed: PlanVerificationFailed ...` to stderr,
      never reaching `listening on`. Probe database dropped; the dev database still reports
      28 applied migrations and 20 tables.
- [x] `just` recipes exercised (2026-08-24): `migration-check`, `migrate` (idempotent
      re-run), `migration-status`, and `new-migration` — which derived `0029` from the
      manifest, created the file, appended to the manifest atomically, and still rejects a
      non-conforming slug. Probe migration reverted.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(Entries marked *plan research* were found before implementation began; the rest during
implementation.)

- **[implementation] The dev shell provides PostgreSQL 17.10, not 18.6.** The plan's
  Context section states "The development shell in this repository provides PostgreSQL
  18.6 (`psql --version`)". The actual shell provides 17.10 (`PostgreSQL 17.10 on
  aarch64-apple-darwin25.4.0`). This is still inside `pg-migrate`'s supported range
  (17 and 18 only), so nothing is blocked, but the plan's stated evidence was wrong.

- **[implementation] The local codd ledger carried 15 stale rows — direct evidence for
  the migration away from filename-keyed history.** `codd.sql_migrations` held **43** rows
  against only 28 migration files. The 15 extras are entries from a previous filename
  convention (`2026-06-03-00-00-00-shomei-schema.sql` and siblings with sentinel
  `00-00-00` timestamps) that were later renamed to real timestamps. Because codd keys
  applied migrations by *filename*, the rename orphaned the old rows and re-applied the
  same SQL under new names. This is precisely the fragility the manifest-plus-component
  model removes, and it is why the database is dropped and recreated in M3 rather than
  imported.

- **[implementation] `cabal build` can short-circuit the manifest safety net; GHC itself
  cannot.** The plan's M2 acceptance predicted that adding an unlisted `.sql` file beside
  the manifest makes `cabal build` fail, and that a *successful* build proves the
  `RecompilePlugin` pragma is missing. Both halves are imprecise. With the pragma
  correctly in place, adding an unlisted file and running `cabal build` with no other
  change reports `Up to date`: cabal's own up-to-date check runs *before* GHC is invoked,
  and an unlisted `.sql` file is not a tracked dependency of anything, so GHC — and
  therefore the plugin and the splice — never run. As soon as anything causes cabal to
  invoke GHC for that package, the plugin fires and the check is enforced:

  ```text
  [1 of 1] Compiling Shomei.Migrations ... [Impure plugin forced recompilation]
      • invalid pg-migrate manifest: UnlistedSqlFiles ["9999-not-in-manifest.sql"]
  ```

  `pg-migrate`'s own recompilation test (`pg-migrate-embed/test/recompilation/Main.hs`)
  drives `cabal exec -- ghc --make` directly rather than `cabal build`, which is why
  upstream does not see this. The safety net is real and strictly better than `embedDir`
  — it just fires on the next compile of the module, not necessarily on the very next
  `cabal build`. `shomei-migrate check --manifest ...` is the way to force the audit on
  demand, and the `new` command appends to the manifest atomically so the gap is hard to
  reach in practice.

- **The `embedDir` staleness hazard disappears.** `shomei-migrations/src/Shomei/Migrations.hs`
  carries a 25-line comment block whose entire purpose is to force recompilation, because
  `Data.FileEmbed.embedDir` is a compile-time Template Haskell splice that does not register
  the *directory* as a dependency. Every migration wave since 2026-06-04 has appended a line
  to that comment purely to change the module's bytes. The `Justfile` `migrate` recipe
  `touch`es the `.cabal` file for the same reason and, as its own comment admits, that does
  not even work under cabal >= 3.16, which hashes content rather than checking mtime.
  `pg-migrate-embed` solves this properly: `embedMigrationManifest` registers the manifest
  and every listed `.sql` file as compiler dependencies, and the module-local
  `Database.PostgreSQL.Migrate.Embed.RecompilePlugin` pragma forces the embedding module
  alone to be re-checked on every build so that an *unlisted* new `.sql` file is caught. The
  comment block and the `touch` both get deleted.

- **Migration failure is currently swallowed at server startup.** Both
  `shomei-server/src/Shomei/Server/Boot.hs:283` and `shomei-server/app/Admin.hs:105` call
  `_ <- runShomeiMigrationsNoCheck ...`, discarding the `ApplyResult`. A failed migration
  therefore does not stop the server from booting against a half-migrated schema. The
  `pg-migrate` API returns `Either MigrationError MigrationReport`, and `-Wall` will not
  flag a discarded `Either` either — so M4 must make the failure explicitly fatal rather
  than relying on the type change to surface it.

- **All 28 migrations are transactional and none uses `CREATE INDEX CONCURRENTLY`.**
  Verified with `grep -c '^-- codd: in-txn'` (28 of 28) and `grep -i CONCURRENTLY` (no
  matches). This means no migration needs `pg-migrate`'s `-- pg-migrate: no-transaction`
  directive, and the `repair` command and its runbook are not on the critical path for this
  cutover.

- **`ephemeral-pg`'s git pin is stale, not necessary.** `cabal.project` pins
  `shinzui/ephemeral-pg` at commit `304c160f`, which `git show 304c160f:ephemeral-pg.cabal`
  reports as version `0.2.1.0`. The repository's `v0.2.2.0` tag *contains* that commit, and
  `cabal list --simple ephemeral-pg` shows `0.2.2.0` on Hackage. The pin can simply be
  deleted in favour of a Hackage bound.

- **[implementation] M5's `cabal.project` edit is a hard prerequisite of M4's build, not a
  follow-on step.** The plan orders the pin removal after M4, but M4 raises `test-support`'s
  bound to `ephemeral-pg >=0.2.2 && <0.3` while the `source-repository-package` pin still
  forces `==0.2.1.0`. The solver rejects the workspace outright:

  ```text
  [__0] rejecting: ephemeral-pg-0.2.2.0 (constraint from user target requires ==0.2.1.0)
  [__1] rejecting: shomei-migrations-0.1.0.0 (conflict: ephemeral-pg==0.2.1.0,
        shomei-migrations => ephemeral-pg>=0.2.2 && <0.3)
  ```

  The `cabal.project` pin removal was therefore pulled forward and applied before M4's
  build. Anyone replaying this plan must do the same.

- **[implementation] `shomei-server` needs a direct `pg-migrate` dependency to read the
  report.** GHC only solves `HasField` — and therefore `OverloadedRecordDot` accessors like
  `report.results` — when the record's field selector is *in scope*. Because `Boot.hs` and
  `Admin.hs` only imported `Shomei.Migrations`, `report.results` failed with
  `No instance for HasField "results" MigrationReport ...` even though the type was
  available transitively. Two follow-on notes: `length report.results` additionally leaves
  the container ambiguous (`HasField ... (t0 a0)`), so it needs `NonEmpty.length`; and the
  fix requires importing `Database.PostgreSQL.Migrate (MigrationReport (..))`, which makes
  `pg-migrate >=1.1 && <1.2` a direct dependency of both the `shomei-server` library and the
  `shomei-admin` executable. This is honest rather than incidental — that code genuinely
  branches on `pg-migrate`'s error and report types.

- **The working tree already contains an unrelated, in-flight Nix change.** `git status`
  shows uncommitted modifications to `flake.nix`, `flake.lock`, `nix/haskell.nix`,
  `nix/pre-commit.nix`, `flake.module.nix.example`, and `process-compose.yaml` from a
  `seihou` refresh. That refresh **removed every `*-src` flake input** (`codd-src`,
  `ephemeral-pg-src`, `jose-src`, `webauthn-src`, and the rest) from `flake.nix`, while
  `flake.module.nix` still references `inputs.codd-src` on line 63 and `inputs.ephemeral-pg-src`
  on line 64. The Nix `packages.default` and `packages.dockerImage` outputs are therefore
  already broken in the working tree, independently of this plan. M5 must not try to repair
  that refresh; it must only remove the two lines this plan is responsible for and note the
  remaining breakage.

  **[implementation] This no longer holds.** That refresh was committed as `3a282bf`
  ("chore(nix): upgrade nix-haskell-flake 0.11.1 -> 0.13.2") before implementation started,
  and it did **not** remove the `*-src` inputs: `flake.nix` still declares `codd-src` and
  `ephemeral-pg-src`, matching `flake.module.nix`'s references. The working tree at the
  start of M1 was clean apart from `agents/skills/release/SKILL.md` and an untracked
  `assets/`. There is therefore no pre-existing breakage to route around, and M5 removes the
  now-dead `codd-src` / `ephemeral-pg-src` **inputs** as well as the two overlay lines.


## Decision Log

Record every decision made while working on the plan.

- Decision: Renumber all 28 migration files from codd timestamps
  (`2026-06-03-18-44-51-shomei-schema.sql`) to zero-padded sequence numbers
  (`0001-shomei-schema.sql`), preserving their current chronological order exactly.
  Rationale: `pg-migrate` derives the durable migration name from the filename minus `.sql`
  and takes order from the manifest, so the timestamp no longer carries any meaning — it
  just makes every identity long. More concretely, `shomei-migrate new`'s automatic
  numbering only works when every existing basename starts with a zero-padded number of the
  same width; keeping timestamps would force `--name` on every future migration forever.
  Renaming applied migrations is normally forbidden, but nothing has durable history worth
  protecting: there is no production database and no external consumer. This is the one
  moment the rename is free. Confirmed with the user on 2026-08-24.
  Date: 2026-08-24

- Decision: Drop the `shinzui/ephemeral-pg` `source-repository-package` pin in this same
  plan and depend on Hackage `ephemeral-pg >=0.2.2 && <0.3`.
  Rationale: the stated purpose is unblocking the first Hackage release. `shomei-migrations`
  is blocked twice — by `codd` *and* by `ephemeral-pg`, because its `test-support`
  sublibrary is `visibility: public` and therefore ships in the tarball. Removing only
  `codd` would leave the package exactly as unpublishable as before, so the two removals
  belong together. Confirmed with the user on 2026-08-24.
  Date: 2026-08-24

- Decision: Do not use `pg-migrate-import-codd`.
  Rationale: that adapter exists to read an existing codd ledger and write equivalent rows
  into a `pg-migrate` ledger, so that a database with real applied history can cut over
  without re-running migrations. Shōmei has no such database. Every environment is either an
  ephemeral test database or a local development database that can be dropped and recreated
  in seconds. Importing history would also be actively wrong here, because M1 changes both
  the filenames and the bytes of every migration, so the imported rows would not match the
  new plan's checksums.
  Date: 2026-08-24

- Decision: Keep the `pg-migrate` ledger in its default `pgmigrate` schema rather than
  putting it in Shōmei's own `shomei` schema.
  Rationale: the ledger is the migration tool's bookkeeping, not part of Shōmei's data
  model. Leaving it in `pgmigrate` keeps `shomei` containing exactly the tables Shōmei's
  code queries, and means a `pg_dump -n shomei` captures application state without tool
  bookkeeping. `defaultLedgerConfig` already supplies both the schema name and the advisory
  lock key, so this is also the zero-configuration path.
  Date: 2026-08-24

- Decision: Keep a hand-written `Shomei.Migrations.TestSupport` built directly on
  `EphemeralPg.withCached` plus `runMigrationPlan`, rather than switching to
  `Database.PostgreSQL.Migrate.Test.withMigratedDatabase` from `pg-migrate-test-support`.
  Rationale: two reasons, both load-bearing. `withMigratedDatabase` hands the callback a
  `Hasql.Connection.Connection`, but every Shōmei caller needs the *connection string* to
  build its own `hasql-pool`; and `withMigratedDatabaseConfig` is implemented on
  `EphemeralPg.withConfig`, not `withCached`, which would discard the cached `initdb`
  cluster that keeps Shōmei's integration suites fast. Shōmei therefore does not depend on
  `pg-migrate-test-support` at all — one fewer package in the closure.
  Date: 2026-08-24

- Decision: Export `shomeiMigrationComponent` from `Shomei.Migrations` as public API, not
  just the assembled plan.
  Rationale: this is the reason to prefer `pg-migrate`'s design. An application embedding
  Shōmei can put `shomeiMigrationComponent` and its own components into a single
  `migrationPlan`, giving one ordered plan and one ledger for the whole database. Exporting
  only a ready-made `MigrationPlan` would make that impossible and force consumers into the
  two-ledger situation `docs/user/authorization.md` currently warns about.
  Date: 2026-08-24

- Decision: Make a failed migration fatal in `Shomei.Server.Boot.buildEnv` and in
  `shomei-admin migrate`, rather than mechanically translating the existing `_ <- ...`.
  Rationale: see Surprises & Discoveries. Preserving the current behaviour would preserve a
  latent bug — a server that boots and serves traffic against a schema that failed to
  migrate. Changing it is a one-line judgment call fully inside this plan's blast radius.
  Date: 2026-08-24


- Decision: Provide `pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`, and `ephemeral-pg`
  to the Nix overlay with `callHackageDirect` rather than `callCabal2nix` on a flake input.
  Rationale: `nix eval` confirmed the pinned nixpkgs `ghc9124` set has none of the
  `pg-migrate` packages and carries only `ephemeral-pg` 0.2.1.0, below the `>=0.2.2` bound.
  A flake input would reintroduce a git source for dependencies that are now on Hackage and
  would contradict the whole point of the change; `callHackageDirect` with pinned tarball
  hashes keeps the Nix closure aligned with the Hackage-only solve `cabal.project` performs.
  Date: 2026-08-24

- Decision: Also remove the dead `haxl` overlay entry from `flake.module.nix` and the
  `allow-newer: haxl:time` stanza from `cabal.project`.
  Rationale: both existed solely to make `codd` build. A fresh solve confirms `haxl` no
  longer appears anywhere in the build plan. The plan said to remove "only these two lines",
  but leaving a dead override for a package no longer in the closure is exactly the trap
  this plan removes elsewhere.
  Date: 2026-08-24

- Decision: Add `pg-migrate >=1.1 && <1.2` as a direct dependency of the `shomei-server`
  library and the `shomei-admin` executable.
  Rationale: forced by GHC's `HasField` rule — see Surprises & Discoveries. Both call sites
  branch on `pg-migrate`'s `MigrationError` and read `MigrationReport`, so the direct
  dependency is honest rather than incidental.
  Date: 2026-08-24

- Decision: Report a plan-level summary from `shomei-admin migrate` rather than a
  per-migration `AppliedNow`/`AlreadyApplied` breakdown.
  Rationale: the breakdown needs `MigrationOutcome (..)` and a `toList` over the report,
  and `shomei-migrate status` already renders per-migration detail properly. The admin
  command points at it instead of duplicating it.
  Date: 2026-08-24

- Decision: Rewrite `docs/user/authorization.md`'s reason 1 to say Shōmei *can* now share a
  ledger but en cannot yet, rather than claiming shared-ledger operation is now supported.
  Rationale: the plan warned against overselling. `pg-migrate`'s component model genuinely
  makes one-plan/one-ledger a supported arrangement on Shōmei's side, but `en` still runs on
  codd, so today the two projects would still bring mutually unaware bookkeeping into one
  database. Reason 2 (en's per-database consistency machinery) remains the stronger argument
  and is unchanged.
  Date: 2026-08-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

**The purpose was met, and the central claim is verified rather than argued.** Before this
change the release runbook concluded that "only `shomei-core` can actually be published."
After it, a Hackage-only solve of the `shomei-migrations` sdist — run with `--enable-tests`
in a scratch directory with no `cabal.project`, so no `source-repository-package` pin
applies — resolves every dependency from Hackage:

```text
 - ephemeral-pg-0.2.2.0 (lib) (requires build)
 - pg-migrate-1.1.0.0 (lib) (requires build)
 - pg-migrate-embed-1.1.0.0 (lib) (requires build)
 - shomei-migrations-0.1.0.0 (lib) (first run)
 - pg-migrate-cli-1.1.0.0 (lib) (requires build)
 - shomei-migrations-0.1.0.0 (lib:test-support) (first run)
```

`shomei-postgres` has no third-party blocker left either; its sdist solve fails only on
`unknown package: shomei-core`, which is upload ordering, not a blocker. The releasable set
goes from one package to three. `jose` 0.13 and the `webauthn` fork are now the only
remaining upstream blockers, and they gate a different set of packages.

**The other two goals also landed.** `shomei-migrate` is a real CLI (`plan`, `list`,
`check`, `status`, `verify`, `up`, `repair`, `new`, each with `--json`) that reports before
it changes anything. And `shomeiMigrationComponent` is exported, so a host application can
compose Shōmei's schema with its own into one plan and one ledger.

**Schema integrity was proven three independent ways**, which matters because M1 renamed
every file and rewrote its first two bytes:

1. SHA-256 of all 28 header-stripped bodies, captured before M1, matched byte-for-byte
   after.
2. `shomei-migrate list` printed checksums identical to those recorded hashes — so what
   `pg-migrate` embedded is exactly what was verified.
3. The `shomei` schema contains **20 tables** after a from-scratch apply, the same count as
   the pre-change database, and all 13 test suites pass.

**What went differently from the plan.** Four things, all recorded in Surprises &
Discoveries: the `cabal.project` pin removal is a *prerequisite* of M4 rather than a
follow-on; `cabal build` can short-circuit the manifest safety net that the plan expected it
to trip (the net is real, but it fires on the next compile of the module, not necessarily
the next `cabal build`); `shomei-server` needs a direct `pg-migrate` dependency because GHC
only solves `HasField` for fields in scope; and the in-flight Nix breakage the plan told the
implementer to route around had already been committed and did not exist.

**Loose ends, stated plainly.**

- The Nix `packages.default` / `dockerImage` outputs were **not** built end-to-end. The
  overlay was updated with `callHackageDirect` entries pinned to verified Hackage tarball
  hashes and `nix flake lock` prunes cleanly, but building that closure compiles the whole
  Haskell dependency tree from source and was out of proportion to this plan's acceptance
  criteria, which are all Cabal-side. Anyone touching the Nix image path should build it
  once before relying on it.
- No ADR was created. This repository has no `docs/adr/` corpus and the plan explicitly
  forbids introducing one as an incidental edit, so the durable context — the component
  model, the ledger-in-`pgmigrate` decision, the `HasField` gotcha, and the manifest
  recompilation nuance — stays in this file's Decision Log and Surprises & Discoveries.
- The connection-timeout behaviour noted in M4 is unchanged: `RunOptions` has no connection
  timeout, so the old codd call's 60-second bound has no equivalent. Nothing observed during
  implementation suggested this matters, but it has not been exercised against a slow or
  unreachable database.


## Context and Orientation

### Architecture decision records

This repository has **no `docs/adr/` directory**. `mori.dhall` declares exactly one OKF
bundle, `improvement-requests` at `docs/improvement-requests`, and no architecture-decision
bundle. There is therefore no existing ADR relevant to this work, and none to cite. Per the
plan skill's ADR workflow, do **not** create `docs/adr/` or introduce OKF frontmatter as an
incidental edit of this plan; adopting an ADR corpus is separate work. Durable context from
this plan stays in this file's Decision Log until such a corpus exists.

The repository's durable design context lives instead in `docs/masterplans/` and
`docs/plans/`. The relevant history is that
`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md` introduced the
`shomei-migrations` package with codd in its EP-3, and every MasterPlan since has appended
migrations under the convention described there.

### What exists today

The repository is a Cabal workspace of eight `shomei-*` packages plus two example
applications, listed in `cabal.project`. The package this plan mostly touches is
`shomei-migrations`, which has three build targets defined in
`shomei-migrations/shomei-migrations.cabal`:

- a **library** exposing the single module `shomei-migrations/src/Shomei/Migrations.hs`;
- an **executable** `shomei-migrate` whose entire source is
  `shomei-migrations/app/Main.hs` (nine lines);
- a **public sublibrary** `test-support` exposing
  `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`.

"Public sublibrary" is a Cabal feature: a second library inside the same package, marked
`visibility: public`, that other packages depend on as `shomei-migrations:test-support`.
The important consequence is that it is part of the published tarball, so *its*
dependencies must resolve from Hackage too.

The 28 SQL files live flat in `shomei-migrations/sql-migrations/`. Each is named
`YYYY-MM-DD-HH-MM-SS-<slug>.sql` and begins with the two lines:

```sql
-- codd: in-txn

```

`-- codd: in-txn` is a directive telling codd to run the file inside a transaction. Most
files then contain `SET search_path TO shomei, pg_catalog;` before their `CREATE TABLE` or
`ALTER TABLE` statements. The very first migration,
`2026-06-03-18-44-51-shomei-schema.sql`, is just `CREATE SCHEMA IF NOT EXISTS shomei;`.

`Shomei.Migrations` embeds that whole directory at compile time with
`Data.FileEmbed.embedDir`, parses each file with codd's parser, and exposes three values:
`shomeiMigrations` (the parsed list), `runShomeiMigrationsNoCheck` (applies them, skipping
codd's "expected schema" verification), and `coddSettingsFromConnString` (builds a
`CoddSettings` record from a libpq connection string instead of from the `CODD_*`
environment).

There are exactly four consumers of that module:

1. `shomei-migrations/app/Main.hs` — the `shomei-migrate` executable, which reads
   `CoddSettings` from the environment via `Codd.Environment.getCoddSettings`.
2. `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs` — exposes
   `withShomeiMigratedDatabase :: (Text -> IO a) -> IO a`, which starts a cached ephemeral
   PostgreSQL, applies the schema, and hands the callback a connection string.
3. `shomei-server/src/Shomei/Server/Boot.hs`, in `buildEnv` at line 283 — the server
   migrates its own database on startup before acquiring its connection pool.
4. `shomei-server/app/Admin.hs`, in `run` at line 105 — the `shomei-admin migrate`
   subcommand.

`withShomeiMigratedDatabase` in turn has many callers across `shomei-postgres`,
`shomei-server`, `shomei-client`, and both examples. None of them will change: this plan
deliberately keeps that function's name and type identical.

Outside Haskell, codd appears in `Justfile` (the `migrate` and `new-migration` recipes),
`cabal.project` (a `source-repository-package` and a `package codd` stanza), `flake.nix`
and `flake.module.nix` (the Nix build), `mori.dhall` (the project's dependency catalogue),
`README.md`, `docs/user/architecture.md`, `docs/user/authorization.md`, `Dockerfile` (a
comment), and `agents/skills/release/SKILL.md` (the Hackage blocker tables).

### What pg-migrate is, in plain terms

`pg-migrate` version 1.1.0.0 is a family of six Haskell packages. This plan uses three of
them, all from Hackage:

- **`pg-migrate`** — the model and the runner. It defines a `Migration` (a name plus exact
  SQL bytes plus a SHA-256 checksum), a `MigrationComponent` (a stable component name, a set
  of other component names it depends on, and a non-empty ordered list of migrations), and a
  `MigrationPlan` (a validated, dependency-ordered collection of components). `runMigrationPlan`
  applies a plan; `migrationStatus` and `verifyMigrationPlan` inspect one without changing it.
- **`pg-migrate-embed`** — a Template Haskell splice, `embedMigrationManifest`, that reads a
  manifest file at compile time, validates it, and embeds the exact bytes of every listed
  `.sql` file into the binary. It ships a companion GHC plugin,
  `Database.PostgreSQL.Migrate.Embed.RecompilePlugin`, which must be enabled with a
  module-local `OPTIONS_GHC` pragma in every module that uses the splice.
- **`pg-migrate-cli`** — an `optparse-applicative` parser and command dispatcher that an
  application mounts into its own executable. It is a *library*, not a binary: the
  application supplies the plan and the database configuration, so an independently
  installed tool can never discover a different plan than the service it migrates.

A **manifest** is a plain UTF-8 text file listing one `.sql` filename per line, in
execution order, with no comments, no directives, no header, and no paths. Its validator is
strict: it rejects blank lines, leading or trailing whitespace, duplicate entries, missing
files, and — importantly — any `.sql` file sitting beside the manifest that the manifest
does not list. That last rule is what catches "I created the migration but forgot to wire
it in."

The **ledger** is `pg-migrate`'s bookkeeping: a schema (by default named `pgmigrate`)
holding a `migrations` table keyed by `(component, migration)` plus tables for repairs and
history imports. A transactional migration and its ledger row commit in the same PostgreSQL
transaction, so they cannot disagree.

The durable identity of a migration is `<component>/<migration>` — for Shōmei, after M1,
`shomei/0001-shomei-schema`.

Two hard constraints to know before starting. `pg-migrate` supports **PostgreSQL 17 and 18
only**; it queries `server_version_num` on connect and returns
`UnsupportedPostgresVersion` otherwise. The development shell in this repository provides
PostgreSQL 18.6 (`psql --version`), so this is satisfied. And SQL migrations must not
contain transaction-control statements (`BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`), psql
meta-commands, or `COPY FROM STDIN`; the runner owns the transaction boundary. None of
Shōmei's 28 files violate this — verified by `grep`.

### Development environment

All commands in this plan run from the repository root,
`/Users/shinzui/Keikaku/bokuno/shomei`, inside the Nix development shell:

```bash
nix develop
```

That shell exports `PGHOST` (a Unix socket directory at `./db`), `PGDATA`, `PGDATABASE`,
and `PG_CONNECTION_STRING`, and puts `just`, `psql`, `cabal`, and `process-compose` on the
`PATH`. `process-compose up --no-server` brings up the whole local stack. A PostgreSQL
server may already be running against `./db` from earlier work.


## Plan of Work

The work splits into five milestones. M1 touches only files on disk and can be verified
without compiling anything. M2 and M3 rebuild the `shomei-migrations` package and its
executable. M4 moves the four consumers. M5 removes the dependency pins and updates the
prose, which is where the release-unblocking payoff is actually observed. Each milestone
leaves the tree in a state where the previous milestone's verification still passes, except
that between M2 and M4 the workspace does not fully build — M2 and M3 change the library's
API, and M4 is what updates the callers. Treat M2, M3, and M4 as one commit boundary if you
prefer a green tree at every commit; the plan describes them separately because their
verification steps differ.

### Milestone 1 — Restructure the migration sources

**Scope.** Move the 28 `.sql` files from `shomei-migrations/sql-migrations/` to
`shomei-migrations/migrations/shomei/`, renaming each to a four-digit sequence number that
preserves the existing chronological order; delete the two-line `-- codd: in-txn` header
from each; and write `shomei-migrations/migrations/shomei/manifest`.

**Why this shape.** The new directory is named `migrations/<component>/` because a manifest
belongs beside the files of exactly one component, and Shōmei's component is named `shomei`.
Keeping the old `sql-migrations/` name would work but would misleadingly suggest the old
flat, order-by-filename layout. The `-- codd: in-txn` line is only a comment to
`pg-migrate` — it would be accepted, since only `-- pg-migrate:` prefixed comments are
parsed as directives — but leaving a directive for a tool the project no longer uses is a
trap for the next reader. `pg-migrate` treats SQL as transactional by default, so deleting
the line is also semantically exact.

**What exists at the end.** A `migrations/shomei/` directory containing 28 renumbered
`.sql` files and one `manifest`, and an empty (deleted) `sql-migrations/` directory. The
old Haskell still compiles at this point only if you have not yet touched it — you have
not; but it will no longer find its migrations, because `embedDir "sql-migrations"` now
points at nothing. That is expected and is repaired in M2. Do M1 and M2 in one sitting.

**Acceptance.** The manifest lists 28 filenames; every listed file exists; no unlisted
`.sql` file sits beside it; and the SQL bodies are byte-identical to the originals apart
from the removed header.

The rename mapping, in order, is:

```text
2026-06-03-18-44-51-shomei-schema.sql                       -> 0001-shomei-schema.sql
2026-06-03-18-44-52-shomei-users.sql                        -> 0002-shomei-users.sql
2026-06-03-18-44-53-shomei-password-credentials.sql         -> 0003-shomei-password-credentials.sql
2026-06-03-18-44-54-shomei-sessions.sql                     -> 0004-shomei-sessions.sql
2026-06-03-18-44-55-shomei-refresh-tokens.sql               -> 0005-shomei-refresh-tokens.sql
2026-06-03-18-44-56-shomei-signing-keys.sql                 -> 0006-shomei-signing-keys.sql
2026-06-03-18-44-57-shomei-auth-events.sql                  -> 0007-shomei-auth-events.sql
2026-06-04-05-46-54-shomei-users-email-verified.sql         -> 0008-shomei-users-email-verified.sql
2026-06-04-05-46-55-shomei-email-verification-tokens.sql    -> 0009-shomei-email-verification-tokens.sql
2026-06-04-05-46-56-shomei-password-reset-tokens.sql        -> 0010-shomei-password-reset-tokens.sql
2026-06-05-12-37-20-shomei-login-attempts.sql               -> 0011-shomei-login-attempts.sql
2026-06-05-12-37-21-shomei-account-lockouts.sql             -> 0012-shomei-account-lockouts.sql
2026-06-17-12-07-46-shomei-sessions-actor.sql               -> 0013-shomei-sessions-actor.sql
2026-06-18-10-33-55-shomei-webauthn-credentials.sql         -> 0014-shomei-webauthn-credentials.sql
2026-06-18-10-33-56-shomei-webauthn-pending-ceremonies.sql  -> 0015-shomei-webauthn-pending-ceremonies.sql
2026-06-19-16-55-51-shomei-users-login-id.sql               -> 0016-shomei-users-login-id.sql
2026-06-19-16-55-52-shomei-users-email-optional.sql         -> 0017-shomei-users-email-optional.sql
2026-06-19-16-55-53-shomei-password-credentials-login-id.sql -> 0018-shomei-password-credentials-login-id.sql
2026-06-19-16-55-54-shomei-password-credentials-email-optional.sql -> 0019-shomei-password-credentials-email-optional.sql
2026-07-09-13-51-07-sweeper-indexes-and-retention.sql       -> 0020-sweeper-indexes-and-retention.sql
2026-07-09-20-34-28-shomei-role-grants.sql                  -> 0021-shomei-role-grants.sql
2026-07-10-03-54-27-shomei-service-accounts.sql             -> 0022-shomei-service-accounts.sql
2026-07-10-14-15-52-shomei-oauth-clients.sql                -> 0023-shomei-oauth-clients.sql
2026-07-10-14-55-38-shomei-oauth-authorization-codes.sql    -> 0024-shomei-oauth-authorization-codes.sql
2026-07-10-15-25-43-shomei-sessions-oauth-client.sql        -> 0025-shomei-sessions-oauth-client.sql
2026-07-10-18-00-02-shomei-totp-credentials.sql             -> 0026-shomei-totp-credentials.sql
2026-07-10-18-00-03-shomei-recovery-codes.sql               -> 0027-shomei-recovery-codes.sql
2026-07-11-00-15-02-shomei-role-permissions.sql             -> 0028-shomei-role-permissions.sql
```

That mapping is exactly `ls sql-migrations/*.sql | sort` with the timestamp prefix replaced
by a counter, so it is reproducible mechanically rather than transcribed by hand — the
Concrete Steps section does it with a loop.

### Milestone 2 — Rewrite `Shomei.Migrations` on pg-migrate

**Scope.** Replace `shomei-migrations/src/Shomei/Migrations.hs` entirely and update
`shomei-migrations/shomei-migrations.cabal`.

The new module is much shorter than the old one, because `pg-migrate` does the parsing,
ordering, checksumming, and transaction handling. It exports four things:

- `shomeiMigrationComponent :: Either DefinitionError MigrationComponent` — Shōmei's
  component, named `"shomei"`, depending on no other component, built from the embedded
  manifest. This is the value a host application composes with its own components.
- `shomeiMigrationPlan :: Either DefinitionError (Either PlanError MigrationPlan)` — the
  ready-made single-component plan for anyone who only wants Shōmei's schema. The doubly
  nested `Either` is `pg-migrate`'s shape: the outer failure means a component was defined
  invalidly, the inner means valid components could not be ordered into a plan.
- `resolveShomeiMigrationPlan :: IO MigrationPlan` — a convenience that unwraps both layers
  and throws with a readable message. Both plan construction failures are programmer
  errors in a compiled binary (the SQL is embedded and validated at compile time), so
  failing loudly at startup is correct.
- `applyShomeiMigrations :: Text -> IO (Either MigrationError MigrationReport)` — applies
  the plan to the database named by a libpq connection string, using `defaultRunOptions`.
  This is the direct replacement for `runShomeiMigrationsNoCheck` plus
  `coddSettingsFromConnString`, which both disappear.

Note what is *not* in the new module: no `EnvVars`/`MonadFail` constraints, no attoparsec
connection-string parser, no `CoddSettings` placeholder record with a fake `DbRep`, and no
25-line comment block existing solely to defeat a recompilation check.

The cabal file loses `codd`, `file-embed`, `attoparsec`, `streaming`, and `aeson` from the
library stanza, and gains `pg-migrate` and `pg-migrate-embed`. `extra-source-files` changes
from `sql-migrations/*.sql` to `migrations/shomei/*.sql` plus `migrations/shomei/manifest`
— the manifest must be listed explicitly because it has no extension and no glob would
catch it, and if it is missing from the source distribution the package will not compile
from a Hackage tarball. The `synopsis` and `description` stop saying "codd".

**Acceptance.** `cabal build shomei-migrations:lib:shomei-migrations` succeeds. Deliberately
breaking the manifest (adding a stray unlisted `.sql` file) makes the build fail with a
manifest error, proving the compile-time validation is live.

### Milestone 3 — Replace the `shomei-migrate` executable

**Scope.** Rewrite `shomei-migrations/app/Main.hs` as a `pg-migrate-cli` mount, add the CLI
dependencies to the executable stanza, and rewrite the `migrate` and `new-migration`
recipes in `Justfile`.

The new `Main.hs` follows the structure `pg-migrate`'s own documentation prescribes:
resolve the plan, parse the command with `migrationCommandParser plan`, read the database
URL from the environment, build a `CliEnvironment` with `cliEnvironment`, dispatch with
`runMigrationCommand`, render with `renderMigrationCommandText` or
`renderMigrationCommandJson` depending on the parsed `--json` flag, and exit with a code
derived from the outcome's `ExitClass`.

Two application-owned policy decisions to make explicitly here. First, the connection
string comes from `DATABASE_URL`, matching what `shomei-admin` and
`process-compose.yaml`'s `bootstrap_keys` step already use, rather than inventing a
`SHOMEI_*` variable or reviving the `CODD_*` ones. Second, map the four exit classes
distinctly — `ExitSucceeded` to 0, `ExitVerificationFailed` to 2, `ExitUsageFailed` to 64,
`ExitExecutionFailed` to 1 — rather than collapsing everything to 1, so that a deployment
script can tell "the plan does not match the database" from "the migration blew up."

Commands that do not touch a database (`plan`, `list`, `check`, `new`) should not require
`DATABASE_URL`. Read the variable lazily, defaulting to an empty connection setting only
when it is absent, so `shomei-migrate plan` works in a checkout with no PostgreSQL running.

The `Justfile` changes are a net deletion. `migrate` loses the `touch` line and all four
`CODD_*` variables, becoming a `shomei-migrate up` invocation against `DATABASE_URL`.
`new-migration` loses its hand-rolled slug validation, timestamp generation, and
`printf` template entirely, delegating to `shomei-migrate new --manifest ... --name ...`,
which creates the file exclusively and appends to the manifest atomically. Both recipes'
long comment blocks about `embedDir` staleness get deleted, because the hazard they warn
about no longer exists.

**Acceptance.** `cabal run shomei-migrate -- plan` and `-- list` print the component and
all 28 migrations with checksums, without a database. Against a freshly created database,
`status` reports 28 pending, `up` applies them, a second `up` reports them all already
applied, and `verify` succeeds.

### Milestone 4 — Move test-support and the server

**Scope.** Rewrite `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`,
update its cabal stanza, and update `shomei-server/src/Shomei/Server/Boot.hs` and
`shomei-server/app/Admin.hs`.

`withShomeiMigratedDatabase :: (Text -> IO a) -> IO a` keeps its exact name and type, so
none of its many callers across `shomei-postgres`, `shomei-server`, `shomei-client`,
`examples/embedded-servant-app`, and `examples/microservice-auth-stack` need to change. Its
body swaps `runShomeiMigrationsNoCheck (coddSettingsFromConnString connStr) ...` for
`applyShomeiMigrations connStr`, and — unlike the current version, which discards the
result — pattern-matches the `Either` and calls `error` with the rendered `MigrationError`
on failure. A test that silently runs against an unmigrated database produces confusing
downstream failures; failing at provisioning time is much easier to diagnose.

Its cabal stanza drops `codd`, `aeson`, `attoparsec`, `containers`, and `time`, and gains
`pg-migrate`. It keeps `ephemeral-pg`, now from Hackage (see M5).

In `Shomei.Server.Boot.buildEnv`, the single line at 283 becomes an `applyShomeiMigrations`
call whose `Left` branch writes the error to `stderr` and exits non-zero rather than
proceeding to `acquirePool`. Note the surrounding function already writes structured
startup diagnostics to `stderr`; match that style. The 60-second connect timeout the codd
call passed has no direct `pg-migrate` equivalent — `RunOptions` has `withLockWait` for
advisory-lock waiting and `withStatementTimeout` for statement duration, neither of which
is a connection timeout — so simply use `defaultRunOptions` and record this in Surprises &
Discoveries if it turns out to matter operationally.

In `shomei-server/app/Admin.hs`, the `Migrate` branch does the same and prints a summary
drawn from the `MigrationReport` (which carries `startedAt`, `finishedAt`, and a non-empty
`results` list of per-migration outcomes) instead of the current bare
`putStrLn "migrations applied"`. Do not print full connection strings anywhere; they may
carry passwords.

**Acceptance.** `cabal build all` succeeds and `cabal test all` is green — in particular
`shomei-postgres`' integration suite, `shomei-server`'s E2E and admin suites, and
`shomei-client`'s suite, all of which provision databases through
`withShomeiMigratedDatabase`.

### Milestone 5 — Drop the pins and update the prose

**Scope.** This is where the release-unblocking result becomes observable.

In `cabal.project`, delete the `source-repository-package` block for
`https://github.com/mzabani/codd.git`, the `source-repository-package` block for
`https://github.com/shinzui/ephemeral-pg.git`, and the `package codd { tests: False;
benchmarks: False }` stanza. Rewrite the surrounding "EP-3 (persistence)" comment to say
that both dependencies now resolve from Hackage. Leave the `jose`, `webauthn`, and
`allow-newer` blocks alone — they are other packages' blockers and out of scope.

In `flake.module.nix`, delete the `codd = ...` and `ephemeral-pg = ...` overlay lines
(currently lines 63 and 64) and the `mori://mzabani/codd/repos/codd` and
`mori://shinzui/ephemeral-pg/repos/ephemeral-pg` comment references. Whether `pg-migrate`
needs overlay entries depends on whether the pinned nixpkgs' `ghc9124` package set already
carries it; check with `nix eval` before adding anything. **Do not attempt to repair the
in-flight `seihou` refresh described in Surprises & Discoveries** — `flake.nix` no longer
declares the `*-src` inputs that `flake.module.nix` still references, so the Nix build is
already broken for reasons unrelated to this plan. Remove only these two lines, verify the
Cabal build, and record the remaining Nix breakage in Surprises & Discoveries for whoever
finishes the refresh.

In `mori.dhall`, replace `"mzabani/codd"` in the `dependencies` list with
`"shinzui/pg-migrate"`, and update the `shomei-migrations` package `description` from
"codd-managed PostgreSQL schema migrations (embedded SQL) plus a public test-support
sublibrary (ephemeral-pg)" to name `pg-migrate` instead.

In `README.md` line 31, change the `shomei-migrations` table row from "`codd`-managed SQL
schema" to name `pg-migrate`.

In `docs/user/architecture.md`, the "Persistence and migrations" section (around line 67)
says state is "managed by timestamped `codd` migrations under
`shomei-migrations/sql-migrations/`". Update both the tool name and the path, and drop
"timestamped" since the files are now sequence-numbered.

In `docs/user/authorization.md`, the "Database topology" section's reason 1 currently reads
"Two codd migration ledgers in one database is unverified." Rewrite it: with `pg-migrate`,
a host application can compose `shomeiMigrationComponent` with another library's component
into one plan and one ledger, which is a supported arrangement rather than an unverified
one. Be careful and honest about scope — `en` has not itself moved to `pg-migrate`, and
reason 2 (en's `pg_current_snapshot()`-based consistency being inherently per-database) is
unaffected and remains the stronger argument for separate databases. Do not oversell.

In `agents/skills/release/SKILL.md`, update the "Non-Hackage dependency blockers" table to
delete the `mzabani/codd` and `shinzui/ephemeral-pg` rows, delete the block-quoted
"`ephemeral-pg` is not 'tests only'" warning, and recompute the per-package releasability
table. After this milestone `shomei-migrations` and `shomei-postgres` should both become
releasable, and `shomei-server` should be left blocked only by `jose` 0.13 and the
`webauthn` fork. **Verify that recomputation with an actual solve** (see Validation) rather
than reasoning it out — this file is already modified in the working tree by the in-flight
`seihou` refresh, so re-read it before editing.

In `Dockerfile` line 5, the comment listing pinned source-repository-packages mentions
`codd` and `ephemeral-pg`; update it.

**Acceptance.** `cabal build all` succeeds with no `codd` and no `ephemeral-pg` git
checkout in `dist-newstyle/src/`, and the Hackage-only sdist solve for `shomei-migrations`
described in Validation succeeds.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

### M1 — restructure the sources

Create the new directory and move the files with a loop that derives the numbering from
sort order, so the mapping cannot drift from the table above:

```bash
mkdir -p shomei-migrations/migrations/shomei
n=0
for f in $(ls shomei-migrations/sql-migrations/*.sql | sort); do
  n=$((n + 1))
  base=$(basename "$f" .sql)
  slug=${base#????-??-??-??-??-??-}
  printf -v num '%04d' "$n"
  git mv "$f" "shomei-migrations/migrations/shomei/$num-$slug.sql"
done
rmdir shomei-migrations/sql-migrations
```

Confirm 28 files landed with the expected names:

```bash
ls shomei-migrations/migrations/shomei/ | head -3
ls shomei-migrations/migrations/shomei/*.sql | wc -l
```

Expected:

```text
0001-shomei-schema.sql
0002-shomei-users.sql
0003-shomei-password-credentials.sql
      28
```

Strip the codd directive. Each file starts with `-- codd: in-txn` followed by one blank
line; remove both so the file begins at its first real line:

```bash
for f in shomei-migrations/migrations/shomei/*.sql; do
  perl -0pi -e 's/\A-- codd: in-txn\n\n//' "$f"
done
grep -rn 'codd' shomei-migrations/migrations/shomei/ || echo "no codd references remain"
```

Expected final line:

```text
no codd references remain
```

Write the manifest from the same sort order:

```bash
ls shomei-migrations/migrations/shomei/*.sql \
  | sort \
  | xargs -n1 basename \
  > shomei-migrations/migrations/shomei/manifest
wc -l < shomei-migrations/migrations/shomei/manifest
head -2 shomei-migrations/migrations/shomei/manifest
```

Expected:

```text
      28
0001-shomei-schema.sql
0002-shomei-users.sql
```

Sanity-check that the SQL bodies survived intact — the first migration should now be just
its comment and `CREATE SCHEMA`:

```bash
cat shomei-migrations/migrations/shomei/0001-shomei-schema.sql
```

Expected:

```sql
-- Create the dedicated Shōmei namespace. Idempotent.
CREATE SCHEMA IF NOT EXISTS shomei;
```

### M2 — rewrite the library

Replace `shomei-migrations/src/Shomei/Migrations.hs` with:

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

-- | Shōmei's PostgreSQL schema as a @pg-migrate@ component.
--
-- The SQL under @migrations\/shomei\/@ is embedded at compile time from the ordered
-- manifest beside it, so a built binary never reads the migration directory at runtime.
--
-- Host applications that also own migrations should compose 'shomeiMigrationComponent'
-- with their own components into a single 'MigrationPlan', so the whole database is
-- described by one plan and tracked by one ledger. Applications that only need Shōmei's
-- schema can use 'shomeiMigrationPlan' or 'applyShomeiMigrations' directly.
module Shomei.Migrations
  ( shomeiMigrationComponent,
    shomeiMigrationPlan,
    resolveShomeiMigrationPlan,
    applyShomeiMigrations,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Hasql.Connection.Settings qualified as Settings

-- | Shōmei's migration component. Its durable identities are @shomei\/0001-shomei-schema@
-- and so on, in manifest order. It depends on no other component.
shomeiMigrationComponent :: Either DefinitionError MigrationComponent
shomeiMigrationComponent =
  migrationComponentFromEmbeddedSql
    "shomei"
    Set.empty
    $(embedMigrationManifest "migrations/shomei/manifest")

-- | A single-component plan containing only Shōmei's schema.
shomeiMigrationPlan :: Either DefinitionError (Either PlanError MigrationPlan)
shomeiMigrationPlan = do
  component <- shomeiMigrationComponent
  pure (migrationPlan (component :| []))

-- | Resolve 'shomeiMigrationPlan', failing loudly. Both failure modes are programmer
-- errors in a compiled binary: the SQL is embedded and validated at compile time.
resolveShomeiMigrationPlan :: IO MigrationPlan
resolveShomeiMigrationPlan =
  case shomeiMigrationPlan of
    Left definitionError -> fail ("Invalid Shōmei migration component: " <> show definitionError)
    Right (Left planError) -> fail ("Invalid Shōmei migration plan: " <> show planError)
    Right (Right plan) -> pure plan

-- | Apply Shōmei's schema to the database named by a libpq connection string, using
-- @pg-migrate@'s default ledger (schema @pgmigrate@), indefinite advisory-lock waiting,
-- and no statement timeout. Idempotent: already-applied migrations are reported as such
-- and not re-run.
applyShomeiMigrations :: Text -> IO (Either MigrationError MigrationReport)
applyShomeiMigrations connStr = do
  plan <- resolveShomeiMigrationPlan
  runMigrationPlan defaultRunOptions (Settings.connectionString connStr) plan
```

Then edit `shomei-migrations/shomei-migrations.cabal`. Update the header fields:

```cabal
synopsis:           Schema migrations for Shōmei (pg-migrate component, embedded SQL)
description:
  Owns Shōmei's PostgreSQL schema. Embeds Shōmei's ordered SQL manifest at compile
  time with pg-migrate-embed and exposes it as a pg-migrate MigrationComponent that a
  host application can compose with its own migrations. Also exposes a public
  test-support sublibrary that provisions a fresh ephemeral PostgreSQL with the
  schema applied.

extra-source-files:
  migrations/shomei/*.sql
  migrations/shomei/manifest
```

Replace the library stanza's `build-depends` with:

```cabal
  build-depends:
    , base              >=4.18 && <5
    , containers        >=0.7  && <0.8
    , hasql             >=1.10 && <1.11
    , pg-migrate        >=1.1  && <1.2
    , pg-migrate-embed  >=1.1  && <1.2
    , text
```

Build the library:

```bash
cabal build shomei-migrations:lib:shomei-migrations
```

Prove the compile-time manifest validation is live by adding a stray file and rebuilding:

```bash
touch shomei-migrations/migrations/shomei/9999-not-in-manifest.sql
cabal build shomei-migrations:lib:shomei-migrations   # must FAIL
rm shomei-migrations/migrations/shomei/9999-not-in-manifest.sql
cabal build shomei-migrations:lib:shomei-migrations   # must succeed again
```

The failing build should name the unlisted file. If it *succeeds*, the `RecompilePlugin`
pragma is missing or misspelled — that pragma is what forces the sibling-file audit to
re-run.

### M3 — replace the executable

Replace `shomei-migrations/app/Main.hs` with:

```haskell
-- | @shomei-migrate@: the operator CLI for Shōmei's schema.
--
-- The plan is embedded at compile time, so this binary can only ever migrate the schema
-- it was built with. The application owns configuration (@DATABASE_URL@, overridable per
-- command with @--database-url@), rendering, and the process exit code.
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate (defaultRunOptions)
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
import Shomei.Migrations (resolveShomeiMigrationPlan)
import System.Environment (lookupEnv)
import System.Exit qualified as System.Exit

main :: IO ()
main = do
  plan <- resolveShomeiMigrationPlan
  parsedCommand <-
    execParser
      ( info
          (migrationCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage the Shōmei database schema" <> header "shomei-migrate")
      )
  -- Absent DATABASE_URL is fine for plan/list/check/new, which never connect. The
  -- database-backed commands fail at acquisition with a clear connection error.
  databaseUrl <- maybe "" Text.pack <$> lookupEnv "DATABASE_URL"
  let environment =
        cliEnvironment (Settings.connectionString databaseUrl) plan defaultRunOptions
  outcome <- runMigrationCommand environment parsedCommand
  case commandOutputFormat parsedCommand of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  System.Exit.exitWith (exitCode (exitClass outcome))

-- | Distinct codes so deployment automation can tell a plan/ledger mismatch from a
-- failed apply from a bad invocation.
exitCode :: ExitClass -> System.Exit.ExitCode
exitCode = \case
  ExitSucceeded -> System.Exit.ExitSuccess
  ExitVerificationFailed -> System.Exit.ExitFailure 2
  ExitUsageFailed -> System.Exit.ExitFailure 64
  ExitExecutionFailed -> System.Exit.ExitFailure 1

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat = \case
  Plan PlanOptions {output = OutputOptions format} -> format
  List ListOptions {output = OutputOptions format} -> format
  Check CheckOptions {output = OutputOptions format} -> format
  Status StatusOptions {output = OutputOptions format} -> format
  Verify VerifyOptions {output = OutputOptions format} -> format
  Up UpOptions {output = OutputOptions format} -> format
  Repair RepairOptions {output = OutputOptions format} -> format
  New NewOptions {output = OutputOptions format} -> format
```

Update the executable stanza in `shomei-migrations/shomei-migrations.cabal`:

```cabal
executable shomei-migrate
  import:         warnings, shared
  main-is:        Main.hs
  hs-source-dirs: app
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , aeson                 >=2.1  && <2.3
    , base
    , bytestring
    , hasql                 >=1.10 && <1.11
    , optparse-applicative  >=0.19 && <0.20
    , pg-migrate            >=1.1  && <1.2
    , pg-migrate-cli        >=1.1  && <1.2
    , shomei-migrations
    , text
```

`LambdaCase` is part of `GHC2024`, which the `shared` common stanza already sets as
`default-language`, so the `\case` expressions above need no extra extension.

Now rewrite the two `Justfile` recipes, deleting their obsolete comment blocks:

```make
# Apply all embedded migrations to $PGDATABASE via the shomei-migrate executable.
# Idempotent: already-applied migrations are reported and skipped.
migrate:
    DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 shomei-migrate -- up

# Show which migrations are applied and which are pending, without changing anything.
migration-status:
    DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 shomei-migrate -- status

# Scaffold a new migration and append it to the manifest atomically:
#   just new-migration add-something
new-migration slug:
    @echo "{{slug}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "Invalid slug: {{slug}}"; exit 1; }
    @next=$(printf '%04d' $(( $(sed -n '$p' shomei-migrations/migrations/shomei/manifest | cut -c1-4 | sed 's/^0*//') + 1 ))); \
    cabal run -v0 shomei-migrate -- new \
      --manifest shomei-migrations/migrations/shomei/manifest \
      --name "$next-{{slug}}" \
      --description "{{slug}}"
```

Two details in that recipe are deliberate. The slug validation is carried over from the old
recipe because `pg-migrate`'s `new` accepts any valid basename, and Shōmei wants its
lowercase-and-hyphens convention enforced. The number is computed from the last line of the
manifest rather than left to `new`'s own inference, because `new`'s automatic numbering
produces a bare `0029.sql` with no descriptive suffix; passing an explicit
`--name 0029-add-something` keeps both the ordering prefix and the human-readable name in
one atomic file-plus-manifest operation. Note this recipe reads the manifest, which is the
authoritative order, not the directory listing.

Now recreate the development database and exercise the CLI. The existing local database
still carries codd's bookkeeping and the old schema, so drop it:

```bash
dropdb --if-exists "$PGDATABASE"
createdb "$PGDATABASE"
```

If `dropdb` reports the database is in use, stop the stack first: `process-compose down`,
or `pg_ctl stop -D "$PGDATA"` followed by a restart.

Inspect the plan without a database:

```bash
cabal run -v0 shomei-migrate -- plan
cabal run -v0 shomei-migrate -- list
```

`plan` should show one component, `shomei`, with no dependencies. `list` should show 28
migrations with positions 1 through 28, kind `sql`, transaction mode `transactional`, and a
SHA-256 checksum each.

Validate the manifest from the filesystem:

```bash
cabal run -v0 shomei-migrate -- check --manifest shomei-migrations/migrations/shomei/manifest
```

Then apply and re-apply:

```bash
export DATABASE_URL="$PG_CONNECTION_STRING"
cabal run -v0 shomei-migrate -- status    # 28 pending
cabal run -v0 shomei-migrate -- up        # 28 AppliedNow
cabal run -v0 shomei-migrate -- up        # 28 AlreadyApplied  <- idempotence
cabal run -v0 shomei-migrate -- verify    # succeeds, exit 0
cabal run -v0 shomei-migrate -- status --json | head -20
```

Confirm both the schema and the ledger exist:

```bash
psql -d "$PGDATABASE" -c '\dn'
psql -d "$PGDATABASE" -tAc \
  'SELECT component, migration, position, status FROM pgmigrate.migrations ORDER BY position LIMIT 3'
psql -d "$PGDATABASE" -tAc 'SELECT count(*) FROM pgmigrate.migrations'
```

Expected shape:

```text
shomei|0001-shomei-schema|1|applied
shomei|0002-shomei-users|2|applied
shomei|0003-shomei-password-credentials|3|applied
28
```

The `\dn` listing should show both `shomei` and `pgmigrate`, and must **not** show any
codd bookkeeping.

### M4 — move test-support and the server

Replace `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs` with:

```haskell
-- | Provision a fresh, isolated ephemeral PostgreSQL with the complete Shōmei schema
-- applied in-process through @pg-migrate@. Each call gets a brand-new database
-- (@ephemeral-pg@ caches only the @initdb@ cluster and hands back a fresh server plus
-- database per call), so tests stay isolated.
module Shomei.Migrations.TestSupport
  ( withShomeiMigratedDatabase,
  )
where

import Data.Text (Text)
import EphemeralPg qualified as Pg
import Shomei.Migrations (applyShomeiMigrations)

-- | Run @action@ against a fresh ephemeral PostgreSQL connection string whose database
-- already has the full Shōmei schema applied.
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
withShomeiMigratedDatabase action = do
  result <- Pg.withCached \db -> do
    let connStr = Pg.connectionString db
    applied <- applyShomeiMigrations connStr
    case applied of
      Left migrationError ->
        error ("Failed to migrate ephemeral Shōmei database: " <> show migrationError)
      Right _ -> action connStr
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right value -> pure value
```

Update its cabal stanza:

```cabal
library test-support
  import:          warnings, shared
  visibility:      public
  hs-source-dirs:  test-support
  exposed-modules: Shomei.Migrations.TestSupport
  build-depends:
    , base               >=4.18  && <5
    , ephemeral-pg       >=0.2.2 && <0.3
    , pg-migrate         >=1.1   && <1.2
    , shomei-migrations
    , text
```

In `shomei-server/src/Shomei/Server/Boot.hs`, change the import on line 57 from
`Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)` to
`Shomei.Migrations (applyShomeiMigrations)`, and replace line 283 with a fatal-on-failure
form along these lines:

```haskell
  applyShomeiMigrations settings.serverConnStr >>= \case
    Left migrationError -> do
      hPutStrLn stderr ("[shomei] FATAL: schema migration failed: " <> show migrationError)
      exitFailure
    Right report ->
      hPutStrLn
        stderr
        ("[shomei] schema migrations applied: " <> show (length report.results) <> " migrations")
```

`exitFailure` comes from `System.Exit`; check whether `Boot.hs` already imports it and add
the import if not. `secondsToDiffTime` may become an unused import — `-Wall` will say so.

In `shomei-server/app/Admin.hs`, apply the same change to the `Migrate` branch at line 105,
replacing `putStrLn "migrations applied"` with a report-derived summary.

Then build and test the whole workspace:

```bash
cabal build all
cabal test all
```

### M5 — drop the pins and update the prose

Edit `cabal.project`: delete the two `source-repository-package` blocks named above and the
`package codd` stanza, and rewrite the EP-3 comment. Then force a fresh solve and confirm
neither dependency is fetched:

```bash
rm -rf dist-newstyle/src
cabal build all --dry-run 2>&1 | grep -iE 'codd|ephemeral-pg'
```

Expected: `ephemeral-pg-0.2.2.0` appears as a plain Hackage dependency and `codd` does not
appear at all.

Edit `flake.module.nix`, `mori.dhall`, `README.md`, `docs/user/architecture.md`,
`docs/user/authorization.md`, `Dockerfile`, and `agents/skills/release/SKILL.md` as
described in Milestone 5. Then confirm no stale references survive:

```bash
grep -rn -i 'codd' \
  --include='*.hs' --include='*.cabal' --include='*.nix' --include='*.dhall' \
  --include='*.md' --include='*.yaml' --include='Justfile' --include='Dockerfile' \
  --include='cabal.project' . \
  | grep -v '^./docs/plans/' \
  | grep -v '^./docs/masterplans/' \
  | grep -v '^./dist-newstyle' \
  | grep -v '^./.direnv'
```

Expected: no output. Historical plans and masterplans under `docs/plans/` and
`docs/masterplans/` legitimately keep their codd references — they are a record of what was
done at the time and must not be rewritten. This plan file itself will also match; that is
fine.

Validate `mori.dhall` still type-checks and that the new dependency resolves:

```bash
mori show --full | head -40
mori registry show shinzui/pg-migrate --full | head -20
```

### Commit

Each commit must carry both trailers:

```text
refactor(migrations)!: replace codd with pg-migrate

<body>

ExecPlan: docs/plans/50-migrate-shomei-from-codd-to-pg-migrate.md
Intention: intention_01m0t088cce2dajvbdw4ppfbj1
```

The `!` marks the breaking change: `Shomei.Migrations` loses
`runShomeiMigrationsNoCheck`, `coddSettingsFromConnString`, and `shomeiMigrations`, and
`shomei-migrate` changes its entire command-line interface. Commit directly to the current
branch; do not create a feature branch.


## Validation and Acceptance

Acceptance is behavioural, not "the code compiles." Five things must be observable.

**1. The CLI reports and applies the plan.** Against a freshly created empty database:

```bash
dropdb --if-exists "$PGDATABASE" && createdb "$PGDATABASE"
export DATABASE_URL="$PG_CONNECTION_STRING"
cabal run -v0 shomei-migrate -- status
```

reports 28 pending and 0 applied. After `cabal run -v0 shomei-migrate -- up`, `status`
reports 28 applied and 0 pending, and `verify` exits 0. Running `up` a second time reports
every migration as already applied and changes nothing — this idempotence is what makes it
safe for `deploy/entrypoint.sh` and for `buildEnv` to run on every start.

**2. The ledger and schema are both correct.**

```bash
psql -d "$PGDATABASE" -tAc "SELECT count(*) FROM pgmigrate.migrations WHERE status = 'applied'"
psql -d "$PGDATABASE" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'shomei'"
```

The first must print `28`. The second must print the same table count as before the
migration — capture it *before* starting M1 with the same query against the current
database so you have a number to compare against, and record both in Surprises &
Discoveries. This is the check that proves the renumbering and header-stripping did not
silently drop or corrupt a migration.

**3. The full test suite passes.** `cabal test all` must be green. This is the strongest
signal available, because `shomei-postgres`, `shomei-server` (E2E, admin, and health
suites), `shomei-client`, and both examples all provision real PostgreSQL databases through
`withShomeiMigratedDatabase`. If the schema were wrong in any way, these fail loudly.

**4. A migration failure is now fatal.** Prove the M4 behaviour change rather than assuming
it. Point the server at a database it cannot migrate — for example a connection string for
a database whose `pgmigrate.migrations` table has been hand-edited to contain a checksum
that does not match the plan — and confirm `shomei-server` exits non-zero with the error on
`stderr` instead of proceeding to bind its port. Restore the database afterwards by
dropping and recreating it.

**5. The Hackage-only solve succeeds — the actual point of the exercise.** This is the
check the release runbook prescribes in its step 8, and it is what proves the release
blocker is gone:

```bash
cabal sdist shomei-migrations
scratch=$(mktemp -d)
tar -xzf dist-newstyle/sdist/shomei-migrations-0.1.0.0.tar.gz -C "$scratch"
cd "$scratch/shomei-migrations-0.1.0.0" && cabal build --dry-run --enable-tests all
```

`--enable-tests` matters: the `test-support` sublibrary is public and ships in the tarball,
so its dependencies must resolve too. A successful solve here, with no local
`cabal.project`, means `shomei-migrations` can actually be uploaded. Repeat for
`shomei-postgres`. Record the outcome for each package and update
`agents/skills/release/SKILL.md`'s releasability table from what you observe, not from what
this plan predicts.

Also confirm the compile-time safety net still works, since it is a real behavioural
improvement over `embedDir`: adding an unlisted `.sql` file beside the manifest must fail
the build (the exact procedure is in M2's Concrete Steps).


## Idempotence and Recovery

Every database step in this plan is safe to repeat. `shomei-migrate up` is idempotent by
construction — it consults the ledger and applies only what is pending. `dropdb --if-exists`
followed by `createdb` can be run any number of times. The ephemeral databases used by
tests are created and destroyed per test run and need no cleanup.

The file-level steps in M1 are the only ones that are not naturally repeatable: the rename
loop derives its numbering from `sort` order, so running it twice would try to renumber
already-renumbered files. Recovery is `git checkout -- shomei-migrations/` (or
`git restore --staged --worktree shomei-migrations/` if the `git mv` was staged), which
restores the original filenames and contents. Because the loop uses `git mv`, the renames
are staged and visible in `git status` as renames rather than as deletes plus adds, which
makes review and rollback straightforward.

If a build fails midway between M2 and M4, the workspace is genuinely inconsistent — the
library's API has changed but its callers have not. That is expected and is not a state to
try to recover from; finish M4. If you need a working tree urgently, `git stash` the whole
change set.

The riskiest single step is dropping the local development database in M3. There is no
production data anywhere and no consumer, which is the premise of this plan; the local
database holds only development fixtures and can always be rebuilt with
`process-compose up --no-server`, whose `create_schema` and `bootstrap_keys` steps recreate
the schema and a signing key. If you have local test data you care about, take a
`pg_dump -n shomei` first — but note that restoring it into the new schema is only sensible
because the schema itself is unchanged by this plan; only the migration *tooling* changes.

Two things this plan deliberately does not do, and should not be extended to do without a
new decision: it does not import codd history into a `pg-migrate` ledger (see Decision
Log), and it does not touch the `jose` or `webauthn` git pins, which block other packages
for unrelated reasons.


## Interfaces and Dependencies

### New dependencies

All from Hackage; no `source-repository-package` entries are added by this plan.

- `pg-migrate >=1.1 && <1.2` — the model, runner, ledger, and inspection API. Used by the
  `shomei-migrations` library, its `shomei-migrate` executable, and its `test-support`
  sublibrary. Module: `Database.PostgreSQL.Migrate`.
- `pg-migrate-embed >=1.1 && <1.2` — the compile-time manifest splice and its GHC plugin.
  Used only by the `shomei-migrations` library. Modules:
  `Database.PostgreSQL.Migrate.Embed` and
  `Database.PostgreSQL.Migrate.Embed.RecompilePlugin`.
- `pg-migrate-cli >=1.1 && <1.2` — the reusable command parser and dispatcher. Used only by
  the `shomei-migrate` executable. Module: `Database.PostgreSQL.Migrate.CLI`.
- `optparse-applicative >=0.19 && <0.20` — required by the CLI mount. Already used
  elsewhere in the workspace by `shomei-admin`.
- `ephemeral-pg >=0.2.2 && <0.3` — unchanged in role, but now resolved from Hackage rather
  than from the `shinzui/ephemeral-pg` git pin.

`pg-migrate-test-support` is deliberately **not** used; see the Decision Log for why
Shōmei keeps its own `withShomeiMigratedDatabase`.

### Removed dependencies

`codd` disappears entirely. `file-embed`, `attoparsec`, `streaming`, and `aeson` leave the
`shomei-migrations` library stanza (`aeson` remains in the executable, for `--json`
rendering). `codd`, `aeson`, `attoparsec`, `containers`, and `time` leave the
`test-support` stanza.

### Signatures that must exist at the end of M2

In `Shomei.Migrations` (`shomei-migrations/src/Shomei/Migrations.hs`):

```haskell
shomeiMigrationComponent  :: Either DefinitionError MigrationComponent
shomeiMigrationPlan       :: Either DefinitionError (Either PlanError MigrationPlan)
resolveShomeiMigrationPlan :: IO MigrationPlan
applyShomeiMigrations     :: Text -> IO (Either MigrationError MigrationReport)
```

`DefinitionError`, `MigrationComponent`, `PlanError`, `MigrationPlan`, `MigrationError`,
and `MigrationReport` all come from `Database.PostgreSQL.Migrate`. These four replace the
old `shomeiMigrations`, `runShomeiMigrationsNoCheck`, and `coddSettingsFromConnString`,
none of which survive.

### Signatures that must be unchanged at the end of M4

In `Shomei.Migrations.TestSupport`
(`shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`):

```haskell
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
```

Keeping this identical is what lets roughly a dozen call sites across `shomei-postgres`,
`shomei-server`, `shomei-client`, `examples/embedded-servant-app`, and
`examples/microservice-auth-stack` compile untouched. If you find yourself wanting to
change it, stop and reconsider — the change almost certainly belongs inside the body.

### Upstream API surface relied upon

From `Database.PostgreSQL.Migrate`: `migrationComponentFromEmbeddedSql`, `migrationPlan`,
`runMigrationPlan`, `defaultRunOptions`, and the types listed above. From
`Database.PostgreSQL.Migrate.Embed`: `embedMigrationManifest`. From
`Database.PostgreSQL.Migrate.CLI`: `migrationCommandParser`, `cliEnvironment`,
`runMigrationCommand`, `renderMigrationCommandText`, `renderMigrationCommandJson`,
`exitClass`, `ExitClass (..)`, `OutputFormat (..)`, `MigrationCommand (..)`, and the
per-command options records. From `EphemeralPg`: `withCached` and `connectionString`.

`Database.PostgreSQL.Migrate`'s documentation is explicit that modules named `Internal` are
not covered by the version bound and must not be imported. Nothing in this plan does.

### Canonical cross-repository references

- `pg-migrate`: `mori://shinzui/pg-migrate` — packages
  `mori://shinzui/pg-migrate/packages/pg-migrate`,
  `mori://shinzui/pg-migrate/packages/pg-migrate-embed`,
  `mori://shinzui/pg-migrate/packages/pg-migrate-cli`.
- `ephemeral-pg`: `mori://shinzui/ephemeral-pg`.
- `codd` (being removed): `mori://mzabani/codd`.
- The `en` authorization project referenced by `docs/user/authorization.md`:
  `mori://shinzui/en`.

`pg-migrate`'s own user documentation lives in its checkout under `docs/user/` and
`docs/operations/`; locate it with `mori registry docs shinzui/pg-migrate`. This plan
deliberately restates everything needed rather than sending the reader there, but the
manifest-authoring and CLI-integration guides are worth reading before extending the setup.
