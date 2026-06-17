---
id: 3
slug: webauthn-passkey-multi-factor-authentication
title: "WebAuthn Passkey Multi-Factor Authentication"
kind: master-plan
created_at: 2026-06-17T14:35:30Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
---

# WebAuthn Passkey Multi-Factor Authentication

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Precondition: MasterPlans 1 and 2 must be substantially complete

This initiative builds on the working, hardened auth service delivered by
`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md` (the runnable vertical
slice) and `docs/masterplans/2-production-hardening-account-lifecycle-and-adoption.md`
(account lifecycle, abuse protection, observability, CLI, packaging, docs). Every child
plan here assumes that, as of the current `master` branch, `cabal build all` and `cabal
test all` are green and that `shomei-server` boots against PostgreSQL and serves the
`ShomeiAPI` (`POST /auth/signup`, `/auth/login`, `/auth/refresh`, `/auth/logout`, the
account-lifecycle routes, `GET /auth/me`, `/auth/session`, `GET /.well-known/jwks.json`,
`GET /health`, `/ready`, `/metrics`), signs/verifies ES256 JWTs, and publishes JWKS.

MFA was **explicitly out of scope** in both prior MasterPlans (see MasterPlan 2 Vision &
Scope, which lists "passkeys/WebAuthn, MFA" among the deferred items). This MasterPlan
removes that deferral and delivers it. Because the dependency on the prior MasterPlans is
global and identical for every child plan, it is stated once here. The Hard Deps / Soft
Deps columns in the Exec-Plan Registry below refer only to dependencies *within this*
MasterPlan.


## Vision & Scope

Today a Shōmei-protected application authenticates a user with exactly one factor: an
email and password (`POST /auth/login`). After this initiative, an account can be
protected by a **passkey** — a public-key credential created by a hardware security key
(YubiKey), a platform authenticator (Touch ID, Windows Hello, Android), or a synced
passkey provider (iCloud Keychain, 1Password) — used as a **second authentication factor**
on top of the password, with a passwordless path available as a natural extension.

Concretely, after this initiative:

- An authenticated end user can **enroll one or more passkeys** on their account. The
  browser runs the WebAuthn registration ceremony (`navigator.credentials.create()`); the
  server verifies the resulting attestation and stores the credential's public key. The
  user can **list** their enrolled passkeys and **remove** one. This is the new
  `POST /auth/passkeys/register/begin` → `…/register/complete` flow plus
  `GET /auth/passkeys` and `DELETE /auth/passkeys/{id}`.

- When a user who has at least one passkey enrolled logs in with email + password, the
  server no longer returns tokens immediately. Instead it returns an **MFA challenge**: a
  short-lived pending-MFA token plus the WebAuthn authentication options. The browser runs
  the assertion ceremony (`navigator.credentials.get()`) and posts the result to
  `POST /auth/mfa/complete`; only then does the server issue the access/refresh token
  pair. This is the headline multi-factor behavior: possession of the password alone no
  longer grants a session.

- An operator can configure the Relying Party identity (the `rpId` domain, the allowed
  `origin`(s), the human-readable RP name, user-verification and attestation policy) and
  whether MFA is **required** for accounts that have a passkey, through new typed fields on
  `ShomeiConfig` loaded the same Dhall/env way as every other setting.

- A developer adopting Shōmei can read a new `docs/passkeys.md` guide (and additions to
  `docs/api.md`/`docs/security.md`), use the new typed `shomei-client` functions, and see a
  working passkey enrollment + step-up login in the embedded demo app.

To see it working end to end: enroll a passkey while authenticated, log out, log in with
email + password and observe the `mfa_required` response, complete the WebAuthn assertion,
and receive a token pair — then verify that logging in *without* completing the assertion
yields no usable token.

**In scope.** Server-side (Relying Party) WebAuthn 2 registration and authentication
ceremonies via the `tweag/webauthn` Haskell library (`webauthn 0.11.0.0`); a new
`shomei-webauthn` package interpreting a transport-agnostic ceremony port; passkey and
pending-ceremony persistence (PostgreSQL + in-memory) with new codd migrations; the
enrollment and passkey-management HTTP surface; the password-then-passkey **MFA step-up**
login flow and a **passwordless passkey login** path; a `webauthnConfig` sub-record on
`ShomeiConfig` and its loader wiring; new audit events; typed client functions; a demo
update; and documentation.

**Explicitly out of scope (deferred).** TOTP/authenticator-app codes, SMS/email one-time
codes, and recovery/backup codes (this initiative delivers *passkeys* as the second factor,
per the scoping decision; other factors remain future work). The FIDO Metadata Service
(MDS) trust pipeline for enterprise attestation policy — the interpreter is built to accept
an empty/`mempty` metadata registry and a permissive attestation preference suitable for
consumer passkeys, with the MDS hook noted as a future extension. Account-recovery policy
when a user loses their only passkey (beyond the existing password-reset flow, which still
works because the password remains the first factor). Cross-device/hybrid transport
specifics beyond what the browser and library handle. An admin UI. Per-credential
risk/anomaly scoring. Distributed pending-ceremony state beyond a single PostgreSQL-backed
instance (the challenge store is PostgreSQL-backed, sufficient for the single-instance
deployment Shōmei targets).

