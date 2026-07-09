---
id: 38
slug: persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment
title: "Persistent Roles and Scopes with a Granting Path and Claims Enrichment"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# Persistent Roles and Scopes with a Granting Path and Claims Enrichment

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-1** of MasterPlan 7
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`), the keystone of its
Phase 1. It has no dependencies on other plans in that MasterPlan. Three later plans build
directly on it: the admin HTTP API (`docs/plans/39-admin-http-api-for-user-and-session-management.md`)
cannot demonstrate an authorized request until this plan's granting path exists; the
built-in tier's growth plan
(`docs/plans/46-role-definitions-permissions-and-time-bound-grants.md`, EP-9) extends this
plan's registry table, `RoleStore` port, enrichment path, and combinator pattern; and the
OIDC plans reuse the claims-construction hook this plan introduces.


## Purpose / Big Picture

Shōmei (a Haskell authentication toolkit: `effectful` domain core, hasql/PostgreSQL
persistence, Servant `NamedRoutes` HTTP API, Warp server) already puts `roles` and `scopes`
claims into every access token it signs — but **nothing can ever populate them**. The
claims builder `buildClaims` in `shomei-core/src/Shomei/Workflow/Session.hs` hardcodes
`scopes = Set.empty, roles = Set.empty`. There is no role table, no grant command, no
enrichment hook. The consequence is user-visible and absurd: the only admin-gated HTTP
endpoint, `GET /admin/audit/events`, is guarded by `requireRole (Role "admin")` — a role no
production flow can ever mint into a token. `docs/user/security.md` documents this openly
("Known limitation — the `admin` role"). Worse, the `RequireRole`/`RequireScope` Servant
combinators exported from `shomei-servant/src/Shomei/Servant/Authz.hs` are *phantom types*
with no `HasServer` instance: writing `RequireRole "admin" :> ...` in a route type compiles
and enforces **nothing** — a route author who writes the type but forgets the in-handler
`requireRole` call ships a silently unprotected route.

After this plan, all of that is fixed end-to-end:

1. Roles have a **persistent source of truth**: a new `shomei_role_grants` table and a
   `RoleStore` effect (define, list-defined, grant, revoke, list) with PostgreSQL and
   in-memory interpreters.
2. Roles have a **declared catalog** (a "role registry"): a new `shomei_roles` table (role
   name as primary key, plus a description and a created-at timestamp), seeded with `admin`
   by the migration. `shomei_role_grants.role` carries a foreign key into it, and the
   granting workflow refuses a role that has not been defined — so
   `roles grant --role adminn` (a typo) fails loudly (CLI exit code 1; HTTP 422
   `role_not_defined` once plan 39 exposes granting over HTTP) instead of silently minting
   a role nothing will ever check. Operators declare new roles with
   `shomei-admin roles define <name> --description "…"` and inspect the catalog with
   `shomei-admin roles list-defined`.
3. Every token mint (signup, login, MFA completion, passwordless login, refresh) populates
   the `roles` claim from that store and runs a **host-supplied claims-enrichment hook** (a
   new `ClaimsEnricher` effect) that can add scopes, roles, and extra claims. This hook is
   the claims-construction integration point that the later OIDC and token-exchange plans
   (MasterPlan 7 EP-5/EP-6) must reuse.
4. Deployments can configure **default roles for new users**: a new
   `defaultRoles :: Set Role` field on `ShomeiConfig` (default empty), validated against
   the role registry at server boot (the server refuses to start naming an undefined
   default role), and applied inside the signup workflow at the same point the user row is
   created — audited as `role_granted` with a `NULL` granting actor, exactly like a CLI
   bootstrap grant. `shomei-admin users create` drives the same workflow, so CLI-created
   users receive them too.
5. An operator can **bootstrap the first admin** from the box:
   `shomei-admin roles grant --user <id> --role admin`, plus `roles revoke` and `roles list`.
6. `RequireRole`/`RequireScope` become **real, enforcing combinators** with `HasServer`
   instances: the route type alone authenticates the caller and rejects a principal lacking
   the role/scope with 403. The audit endpoint switches to `RequireRole "admin"` as the
   proving route.
7. Grants and revocations are **audited** (`role_granted` / `role_revoked` rows in
   `shomei_auth_events`, carrying who granted what to whom).

You can see it working: run the dev server, create a user, grant them `admin` with the CLI,
log in, and `curl /admin/audit/events` with the fresh token — HTTP 200 with the audit trail.
Revoke the role, refresh the token, and the same request is 403. Grant a misspelled role
and the CLI refuses with `role not defined`. The exact transcript is in Validation and
Acceptance.

One product decision frames what this plan builds and, deliberately, what it does not
(recorded in the Decision Log): Shōmei ships a **two-tier authorization story**. This plan
is tier 1 — flat, self-contained role-based access control that works with zero extra
infrastructure, gates Shōmei's *own* `/admin` endpoints, and grows (in
`docs/plans/46-role-definitions-permissions-and-time-bound-grants.md`) into role→permission
definitions and time-bound grants. Tier 2, the recommended path for robust, fine-grained,
relationship-based authorization ("is this user an editor *of this project*?", live
revocation, conditional access), is the author's sibling project **en** — a Zanzibar-style
ReBAC toolkit at `/Users/shinzui/Keikaku/bokuno/en` — documented in
`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`.
Shōmei's built-in roles are never removed in favor of en: they are the bootstrap tier that
cuts the auth↔authz circularity (en's own server has no caller authentication yet; its
plan for adding it names Shōmei-JWT verification as the intended credential checker, so
*something* that is not en must gate Shōmei's admin surface). The docs milestone below
states this boundary for users.

One semantic to understand up front (documented for operators in Milestone 5): **role
changes take effect at the next token mint**, i.e. the next login or refresh, not on
outstanding access tokens. An already-issued JWT is self-contained; Shōmei does not re-read
the role store on verification. The immediate lever after revoking a role from a
compromised account is session revocation (`revokeAllUserSessions`), which kills the
refresh path so no further tokens can be minted.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Role persistence (migration, registry, port, interpreters, audit events): **done 2026-07-09**

- [x] Add migration `shomei-migrations/sql-migrations/2026-07-09-20-34-28-shomei-role-grants.sql` (via `just new-migration shomei-role-grants` — see Surprises: the documented `name=` form is wrong) creating `shomei_roles` (seeded with `admin`) and `shomei_role_grants` (with the `role` FK into `shomei_roles`).
- [x] Append a comment line to `shomei-migrations/src/Shomei/Migrations.hs` so the `embedDir` Template Haskell splice re-embeds the new `.sql` file (see Surprises — the Justfile's `touch` of the `.cabal` does **not** do this).
- [x] Add `UserNotFound` and `RoleNotDefined` to `AuthError` (`shomei-core/src/Shomei/Error.hs`) and their mappings in `shomei-servant/src/Shomei/Servant/Error.hs` (404 `user_not_found`; 422 `role_not_defined`, with a locally defined `err422`).
- [x] Add `RoleGranted`/`RoleRevoked` constructors + `RoleGrantedData`/`RoleRevokedData` to `shomei-core/src/Shomei/Domain/Event.hs`.
- [x] Extend `projectAuthEvent`/`reconstructAuthEvent` in `shomei-core/src/Shomei/Domain/EventCodec.hs` (`role_granted`, `role_revoked`) and bump the constructor-count guard in `shomei-core/test/Shomei/Domain/EventCodecSpec.hs` from 25 to 27 with round-trip cases. (Role *definitions* are not audit events — Decision Log.)
- [x] Add the `RoleStore` effect (`shomei-core/src/Shomei/Effect/RoleStore.hs`) with grant/revoke/list **and** `DefineRole`/`ListDefinedRoles` + the `RoleDefinition` record; export it from the cabal file.
- [x] Add `Shomei.Workflow.Roles` (`grantRoleTo`, `revokeRoleFrom`, `rolesOf`, `applyDefaultRoles`, `undefinedDefaultRoles`) publishing the audit events; `grantRoleTo` refuses undefined roles with `RoleNotDefined`.
- [x] Add `defaultRoles :: Set Role` to `ShomeiConfig` (pulled forward from Milestone 2.5: `Shomei.Workflow.Roles` cannot compile without it).
- [x] Add the PostgreSQL interpreter `shomei-postgres/src/Shomei/Postgres/RoleStore.hs` (`runRoleStorePostgres`, five statements); add `containers` to `shomei-postgres`'s library `build-depends`.
- [x] Add the in-memory interpreter (`runRoleStore` + `roleGrants` and `definedRoles` fields in `World`, `definedRoles` pre-seeded with `admin` to mirror the migration) to `shomei-core/src/Shomei/Effect/InMemory.hs`; add `RoleStore` to `runInMemory`'s effect list.
- [x] Postgres interpreter tests in `shomei-postgres/test/Main.hs` (`testRoleRegistry`, `testRoleGrants`, `testRoleGrantForeignKeys`) — `cabal test shomei-postgres` green (43 tests), `cabal test shomei-core` green (135 tests).

Milestone 2 — Claims enrichment at every mint, and default roles at signup: **done 2026-07-09**

- [x] Add the `ClaimsEnricher` effect + `ClaimsDelta` (`shomei-core/src/Shomei/Effect/ClaimsEnricher.hs`) with `runClaimsEnricherNull` and `runClaimsEnricherPure`; module haddock carries the staleness warning (do **not** mirror live en/ReBAC decisions into JWT claims — see 2.1).
- [x] Add `buildEnrichedClaims` to `shomei-core/src/Shomei/Workflow/Session.hs`; switch `issueSession`, `Shomei.Workflow.signup`, and `Shomei.Workflow.refresh` to it. (`login` and both `Shomei.Workflow.Mfa` completions inherit the two new constraints through `issueSession`.)
- [x] `defaultRoles :: Set Role` on `ShomeiConfig` (landed in Milestone 1); the `SHOMEI_DEFAULT_ROLES` env override **and** a `defaultRoles` Dhall-file field in `shomei-server/src/Shomei/Server/Config.hs`, plus `config/shomei-types.dhall` and `config/shomei.example.dhall`.
- [x] Apply default roles in `Shomei.Workflow.signup` (via `Shomei.Workflow.Roles.applyDefaultRoles`, immediately after `createUser`) so the first minted token already carries them; audited as `role_granted` with `granted_by = NULL`. Required widening `signup` with `AuthEventPublisher :> es` (see Surprises).
- [x] Boot-time validation: `validateDefaultRoles` in `shomei-server/src/Shomei/Server/Boot.hs` refuses to start when `defaultRoles` names a role missing from `shomei_roles` (via `undefinedDefaultRoles`); embedded-host guidance documented on the helper's haddock.
- [x] Wire `RoleStore` + `ClaimsEnricher` into every effect stack: `Shomei.Servant.Seam.AppEffects`, `Shomei.Server.App.AppEffects` + `runAppIO`, `Shomei.Effect.InMemory.runInMemory`, `shomei-postgres/test/Main.hs`, `shomei-servant/test/Main.hs`, `shomei-core/test/Shomei/Workflow/TimingSpec.hs`, and `shomei-server/app/Shomei/Admin/Users.hs`.
- [x] Factor `runInMemoryWith` out of `runInMemory` (and name the shared list `InMemoryPorts`) so a test can supply a `ClaimsEnricher` hook without restating the twenty-interpreter chain.
- [x] Core tests (`shomei-core/test/Shomei/Workflow/RolesSpec.hs`, 7 cases): a grant reaches the next login's token but not the outstanding one; refresh picks up a grant; refresh drops a revoked role; a `ClaimsDelta` cannot forge `sub`/`roles`/`scopes`/`iss`/`act`; hook roles union with stored roles and hook scopes reach the token; `defaultRoles` land on the **first** token with a `role_granted` audit row and no actor; `undefinedDefaultRoles` reports exactly the missing names.
- [x] Postgres test `testGrantedRoleReachesEnrichedClaims` proving the real store feeds `buildEnrichedClaims`.
- [x] Update the two round-trip budget guards (`testLoginRoundTripBudget` 7 → 8, `testRefreshRoundTripBudget` 3 → 4) for the one `listRolesForUser` read per mint, documenting why (see Surprises).
- [x] `cabal build all` and `cabal test all` green (core 142, postgres 44, servant 10, admin 14, all others unchanged).

Milestone 3 — CLI granting path:

- [ ] Add `shomei-server/app/Shomei/Admin/Roles.hs` (`roles define|list-defined|grant|revoke|list`) and wire it into `shomei-server/app/Admin.hs` + both cabal stanzas.
- [ ] `roles grant` with an undefined role exits 1 with `role not defined: <name> (define it first: shomei-admin roles define <name>)`.
- [ ] Admin CLI test (define → list-defined → grant → list → revoke → grant-typo-fails, over a migrated ephemeral DB) — suite green.

Milestone 4 — Enforcing combinators:

- [ ] Implement `HasServer` for `RequireRole`/`RequireScope` in `shomei-servant/src/Shomei/Servant/Authz.hs` (self-authenticating; 403 on missing role/scope).
- [ ] Switch `auditEvents` in `shomei-servant/src/Shomei/Servant/API.hs` from `Authenticated :>` to `RequireRole "admin" :>`; update `AppAPI` example; keep handler signature.
- [ ] Update `HasOpenApi (RequireRole …)`/`(RequireScope …)` in `shomei-servant/src/Shomei/Servant/OpenApi.hs` to register the bearer security scheme; regenerate `docs/api/openapi.json`; openapi conformance suite green.
- [ ] Add `HasClient` delegation instances for the combinators (in `shomei-client`) so `genericClient` still derives.
- [ ] Servant end-to-end test: combinator-gated route returns 401 (no token), 403 (no role), 200 (role); a scope-gated route ditto.

Milestone 5 — Live proof and docs:

- [ ] Live transcript: CLI grant → login → `curl /admin/audit/events` 200 → revoke + refresh → 403; plus the typo-grant refusal (recorded below).
- [ ] Rewrite the "Known limitation — the `admin` role" section of `docs/user/security.md`; document staleness semantics, the role registry, default roles, and the enrichment hook; update `docs/user/api.md`; CHANGELOG entry.
- [ ] The rewritten `docs/user/security.md` section states the **two-tier authorization story**: built-in flat roles as the self-contained/bootstrap/coarse tier, en (`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`) as the recommended tier for fine-grained/relationship-based authorization with live revocation.
- [ ] Update MasterPlan 7 registry/progress for EP-1.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-07-09 — `just new-migration name=<slug>` does not work.** The Justfile's own comment
documents `just new-migration name=add-something`, and this plan's Concrete Steps copied it.
`just` treats recipe parameters positionally, so `name=shomei-role-grants` is passed *as the
slug* and fails the slug regex:

```text
$ just new-migration name=shomei-role-grants
Invalid slug: name=shomei-role-grants
error: recipe `new-migration` failed on line 33 with exit code 1
```

The working form is `just new-migration shomei-role-grants`. The stale comment in `Justfile`
is corrected in Milestone 5's docs pass.

**2026-07-09 — touching the `.cabal` no longer forces the migration re-embed; editing
`Shomei.Migrations` does.** `embeddedFiles = $(embedDir "sql-migrations")` is a compile-time
splice, so a brand-new `.sql` file is invisible until that module recompiles. The `migrate`
Justfile recipe (and this module's own comment) claim `touch shomei-migrations/shomei-migrations.cabal`
forces it. Under cabal 3.16 it does not — cabal detects changes by content hash, not mtime:

```text
$ touch shomei-migrations/shomei-migrations.cabal && cabal build shomei-migrations
Up to date
$ cabal build shomei-migrations --ghc-options=-fforce-recomp
Up to date
```

and the postgres suite failed with `relation "shomei.shomei_roles" does not exist`. What
actually works — and what every previous migration wave silently relied on — is *editing*
`shomei-migrations/src/Shomei/Migrations.hs`: the module carries a growing comment block, one
line per migration wave, appended for exactly this reason. This plan appends its own line and
records the real mechanism in the module haddock. The `Justfile` comment is corrected in
Milestone 5.

**2026-07-09 — `Shomei.Workflow.signup` has no `AuthEventPublisher` constraint.** Milestone
2.5 asserts "`signup` already has every constraint `applyDefaultRoles` needs". It does not:
`signup` publishes `UserRegistered`/`SessionStarted` through `persistNewSession`'s event-list
argument (the unit-of-work writes them inside the transaction), never through
`publishAuthEvent`. Adding `applyDefaultRoles` therefore widens `signup`'s signature with
`AuthEventPublisher :> es` — which in turn widens every call site's interpreter chain,
including `shomei-server/app/Shomei/Admin/Users.hs`'s private one. Handled in Milestone 2.

**2026-07-09 — enrichment costs one database round-trip per mint, and two guard tests pin it.**
`shomei-postgres/test/Main.hs` carries `testLoginRoundTripBudget` and
`testRefreshRoundTripBudget`, which count `Database` operations through an `interpose`d
counting interpreter and assert an exact number. `buildEnrichedClaims`'s `listRolesForUser`
made login 7 → 8 and refresh 3 → 4. The cost is inherent to the design (roles are read at mint,
never at verification) and is a single indexed lookup on `shomei_role_grants`'s primary-key
prefix; both constants and their explanatory haddocks were updated rather than the design.
**Any later plan that adds a store read to a mint path will trip these tests** — that is what
they are for.

**2026-07-09 — the servant test forged an admin token by hand.** `shomei-servant/test/Main.hs`
has `mkAdminToken`, whose comment reads "the workflows issue no roles, so this is the only way
to get one". After Milestone 2 that is false; Milestone 4's tests grant the role through
`Shomei.Workflow.Roles.grantRoleTo` and log in, which is what makes the combinator test prove
something about the real path rather than about a hand-signed token.

**2026-07-09 — `ShomeiConfig`'s new field does not break Dhall decoding.** The plan warned that
adding a field to a `FromJSON`-deriving record breaks existing config files. It does not here:
`shomei-server/src/Shomei/Server/Config.hs` decodes a *separate* flat `FileConfig` of all-optional
scalars and merges it onto `defaultShomeiConfig`. `ShomeiConfig`'s own `FromJSON` is never used
to read a config file. Adding `defaultRoles` is therefore safe, and the loader needs only a new
optional `FileConfig` field plus the env override.


## Decision Log

Record every decision made while working on the plan.

- Decision: Role grants use a **flat** `(user_id, role)` model — role as plain text, no
  projects/organizations/grant-objects (the Zitadel shape). Scopes get **no** persistence:
  they remain claim-strings supplied by service-token requests and by the enrichment hook.
  Rationale: MasterPlan 7's gap analysis concluded Shōmei is single-tenant and headless;
  a grant hierarchy would touch every table and route for no current consumer. Roles are
  the thing the existing `requireRole` gate actually reads; scopes are already minted
  per-request by `/auth/service-token` and will be negotiated per-grant by the OAuth2 plans.
  A flat table upgrades cleanly (add columns) if more is ever needed.
  (Amended 2026-07-07, same-day scope fold: the original "no role catalog" clause is
  superseded by the role-registry decision below. The flat, object-free *grant* model
  itself is unchanged.)
  Date: 2026-07-07

- Decision: Roles get a **registry** — a `shomei_roles` catalog table (`role text PRIMARY
  KEY`, `description text NULL`, `created_at timestamptz NOT NULL`), seeded with `admin`
  by the migration; `shomei_role_grants.role` carries an FK into it; the `RoleStore` port
  gains `DefineRole`/`ListDefinedRoles` (with a `RoleDefinition` record); `grantRoleTo`
  refuses an undefined role with a new `AuthError` constructor `RoleNotDefined`, mapped to
  HTTP 422 `role_not_defined` (the CLI renders it as a stderr error, exit 1). The registry
  is append-only in this plan: there is no `roles undefine` (removal would have to answer
  what happens to outstanding grants; deferred until a consumer needs it —
  `docs/plans/46-role-definitions-permissions-and-time-bound-grants.md` builds on the
  registry and may revisit). The admin HTTP route `GET /admin/roles` that lists the
  catalog belongs to plan 39 (`docs/plans/39-admin-http-api-for-user-and-session-management.md`),
  which owns the admin HTTP surface; this plan provides the port operation and the
  `RoleDefinition` shape it will serialize.
  Rationale: without a catalog, `roles grant --role adminn` (typo) silently succeeds and
  mints a role no gate ever checks — the same "compiles but enforces nothing" failure mode
  this plan exists to kill, moved one layer up. The FK makes the invariant hold even for
  code that bypasses the workflow. A separate table (rather than an enum or a config list)
  keeps definitions administrable at runtime and gives plan 46's `shomei_role_permissions`
  table something to reference. Definitions are **not** audit events: they are rare,
  low-sensitivity catalog metadata, and keeping the `AuthEvent` count at 27 avoids codec
  churn; grants/revocations (the security-relevant facts) remain fully audited.
  Date: 2026-07-07

- Decision: New users can receive **default roles at signup**: `ShomeiConfig` gains
  `defaultRoles :: Set Role` (default empty; `SHOMEI_DEFAULT_ROLES` comma-separated env
  override in the server's config loader), validated against the registry at server boot
  (fail fast with the offending names), and applied by `Shomei.Workflow.signup`
  immediately after `createUser` — inside the same workflow invocation, before the first
  token is minted, so the very first access token already carries them. Each application
  is audited as `role_granted` with `granted_by = NULL` (the "system/bootstrap" actor,
  same convention as CLI grants). `shomei-admin users create` drives the same `signup`
  workflow, so CLI-created users receive default roles too — no special-casing.
  Rationale: "every new user is a `member`" is the most common role shape and must not
  require a per-user CLI call. Applying them inside `signup` (not in a store trigger, not
  in the HTTP handler) keeps one audited code path for every entry point (HTTP signup and
  the admin CLI both call `signup`). Boot-time validation (rather than validating at each
  signup) keeps the hot path free of catalog reads beyond the grant inserts themselves and
  turns a config typo into an immediate, obvious startup failure instead of a stream of
  522s; because the registry is append-only in this plan, a boot-validated role cannot
  later disappear, so `applyDefaultRoles` may grant without re-checking.
  Date: 2026-07-07

- Decision: Shōmei ships a **two-tier authorization story**, and this plan is tier 1 —
  deliberately flat and self-contained. Tier 2, recommended for robust fine-grained
  authorization (resource-scoped permissions, relationship-derived access, live
  revocation, caveats), is the sibling Zanzibar-style ReBAC project **en**
  (`/Users/shinzui/Keikaku/bokuno/en`; integration guidance is
  `docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`).
  Shōmei's built-in roles are **never removed** in favor of en. The docs milestone states
  the boundary, and the `ClaimsEnricher` haddock warns hosts not to mirror live en
  decisions into JWT claims.
  Rationale: two reasons. (1) Bootstrap circularity: en's own server currently has **no
  caller authentication** (en's `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md`
  is unimplemented and names Shōmei-JWT verification as a future credential checker), so
  Shōmei's admin surface cannot be gated by en without each system depending on the other
  at boot; flat JWT roles cut that knot. (2) Deployments that do not want a second
  authorization system get a complete, if coarse, story from Shōmei alone — plan 46 grows
  it (permissions, time-bound grants) precisely so that tier 1 remains genuinely usable.
  JWT claims are minted-then-static, which is the wrong transport for en's live decisions
  (a mirrored decision is stale the moment a tuple changes); the enrichment hook is for
  coarse hints and scopes, and plan 47's guide shows the correct live-check pattern.
  Date: 2026-07-07

- Decision: `granted_by` on `shomei_role_grants` is **nullable**.
  Rationale: the bootstrap path is the CLI on the box, where there is no authenticated
  admin principal yet (chicken-and-egg). CLI grants record `NULL`; HTTP grants (plan 39)
  record the acting admin's user id.
  Date: 2026-07-07

- Decision: The claims-enrichment hook is a new **effect**, `ClaimsEnricher`, returning a
  `ClaimsDelta` (extra roles, extra scopes, extra claims object) that the core merges —
  running the extra-claims object through the existing `mkExtraClaims` filter so reserved
  keys (`iss`, `sub`, `aud`, `iat`, `exp`, `sid`, `scopes`, `roles`, `act`) can never be
  forged. The default interpreter `runClaimsEnricherNull` returns an empty delta.
  Rationale: an effect is exactly how Shōmei already models host-supplied behavior — the
  `Notifier` port is the precedent (Shōmei emits, the host delivers). Putting a function in
  `ShomeiConfig` was rejected: `ShomeiConfig` is plain data loaded from Dhall/env and must
  stay `Show`/decodable. Returning a *delta* rather than letting the hook rewrite the whole
  `AuthClaims` keeps the standard claims tamper-proof by construction. Embedding hosts
  supply their own interpreter when assembling `Seam.Env.runPorts`, exactly as they do for
  `Notifier`. MasterPlan 7 designates this hook as the claims-construction integration
  point EP-5 (ID token/userinfo) and EP-6 (token exchange) must call — never re-reading
  stores in the HTTP layer.
  Date: 2026-07-07

- Decision: The enrichment path is wired into the three mint sites that build fresh
  user-session claims — `Shomei.Workflow.signup`, `Shomei.Workflow.refresh`, and
  `Shomei.Workflow.Session.issueSession` (the shared tail of login/MFA/passwordless). The
  **service-token** workflow (`Shomei.Workflow.ServiceToken`, which sets scopes explicitly
  from the allow-list) and the **impersonation** workflow (which constructs delegated
  claims directly) are left unchanged in this plan.
  Rationale: service tokens carry an explicitly negotiated scope set — silently adding the
  service user's roles would widen a deliberately narrow credential; MasterPlan 7's EP-4
  replaces this surface anyway. Impersonation tokens are short-lived operator credentials
  whose claim shape is a security contract of MasterPlan 3; EP-6 (token exchange)
  generalizes them and will route through the hook then. Recorded so nobody "fixes" these
  paths casually.
  Date: 2026-07-07

- Decision: `RequireRole`/`RequireScope` get **real `HasServer` instances** that subsume
  `Authenticated`: `RequireRole "admin" :> sub` authenticates the request (running the same
  `AuthHandler` from the Servant `Context` that `Authenticated` uses), checks the role,
  fails with 403, and passes the `AuthUser` to the sub-handler. Routes write the combinator
  *instead of* `Authenticated`, not in addition. The guard functions `requireRole`/
  `requireScope` remain exported for composite checks a single symbol cannot express
  (plan 39's "role `admin` OR scope `shomei:admin`").
  Rationale: the alternative (delete the phantoms; standardize on handler guards) preserves
  the exact failure mode the review flagged — the type documents protection the handler
  may not implement. A combinator whose *absence* of enforcement is impossible is the point.
  The "wrap the inner server, receive `AuthUser` from `Authenticated` upstream" design was
  rejected because Servant combinators cannot observe values captured by *other* combinators;
  the only sound way for `RequireRole` to know the principal is to run the auth check itself,
  which the `Context`-registered `AuthHandler` makes cheap and consistent (same token
  extraction, same verifier).
  Date: 2026-07-07

- Decision: Role changes are **eventually consistent with token lifetime**: they apply at
  the next mint (login or refresh — `refresh` re-runs `buildEnrichedClaims`), never to
  outstanding access tokens. No token-revocation-by-role machinery is added.
  Rationale: JWTs are self-contained by design; re-checking the store per request would
  reintroduce the DB round-trip stateless verification exists to avoid. The access-token
  TTL (default short) bounds the staleness window, and `revokeAllUserSessions` is the
  documented immediate lever. Operators are told this explicitly in `docs/user/security.md`.
  Date: 2026-07-07

- Decision: The in-memory `World` stores `definedRoles :: Map Role RoleDefinition` (the real
  record, with the `createdAt` the caller passed) rather than the planned
  `Map Role (Maybe Text)` with a fabricated timestamp.
  Rationale: it costs nothing, and a fabricated `createdAt` would let a test pass against the
  in-memory stack that fails against PostgreSQL. The seed row uses `emptyWorld`'s own fixed
  clock, so the fresh in-memory world and the freshly migrated database agree on both the
  `admin` role and its description (which the migration and `InMemory.adminRoleDescription`
  now state identically).
  Date: 2026-07-09

- Decision: `ShomeiConfig.defaultRoles` landed in Milestone 1, not Milestone 2.
  Rationale: `Shomei.Workflow.Roles.applyDefaultRoles`/`undefinedDefaultRoles` — both
  Milestone-1 deliverables per 1.5 — take a `ShomeiConfig` and read the field, so the field
  must exist for Milestone 1 to compile. Only the *loader* work (the `FileConfig` field, the
  `SHOMEI_DEFAULT_ROLES` override, boot validation) stays in Milestone 2, where it belongs.
  Date: 2026-07-09

- Decision: `defaultRoles` is configurable from the **Dhall file as well as** the environment,
  and `config/shomei-types.dhall` gains a required `defaultRoles : List Text` field.
  Rationale: 2.5 specified only `SHOMEI_DEFAULT_ROLES`, but "every new user is a member" is a
  deployment-shaped setting that belongs in the committed config file next to
  `emailVerificationRequired`, not only in an env var. Because the loader decodes a separate
  all-optional `FileConfig` (see Surprises), the JSON key is optional and a deployment that
  omits it is unaffected. The Dhall *schema* field is required, matching how every other field
  in that file is declared; an operator upgrading gets a loud Dhall type error naming the
  missing field, with `config/shomei.example.dhall` showing `[] : List Text`.
  Date: 2026-07-09

- Decision: `Shomei.Effect.InMemory` exports `runInMemoryWith` (a `ClaimsEnricher`-parameterized
  `runInMemory`) and the named `InMemoryPorts` effect list.
  Rationale: testing the enrichment hook needs a non-null interpreter, and the alternative was a
  second copy of the twenty-interpreter chain in the test suite — the exact drift the existing
  "keep the order aligned" comments warn about. `runInMemory` is now
  `runInMemoryWith (\_ _ -> emptyClaimsDelta)`, so there is one chain. Embedding hosts get the
  same seam for free.
  Date: 2026-07-09

- Decision: The postgres FK-violation test asserts `InternalAuthError` from the **raw port**
  and the typed `RoleNotDefined`/`UserNotFound` from the **workflow**, for both the role FK and
  the user FK.
  Rationale: 1.8 left the choice open ("assert whichever the port does"). Asserting both halves
  pins the actual contract: the workflow pre-checks and never reaches the table, while the
  database is genuine defense in depth for a caller that bypasses the workflow. The test also
  asserts exactly one `role_granted` audit row after a grant followed by a re-grant, proving
  the publish-only-on-change rule.
  Date: 2026-07-09

- Decision: The CLI accepts a user reference as either the typed id (`user_...`, the
  KindID text) or a bare UUID.
  Rationale: `shomei-admin audit` speaks UUIDs (the denormalized audit columns), while
  API responses render KindID text; operators will paste either. `parseId` first,
  `Data.UUID.fromText` + `userIdFromUUID` as fallback.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Everything below was verified
against the working tree on 2026-07-07.

### The repository at a glance

Shōmei is a multi-package Cabal project (build inside `nix develop`; `cabal build all`,
`cabal test all`). The packages this plan touches:

- `shomei-core` — pure domain types (`shomei-core/src/Shomei/Domain/`), *effects* (abstract
  operation interfaces defined with the `effectful` library, under
  `shomei-core/src/Shomei/Effect/`), and *workflows* (the use-case functions under
  `shomei-core/src/Shomei/Workflow*.hs` that compose effects). An **effect** here is a GADT
  of operations plus `send`-based helper functions; an **interpreter** is a concrete
  implementation that "peels" the effect off the `Eff es` type-level list.
- `shomei-postgres` — hasql/PostgreSQL interpreters under `shomei-postgres/src/Shomei/Postgres/`.
- `shomei-servant` — the HTTP surface: route record `ShomeiAPI`
  (`shomei-servant/src/Shomei/Servant/API.hs`), DTOs (`DTO.hs`), the auth seam (`Auth.hs`,
  `Authz.hs`, `Seam.hs`), handlers (`Handlers.hs`), error mapping (`Error.hs`), and the
  OpenAPI derivation (`OpenApi.hs`).
- `shomei-server` — the Warp executable (`shomei-server`) and the operator CLI
  (`shomei-admin`, entry point `shomei-server/app/Admin.hs`, subcommand modules in
  `shomei-server/app/Shomei/Admin/`).
- `shomei-migrations` — timestamped SQL files under `shomei-migrations/sql-migrations/`,
  applied by the `codd` tool (embedded at compile time; the Justfile recipe
  `just new-migration name=<slug>` scaffolds a file with the required
  `-- codd: in-txn` header and `SET search_path TO shomei, pg_catalog;`).
- `shomei-client` — curated `servant-client` wrappers (`shomei-client/src/Shomei/Client.hs`)
  over `genericClient` for `ShomeiAPI`.

Every module starts with `import Shomei.Prelude` (a custom prelude replacing `Prelude`;
it already exports `Text`, `UTCTime`, `Set` is *not* in it — import `Data.Set` qualified).

Per the repository's dependency-lookup convention, when an exact library API is needed
(hasql encoders, servant-server internals), run `mori registry show <project> --full` and
read the source on disk. Never guess, and never search `/nix/store`.

### The hole, precisely

`shomei-core/src/Shomei/Workflow/Session.hs` (lines ~41–64):

```haskell
buildClaims :: ShomeiConfig -> UserId -> SessionId -> UTCTime -> AuthClaims
buildClaims cfg uid sid ts =
  AuthClaims
    { subject = uid, sessionId = sid, issuer = cfg.issuer, audience = cfg.audience,
      issuedAt = ts, expiresAt = addUTCTime cfg.accessTokenTTL ts,
      scopes = Set.empty,
      roles = Set.empty,
      actor = Nothing, extraClaims = noExtraClaims }

