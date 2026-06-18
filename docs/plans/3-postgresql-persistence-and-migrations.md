---
id: 3
slug: postgresql-persistence-and-migrations
title: "PostgreSQL persistence and migrations"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# PostgreSQL persistence and migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei ("証明", proof / authentication) is a Haskell authentication toolkit. Its
domain layer — types like `User`, `Session`, `PersistedRefreshToken`, plus a set of
effects (abstract interfaces) such as `UserStore` and `SessionStore` — is built by a
sibling plan, EP-2 (`docs/plans/2-core-domain-model-ports-and-auth-workflows.md`), in
the package `shomei-core`. An *effect* in this codebase is an `effectful` dynamic
effect: a small typed interface (a GADT of operations) with no implementation attached,
so the domain can be written once and run against different backends (an in-memory test
double, or a real database). EP-2 ships those effects and an in-memory interpreter for
tests. It does **not** persist anything to disk.

This plan, EP-3, makes Shōmei durable. After this change, a developer can run one
command and have the complete authentication schema materialize in PostgreSQL, and can
run the auth workflows (signup, login, refresh-token rotation, logout) against a real
PostgreSQL database instead of an in-memory map. Concretely, after EP-3:

- Running `just migrate` (from the repository root, inside the Nix dev shell) creates
  the six Shōmei tables inside a dedicated `shomei` PostgreSQL schema (a *schema* in
  PostgreSQL is a namespace for tables, like a folder). Connecting with `psql` and
  running `\dt shomei.*` lists `shomei_users`, `shomei_password_credentials`,
  `shomei_sessions`, `shomei_refresh_tokens`, `shomei_signing_keys`, and
  `shomei_auth_events`.
- Running `cabal test shomei-postgres` spins up a throwaway PostgreSQL server, applies
  the schema to it, and exercises every store effect against that real database: create a
  user and read it back, create a credential and find it by email, open a session and
  revoke it, mint a refresh token and rotate it, insert and list signing keys, publish
  an audit event and observe the row. The same test then drives EP-2's *workflows*
  (signup → rows appear; refresh rotation → old token marked `used` and a child token
  inserted; reuse of a used token → the whole token family and its session are revoked)
  through the PostgreSQL adapters, proving the adapters truly satisfy the effects
  end-to-end against PostgreSQL.

The user-visible outcome is therefore: Shōmei's authentication state survives process
restarts, lives in a real relational database, and is provably correct against that
database — not merely "the code compiles".

This plan delivers two new packages:

- `shomei-migrations` — owns the database schema. It carries the SQL files
  that build the schema, embeds them into the compiled binary, and applies them through
  `codd` (a Haskell schema-migration tool; see Context). It exposes a public
  `test-support` sublibrary that provisions a fresh throwaway PostgreSQL with the schema
  already applied, using `ephemeral-pg`.
- `shomei-postgres` — owns the runtime adapters. It defines a `Database`
  effect (a thin `effectful` wrapper over a `hasql` connection pool) and provides
  PostgreSQL interpreters for every EP-2 store/publisher/signing-key effect, plus the
  infrastructure effects `Clock` and `PasswordHasher` (Argon2id) and a token-generation
  helper.

