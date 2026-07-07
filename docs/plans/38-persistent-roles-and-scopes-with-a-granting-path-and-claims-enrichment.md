---
id: 38
slug: persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment
title: "Persistent Roles and Scopes with a Granting Path and Claims Enrichment"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# Persistent Roles and Scopes with a Granting Path and Claims Enrichment

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-1** of MasterPlan 7
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`), the keystone of its
Phase 1. It has no dependencies on other plans in that MasterPlan. Two later plans build
directly on it: the admin HTTP API (`docs/plans/39-admin-http-api-for-user-and-session-management.md`)
cannot demonstrate an authorized request until this plan's granting path exists, and the OIDC
plans reuse the claims-construction hook this plan introduces.


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
   `RoleStore` effect (grant, revoke, list) with PostgreSQL and in-memory interpreters.
2. Every token mint (signup, login, MFA completion, passwordless login, refresh) populates
   the `roles` claim from that store and runs a **host-supplied claims-enrichment hook** (a
   new `ClaimsEnricher` effect) that can add scopes, roles, and extra claims. This hook is
   the claims-construction integration point that the later OIDC and token-exchange plans
   (MasterPlan 7 EP-5/EP-6) must reuse.
3. An operator can **bootstrap the first admin** from the box:
   `shomei-admin roles grant --user <id> --role admin`, plus `roles revoke` and `roles list`.
4. `RequireRole`/`RequireScope` become **real, enforcing combinators** with `HasServer`
   instances: the route type alone authenticates the caller and rejects a principal lacking
   the role/scope with 403. The audit endpoint switches to `RequireRole "admin"` as the
   proving route.
5. Grants and revocations are **audited** (`role_granted` / `role_revoked` rows in
   `shomei_auth_events`, carrying who granted what to whom).

You can see it working: run the dev server, create a user, grant them `admin` with the CLI,
log in, and `curl /admin/audit/events` with the fresh token — HTTP 200 with the audit trail.
Revoke the role, refresh the token, and the same request is 403. The exact transcript is in
Validation and Acceptance.

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

Milestone 1 — Role persistence (migration, port, interpreters, audit events):

- [ ] Add migration `shomei-migrations/sql-migrations/<ts>-shomei-role-grants.sql` (via `just new-migration name=shomei-role-grants`) creating `shomei_role_grants`.
- [ ] Add `UserNotFound` to `AuthError` (`shomei-core/src/Shomei/Error.hs`) and its mapping in `shomei-servant/src/Shomei/Servant/Error.hs` (404 `user_not_found`).
- [ ] Add `RoleGranted`/`RoleRevoked` constructors + `RoleGrantedData`/`RoleRevokedData` to `shomei-core/src/Shomei/Domain/Event.hs`.
- [ ] Extend `projectAuthEvent`/`reconstructAuthEvent` in `shomei-core/src/Shomei/Domain/EventCodec.hs` (`role_granted`, `role_revoked`) and bump the constructor-count guard in `shomei-core/test/Shomei/Domain/EventCodecSpec.hs` from 25 to 27 with round-trip cases.
- [ ] Add the `RoleStore` effect (`shomei-core/src/Shomei/Effect/RoleStore.hs`) and export it from the cabal file.
- [ ] Add `Shomei.Workflow.Roles` (`grantRole`, `revokeRole`, `rolesForUser`) publishing the audit events.
- [ ] Add the PostgreSQL interpreter `shomei-postgres/src/Shomei/Postgres/RoleStore.hs` (`runRoleStorePostgres`).
- [ ] Add the in-memory interpreter (`runRoleStore` + a `roleGrants` field in `World`) to `shomei-core/src/Shomei/Effect/InMemory.hs`.
- [ ] Postgres interpreter test in `shomei-postgres/test/Main.hs` (grant/duplicate-grant/list/revoke/FK failure) — suite green.

Milestone 2 — Claims enrichment at every mint:

- [ ] Add the `ClaimsEnricher` effect + `ClaimsDelta` (`shomei-core/src/Shomei/Effect/ClaimsEnricher.hs`) with `runClaimsEnricherNull` and `runClaimsEnricherPure`.
- [ ] Add `buildEnrichedClaims` to `shomei-core/src/Shomei/Workflow/Session.hs`; switch `issueSession`, `Shomei.Workflow.signup`, and `Shomei.Workflow.refresh` to it.
- [ ] Wire `RoleStore` + `ClaimsEnricher` into every effect stack: `Shomei.Servant.Seam.AppEffects`, `Shomei.Server.App.AppEffects` + `runAppIO`, `Shomei.Effect.InMemory.runInMemory`, `shomei-postgres/test/Main.hs`, `shomei-servant/test/Main.hs`, `shomei-server/app/Shomei/Admin/Users.hs`, and the admin test suite.
- [ ] Core/postgres/servant tests proving a granted role appears in the next minted token (login and refresh), and that a `ClaimsDelta` cannot smuggle reserved claim keys.

Milestone 3 — CLI granting path:

- [ ] Add `shomei-server/app/Shomei/Admin/Roles.hs` (`roles grant|revoke|list`) and wire it into `shomei-server/app/Admin.hs` + both cabal stanzas.
- [ ] Admin CLI test (grant → list → revoke over a migrated ephemeral DB) — suite green.

Milestone 4 — Enforcing combinators:

- [ ] Implement `HasServer` for `RequireRole`/`RequireScope` in `shomei-servant/src/Shomei/Servant/Authz.hs` (self-authenticating; 403 on missing role/scope).
- [ ] Switch `auditEvents` in `shomei-servant/src/Shomei/Servant/API.hs` from `Authenticated :>` to `RequireRole "admin" :>`; update `AppAPI` example; keep handler signature.
- [ ] Update `HasOpenApi (RequireRole …)`/`(RequireScope …)` in `shomei-servant/src/Shomei/Servant/OpenApi.hs` to register the bearer security scheme; regenerate `docs/api/openapi.json`; openapi conformance suite green.
- [ ] Add `HasClient` delegation instances for the combinators (in `shomei-client`) so `genericClient` still derives.
- [ ] Servant end-to-end test: combinator-gated route returns 401 (no token), 403 (no role), 200 (role); a scope-gated route ditto.

Milestone 5 — Live proof and docs:

- [ ] Live transcript: CLI grant → login → `curl /admin/audit/events` 200 → revoke + refresh → 403 (recorded below).
- [ ] Rewrite the "Known limitation — the `admin` role" section of `docs/user/security.md`; document staleness semantics and the enrichment hook; update `docs/user/api.md`; CHANGELOG entry.
- [ ] Update MasterPlan 7 registry/progress for EP-1.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Role grants use a **flat** `(user_id, role)` model — one table, role as plain
  text, no role catalog, no projects/organizations/grant-objects (the Zitadel shape).
  Scopes get **no** persistence: they remain claim-strings supplied by service-token
  requests and by the enrichment hook.
  Rationale: MasterPlan 7's gap analysis concluded Shōmei is single-tenant and headless;
  a grant hierarchy would touch every table and route for no current consumer. Roles are
  the thing the existing `requireRole` gate actually reads; scopes are already minted
  per-request by `/auth/service-token` and will be negotiated per-grant by the OAuth2 plans.
  A flat table upgrades cleanly (add columns) if a catalog is ever needed.
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

### Milestone 1 — Role persistence: table, port, interpreters, audit events

Scope: after this milestone the repository can durably record "user U has role R", read it
back, revoke it, and every grant/revoke is an audit event — proven by postgres interpreter
tests. Nothing reads the store at mint time yet.

**1.1 The migration.** From the repo root (inside `nix develop`):
`just new-migration name=shomei-role-grants`, then edit the generated file to:

```sql
-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_role_grants (
  user_id    uuid        NOT NULL REFERENCES shomei_users(user_id) ON DELETE CASCADE,
  role       text        NOT NULL,
  granted_by uuid        NULL REFERENCES shomei_users(user_id),
  granted_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, role)
);