buildClaimsWith :: ShomeiConfig -> Object -> UserId -> SessionId -> UTCTime -> AuthClaims
buildClaimsWith cfg extra uid sid ts =
  (buildClaims cfg uid sid ts) {extraClaims = mkExtraClaims extra}
```

`buildClaimsWith` exists but **no standard workflow calls it**. The callers of `buildClaims`
that mint user-session tokens (verify with `grep -rn buildClaims shomei-core/src`):

- `shomei-core/src/Shomei/Workflow.hs` line ~152 — inside `signup` (which mints its own
  first session inline rather than via `issueSession`);
- `shomei-core/src/Shomei/Workflow.hs` line ~311 — inside `refresh` (token rotation
  re-signs fresh claims, which is why role changes propagate on refresh);
- `shomei-core/src/Shomei/Workflow/Session.hs` line ~101 — inside `issueSession`, the
  shared tail used by `login` (non-MFA arm), `Mfa.completeMfa`, and
  `Mfa.completePasswordlessLogin`;
- `shomei-core/src/Shomei/Workflow/ServiceToken.hs` line ~89 — service tokens, which then
  overwrite `scopes` with the requested allow-listed set (left alone; see Decision Log).

`AuthClaims` is defined in `shomei-core/src/Shomei/Domain/Claims.hs`:
`Role` and `Scope` are `newtype ... Text`; `mkExtraClaims` filters `reservedClaimKeys`.

The phantom combinators, `shomei-servant/src/Shomei/Servant/Authz.hs`:

```haskell
type RequireRole :: Symbol -> Type
data RequireRole r

