---
id: 46
slug: role-definitions-permissions-and-time-bound-grants
title: "Role Definitions, Permissions, and Time-Bound Grants"
kind: exec-plan
created_at: 2026-07-07T19:30:02Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# Role Definitions, Permissions, and Time-Bound Grants

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-9** of MasterPlan 7
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`). It **hard-depends**
on plan 38 (EP-1) (`docs/plans/38-persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment.md`):
everything here extends artifacts that plan 38 creates — the `shomei_roles` registry
table, the `RoleStore` effect, the `buildEnrichedClaims` mint path, and the enforcing
`HasServer` combinator pattern. Do not start this plan until plan 38's five milestones are
complete. Soft dependencies: plan 39
(`docs/plans/39-admin-http-api-for-user-and-session-management.md`) owns the admin HTTP
routes that will expose this plan's port operations over the network, and plan 34
(`docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md`) owns
the background sweeper that will eventually delete expired grant rows.


## Purpose / Big Picture

Shōmei (a Haskell authentication toolkit: `effectful` domain core, hasql/PostgreSQL
persistence, Servant `NamedRoutes` HTTP API) ships, after plan 38, a flat role system:
a `shomei_roles` catalog, `shomei_role_grants` rows saying "user U has role R", and a
`roles` claim minted into every access token. That is Shōmei's **built-in authorization
tier** — deliberately self-contained, deliberately coarse. This plan is that tier's growth
path, for teams that do **not** adopt a dedicated authorization system. (Teams that need
fine-grained, relationship-based authorization should graduate to the sibling
Zanzibar-style ReBAC project **en** instead — see the Decision Log and
`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`.
This plan and that graduation path coexist by design; neither replaces the other.)

Two capabilities are added, both classic RBAC mechanics:

1. **Role→permission definitions.** Today a downstream service that gates a request on
   the `roles` claim containing `"support"` has hardcoded an org-chart name into an
   authorization check:
   renaming the role, splitting it, or granting its abilities to a second role means
   redeploying every consumer. After this plan, an operator attaches *permissions* —
   verb-noun strings like `projects:write` or `billing:read` — to roles
   (`shomei-admin roles allow support tickets:write`), and every token mint resolves the
   user's roles to the **union of their permissions**, minted as a new `permissions` claim
   alongside `roles`. Downstream services check permissions, not role names; roles become
   centrally re-wireable without touching a single consumer. A new `RequirePermission`
   Servant combinator (same enforcing `HasServer` design as plan 38's `RequireRole`)
   makes the check a route-type annotation.

2. **Time-bound grants.** Today every grant is forever until revoked. After this plan,
   `shomei-admin roles grant --user u --role incident-commander --expires-in 4h` records
   an expiry on the grant row; expired grants simply stop appearing in tokens at the next
   mint. Temporary elevation — the single most common "we need this yesterday" RBAC
   request — no longer depends on an operator remembering to revoke.

You can see both working from the box: define a role, allow it a permission, grant it to
a user with `--expires-in 15s`, log the user in — the token's `roles` claim carries the
role and its `permissions` claim carries the permission. Wait out the expiry, refresh the
session — the new token carries neither. The exact transcript is in Validation and
Acceptance.

Two semantics to understand up front (both documented for operators in Milestone 5).
First, **staleness**: like role revocation in plan 38, permission rewiring and grant
expiry take effect at the next token mint (login or refresh), never on outstanding access
tokens — a JWT is self-contained and Shōmei does not re-read stores at verification time.
The access-token TTL bounds the window; `revokeAllUserSessions` is the immediate lever.
Second, **expiry is passive**: nothing fires when a grant expires. There is no
`RoleGrantExpired` audit event and no background job flips a status column; the expiry
timestamp is checked when roles are read at mint time, and the (already-inert) row is
eventually deleted by plan 34's sweeper as hygiene. The audit trail still tells the whole
story, because the original `role_granted` event carries the expiry it was granted with.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Schema and port (permissions table, expiring grants, interpreters): **COMPLETE (2026-07-11)**

- [x] Migration `shomei-migrations/sql-migrations/2026-07-11-00-15-02-shomei-role-permissions.sql`: `shomei_role_permissions` table, `expires_at` column on `shomei_role_grants`, partial index on `expires_at`. (Comment line also appended to `Migrations.hs` per the EP-1 TH re-splice caveat.)
- [x] `Permission` newtype in `shomei-core/src/Shomei/Domain/Claims.hs` (next to `Role`).
- [x] `RoleStore` effect extended: `AllowPermission`/`DisallowPermission`/`ListPermissionsForRole`/`PermissionsForRoles`; `GrantRole` gains a `Maybe UTCTime` expiry; `ListRolesForUser` gains an as-of `UTCTime`.
- [x] `Shomei.Workflow.Roles.grantRoleTo` gains the expiry parameter (order: actor, expiry, subject, role); upsert semantics implemented and tested. `rolesOf` gained a `Clock` constraint (filters as of now).
- [x] `RoleGrantedData` gains `expiresAt :: Maybe UTCTime`; EventCodec round-trip carries `Just` expiry; `testOldRoleGrantedDecodes` (missing field → `Nothing`) added; constructor count stays 40 (the plan's "27" predated EP-4..EP-8).
- [x] PostgreSQL interpreter (`shomei-postgres/src/Shomei/Postgres/RoleStore.hs`) extended with the four permission statements and the expiry-aware grant (upsert, `IS DISTINCT FROM`) / list (`expires_at > $2`) statements.
- [x] In-memory interpreter (`shomei-core/src/Shomei/Effect/InMemory.hs`) extended: `rolePermissions` map, expiry-aware `roleGrants` (value now `Map Role (Maybe UTCTime)`).
- [x] Postgres interpreter tests: `testRolePermissions` (allow/dup-allow/list/union/disallow), `testRolePermissionForeignKey` (allow on undefined role → FK), `testExpiringGrants` (as-of filter + upsert reports change only when expiry moves). `cabal test shomei-core-test shomei-postgres-test` green (234 + 56).

Milestone 2 — The `permissions` claim at every mint: **COMPLETE (2026-07-11)**

- [x] `"permissions"` added to `reservedClaimKeys` (`shomei-core/src/Shomei/Domain/Claims.hs`).
- [x] `AuthClaims` gains `permissions :: Set Permission`; `buildClaims` sets it empty. (Every other `AuthClaims` literal — Impersonation/TokenExchange mint paths and ~10 test sites — got `permissions = Set.empty`; the compiler flagged all via `-Wmissing-fields`-as-error in the test stanzas.)
- [x] `shomei-jwt` sign path: `addClaim "permissions"` in `claimsFromAuth` (after `roles`).
- [x] `shomei-jwt` verify path: reads `permissions` via `lookupStringList` and `"permissions"` joins the `managed` filter list.
- [x] `buildEnrichedClaims` resolves permissions from the effective role set via `permissionsForRoles` and reads expiry-filtered roles via the as-of `listRolesForUser`.
- [x] `AuthUser` gains `authPermissions :: Set Permission`, populated in `authUserFromClaims`.
- [x] Tests: `testPermissionUnionReachesTheToken`, `testExpiredGrantDropsRoleAndPermissions`, `testEnricherRoleContributesPermissions`, forgery test extended with a `"permissions"` key, jwt "round-trips and never leaks into the extra bag" + `coreFields` now compares `permissions`. core/jwt/servant suites green (237/46/30). Servant HTTP-login end-to-end assertion folded into M4's `RequirePermission` route test.

Milestone 3 — CLI: permission wiring and expiring grants: **COMPLETE (2026-07-11)**

- [x] `Shomei.Admin.Roles` gains `roles allow <role> <permission>`, `roles disallow <role> <permission>`, `roles show <role>` (all direct RoleStore-port, no audit event).
- [x] `roles grant` gains `--expires-in <n>(s|m|h|d)` / `--expires-at <ISO8601>` (a `GrantExpiry` alternative, resolved to an absolute instant via the CLI clock; both flags → optparse parse error).
- [x] `roles allow`/`disallow`/`show` on an undefined role exit 1 with `role not defined: …`; blank/whitespace-containing permission rejected at the boundary (`parsePermission`).
- [x] Admin CLI tests: `testRolesPermissionWiring` (allow → show → disallow, no audit event, allow-on-undefined exits nonzero), `testRolesGrantWithExpiry` (grant row `expires_at` ~1h out + `role_granted` payload carries `expiresAt`), `testRolesGrantBothExpiryFlagsFailsToParse` (parser-level mutual exclusion). Existing `RolesGrant` sites updated to the 3-arg form. `shomei-admin-test` green (28).

Milestone 4 — The `RequirePermission` combinator:

- [ ] `RequirePermission :: Symbol -> Type` in `shomei-servant/src/Shomei/Servant/Authz.hs` with an enforcing `HasServer` instance (same pattern as plan 38's `RequireRole`), checking `authPermissions`, 403 `missing_permission`.
- [ ] Haddock distinguishing this static-claim check from en's live relationship check (`En.Servant.Authorize.requirePermission`); no code collision — different packages, no import relationship.
- [ ] `HasOpenApi` instance (bearer security scheme, mirroring `RequireRole`'s) in `shomei-servant/src/Shomei/Servant/OpenApi.hs`; `HasClient` delegation instance in `shomei-client`.
- [ ] Servant end-to-end test: a `RequirePermission "projects:write"`-gated test route returns 401 (no token), 403 (role without the permission), 200 (role with it), and 200 again after the permission is re-wired to a different role the user holds.

Milestone 5 — Live proof, docs, graduation boundary:

- [ ] Live transcript (define → allow → grant --expires-in → login shows `permissions` → expiry + refresh drops it) recorded below.
- [ ] `docs/user/security.md` roles section extended: permissions model, verb-noun naming convention, token-size guidance, expiring grants, passive-expiry semantics.
- [ ] The docs gain an explicit **graduation boundary** paragraph: resource-scoped permissions, relationship-derived access, live revocation, caveats/conditions → use en (link `docs/user/authorization.md` / plan 47); Shōmei's built-in tier will not grow those.
- [ ] Plan 34 coordination: `shomei_role_grants` added to the sweeper's table list if plan 34 has landed; otherwise a note left in plan 34's plan document.
- [ ] OpenAPI spec regenerated; CHANGELOG entry; MasterPlan 7 registry row updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Permissions are **flat verb-noun strings** (`projects:write`) attached to
  roles in a `shomei_role_permissions` join table, resolved to a **union** at token mint,
  and carried in a new `permissions` JWT claim alongside `roles`. There is no permission
  catalog table, no wildcard/hierarchy syntax (`projects:*`), and no per-user permission
  grants (permissions attach only to roles; users get permissions only via roles).
  Rationale: the entire value is the indirection — consumers check a stable capability
  name while operators re-wire which roles imply it. A permission catalog would repeat
  plan 38's registry machinery for a namespace that (unlike roles) is owned by downstream
  *code*, not by operators: the set of meaningful permission strings is defined by what
  services actually check, so a database catalog cannot be authoritative and a typo'd
  `allow` is caught by the Validation matrix instead. Wildcards and hierarchies are the
  first step down the policy-language slope that the two-tier decision (plan 38 Decision
  Log) explicitly assigns to en. The `resource:verb` shape is a documented convention,
  not enforced grammar — boundaries reject only blank/whitespace strings.
  Date: 2026-07-07

- Decision: The `permissions` claim is a **first-class field** on `AuthClaims`
  (`permissions :: Set Permission`, `newtype Permission = Permission Text`), and
  `"permissions"` joins `reservedClaimKeys` in `shomei-core/src/Shomei/Domain/Claims.hs`
  (line ~64) so neither a host's `extraClaims` nor a `ClaimsDelta` can forge it. Both
  shomei-jwt filter tables gain it: the sign path's managed-claim block
  (`shomei-jwt/src/Shomei/Jwt/Sign.hs` line ~99-101, where `sid`/`scopes`/`roles` are
  applied *after* extras so they always win) and the verify path's `managed` list
  (`shomei-jwt/src/Shomei/Jwt/Verify.hs` line ~141), plus a `lookupStringList
  "permissions"` read (line ~136).
  Rationale: `scopes` and `roles` set the precedent — claims Shōmei's own combinators
  gate on must be unforgeable by construction, which means a typed field plus membership
  in every reserved/managed filter, not an `extraClaims` entry. A missing `permissions`
  claim verifies as the empty set (same as `roles` today), so tokens minted before this
  plan remain verifiable.
  Date: 2026-07-07

- Decision: Permissions are resolved from the **effective** role set — the store's
  (expiry-filtered) roles unioned with the enricher's `extraRoles` — and `ClaimsDelta` is
  **unchanged** (no `extraPermissions` field).
  Rationale: a host-injected role must behave exactly like a granted role, or the
  enrichment hook becomes a second, subtly different authorization semantics. A host that
  wants bespoke permissions defines a role carrying them; going through the catalog keeps
  `permissions` fully explainable from `shomei-admin roles show`.
  Date: 2026-07-07

- Decision: Grant expiry is **passive**. `shomei_role_grants` gains a nullable
  `expires_at`; `ListRolesForUser` takes an as-of timestamp and the SQL filters
  `(expires_at IS NULL OR expires_at > $2)`; there is **no** `RoleGrantExpired` audit
  event, no status column, and no eager deletion. The `role_granted` audit payload
  carries the expiry (`RoleGrantedData.expiresAt`); expired rows are swept later by plan
  34's sweeper (`docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md`)
  purely as hygiene — if plan 34 has landed when this milestone runs, add
  `shomei_role_grants` (rows with `expires_at < now() - retention`) to its table list;
  otherwise record the integration point in that plan.
  Rationale: an expiry event would be a lie about causality — nothing *happens* at the
  expiry instant; the fact was fully recorded at grant time and the effect materializes
  at the next mint (identical semantics to revocation, already documented by plan 38).
  Emitting synthetic events would require exactly the scheduler this design avoids, and
  every consumer (audit queries, SIEM forwarding) can derive expiry from the grant
  payload. Filtering at read time keeps expiry correct even if the sweeper is down for a
  week.
  Date: 2026-07-07

- Decision: Re-granting an existing role **updates the expiry** (upsert):
  `ON CONFLICT (user_id, role) DO UPDATE` guarded by
  `WHERE shomei_role_grants.expires_at IS DISTINCT FROM EXCLUDED.expires_at`, so
  `rowsAffected > 0` still means "something changed" and the workflow publishes
  `role_granted` (with the new expiry) exactly when state changed.
  Rationale: the operator intent of `roles grant --expires-in 4h` on an already-granted
  role is unambiguous — extend/replace the window. Plan 38's `DO NOTHING` would silently
  ignore it. The `IS DISTINCT FROM` guard preserves plan 38's idempotence contract
  (identical re-grants stay audit-silent).
  Date: 2026-07-07

- Decision: `roles allow`/`disallow` (permission wiring) are **not** audit events, same
  as plan 38's role definitions; the `AuthEvent` count stays 27.
  Rationale: they are catalog metadata changed rarely by operators on the box, mirrored
  one-to-one by the queryable `shomei_role_permissions` table (the current wiring is
  always inspectable via `roles show`). This is explicitly revisitable when plan 39
  exposes permission wiring over the network — a remote, credentialed mutation deserves
  an audit row, and plan 39 should add events for its mutation routes wholesale.
  Date: 2026-07-07

- Decision: The combinator is named `RequirePermission` even though en-servant exports a
  term-level function named `requirePermission`.
  Rationale: verified no collision — `En.Servant.Authorize.requirePermission`
  (`en-servant/src/En/Servant/Authorize.hs` line 14) is a *function* in a package Shōmei
  does not depend on (and en does not depend on Shōmei); Shōmei's `RequirePermission` is
  a *type* in `shomei-servant`. A host importing both modules unqualified would still not
  clash (type vs. term namespaces). The real risk is conceptual confusion, which the
  haddock addresses head-on: Shōmei's combinator checks a **static claim minted at login
  time** (staleness = token TTL); en's function performs a **live relationship check**
  against the tuple store (staleness = consistency-token choice). Naming them the same
  thing is honest — they are the same *intent* at two freshness tiers.
  Date: 2026-07-07

- Decision: No route in `ShomeiAPI` switches to `RequirePermission`; Shōmei's own admin
  surface stays gated by `RequireRole "admin"` (plan 38) / the role-or-scope guard (plan
  39). The combinator's proving route lives in the servant test suite's host app, like
  plan 38's scope-gated test route.
  Rationale: Shōmei gating itself via permissions would force every deployment to run
  `roles allow admin shomei:admin-api` before the admin surface works, re-introducing the
  bootstrap problem plan 38 just fixed. The `admin` role seeded by the migration must
  remain sufficient on a fresh database. `RequirePermission` is for *host* routes and for
  downstream services.
  Date: 2026-07-07

- Decision: Token-size posture: the `permissions` claim is bounded by the union of the
  user's roles' permission sets, and Shōmei imposes **no hard cap**; the docs (Milestone
  5) recommend small permission sets (tens, not hundreds — a JWT rides in an
  `Authorization` header or a cookie, and cookies cap around 4 KiB) and note that a
  deployment whose permission list is growing unbounded is expressing resource-scoped
  authorization in the wrong tier and should read the graduation-boundary section.
  Rationale: a hard cap would turn a docs problem into a runtime failure with no good
  error path at mint time. The guidance plus the graduation boundary is the honest fix.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository beyond plan 38 being fully
implemented. Everything below was verified against the working tree on 2026-07-07 (where
a named artifact comes from plan 38, that is stated; re-verify locations after it lands,
since line numbers will have shifted).

Shōmei is a multi-package Cabal project built inside `nix develop` (`cabal build all`,
`cabal test all`), GHC 9.12.4. The packages this plan touches: `shomei-core` (domain
types under `shomei-core/src/Shomei/Domain/`, `effectful` effect definitions under
`shomei-core/src/Shomei/Effect/`, workflows under `shomei-core/src/Shomei/Workflow*.hs`),
`shomei-jwt` (JOSE signing/verification), `shomei-postgres` (hasql interpreters),
`shomei-servant` (the HTTP surface and the auth combinators), `shomei-server` (the Warp
executable and the `shomei-admin` operator CLI under `shomei-server/app/`),
`shomei-migrations` (timestamped SQL applied by codd; scaffold with
`just new-migration name=<slug>`), and `shomei-client` (typed `servant-client` wrappers).
An *effect* is a GADT of operations plus `send`-based helpers; an *interpreter* peels the
effect off the `Eff es` type-level list; every SQL-issuing interpreter runs above
`runDatabasePool`. Every module imports `Shomei.Prelude` (custom prelude; `Data.Set`
imported qualified).

What plan 38 leaves in place, and this plan extends:

The **role tables**. `shomei_roles` (role text PK, description, created_at; seeded with
`admin`) is the registry of declared roles; `shomei_role_grants` (user_id, role FK,
granted_by nullable, granted_at; PK (user_id, role)) records who holds what. This plan
adds a `shomei_role_permissions` join table referencing `shomei_roles` and an
`expires_at` column on `shomei_role_grants`.

The **`RoleStore` effect** (`shomei-core/src/Shomei/Effect/RoleStore.hs`) with operations
`DefineRole`, `ListDefinedRoles` (returning `RoleDefinition {role, description,
createdAt}`), `GrantRole :: UserId -> Role -> Maybe UserId -> UTCTime -> RoleStore m
Bool`, `RevokeRole`, `ListRolesForUser :: UserId -> RoleStore m (Set Role)`; PostgreSQL
interpreter `shomei-postgres/src/Shomei/Postgres/RoleStore.hs` (`runRoleStorePostgres`);
in-memory interpreter in `shomei-core/src/Shomei/Effect/InMemory.hs` over an `IORef
World` with `roleGrants` and `definedRoles` fields. This plan changes two operation
signatures (expiry) and adds four (permissions) — GHC's exhaustiveness warnings walk you
to every interpreter arm.

The **mint path**. `Shomei.Workflow.Session.buildEnrichedClaims` (plan 38) is called by
every user-session mint site — `Shomei.Workflow.signup`, `Shomei.Workflow.refresh`, and
`Shomei.Workflow.Session.issueSession` (the shared tail of login/MFA/passwordless). It
reads `listRolesForUser`, runs the `ClaimsEnricher` hook (host-supplied `ClaimsDelta`
with `extraRoles`/`extraScopes`/`extraClaims`), and builds `AuthClaims`. The
service-token workflow (`shomei-core/src/Shomei/Workflow/ServiceToken.hs`, which
overwrites `scopes` from an allow-list at line ~88) and the impersonation workflow do
**not** go through enrichment (plan 38 Decision Log) — they get no `permissions` claim
either, and that is deliberate: service tokens carry negotiated scopes, and machine
consumers should keep checking scopes.

The **claims and their protection**. `shomei-core/src/Shomei/Domain/Claims.hs`: `newtype
Scope = Scope Text` (line 30), `newtype Role = Role Text` (line 34), `data AuthClaims`
(line 38) with `subject`, `sessionId`, `issuer`, `audience`, `issuedAt`, `expiresAt`,
`scopes`, `roles`, `actor`, `extraClaims`; `reservedClaimKeys` (line 64) currently
`["iss","sub","aud","iat","exp","sid","scopes","roles","act"]`; `mkExtraClaims` (line 68)
drops reserved keys from any extra-claims object. In `shomei-jwt`,
`claimsFromAuth` (`shomei-jwt/src/Shomei/Jwt/Sign.hs` line ~78) seeds extras *first* and
then applies the registered claims and the managed custom claims (`addClaim "sid"`,
`addClaim "scopes"`, `addClaim "roles"` at lines ~99-101) on top, so Shōmei's values
always overwrite a same-named extra; the verify side
(`shomei-jwt/src/Shomei/Jwt/Verify.hs`) reads them back with `lookupStringList` (lines
~136-137) and strips the `managed = ["sid", "scopes", "roles", "act"]` list (line 141)
out of the unregistered claims before they become `extraClaims`. Any new managed claim
must appear in **all three** places (reserved keys, sign block, verify read+managed
list) or it is forgeable — this plan's Milestone 2 does exactly that for `"permissions"`.

The **combinator pattern**. `shomei-servant/src/Shomei/Servant/Authz.hs` holds
`RequireRole`/`RequireScope` with real `HasServer` instances (plan 38 Milestone 4): the
instance fetches the `AuthHandler Request AuthUser` from the Servant `Context` (the same
one `Authenticated = AuthProtect "shomei-jwt"` uses, registered by `authContext` in
`shomei-server/src/Shomei/Server/Boot.hs`), runs it inside `route`'s `addAuthCheck`,
checks the extracted `AuthUser` field, `delayedFailFatal`s a 403 on failure, and passes
the `AuthUser` to the sub-handler (`ServerT (RequireRole r :> api) m = AuthUser ->
ServerT api m`). `AuthUser` (`shomei-servant/src/Shomei/Servant/Auth.hs` line ~46)
carries `authUserId`, `authSessionId`, `authRoles :: Set Role`, `authScopes :: Set
Scope`, `authClaims`. Matching `HasOpenApi` instances live in
`shomei-servant/src/Shomei/Servant/OpenApi.hs` (they register the bearer security
scheme; `cabal run shomei-openapi > docs/api/openapi.json` regenerates the committed
spec, and the conformance suite asserts the path count), and `HasClient` delegation
instances live in `shomei-client`. Milestone 4 clones this whole pattern for
`RequirePermission`.

The **CLI**. `shomei-server/app/Shomei/Admin/Roles.hs` (plan 38) implements
`roles define|list-defined|grant|revoke|list` as an `optparse-applicative` subtree wired
into `shomei-server/app/Admin.hs`, running `Shomei.Workflow.Roles` over a small
interpreter chain built from `AdminEnv.pool`. Milestone 3 adds subcommands and flags to
this module. New modules/flags need no cabal changes; a new module would need adding to
both `other-modules` lists in `shomei-server/shomei-server.cabal`.

The **audit vocabulary**. `shomei-core/src/Shomei/Domain/Event.hs` has 27 constructors
after plan 38, including `RoleGranted RoleGrantedData` where `RoleGrantedData = {userId,
role, grantedBy :: Maybe UserId, occurredAt}`. `shomei-core/src/Shomei/Domain/EventCodec.hs`
projects/reconstructs the envelope; the count guard in
`shomei-core/test/Shomei/Domain/EventCodecSpec.hs` sits at 27 and stays there (this plan
adds a field, not a constructor).

One term of art: a **claim** is a named value inside the signed JWT payload. Claims are
minted once and never re-read from the database during verification — which is why every
staleness statement in this plan says "at the next mint".


## Plan of Work

Five milestones. Each is independently verifiable; commit at each boundary.

### Milestone 1 — Schema and port: the permissions table and expiring grants

Scope: after this milestone the database can record "role R implies permission P" and
"user U has role R until T", the `RoleStore` port exposes both, and both interpreters
implement them — proven by postgres interpreter tests. Nothing reaches tokens yet.

**1.1 The migration.** From the repo root (inside `nix develop`):
`just new-migration name=shomei-role-permissions`, then edit the generated file to:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_role_permissions (
  role       text        NOT NULL REFERENCES shomei_roles(role),
  permission text        NOT NULL,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (role, permission)
);

ALTER TABLE shomei_role_grants
  ADD COLUMN IF NOT EXISTS expires_at timestamptz NULL;

CREATE INDEX IF NOT EXISTS shomei_role_grants_expires_at_idx
  ON shomei_role_grants (expires_at)
  WHERE expires_at IS NOT NULL;
```