CREATE INDEX IF NOT EXISTS shomei_role_grants_role_idx ON shomei_role_grants (role);
```

The composite primary key makes a duplicate grant a no-op-detectable conflict; `ON DELETE
CASCADE` means deleting a user removes their grants; `granted_by` is nullable for CLI
bootstrap grants (Decision Log). Because migrations are embedded via Template Haskell,
`just migrate` touches the cabal file first — nothing else to wire.

**1.2 The error.** Add a `UserNotFound` constructor to `AuthError` in
`shomei-core/src/Shomei/Error.hs` (grant/revoke against a nonexistent user must fail
cleanly, and plan 39 reuses it). Add its arm to `authErrorToServerError` in
`shomei-servant/src/Shomei/Servant/Error.hs`:
`UserNotFound -> json err404 "user_not_found" "User not found"`. GHC's exhaustiveness
warnings (the repo builds with warnings on) will point at any other `case` over `AuthError`
needing an arm.

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

-- | The role-grant port: durable "user has role" facts (EP-1 of MasterPlan 7).
module Shomei.Effect.RoleStore
  ( RoleStore (..),
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

data RoleStore :: Effect where
  -- | Record a grant. Returns 'True' if the grant is new, 'False' if it already existed
  -- (idempotent; callers publish the audit event only on 'True').
  GrantRole :: UserId -> Role -> Maybe UserId -> UTCTime -> RoleStore m Bool
  -- | Remove a grant. Returns 'True' if a grant was removed.
  RevokeRole :: UserId -> Role -> RoleStore m Bool
  ListRolesForUser :: UserId -> RoleStore m (Set Role)

type instance DispatchOf RoleStore = Dynamic

grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> UTCTime -> Eff es Bool
grantRole uid r by ts = send (GrantRole uid r by ts)

revokeRole :: (RoleStore :> es) => UserId -> Role -> Eff es Bool
revokeRole uid r = send (RevokeRole uid r)

listRolesForUser :: (RoleStore :> es) => UserId -> Eff es (Set Role)
listRolesForUser = send . ListRolesForUser
```