type RequireScope :: Symbol -> Type
data RequireScope s

requireRole :: Role -> AuthUser -> Handler ()
requireRole role u
  | role `Set.member` u.authRoles = pure ()
  | otherwise = throwError err403 {errBody = "missing required role"}
```

(The type parameter is `r`, not `role` — under GHC2024 `RoleAnnotations` is on and `role`
is a context-sensitive keyword.) The only real guard is the `requireRole (Role "admin")`
call at the top of `auditEventsH` in `shomei-servant/src/Shomei/Servant/Handlers.hs`
(~line 387). The `auditEvents` route in `API.hs` (~line 218) carries `Authenticated` plus a
comment admitting no production flow grants the role.

### Authentication plumbing you will reuse

`shomei-servant/src/Shomei/Servant/Auth.hs` defines Servant *generalized auth*:
`type Authenticated = AuthProtect "shomei-jwt"`, with
`type instance AuthServerData (AuthProtect "shomei-jwt") = AuthUser`. The server side is an
`AuthHandler Request AuthUser` built by `authHandler` and registered in the Servant
`Context` by `authContext` in `shomei-server/src/Shomei/Server/Boot.hs`:

```haskell
authContext :: Seam.Env -> Context '[AuthHandler Request AuthUser]
authContext senv = authHandler senv.verifier :. EmptyContext
```

`AuthUser` carries `authRoles :: Set Role` and `authScopes :: Set Scope` extracted from the
verified claims. This context-registered handler is exactly what the new `HasServer`
instances will fetch (via `HasContextEntry`) and run.

### The effect/interpreter/stack idiom you will copy

A port, e.g. `shomei-core/src/Shomei/Effect/SessionStore.hs`:

```haskell
data SessionStore :: Effect where
  CreateSession :: NewSession -> SessionStore m Session
  ...
