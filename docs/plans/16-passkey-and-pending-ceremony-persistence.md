---
id: 16
slug: passkey-and-pending-ceremony-persistence
title: "Passkey and pending-ceremony persistence"
kind: exec-plan
created_at: 2026-06-17T14:38:15Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
master_plan: "docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md"
---

# Passkey and pending-ceremony persistence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. Today it persists users, sessions, refresh
tokens, one-time tokens, login attempts, and signing keys — but it has no place to store a
**passkey** (a WebAuthn public-key credential) nor the short-lived **challenge state** that
a WebAuthn ceremony needs between its "begin" and "complete" halves. This plan adds exactly
those two storage capabilities, and nothing else.

After this change, a developer can — in a Haskell test, with no HTTP and no browser —
**insert a passkey credential for a user, look it up three different ways (by user, by the
WebAuthn credential id the browser sends back, and by the user handle), bump its signature
counter, count a user's passkeys, and delete it**; and can **stash a pending WebAuthn
ceremony (the challenge + options blob) and consume it exactly once** — a second consume,
or a consume after it has expired, returns nothing. This is the persistence foundation that
the enrollment workflow (`docs/plans/17-passkey-enrollment-workflow-and-management-api.md`)
and the MFA-login workflow (`docs/plans/18-passkey-login-mfa-step-up-and-passwordless.md`)
will build their HTTP surfaces on. The "consume exactly once" property is the security
heart of this plan: a WebAuthn challenge must never be replayable.

You can see it working two ways. First, a new pure in-memory test
(`shomei-core/test/Shomei/PasskeyStoreSpec.hs`) exercises both stores against the fake
`World`, runnable with `nix develop --command cabal test shomei-core-test`. Second, a new
PostgreSQL integration test (added to `shomei-postgres/test/Main.hs`) runs the **real
hasql interpreters** against an ephemeral PostgreSQL that has the **two new migrations**
applied, runnable with `nix develop --command cabal test shomei-postgres-test`. Both prove
behavior, not just that the code compiles.

Concretely, this plan delivers, in Shōmei's hexagonal style (core defines effects with no
infrastructure dependency; `shomei-postgres` interprets them against hasql/PostgreSQL; the
in-memory interpreter backs the test suite):

- two new core **effects** (`effectful` dynamic effects): `Shomei.Effect.PasskeyStore` and
  `Shomei.Effect.PendingCeremonyStore`;
- their **in-memory interpreters** (extending `Shomei.Effect.InMemory.World`);
- their **PostgreSQL interpreters** (`Shomei.Postgres.PasskeyStore` and
  `Shomei.Postgres.PendingCeremonyStore`);
- two new **codd migrations** creating the `shomei_webauthn_credentials` and
  `shomei_webauthn_pending_ceremonies` tables;
- the wiring that inserts both new effects into every **effect-stack list** Shōmei keeps in
  lock-step.

This plan is **EP-2** of MasterPlan 3. Its only hard dependency is **EP-1**
(`docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md`), which
defines the shared passkey **domain types** this plan persists. EP-1 also adds the
`WebAuthnCeremony` effect to the effect stacks (right after `Notifier`); this plan must not
move that entry. See "Context and Orientation" for the exact domain-type contract, which is
reproduced here so this plan is self-contained even if EP-1's document is still a skeleton
when you read it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

### Milestone 1 — core effects + in-memory interpreters + non-DB stack wiring

- [x] Confirm EP-1's `Shomei.Domain.Passkey` module exists and exports the domain types and
      ids listed in "Context and Orientation". (Verified: module + `Shomei.Id` ids/codecs all
      present — EP-1 is Complete.)
- [x] Add `PasskeyId` / `CeremonyId` to `Shomei.Id` IF EP-1 has not already. (Not needed —
      EP-1 already defined both ids and their gen/UUID helpers.)
- [x] Create `shomei-core/src/Shomei/Effect/PasskeyStore.hs` (the effect + smart constructors).
- [x] Create `shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs` (the effect + smart
      constructors).
- [x] Add both modules to `shomei-core.cabal` `exposed-modules`.
- [x] Extend `Shomei.Effect.InMemory.World` with `passkeys` and `pendingCeremonies` fields;
      extend `emptyWorld`.
- [x] Add `runPasskeyStore` and `runPendingCeremonyStore` to `Shomei.Effect.InMemory`;
      export them; add both to `runInMemory`'s inline type list AND its composition, right
      after `runLoginAttemptStore`.
- [x] Insert `PasskeyStore, PendingCeremonyStore` after `LoginAttemptStore`, before
      `Notifier`, in `Shomei.Servant.Seam.AppEffects`.
