---
id: 1
slug: bootstrap-shomei-authentication-toolkit
title: "Bootstrap Shōmei Authentication Toolkit"
kind: master-plan
created_at: 2026-06-03T23:50:51Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
---


# Bootstrap Shōmei Authentication Toolkit

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Shōmei (証明, "proof / verification") is a Haskell authentication toolkit that can run two
ways from one set of primitives: as a **standalone authentication microservice**
(`shomei-server`) that issues locally-verifiable JWT access tokens and publishes a JWKS
document so downstream services verify tokens without calling back, and as an **embedded
library** that drops password login, sessions, and route protection directly into an
existing Servant application. This initiative bootstraps the entire toolkit from an empty
repository to a working vertical slice.

After the full initiative is complete, a user can: start `shomei-server` against a local
PostgreSQL database; `POST /auth/signup` and `POST /auth/login` with an email and password
and receive a JSON token pair (a signed JWT access token plus an opaque refresh token);
call `POST /auth/refresh` to rotate the refresh token; have a replayed (already-used)
refresh token detected as theft and the whole session revoked; call `POST /auth/logout` to
revoke the session; call `GET /auth/me` and `GET /auth/session` with a Bearer token; fetch
`GET /.well-known/jwks.json`; and run a separate downstream demo service that verifies those
JWTs locally using only the JWKS document. The same handlers can be mounted inside a host
Servant app, and a `RequireRole`/`RequireScope` combinator can guard application routes.

The architecture is **library-first** and **transport-agnostic at the core**. `shomei-core`
defines the domain (types, commands, events, errors), the **ports** as `effectful` effects,
and the auth **workflows** (signup, login, refresh-rotation, logout, verification) written
purely against those effects. Adapters live in separate packages: `shomei-postgres`
(hasql interpreters of the store ports), `shomei-jwt` (JWT signing/verification and JWKS via
the `jose` library), `shomei-migrations` (codd-managed schema), and `shomei-servant`
(Servant combinators, API types, and handlers). `shomei-server` is a thin executable that
assembles the adapters; `shomei-client` and two example apps demonstrate both deployment
modes.

In scope for this bootstrap: user registration, email/password login, persisted sessions,
refresh-token rotation with reuse detection, JWT access tokens with asymmetric signing,
JWKS publishing and key rotation, Servant route protection (Bearer plus optional HttpOnly
cookie), PostgreSQL persistence, an audit/security event port with a PostgreSQL
implementation, minimal role/scope authorization primitives, the standalone HTTP API, the
embedded Servant integration, a Haskell client, and the two demo apps.

Explicitly out of scope (deferred, per the spec): OAuth, OIDC, social login, magic links,
passkeys/WebAuthn, MFA, device management, an admin UI, organization/team management, a full
authorization policy engine, risk scoring, and anomaly detection. Event-sourcing the audit
log (e.g. via MessageDB) is also deferred; the bootstrap ships a relational audit table
behind the event port.


## Decomposition Strategy

The initiative is decomposed by **functional concern**, and the boundaries deliberately
follow the package dependency layering the spec mandates (`shomei-core` →
`shomei-jwt`/`shomei-postgres` → `shomei-servant` → `shomei-server` → demos). Each work
stream produces an independently verifiable behavior, and the layering keeps cross-plan
coupling low: the core has no infrastructure dependencies, and each adapter is testable in
isolation before the server stitches them together.

Seven child ExecPlans are grouped into six implementation phases:

- **Phase 1 — Foundation.** EP-1 turns the empty repo into a compiling multi-package cabal
  workspace with the house build conventions (GHC 9.12.4, GHC2024, common cabal stanzas,
  the `Shomei.Prelude` custom prelude, fourmolu/treefmt, and `cabal build all` green inside
  `nix develop`). Nothing else can proceed without this skeleton.

- **Phase 2 — Domain core.** EP-2 fills `shomei-core`: all domain types with smart
  constructors (TypeID identifiers, `Email` normalization, password newtypes), commands,
  events, errors, the `ShomeiConfig`, the ports expressed as `effectful` effects, and the
  auth workflows implemented against those ports — validated end-to-end with an in-memory
  interpreter and pure tests. This is the heart of the system; every later plan consumes its
  types and effect interfaces.