The FK means a permission can only attach to a defined role (typo protection, same
argument as plan 38's grants FK). `expires_at NULL` means "forever" — every existing row
keeps its meaning, so this is a safe additive migration. The partial index serves plan
34's sweeper (`DELETE … WHERE expires_at < $1` in bounded batches) without taxing the
common forever-NULL case; the mint-path query stays on the primary key. Because migrations are
embedded via Template Haskell, `just migrate` handles wiring.

**1.2 The `Permission` type.** In `shomei-core/src/Shomei/Domain/Claims.hs`, next to
`Role` (line ~34), add:

```haskell
-- | A capability string carried in the @permissions@ claim, resolved at mint time from
-- the subject's roles ('shomei_role_permissions'). Convention: @resource:verb@, e.g.
-- @projects:write@ — a convention, not enforced grammar.
newtype Permission = Permission Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving anyclass (FromJSON, ToJSON)
```

(match `Role`'s exact deriving clauses in the file). Export it.

**1.3 The port.** In `shomei-core/src/Shomei/Effect/RoleStore.hs`, change two operations
and add four:

```haskell
data RoleStore :: Effect where
  DefineRole :: Role -> Maybe Text -> UTCTime -> RoleStore m Bool
  ListDefinedRoles :: RoleStore m [RoleDefinition]
  -- | Record a grant, with an optional expiry ('Nothing' = does not expire). Returns
  -- 'True' when state changed: a new grant, or an existing grant whose expiry differs
  -- (re-granting updates the expiry — upsert). Callers publish audit only on 'True'.
  GrantRole :: UserId -> Role -> Maybe UserId -> Maybe UTCTime -> UTCTime -> RoleStore m Bool
  RevokeRole :: UserId -> Role -> RoleStore m Bool
  -- | The subject's roles as of the given instant: grants with @expires_at@ at or before
  -- it are excluded. Callers pass the mint timestamp.
  ListRolesForUser :: UserId -> UTCTime -> RoleStore m (Set Role)
  -- | Attach a permission to a role. 'True' = newly attached.
  AllowPermission :: Role -> Permission -> UTCTime -> RoleStore m Bool
  -- | Detach. 'True' = something was detached.
  DisallowPermission :: Role -> Permission -> RoleStore m Bool
  ListPermissionsForRole :: Role -> RoleStore m (Set Permission)
  -- | The union of permissions across a role set — one query, used by the mint path.
  PermissionsForRoles :: Set Role -> RoleStore m (Set Permission)
```

with `send`-helpers for each (`allowPermission`, `disallowPermission`,
`listPermissionsForRole`, `permissionsForRoles`; update `grantRole`/`listRolesForUser`).
The signature changes are deliberate breaking changes inside the repo: fix every caller
the compiler flags — `Shomei.Workflow.Roles` (thread the expiry through `grantRoleTo`;
`applyDefaultRoles` passes `Nothing`), `buildEnrichedClaims` (pass its `ts`), both
interpreters, and the test harnesses.

**1.4 The workflow.** `Shomei.Workflow.Roles.grantRoleTo` gains the `Maybe UTCTime`
expiry parameter (after the actor, before the subject-visible args — pick an order and
keep the CLI/plan-39 callers aligned) and passes it through; its haddock states the
upsert semantics (Decision Log). Permission wiring needs no workflow wrapper: the CLI and
plan 39's handlers call the port directly after the boundary validates the role exists
(reuse `listDefinedRoles` membership → `RoleNotDefined`; the FK backstops).

**1.5 The audit payload.** In `shomei-core/src/Shomei/Domain/Event.hs`, add
`expiresAt :: !(Maybe UTCTime)` to `RoleGrantedData` (before `occurredAt`, matching field
order conventions). `projectAuthEvent`/`reconstructAuthEvent` in
`shomei-core/src/Shomei/Domain/EventCodec.hs` need no arm changes (the payload is the
generically-encoded record), but add two tests to
`shomei-core/test/Shomei/Domain/EventCodecSpec.hs`: a round-trip with `Just` expiry, and
a decode of a hand-written *old-format* JSON payload (no `expiresAt` key) asserting it
parses with `Nothing` — aeson's generic decoding treats an omitted `Maybe` field as
`Nothing`, and this test pins that (existing `role_granted` rows in production databases
must keep reconstructing). The constructor count guard stays 27.

**1.6 The PostgreSQL interpreter.** In
`shomei-postgres/src/Shomei/Postgres/RoleStore.hs`, the changed/new statements:

```sql
-- grant (upsert; rowsAffected 0 = identical grant already present)
INSERT INTO shomei.shomei_role_grants (user_id, role, granted_by, granted_at, expires_at)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (user_id, role) DO UPDATE
  SET expires_at = EXCLUDED.expires_at,
      granted_by = EXCLUDED.granted_by,
      granted_at = EXCLUDED.granted_at
  WHERE shomei_role_grants.expires_at IS DISTINCT FROM EXCLUDED.expires_at

-- list (expiry-filtered as of $2)
SELECT role FROM shomei.shomei_role_grants
WHERE user_id = $1 AND (expires_at IS NULL OR expires_at > $2)
ORDER BY role

-- allow: rowsAffected 0 means already allowed
INSERT INTO shomei.shomei_role_permissions (role, permission, created_at)
VALUES ($1, $2, $3)
ON CONFLICT (role, permission) DO NOTHING

-- disallow
DELETE FROM shomei.shomei_role_permissions WHERE role = $1 AND permission = $2

-- permissions for one role
SELECT permission FROM shomei.shomei_role_permissions WHERE role = $1 ORDER BY permission

-- union for a role set (mint path; one round trip)
SELECT DISTINCT permission FROM shomei.shomei_role_permissions
WHERE role = ANY ($1) ORDER BY permission
```

Encoders/decoders follow plan 38's patterns (`contrazip*`, `D.rowsAffected` for the
booleans, `D.rowList` + `Set.fromList . map Permission` for the sets). For `ANY ($1)`
use hasql's array encoder (`E.param (E.nonNullable (E.foldableArray (E.nonNullable
E.text)))` over the sorted role texts) — confirm the exact encoder names against the
installed hasql via `mori registry show hasql --full` before coding.

**1.7 The in-memory interpreter.** In `shomei-core/src/Shomei/Effect/InMemory.hs`, change
`World.roleGrants` to `Map UserId (Map Role (Maybe UTCTime))` (the value is the expiry)
and add `rolePermissions :: !(Map Role (Set Permission))` (empty in `emptyWorld`).
Implement the nine ops over the maps, mirroring the SQL semantics exactly: grant compares
expiries for the changed-`Bool`; list filters `maybe True (> asOf)`; the union op folds
lookups. As with plan 38, the in-memory store does not enforce the FK (the workflow
check is the tested path).

**1.8 Tests.** Extend the role-store test in `shomei-postgres/test/Main.hs`: allow →
`True`, duplicate allow → `False`, `listPermissionsForRole` and `permissionsForRoles`
(two roles, overlapping permissions → deduplicated union), disallow → `True`/`False`;
allow on an undefined role → `InternalAuthError` (FK); grant with `expires_at` one hour
past, `listRolesForUser` as-of now excludes it, as-of two hours ago includes it; re-grant
with a different expiry → `True` and the new expiry wins; identical re-grant → `False`.

Acceptance: `cabal test shomei-core:shomei-core-test shomei-postgres:shomei-postgres-test`
green, including the old-payload decode test.

### Milestone 2 — The `permissions` claim at every mint

Scope: after this milestone every user-session token carries a `permissions` claim
resolved from the subject's unexpired roles, the claim is unforgeable through
`extraClaims`, and expired grants stop influencing fresh tokens. Proven by core, jwt, and
servant tests.

**2.1 Reserve and carry the claim.** Three files, in the order the Context section
explained (all three or it is forgeable):

- `shomei-core/src/Shomei/Domain/Claims.hs`: add `permissions :: !(Set Permission)` to
  `AuthClaims` (after `roles`); add `"permissions"` to `reservedClaimKeys` (line ~64).
- `shomei-jwt/src/Shomei/Jwt/Sign.hs` `claimsFromAuth`: add
  `& addClaim "permissions" (Aeson.toJSON (Set.toList ac.permissions))` in the managed
  block (line ~99-101, right after `roles`).
- `shomei-jwt/src/Shomei/Jwt/Verify.hs`: add
  `perms = Set.fromList (map Domain.Permission (lookupStringList "permissions"))` beside
  the `scopes`/`roles` reads (lines ~136-137), put it in the reconstructed `AuthClaims`,
  and extend `managed` (line ~141) to
  `["sid", "scopes", "roles", "act", "permissions"]`.

`buildClaims` (`shomei-core/src/Shomei/Workflow/Session.hs` line ~43) sets
`permissions = Set.empty`. A token with no `permissions` claim (minted before this plan)
verifies to the empty set — additive compatibility, same as `roles`.

**2.2 Resolve at mint.** In `buildEnrichedClaims`
(`shomei-core/src/Shomei/Workflow/Session.hs`):

```haskell
buildEnrichedClaims ::
  (RoleStore :> es, ClaimsEnricher :> es) =>
  ShomeiConfig -> UserId -> SessionId -> UTCTime -> Eff es AuthClaims