type instance DispatchOf SessionStore = Dynamic

createSession :: (SessionStore :> es) => NewSession -> Eff es Session
createSession = send . CreateSession
```

A PostgreSQL interpreter, e.g. `shomei-postgres/src/Shomei/Postgres/SessionStore.hs`:
`interpret_ \case ...`, statements built with `preparable` + `Hasql.Encoders`/`Decoders`
(`contrazip2`… for tuples), run via `runSession (Session.statement input stmt)` from
`Shomei.Postgres.Database`, failures surfaced as
`throwError (InternalAuthError ("database error: " <> tshow e))`. Ids convert with
`userIdToUUID`/`userIdFromUUID` (`Shomei.Id`; every id is an `mmzk-typeid` `KindID` — a
UUIDv7 with a type-level prefix).

There are FOUR stack assemblies, all of which must gain any new effect **in the same
relative position** (the server bridges the smaller onto the larger with `effectful`'s
`inject`, so keep the lists aligned):

1. `shomei-servant/src/Shomei/Servant/Seam.hs` — `type AppEffects = '[UserStore, …, IOE]`,
   the handler-facing list.
2. `shomei-server/src/Shomei/Server/App.hs` — the same list extended with `Database` and
   `Error AuthError` at the base, plus `runAppIO`, the interpreter chain (order is
   load-bearing; every SQL-issuing port is interpreted above `runDatabasePool`).
3. `shomei-core/src/Shomei/Effect/InMemory.hs` — one in-memory interpreter per port over an
   `IORef World`, composed by `runInMemory`; the individual interpreters are also exported
   for the servant test's hybrid stack.
4. `shomei-postgres/test/Main.hs` — the postgres test harness's own `AppEffects`/`runApp`.

Additionally `shomei-server/app/Shomei/Admin/Users.hs` (`createUserAction`) assembles a
*private* minimal chain to run `Wf.signup` — it interprets exactly the effects `signup`
demands, so widening `signup`'s constraints means widening that chain too.

### Configuration

`ShomeiConfig` (`shomei-core/src/Shomei/Config.hs`, `data ShomeiConfig` at line ~221) is
plain data with `FromJSON`/`ToJSON` instances and a `defaultShomeiConfig :: Issuer ->
Audience -> ShomeiConfig` constructor (line ~278). The standalone server loads it in
`shomei-server/src/Shomei/Server/Config.hs`: defaults → optional Dhall file
(`$SHOMEI_CONFIG`, rendered by `dhall-to-json` and decoded) → individual `SHOMEI_*`
environment overrides (see `applyEnv`, line ~211 onward, for the `textEnv`/`intEnv`
helpers to imitate). Milestone 2 adds the `defaultRoles` field here and a
`SHOMEI_DEFAULT_ROLES` override (comma-separated role names). Because the record has
`FromJSON`, adding a field with no default breaks decoding of existing config files —
follow the loader's existing pattern for optional fields (GHC's record-completeness errors
plus the loader tests will point at every construction site).

### The audit-event vocabulary

`shomei-core/src/Shomei/Domain/Event.hs` defines `data AuthEvent` with **25 constructors**
(from `UserRegistered` to `ServiceTokenIssued`), each carrying a `*Data` record with an
`occurredAt :: UTCTime`. `shomei-core/src/Shomei/Domain/EventCodec.hs` is the single source
of truth for the envelope: `projectAuthEvent` maps an event to
`(Maybe UUID userId, Maybe UUID sessionId, Text event_type, Value payload, UTCTime)`, and
`reconstructAuthEvent` inverts it by dispatching on `event_type`. The test
`shomei-core/test/Shomei/Domain/EventCodecSpec.hs` round-trips **every** constructor and
has a count guard (`testConstructorCount`, currently 25) that fails loudly when a
constructor is added — you will bump it to 27.

### The CLI you are extending

`shomei-server/app/Admin.hs` is an `optparse-applicative` tree:
`data Command = Migrate | Keys KeysCommand | Users UsersCommand | Audit AuditCommand`,
dispatched by `hsubparser`. Subcommand modules live in `shomei-server/app/Shomei/Admin/`
(`Env.hs` exposes `AdminEnv {config, pool, connStr}` from `DATABASE_URL` etc.; `Audit.hs`
shows the list/filter/output style; `Users.hs` shows driving a core workflow through a
hand-rolled postgres chain). New modules must be added to `other-modules` of **both** the
`executable shomei-admin` and the `shomei-admin-test` stanzas in
`shomei-server/shomei-server.cabal`.

### OpenAPI

`shomei-servant/src/Shomei/Servant/OpenApi.hs` derives the spec from the Servant types
(`toOpenApi (Proxy @(NamedRoutes ShomeiAPI))`) and already contains *pass-through*
`HasOpenApi` instances for `RequireRole`/`RequireScope` (they currently add nothing).
`cabal run shomei-openapi > docs/api/openapi.json` regenerates the committed spec; the
conformance suite `shomei-servant-openapi-test` (in `shomei-servant/test-openapi/Main.hs`)
validates every `ToJSON` against its `ToSchema` and asserts the document covers exactly
24 paths. **Spec regeneration is part of any route change.** This plan changes one route's
combinator (no path count change) and the combinator instances.


## Plan of Work

Five milestones. Each is independently verifiable; commit at each boundary.

### Milestone 1 — Role persistence: registry + grants tables, port, interpreters, audit events

Scope: after this milestone the repository can durably declare "role R exists" and record
"user U has role R", read both back, revoke grants, refuse grants of undeclared roles, and
every grant/revoke is an audit event — proven by postgres interpreter tests. Nothing reads
the store at mint time yet.

**1.1 The migration.** From the repo root (inside `nix develop`):
`just new-migration name=shomei-role-grants`, then edit the generated file to:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_roles (
  role        text        PRIMARY KEY,
  description text        NULL,
  created_at  timestamptz NOT NULL
);

INSERT INTO shomei_roles (role, description, created_at)
VALUES ('admin', 'Full access to the shomei /admin surface and admin CLI-equivalent HTTP routes', now())
ON CONFLICT (role) DO NOTHING;

CREATE TABLE IF NOT EXISTS shomei_role_grants (
  user_id    uuid        NOT NULL REFERENCES shomei_users(user_id) ON DELETE CASCADE,
  role       text        NOT NULL REFERENCES shomei_roles(role),
  granted_by uuid        NULL REFERENCES shomei_users(user_id),
  granted_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, role)
);