- **Phase 3 — Adapters (parallel).** EP-3 (PostgreSQL persistence + migrations) and EP-4
  (JWT/JWKS) both depend only on the core and can be implemented concurrently. EP-3 provides
  the codd migration package, the hasql `Database` effect, and the store-port interpreters
  plus the audit-event publisher. EP-4 provides signing-key handling, JWT signing,
  verification, and the JWKS document, interpreting the core's `TokenSigner`/`TokenVerifier`
  ports.

- **Phase 4 — HTTP surface.** EP-5 builds `shomei-servant`: the `Authenticated` combinator
  (custom `AuthProtect` + `AuthHandler`), `RequireRole`/`RequireScope`, the `ShomeiAPI`
  NamedRoutes type, request/response DTOs, and handlers that drive the core workflows.

- **Phase 5 — Delivery.** EP-6 ships `shomei-server`: the executable, configuration loading,
  signing-key bootstrap, and full assembly of the postgres + jwt + servant adapters behind
  the standalone HTTP API, demonstrable with `curl`.

- **Phase 6 — Demonstrations.** EP-7 delivers `shomei-client` and the two example apps
  (`examples/embedded-servant-app`, `examples/microservice-auth-stack`) that prove both the
  embedded and microservice deployment models, including local downstream JWT verification.

Alternatives considered. A single mega-ExecPlan was rejected: the scope spans seven packages
and well over ten files across unrelated concerns, exceeding the ExecPlan size guidance. A
per-package decomposition (one plan per cabal package) was rejected because `shomei-migrations`
and `shomei-postgres` form one persistence concern best verified together, and because
splitting the core's types from its workflows would create a hard dependency with no
independently demonstrable behavior in between. Folding JWT into the server plan was rejected
because JWT/JWKS is independently verifiable (sign-then-verify, JWKS round-trip) and the
microservice demo depends on JWKS specifically, so it earns its own stream.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Project scaffolding and multi-package build foundation | docs/plans/1-project-scaffolding-and-multi-package-build-foundation.md | None | None | Complete |
| 2 | Core domain model, ports, and auth workflows | docs/plans/2-core-domain-model-ports-and-auth-workflows.md | EP-1 | None | Not Started |
| 3 | PostgreSQL persistence and migrations | docs/plans/3-postgresql-persistence-and-migrations.md | EP-1, EP-2 | None | Not Started |
| 4 | JWT signing, verification, and JWKS publishing | docs/plans/4-jwt-signing-verification-and-jwks-publishing.md | EP-2 | EP-1 | Not Started |
| 5 | Servant integration and route protection | docs/plans/5-servant-integration-and-route-protection.md | EP-2, EP-4 | EP-3 | Not Started |
| 6 | Standalone authentication server | docs/plans/6-standalone-authentication-server.md | EP-3, EP-4, EP-5 | None | Not Started |
| 7 | Haskell client and demo applications | docs/plans/7-haskell-client-and-demo-applications.md | EP-6 | EP-5 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the root: it creates the cabal workspace, the shared `common` stanzas, the package
skeletons, and the `Shomei.Prelude` module. Every other plan needs a buildable workspace, so
EP-1 is a hard dependency of EP-2 and EP-3 and a soft dependency of EP-4 (EP-4 could begin
its `jose` spike against a throwaway package, but its real home, `shomei-jwt`, is created by
EP-1).

EP-2 is the second root of all real work: it defines, in `shomei-core`, the domain types, the
TypeID identifiers (`Shomei.Id`), the error type, the `ShomeiConfig`, and — critically — the
**port effects** and the **auth workflows**. EP-3 hard-depends on EP-2 because the postgres
package interprets the store/publisher port effects and persists the core's domain types;
it cannot compile without those effect and type definitions. EP-4 hard-depends on EP-2
because it interprets the `TokenSigner`/`TokenVerifier` port effects and converts the core's
storage-agnostic `StoredSigningKey` records to/from `jose` keys; `AuthClaims`, `AccessToken`,
and `TokenError` are core types it must match.

EP-3 and EP-4 have no dependency on each other and run in parallel during Phase 3.