buildEnrichedClaims cfg uid sid ts = do
  storeRoles <- listRolesForUser uid ts          -- expiry-filtered as of the mint instant
  delta <- enrichClaims uid storeRoles
  let effectiveRoles = storeRoles <> delta.extraRoles
  perms <- permissionsForRoles effectiveRoles
  pure
    (buildClaims cfg uid sid ts)
      { roles = effectiveRoles,
        scopes = delta.extraScopes,
        permissions = perms,
        extraClaims = mkExtraClaims delta.extraClaims
      }
```

The union runs over the *effective* set (Decision Log): an enricher-added role brings its
catalog permissions with it. The service-token and impersonation paths are untouched and
mint `permissions = Set.empty` via `buildClaims`.

**2.3 Expose to handlers.** In `shomei-servant/src/Shomei/Servant/Auth.hs`, add
`authPermissions :: !(Set Permission)` to `AuthUser` (line ~46) and populate it where
`authRoles`/`authScopes` are extracted from the verified claims.

**2.4 Tests.** (a) Core (in-memory): two roles with overlapping permissions granted →
mint → `permissions` is the deduplicated union. (b) Expiry: grant with an expiry in the
past → mint → neither the role nor its permissions appear; expiry in the future → both
do. (c) Enricher interplay: `runClaimsEnricherPure` adding an extra role that has catalog
permissions → they appear. (d) Forgery: a `ClaimsDelta` whose `extraClaims` sets
`"permissions"` → dropped by `mkExtraClaims` (extend plan 38's reserved-key test). (e)
jwt round-trip: sign an `AuthClaims` with permissions, verify, assert the set survives
and that a hand-crafted token carrying `permissions` only as an *extra* claim does not
leak it into `extraClaims` (the `managed` filter). (f) Servant end-to-end: grant + allow
through the harness, login over HTTP, decode the access token, assert the `permissions`
claim.

Acceptance: `cabal build all && cabal test all` green.

### Milestone 3 — CLI: permission wiring and expiring grants

Scope: an operator can wire permissions and issue temporary grants from the box. Proven
by the admin test suite and the live transcript.

Extend `shomei-server/app/Shomei/Admin/Roles.hs`:

```text
shomei-admin roles allow    <role> <permission>
shomei-admin roles disallow <role> <permission>
shomei-admin roles show     <role>
shomei-admin roles grant  --user <user_… | UUID> --role <text> [--expires-in <dur> | --expires-at <ISO8601>]
```

`allow`/`disallow` validate the role against `listDefinedRoles` first (`die "role not
defined: …"` exit 1, reusing plan 38's wording), trim the permission and reject
blank/whitespace-containing strings (`die "invalid permission: …"`), then call the port;
output `allowed projects:write for role support` / `role support already allowed
projects:write` (exit 0 both ways) and symmetrically for disallow. `show` prints the
definition line (name — description) followed by one permission per line (or `(no
permissions)`). `--expires-in` accepts `<n>(s|m|h|d)` (parse with a small
`optparse-applicative` reader; compute `addUTCTime` from the CLI's clock);
`--expires-at` accepts ISO8601 UTC (`Data.Time.Format.ISO8601.iso8601ParseM`); supplying
both is a parse error (make them an `optparse-applicative` mutually exclusive group).
Grant output gains the window: `granted incident-commander to user_… (expires
2026-07-07T21:00:00Z)`, and a re-grant that only moved the expiry says `updated expiry
for incident-commander on user_…` (the workflow's changed-`Bool` plus a compare of prior
state is overkill — wording keyed on the `Bool` alone is fine: `True` with an expiry
flag present prints the expiring form).

Extend the `shomei-admin-test` suite: allow → show lists it → disallow → show empty;
allow on an undefined role exits 1; grant with `--expires-in 1h` → the `role_granted`
audit row's payload carries an `expiresAt` ≈ one hour out (read it back via the audit
reader); grant with both flags fails to parse.

