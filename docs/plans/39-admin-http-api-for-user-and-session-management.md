---
id: 39
slug: admin-http-api-for-user-and-session-management
title: "Admin HTTP API for User and Session Management"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# Admin HTTP API for User and Session Management

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-2** of MasterPlan 7
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`).

**Hard dependency:** plan 38
(`docs/plans/38-persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment.md`)
must be Complete before this plan starts. This plan literally cannot demonstrate a single
authorized request without it: the admin surface is gated on the `admin` role (or an admin
scope), and before plan 38 there is no role persistence, no `shomei-admin roles grant`
bootstrap, and no claims enrichment putting granted roles into tokens. This plan also
delegates its role-grant routes to plan 38's `Shomei.Workflow.Roles` and `RoleStore`.

**Soft dependency (boundary statement):** plan 40
(`docs/plans/40-api-v1-prefix-and-universal-problem-details-error-envelope.md`) owns the
`/v1` path prefix and the universal problem-details error envelope. If plan 40 has landed
when this plan is implemented, every route below is born under `/v1` (i.e.
`/v1/admin/users/...`) and every error path goes through plan 40's envelope helper — use
them and adjust the transcripts accordingly. If plan 40 has *not* landed, build exactly as
written here (unprefixed paths, the current `{"error","message"}` JSON error convention),
and plan 40 will sweep these routes along with everything else. Do not half-adopt.


## Purpose / Big Picture

Today a deployed Shōmei (a Haskell authentication service: `effectful` core,
hasql/PostgreSQL, Servant `NamedRoutes` API on Warp) is administrable **only via the
`shomei-admin` CLI on the box** — an operator with shell access to the deployment
environment and `DATABASE_URL`. There is no HTTP way to answer "what users exist?", to
suspend a compromised account, to kick a user's sessions, to trigger a password reset for
a locked-out customer, or to grant a role. The core domain already has the vocabulary
(`UserStatus = UserActive | UserSuspended | UserDeleted`, session revocation, audit events
`UserSuspended`/`UserDeleted`/`SessionRevoked` — though nothing currently publishes the
first two), and exactly one `/admin` HTTP route exists: `GET /admin/audit/events`.

After this plan, an administrator — a human with an `admin`-roled token, or a service (a
support console, an internal back-office) holding a `shomei:admin`-scoped service token —
can manage the full user lifecycle over HTTP:

```text
GET    /admin/users                          list users (keyset-paginated, ?status= filter)
GET    /admin/users/{userId}                 one user, with their granted roles
POST   /admin/users/{userId}/suspend         suspend + revoke all sessions
POST   /admin/users/{userId}/reinstate       reactivate a suspended user
DELETE /admin/users/{userId}                 soft-delete + revoke all sessions
GET    /admin/users/{userId}/sessions        the user's sessions
DELETE /admin/users/{userId}/sessions        revoke all the user's sessions
DELETE /admin/sessions/{sessionId}           revoke one session
POST   /admin/users/{userId}/password-reset  trigger the reset email flow for the user
PUT    /admin/users/{userId}/roles/{role}    grant a role (delegates to plan 38)
DELETE /admin/users/{userId}/roles/{role}    revoke a role
```

Every mutation is audited with the **actor identity** (the acting admin's user id from the
verified token), refused under **impersonation** (a delegated token carrying an `act`
claim cannot administer), documented in the **OpenAPI** spec, and callable through
**`shomei-client`** wrappers. You can see it working: grant yourself `admin` with the plan
38 CLI, log in, and drive a suspend/reinstate cycle with `curl`, watching the target user's
login start failing and their sessions die — the transcript is in Validation and
Acceptance.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Core capabilities (queries, workflows, events): **done 2026-07-09**

- [x] `ListUsers` (keyset-paginated on `(created_at, user_id)`, optional status filter) on the `UserStore` port with `UserListQuery`/`UserCursor`/`emptyUserListQuery`/`maxUserLimit`/`clampUserLimit`.
- [x] `ListSessionsForUser` on the `SessionStore` port (newest-first, every status, unpaginated).
- [x] Both implemented in the PostgreSQL interpreters and the in-memory ones, with the same ordering and cursor predicate so the servant suite's pagination walk means something.
- [x] `UserSuspendedData`/`UserDeletedData` gained `actor :: Maybe UserId`; new `UserReinstated`/`UserReinstatedData`; `SessionRevokedData` gained `revokedBy :: Maybe UserId`. `EventCodec` updated; the count guard is 28. A dedicated test decodes a **pre-EP-2 `session_revoked` payload** (no `revokedBy` key) and asserts `Nothing` — those rows exist in every deployment.
- [x] `InvalidUserStatus` and `UserHasNoEmail` on `AuthError`, mapped to 409 problem documents through EP-3's catalog (`pcInvalidUserStatus`, `pcUserHasNoEmail` — added to `problemCatalog`, so the conformance suite already covers them).
- [x] `Shomei.Workflow.Admin` (`suspendUser`, `reinstateUser`, `deleteUser`, `revokeUserSessions`, `revokeOneSession`): strict transitions, session revocation, actor-carrying audit events. It authorizes nothing — that is HTTP-layer policy, stated in the module haddock.
- [x] Tests: `shomei-postgres` pins newest-first order, the status filter, and a disjoint+complete keyset walk, plus `listSessionsForUser` scoping and status visibility. `Shomei.Workflow.AdminSpec` (7 cases) covers all five workflows including the actor on every event. `cabal test all` green.

Milestone 2 — HTTP surface:

- [ ] `requireAdmin` guard (role `admin` OR scope `shomei:admin`) in `shomei-servant/src/Shomei/Servant/Authz.hs`.
- [ ] DTOs (`AdminUserResponse`, `AdminUsersPage`) + cursor reuse in `shomei-servant/src/Shomei/Servant/DTO.hs`.
- [ ] Eleven route fields on `ShomeiAPI` (`shomei-servant/src/Shomei/Servant/API.hs`) under `/admin`.
- [ ] Handlers in `shomei-servant/src/Shomei/Servant/Handlers.hs`: guard → `denyUnderImpersonation` (mutations) → workflow → DTO; self-targeting suspend/delete refused.
- [ ] Servant end-to-end tests: authz matrix (no token / non-admin / admin role / admin scope / delegated token), full lifecycle walk, pagination walk, audit rows carry the actor.

Milestone 3 — Spec and client:

- [ ] `ToSchema` instances for the new DTOs in `shomei-servant/src/Shomei/Servant/OpenApi.hs`; regenerate `docs/api/openapi.json`; bump the conformance suite's path count (24 → 32).
- [ ] `shomei-client` wrappers for the eleven admin operations.

Milestone 4 — Proof and docs:

- [ ] Live curl transcript recorded (below).
- [ ] `docs/user/api.md` "Admin API" section; `docs/user/security.md` note on admin authz + impersonation refusal; CHANGELOG entry; MasterPlan 7 registry/progress updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-07-09 (M1) — plan 40 landed first, so the boundary statement resolves to "adopt it".**
Routes below become fields of `ShomeiAPI`, which `ShomeiRoutes` mounts under `/v1`, so they are
born at `/v1/admin/...` with no extra work. Errors go through `toProblemError`; the two new
`AuthError`s got `ProblemSpec` constants in `problemCatalog` rather than ad-hoc `json err409`
bodies. Consequences for this plan's own numbers: the conformance path count is **25 → 33**, not
the 24 → 32 written in Milestone 3, and the M2 `requireAdmin` guard throws a problem document.

**2026-07-09 (M1) — the audit `user_id` column is the event's subject, not its actor.** Adding
`revokedBy` to `SessionRevokedData` invited setting `session_revoked`'s `user_id` projection to the
acting admin. That would have quietly corrupted the audit query: `GET /v1/admin/audit/events?user=<admin>`
would return the sessions that admin revoked *for other people*, which reads as "things that
happened to the admin". The column stays NULL (as it always was) and the actor rides in the
payload. **Every actor-carrying event this plan adds follows the rule**: `user_id` = subject,
payload = actor. `user_suspended` sets `user_id` to the *target*, not the admin.

**2026-07-09 (M1) — `updateUserStatus` never moved `updated_at`.** Nothing had ever called it from
a workflow, so the omission could not be observed. The admin listing exposes `updatedAt`, and a
suspension that leaves it at the signup timestamp reads to an operator as "nothing has happened to
this account". Fixed in the SQL (`SET status = $2, updated_at = now()`) and in the in-memory
interpreter (which uses the `World` clock).

**2026-07-09 (M1) — `revokeUserSessions` revokes session-by-session, not via
`revokeAllUserSessions`.** The bulk primitive emits no per-session audit events and cannot report a
count. Revoking each active session individually gives one `SessionRevoked` per session with
`revokedBy` set, and returns the number actually ended — so an operator reading "revoked 0
sessions" learns something true instead of "revoked 3" about three corpses. `suspendUser` and
`deleteUser` still use the bulk primitive (per the plan), so their trail is the single
`user_suspended`/`user_deleted` event; that is a deliberate asymmetry, not an oversight.


## Decision Log

Record every decision made while working on the plan.

- Decision: The admin surface is authorized by `admin` **role OR** `shomei:admin` **scope**
  (a `requireAdmin` guard function), and the route types therefore carry plain
  `Authenticated :>` with the guard called first in each handler — not plan 38's
  single-symbol `RequireRole`/`RequireScope` combinators.
  Rationale: a database-less service (support console, back-office job) should administer
  with a service token, and `/auth/service-token` mints scopes, not roles; a human admin
  carries the granted role. A disjunction is not expressible with one `RequireRole` symbol,
  and inventing a combinator-level boolean algebra is not worth it for one guard — plan 38
  explicitly kept the guard functions for exactly this composite case. The scope string is
  `shomei:admin`, following the existing `impersonate:user` namespaced-scope convention.
  Date: 2026-07-07

- Decision: Suspend and delete **revoke all of the target's sessions immediately**
  (`revokeAllUserSessions`); delete is a **soft delete** (`UserStatus` → `UserDeleted`),
  not a row removal.
  Rationale: an admin suspending an account expects the account to stop working — leaving
  live sessions would make the button decorative. Outstanding *access* tokens still ride
  out their short TTL unless the deployment sets `sessionCheckMode = VerifyTokenAndSession`
  (which re-checks the session per request); the docs state this. Soft delete preserves the
  audit trail's referential integrity (`shomei_role_grants` and sessions FK the user row)
  and matches the existing `UserDeleted` status the domain already defines; hard erasure
  (GDPR-style) is a separate concern deliberately out of scope.
  Date: 2026-07-07

- Decision: Status transitions are strict: suspend requires `UserActive`, reinstate
  requires `UserSuspended`, delete requires not-already-`UserDeleted`; a wrong-state
  request is `409` with a new `InvalidUserStatus` error. Deleted users still appear in
  list/get (with `"status":"deleted"`) but refuse every mutation.
  Rationale: an idempotent-looking "suspend an already-suspended user succeeds silently"
  hides operator races (two admins acting on one incident); a 409 tells the second admin
  the state already changed. Listing deleted users keeps the surface honest about soft
  delete.
  Date: 2026-07-07

- Decision: Mutations refuse **delegated (impersonation) tokens** via the existing
  `denyUnderImpersonation` helper (`shomei-servant/src/Shomei/Servant/Handlers.hs`,
  ~lines 256–272 — verified present under that name); reads allow them.
  Rationale: an operator impersonating a customer must not be able to administer *as*
  that customer (privilege laundering); this extends the exact policy the helper already
  enforces for credential changes, and each refusal is audited by the helper
  (`impersonation_action_blocked`).
  Date: 2026-07-07

- Decision: An admin cannot suspend or delete **their own** account through this API
  (`403`); they can revoke their own sessions.
  Rationale: prevents the last admin locking everyone out with one mistyped request; the
  CLI on the box remains the escape hatch for genuinely removing an admin.
  Date: 2026-07-07

- Decision: `GET /admin/users/{userId}/sessions` returns all of the user's sessions
  newest-first **without pagination**; user listing IS keyset-paginated (cursor on
  `(created_at, user_id)`, the same opaque `"<iso8601>;<uuid>"` cursor codec the audit
  endpoint uses).
  Rationale: sessions per user are bounded small in practice (one per device); users per
  deployment are not. The user cursor reuses `encodeCursor`/`decodeCursor` from
  `shomei-servant/src/Shomei/Servant/DTO.hs` unchanged — same shape, no new codec.
  Date: 2026-07-07

- Decision: The password-reset trigger delegates to the existing
  `Account.requestPasswordReset` workflow (same `Notifier` delivery, same audit event,
  same 202 semantics); a user without an email is `409 user_has_no_email` (new error).
  Rationale: one reset flow, one token table, one notifier path — the admin surface must
  not fork the lifecycle machinery. Since the admin names a user id (not a guessable
  email), a real 409 leaks nothing: the generic-202 anti-enumeration rule protects the
  *public* endpoint, not an authenticated admin.
  Date: 2026-07-07

- Decision: Role grant/revoke are `PUT`/`DELETE` on
  `/admin/users/{userId}/roles/{role}` (the role as a path capture), returning 204; grant
  is idempotent (re-granting an existing role is still 204), revoke of an absent grant is
  404.
  Rationale: PUT-to-a-resource-name is the natural idempotent shape for set membership;
  the workflow (`Shomei.Workflow.Roles`, plan 38) already reports changed/unchanged so the
  handler audits only real changes; the acting admin's id flows in as `granted_by`.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior repository knowledge, but it does assume **plan 38 is
implemented** (hard dependency): the `RoleStore` effect, `Shomei.Workflow.Roles`, the
`ClaimsEnricher` hook, the enforcing combinators, and `shomei-admin roles grant` all
exist. Verify before starting: `shomei-core/src/Shomei/Effect/RoleStore.hs` exists and
plan 38's Progress checklist is fully ticked.

### The repository at a glance

Shōmei is a multi-package Cabal project built inside `nix develop` (`cabal build all`,
`cabal test all`; dev database via `just create-database`). Packages touched here:

- `shomei-core` — domain types (`src/Shomei/Domain/`), effects/ports
  (`src/Shomei/Effect/`; an *effect* is an `effectful` GADT of operations with
  `send`-based helper functions, an *interpreter* its concrete implementation), workflows
  (`src/Shomei/Workflow*`).
- `shomei-postgres` — hasql interpreters (`src/Shomei/Postgres/`).
- `shomei-servant` — the `ShomeiAPI` NamedRoutes record (`src/Shomei/Servant/API.hs`),
  DTOs (`DTO.hs`), auth (`Auth.hs` — `Authenticated = AuthProtect "shomei-jwt"` injecting
  an `AuthUser` carrying `authUserId`, `authSessionId`, `authRoles`, `authScopes`,
  `authClaims`), authz guards (`Authz.hs`), handlers (`Handlers.hs`), error mapping
  (`Error.hs`), OpenAPI derivation (`OpenApi.hs`).
- `shomei-server` — the Warp boot (`src/Shomei/Server/`) and the `shomei-admin` CLI
  (`app/`).
- `shomei-client` — curated wrappers (`src/Shomei/Client.hs`) over `genericClient`.

Every module starts with `import Shomei.Prelude` (custom prelude; import `Data.Set`
qualified). For any third-party API question (hasql combinators, servant instances) read
the dependency source via `mori registry show <lib> --full`; never guess and never search
`/nix/store` or `/`.

### What already exists that this plan builds on

**User lifecycle vocabulary.** `shomei-core/src/Shomei/Domain/User.hs`:
`data UserStatus = UserActive | UserSuspended | UserDeleted`; the `User` record carries
`userId`, `loginId`, optional `email`, `displayName`, `status`, and created/updated
timestamps (read the file for exact field names). `UserStore`
(`shomei-core/src/Shomei/Effect/UserStore.hs`) has **only point operations**:
`CreateUser`, `FindUserById`, `FindUserByLoginId`, `FindUserByEmail`, `UpdateUserStatus`,
`MarkUserEmailVerified` — no listing. `updateUserStatus` is the suspend/delete primitive;
nothing currently calls it from any workflow, and nothing publishes the
`UserSuspended`/`UserDeleted` audit events (verified by grep on 2026-07-07: only
`Shomei.Domain.EventCodec` mentions their data records). This plan writes the first real
producers.

**Sessions.** `Session` (`shomei-core/src/Shomei/Domain/Session.hs`) carries `sessionId`,
`userId`, `status`, `createdAt`, `expiresAt`, `revokedAt :: Maybe UTCTime`,
`actor :: Maybe UserId`. `SessionStore` has `CreateSession`, `FindSessionById`,
`RevokeSession :: SessionId -> UTCTime -> …`, `RevokeAllUserSessions :: UserId -> UTCTime
-> …` — no per-user listing.

**The one existing paginated list — copy its pattern.** `Shomei.Effect.AuthEventReader`
(`shomei-core/src/Shomei/Effect/AuthEventReader.hs`) defines a query record with a
`queryLimit` (default 50, clamped to 1000 by `clampLimit`) and a keyset cursor
`AuditCursor { cursorCreatedAt :: UTCTime, cursorEventId :: UUID }`. Its PostgreSQL
interpreter (`shomei-postgres/src/Shomei/Postgres/AuthEventReader.hs`) uses one SELECT
with the `($n IS NULL OR col = $n)` idiom, the keyset predicate
`(created_at, event_id) < ($cursorTs, $cursorId)`, and
`ORDER BY created_at DESC, event_id DESC LIMIT $n`. The HTTP side (`auditEventsH` in
`Handlers.hs`; `encodeCursor`/`decodeCursor` in `DTO.hs`, opaque format
`"<iso8601>;<uuid>"`) sets `nextCursor` only when the page came back full. Mirror all of
this for user listing.

**Authz.** `requireRole`/`requireScope` guard functions live in
`shomei-servant/src/Shomei/Servant/Authz.hs` (`AuthUser -> Handler ()`, throwing 403).
After plan 38 the `RequireRole`/`RequireScope` *combinators* also enforce, but this plan's
gate is a disjunction (Decision Log) so it uses a new guard function.

**Impersonation refusal.** `denyUnderImpersonation :: Env -> Text -> AuthUser -> Handler ()`
in `Handlers.hs` (~line 256): if the verified claims carry an `act` actor, it publishes an
`ImpersonationActionBlocked` audit event (actor, subject, session, and the action name you
pass) and throws the mapped 403. Its own TODO comment says to call it from every new
sensitive endpoint — this plan does, for every admin mutation.

**Password reset.** `Shomei.Workflow.Account.requestPasswordReset` takes a
`RequestPasswordReset email` command, generates a one-time token, publishes
`PasswordResetRequested`, and emits a `Notifier` notification (the dev interpreter logs
the link; delivery is host-owned). The public endpoint `POST /auth/password-reset/request`
wraps it with anti-enumeration 202 semantics.

**Effect stacks.** Four aligned assemblies list every port — described at length in plan
38's checked-in "Context and Orientation" (read its stack-idiom section):
`Shomei.Servant.Seam.AppEffects`, `Shomei.Server.App.AppEffects`+`runAppIO`,
`Shomei.Effect.InMemory.runInMemory`, and the `shomei-postgres/test/Main.hs` harness.
This plan adds **no new effects** — only new operations on existing ports (`UserStore`,
`SessionStore`) — so no stack wiring changes; only those two ports' interpreters grow
arms.

**Handlers idiom.** Handlers run in Servant's `Handler` and drive workflows through the
seam (`shomei-servant/src/Shomei/Servant/Seam.hs`): `runAuth env action` for workflows
returning `Either AuthError a` (a `Left` becomes the mapped `ServerError` via
`authErrorToServerError`); `runPort env action` for plain port reads. Path captures:
routes already use `Capture "passkeyId" PasskeyId` — every id is an `mmzk-typeid`
`KindID` (UUIDv7 with a type-level prefix) with `FromHttpApiData`, so
`Capture "userId" UserId` and `Capture "sessionId" SessionId` work identically (wire form
`user_…`/`session_…`).

**OpenAPI.** `shomei-servant/src/Shomei/Servant/OpenApi.hs` derives the spec from the API
type; every DTO needs a `ToSchema` instance there (generic derivation matches the DTOs'
default-options `ToJSON`; the conformance suite proves it). Regenerate with
`cabal run shomei-openapi > docs/api/openapi.json`. The conformance suite
(`shomei-servant/test-openapi/Main.hs`, target `shomei-servant-openapi-test`) asserts the
exact path count — 24 before this plan; this plan adds 8 paths (the eleven operations
share paths) → 32. **Spec regeneration is part of any route change.**

**Client.** `shomei-client/src/Shomei/Client.hs` exposes `shomeiClient = genericClient`
plus curated per-operation wrappers (`signup`, `login`, `me`, …) that take a `Token` and
attach it with `bearer`. The curated wrapper surface is incomplete in general (e.g. no
audit-endpoint wrapper today) — this plan adds wrappers for its own routes only and does
not backfill others.

### Events and their compatibility rule

`shomei-core/src/Shomei/Domain/Event.hs` has (after plan 38) 27 constructors;
`Shomei.Domain.EventCodec` projects/reconstructs them, and
`shomei-core/test/Shomei/Domain/EventCodecSpec.hs` round-trips each and guards the count.
The existing `UserSuspendedData`/`UserDeletedData` records carry only
`{userId, occurredAt}` and `SessionRevokedData` only `{sessionId, occurredAt}`. This plan
adds `Maybe UserId` actor fields to them. That is read-compatible with historical rows:
the records derive `FromJSON` generically with default aeson options, under which a
missing `Maybe` field parses as `Nothing` — and for `UserSuspended`/`UserDeleted` no
producer has ever existed, so no rows exist anyway. `SessionRevoked` rows DO exist
(logout, refresh-reuse revocation, impersonation stop); pin the compatibility with a test
that decodes an old-shape payload (no `revokedBy` key).


## Plan of Work

Four milestones: core capabilities, the HTTP surface, spec+client, proof and docs.

### Milestone 1 — Core capabilities: queries, workflows, events

Scope: after this milestone the domain can list users (paginated) and a user's sessions,
and can suspend/reinstate/delete a user and revoke sessions through audited workflow
functions — proven by core and postgres tests. No HTTP yet.

**1.1 `ListUsers`.** In `shomei-core/src/Shomei/Effect/UserStore.hs` add:

```haskell
-- | Keyset-pagination cursor over (created_at, user_id), newest first.
data UserCursor = UserCursor
  { cursorCreatedAt :: !UTCTime,
    cursorUserId :: !UserId
  }
  deriving stock (Eq, Show)

