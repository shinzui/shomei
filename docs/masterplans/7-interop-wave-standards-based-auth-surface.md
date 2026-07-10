---
id: 7
slug: interop-wave-standards-based-auth-surface
title: "Interop Wave: Standards-Based Auth Surface"
kind: master-plan
created_at: 2026-07-07T17:22:07Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
---

# Interop Wave: Standards-Based Auth Surface

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A July 2026 review compared Shōmei against Zitadel (a full-featured open-source IAM at
`/Users/shinzui/Keikaku/hub/zitadel`, referenced here only for study — nothing is vendored
from it). The conclusion: Shōmei's per-feature depth already matches or beats Zitadel where
the features overlap (refresh reuse detection, zero-downtime key rotation design, passkeys as
both second factor and passwordless, impersonation safeguards), but Shōmei is "an auth API you
integrate bespoke" while Zitadel is "an auth provider any stack can consume." The gap is
interop shape, not depth. Separately, the review found the authorization half of Shōmei's own
model is missing: roles and scopes ride in JWT claims but nothing can grant them — the
`admin`-gated audit endpoint is unsatisfiable by any production flow, and the
`RequireRole`/`RequireScope` Servant combinators are phantom types that enforce nothing.

After this initiative, Shōmei is a standards-consumable auth provider. Concretely: roles and
scopes have a persistent source of truth with granting paths (admin API, CLI bootstrap, and a
claims-enrichment hook for embedding hosts), and the role/scope combinators genuinely enforce;
a deployed instance is administrable over HTTP (user lifecycle, session revocation, role
grants) instead of CLI-on-the-box only; the HTTP API lives under `/v1` with one universal
problem-details error envelope that the OpenAPI spec documents per route; service-to-service
auth is standard OAuth2 `client_credentials` against database-backed service accounts that can
be created, rotated, and revoked at runtime; Shōmei publishes `/.well-known/openid-configuration`
and implements the OIDC provider subset that lets stock middleware (Spring, ASP.NET, Envoy,
oauth2-proxy) auto-configure: authorization code with PKCE, token, introspection, revocation,
and userinfo endpoints; impersonation and service on-behalf-of flows are reachable through a
standard RFC 8693 token-exchange grant; TOTP joins passkeys as a second factor with hashed
one-time recovery codes as the lockout escape hatch; and account-lifecycle email actually
delivers in production through SMTP and webhook `Notifier` interpreters.

Authorization follows a deliberate two-tier story. Shōmei's built-in RBAC — flat roles with a
registry, default signup roles, role→permission definitions, and time-bound grants — is
self-contained and complete for deployments that want no second system, and it gates Shōmei's
own `/admin` surface with zero external infrastructure. For robust fine-grained authorization
(resource-scoped permissions, relationship-derived access, live revocation, caveats), the
documented recommendation is **en**, the author's Zanzibar-style ReBAC toolkit at
`/Users/shinzui/Keikaku/bokuno/en`; this initiative ships the integration examples and guide
that make "shomei for authentication, en for authorization" the paved road. The built-in tier
is never removed in favor of en.

Explicitly out of scope, deliberately and permanently (recorded in the Decision Log):
multi-tenancy (instances/orgs — tenant-per-deployment plus a host-managed `tenant` claim via
`extraClaims` covers Shōmei's cases), SAML and LDAP, SCIM (only coherent after the admin API
exists; revisit later), hosted login UI / console / branding (Shōmei's headless,
host-owns-the-UI stance is its differentiator), JavaScript action sandboxes, device
authorization grant, quotas, and SMS/email OTP factors.


## Decomposition Strategy

Ten work streams exceed the seven-plan guideline, so they are grouped into three phases —
implementation waves that also match dependency structure and risk.