### Milestone 4 — The `RequirePermission` combinator

Scope: a route written `RequirePermission "projects:write" :> …` rejects an
unauthenticated request with 401 and a principal without the permission with 403, with no
handler code — the type-level twin of the CLI's re-wireable checks.

In `shomei-servant/src/Shomei/Servant/Authz.hs`, add:

```haskell
-- | Authenticate the request and require @p@ ∈ the token's @permissions@ claim (403
-- otherwise). This checks a __static claim__ minted at login\/refresh from the role →
-- permission catalog: rewiring or expiry applies at the next mint (see
-- @docs\/user\/security.md@). It is not a live authorization check — for
-- relationship-based, instantly-revocable decisions use the en toolkit's
-- 'En.Servant.Authorize.requirePermission' (a term-level guard in the separate en
-- project), which shares this name because it expresses the same intent at a different
-- freshness tier. See @docs\/user\/authorization.md@.
type RequirePermission :: Symbol -> Type
data RequirePermission p
```

with a `HasServer` instance copied from `RequireRole`'s (plan 38 Milestone 4: fetch the
`AuthHandler Request AuthUser` via `HasContextEntry`, `addAuthCheck`/`withRequest`,
`delayedFailFatal` on failure) checking that `Permission (symbolVal …)` is a member of
`user.authPermissions`, and failing with the same JSON 403 shape,
`"error":"missing_permission"`. Add the `HasOpenApi` instance in
`shomei-servant/src/Shomei/Servant/OpenApi.hs` (copy the `RequireRole` body — bearer
security scheme) and the `HasClient` delegation instance next to plan 38's in
`shomei-client`. No `ShomeiAPI` route changes (Decision Log), so
`cabal run shomei-openapi > docs/api/openapi.json` should be a no-op diff — run it and
commit if anything moved.