EP-5 hard-depends on EP-2 (it drives the workflows and exposes `AuthUser`, commands, and DTOs
built from core types) and on EP-4 (the `Authenticated` combinator needs a token-verifier of
shape `Text -> IO (Either TokenError AuthClaims)`, which EP-4 provides). It soft-depends on
EP-3: handlers run against the store ports, which can be exercised with EP-2's in-memory
interpreter in `shomei-servant`'s own tests, with full PostgreSQL wiring deferred to EP-6.

EP-6 hard-depends on EP-3, EP-4, and EP-5: it is the assembly point that runs the real
postgres pool, loads/rotates real signing keys, and serves the real Servant API.

EP-7 hard-depends on EP-6 (the microservice demo and the live-server client tests target a
running `shomei-server`) and soft-depends on EP-5 (the embedded demo and the servant-client
derivation reuse the API types from `shomei-servant`).

Parallelism summary: after EP-1 and EP-2 land, EP-3 and EP-4 proceed together. EP-5 starts as
soon as EP-2 and EP-4 are done (it does not need to wait for EP-3). EP-6 waits for the whole
adapter+surface set. EP-7 is last.


## Integration Points

**IP-1 — `Shomei.Prelude` (custom prelude).** The shared prelude module, exposed from
`shomei-core` and imported by every package. Owner: **EP-1** (creates it with the house
`PackageImports` re-exports of base/text/aeson/time/lens and the standard `eventAesonOptions`,
mirroring `kizashi-api`'s `Kizashi.Prelude`). Consumers: all plans. Later plans must import
it rather than re-importing base modules directly, and must not add the `Data.Generics.Labels`
orphan to it (import that per-module where `#label` is used).

**IP-2 — Core domain types and TypeID identifiers.** `Shomei.Domain.*` (User, Email,
Password, Credential, Session, RefreshToken, AccessToken, TokenPair, AuthClaims, scopes,
roles), `Shomei.Id` (the `KindID`-based `UserId`/`SessionId`/`RefreshTokenId`/`CredentialId`
with orphan `FromHttpApiData`/`ToHttpApiData`), `Shomei.Error` (`AuthError`, `TokenError`,
`PasswordPolicyViolation`). Owner: **EP-2**. Consumers: EP-3 (persists them), EP-4 (claims),
EP-5 (DTOs and `AuthUser`), EP-6, EP-7. Rule: identifiers are TypeIDs at the type level and
are stored as native `uuid` columns in Postgres via `getUUID`/`decorateKindID`; no plan may
redefine these types.

**IP-3 — Port effects (the `effectful` effect interfaces).** `Shomei.Port.UserStore`,
`Shomei.Port.CredentialStore`, `Shomei.Port.SessionStore`, `Shomei.Port.RefreshTokenStore`,
`Shomei.Port.PasswordHasher`, `Shomei.Port.TokenSigner`, `Shomei.Port.TokenVerifier`,
`Shomei.Port.AuthEventPublisher`, `Shomei.Port.SigningKeyStore`, and the support effects
`Shomei.Port.Clock` (current time) and `Shomei.Port.TokenGen` (random opaque tokens). Owner:
**EP-2** (defines each as a dynamic `effectful` `Effect` GADT with `send` smart constructors,
plus an in-memory interpreter for testing). Consumers: EP-3 interprets the store/publisher/
signing-key/clock ports against PostgreSQL and Argon2; EP-4 interprets `TokenSigner`/
`TokenVerifier` and consumes `SigningKeyStore`; EP-5 runs workflows over the ports; EP-6
assembles the real interpreter stack. Rule: the **effect signatures are owned by EP-2**;
adapter plans must implement them exactly and may not change a signature without a Decision
Log entry here and a cascade to the affected plans.

**IP-4 — `StoredSigningKey` and the signing-key boundary.** To keep `shomei-core` free of any
`jose` dependency (transport-agnostic core), signing keys cross the `SigningKeyStore` port as
a storage-agnostic `Shomei.Domain.SigningKey.StoredSigningKey` record whose key material is
opaque `Text` (JWK JSON or PEM), with a `kid`, algorithm tag, status, and timestamps. Owner:
**EP-2** (defines `StoredSigningKey` and `SigningKeyStore`). EP-3 persists it to the
`shomei_signing_keys` table. EP-4 converts `StoredSigningKey` ↔ `jose` `JWK`. Rule: the core
and postgres packages never import `jose`; only `shomei-jwt` does.

**IP-5 — `ShomeiConfig`.** The runtime configuration record (issuer, audience, access/refresh/
session TTLs, password policy, token transport, signing-key config, session-check mode).
Owner: **EP-2** (defines the type and sane defaults in `shomei-core`). Consumers: EP-4 (TTLs,
issuer, audience, algorithm), EP-5 (transport, session-check mode), EP-6 (loads it, e.g. from
environment/Dhall, and threads it through assembly).

**IP-6 — `ShomeiAPI`, DTOs, and `AuthUser`.** The Servant `ShomeiAPI` NamedRoutes record, the
request/response JSON DTOs (`SignupRequest`/`SignupResponse`, `LoginRequest`/`LoginResponse`,
`RefreshRequest`, etc.), and the `AuthUser` principal supplied by the `Authenticated`
combinator. Owner: **EP-5** (in `shomei-servant`). Consumers: EP-6 serves the API; EP-7's
client derives `servant-client` functions from the same `ShomeiAPI` type and the embedded
demo reuses the routes. Rule: `shomei-client` depends on `shomei-servant` for the API type
(a deliberate widening of the `mori.dhall` dependency that listed only `shomei-core` — see
Decision Log) so the client and server cannot drift.

**IP-7 — Database schema and the `shomei` namespace.** The PostgreSQL tables
(`shomei_users`, `shomei_password_credentials`, `shomei_sessions`, `shomei_refresh_tokens`,
`shomei_signing_keys`, `shomei_auth_events`) and the `shomei` schema/`search_path`. Owner:
**EP-3** (codd migrations in `shomei-migrations`). Consumers: EP-3's own hasql statements;
EP-6 runs the migrations at startup or via `just migrate`. Rule: column types for identifier
columns are native `uuid`; status enums are stored as `text`; event payloads as `jsonb`.

**IP-8 — `cabal.project` and shared cabal `common` stanzas.** The workspace manifest (package
list, `with-compiler: ghc-9.12.4`, `source-repository-package` entries for `codd` and
`ephemeral-pg`, `package codd { tests: False }`, `allow-newer`) and the `common warnings` /
`common shared` stanzas every package imports. Owner: **EP-1**. Consumers: every plan adds its
package's dependencies but reuses the shared stanzas; EP-3 adds the codd/ephemeral-pg
source-repository entries it introduces (EP-1 establishes the mechanism, EP-3 fills the
persistence entries) — recorded here so the two plans do not conflict on `cabal.project`.
**EP-4** also contributes one entry to the same placeholder section: a `source-repository-package`
for `jose` pinned to PR #137 (`crypton >= 1.1.0` + `ram`; commit
`4726d077a13b24cd1d78fb94b2db5a86c79e3f0f`), because Hackage jose is incompatible with the
corpus crypton 1.1.2. EP-1 leaves the placeholder; EP-3 fills codd/ephemeral-pg; EP-4 fills
jose — each adds its own block, none rewrites another's. No Shōmei package may depend on the
deprecated `memory` package; `ram` is used wherever `Data.ByteArray` is needed.