Add `Shomei.Effect.RoleStore` to `shomei-core.cabal` `exposed-modules`.

**1.5 The workflow.** Create `shomei-core/src/Shomei/Workflow/Roles.hs` so the CLI (this
plan) and the admin API (plan 39) share one audited path:

```haskell
grantRoleTo ::
  (UserStore :> es, RoleStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  Maybe UserId ->  -- the granting actor (Nothing = CLI bootstrap)
  UserId ->        -- the subject
  Role ->
  Eff es (Either AuthError Bool)  -- Right True = newly granted; Right False = already had it

revokeRoleFrom :: (…same…) => Maybe UserId -> UserId -> Role -> Eff es (Either AuthError Bool)

rolesOf :: (UserStore :> es, RoleStore :> es) => UserId -> Eff es (Either AuthError (Set Role))
```

Each first checks `findUserById` (a `Nothing` is `Left UserNotFound`), then calls the
store, and publishes `RoleGranted`/`RoleRevoked` **only when the store reported a change**
(so re-running a grant does not spam the audit trail). The workflow treats the `Role` text
as opaque and does not validate it: input validation (trimming, rejecting blank role text)
belongs to the boundary layers — the CLI in Milestone 3 and plan 39's HTTP handlers —
matching how `mkEmail`/`mkLoginId` validate before workflows run. Do not invent a new
`AuthError` for a blank role; the boundaries refuse it before the workflow ever sees it.
State this in the module haddock.

**1.6 The PostgreSQL interpreter.** Create
`shomei-postgres/src/Shomei/Postgres/RoleStore.hs` exporting `runRoleStorePostgres`,
mirroring `Shomei.Postgres.SessionStore` (`interpret_`, `runSession`, `dbFail`). Three
statements:

```sql
-- grant: rowsAffected 0 means the grant already existed
INSERT INTO shomei.shomei_role_grants (user_id, role, granted_by, granted_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (user_id, role) DO NOTHING

-- revoke: rowsAffected 0 means there was nothing to revoke
DELETE FROM shomei.shomei_role_grants WHERE user_id = $1 AND role = $2

-- list
SELECT role FROM shomei.shomei_role_grants WHERE user_id = $1 ORDER BY role
```