- [x] Insert the same two entries in the same position in `Shomei.Server.App.AppEffects`
      (the runAppIO chain is M2's job since it needs the PostgreSQL interpreters).
- [x] Add `shomei-core/test/Shomei/PasskeyStoreSpec.hs`; register it in
      `shomei-core.cabal` `other-modules` and in `shomei-core/test/Main.hs`.
- [x] `nix develop --command cabal build shomei-core` green (the full `cabal build all` is
      the M2 gate, per the Plan-of-Work cut — `shomei-servant`/`shomei-server` need M2's
      PostgreSQL interpreters to type-check).
- [x] `nix develop --command cabal test shomei-core-test` green; the new spec passes (29
      tests, including the 6 new PasskeyStore/PendingCeremony cases).

### Milestone 2 — migrations + PostgreSQL interpreters + DB stack wiring

- [x] Create `shomei-migrations/sql-migrations/2026-06-18-10-33-55-shomei-webauthn-credentials.sql`.
- [x] Create `shomei-migrations/sql-migrations/2026-06-18-10-33-56-shomei-webauthn-pending-ceremonies.sql`.
- [x] Touch `shomei-migrations/src/Shomei/Migrations.hs` (added a two-line comment referencing
      the two new files) to force the `embedDir` Template Haskell splice to recompile.
- [x] Confirm `shomei-migrations.cabal` `extra-source-files: sql-migrations/*.sql` already
      globs the new files (it does — no edit needed; see Decision Log).
- [x] Create `shomei-postgres/src/Shomei/Postgres/PasskeyStore.hs`
      (`runPasskeyStorePostgres`).
- [x] Create `shomei-postgres/src/Shomei/Postgres/PendingCeremonyStore.hs`
      (`runPendingCeremonyStorePostgres`).
- [x] Add both modules to `shomei-postgres.cabal` `exposed-modules`.
- [x] Add `. runPendingCeremonyStorePostgres . runPasskeyStorePostgres` to
      `Shomei.Server.App.runAppIO`, in the position matching the AppEffects list (right after
      `runNotifierFromConfig`, before `runLoginAttemptStorePostgres` in the source text —
      i.e. the composition is the reverse of the type list).
- [x] Insert `PasskeyStore, PendingCeremonyStore` after `LoginAttemptStore` in the
      `shomei-postgres/test/Main.hs` `AppEffects`, and add
      `. runPendingCeremonyStorePostgres . runPasskeyStorePostgres` to its `runApp*` chains in
      the matching position. Also updated the servant test's `runHybrid` chain
      (`shomei-servant/test/Main.hs`), which interprets the servant `AppEffects` and would
      otherwise not type-check.
- [x] Add the new integration test cases to `shomei-postgres/test/Main.hs` `tests`.
- [x] `nix develop --command cabal build all` green.
- [x] `nix develop --command cabal test shomei-postgres-test` green; the embedded migration
      count grew from 12 to 14 (codd applied both new migrations) and all 4 new cases pass.
      `cabal test all` green across all 11 suites.

### Remaining / follow-on (not this plan)

- [ ] EP-3 / EP-4 consume these effects. Not in scope here.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Confirmed during implementation (2026-06-17):

- **The embedded migration count grew from 12 to 14, as predicted.** Verified directly with
  `print (length Shomei.Migrations.embeddedFiles)` in a `cabal repl` (temporarily exporting
  `embeddedFiles` for the check, then reverting): it printed `14`. The `shomei-postgres-test`
  run then shows codd applying both new files
  (`Applying 2026-06-18-10-33-55-shomei-webauthn-credentials.sql`,
  `…-01-shomei-webauthn-pending-ceremonies.sql`). Touching `Shomei.Migrations.hs` (a two-line
  comment) was sufficient to force the `embedDir` splice to re-run; no `.cabal` edit was
  needed (the `extra-source-files: sql-migrations/*.sql` glob already covers new files).
- **EP-1 had already landed `WebAuthnCeremony` after `Notifier` in every stack** (the master
  plan marks EP-1 Complete). As instructed, it was left untouched and the two new effects were
  inserted between `LoginAttemptStore` and `Notifier`. The canonical order is now
  `… LoginAttemptStore, PasskeyStore, PendingCeremonyStore, Notifier, WebAuthnCeremony …`.
- **The composition order is the exact reverse of the type-list order** (the head of the
  effect list is interpreted by the *rightmost* `.`-applied runner). The plan's M1 edit-4
  "order check" note listed the two new interpreters as
  `runPasskeyStore . runPendingCeremonyStore`, but with the type list ordered
  `PasskeyStore, PendingCeremonyStore` the composition must read
  `… runNotifier . runPendingCeremonyStore . runPasskeyStore . runLoginAttemptStore …`
  (PendingCeremony *before* Passkey, textually). The compiler is the arbiter; the reversed
  order type-checks and all five lists are consistent. Same shape in `runAppIO`,
  `runHybrid`, and the two `shomei-postgres` test chains.
- **`contrazip10` exists** (`contravariant-extras` generates `contrazip2 .. contrazip42`), so
  the 10-column passkey insert encoder did not need nesting.
- **`OverloadedRecordDot` is unreliable for the EP-1 passkey/ceremony records** (the
  MasterPlan-3 discovery applies to `PasskeyCredential`/`NewPasskeyCredential`/`PendingCeremony`
  too, which share field names under `DuplicateRecordFields`). Every read of those records in
  this plan — in-memory interpreter, both PostgreSQL interpreters, both test suites — uses
  plain record-pattern accessors (`pkUserId PasskeyCredential{userId} = userId`) rather than
  `value.field`; record *construction* with the explicit constructor and `#label`/`#signCounter`
  generic-lens label updates work fine.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store the `transports :: [Text]` field of a passkey as a PostgreSQL `jsonb`
  column (a JSON array of strings), not `text[]` and not a serialized `text` blob.
  Rationale: hasql ships a first-class `jsonb` encoder/decoder over aeson `Value`
  (`Hasql.Encoders.jsonb`, `Hasql.Decoders.jsonb`), and Shōmei already uses it for the
  `shomei_auth_events.payload` column (see `Shomei.Postgres.AuthEventPublisher`). Encoding
  `[Text]` as `Data.Aeson.toJSON` and decoding back with `Data.Aeson.fromJSON` reuses that
  proven path with zero new array-codec machinery. `text[]` would need hasql's array
  encoders (more code, no benefit here, since the list is short and only ever read/written
  whole); a serialized `text` blob loses queryability and JSON validation. The list is tiny
  (a handful of transport hints like `"usb"`, `"internal"`, `"hybrid"`), so jsonb overhead
  is negligible.
  Date: 2026-06-17

- Decision: Implement `TakePendingCeremony` (the consume-once primitive) in PostgreSQL as a
  single `DELETE ... WHERE ceremony_id = $1 RETURNING ...` statement, then filter the
  returned row on expiry in Haskell (return `Nothing` if `expires_at <= now`).
  Rationale: `DELETE ... RETURNING` is atomic — under concurrent requests, at most one
  transaction's `DELETE` can match and return the row; every other concurrent `DELETE` sees
  zero rows. That makes a WebAuthn challenge usable **at most once**, which is the security
  invariant. Doing a `SELECT` then a separate `DELETE` would open a race where two requests
  both read the row before either deletes it. Filtering on expiry *after* the delete (rather
  than `WHERE expires_at > now` in the SQL) means an expired ceremony is still removed from
  the table when taken, so a stale row cannot linger and be retried; `DeleteExpiredCeremonies`
  remains a coarse bulk sweep for rows never taken.
  Date: 2026-06-17

- Decision: Store the WebAuthn signature counter (`SignatureCounter`, a `Word32`) in a
  `bigint` (`int8`) column, encoding `Word32 -> Int64` on write and `Int64 -> Word32` on read.
  Rationale: PostgreSQL has no native unsigned 32-bit integer. A `Word32` ranges 0 ..
  4 294 967 295, which overflows a signed `int4` (`integer`, max 2 147 483 647) but fits
  comfortably in a signed `int8` (`bigint`). hasql offers `int8` over `Int64`. The
  conversions `fromIntegral :: Word32 -> Int64` and `fromIntegral :: Int64 -> Word32` are
  total and lossless for the stored range (every `Word32` maps to a distinct non-negative
  `Int64`, and we only ever read back values we wrote).
  Date: 2026-06-17

- Decision: Force the `embedDir` Template Haskell splice in
  `shomei-migrations/src/Shomei/Migrations.hs` to re-run by editing that module (appending a
  one-line comment that names the two new migration files), and verify the embedded migration
  count grows from 12 to 14 before trusting any test or `just migrate`.
  Rationale: Carried over from MasterPlan 2's discovery (recorded in MasterPlan 3's Surprises
  section): adding `.sql` files under `sql-migrations/` does **not** refresh the embedded
  list until the module holding the `$(embedDir "sql-migrations")` splice is recompiled,
  because the splice is evaluated at compile time over the directory contents. A source edit
  to that module is the reliable trigger; the `.cabal`'s `extra-source-files` glob already
  picks the files up for packaging.
  Date: 2026-06-17

- Decision: `DeletePasskey` is scoped by `UserId` (signature `UserId -> PasskeyId -> ...`),
  deleting only when both match; `FindPasskeyByCredentialId` and `FindPasskeysByUserHandle`
  are NOT user-scoped.
  Rationale: Deletion is a user action ("remove *my* passkey"), so the `WHERE user_id = $1
  AND passkey_id = $2` guard prevents one user deleting another's credential even if a
  passkey id leaks. The two finders are used by the authentication/login path (EP-4), which
  looks a credential up *before* it knows which user is authenticating (passwordless
  discovery keys off the credential id / user handle the browser returns), so they must not
  be user-scoped. This matches the canonical effect contract in MasterPlan 3 IP-2.
  Date: 2026-06-17

- Decision: Confirmed `shomei-migrations.cabal` already globs the new `.sql` files via
  `extra-source-files: sql-migrations/*.sql`; left it unedited and forced the `embedDir`
  re-embed solely by appending a two-line comment to `Shomei.Migrations.hs`.
  Rationale: The glob (verified by reading the `.cabal`) packages any file under
  `sql-migrations/`; only the compile-time splice needs a kick, which a source edit to the
  splice-holding module provides. The embedded count then read 14 (was 12), proving the
  re-embed. No `.cabal` change keeps the diff minimal.
  Date: 2026-06-17

- Decision: Read every EP-1 passkey/ceremony record via plain record-pattern accessors
  (e.g. `pkUserId PasskeyCredential{userId} = userId`), never via `value.field`
  `OverloadedRecordDot`.
  Rationale: MasterPlan 3's EP-1 discovery records that `OverloadedRecordDot`/`HasField` is
  unreliable for the new `DuplicateRecordFields` records even for unique fields. Record
  patterns (and `DisambiguateRecordFields` construction) resolve unambiguously via the
  constructor and are guaranteed to compile. Generic-lens `#field` label *updates*
  (`& #signCounter .~ …`) remain reliable and are used in the in-memory interpreter.
  Date: 2026-06-17

- Decision: Defined `ceremonyKindToText`/`ceremonyKindFromText` locally inside
  `Shomei.Postgres.PendingCeremonyStore` rather than adding them to the shared
  `Shomei.Postgres.Codec`.
  Rationale: The two-constructor `CeremonyKind` enum is local to ceremonies and used by
  exactly one interpreter; keeping it inline avoids growing the shared codec module for a
  single consumer. (The plan explicitly permits either choice; this is the less-coupled one.)
  Date: 2026-06-17