Phase 1 (Foundations) makes the existing surface trustworthy and evolvable before new
protocol surface is added: EP-1 gives roles/scopes a source of truth (the review's
"unsatisfiable admin role" finding makes this the keystone — both the admin API and every
gated route depend on it), including the role registry and default signup roles; EP-9 grows
that built-in tier with role→permission indirection and time-bound grants so non-en adopters
never hard-code role names across services; EP-2 exposes administration over HTTP; EP-3
establishes `/v1` and the universal error envelope. EP-3 sits in Phase 1 because it is a
breaking-change window: every route added by later plans must be born under `/v1` with the
new envelope, not migrated afterward.

Phase 2 (Standards surface) recasts Shōmei's token machinery as OAuth2/OIDC: EP-4 moves
service accounts from static config into the database and introduces the `/oauth/token`
endpoint with the `client_credentials` grant; EP-5 builds the OIDC provider subset around that
endpoint (discovery, authorization code with PKCE, introspection, revocation, userinfo); EP-6
adds RFC 8693 token exchange as a third grant, generalizing the existing impersonation
workflow. Splitting EP-4 from EP-5 keeps the highest-value microservice win
(client_credentials) shippable without the larger browser-flow work; EP-6 is separate because
it generalizes a different workflow (impersonation) and is droppable without weakening EP-4/EP-5.

Phase 3 (Factors and delivery) is user-facing completeness, independent of the protocol work:
EP-7 adds TOTP and recovery codes by extending the existing factor-agnostic MFA shape
(`mfa_required` login arm and `/auth/mfa/complete`); EP-8 ships real SMTP and webhook
`Notifier` interpreters so verification/reset email leaves the process; EP-10 ships the en
integration example and guide (nominally Phase 3, but dependency-free — it may run at any
point).

The alternative of one mega-plan "OIDC provider" containing EP-4 through EP-6 was rejected: it
would exceed five milestones, and client_credentials alone delivers most of the
distributed-microservice value with a fraction of the risk. The alternative of putting EP-3
last (version the API once everything exists) was rejected because it guarantees a second
migration for every consumer who adopts the Phase 2 endpoints early.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Persistent Roles and Scopes with a Granting Path and Claims Enrichment | docs/plans/38-persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment.md | None | None | Complete |
| 2 | Admin HTTP API for User and Session Management | docs/plans/39-admin-http-api-for-user-and-session-management.md | EP-1 | EP-3 | In Progress |
| 3 | API v1 Prefix and Universal Problem-Details Error Envelope | docs/plans/40-api-v1-prefix-and-universal-problem-details-error-envelope.md | None | None | Complete |
| 4 | Database-Backed Service Accounts with OAuth2 Client-Credentials Grant | docs/plans/41-database-backed-service-accounts-with-oauth2-client-credentials-grant.md | None | EP-3 | Not Started |
| 5 | OIDC Provider Subset: Discovery, Authorization Code with PKCE, Introspection | docs/plans/42-oidc-provider-subset-discovery-authorization-code-with-pkce-introspection.md | EP-4 | EP-1 | Not Started |
| 6 | RFC 8693 Token Exchange Endpoint | docs/plans/43-rfc-8693-token-exchange-endpoint.md | EP-4 | EP-5 | Not Started |
| 7 | TOTP Second Factor and Recovery Codes | docs/plans/44-totp-second-factor-and-recovery-codes.md | None | EP-3 | Not Started |
| 8 | SMTP and Webhook Notifier Interpreters | docs/plans/45-smtp-and-webhook-notifier-interpreters.md | None | None | Not Started |
| 9 | Role Definitions, Permissions, and Time-Bound Grants | docs/plans/46-role-definitions-permissions-and-time-bound-grants.md | EP-1 | EP-2 | Not Started |
| 10 | En Integration: Examples and Guidance for the Recommended Authorization Layer | docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md | None | EP-1, EP-4 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Phases: Phase 1 = EP-1, EP-2, EP-3, EP-9. Phase 2 = EP-4, EP-5, EP-6. Phase 3 = EP-7, EP-8,
EP-10 (EP-10 has no hard dependencies and may run at any point).


## Dependency Graph