CREATE INDEX IF NOT EXISTS shomei_role_grants_role_idx ON shomei_role_grants (role);
```

`shomei_roles` is the registry (Decision Log): the catalog of roles an operator has
declared, seeded with `admin` so the bootstrap grant works on a fresh database with no
prior `roles define`. The FK from `shomei_role_grants.role` makes "grants reference
defined roles" a database invariant, not just workflow discipline. The composite primary
key makes a duplicate grant a no-op-detectable conflict; `ON DELETE CASCADE` means
deleting a user removes their grants; `granted_by` is nullable for CLI bootstrap grants
and config-driven default-role grants (Decision Log). There is deliberately no CASCADE on
the role FK — the registry is append-only in this plan, so the case never arises. Because
migrations are embedded via Template Haskell, `just migrate` touches the cabal file
first — nothing else to wire.

**1.2 The errors.** Add `UserNotFound` and `RoleNotDefined Role` constructors to
`AuthError` in `shomei-core/src/Shomei/Error.hs` (grant/revoke against a nonexistent user,
and grants of undeclared roles, must fail cleanly; plan 39 reuses both). Add their arms to
`authErrorToServerError` in `shomei-servant/src/Shomei/Servant/Error.hs`:
`UserNotFound -> json err404 "user_not_found" "User not found"` and
`RoleNotDefined (Role r) -> json err422 "role_not_defined" ("Role not defined: " <> r)`
(422 Unprocessable Content: the request was well-formed but names a role the deployment
never declared — a client mistake, not a missing resource; plan 39's grant route relies on
this mapping). GHC's exhaustiveness warnings (the repo builds with warnings on) will point
at any other `case` over `AuthError` needing an arm.

**1.3 The events.** In `shomei-core/src/Shomei/Domain/Event.hs` add two constructors and
records, mirroring the existing style exactly (`deriving stock (Generic, Eq, Show)`,
`deriving anyclass (FromJSON, ToJSON)`, strict fields, `occurredAt` last):

```haskell
data RoleGrantedData = RoleGrantedData
  { userId :: !UserId,
    role :: !Role,
    -- | the admin who granted it; 'Nothing' for a CLI bootstrap grant
    grantedBy :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }

data RoleRevokedData = RoleRevokedData
  { userId :: !UserId,
    role :: !Role,
    revokedBy :: !(Maybe UserId),
    occurredAt :: !UTCTime
  }
```

(`Role` needs importing from `Shomei.Domain.Claims`; note `Scope` is already imported
there for `ServiceTokenIssuedData`.) Add `RoleGranted RoleGrantedData` and
`RoleRevoked RoleRevokedData` arms to `AuthEvent`, export the records.

In `shomei-core/src/Shomei/Domain/EventCodec.hs` add arms to `projectAuthEvent` (event
types `"role_granted"` / `"role_revoked"`, `user_id` column = the subject `userId`, no
session id) and to `reconstructAuthEvent`. In
`shomei-core/test/Shomei/Domain/EventCodecSpec.hs` add two round-trip cases and change the
count guard 25 → 27 (the guard failing is your checklist that you found every site).

**1.4 The port.** Create `shomei-core/src/Shomei/Effect/RoleStore.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The role port: the declared role catalog ("registry") and durable "user has role"
-- facts (EP-1 of MasterPlan 7).
module Shomei.Effect.RoleStore
  ( RoleStore (..),
    RoleDefinition (..),
    defineRole,
    listDefinedRoles,
    grantRole,
    revokeRole,
    listRolesForUser,
  )
where

import Data.Set (Set)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Claims (Role)
import Shomei.Id (UserId)
import Shomei.Prelude