Test in `shomei-servant/test/Main.hs`, mirroring the plan-38 combinator tests: a host
test route `RequirePermission "projects:write" :> "host" :> "projects" :> …`; assert 401
with no token; 403 for a user whose role lacks the permission; 200 after
`allowPermission` + fresh login; and the **re-wiring proof** — disallow from role A,
allow to role B, user holds B: after refresh, 200 again with zero route/handler changes.

### Milestone 5 — Live proof, docs, and the graduation boundary

Scope: the full loop against a real server, documentation that teaches the model, and an
explicit statement of where this tier stops. Run the Validation transcript and paste real
output into this plan.

Docs work, all in `docs/user/security.md`'s roles section (created by plan 38's Milestone
5) unless noted: describe the permission model (verb-noun convention; check permissions
in services, not role names; roles become re-wireable), the `permissions` claim and its
staleness (identical to roles: next mint; `revokeAllUserSessions` is the immediate
lever, as plan 38 documented), token-size guidance (keep permission sets small — tens,
not hundreds; JWTs ride headers/cookies), time-bound grants (`--expires-in`, passive
expiry, audit payload carries the window, sweeper hygiene per plan 34), and update
`docs/user/api.md` if plan 39 has landed any permission routes by then. Add the
CHANGELOG entry and update this plan's row in MasterPlan 7's registry.