- Decision: `PutPendingCeremony` uses a plain `INSERT` (no `ON CONFLICT`).
  Rationale: Ceremony ids are freshly generated by the workflow per ceremony (a UUIDv7
  `CeremonyId`), so a collision cannot occur in practice; a plain insert is simplest and a
  duplicate would (correctly) surface as a database error rather than silently overwriting.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-17): complete and green.** Both milestones landed exactly as scoped. The
purpose — "insert a passkey, look it up three ways, bump its counter, count, delete it; and
stash a pending ceremony and consume it exactly once" — is now demonstrable two ways:

- `shomei-core/test/Shomei/PasskeyStoreSpec.hs` (pure, in-memory): 6 cases, all green within
  `shomei-core-test` (29 tests total).
- `shomei-postgres/test/Main.hs` (real hasql interpreters against an ephemeral migrated
  PostgreSQL): `testPasskeyCreateAndFind`, `testPasskeyUpdateCountDelete`,
  `testPendingCeremonyConsumeOnce`, `testPendingCeremonyExpired` — all green within
  `shomei-postgres-test` (20 tests total). The consume-once security invariant is proven by
  the `DELETE … RETURNING` count assertions (a second take returns `Nothing`; an expired take
  returns `Nothing` yet still removes the stale row).

`cabal build all` and `cabal test all` are green across all 11 suites. The two new effects sit
in every effect-stack list between `LoginAttemptStore` and `Notifier`, leaving EP-1's
`WebAuthnCeremony` untouched. The embedded migration count rose 12 → 14.

