---
id: 61
slug: make-shomei-migrations-schema-qualified-and-composition-safe
title: "Make Shomei Migrations Schema-Qualified and Composition-Safe"
kind: exec-plan
created_at: 2026-08-27T17:49:04Z
intention: "intention_01m1258k0me2vbdhg808zjvha1"
---

# Make Shomei Migrations Schema-Qualified and Composition-Safe

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shōmei is intended to be embedded in an application that may own PostgreSQL migrations of its
own. Both Shōmei and the host can contribute a `MigrationComponent` to one pg-migrate
`MigrationPlan`; pg-migrate then executes those components in order on one dedicated connection.
Today every Shōmei migration after the schema creation runs session-scoped
`SET search_path TO shomei, pg_catalog` and refers to Shōmei tables without their `shomei.` schema
prefix. That works when Shōmei is the only component, but the setting survives the migration's
transaction and changes how later host migrations resolve unqualified names. It also places the
application-owned `shomei` schema before PostgreSQL's built-in `pg_catalog` namespace.

After this change, a host can place a component before and after Shōmei in one plan, use its own
session search path, and observe no namespace state left behind by Shōmei. Every Shōmei-owned
table, index target, foreign-key target, and data-manipulation target will be explicitly qualified.
Transactional migrations will restrict their temporary lookup path with
`SET LOCAL search_path = pg_catalog, pg_temp`, which PostgreSQL automatically restores at commit
or rollback. A composed-plan integration test will demonstrate the behavior by placing a hostile
host component before Shōmei and an unqualified host statement after it. The test fails against
the current migrations and passes after the rewrite.

This is intentionally a pre-adoption history rewrite. The user has confirmed that Shōmei has not
yet been adopted, so no durable consumer database relies on the current migration checksums. The
migration names, component name, manifest order, and resulting Shōmei schema stay the same; only
the exact SQL bytes and therefore pg-migrate checksums change. If evidence appears that any
durable database has applied the present checksums, stop this plan and replace the rewrite with an
append-only compatibility strategy.


## Progress

- [ ] Milestone 1 — add a composed pg-migrate regression test that reproduces Shōmei leaking its
      session search path into a later host component, and record the expected pre-fix failure.
- [ ] Milestone 2 — rewrite all 36 pre-adoption SQL files so Shōmei objects are schema-qualified
      and every transactional lookup-path change is transaction-local; make the regression and
      existing PostgreSQL suites pass.
- [ ] Milestone 3 — enforce the policy for future migrations through the authoring recipe, a
      source-policy check, CI, user documentation, and a profile-governed ADR.
- [ ] Milestone 4 — run the full build, test, formatting, manifest, ADR, and Nix validation gates;
      record evidence and complete the ADR distillation pass.


## Surprises & Discoveries

- Observation: pg-migrate deliberately keeps one dedicated Hasql connection for the complete
  plan, while wrapping each transactional migration and its ledger row in a separate transaction.
  Therefore connection state does not leak into Shōmei's application pool, but ordinary `SET`
  state does flow from one migration component to the next inside the same plan. The relevant
  dependency is `mori://shinzui/pg-migrate/packages/pg-migrate`; within that project the behavior
  is implemented in `pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Connection.hs` and
  `pg-migrate/src/Database/PostgreSQL/Migrate/Runner.hs`.

- Observation: Shōmei's `just new-migration` recipe delegates to pg-migrate-cli 1.1.0.0, whose
  `new` command writes only a one-line SQL comment and a blank line. A Shōmei-specific safe header
  must therefore be inserted by repository-owned authoring code rather than assumed to come from
  the dependency. Mori identifies the package as
  `mori://shinzui/pg-migrate/packages/pg-migrate-cli`; Hackage and upstream tag `v1.1.0.0` agree
  with the repository's `>=1.1 && <1.2` bounds.

- Observation: `pg-migrate-test-support` 1.1.0.0 is published on Hackage and exposes
  `Database.PostgreSQL.Migrate.Test.withMigratedDatabase`. It applies a complete plan on one
  migration connection and then supplies a fresh connection for assertions, which is exactly the
  lifecycle this regression needs. It remains a test-only dependency and does not enter the
  published library's production closure. Its canonical package reference is
  `mori://shinzui/pg-migrate/packages/pg-migrate-test-support`.

- Observation: The implementation baseline contains 36 manifest entries rather than the 33 present
  when this plan was authored. Migrations `0034` through `0036` were committed after the plan and
  also use the legacy session-scoped search path, so the rewrite and regression must cover them.
  Evidence: `wc -l shomei-migrations/migrations/shomei/manifest` printed `36`, and the baseline
  search reported the legacy header in all three new files.