Then the **graduation boundary**, a short named subsection the other docs link to. It
must say, in substance: Shōmei's built-in tier answers "what may this *user* do,
coarsely, cheaply, with no extra infrastructure". The moment you need *resource-scoped*
permissions ("editor of project X" — you will feel this as permission strings sprouting
ids, `projects:42:write`), relationship-derived access (access because of membership,
ownership, hierarchy), revocation that takes effect faster than a token TTL, or
conditional access (caveats: time windows, IP ranges, attributes), stop growing
permission strings and use en — the recommended authorization layer, integration guide at
`docs/user/authorization.md` (plan 47; until it lands, reference
`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`).
Shōmei's built-in tier deliberately will not grow those four things (plan 38's two-tier
decision); it remains the bootstrap tier that gates Shōmei's own admin surface either
way. Finally, the plan-34 coordination step: if
`docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md` has been
implemented, add `shomei_role_grants` (`expires_at < now() - retention`) to the sweeper's
table list with a test; if not, add a note to plan 34's Progress/Integration text naming
this table so it is swept when that plan runs.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`, inside
the dev shell (`nix develop`). The dev PostgreSQL comes from the dev shell /
`process-compose.yaml`; `just create-database` creates and migrates the dev database
idempotently.

```bash
nix develop            # once per session
just create-database   # idempotent