This plan **does** change the existing `Shomei.Workflow.login` contract (prior MasterPlans
deliberately did not): `login` gains a result that is either "completed with a token pair"
(unchanged for accounts with no passkey) or "MFA required with a challenge." The change is
additive in behavior — an account with no enrolled passkey logs in exactly as before — but
it widens the workflow's return type and the `LoginResponse` DTO, which is an integration
point (IP-8) every caller must handle.


## Decomposition Strategy

The initiative is decomposed by **functional concern**, respecting Shōmei's hexagonal
layering: the transport-agnostic core (`shomei-core`) defines domain types, ports (effect
interfaces), and workflows with **no infrastructure dependencies**; infrastructure packages
(`shomei-jwt`, `shomei-postgres`, and the new `shomei-webauthn`) interpret those ports
against real libraries; `shomei-servant` exposes HTTP routes/handlers/DTOs; `shomei-server`
assembles everything; `shomei-client`/`docs` deliver adoption. The single hardest problem
is keeping the heavy `webauthn` library (it pulls in `crypton-x509`, `cborg`, `serialise`)
**out of the core** while still letting core workflows orchestrate the ceremonies — solved
by a `Value`-boundary port (IP-1) so the core never names a WebAuthn library type.

Five child plans are grouped into five implementation phases (phases 3 and 4 overlap):

- **Phase 1 — Foundation.** EP-1 (plan 15) introduces the `WebAuthnCeremony` port in
  `shomei-core` (whose operations cross the boundary as aeson `Value`s plus Shōmei domain
  result types, so core takes no `webauthn` dependency), the `webauthnConfig` sub-record on
  `ShomeiConfig`, and the new `shomei-webauthn` package that interprets the port against
  `webauthn 0.11.0.0`. Because the library is tested with GHC 9.10.3 and Shōmei builds with
  GHC 9.12.4, EP-1 includes a **prototyping milestone** that proves the dependency builds in
  `nix develop` (adding any `allow-newer`) and that a full register→authenticate ceremony
  verifies through the interpreter, including the strategy for serializing the pending
  `CredentialOptions` for later persistence. It is first because every other plan needs the
  ceremony port and the package.

- **Phase 2 — Persistence.** EP-2 (plan 16) introduces the two storage ports —
  `PasskeyStore` (the registered public-key credentials) and `PendingCeremonyStore` (the
  short-lived challenge/options state, consumed once) — in `shomei-core`, their PostgreSQL
  interpreters in `shomei-postgres`, their in-memory interpreters in
  `Shomei.Effect.InMemory`, and two new codd migrations. It hard-depends on EP-1 only for
  the shared domain types (`PasskeyCredential` and friends) that EP-1 defines; it is a
  separate plan because persistence is an independently verifiable behavior (insert a
  credential, query it by user and by credential id, consume a pending ceremony exactly
  once) and it owns the migration and effect-stack-extension conventions the workflow plans
  reuse.

- **Phase 3 — Enrollment.** EP-3 (plan 17) delivers the authenticated passkey-management
  surface: the core enrollment workflow (begin/complete registration), the routes
  `POST /auth/passkeys/register/begin`, `POST /auth/passkeys/register/complete`,
  `GET /auth/passkeys`, `DELETE /auth/passkeys/{id}`, their DTOs and handlers, server
  assembly of the new interpreters, and the `PasskeyRegistered`/`PasskeyRemoved` audit
  events. It hard-depends on EP-1 (ceremony port) and EP-2 (stores).