EP-2 hard-depends on EP-1 because the admin API's authorization gate (`admin` role or scope)
and its role-grant routes are meaningless until roles have persistence and a claims path; the
plan literally cannot demonstrate an authorized request without EP-1's granting mechanism.
EP-2 soft-depends on EP-3 so admin routes are born under `/v1` with the problem-details
envelope; if EP-3 has not landed, EP-2 proceeds on the old surface and EP-3 sweeps it.

EP-5 hard-depends on EP-4 because EP-4 creates the `/oauth/token` endpoint, its grant-dispatch
structure, and the `oauth_clients`-style credential storage that the authorization-code grant
authenticates against; EP-5 adds grants and endpoints around that skeleton. EP-6 hard-depends
on EP-4 for the same token endpoint and soft-depends on EP-5 only for consistency of
introspection responses on exchanged tokens.

EP-5 soft-depends on EP-1: userinfo and ID-token claims should include role/scope claims from
the persistent store when it exists, but EP-5 can ship reading the (possibly empty) claim sets
that `buildClaims` already produces.

EP-4, EP-7, and EP-8 soft-depend on EP-3 in the same born-under-`/v1` sense as EP-2 (EP-4's
`/oauth/*` and well-known routes are conventionally *unversioned* — the exception is documented
in EP-3 and in Integration Points). EP-8 has no dependencies at all and is a good
warm-up or parallel filler at any point. EP-7 is independent of the protocol plans; its only
coordination is with the MFA method union (Integration Points).

EP-9 hard-depends on EP-1 because it extends every artifact EP-1 creates: the role registry
table gains a permissions side-table, the grants table gains an expiry column, the RoleStore
port gains definition/permission operations, the claims-enrichment path resolves permissions,
and the `RequirePermission` combinator follows the enforcing-combinator pattern EP-1
establishes. Its soft dependency on EP-2 covers the admin routes that expose role/permission
management over HTTP. It also has a cross-MasterPlan integration with the Operational
MasterPlan's sweeper (`docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md`)
for expired-grant cleanup.

EP-10 has no hard dependencies: the en integration example and guide work against today's
`Authenticated`/`AuthUser` surface. It soft-depends on EP-1 (its documentation cross-links the
two-tier boundary text EP-1 adds to `docs/user/security.md`) and EP-4 (the service-account
subject-mapping note references `client_id`s that EP-4 introduces).

Parallelism guide: Phase 1 can run EP-1 and EP-3 concurrently, with EP-2 and EP-9 starting
once EP-1 lands. Phase 2 can start EP-4 concurrently with Phase 1 (it integrates with, but
does not require, EP-3). EP-7, EP-8, and EP-10 fit anywhere.


## Integration Points

Claims construction (`shomei-core/src/Shomei/Workflow/Session.hs`, `buildClaims` /
`buildClaimsWith`; `shomei-core/src/Shomei/Domain/Claims.hs`): involved plans EP-1, EP-5, EP-6.
EP-1 owns the change: it introduces the claims-enrichment hook (role/scope population from the
persistent store plus a host-supplied enrichment function) that `issueSession` calls. EP-5's
ID-token/userinfo claims and EP-6's exchanged-token claims must be built through that same
hook, never by re-reading stores in the HTTP layer.

Token endpoint and grant dispatch (new module in `shomei-servant`, wired in
`shomei-server`): involved plans EP-4 (owner), EP-5, EP-6. EP-4 defines `POST /oauth/token`
accepting `application/x-www-form-urlencoded` with a `grant_type` dispatcher and the OAuth2
error-response shape (`invalid_grant`, `invalid_client`, …, per RFC 6749 §5.2 — distinct from
the EP-3 problem-details envelope; both plans document this boundary). EP-5 registers
`authorization_code` (+ PKCE verification) and `refresh_token`; EP-6 registers
`urn:ietf:params:oauth:grant-type:token-exchange`. Client authentication (secret post/basic)
is defined by EP-4 and reused by both.