EP-3 hard-depends on EP-1 (`docs/plans/1-project-scaffolding-and-multi-package-build-foundation.md`,
the Cabal workspace and Nix dev shell) and EP-2 (the domain types and effects it
persists and interprets). It runs in parallel with EP-4 (JWT/JWKS); the two share no
code. EP-3 owns Integration Point **IP-7** (the database schema and the `shomei`
namespace) and contributes the persistence entries to Integration Point **IP-8** (the
`source-repository-package` stanzas in the root `cabal.project`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — `shomei-migrations` package builds and `just migrate` applies the
      schema to a fresh ephemeral DB and to the local dev DB; `\dt shomei.*` lists all
      six tables. (2026-06-03)
  - [x] Add the `source-repository-package` / `allow-newer` entries (IP-8) to the root
        `cabal.project`. (2026-06-03)
  - [x] Create `shomei-migrations/shomei-migrations.cabal` (library, executable
        `shomei-migrate`, public `test-support` sublibrary). (2026-06-03)
  - [x] Write `shomei-migrations/src/Shomei/Migrations.hs` (embed + run via codd). (2026-06-03)
  - [x] Write `shomei-migrations/app/Main.hs` (the `shomei-migrate` executable). (2026-06-03)
  - [x] Write the six SQL migration files under
        `shomei-migrations/sql-migrations/`. (2026-06-03; 7 files incl. schema-create;
        signing-key JWK columns are `text` not `jsonb` — see Decision Log)
  - [x] Write
        `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`. (2026-06-03)
  - [x] Add `create-database`, `migrate`, and `new-migration` recipes to the root
        `Justfile`. (2026-06-03)
  - [x] Register `shomei-migrations` (and `shomei-postgres`) in `mori.dhall`. (2026-06-03)
- [x] Milestone 2 — `shomei-postgres` `Database` effect + effect interpreters + Argon2
      hasher compile. (2026-06-03; `cabal build shomei-postgres` exit 0, zero warnings)
  - [x] Create `shomei-postgres/shomei-postgres.cabal`. (2026-06-03)
  - [x] Write `shomei-postgres/src/Shomei/Postgres/Database.hs`. (2026-06-03)
  - [x] Write the connection-pool helper and the example `hasql` statements. (2026-06-03;
        `acquirePool` uses `Hasql.Connection.Settings.connectionString` per the verified
        hasql 1.10 / hasql-pool API — see Surprises)
  - [x] Write each effect interpreter under `Shomei.Postgres.*` (+ shared `Shomei.Postgres.Codec`).
        (2026-06-03; adapted to the as-built EP-2 surface — see Decision Log)
  - [x] Write `Shomei.Crypto` (Argon2id hasher + token generation + the `PasswordHasher`
        and `TokenGen` interpreters). (2026-06-03; Argon2 `hash` returns `CryptoFailable`,
        not `Either` — see Surprises)
- [x] Milestone 3 — Integration tests green: `cabal test shomei-postgres` passes,
      including the workflow-over-PostgreSQL scenario. (2026-06-03; all 9 tests pass)
  - [x] Write `test-suite shomei-postgres-test`. (2026-06-03)
  - [x] Round-trip tests for every effect. (2026-06-03; user, credential, session+revoke,
        refresh-token+mark-used, signing keys, publish-event)
  - [x] Workflow-over-PostgreSQL tests (signup / rotation / reuse-revokes-family). (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **crypton's Argon2 `hash` returns `CryptoFailable`, not `Either`.** The plan's
  `Shomei.Crypto` sketch pattern-matched `Left`/`Right`; the real signature (crypton 1.1.2,
  `Crypto/KDF/Argon2.hs`) is
  `hash :: (…) => Options -> password -> salt -> Int -> CryptoFailable out`. `deriveArgon2`
  therefore matches `CryptoPassed digest` / `CryptoFailed e` (from `Crypto.Error`).

- **hasql 1.10 `preparable` takes `Text` SQL (not `ByteString`), and the connection-string
  API moved.** `Hasql.Statement.preparable :: Text -> Encoders.Params a -> Decoders.Result b
  -> Statement a b` (the `"""…"""` literals are `Text` via `OverloadedStrings`). The pool is
  built with `Hasql.Pool.Config.settings [Hasql.Pool.Config.staticConnectionSettings
  (Hasql.Connection.Settings.connectionString connStr), Hasql.Pool.Config.size n]` —
  `Hasql.Connection.Settings.connectionString :: Text -> Settings` — not the
  `Hasql.Connection.Setting.Connection.*` path the plan guessed. (Installed: hasql 1.10.3.2,
  hasql-pool 1.4.2, hasql-transaction 1.2.2.)

- **`Shomei.Prelude` re-exports `liftIO` and `toJSON` (and the rest of the aeson class
  surface).** Importing them again from `Effectful` / `Data.Aeson` triggers
  `-Wunused-imports`; in modules that import `Shomei.Prelude`, take only the *additional*
  names (`Value` from aeson; `Eff`/`IOE`/`(:>)` from Effectful) and let the prelude supply
  `liftIO`/`toJSON`. (Same family of finding as EP-2's prelude note.)

- **`contravariant-extras` provides `contrazip` up to at least 10**, so the 9-column
  refresh-token insert uses `contrazip9` (verified in the unpacked
  `contravariant-extras-0.3.5.4` source).

- **codd/ephemeral-pg build cleanly from the IP-8 git pins.** The first `cabal build`
  fetched `shinzui/codd-project` and `shinzui/ephemeral-pg` and compiled codd 0.1.8,
  ephemeral-pg 0.2.1.0, hasql 1.10.3.2, haxl, postgresql-simple, etc. with no solver
  conflicts under `allow-newer: haxl:time`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store TypeID identifiers in native PostgreSQL `uuid` columns, not `text`.
  Rationale: EP-2's identifiers (`UserId`, `SessionId`, `RefreshTokenId`,
  `CredentialId`) are `mmzk-typeid` `KindID "<prefix>"` values that wrap a UUID plus a
  human-readable prefix (e.g. `user_01h…`). EP-2 exposes `userIdToUUID = getUUID` and
  `userIdFromUUID = decorateKindID`, so the UUID component round-trips losslessly. Native
  `uuid` is 16 bytes (vs. ~26-char text), indexes faster, and lets PostgreSQL enforce
  foreign keys between the UUID columns. The prefix is a fixed per-type constant, so
  dropping it on the way to the database and re-attaching it on the way out loses no
  information. The initial spec's "PostgreSQL Schema" section writes these columns as
  `UUID` already; we keep that and additionally change any TypeID-bearing column the spec
  left as text to `uuid`.
  Date: 2026-06-03

- Decision: Argon2id with iterations=3, memory=64 MiB (65536 KiB), parallelism=1,
  version 1.3, 16-byte salt, 32-byte output; store as the single text encoding
  `argon2id$<base64(salt)>$<base64(hash)>` in the existing `password_hash` column.
  Rationale: `crypton`'s `Crypto.KDF.Argon2.defaultOptions` is **Argon2i with
  iterations = 1** — far too weak and the wrong variant for password storage. We must
  explicitly set `variant = Argon2id` and raise the cost. A self-describing single-column
  encoding (algorithm tag + salt + hash) keeps the schema unchanged (`password_hash` stays
  `text`), is forward-compatible (we can add new tags later), and avoids a second column.
  Verification re-derives the hash from the stored salt and compares with the constant-time
  `Data.ByteArray.constEq` to avoid timing leaks.
  Date: 2026-06-03

- Decision: Apply migrations as **embedded** SQL through codd's `applyMigrationsNoCheck`
  with an explicit `Just migrations` override, rather than letting codd read a
  `sqlMigrations` directory off disk.
  Rationale: Embedding (via `file-embed`'s `embedDir`) means the `shomei-migrate`
  executable is self-contained — it ships the SQL inside the binary, so there is no
  runtime dependency on the working tree's directory layout, and the throwaway-database
  test support can run the exact same migrations in-process. The cost is the
  recompile-on-new-file gotcha (next decision).
  Date: 2026-06-03

- Decision: The `migrate` Justfile recipe `touch`es
  `shomei-migrations/shomei-migrations.cabal` before `cabal run shomei-migrate`,
  and passes dummy values for the `CODD_MIGRATION_DIRS` / `CODD_EXPECTED_SCHEMA_DIR`
  environment variables.
  Rationale: `embedDir` is a Template Haskell splice evaluated at *compile* time; a
  brand-new `.sql` file under `sql-migrations/` is **not** re-embedded unless GHC
  recompiles `Shomei.Migrations`. Touching the `.cabal` forces a rebuild so new
  migrations are picked up. Separately, codd's `getCoddSettings` reads
  `CODD_MIGRATION_DIRS` and `CODD_EXPECTED_SCHEMA_DIR` *unconditionally*, even though we
  override the migrations with an embedded list and skip schema verification; we therefore
  pass harmless placeholder strings so `getCoddSettings` does not fail.
  Date: 2026-06-03

- Decision: All Shōmei tables live in a dedicated `shomei` PostgreSQL schema, and every
  migration begins with `SET search_path TO shomei, pg_catalog;`.
  Rationale: A dedicated namespace keeps Shōmei's tables isolated from `public` and from
  any other application sharing the database, and lets `codd`'s `CODD_SCHEMAS=shomei`
  verify exactly Shōmei's namespace. Pinning `search_path` in each migration makes
  unqualified table names resolve into `shomei` regardless of the connection's default
  search path. (Note: unlike kizashi, which co-locates a read model in kiroku's schema,
  Shōmei owns its schema entirely.)
  Date: 2026-06-03

- Decision: The `PasswordHasher` and token-generation interpreters live in
  `shomei-postgres` (module `Shomei.Crypto`), not in `shomei-core`.
  Rationale: They need `crypton` (Argon2, SHA-256, secure random bytes), an
  infrastructure dependency we deliberately keep out of the transport-agnostic core.
  `shomei-postgres` already depends on `crypton` for nothing else yet, so this is the
  natural home. `TokenSigner` / `TokenVerifier` are EP-4's responsibility and are not
  touched here.
  Date: 2026-06-03

- Decision: Register both `shomei-migrations` and `shomei-postgres` in `mori.dhall`.
  Rationale: `mori.dhall` currently lists six packages but not `shomei-migrations`
  (the seventh package, introduced by this plan) and lists `shomei-postgres` without
  the migrations dependency. The MasterPlan (IP-8 / open question) explicitly notes
  `mori.dhall` must be updated to register the seventh package during EP-3, so dependency
  tooling (`mori`) can see it.
  Date: 2026-06-03

- Decision: The `shomei_signing_keys` table stores JWK columns (`public_key_jwk`,
  `private_key_jwk` as `jsonb`), not the spec's `public_key_pem` /
  `private_key_pem_encrypted` text columns.
  Rationale: EP-2's `StoredSigningKey` record carries `publicKeyJwk` and `privateKeyJwk`
  (JSON Web Key documents), which EP-4 consumes to build a JWKS endpoint. Persisting the
  JWK form matches the domain type exactly and avoids a lossy PEM↔JWK conversion. This is
  a deliberate, documented divergence from the initial spec's schema sketch.
  Date: 2026-06-03

- Decision (revised during implementation): the `public_key_jwk` / `private_key_jwk`
  columns are **`text`**, not `jsonb`.
  Rationale: The plan's `jsonb` choice assumed EP-2's `StoredSigningKey` JWK fields were
  `Data.Aeson.Value`. The **actual** EP-2 surface (see the reconciliation decision below)
  makes them **opaque `Text`** (MasterPlan IP-4: the core/postgres packages never import
  `jose`; key material crosses the `SigningKeyStore` effect as opaque `Text`). Storing opaque
  `Text` in a `text` column is lossless and avoids forcing the material to be re-parseable
  JSON; only EP-4's `shomei-jwt` interprets it as a JWK. Event payloads remain `jsonb`.
  Date: 2026-06-03

- Decision (reconciliation with the as-built EP-2): EP-3's "What EP-2 provides" section was
  written before EP-2 landed and its assumed surface differs from the implemented one. The
  interpreters here are adapted to **the real EP-2 API** (in `shomei-core`). The
  differences and how EP-3 adapts:
  - Identifier prefixes are `KindID "refresh_token"` and `KindID "credential"` (not
    `"refresh"`/`"cred"`); the `*IdToUUID`/`*IdFromUUID` helpers are unchanged in spirit.
  - `RefreshTokenStatus` has **four** constructors (`…Active/Used/Revoked/Expired`), so the
    text⇄status helper handles `expired` too.
  - `StoredSigningKey.publicKeyJwk/privateKeyJwk :: Text` (opaque), not `Value` → `text`
    columns and `E.text`/`D.text` (see the column decision above).
  - `CreatePasswordCredential :: UserId -> Email -> PasswordHash -> …` (no `CredentialId`
    arg) → the interpreter allocates the `CredentialId` and timestamps, like `CreateUser`.
  - `UpdatePasswordHash :: UserId -> PasswordHash -> …` (keyed by `UserId`, not
    `CredentialId`).
  - `NewSession {userId, createdAt, expiresAt}` and `NewRefreshToken {…, createdAt,
    expiresAt}` carry `createdAt` from the workflow's `Clock`; the interpreters use it
    rather than `now()`.
  - The revocation/used/mark/update ops carry an explicit `UTCTime`
    (`RevokeSession :: SessionId -> UTCTime -> …`, `MarkRefreshTokenUsed`,
    `RevokeRefreshTokenFamily`, `RevokeSessionRefreshTokens`, `RevokeAllUserSessions`,
    `UpdateSigningKeyStatus`), so the SQL sets `revoked_at`/`used_at`/timestamps from that
    parameter rather than `now()`.
  - `PasswordHasher` ops take `PlainPassword` (a newtype over `Text`), not raw `Text`; the
    interpreter unwraps it.
  - EP-2 **does** expose a `TokenGen` effect (`GenerateOpaqueToken`, `HashRefreshToken`); EP-3
    therefore adds a real `runTokenGenCrypto` interpreter in `Shomei.Crypto` (crypton random
    + SHA-256), beyond the bare `generateOpaqueToken`/`hashRefreshToken` IO helpers.
  - `AuthEvent`'s per-constructor `*Data` records carry typed fields (not a uniform
    `event_type`+`payload`), so `Shomei.Postgres.AuthEventPublisher` projects each
    constructor to `(user_id?, session_id?, event_type, toJSON payload, occurredAt)`.
  - `TokenSigner`/`TokenVerifier` are EP-4's; the M3 workflow-over-PostgreSQL tests use a
    trivial in-test `TokenSigner` fake to exercise `signup`/`refresh`.
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Achieved (2026-06-03).** Shōmei is now durable. `shomei-migrations` owns the
schema: `just migrate` applies the seven codd migrations (the `shomei` schema + six tables)
to the dev DB, and `\dt shomei.*` lists them; the public `test-support` sublibrary
provisions fresh ephemeral PostgreSQL databases with the schema applied.
`shomei-postgres` provides the `Database` effect over a hasql pool, PostgreSQL
interpreters for every EP-2 store/publisher/signing-key effect plus `Clock`, and
`Shomei.Crypto` (Argon2id hashing + `PasswordHasher`/`TokenGen` interpreters).
`cabal test shomei-postgres` is green — all nine cases: the six effect round-trips and the
three workflow-over-PostgreSQL scenarios (signup persists user+session+token; refresh
rotation marks the old token `used` and inserts a child with `parent_token_id` set; reuse
of a used token revokes the whole token family **and** its session). `cabal build all` and
`nix fmt` are clean.

**Faithfulness / deviations.** EP-3 owns IP-7 (the schema) and contributed IP-8 (the codd /
ephemeral-pg `source-repository-package` pins). Two deliberate deviations from the plan as
written, both forced by reality and recorded in the Decision Log / Surprises: (1) the
interpreters target the **as-built EP-2 surface** (UTCTime-carrying revoke ops, PlainPassword,
four-constructor `RefreshTokenStatus`, opaque-`Text` JWK fields, interpreter-allocated ids,
typed event `*Data` records), and EP-2 turned out to expose a `TokenGen` effect so EP-3 adds a
real `runTokenGenCrypto`; (2) the `public_key_jwk`/`private_key_jwk` columns are `text` (opaque
material per IP-4), not `jsonb`. Library-API corrections vs the plan's sketches: Argon2 `hash`
returns `CryptoFailable`, hasql 1.10 `preparable` takes `Text`, and the pool is built via
`Hasql.Connection.Settings.connectionString`.

**For the next contributor.** EP-6 (the server) runs these same migrations at startup and
assembles these interpreters behind the real Servant API. The reuse-detection family
revocation is a recursive CTE in `Shomei.Postgres.RefreshTokenStore` that mirrors EP-2's
in-memory `rootOf` walk. `TokenSigner`/`TokenVerifier` remain EP-4's responsibility; the
integration tests stub `TokenSigner`. `mori.dhall` now registers `shomei-migrations` and the
`shomei-postgres → shomei-migrations` dependency (the file also already carried the EP-4
`hs-jose`/`ram` registry entries, committed here alongside).


## Context and Orientation

This section assumes no prior knowledge of the repository or its tools.

### Where things are

The repository root is the Shōmei project. Today it contains Nix flake files
(`flake.nix`, `nix/haskell.nix`, …), a `process-compose.yaml` that runs a local
PostgreSQL plus a `create_schema` process, a `db/` directory holding a local PostgreSQL
data cluster, `mori.dhall` (project + package registry metadata), and `docs/`. The
authentication packages live (or will live) under `/`. EP-1 creates
`shomei-core` and friends plus the root `cabal.project` and `Justfile`; EP-2
fills `shomei-core`. This plan adds `shomei-migrations` and
`shomei-postgres`.

The detailed product specification, including the intended SQL schema, is in
`docs/initial-spec.md` (the "PostgreSQL Schema" section starts around line 739). The
coordinating MasterPlan is
`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`.

A near-identical persistence stack already exists in a sibling repository at
`/Users/shinzui/Keikaku/bokuno/kizashi/kizashi-migrations/`. We mirror its structure
(the `.cabal` layout, the `Migrations.hs` embedding code, and the
`TestSupport.hs` ephemeral-database helper), renaming kizashi/kiroku to shomei. That
repo is a reference only; do not import from it.

### The toolchain (define every term)

- **GHC 9.12.4** is the Haskell compiler version pinned by the workspace.
  **GHC2024** is the language edition (a bundle of default language extensions). All
  Shōmei packages set `default-language: GHC2024` and `cabal-version: 3.0`.

- **`cabal`** is the Haskell build tool. A **package** is a unit of build with a
  `<name>.cabal` file. A `.cabal` file contains **stanzas**: `library`, `executable`,
  `test-suite`, and named sub-`library` stanzas. A **sublibrary** is an extra library
  inside one package (here, `test-support`); marking it `visibility: public` lets *other*
  packages depend on it as `shomei-migrations:test-support`. The root
  `cabal.project` lists every package and any external source dependencies.

- **`source-repository-package`** is a `cabal.project` stanza that pulls a dependency
  directly from a git repository (pinned by commit hash) instead of from Hackage (the
  central package index). We need this for two not-yet-on-Hackage forks: `ephemeral-pg`
  and `codd`.

- **`codd`** is a Haskell library + CLI for applying SQL **migrations**. A *migration*
  is a `.sql` file that evolves the database schema (e.g. "create this table"). codd
  applies pending migrations in a deterministic order (by the timestamp encoded in each
  filename), records which it has applied so each runs exactly once, and can optionally
  verify the resulting schema against a checked-in snapshot. We use its
  `applyMigrationsNoCheck` entry point (apply without snapshot verification) with an
  in-process list of embedded migrations.

- **`file-embed`** provides the Template Haskell splice `embedDir`, which reads a
  directory at *compile time* and bakes its files into the binary as
  `[(FilePath, ByteString)]`. **Template Haskell (TH)** is GHC's compile-time
  metaprogramming: a `$(...)` *splice* runs Haskell during compilation. The crucial
  consequence: a new `.sql` file is only seen after the module that splices `embedDir` is
  recompiled.

- **`ephemeral-pg`** is a library that starts a throwaway PostgreSQL server for tests.
  Its `EphemeralPg.withCached` caches only the expensive one-time `initdb` cluster setup
  and hands each call a *fresh* server + database, so tests are isolated. It returns
  `Either StartError a`; we unwrap with `error` on `Left`. `EphemeralPg.connectionString
  db :: Text` gives the libpq connection string to that database.

- **`hasql`** is a fast PostgreSQL client library. Its three core types:
  - A **`Statement a b`** is a single parameterized SQL command: SQL text + an
    *encoder* (how to turn the Haskell input `a` into bind parameters) + a *decoder* (how
    to turn result rows into the Haskell output `b`). In hasql 1.10 the `Statement`
    constructor is hidden; build one with
    `Hasql.Statement.preparable sqlText encoder decoder`.
  - A **`Session a`** is a sequence of statements run on one connection, producing `a`.
    `Hasql.Session.statement params stmt` runs one statement inside a session.
  - A **`Transaction a`** is like a session but wrapped in a database transaction
    (BEGIN/COMMIT, with automatic retry on serialization failures via
    `hasql-transaction`). `Hasql.Transaction.statement params stmt` runs one statement
    inside a transaction.
  - **`Hasql.Pool.Pool`** is a connection pool. `Hasql.Pool.use pool session` runs a
    `Session` (or, via `Hasql.Transaction.Sessions.transaction`, a `Transaction`)
    against a pooled connection, returning `Either Hasql.Pool.UsageError a` (a `Left`
    means a connection or query error).
  - **Encoders** come from `Hasql.Encoders` (commonly imported `qualified as E`):
    `E.param (E.nonNullable E.uuid)`, `E.text`, `E.timestamptz`, `E.jsonb` (for an aeson
    `Value`), `E.int4`/`E.int8`, `E.noParams`. Multiple parameters are combined with
    `Contravariant.Extras.contrazipN` (`contrazip2`, `contrazip3`, …).
  - **Decoders** come from `Hasql.Decoders` (`qualified as D`):
    `D.column (D.nonNullable D.uuid)`, `D.column (D.nullable D.timestamptz)`, and
    row-shaping combinators `D.singleRow`, `D.rowMaybe`, `D.rowList`, `D.rowVector`,
    `D.noResult`.

- **`effectful`** is an effect-system library. An **effect** is a typed capability
  (e.g. "can talk to the database"). A *dynamic* effect is declared as a GADT
  `data Foo :: Effect where …`, with `type instance DispatchOf Foo = Dynamic`. You
  *send* an operation with `Effectful.Dispatch.Dynamic.send`, and *interpret* it (give it
  a concrete meaning) with `interpret` / `interpret_`. `Eff es a` is a computation
  requiring the effects in the type-level list `es`; `(Foo :> es)` means `Foo` is
  available in `es`. `IOE :> es` means `IO` is available (via `liftIO`). An
  **interpreter** is a function `run… :: … => Eff (Foo : es) a -> Eff es a` that handles
  every `Foo` operation and removes `Foo` from the required effects.

### What EP-2 provides (consumed by this plan)

EP-2 (`shomei-core`) is not yet implemented at the time this plan is authored,
but its surface is fixed by the MasterPlan and reproduced here so this plan is
self-contained. EP-3 must compile against exactly these names. (If EP-2's final names
differ, update this section and the interpreters accordingly and record it in the
Decision Log.)

Identifiers, in `Shomei.Id`. Each is an `mmzk-typeid` `KindID "<prefix>"`:

```haskell
type UserId          = KindID "user"
type SessionId       = KindID "session"
type RefreshTokenId  = KindID "refresh"
type CredentialId    = KindID "cred"

userIdToUUID   :: UserId -> Data.UUID.UUID    -- = getUUID
userIdFromUUID :: Data.UUID.UUID -> UserId     -- = decorateKindID
-- and the analogous sessionIdToUUID / refreshTokenIdToUUID / credentialIdToUUID pairs.
```

Domain types, in `Shomei.Domain` (or sub-modules; import via `Shomei.Prelude`/the
package's re-exports). Field accessors shown are the record fields:

```haskell
data UserStatus = UserActive | UserSuspended | UserDeleted
data User = User
  { userId      :: UserId
  , email       :: Email
  , displayName :: Maybe Text
  , status      :: UserStatus
  , createdAt   :: UTCTime
  , updatedAt   :: UTCTime
  }

newtype Email        = Email Text
newtype PasswordHash = PasswordHash Text

data Credential = PasswordCredential
  { credentialId :: CredentialId
  , userId       :: UserId
  , email        :: Email
  , passwordHash :: PasswordHash
  , createdAt    :: UTCTime
  , updatedAt    :: UTCTime
  }

data SessionStatus = SessionActive | SessionRevoked | SessionExpired
data Session = Session
  { sessionId :: SessionId
  , userId    :: UserId
  , status    :: SessionStatus
  , createdAt :: UTCTime
  , expiresAt :: UTCTime
  , revokedAt :: Maybe UTCTime
  }

newtype RefreshTokenHash = RefreshTokenHash Text
data RefreshTokenStatus  = RefreshTokenActive | RefreshTokenUsed | RefreshTokenRevoked
data PersistedRefreshToken = PersistedRefreshToken
  { refreshTokenId :: RefreshTokenId
  , sessionId      :: SessionId
  , tokenHash      :: RefreshTokenHash
  , parentTokenId  :: Maybe RefreshTokenId
  , status         :: RefreshTokenStatus
  , createdAt      :: UTCTime
  , expiresAt      :: UTCTime
  , usedAt         :: Maybe UTCTime
  , revokedAt      :: Maybe UTCTime
  }

data SigningKeyStatus = KeyPending | KeyActive | KeyRetired | KeyRevoked
data StoredSigningKey = StoredSigningKey
  { keyId         :: Text                 -- the "kid"
  , algorithm     :: Text
  , publicKeyJwk  :: Data.Aeson.Value
  , privateKeyJwk :: Data.Aeson.Value
  , status        :: SigningKeyStatus
  , createdAt     :: UTCTime
  , activatedAt   :: Maybe UTCTime
  , retiredAt     :: Maybe UTCTime
  }

-- Input records (no server-assigned fields):
data NewUser         = NewUser { email :: Email, displayName :: Maybe Text }
data NewSession      = NewSession { userId :: UserId, expiresAt :: UTCTime }
data NewRefreshToken = NewRefreshToken
  { sessionId :: SessionId, tokenHash :: RefreshTokenHash
  , parentTokenId :: Maybe RefreshTokenId, expiresAt :: UTCTime }

-- The audit event sum plus its per-constructor *Data records (carry user/session ids,
-- a textual event type, an aeson payload, and a timestamp):
data AuthEvent = …            -- e.g. UserSignedUp UserSignedUpData | LoggedIn LoggedInData | …

data AuthError = …            -- includes an InternalAuthError carrying Text
data TokenError = …
data ShomeiConfig = …
```

The effects EP-3 must interpret (each is an `effectful` dynamic effect in
`Shomei.Effect.*`). The operation set per effect:

```haskell
-- Shomei.Effect.UserStore
data UserStore :: Effect where
  CreateUser       :: NewUser -> UserStore m User
  FindUserById     :: UserId  -> UserStore m (Maybe User)
  FindUserByEmail  :: Email   -> UserStore m (Maybe User)
  UpdateUserStatus :: UserId -> UserStatus -> UserStore m ()

-- Shomei.Effect.CredentialStore
data CredentialStore :: Effect where
  CreatePasswordCredential       :: CredentialId -> UserId -> Email -> PasswordHash -> CredentialStore m Credential
  FindPasswordCredentialByEmail  :: Email -> CredentialStore m (Maybe Credential)
  UpdatePasswordHash             :: CredentialId -> PasswordHash -> CredentialStore m ()

-- Shomei.Effect.SessionStore
data SessionStore :: Effect where
  CreateSession         :: NewSession -> SessionStore m Session
  FindSessionById       :: SessionId -> SessionStore m (Maybe Session)
  RevokeSession         :: SessionId -> SessionStore m ()
  RevokeAllUserSessions :: UserId -> SessionStore m ()

-- Shomei.Effect.RefreshTokenStore
data RefreshTokenStore :: Effect where
  CreateRefreshToken          :: NewRefreshToken -> RefreshTokenStore m PersistedRefreshToken
  FindRefreshTokenByHash      :: RefreshTokenHash -> RefreshTokenStore m (Maybe PersistedRefreshToken)
  MarkRefreshTokenUsed        :: RefreshTokenId -> RefreshTokenStore m ()
  RevokeRefreshTokenFamily    :: RefreshTokenId -> RefreshTokenStore m ()
  RevokeSessionRefreshTokens  :: SessionId -> RefreshTokenStore m ()

-- Shomei.Effect.AuthEventPublisher
data AuthEventPublisher :: Effect where
  PublishAuthEvent :: AuthEvent -> AuthEventPublisher m ()

-- Shomei.Effect.SigningKeyStore
data SigningKeyStore :: Effect where
  ListActiveSigningKeys :: SigningKeyStore m [StoredSigningKey]
  FindSigningKeyByKid   :: Text -> SigningKeyStore m (Maybe StoredSigningKey)
  InsertSigningKey      :: StoredSigningKey -> SigningKeyStore m ()
  UpdateSigningKeyStatus:: Text -> SigningKeyStatus -> SigningKeyStore m ()

-- Shomei.Effect.Clock
data Clock :: Effect where
  Now :: Clock m UTCTime

-- Shomei.Effect.PasswordHasher
data PasswordHasher :: Effect where
  HashPassword   :: Text -> PasswordHasher m PasswordHash
  VerifyPassword :: Text -> PasswordHash -> PasswordHasher m Bool
```

Each effect also exports `send`-wrapper functions (`createUser`, `findUserById`, …); the
interpreters do not need them, only the GADT constructors.

### House conventions (apply to every Shōmei module)

- `cabal-version: 3.0`, `default-language: GHC2024`, GHC 9.12.4.
- Two shared `common` stanzas defined in each `.cabal`: a `warnings` stanza (the
  workspace's warning flags) and a `shared` stanza whose `default-extensions` are exactly:
  `DeriveAnyClass DuplicateRecordFields BlockArguments MultilineStrings OverloadedLabels
  OverloadedRecordDot OverloadedStrings PackageImports QualifiedDo TemplateHaskell`. Every
  library/executable/test stanza writes `import: warnings, shared`.
- **Postpositive qualified imports**: `import Foo.Bar qualified as FB` (the `qualified`
  comes after the module name; enabled by `ImportQualifiedPost`, part of GHC2024).
- **`PackageImports`**: imports may name their package, e.g.
  `import "hasql" Hasql.Encoders qualified as E`.
- Strict record fields (prefix field types with `!`) and explicit `deriving stanzas`
  (`deriving stanza (Show, Eq)` / `deriving anyclass (…)`).
- Import `Shomei.Prelude` in every module (EP-2's custom prelude; re-exports `Text`,
  `UTCTime`, `Maybe`, etc.).
- `#field` record-dot/label access requires `import Data.Generics.Labels ()` in that
  module (an orphan-instance import, hence the empty import list).
- Use `MultilineStrings` for SQL literals: triple-quoted `"""…"""` string literals.


## Plan of Work

The work is three milestones, each independently verifiable.

### Milestone 1 — schema package and `just migrate`

Scope: stand up `shomei-migrations` and make `just migrate` build the schema in
PostgreSQL. At the end of this milestone the schema exists; `\dt shomei.*` lists six
tables in both a throwaway test DB and the local dev DB.

First, contribute the IP-8 entries to the root `cabal.project`. EP-1 leaves a placeholder
comment where these go (a line containing `EP-3` / "persistence" near the top-level
stanzas). Replace that placeholder with the two `source-repository-package` stanzas
(`ephemeral-pg`, `codd`), the `package codd { tests: False; benchmarks: False }` block,
and the `allow-newer: haxl:time` line. Also add
`shomei-migrations/shomei-migrations.cabal` and
`shomei-postgres/shomei-postgres.cabal` to the `packages:` field. (If the
placeholder comment is absent because EP-1 has not landed yet, add the stanzas anyway and
note it in Surprises & Discoveries.)

Second, create `shomei-migrations/shomei-migrations.cabal` with four stanzas: a
`library` exposing `Shomei.Migrations`; an `executable shomei-migrate` over `app/Main.hs`;
and a public sublibrary `library test-support` exposing `Shomei.Migrations.TestSupport`.
The package must set `extra-source-files: sql-migrations/*.sql` so the SQL files ship in
the source distribution and are visible to `embedDir`.

Third, write `shomei-migrations/src/Shomei/Migrations.hs`: embed the
`sql-migrations` directory, parse each file into a codd `AddedSqlMigration`, and expose
`runShomeiMigrationsNoCheck` which applies them through codd.

Fourth, write `shomei-migrations/app/Main.hs`: read codd settings from the
environment and call `runShomeiMigrationsNoCheck`.

Fifth, write the six SQL migrations under
`shomei-migrations/sql-migrations/`. Each file's first line must be
`-- codd: in-txn` (codd directive: run this migration inside a transaction), then
`SET search_path TO shomei, pg_catalog;`, then idempotent DDL (`CREATE … IF NOT EXISTS`).
Use the spec's "PostgreSQL Schema" SQL, but (a) put everything in the `shomei` schema,
(b) keep the TypeID-bearing id columns as native `uuid`, (c) keep status columns `text`,
payload `jsonb`, timestamps `timestamptz`, and (d) for `shomei_signing_keys` use the JWK
`jsonb` columns matching EP-2's `StoredSigningKey` (see Decision Log). One migration
creates the schema; the rest create the tables (and indexes / foreign keys) listed in
Concrete Steps.

Sixth, write
`shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`, mirroring
kizashi's `withKizashiMigratedDatabase`: build a `CoddSettings` directly from an ephemeral
connection string (parsed with `Codd.Parsing.connStringParser`), with
`namespacesToCheck = IncludeSchemas [SqlSchema "shomei", SqlSchema "public"]`, and call
`runShomeiMigrationsNoCheck`.

Seventh, add the `create-database`, `migrate`, and `new-migration` recipes to the root
`Justfile` (EP-1's), as specified in Concrete Steps.

Eighth, register `shomei-migrations` and `shomei-postgres` in `mori.dhall`.

Acceptance: from the dev shell, `just migrate` exits 0 and `psql -c '\dt shomei.*'`
lists the six tables; `cabal build shomei-migrations:test-support` succeeds.

### Milestone 2 — the `Database` effect, effect interpreters, and Argon2 hasher

Scope: stand up `shomei-postgres`. At the end, the `Database` effect, all effect
interpreters, and the Argon2id hasher compile.

Create `shomei-postgres/shomei-postgres.cabal`. Write
`src/Shomei/Postgres/Database.hs` (the `Database` effect + `runDatabasePool`), a small
pool-construction helper, the example `hasql` statements, the effect interpreters (one
module per effect group, all under `Shomei.Postgres.*`), and `Shomei.Crypto` (Argon2id +
token generation + SHA-256 token hashing). Each store/publisher/signing-key interpreter
translates each operation into a `hasql` `Session`/`Transaction` run via `runSession`/
`runTransaction`, mapping a `Left UsageError` to a failure (we throw an `Error AuthError`
effect carrying `InternalAuthError`). The `Clock` interpreter answers `Now` with
`liftIO getCurrentTime`. The `PasswordHasher` interpreter uses `Shomei.Crypto`.

Acceptance: `cabal build shomei-postgres` succeeds.

### Milestone 3 — integration tests, including workflows over PostgreSQL

Scope: prove the adapters satisfy the effects against real PostgreSQL. Write
`test-suite shomei-postgres-test` (tasty + tasty-hunit, `-threaded`) depending on
`shomei-migrations:test-support`. For each test, provision a fresh ephemeral DB via
`withShomeiMigratedDatabase`, acquire a `hasql` pool against its connection string, run
the interpreters, and assert behavior. Then drive EP-2's workflows through the PostgreSQL
interpreters and assert the database state.

Acceptance: `cabal test shomei-postgres` is green and the transcript shows the workflow
scenarios passing.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`, inside
the Nix dev shell (entered by `nix develop` or automatically via `direnv` from `.envrc`).
The dev shell exports `PGHOST=$PWD/db`, `PGDATA=$PGHOST/db`, and `PGDATABASE=shomei`, and
PostgreSQL listens on a Unix socket in `$PGHOST` (no TCP). `process-compose.yaml` already
runs `just create-database` once PostgreSQL is healthy (its `create_schema` process).

### Step 1 — IP-8 entries in `cabal.project`

Add (replacing EP-1's placeholder comment) the following to the root `cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/shinzui/ephemeral-pg.git
  tag: 304c160f25570ea5e225baf5024778c93f434b56
source-repository-package
  type: git
  location: https://github.com/shinzui/codd-project.git
  tag: d176b3088f23ef2218c7a1f31835e8ee0c0601aa
  subdir: codd
package codd
  tests: False
  benchmarks: False
allow-newer:
  haxl:time
```

Ensure the `packages:` field includes the two new packages:

```cabal
packages:
  shomei-core
  shomei-migrations
  shomei-postgres
  -- (plus the other EP-1 packages)
```

### Step 2 — `shomei-migrations/shomei-migrations.cabal`

```cabal
cabal-version:      3.0
name:               shomei-migrations
version:            0.1.0.0
synopsis:           Schema migrations for Shōmei (codd-managed, embedded SQL)
description:
  Owns Shōmei's PostgreSQL schema. Embeds Shōmei's timestamped SQL migrations
  with file-embed and applies them through codd. Exposes a public test-support
  sublibrary that provisions a fresh ephemeral PostgreSQL with the schema applied.
license:            BSD-3-Clause
author:             Nadeem Bitar
maintainer:         nadeem@gmail.com
copyright:          2026 Nadeem Bitar
category:           Database, Security
build-type:         Simple
extra-source-files: sql-migrations/*.sql

common warnings
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates
               -Wincomplete-uni-patterns -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DeriveAnyClass
    DuplicateRecordFields
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
  exposed-modules: Shomei.Migrations
  build-depends:
    , base        >=4.18   && <5
    , bytestring
    , codd        >=0.1.8  && <0.2
    , file-embed  >=0.0.15 && <0.0.17
    , streaming
    , text
    , time

executable shomei-migrate
  import:         warnings, shared
  main-is:        Main.hs
  hs-source-dirs: app
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , base
    , codd
    , shomei-migrations
    , time

library test-support
  import:          warnings, shared
  visibility:      public
  hs-source-dirs:  test-support
  exposed-modules: Shomei.Migrations.TestSupport
  build-depends:
    , aeson         >=2.1   && <2.3
    , attoparsec
    , base          >=4.18  && <5
    , codd          >=0.1.8 && <0.2
    , containers
    , ephemeral-pg  >=0.2   && <0.3
    , shomei-migrations
    , text
    , time
```

### Step 3 — `shomei-migrations/src/Shomei/Migrations.hs`

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Shomei.Migrations
  ( shomeiMigrations
  , runShomeiMigrationsNoCheck
  ) where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Streaming.Prelude qualified as Streaming

-- | All Shōmei migrations, parsed from the embedded SQL files (ordered by codd by
-- the timestamp encoded in each filename).
shomeiMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shomeiMigrations = traverse parseOne embeddedFiles
  where
    parseOne (name, bytes) = do
      let stream = PureStream (Streaming.yield (TE.decodeUtf8 bytes))
      parseAddedSqlMigration name stream
        >>= either (\e -> fail ("Invalid migration " <> name <> ": " <> e)) pure

-- NB: 'embedDir' is a TH splice evaluated at compile time. A NEW .sql file under
-- sql-migrations/ is not re-embedded until this module is recompiled. The 'migrate'
-- Justfile recipe touches the .cabal first to force a rebuild.
embeddedFiles :: [(FilePath, ByteString)]
embeddedFiles = $(embedDir "sql-migrations")

-- | Apply all migrations through codd WITHOUT expected-schema verification.
runShomeiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runShomeiMigrationsNoCheck settings t = runCoddLogger $ do
  migs <- shomeiMigrations
  applyMigrationsNoCheck settings (Just migs) t (const (pure SchemasNotVerified))
```

### Step 4 — `shomei-migrations/app/Main.hs`

```haskell
module Main where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Shomei.Migrations (runShomeiMigrationsNoCheck)

main :: IO ()
main = do
  s <- getCoddSettings
  _ <- runShomeiMigrationsNoCheck s (secondsToDiffTime 5)
  pure ()
```

### Step 5 — the six SQL migrations

Create these under `shomei-migrations/sql-migrations/`. Filenames encode the
ordering timestamp; keep the listed order (schema first, then users, credentials,
sessions, refresh tokens, signing keys, auth events — combined into six files as below;
the schema-create is folded into the users file's predecessor). Note: identifier columns
that hold TypeID UUIDs are `uuid`; status columns are `text`; payloads are `jsonb`;
timestamps are `timestamptz`.

`2026-06-03-00-00-00-shomei-schema.sql`:

```sql
-- codd: in-txn

-- Create the dedicated Shōmei namespace. Idempotent.
CREATE SCHEMA IF NOT EXISTS shomei;
```

`2026-06-03-00-00-01-shomei-users.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_users (
  user_id      uuid PRIMARY KEY,
  email        text NOT NULL UNIQUE,
  display_name text NULL,
  status       text NOT NULL,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL
);
```

`2026-06-03-00-00-02-shomei-password-credentials.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_password_credentials (
  credential_id uuid PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES shomei_users(user_id),
  email         text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL
);
```

`2026-06-03-00-00-03-shomei-sessions.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_sessions (
  session_id uuid PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES shomei_users(user_id),
  status     text NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_sessions_user_id_idx ON shomei_sessions (user_id);
CREATE INDEX IF NOT EXISTS shomei_sessions_status_idx  ON shomei_sessions (status);
```

`2026-06-03-00-00-04-shomei-refresh-tokens.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_refresh_tokens (
  refresh_token_id uuid PRIMARY KEY,
  session_id       uuid NOT NULL REFERENCES shomei_sessions(session_id),
  token_hash       text NOT NULL UNIQUE,
  parent_token_id  uuid NULL REFERENCES shomei_refresh_tokens(refresh_token_id),
  status           text NOT NULL,
  created_at       timestamptz NOT NULL,
  expires_at       timestamptz NOT NULL,
  used_at          timestamptz NULL,
  revoked_at       timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_session_id_idx
  ON shomei_refresh_tokens (session_id);
CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_parent_token_id_idx
  ON shomei_refresh_tokens (parent_token_id);
CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_status_idx
  ON shomei_refresh_tokens (status);
```

`2026-06-03-00-00-05-shomei-signing-keys.sql` (JWK columns; see Decision Log):

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_signing_keys (
  key_id          text PRIMARY KEY,
  algorithm       text NOT NULL,
  public_key_jwk  jsonb NOT NULL,
  private_key_jwk jsonb NOT NULL,
  status          text NOT NULL,
  created_at      timestamptz NOT NULL,
  activated_at    timestamptz NULL,
  retired_at      timestamptz NULL
);
```

`2026-06-03-00-00-06-shomei-auth-events.sql`:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_auth_events (
  event_id   uuid PRIMARY KEY,
  user_id    uuid NULL,
  session_id uuid NULL,
  event_type text NOT NULL,
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_auth_events_user_id_idx    ON shomei_auth_events (user_id);
CREATE INDEX IF NOT EXISTS shomei_auth_events_session_id_idx ON shomei_auth_events (session_id);
CREATE INDEX IF NOT EXISTS shomei_auth_events_event_type_idx ON shomei_auth_events (event_type);
CREATE INDEX IF NOT EXISTS shomei_auth_events_created_at_idx ON shomei_auth_events (created_at);
```

(That is seven files: one schema-create plus six table files. "Six tables" refers to the
tables themselves. If you prefer literally six files, fold the `CREATE SCHEMA` into the
top of the users file — but keeping it separate makes the namespace creation explicit and
re-runnable.)

### Step 6 — `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`

```haskell
{- | Provision a fresh, isolated ephemeral PostgreSQL with the complete Shōmei schema
applied in-process through codd via 'runShomeiMigrationsNoCheck'. Each call gets a
brand-new database (ephemeral-pg caches only the initdb cluster), so tests stay isolated. -}
module Shomei.Migrations.TestSupport
  ( withShomeiMigratedDatabase
  ) where

import Codd (CoddSettings (..))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Shomei.Migrations (runShomeiMigrationsNoCheck)

-- | Run @action@ against a fresh ephemeral PostgreSQL connection string whose database
-- already has the full Shōmei schema applied.
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
withShomeiMigratedDatabase action = do
  result <- Pg.withCached $ \db -> do
    let connStr = Pg.connectionString db
    _ <- runShomeiMigrationsNoCheck (testCoddSettings connStr) (secondsToDiffTime 5)
    action connStr
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right value -> pure value

-- | codd settings built directly from an ephemeral connection string (NOT from env). We
-- apply without schema verification, so onDiskReps / namespacesToCheck use harmless
-- placeholders.
testCoddSettings :: Text -> CoddSettings
testCoddSettings connStr =
  CoddSettings
    { migsConnString = parseConnString connStr
    , sqlMigrations = []
    , onDiskReps = Right (DbRep Null Map.empty Map.empty)
    , namespacesToCheck = IncludeSchemas [SqlSchema "shomei", SqlSchema "public"]
    , extraRolesToCheck = []
    , retryPolicy = singleTryPolicy
    , txnIsolationLvl = DbDefault
    , schemaAlgoOpts = SchemaAlgo False False False
    }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
  case parseOnly (connStringParser <* endOfInput) connStr of
    Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
    Right parsed -> parsed
```

### Step 7 — Justfile recipes (root `Justfile`, extend EP-1's)

`create-database` is idempotent (checks `pg_database` first); `migrate` touches the
`.cabal` to force the `embedDir` re-embed, then runs `shomei-migrate` with the required
`CODD_*` environment variables; `new-migration` scaffolds a timestamped file.

```text
# Create the dev database if it does not exist, then migrate it.
create-database:
    @if [ -z "$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'")" ]; then \
        createdb "$PGDATABASE"; \
        echo "Created database $PGDATABASE"; \
    else \
        echo "Database $PGDATABASE already exists"; \
    fi
    just migrate

# Apply all embedded migrations to $PGDATABASE via the shomei-migrate executable.
# Touch the .cabal first so a newly added .sql file is re-embedded (embedDir is a TH splice).
migrate:
    touch shomei-migrations/shomei-migrations.cabal
    CODD_CONNECTION="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
    CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
    CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
    CODD_SCHEMAS=shomei \
    cabal run shomei-migrate

# Scaffold a new migration: just new-migration name=add-something
new-migration name:
    @echo "{{name}}" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "Invalid slug: {{name}}"; exit 1; }
    @ts=$(date -u '+%Y-%m-%d-%H-%M-%S'); \
    f="shomei-migrations/sql-migrations/$ts-{{name}}.sql"; \
    if [ -e "$f" ]; then echo "Refusing to overwrite $f"; exit 1; fi; \
    printf -- '-- codd: in-txn\n\nSET search_path TO shomei, pg_catalog;\n\n' > "$f"; \
    echo "Wrote $f"
```

### Step 8 — register packages in `mori.dhall`

Add a `Schema.Package::{…}` entry for `shomei-migrations` (path
`shomei-migrations`, type `Library`, depending on nothing in-tree), and add
`Schema.Dependency.ByName "shomei-migrations"` to the `shomei-postgres` package's
`dependencies` (`shomei-postgres` depends on the migrations sublibrary for its tests).

### Step 9 — `shomei-postgres/shomei-postgres.cabal`

```cabal
cabal-version:      3.0
name:               shomei-postgres
version:            0.1.0.0
synopsis:           PostgreSQL adapters for Shōmei's store/publisher/signing-key effects
license:            BSD-3-Clause
author:             Nadeem Bitar
maintainer:         nadeem@gmail.com
copyright:          2026 Nadeem Bitar
category:           Database, Security
build-type:         Simple

common warnings
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates
               -Wincomplete-uni-patterns -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DataKinds
    DeriveAnyClass
    DuplicateRecordFields
    GADTs
    LambdaCase
    MultilineStrings
    OverloadedLabels
    OverloadedRecordDot
    OverloadedStrings
    PackageImports
    QualifiedDo
    TemplateHaskell
    TypeFamilies

library
  import:          warnings, shared
  hs-source-dirs:  src
  exposed-modules:
    Shomei.Crypto
    Shomei.Postgres.Database
    Shomei.Postgres.Pool
    Shomei.Postgres.UserStore
    Shomei.Postgres.CredentialStore
    Shomei.Postgres.SessionStore
    Shomei.Postgres.RefreshTokenStore
    Shomei.Postgres.AuthEventPublisher
    Shomei.Postgres.SigningKeyStore
    Shomei.Postgres.Clock
    Shomei.Postgres.PasswordHasher
  build-depends:
    , aeson
    , base                  >=4.18  && <5
    , base64-bytestring
    , bytestring
    , contravariant-extras
    , crypton               >=1.1.0
    , effectful
    , effectful-core
    , hasql                 >=1.10
    , hasql-pool            >=1.2
    , hasql-transaction     >=1.0
    , ram
    , shomei-core
    , text
    , time
    , uuid

test-suite shomei-postgres-test
  import:         warnings, shared
  type:           exitcode-stdio-1.0
  main-is:        Main.hs
  hs-source-dirs: test
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , aeson
    , base
    , effectful
    , effectful-core
    , hasql
    , hasql-pool
    , shomei-core
    , shomei-migrations:test-support
    , shomei-postgres
    , tasty
    , tasty-hunit
    , text
    , time
    , uuid
```

### Step 10 — `shomei-postgres/src/Shomei/Postgres/Database.hs`

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}

module Shomei.Postgres.Database
  ( Database (..)
  , runSession
  , runTransaction
  , runDatabasePool
  ) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful (liftIO)
import Effectful.Dispatch.Dynamic (interpret_, send)
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session (Session)
import Hasql.Transaction (Transaction)
import Hasql.Transaction.Sessions qualified as Tx

-- | The Database effect: run a hasql Session or Transaction against a pool.
data Database :: Effect where
  RunSession     :: Session a     -> Database m (Either Pool.UsageError a)
  RunTransaction :: Transaction a -> Database m (Either Pool.UsageError a)

type instance DispatchOf Database = Dynamic

runSession :: (Database :> es) => Session a -> Eff es (Either Pool.UsageError a)
runSession = send . RunSession

runTransaction :: (Database :> es) => Transaction a -> Eff es (Either Pool.UsageError a)
runTransaction = send . RunTransaction

-- | Interpret Database against a concrete hasql Pool.
runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a -> Eff es a
runDatabasePool pool = interpret_ $ \case
  RunSession sess  -> liftIO (Pool.use pool sess)
  RunTransaction t -> liftIO (Pool.use pool (Tx.transaction Tx.ReadCommitted Tx.Write t))
```

### Step 11 — `shomei-postgres/src/Shomei/Postgres/Pool.hs`

```haskell
module Shomei.Postgres.Pool (acquirePool) where

import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Hasql.Connection.Setting qualified as Setting
import Hasql.Connection.Setting.Connection qualified as Connection
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Config

-- | Acquire a hasql connection pool of @size@ connections against a libpq conn string.
-- (hasql 1.10 builds settings via Hasql.Pool.Config; the exact module path for the
-- single static connection setting may be Hasql.Connection.Setting — confirm against the
-- installed hasql/hasql-pool version and adjust imports if the build complains.)
acquirePool :: Int -> Text -> IO Pool
acquirePool size connStr =
  Pool.acquire
    ( Config.settings
        [ Config.staticConnectionSettings
            (Connection.connection (Connection.string (TE.encodeUtf8 connStr)))
        , Config.size size
        ]
    )
```

Note for the implementer: hasql-pool's exact connection-settings constructor changed
across 1.x point releases. The brief specifies
`Hasql.Pool.Config.staticConnectionSettings (Hasql.Connection.Settings.connectionString
connStr)`. Use whichever the installed version exposes; `mori registry docs hasql` and the
package's source on disk are authoritative. Record the final form in Surprises &
Discoveries.

### Step 12 — example `hasql` statements (≥3), in the interpreter modules

These live next to the interpreters that use them. They show UUID, timestamptz, text,
jsonb, and nullable columns. Map TypeID ids to `uuid` with `userIdToUUID` / `userIdFromUUID`.

Insert a user (in `Shomei.Postgres.UserStore`):

```haskell
import "contravariant-extras" Contravariant.Extras (contrazip6)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Statement (Statement, preparable)
import Data.UUID (UUID)

-- Encodes (user_id, email, display_name?, status, created_at, updated_at).
insertUserStmt :: Statement (UUID, Text, Maybe Text, Text, UTCTime, UTCTime) ()
insertUserStmt =
  preparable
    """
    INSERT INTO shomei.shomei_users
      (user_id, email, display_name, status, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    """
    ( contrazip6
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult
```

Find a user by email (returns all columns, possibly none):

```haskell
findUserByEmailStmt :: Statement Text (Maybe (UUID, Text, Maybe Text, Text, UTCTime, UTCTime))
findUserByEmailStmt =
  preparable
    """
    SELECT user_id, email, display_name, status, created_at, updated_at
    FROM shomei.shomei_users
    WHERE email = $1
    """
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe $
        (,,,,,)
          <$> D.column (D.nonNullable D.uuid)
          <*> D.column (D.nonNullable D.text)
          <*> D.column (D.nullable D.text)
          <*> D.column (D.nonNullable D.text)
          <*> D.column (D.nonNullable D.timestamptz)
          <*> D.column (D.nonNullable D.timestamptz)
    )
```

Find a refresh token by its hash (note the nullable `parent_token_id`, `used_at`,
`revoked_at` columns):

```haskell
findRefreshTokenByHashStmt
  :: Statement Text (Maybe (UUID, UUID, Text, Maybe UUID, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UTCTime))
findRefreshTokenByHashStmt =
  preparable
    """
    SELECT refresh_token_id, session_id, token_hash, parent_token_id, status,
           created_at, expires_at, used_at, revoked_at
    FROM shomei.shomei_refresh_tokens
    WHERE token_hash = $1
    """
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe $
        (,,,,,,,,)
          <$> D.column (D.nonNullable D.uuid)
          <*> D.column (D.nonNullable D.uuid)
          <*> D.column (D.nonNullable D.text)
          <*> D.column (D.nullable D.uuid)
          <*> D.column (D.nonNullable D.text)
          <*> D.column (D.nonNullable D.timestamptz)
          <*> D.column (D.nonNullable D.timestamptz)
          <*> D.column (D.nullable D.timestamptz)
          <*> D.column (D.nullable D.timestamptz)
    )
```

### Step 13 — effect interpreters (full for two; the rest follow the same shape)

Every interpreter follows one shape: `interpret_` over the effect GADT; each operation
builds a `Session`/`Transaction` of one or more statements, runs it via `runSession`/
`runTransaction`, and translates a `Left UsageError` into a thrown
`InternalAuthError` via an `Error AuthError` effect. Status enums and `KindID`s are
converted to/from their stored text/uuid forms with small total helper functions
(`userStatusToText` / `userStatusFromText`, etc.) defined in each module.

`UserStore` (full):

```haskell
{-# LANGUAGE LambdaCase #-}

module Shomei.Postgres.UserStore (runUserStorePostgres) where

import Shomei.Prelude
import "generic-lens" Data.Generics.Labels ()
import Data.UUID (UUID)
import "hasql" Hasql.Session qualified as Session
import "effectful-core" Effectful (Eff, IOE, (:>))
import "effectful" Effectful.Dispatch.Dynamic (interpret_)
import "effectful" Effectful.Error.Static (Error, throwError)
import Shomei.Id (userIdToUUID, userIdFromUUID)
import Shomei.Domain (User (..), UserStatus (..), Email (..), NewUser (..), AuthError (..))
import Shomei.Effect.UserStore (UserStore (..))
import Shomei.Postgres.Database (Database, runSession)
-- plus the Statement definitions from Step 12 and status/uuid helpers.

runUserStorePostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es)
  => Eff (UserStore : es) a -> Eff es a
runUserStorePostgres = interpret_ \case
  CreateUser newUser -> do
    -- caller-side helpers create a fresh UserId + timestamps before insert; here we
    -- assume the workflow passes them in via NewUser+id allocation. Build the row,
    -- INSERT it, then return the constructed User.
    user <- buildNewUser newUser   -- allocate UserId/UTCTime (see note below)
    res  <- runSession (Session.statement (userRow user) insertUserStmt)
    either dbFail (const (pure user)) res
  FindUserById uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) findUserByIdStmt)
    either dbFail (pure . fmap rebuildUser) res
  FindUserByEmail (Email e) -> do
    res <- runSession (Session.statement e findUserByEmailStmt)
    either dbFail (pure . fmap rebuildUser) res
  UpdateUserStatus uid st -> do
    res <- runSession (Session.statement (userIdToUUID uid, userStatusToText st) updateUserStatusStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))

rebuildUser :: (UUID, Text, Maybe Text, Text, UTCTime, UTCTime) -> User
rebuildUser (uid, e, dn, st, c, u) =
  User
    { userId      = userIdFromUUID uid
    , email       = Email e
    , displayName = dn
    , status      = userStatusFromText st
    , createdAt   = c
    , updatedAt   = u
    }
```

Note: whether `CreateUser` allocates the `UserId` and timestamps inside the interpreter
or whether EP-2's workflow supplies them via the `Clock` effect and an id generator is an
EP-2 contract detail. The brief's `NewUser` has only `email`/`displayName`, so the
interpreter must allocate. Allocate the UUID with `uuid`'s random generator and the
timestamps via the same `getCurrentTime` the `Clock` interpreter uses. Resolve this
against EP-2's actual `CreateUser` shape when EP-2 lands, and record it in the Decision
Log. (`tshow` here is `Data.Text.pack . show`; provide it locally if `Shomei.Prelude`
does not.)

`AuthEventPublisher` (full):

```haskell
{-# LANGUAGE LambdaCase #-}

module Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres) where

import Shomei.Prelude
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import "aeson" Data.Aeson (Value)
import "hasql" Hasql.Session qualified as Session
import "effectful-core" Effectful (Eff, IOE, (:>), liftIO)
import "effectful" Effectful.Dispatch.Dynamic (interpret_)
import "effectful" Effectful.Error.Static (Error, throwError)
import Shomei.Domain (AuthEvent, AuthError (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Postgres.Database (Database, runSession)
-- plus insertAuthEventStmt and the AuthEvent -> (user_id?, session_id?, type, payload, ts) projection.

runAuthEventPublisherPostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es)
  => Eff (AuthEventPublisher : es) a -> Eff es a
runAuthEventPublisherPostgres = interpret_ \case
  PublishAuthEvent ev -> do
    eid <- liftIO UUIDv4.nextRandom
    let (mUser, mSession, etype, payload, ts) = projectAuthEvent ev
    res <- runSession (Session.statement (eid, mUser, mSession, etype, payload, ts) insertAuthEventStmt)
    either (\e -> throwError (InternalAuthError ("database error: " <> tshow e))) (const (pure ())) res

-- where projectAuthEvent extracts the per-constructor fields and toJSON's the payload.
```

The remaining interpreters — `runCredentialStorePostgres`, `runSessionStorePostgres`,
`runRefreshTokenStorePostgres`, `runSigningKeyStorePostgres` — follow the identical shape
(`interpret_` over the GADT; one statement or a small multi-statement `Transaction` per
operation; `Left UsageError → throwError InternalAuthError`). Notes on the non-trivial
ones:

- `RevokeRefreshTokenFamily tokenId`: walk the parent/child chain (a recursive CTE over
  `shomei_refresh_tokens` following `parent_token_id`) and set `status = 'revoked'`,
  `revoked_at = now()` for every token reachable from the family root, all in one
  `Transaction`.
- `MarkRefreshTokenUsed tokenId`: `UPDATE … SET status='used', used_at=now() WHERE
  refresh_token_id = $1`.
- `RevokeSession` / `RevokeAllUserSessions`: `UPDATE shomei_sessions SET status='revoked',
  revoked_at=now() WHERE …`.
- `SigningKeyStore`: `public_key_jwk` / `private_key_jwk` use `E.jsonb` / `D.jsonb` over
  aeson `Value`; `ListActiveSigningKeys` uses `D.rowList`.

`Clock` (full):

```haskell
{-# LANGUAGE LambdaCase #-}

module Shomei.Postgres.Clock (runClockIO) where

import Data.Time (getCurrentTime)
import "effectful-core" Effectful (Eff, IOE, (:>), liftIO)
import "effectful" Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Effect.Clock (Clock (..))

runClockIO :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runClockIO = interpret_ \case
  Now -> liftIO getCurrentTime
```

### Step 14 — `Shomei.Crypto` (Argon2id hasher + token generation)

```haskell
{-# LANGUAGE LambdaCase #-}

module Shomei.Crypto
  ( hashPasswordArgon2id
  , verifyPasswordArgon2id
  , runPasswordHasherCrypto
  , generateOpaqueToken
  , hashRefreshToken
  ) where

import Shomei.Prelude
import "crypton" Crypto.KDF.Argon2 qualified as Argon2
import "crypton" Crypto.Hash (SHA256 (..), hashWith)
import "crypton" Crypto.Random (getRandomBytes)
import "ram" Data.ByteArray (constEq, convert)
import "ram" Data.ByteArray.Encoding (Base (Base64, Base64URLUnpadded), convertToBase, convertFromBase)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Shomei.Domain (PasswordHash (..))
import "effectful-core" Effectful (Eff, IOE, (:>), liftIO)
import "effectful" Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Effect.PasswordHasher (PasswordHasher (..))

-- CRITICAL: crypton's defaultOptions = Argon2i, iterations=1 (too weak). Set Argon2id
-- and raise the cost explicitly.
argonOptions :: Argon2.Options
argonOptions = Argon2.Options
  { Argon2.iterations  = 3
  , Argon2.memory      = 64 * 1024     -- KiB == 64 MiB
  , Argon2.parallelism = 1
  , Argon2.variant     = Argon2.Argon2id
  , Argon2.version     = Argon2.Version13
  }

saltLen, hashLen :: Int
saltLen = 16
hashLen = 32

-- | Returns "argon2id$<b64 salt>$<b64 hash>".
hashPasswordArgon2id :: Text -> IO PasswordHash
hashPasswordArgon2id pw = do
  salt <- getRandomBytes saltLen :: IO ByteString
  let digest = deriveArgon2 (TE.encodeUtf8 pw) salt
      b64 b  = TE.decodeUtf8 (convertToBase Base64 b)
  pure (PasswordHash ("argon2id$" <> b64 salt <> "$" <> b64 digest))

verifyPasswordArgon2id :: Text -> PasswordHash -> Bool
verifyPasswordArgon2id pw (PasswordHash stored) =
  case splitOn3 stored of
    Just ("argon2id", saltB64, hashB64)
      | Right salt <- b64dec saltB64, Right want <- b64dec hashB64 ->
          constEq (deriveArgon2 (TE.encodeUtf8 pw) salt) want
    _ -> False
  where b64dec t = convertFromBase Base64 (TE.encodeUtf8 t) :: Either String ByteString

deriveArgon2 :: ByteString -> ByteString -> ByteString
deriveArgon2 pw salt =
  case Argon2.hash argonOptions pw salt hashLen of
    Left e  -> error ("Argon2 hashing failed: " <> show e)  -- only on invalid params
    Right d -> d

runPasswordHasherCrypto :: (IOE :> es) => Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasherCrypto = interpret_ \case
  HashPassword pw        -> liftIO (hashPasswordArgon2id pw)
  VerifyPassword pw hash -> pure (verifyPasswordArgon2id pw hash)

-- | A fresh opaque refresh token: base64url of 32 random bytes (the secret handed to
-- the client; only its hash is stored — see 'hashRefreshToken').
generateOpaqueToken :: IO Text
generateOpaqueToken = do
  raw <- getRandomBytes 32 :: IO ByteString
  pure (TE.decodeUtf8 (convertToBase Base64URLUnpadded raw))

-- | SHA-256 of the opaque token, base64url-encoded: what we persist in token_hash.
hashRefreshToken :: Text -> Text
hashRefreshToken tok =
  TE.decodeUtf8 (convertToBase Base64URLUnpadded (convert (hashWith SHA256 (TE.encodeUtf8 tok)) :: ByteString))

-- splitOn3 splits "a$b$c" into ("a","b","c"); definition omitted for brevity.
```

The token generator and `hashRefreshToken` live here (not in core) because they need
`crypton`. EP-2's workflows call them through whichever effect EP-2 exposes for token
generation; if EP-2 has no such effect, the workflow can call these directly in the
assembly layer (EP-6). Record the integration point in the Decision Log when EP-2 lands.

### Step 15 — the test suite (`shomei-postgres/test/Main.hs`)

```haskell
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import "shomei-migrations" Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.Database (runDatabasePool)
-- import the interpreters and EP-2 effects/workflows
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=), assertBool)

main :: IO ()
main = defaultMain $ testGroup "shomei-postgres"
  [ testCase "create + find user round-trips" $
      withShomeiMigratedDatabase \connStr -> do
        pool <- acquirePool 4 connStr
        -- run runDatabasePool / runUserStorePostgres / runClockIO / runError over the pool;
        -- create a user, find it by id and by email, assert equality.
        pure ()
  -- … the remaining round-trip tests + workflow scenarios (see Validation).
  ]
```

### Step 16 — build, migrate, and test (the real commands)

```bash
# From the repo root, inside the dev shell.
cabal build all
just create-database          # idempotent: creates $PGDATABASE if absent, then migrates
psql -d shomei -c '\dt shomei.*'
cabal test shomei-postgres
```


## Validation and Acceptance

### Milestone 1 — schema exists

After `just migrate`, `psql -d shomei -c '\dt shomei.*'` must list exactly the six
tables. Expected (column widths vary):

```text
                 List of relations
 Schema |            Name             | Type  |  Owner
--------+-----------------------------+-------+---------
 shomei | shomei_auth_events          | table | <user>
 shomei | shomei_password_credentials | table | <user>
 shomei | shomei_refresh_tokens       | table | <user>
 shomei | shomei_sessions             | table | <user>
 shomei | shomei_signing_keys         | table | <user>
 shomei | shomei_users                | table | <user>
(6 rows)
```

Running `just migrate` a second time must be a no-op (codd records applied migrations;
the `IF NOT EXISTS` DDL is itself idempotent), exiting 0 with no new tables. The
ephemeral path is validated implicitly by Milestone 3 (every test provisions a fresh DB
through `withShomeiMigratedDatabase`, which applies the same migrations).

### Milestone 2 — adapters compile

`cabal build shomei-postgres` exits 0. There is no runtime behavior to observe yet;
correctness is proven by Milestone 3.

### Milestone 3 — behavior over real PostgreSQL

`cabal test shomei-postgres` runs the suite against throwaway databases and must pass.
The round-trip group asserts: a created user is found by id and by email with equal
fields; a created credential is found by email; a created session can be revoked
(`FindSessionById` then shows `SessionRevoked`); a refresh token is found by its hash,
then `MarkRefreshTokenUsed` flips its status to `RefreshTokenUsed`; inserted signing keys
appear in `ListActiveSigningKeys` and by `FindSigningKeyByKid`; `PublishAuthEvent` lands a
row in `shomei_auth_events` (assert with a direct `SELECT count(*)`).

The workflow group drives EP-2's workflows through the PostgreSQL interpreters and
asserts database state:

- **Signup** inserts one row each into `shomei_users`, `shomei_sessions`, and
  `shomei_refresh_tokens` (assert by `SELECT count(*)` per table == 1, and that the
  user/session/token reference each other by id).
- **Refresh rotation**: presenting the active refresh token marks the old token `used`
  (`used_at` set, `status = 'used'`) and inserts a *child* token whose `parent_token_id`
  equals the old token's id and whose `status = 'active'`.
- **Reuse detection**: presenting the *already-used* token a second time revokes the
  whole token family (every token sharing the family root is `status = 'revoked'`) and
  the owning session (`shomei_sessions.status = 'revoked'`).

Expected tasty transcript shape:

```text
shomei-postgres
  create + find user round-trips:                 OK
  create credential + find-by-email:              OK
  create session + revoke:                        OK
  create refresh token + find-by-hash + mark-used:OK
  insert + list signing keys:                     OK
  publish auth event lands a row:                 OK
  workflow: signup persists user+session+token:   OK
  workflow: refresh rotation marks used + child:  OK
  workflow: reuse revokes family + session:       OK

All 9 tests passed (3.2s)
```

The exact timings differ; what matters is `All N tests passed` with zero failures. A
failing run prints the failing assertion (e.g. `expected: RefreshTokenUsed / but got:
RefreshTokenActive`), which tells you which adapter is wrong.


## Idempotence and Recovery

Every migration uses `CREATE … IF NOT EXISTS`, so re-running them is safe; codd
additionally records which migrations it has applied and skips them, so `just migrate`
is safe to run repeatedly. `just create-database` checks `pg_database` before calling
`createdb`, so it never errors on an existing database. Each integration test provisions a
brand-new ephemeral database, so tests never collide with each other or with the dev DB
and need no cleanup.

If a migration is added but `just migrate` does not seem to see it, the cause is almost
always the `embedDir` TH-splice gotcha: the `migrate` recipe `touch`es the `.cabal` to
force a recompile, but if you ran `cabal run shomei-migrate` by hand without touching, do
`touch shomei-migrations/shomei-migrations.cabal` and re-run. If
`getCoddSettings` fails, confirm the `CODD_MIGRATION_DIRS` / `CODD_EXPECTED_SCHEMA_DIR`
placeholders and `CODD_CONNECTION` are exported (they are read unconditionally even though
we override migrations and skip verification).

To start over locally: stop PostgreSQL, `dropdb shomei`, then `just create-database`. The
local cluster lives in `db/`; deleting `db/db` and re-running `initdb` (via the dev shell
/ process-compose) rebuilds it from scratch. None of these steps touch source files.


## Interfaces and Dependencies

Libraries and why: `codd` (apply embedded SQL migrations deterministically), `file-embed`
(bake SQL into the binary at compile time), `streaming` (codd's parser consumes a
`PureStream`), `ephemeral-pg` (throwaway PostgreSQL per test), `attoparsec` (parse the
ephemeral connection string for codd via `connStringParser`), `hasql` + `hasql-pool` +
`hasql-transaction` (PostgreSQL access), `contravariant-extras` (combine multi-param
encoders), `crypton` (>=1.1.0) + `ram` + `base64-bytestring` (Argon2id, SHA-256, secure random,
constant-time compare, base64 encodings — `ram` is the maintained drop-in replacement for the
deprecated `memory` package, keeping the `Data.ByteArray` module and `constEq`/`convert`), `aeson` (jsonb payloads and JWK columns),
`uuid` (TypeID UUID component + random event ids), `time` (timestamps), `effectful` +
`effectful-core` (the effect system the effects and `Database` effect use),
`tasty` + `tasty-hunit` (tests). `shomei-core` provides every domain type and effect.

Signatures that must exist at the end of each milestone.

Milestone 1 (`shomei-migrations`):

```haskell
-- Shomei.Migrations
shomeiMigrations            :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
runShomeiMigrationsNoCheck  :: CoddSettings -> DiffTime -> IO ApplyResult

-- Shomei.Migrations.TestSupport (in the public test-support sublibrary)
withShomeiMigratedDatabase  :: (Text -> IO a) -> IO a
```

Milestone 2 (`shomei-postgres`):

```haskell
-- Shomei.Postgres.Database
data Database :: Effect
runSession      :: (Database :> es) => Session a     -> Eff es (Either Pool.UsageError a)
runTransaction  :: (Database :> es) => Transaction a -> Eff es (Either Pool.UsageError a)
runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a -> Eff es a

-- Shomei.Postgres.Pool
acquirePool :: Int -> Text -> IO Pool

-- One interpreter per effect; all share this shape:
runUserStorePostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (UserStore : es) a -> Eff es a
runCredentialStorePostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (CredentialStore : es) a -> Eff es a
runSessionStorePostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (SessionStore : es) a -> Eff es a
runRefreshTokenStorePostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (RefreshTokenStore : es) a -> Eff es a
runAuthEventPublisherPostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (AuthEventPublisher : es) a -> Eff es a
runSigningKeyStorePostgres
  :: (Database :> es, IOE :> es, Error AuthError :> es) => Eff (SigningKeyStore : es) a -> Eff es a
runClockIO
  :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runPasswordHasherCrypto
  :: (IOE :> es) => Eff (PasswordHasher : es) a -> Eff es a

-- Shomei.Crypto
hashPasswordArgon2id   :: Text -> IO PasswordHash
verifyPasswordArgon2id :: Text -> PasswordHash -> Bool
generateOpaqueToken    :: IO Text
hashRefreshToken       :: Text -> Text
```

Integration points owned/contributed here.

**IP-7 (owned by EP-3) — Database schema and the `shomei` namespace.** The six tables in
the `shomei` schema, created by the migrations in
`shomei-migrations/sql-migrations/`. Consumers: EP-3's own hasql statements;
EP-6 (the standalone server) runs the same migrations at deploy time and the same
adapters at runtime. The stable surface is the table/column names and the `shomei` schema
name; changing them is a schema migration.

**IP-8 (contributed by EP-3) — `cabal.project` source dependencies.** EP-3 adds the
`source-repository-package` stanzas for `ephemeral-pg` and `codd` (pinned commits), the
`package codd { tests: False; benchmarks: False }` block, and `allow-newer: haxl:time`,
plus the two new package paths under `packages:`. EP-1 owns the rest of `cabal.project`
(compiler pin, shared `common` stanzas); EP-3 only fills the persistence entries.

Cross-plan dependency on EP-2: this plan compiles against the EP-2 names reproduced in
Context and Orientation. If EP-2's final API differs (e.g. `CreateUser` carries the id and
timestamps rather than allocating them in the adapter), update the affected interpreters
and the Context section, and record the change in the Decision Log per the Revision
Protocol.