- **Phase 4 — Authentication (the MFA step-up).** EP-4 (plan 18) delivers the multi-factor
  login: it widens `Shomei.Workflow.login` to return `LoginComplete` or `MfaRequired`,
  adds the pending-MFA token, the `POST /auth/mfa/begin`/`POST /auth/mfa/complete` step-up
  endpoints and a passwordless `POST /auth/login/passkey/begin`/`…/complete` path, the
  `mfaRequired` enforcement policy, the widened `LoginResponse` DTO, and the
  `MfaChallenged`/`MfaSucceeded`/`MfaFailed` events. It hard-depends on EP-1 and EP-2 and
  soft-depends on EP-3 (it needs enrolled passkeys to demonstrate end to end; tests can seed
  credentials directly through EP-2's store, so it does not *block* on EP-3). Phases 3 and 4
  can therefore proceed in parallel once EP-2 lands.

- **Phase 5 — Adoption.** EP-5 (plan 19) adds the typed `shomei-client` passkey functions,
  a passkey flow in the embedded demo (including the small browser-side JavaScript that
  calls `navigator.credentials`), `docs/passkeys.md`, and the `docs/api.md`/`docs/security.md`
  additions. It soft-depends on every other plan because it documents and exercises their
  finished surface; it is finalized last.

Alternatives considered. **One mega-plan** was rejected: the work spans a new package with a
heavy external dependency, two persistence tables, two distinct HTTP ceremonies, and a
breaking change to the login contract — far past the single-ExecPlan size guidance, and the
ceremony/verification foundation must be proven before the workflows are worth building.
**Folding persistence (EP-2) into the foundation (EP-1)** was rejected because the
verification interpreter needs no database (verification is pure), so keeping the
`webauthn`-dependent package free of PostgreSQL coupling is cleaner and lets EP-1's spike
run without a database. **Merging enrollment (EP-3) and authentication (EP-4)** was rejected
because registration and assertion are distinct ceremonies with separate endpoints and
separate acceptance ("I can enroll a passkey" vs "I am challenged for it at login"), and
splitting them lets enrollment land first and the two HTTP surfaces be built in parallel.
**Putting the ceremony logic in `shomei-core`** was rejected outright: it would drag
`crypton-x509`/`cborg`/`serialise` into the transport-agnostic core, violating the
invariant that core has no infrastructure dependencies (mirroring how JWT lives in
`shomei-jwt`, not core). **Holding pending-ceremony state in an in-process `TVar`** (as the
library's example server does) was rejected for the server in favor of a PostgreSQL-backed
`PendingCeremonyStore`, consistent with Shōmei's discipline of backing security state with
the database; the in-memory interpreter remains for tests.


## Exec-Plan Registry

Every plan below additionally requires **MasterPlans 1 and 2 to be substantially complete**
(see Precondition above); that global dependency is omitted from the columns, which list
only intra-MasterPlan-3 dependencies.

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | WebAuthn ceremony port and `shomei-webauthn` interpreter package | docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md | None | None | Complete |
| 2 | Passkey and pending-ceremony persistence | docs/plans/16-passkey-and-pending-ceremony-persistence.md | EP-1 | None | In Progress |
| 3 | Passkey enrollment workflow and management API | docs/plans/17-passkey-enrollment-workflow-and-management-api.md | EP-1, EP-2 | None | Not Started |
| 4 | Passkey login: MFA step-up and passwordless | docs/plans/18-passkey-login-mfa-step-up-and-passwordless.md | EP-1, EP-2 | EP-3 | Not Started |
| 5 | Client, demo, and documentation | docs/plans/19-passkey-client-demo-and-documentation.md | None | EP-1, EP-2, EP-3, EP-4 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The hard ordering inside this MasterPlan is rooted at **EP-1**, which every other plan
needs because it defines the `WebAuthnCeremony` port (IP-1), the `webauthnConfig` config
sub-record (IP-3), and the `shomei-webauthn` package (IP-7) plus the shared passkey domain
types that EP-2's storage ports persist.

EP-2 hard-depends on EP-1 for those shared domain types (`PasskeyCredential`,
`PendingCeremony`, the WebAuthn id newtypes). EP-2 then defines the two storage ports and
their interpreters and owns the migration convention (IP-5) and the effect-stack-extension
convention (IP-6).

EP-3 (enrollment) and EP-4 (authentication) both hard-depend on EP-1 (ceremony port) and
EP-2 (stores), and are otherwise **independent of each other** — they add disjoint routes
(passkey management vs MFA/login) and disjoint workflows. They can be built in **parallel**
once EP-2 lands. EP-4 soft-depends on EP-3 only so an operator can enroll a passkey before
being challenged for it; EP-4's automated tests seed credentials directly through EP-2's
`PasskeyStore`, so EP-4 is not blocked by EP-3.

EP-5 (client/demo/docs) soft-depends on all four: it documents and exercises their finished
behavior. It carries no hard dependency, so a first draft can start early, but it is
finalized last so the client functions match the real routes, `docs/api.md` lists the real
endpoints, and `docs/passkeys.md` describes the real ceremony and config.

Parallelism summary: EP-1 first (alone). Then EP-2. Then EP-3 and EP-4 in parallel. EP-5
finalized last.


## Integration Points

**IP-1 — `WebAuthnCeremony` port (the ceremony/verification effect).** A new dynamic
`effectful` effect in `shomei-core/src/Shomei/Effect/WebAuthnCeremony.hs`. Its operations
cross the package boundary using only **aeson `Value`** (already a core dependency) and
Shōmei domain types, so `shomei-core` never imports a `webauthn` library type. The intended
shape (EP-1 owns the exact signatures and records them here as it lands):

- `beginRegistration :: CredentialUserInfo -> Eff es PendingRegistration` — given the user
  to register for, produce the browser-facing options JSON (`Value`) plus the data to
  persist (a serialized options/challenge blob). `PendingRegistration` is a Shōmei domain
  record carrying the options `Value`, the opaque persisted blob (`Text`/`ByteString`), the
  challenge, and an expiry.
- `completeRegistration :: PersistedCeremonyBlob -> Value -> Eff es (Either WebAuthnError NewPasskeyCredential)`
  — given the persisted options blob and the browser's credential JSON, verify the
  registration and return a Shōmei `NewPasskeyCredential` (credential id, user handle,
  public-key bytes, initial sign counter, transports) or a `WebAuthnError`.
- `beginAuthentication :: [PasskeyCredentialRef] -> Eff es PendingAuthentication` — given the
  user's known credentials (or none, for passwordless discovery), produce the
  authentication options JSON plus the persisted blob.
- `completeAuthentication :: PersistedCeremonyBlob -> StoredPasskey -> Value -> Eff es (Either WebAuthnError VerifiedAssertion)`
  — verify the assertion against a stored credential and return the verified user handle and
  the new signature counter (or a "potentially cloned" signal) or a `WebAuthnError`.

Owner: **EP-1**, which defines the effect, the Shōmei domain types it returns, and the
`shomei-webauthn` interpreter (`runWebAuthnCeremony…`) that maps to/from the library's
`CredentialOptions`/`Credential`/`CredentialEntry` and calls
`wjEncodeCredentialOptions*`/`wjDecodeCredential*` and
`verifyRegistrationResponse`/`verifyAuthenticationResponse`. Consumers: EP-3 (registration
ops) and EP-4 (authentication ops). Rule: the effect signature is owned by EP-1; EP-3/EP-4
must not change it without a Decision Log entry here. The interpreter closes over the RP
configuration from IP-3.

**IP-2 — `PasskeyStore` and `PendingCeremonyStore` ports.** Two new dynamic `effectful`
effects in `shomei-core/src/Shomei/Effect/`. `PasskeyStore` persists the registered
public-key credentials: create a credential, list a user's credentials, find one by its
WebAuthn credential id, update its signature counter, delete one by Shōmei id, and (for
the login path) find credentials by the user handle. `PendingCeremonyStore` persists the
short-lived challenge/options blob keyed by a ceremony id or challenge, with a **consume-once**
take operation and TTL expiry. Owner: **EP-2**, which defines both effects, their in-memory
interpreters (extending `Shomei.Effect.InMemory.World`), and their PostgreSQL interpreters.
The stored shapes mirror the library's `CredentialEntry` (credential id bytes, user handle
bytes, public-key bytes, signature counter `Word32`, transports) plus Shōmei metadata
(`PasskeyId`, `UserId`, label, created/last-used timestamps). Consumers: EP-3 and EP-4.
Rule: signatures owned by EP-2; later plans extend only with a Decision Log entry here.

**IP-3 — `ShomeiConfig` extension (shared, append-only).** `ShomeiConfig` lives in
`shomei-core/src/Shomei/Config.hs`. **EP-1** adds a `webauthnConfig :: WebAuthnConfig`
sub-record (and extends `defaultShomeiConfig`) carrying the Relying Party identity and
ceremony policy: `rpId` (the scope domain, e.g. `auth.example.com`), `rpName` (human label),
`origins` (the allowed `Origin`s, e.g. `https://auth.example.com`), `userVerification`
(required/preferred/discouraged), `attestation` preference, `timeout`, the pending-ceremony
TTL, and `mfaRequired` (whether accounts that have a passkey MUST complete MFA at login).
Mirroring MasterPlan 2's IP-3: the field carries a default so older config files still parse,
and no plan rewrites another's field. EP-5/the server config loader reads it. EP-4 reads
`mfaRequired`; the `shomei-webauthn` interpreter (EP-1) reads the RP identity fields.

**IP-4 — `ShomeiAPI` route additions.** The Servant `ShomeiAPI` `NamedRoutes` record in
`shomei-servant/src/Shomei/Servant/API.hs` is extended: **EP-3** adds the authenticated
passkey-management routes (`POST /auth/passkeys/register/begin`,
`POST /auth/passkeys/register/complete`, `GET /auth/passkeys`,
`DELETE /auth/passkeys/{id}`); **EP-4** adds `POST /auth/mfa/complete` and the passwordless
`POST /auth/login/passkey/begin`, `POST /auth/login/passkey/complete`, and widens the
`login` response. EP-4 deliberately does **not** add `/auth/mfa/begin`: the WebAuthn
authentication challenge is returned by `POST /auth/login` itself (the `mfa_required` arm of
the widened response carries `ceremonyId` + `options`), so the client only needs `…/mfa/complete`
to finish the step-up. Owner of the record:
`shomei-servant`. Rule: each plan adds its routes and corresponding handlers/DTOs; neither
removes the other's; request/response DTOs follow the existing `SignupRequest`/`LoginRequest`
JSON conventions in `Shomei.Servant.DTO`. The ceremony begin/complete bodies carry the
WebAuthn JSON `Value` produced/consumed by IP-1 verbatim (the browser's `webauthn-json`
payloads).

**IP-5 — codd migrations and the `shomei` schema.** New PostgreSQL tables under
`shomei-migrations/sql-migrations/` following the timestamped naming convention
(`YYYY-MM-DD-HH-MM-SS-<name>.sql`). **EP-2** adds `shomei_webauthn_credentials` (the
registered passkeys) and `shomei_webauthn_pending_ceremonies` (the consumed-once challenge
state). Rule, mirroring MasterPlan 2's IP-7: migrations are immutable and append-only — no
plan edits another's applied migration; new tables live in the `shomei` schema and use
native `uuid` identifier columns, `bytea` for the credential-id/public-key/user-handle
bytes, `text` status/enum columns, and `timestamptz` timestamps. Choose timestamps strictly
later than the existing `2026-06-05-*` files. **Reminder (MasterPlan 2 discovery):** adding
`.sql` files is not enough for the embedded migration list to refresh — a source change to
`shomei-migrations/src/Shomei/Migrations.hs` is required to force the `embedDir` Template
Haskell splice to re-run; verify the embedded count grows before trusting tests.

**IP-6 — the shared effect-stack lists.** The new ports must be appended to every list/chain
that enumerates the Shōmei port stack, mirroring how MasterPlan 2's IP-9 added
`AuthEventReader`: `Shomei.Servant.Seam.AppEffects` (servant stack), `Shomei.Server.App.AppEffects`
and its `runAppIO` interpreter chain (server stack), `Shomei.Effect.InMemory.runInMemory`
(test stack), and the `shomei-postgres` test `AppEffects`. **EP-1** adds `WebAuthnCeremony`;
**EP-2** adds `PasskeyStore` and `PendingCeremonyStore`. **Rule: each plan adds exactly its
new entries plus their interpreters to each such list/chain, in the same relative position
across all lists, and must not reorder or remove existing entries.** The server's `runAppIO`
interprets the `WebAuthnCeremony` via the new `shomei-webauthn` interpreter (closing over the
`webauthnConfig` RP identity and `Clock`), and the two stores via their PostgreSQL
interpreters; the in-memory stack uses the in-memory interpreters.

**IP-7 — `cabal.project`, `mori.dhall`, and the new dependency.** The new `shomei-webauthn`
package is registered: a top-level `shomei-webauthn/` directory with its `.cabal` file added
to `cabal.project`, and a package entry added to `mori.dhall` (as MasterPlan 1 EP-3 did for
`shomei-migrations`, depending on `shomei-core`). The `webauthn` dependency
(`webauthn 0.11.0.0`, registered in `mori` as `tweag/webauthn` at
`/Users/shinzui/Keikaku/hub/haskell/webauthn-project`) is added in EP-1's own
`cabal.project` block; because it is tested with GHC 9.10.3 and Shōmei uses GHC 9.12.4, EP-1
must verify it builds in `nix develop` and add any required `allow-newer`/source-repository
entry in its own block. The library transitively needs `crypton-x509*`, `cborg`,
`serialise`, and `base16`/`base64-bytestring` — already compatible with Shōmei's existing
`crypton` usage. Rule (MasterPlan 1/2): no Shōmei package may depend on the deprecated
`memory` package (use `ram`).

**IP-8 — the `login` workflow contract change.** `Shomei.Workflow.login` currently returns
`Eff es (Either AuthError (User, TokenPair))`. **EP-4** widens the success arm to a sum
(final shape, as authored): `data LoginResult = LoginComplete User TokenPair | MfaRequired
MfaChallenge` where `data MfaChallenge = MfaChallenge { ceremonyId :: CeremonyId, options ::
Value }`. The `CeremonyId` is itself the "pending-MFA token" — it references the
authentication `PendingCeremony` row (which is bound to the user via `PendingCeremony.userId`),
so completing `POST /auth/mfa/complete { ceremonyId, assertion }` issues tokens for that user.
This is **breaking to the type but additive to behavior**: an account with no enrolled passkey
(or with `mfaRequired = False`) yields `LoginComplete` exactly as today. The HTTP `LoginResponse`
DTO becomes a `status`-tagged JSON sum: `{ "status":"complete", "user":…, "token":… }` or
`{ "status":"mfa_required", "ceremonyId":…, "options":… }`. Owner: **EP-4**. Every caller is
updated in EP-4 except the client: `Shomei.Servant.Handlers.loginH`, the `LoginResponse` DTO
(IP-4), and the workflow tests in EP-4; the `shomei-client` `login` return type changes in
**EP-5**. Rule: EP-4 owns this shape; EP-5's client and docs must match it.


## Progress

Milestone-level tracking across all child plans. Updated as each plan's milestones land.

- [x] EP-1: `webauthn 0.11.0.0` builds in `nix develop` on GHC 9.12.4 (patched fork `shinzui/webauthn-project` @ `a8b5636`, pinned as a source-repository-package; `allow-newer: webauthn:*`); a register→authenticate ceremony verifies (the fork's own emulation test, real ECDSA, 100 cases), and the pending-options WJ-JSON serialization round-trips (100 cases) — 2026-06-17
- [x] EP-1: `WebAuthnCeremony` port in `shomei-core` (Value-boundary) + Shōmei result domain types; `webauthnConfig` sub-record on `ShomeiConfig`; deterministic fake interpreter + core unit test; port slotted into all effect-stack lists (server uses a temporary stub until M2) — `cabal build all`/`test all` green — 2026-06-17
- [x] EP-1: `shomei-webauthn` package interprets the port against the library; registered in `cabal.project` + `mori.dhall`; wired into the server's `runAppIO`; `cabal build all`/`cabal test all` green (11 suites); `mori show --full` lists it — 2026-06-17
- [ ] EP-2: `PasskeyStore` + `PendingCeremonyStore` ports + in-memory interpreters (extended `World`); two codd migrations applied (embedded count grows)
- [ ] EP-2: PostgreSQL interpreters for both stores; integration test inserts/queries a passkey and consumes a pending ceremony exactly once
- [ ] EP-3: enrollment workflow (begin/complete registration) passes pure in-memory tests; `PasskeyRegistered`/`PasskeyRemoved` events
- [ ] EP-3: `POST /auth/passkeys/register/{begin,complete}`, `GET /auth/passkeys`, `DELETE /auth/passkeys/{id}` routes + handlers + server wiring; in-process HTTP test enrolls/lists/deletes a passkey
- [ ] EP-4: `login` widened to `LoginComplete`/`MfaRequired`; pending-MFA token; `mfaRequired` policy; pure step-up tests
- [ ] EP-4: `POST /auth/mfa/{begin,complete}` and passwordless `POST /auth/login/passkey/{begin,complete}`; `MfaChallenged`/`MfaSucceeded`/`MfaFailed` events; HTTP test proves password-only yields no usable token
- [ ] EP-5: typed `shomei-client` passkey functions; embedded-demo passkey flow with browser JS
- [ ] EP-5: `docs/passkeys.md` + `docs/api.md`/`docs/security.md` additions, grounded in the finished EP-1..EP-4 surface


## Surprises & Discoveries

Cross-plan insights, dependency changes, and scope adjustments discovered during
implementation. Provide concise evidence.

The following were surfaced while authoring the child plans (2026-06-17), before any
implementation, by reading the real `shomei-core`/`shomei-postgres`/`shomei-servant` source
and the `tweag/webauthn` library (`webauthn 0.11.0.0`). They are recorded here because they
cross plan boundaries.

- **The core must not import `webauthn`.** The library defines `CredentialOptions`,
  `Credential`, and `CredentialEntry` and pulls in `crypton-x509`/`cborg`/`serialise`.
  Shōmei's core is transport- and infrastructure-agnostic (mirroring how JWT lives in
  `shomei-jwt`, not core). The resolution is IP-1: the `WebAuthnCeremony` port crosses the
  boundary as aeson `Value` (browser-facing JSON, already a core dependency) plus Shōmei
  domain result types, and the new `shomei-webauthn` package owns all library types. This is
  the central design constraint shaping EP-1.

- **GHC version skew is a real risk.** `webauthn 0.11.0.0`'s cabal declares `tested-with: GHC
  == 9.10.3`; Shōmei builds with GHC 9.12.4. EP-1's first milestone is a build/verification
  spike precisely to surface any `allow-newer` or bound bumps before downstream plans depend
  on the package. If the library does not build on 9.12.4 even with `allow-newer`, EP-1's
  Decision Log must record the fallback (a `source-repository-package` pin or a patch), and
  the MasterPlan must be revised.

- **Pending-ceremony state needs serialization for PostgreSQL.** The library's example server
  holds the entire `CredentialOptions` in an in-process `TVar` keyed by an expiry-encoding
  challenge (`server/src/PendingCeremonies.hs`). Shōmei backs security state with PostgreSQL
  (`PendingCeremonyStore`, IP-2/IP-5), so EP-1 must establish a serialization for the options
  blob that round-trips through the interpreter (the `verify*` functions need only a subset
  of the options, primarily the challenge and the user/credential context). EP-1's spike
  validates the chosen serialization; EP-2 persists the resulting opaque blob.

- **The `login` contract change is unavoidable and breaks the type (not the behavior).**
  Unlike MasterPlans 1 and 2, which preserved `login`'s `(User, TokenPair)` result, EP-4 must
  widen it (IP-8) so a password success can yield an MFA challenge instead of tokens. Every
  `login` caller (`loginH`, the `LoginResponse` DTO, the `shomei-client`, the workflow tests)
  is updated in EP-4/EP-5. Accounts without a passkey are unaffected at runtime.

- **Migration embedding requires a source rebuild (carried over from MasterPlan 2).** Adding
  `.sql` files under `shomei-migrations/sql-migrations/` does not refresh the embedded
  migration list until `shomei-migrations/src/Shomei/Migrations.hs` is touched to force the
  `embedDir` Template Haskell splice to re-run. EP-2 must do this and confirm the embedded
  count grows before trusting tests or `just migrate` (EP-2 expects the count to rise from 12
  to 14).

The following were surfaced while authoring the child plans (2026-06-17) and lock in
decisions that cross plan boundaries:

- **`webauthn 0.11.0.0`'s dependency bounds may fight Shōmei's set — this is EP-1's headline
  risk.** Reading `webauthn.cabal` shows it constrains `crypton < 1.1` and `jose < 0.12` and
  depends on the deprecated `memory` package, whereas Shōmei standardizes on `ram` (not
  `memory`, per MasterPlans 1/2) and may resolve a different `crypton`/`jose`. EP-1's M0 spike
  exists precisely to surface the `allow-newer` (and possibly a `source-repository-package`
  pin or a patch to drop the `memory` edge) needed to build the library on GHC 9.12.4. If it
  cannot be made to build, EP-1's Decision Log records the fallback and this MasterPlan must be
  revised. **No downstream plan should be started until EP-1 M0 is green.**

- **Pending options are serialized as the WebAuthn-JSON encoding of the `CredentialOptions`.**
  EP-1 chose to store `optionsBlob` as the JSON bytes produced by the library's
  WebAuthn-JSON options encoder and to recover the `CredentialOptions` at complete-time via the
  library's exposed-internal decode (no public decode-of-options exists). EP-2 persists this
  opaque blob in `shomei_webauthn_pending_ceremonies.options_blob` (`bytea`). The round-trip is
  validated in EP-1's M0 spike before EP-2 depends on it.

- **A potentially-cloned signature counter fails closed by default.** EP-1 maps the library's
  `SignatureCounterPotentiallyCloned` result to `Left WebAuthnCounterCloned` (reject the
  assertion) rather than a soft warning, matching the library example's abort-on-clone posture.
  EP-4's `completeMfa`/passwordless paths therefore deny login on a clone signal and publish
  `MfaFailed`.

- **`/auth/mfa/begin` is intentionally absent; the challenge rides in the login response.** EP-4
  returns the WebAuthn authentication options inside the `mfa_required` arm of the widened
  `POST /auth/login` response (a `status`-tagged JSON sum), so the only new step-up endpoint is
  `POST /auth/mfa/complete`. The `CeremonyId` doubles as the pending-MFA token. (IP-4, IP-8.)

- **The per-user `UserHandle` is derived deterministically from the `UserId`.** EP-3 derives a
  stable WebAuthn user handle from the Shōmei `UserId` bytes (rather than the library's random
  `generateUserHandle`) so that all of a user's passkeys share one handle and EP-4's
  passwordless discovery can resolve the account from a discoverable credential's user handle.

- **Authoring order note (consistency).** EP-5 (client/demo/docs) was drafted in parallel with
  EP-4 and read plan 18 while it was still a skeleton, so it sourced the MFA/login wire shape
  from this MasterPlan's IP-4/IP-8 and flagged a reconciliation in its Decision Log. A
  post-authoring cross-check confirmed the route names (`/auth/mfa/complete`,
  `/auth/login/passkey/{begin,complete}`) and the `status:"complete"|"mfa_required"` response
  shape match between EP-4 and EP-5; the implementer of EP-5 should still re-verify field names
  against EP-4 as merged.


Discoveries during EP-1 implementation (2026-06-17) that affect later plans:

- **The `webauthn` dependency builds on GHC 9.12.4 via a patched fork.** EP-1 pinned
  `shinzui/webauthn-project` @ `a8b56361dc9c359186c88daec065e91a409b39f3` (subdir `webauthn`) in
  `cabal.project` with `allow-newer: webauthn:*`, after four patches (`memory`→`ram`; jose 0.13
  `RequiredProtection` header param; `SignedJWT` annotation; `validation` `toEither`), all in
  deferred MDS/SafetyNet code. EP-2..EP-5 inherit this pin unchanged; the M0 risk flagged above is
  retired.

- **`OverloadedRecordDot`/`HasField` is unreliable for the new records under
  `DuplicateRecordFields`.** `cfg.rpId` (on `WebAuthnConfig`) and `stored.credentialId` (on
  `StoredCredentialForVerify`) fail to resolve `HasField`, even for unique fields, while the plain
  field selectors are generated and importable. **EP-2/EP-3/EP-4 should read the new passkey/config
  records via plain selectors or positional/record destructuring, not `value.field` dot syntax.**

- **base64url helpers live in `Shomei.Domain.Passkey`.** `b64urlEncode :: ByteString -> Text` and
  `b64urlDecode :: Text -> Either String ByteString` (over the `base64` package — note: core uses
  `base64`, NOT `base64-bytestring`) are exported for reuse by EP-2's stores and EP-3/EP-4 DTOs.

- **The port stack is one coupled type; `WebAuthnCeremony` sits immediately after `Notifier`.** It
  is present (in that fixed position) in `Shomei.Effect.InMemory.runInMemory`,
  `Shomei.Servant.Seam.AppEffects` (+ the servant test `runHybrid`), `Shomei.Server.App.AppEffects`
  (+ `runAppIO`, now using the real `runWebAuthnCeremonyLibrary`), and the `shomei-postgres` test
  stack. Per IP-6, **EP-2 inserts `PasskeyStore`/`PendingCeremonyStore` right after
  `LoginAttemptStore` (before `Notifier`/`WebAuthnCeremony`)** so this position is not disturbed.


## Decision Log

- Decision: Author MasterPlan 3 to deliver MFA as **WebAuthn passkeys**, using the
  `tweag/webauthn` Haskell library, scoped to passkeys as a second factor (with a
  passwordless path) and explicitly deferring TOTP, SMS/email OTP, and recovery codes.
  Rationale: The user requested MFA and, when asked which methods, chose
  "WebAuthn / passkeys" with the direction "let's use the webauthn package in Haskell to
  support passkeys." Passkeys are phishing-resistant and the library is already registered in
  `mori` (`tweag/webauthn`, `webauthn 0.11.0.0`), so the dependency-lookup rule is satisfied.
  MFA was explicitly deferred in MasterPlans 1 and 2; this plan removes that deferral.
  Date: 2026-06-17

- Decision: Introduce a new top-level `shomei-webauthn` package that interprets a
  transport-agnostic `WebAuthnCeremony` port, rather than placing WebAuthn logic in
  `shomei-core` or folding it into an existing infrastructure package.
  Rationale: The `webauthn` library is infrastructure (it needs `crypton-x509`, `cborg`,
  `serialise`). Shōmei's core has no infrastructure dependencies; isolating the library in a
  dedicated package mirrors `shomei-jwt` and keeps the dependency contained. The package is
  registered in `mori.dhall` as MasterPlan 1 EP-3 did for `shomei-migrations`. (IP-1, IP-7.)
  Date: 2026-06-17

- Decision: Cross the core/infrastructure boundary in the `WebAuthnCeremony` port using
  aeson `Value` for the browser-facing ceremony payloads plus Shōmei domain result types,
  not the library's own types.
  Rationale: `Value` is already a core dependency (events, claims, config use aeson), the
  browser exchanges `webauthn-json` JSON anyway, and this keeps every `webauthn` type inside
  `shomei-webauthn`. The interpreter does the encode/decode/verify. (IP-1.)
  Date: 2026-06-17

- Decision: Back the pending-ceremony (challenge/options) state with PostgreSQL via a
  `PendingCeremonyStore` port, with an in-memory interpreter for tests — not an in-process
  `TVar` as the library's example server uses.
  Rationale: Shōmei's discipline is to back security state with the database (sessions,
  refresh tokens, lockouts). A PostgreSQL store is consistent and survives restarts; the
  consume-once semantics map cleanly to a `DELETE … RETURNING`. The distributed/multi-instance
  story is out of scope (single-instance deployment target). (IP-2, IP-5.)
  Date: 2026-06-17

- Decision: Deliver passkeys primarily as a **second factor** (password-then-passkey step-up),
  with a passwordless passkey login path as a secondary endpoint, and gate enforcement on a
  `mfaRequired` config toggle plus per-account passkey enrollment.
  Rationale: The request was for MFA, so the headline is step-up. A passwordless path is a
  small additive extension once the authentication ceremony exists and is commonly expected of
  passkeys. Gating on enrollment means accounts without a passkey are unaffected (additive
  behavior), and the toggle lets operators require the second factor where they enroll one.
  (IP-3, IP-8, EP-4.)
  Date: 2026-06-17

- Decision: Decompose into five ExecPlans across five phases (Foundation → Persistence →
  Enrollment ∥ Authentication → Adoption), with EP-3 and EP-4 parallelizable after EP-2.
  Rationale: Boundaries follow functional concern and Shōmei's package layering; each plan is
  an independently demonstrable behavior (a verified ceremony, a persisted credential, an
  enrollment endpoint, an MFA login, a documented client). Alternatives (one mega-plan;
  merging persistence into the foundation; merging enrollment and authentication; core-resident
  ceremony logic; in-process challenge state) were rejected — see Decomposition Strategy.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original vision.

(To be filled during and after implementation.)
