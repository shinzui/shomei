---
id: 7
slug: interop-wave-standards-based-auth-surface
title: "Interop Wave: Standards-Based Auth Surface"
kind: master-plan
created_at: 2026-07-07T17:22:07Z
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

Explicitly out of scope, deliberately and permanently (recorded in the Decision Log):
multi-tenancy (instances/orgs — tenant-per-deployment plus a host-managed `tenant` claim via
`extraClaims` covers Shōmei's cases), SAML and LDAP, SCIM (only coherent after the admin API
exists; revisit later), hosted login UI / console / branding (Shōmei's headless,
host-owns-the-UI stance is its differentiator), JavaScript action sandboxes, device
authorization grant, quotas, and SMS/email OTP factors.


## Decomposition Strategy

Eight work streams exceed the seven-plan guideline, so they are grouped into three phases —
implementation waves that also match dependency structure and risk.

Phase 1 (Foundations) makes the existing surface trustworthy and evolvable before new
protocol surface is added: EP-1 gives roles/scopes a source of truth (the review's
"unsatisfiable admin role" finding makes this the keystone — both the admin API and every
gated route depend on it); EP-2 exposes administration over HTTP; EP-3 establishes `/v1` and
the universal error envelope. EP-3 sits in Phase 1 because it is a breaking-change window:
every route added by later plans must be born under `/v1` with the new envelope, not migrated
afterward.

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
`Notifier` interpreters so verification/reset email leaves the process.

The alternative of one mega-plan "OIDC provider" containing EP-4 through EP-6 was rejected: it
would exceed five milestones, and client_credentials alone delivers most of the
distributed-microservice value with a fraction of the risk. The alternative of putting EP-3
last (version the API once everything exists) was rejected because it guarantees a second
migration for every consumer who adopts the Phase 2 endpoints early.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Persistent Roles and Scopes with a Granting Path and Claims Enrichment | docs/plans/38-persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment.md | None | None | Not Started |
| 2 | Admin HTTP API for User and Session Management | docs/plans/39-admin-http-api-for-user-and-session-management.md | EP-1 | EP-3 | Not Started |
| 3 | API v1 Prefix and Universal Problem-Details Error Envelope | docs/plans/40-api-v1-prefix-and-universal-problem-details-error-envelope.md | None | None | Not Started |
| 4 | Database-Backed Service Accounts with OAuth2 Client-Credentials Grant | docs/plans/41-database-backed-service-accounts-with-oauth2-client-credentials-grant.md | None | EP-3 | Not Started |
| 5 | OIDC Provider Subset: Discovery, Authorization Code with PKCE, Introspection | docs/plans/42-oidc-provider-subset-discovery-authorization-code-with-pkce-introspection.md | EP-4 | EP-1 | Not Started |
| 6 | RFC 8693 Token Exchange Endpoint | docs/plans/43-rfc-8693-token-exchange-endpoint.md | EP-4 | EP-5 | Not Started |
| 7 | TOTP Second Factor and Recovery Codes | docs/plans/44-totp-second-factor-and-recovery-codes.md | None | EP-3 | Not Started |
| 8 | SMTP and Webhook Notifier Interpreters | docs/plans/45-smtp-and-webhook-notifier-interpreters.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Phases: Phase 1 = EP-1, EP-2, EP-3. Phase 2 = EP-4, EP-5, EP-6. Phase 3 = EP-7, EP-8.


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

Parallelism guide: Phase 1 can run EP-1 and EP-3 concurrently, with EP-2 starting once EP-1
lands. Phase 2 can start EP-4 concurrently with Phase 1 (it integrates with, but does not
require, EP-3). EP-7 and EP-8 fit anywhere.


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
and every plan adding routes (EP-2, EP-4, EP-5, EP-7). EP-3 establishes: application routes
live under `/v1`; `/.well-known/*`, `/oauth/*`, `/health`, `/ready`, and `/metrics` remain
unversioned root paths (protocol and infrastructure conventions). Later plans follow that rule
and extend the OpenAPI generation (`shomei-servant/src/Shomei/Servant/OpenApi.hs`) for their
routes, including per-route error documentation in the EP-3 envelope schema.

Error envelope (`shomei-servant/src/Shomei/Servant/Error.hs`): EP-3 owns the universal
envelope helper and the OpenAPI `Error` component; EP-2, EP-5, and EP-7 route every new
failure through it (except the RFC 6749 token-endpoint errors owned by EP-4, above).

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

`shomei-admin` CLI (`shomei-server/app/`): EP-1 adds `roles grant/revoke` (the bootstrap path
for the first admin), EP-4 adds `service-accounts create/rotate/revoke`. Additive subcommands;
no shared code beyond the existing CLI plumbing.


## Progress

- [ ] EP-1: Role/scope grant storage (migration) and port with Postgres + in-memory interpreters
- [ ] EP-1: Claims population at token mint through an enrichment hook; `shomei-admin roles grant`
- [ ] EP-1: `RequireRole`/`RequireScope` enforce via `HasServer` (or are removed from the public surface)
- [ ] EP-2: Admin routes: list/get users, suspend/reinstate/delete, revoke sessions, grant/revoke roles
- [ ] EP-2: Admin surface authorized by role/scope; audited; OpenAPI documented
- [ ] EP-3: `/v1` prefix with unversioned protocol/infra exceptions; redirect-or-410 policy for old paths
- [ ] EP-3: Universal problem-details envelope on every error path (including auth combinator 401s)
- [ ] EP-3: OpenAPI error schema + per-route error responses; status-code fixes (201 signup, idempotent logout)
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


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)