## Decision Log

- Decision: Rewrite migrations `0001` through `0033` in place instead of appending a corrective
  migration.
  Rationale: The user explicitly confirmed there is no adoption to preserve. Rewriting now makes
  every fresh installation and every future composition safe, while a corrective migration could
  not prevent earlier session-scoped `SET` commands from affecting components ordered after
  Shōmei.
  Date: 2026-08-27

- Decision: Qualify every Shōmei-owned object and set transactional lookup to
  `pg_catalog, pg_temp` with `SET LOCAL`.
  Rationale: Qualification fixes object identity in the SQL itself. The restricted local path
  makes built-in types, functions, operators, and collations deterministic without allowing the
  `shomei` schema to shadow `pg_catalog`, and its lifetime ends automatically with the migration
  transaction. Qualification and a restricted path defend different name-resolution surfaces, so
  both are retained.
  Date: 2026-08-27

- Decision: Prove the public composition promise with host-before, Shōmei, and host-after
  components in one real PostgreSQL plan.
  Rationale: A standalone migration test cannot see state leaking between components. The
  three-component order makes the current failure observable and exercises the same public
  `shomeiMigrationComponent` consumers will compose.
  Date: 2026-08-27

- Decision: Keep this ExecPlan standalone rather than adding it to
  `docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md`.
  Rationale: The commit-pinned migration review found the current runner isolated from the
  application pool; this plan strengthens a pre-adoption reusable-component contract rather than
  closing one of that MasterPlan's enumerated review findings.
  Date: 2026-08-27

- Decision: Do not rewrite completed ExecPlans or commit-pinned reviews that quote the old SQL.
  Record the new durable policy in a new ADR and current user documentation instead.
  Rationale: Completed plans and reviews are evidence of what was decided or observed at a point in
  time. Editing their examples would erase history, while an accepted ADR can clearly supersede
  the original migration-authoring decision.
  Date: 2026-08-27

- Decision: Extend the in-place rewrite through migration `0036` and treat the 36-entry manifest as
  the implementation baseline.
  Rationale: Migrations `0034` through `0036` are part of the same pre-adoption history and contain
  the same unsafe session-scoped command. Excluding them would leave the composition leak intact.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation. Compare the composed-plan behavior, authoring
guardrails, and validation evidence with the purpose above. Before completion, distill any further
durable decisions or surprises into the migration-namespace ADR.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/shomei`. Commands below run there inside
`nix develop` unless a step says otherwise. A PostgreSQL schema is a namespace containing tables,
indexes, types, functions, and related database objects. A schema-qualified table name such as
`shomei.shomei_users` identifies one object independently of the connection's `search_path`.
`search_path` is session configuration PostgreSQL uses to resolve names without a schema prefix.
Ordinary `SET` survives transaction commit until the connection ends; `SET LOCAL` lasts only for
the current transaction.

`shomei-migrations/migrations/shomei/manifest` is the ordered list embedded into the
`shomei-migrations` library. At implementation it lists 36 files. Migration
`shomei-migrations/migrations/shomei/0001-shomei-schema.sql` creates the `shomei` namespace. Files
`0002` through `0036` currently start with session-scoped
`SET search_path TO shomei, pg_catalog` and then use unqualified Shōmei relations in `CREATE TABLE`,
`ALTER TABLE`, `UPDATE`, `INSERT`, `REFERENCES`, `CREATE INDEX ... ON`, and `DROP INDEX` statements.

`shomei-migrations/src/Shomei/Migrations.hs` embeds the manifest and exports
`shomeiMigrationComponent`, `shomeiMigrationPlan`, `resolveShomeiMigrationPlan`, and
`applyShomeiMigrations`. The public component has the stable name `shomei` and no dependencies.
Do not change that API, component identity, migration names, or order. The application-side order
is explicit: pg-migrate's `migrationPlan` preserves the supplied component order. This behavior is
documented by `mori://shinzui/pg-migrate/docs/public-api` and the component-composition guidance in
`mori://shinzui/pg-migrate/docs/user-guide`.

`shomei-migrations/shomei-migrations.cabal` currently defines the library, CLI executable, and
public `test-support` sublibrary but no test suite of its own. Add the new integration suite here,
with its entry point at `shomei-migrations/test/Main.hs`. Existing application-level database
coverage lives in `shomei-postgres/test/Main.hs` and obtains a freshly migrated database through
`Shomei.Migrations.TestSupport`; it proves Shōmei's data access works but does not compose another
migration component around Shōmei.