## Progress

Milestone-level tracking across all child plans. Updated as each plan's milestones land.

- [x] EP-1: Multi-package cabal workspace compiles (`cabal build all` green in `nix develop`) (2026-06-03)
- [x] EP-1: `Shomei.Prelude` and shared `common` stanzas in place; treefmt/fourmolu wired (2026-06-03)
- [ ] EP-2: Domain types, `Shomei.Id`, errors, and `ShomeiConfig` defined
- [ ] EP-2: Port effects + in-memory interpreters defined
- [ ] EP-2: Signup/login/refresh-rotation/logout workflows pass pure in-memory tests
- [ ] EP-3: codd `shomei-migrations` package + schema migrations apply to ephemeral PostgreSQL
- [ ] EP-3: hasql `Database` effect + store-port interpreters + audit publisher pass integration tests
- [ ] EP-4: signing-key generation + `StoredSigningKey` ↔ JWK conversion working
- [ ] EP-4: JWT sign → verify round-trip and JWKS public document validated
- [ ] EP-5: `Authenticated`/`RequireRole`/`RequireScope` combinators and `ShomeiAPI` defined
- [ ] EP-5: handlers drive workflows; in-process warp test exercises signup/login/me
- [ ] EP-6: `shomei-server` boots, loads config + keys, runs migrations, serves the API
- [ ] EP-6: full `curl` walkthrough (signup→login→refresh→reuse-detect→logout→jwks) passes
- [ ] EP-7: `shomei-client` round-trips against a live server
- [ ] EP-7: embedded demo and microservice demo (downstream local JWT verification) run