Use `D.rowsAffected` (yields `Int64`; `> 0` gives the `Bool`) for the first two and
`D.rowList (D.column (D.nonNullable D.text))` (then `Set.fromList . map Role`) for the
third. Encoders: `contrazip4 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable
E.text)) (E.param (E.nullable E.uuid)) (E.param (E.nonNullable E.timestamptz))` for grant
(convert with `userIdToUUID`, `fmap userIdToUUID`, and unwrap `Role`); `contrazip2` for
revoke. Constraint: `(Database :> es, Error AuthError :> es)` — no `IOE` needed (no
`liftIO`; the audit reader set this precedent). Confirm the exact `D.rowsAffected` name
against the installed hasql via `mori registry show hasql --full` before coding. Add the
module to `shomei-postgres.cabal`.

**1.7 The in-memory interpreter.** In `shomei-core/src/Shomei/Effect/InMemory.hs` add a
field `roleGrants :: !(Map UserId (Set Role))` to `World` (initialize empty in
`emptyWorld`), an exported `runRoleStore :: (IOE :> es) => IORef World -> Eff (RoleStore :
es) a -> Eff es a` implementing the three ops over the map (grant returns `False` when the
role is already present; `granted_by`/timestamps are not modeled), and stack it inside
`runInMemory` in the same relative position you add it to the other lists (1.9/M2).

**1.8 Interpreter tests.** In `shomei-postgres/test/Main.hs` (which runs against an
ephemeral migrated PostgreSQL): add `RoleStore` to the harness stack + chain, then a
`testRoleStore` that creates a user through the existing store helpers, asserts
grant → `True`, duplicate grant → `False`, `listRolesForUser` = the granted set, revoke →
`True`, revoke again → `False`, list empty; and asserts a grant for a random nonexistent
UUID-derived user id surfaces the FK violation as `InternalAuthError` (or pre-check — the
workflow pre-checks, the raw port may FK-fail; assert whichever the port does, and note it).

Acceptance: `cabal test shomei-core:shomei-core-test shomei-postgres:shomei-postgres-test`
green, including the 27-constructor guard and the new role-store test.

### Milestone 2 — Claims enrichment at every mint

Scope: after this milestone, a granted role appears in the `roles` claim of every token
minted afterward (signup/login/MFA/passwordless/refresh), and hosts have a hook to add
claims. Proven by tests that mint before/after a grant.

**2.1 The enrichment effect.** Create `shomei-core/src/Shomei/Effect/ClaimsEnricher.hs`:

