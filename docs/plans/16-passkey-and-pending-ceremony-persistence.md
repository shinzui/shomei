---
id: 16
slug: passkey-and-pending-ceremony-persistence
title: "Passkey and pending-ceremony persistence"
kind: exec-plan
created_at: 2026-06-17T14:38:15Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
master_plan: "docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T04:39:40Z
      mode: "update"
      note: "Refresh completed persistence plan against current atomic stores, migration tooling, assemblies, and validation coverage."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-14T04:40:54Z
      verdict: "approved"
      note: "Reviewed refreshed completed plan against source and ADRs; 355 tests, migration checks, and document checks passed; coverage limits explicit."
---

# Passkey and pending-ceremony persistence


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision
Log, and Outcomes & Retrospective current. The two implementation milestones are
complete. This refresh describes the working tree at `0eedad1`, audited on
2026-10-14 UTC (2026-10-13 in the session's local timezone). Historical commands and
interfaces are retained in Git history, not presented as instructions to execute now.


## Purpose / Big Picture


Shōmei is a Haskell authentication toolkit. This plan delivered persistence for a
**passkey**, the public credential created by a WebAuthn authenticator, and a
**pending ceremony**, the short-lived challenge/options state between beginning and
completing registration or authentication. Developers can create a passkey, find it
by user, credential identifier, or user handle, advance its signature counter,
count a user's credentials, and delete only a credential owned by that user.
They can store pending ceremony state and consume it at most once while it is live.

The capability already exists. This is EP-2 of
[MasterPlan 3](../masterplans/3-webauthn-passkey-multi-factor-authentication.md).
[Plan 15](15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md)
supplied the shared types and ceremony verification port;
[Plan 17](17-passkey-enrollment-workflow-and-management-api.md) and
[Plan 18](18-passkey-login-mfa-step-up-and-passwordless.md) subsequently consumed
these stores for enrollment and login. HTTP endpoints and cryptographic verification
remain owned by those workflows, not this persistence plan.

Run the core tests for the in-memory implementation and the PostgreSQL tests for the
real database implementation, using the commands below. No browser or running Shōmei
server is needed. The database tests provision isolated PostgreSQL instances and apply
the current embedded migration history. Passing those tests is evidence for the
specific cases described under Validation and Acceptance, not a proof of every
possible race or malformed database state.


## Progress


- [x] (2026-06-17, historical) Milestone 1: implement the two store effects, the
  in-memory interpreters, effect-stack entries, and six store tests in commit
  `e07b819`; the original 29-test core suite passed.
- [x] (2026-06-17, historical) Milestone 2: implement the two tables, PostgreSQL
  interpreters, runtime/test wiring, and four integration cases in commit
  `db79c24`; the original 20-test PostgreSQL suite and all 11 then-existing suites
  passed. Both commits carry this plan's `ExecPlan:` trailer.
- [x] (2026-08-27, historical) Audit ownership and later changes: Plans 17 and 18
  consume the stores; Plans 48, 50, 55, and 61 evolve layout, migrations, counter
  atomicity, and schema qualification. The recorded rerun passed 278 core and
  76 PostgreSQL tests.
- [x] (2026-10-14 UTC) Review the current domain, effects, interpreters, migrations,
  stack assemblies, test assertions, and relevant ADRs; replace obsolete execution
  instructions throughout this document.
- [x] (2026-10-14 UTC) Validate the refresh: 278 core, 76 PostgreSQL, and one
  migration-composition test passed; migration-check, local link/path checks,
  section/fence checks, Mori reference resolution, and `git diff --check` passed.
  Final document review: approved with the stated coverage limitations.


## Surprises & Discoveries


The original document had no model provenance block. Its original authoring model
and prior model-review history are unknown. The 2026-08-27 prose audit and Git
trailers do establish implementation ownership; they do not establish model identity.
The refresh appends only the current agent's verified provenance.

The previous plan acknowledged renamed modules in one subsection but continued to
instruct readers to create obsolete files, use codd, restore the removed
`DeleteExpiredCeremonies` operation, and return `()` from counter updates. It also
showed the wrong interpreter composition order and a non-atomic in-memory
read-then-delete algorithm. The current tree has already corrected those issues.
Its counter update returns `Bool`; ceremony take uses `atomicModifyIORef'` in memory
and one `DELETE ... RETURNING` statement in PostgreSQL.

The old claim that every effect list has one identical order was too broad. Relevant
assemblies retain `LoginAttemptStore, PasskeyStore, PendingCeremonyStore`, but other
stores now appear between them and `Notifier`, and support-effect tails differ by
assembly. Each runner must match its own list. Function composition interprets the
head of that list with the rightmost runner; the textual pair is
`runPendingCeremonyStore ... . runPasskeyStore ...`.

The original embedded migration count of 14 is historical, not a current acceptance
criterion. The current manifest contains 36 SQL files, including `0014` and `0015`.
`Shomei.Migrations` now uses `embedMigrationManifest` and
`Database.PostgreSQL.Migrate.Embed.RecompilePlugin`; forcing recompilation with a
comment edit and looking for `embeddedFiles` are obsolete. The plugin reconsiders
the embedding module on each build so newly added or removed SQL files are checked.

The tests provide narrower evidence than the old prose claimed. Pending-ceremony
cases test sequential take and past-expiry rejection; they do not race consumers or
exercise `expiresAt == now`. The in-memory expired-take test's second expired take
would also pass if a stale row remained, so it does not independently prove physical
removal. PostgreSQL tests do check the remaining row count. The eight-racer test is
for the passkey counter and submits the same nonzero next counter in every worker.

The fake is not a complete SQL constraint emulator. It allows fabricated user IDs,
does not enforce unique credential IDs, and replaces an existing pending ceremony
on `put` via `Map.insert`. PostgreSQL enforces foreign keys and unique credential
IDs and rejects a duplicate ceremony ID with a plain insert. Workflows must generate
a fresh ceremony ID for each begin operation; retries must not treat `put` as an
idempotent operation. These are existing limitations, not newly introduced behavior.


## Decision Log


On 2026-06-17, the implementation chose native `bytea` for credential identifiers,
user handles, public keys, and ceremony options; `jsonb` for the transport-hint list;
and `bigint` for the unsigned 32-bit signature counter. These choices preserve bytes,
reuse the existing JSON codec path, and accommodate the entire `Word32` range.
They remain current. The read-side `Int64` to `Word32` conversion is lossless only
for values in 0 through 4,294,967,295: the schema has no counter-range check and the
decoder currently uses unchecked `fromIntegral`. Do not describe it as validation of
arbitrary externally written database values.

On 2026-06-17, ceremony consumption was made a single `DELETE ... RETURNING` followed
by an expiry check. This removes even an expired row and prevents two successful
committed takes of the same stored row. The precise guarantee is **at most once**,
not guaranteed successful completion: a request can fail after consuming the state.
Consumption is keyed by ceremony ID; workflows separately check owner, ceremony kind,
and cryptographic response. The signature-counter guard alone does not replace
challenge consumption, particularly for authenticators that always report zero.

On 2026-06-17, passkey deletion was scoped by both user ID and passkey ID; credential-ID
and user-handle lookups were deliberately unscoped so authentication can discover the
owner. Ceremony-kind codecs remained local to the PostgreSQL ceremony interpreter,
and PostgreSQL `put` used plain `INSERT`, not an upsert. Record-pattern accessors were
used for records sharing field names. The original codd embedding workaround and
migration packaging choices are historical; current migration instructions follow
ADR-19 and the manifest embedding API below.

On 2026-08-27, the audit retained Plan 16 as the original implementation record.
Commits `e07b819` and `db79c24` name this plan; later plans consume or strengthen it.
Plan 55's atomic counter guard supersedes the unconditional update. The term
compare-and-swap is used in the API documentation for this conditional transition,
but the API does not take an expected old counter: it compares the proposed counter
against the authoritative stored value.

On 2026-10-14 UTC, this refresh replaced stale reconstruction instructions with the
current completed contract and repeatable validation steps. Existing ADRs already
cover the relevant architectural decisions, so no new ADR or change to accepted
architecture is needed. Missing edge-case tests are recorded as validation limitations
and concrete future test guidance, not silently claimed to have passed or used to
reclassify the original implementation as unfinished. Dependency bounds and pins are
outside this documentation refresh.


## Outcomes & Retrospective


The original storage foundation is complete. It is still implemented in core and
PostgreSQL, and consumed by enrollment and MFA/passwordless workflows. Later work
strengthened counter updates and moved expiry cleanup into batched maintenance.
The core store API now has seven passkey operations and two pending-ceremony
operations. There is no store-level bulk-expiry operation to implement or wire.

The June test totals and August rerun totals in Progress are historical evidence.
The 2026-10-14 UTC rerun passed all 278 core tests, 76 PostgreSQL tests, and the
one migration-composition test (355 total). `just migration-check` accepted all 36
manifest entries and the namespace policy. Required sections, tagged code fences,
heading spacing, local links and explicit file paths, canonical Mori references,
and `git diff --check` were also verified. The refreshed completed-plan record is
approved; the missing regression cases remain advisory follow-up coverage.

This review changes the plan only; it does not add runtime code, schema migrations,
or new tests. The outstanding evidence limits are stated in Validation and
Acceptance so future maintenance can extend coverage without relying on overstated
claims. Source inspection supports the current atomic implementation; it is not a
substitute for dedicated ceremony concurrency tests.


## Context and Orientation


Shōmei uses a ports-and-interpreters design: core declares operations as effects,
and an interpreter supplies their implementation. An `Eff es a` computation returns
`a` while using the effects listed in `es`; `PasskeyStore :> es` means that list
contains the passkey port. Core must remain free of database, HTTP, and external
WebAuthn-verifier dependencies. It owns the domain types and workflows.

The current files are `shomei-core/src/Shomei/Passkey/Domain.hs`,
`shomei-core/src/Shomei/Passkey/Store.hs`, and
`shomei-core/src/Shomei/Passkey/Ceremony/Store.hs`. The interpreters are
`shomei-core/src/Shomei/Test/InMemory.hs`,
`shomei-postgres/src/Shomei/Passkey/Postgres.hs`, and
`shomei-postgres/src/Shomei/Passkey/Ceremony/Postgres.hs`. Tests live in
`shomei-core/test/Shomei/PasskeyStoreSpec.hs` and `shomei-postgres/test/Main.hs`.
Library exports and test registration are in `shomei-core/shomei-core.cabal`,
`shomei-postgres/shomei-postgres.cabal`, and `shomei-core/test/Main.hs`.

`WebAuthnCredentialId`, `UserHandle`, and `PublicKeyBytes` wrap strict bytes;
`SignatureCounter` wraps `Word32`. `NewPasskeyCredential` has `userId`,
`credentialId`, `userHandle`, `publicKey`, `signCounter`, `transports :: [Text]`,
`label :: Maybe Text`, and `createdAt :: UTCTime`. `PasskeyCredential` adds a
server-generated `passkeyId` and `lastUsedAt :: Maybe UTCTime`, initially `Nothing`.
`PendingCeremony` has `ceremonyId`, `userId :: Maybe UserId`, `kind`,
`optionsBlob :: ByteString`, `createdAt`, and `expiresAt`. The kind is
`RegistrationCeremony` or `AuthenticationCeremony`; an absent user permits
passwordless discovery. The blob is opaque to the store, which must preserve it.
`shomei-core/src/Shomei/Id.hs` owns the typed `PasskeyId` and `CeremonyId` identifiers,
generators, and UUID conversion helpers. Do not redefine these existing types.

`World` in `Shomei.Test.InMemory` holds
`passkeys :: Map PasskeyId PasskeyCredential` and
`pendingCeremonies :: Map CeremonyId PendingCeremony`; `emptyWorld` initializes both
empty. This test interpreter uses mutable references and generated IDs, so "pure"
in older reports means database-free, not an IO-free implementation. `modifyWorld`
and `casWorld` update the reference atomically.

The database effect is in
`shomei-postgres/src/Shomei/Persistence/Database/Postgres.hs`. Both store interpreters
execute Hasql statements through `runSession`. Driver/pool failures become the typed
`DependencyUnavailable PostgreSQL` via `postgresUnavailable`, without exposing raw
SQL/driver text. Domain reconstruction failures use `InternalAuthError`. A missing
row or rejected counter transition is a normal result, not a dependency failure.

The schema is owned by `shomei-migrations/migrations/shomei/manifest` and its SQL
files. In particular,
`shomei-migrations/migrations/shomei/0014-shomei-webauthn-credentials.sql` creates
`shomei.shomei_webauthn_credentials`, and
`shomei-migrations/migrations/shomei/0015-shomei-webauthn-pending-ceremonies.sql` creates
`shomei.shomei_webauthn_pending_ceremonies`. Credentials have a primary passkey ID,
a user foreign key, unique credential bytes, indexes on user and user handle,
`bigint` counter, `jsonb` transports, nullable label and last-use time. Ceremonies
have a primary ceremony ID, nullable user foreign key, kind text, options bytes,
creation/expiry times, and an expiry index. The later
`shomei-migrations/migrations/shomei/0035-status-checks-and-case-insensitive-identity.sql`
adds the kind constraint admitting only `registration` and `authentication`.
The entire manifest, not only the two initial SQL files, defines the current schema.

`shomei-migrations/src/Shomei/Migrations.hs` embeds that manifest and exports
`shomeiMigrationComponent`, `shomeiMigrationPlan`, `resolveShomeiMigrationPlan`, and
`applyShomeiMigrations`. A component is one named history of schema changes;
a plan orders components and applies them with a durable migration ledger.
`shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs` provisions and
migrates temporary databases for integration tests. Batched cleanup of untaken expired
ceremonies belongs to `shomei-postgres/src/Shomei/Persistence/Maintenance/Postgres.hs`.

[ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md)
requires authoritative single-use and counter transitions at the persistence boundary,
with equivalent atomic behavior in the fake.
[ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md)
requires schema-qualified owned objects and transaction-local lookup-path settings;
its required preamble is `SET LOCAL search_path = pg_catalog, pg_temp;`.
[ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md)
places background maintenance, including expiry sweeping, in the host runtime contract.
These records are the existing durable context; this refresh does not change them.


## Plan of Work


### Milestone 1 — core stores and in-memory behavior (complete)


The delivered result is the two dynamic effects and their in-memory interpreters,
with six registered tests. To maintain this milestone, edit the current Store modules
and `Shomei.Test.InMemory` together, preserve the signatures below, and adjust
`shomei-core/test/Shomei/PasskeyStoreSpec.hs` when behavior changes. Use record-pattern
accessors where shared field names are ambiguous. `createPasskey` allocates an ID,
copies the supplied fields, and starts with no last-use timestamp. All three finders
and per-user count read the same credential map; deletion checks the owner.

Counter advancement must decide and write in one `casWorld` update. It succeeds only
when `current < next`, or both are zero; on success it changes the counter and
last-use time together. Missing credentials, repeated nonzero counters, and smaller
counters return `False` without mutation. Ceremony take must use one
`atomicModifyIORef'` to look up and remove the row, returning it only when
`expiresAt > now`. A separate read then delete would break concurrent consumption.

Verify this milestone with `nix develop --command cabal test shomei-core-test
--test-show-details=direct` from the repository root. The six store cases must pass,
including `(True, False, False)` for advancing to 7, replaying 7, and proposing 6.
The original milestone's build gate was `cabal build shomei-core`; the full workspace
gate belongs after runtime wiring, not halfway through adding effects.


### Milestone 2 — PostgreSQL schema, interpreters, and assemblies (complete)


The delivered result is persisted credentials and consume-once ceremonies through
real SQL interpreters and the assembled server. The current schema files already
exist; do not recreate the original codd migrations. For future schema changes use
`Justfile`'s `new-migration` recipe and append a migration to the manifest, preserving
ADR-19's namespace rules. Builds use the embedding plugin; no source touch workaround
or temporary export is required.

Maintain encoders/decoders alongside SQL column order in the two PostgreSQL modules.
The credential row has ten fields and uses `contrazip10`; the ceremony row has six
and uses `contrazip6`. Convert identifiers with `Shomei.Id` helpers, preserve binary
fields as `bytea`, use `toJSON`/`fromJSON` for transports, and widen `Word32` to
`Int64` for writes. Keep the conditional `UPDATE ... RETURNING` and
`DELETE ... RETURNING` statements shown below intact in meaning. PostgreSQL `put`
is a plain insert. A take deletes before the Haskell expiry check, so a malformed
row reconstruction or later verification failure does not restore consumed state.

Assemblies to check are `shomei-core/src/Shomei/Test/InMemory.hs`,
`shomei-servant/src/Shomei/Servant/Seam.hs`,
`shomei-server/src/Shomei/Server/App.hs`, and `shomei-postgres/test/Main.hs`.
Also inspect `shomei-servant/test/Main.hs`'s `runHybrid` and the narrower harness in
`shomei-core/test/Shomei/Session/Authentication/TimingSpec.hs` when signatures change.
The relevant list segment is `LoginAttemptStore, PasskeyStore, PendingCeremonyStore`.
In the PostgreSQL chains the corresponding source order is
`. runPendingCeremonyStorePostgres . runPasskeyStorePostgres . runLoginAttemptStorePostgres`.
Preserve each assembly's other effects and its own list/runner correspondence.

Verify with the full PostgreSQL suite and the migration composition suite in Concrete
Steps. Acceptance includes round-trip lookup, owner-scoped deletion, sequential and
racing counter checks, and removal of both live and expired ceremonies. If changing
interfaces or wiring, also run `nix develop --command cabal build all` and the servant
suite to catch assembly mismatches. This documentation refresh only needs the current
persistence/migration suites and document checks.


## Concrete Steps


Run commands from the repository root. Nix supplies the Haskell compiler and
PostgreSQL binaries; the test helpers start their own databases. Do not aim the
integration tests or these review steps at an existing application's database.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
rg -n 'UpdatePasskeySignCounter|updatePasskeySignCounter' shomei-core/src/Shomei/Passkey/Store.hs
rg -n 'PutPendingCeremony|TakePendingCeremony' shomei-core/src/Shomei/Passkey/Ceremony/Store.hs
rg -n '0014-shomei-webauthn|0015-shomei-webauthn' shomei-migrations/migrations/shomei/manifest
nix develop --command cabal test shomei-core-test shomei-postgres-test shomei-migrations-test --test-show-details=direct
nix develop --command just migration-check
git diff --check
```

Expect a `Bool` result for counter updates, the two ceremony operations, and both SQL
files in the manifest. All three test suites must report `PASS`; migration-check must
accept manifest membership and the SQL namespace policy. Test totals may grow with
unrelated work, so do not hard-code historical totals as acceptance requirements.
Expected relevant test names include:

```text
PasskeyStore (in-memory)
  create + find by user/credential-id/user-handle
  update sign counter sets counter and last_used_at
  PendingCeremony (in-memory)
    put then take returns the row exactly once
passkey counter advances atomically and preserves counterless authenticators
passkey counter: eight racing nonzero updates have one winner
pending ceremony store: put then take consumes exactly once
pending ceremony store: expired ceremony is not returned
composition preserves a host component's namespace state
```

For changes to interfaces or interpreter assembly, additionally run:

```bash
nix develop --command cabal build all
nix develop --command cabal test shomei-servant-test --test-show-details=direct
```

These are validation instructions for future implementation edits, not claims that
this refresh ran every workspace build and test. No development-database migration
or table drop is necessary to validate the completed plan.


## Validation and Acceptance


### Existing behavioral evidence


The six core store cases cover creation/three-way lookup, counter advancement and
stale/replayed counter rejection, count isolation, owner-scoped deletion, sequential
ceremony consumption, and past-expiry rejection. Inspect the assertions in
`shomei-core/test/Shomei/PasskeyStoreSpec.hs`: metadata assertions currently inspect
the created value, while lookups assert identifiers. Do not call this a complete
field-by-field equality round trip.

The six PostgreSQL cases in `shomei-postgres/test/Main.hs` are
`testPasskeyCreateAndFind`, `testPasskeyUpdateCountDelete`,
`testPasskeyCounterIsCompareAndSwap`, `testPasskeyCounterCasUnderRace`,
`testPendingCeremonyConsumeOnce`, and `testPendingCeremonyExpired`. Each uses `withDb`
and `runApp` with a fresh migrated database. Passkey cases seed a user first to
satisfy the foreign key. Sequential counter proposals `0, 42, 0, 42, 41, 43` starting
from zero yield `True, True, False, False, False, True`. Eight callers proposing 42
from a stored zero yield one `True`. This does not imply only one winner for distinct
increasing proposals, or for zero-to-zero updates: both can legitimately succeed.

PostgreSQL ceremony cases check that a first live take returns a value and leaves
zero rows, a second returns `Nothing`, and a past-expiry take returns `Nothing` and
leaves zero rows. The migration suite composes a host component before and after
Shōmei to prove the schema component does not leak its lookup path. The namespace
checker complements this behavioral test; neither requires restoring the old
migration count.

### Evidence limits and future regression cases


No dedicated pending-ceremony race test or exact-expiry-boundary test was found in
the audited suites. A follow-up test change should use a shared start gate for eight
workers taking one live ceremony, collect every success/error, require exactly one
`Just`, and assert the row is absent. Do this with one shared `World` and separately
with independent calls through the PostgreSQL pool. Bound the test with a timeout
and ensure worker exceptions reach the collector so a failed worker cannot hang it.
This extends evidence for an existing contract, rather than changing its semantics.

Test `now == expiresAt` explicitly in both interpreters: require `Nothing` and
removal. In memory, inspect `World.pendingCeremonies` after the expired take or make
a second take with an earlier time; simply taking twice at an expired time does not
prove deletion. Add missing-ID takes, both ceremony kinds, nullable and present user
IDs, and complete options-byte equality if strengthening round-trip coverage.

Counter follow-up cases should cover a missing credential (`False`), zero-to-zero
in memory, concurrent in-memory proposals, the maximum `Word32`, and preservation
of `lastUsedAt` after rejection using a different proposed timestamp. The current
schema and fake discrepancies documented in Surprises are limitations; invalid SQL
counter-range handling or fake constraint parity require a separately scoped design
change, not an assertion that those guarantees already exist.


## Idempotence and Recovery


Tests use fresh `World` values or throwaway PostgreSQL instances and can be repeated.
An infrastructure startup/build failure is not a failed persistence assertion; retain
the error, correct the environment, and rerun the affected suite. Do not weaken a
security predicate to make a race test pass. Document checks are read-only.

Applied SQL payloads and migration identities are immutable. The migration ledger
skips already-applied work and verifies history; `CREATE TABLE IF NOT EXISTS` alone
would not repair a wrong existing schema. Future corrections use a new migration.
Never reset a durable database or rewrite old migration bytes to resolve drift.
The historical pre-adoption namespace rewrite described by ADR-19 is not permission
to repeat such rewrites on an adopted history.

A rejected counter update is safe and leaves state unchanged. Repeating a successful
nonzero update returns `False`; zero-to-zero intentionally remains admissible.
A ceremony consumed before a later request failure stays consumed: restart the
ceremony with a freshly generated ID and challenge, never reinsert consumed state.
If an interface edit breaks compilation, reconcile each affected type list and its
reverse runner order before proceeding. Git history contains the original milestone
implementation if historical details are needed.


## Interfaces and Dependencies


The existing dynamic store effects expose these public functions; domain types and
identifiers are imported from `Shomei.Passkey.Domain` and `Shomei.Id`:

```haskell
-- Shomei.Passkey.Store
createPasskey :: (PasskeyStore :> es) => NewPasskeyCredential -> Eff es PasskeyCredential
findPasskeysByUser :: (PasskeyStore :> es) => UserId -> Eff es [PasskeyCredential]
findPasskeyByCredentialId :: (PasskeyStore :> es) => WebAuthnCredentialId -> Eff es (Maybe PasskeyCredential)
findPasskeysByUserHandle :: (PasskeyStore :> es) => UserHandle -> Eff es [PasskeyCredential]
updatePasskeySignCounter :: (PasskeyStore :> es) => PasskeyId -> SignatureCounter -> UTCTime -> Eff es Bool
deletePasskey :: (PasskeyStore :> es) => UserId -> PasskeyId -> Eff es ()
countPasskeysByUser :: (PasskeyStore :> es) => UserId -> Eff es Int

-- Shomei.Passkey.Ceremony.Store
putPendingCeremony :: (PendingCeremonyStore :> es) => PendingCeremony -> Eff es ()
takePendingCeremony :: (PendingCeremonyStore :> es) => CeremonyId -> UTCTime -> Eff es (Maybe PendingCeremony)

-- Shomei.Test.InMemory
runPasskeyStore :: (IOE :> es) => IORef World -> Eff (PasskeyStore : es) a -> Eff es a
runPendingCeremonyStore :: (IOE :> es) => IORef World -> Eff (PendingCeremonyStore : es) a -> Eff es a

-- Shomei.Passkey.Postgres
runPasskeyStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (PasskeyStore : es) a -> Eff es a

-- Shomei.Passkey.Ceremony.Postgres
runPendingCeremonyStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (PendingCeremonyStore : es) a -> Eff es a
```

The essential SQL transitions are:

```sql
UPDATE shomei.shomei_webauthn_credentials
SET sign_counter = $2, last_used_at = $3
WHERE passkey_id = $1
  AND (sign_counter < $2 OR ($2 = 0 AND sign_counter = 0))
RETURNING passkey_id;

DELETE FROM shomei.shomei_webauthn_pending_ceremonies
WHERE ceremony_id = $1
RETURNING ceremony_id, user_id, kind, options_blob, created_at, expires_at;
```

The latter statement is followed by `expiresAt > now` in Haskell. Under the ordinary
committed statement execution used here, a competing delete cannot return a row that
another committed delete removed, and a competing update rechecks its condition
against the updated row. These database rules support the source-level atomicity
argument; the listed tests are the executable evidence.

Dependency discovery used Mori. The SQL driver is
`mori://hasql/hasql/packages/hasql`; its encoder guide is
`mori://hasql/hasql/docs/hasql-encoders-best-practices`. Existing code uses
`Hasql.Statement.preparable`, `Hasql.Session.statement`, UUID/bytea/int8/jsonb/text/time
codecs, `rowMaybe` and `rowList`, with tuple encoders from `contravariant-extras`.
The migration engine and embedding API are
`mori://shinzui/pg-migrate/packages/pg-migrate` and
`mori://shinzui/pg-migrate/packages/pg-migrate-embed`. Local dependency sources and the
embedding plugin were inspected; the project Cabal files and `cabal.project` remain
the build inputs. This refresh selects no dependency version, compatibility workaround,
or new bound. Before doing so in later work, rediscover sources through Mori and
verify current releases against the authoritative registry and upstream tags.


## Revision Notes


2026-08-27: Audited Git history, dependent passkey plans, the current source tree,
migrations, and relevant ADRs. Recorded commits `e07b819` and `db79c24` as Plan 16's
implementation, Plans 17 and 18 as consumers, and Plans 48, 50, 55, and 61 as later
evolutions. The recorded rerun passed 278 core and 76 PostgreSQL tests.

2026-10-14 UTC: Reviewed and refreshed the completed plan against `0eedad1`. Replaced
obsolete module paths, codd SQL and embedding instructions, wrong runner order,
non-atomic pseudocode, and the obsolete unit-returning counter API with current
contracts and commands. Preserved historical implementation ownership and decisions,
clarified at-most-once consumption and conditional counter advancement, documented
fake/SQL differences and unchecked counter narrowing, and distinguished existing
test evidence from missing boundary/race coverage. Reused ADR-7, ADR-17, and ADR-19;
no accepted architecture or runtime implementation changed.

Validation on 2026-10-14 UTC: 355 tests passed across the three targeted suites;
migration manifest/namespace validation and document consistency checks passed.
Recorded verified revision and review provenance without backfilling authorship.