## Surprises & Discoveries

Cross-plan insights, dependency changes, and scope adjustments discovered during
implementation. Provide concise evidence.

- The corpus `crypton` is **1.1.2**, which dropped the (now-deprecated) `memory` package in
  favor of **`ram`** — a maintained drop-in fork that keeps the `Data.ByteArray` module and its
  `constEq`/`convert`/encoding functions. Consequence: NO Shōmei package may depend on `memory`;
  everything that needs `Data.ByteArray` (the Argon2 hasher in EP-3, the thumbprint/Base64URL
  code in EP-4) depends on `ram` instead. Evidence: `crypton.cabal` in the corpus lists
  `ram >=0.20.1 && <0.23`; `ram` exposes `ram/Data/ByteArray.hs`.
- The released `jose` 0.12 on Hackage is **incompatible** with crypton 1.1.x: it still pins
  `memory >= 0.7` and `crypton >= 0.31`, so its `ByteArray` class would not unify with crypton
  1.1's. The fix is `frasertweedale/hs-jose` **PR #137** ("Update to crypton >= 1.1.0 and ram
  instead of memory", jose 0.13, commit `4726d077a13b24cd1d78fb94b2db5a86c79e3f0f`, still OPEN).
  Shōmei pulls `jose` from that revision via a `cabal.project` `source-repository-package` (EP-4
  owns this entry, under IP-8). The corpus now registers `frasertweedale/hs-jose` at
  `/Users/shinzui/Keikaku/hub/haskell/jose-project/hs-jose`, but that copy is **0.12 (memory-based)**
  — it is for reading the API on disk; the build still uses the PR-#137 source-repository pin.


## Decision Log

- Decision: Model the core ports as `effectful` effects rather than the spec's tagless-final
  `class Monad m => UserStore m` typeclasses.
  Rationale: Matches the established house style (kizashi's `AppEffects`, `mori.dhall`'s
  declared stack) and the user's Haskell standards; gives one fixed, interpretable effect
  stack with IO and in-memory interpreters. Confirmed with the user at kickoff.
  Date: 2026-06-03

- Decision: Use `mmzk-typeid` `KindID` TypeIDs (prefixed: `user_…`, `session_…`,
  `refresh_token_…`, `credential_…`) for identifiers, stored as native `uuid` columns via
  `getUUID`/`decorateKindID`.
  Rationale: `mori.dhall` already lists `mmzk-typeid`; kizashi's `Kizashi.Id` is the template;
  self-describing IDs improve API ergonomics while keeping efficient UUID storage. Diverges
  from the spec's raw `newtype UserId = UserId UUID`. Confirmed with the user at kickoff.
  Date: 2026-06-03

- Decision: Add a dedicated `shomei-migrations` package (codd + `file-embed` SQL, plus a
  public `test-support` sublibrary using `ephemeral-pg`), beyond the six packages listed in
  `mori.dhall`.
  Rationale: Mirrors `kizashi-migrations` exactly and gives the ephemeral-PostgreSQL
  integration-test pattern. Confirmed with the user at kickoff. `mori.dhall` should be
  updated to register the seventh package during EP-3.
  Date: 2026-06-03

- Decision: Keep signing-key material crossing the `SigningKeyStore` port as a
  storage-agnostic `StoredSigningKey` (key material as opaque `Text`), so `shomei-core` and
  `shomei-postgres` never depend on `jose`.
  Rationale: Preserves the transport-agnostic-core principle; only `shomei-jwt` knows about
  `jose`'s `JWK`. Resolves the otherwise-circular pull of a JWT library into the core.
  Date: 2026-06-03