The root `Justfile` owns `migration-check` and `new-migration`. `migration-check` presently asks
pg-migrate-cli to validate manifest membership and readability. `new-migration` creates a numbered
file and manifest entry through the CLI. `.github/workflows/ci.yaml` builds every package, runs all
Cabal test suites, and checks formatting, but does not invoke the source-level migration policy
check. `docs/user/deployment.md` is the current operator and contributor-facing database document.

The original search-path decision is recorded historically in
`docs/plans/3-postgresql-persistence-and-migrations.md`, and the public component composition
promise is recorded in `docs/plans/50-migrate-shomei-from-codd-to-pg-migrate.md`. The local ADR
bundle contains ADR-1 through ADR-4, none of which governs migration namespace behavior. Its
descriptor `docs/adr/profile.dhall` type-checks and declares the shared architecture-decision
profile. Implementation must allocate a new stable ADR handle through OKF rather than guessing a
number.


## Plan of Work

Milestone 1 adds the regression before changing SQL. In
`shomei-migrations/shomei-migrations.cabal`, add an `exitcode-stdio-1.0` test suite named
`shomei-migrations-test`. Its dependencies are the existing production packages plus test-only
`pg-migrate-test-support >=1.1 && <1.2`, `tasty`, and `tasty-hunit`; include `hasql`, `containers`,
and any small foundational packages directly imported by the test. Create
`shomei-migrations/test/Main.hs`. Construct a `host-before` component whose SQL creates a `host`
schema, executes session-scoped `SET search_path TO host, pg_catalog`, creates a host probe table,
and creates a collision-shaped `host.shomei_users` table. Compose it before the real
`shomeiMigrationComponent`. Construct `host-after`, dependent on `shomei`, whose migration inserts
into the host probe by an unqualified name. Compose the explicit order
`host-before :| [shomei, host-after]` and apply it with `withMigratedDatabase`. Against the current
SQL, Shōmei's final ordinary `SET` leaves `shomei, pg_catalog` active and `host-after` cannot resolve
the probe. Record that structured failure in Surprises & Discoveries before proceeding. After the
fix, the callback uses schema-qualified Hasql assertions to prove the host probe received the row,
both `host.shomei_users` and `shomei.shomei_users` exist, and the host collision table retained its
host-only shape.

Milestone 2 rewrites the embedded history. In all files from
`shomei-migrations/migrations/shomei/0001-shomei-schema.sql` through
`0036-unique-password-credential-per-user.sql`, place exactly one
`SET LOCAL search_path = pg_catalog, pg_temp;` after the leading description/comment region.
Replace every session-scoped search-path command. Prefix Shōmei-owned tables, views, sequences,
types, functions, and DML targets with `shomei.`. In the present files this includes table names in
`CREATE TABLE`, `ALTER TABLE`, `UPDATE`, `INSERT INTO`, subquery `FROM`, and `REFERENCES`; table
targets after `CREATE INDEX ... ON`; and index names passed to `DROP INDEX`. Do not prefix a
`CREATE INDEX` index name: PostgreSQL does not accept a schema-qualified index name there and
automatically creates it in the explicitly qualified parent table's schema. Constraint names after
`DROP CONSTRAINT` are table-local and also remain unqualified. Built-in types and functions may
remain textually unqualified because `pg_catalog` is first in the restricted local path. Preserve
every migration's data behavior, comments, filename, and manifest position, including migrations
`0034` through `0036`, which were added after this plan was authored.

Run the composed regression after the rewrite. It must now pass because every Shōmei transaction
temporarily selects the safe built-in path and then restores the host's session path. Run the
existing `shomei-postgres` integration suite as a second boundary: it must still create and use the
same Shōmei schema. Inspect the resulting SQL diff statement by statement; this is a semantic
rewrite, not a blind prefix replacement, because index and constraint grammar differ from relation
grammar.

Milestone 3 prevents regression. Add a small repository script under `scripts/` that checks every
manifest-listed transactional SQL file contains exactly one canonical local header, rejects the
legacy session-scoped command, and rejects any other session-scoped `SET search_path`. A future
file carrying pg-migrate's leading `-- pg-migrate: no-transaction` directive cannot use `SET LOCAL`
and is allowed to omit the header, but the checker must reject any search-path mutation in such a
file; every object reference in a nontransactional statement must be schema-qualified. Keep the
checker narrow and transparent rather than attempting to implement a SQL parser. The real
PostgreSQL composition test remains the behavioral proof.