data UserListQuery = UserListQuery
  { queryStatus :: !(Maybe UserStatus),
    queryLimit :: !Int,               -- clamp with 'clampUserLimit' before use
    queryBefore :: !(Maybe UserCursor)
  }
  deriving stock (Eq, Show)

emptyUserListQuery :: UserListQuery   -- Nothing / 50 / Nothing
maxUserLimit :: Int                   -- 1000
clampUserLimit :: Int -> Int          -- \n -> max 1 (min maxUserLimit n)
```

plus a `ListUsers :: UserListQuery -> UserStore m [User]` operation and its `listUsers`
send-helper. This mirrors `AuditEventQuery` deliberately; do **not** try to share the
audit types — different port, different filters.

**1.2 `ListSessionsForUser`.** In `shomei-core/src/Shomei/Effect/SessionStore.hs` add
`ListSessionsForUser :: UserId -> SessionStore m [Session]` (+ send-helper), documented as
newest-first, all statuses.

**1.3 PostgreSQL interpreters.** In `shomei-postgres/src/Shomei/Postgres/UserStore.hs`
add a `ListUsers` arm reusing the module's existing row decoder and rebuild function. The
statement shape (match the column list to the module's existing SELECTs — read the file
first):

```sql
SELECT user_id, login_id, email, display_name, status, email_verified_at, created_at, updated_at
FROM shomei.shomei_users
WHERE ($1::text IS NULL OR status = $1)
  AND ($2::timestamptz IS NULL OR (created_at, user_id) < ($2, $3))