- Decision: `shomei-client` depends on `shomei-servant` (not only `shomei-core` as in
  `mori.dhall`).
  Rationale: Lets the client derive `servant-client` functions from the single source-of-truth
  `ShomeiAPI` type, preventing client/server drift. `mori.dhall` dependency list to be widened
  during EP-7.
  Date: 2026-06-03

- Decision: Default JWT algorithm is **ES256** (EC P-256), asymmetric, with JWKS publishing
  and key rotation.
  Rationale: Asymmetric is required for downstream local verification; ES256 keys/signatures
  are far smaller than RSA and universally supported by JWKS consumers. EdDSA considered but
  has slightly less universal verifier support.
  Date: 2026-06-03

- Decision: Use the `jose` (crypton-jose) library for JWS/JWK/JWKS and `crypton`'s
  `Crypto.KDF.Argon2` (Argon2id) for password hashing; Servant protection via the built-in
  `AuthProtect` + `AuthHandler` mechanism rather than `servant-auth-server`.
  Rationale: `jose` is the standard JWK/JWKS library on the crypton stack; crypton already
  provides Argon2id (no extra dep). The custom `AuthHandler` lets the `Authenticated`
  combinator call `shomei-jwt`'s verifier directly and gives precise Bearer-vs-cookie
  precedence and 401/403 semantics. Risk flagged: `jose` 0.12's tested GHC ceiling is 9.12.2,
  so EP-4 must verify the build on 9.12.4 early (an `allow-newer` bump may be needed).
  Date: 2026-06-03

- Decision: Pull `jose` from `frasertweedale/hs-jose` PR #137 (jose 0.13; `crypton >= 1.1.0`,
  `ram` instead of `memory`) via a `cabal.project` `source-repository-package` — not from
  Hackage — and forbid the deprecated `memory` package anywhere in Shōmei (use `ram`).
  Rationale: the corpus `crypton` is 1.1.2, which replaced `memory` with `ram`; Hackage jose
  0.12 still pins `memory`/`crypton>=0.31` and would fail to type-check against crypton 1.1.
  `memory` is deprecated; `ram` is its maintained drop-in (same `Data.ByteArray` API). EP-4
  owns the jose `source-repository-package` entry (IP-8); EP-3 and EP-4 both depend on `ram`
  (not `memory`) for `Data.ByteArray`. The `jose` source is now in the mori corpus
  (`frasertweedale/hs-jose`) for API reference, but at version 0.12 (memory-based), so the build
  must still use the PR-#137 pin. Confirmed with the user after checking corpus versions.
- **EP-1: `nix fmt` was not wired by the seihou scaffold (affects IP-8 and every plan's
  formatting step).** `flake.nix` imports only `nix/haskell.nix` + `flake.module.nix`; it
  does not import `nix/treefmt.nix`, and `treefmt-nix` is not a top-level flake input, so
  `nix fmt` reported no `formatter` attribute. EP-1 wired it from the unmanaged
  `flake.module.nix` via the transitive `haskell-nix-dev.inputs.treefmt-nix.flakeModule`
  and excluded the seihou-managed `nix/*` and `flake.nix` from treefmt (the pinned
  nixpkgs-fmt otherwise rewrote `nix/pre-commit.nix` and broke idempotence). Consequence
  for later plans: `nix fmt` now works and only touches project sources; do not edit
  seihou Nix files to "fix" formatting. The formatter is fourmolu 0.19.0.1 (4-space,
  leading-comma style) — that output is the source of truth for all Haskell sources.
  Date: 2026-06-03

- Decision: Decompose into seven ExecPlans across six phases (Foundation → Domain core →
  Adapters[parallel] → HTTP surface → Delivery → Demonstrations), boundaries following the
  package dependency layering.
  Rationale: Maximizes independent verifiability and parallelism (EP-3 ∥ EP-4) while keeping
  each plan a demonstrable behavior; see Decomposition Strategy for alternatives rejected.
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original vision.

(To be filled during and after implementation.)