Update `migration-check` in `Justfile` to run both pg-migrate's manifest check and the local policy
checker. Update `new-migration` so that after pg-migrate-cli exclusively creates the comment-only
file and atomically updates the manifest, the recipe inserts the canonical local header into that
known new file using a same-directory temporary file and atomic rename. Preserve the description
comment. If header insertion fails, print the affected path and fail rather than presenting an
unsafe scaffold as successful. Add a CI step in `.github/workflows/ci.yaml` that runs
`nix develop --command just migration-check` before the full build.

Add a migration composition and authoring subsection to `docs/user/deployment.md`. Explain the
qualification rule, the transactional header, the exception for nontransactional one-statement
migrations, why `CREATE INDEX` qualifies its table rather than its new index name, and the commands
`just new-migration` and `just migration-check`. Do not rewrite old ExecPlans or commit-pinned
reviews; identify the new ADR as the current policy.

Create that ADR in `docs/adr/` following `docs/adr/profile.dhall`. Allocate the handle at
implementation time with `okf id next`; use a title equivalent to “Migration components do not
mutate shared namespace state,” set `originatingPlan` to this file, and record the decision that
reusable migration components schema-qualify owned objects and confine lookup-path changes to the
current transaction. Include the nontransactional exception and rejected alternatives: ordinary
session `SET`, relying on an ambient path, or asking hosts to run Shōmei separately. Add an OKF log
entry and validate the bundle strictly.

Milestone 4 runs all focused and repository-wide gates. Update Progress after every stopping point,
record concrete test output in Surprises & Discoveries, and fill Outcomes & Retrospective. Review
the completed Decision Log and ADR together so project-level guidance lives in the ADR while
transient execution details remain here. Every implementation commit must use Conventional
Commits and include both trailers:

```text
ExecPlan: docs/plans/61-make-shomei-migrations-schema-qualified-and-composition-safe.md
Intention: intention_01m1258k0me2vbdhg808zjvha1
```


## Concrete Steps

Start from the repository root and preserve unrelated dirty work. Establish the baseline:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
git status --short
cabal run -v0 shomei-migrate -- check \
  --manifest shomei-migrations/migrations/shomei/manifest