```haskell
-- | The host claims-enrichment hook (EP-1 of MasterPlan 7): called at every user-session
-- token mint with the subject and the roles read from the 'RoleStore'; returns a delta the
-- core merges. The delta's extra-claims object is filtered through 'mkExtraClaims', so a
-- host (or compromised host code path) can never override a reserved claim. The OIDC and
-- token-exchange plans (MasterPlan 7 EP-5/EP-6) MUST build their claims through this same
-- hook rather than re-reading stores in the HTTP layer.
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

**2.5 Tests.** (a) In the servant end-to-end suite (`shomei-servant/test/Main.hs`), grant
`admin` to a user through the in-memory `RoleStore` (drive `Shomei.Workflow.Roles.grantRoleTo`
through the harness), log the user in over HTTP, and assert the decoded access token's
`roles` claim contains `admin` (the suite already decodes/verifies tokens for other
assertions — reuse that machinery), then hit `GET /admin/audit/events` with it → 200.
(b) Refresh propagation: grant a role *after* login, `POST /auth/refresh`, assert the new
access token carries it. (c) Reserved-key safety: a core-level test running
`buildEnrichedClaims` under `runClaimsEnricherPure` with a delta whose `extraClaims` tries
to set `"sub"`/`"roles"` — assert the resulting `AuthClaims.extraClaims` dropped them.
(d) A postgres-side test that a granted role survives the real store into
`buildEnrichedClaims` output.

Acceptance: `cabal build all && cabal test all` green.

### Milestone 3 — The CLI granting path

Scope: an operator can bootstrap the first admin without any HTTP call. Proven by the
admin test suite and a live transcript.

Create `shomei-server/app/Shomei/Admin/Roles.hs` exporting `RolesCommand`, `rolesParser`,
`runRoles`, modeled on `Shomei.Admin.Audit` (parser shape) and `Shomei.Admin.Users`
(running an effectful chain over `AdminEnv.pool`). Commands:

```text
shomei-admin roles grant  --user <user_… | UUID> --role <text>
shomei-admin roles revoke --user <user_… | UUID> --role <text>
shomei-admin roles list   --user <user_… | UUID>
```

Parse the user reference with `parseId` first, falling back to `Data.UUID.fromText` +
`userIdFromUUID` (Decision Log); trim the role text and reject blank with a stderr `die`.
`runRoles` assembles a small chain — `runEff . runErrorNoCallStack . runDatabasePool
env.pool . runClockIO . runAuthEventPublisherPostgres . runRoleStorePostgres .
runUserStorePostgres` — and drives `Shomei.Workflow.Roles` with `Nothing` as the actor.
Output: `granted admin to user_…` / `user already had role admin` (exit 0 both ways, the
Bool distinguishes wording); `revoked` / `no such grant`; `list` prints one role per line.
`Left UserNotFound` → `die "user not found: …"` (exit 1). Wire `Roles RolesCommand` into
`Admin.hs`'s `Command`/`commandParser`/`run`, and add the module to both `other-modules`
lists in `shomei-server/shomei-server.cabal`.

Add a test to the `shomei-admin-test` suite mirroring its existing audit test: against the
ephemeral migrated DB, create a user, grant → list shows it → revoke → list empty, and
assert two audit rows (`role_granted`, `role_revoked`) landed via the audit reader.

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
section into "Granting roles" (CLI bootstrap, staleness semantics, revocation lever);
document the `ClaimsEnricher` hook for embedding hosts (a short section in
`docs/user/security.md` or `docs/user/architecture.md` — wherever `Notifier`'s host-hook
story lives, mirror it); update `docs/user/api.md`'s audit-endpoint paragraph; add a
CHANGELOG entry under Unreleased; tick EP-1 in MasterPlan 7's registry and Progress.


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
shomei-admin-test       ... all tests passed (roles grant/list/revoke round-trip)
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

# 3. grant admin, log in again (fresh mint), and read the audit trail
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

- `shomei-admin roles grant/revoke/list` behave as transcribed (idempotent wording on
  repeats; `user not found` on a bogus id; exit codes 0/1 accordingly).
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

- `Shomei.Effect.RoleStore` (shomei-core): `RoleStore (..)`,
  `grantRole :: (RoleStore :> es) => UserId -> Role -> Maybe UserId -> UTCTime -> Eff es Bool`,
  `revokeRole :: (RoleStore :> es) => UserId -> Role -> Eff es Bool`,
  `listRolesForUser :: (RoleStore :> es) => UserId -> Eff es (Set Role)`.
- `Shomei.Effect.ClaimsEnricher` (shomei-core): `ClaimsEnricher (..)`, `ClaimsDelta (..)`,
  `emptyClaimsDelta`, `enrichClaims`, `runClaimsEnricherNull`, `runClaimsEnricherPure`.
- `Shomei.Workflow.Session.buildEnrichedClaims :: (RoleStore :> es, ClaimsEnricher :> es)
  => ShomeiConfig -> UserId -> SessionId -> UTCTime -> Eff es AuthClaims` — the
  MasterPlan-7 claims-construction integration point.
- `Shomei.Workflow.Roles` (shomei-core): `grantRoleTo`, `revokeRoleFrom`, `rolesOf` as in
  Milestone 1.5.
- `Shomei.Postgres.RoleStore.runRoleStorePostgres :: (Database :> es, Error AuthError :> es)
  => Eff (RoleStore : es) a -> Eff es a`.
- `Shomei.Effect.InMemory`: `roleGrants` in `World`, exported `runRoleStore`.
- `Shomei.Domain.Event`: `RoleGranted`/`RoleRevoked` (+ data records);
  `Shomei.Domain.EventCodec` handling `role_granted`/`role_revoked`; `Shomei.Error.AuthError`
  gains `UserNotFound`.
- `Shomei.Servant.Authz`: `HasServer` instances for `RequireRole r :> api` /
  `RequireScope s :> api` with `ServerT … m = AuthUser -> ServerT api m`; guards retained.
- `Shomei.Client`: `HasClient` delegation instances for both combinators.
- `shomei-admin` CLI: `roles grant|revoke|list` (`Shomei.Admin.Roles`).
- Migration `shomei-migrations/sql-migrations/<ts>-shomei-role-grants.sql`.