Versioning boundary (`shomei-servant/src/Shomei/Servant/API.hs`): involved plans EP-3 (owner)
and every plan adding routes (EP-2, EP-4, EP-5, EP-7). **Landed 2026-07-09.** The served tree is
`ShomeiRoutes`: `v1 :: "v1" :> NamedRoutes ShomeiAPI` plus unversioned `jwks`, `openapi`,
`health`, `ready` (`/metrics` stays a WAI middleware; `/oauth/*` joins the unversioned root).
A new application route goes in `ShomeiAPI` and inherits `/v1` for free; a new protocol endpoint
goes in `ShomeiRoutes`. Later plans extend the OpenAPI generation
(`shomei-servant/src/Shomei/Servant/OpenApi.hs`) for their routes: add an entry to `routeErrors`
for the codes only the handler knows, and the `baselineSpecs` pass documents the 401s and the
body-parse 400 automatically.

**A route's path is also written down in four non-Servant places** — see Surprises. A plan adding
a throttled endpoint extends `RateLimit.throttledPath` *and* `testThrottledPathsAreVersioned`; one
changing a success status extends `Metrics.recordRequest`.

Error envelope (`shomei-servant/src/Shomei/Servant/Error.hs`): EP-3 owns it. **Landed
2026-07-09.** `ProblemSpec` constants (41 of them, all exported) are the single source: the
runtime renders them through `toProblemError`, and `OpenApi.hs` renders the same constants into
`components.schemas.Problem` plus per-operation error responses. EP-2, EP-5, and EP-7 route every
new failure through `toProblemError` (except the RFC 6749 token-endpoint errors owned by EP-4,
above), add their new specs to `problemCatalog`, and list them in `routeErrors`. The conformance
suite fails if a documented code or status is not in the catalog, or if the runtime document stops
validating against the published schema.

MFA method union (`shomei-servant/src/Shomei/Servant/DTO.hs` `LoginResponse` /
`MfaRequiredResponse`; `shomei-core/src/Shomei/Workflow/Mfa.hs`): involved plans EP-7 (owner
of the change) and, read-only, the existing passkey flows. EP-7 extends the advertised-methods
field and `/auth/mfa/complete` request union with `totp` and `recovery_code` variants; the
extension must be additive so existing passkey-only clients keep parsing responses.

Service-account storage (new migration in `shomei-migrations/sql-migrations/`, new port in
`shomei-core/src/Shomei/Effect/`): EP-4 owns it. EP-6 reads service accounts for actor
authentication in service on-behalf-of exchanges. The existing config-defined service accounts
(`Shomei.Config` service-token sub-record) remain supported during a deprecation window; EP-4
documents the migration path.

`shomei-admin` CLI (`shomei-server/app/`): EP-1 adds `roles grant/revoke` plus the role
registry subcommands (the bootstrap path for the first admin), EP-9 adds
`roles allow/disallow/show` and grant-expiry flags, EP-4 adds
`service-accounts create/rotate/revoke`. Additive subcommands; no shared code beyond the
existing CLI plumbing.

Role storage (`shomei_roles` registry and `shomei_role_grants` tables, `RoleStore` port in
`shomei-core/src/Shomei/Effect/`): EP-1 owns the tables and the port; EP-9 extends them
(permissions side-table, nullable `expires_at` on grants, new port operations) and must do so
additively — EP-2's admin routes and EP-1's CLI keep working unchanged.

Claims vocabulary (`shomei-core/src/Shomei/Domain/Claims.hs`, `reservedClaimKeys`, and the
matching sign/verify claim filters in `shomei-jwt`): EP-1 populates the existing `roles` and
`scopes` claims through its enrichment hook; EP-9 adds a `permissions` claim, which must join
`reservedClaimKeys` and the jwt-layer filter tables so `extraClaims` cannot forge it. Any plan
adding a reserved claim updates all of these sites together.