-- | One row of the role registry (the @shomei_roles@ table): a role an operator has
-- declared grantable, with an optional human description.
data RoleDefinition = RoleDefinition
  { role :: !Role,
    description :: !(Maybe Text),
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data RoleStore :: Effect where
  -- | Declare a role in the registry. Returns 'True' if newly defined, 'False' if it
  -- already existed (idempotent; the description of an existing role is NOT updated).
  DefineRole :: Role -> Maybe Text -> UTCTime -> RoleStore m Bool
  -- | The full registry, sorted by role name. Deployments have few roles; no paging.
  ListDefinedRoles :: RoleStore m [RoleDefinition]
  -- | Record a grant. Returns 'True' if the grant is new, 'False' if it already existed
  -- (idempotent; callers publish the audit event only on 'True').
  GrantRole :: UserId -> Role -> Maybe UserId -> UTCTime -> RoleStore m Bool
  -- | Remove a grant. Returns 'True' if a grant was removed.
  RevokeRole :: UserId -> Role -> RoleStore m Bool
  ListRolesForUser :: UserId -> RoleStore m (Set Role)

type instance DispatchOf RoleStore = Dynamic

defineRole :: (RoleStore :> es) => Role -> Maybe Text -> UTCTime -> Eff es Bool
defineRole r desc ts = send (DefineRole r desc ts)

listDefinedRoles :: (RoleStore :> es) => Eff es [RoleDefinition]
listDefinedRoles = send ListDefinedRoles

grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> UTCTime -> Eff es Bool
grantRole uid r by ts = send (GrantRole uid r by ts)

revokeRole :: (RoleStore :> es) => UserId -> Role -> Eff es Bool
revokeRole uid r = send (RevokeRole uid r)

listRolesForUser :: (RoleStore :> es) => UserId -> Eff es (Set Role)
listRolesForUser = send . ListRolesForUser
```

Add `Shomei.Effect.RoleStore` to `shomei-core.cabal` `exposed-modules`. `RoleDefinition`
is the shape plan 39's `GET /admin/roles` route will serialize — the route itself is
plan 39's; this plan ships the port operation and the record.

**1.5 The workflow.** Create `shomei-core/src/Shomei/Workflow/Roles.hs` so the CLI (this
plan) and the admin API (plan 39) share one audited path:

```haskell
grantRoleTo ::
  (UserStore :> es, RoleStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  Maybe UserId ->  -- the granting actor (Nothing = CLI bootstrap / system)
  UserId ->        -- the subject
  Role ->
  Eff es (Either AuthError Bool)  -- Right True = newly granted; Right False = already had it

revokeRoleFrom :: (…same…) => Maybe UserId -> UserId -> Role -> Eff es (Either AuthError Bool)

rolesOf :: (UserStore :> es, RoleStore :> es) => UserId -> Eff es (Either AuthError (Set Role))

-- | Grant every configured default role to a fresh user (called by 'signup' right after
-- 'createUser'; audited as role_granted with no actor). Boot validated the roles against
-- the registry (see 'undefinedDefaultRoles'), so this does not re-check definitions.
applyDefaultRoles ::
  (RoleStore :> es, AuthEventPublisher :> es) =>
  ShomeiConfig -> UserId -> UTCTime -> Eff es ()

-- | The configured default roles missing from the registry — nonempty means the config
-- is broken and the process should refuse to serve. The standalone server calls this at
-- boot; embedding hosts should call it wherever they assemble their ports.
undefinedDefaultRoles :: (RoleStore :> es) => ShomeiConfig -> Eff es (Set Role)
```

`grantRoleTo` first checks `findUserById` (a `Nothing` is `Left UserNotFound`), then
checks the role is defined — `listDefinedRoles`, membership on the role names (catalogs
are tiny; no dedicated exists-op) — returning `Left (RoleNotDefined r)` if not, then calls
the store, and publishes `RoleGranted` **only when the store reported a change** (so
re-running a grant does not spam the audit trail). `revokeRoleFrom` needs no registry
check (revoking an existing grant of any role must always work). `applyDefaultRoles`
iterates `cfg.defaultRoles` calling the store's `grantRole` with `Nothing` as actor and
publishing `RoleGranted` per new grant — it deliberately skips the `findUserById` and
registry checks (`signup` just created the user; boot validated the roles, and the
registry is append-only so they cannot have vanished). The workflow treats the `Role` text
as opaque and does not validate its *shape*: input validation (trimming, rejecting blank
role text) belongs to the boundary layers — the CLI in Milestone 3 and plan 39's HTTP
handlers — matching how `mkEmail`/`mkLoginId` validate before workflows run. Do not invent
a new `AuthError` for a blank role; the boundaries refuse it before the workflow ever sees
it. State this in the module haddock.

**1.6 The PostgreSQL interpreter.** Create
`shomei-postgres/src/Shomei/Postgres/RoleStore.hs` exporting `runRoleStorePostgres`,
mirroring `Shomei.Postgres.SessionStore` (`interpret_`, `runSession`, `dbFail`). Five
statements:

```sql
-- define: rowsAffected 0 means the role was already defined
INSERT INTO shomei.shomei_roles (role, description, created_at)
VALUES ($1, $2, $3)
ON CONFLICT (role) DO NOTHING

-- list-defined
SELECT role, description, created_at FROM shomei.shomei_roles ORDER BY role

-- grant: rowsAffected 0 means the grant already existed
INSERT INTO shomei.shomei_role_grants (user_id, role, granted_by, granted_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (user_id, role) DO NOTHING

-- revoke: rowsAffected 0 means there was nothing to revoke
DELETE FROM shomei.shomei_role_grants WHERE user_id = $1 AND role = $2

-- list
SELECT role FROM shomei.shomei_role_grants WHERE user_id = $1 ORDER BY role
```

Use `D.rowsAffected` (yields `Int64`; `> 0` gives the `Bool`) for define/grant/revoke,
`D.rowList` with a three-column row decoder (`text`, nullable `text`, `timestamptz` →
`RoleDefinition`) for list-defined, and `D.rowList (D.column (D.nonNullable D.text))`
(then `Set.fromList . map Role`) for list. Encoders: `contrazip3` for define (unwrap
`Role`, nullable text description, timestamptz), `contrazip4 (E.param (E.nonNullable
E.uuid)) (E.param (E.nonNullable E.text)) (E.param (E.nullable E.uuid)) (E.param
(E.nonNullable E.timestamptz))` for grant (convert with `userIdToUUID`, `fmap
userIdToUUID`, and unwrap `Role`); `contrazip2` for revoke. Constraint: `(Database :> es,
Error AuthError :> es)` — no `IOE` needed (no `liftIO`; the audit reader set this
precedent). Confirm the exact `D.rowsAffected` name against the installed hasql via
`mori registry show hasql --full` before coding. Add the module to `shomei-postgres.cabal`.

**1.7 The in-memory interpreter.** In `shomei-core/src/Shomei/Effect/InMemory.hs` add two
fields to `World`: `roleGrants :: !(Map UserId (Set Role))` (initialize empty in
`emptyWorld`) and `definedRoles :: !(Map Role (Maybe Text))` (initialize with `admin`
pre-defined, mirroring the migration's seed so in-memory and postgres stacks agree on a
fresh world). Export `runRoleStore :: (IOE :> es) => IORef World -> Eff (RoleStore : es) a
-> Eff es a` implementing the five ops over the maps (define returns `False` when the role
is already present and does not overwrite the description; grant returns `False` when the
role is already granted; `granted_by`/timestamps are not modeled — `ListDefinedRoles`
fabricates a fixed `createdAt`), and stack it inside `runInMemory` in the same relative
position you add it to the other lists (M2). The in-memory grant does **not** enforce the
FK (the workflow's registry check is the tested path; the FK is postgres-only defense in
depth — note this asymmetry in a comment).

**1.8 Interpreter tests.** In `shomei-postgres/test/Main.hs` (which runs against an
ephemeral migrated PostgreSQL): add `RoleStore` to the harness stack + chain, then a
`testRoleStore` that: asserts the seeded registry (`listDefinedRoles` contains `admin`),
`defineRole "auditor"` → `True`, duplicate define → `False`, list-defined shows both
sorted; creates a user through the existing store helpers, asserts grant → `True`,
duplicate grant → `False`, `listRolesForUser` = the granted set, revoke → `True`, revoke
again → `False`, list empty; asserts the raw port's grant of an **undefined** role
surfaces the FK violation as `InternalAuthError` while `Shomei.Workflow.Roles.grantRoleTo`
returns `Left (RoleNotDefined …)` before touching the table; and asserts a grant for a
random nonexistent UUID-derived user id surfaces the user FK violation as
`InternalAuthError` (or pre-check — the workflow pre-checks, the raw port may FK-fail;
assert whichever the port does, and note it).

Acceptance: `cabal test shomei-core:shomei-core-test shomei-postgres:shomei-postgres-test`
green, including the 27-constructor guard and the new role-store test.

### Milestone 2 — Claims enrichment at every mint, and default roles at signup

Scope: after this milestone, a granted role appears in the `roles` claim of every token
minted afterward (signup/login/MFA/passwordless/refresh), hosts have a hook to add claims,
and a deployment configured with `defaultRoles` mints them onto every new user's first
token (with the server refusing to boot if the config names an undefined role). Proven by
tests that mint before/after a grant and by a signup-under-config test.

**2.1 The enrichment effect.** Create `shomei-core/src/Shomei/Effect/ClaimsEnricher.hs`:

```haskell
-- | The host claims-enrichment hook (EP-1 of MasterPlan 7): called at every user-session
-- token mint with the subject and the roles read from the 'RoleStore'; returns a delta the
-- core merges. The delta's extra-claims object is filtered through 'mkExtraClaims', so a
-- host (or compromised host code path) can never override a reserved claim. The OIDC and
-- token-exchange plans (MasterPlan 7 EP-5/EP-6) MUST build their claims through this same
-- hook rather than re-reading stores in the HTTP layer.
--
-- __Do not mirror live authorization decisions into JWT claims through this hook.__
-- Claims are minted once and are then static for the token's lifetime; a decision copied
-- from a live authorization system (e.g. a check against the en ReBAC engine — see
-- @docs\/plans\/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md@)
-- is stale the moment the underlying relationship changes, silently granting revoked
-- access until the token expires. This hook is for coarse, slow-moving hints — tenant
-- ids, plan tiers, extra scopes — not for per-resource permissions. Check fine-grained
-- permissions live, in the handler, against the authorization system.
module Shomei.Effect.ClaimsEnricher
  ( ClaimsEnricher (..),
    ClaimsDelta (..),
    emptyClaimsDelta,
    enrichClaims,
    runClaimsEnricherNull,
    runClaimsEnricherPure,
  )
where

data ClaimsDelta = ClaimsDelta
  { extraRoles :: !(Set Role),
    extraScopes :: !(Set Scope),
    extraClaims :: !Object
  }

emptyClaimsDelta :: ClaimsDelta

data ClaimsEnricher :: Effect where
  EnrichClaims :: UserId -> Set Role -> ClaimsEnricher m ClaimsDelta

enrichClaims :: (ClaimsEnricher :> es) => UserId -> Set Role -> Eff es ClaimsDelta

-- | The default: no enrichment (the standalone server uses this).
runClaimsEnricherNull :: Eff (ClaimsEnricher : es) a -> Eff es a

-- | A pure hook for hosts/tests: supply a function.
runClaimsEnricherPure :: (UserId -> Set Role -> ClaimsDelta) -> Eff (ClaimsEnricher : es) a -> Eff es a
```

(Write the bodies with `interpret_ \case EnrichClaims uid rs -> …` following any small
existing interpreter; `runClaimsEnricherNull = runClaimsEnricherPure \_ _ -> emptyClaimsDelta`.)
Export from the cabal file.

**2.2 `buildEnrichedClaims`.** In `shomei-core/src/Shomei/Workflow/Session.hs` add:

```haskell
buildEnrichedClaims ::
  (RoleStore :> es, ClaimsEnricher :> es) =>
  ShomeiConfig -> UserId -> SessionId -> UTCTime -> Eff es AuthClaims
buildEnrichedClaims cfg uid sid ts = do
  storeRoles <- listRolesForUser uid
  delta <- enrichClaims uid storeRoles
  pure
    (buildClaims cfg uid sid ts)
      { roles = storeRoles <> delta.extraRoles,
        scopes = delta.extraScopes,
        extraClaims = mkExtraClaims delta.extraClaims
      }
```

Keep `buildClaims`/`buildClaimsWith` exported (the service-token workflow still uses
`buildClaims`; `buildClaimsWith` remains a documented host utility). Update the module
haddock: the "MVP issues no scopes or roles" comment on `buildClaims` is now "the *base*
claims; the standard workflows call 'buildEnrichedClaims'".

**2.3 Rewire the three mint sites.** Change each
`access <- signAccessToken (buildClaims cfg <uid> <sid> ts)` to
`access <- signAccessToken =<< buildEnrichedClaims cfg <uid> <sid> ts` at:
`Shomei.Workflow.signup` (~line 152), `Shomei.Workflow.refresh` (~line 311), and
`Shomei.Workflow.Session.issueSession` (~line 101). Add `RoleStore :> es` and
`ClaimsEnricher :> es` to those functions' constraint lists (and to `login`'s if it
delegates constraints — GHC will tell you; also `Shomei.Workflow.Mfa`'s two completions
inherit via `issueSession`). Do **not** touch `ServiceToken.hs` or `Impersonation.hs`
(Decision Log).

**2.4 Stack wiring.** Insert `RoleStore` immediately after `UserStore`, and
`ClaimsEnricher` immediately after `Notifier`, in ALL of:

- `shomei-servant/src/Shomei/Servant/Seam.hs` `AppEffects`;
- `shomei-server/src/Shomei/Server/App.hs` `AppEffects`, and in `runAppIO` add
  `runRoleStorePostgres` adjacent to `runUserStorePostgres` and `runClaimsEnricherNull`
  adjacent to `runNotifierFromConfig` (remember the chain is written outermost-last, so the
  new entries go where their neighbors are);
- `shomei-core/src/Shomei/Effect/InMemory.hs` `runInMemory` (use the M1 `runRoleStore` and
  `runClaimsEnricherNull`);
- `shomei-postgres/test/Main.hs` harness stack and chain;
- the hybrid stack in `shomei-servant/test/Main.hs` (it composes `InMemory` interpreters —
  add the two new runners in the same spots);
- `shomei-server/app/Shomei/Admin/Users.hs` `createUserAction`'s private chain (its
  `signup` call now demands both effects: add `runRoleStorePostgres` and
  `runClaimsEnricherNull`).

The `inject` bridge in `Shomei.Server.Boot.seamEnv` type-checks only if the seam list is a
subset of the server list — building `shomei-server` verifies the alignment.

**2.5 Default roles.** Three edits, in dependency order:

First, the config field. In `shomei-core/src/Shomei/Config.hs` add
`defaultRoles :: !(Set Role)` to `data ShomeiConfig` (line ~221; import `Role` from
`Shomei.Domain.Claims` and `Data.Set` qualified) and `defaultRoles = Set.empty` to
`defaultShomeiConfig` (line ~278). In `shomei-server/src/Shomei/Server/Config.hs` add a
`SHOMEI_DEFAULT_ROLES` override in `applyEnv` (line ~211 onward): comma-separated role
names, split with `Text.splitOn ","`, trimmed, blanks dropped, into `Set Role` — follow
the existing `textEnv` helper style. Keep the loader's precedence (defaults → Dhall file →
env).

Second, the signup application. In `Shomei.Workflow.signup`
(`shomei-core/src/Shomei/Workflow.hs`), immediately after the `createUser` call (line
~131) and before the session is created, add
`applyDefaultRoles cfg user.userId ts` (from `Shomei.Workflow.Roles`, Milestone 1.5). The
grants therefore exist before 2.3's `buildEnrichedClaims` runs at line ~152, so the
**first** access token already carries the default roles, and each grant lands a
`role_granted` audit row with no actor. `signup` already has (after 2.3) every constraint
`applyDefaultRoles` needs. `shomei-admin users create` drives this same `signup` through
its private chain (`shomei-server/app/Shomei/Admin/Users.hs`), so CLI-created users get
default roles with no further code — the 2.4 wiring already added the interpreters it
needs.

Third, boot validation. In `shomei-server/src/Shomei/Server/Boot.hs` (or the server's
startup path in `Shomei.Server.App` — wherever the pool exists before Warp binds), when
`cfg.defaultRoles` is nonempty, run `Shomei.Workflow.Roles.undefinedDefaultRoles` over a
minimal chain (`runEff . runErrorNoCallStack . runDatabasePool pool .
runRoleStorePostgres`) and, if the result is nonempty, exit with a message naming the
missing roles and the fix:

```text
shomei-server: defaultRoles names undefined roles: member, staff
define them first: shomei-admin roles define member
```

Failing at boot (not at signup time) turns a config typo into an immediate, obvious
failure instead of intermittent signup 5xx responses (Decision Log). Embedding hosts
assemble their own boot; the `undefinedDefaultRoles` haddock tells them to call it when
they set `defaultRoles`.

**2.6 Tests.** (a) In the servant end-to-end suite (`shomei-servant/test/Main.hs`), grant
`admin` to a user through the in-memory `RoleStore` (drive `Shomei.Workflow.Roles.grantRoleTo`
through the harness), log the user in over HTTP, and assert the decoded access token's
`roles` claim contains `admin` (the suite already decodes/verifies tokens for other
assertions — reuse that machinery), then hit `GET /admin/audit/events` with it → 200.
(b) Refresh propagation: grant a role *after* login, `POST /auth/refresh`, assert the new
access token carries it. (c) Reserved-key safety: a core-level test running
`buildEnrichedClaims` under `runClaimsEnricherPure` with a delta whose `extraClaims` tries
to set `"sub"`/`"roles"` — assert the resulting `AuthClaims.extraClaims` dropped them.
(d) A postgres-side test that a granted role survives the real store into
`buildEnrichedClaims` output. (e) Default roles: a core-level (in-memory) test that runs
`signup` under a config with `defaultRoles = Set.fromList [Role "member"]` after defining
`member` in the world, asserting the returned access token's claims carry `member` and a
`role_granted` event with no actor was published; and a companion negative test that
`undefinedDefaultRoles` reports a role missing from the registry.

Acceptance: `cabal build all && cabal test all` green.

### Milestone 3 — The CLI granting path

Scope: an operator can bootstrap the first admin without any HTTP call. Proven by the
admin test suite and a live transcript.

Create `shomei-server/app/Shomei/Admin/Roles.hs` exporting `RolesCommand`, `rolesParser`,
`runRoles`, modeled on `Shomei.Admin.Audit` (parser shape) and `Shomei.Admin.Users`
(running an effectful chain over `AdminEnv.pool`). Commands:

```text
shomei-admin roles define       <name> [--description <text>]
shomei-admin roles list-defined
shomei-admin roles grant  --user <user_… | UUID> --role <text>
shomei-admin roles revoke --user <user_… | UUID> --role <text>
shomei-admin roles list   --user <user_… | UUID>
```

Parse the user reference with `parseId` first, falling back to `Data.UUID.fromText` +
`userIdFromUUID` (Decision Log); trim role names and reject blank with a stderr `die`.
`runRoles` assembles a small chain — `runEff . runErrorNoCallStack . runDatabasePool
env.pool . runClockIO . runAuthEventPublisherPostgres . runRoleStorePostgres .
runUserStorePostgres` — and drives `Shomei.Workflow.Roles` with `Nothing` as the actor
(`define`/`list-defined` call the `RoleStore` port directly — no user lookup, no audit
event; Decision Log). Output: `defined role auditor` / `role auditor was already defined`
(exit 0 both ways); `list-defined` prints one role per line with its description
(`admin — Full access to the shomei /admin surface…`); `granted admin to user_…` /
`user already had role admin` (exit 0 both ways, the Bool distinguishes wording);
`revoked` / `no such grant`; `list` prints one role per line. `Left UserNotFound` →
`die "user not found: …"` (exit 1). `Left (RoleNotDefined r)` →
`die "role not defined: <r> (define it first: shomei-admin roles define <r>)"` (exit 1) —
this is the typo guard working. Wire `Roles RolesCommand` into `Admin.hs`'s
`Command`/`commandParser`/`run`, and add the module to both `other-modules` lists in
`shomei-server/shomei-server.cabal`.

Add a test to the `shomei-admin-test` suite mirroring its existing audit test: against the
ephemeral migrated DB, define `auditor` → list-defined shows `admin` and `auditor`; create
a user, grant `auditor` → list shows it → revoke → list empty; grant a never-defined role
name → exit code 1 and the `role not defined` stderr message; and assert exactly two audit
rows (`role_granted`, `role_revoked`) landed via the audit reader (definitions add none).

### Milestone 4 — Enforcing `RequireRole`/`RequireScope`

Scope: the combinators genuinely enforce. After this milestone a route written
`RequireRole "admin" :> …` rejects an unauthenticated request with 401 and a role-less
principal with 403 — with no handler code at all — and the audit route is the first user.

**4.1 The instances.** In `shomei-servant/src/Shomei/Servant/Authz.hs`, keep the data
declarations, delete the "phantom / reserved for future HasServer" language, and add (names
below verified conceptually against servant-server's own
`Servant.Server.Experimental.Auth` instance — read the installed source via
`mori registry show servant --full` and confirm `addAuthCheck`, `withRequest`,
`DelayedIO`, `delayedFailFatal`, `runHandler`, `unAuthHandler` before coding):

```haskell
instance
  ( HasServer api ctx,
    HasContextEntry ctx (AuthHandler Request AuthUser),
    KnownSymbol r
  ) =>
  HasServer (RequireRole r :> api) ctx
  where
  type ServerT (RequireRole r :> api) m = AuthUser -> ServerT api m

  hoistServerWithContext _ pc nt s =
    hoistServerWithContext (Proxy :: Proxy api) pc nt . s

  route _ ctx subserver =
    route (Proxy :: Proxy api) ctx (subserver `addAuthCheck` withRequest check)
    where
      check :: Request -> DelayedIO AuthUser
      check req = do
        outcome <- liftIO (runHandler (unAuthHandler (getContextEntry ctx) req))
        user <- either delayedFailFatal pure outcome
        let needed = Role (Text.pack (symbolVal (Proxy :: Proxy r)))
        if needed `Set.member` user.authRoles
          then pure user
          else delayedFailFatal (forbidden "missing required role")
```

and the symmetric `RequireScope` instance checking `authScopes`, plus a shared
`forbidden :: Text -> ServerError` producing the same JSON body shape the guards use today
(`err403` with a JSON `{"error":"missing_role"|"missing_scope","message":…}` body and a
`Content-Type: application/json` header — matching `authErrorToServerError`'s style; plan
40 will sweep this into the universal envelope and owns that boundary). Note
`hoistServerWithContext`'s composition: `s :: AuthUser -> ServerT api m`, so it is
`hoistServerWithContext (Proxy @api) pc nt . s` — the sub-hoist applied after the
`AuthUser` argument. The instance *replaces* `Authenticated`: the auth handler from the
context runs inside the check (401s from it — "missing token"/"invalid token" — propagate
via `delayedFailFatal`), so a route carries `RequireRole "admin" :>` INSTEAD of
`Authenticated :>` and its handler still receives the `AuthUser`. Update the guard
functions' haddocks: they remain the tool for composite conditions (role OR scope), used
by plan 39.

**4.2 Switch the audit route.** In `API.hs` change `auditEvents` from
`"admin" :> "audit" :> "events" :> Authenticated :> …` to
`"admin" :> "audit" :> "events" :> RequireRole "admin" :> …` and rewrite the field comment
(the "no production flow grants that role" admission is now false — say the role is granted
via `shomei-admin roles grant` / plan 39). In `Handlers.hs` delete the now-redundant
`requireRole (Role "admin") user` line from `auditEventsH` (the signature keeps its
`AuthUser`). Update the `AppAPI` embeddability example at the bottom of `API.hs`:
`RequireRole "admin" :> Authenticated :> "admin" :> …` becomes
`RequireRole "admin" :> "admin" :> …`, and its comment now states the combinator is
enforcing.

**4.3 Client and OpenAPI truth.** `shomei-client`'s `genericClient` must still derive: add
`HasClient` instances that delegate to `AuthProtect "shomei-jwt"` (so callers pass the same
`bearer tok` authenticated-request value):

```haskell
instance (HasClient m api) => HasClient m (RequireRole r :> api) where
  type Client m (RequireRole r :> api) = Client m (AuthProtect "shomei-jwt" :> api)
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
```

Put these (orphans by the same design argument as `OpenApi.hs`'s header comment) in
`shomei-client/src/Shomei/Client.hs` or a small internal module with
`{-# OPTIONS_GHC -Wno-orphans #-}`; confirm the `HasClient` method set against the
installed `servant-client-core` via mori. In `OpenApi.hs`, replace the two pass-through
`HasOpenApi` instances with copies of the `AuthProtect "shomei-jwt"` instance body (they
now imply bearer auth, and the spec must say so). Regenerate the committed spec:

```bash
cabal run shomei-openapi > docs/api/openapi.json
```

The diff should show only the audit operation (still bearer-secured — ideally a no-op or
near-no-op diff) — path count stays 24, so the conformance suite's count assertion is
untouched.

**4.4 Tests.** In `shomei-servant/test/Main.hs` the test API's host admin route
(`"admin" :> "users" :> Authenticated :> …` with an in-handler `requireRole`) becomes
`RequireRole "admin" :> "admin" :> "users" :> …` with a guard-free handler — the existing
(g) assertions (non-admin → 403, admin → 200) now prove the combinator. Add: no token →
401; and a `RequireScope "kawa:ingest"`-gated test route proving a service token with the
scope passes and a plain login token gets 403 (the suite already mints scoped tokens for
the service-token tests — reuse).

### Milestone 5 — Live proof and documentation

Scope: the full loop demonstrated against a real server, and the docs stop describing the
hole. Run the transcript in Validation and Acceptance and paste the real output into this
plan. Then: rewrite `docs/user/security.md`'s "Known limitation — the `admin` role"
section into "Granting roles" (role registry and `roles define`, CLI bootstrap grant,
default roles via `defaultRoles`/`SHOMEI_DEFAULT_ROLES`, staleness semantics, revocation
lever); document the `ClaimsEnricher` hook for embedding hosts (a short section in
`docs/user/security.md` or `docs/user/architecture.md` — wherever `Notifier`'s host-hook
story lives, mirror it), including the "no live-decision mirroring" warning from 2.1;
update `docs/user/api.md`'s audit-endpoint paragraph; add a CHANGELOG entry under
Unreleased; tick EP-1 in MasterPlan 7's registry and Progress.

The rewritten security-model section must also state the **two-tier authorization story**
(Decision Log) so users can place Shōmei's roles correctly: Shōmei's flat roles + scopes
are the self-contained, bootstrap, coarse-grained tier — they work with zero extra
infrastructure, they gate Shōmei's own `/admin` endpoints, and (because en's server has no
caller authentication yet and plans to verify Shōmei JWTs when it gets one) they are what
cuts the authentication↔authorization bootstrap circularity. For robust fine-grained or
relationship-based authorization with live revocation ("editor of *this* project",
consistency tokens, caveats), the recommended graduation path is the sibling project en;
point the section at `docs/user/authorization.md` (created by
`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`;
until that plan lands, point at the plan document itself) and note that the built-in tier
grows permission indirection and time-bound grants in
`docs/plans/46-role-definitions-permissions-and-time-bound-grants.md` without ever being
removed in favor of en.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`, inside
the dev shell (`nix develop`). The dev PostgreSQL environment (`PGHOST`/`PGDATABASE`) comes
from the dev shell / `process-compose.yaml`; `just create-database` creates and migrates
the dev database idempotently.

```bash
nix develop            # once, at the start of the session
just create-database   # idempotent: create + migrate the dev database

# scaffold the migration (Milestone 1)
just new-migration name=shomei-role-grants
# → Wrote shomei-migrations/sql-migrations/<UTC-timestamp>-shomei-role-grants.sql

# after each edit batch:
cabal build all
cabal test all
```

Expected test-suite result shape (names as of 2026-07-07; counts will grow):

```text
shomei-core-test        ... all tests passed (incl. EventCodec 27-constructor guard)
shomei-postgres-test    ... all tests passed (incl. testRoleStore)
shomei-servant-test     ... all tests passed (combinator 401/403/200, enrichment claims)
shomei-servant-openapi-test ... 24 paths, ToJSON⇔ToSchema conformance passed
shomei-admin-test       ... all tests passed (roles define/grant/list/revoke round-trip, typo refusal)
```

Regenerate the OpenAPI spec whenever `API.hs`, a DTO, or an `OpenApi.hs` instance changes,
and commit the result:

```bash
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json
```

Commit at each milestone boundary with conventional-commit messages, e.g.:

```text
feat(core): add shomei_role_grants migration and RoleStore port (EP-1 M1)
feat(core): enrich claims from RoleStore + ClaimsEnricher hook at every mint (EP-1 M2)
feat(admin): add shomei-admin roles grant/revoke/list (EP-1 M3)
feat(servant): make RequireRole/RequireScope enforcing HasServer combinators (EP-1 M4)
docs(user): replace the admin-role known-limitation with the granting path (EP-1 M5)
```


## Validation and Acceptance

Beyond the suites above, the end-to-end proof (Milestone 5). Start the dev stack (server on
:8080; `process-compose` or `cabal run shomei-server` with the dev env), then:

```bash
# 1. create a user and capture their id
cabal run shomei-admin -- users create --email root@example.com --password 'Str0ng-Pass-123!'
# → created user user_01ABC... <root@example.com>

# 2. log in BEFORE any grant; the token works but /admin is forbidden
TOK=$(curl -s -XPOST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"root@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/admin/audit/events -H "Authorization: Bearer $TOK"
# → 403

# 3. a typo'd role name is refused (the registry at work), then grant admin for real,
#    log in again (fresh mint), and read the audit trail
cabal run shomei-admin -- roles grant --user user_01ABC... --role adminn
# → shomei-admin: role not defined: adminn (define it first: shomei-admin roles define adminn)
#   (exit code 1)
cabal run shomei-admin -- roles list-defined
# → admin — Full access to the shomei /admin surface and admin CLI-equivalent HTTP routes
cabal run shomei-admin -- roles grant --user user_01ABC... --role admin
# → granted admin to user_01ABC...
TOK=$(curl -s -XPOST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"root@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)
curl -s localhost:8080/admin/audit/events -H "Authorization: Bearer $TOK" | jq '.events[0].eventType'
# → HTTP 200; newest events include "login_succeeded" and a "role_granted"

# 4. revoke; outstanding token still works until it expires/refreshes (staleness semantics)
cabal run shomei-admin -- roles revoke --user user_01ABC... --role admin
# a refresh now mints a role-less token:
#   POST /auth/refresh with the stored refreshToken → new access token
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/admin/audit/events -H "Authorization: Bearer $NEW_TOK"
# → 403
```

Acceptance criteria, phrased as observable behavior:

- `shomei-admin roles define/list-defined/grant/revoke/list` behave as transcribed
  (idempotent wording on repeats; `user not found` on a bogus id; `role not defined` on a
  role name absent from the registry; exit codes 0/1 accordingly).
- With `SHOMEI_DEFAULT_ROLES=member` (after `roles define member`), a fresh signup's very
  first access token carries `member` in its `roles` claim and
  `shomei-admin audit events --type role_granted` shows the grant with no acting admin.
  With `SHOMEI_DEFAULT_ROLES=nosuchrole`, the server refuses to start, naming the role.
- A token minted after a grant carries the role; `GET /admin/audit/events` with it → 200.
- A token minted after revocation → 403 with a JSON error body; no token → 401.
- `shomei-admin audit events --type role_granted` lists the grant with the subject's
  user id (and `--type role_revoked` the revocation).
- A route protected only by the type (`RequireRole`/`RequireScope`, no handler guard)
  provably rejects: the servant test suite exercises 401/403/200 through a real Warp
  round-trip.
- `cabal build all` and `cabal test all` green; `cabal run shomei-openapi` output matches
  the committed `docs/api/openapi.json` byte-for-byte.


## Idempotence and Recovery

Every step is safe to repeat. The migration uses `CREATE TABLE IF NOT EXISTS` and codd
applies each file exactly once (re-running `just migrate` is a no-op); if you must iterate
on the migration during development, drop and recreate the *dev* database
(`dropdb "$PGDATABASE" && just create-database`) rather than editing an applied file —
never edit a migration that has been applied anywhere shared. Grants are idempotent by
design (`ON CONFLICT DO NOTHING`; the workflow publishes an event only on state change), so
re-running the CLI or a test seed causes no drift. Code changes are additive until
Milestone 4; if M4's combinator work stalls, everything before it still stands alone (the
audit route keeps its handler guard until 4.2 flips it — flip route and handler in the same
commit so no window exists where neither enforces). Regenerating `docs/api/openapi.json` is
deterministic; a dirty diff after regeneration means the spec drifted and must be
committed, not discarded.


## Interfaces and Dependencies

No new external dependencies: `effectful`, `hasql`, `contravariant-extras`, `servant`,
`servant-server`, `servant-client-core`, `optparse-applicative`, `containers`, `aeson` are
all already in the workspace (new cabal `build-depends` lines may be needed on individual
stanzas — add only what GHC demands). Consult installed sources via `mori registry show
<lib> --full` for: hasql `D.rowsAffected`, servant-server's `Servant.Server.Internal`
(`addAuthCheck`, `withRequest`, `DelayedIO`, `delayedFailFatal`) and
`Servant.Server.Experimental.Auth` (`unAuthHandler`), servant-client-core's `HasClient`.

Must exist at the end (full module paths, exact signatures):

- `Shomei.Effect.RoleStore` (shomei-core): `RoleStore (..)`, `RoleDefinition (..)`,
  `defineRole :: (RoleStore :> es) => Role -> Maybe Text -> UTCTime -> Eff es Bool`,
  `listDefinedRoles :: (RoleStore :> es) => Eff es [RoleDefinition]`,
  `grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> UTCTime -> Eff es Bool`,
  `revokeRole :: (RoleStore :> es) => UserId -> Role -> Eff es Bool`,
  `listRolesForUser :: (RoleStore :> es) => UserId -> Eff es (Set Role)`.
- `Shomei.Effect.ClaimsEnricher` (shomei-core): `ClaimsEnricher (..)`, `ClaimsDelta (..)`,
  `emptyClaimsDelta`, `enrichClaims`, `runClaimsEnricherNull`, `runClaimsEnricherPure` —
  haddock carries the no-live-decision-mirroring warning (2.1).
- `Shomei.Workflow.Session.buildEnrichedClaims :: (RoleStore :> es, ClaimsEnricher :> es)
  => ShomeiConfig -> UserId -> SessionId -> UTCTime -> Eff es AuthClaims` — the
  MasterPlan-7 claims-construction integration point.
- `Shomei.Workflow.Roles` (shomei-core): `grantRoleTo`, `revokeRoleFrom`, `rolesOf`,
  `applyDefaultRoles`, `undefinedDefaultRoles` as in Milestone 1.5.
- `Shomei.Config.ShomeiConfig` gains `defaultRoles :: Set Role` (empty in
  `defaultShomeiConfig`); `Shomei.Server.Config` reads `SHOMEI_DEFAULT_ROLES`.
- `Shomei.Postgres.RoleStore.runRoleStorePostgres :: (Database :> es, Error AuthError :> es)
  => Eff (RoleStore : es) a -> Eff es a`.
- `Shomei.Effect.InMemory`: `roleGrants` and `definedRoles` (seeded with `admin`) in
  `World`, exported `runRoleStore`.
- `Shomei.Domain.Event`: `RoleGranted`/`RoleRevoked` (+ data records);
  `Shomei.Domain.EventCodec` handling `role_granted`/`role_revoked`; `Shomei.Error.AuthError`
  gains `UserNotFound` and `RoleNotDefined` (mapped to 404 `user_not_found` / 422
  `role_not_defined`).
- `Shomei.Servant.Authz`: `HasServer` instances for `RequireRole r :> api` /
  `RequireScope s :> api` with `ServerT … m = AuthUser -> ServerT api m`; guards retained.
- `Shomei.Client`: `HasClient` delegation instances for both combinators.
- `shomei-admin` CLI: `roles define|list-defined|grant|revoke|list` (`Shomei.Admin.Roles`).
- Migration `shomei-migrations/sql-migrations/<ts>-shomei-role-grants.sql` creating
  `shomei_roles` (seeded with `admin`) and `shomei_role_grants` (role FK into the registry).


## Revision Notes

**2026-07-07 — Scope fold: role registry, default roles, and the two-tier authorization
boundary.** Revised before implementation started (no code exists yet, so no migration of
in-flight work was needed). Three additions were folded through every section — Purpose,
Progress, Decision Log, Context and Orientation (new Configuration subsection), Milestones
1/2/3/5, Concrete Steps, Validation and Acceptance, and Interfaces and Dependencies:

1. **Role registry.** The original plan's "no role catalog" stance left a silent failure
   mode: `roles grant --role adminn` (a typo) would succeed and grant a role nothing
   checks. A `shomei_roles` catalog table (seeded with `admin`), an FK from
   `shomei_role_grants`, `DefineRole`/`ListDefinedRoles` port operations, `roles
   define`/`roles list-defined` CLI commands, and a `RoleNotDefined` error (HTTP 422
   `role_not_defined`; CLI exit 1) close it. The `GET /admin/roles` HTTP route stays in
   plan 39 (which owns the admin HTTP surface); this plan ships the query, port op, and
   `RoleDefinition` shape it serializes. The Decision Log's flat-model entry was amended
   rather than rewritten: the flat grant model stands, only the catalog clause was
   superseded.

2. **Default roles on signup.** `ShomeiConfig.defaultRoles` (empty default,
   `SHOMEI_DEFAULT_ROLES` env override), validated against the registry at server boot
   (fail fast), applied inside `Shomei.Workflow.signup` right after `createUser` so the
   first minted token carries them, audited as `role_granted` with `granted_by = NULL`.
   `shomei-admin users create` inherits the behavior for free because it drives the same
   workflow.

3. **Two-tier authorization boundary.** A product decision now recorded here (Decision
   Log) and propagated to the docs milestone: Shōmei's flat roles are the permanent,
   self-contained tier-1 authorization story (zero extra infrastructure; gates Shōmei's
   own `/admin`; cuts the bootstrap circularity with en, whose server has no caller
   authentication yet and plans to verify Shōmei JWTs when it gets one), and the sibling
   Zanzibar-style ReBAC project **en** is the recommended tier 2 for fine-grained,
   relationship-based authorization with live revocation. The `ClaimsEnricher` haddock
   (2.1) gained an explicit warning against mirroring live en decisions into static JWT
   claims. Follow-up plans referenced:
   `docs/plans/46-role-definitions-permissions-and-time-bound-grants.md` (tier-1 growth:
   permissions, time-bound grants — it extends this plan's registry table, `RoleStore`
   port, enrichment path, and combinator pattern) and
   `docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`
   (tier-2 paved road).

Why folded here rather than into a new plan: the registry is the same migration, port,
CLI module, and test suites this plan already creates — a separate plan would edit every
file this one touches; and default roles are meaningless before the enrichment path
exists. Plan 46 was kept separate because permission indirection and expiring grants are
additive layers on top of a working registry, not prerequisites for killing the
"unsatisfiable admin role" hole this plan exists to fix.