**Gaps / deferred (as planned):** EP-3 (enrollment) and EP-4 (login/MFA) consume these effects
and own their HTTP surfaces; not in scope here. `DeleteExpiredCeremonies` is implemented and
wired but has no caller yet (the future sweeper/cron is EP-4's or operational concern).

**Lessons:** (1) the effect-stack composition is the strict reverse of the type list — the
plan's M1 order-check note had the two new interpreters in the wrong relative order; trust
the compiler. (2) `OverloadedRecordDot` genuinely does not work for the new EP-1 records, so
record-pattern accessors were used everywhere; this is worth carrying into EP-3/EP-4.


## Context and Orientation

This section assumes you know nothing about Shōmei. Read it before touching code.

### What Shōmei is and how it is layered

Shōmei is a multi-package Haskell authentication toolkit built with GHC 9.12.4 and the
`effectful` effect system. It is **hexagonal**:

- `shomei-core` (`shomei-core/src/Shomei/…`) holds the domain model — pure types, the
  workflows, and the **effects**. An effect is a dynamic `effectful` effect: a GADT named like
  `data Foo :: Effect where …` plus small `send`-based smart constructors. The core has **no
  database, JWT, or HTTP dependency**. This is the invariant you must preserve: nothing you
  add to `shomei-core` may import hasql, a WebAuthn library, or servant.
- `shomei-postgres` (`shomei-postgres/src/Shomei/Postgres/…`) **interprets** those effects
  against PostgreSQL using the `hasql` library. Each interpreter is a function
  `run<Port>Postgres :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (<Port> :
  es) a -> Eff es a`.
- `shomei-core/src/Shomei/Effect/InMemory.hs` provides a pure, IORef-backed interpreter for
  **every** effect, used by the test suites. A single mutable `World` record holds all the
  in-memory maps; `runInMemory` stacks one interpreter per effect over `IOE`.
- `shomei-migrations` owns the PostgreSQL schema as timestamped `.sql` files under
  `sql-migrations/`, embedded at compile time and applied by the `codd` migration tool.
- `shomei-servant` exposes HTTP; `shomei-server` assembles everything into a runnable binary.

Identifiers (`Shomei.Id`) are `mmzk-typeid` `KindID`s — a UUIDv7 with a type-level prefix
(`UserId = KindID "user"`, etc.). Each id has `…IdToUUID`/`…IdFromUUID` helpers
(`= getUUID` / `decorateKindID`) so it stores as a native PostgreSQL `uuid` column. A new id
type follows that exact pattern.

### The shared passkey domain types (defined by EP-1 — DO NOT redefine here)

EP-1 (`docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md`)
introduces module `Shomei.Domain.Passkey` in `shomei-core`, plus the two new id types. This
plan **consumes** those types; it must not redefine them. The canonical contract — which
EP-1 also uses, reproduced here so this plan stands alone — is:

```haskell
-- Shomei.Domain.Passkey (owned by EP-1)
newtype WebAuthnCredentialId = WebAuthnCredentialId ByteString
newtype UserHandle           = UserHandle ByteString
newtype PublicKeyBytes       = PublicKeyBytes ByteString
newtype SignatureCounter     = SignatureCounter Word32

data CeremonyKind = RegistrationCeremony | AuthenticationCeremony

data NewPasskeyCredential = NewPasskeyCredential
  { userId       :: UserId
  , credentialId :: WebAuthnCredentialId
  , userHandle   :: UserHandle
  , publicKey    :: PublicKeyBytes
  , signCounter  :: SignatureCounter
  , transports   :: [Text]
  , label        :: Maybe Text
  , createdAt    :: UTCTime
  }

data PasskeyCredential = PasskeyCredential
  { passkeyId    :: PasskeyId
  , userId       :: UserId
  , credentialId :: WebAuthnCredentialId
  , userHandle   :: UserHandle
  , publicKey    :: PublicKeyBytes
  , signCounter  :: SignatureCounter
  , transports   :: [Text]
  , label        :: Maybe Text
  , createdAt    :: UTCTime
  , lastUsedAt   :: Maybe UTCTime
  }

data PendingCeremony = PendingCeremony
  { ceremonyId  :: CeremonyId
  , userId      :: Maybe UserId
  , kind        :: CeremonyKind
  , optionsBlob :: ByteString
  , createdAt   :: UTCTime
  , expiresAt   :: UTCTime
  }
```

And in `Shomei.Id` (added by EP-1):

```haskell
type PasskeyId  = KindID "passkey"            -- stored as a uuid column
type CeremonyId = KindID "webauthn_ceremony"  -- stored as a uuid column
```

with the matching generators and codecs `genPasskeyId`, `passkeyIdToUUID`,
`passkeyIdFromUUID`, `genCeremonyId`, `ceremonyIdToUUID`, `ceremonyIdFromUUID` (mirroring the
existing `genUserId` / `userIdToUUID` / `userIdFromUUID` triple in
`shomei-core/src/Shomei/Id.hs`).

> Coordination note. If, when you start, `Shomei.Domain.Passkey` and the two ids do **not**
> yet exist (EP-1 still a skeleton), STOP: this is a hard dependency. Do not invent the types
> here — they must be defined once, by EP-1, so EP-3/EP-4 share them. The one acceptable
> exception is the two id type aliases: if EP-1 has defined `Shomei.Domain.Passkey` but not
> the ids, add `PasskeyId`/`CeremonyId` and their gen/UUID helpers to `Shomei.Id` following
> the existing pattern, and record it in the Decision Log.

### How `WebAuthnCredentialId`, `UserHandle`, `PublicKeyBytes` cross to PostgreSQL

All three wrap a `ByteString`; they store as `bytea`. hasql provides `Hasql.Encoders.bytea`
and `Hasql.Decoders.bytea` over strict `ByteString`. The `WebAuthnCredentialId` is the
opaque handle the browser returns at assertion time, so it is the natural lookup key for the
login path and gets a `UNIQUE` index.

### The store this plan mirrors

`shomei-core/src/Shomei/Effect/VerificationTokenStore.hs` is the **template** for a core
effect (GADT + `type instance DispatchOf … = Dynamic` + one smart constructor per operation).
`shomei-postgres/src/Shomei/Postgres/VerificationTokenStore.hs` is the template for a
PostgreSQL interpreter (a `Statement` per operation built with `preparable`, hasql
`Hasql.Encoders`/`Hasql.Decoders`, `contrazipN` from `contravariant-extras` to combine
encoders, `runSession` from `Shomei.Postgres.Database`, and `throwError (InternalAuthError …)`
on a hasql `Left`). The in-memory interpreter `runVerificationTokenStore` in
`Shomei.Effect.InMemory` is the template for the in-memory pair. Study those three before
writing code.

### The effect-stack lists that must stay in lock-step

Five lists enumerate the effect stack in the same relative order, and the workflows rely on
that order being identical across all of them:

1. `Shomei.Servant.Seam.AppEffects` (`shomei-servant/src/Shomei/Servant/Seam.hs`).
2. `Shomei.Server.App.AppEffects` and its `runAppIO` interpreter chain
   (`shomei-server/src/Shomei/Server/App.hs`).
3. `Shomei.Effect.InMemory.runInMemory`'s inline type list and its composition
   (`shomei-core/src/Shomei/Effect/InMemory.hs`).
4. The `AppEffects` type and the `runApp` / `runAppWithNotifications` / `runAppAtTime`
   chains in `shomei-postgres/test/Main.hs`.

This plan inserts `PasskeyStore` then `PendingCeremonyStore` immediately **after**
`LoginAttemptStore` and **before** `Notifier` in all of them. (EP-1 separately adds
`WebAuthnCeremony` right after `Notifier`; this plan must not reorder or remove it.)


## Plan of Work

The work splits cleanly into two independently verifiable milestones. M1 is the core effects
plus their in-memory interpreters plus the non-database stack wiring — it needs no
PostgreSQL and is verified by a pure `shomei-core` test. M2 is the migrations plus the
PostgreSQL interpreters plus the database stack wiring — verified by the `shomei-postgres`
integration test against an ephemeral PostgreSQL.

### Milestone 1 — core effects, in-memory interpreters, non-DB wiring

**Scope and end state.** At the end of M1, `shomei-core` exports two new effects and their
in-memory interpreters, the servant and server `AppEffects` lists contain the two new
entries, and a new pure test exercises every operation of both stores against the fake
`World`. `nix develop --command cabal build all` and
`nix develop --command cabal test shomei-core-test` are green. No PostgreSQL is touched.

**Edits.**

1. **`shomei-core/src/Shomei/Effect/PasskeyStore.hs` (new).** Mirror
   `VerificationTokenStore.hs` exactly in shape: the same three `LANGUAGE` pragmas
   (`DataKinds`, `GADTs`, `TypeFamilies`), `import Shomei.Prelude`, the `effectful` imports,
   and `import` the domain types from `Shomei.Domain.Passkey` and the ids from `Shomei.Id`.
   Define:

   ```haskell
   data PasskeyStore :: Effect where
     CreatePasskey               :: NewPasskeyCredential -> PasskeyStore m PasskeyCredential
     FindPasskeysByUser          :: UserId -> PasskeyStore m [PasskeyCredential]
     FindPasskeyByCredentialId   :: WebAuthnCredentialId -> PasskeyStore m (Maybe PasskeyCredential)
     FindPasskeysByUserHandle    :: UserHandle -> PasskeyStore m [PasskeyCredential]
     UpdatePasskeySignCounter    :: PasskeyId -> SignatureCounter -> UTCTime -> PasskeyStore m ()
     DeletePasskey               :: UserId -> PasskeyId -> PasskeyStore m ()
     CountPasskeysByUser         :: UserId -> PasskeyStore m Int

   type instance DispatchOf PasskeyStore = Dynamic
   ```

   plus one `send`-based smart constructor per operation, e.g.
   `createPasskey = send . CreatePasskey`,
   `updatePasskeySignCounter i c t = send (UpdatePasskeySignCounter i c t)`,
   `deletePasskey u p = send (DeletePasskey u p)`, etc. Export the type, its constructors
   `(PasskeyStore (..))`, and every smart constructor. `UpdatePasskeySignCounter` semantics:
   set both `sign_counter` and `last_used_at` to the new counter / timestamp (the assertion
   that bumps the counter is also the credential's most recent use).

2. **`shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs` (new).** Same shape. Define:

   ```haskell
   data PendingCeremonyStore :: Effect where
     PutPendingCeremony        :: PendingCeremony -> PendingCeremonyStore m ()
     TakePendingCeremony       :: CeremonyId -> UTCTime -> PendingCeremonyStore m (Maybe PendingCeremony)
     DeleteExpiredCeremonies   :: UTCTime -> PendingCeremonyStore m ()

   type instance DispatchOf PendingCeremonyStore = Dynamic
   ```

   plus `putPendingCeremony`, `takePendingCeremony`, `deleteExpiredCeremonies` smart
   constructors. Document on `TakePendingCeremony` that it is **consume-once**: it removes
   the row and returns it only if present AND not yet expired (`expiresAt > now`); it returns
   `Nothing` if the ceremony is absent OR expired. The `UTCTime` argument is "now", supplied
   by the caller (the workflow reads it from the `Clock` effect).

3. **`shomei-core/shomei-core.cabal`.** Add the two modules to the library's
   `exposed-modules` (alphabetically: after `Shomei.Effect.PasswordResetTokenStore` add
   `Shomei.Effect.PendingCeremonyStore`; add `Shomei.Effect.PasskeyStore` after
   `Shomei.Effect.PasswordHasher`). No new dependencies — `bytestring` and the rest are
   already present.

4. **`shomei-core/src/Shomei/Effect/InMemory.hs`.**
   - Imports: add `import Shomei.Domain.Passkey (…)` for the domain types, the
     `PasskeyId`/`CeremonyId`/`genPasskeyId`/`genCeremonyId` from `Shomei.Id`, and
     `import Shomei.Effect.PasskeyStore (PasskeyStore (..))`,
     `import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore (..))`.
   - `World`: add two strict fields, placed right after `accountLockouts`:
     `passkeys :: !(Map PasskeyId PasskeyCredential)` and
     `pendingCeremonies :: !(Map CeremonyId PendingCeremony)`.
   - `emptyWorld`: add `passkeys = Map.empty` and `pendingCeremonies = Map.empty`.
   - Add `runPasskeyStore` (mirror `runVerificationTokenStore`):
     - `CreatePasskey nc` — `pid <- genPasskeyId`; build a `PasskeyCredential` copying every
       field from `nc`, setting `passkeyId = pid` and `lastUsedAt = Nothing`; insert into
       `#passkeys` keyed by `pid`; return it.
     - `FindPasskeysByUser uid` — `[p | p <- Map.elems w.passkeys, p.userId == uid]`.
     - `FindPasskeyByCredentialId cid` — `listToMaybe [p | p <- Map.elems w.passkeys,
       p.credentialId == cid]`.
     - `FindPasskeysByUserHandle uh` — `[p | p <- Map.elems w.passkeys, p.userHandle == uh]`.
     - `UpdatePasskeySignCounter pid c t` — `Map.adjust (\p -> p & #signCounter .~ c &
       #lastUsedAt .~ Just t) pid`.
     - `DeletePasskey uid pid` — adjust the map to delete `pid` only when the stored
       passkey's `userId == uid` (e.g. `Map.update (\p -> if p.userId == uid then Nothing
       else Just p) pid`).
     - `CountPasskeysByUser uid` — `length [p | p <- Map.elems w.passkeys, p.userId == uid]`.
   - Add `runPendingCeremonyStore` (mirror, using `genCeremonyId` is NOT needed — the
     ceremony id is supplied in the `PendingCeremony` value):
     - `PutPendingCeremony pc` — `Map.insert pc.ceremonyId pc` into `#pendingCeremonies`.
     - `TakePendingCeremony cid now'` — read the world; look up `cid`; if found AND
       `pc.expiresAt > now'`, delete it and return `Just pc`; otherwise (absent OR expired)
       delete it if present (so an expired row is also removed) and return `Nothing`. A clean
       way: `case Map.lookup cid w.pendingCeremonies of { Nothing -> pure Nothing; Just pc ->
       do { modifyIORef' ref (#pendingCeremonies %~ Map.delete cid); pure (if pc.expiresAt >
       now' then Just pc else Nothing) } }`.
     - `DeleteExpiredCeremonies now'` — `#pendingCeremonies %~ Map.filter (\pc -> pc.expiresAt
       > now')`.
   - Export `runPasskeyStore` and `runPendingCeremonyStore` in the module export list (next
     to `runLoginAttemptStore`).
   - `runInMemory`: insert `PasskeyStore` and `PendingCeremonyStore` into the inline type
     list right after `LoginAttemptStore` and before `Notifier`; insert
     `. runPasskeyStore ref . runPendingCeremonyStore ref` into the composition at the
     matching position (the composition is written outermost-last, so these go right after
     `. runNotifier ref` reading top-to-bottom and right before `. runLoginAttemptStore ref`
     — i.e. between `runNotifier` and `runLoginAttemptStore` in the textual source, because
     the list head is interpreted last; double-check against the existing pattern so
     `Notifier` stays *outside* (above) the two new stores, exactly as the type list orders
     `… LoginAttemptStore, PasskeyStore, PendingCeremonyStore, Notifier …`).

   > Order check: in `runInMemory` the type list is head-first (`UserStore` first), and the
   > composition is the reverse — the **last** `.`-applied interpreter handles the **head**
   > of the list. The existing source reads `… . runNotifier ref . runLoginAttemptStore ref
   > . runPasswordResetTokenStore ref …`. Since `PasskeyStore`/`PendingCeremonyStore` sit in
   > the type list *between* `LoginAttemptStore` and `Notifier`, the composition must read
   > `… . runNotifier ref . runPasskeyStore ref . runPendingCeremonyStore ref
   > . runLoginAttemptStore ref …`. Verify by compiling: a mismatch is a type error.

5. **`shomei-servant/src/Shomei/Servant/Seam.hs`.** Add the two imports
   (`import Shomei.Effect.PasskeyStore (PasskeyStore)`,
   `import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore)`) and insert
   `PasskeyStore` and `PendingCeremonyStore` into the `AppEffects` type list after
   `LoginAttemptStore`, before `Notifier`.

6. **`shomei-server/src/Shomei/Server/App.hs`.** Add the two imports and insert the two
   entries into the `AppEffects` type list in the same position. (The `runAppIO` chain edit
   is deferred to M2, where the PostgreSQL interpreters exist; if you compile after this step
   only, `AppEffects` will list effects with no interpreter and `runAppIO` will not
   type-check — so do step 6 and M2 step 4 together if you want `shomei-server` to compile in
   isolation. It is fine to let `shomei-server` be temporarily uncompilable between M1 and M2
   as long as `cabal build shomei-core` and `cabal test shomei-core-test` are green at the M1
   checkpoint; note this split in Progress.)

   > Practical sequencing: to keep `cabal build all` green at the M1 checkpoint, do the
   > `Shomei.Server.App` `AppEffects` edit AND its `runAppIO` edit (M2 step 4) in the same
   > pass, which means M1's "build all" checkpoint depends on the PostgreSQL interpreter
   > modules existing. The cleaner cut is: M1 builds and tests **`shomei-core` only**
   > (`cabal build shomei-core && cabal test shomei-core-test`), and the full
   > `cabal build all` is an M2 acceptance gate. Use that cut; it is reflected in Concrete
   > Steps.

7. **`shomei-core/test/Shomei/PasskeyStoreSpec.hs` (new).** A `tasty`/`tasty-hunit` module
   exposing `tests :: TestTree`, following `shomei-core/test/Shomei/WorkflowSpec.hs`'s style.
   It builds an `IORef World` with `emptyWorld t0`, runs operations through `runInMemory`,
   and asserts. See "Validation and Acceptance" for the exact cases. Register it in
   `shomei-core.cabal` `other-modules` and add `Shomei.PasskeyStoreSpec.tests` to the list in
   `shomei-core/test/Main.hs`.

### Milestone 2 — migrations, PostgreSQL interpreters, DB wiring

**Scope and end state.** At the end of M2, two new migration files create the
`shomei_webauthn_credentials` and `shomei_webauthn_pending_ceremonies` tables; the embedded
migration count has grown from 12 to 14; `shomei-postgres` exports the two PostgreSQL
interpreters; the server `runAppIO` and the `shomei-postgres` test harness interpret the two
new effects; and a new set of integration test cases proves insert/query-three-ways/update/
delete for a passkey and consume-exactly-once for a pending ceremony against a real
PostgreSQL. `nix develop --command cabal build all` and
`nix develop --command cabal test shomei-postgres-test` are green.

**Edits.**

1. **`shomei-migrations/sql-migrations/2026-06-18-10-33-55-shomei-webauthn-credentials.sql`
   (new).** Exact contents in "Concrete Steps". Timestamp `2026-06-18-10-33-55` is strictly
   later than the existing latest (`2026-06-05-12-37-21`), so codd orders it last but one.

2. **`shomei-migrations/sql-migrations/2026-06-18-10-33-56-shomei-webauthn-pending-ceremonies.sql`
   (new).** Exact contents in "Concrete Steps". Timestamp `2026-06-18-10-33-56` orders it
   last.

3. **`shomei-migrations/src/Shomei/Migrations.hs`.** Append a comment line to the block that
   documents the embedding (right after the existing 2026-06-05 note), naming the two new
   files, to force the `embedDir` splice to recompile. Example line to add:
   `-- WebAuthn migrations (shomei_webauthn_credentials, shomei_webauthn_pending_ceremonies)`
   `-- were added on 2026-06-18 by EP-2, requiring another recompile of this splice.` The
   `shomei-migrations.cabal` `extra-source-files: sql-migrations/*.sql` glob already covers
   the new files — confirm, do not edit (record in Decision Log).

4. **`shomei-postgres/src/Shomei/Postgres/PasskeyStore.hs` (new).** Mirror
   `Shomei.Postgres.VerificationTokenStore`. Signature
   `runPasskeyStorePostgres :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff
   (PasskeyStore : es) a -> Eff es a`, `interpret_ \case` over the seven operations. Imports:
   `Data.UUID (UUID)`, `Data.Int (Int64)`, `Data.Word (Word32)` (already via prelude?
   import if not), `Contravariant.Extras (contrazipN…)`, `Hasql.Decoders qualified as D`,
   `Hasql.Encoders qualified as E`, `Hasql.Session qualified as Session`,
   `Hasql.Statement (Statement, preparable)`, `Data.Aeson (toJSON, fromJSON, Result (..),
   Value)`, the effectful/error imports, the domain types from `Shomei.Domain.Passkey`, the
   ids and codecs from `Shomei.Id`, `Shomei.Error (AuthError (..))`, and
   `Shomei.Postgres.Database (Database, runSession)`, `Shomei.Postgres.Codec (tshow)`.
   - Define a row type alias for a stored credential, e.g.
     `type PasskeyRow = (UUID, UUID, ByteString, ByteString, ByteString, Int64, Value, Maybe
     Text, UTCTime, Maybe UTCTime)` matching the column order `(passkey_id, user_id,
     credential_id, user_handle, public_key, sign_counter, transports, label, created_at,
     last_used_at)`.
   - `CreatePasskey nc` — `pid <- genPasskeyId`; build the `PasskeyCredential` (copy fields,
     `passkeyId = pid`, `lastUsedAt = Nothing`); build the row, encoding
     `WebAuthnCredentialId`/`UserHandle`/`PublicKeyBytes` to their `ByteString`s,
     `SignatureCounter (Word32) -> Int64` via `fromIntegral`, `transports :: [Text] -> Value`
     via `toJSON`; run the insert `Statement`; on `Left` `throwError (InternalAuthError …)`;
     on `Right` return the built `PasskeyCredential`. (Same `genId`-then-build-then-insert
     pattern as `CreateVerificationToken`.)
   - `FindPasskeysByUser uid` — `Session.statement (userIdToUUID uid) findByUserStmt` whose
     decoder is `D.rowList passkeyRowDecoder`; `traverse rebuild`.
   - `FindPasskeyByCredentialId (WebAuthnCredentialId bs)` — `findByCredentialIdStmt` with
     `D.rowMaybe`; `traverse rebuild`.
   - `FindPasskeysByUserHandle (UserHandle bs)` — `findByUserHandleStmt` with `D.rowList`;
     `traverse rebuild`.
   - `UpdatePasskeySignCounter pid c t` — `updateSignCounterStmt` with params
     `(passkeyIdToUUID pid, fromIntegral c :: Int64, t)`, setting `sign_counter` AND
     `last_used_at`.
   - `DeletePasskey uid pid` — `deletePasskeyStmt` with `(userIdToUUID uid, passkeyIdToUUID
     pid)` and `WHERE user_id = $1 AND passkey_id = $2`.
   - `CountPasskeysByUser uid` — `countByUserStmt` returning a single `int8`, decoded to
     `Int` via `fromIntegral`.
   - `rebuild`/`rebuildPasskey :: PasskeyRow -> Either Text PasskeyCredential` reconstructs
     the record: `passkeyIdFromUUID`, `userIdFromUUID`, wrap the three `bytea`s back into
     their newtypes, `SignatureCounter (fromIntegral int64)`, decode the `Value` back to
     `[Text]` with `fromJSON` (a `Data.Aeson.Error msg` becomes `Left ("invalid transports
     json: " <> pack msg)`). Surface a `Left` from `rebuild` as `throwError
     (InternalAuthError …)`, exactly as `VerificationTokenStore` does with `rebuildToken`.
   - Encoders/decoders: `E.uuid`, `E.bytea`, `E.int8`, `E.jsonb`, `E.text` (nullable for
     label), `E.timestamptz` (nullable for last_used_at); decoders the matching
     `D.uuid`/`D.bytea`/`D.int8`/`D.jsonb`/`D.text`/`D.timestamptz` with `D.nonNullable` /
     `D.nullable`. Combine insert params with `contrazip10` (from `contravariant-extras`; if
     `contrazip10` is unavailable, nest two `contrazipN`s — verify which arities the pinned
     `contravariant-extras` exports and pick accordingly; record in Surprises if you nest).

5. **`shomei-postgres/src/Shomei/Postgres/PendingCeremonyStore.hs` (new).** Mirror likewise.
   `runPendingCeremonyStorePostgres :: (Database :> es, IOE :> es, Error AuthError :> es) =>
   Eff (PendingCeremonyStore : es) a -> Eff es a`.
   - Row type `type CeremonyRow = (UUID, Maybe UUID, Text, ByteString, UTCTime, UTCTime)` for
     `(ceremony_id, user_id, kind, options_blob, created_at, expires_at)`.
   - `kind` text codec: a local `ceremonyKindToText`/`ceremonyKindFromText`
     (`RegistrationCeremony -> "registration"`, `AuthenticationCeremony -> "authentication"`)
     — define inline in this module (it is a tiny enum local to ceremonies; not worth adding
     to the shared `Shomei.Postgres.Codec`, though you may add it there if you prefer
     symmetry — record the choice).
   - `PutPendingCeremony pc` — build the row (`ceremonyIdToUUID`, `fmap userIdToUUID
     pc.userId`, `ceremonyKindToText pc.kind`, the `optionsBlob` `ByteString`, timestamps);
     run an `INSERT`; on `Left` throw. (Use a plain `INSERT`; ceremony ids are freshly
     generated by the workflow per ceremony, so no upsert is needed. If you want
     belt-and-braces idempotence, `INSERT … ON CONFLICT (ceremony_id) DO UPDATE SET …` is
     acceptable — record the choice.)
   - `TakePendingCeremony cid now'` — run `takeStmt` (a `DELETE … RETURNING` statement, see
     SQL below) with `ceremonyIdToUUID cid`, decoder `D.rowMaybe ceremonyRowDecoder`; on
     `Left` throw; on `Right Nothing` return `Nothing`; on `Right (Just row)` rebuild the
     `PendingCeremony`, then **filter on expiry**: return `Just pc` iff `pc.expiresAt > now'`,
     else `Nothing`. The row is already deleted regardless (that is the point — an expired
     take still removes the stale row).
   - `DeleteExpiredCeremonies now'` — `deleteExpiredStmt`: `DELETE … WHERE expires_at <= $1`.
   - `rebuildCeremony :: CeremonyRow -> Either Text PendingCeremony` with
     `ceremonyKindFromText`, `ceremonyIdFromUUID`, `fmap userIdFromUUID` for the nullable
     user id.

6. **`shomei-postgres/shomei-postgres.cabal`.** Add `Shomei.Postgres.PasskeyStore` and
   `Shomei.Postgres.PendingCeremonyStore` to the library `exposed-modules`. No new
   dependencies — `aeson`, `bytestring`, `contravariant-extras`, `hasql`, `uuid`, `time`,
   `text`, `shomei-core` are all present.

7. **`shomei-server/src/Shomei/Server/App.hs`.** Imports:
   `import Shomei.Postgres.PasskeyStore (runPasskeyStorePostgres)` and
   `import Shomei.Postgres.PendingCeremonyStore (runPendingCeremonyStorePostgres)`. In
   `runAppIO`, insert `. runPasskeyStorePostgres . runPendingCeremonyStorePostgres` in the
   position matching the `AppEffects` list — between `. runNotifierFromConfig env.envConfig`
   and `. runLoginAttemptStorePostgres` in the source text (same head-last reasoning as the
   in-memory chain). Verify by compiling.

8. **`shomei-postgres/test/Main.hs`.** Imports the two interpreters and the two effects' smart
   constructors and the `Shomei.Domain.Passkey`/`Shomei.Id` types. Insert `PasskeyStore` and
   `PendingCeremonyStore` after `LoginAttemptStore` in the test `AppEffects`, and insert
   `. runPasskeyStorePostgres . runPendingCeremonyStorePostgres` in the same relative
   position in each of `runAppWithNotifications` and the `runAppAtTime` chain (between
   `. runNotifierRef ref` and `. runLoginAttemptStorePostgres`). Add the new test cases (see
   Validation) to the `tests` list.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside the
project's Nix dev shell (prefix build/test commands with `nix develop --command`).

### Step 0 — verify the EP-1 precondition

```bash
ls shomei-core/src/Shomei/Domain/Passkey.hs && \
  grep -nE 'PasskeyId|CeremonyId|genPasskeyId|genCeremonyId' shomei-core/src/Shomei/Id.hs
```

Expected: the file exists and `Shomei.Id` mentions the ids/generators. If not, see the
coordination note in "Context and Orientation".

### Step 1 — author the M1 source (see Plan of Work edits 1–7), then:

```bash
nix develop --command cabal build shomei-core
nix develop --command cabal test shomei-core-test
```

Expected transcript tail (illustrative):

```text
shomei-core-test
  shomei-core-test
    ...
    PasskeyStore (in-memory)
      create + find by user/credential-id/user-handle: OK
      update sign counter sets counter and last_used_at: OK
      count passkeys by user: OK
      delete is scoped to the owning user: OK
    PendingCeremony (in-memory)
      put then take returns the row exactly once: OK
      take of an expired ceremony returns Nothing: OK

All N tests passed (0.0Ns)
```

### Step 2 — write the two migration files.

`shomei-migrations/sql-migrations/2026-06-18-10-33-55-shomei-webauthn-credentials.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_webauthn_credentials (
  passkey_id    uuid PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES shomei_users(user_id),
  credential_id bytea NOT NULL UNIQUE,
  user_handle   bytea NOT NULL,
  public_key    bytea NOT NULL,
  sign_counter  bigint NOT NULL,
  transports    jsonb NOT NULL,
  label         text NULL,
  created_at    timestamptz NOT NULL,
  last_used_at  timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_webauthn_credentials_user_id_idx
  ON shomei_webauthn_credentials (user_id);
CREATE INDEX IF NOT EXISTS shomei_webauthn_credentials_user_handle_idx
  ON shomei_webauthn_credentials (user_handle);
```

(The `credential_id` column already gets a unique B-tree index from the `UNIQUE`
constraint, so no separate index statement is needed for it. The `user_id` index speeds
`FindPasskeysByUser`/`CountPasskeysByUser`; the `user_handle` index speeds
`FindPasskeysByUserHandle`.)

`shomei-migrations/sql-migrations/2026-06-18-10-33-56-shomei-webauthn-pending-ceremonies.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_webauthn_pending_ceremonies (
  ceremony_id  uuid PRIMARY KEY,
  user_id      uuid NULL REFERENCES shomei_users(user_id),
  kind         text NOT NULL,
  options_blob bytea NOT NULL,
  created_at   timestamptz NOT NULL,
  expires_at   timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_webauthn_pending_ceremonies_expires_at_idx
  ON shomei_webauthn_pending_ceremonies (expires_at);
```

### Step 3 — force the migration splice to re-embed, then confirm the count.

Edit `shomei-migrations/src/Shomei/Migrations.hs` (add the two-line comment from Plan of
Work M2 edit 3). Then:

```bash
nix develop --command cabal build shomei-migrations
```

Confirm the embedded count grew from 12 to 14 with a one-off check (the embedded list is
`embeddedFiles`; print its length via ghci, or run `just migrate` against a scratch DB and
watch codd apply 14 migrations). Quick ghci check:

```bash
nix develop --command cabal repl shomei-migrations \
  --repl-options -e --repl-options 'length Shomei.Migrations.embeddedFiles'
```

Expected:

```text
14
```

(If `embeddedFiles` is not exported, temporarily add it to the module's export list for the
check, or evaluate `length <$> (Shomei.Migrations.shomeiMigrations :: IO _)` — adapt to the
`MonadFail`/`EnvVars` context as needed. The point is to SEE 14, not 12.)

### Step 4 — author the M2 PostgreSQL source (Plan of Work edits 4–8), then:

```bash
nix develop --command cabal build all
nix develop --command cabal test shomei-postgres-test
```

Expected transcript tail (illustrative; the ephemeral PostgreSQL spin-up is handled by
`shomei-migrations:test-support` via `withShomeiMigratedDatabase`):

```text
shomei-postgres
  create + find user round-trips: OK
  ...
  passkey store: create + find by user/credential-id/user-handle: OK
  passkey store: update sign counter + count + delete (user-scoped): OK
  pending ceremony store: put then take consumes exactly once: OK
  pending ceremony store: expired ceremony is not returned: OK

All N tests passed (Ns)
```

### Step 5 — (optional) apply the migrations to the dev database to eyeball the tables.

```bash
nix develop --command just migrate
nix develop --command psql -c '\d shomei.shomei_webauthn_credentials'
nix develop --command psql -c '\d shomei.shomei_webauthn_pending_ceremonies'
```

Expected: `just migrate` `touch`es the `.cabal`, rebuilds, and codd reports applying the new
migrations (it is idempotent — re-running applies nothing new); `\d` shows the two tables
with the columns and indexes above.


## Validation and Acceptance

Acceptance is **observable behavior**, not compilation. Two test layers exercise the same
operations.

### M1 — pure in-memory test (`shomei-core/test/Shomei/PasskeyStoreSpec.hs`)

Build a fixed clock `t0` and an `IORef World` via `emptyWorld t0`; seed a user with
`createUser` (so `user_id` is a real id) where needed, or fabricate a `UserId` with
`genUserId` for the pure store (the in-memory passkey store does not enforce the FK). Drive
operations through `runInMemory ref`.

1. **Create + find three ways.** `createPasskey (NewPasskeyCredential uid cid uh pk
   (SignatureCounter 0) ["internal","hybrid"] (Just "My YubiKey") t0)`; then
   `findPasskeysByUser uid` returns a one-element list whose `passkeyId` equals the created
   one; `findPasskeyByCredentialId cid` returns `Just` that credential; `findPasskeysByUserHandle
   uh` returns the one-element list. Assert the round-tripped `transports`, `label`,
   `signCounter`, and `createdAt` survive unchanged and `lastUsedAt == Nothing`.
2. **Update sign counter.** `updatePasskeySignCounter pid (SignatureCounter 7) t1` then
   re-find: `signCounter == SignatureCounter 7` and `lastUsedAt == Just t1`.
3. **Count.** Insert a second passkey for the same user and a third for a different user;
   `countPasskeysByUser uid == 2`.
4. **User-scoped delete.** `deletePasskey otherUid pid` (wrong user) leaves the passkey
   present; `deletePasskey uid pid` removes it; `findPasskeyByCredentialId cid == Nothing`
   afterward.
5. **Pending ceremony consume-once.** Build `pc = PendingCeremony cid Nothing
   RegistrationCeremony optsBytes t0 (addUTCTime 300 t0)`; `putPendingCeremony pc`; the first
   `takePendingCeremony cid t0` returns `Just pc`; a second `takePendingCeremony cid t0`
   returns `Nothing`.
6. **Expired ceremony.** `putPendingCeremony pc2` with `expiresAt = addUTCTime 60 t0`; then
   `takePendingCeremony cid2 (addUTCTime 120 t0)` (now is past expiry) returns `Nothing`; and
   a subsequent take also returns `Nothing` (the expired row was removed).

Run: `nix develop --command cabal test shomei-core-test`. Acceptance: all assertions pass.

### M2 — PostgreSQL integration test (`shomei-postgres/test/Main.hs`)

Each case uses `withDb` to get a fresh migrated ephemeral database and pool, and
`runApp pool …` to drive the real interpreters. Seed a user via `createUser` first (the FK
`user_id REFERENCES shomei_users` must be satisfied). Use a fixed-bytes `WebAuthnCredentialId
"cred-1"`, `UserHandle "uh-1"`, `PublicKeyBytes "pk-1"`.

1. **`testPasskeyCreateAndFind`.** Create a user; `createPasskey` a credential with
   `transports ["usb","nfc"]`, label `Just "key"`, counter `0`. Then
   `findPasskeysByUser u.userId`, `findPasskeyByCredentialId (WebAuthnCredentialId "cred-1")`,
   and `findPasskeysByUserHandle (UserHandle "uh-1")` all return the credential, and the
   `transports`/`label`/`signCounter` survived the jsonb/bigint round-trip. Also assert with
   `scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_credentials"` `== 1`.
2. **`testPasskeyUpdateCountDelete`.** From the created credential: `updatePasskeySignCounter
   pid (SignatureCounter 42) t`; re-find shows `signCounter == 42` and a non-null
   `last_used_at` (assert `lastUsedAt` is `Just`). `countPasskeysByUser u.userId == 1`.
   `deletePasskey otherUserId pid` (a different user's id) does NOT delete (count still 1 via
   `scalarInt`); `deletePasskey u.userId pid` deletes (count 0).
3. **`testPendingCeremonyConsumeOnce`.** `putPendingCeremony` a registration ceremony
   `expiresAt = now + 300s`. First `takePendingCeremony cid now` returns `Just`; the second
   returns `Nothing`; `scalarInt pool "SELECT count(*) FROM
   shomei.shomei_webauthn_pending_ceremonies" == 0` after the first take (the
   `DELETE … RETURNING` removed it).
4. **`testPendingCeremonyExpired`.** `putPendingCeremony` with `expiresAt = now`. Then
   `takePendingCeremony cid (addUTCTime 1 now)` (now is past expiry) returns `Nothing`, and
   the row count is `0` afterward (the expired row was still deleted by the take).

Register cases 1–4 in `tests`. Run:
`nix develop --command cabal test shomei-postgres-test`. Acceptance: all four pass against
the real database, proving the schema, the jsonb transports codec, the bigint counter codec,
and the `DELETE … RETURNING` consume-once semantics all work end to end.

### Embedded-count acceptance

The Step-3 ghci check (or a `just migrate` transcript applying 14 migrations) must show the
embedded migration count rose from **12** to **14**. If it still shows 12, the splice did
not recompile — re-touch `Migrations.hs` and rebuild `shomei-migrations`.


## Idempotence and Recovery

- **Migrations** are append-only and immutable. Both new files use `CREATE TABLE IF NOT
  EXISTS` and `CREATE INDEX IF NOT EXISTS`, so re-applying them is a no-op; codd additionally
  tracks applied migrations and will not re-run them. Never edit an applied migration to fix
  it — add a new, later-timestamped migration instead. If a table is wrong before any release,
  during development you may drop the ephemeral/dev database and re-migrate from scratch
  (`just migrate` recreates everything).
- **The `Migrations.hs` touch** is safe to repeat; it only forces a recompile.
- **Integration tests** run against throwaway ephemeral databases (`withShomeiMigratedDatabase`
  provisions a fresh one per test and tears it down), so they are inherently repeatable and
  leave no state behind. Re-running `cabal test shomei-postgres-test` is always safe.
- **In-memory tests** are pure and repeatable.
- **Effect-stack edits** are mechanical insertions; if a build fails with a type error about
  an unhandled effect or an extra interpreter, the cause is almost always a mismatch between
  the type-list position and the composition position — re-check that `PasskeyStore` and
  `PendingCeremonyStore` sit between `LoginAttemptStore` and `Notifier` in BOTH the list and
  (reversed) the composition, in every one of the five places.
- **Recovery checkpoint between milestones.** M1 leaves `shomei-core` fully green on its own.
  If M2 stalls, the repository still builds and tests `shomei-core`; the only partially-wired
  package is `shomei-server`/`shomei-postgres`, which Progress must note as "remaining".


## Interfaces and Dependencies

Libraries and modules used, and why:

- **`effectful` / `effectful-core`** — the effect system; the two new effects are dynamic
  (`type instance DispatchOf … = Dynamic`) interpreted with `interpret_`.
- **`hasql` (`Hasql.Encoders`, `Hasql.Decoders`, `Hasql.Statement`, `Hasql.Session`)** — the
  PostgreSQL access layer. Encoders/decoders used: `uuid`, `bytea`, `int8` (the bigint sign
  counter, over `Int64`), `jsonb` (the transports array, over aeson `Value`), `text`,
  `timestamptz`. `bytea`/`jsonb`/`int8` are all confirmed present as both an encoder and a
  decoder in the pinned hasql.
- **`contravariant-extras` (`contrazipN`)** — combine the per-column encoders into one
  product encoder for multi-param statements (as `VerificationTokenStore` uses `contrazip8`).
  The passkey insert has 10 columns; use `contrazip10` if exported, otherwise nest.
- **`aeson` (`toJSON`, `fromJSON`, `Value`, `Result (..)`)** — serialize `transports ::
  [Text]` to/from the `jsonb` column.
- **`uuid` (`Data.UUID`)** — the row tuple type for id columns; converted via the
  `…IdToUUID`/`…IdFromUUID` helpers in `Shomei.Id`.
- **`Shomei.Postgres.Database` (`Database`, `runSession`)** — the effect the interpreters
  issue SQL through; failures surface as `throwError (InternalAuthError …)` via
  `Effectful.Error.Static`.
- **`Shomei.Domain.Passkey`** (owned by **EP-1**,
  `docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md`) — the
  domain types persisted here; consumed by path, never redefined.
- **`Shomei.Id`** — `PasskeyId`/`CeremonyId` and their gen/UUID helpers (EP-1).
- **Consumers (later plans):**
  `docs/plans/17-passkey-enrollment-workflow-and-management-api.md` (EP-3) and
  `docs/plans/18-passkey-login-mfa-step-up-and-passwordless.md` (EP-4) consume these effects;
  this plan must not depend on them.

### Types and functions that must exist at the end of each milestone

**End of M1:**

```haskell
-- Shomei.Effect.PasskeyStore
data PasskeyStore :: Effect where
  CreatePasskey             :: NewPasskeyCredential -> PasskeyStore m PasskeyCredential
  FindPasskeysByUser        :: UserId -> PasskeyStore m [PasskeyCredential]
  FindPasskeyByCredentialId :: WebAuthnCredentialId -> PasskeyStore m (Maybe PasskeyCredential)
  FindPasskeysByUserHandle  :: UserHandle -> PasskeyStore m [PasskeyCredential]
  UpdatePasskeySignCounter  :: PasskeyId -> SignatureCounter -> UTCTime -> PasskeyStore m ()
  DeletePasskey             :: UserId -> PasskeyId -> PasskeyStore m ()
  CountPasskeysByUser       :: UserId -> PasskeyStore m Int
createPasskey             :: (PasskeyStore :> es) => NewPasskeyCredential -> Eff es PasskeyCredential
findPasskeysByUser        :: (PasskeyStore :> es) => UserId -> Eff es [PasskeyCredential]
findPasskeyByCredentialId :: (PasskeyStore :> es) => WebAuthnCredentialId -> Eff es (Maybe PasskeyCredential)
findPasskeysByUserHandle  :: (PasskeyStore :> es) => UserHandle -> Eff es [PasskeyCredential]
updatePasskeySignCounter  :: (PasskeyStore :> es) => PasskeyId -> SignatureCounter -> UTCTime -> Eff es ()
deletePasskey             :: (PasskeyStore :> es) => UserId -> PasskeyId -> Eff es ()
countPasskeysByUser       :: (PasskeyStore :> es) => UserId -> Eff es Int

-- Shomei.Effect.PendingCeremonyStore
data PendingCeremonyStore :: Effect where
  PutPendingCeremony      :: PendingCeremony -> PendingCeremonyStore m ()
  TakePendingCeremony     :: CeremonyId -> UTCTime -> PendingCeremonyStore m (Maybe PendingCeremony)
  DeleteExpiredCeremonies :: UTCTime -> PendingCeremonyStore m ()
putPendingCeremony      :: (PendingCeremonyStore :> es) => PendingCeremony -> Eff es ()
takePendingCeremony     :: (PendingCeremonyStore :> es) => CeremonyId -> UTCTime -> Eff es (Maybe PendingCeremony)
deleteExpiredCeremonies :: (PendingCeremonyStore :> es) => UTCTime -> Eff es ()

-- Shomei.Effect.InMemory (additions)
runPasskeyStore         :: (IOE :> es) => IORef World -> Eff (PasskeyStore : es) a -> Eff es a
runPendingCeremonyStore :: (IOE :> es) => IORef World -> Eff (PendingCeremonyStore : es) a -> Eff es a
-- World gains: passkeys :: Map PasskeyId PasskeyCredential
--              pendingCeremonies :: Map CeremonyId PendingCeremony
```

**End of M2:**

```haskell
-- Shomei.Postgres.PasskeyStore
runPasskeyStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (PasskeyStore : es) a -> Eff es a

-- Shomei.Postgres.PendingCeremonyStore
runPendingCeremonyStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (PendingCeremonyStore : es) a -> Eff es a
```

### Canonical effect-stack order (the one true order all five lists must match)

```text
UserStore, CredentialStore, SessionStore, RefreshTokenStore, VerificationTokenStore,
PasswordResetTokenStore, LoginAttemptStore,
PasskeyStore, PendingCeremonyStore,        -- THIS plan (EP-2): after LoginAttemptStore, before Notifier
Notifier, WebAuthnCeremony,                -- WebAuthnCeremony from EP-1 (do not move)
PasswordHasher, TokenSigner, TokenVerifier, AuthEventPublisher, SigningKeyStore, Clock, TokenGen,
[Database, Error AuthError in server App only,] IOE
```

> Note on existing variance: the `shomei-postgres/test/Main.hs` stack today orders the
> support effects slightly differently below `Notifier` (e.g. `AuthEventPublisher`,
> `SigningKeyStore`, `TokenSigner`, `PasswordHasher`, `TokenGen`, `Clock`). Do NOT
> "normalize" that pre-existing tail — only insert `PasskeyStore, PendingCeremonyStore`
> after `LoginAttemptStore` and before `Notifier`, matching the rule "add exactly your two
> entries in the same relative position, reorder nothing else." The two new effects sit above
> `Notifier` in every list, which is the invariant that matters for the workflows.