The en boundary (docs and combinator naming): shomei's built-in RBAC (EP-1, EP-9) is the
self-contained tier; the author's sibling project **en** (`/Users/shinzui/Keikaku/bokuno/en`,
a Zanzibar-style ReBAC toolkit) is the documented recommendation for fine-grained,
relationship-based authorization. EP-10 owns the integration guide and examples; EP-1 and
EP-9 own short boundary statements in their docs milestones that point at it. Naming is
verified non-colliding: shomei's `RequireRole`/`RequireScope`/`RequirePermission` are
type-level combinators over static JWT claims; en-servant exports only a term-level
`requirePermission` handler guard for live relationship checks, and neither library imports
the other.


## Progress

- [x] EP-1: Role/scope grant storage (migration) and port with Postgres + in-memory interpreters
- [x] EP-1: Claims population at token mint through an enrichment hook
- [x] EP-1: `shomei-admin roles grant`
- [x] EP-1: `RequireRole`/`RequireScope` enforce via `HasServer` (or are removed from the public surface)
- [ ] EP-2: Admin routes: list/get users, suspend/reinstate/delete, revoke sessions, grant/revoke roles
- [ ] EP-2: Admin surface authorized by role/scope; audited; OpenAPI documented
- [x] EP-3: `/v1` prefix with unversioned protocol/infra exceptions; redirect-or-410 policy for old paths
- [x] EP-3: Universal problem-details envelope on every error path (including auth combinator 401s)
- [x] EP-3: OpenAPI error schema + per-route error responses; status-code fixes (201 signup, idempotent logout)
- [ ] EP-4: Service-account table, port, CLI; secrets hashed, rotatable, revocable at runtime
- [ ] EP-4: `POST /oauth/token` with `client_credentials` grant and RFC 6749 error shape
- [ ] EP-5: `/.well-known/openid-configuration` discovery document
- [ ] EP-5: Authorization-code grant with mandatory PKCE for public clients; consent delegated to host redirect contract
- [ ] EP-5: Introspection, revocation, userinfo endpoints; ID tokens signed by the existing key machinery
- [ ] EP-6: Token-exchange grant covering impersonation and service on-behalf-of; bespoke `/auth/impersonate` deprecated
- [ ] EP-7: TOTP enrollment/verification with encrypted secrets; login MFA union extended
- [ ] EP-7: Hashed one-time recovery codes with generation and consumption flows
- [ ] EP-8: SMTP `Notifier` interpreter with TLS and auth, configured via Dhall/env
- [ ] EP-8: Webhook `Notifier` interpreter (signed JSON POST); docs position it as the eventing hook
- [ ] EP-9: Role→permission definitions (`shomei_role_permissions`) with a `permissions` claim and `RequirePermission` combinator
- [ ] EP-9: Time-bound grants (`expires_at`), expiry-filtered at mint, CLI flags, sweeper integration
- [ ] EP-10: `examples/embedded-with-en` — shomei auth + embedded en authorization, end-to-end transcript
- [ ] EP-10: Microservice recipe (JWKS verify → subject mapping → en-client check) and `docs/user/authorization.md` two-tier guide


## Surprises & Discoveries

**2026-07-09 (EP-1) — Adding a migration requires editing `shomei-migrations/src/Shomei/Migrations.hs`,
not touching its `.cabal`.** `embeddedFiles = $(embedDir "sql-migrations")` is a compile-time
Template Haskell splice; under cabal 3.16 (content-hash change detection) neither
`touch shomei-migrations/shomei-migrations.cabal` — what the `Justfile`'s `migrate` recipe does —
nor `--ghc-options=-fforce-recomp` forces the re-splice. Only a content change to that module
does. **Every later plan in this MasterPlan that adds a migration is affected**: EP-4
(service accounts), EP-7 (TOTP secrets and recovery codes), and EP-9 (`shomei_role_permissions`,
`expires_at`). Each must append a line to that module's comment block, as EP-1 did. The symptom
otherwise is an integration suite failing with `relation "shomei.<new_table>" does not exist`.