# Milestone 1 scaffold
just new-migration name=shomei-role-permissions
# → Wrote shomei-migrations/sql-migrations/<UTC-timestamp>-shomei-role-permissions.sql

# after each edit batch
cabal build all
cabal test all

# spec regeneration after the M4 instances (expect no path changes)
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json
```

Expected test-suite result shape (counts grow over plan 38's):

```text
shomei-core-test        ... all tests passed (permission union, expiry filter, old-payload decode)
shomei-jwt tests        ... all tests passed (permissions claim round-trip, managed-claim filter)
shomei-postgres-test    ... all tests passed (allow/disallow/union, expiring grants, upsert)
shomei-servant-test     ... all tests passed (RequirePermission 401/403/200, re-wiring proof)
shomei-servant-openapi-test ... path count unchanged, conformance passed
shomei-admin-test       ... all tests passed (allow/show/disallow, --expires-in audit payload)
```

Commit at each milestone boundary with conventional-commit messages, e.g.:

```text
feat(core): role permissions table and expiring role grants in RoleStore (EP-9 M1)
feat(core): mint a reserved permissions claim from the role catalog (EP-9 M2)
feat(admin): roles allow/disallow/show and grant --expires-in/--expires-at (EP-9 M3)
feat(servant): enforcing RequirePermission combinator (EP-9 M4)
docs(user): permission model, time-bound grants, and the en graduation boundary (EP-9 M5)
```


## Validation and Acceptance

Beyond the suites, the end-to-end proof (Milestone 5). Start the dev stack (server on
:8080), then:

```bash
# 1. wire a role: define, allow, inspect
cabal run shomei-admin -- roles define support --description "Customer support staff"
# → defined role support
cabal run shomei-admin -- roles allow support tickets:write
# → allowed tickets:write for role support
cabal run shomei-admin -- roles show support
# → support — Customer support staff
#   tickets:write