wc -l shomei-migrations/migrations/shomei/manifest
rg -n '^SET search_path TO shomei, pg_catalog;$' \
  shomei-migrations/migrations/shomei/*.sql
```

The manifest check should succeed, `wc` should report 36, and the final command should list
migrations `0002` through `0036`. Preserve unrelated working-tree changes; do not reset or
overwrite them.

After adding the Milestone 1 test but before rewriting SQL, run:

```bash
cabal test shomei-migrations-test --test-show-details=direct
```

The expected red test is a `MigratedDatabaseMigrationFailed` whose underlying PostgreSQL failure
comes from `host-after` resolving the unqualified host probe under Shōmei's leaked search path.
Record the exact output in this plan; do not weaken the assertion to accept the failure.

After rewriting all migrations, run these focused checks:

```bash
rg -n '^SET search_path TO shomei, pg_catalog;$' \
  shomei-migrations/migrations/shomei/*.sql
rg --files-without-match '^SET LOCAL search_path = pg_catalog, pg_temp;$' \
  shomei-migrations/migrations/shomei/*.sql
cabal test shomei-migrations-test --test-show-details=direct
cabal test shomei-postgres-test --test-show-details=direct
```

Both `rg` commands should print nothing. Both test suites should pass. If a migration uses the
nontransactional directive in the future, exclude it deliberately from the second source check;
none of the current 36 files is nontransactional.

Allocate and validate the ADR without guessing its ID:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr --kind Addition \
  --message 'Record schema-qualified, transaction-local migration component policy'
just adr-validate
```

Use the ID printed by `okf id next` in both the filename convention and the ADR's `docId`. The
strict validation must exit successfully with no profile or log errors.

Run the finished focused policy checks and full project gates:

```bash
just migration-check
cabal build all
cabal test all --test-options='-j2'
nix fmt -- --fail-on-change
nix flake check
git diff --check
git status --short
```

Expected results are successful exits from every command, no formatter-generated diff, and a
final status containing only the pre-existing user changes plus files intentionally changed by
this plan. If the formatter changes plan-owned files, inspect the diff and rerun the affected
focused tests before the full gates.


## Validation and Acceptance

Acceptance is behavioral, not merely a clean grep. The new `shomei-migrations-test` must apply one
explicit plan ordered as host-before, Shōmei, host-after on real ephemeral PostgreSQL. Host-before
leaves `search_path` set to `host, pg_catalog`; Shōmei applies all 36 migrations; host-after then
successfully inserts into its unqualified host probe. On a fresh assertion connection, the test
must show that the row exists in `host`, both collision-named user tables exist in their intended
schemas, and the host table was not altered into Shōmei's shape. This single scenario proves that
Shōmei neither consumes host objects nor leaves session namespace state for later components.

Every current SQL file must use the canonical transaction-local path and every Shōmei relation
reference must identify the `shomei` schema. Review the migration-only `git diff` manually because
regular-expression checks cannot understand all PostgreSQL grammar. `just migration-check` must
validate both manifest integrity and the local source policy. The scaffold path must preserve
pg-migrate-cli's exclusive file creation and atomic manifest replacement while ensuring the new
file contains the canonical header before the recipe reports success.

The existing `shomei-postgres-test` suite must remain green, demonstrating that schema
qualification did not change application-visible tables, columns, indexes, foreign keys, seed
data, or persistence behavior. The complete Cabal test aggregate and Nix checks must also pass.
`docs/user/deployment.md` and the new accepted ADR must state the same policy, and strict ADR
validation must accept the record and its log entry.


## Idempotence and Recovery

Editing the pre-adoption SQL files is repeatable at the source level, but applying different
checksums to a database that already has the old `shomei/*` ledger rows is not. Before executing
the rewrite against any persistent database, confirm it is disposable or has never applied the
current component. Ephemeral test databases are always safe to recreate. Do not repair or edit a
pg-migrate ledger to force the new checksums over adopted history.

The SQL itself retains the existing idempotent guards such as `IF NOT EXISTS` and `IF EXISTS`.
`SET LOCAL` automatically restores the previous session value on both commit and rollback, so a
failed migration can be retried without cleanup of connection state. The authoring-policy checker
is read-only. The new-migration recipe must create its temporary file beside the target and
atomically rename only after a complete header rewrite; on failure it should leave the CLI-created
migration and manifest entry visible for diagnosis rather than deleting or guessing at user intent.

If the integration test fails during database startup, preserve the structured
`MigratedDatabaseStartupFailed` output and verify PostgreSQL binaries are available in
`nix develop`. If it fails while applying a Shōmei migration, inspect the first failing qualified
statement rather than changing the host fixture. If unrelated dirty files conflict with a planned
edit, stop and report the overlap instead of resetting user work.


## Interfaces and Dependencies

No production Haskell interface changes. `Shomei.Migrations.shomeiMigrationComponent` keeps type
`Either DefinitionError MigrationComponent`, stable component name `shomei`, an empty dependency
set, and the same 36 migration identities in manifest order. `shomeiMigrationPlan`,
`resolveShomeiMigrationPlan`, and `applyShomeiMigrations` keep their existing signatures and
semantics.

The new test uses the public APIs from `mori://shinzui/pg-migrate/packages/pg-migrate`:
`sqlMigration`, `migrationComponent`, `migrationPlan`, and their structured `DefinitionError` and
`PlanError` results. It uses
`mori://shinzui/pg-migrate/packages/pg-migrate-test-support` version 1.1.0.0 through:

```haskell
withMigratedDatabase
  :: MigrationPlan
  -> (Connection.Connection -> IO value)
  -> IO (Either MigratedDatabaseError value)
```

Add `pg-migrate-test-support >=1.1 && <1.2` only to the new test suite. This version and bound were
verified against Mori source, upstream release tag `v1.1.0.0`, and the authoritative Hackage Cabal
file. Continue using `hasql >=1.10 && <1.11`, matching the package family. Use the repository's
existing Tasty bounds rather than introducing another test framework.

At the SQL boundary, the canonical transactional preamble is:

```sql
SET LOCAL search_path = pg_catalog, pg_temp;
```

Application-owned objects use forms such as:

```sql
CREATE TABLE IF NOT EXISTS shomei.shomei_users (...);
ALTER TABLE shomei.shomei_sessions ...;
REFERENCES shomei.shomei_users(user_id);
CREATE INDEX IF NOT EXISTS shomei_sessions_user_id_idx
  ON shomei.shomei_sessions (user_id);
DROP INDEX IF EXISTS shomei.shomei_sessions_status_idx;
```

A nontransactional pg-migrate file is one statement and cannot use `SET LOCAL`; its one statement
must therefore qualify every non-built-in object directly. This exception must be present in the
checker, documentation, and ADR even though none of the current migrations uses it.


Revision note (2026-08-27): Extended the implementation baseline from 33 to 36 migrations after
the baseline manifest and source scan showed that committed migrations `0034` through `0036` also
carry the legacy session-scoped search path. The purpose and policy are unchanged; every current
pre-adoption migration is now explicitly in scope.