**2026-07-09 (EP-1) — `Shomei.Workflow.signup` publishes no events through `AuthEventPublisher`.**
Its `UserRegistered`/`SessionStarted` events are written inside `persistNewSession`'s transaction,
so `signup` carries no `AuthEventPublisher :> es` constraint. Any plan that adds an audited step
to `signup` widens its signature and therefore every interpreter chain that runs it — including
the private one in `shomei-server/app/Shomei/Admin/Users.hs`. EP-1 hit this adding default-role
grants; **EP-7** should expect the same when it touches signup-adjacent workflows.

**2026-07-09 (EP-1) — two round-trip budget guards pin the exact database cost of login and
refresh.** `shomei-postgres/test/Main.hs`'s `testLoginRoundTripBudget` and
`testRefreshRoundTripBudget` count `Database` operations and assert an exact number (now 8 and
4, raised from 7 and 3 by the one `listRolesForUser` read that `buildEnrichedClaims` performs
per mint). **EP-5, EP-6, and EP-9 all add work to token-minting paths and will trip these
tests.** That is intended: raise the constant only after finding and justifying the new
round-trip, and update the haddock that enumerates them.

**2026-07-09 (EP-1) — `Shomei.Workflow.Session.buildEnrichedClaims` is the claims-construction
integration point, and it exists now.** Its signature is
`(RoleStore :> es, ClaimsEnricher :> es) => ShomeiConfig -> UserId -> SessionId -> UTCTime -> Eff es AuthClaims`.
Per this MasterPlan's Integration Points, **EP-5** (ID token, userinfo) and **EP-6** (exchanged
tokens) must build their claims through it rather than re-reading stores in the HTTP layer.
`Shomei.Effect.InMemory.runInMemoryWith` supplies a `ClaimsEnricher` hook for tests that need
to observe a host delta.

**2026-07-09 (EP-1) — adding a Servant combinator costs three instances and three GHC papercuts.**
A new combinator needs `HasServer` (shomei-servant), `HasOpenApi` (shomei-servant — and it must
register the security scheme, not pass through, or the route is documented as unauthenticated),
and `HasClient` (shomei-client, or `genericClient` stops deriving `ShomeiClient` entirely). All
three need `UndecidableInstances`. Two name collisions bite because `Shomei.Prelude` re-exports
`Control.Lens`: its `Context` shadows servant's (use `import Shomei.Prelude hiding (Context)`),
and its `:>` *pattern synonym* shadows the type operator in an instance head (use an explicit
`import Servant.API (type (:>))`). **EP-3, EP-4, EP-5, EP-7, and EP-9 all add route surface**;
EP-9's `RequirePermission` follows this exact pattern.

