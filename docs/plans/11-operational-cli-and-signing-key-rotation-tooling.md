---
id: 11
slug: operational-cli-and-signing-key-rotation-tooling
title: "Operational CLI and signing-key rotation tooling"
kind: exec-plan
created_at: 2026-06-04T02:42:05Z
intention: "intention_01kt8847mre3wa36x0s0k9j6pm"
master_plan: "docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md"
---

# Operational CLI and signing-key rotation tooling

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-4** of MasterPlan 2
(`docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`). It delivers a
command-line tool, `shomei-admin`, that an operator runs to manage a deployed Shōmei
installation: apply database migrations, manage the lifecycle of the ES256 signing keys used
to mint and verify JSON Web Tokens, and create a bootstrap user account without going through
the HTTP API. It also nails down the **signing-key rotation lifecycle** — the precise sequence
of key statuses that lets Shōmei rotate keys with zero downtime, so that tokens signed by an
old key keep verifying for a grace period while new tokens are signed by a new key.


## Purpose / Big Picture

Shōmei ("証明", proof / authentication) is a Haskell authentication toolkit. Today, an
operator who has deployed it can run the server, but everything *around* the server — applying
the database schema, generating and rotating the cryptographic keys that sign access tokens,
and seeding the very first user account — has no first-class tooling. The database migrations
have a runner (`shomei-migrate`, built by MasterPlan 1's EP-3) but signing keys can only be
created or rotated by writing raw SQL against the `shomei_signing_keys` table, which is
error-prone and unsafe: get the status transitions wrong and you either break every existing
token or leave a compromised key trusted.

After this plan, an operator has one binary, **`shomei-admin`**, with clear subcommands:

```text
shomei-admin migrate                       # apply pending database migrations
shomei-admin keys generate                 # mint a new ES256 key in `pending` status
shomei-admin keys activate <kid>           # promote a pending key to `active` (old one auto-retires)
shomei-admin keys retire <kid>             # demote an active key to `retired` (still trusted)
shomei-admin keys revoke <kid>             # mark a key `revoked` (immediately untrusted)
shomei-admin keys list                     # show every key with kid / status / timestamps
shomei-admin users create --email … --password …  [--display-name …]
```

The user-visible outcome you can observe: from an empty database, an operator runs
`shomei-admin migrate`, then `shomei-admin keys generate`, copies the printed `kid`, runs
`shomei-admin keys activate <kid>`, then `shomei-admin users create --email … --password …`,
and finally `shomei-admin keys list` to see one `active` key and one user's worth of state in
PostgreSQL — all without touching SQL and without the HTTP server running. This is the exact
runbook a fresh deployment follows, and Milestone 4 ships it as a copy-pasteable transcript.

The security-critical heart of this plan is the **signing-key rotation lifecycle**. A *signing
key* is an elliptic-curve key pair: the private half signs access tokens, the public half (the
one Shōmei publishes in its JWKS document) verifies them. A *JWKS* ("JSON Web Key Set") is the
public document — served by the running server at `GET /.well-known/jwks.json` — that
downstream services download to verify Shōmei's tokens locally without calling back. A *kid*
("key ID") is a short string naming one key so a token's header can say "I was signed by key
kid" and a verifier can pick the matching public key. Each key has a **status**, one of
`pending`, `active`, `retired`, or `revoked`, and the whole point of this plan is to make the
transitions between those statuses coherent and demonstrable:

- A freshly generated key is `pending`: it exists in the database and its private material is
  stored, but it is *not* used to sign and is *not* published in the JWKS. This lets an
  operator stage a key ahead of a planned rotation.
- Activating a `pending` key makes it `active`: it becomes the single key new tokens are signed
  with, and it appears in the JWKS. At the same moment, the key that *was* active is demoted to
  `retired`.
- A `retired` key is no longer used to sign new tokens, but it **stays in the JWKS** and stays
  trusted. This is what makes rotation zero-downtime: a token minted seconds before the
  rotation, signed by the now-retired key, still verifies until it naturally expires.
- A `revoked` key is removed from the JWKS and is no longer trusted at all. Revocation is the
  emergency lever for a compromised key; it takes effect immediately, deliberately breaking any
  token still signed by that key.

So the observable rotation story this plan demonstrates end-to-end is: **generate → activate
(old key auto-retires; the JWKS now lists both the new active key and the old retired key) →
tokens signed by the new active key verify, AND tokens signed by the now-retired old key STILL
verify → revoke the old key (it disappears from the JWKS and its tokens stop verifying).**
Milestone 2 proves this with an integration test against a real PostgreSQL database that
inspects the JWKS contents at each step and checks that overlapping-key verification holds.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `executable shomei-admin` + `test-suite shomei-admin-test` stanzas added to
      `shomei-server.cabal` (optparse-applicative + the Shōmei packages); `optparse-applicative`
      block appended to `cabal.project` (IP-8); builds on GHC 9.12.4. Completed 2026-06-10.
- [x] M1: `shomei-server/app/Admin.hs` — `optparse-applicative` parser with `migrate`, `keys`
      (sub-parser), and `users` command groups; `--help` renders all subcommands. Completed
      2026-06-10.
- [x] M1: `Shomei.Admin.Env` env loader (`DATABASE_URL`, `SHOMEI_ISSUER`, `SHOMEI_AUDIENCE`;
      builds `ShomeiConfig` + acquires a pool). Completed 2026-06-10.
- [x] M1: `migrate` reuses `runShomeiMigrationsNoCheck` (codd settings from `DATABASE_URL` via
      `coddSettingsFromConnString`, not `getCoddSettings` — see Decision Log); `keys list` reads
      the table. Integration test asserts an empty list + the table exists. Completed 2026-06-10.
- [x] M2: `keys generate` mints a `pending` ES256 key via `generateSigningKey` +
      `toStoredSigningKey`; prints the `kid`. Completed 2026-06-10.
- [x] M2: `keys activate <kid>` promotes `pending`→`active` (stamping `activated_at`) and
      auto-retires the prior `active`→`retired` (stamping `retired_at`); `keys retire`/`revoke`
      implement the remaining transitions with status guards. Completed 2026-06-10.
- [x] M2: integration test proving the lifecycle and JWKS overlap — after a second
      generate+activate, `listPublishableSigningKeys` lists BOTH the new active and the
      auto-retired old key, a token signed by the RETIRED key STILL verifies against that JWKS,
      and after `revoke` that token no longer verifies. `shomei-admin-test` green. Completed
      2026-06-10.
- [x] M3: `users create --email --password [--display-name]` drives `Shomei.Workflow.signup`
      through the PostgreSQL stack; prints the new user's id and email; test asserts the
      `shomei_users` + `shomei_password_credentials` rows exist. Completed 2026-06-10.
- [x] M4: `Shomei.Admin.Env.loadAdminEnv` is the single config entry point (EP-5 supersedes its
      body); operator runbook captured live (below); whole-CLI smoke covered by the integration
      tests. `nix fmt` clean; `cabal build all` + `cabal test all` (9 suites) green. Completed
      2026-06-10.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-10: **All key operations use binary-local `hasql` statements, not the
  `SigningKeyStore` effect.** The effect's `UpdateSigningKeyStatus` interpreter ignores its
  timestamp argument and `ListActiveSigningKeys` only returns `active` keys, so the CLI needs
  its own SQL anyway (`listPublishableSigningKeys` for `active`+`retired`, and updates that
  stamp `activated_at`/`retired_at`). Doing every key op in one consistent `hasql` style keeps
  the CLI free of effect-stack assembly. Evidence: `keys activate` correctly auto-retires the
  prior active key and `keys list` shows the stamped timestamps.
- 2026-06-10: **`migrate` derives codd settings from `DATABASE_URL`, not `getCoddSettings`.**
  `shomei-migrations/app/Main.hs` reads `CODD_*` env vars via `getCoddSettings`, but the admin
  CLI already requires `DATABASE_URL`, so it builds codd settings with
  `coddSettingsFromConnString env.connStr` (the same helper `shomei-server`'s boot uses) — one
  env var instead of several. Recorded in the Decision Log.
- 2026-06-10: **No new `cabal.project` override was needed for `optparse-applicative`.** It
  resolves on the pinned GHC 9.12.4 set straight from Hackage; the appended block is just the
  documented home for any future override. `contravariant-extras`, `jose`, and `hasql` had to be
  added to the new stanzas' `build-depends` (the executable for the key SQL, the test for JWKS
  signing/verification).


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship `shomei-admin` as a **second `executable` stanza inside the existing
  `shomei-server` package** (a new `executable shomei-admin` over a new
  `shomei-server/app/Admin.hs`), not as a dedicated `shomei-cli` package.
  Rationale: This is the MasterPlan-2 default (its Decision Log, 2026-06-04, and IP-8). A new
  package would have to be registered in `mori.dhall` (as MasterPlan 1's EP-3 did for
  `shomei-migrations`), adding ceremony for no benefit. `shomei-server` already depends on
  `shomei-core`, `shomei-jwt`, `shomei-postgres`, and `shomei-servant`, so the admin binary can
  reuse the very same pool/config/key assembly the server will use, keeping a single source of
  truth for how Shōmei wires its interpreters. The alternative — a dedicated `shomei-cli`
  package — is reconsidered only if the assembly coupling proves awkward (e.g. the admin binary
  needs no servant/wai dependency and the build cost of pulling them in becomes annoying); if we
  switch, register `shomei-cli` in `mori.dhall` and record it here. Until then, the executable
  lives in `shomei-server`.
  Date: 2026-06-04

- Decision: Use **`optparse-applicative`** for the CLI's argument parsing, with one top-level
  sub-command parser (`migrate`, `keys`, `users`) and nested sub-parsers under `keys`
  (`generate`/`activate`/`retire`/`revoke`/`list`) and `users` (`create`).
  Rationale: It is the de-facto standard Haskell CLI library, gives automatic `--help`,
  usage-on-error, and typed option parsing, and is the library MasterPlan 2's IP-8 explicitly
  names for EP-4. Its `cabal.project`/dependency block is appended under the existing
  "each plan appends its own block" comment and verified on GHC 9.12.4 (see Concrete Steps).
  Date: 2026-06-04

- Decision: Ship a **minimal environment-variable configuration loader now**, to be **superseded
  by EP-5's typed Dhall/env loader (MasterPlan 2 IP-6)**. The minimal loader reads
  `DATABASE_URL` (a libpq connection string), `SHOMEI_ISSUER`, and `SHOMEI_AUDIENCE` from the
  process environment and builds a `ShomeiConfig` via `defaultShomeiConfig issuer audience`
  plus a `hasql` pool via `Shomei.Postgres.Pool.acquirePool`.
  Rationale: EP-4 may land before EP-5. IP-6 states verbatim: "A single typed configuration
  loader, owned by EP-5 … Consumers: the `shomei-server` executable and the `shomei-admin` CLI
  (EP-4) should load configuration the same way, so EP-5's loader must be usable by EP-4's
  binary; **if EP-4 lands first with a minimal env-only loader, EP-5 supersedes it with the
  Dhall-backed one and records the migration in the Decision Log.**" We therefore keep the
  loader behind a tiny `Shomei.Admin.Env` module with a single entry point
  (`loadAdminEnv :: IO AdminEnv`) so EP-5 can replace its body with a Dhall-backed loader
  without touching any subcommand. This is the **IP-6 handoff point** and the one cross-plan
  hard dependency: EP-5 hard-depends on this plan.
  Date: 2026-06-04

- Decision: The signing-key status transitions the CLI enforces are exactly:
  `generate`: (nothing) → **pending**; `activate <kid>`: **pending → active**, and the same
  operation demotes the currently-active key **active → retired**; `retire <kid>`:
  **active → retired**; `revoke <kid>`: **{pending|active|retired} → revoked**. Each command
  refuses an illegal transition (e.g. activating a `revoked` key, or retiring a `pending` key)
  with a clear error and a non-zero exit.
  Rationale: This is the lifecycle MasterPlan 2 scoped for EP-4 ("pending → active → retired →
  revoked, with JWKS reflecting overlapping keys during rotation"). It is *richer* than
  `shomei-jwt`'s EP-4-of-MasterPlan-1 `rotateSigningKey`, which inserts a new key directly as
  `KeyActive` with no `pending` staging step (see `Shomei.Jwt.Rotation`,
  `docs/plans/4-jwt-signing-verification-and-jwks-publishing.md` Step 7). We deliberately do
  **not** call `rotateSigningKey`; instead the CLI drives the `Shomei.Effect.SigningKeyStore`
  effect operations directly (`insertSigningKey`, `updateSigningKeyStatus`) so an operator can
  stage a `pending` key and choose the activation moment. We reuse `shomei-jwt`'s
  `generateSigningKey`/`toStoredSigningKey` only for the cryptography (generating the key pair
  and serialising it to a `StoredSigningKey`), then override the status to `KeyPending`.
  Date: 2026-06-04

- Decision: The published JWKS includes a key iff its status is **`active` or `retired`** (i.e.
  every non-revoked, non-pending key). `pending` and `revoked` keys are excluded.
  Rationale: A `pending` key is staged but not yet in service, so publishing it would invite a
  verifier to trust tokens that were never signed (none are yet). A `retired` key must stay in
  the JWKS so previously-issued tokens keep verifying during the overlap window (zero-downtime
  rotation). A `revoked` key is excluded immediately so a compromised key cannot verify
  anything. This matches MasterPlan 1's EP-4 JWKS policy ("includes all keys that are not
  `KeyRevoked`") *except* that we additionally exclude `pending`, because this plan introduces
  the `pending` staging step that MasterPlan 1's simpler rotation did not have. Implementation
  note: `Shomei.Effect.SigningKeyStore.ListActiveSigningKeys`'s PostgreSQL interpreter currently
  returns **only** `status = 'active'` keys (see
  `shomei-postgres/src/Shomei/Postgres/SigningKeyStore.hs`), which is insufficient for
  "active + retired". This plan adds a small `listPublishableSigningKeys` helper (a direct
  `hasql` query `WHERE status IN ('active','retired')`) used by the CLI's JWKS assertions and by
  `keys list`; it does not change the existing effect signature. See Interfaces and Dependencies.
  Date: 2026-06-04

- Decision: `users create` drives the **existing `Shomei.Workflow.signup`** workflow through the
  PostgreSQL interpreters rather than inserting rows directly.
  Rationale: `signup` already enforces email normalisation, the password policy, the
  no-duplicate-email rule, Argon2id hashing (via `Shomei.Crypto.runPasswordHasherCrypto`), and
  the audit-event publication. Re-implementing any of that in the CLI would risk divergence.
  The signup also opens a session and mints a token pair; for an admin-bootstrap the session and
  token are discarded (the operator only needs the account to exist), so the CLI requires a
  `TokenSigner` interpreter in the stack — we use the trivial in-CLI `TokenSigner` fake the
  `shomei-postgres` integration tests already use (`runTokenSignerFake`), because the bootstrap
  user's first real token is minted later through the HTTP login flow. The fake never reaches
  the database.
  Date: 2026-06-04


- Decision: Update this ExecPlan for the 2026-06-04 package-layout and effect-namespace refactor.
  Rationale: The packages now live as top-level directories rather than under the old nested packages directory, and the core effect interfaces now live under `Shomei.Effect.*` rather than the old Port namespace. This revision also removes stale bootstrap-placeholder assumptions and points implementation steps at the current real modules.
  Date: 2026-06-04

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-06-10: **EP-4 complete.** An operator now has one binary, `shomei-admin`, to migrate,
  manage the signing-key rotation lifecycle, and seed a bootstrap user — no raw SQL, no running
  server. Live operator runbook (with `DATABASE_URL` set):

  ```text
  $ shomei-admin --help        # lists migrate | keys | users
  $ shomei-admin migrate
  migrations applied
  $ shomei-admin keys generate
  generated pending key: OcnLm3JqGVfCbNnOGz6ViK4lwCwUFIwrNEw5tqOkv4s
  $ shomei-admin keys activate OcnLm3JqGVfCbNnOGz6ViK4lwCwUFIwrNEw5tqOkv4s
  activated OcnLm3JqGVfCbNnOGz6ViK4lwCwUFIwrNEw5tqOkv4s
  retired (auto) nuGfPxoxeWe0NrtegJiTvJcB37YYXLAgMi10xC3T36Q
  $ shomei-admin users create --email admin@example.com --password '…' --display-name Admin
  created user user_01ktsjgp7aeh1a7b2rcymwdb4t <admin@example.com>
  $ shomei-admin keys list
  nuGfP…  KeyRetired  …
  OcnLm…  KeyActive   …
  ```

  The **rotation lifecycle** is proven by the `shomei-admin-test` integration suite against a
  throwaway database: generate → activate → (generate → activate, which auto-retires the prior
  active key) → `listPublishableSigningKeys` lists BOTH keys → a token signed by the now-RETIRED
  key STILL verifies against that JWKS (zero-downtime overlap) → after `revoke`, the revoked key
  leaves the JWKS and its token no longer verifies.

  Gaps / handoff: `Shomei.Admin.Env.loadAdminEnv` is the single env-only config entry point that
  EP-5's typed Dhall/env loader (IP-6) is expected to supersede in place; the table has no
  `revoked_at` column, so `revoke` records only the status (a later migration could add one).


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before any edit.

### Precondition: MasterPlan 1 must be Complete; this plan executes after it

This plan belongs to MasterPlan 2, which is **strictly post-bootstrap**: it assumes MasterPlan
1 (`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md`) is finished — that
`shomei-server` boots against PostgreSQL, signs/verifies ES256 JWTs, and publishes a JWKS. As
of the 2026-06-04 package-layout refactor, that precondition is satisfied: `shomei-jwt`,
`shomei-servant`, and the `shomei-server` library/executable are real top-level packages and
`cabal build all` / `cabal test all` pass. This plan reuses, by path:

- the `shomei-jwt` key cryptography — `Shomei.Jwt.Key.generateSigningKey`,
  `Shomei.Jwt.Key.toStoredSigningKey`, `Shomei.Jwt.Key.fromStoredSigningKey`, and
  `Shomei.Jwt.Jwks.jwksDocument` (specified in
  `docs/plans/4-jwt-signing-verification-and-jwks-publishing.md`, Steps 3, 4, 7) — for
  generating ES256 keys and building JWKS documents in the lifecycle integration test;
- the PostgreSQL `SigningKeyStore` interpreter
  `Shomei.Postgres.SigningKeyStore.runSigningKeyStorePostgres`
  (`shomei-postgres/src/Shomei/Postgres/SigningKeyStore.hs`) and the pool/config
  assembly (`Shomei.Postgres.Pool.acquirePool`,
  `Shomei.Postgres.Database.runDatabasePool`) for all key persistence;
- the codd migration runner `Shomei.Migrations.runShomeiMigrationsNoCheck`
  (`shomei-migrations/src/Shomei/Migrations.hs`) for `shomei-admin migrate`;
- the ephemeral-PostgreSQL test helper `Shomei.Migrations.TestSupport.withShomeiMigratedDatabase`
  (`shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs`) for the
  integration tests, exactly as `shomei-postgres/test/Main.hs` already uses it.

If any of those names differ when you implement, update this section and the steps below and
record it in the Decision Log.

### The repository and toolchain (define every term)

The repository root is `/Users/shinzui/Keikaku/bokuno/shomei`. It is a **multi-package cabal
workspace** (a single git repo with several independently-built packages, listed under
`packages:` in the root `cabal.project`): `shomei-core` (transport-agnostic domain + effects),
`shomei-jwt` (JWT/JWKS), `shomei-postgres` (PostgreSQL adapters), `shomei-migrations` (codd
schema + runner), `shomei-servant` (HTTP API types), `shomei-server` (the runnable service —
**and now the home of `shomei-admin`**), and `shomei-client`.

- The compiler is **GHC 9.12.4** (pinned by `with-compiler: ghc-9.12.4` in `cabal.project`),
  language edition **GHC2024**, `cabal-version: 3.0`. All commands run inside a **Nix
  development shell** entered with `nix develop` from the repository root (or automatically via
  `direnv`). Build with `cabal build all`; test with `cabal test`; format with `nix fmt`.
- A **custom prelude**, `Shomei.Prelude` (exposed by `shomei-core`), is imported in **every**
  Shōmei module instead of importing `Prelude`/base modules directly; it re-exports `Text`,
  `UTCTime`, `liftIO`, `toJSON`, the aeson class surface, etc. (Caution from prior plans:
  importing a name the prelude already re-exports triggers `-Wall`'s `-Wunused-imports`; take
  only the *additional* names from `Effectful`/`Data.Aeson`.)
- Each `.cabal` imports two shared `common` stanzas via `import: warnings, shared`. `warnings`
  enables `-Wall -Wcompat -Widentities -Wincomplete-record-updates -Wincomplete-uni-patterns
  -Wpartial-fields -Wredundant-constraints`. `shared` sets `default-extensions: BlockArguments,
  DeriveAnyClass, DuplicateRecordFields, MultilineStrings, OverloadedLabels, OverloadedRecordDot,
  OverloadedStrings, PackageImports, QualifiedDo, TemplateHaskell` (the `shomei-postgres` stanza
  additionally enables `DataKinds, GADTs, LambdaCase, TypeFamilies`, needed for effect GADTs).
- Imports are **postpositive-qualified** (`import Data.Text qualified as Text`) and may name
  their package with `PackageImports` (`import "hasql" Hasql.Encoders qualified as E`).
- **House gotchas** (inherited, non-negotiable): a record whose fields you read via `.field`
  must be imported with `(..)` (e.g. `StoredSigningKey (..)`), or you get
  `Could not deduce HasField …`. The `Shomei.Domain.Event` module is imported **qualified**
  (its constructors share names with `AuthError`). Record *updates* use `generic-lens` `#field`
  lenses plus `import Data.Generics.Labels ()` per module. **Never** depend on the deprecated
  `memory` package — use `ram`. Identifiers are `mmzk-typeid` `KindID`s (UUIDv7 + a type-level
  prefix), rendered with `idText` and parsed with `parseId`.

### What `effectful` is (used by every interpreter)

`effectful` is an effect-system library. An **effect** is a typed capability declared as a GADT
`data Foo :: Effect where …` with `type instance DispatchOf Foo = Dynamic`; you invoke an
operation with `send` (usually wrapped in a smart-constructor function) and supply behaviour
with an **interpreter** built from `interpret_`. `Eff es a` is a computation needing the
effects in the type-level list `es`; `(Foo :> es)` means `Foo` is available; `IOE :> es` means
`IO` is available (via `liftIO`). A `run…` interpreter has shape `Eff (Foo : es) a -> Eff es a`,
handling every `Foo` operation and removing `Foo` from the list. This plan assembles a stack of
interpreters and discharges it with `runEff`, exactly as `shomei-postgres/test/Main.hs`
does (see its `runApp`).

### The domain types this plan touches (reproduced for self-containment)

From `shomei-core/src/Shomei/Domain/SigningKey.hs` (do not redefine — import):

```haskell
data SigningKeyStatus = KeyPending | KeyActive | KeyRetired | KeyRevoked
  deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)

data StoredSigningKey = StoredSigningKey
  { keyId         :: !Text          -- the kid
  , algorithm     :: !Text          -- e.g. "ES256"
  , publicKeyJwk  :: !Text          -- opaque JWK JSON; core never imports jose
  , privateKeyJwk :: !Text          -- opaque JWK JSON (includes the private "d")
  , status        :: !SigningKeyStatus
  , createdAt     :: !UTCTime
  , activatedAt   :: !(Maybe UTCTime)
  , retiredAt     :: !(Maybe UTCTime)
  } deriving stock (Generic, Eq, Show) deriving anyclass (FromJSON, ToJSON)
```

From `shomei-core/src/Shomei/Effect/SigningKeyStore.hs` (the signing-key effect interface and its
smart constructors — verbatim):

```haskell
data SigningKeyStore :: Effect where
  ListActiveSigningKeys  :: SigningKeyStore m [StoredSigningKey]
  FindSigningKeyByKid    :: Text -> SigningKeyStore m (Maybe StoredSigningKey)
  InsertSigningKey       :: StoredSigningKey -> SigningKeyStore m ()
  UpdateSigningKeyStatus :: Text -> SigningKeyStatus -> UTCTime -> SigningKeyStore m ()

listActiveSigningKeys  :: (SigningKeyStore :> es) => Eff es [StoredSigningKey]
findSigningKeyByKid    :: (SigningKeyStore :> es) => Text -> Eff es (Maybe StoredSigningKey)
insertSigningKey       :: (SigningKeyStore :> es) => StoredSigningKey -> Eff es ()
updateSigningKeyStatus :: (SigningKeyStore :> es) => Text -> SigningKeyStatus -> UTCTime -> Eff es ()
```

Note carefully: `ListActiveSigningKeys`'s PostgreSQL interpreter
(`shomei-postgres/src/Shomei/Postgres/SigningKeyStore.hs`) issues
`WHERE status = 'active'` — it returns only `active` keys, **not** `retired` ones. The CLI's
`keys list` and the JWKS used by the lifecycle test therefore need a query that returns more
than this effect exposes; this plan adds a small read helper rather than changing the effect (see
Interfaces and Dependencies / Decision Log).

From `shomei-core/src/Shomei/Config.hs`: `ShomeiConfig` and
`defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig` (which sets `signingKeyConfig =
SigningKeyConfig { algorithm = "ES256" }`). `Issuer` and `Audience` are newtypes over `Text`
from `Shomei.Domain.Claims` (`Issuer (..)`, `Audience (..)`).

From `shomei-core/src/Shomei/Workflow.hs`:

```haskell
signup :: ( UserStore :> es, CredentialStore :> es, SessionStore :> es
          , RefreshTokenStore :> es, PasswordHasher :> es, TokenSigner :> es
          , AuthEventPublisher :> es, Clock :> es, TokenGen :> es )
       => ShomeiConfig -> SignupCommand -> Eff es (Either AuthError (User, TokenPair))
```

`SignupCommand` is `SignupCommand { email :: Email, password :: PlainPassword,
displayName :: Maybe Text }` (`Shomei.Domain.Command`); `Email` is built with
`mkEmail :: Text -> Either AuthError Email` (`Shomei.Domain.Email`); `PlainPassword` is a
newtype over `Text` with a redacting `Show` (`Shomei.Domain.Password`, `PlainPassword (..)`).

### The PostgreSQL assembly this plan reuses

`shomei-postgres` provides the `Database` effect and the interpreters the CLI strings
together. The canonical assembly is `shomei-postgres/test/Main.hs`'s `runApp`, which
this plan mirrors. The relevant pieces:

- `Shomei.Postgres.Pool.acquirePool :: Int -> Text -> IO Pool` — build a `hasql` pool of N
  connections from a libpq connection string.
- `Shomei.Postgres.Database.runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a ->
  Eff es a` — interpret the `Database` effect against the pool.
- One interpreter per effect: `runUserStorePostgres`, `runCredentialStorePostgres`,
  `runSessionStorePostgres`, `runRefreshTokenStorePostgres`, `runAuthEventPublisherPostgres`,
  `runSigningKeyStorePostgres`, `runClockIO` (all under `Shomei.Postgres.*`), plus
  `runPasswordHasherCrypto` and `runTokenGenCrypto` from `Shomei.Crypto`.
- Each store interpreter needs `Database :> es` and `Error AuthError :> es` in scope; the
  failure channel is `Effectful.Error.Static.Error AuthError`, discharged with
  `runErrorNoCallStack`. A `Left UsageError` from `hasql` becomes
  `InternalAuthError "database error: …"`.

### Files this plan creates or edits (all under the repository root)

```text
cabal.project                                              (edit: append optparse-applicative block, IP-8)
shomei-server/shomei-server.cabal                (edit: add `executable shomei-admin`)
shomei-server/app/Admin.hs                       (new: the CLI Main + optparse parser)
shomei-server/app/Shomei/Admin/Env.hs            (new: minimal env loader — IP-6 handoff)
shomei-server/app/Shomei/Admin/Keys.hs           (new: key lifecycle + JWKS read helper)
shomei-server/app/Shomei/Admin/Users.hs          (new: bootstrap-user creation over signup)
shomei-server/test/Admin/Main.hs                 (new: tasty integration tests)
```

(The CLI's helper modules live under `app/` alongside `Admin.hs`, in the `shomei-admin`
executable stanza's `other-modules`, because they are binary-internal. If a later plan needs to
reuse them they can move to the `shomei-server` library; for now keeping them in the executable
avoids enlarging the library's public surface.)


## Plan of Work

The work proceeds in four independently verifiable milestones. Every milestone ends in a
concrete `cabal` command and an observable behaviour. All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

### Milestone M1 — `shomei-admin` skeleton: `migrate` and `keys list`

Scope: stand up the binary and prove two read-ish commands end-to-end against a throwaway
PostgreSQL. At the end of M1, `cabal run shomei-admin -- --help` lists every subcommand,
`cabal run shomei-admin -- migrate` applies the schema, and `cabal run shomei-admin -- keys
list` prints the (initially empty) key table — and an integration test asserts both against an
ephemeral database.

First, append the `optparse-applicative` dependency block to the root `cabal.project` under the
existing "each plan appends its own block; none rewrites another's" comment (IP-8). Then add the
`executable shomei-admin` stanza to `shomei-server/shomei-server.cabal` and verify the
solver picks `optparse-applicative` on GHC 9.12.4 with `cabal build --dry-run shomei-server`.

Next, write `shomei-server/app/Shomei/Admin/Env.hs`, the minimal env loader: a record
`AdminEnv { config :: ShomeiConfig, pool :: Pool }` and `loadAdminEnv :: IO AdminEnv` that reads
`DATABASE_URL`, `SHOMEI_ISSUER`, `SHOMEI_AUDIENCE` (failing with a clear message if `DATABASE_URL`
is unset, defaulting issuer/audience to `"shomei"`/`"shomei-clients"` if unset), builds the
config with `defaultShomeiConfig`, and acquires a pool with `acquirePool 4`.

Then write `shomei-server/app/Admin.hs`: the `optparse-applicative` parser (top-level
`migrate | keys | users`, with `keys` and `users` sub-parsers), and a `main` that parses, then
dispatches. Implement `migrate` (call `getCoddSettings` then
`runShomeiMigrationsNoCheck settings (secondsToDiffTime 5)`, exactly as
`shomei-migrations/app/Main.hs` does) and `keys list` (read the keys via a small
`listPublishableSigningKeys`-style query and print a table). Make every command print a
human-readable line and `exitFailure` on error.

Finally, write the integration test `shomei-server/test/Admin/Main.hs` mirroring
`shomei-postgres/test/Main.hs`: for each case, `withShomeiMigratedDatabase` provisions
a fresh database, the test acquires a pool, and asserts behaviour. The M1 cases: (1) after
migration, `keys list` returns an empty list; (2) the schema's `shomei_signing_keys` table
exists (a `SELECT count(*)` succeeds).

Acceptance: `cabal build shomei-server` succeeds; `cabal test shomei-server` (the
`shomei-admin-test` suite) is green; and, against a live dev DB, `cabal run shomei-admin --
--help` and `cabal run shomei-admin -- keys list` behave as transcribed in Concrete Steps.

### Milestone M2 — key lifecycle (`generate`/`activate`/`retire`/`revoke`) + JWKS overlap test

Scope: the security-critical heart. At the end of M2, an operator can generate, activate,
retire, and revoke keys, and an integration test proves the rotation lifecycle and that
overlapping-key verification holds. Write `shomei-server/app/Shomei/Admin/Keys.hs`
containing the four lifecycle actions and the `listPublishableSigningKeys` read helper, and wire
them into `Admin.hs`'s `keys` sub-parser.

`keys generate` calls `shomei-jwt`'s `generateSigningKey` (mint an ES256 P-256 key with its
`kid` = RFC 7638 thumbprint) and `toStoredSigningKey now jwk`, then **overrides the status to
`KeyPending`** and clears `activatedAt`/`retiredAt`, and persists with `insertSigningKey`. It
prints the new `kid`.

`keys activate <kid>` is the rotation operation. It looks up the key by `kid`
(`findSigningKeyByKid`), refuses if its status is not `KeyPending` (clear error + non-zero
exit), finds the currently-active key(s) via `listPublishableSigningKeys` filtered to `active`,
then, with a single `now` timestamp: `updateSigningKeyStatus kid KeyActive now` for the target
and `updateSigningKeyStatus oldKid KeyRetired now` for each prior active key. It prints which
key became active and which retired.

`keys retire <kid>` requires the key be `active` and sets it `KeyRetired now`. `keys revoke
<kid>` requires the key be `pending`, `active`, or `retired` (i.e. not already `revoked`) and
sets it `KeyRevoked now`. Each prints the transition.

The lifecycle integration test (added to `test/Admin/Main.hs`) is the proof and must assert,
against a fresh migrated database, the full sequence (precise statuses and JWKS contents are in
Validation and Acceptance). Critically it builds the JWKS from the database via
`listPublishableSigningKeys` + `shomei-jwt`'s `jwksDocument`, signs a token with the *retired*
key, and verifies it against that JWKS to prove overlap; then revokes and proves the token no
longer verifies.

Acceptance: `cabal test shomei-server` is green including the lifecycle case; the M2 transcript
in Concrete Steps reproduces the generate→activate→retire→revoke output.

### Milestone M3 — `users create` driving signup

Scope: bootstrap a first user without the HTTP API. Write
`shomei-server/app/Shomei/Admin/Users.hs` with `createUserAction :: AdminEnv -> Text ->
Text -> Maybe Text -> IO ()` that builds a `SignupCommand` (parsing the email with `mkEmail`,
wrapping the password in `PlainPassword`), runs `Shomei.Workflow.signup` through the full
PostgreSQL interpreter stack (mirroring `shomei-postgres`'s `runApp`, with the trivial
`TokenSigner` fake), and prints the new user's id and email — or the workflow's `AuthError`
(e.g. `EmailAlreadyRegistered`, `WeakPassword …`) with a non-zero exit. Wire it into `Admin.hs`'s
`users create` sub-parser (`--email`, `--password`, optional `--display-name`).

Acceptance: `cabal test shomei-server` green including a `users create` case that asserts a
`shomei_users` and a `shomei_password_credentials` row exist and that the stored credential
verifies the supplied password (via `Shomei.Crypto`'s `runPasswordHasherCrypto` /
`verifyPassword`).

### Milestone M4 — minimal loader finalised + operator runbook transcript

Scope: tie it together and document the operator runbook. Confirm `Shomei.Admin.Env.loadAdminEnv`
is the single config entry point (so EP-5 can swap its body). Capture the full runbook transcript
(migrate → keys generate → keys activate → users create → keys list) verbatim into Concrete
Steps as the canonical end-to-end demonstration, and add a whole-CLI smoke test that drives that
sequence against an ephemeral database in one test case.

Acceptance: the runbook transcript in Concrete Steps reproduces against a live dev DB; the smoke
test is green; `nix fmt` and `cabal build all` are clean.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

### Step 1 — Append the `optparse-applicative` block to `cabal.project` (M1, IP-8)

The root `cabal.project` already has a section beginning
`-- DEPENDENCY OVERRIDES — each plan appends its own block; none rewrites another's.` followed by
EP-3's codd/ephemeral-pg block and EP-4-of-MasterPlan-1's jose block. Append a new block:

```cabal
-- ============================================================
-- MasterPlan 2 / EP-4 (operational CLI): optparse-applicative for shomei-admin.
-- On Hackage and on the GHC 9.12.4 package set; no source-repository-package needed.
-- If a version bound blocks the solve, add an `allow-newer: optparse-applicative:base`
-- entry here and record it in Surprises & Discoveries.
-- ============================================================
```

`optparse-applicative` itself is declared as a `build-depends` in the cabal stanza (Step 2), not
in `cabal.project`; this block is the documented home for any override it needs. Verify the
solver is happy:

```bash
cabal build --dry-run shomei-server
```

Expected: the plan resolves and lists `optparse-applicative` (a recent 0.18.x) among the
to-be-built packages, with no "unknown package" or version-conflict error. If it conflicts, add
`allow-newer: optparse-applicative:base` under the block above and re-run.

### Step 2 — Add the `executable shomei-admin` stanza (M1)

Append to `shomei-server/shomei-server.cabal` (after the existing `executable
shomei-server` stanza). The test-suite stanza is added here too (used from M1 on):

```cabal
executable shomei-admin
  import:         warnings, shared
  hs-source-dirs: app
  main-is:        Admin.hs
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  other-modules:
    Shomei.Admin.Env
    Shomei.Admin.Keys
    Shomei.Admin.Users
  build-depends:
    , base                 >=4.18 && <5
    , bytestring
    , codd
    , containers
    , effectful
    , effectful-core
    , hasql
    , hasql-pool
    , optparse-applicative
    , shomei-core
    , shomei-jwt
    , shomei-migrations
    , shomei-postgres
    , text
    , time

test-suite shomei-admin-test
  import:         warnings, shared
  type:           exitcode-stdio-1.0
  hs-source-dirs: app, test
  main-is:        Admin/Main.hs
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  other-modules:
    Shomei.Admin.Env
    Shomei.Admin.Keys
    Shomei.Admin.Users
  build-depends:
    , base
    , bytestring
    , codd
    , containers
    , effectful
    , effectful-core
    , hasql
    , hasql-pool
    , optparse-applicative
    , shomei-core
    , shomei-jwt
    , shomei-migrations
    , shomei-migrations:test-support
    , shomei-postgres
    , tasty
    , tasty-hunit
    , text
    , time
```

(The test stanza lists both `app` and `test` source dirs so it can re-use the `Shomei.Admin.*`
helper modules directly. `shomei-migrations:test-support` provides
`withShomeiMigratedDatabase`, exactly as `shomei-postgres`'s test stanza uses it — see
`shomei-postgres/shomei-postgres.cabal`.)

### Step 3 — `shomei-server/app/Shomei/Admin/Env.hs` (M1; IP-6 handoff)

The single config entry point. EP-5 (IP-6) will replace the body of `loadAdminEnv` with a typed
Dhall/env loader; **keep the type signature and module surface stable** so no subcommand changes.

```haskell
-- | Minimal environment-variable configuration loader for shomei-admin.
--
-- THIS IS A PLACEHOLDER superseded by MasterPlan 2 EP-5's typed Dhall/env loader (IP-6).
-- It reads DATABASE_URL (required), SHOMEI_ISSUER and SHOMEI_AUDIENCE (optional). Keep
-- 'loadAdminEnv' as the ONLY config entry point so EP-5 can swap the body without touching
-- any subcommand.
module Shomei.Admin.Env
  ( AdminEnv (..)
  , loadAdminEnv
  ) where

import Shomei.Prelude

import Data.Text qualified as Text
import Hasql.Pool (Pool)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Postgres.Pool (acquirePool)

data AdminEnv = AdminEnv
  { config :: !ShomeiConfig
  , pool   :: !Pool
  }

loadAdminEnv :: IO AdminEnv
loadAdminEnv = do
  mDbUrl <- lookupEnv "DATABASE_URL"
  dbUrl  <- case mDbUrl of
    Just u  -> pure (Text.pack u)
    Nothing -> do
      hPutStrLn stderr "shomei-admin: DATABASE_URL is not set (a libpq connection string)."
      exitFailure
  iss <- maybe "shomei"         Text.pack <$> lookupEnv "SHOMEI_ISSUER"
  aud <- maybe "shomei-clients" Text.pack <$> lookupEnv "SHOMEI_AUDIENCE"
  let cfg = defaultShomeiConfig (Issuer iss) (Audience aud)
  p <- acquirePool 4 dbUrl
  pure AdminEnv { config = cfg, pool = p }
```

### Step 4 — `shomei-server/app/Shomei/Admin/Keys.hs` (M1 read helper + M2 lifecycle)

This module owns key persistence logic. Two parts: (a) a `listPublishableSigningKeys` read
helper that returns active + retired keys (the effect's `ListActiveSigningKeys` returns only
`active`, which is insufficient for a JWKS that must include retired keys during overlap), and
(b) the four lifecycle actions. The read helper runs a direct `hasql` session against the pool;
the lifecycle actions run the `SigningKeyStore` interpreter stack.

```haskell
{- | shomei-admin signing-key lifecycle and a JWKS-publishing read helper.

The lifecycle is: generate → pending; activate → active (prior active auto-retires);
retire → retired; revoke → revoked. The published JWKS includes active + retired keys
(every non-revoked, non-pending key), so retired keys keep verifying old tokens during
overlap while revoked keys are dropped immediately.
-}
module Shomei.Admin.Keys
  ( generateKeyAction
  , activateKeyAction
  , retireKeyAction
  , revokeKeyAction
  , listKeysAction
  , listPublishableSigningKeys
  ) where

import Shomei.Prelude

import Data.Text qualified as Text
import Data.Time (getCurrentTime)

import "contravariant-extras" Contravariant.Extras (contrazip8)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Pool (Pool)
import "hasql" Hasql.Pool qualified as Pool
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Error (AuthError)
import Shomei.Effect.SigningKeyStore
  (SigningKeyStore, findSigningKeyByKid, insertSigningKey, updateSigningKeyStatus)

import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)

import "shomei-jwt" Shomei.Jwt.Key (generateSigningKey, toStoredSigningKey)

-- The interpreter stack the key actions run in. Mirrors shomei-postgres test's runApp,
-- pared to the effects key persistence needs.
type KeyEffects = '[SigningKeyStore, Database, Error AuthError, IOE]

runKeys :: Pool -> Eff KeyEffects a -> IO (Either AuthError a)
runKeys p =
  runEff
    . runErrorNoCallStack
    . runDatabasePool p
    . runSigningKeyStorePostgres

-- | Generate a new ES256 key in `pending` status and persist it. Prints the new kid.
generateKeyAction :: AdminEnv -> IO ()
generateKeyAction env = do
  now <- getCurrentTime
  jwk <- generateSigningKey
  let stored0 = toStoredSigningKey now jwk
      -- toStoredSigningKey sets status KeyActive/activatedAt=now; stage it as pending instead.
      stored  = stored0 { status = KeyPending, activatedAt = Nothing, retiredAt = Nothing }
  r <- runKeys env.pool (insertSigningKey stored)
  case r of
    Left e  -> die ("failed to persist key: " <> show e)
    Right () -> putStrLn ("generated pending key: " <> Text.unpack stored.keyId)

-- | Promote a pending key to active and retire whatever was active (single timestamp).
activateKeyAction :: AdminEnv -> Text -> IO ()
activateKeyAction env kid = do
  now <- getCurrentTime
  priorActive <- map (.keyId) . filter ((== KeyActive) . (.status))
                   <$> listPublishableSigningKeys env.pool
  r <- runKeys env.pool do
    mKey <- findSigningKeyByKid kid
    case mKey of
      Nothing -> pure (Left ("no key with kid " <> kid))
      Just k
        | k.status /= KeyPending ->
            pure (Left ("key " <> kid <> " is " <> statusText k.status <> ", not pending"))
        | otherwise -> do
            updateSigningKeyStatus kid KeyActive now
            for_ priorActive \old -> updateSigningKeyStatus old KeyRetired now
            pure (Right ())
  case r of
    Left e          -> die ("activate failed: " <> show e)
    Right (Left msg) -> die (Text.unpack msg)
    Right (Right ()) -> do
      putStrLn ("activated key: " <> Text.unpack kid)
      for_ priorActive \old -> putStrLn ("retired previously-active key: " <> Text.unpack old)

-- | Retire an active key (still trusted / still in the JWKS).
retireKeyAction :: AdminEnv -> Text -> IO ()
retireKeyAction = transitionFrom [KeyActive] KeyRetired "retired"

-- | Revoke a key (immediately untrusted / removed from the JWKS).
revokeKeyAction :: AdminEnv -> Text -> IO ()
revokeKeyAction = transitionFrom [KeyPending, KeyActive, KeyRetired] KeyRevoked "revoked"

-- A guarded single-key transition shared by retire/revoke.
transitionFrom :: [SigningKeyStatus] -> SigningKeyStatus -> String -> AdminEnv -> Text -> IO ()
transitionFrom allowed target verb env kid = do
  now <- getCurrentTime
  r <- runKeys env.pool do
    mKey <- findSigningKeyByKid kid
    case mKey of
      Nothing -> pure (Left ("no key with kid " <> kid))
      Just k
        | k.status `notElem` allowed ->
            pure (Left ("key " <> kid <> " is " <> statusText k.status
                          <> "; cannot " <> Text.pack verb))
        | otherwise -> Right () <$ updateSigningKeyStatus kid target now
  case r of
    Left e           -> die (verb <> " failed: " <> show e)
    Right (Left msg) -> die (Text.unpack msg)
    Right (Right ()) -> putStrLn (verb <> " key: " <> Text.unpack kid)

-- | Print every key (active/retired/pending/revoked) with status and timestamps.
listKeysAction :: AdminEnv -> IO ()
listKeysAction env = do
  keys <- listAllSigningKeys env.pool
  if null keys
    then putStrLn "(no signing keys)"
    else for_ keys \k ->
      putStrLn (Text.unpack k.keyId <> "  " <> Text.unpack (statusText k.status)
                  <> "  created=" <> show k.createdAt
                  <> "  activated=" <> show k.activatedAt
                  <> "  retired=" <> show k.retiredAt)

statusText :: SigningKeyStatus -> Text
statusText = \case
  KeyPending -> "pending"; KeyActive -> "active"; KeyRetired -> "retired"; KeyRevoked -> "revoked"

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) *> exitFailure

-- Direct read helpers (not on the effect): list keys for the JWKS and for `keys list`. ----

-- | Keys eligible for the published JWKS: active + retired (every non-revoked, non-pending key).
listPublishableSigningKeys :: Pool -> IO [StoredSigningKey]
listPublishableSigningKeys = runListQuery
  """
  SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
         created_at, activated_at, retired_at
  FROM shomei.shomei_signing_keys
  WHERE status IN ('active','retired')
  ORDER BY created_at
  """

-- | Every key regardless of status (for `keys list`).
listAllSigningKeys :: Pool -> IO [StoredSigningKey]
listAllSigningKeys = runListQuery
  """
  SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
         created_at, activated_at, retired_at
  FROM shomei.shomei_signing_keys
  ORDER BY created_at
  """

runListQuery :: Text -> Pool -> IO [StoredSigningKey]
runListQuery sql p = do
  res <- Pool.use p (Session.statement () (listStmt sql))
  either (\e -> die ("key query failed: " <> show e)) (pure . map rebuild) res

-- Row + decoder match shomei-postgres' SigningKeyStore (text JWK columns).
type KeyRow = (Text, Text, Text, Text, Text, UTCTime, Maybe UTCTime, Maybe UTCTime)

listStmt :: Text -> Statement () [KeyRow]
listStmt sql = preparable sql E.noParams (D.rowList keyRowDecoder)

keyRowDecoder :: D.Row KeyRow
keyRowDecoder =
  (,,,,,,,)
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

rebuild :: KeyRow -> StoredSigningKey
rebuild (kid, alg, pub, priv, st, c, act, ret) =
  StoredSigningKey
    { keyId = kid, algorithm = alg, publicKeyJwk = pub, privateKeyJwk = priv
    , status = statusFromText st, createdAt = c, activatedAt = act, retiredAt = ret }

statusFromText :: Text -> SigningKeyStatus
statusFromText = \case
  "pending" -> KeyPending; "active" -> KeyActive; "retired" -> KeyRetired
  "revoked" -> KeyRevoked; other -> error ("unknown signing-key status: " <> Text.unpack other)
```

The `contrazip8` import is listed for parity with the existing `SigningKeyStore` module; if the
final code does not use an 8-tuple encoder, drop it to satisfy `-Wunused-imports`. The
`statusFromText`/`statusText` helpers duplicate `Shomei.Postgres.Codec`'s
`signingKeyStatusFromText`/`signingKeyStatusToText`; if `Codec` is exposed from
`shomei-postgres`, import those instead and delete the local copies (record in Decision Log).

### Step 5 — `shomei-server/app/Shomei/Admin/Users.hs` (M3)

Drive `signup` through the full PostgreSQL interpreter stack (mirroring
`shomei-postgres/test/Main.hs`'s `runApp`, including the trivial `TokenSigner` fake).

```haskell
-- | shomei-admin bootstrap-user creation by driving Shomei.Workflow.signup.
module Shomei.Admin.Users (createUserAction) where

import Shomei.Prelude

import Data.Text qualified as Text

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..))
import Shomei.Error (AuthError)
import Shomei.Id (idText)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.Clock (Clock)
import Shomei.Effect.CredentialStore (CredentialStore)
import Shomei.Effect.PasswordHasher (PasswordHasher)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.UserStore (UserStore)
import Shomei.Workflow (signup)

import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Effect.SigningKeyStore (SigningKeyStore)

type AppEffects =
  '[ UserStore, CredentialStore, SessionStore, RefreshTokenStore, AuthEventPublisher
   , SigningKeyStore, TokenSigner, PasswordHasher, TokenGen, Clock
   , Database, Error AuthError, IOE ]

runApp :: Pool -> Eff AppEffects a -> IO (Either AuthError a)
runApp p =
  runEff . runErrorNoCallStack . runDatabasePool p . runClockIO . runTokenGenCrypto
    . runPasswordHasherCrypto . runTokenSignerFake . runSigningKeyStorePostgres
    . runAuthEventPublisherPostgres . runRefreshTokenStorePostgres . runSessionStorePostgres
    . runCredentialStorePostgres . runUserStorePostgres

-- The bootstrap account's first real token is minted later via HTTP login; this never persists.
runTokenSignerFake :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFake = interpret_ \case
  SignAccessToken _ -> pure (AccessToken "bootstrap-no-token")

createUserAction :: AdminEnv -> Text -> Text -> Maybe Text -> IO ()
createUserAction env emailRaw pwRaw mDisplay =
  case mkEmail emailRaw of
    Left err -> die ("invalid email: " <> show err)
    Right email -> do
      let cmd = SignupCommand { email = email, password = PlainPassword pwRaw, displayName = mDisplay }
      outer <- runApp env.pool (signup env.config cmd)
      case outer of
        Left e            -> die ("signup interpreter error: " <> show e)
        Right (Left e)    -> die ("signup rejected: " <> show e)
        Right (Right (u, _pair)) ->
          putStrLn ("created user " <> Text.unpack (idText u.userId)
                      <> " <" <> Text.unpack (idText u.userId) <> "> email recorded")

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) *> exitFailure
```

(When implementing, print the email via the `Email`'s `emailText` accessor from
`Shomei.Domain.Email` rather than repeating the id; the placeholder above shows the id twice
only to avoid importing the accessor in this sketch.)

### Step 6 — `shomei-server/app/Admin.hs` (the CLI entry point + parser)

```haskell
-- | shomei-admin: the operational CLI. Subcommands: migrate | keys {generate,activate,
-- retire,revoke,list} | users create.
module Main (main) where

import Shomei.Prelude

import Data.Text qualified as Text
import Options.Applicative

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Shomei.Migrations (runShomeiMigrationsNoCheck)

import Shomei.Admin.Env (loadAdminEnv)
import Shomei.Admin.Keys
  (activateKeyAction, generateKeyAction, listKeysAction, retireKeyAction, revokeKeyAction)
import Shomei.Admin.Users (createUserAction)

data Command
  = Migrate
  | KeysGenerate
  | KeysActivate Text
  | KeysRetire Text
  | KeysRevoke Text
  | KeysList
  | UsersCreate Text Text (Maybe Text)

main :: IO ()
main = run =<< customExecParser (prefs showHelpOnEmpty) opts
  where
    opts = info (commandP <**> helper)
      (fullDesc <> progDesc "Operational CLI for Shōmei (migrations, signing keys, users)")

commandP :: Parser Command
commandP = hsubparser
  ( command "migrate" (info (pure Migrate) (progDesc "Apply pending database migrations"))
 <> command "keys"    (info keysP  (progDesc "Manage signing keys"))
 <> command "users"   (info usersP (progDesc "Manage users"))
  )

keysP :: Parser Command
keysP = hsubparser
  ( command "generate" (info (pure KeysGenerate) (progDesc "Generate a new pending ES256 key"))
 <> command "activate" (info (KeysActivate <$> kidArg) (progDesc "Activate a pending key (retires the old active one)"))
 <> command "retire"   (info (KeysRetire   <$> kidArg) (progDesc "Retire an active key (stays trusted)"))
 <> command "revoke"   (info (KeysRevoke   <$> kidArg) (progDesc "Revoke a key (immediately untrusted)"))
 <> command "list"     (info (pure KeysList) (progDesc "List all keys with status and timestamps"))
  )
  where kidArg = Text.pack <$> argument str (metavar "KID")

usersP :: Parser Command
usersP = hsubparser
  ( command "create" (info userCreateP (progDesc "Create a bootstrap user via the signup workflow")) )
  where
    userCreateP = UsersCreate
      <$> (Text.pack <$> strOption (long "email" <> metavar "EMAIL" <> help "user email"))
      <*> (Text.pack <$> strOption (long "password" <> metavar "PASSWORD" <> help "user password"))
      <*> optional (Text.pack <$> strOption (long "display-name" <> metavar "NAME" <> help "display name"))

run :: Command -> IO ()
run Migrate = do
  settings <- getCoddSettings
  _ <- runShomeiMigrationsNoCheck settings (secondsToDiffTime 5)
  putStrLn "migrations applied"
run cmd = do
  env <- loadAdminEnv
  case cmd of
    KeysGenerate         -> generateKeyAction env
    KeysActivate kid     -> activateKeyAction env kid
    KeysRetire kid       -> retireKeyAction env kid
    KeysRevoke kid       -> revokeKeyAction env kid
    KeysList             -> listKeysAction env
    UsersCreate e p d    -> createUserAction env e p d
    Migrate              -> pure ()  -- handled above
```

`migrate` uses `getCoddSettings` (which reads `CODD_*` env vars) like
`shomei-migrations/app/Main.hs`; the other commands use `loadAdminEnv`. Verify `--help`:

```bash
cabal run shomei-admin -- --help
```

Expected (abridged):

```text
Operational CLI for Shōmei (migrations, signing keys, users)

Available commands:
  migrate   Apply pending database migrations
  keys      Manage signing keys
  users     Manage users
```

### Step 7 — The operator runbook transcript (M1–M4 demonstration)

Against a live dev PostgreSQL (the Nix shell exports `PGHOST=$PWD/db`, `PGDATABASE=shomei`, and
the schema lives in the `shomei` namespace). Export the env the CLI reads, then walk the runbook:

```bash
export DATABASE_URL="postgresql:///shomei?host=$PGHOST"
export SHOMEI_ISSUER="shomei"
export SHOMEI_AUDIENCE="shomei-clients"
# migrate also needs codd's vars, set as the Justfile `migrate` recipe does:
export CODD_MIGRATION_DIRS=unused CODD_EXPECTED_SCHEMA_DIR=unused CODD_CONNECTION="$DATABASE_URL"

cabal run shomei-admin -- migrate
cabal run shomei-admin -- keys generate
# copy the printed kid, e.g. AbC123…
cabal run shomei-admin -- keys activate AbC123…
cabal run shomei-admin -- users create --email alice@example.com --password 'correct horse battery staple' --display-name Alice
cabal run shomei-admin -- keys list
```

Expected transcript:

```text
migrations applied
generated pending key: AbC123…
activated key: AbC123…
created user user_01jabc… <alice@example.com> recorded
AbC123…  active  created=2026-… activated=2026-… retired=Nothing
```

(After a *second* `keys generate`/`keys activate` cycle, `keys list` would show the first key as
`retired` and the second as `active` — the overlap the lifecycle test exercises.)

### Step 8 — Run the integration tests

```bash
cabal test shomei-server
```

Expected tasty transcript (M1–M4 cases):

```text
shomei-admin
  migrate then keys list is empty:                                   OK
  keys generate stages a pending key (absent from JWKS):             OK
  keys activate publishes the active key in the JWKS:                OK
  rotation overlap: retired key still verifies; revoked key does not: OK
  users create persists a user whose password verifies:             OK
  full runbook smoke (migrate→generate→activate→create→list):       OK

All 6 tests passed
```


## Validation and Acceptance

Validation is behavioural, not "it compiles". Each criterion has concrete inputs and observable
outputs, encoded as tasty-hunit cases in `shomei-server/test/Admin/Main.hs`. Every case
provisions a fresh database with `withShomeiMigratedDatabase` and acquires a pool with
`acquirePool` — the same pattern as `shomei-postgres/test/Main.hs`.

1. **`migrate` then `keys list` is empty.** After running the migrations against a fresh
   database, `listAllSigningKeys pool` returns `[]` and a direct `SELECT count(*) FROM
   shomei.shomei_signing_keys` returns 0. Observable: empty list, count 0.

2. **`keys generate` stages a pending key absent from the JWKS.** Call `generateKeyAction`
   (or its persistence core) once. Then: `listAllSigningKeys` returns exactly one key with
   `status == KeyPending`; `listPublishableSigningKeys` returns `[]` (a pending key is **not**
   publishable); and `Shomei.Jwt.Jwks.jwksDocument` over the publishable keys decodes to JSON
   `{"keys":[]}`. Observable: one pending key in storage, zero keys in the JWKS.

3. **`keys activate` publishes the active key.** Generate a key (capture its `kid`), then
   `activateKeyAction env kid`. Now: the key's `status == KeyActive` and its `activatedAt` is
   `Just`; `listPublishableSigningKeys` returns exactly that key; the JWKS document over the
   publishable keys contains exactly one entry whose `kid` equals the activated key's `kid` and
   contains **no** private `"d"` field. Observable: one active key in storage and in the JWKS.

4. **Rotation overlap — retired key still verifies; revoked key does not.** This is the
   security-critical case. (a) Generate key A, activate A. (b) Generate key B, activate B —
   asserting A auto-retired (`A.status == KeyRetired`, `B.status == KeyActive`). (c)
   `listPublishableSigningKeys` now returns **both** A and B, and the JWKS document contains
   both kids. (d) Using `shomei-jwt`'s signer with A's *private* JWK
   (`fromStoredSigningKey A` → sign an `AuthClaims` for the configured issuer/audience), produce
   a token, then verify it against the JWKS built from the publishable keys
   (`shomei-jwt`'s `verifyToken` / a `JWKSet` of the publishable public keys): assert it returns
   `Right …` — **a token signed by the now-retired key A still verifies**. Also verify a token
   signed by the active key B verifies. (e) `revokeKeyAction env A.kid`; now
   `listPublishableSigningKeys` returns only B, the JWKS contains only B's kid, and verifying the
   A-signed token against the new JWKS returns `Left TokenSignatureInvalid` — **the revoked
   key's token no longer verifies**. Observable: the exact status transitions and the
   verify-Right-then-Left flip across revocation.

   This case proves the precise lifecycle: `generate → pending`; `activate → active` with the
   prior active demoted to `retired`; the published JWKS lists `active + retired` so overlapping
   verification holds; `revoke → revoked` drops the key from the JWKS and from trust.

5. **Illegal transitions are refused.** Activating a key that is not `pending`, retiring a key
   that is not `active`, or revoking an already-`revoked` key returns the guard's `Left` message
   (and, at the CLI level, exits non-zero). Encode at least: activate-a-revoked-key and
   retire-a-pending-key both fail without mutating the row. Observable: the key's status is
   unchanged after the rejected command.

6. **`users create` persists a user whose password verifies.** Run `createUserAction` for
   `alice@example.com` with a policy-satisfying password. Then: `SELECT count(*) FROM
   shomei.shomei_users` is 1 and `… shomei_password_credentials` is 1; and the stored credential
   hash verifies the supplied password (run `Shomei.Crypto.runPasswordHasherCrypto` with
   `verifyPassword` against the row's `password_hash`). A second `users create` with the same
   email is rejected (`EmailAlreadyRegistered`, non-zero exit) and leaves the count at 1.
   Observable: exactly one user/credential row, the hash verifies, the duplicate is rejected.

7. **Full runbook smoke.** In one case, drive migrate (the migrations are already applied by the
   harness, so this asserts idempotence — see below) → generate → activate → users create → and
   read back: one active key and one user. Observable: the end state matches the runbook
   transcript in Concrete Steps.

Run all cases with `cabal test shomei-server`; the expected transcript is in Concrete Steps,
Step 8. The suite uses **only** the ephemeral-PostgreSQL helper — no HTTP server, no manual
SQL — so a green run proves the CLI's behaviour against a real database in isolation.


## Idempotence and Recovery

All steps are safe to repeat. Editing `cabal.project`, the `.cabal` stanza, and the source
files is idempotent (re-running overwrites identical content). `cabal build`/`cabal test` only
recompile what changed; a stale-cache failure recovers with `cabal clean && cabal build
shomei-server`.

The CLI commands themselves:

- `migrate` is idempotent: codd records which migrations it has applied and skips them on
  re-run, so running `shomei-admin migrate` twice applies nothing the second time and exits 0.
  (Same property MasterPlan 1's EP-3 relies on for `shomei-migrate`.)
- `keys generate` always mints a **new** key (a fresh random key pair → a fresh thumbprint
  `kid`), so re-running it creates additional pending keys rather than duplicating one; this is
  safe and intentional. To avoid clutter, an operator revokes unwanted pending keys.
- `keys activate`/`retire`/`revoke` are guarded by status preconditions and use
  `updateSigningKeyStatus`, which is an idempotent `UPDATE … WHERE key_id = $1`. Re-running
  `activate <kid>` after the key is already `active` is **refused** by the `KeyPending` guard
  (non-zero exit, no mutation) — this is deliberate so a double-activate cannot silently
  re-retire a freshly-activated key. Re-running `revoke <kid>` on an already-revoked key is
  likewise refused. There is no destructive "delete key" command: revocation is the terminal,
  recoverable-by-generating-a-new-key state.
- `users create` is guarded by the signup workflow's no-duplicate-email rule: a repeat with the
  same email is rejected with `EmailAlreadyRegistered` and a non-zero exit, leaving the database
  unchanged.

Recovery: if `activate` half-completes (the new key flips to `active` but a prior key fails to
retire), re-running `keys list` shows the actual state; an operator can `keys retire <oldKid>`
manually to finish. Because each transition is a single-row `UPDATE`, partial state is always
inspectable and repairable through the same CLI. No step deletes data, so there is nothing to
back up beyond ordinary database backups; a botched rotation is corrected by activating the
intended key and retiring/revoking the others.


## Interfaces and Dependencies

Libraries and why: **`optparse-applicative`** (typed subcommand parsing with automatic `--help`
and usage-on-error; MasterPlan 2 IP-8 names it for EP-4). **`codd`** (the migration runner,
reused from `shomei-migrations`). **`hasql`/`hasql-pool`** (the `listPublishableSigningKeys`/
`listAllSigningKeys` read helpers run direct sessions against the pool). **`effectful`/
`effectful-core`** (the interpreter stacks). **`shomei-core`** (domain types, effects, config,
workflow), **`shomei-jwt`** (`generateSigningKey`/`toStoredSigningKey`/`fromStoredSigningKey`/
`jwksDocument`/`verifyToken`), **`shomei-postgres`** (pool, `Database`, effect interpreters,
`Shomei.Crypto`), **`shomei-migrations`** (runner + `test-support`). **`tasty`/`tasty-hunit`**
(tests). Forbidden, as everywhere in Shōmei: the deprecated `memory` package (use `ram`).

The signatures that must exist at the end of each milestone (full module paths):

End of **M1**:

```haskell
-- shomei-server/app/Shomei/Admin/Env.hs
data AdminEnv = AdminEnv { config :: !ShomeiConfig, pool :: !Hasql.Pool.Pool }
loadAdminEnv :: IO AdminEnv

-- shomei-server/app/Shomei/Admin/Keys.hs
listPublishableSigningKeys :: Hasql.Pool.Pool -> IO [StoredSigningKey]   -- status IN (active,retired)
listKeysAction             :: AdminEnv -> IO ()                          -- prints all keys

-- shomei-server/app/Admin.hs
main :: IO ()                                                            -- migrate | keys | users
```

End of **M2**:

```haskell
-- shomei-server/app/Shomei/Admin/Keys.hs
generateKeyAction :: AdminEnv -> IO ()          -- → pending
activateKeyAction :: AdminEnv -> Text -> IO ()  -- pending→active, prior active→retired
retireKeyAction   :: AdminEnv -> Text -> IO ()  -- active→retired
revokeKeyAction   :: AdminEnv -> Text -> IO ()  -- {pending|active|retired}→revoked
```

End of **M3**:

```haskell
-- shomei-server/app/Shomei/Admin/Users.hs
createUserAction :: AdminEnv -> Text -> Text -> Maybe Text -> IO ()      -- email pw displayName
```

The CLI **consumes** but does not change the `Shomei.Effect.SigningKeyStore` effect signature
(`InsertSigningKey`, `FindSigningKeyByKid`, `UpdateSigningKeyStatus`, `ListActiveSigningKeys`).
Because that effect's `ListActiveSigningKeys` returns only `active` keys, this plan adds the
direct `listPublishableSigningKeys`/`listAllSigningKeys` read helpers (a `hasql`
`WHERE status IN (…)` query) rather than altering the effect. If a later plan decides the effect
should expose "all non-revoked keys," that is a `shomei-core`/`shomei-postgres` change owned
there, not here; record any such decision in this plan's Decision Log and in EP-4-of-MasterPlan-1's.

**Cross-plan dependency (the IP-6 handoff).** `Shomei.Admin.Env.loadAdminEnv` is the single
configuration entry point, deliberately small so MasterPlan 2 **EP-5 (packaging, plan 12)** can
replace its body with the typed Dhall/env loader it owns (IP-6) without touching any subcommand.
EP-5 **hard-depends** on this plan: its container entrypoint runs `shomei-admin migrate` and
ensures an active signing key (`shomei-admin keys generate` + `keys activate`) at startup, and
its config loader supersedes the minimal env loader here. Keep `AdminEnv`/`loadAdminEnv` stable;
when EP-5 supersedes the loader, record the migration in both plans' Decision Logs.


## Revision Notes

2026-06-04: Updated after the package-layout refactor and MasterPlan audit. Package paths now
refer to top-level directories, effect modules use `Shomei.Effect.*`, and the precondition
reflects that `shomei-jwt`, `shomei-servant`, and `shomei-server` are implemented.