ORDER BY created_at DESC, user_id DESC
LIMIT $4
```

Encode the status filter through the module's existing status↔text codec; build the
4-parameter encoder with the `Params`-monoid idiom
(`(projection >$< E.param …) <> …`) exactly as
`shomei-postgres/src/Shomei/Postgres/AuthEventReader.hs` does for its optional filters
(nullable params need the `$n::type IS NULL` casts shown). In `SessionStore.hs` add the
`ListSessionsForUser` arm:

```sql
SELECT session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id
FROM shomei.shomei_sessions
WHERE user_id = $1
ORDER BY created_at DESC, session_id DESC
```

reusing its `SessionRow` decoder and `rebuild`. No migration is required; the sessions
table already has a user-id index. If the user-list ordering proves to want a composite
`(created_at, user_id)` index at scale, note it in Surprises & Discoveries rather than
adding it pre-emptively.

**1.4 In-memory interpreters.** Add matching arms to `runUserStore` and `runSessionStore`
in `shomei-core/src/Shomei/Effect/InMemory.hs`: filter/sort the `World` maps, apply the
same clamp and cursor predicate, so the servant test's pagination walk runs in-memory
identically.

**1.5 Events and errors.** In `shomei-core/src/Shomei/Domain/Event.hs`: add
`actor :: !(Maybe UserId)` to `UserSuspendedData` and `UserDeletedData`; add
`revokedBy :: !(Maybe UserId)` to `SessionRevokedData`; add
`UserReinstated UserReinstatedData` with
`UserReinstatedData {userId :: !UserId, actor :: !(Maybe UserId), occurredAt :: !UTCTime}`.
Update `Shomei.Domain.EventCodec` (`projectAuthEvent` + `reconstructAuthEvent`; new event
type string `user_reinstated`; the widened records keep their existing strings). In
`shomei-core/test/Shomei/Domain/EventCodecSpec.hs`: bump the count guard 27 → 28, add a
`UserReinstated` round-trip, and add the backward-compat case asserting
`reconstructAuthEvent "session_revoked" <payload without revokedBy>` yields
`revokedBy = Nothing`. Fix the existing `SessionRevoked` publishers (grep
`SessionRevokedData` across `shomei-core/src` — logout, refresh-reuse revocation,
impersonation stop) to pass `revokedBy = Nothing`.

In `shomei-core/src/Shomei/Error.hs` add `InvalidUserStatus` and `UserHasNoEmail`; map
them in `shomei-servant/src/Shomei/Servant/Error.hs`:

```haskell
InvalidUserStatus -> json err409 "invalid_user_status" "User is not in a state that allows this action"
UserHasNoEmail    -> json err409 "user_has_no_email" "User has no email address"
```

(`UserNotFound` exists from plan 38.) Exhaustiveness warnings will flag any other `case`
over `AuthError`.

**1.6 The admin workflows.** Create `shomei-core/src/Shomei/Workflow/Admin.hs`:

```haskell
suspendUser, reinstateUser, deleteUser ::
  (UserStore :> es, SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId ->   -- the acting admin (recorded as the event's actor)
  UserId ->   -- the target
  Eff es (Either AuthError ())

revokeUserSessions ::
  (SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId -> UserId -> Eff es (Either AuthError Int)   -- how many were revoked

revokeOneSession ::
  (SessionStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  UserId -> SessionId -> Eff es (Either AuthError ())
```

Semantics (Decision Log): look the target up (`Nothing` → `Left UserNotFound`); enforce
the strict transition (suspend: from `UserActive` only; reinstate: from `UserSuspended`
only; delete: from anything except `UserDeleted`; otherwise `Left InvalidUserStatus`);
`updateUserStatus`; suspend and delete also `revokeAllUserSessions target ts`; publish
the event with `actor = Just actingAdmin`. `revokeUserSessions` lists the target's
sessions, revokes the active ones, publishes one `SessionRevoked` per revocation with
`revokedBy = Just actingAdmin`, and returns the count. `revokeOneSession` finds the
session (`Nothing` → `Left SessionNotFound`), revokes, publishes. The workflows do **not**
authorize and do **not** implement the self-targeting refusal — those are HTTP-layer
policy (a future surface may differ); say so in the module haddock.

**1.7 Tests.** `shomei-postgres/test/Main.hs`: seed users across statuses; assert
`listUsers` newest-first ordering, the status filter, and that a `queryLimit = 2` cursor
walk is disjoint and complete; assert `listSessionsForUser` returns seeded sessions
newest-first. Core (in-memory) tests for `Shomei.Workflow.Admin`: suspend flips status,
revokes sessions, and publishes `UserSuspended` carrying the actor; wrong-state
transitions yield `InvalidUserStatus`; delete-then-reinstate yields `InvalidUserStatus`.

Acceptance: `cabal test shomei-core:shomei-core-test shomei-postgres:shomei-postgres-test`
green.

### Milestone 2 — The HTTP surface

Scope: after this milestone all eleven operations exist — gated, audited,
impersonation-refused — and are integration-tested through a real Warp round-trip.

**2.1 The guard.** In `shomei-servant/src/Shomei/Servant/Authz.hs`:

```haskell
-- | The admin gate (EP-2 of MasterPlan 7): the principal must carry the @admin@ role
-- (granted via the plan-38 store) OR the @shomei:admin@ scope (mintable to service
-- tokens), so both humans and DB-less services can administer.
requireAdmin :: AuthUser -> Handler ()
requireAdmin u
  | Role "admin" `Set.member` u.authRoles = pure ()
  | Scope "shomei:admin" `Set.member` u.authScopes = pure ()
  | otherwise = throwError err403 {errBody = "missing admin role or scope"}
```

Match the error-body style of the file's other guards as they exist at implementation
time (plan 40 may have converted them to its envelope — follow suit).

**2.2 DTOs.** In `shomei-servant/src/Shomei/Servant/DTO.hs` (same conventions as
neighbors: `deriving stock (Generic)`, `deriving anyclass (FromJSON, ToJSON)`, ISO-8601
text timestamps):

```haskell
data AdminUserResponse = AdminUserResponse
  { user :: !UserResponse,
    roles :: ![Text]   -- the persistent role grants, sorted
  }

data AdminUsersPage = AdminUsersPage
  { users :: ![UserResponse],
    nextCursor :: !(Maybe Text)   -- opaque; pass back as ?before= for the next page
  }
```

plus `adminUserToResponse :: User -> Set Role -> AdminUserResponse`. Reuse
`userToResponse`/`sessionToResponse` and the existing `encodeCursor`/`decodeCursor`
(convert the user id with `userIdToUUID` — same `"<iso8601>;<uuid>"` cursor shape).
Confirm `UserResponse` exposes the user's `status`; if it does not, add the field
(additive JSON; CHANGELOG note) — the admin listing is useless without it.

**2.3 Routes.** Add eleven fields to `ShomeiAPI` in
`shomei-servant/src/Shomei/Servant/API.hs`, in the record's existing style, each with a
haddock comment. All carry `Authenticated :>`:

```haskell
adminListUsers ::
  mode :- "admin" :> "users" :> Authenticated
    :> QueryParam "status" Text :> QueryParam "limit" Int :> QueryParam "before" Text
    :> Get '[JSON] AdminUsersPage,
adminGetUser ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> Get '[JSON] AdminUserResponse,
adminSuspendUser ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "suspend" :> PostNoContent,
adminReinstateUser ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "reinstate" :> PostNoContent,
adminDeleteUser ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> Verb 'DELETE 204 '[JSON] NoContent,
adminListSessions ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "sessions" :> Get '[JSON] [SessionResponse],
adminRevokeSessions ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "sessions" :> Verb 'DELETE 204 '[JSON] NoContent,
adminRevokeSession ::
  mode :- "admin" :> "sessions" :> Authenticated :> Capture "sessionId" SessionId
    :> Verb 'DELETE 204 '[JSON] NoContent,
adminPasswordReset ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "password-reset" :> Verb 'POST 202 '[JSON] NoContent,
adminGrantRole ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "roles" :> Capture "role" Text :> Verb 'PUT 204 '[JSON] NoContent,
adminRevokeRole ::
  mode :- "admin" :> "users" :> Authenticated :> Capture "userId" UserId
    :> "roles" :> Capture "role" Text :> Verb 'DELETE 204 '[JSON] NoContent
```

(If plan 40 has landed, these become fields of its v1 application record instead — same
shapes, `/v1` prefix supplied by the outer record.)

**2.4 Handlers.** In `shomei-servant/src/Shomei/Servant/Handlers.hs`, one handler per
route, all following one shape: `requireAdmin user` first; then, for every mutation,
`denyUnderImpersonation env "admin_<action>" user` (action names: `admin_suspend`,
`admin_reinstate`, `admin_delete`, `admin_revoke_sessions`, `admin_revoke_session`,
`admin_password_reset`, `admin_grant_role`, `admin_revoke_role`); then parse/validate;
then `runAuth`/`runPort` a Milestone-1 or plan-38 workflow; then render. Handler-specific
notes:

- `adminListUsersH`: parse `?status=` via the domain status↔text codec (unknown text →
  400 in the same JSON style as `auditEventsH`'s `badRequest`); default limit 50; decode
  `?before=` with `decodeCursor` (invalid → 400); set `nextCursor` when the page is full,
  copying `auditEventsH`'s tail logic.
- `adminGetUserH`: `findUserById` (`Nothing` → `throwError (authErrorToServerError
  UserNotFound)`), `rolesOf` from plan 38, render `AdminUserResponse`.
- `adminSuspendUserH`/`adminDeleteUserH`: first refuse `target == user.authUserId` with a
  403 JSON body, code `"self_target_forbidden"` (Decision Log); then the workflow with
  `user.authUserId` as actor.
- `adminPasswordResetH`: load the target; no email → `UserHasNoEmail` (409); else
  `runAuth env (Account.requestPasswordReset env.config (Account.RequestPasswordReset
  email))` and return the 202 `NoContent`.
- `adminGrantRoleH`/`adminRevokeRoleH`: trim the captured role text, refuse blank with
  400; `grantRoleTo (Just user.authUserId) target (Role r)` — both `Right True` and
  `Right False` are 204 (idempotent PUT); revoke maps `Right False` to a 404 with code
  `"role_not_granted"`.

Wire all eleven into the `shomeiServer` record assembly.

**2.5 Tests.** Extend `shomei-servant/test/Main.hs` (it already runs the full API over
Warp on the in-memory stack and mints admin/scoped/delegated tokens — reuse those
helpers):

- Authz matrix on `GET /admin/users`: no token → 401; ordinary token → 403; admin-roled
  token → 200; `shomei:admin`-scoped token → 200.
- Lifecycle: sign a target up over HTTP; suspend → target login now 401 and their session
  shows revoked via `GET /admin/users/{id}/sessions`; double-suspend → 409; reinstate →
  login works; delete → subsequent mutations 409, user still listed with
  `"status":"deleted"`.
- Sessions: revoke-one and revoke-all → 204, reflected in the session list.
- Roles over HTTP: PUT grant → the target's *next* login token carries the role (decode
  the JWT as the suite does elsewhere); DELETE → 204; DELETE again → 404.
- Impersonation: a delegated token gets 403 on `POST …/suspend`; reads still work for it.
- Self-protection: the admin suspending themselves → 403.
- Audit actor: `GET /admin/audit/events?type=user_suspended` (admin token) shows the
  event whose payload carries the acting admin's id.
- Pagination: with ≥3 users, `?limit=2` then `?before=<nextCursor>` walks disjoint,
  complete pages.

Acceptance: `cabal test shomei-servant:shomei-servant-test` green.

### Milestone 3 — OpenAPI and client

Scope: the committed spec documents the admin surface; `shomei-client` gets typed
wrappers.

In `shomei-servant/src/Shomei/Servant/OpenApi.hs` add
`instance ToSchema AdminUserResponse` and `instance ToSchema AdminUsersPage` (generic,
like the neighbors — `UserResponse`/`SessionResponse` instances already exist).
Regenerate and commit the spec; bump the conformance path count 24 → 32 in
`shomei-servant/test-openapi/Main.hs`. In `shomei-client/src/Shomei/Client.hs` add eleven
wrappers following the `me`/`logout` pattern (qualified selector application:
`API.adminSuspendUser shomeiClient (bearer tok) uid`), e.g.:

```haskell
adminListUsers :: ClientEnv -> Token -> Maybe Text -> Maybe Int -> Maybe Text -> IO (Either ClientError AdminUsersPage)
adminSuspendUser :: ClientEnv -> Token -> UserId -> IO (Either ClientError ())
adminGrantRole :: ClientEnv -> Token -> UserId -> Text -> IO (Either ClientError ())
```

Do not backfill wrappers for pre-existing unwrapped routes — out of scope.

Acceptance: `cabal test shomei-servant:shomei-servant-openapi-test` green (32 paths);
`git diff docs/api/openapi.json` shows exactly the eight new paths + two schemas;
`cabal build shomei-client` green.

### Milestone 4 — Live proof and docs

Run the Validation transcript against the dev server and paste the real output into this
plan. Add an "Admin API" section to `docs/user/api.md` (all eleven operations, the
role-or-scope authz rule, impersonation refusal, pagination, the strict status
transitions, and the token-staleness note: suspended users' outstanding access tokens ride
out their TTL unless `sessionCheckMode = VerifyTokenAndSession`). Extend
`docs/user/security.md`'s roles section with the HTTP grant path and `shomei:admin`.
CHANGELOG entry under Unreleased. Tick EP-2 in MasterPlan 7's registry and Progress.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shomei`, inside `nix develop`.

```bash
nix develop
just create-database   # idempotent dev DB create+migrate

# verify the hard dependency before starting:
test -f shomei-core/src/Shomei/Effect/RoleStore.hs && echo "plan 38 present"

# iterate:
cabal build all
cabal test all

# spec regeneration (Milestone 3):
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json    # expect ~8 new paths + AdminUserResponse/AdminUsersPage schemas
```

Expected suite shape when done:

```text
shomei-core-test            ... passed (EventCodec guard = 28; Workflow.Admin tests)
shomei-postgres-test        ... passed (listUsers pagination/filter; listSessionsForUser)
shomei-servant-test         ... passed (admin authz matrix, lifecycle, roles, audit actor)
shomei-servant-openapi-test ... passed (32 paths)
```

Conventional commits per milestone:

```text
feat(core): user/session listing + audited admin lifecycle workflows (EP-2 M1)
feat(servant): /admin user and session management API (EP-2 M2)
feat(servant): OpenAPI + shomei-client coverage for the admin API (EP-2 M3)
docs(user): document the admin HTTP API (EP-2 M4)
```


## Validation and Acceptance

End-to-end transcript (dev server on :8080; `jq` available; prefix paths with `/v1` if
plan 40 landed first):

```bash
# bootstrap an admin (plan 38) and log in
cabal run shomei-admin -- users create --email admin@example.com --password 'Str0ng-Pass-123!'
cabal run shomei-admin -- roles grant --user user_01ADMIN... --role admin
ADM=$(curl -s -XPOST localhost:8080/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)

# create a managed user over the public API
curl -s -XPOST localhost:8080/auth/signup -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"An0ther-Pass-123!"}' | jq -r .user.userId
# → user_01TARGET...

# list users
curl -s localhost:8080/admin/users -H "Authorization: Bearer $ADM" | jq '.users | length, .nextCursor'
# → 2
# → null

# suspend: 204; the target's login now fails; a repeat suspend is 409
curl -s -o /dev/null -w '%{http_code}\n' -XPOST \
  localhost:8080/admin/users/user_01TARGET.../suspend -H "Authorization: Bearer $ADM"
# → 204
curl -s -o /dev/null -w '%{http_code}\n' -XPOST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"user@example.com","password":"An0ther-Pass-123!"}'
# → 401
curl -s -XPOST localhost:8080/admin/users/user_01TARGET.../suspend \
  -H "Authorization: Bearer $ADM"
# → 409 {"error":"invalid_user_status","message":"User is not in a state that allows this action"}

# reinstate, grant a role over HTTP, check the audit actor
curl -s -o /dev/null -w '%{http_code}\n' -XPOST \
  localhost:8080/admin/users/user_01TARGET.../reinstate -H "Authorization: Bearer $ADM"
# → 204
curl -s -o /dev/null -w '%{http_code}\n' -XPUT \
  localhost:8080/admin/users/user_01TARGET.../roles/auditor -H "Authorization: Bearer $ADM"
# → 204
curl -s "localhost:8080/admin/audit/events?type=user_suspended" \
  -H "Authorization: Bearer $ADM" | jq '.events[0].payload.actor'
# → "user_01ADMIN..."

# refusals
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/admin/users              # → 401
# (with a plain user token) → 403
# (with a delegated/impersonation token, POST …/suspend) → 403 impersonation_action_blocked
# (admin suspending themselves) → 403 self_target_forbidden
```

Acceptance criteria: every line behaves as shown; the Milestone 2.5 test matrix passes;
the spec documents all eleven operations (conformance at 32 paths); `shomei-client`
builds with the new wrappers; suspended users cannot log in and their sessions are
revoked; every mutation's audit row carries the acting admin's id; delegated tokens are
refused for mutations and the refusal is itself audited.


## Idempotence and Recovery

This plan adds no migration, so there is nothing destructive to roll back. All code steps
are additive and re-runnable; the suites can be re-run at any point. The API semantics are
deliberately race-honest (strict transitions → a repeated suspend is a clean 409; PUT
role-grant is idempotent), so re-driving the acceptance transcript needs only a state
reset (reinstate the target) or a dev-database rebuild
(`dropdb "$PGDATABASE" && just create-database`). If work pauses between Milestones 2 and
3, the API functions without spec/client coverage, but the conformance suite's path-count
assertion fails loudly until the spec is regenerated — that failure is the designed guard
against shipping the gap; do not silence it by skipping the suite.


## Interfaces and Dependencies

No new external dependencies (servant, servant-server, hasql, effectful, aeson,
containers, uuid are all in the workspace; add per-stanza `build-depends` only if GHC
asks). Interfaces consumed from plan 38 (must already exist): `Shomei.Effect.RoleStore`
(`listRolesForUser`), `Shomei.Workflow.Roles` (`grantRoleTo`, `revokeRoleFrom`,
`rolesOf`), `Shomei.Error.AuthError.UserNotFound`, and mint-time claims enrichment (so a
granted role reaches the next token).

Must exist at the end (full module paths):

- `Shomei.Effect.UserStore`: `ListUsers :: UserListQuery -> UserStore m [User]`,
  `UserListQuery (..)`, `UserCursor (..)`, `emptyUserListQuery`, `maxUserLimit`,
  `clampUserLimit`, `listUsers`.
- `Shomei.Effect.SessionStore`: `ListSessionsForUser :: UserId -> SessionStore m [Session]`,
  `listSessionsForUser`.
- `Shomei.Workflow.Admin`: `suspendUser` / `reinstateUser` / `deleteUser`
  `:: UserId -> UserId -> Eff es (Either AuthError ())`;
  `revokeUserSessions :: UserId -> UserId -> Eff es (Either AuthError Int)`;
  `revokeOneSession :: UserId -> SessionId -> Eff es (Either AuthError ())`.
- `Shomei.Domain.Event`: actor-carrying `UserSuspendedData` / `UserDeletedData` /
  `SessionRevokedData`; new `UserReinstated` / `UserReinstatedData`; EventCodec coverage
  and the 28-constructor guard.
- `Shomei.Error`: `InvalidUserStatus`, `UserHasNoEmail` (mapped to 409s in
  `Shomei.Servant.Error`).
- `Shomei.Servant.Authz.requireAdmin :: AuthUser -> Handler ()`.
- `Shomei.Servant.DTO`: `AdminUserResponse`, `AdminUsersPage`, `adminUserToResponse`.
- `Shomei.Servant.API.ShomeiAPI`: the eleven `admin*` fields, served by
  `Shomei.Servant.Handlers.shomeiServer`.
- Regenerated `docs/api/openapi.json` (32 paths) + updated conformance count.
- `Shomei.Client`: `adminListUsers`, `adminGetUser`, `adminSuspendUser`,
  `adminReinstateUser`, `adminDeleteUser`, `adminListSessions`, `adminRevokeSessions`,
  `adminRevokeSession`, `adminPasswordReset`, `adminGrantRole`, `adminRevokeRole`.