**2026-07-09 (EP-1) — `RequireRole` replaces `Authenticated`; it does not accompany it.** The
`HasServer` instance runs the context-registered `AuthHandler` itself (a combinator cannot
observe a value another combinator captured), so a route writes `RequireRole "admin" :> sub`
*instead of* `Authenticated :> sub` and its handler still receives the `AuthUser`. Writing both
authenticates twice and gives the handler two `AuthUser` arguments. EP-2's admin routes and
EP-9's `RequirePermission` must follow the same rule. Composite conditions a single symbol
cannot express (EP-2's "role `admin` OR scope `shomei:admin`") still use the exported
`requireRole` / `requireScope` handler guards.

**2026-07-09 (EP-1) — `ShomeiConfig`'s `FromJSON` is not the config-file decoder.** The Dhall
file is rendered to JSON and decoded into a *separate* flat, all-optional `FileConfig`
(`shomei-server/src/Shomei/Server/Config.hs`), then merged onto `defaultShomeiConfig`. Adding a
field to `ShomeiConfig` therefore cannot break an existing deployment's config file. **EP-4**
(service-account config migration) and **EP-8** (SMTP/webhook notifier config) can add
`ShomeiConfig` fields freely; they only need a matching optional `FileConfig` field and env
override.

**2026-07-09 (EP-1) — `shomei-admin` has its OWN config loader, and it is partial.**
`Shomei.Admin.Env.loadAdminEnv` does not call `loadConfigFromEnv`; it builds a `ShomeiConfig` from
`defaultShomeiConfig` plus a few `SHOMEI_*` reads. EP-1 shipped `defaultRoles` and every unit test
passed while `shomei-admin users create` silently ignored it — caught only by the live transcript.
**Any plan adding a `ShomeiConfig` field that a `shomei-admin` subcommand depends on must add it
to `loadAdminEnv` too, and must supply whatever validation the server performs at boot** (the CLI
has no boot). **EP-4** (service accounts, `service-accounts create/rotate/revoke`), **EP-8**
(notifier config), and **EP-9** (grant-expiry flags) are all exposed to this. Driving the same
workflow does not mean loading the same configuration; an end-to-end run is what closes the gap.

**2026-07-09 (EP-3) — a route's path is written down in four places, and three of them fail
silently.** Moving the application routes under `/v1` compiled clean and left the whole suite
green while it had *disarmed the rate limiter*: `Shomei.Server.Middleware.RateLimit.throttledPath`
matches `pathInfo` against a literal `["auth","login"]` list, answers before Servant routes
anything, and so cannot be derived from the route type. Every login and signup went unthrottled.
Two siblings in the same class: the refresh cookie's `Path` attribute (`Shomei.Servant.Cookie` —
wrong path means the browser never sends the cookie, breaking cookie-mode refresh while every
bearer-mode test passes) and the metrics middleware's per-route counter table
(`Shomei.Server.Observability.Metrics` — wrong path means `shomei_logins_succeeded_total`
flatlines at zero). `Shomei.Notify`'s emailed confirmation links are a fourth, visible only to a
real recipient.

**Every later plan that adds or moves a route is affected**: EP-2 (admin routes), EP-4
(`/oauth/token` — unversioned, and a *new* candidate for throttling), EP-5 (OIDC endpoints), EP-6,
EP-7 (`/v1/auth/mfa/*`). Before declaring a route change done, run
`grep -rn '"/auth\|"/v1\|\["auth"' --include='*.hs'` and check the WAI layer, the cookie scope, and
the metrics table. EP-3 added `testThrottledPathsAreVersioned` to pin the limiter's list; a plan
that adds a throttled endpoint must extend both the list and that test.

**2026-07-09 (EP-3) — `operationId`s survived the `/v1` move, deliberately.**
`Shomei.Servant.OpenApi.camel` drops a leading `v1` segment, so `GET /v1/auth/me` is still
`getAuthMe`. Generated clients keep their method names across this migration and across a future
`/v2`. **EP-4 and EP-5 add unversioned `/oauth/*` and `/.well-known/*` routes**, which fall
through that rule untouched — no action needed, but do not "fix" the drop by removing it.

**2026-07-09 (EP-1) — `shomei-server-test`'s `SupervisorSpec` is flaky under `cabal test all`.**
Two timing-based tests ("a crashing cycle is retried", "backoff resets after a clean cycle")
intermittently fail when suites run concurrently. Verified pre-existing at commit `9b46c5b`, and
they pass 8/8 in isolation. Do not mistake this for your plan's breakage; run the suite alone to
confirm.


## Decision Log

- Decision: Three phases (foundations → standards surface → factors/delivery) rather than a
  flat eight-plan list.
  Rationale: Eight plans exceed the decomposition guideline; the phases match both the
  dependency structure (roles before admin API; token endpoint before OIDC) and the
  breaking-change window (`/v1` before new routes exist).
  Date: 2026-07-07

- Decision: `/oauth/*` and `/.well-known/*` endpoints are unversioned; application routes move
  under `/v1`.
  Rationale: OAuth2/OIDC tooling expects well-known paths at conventional locations; versioning
  them breaks the auto-configuration that is the whole point of EP-5.
  Date: 2026-07-07