# 2. a temporary grant (use a short window so the transcript can outlive it)
cabal run shomei-admin -- users create --email temp@example.com --password 'Str0ng-Pass-123!'
# → created user user_01XYZ... <temp@example.com>
cabal run shomei-admin -- roles grant --user user_01XYZ... --role support --expires-in 30s
# → granted support to user_01XYZ... (expires 2026-07-07T21:00:30Z)

# 3. a fresh login carries role AND permission (decode the JWT payload)
TOK=$(curl -s -XPOST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"temp@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)
echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{roles, permissions}'
# → { "roles": ["support"], "permissions": ["tickets:write"] }

# 4. after expiry, the next mint carries neither (refresh, or log in again)
sleep 35
TOK2=$(curl -s -XPOST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"temp@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)
echo "$TOK2" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{roles, permissions}'
# → { "roles": [], "permissions": [] }

# 5. the audit trail recorded the window at grant time (passive expiry: no expiry event)
cabal run shomei-admin -- audit events --type role_granted
# → ... role=support user=<uuid> expiresAt=2026-07-07T21:00:30Z ...
cabal run shomei-admin -- audit events --type role_grant_expired
# → (no such event type — expiry is passive by design)
```

Acceptance criteria, phrased as observable behavior:

- `roles allow/disallow/show` behave as transcribed (idempotent wording on repeats;
  `role not defined` exit 1 on an unregistered role; blank permission rejected).
- A token minted while a grant is live carries the role in `roles` and the union of its
  roles' permissions in `permissions`; a token minted after the expiry instant carries
  neither; outstanding tokens are untouched until they expire or refresh.
- Re-wiring (`disallow` from one role, `allow` to another the user holds) changes which
  users receive a permission at their next mint with zero consumer redeploys — the
  servant suite's re-wiring test proves it end-to-end through a `RequirePermission`
  route.
- A `RequirePermission`-gated route (no handler guard) returns 401 with no token, 403
  without the permission, 200 with it.
- A `ClaimsDelta`/`extraClaims` attempt to set `"permissions"` never reaches a signed
  token; a foreign token's unregistered `permissions` key is stripped by the verify
  filter.
- `role_granted` audit payloads carry `expiresAt`; pre-existing payloads without the
  field still reconstruct (`Nothing`).
- `cabal build all && cabal test all` green; the committed OpenAPI spec matches
  regeneration byte-for-byte.


## Idempotence and Recovery

Every step is safe to repeat. The migration is additive (`CREATE TABLE IF NOT EXISTS`,
`ADD COLUMN IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`) and codd applies it exactly
once; to iterate during development, drop and recreate the *dev* database (`dropdb
"$PGDATABASE" && just create-database`) rather than editing an applied file. `allow` is
`ON CONFLICT DO NOTHING`; grant's upsert is guarded by `IS DISTINCT FROM`, so re-running
any CLI command or test seed causes no drift and no duplicate audit rows. The port
signature changes (1.3) are the one non-additive move: land Milestone 1 as a single
commit so no intermediate state has interpreters disagreeing with the GADT — the compiler
enforces this anyway (an un-updated interpreter arm is a build failure, not a runtime
surprise). If Milestone 4 stalls, Milestones 1–3 stand alone (permissions mint and are
CLI-manageable; only the type-level consumer is missing). Regenerating
`docs/api/openapi.json` is deterministic; a dirty diff means the spec drifted and must be
committed.


## Interfaces and Dependencies

No new external dependencies: `effectful`, `hasql`, `contravariant-extras`, `servant`,
`servant-server`, `servant-client-core`, `optparse-applicative`, `containers`, `aeson`,
`time` are already in the workspace. Consult installed sources via `mori registry show
<lib> --full` for hasql's array encoder (`E.foldableArray`), `D.rowsAffected`, and
`Data.Time.Format.ISO8601.iso8601ParseM`. Hard dependency: plan 38 fully implemented
(this plan edits its migration's tables, its `RoleStore`, its `buildEnrichedClaims`, its
CLI module, and clones its combinator pattern). Soft dependencies: plan 39 (will expose
`allow`/`disallow`/`show` and expiring grants over HTTP using this plan's port ops — the
routes are *not* in this plan), plan 34 (sweeps expired grant rows; integration step in
Milestone 5).

Must exist at the end (full module paths, exact signatures):

- `Shomei.Domain.Claims` (shomei-core): `newtype Permission = Permission Text`;
  `AuthClaims.permissions :: Set Permission`; `reservedClaimKeys` includes
  `"permissions"`.
- `Shomei.Effect.RoleStore` (shomei-core):
  `grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> Maybe UTCTime -> UTCTime -> Eff es Bool`,
  `listRolesForUser :: (RoleStore :> es) => UserId -> UTCTime -> Eff es (Set Role)`,
  `allowPermission :: (RoleStore :> es) => Role -> Permission -> UTCTime -> Eff es Bool`,
  `disallowPermission :: (RoleStore :> es) => Role -> Permission -> Eff es Bool`,
  `listPermissionsForRole :: (RoleStore :> es) => Role -> Eff es (Set Permission)`,
  `permissionsForRoles :: (RoleStore :> es) => Set Role -> Eff es (Set Permission)`.
- `Shomei.Workflow.Session.buildEnrichedClaims` resolving expiry-filtered roles and the
  permission union as in Milestone 2.2 (signature unchanged from plan 38).
- `Shomei.Domain.Event.RoleGrantedData.expiresAt :: Maybe UTCTime` (old payloads decode
  to `Nothing`; constructor count stays 27).
- `Shomei.Jwt.Sign.claimsFromAuth` writing, and `Shomei.Jwt.Verify` reading+filtering,
  the `permissions` custom claim.
- `Shomei.Servant.Auth.AuthUser.authPermissions :: Set Permission`.
- `Shomei.Servant.Authz.RequirePermission :: Symbol -> Type` with `HasServer`
  (`ServerT (RequirePermission p :> api) m = AuthUser -> ServerT api m`), `HasOpenApi`
  (in `Shomei.Servant.OpenApi`), and `HasClient` (in `shomei-client`) instances.
- `shomei-admin` CLI: `roles allow|disallow|show`, and `roles grant` with
  `--expires-in`/`--expires-at` (`Shomei.Admin.Roles`).
- Migration `shomei-migrations/sql-migrations/<ts>-shomei-role-permissions.sql` creating
  `shomei_role_permissions`, adding `shomei_role_grants.expires_at`, and the partial
  expiry index.
