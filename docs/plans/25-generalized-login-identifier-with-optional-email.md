---
id: 25
slug: generalized-login-identifier-with-optional-email
title: "Generalized login identifier with optional email"
kind: exec-plan
created_at: 2026-06-17T22:35:51Z
intention: intention_01kvbyj0d7edhaxdwhj2haw3vb
---

# Generalized login identifier with optional email

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the Shōmei authentication library (the Haskell multi-package Cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/shomei`) treats a user's **email address as the one and only
principal**: the value you sign up with, the value you log in with, the value the database
enforces as unique, and the value the password-strength check uses for its "don't reuse your
identity" rule. The `Shomei.Domain.User.User` record carries `email :: !Email` as a
non-optional field; `Shomei.Domain.Credential.Credential` carries `email :: !Email`; the
stores look users and credentials up *by email* (`FindUserByEmail`,
`FindPasswordCredentialByEmail`); and the migrations declare `shomei_users.email` and
`shomei_password_credentials.email` as `NOT NULL UNIQUE`.

That is a modeling error for a real consumer. The TAN auth service (the system this library
is being adopted by — see the consumer plans referenced at the bottom of this document) has
principals whose identity is a **username/handle**: agent and client identifiers that are not
necessarily email addresses and frequently are not. A service account or an agent id like
`agent-4815162342` has no email at all. Forcing every principal to be a syntactically valid
email is wrong: it rejects legitimate identifiers and it lies about the data.

After this change, the principal of Shōmei is a **login identifier** — a free-form,
case-insensitive, unique handle (we name the type `LoginId`) — and **email becomes an optional
attribute** of the user. A caller can sign up and log in with `LoginId "agent-4815162342"` and
no email whatsoever. When a real email *is* present, everything that genuinely needs an email
still works: the password-reset and email-verification workflows still deliver to that email,
the password-strength "resembles identity" check still considers the email, the HIBP breach
check's contextual comparison still considers the email, and the WebAuthn passkey user-handle
still resolves (it was always derived from the user id, not the email, so it is unaffected).

You can see the change working three ways once it lands:

1. A new in-memory workflow test signs up `agent-4815162342` with **no email**, then logs that
   same identifier in and gets a token pair back. Before this change that test cannot even be
   written, because `SignupCommand` has no field for a non-email identifier and `signup`
   rejects anything `mkEmail` cannot parse.
2. A second test signs up a user *with* an email, requests a password reset, and asserts that
   the `Notifier` effect received a `PasswordResetRequested` notification addressed to that
   email — proving email-bearing accounts keep their reset path. A companion assertion turns
   on `breachCheckEnabled` + `rejectContextualPasswords` and proves the email still feeds the
   contextual/breach context.
3. A PostgreSQL store test signs up by identifier with no email, reads the row back, and shows
   `email IS NULL` is now legal and `login_id` is unique — proving the migration relaxed the
   old `NOT NULL UNIQUE` on email and added the new unique identifier column.

This plan is a **shomei library enhancement only**. It does not touch the TAN auth service. It
is the upstream prerequisite known in the master plan as **SH-25**, and it is consumed by the
auth-service-v2 plans **EP-2** (identity + data model) at
`/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/3-...` and **EP-8** (passkeys)
at `/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/9-...`. Those plans assume
the contract this plan establishes (a `LoginId` principal with optional `email`). We will not
modify those files here; we only note where they consume our output.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Introduce the `LoginId` domain type (`shomei-core/src/Shomei/Domain/LoginId.hs`),
  export it from the core, and make `User`/`Credential`/`NewUser` carry `loginId` with `email`
  optional. Core compiles; in-memory interpreter updated. **(2026-06-17)** Done. Note: the
  `shomei-core` *library* could not be built in isolation at the M1 boundary because the
  workflows (`Shomei.Workflow`) live in the same library and construct `NewUser` — see Surprises
  & Discoveries. M1's domain/type changes therefore landed together with M2's workflow/effect
  changes in one buildable commit.
- [x] M2: Update workflows (`signup`, `login`, account/password-reset) and the effects
  (`UserStore`, `CredentialStore`, `Command`) to key on `LoginId`, keeping optional
  lookup-by-email for reset/verification. **(2026-06-17)** Done. `cabal test shomei-core-test`
  green — all 105 tests pass, including the new `signup+login by identifier with no email` and
  `password reset delivers to the email when present` cases.
- [x] M3: Expand/contract PostgreSQL migration + store updates: add `login_id` column with
  backfill, relax `email` to nullable, swap unique constraints. `cabal test
  shomei-postgres-test` green against the ephemeral database. **(2026-06-17)** Done. Four new
  migration files (`2026-06-19-00-00-00..03`) expand/backfill/constrain `login_id` and relax
  `email` to nullable + partial-unique on both `shomei_users` and `shomei_password_credentials`.
  The `Shomei.Migrations` splice was edited (documenting comment) to force the `embedDir`
  recompile — without it the new files are silently not embedded (the first test run failed with
  `column "login_id" ... does not exist`; see Surprises & Discoveries). Postgres interpreters
  carry `login_id` + nullable `email` (new `Codec.maybeEmailFromDb`/`loginIdFromDb`,
  `contrazip7`, `findUserByLoginIdStmt`/`findCredByLoginIdStmt`). All 23 postgres tests pass
  (19 migrations applied), including the new `NULL email round-trips; login_id unique; NULL
  emails don't collide` case.
- [x] M4: Update the Servant DTO/handler wire surface so HTTP signup/login accept a
  `loginId` (email optional) while preserving backward compatibility for email-only callers.
  `cabal build shomei-servant` and `cabal test shomei-servant-test` green. **(2026-06-17)** Done.
  `SignupRequest`/`LoginRequest` carry optional `loginId`/`email`; `UserResponse` carries
  `loginId :: Text` and `email :: Maybe Text`. A single handler helper `resolvePrincipal`
  implements the compatibility default (explicit `loginId` → `mkLoginId`; else default from a
  present email; else `400`), and the abuse `accountKey` now keys on the login-id text
  (`Seam.accountKeyOf :: Text -> AccountKey`, server supplies `sha256Hex`). `Servant.Error` maps
  the new `InvalidLoginId`/`LoginIdAlreadyRegistered`. Two new servant tests prove identifier-only
  signup (`email == null`, then login by identifier) and the email-only → `loginId == email`
  default. `cabal test all` (serialized) is green across all 11 suites; the example/client/admin
  test fixtures were updated to the new DTO/event shapes. See Surprises & Discoveries for the
  ephemeral-pg concurrency note and the shared-World test-isolation fix.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The in-memory credential store is keyed *by email*, not scanned.** `Shomei.Effect.InMemory`
  holds `credsByEmail :: Map Email Credential` and resolves `FindPasswordCredentialByEmail` with a
  direct `Map.lookup e . (.credsByEmail)` (around lines 164, 279–280). Users, by contrast, live in
  `users :: Map UserId User` and `findByEmail` is a *scan* over the values. Consequence for M1/M2:
  making `LoginId` the credential principal is not merely "compare against `Maybe Email`" — the
  credential `Map` must be **re-keyed by `LoginId`** (e.g. `credsByLoginId :: Map LoginId
  Credential`), `CreatePasswordCredential` (new arity `UserId -> LoginId -> Maybe Email ->
  PasswordHash`) inserts under the login id, `FindPasswordCredentialByLoginId` becomes the direct
  lookup, and the retained `FindPasswordCredentialByEmail` becomes a *scan* over the values that
  matches `Just e == c.email` (mirroring the user `findByEmail`). The `World` record field name and
  every handler that touches it must change together or the module will not compile.

- **`Credential` is the type; `PasswordCredential` is its constructor.**
  `Shomei.Domain.Credential` exports `Credential (..)`, whose sole data constructor is
  `PasswordCredential { credentialId, userId, email :: Email, passwordHash, createdAt, updatedAt }`.
  M1 adds `loginId :: LoginId` and relaxes `email` to `Maybe Email` on that constructor.

- **`failLogin` takes an `Email` (in a tuple) today.** In `Shomei.Workflow` the helper is
  `failLogin :: (Email, UTCTime) -> ...`-shaped and exists to publish `Event.LoginFailed`; M2's
  switch to keying abuse/`accountKey` on the login id must change this helper's `Email` argument to
  `LoginId` (or its text) and update `Event.LoginFailedData` accordingly — confirmed present, as
  the plan states.

- **M1 cannot build the library in isolation; M1+M2 must land together.** The plan's M1 acceptance
  assumed `cabal build shomei-core` (library only) would succeed after the pure data-shape change.
  It does not: the auth workflows (`Shomei.Workflow`, `Shomei.Workflow.Account`,
  `Shomei.Workflow.Passkey`) are modules *of the `shomei-core` library*, and `Shomei.Workflow.signup`
  constructs `NewUser{email = …}` positionally/by-field. Adding `loginId` and making `email`
  optional immediately broke that constructor, so the library would not compile until the M2
  workflow edits were applied. Evidence: first `cabal build shomei-core` after the M1 record change
  failed with `Constructor 'NewUser' does not have the required strict field(s): loginId` at
  `src/Shomei/Workflow.hs:138`. Consequence: M1 and M2 were implemented and committed together as a
  single buildable core change; the milestone *content* is unchanged, only the commit boundary moved.

- **Only two event payloads needed shape changes; the email-bearing account events were kept
  `Email`-typed by guarding.** `Event.UserRegisteredData` gained `loginId :: LoginId` and
  `email :: Maybe Email`; `Event.LoginFailedData` swapped `email :: Email` for `loginId :: LoginId`
  (matching the `failLogin`/`accountKey`-on-principal change). The other email-bearing events
  (`EmailVerificationRequestedData`, `EmailVerifiedData`, `PasswordResetRequestedData`) were left
  `Email`-typed: the account workflows that publish them now run inside a `forM_ user.email \email ->`
  guard (or, for `confirmEmailVerification`, a `maybe (throwError VerificationTokenInvalid) pure
  user.email`), so an email is always in scope where those events fire. This keeps their JSON payload
  shape (and the `EventCodec` round-trip) unchanged — no migration of stored audit rows is needed.

- **`changePassword` resolves the credential by `LoginId`, not email.** Previously it called
  `findPasswordCredentialByEmail user.email`. With email optional, it now calls
  `findPasswordCredentialByLoginId user.loginId` (the principal is always present), which is both
  simpler and correct for email-less accounts — no `Just`-guarding or fallback needed.

- **M3: the `embedDir` splice must be forced to recompile, and `cabal build shomei-migrations`
  will NOT do it on its own.** After adding the four new `.sql` files, `cabal build
  shomei-migrations` reported "Up to date" and the first `cabal test shomei-postgres-test` applied
  only 15 migrations (stopping at `2026-06-18-…`), failing with `column "login_id" of relation
  "shomei_users" does not exist`. GHC's recompilation checker does not track new files appearing in
  a TH-`embedDir`'d directory. Fix (matching the established convention in `Shomei.Migrations`): edit
  the `Shomei.Migrations` source — a documenting comment above `embeddedFiles` is enough — to force
  the splice to re-evaluate. After that the suite applied 19 migrations and went green.

- **M4: the wire surface had more consumers than the four core packages — and two test-harness
  gotchas.** Beyond `shomei-servant`, the DTO/command/event changes rippled into
  `shomei-server` (`Boot.accountKeyOf`, the `shomei-admin` `Users` CLI, and the admin test's
  `LoginFailedData`), `shomei-client`'s round-trip test, and both `examples/*` test suites — all
  construct `SignupRequest`/`LoginRequest`/`UserResponse`/`LoginFailedData` by record and broke at
  `cabal test all` even though `cabal build all` was green (the example/test suites are not built by
  `build all`). Two harness fixes were needed: (1) the servant test shares one in-memory `World`
  IORef across test cases, and tasty runs cases in parallel — adding two new cases raced the
  original scenario into a spurious `401` on the admin route; the fix gives each new case a fresh
  `World`/`Env`. (2) `cabal test all` boots several ephemeral-pg-backed suites concurrently, which
  intermittently fails `shomei-postgres-test` on database contention; each suite passes in
  isolation and `cabal test all -j1` is reliably green across all 11 suites.

- **Validation pass (2026-06-17).** All other factual claims in this plan were checked against the
  live tree and hold exactly: `User`/`NewUser` fields; `mkEmail :: Text -> Either AuthError Email`
  with an unexported raw constructor; `AuthError` carrying `InvalidEmail`/`EmailAlreadyRegistered`;
  the `UserStore`/`CredentialStore` GADT ops and wrappers; `SignupCommand`/`LoginCommand`/
  `ClientContext`; `signup` calling `mkEmail`+`findUserByEmail`+throwing `EmailAlreadyRegistered`
  and `login` calling `findPasswordCredentialByEmail`; the `Workflow/Account.hs` reset/verify
  functions building `PasswordContext { contextEmail = Just (emailText user.email), ... }` and
  sending `PasswordResetRequested user.email …`/`EmailVerificationRequested user.email …`;
  `RequestPasswordReset`/`RequestEmailVerification` email-typed newtypes; `PasswordContext` already
  carrying `contextEmail :: Maybe Text`; `resemblesIdentity`, `rejectContextualPasswords`,
  `breachCheckEnabled`, `PasswordResemblesIdentity`; `userHandleForUser` deriving from the user-id
  UUID and `beginPasskeyRegistration` reading `emailText user.email` for `accountName`; `UserId =
  KindID "user"`; the two base migrations with `email text NOT NULL UNIQUE` and the `embedDir
  "sql-migrations"` splice (latest existing migration is
  `2026-06-18-00-00-01-shomei-webauthn-pending-ceremonies.sql`, so the new files should sort after
  it, e.g. `2026-06-19-…`); the postgres `UserStore`/`CredentialStore` INSERTs and
  `nonNullable D.text` email decoders plus `Codec.emailFromDb`; the servant `SignupRequest`/
  `LoginRequest`/`UserResponse` DTOs, `userToResponse`, and `env.accountKeyOf :: Email ->
  AccountKey` in `Servant.Seam`; and the tasty test suites with the `ctxFor` fixture and the
  ephemeral-pg postgres harness.


## Decision Log

Record every decision made while working on the plan.

- Decision: Introduce a dedicated newtype `LoginId` rather than reusing `Email` or a bare
  `Text`.
  Rationale: A bare `Text` gives no type-safety and would silently mix with display names and
  passwords; reusing `Email` would keep the very email-shape constraint we are trying to
  remove. A newtype with smart-constructor normalization (trim + lowercase) mirrors the
  existing `Email` module's design exactly (`shomei-core/src/Shomei/Domain/Email.hs`), so the
  codebase stays internally consistent and invalid identifiers remain unrepresentable.
  Date: 2026-06-17

- Decision: `email` becomes `Maybe Email` on `User`, `NewUser`, and `Credential`; lookups are
  keyed by `LoginId`; an *optional* `FindUserByLoginIdOrEmail`-style path is retained only
  where reset genuinely needs email entry.
  Rationale: This is the minimal change that makes the principal generic while preserving every
  email-dependent behavior (reset delivery, contextual/breach context, verification). Keeping
  email lookups available (but no longer the principal) means existing email-based consumers
  can still drive a reset by email.
  Date: 2026-06-17

- Decision: Preserve backward compatibility by defaulting `loginId` to the email text when a
  caller supplies only an email (the DTO/handler layer derives `LoginId` from the email when no
  explicit `loginId` is given), and by keeping the email-typed reset/verification entry points.
  Rationale: Existing email-first integrations (and the shomei examples/tests that sign up with
  an email) must keep working with no behavior change. "Identifier can equal email by default"
  is the explicit compatibility rule.
  Date: 2026-06-17

- Decision: Migrate the database with an expand/contract (a.k.a. parallel-change) strategy
  across additive migration files, never an in-place destructive `ALTER`.
  Rationale: `shomei-migrations` embeds ordered SQL files via Template Haskell `embedDir`
  (`shomei-migrations/src/Shomei/Migrations.hs`), and codd applies them in filename order.
  Expand/contract (add nullable column → backfill → add constraints → relax old constraints) is
  idempotent, re-runnable, and safe for any pre-existing rows. It also matches how the schema
  has grown so far (every change is a new dated file; none rewrites a prior one).
  Date: 2026-06-17

- Decision: Implement and commit M1 and M2 as a single buildable core change.
  Rationale: The `shomei-core` *library* contains the workflows, which construct `NewUser`; the
  M1 record change alone does not compile (see Surprises & Discoveries). Rather than introduce
  throwaway scaffolding to make an intermediate library build, M1's type changes were landed
  together with the M2 effect/workflow changes in one commit that leaves the library and the test
  suite green. The milestone *structure* and acceptance criteria are unchanged.
  Date: 2026-06-17

- Decision: Keep `EmailVerificationRequestedData`/`EmailVerifiedData`/`PasswordResetRequestedData`
  email-typed (only `UserRegisteredData` and `LoginFailedData` changed), guarding the publishing
  sites on the user's `Maybe Email` instead.
  Rationale: Those events are only meaningful for an account with an email, and the workflows that
  emit them now run under a `Just`-email guard, so an `Email` is always available there. Leaving
  their payload shape untouched avoids any change to the stored-audit JSON and the `EventCodec`
  round-trip, so no audit-table migration is required.
  Date: 2026-06-17

- Decision (inherited locked decision from the shared brief): shomei is enhanced upstream via
  SH-24 and SH-25; auth-service-v2 depends on shomei and does **not** fork it. SH-25 is this
  plan. We make the change in the shomei repo only.
  Rationale: Locked decision #1 and #4 in the master brief. Recorded here for self-containment.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-17 — all four milestones delivered; `cabal test all -j1` green across all 11
suites.** The principal of Shōmei is now a free-form, case-insensitive, unique `LoginId`, with
email an optional attribute end-to-end: domain types (`User`/`NewUser`/`Credential`), the
effects (`FindUserByLoginId`/`FindPasswordCredentialByLoginId`, `CreatePasswordCredential`
now `UserId -> LoginId -> Maybe Email -> PasswordHash`), the workflows (signup/login key on the
login id; reset/verification/breach-context guard on `Maybe Email`), the PostgreSQL schema
(expand/contract migrations adding `login_id NOT NULL UNIQUE` and relaxing `email` to nullable +
partial-unique) and interpreters, and the Servant wire surface (optional `loginId`/`email`, the
compatibility default in `resolvePrincipal`).

All three demonstrations from Purpose hold, proven by tests: (1) signup+login by
`agent-4815162342` with no email returns a token pair (`shomei-core-test` and a servant-level
case); (2) an email-bearing account still drives password-reset delivery and the contextual
"resembles identity" check (`shomei-core-test` AccountSpec); (3) the PostgreSQL store permits
`email IS NULL`, enforces a unique `login_id`, and lets multiple NULL emails coexist
(`shomei-postgres-test`). The passkey user-handle was unaffected as predicted (PasskeySpec stays
green). The two locked SH-25 decisions (upstream-only enhancement; identifier-equals-email by
default) were honored; the auth-service-v2 EP-2/EP-8 consumers were not touched.

Gaps / follow-ups: none blocking. Two harness frictions are documented (shared-`World` test
isolation; ephemeral-pg concurrency under `cabal test all` — use `-j1`). A consumer running the
expand/contract migration against real data should verify the inline constraint names
(`shomei_users_email_key`, `shomei_password_credentials_email_key`) match their database; the
`DROP CONSTRAINT IF EXISTS` makes a name mismatch a safe no-op but then leaves the old unique in
place.


## Context and Orientation

This section assumes you have never seen this repository. Read it before editing anything.

**The repository.** `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Cabal project
(GHC 9.12.4, the GHC2024 language edition). The package list lives in
`/Users/shinzui/Keikaku/bokuno/shomei/cabal.project`. You build with `cabal build` and test
with `cabal test`. The repo uses a Nix dev shell; the canonical entry is `nix develop` and then
the `cabal` commands. The packages relevant to this plan are:

- `shomei-core` — pure domain types, "effects" (described below), and the auth workflows.
  This is where the principal is modeled. Source under
  `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/`.
- `shomei-postgres` — the PostgreSQL "interpreters" for the effects (hasql-based). Source under
  `/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/src/Shomei/Postgres/`.
- `shomei-migrations` — the SQL schema migrations (one file per change), embedded into the
  binary and applied by the `codd` migration tool. Files live under
  `/Users/shinzui/Keikaku/bokuno/shomei/shomei-migrations/sql-migrations/`.
- `shomei-servant` — the HTTP wire layer (Servant): request/response JSON shapes ("DTOs") and
  the handlers that translate them into workflow calls. Source under
  `/Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/`.

**"Effect" and "interpreter" (terms of art, defined here).** Shōmei uses the `effectful`
library. An *effect* is a small typed interface (a GADT named like `UserStore`) declaring
the operations the workflows may perform — for example "create a user", "find a user by X". The
workflows depend only on these effects, never on a database. An *interpreter* is a concrete
implementation of an effect: there is an in-memory interpreter used in tests
(`shomei-core/src/Shomei/Effect/InMemory.hs`) and a PostgreSQL interpreter used in production
(`shomei-postgres/src/Shomei/Postgres/*Store*.hs`). When you change an effect (add or rename an
operation), you must update **every** interpreter of that effect or the build breaks.

**The principal today (what we are changing).** The user entity is
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/User.hs`:

```haskell
data User = User
    { userId :: !UserId
    , email :: !Email
    , displayName :: !(Maybe Text)
    , status :: !UserStatus
    , emailVerifiedAt :: !(Maybe UTCTime)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }
```

`Email` is a newtype around `Text` with a smart constructor `mkEmail` that trims, lowercases,
and *rejects anything that does not look like `local@domain.tld`*
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Email.hs`). The raw
constructor is not exported, so an invalid email cannot be built — which is exactly why a
username principal cannot be represented today.

The credential entity
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Credential.hs`) likewise
carries `email :: !Email`.

The effects are keyed by email. `UserStore`
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/UserStore.hs`) declares
`FindUserByEmail :: Email -> UserStore m (Maybe User)`, and `CredentialStore`
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/CredentialStore.hs`)
declares `CreatePasswordCredential :: UserId -> Email -> PasswordHash -> ...` and
`FindPasswordCredentialByEmail :: Email -> CredentialStore m (Maybe Credential)`.

The commands that drive workflows
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Command.hs`) are
email-typed: `SignupCommand { email :: !Email, password, displayName }` and `LoginCommand {
email :: !Email, password }`.

The workflows in `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Workflow.hs`
use them: `signup` calls `mkEmail`, builds a `PasswordContext` from the email, calls
`findUserByEmail`, throws `EmailAlreadyRegistered`, and creates the credential with the email.
`login` calls `findPasswordCredentialByEmail cmd.email`. The account workflows in
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Workflow/Account.hs`
(`requestPasswordReset`, `confirmPasswordReset`, `requestEmailVerification`,
`confirmEmailVerification`, `changePassword`) build `PasswordContext` from `user.email` and
look users up by email.

`PasswordContext`
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Password.hs`) already
carries `contextEmail :: !(Maybe Text)` and `contextDisplayName :: !(Maybe Text)` — note it is
**already optional-friendly**, so the password-strength validator needs no signature change;
we simply pass `Nothing` for `contextEmail` when there is no email.

The database. The base user table
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-migrations/sql-migrations/2026-06-03-00-00-01-shomei-users.sql`):

```sql
CREATE TABLE IF NOT EXISTS shomei_users (
  user_id      uuid PRIMARY KEY,
  email        text NOT NULL UNIQUE,
  display_name text NULL,
  status       text NOT NULL,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL
);
```

The credentials table
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-migrations/sql-migrations/2026-06-03-00-00-02-shomei-password-credentials.sql`)
similarly declares `email text NOT NULL UNIQUE`. Migration files begin with a `-- codd: in-txn`
header and a `SET search_path TO shomei, pg_catalog;` line; codd orders them by filename, so a
new change is a new dated file (look at the existing names like
`2026-06-04-00-00-00-shomei-users-email-verified.sql`, which is a plain additive `ALTER TABLE
... ADD COLUMN IF NOT EXISTS`). The files are embedded at compile time by
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-migrations/src/Shomei/Migrations.hs` via
`$(embedDir "sql-migrations")`; **adding a new `.sql` file requires recompiling that module**
for it to be picked up (the comment in that file warns about this).

The PostgreSQL interpreters mirror the schema. `Shomei.Postgres.UserStore`
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/src/Shomei/Postgres/UserStore.hs`)
builds `INSERT INTO shomei.shomei_users (user_id, email, display_name, status, created_at,
updated_at)` and a `findUserByEmailStmt`. `Shomei.Postgres.CredentialStore`
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/src/Shomei/Postgres/CredentialStore.hs`)
mirrors the credentials table. Both decode `email` as a `nonNullable D.text` today; making
email optional requires the column decoders/encoders to become `nullable`.

The wire layer. `Shomei.Servant.DTO`
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/DTO.hs`) declares
`SignupRequest { email, password, displayName }`, `LoginRequest { email, password }`, and
`UserResponse { userId, email, displayName, status }`. The handlers
(`/Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/Handlers.hs`) parse
`req.email` through `mkEmail` (a malformed address becomes a `400` before the workflow runs),
and the login handler computes an abuse-protection `accountKey` from the email via
`env.accountKeyOf email`.

**What is genuinely email-dependent (must keep working when email is present).**

- *Password-reset delivery* — `requestPasswordReset` in `Workflow/Account.hs` sends
  `PasswordResetRequested user.email raw expires` to the `Notifier` effect. With no email there
  is nothing to deliver to; with an email it must still deliver.
- *Email verification* — `requestEmailVerification`/`confirmEmailVerification` only make sense
  for an account that has an email.
- *Contextual / breach password context* — `PasswordContext.contextEmail` feeds both
  `validatePassword`'s "resembles identity" rule (`resemblesIdentity` in
  `Domain/Password.hs`) and the breach checker's contextual comparison (the policy flags
  `rejectContextualPasswords` and `breachCheckEnabled` in `Domain/Password.hs`; the guard
  `Workflow/Breach.hs`). When an email exists it must be included in the context; the display
  name and (new) login identifier are always available to the context too.

**What is NOT email-dependent (no behavior change needed).**

- *The passkey user-handle* — `userHandleForUser` in
  `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Workflow/Passkey.hs` derives the
  WebAuthn user handle from the **user id's UUID bytes**, never from the email. The only place
  passkey code reads the email is to populate the human-readable `accountName`/`displayName`
  shown in the browser's passkey UI (in `beginPasskeyRegistration`); with no email we will fall
  back to the login identifier text. The handle itself is unaffected, so passwordless login by
  user-handle keeps working with no schema change.

**Identifiers.** All entity ids are `mmzk-typeid` `KindID`s — UUIDv7 values with a type-level
prefix (`UserId = KindID "user"`, etc.), defined in
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Id.hs`. These are unchanged by
this plan; the *login identifier* is a separate human-supplied handle, not an id.


## Plan of Work

The work is four milestones. M1 introduces the new domain type and threads it through the pure
data and the in-memory interpreter. M2 updates the effects, commands, and workflows so the
*behavior* changes (you can sign up/login by identifier with no email, and email still drives
reset/breach when present). M3 changes the database (expand/contract migration) and the
PostgreSQL interpreters. M4 updates the HTTP wire surface. Each milestone leaves the tree
compiling and its tests green, and each is independently verifiable.

Throughout, the **compatibility rule** is: when a caller provides only an email and no explicit
login identifier, the login identifier defaults to the normalized email text. This keeps every
email-first caller working unchanged.


### Milestone 1 — The `LoginId` domain type and the optional-email data model

**Scope.** Add the principal type and make the pure domain records carry it, with email
optional. No workflow behavior changes yet beyond what the types force; the goal is a compiling
core with the new shape and an updated in-memory interpreter.

**What will exist at the end.** A new module
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/LoginId.hs` exporting:

```haskell
module Shomei.Domain.LoginId (
    LoginId,
    mkLoginId,
    loginIdText,
    loginIdFromEmail,
) where
```

`LoginId` is a `newtype LoginId = LoginId Text` with the raw constructor **not exported**,
mirroring `Shomei.Domain.Email`. `mkLoginId :: Text -> Either AuthError LoginId` trims
whitespace and lowercases (case-insensitive principal), and rejects the empty string and any
value containing internal whitespace (returning a new `AuthError` constructor `InvalidLoginId`
— add it to `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Error.hs` next to
`InvalidEmail`). It does **not** require an `@` or a dot — that is the whole point.
`loginIdText :: LoginId -> Text` projects the text. `loginIdFromEmail :: Email -> LoginId`
builds a `LoginId` from an already-validated `Email` by taking `emailText` (this is the
compatibility bridge — "identifier equals email by default"); since the email is already
normalized, this is total and needs no re-validation.

Update `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/User.hs`:

```haskell
data User = User
    { userId :: !UserId
    , loginId :: !LoginId
    , email :: !(Maybe Email)
    , displayName :: !(Maybe Text)
    , status :: !UserStatus
    , emailVerifiedAt :: !(Maybe UTCTime)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }

data NewUser = NewUser
    { loginId :: !LoginId
    , email :: !(Maybe Email)
    , displayName :: !(Maybe Text)
    }
```

Update `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Credential.hs` so
`PasswordCredential` carries `loginId :: !LoginId` and `email :: !(Maybe Email)` (the
credential is still the binding of a principal + password hash to a user; the principal is now
the login id, with email retained as optional metadata for the reset-by-email path).

Add the module to the `exposed-modules` of
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/shomei-core.cabal`.

Update the in-memory interpreter
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/InMemory.hs`: it stores
users/credentials in `Map`s keyed by id; change the email-equality lookups (`findByEmail` and
the credential-by-email lookup near lines 245–280) to compare `Just e` against `u.email` and to
add a `findByLoginId` helper comparing `u.loginId`. **Note** that credentials are stored in a
`Map` *keyed by* `Email` (`credsByEmail`), not scanned — see Surprises & Discoveries — so the
credential side cannot be a one-line comparison change; re-keying that `Map` to `LoginId` is part
of M2 (the new operations), while M1 only adjusts the existing user/credential handlers to the new
record *shape* so the module compiles.)

**Commands to run** (working directory `/Users/shinzui/Keikaku/bokuno/shomei`, inside
`nix develop`):

```bash
cabal build shomei-core
```

**Acceptance.** `cabal build shomei-core` succeeds. The new `Shomei.Domain.LoginId` module is
importable. The `User`/`NewUser`/`Credential` records now carry `loginId` and a `Maybe Email`.
At this point existing core tests may not yet compile (they construct `User`s with the old
shape); that is expected and is fixed in M2, where the tests are updated alongside the
workflows. To keep M1 self-verifiable, build only the `shomei-core` *library* target as shown
(not the test suite).


### Milestone 2 — Effects, commands, and workflows: principal is `LoginId`, email optional

**Scope.** Change the behavior. After this milestone you can sign up and log in by `LoginId`
with no email, and when an email is present the reset/verification/breach-context paths still
work. The in-memory test suite proves both.

**Effects.** In
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/UserStore.hs`:

- Add `FindUserByLoginId :: LoginId -> UserStore m (Maybe User)` and its `findUserByLoginId`
  smart wrapper.
- Keep `FindUserByEmail :: Email -> UserStore m (Maybe User)` and `findUserByEmail` — it is no
  longer the principal lookup but is still needed by the email-entry reset/verification flows
  (a caller who initiates a reset *by typing an email* still finds the user). This is the
  "optional lookup-by-email for reset where applicable" the design calls for.
- `CreateUser` already takes a `NewUser`, which now carries `loginId` + optional `email`; no
  signature change there.

In `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/CredentialStore.hs`:

- Change `CreatePasswordCredential :: UserId -> Email -> PasswordHash -> ...` to
  `CreatePasswordCredential :: UserId -> LoginId -> Maybe Email -> PasswordHash -> ...` (the
  credential's principal is the login id; email is optional metadata).
- Add `FindPasswordCredentialByLoginId :: LoginId -> CredentialStore m (Maybe Credential)` and
  its wrapper.
- Keep `FindPasswordCredentialByEmail` for the reset-by-email path (used by
  `changePassword`/`confirmPasswordReset`, which can equally resolve by `userId` — see below —
  but retaining the email lookup avoids breaking any existing caller).

**Commands.** In
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Command.hs`:

```haskell
data SignupCommand = SignupCommand
    { loginId :: !LoginId
    , email :: !(Maybe Email)
    , password :: !PlainPassword
    , displayName :: !(Maybe Text)
    }

data LoginCommand = LoginCommand
    { loginId :: !LoginId
    , password :: !PlainPassword
    }
```

The `ClientContext` (carrying `accountKey` for abuse protection) is unchanged in shape, but its
`accountKey` is now derived from the **login id text** rather than the email text — the abuse
key must track the principal you actually log in with. The `failLogin` helper currently takes an
`Email` purely to publish `Event.LoginFailed`; change it to take the `LoginId` (or the login-id
text) and adjust `Event.LoginFailedData` accordingly. The `RequestPasswordReset`/
`RequestEmailVerification` newtypes in `Workflow/Account.hs` stay email-typed (you request a
reset *by email*), which is correct: reset-by-email is only meaningful when an email exists.

**Workflows.** In `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Workflow.hs`:

- `signup`: drop the `mkEmail` re-parse (the command now carries an already-validated optional
  `Email` and a required `LoginId`). Build the `PasswordContext` as:

  ```haskell
  PasswordContext
      { contextEmail = emailText <$> cmd.email
      , contextDisplayName = cmd.displayName
      }
  ```

  (When `cmd.email` is `Nothing`, `contextEmail` is `Nothing` and the contextual rule simply
  has nothing to compare against the email — length, common-password, and any login-id/display
  comparison still apply.) Replace `findUserByEmail email` with `findUserByLoginId cmd.loginId`
  and the `EmailAlreadyRegistered` throw with a generic-but-accurate `LoginIdAlreadyRegistered`
  (add to `Error.hs`; keep `EmailAlreadyRegistered` too — if a non-`Nothing` email collides
  with an existing user's email, you may still surface that, but the principal collision check
  is now on the login id). Create the user with `NewUser{loginId = cmd.loginId, email =
  cmd.email, displayName = cmd.displayName}` and create the credential with
  `createPasswordCredential user.userId cmd.loginId cmd.email pwHash`. The
  `Event.UserRegistered`/`Event.SessionStarted` publications keep working; update
  `Event.UserRegisteredData` to carry the login id (and optional email) instead of a required
  email if it currently requires one — check
  `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Domain/Event.hs` and adjust the
  event payload type accordingly (this is a domain event shape change; record it in the
  Decision Log if you alter the wire/JSON codec in `Domain/EventCodec.hs`).

- `login`: replace `findPasswordCredentialByEmail cmd.email` with `findPasswordCredentialByLoginId
  cmd.loginId`. Everything downstream (`findUserById cred.userId`, MFA branch, session issue) is
  unchanged. Update the abuse-protection plumbing so `accountKey`/`failLogin` use the login id.

In `/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Workflow/Account.hs`:

- `requestPasswordReset` / `requestEmailVerification`: unchanged in logic, but
  `user.email` is now `Maybe Email`. Send the notification only when `user.email` is `Just e`:

  ```haskell
  forM_ user.email \e -> sendNotification (PasswordResetRequested e raw expires)
  ```

  When the user has no email, there is no token to deliver and the workflow is a no-op for that
  user (it already silently no-ops for unknown users — keep that anti-enumeration behavior).
- `confirmPasswordReset` / `changePassword`: build `PasswordContext` from `emailText <$>
  user.email` (was `Just (emailText user.email)`); the display name still feeds the context. In
  `changePassword`, resolve the credential by the **user id** path if available, or keep the
  email lookup guarded by `Just`; since `changePassword` already has `cmd.userId`, prefer adding
  no new dependency — it can look up the credential through the user. (If you keep
  `findPasswordCredentialByEmail`, guard it with the `Just` email and fall back to a
  login-id/user-id lookup when the user has no email, so password change works for email-less
  accounts.)

**Update the in-memory interpreter and tests.** In
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-core/src/Shomei/Effect/InMemory.hs`, add handlers
for `FindUserByLoginId`, `FindPasswordCredentialByLoginId`, and the new `CreatePasswordCredential`
arity. Concretely: re-key the credential `Map` from `credsByEmail :: Map Email Credential` to
`credsByLoginId :: Map LoginId Credential` (rename the `World` field and update every reference);
`CreatePasswordCredential userId loginId mEmail hash` inserts under `loginId`;
`FindPasswordCredentialByLoginId` becomes the direct `Map.lookup`; and the retained
`FindPasswordCredentialByEmail e` becomes a *scan* over the credential values matching
`Just e == c.email` (mirroring the user `findByEmail` scan). For users, make
`findByEmail`/credential-by-email compare against the `Maybe Email`. In the
test fixtures (`shomei-core/test/Shomei/WorkflowSpec.hs`, `AccountSpec.hs`, and any others that
build `User`/`SignupCommand`/`LoginCommand`), switch to the new fields; the existing fixture
`ctxFor` derives the `AccountKey` from the principal — derive it from the login id now.

**New tests (the heart of the acceptance).** Add to `WorkflowSpec.hs`:

1. `testSignupLoginByIdentifierNoEmail`: builds `SignupCommand { loginId = mkLoginId'
   "agent-4815162342", email = Nothing, password = strongPw, displayName = Nothing }`, runs
   `signup`, asserts `Right (user, _)` with `user.email == Nothing` and `user.loginId ==
   "agent-4815162342"`; then runs `login` with the same `LoginId` and `strongPw`, asserts
   `Right (LoginComplete _ _)`.
2. `testResetEmailAndContextWhenEmailPresent` (extend/borrow from `AccountSpec.hs`): sign up a
   user *with* an email, request a password reset, and assert the in-memory `Notifier` captured
   a `PasswordResetRequested` to that email. With `rejectContextualPasswords = True`, assert a
   password equal to the email's local part is rejected with `PasswordResemblesIdentity`,
   proving the email still feeds the context.

**Commands to run** (working directory `/Users/shinzui/Keikaku/bokuno/shomei`, inside
`nix develop`):

```bash
cabal build shomei-core
cabal test shomei-core-test
```

**Acceptance.** `cabal test shomei-core-test` is green, and the run includes the two new cases.
A novice can confirm by reading the test output for the case names. Behaviorally: signup+login
by identifier with **no email** succeeds; password reset still delivers to the email and the
contextual check still uses it when an email is present.


### Milestone 3 — Database expand/contract migration and PostgreSQL interpreters

**Scope.** Make the schema and the production interpreters match the new model, safely, with an
expand/contract migration that backfills existing rows.

**The expand/contract strategy, in plain terms.** "Expand/contract" (also called
"parallel-change") means you never break the schema in a single destructive step. Instead you:
(1) *expand* — add the new column nullable, with no constraints, so old and new code both work;
(2) *backfill* — populate the new column for existing rows; (3) *constrain* — add the
constraints (unique, not-null) once data is consistent; (4) *contract* — relax or drop the old
constraints you no longer need. Because each step is a separate, idempotent migration file,
codd can apply them in order and the operation is safe to re-run. There is no production data in
the shomei library's own database (the shomei migrations describe the schema that *consumers*
deploy), but we still write the migration as if rows exist, because consumers (e.g.
auth-service-v2 EP-2) will run it against real data.

Add four new migration files under
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-migrations/sql-migrations/`, named so they sort
after the existing files (use a date past the latest existing `2026-06-18-...`, e.g.
`2026-06-19-...`). Each begins with the standard `-- codd: in-txn` header and `SET search_path
TO shomei, pg_catalog;`.

Migration A — expand `shomei_users` (add `login_id`, backfill from email, constrain):

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Expand: add the new principal column, nullable for now.
ALTER TABLE shomei_users
  ADD COLUMN IF NOT EXISTS login_id text NULL;

-- Backfill: existing rows had email as the principal; identifier defaults to email.
UPDATE shomei_users
  SET login_id = email
  WHERE login_id IS NULL;

-- Constrain: every user must now have a login id, and it must be unique.
ALTER TABLE shomei_users
  ALTER COLUMN login_id SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_login_id_key
  ON shomei_users (login_id);
```

Migration B — relax `shomei_users.email` to optional:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Contract: email is now an optional attribute, not the principal.
ALTER TABLE shomei_users
  ALTER COLUMN email DROP NOT NULL;

-- The old UNIQUE on email was created inline by the CREATE TABLE; drop it and replace
-- with a partial unique index so NULL emails don't collide while real emails stay unique.
ALTER TABLE shomei_users
  DROP CONSTRAINT IF EXISTS shomei_users_email_key;

CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_email_key
  ON shomei_users (email)
  WHERE email IS NOT NULL;
```

Migration C and D do the identical expand/backfill/constrain then relax for
`shomei_password_credentials` (add `login_id text`, backfill from `email`, `SET NOT NULL`,
unique index on `login_id`; then drop the inline `shomei_password_credentials_email_key`
constraint, `DROP NOT NULL` on `email`, and add a partial unique index on `email WHERE email IS
NOT NULL`). Mirror Migration A/B exactly, substituting the table name.

A note on the inline-constraint names: PostgreSQL names a column-level `UNIQUE` as
`<table>_<column>_key` by default, so `shomei_users_email_key` and
`shomei_password_credentials_email_key` are the names to drop. If a consumer's database used a
different name, the `IF EXISTS` makes the drop a no-op; in that case add the explicit drop of
the actual constraint name. The plan author should verify the names with `\d shomei_users` in
the ephemeral test database (see Concrete Steps) and adjust if needed.

**Recompile note.** Because the migration files are embedded via Template Haskell `embedDir`
(`shomei-migrations/src/Shomei/Migrations.hs`), after adding the files you must force a rebuild
of `shomei-migrations` (a `cabal build shomei-migrations` will recompile the splice and pick up
the new files).

**PostgreSQL interpreters.** Update
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/src/Shomei/Postgres/UserStore.hs`:

- The `InsertUserRow`/`UserRow` tuples gain a `login_id` `text` column and the `email` column
  becomes `Maybe Text`. Use `contrazip` arity that matches the new column count, and decode
  `email` with `D.nullable D.text` and `login_id` with `D.nonNullable D.text`.
- `insertUserStmt` SQL becomes `INSERT INTO shomei.shomei_users (user_id, login_id, email,
  display_name, status, created_at, updated_at) VALUES (...)`.
- Add `findUserByLoginIdStmt` (`WHERE login_id = $1`). Keep `findUserByEmailStmt` (`WHERE email
  = $1`).
- `mkUser`/`rebuildUser` carry the `loginId` and the `Maybe Email`. Use `emailFromDb` only when
  the column is `Just` (so a NULL email rebuilds to `Nothing`).

Update
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/src/Shomei/Postgres/CredentialStore.hs`
the same way: add `login_id`, make `email` nullable in the row tuples and decoders, add
`findCredByLoginIdStmt`, and handle the new `CreatePasswordCredential` arity that now takes
`LoginId` + `Maybe Email`.

Check `/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/src/Shomei/Postgres/Codec.hs` for
`emailFromDb`; if it assumes a non-null text, add a `maybeEmailFromDb :: Maybe Text -> Either
Text (Maybe Email)` helper (decode when `Just`, pass through `Nothing`).

**Commands to run** (working directory `/Users/shinzui/Keikaku/bokuno/shomei`, inside
`nix develop`):

```bash
cabal build shomei-migrations
cabal build shomei-postgres
cabal test shomei-postgres-test
```

The PostgreSQL test suite uses an *ephemeral* PostgreSQL (the pinned `ephemeral-pg` from
`cabal.project`): it boots a throwaway database, applies all embedded migrations (including the
four new ones), and runs the store round-trips. No external database setup is required.

**Acceptance.** `cabal test shomei-postgres-test` is green. Add a store test
(`shomei-postgres/test/...`) that: creates a user with `loginId = "svc-bot"`, `email =
Nothing`; reads it back by `findUserByLoginId` and asserts `email == Nothing`; creates a second
user with the same `loginId` and asserts the unique index rejects it; and creates two users
with `email = Nothing` to prove the partial unique index permits multiple NULL emails. This
proves the migration relaxed `NOT NULL`/`UNIQUE` on email and added a unique `login_id`.


### Milestone 4 — Servant wire surface (HTTP), backward-compatible

**Scope.** Let HTTP callers sign up/login by `loginId` with optional `email`, while email-only
callers keep working unchanged (compatibility rule: when only `email` is sent, `loginId`
defaults to the email).

**DTOs.** In `/Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/DTO.hs`:

- `SignupRequest { loginId :: !(Maybe Text), email :: !(Maybe Text), password :: !Text,
  displayName :: !Text }`. Both `loginId` and `email` are optional in the wire JSON; at least
  one must be present (enforced in the handler).
- `LoginRequest { loginId :: !(Maybe Text), email :: !(Maybe Text), password :: !Text }`.
- `UserResponse { userId :: !Text, loginId :: !Text, email :: !(Maybe Text), displayName ::
  !Text, status :: !Text }`. `userToResponse` renders `loginId = loginIdText u.loginId` and
  `email = emailText <$> u.email`.

Keeping `email` as an accepted input field (not removing it) is what preserves backward
compatibility for the existing email-first JSON clients and the shomei examples.

**Handlers.** In
`/Users/shinzui/Keikaku/bokuno/shomei/shomei-servant/src/Shomei/Servant/Handlers.hs`, in the
signup and login handlers:

- Parse the optional email through `mkEmail` only when present (a malformed *present* email is
  still a `400`; an absent email is fine).
- Determine the `LoginId`: if `req.loginId` is `Just t`, run it through `mkLoginId` (a malformed
  one is a `400`); else if an email is present, default to `loginIdFromEmail` of the parsed
  email; else return a `400` ("loginId or email required"). This is the compatibility default in
  one place.
- Build the workflow command with the resolved `LoginId` and the optional `Email`.
- Compute `accountKey` from the **login id text** (`env.accountKeyOf` currently takes an
  `Email`; change it to take `Text`/`LoginId` and key the abuse store on the principal). Verify
  `env.accountKeyOf` in `Shomei.Servant.Seam` / `Shomei.Servant.Handlers` and adjust its type.

The password-reset/verify handlers stay email-typed (they parse `req.email` through `mkEmail`
as today) — initiating a reset still requires an email, which is correct.

**Commands to run** (working directory `/Users/shinzui/Keikaku/bokuno/shomei`, inside
`nix develop`):

```bash
cabal build shomei-servant
cabal test shomei-servant-test
```

**Acceptance.** `cabal build shomei-servant` and `cabal test shomei-servant-test` are green.
Add (or extend) a servant-level test that posts a signup with only `{"loginId":"agent-x",
"password":"correct horse battery staple","displayName":""}` (no email) and gets back a
`UserResponse` with `loginId == "agent-x"` and `email == null`, then logs in with the same
`loginId`. And a second test that posts only `{"email":"a@b.com", ...}` and confirms the
returned `loginId` equals `"a@b.com"` (the compatibility default), proving email-only callers
are unbroken.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`, inside the
Nix dev shell. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop
```

Milestone-by-milestone (run after the edits described above):

```bash
# M1
cabal build shomei-core

# M2
cabal build shomei-core
cabal test shomei-core-test

# M3
cabal build shomei-migrations
cabal build shomei-postgres
cabal test shomei-postgres-test

# M4
cabal build shomei-servant
cabal test shomei-servant-test

# Whole-repo sanity at the end
cabal build all
cabal test all
```

Expected transcript shape for a green core test run (names will include the new cases):

```text
Shomei.Workflow
  signup then login                                  OK
  signup+login by identifier with no email           OK
  refresh rotates                                    OK
  ...
Shomei.Account
  password reset delivers to email                   OK
  contextual check uses email when present           OK
  ...
All N tests passed (… s)
```

To inspect the live schema while writing Migration A–D, boot the ephemeral database used by the
postgres test harness and run `\d shomei_users` to confirm the inline constraint names
(`shomei_users_email_key`, `shomei_password_credentials_email_key`). The exact incantation is
in `/Users/shinzui/Keikaku/bokuno/shomei/shomei-postgres/test/Main.hs`; follow how it starts
`ephemeral-pg` and connects, then run the `\d` describe command against that connection string.


## Validation and Acceptance

The change is proven by behavior, not by compilation alone:

1. **Signup + login by identifier with NO email** (core test
   `testSignupLoginByIdentifierNoEmail`): `signup` with `email = Nothing` returns
   `Right (user, tokenPair)` where `user.email == Nothing`; an immediate `login` with the same
   `LoginId` returns `Right (LoginComplete _ _)`. This is impossible before the change (the
   command had no non-email field and `signup` re-parsed through `mkEmail`).
2. **Password-reset email still works when an email is present** (core/account test): after
   signing up *with* an email and calling `requestPasswordReset`, the in-memory `Notifier`
   recorded a `PasswordResetRequested` notification carrying that exact email and a token.
3. **Breach/contextual context still uses the email when present** (core test): with
   `rejectContextualPasswords = True` (and, in a variant, `breachCheckEnabled = True` with a
   stub breach checker), a password equal to the email's local part is rejected with
   `PasswordResemblesIdentity`, demonstrating `contextEmail` is still fed from the email.
4. **Database permits NULL email and enforces unique login id** (postgres test): a user created
   with `email = Nothing` round-trips with `email IS NULL`; two users may share a NULL email
   (partial unique index) but not a login id.
5. **Passkey user-handle unaffected** (existing `PasskeySpec` stays green): because
   `userHandleForUser` derives the handle from the user-id UUID, the passkey tests pass
   unchanged; the only passkey adjustment is the human-readable `accountName` falling back to
   the login id when `user.email` is `Nothing`.
6. **HTTP backward compatibility** (servant test): an email-only signup yields a `loginId`
   equal to the email text; an identifier-only signup yields `email == null`.

Run `cabal test all` at the end; a fully green run across `shomei-core-test`,
`shomei-postgres-test`, and `shomei-servant-test` is the overall acceptance.


## Idempotence and Recovery

The Haskell edits are ordinary source changes; re-running `cabal build`/`cabal test` is always
safe. The migrations are written to be idempotent and re-runnable: every `ADD COLUMN` uses `IF
NOT EXISTS`, every index uses `CREATE UNIQUE INDEX IF NOT EXISTS`, every constraint drop uses
`DROP CONSTRAINT IF EXISTS`, and the backfill `UPDATE ... WHERE login_id IS NULL` only touches
rows not yet backfilled, so applying the set twice changes nothing.

If a migration fails midway, codd runs each file `in-txn` (per the `-- codd: in-txn` header),
so a failing file rolls back atomically; fix the SQL and re-apply. The expand/contract ordering
means even a partial application leaves the database usable: after Migration A but before B,
`email` is still `NOT NULL UNIQUE` (old code still works) and `login_id` exists and is unique
(new code can begin using it). Only Migration B/D relax email, and they are independent of A/C
beyond ordering.

If you need to back out before consumers depend on the new column, the reverse is: drop the
partial email index and restore the inline unique (recreate `shomei_users_email_key`),
re-`SET NOT NULL` on email (only possible if no NULL emails were inserted), and drop the
`login_id` index and column. Prefer forward fixes over rollback once the change is merged.


## Interfaces and Dependencies

Libraries and modules used (all already present in the repo; no new external dependency):
`effectful` (the effects), `hasql` (PostgreSQL interpreters), `codd` + `ephemeral-pg`
(migrations and the ephemeral test database, pinned in
`/Users/shinzui/Keikaku/bokuno/shomei/cabal.project`), `mmzk-typeid` (the `KindID` identifiers
in `Shomei.Id`), `servant`/`aeson` (the wire layer), and `tasty`/`hspec`-style HUnit cases for
tests.

Types and signatures that must exist at the end of each milestone:

- End of M1:
  - `Shomei.Domain.LoginId.LoginId` (abstract), `mkLoginId :: Text -> Either AuthError LoginId`,
    `loginIdText :: LoginId -> Text`, `loginIdFromEmail :: Email -> LoginId`.
  - `Shomei.Domain.User.User` and `NewUser` with `loginId :: LoginId` and `email :: Maybe Email`.
  - `Shomei.Domain.Credential.Credential` with `loginId :: LoginId` and `email :: Maybe Email`.
  - `Shomei.Error.AuthError` gains `InvalidLoginId` and `LoginIdAlreadyRegistered`.
- End of M2:
  - `Shomei.Effect.UserStore`: `FindUserByLoginId :: LoginId -> UserStore m (Maybe User)` +
    `findUserByLoginId`; existing `FindUserByEmail`/`findUserByEmail` retained.
  - `Shomei.Effect.CredentialStore`: `CreatePasswordCredential :: UserId -> LoginId -> Maybe
    Email -> PasswordHash -> CredentialStore m Credential`; `FindPasswordCredentialByLoginId ::
    LoginId -> CredentialStore m (Maybe Credential)` + wrapper; `FindPasswordCredentialByEmail`
    retained.
  - `Shomei.Domain.Command.SignupCommand`/`LoginCommand` carry `loginId :: LoginId` and (signup)
    `email :: Maybe Email`.
  - `Shomei.Workflow.signup`/`login` key on `LoginId`; `Workflow.Account` reset/verify guard on
    `Maybe Email`.
- End of M3:
  - `Shomei.Postgres.UserStore.runUserStorePostgres` and
    `Shomei.Postgres.CredentialStore.runCredentialStorePostgres` interpret the new effects against
    a schema with `login_id text NOT NULL UNIQUE` and `email text NULL` (partial-unique).
  - Four new migration files under `shomei-migrations/sql-migrations/`.
- End of M4:
  - `Shomei.Servant.DTO.SignupRequest`/`LoginRequest` with optional `loginId`/`email`;
    `UserResponse` with `loginId :: Text` and `email :: Maybe Text`; `userToResponse` updated.
  - Handlers resolve `LoginId` (explicit, or default-from-email) and key the abuse `accountKey`
    on the login id.

Consumers of this plan's output (for reference only; do not edit them here): auth-service-v2
**EP-2** at `/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/3-...` (TAN
identity + data model, which maps TAN's `username` onto this `LoginId` and treats email as
optional) and **EP-8** at
`/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/9-...` (passkeys, which relies
on the user-handle remaining user-id-derived and therefore unaffected). The master brief for
the consuming initiative is
`/Users/shinzui/Keikaku/work/microtan/auth-service/docs/masterplans/1-rewrite-auth-service-on-shomei-auth-service-v2.md`.


## Revision Notes

- 2026-06-17: Initial authoring of SH-25. Replaced the skeleton body with a full, self-contained
  ExecPlan after reading the real shomei source (`Domain/User.hs`, `Credential.hs`,
  `Password.hs`, `Passkey.hs`, `Email.hs`; `Workflow.hs` and `Workflow/Account.hs`;
  `Effect/UserStore.hs`, `CredentialStore.hs`, `InMemory.hs`; `Domain/Command.hs`;
  `Postgres/UserStore.hs`, `CredentialStore.hs`; the `shomei_users`/`shomei_password_credentials`
  migrations; and `Servant/DTO.hs`/`Handlers.hs`). The design (a `LoginId` principal with
  optional `Email`, expand/contract migration, retained lookup-by-email for reset) and the
  rejected alternatives (bare `Text`; reusing `Email`; in-place destructive `ALTER`) are
  recorded in the Decision Log. Reason: deliver the SH-25 prerequisite consumed by
  auth-service-v2 EP-2 and EP-8.
- 2026-06-17 (validation pass): Validated every factual claim against the live shomei tree (see
  the new Surprises & Discoveries entries). All file paths, record fields, effect signatures,
  workflow behaviors, migrations, postgres decoders, servant DTOs/handlers, and test harness
  details were confirmed accurate. Two refinements applied: (1) the in-memory interpreter keys
  credentials in a `Map Email Credential` (`credsByEmail`), so M1/M2 now spell out re-keying that
  map to `LoginId` rather than implying a one-line comparison change; (2) clarified that the
  domain type is `Credential` with constructor `PasswordCredential`, and that `failLogin` currently
  carries an `Email`. No milestone structure changed; the plan fits the project.