- Decision: Split client_credentials (EP-4) from the OIDC browser flows (EP-5).
  Rationale: Service-to-service auth is the highest-value gap for the distributed-microservice
  mission and carries none of the authorization-code/PKCE/consent complexity; it must be
  shippable alone.
  Date: 2026-07-07

- Decision: TOTP and recovery codes are in scope; SMS and email OTP are permanently out.
  Rationale: Recovery codes fix an existing product hole (passkey-only second factor with no
  fallback locks users out). SMS/email OTP are weak factors requiring delivery infrastructure;
  Shōmei's existing masterplans already deferred them, and the Zitadel comparison did not
  change that judgment.
  Date: 2026-07-07

- Decision: Multi-tenancy, SAML, LDAP, SCIM, hosted UI/branding, JS action hooks, and device
  grant are explicitly excluded from this wave.
  Rationale: The Zitadel gap analysis rated them either inappropriate for Shōmei's headless
  single-tenant identity (multi-tenancy would touch every table and route; UI would erase the
  differentiator) or premature (SCIM before an admin API is incoherent — revisit after EP-2).
  The webhook notifier (EP-8) plus `extraClaims` covers the legitimate fraction of the
  actions/eventing use cases.
  Date: 2026-07-07

- Decision: Keep the bespoke `/auth/service-token` and `/auth/impersonate` endpoints working
  through a deprecation window after EP-4/EP-6 land.
  Rationale: Both are documented, shipped surface; the standards-based replacements must prove
  themselves before removal. Removal is a candidate for the `/v1` major-version boundary and is
  recorded in EP-4/EP-6.
  Date: 2026-07-07

- Decision: Shomei ships a two-tier authorization story — the built-in RBAC tier stays and
  grows (EP-1 folded in a role registry and default signup roles; new EP-9 adds
  role→permission definitions and time-bound grants), while **en**
  (`/Users/shinzui/Keikaku/bokuno/en`, the author's Zanzibar-style ReBAC toolkit) is the
  documented recommendation for robust fine-grained authorization (new EP-10 provides the
  integration examples and guide). The built-in tier is never removed in favor of en.
  Rationale: (a) developers who do not want a second system must still get complete, safe
  RBAC from shomei alone — permission indirection exists precisely so non-en adopters do not
  hard-code role names across services; (b) shomei must gate its own `/admin` endpoints with
  zero external infrastructure; (c) a code-level integration analysis found en-server itself
  has no caller authentication yet (en's `docs/plans/33-…` names shomei-JWT verification as
  the intended mechanism), so shomei's flat JWT roles are what cut the auth↔authz bootstrap
  circularity; (d) the graduation boundary is explicit: resource-scoped permissions,
  relationship-derived access, live revocation, and caveats belong to en, and shomei will not
  grow them.
  Date: 2026-07-07

- Decision: The canonical en subject mapping is `user:<TypeID text>` (`idText` of the JWT
  `sub`), pinned in EP-10's guide and example code.
  Rationale: en's `ObjectRef` ids are compared as plain text; shomei renders identifiers both
  as TypeID text (JWT, API) and bare UUID (audit columns), and a mixed convention makes en
  checks silently deny. The JWT `sub` form is what every downstream verifier actually holds.
  Date: 2026-07-07


## Outcomes & Retrospective

(To be filled during and after implementation.)

---

Revision note (2026-07-07): Added EP-9 (`docs/plans/46-role-definitions-permissions-and-time-bound-grants.md`)
and EP-10 (`docs/plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md`)
after an RBAC gap assessment and a code-level shomei×en integration analysis. EP-1's scope was
extended in place (role registry/validation, default signup roles, en-boundary documentation).
Reason: the user directed a two-tier authorization posture — self-contained built-in RBAC for
deployments that do not adopt en, with en as the documented recommendation for robust
authorization — captured in the Decision Log together with the pinned subject-mapping
convention. Registry, Dependency Graph, Integration Points, Progress, and phases updated
accordingly (Phase 1 gains EP-9; EP-10 floats).
