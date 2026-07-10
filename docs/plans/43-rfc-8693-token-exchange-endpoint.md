---
id: 43
slug: rfc-8693-token-exchange-endpoint
title: "RFC 8693 Token Exchange Endpoint"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# RFC 8693 Token Exchange Endpoint

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei (this repository, a Haskell authentication toolkit) already knows how to mint a
*delegated* token — a JWT whose `sub` claim names one user while an `act` claim names the
party actually wielding it. That capability is currently reachable only through the
bespoke endpoint `POST /auth/impersonate`, which serves exactly one story: a human support
operator acting as a customer. Two things are missing. First, there is no *standard*
surface — RFC 8693 (OAuth 2.0 Token Exchange) defines a `grant_type` that stock OAuth
tooling understands, and Shōmei does not speak it. Second, there is no
*service on-behalf-of* mode at all: when service A receives a user's request and calls
service B, today it can only forward the user's own token (over-broad, and it expires
under long jobs) or use its own service token (losing the user identity entirely).

After this plan, `POST /oauth/token` (created by plan 41,
`docs/plans/41-database-backed-service-accounts-with-oauth2-client-credentials-grant.md`)
accepts `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` with two modes:

1. *User impersonation* — an authenticated operator holding the `impersonate:user` scope
   exchanges for a short-lived, refresh-less token whose `sub` is the target user and
   `act` is the operator. Same freshness gate, same audit events, same
   credential-endpoint blocking as today: only the wire shape is new, and the existing
   `/auth/impersonate` keeps working through a deprecation window.
2. *Service on-behalf-of* — a service account (plan 41) authenticates with its client
   credentials and presents a user's valid access token as the subject token; it receives
   a narrowed, short-lived token carrying the user's `sub` and the service's identity in
   `act`, so user identity propagates across service hops verifiably.

The observable outcome is two curl transcripts against the standard endpoint, plus
refusals for every guard (missing scope, stale operator token, scope-narrowing
violations), plus downstream verification: a resource server reads `sub` and `act` out of
the exchanged token with the ordinary JWKS verification it already does.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-10): `Shomei.Workflow.Impersonation` refactored: shared `mintDelegatedToken` core; `startImpersonation` behavior byte-identical (existing `ImpersonationSpec` untouched and green).
- [x] M1 (2026-07-10): `Shomei.Workflow.TokenExchange` with `exchangeToken` covering both modes; new errors (`OAuthGrantInvalid`, `OAuthRequestMalformed`); `ServiceOnBehalfIssued` audit event (+ `EventCodec` + `EventCodecSpec` round-trip, count 34→35).
- [x] M1 (2026-07-10): Core unit tests (`TokenExchangeSpec`, 16 cases): both happy paths, scope gate, freshness gate, narrowing violations, subject-scope bound, chain refusal, inactive users, refresh-less sessions, gate scope never granted, `requested_token_type` rejection. `cabal test shomei-core` green (211 tests).
- [ ] M2: Token-endpoint dispatcher arm for the exchange grant; RFC 8693 request parsing and response shape; in-process HTTP tests.
- [ ] M2: OpenAPI response schema extended (`issued_token_type`); spec regenerated (no new path).
- [ ] M3: `/auth/impersonate` re-expressed over the shared core (thin endpoint, unchanged wire behavior) + deprecation notes in docs.
- [ ] M3: Introspection consistency check (when plan 42 is present): exchanged tokens introspect with `act`.
- [ ] M4: Docs: `docs/user/service-tokens.md` on-behalf-of section; `docs/user/security.md` impersonation section updated; `examples/microservice-auth-stack` doc note (and optional act-claim read).
- [ ] M4: E2E transcripts automated in `shomei-server` tests.
- [ ] Final: `nix fmt`, `cabal build all`, `cabal test all` green; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Impersonation mode maps RFC 8693 parameters as: `subject_token` = the target
  user's id text with `subject_token_type = urn:shomei:params:oauth:token-type:user-id`
  (a Shōmei-defined URN), and `actor_token` = the operator's own access token with
  `actor_token_type = urn:ietf:params:oauth:token-type:access_token`.
  Rationale: RFC 8693 defines the subject token as "a representation of the party the
  resulting token will represent", but a support operator does not *hold* any token of
  the customer's — the customer's identity is known only by id. Defining a provider URN
  for "a bare user id" is the established escape hatch (for background: Zitadel does
  exactly this with `urn:zitadel:params:oauth:token-type:user_id` in
  `/Users/shinzui/Keikaku/hub/zitadel/internal/api/oidc/token_exchange.go`, studied as
  protocol shape only — no code reuse). The operator's credential travels as the actor
  token, matching the RFC's delegation semantics.
  Date: 2026-07-07

- Decision: On-behalf-of mode: the *service authenticates as the OAuth client* of the
  exchange request (client_secret_basic/post per plan 41), the `subject_token` is the
  user's access token (`urn:ietf:params:oauth:token-type:access_token`), and no
  `actor_token` parameter is used — the authenticated client *is* the actor.
  Rationale: RFC 8693 §2.1 explicitly allows client authentication to establish the
  requesting party; requiring the service to also mint itself an access token first, only
  to pass it as `actor_token`, would add a round trip with no security gain. The issued
  token's `act` carries the service account's backing user id.
  Date: 2026-07-07

- Decision: A service account must hold the dedicated scope `token-exchange:subject` in
  its `allowed_scopes` to use on-behalf-of mode at all; that scope itself is never copied
  into an issued token.
  Rationale: On-behalf-of is a powerful capability (any user token the service sees can
  be re-minted with the service as actor); making it opt-in per account means a
  compromised ordinary service account cannot start impersonating its callers. The scope
  is a gate, not a grant to carry — copying it would let exchanged tokens perform further
  exchanges, an escalation chain we do not want.
  Date: 2026-07-07

- Decision: Scope narrowing for on-behalf-of: the granted scope set is
  `requested ∩ service.allowedScopes` (with `requested` defaulting to
  `service.allowedScopes` minus `token-exchange:subject` when the `scope` parameter is
  absent); additionally, when the subject token carries a *non-empty* scope set, the
  result must also be within it (`granted ⊆ subject.scopes`, else `invalid_scope`). An
  empty subject scope set imposes no bound.
  Rationale: The service ceiling is non-negotiable — a service can never confer scopes it
  does not hold. The subject bound implements the intuitive "the service acts with no
  more authority than the user had" rule, but today's Shōmei user tokens carry *empty*
  scopes by design (`buildClaims` mints empty sets until plan 38 lands), where empty
  means "unscoped interactive session", not "no authority" — treating it as a bound would
  make on-behalf-of unusable. Once plan 38 populates user scopes, the subject bound
  engages automatically. This asymmetry is deliberate and documented.
  Date: 2026-07-07

- Decision: TTLs: impersonation mode uses the existing
  `impersonationConfig.impersonationSessionTTL` (default 30 minutes); on-behalf-of mode
  uses `serviceTokenConfig.ttl` (default 5 minutes). Both sessions are refresh-less. No
  new config fields.
  Rationale: Each mode inherits the lifetime policy of the machinery it generalizes —
  operators already tuned these values for the same risk profiles, and refusing refresh
  tokens preserves the "cannot be silently renewed" property both existing flows
  guarantee.
  Date: 2026-07-07

- Decision: The exchange grant accepts optional extension parameters `reason` and
  `ticket_id` for impersonation mode; when `reason` is absent it defaults to the string
  `token_exchange`.
  Rationale: RFC 8693 permits additional parameters. The existing bespoke endpoint
  *requires* `reason` and audits it; forcing it on standards-based callers would break
  stock clients, but dropping it entirely would degrade the audit trail. A default keeps
  `impersonation_started` events well-formed either way, and hosts that care can send it.
  Date: 2026-07-07

- Decision: `/auth/impersonate` (and `DELETE /auth/impersonate`) keep working unchanged
  through a deprecation window; both endpoints and the exchange grant share one workflow
  core (`mintDelegatedToken`), so behavior cannot drift. Removal is a candidate for the
  `/v1` major-version boundary.
  Rationale: MasterPlan Decision Log — shipped, documented surface must not break; and a
  shared core is the only way to guarantee the standard path enforces exactly the same
  freshness/scope/audit policy as the bespoke one.
  Date: 2026-07-07

- Decision: Exchanged tokens can be *revoked* but not *refreshed*: `stopImpersonation`
  (via `DELETE /auth/impersonate`) and plan 42's `/oauth/revoke` both work on them
  (session revocation), and `requested_token_type` values other than
  `urn:ietf:params:oauth:token-type:access_token` are rejected with
  `invalid_request` (we issue access tokens only — no refresh tokens, no ID tokens from
  the exchange).
  Rationale: Matches the refresh-less design of both underlying flows; issuing refresh
  tokens from an exchange would undo the short-lifetime guarantee that makes delegation
  auditable and bounded.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### M1 (2026-07-10)

`mintDelegatedToken` extracted; `startImpersonation` now calls it and `ImpersonationSpec` passes
unmodified (the refactor-safety gate). `Shomei.Workflow.TokenExchange.exchangeToken` covers both
modes; impersonation mode reuses `startImpersonation` verbatim so scope/freshness/self/active
guards and the `impersonation_started` event are literally shared code. `TokenExchangeSpec`
(16 cases) is green; `cabal test shomei-core` = 211 tests, PASS.

Error-constructor decisions worth recording:

- Following the EP-4 established pattern (`Shomei.Servant.Error` header note), the two new
  `AuthError` constructors `OAuthGrantInvalid`\/`OAuthRequestMalformed` are total-mapped in
  `authErrorToServerError` to existing catalog specs (`pcBadRequest`), never to new codes — no
  route emits them through the envelope, so no `problemCatalog`\/`routeErrors` entry is needed.
- An inactive\/absent __subject__ user and an inactive __service backing__ user both map to
  `OAuthGrantInvalid` (→ `invalid_grant`, 400), not `invalid_client`: the service's secret already
  verified, so this is not a client-authentication failure; the exchange simply cannot mint. This is
  a deliberate narrowing of the plan's under-specified "require the service's backing user active".


## Context and Orientation

The repository is a multi-package Haskell Cabal project at
`/Users/shinzui/Keikaku/bokuno/shomei` (GHC 9.12.4; work inside `nix develop`; build with
`cabal build all`; test with `cabal test all`; dev database via `just create-database`;
format with `nix fmt`). `shomei-core` holds domain types, workflows, and `effectful`
effect ports with in-memory test interpreters (`shomei-core/src/Shomei/Effect/InMemory.hs`);
`shomei-postgres` holds hasql interpreters; `shomei-servant` holds the HTTP layer
(`ShomeiAPI` NamedRoutes record, handlers, DTOs, OpenAPI); `shomei-server` is the Warp
server and `shomei-admin` CLI.

Hard dependency — plan 41's deliverables, which must exist before starting:
`POST /oauth/token` (route field `oauthToken`, form-encoded body as a raw
`Web.FormUrlEncoded.Form`), the `grant_type` dispatcher in
`shomei-servant/src/Shomei/Servant/Handlers.hs` (`oauthTokenH`),
`Shomei.Servant.OAuth.{oauthError, extractClientAuth}` (RFC 6749 §5.2 error shape —
distinct from the application envelope; client_secret_basic/post), the
`shomei_service_accounts` table with `ServiceAccountStore` port
(`FindServiceAccountByClientId`, accounts carry `allowedScopes :: Set Scope`,
`secretHash`, a backing `userId`, and a status), and
`Shomei.Workflow.ServiceToken.verifyServiceSecret` (SHA-256 hex + constant-time
compare). Soft dependency — plan 42: if it has landed, its `/oauth/introspect` must
report exchanged tokens with an `act` member; if it has not, that check is deferred (note
it in Progress).

The existing impersonation machinery this plan generalizes (verified in the working
tree):

`shomei-core/src/Shomei/Workflow/Impersonation.hs` exports
`StartImpersonation { actorClaims :: AuthClaims, targetUserId :: UserId, reason :: Text,
ticketId :: Maybe Text, clientIp :: Maybe Text }`, and

```haskell
startImpersonation ::
  ( UserStore :> es, SessionStore :> es, TokenSigner :> es,
    AuthEventPublisher :> es, Clock :> es ) =>
  ShomeiConfig -> StartImpersonation -> Eff es (Either AuthError (Session, AccessToken))
```

Its guards, in order: the caller's claims must contain
`impersonationConfig.impersonateScope` (default `Scope "impersonate:user"`), else
`ImpersonationForbidden`; the caller's token must be fresh —
`when (ts > addUTCTime imp.actorFreshnessWindow caller.issuedAt) (throwError ImpersonationForbidden)`
(default window 5 minutes); the target must not be the caller and must exist and be
`UserActive` (`ImpersonationTargetInvalid`). It then creates a *dedicated, refresh-less*
session (`NewSession` with `expiresAt = addUTCTime imp.impersonationSessionTTL ts` and
`actor = Just caller.subject`), builds claims directly (subject = target,
`actor = Just caller.subject`, empty scopes/roles), signs via the `TokenSigner` effect,
and publishes `Event.ImpersonationStarted` (payload includes both user ids, session id,
reason, ticket id, client IP). `stopImpersonation` requires the presented claims to carry
an actor, revokes the session, and publishes `ImpersonationStopped`.

The HTTP side: `POST /auth/impersonate` and `DELETE /auth/impersonate` in
`shomei-servant/src/Shomei/Servant/API.hs`/`Handlers.hs`. Separately,
`denyUnderImpersonation` in `Handlers.hs` blocks credential-changing endpoints (password
change, passkey register/remove) for *any* token whose claims carry `actor`, publishing
`ImpersonationActionBlocked` — this applies automatically to tokens minted by this plan's
on-behalf-of mode too, which is correct: a service acting for a user must not change the
user's credentials.

Claims: `AuthClaims` (`shomei-core/src/Shomei/Domain/Claims.hs`) carries
`actor :: Maybe UserId`, serialized as the JWT `act` claim by `shomei-jwt`
(`claimsFromAuth` adds `act` only when present). Downstream services verify tokens
offline against `/.well-known/jwks.json` — `examples/microservice-auth-stack`
demonstrates that pattern (`src/Downstream/Service.hs` fetches JWKS into a TTL cache and
verifies with `Shomei.Jwt.Verify.verifyToken`; note its `projectsHandler` currently
*ignores* the decoded claims, so "act-claim reading" is a documentation/example gap this
plan's M4 addresses).

Embedded protocol knowledge — RFC 8693 in brief. Token exchange is a grant type at the
ordinary token endpoint: `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`,
form-encoded. Request parameters: `subject_token` + `subject_token_type` (required — the
identity the issued token will represent), `actor_token` + `actor_token_type` (optional —
the party acting), `scope` (optional, space-delimited), `requested_token_type` (optional),
`audience`/`resource` (optional; this plan rejects `resource` and ignores `audience`,
documenting both). Standard token-type URNs include
`urn:ietf:params:oauth:token-type:access_token`, `...:refresh_token`, `...:id_token`,
`...:jwt`; providers may define their own URNs for non-token subject representations. A
success response is the usual token response plus a required `issued_token_type` member:

```json
{
  "access_token": "<jwt>",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 300
}
```

Errors reuse RFC 6749 §5.2 codes (`invalid_request`, `invalid_client`, `invalid_grant`,
`invalid_scope`); a subject/actor token that fails validation is `invalid_grant`. The
distinction the RFC draws: *impersonation* (no `act` — the subject simply becomes the
token) versus *delegation* (an `act` claim records the acting party). Shōmei issues
delegation-shaped tokens in both modes — the `act` claim is always present on exchanged
tokens, because an audit trail without the acting party would defeat the purpose.

Background study (shape only; Go, different license — never copy):
`/Users/shinzui/Keikaku/hub/zitadel/internal/api/oidc/token_exchange.go` accepts
access/id/jwt/custom-user-id subject tokens, refuses `resource`, gates impersonation
behind an instance-level policy switch, narrows scopes against both subject and actor,
and nests prior `act` claims on chained exchanges. Shōmei's subset deliberately skips
chained-exchange `act` nesting: an exchanged token presented as `subject_token` is
rejected (its claims carry `actor`), preventing delegation chains outright — simpler to
reason about, and revisitable later.


## Plan of Work

Four milestones. Work from the repository root inside `nix develop`.

### Milestone M1 — Shared delegation core and the exchange workflow

Scope: refactor the impersonation workflow into a reusable core, then build the
token-exchange workflow with both modes on top of it. At the end, core unit tests cover
both modes and every refusal; the existing impersonation spec passes untouched
(byte-identical behavior).

Refactor `shomei-core/src/Shomei/Workflow/Impersonation.hs`. Extract the tail of
`startImpersonation` (create refresh-less session with `actor`, build claims, sign) into:

```haskell
data DelegatedMint = DelegatedMint
  { subjectUserId :: !UserId,     -- the token's sub
    actorUserId :: !UserId,       -- the token's act
    scopes :: !(Set Scope),       -- empty for impersonation; narrowed set for on-behalf-of
    ttl :: !NominalDiffTime
  }

mintDelegatedToken ::
  ( SessionStore :> es, TokenSigner :> es, Clock :> es ) =>
  ShomeiConfig -> UTCTime -> DelegatedMint -> Eff es (Session, AccessToken)
```

`startImpersonation` becomes: its existing guards (scope, freshness, self-target, target
active) → `mintDelegatedToken` with empty scopes and the impersonation TTL → publish
`ImpersonationStarted` exactly as today. Prove the refactor is pure by running
`cabal test shomei-core` with `Workflow/ImpersonationSpec.hs` unmodified.

Create `shomei-core/src/Shomei/Workflow/TokenExchange.hs`:

```haskell
data ExchangeRequest = ExchangeRequest
  { subjectToken :: !Text,
    subjectTokenType :: !Text,
    actorToken :: !(Maybe Text),
    actorTokenType :: !(Maybe Text),
    requestedScopes :: !(Maybe (Set Scope)),
    requestedTokenType :: !(Maybe Text),
    reason :: !(Maybe Text),
    ticketId :: !(Maybe Text),
    clientIp :: !(Maybe Text),
    -- Nothing = caller did not client-authenticate (impersonation mode);
    -- Just = plan-41 client authentication already succeeded (on-behalf-of mode).
    authenticatedService :: !(Maybe ServiceAccount)
  }

data ExchangedToken = ExchangedToken
  { accessToken :: !AccessToken,
    expiresIn :: !NominalDiffTime,
    grantedScopes :: !(Set Scope),
    sessionId :: !SessionId
  }

exchangeToken ::
  ( UserStore :> es, SessionStore :> es, TokenSigner :> es, TokenVerifier :> es,
    AuthEventPublisher :> es, Clock :> es ) =>
  ShomeiConfig -> ExchangeRequest -> Eff es (Either AuthError ExchangedToken)
```

(`TokenVerifier` is the existing effect the auth handler uses to turn a compact JWT back
into `AuthClaims`; verify it is exported for workflow use — it is in the `AppEffects`
stack already.)

Mode selection: reject `requestedTokenType` other than absent or
`urn:ietf:params:oauth:token-type:access_token` (`OAuthRequestMalformed`). Then:

*Impersonation mode* — `subjectTokenType == "urn:shomei:params:oauth:token-type:user-id"`
and `authenticatedService == Nothing`. Require `actorToken` with
`actorTokenType == "urn:ietf:params:oauth:token-type:access_token"`; verify it via
`TokenVerifier` (failure → `OAuthGrantInvalid`, a new error); reject actor claims that
themselves carry `actor` (no chains); parse `subjectToken` with `parseId` into the target
`UserId`; then delegate to the *same* guard-plus-mint path as `startImpersonation` —
implement by calling `startImpersonation` with
`StartImpersonation { actorClaims, targetUserId, reason = fromMaybe "token_exchange" reason, ticketId, clientIp }`
so the scope gate, freshness gate, self/active checks, session shape, and the
`ImpersonationStarted` audit event are literally shared code.

*On-behalf-of mode* — `subjectTokenType == "urn:ietf:params:oauth:token-type:access_token"`
and `authenticatedService == Just svc`. Require the account active and
`Scope "token-exchange:subject"` ∈ `svc.allowedScopes` (else `OAuthClientInvalid` /
`OAuthScopeInvalid` respectively — a service without the gate scope must not learn
anything else). Verify `subjectToken` (failure → `OAuthGrantInvalid`); reject subject
claims carrying `actor` (no chains); require the subject user `UserActive`; compute
granted scopes per the Decision Log narrowing rule (requested defaulting to
`svc.allowedScopes \\ {token-exchange:subject}`; ceiling `svc.allowedScopes` minus the
gate scope; subject bound only when subject scopes non-empty; empty result →
`OAuthScopeInvalid`); require the service's backing user active; then
`mintDelegatedToken cfg ts DelegatedMint { subjectUserId = subject.subject, actorUserId = svc.userId, scopes = granted, ttl = cfg.serviceTokenConfig.ttl }`;
publish a new audit event `ServiceOnBehalfIssued` with payload
`{ serviceAccountId :: Text, actorUserId :: UserId, subjectUserId :: UserId, sessionId :: SessionId, scopes :: Set Scope, occurredAt :: UTCTime }`
(event type `service_on_behalf_issued` in `Shomei.Domain.Event` + `EventCodec` + the
round-trip spec).

Any other subject/actor type combination → `OAuthRequestMalformed` naming the parameter.
Add the new `AuthError` constructors (`OAuthGrantInvalid`, reusing plan 41's
`OAuthClientInvalid`/`OAuthScopeInvalid`/`OAuthRequestMalformed`) and their (unused at
`/oauth/*`, but total) mappings in `Shomei.Servant.Error`.

Unit tests, `shomei-core/test/Shomei/Workflow/TokenExchangeSpec.hs` (in-memory world,
deterministic clock): impersonation happy path (token has target sub + operator act,
session refresh-less, `ImpersonationStarted` published, default reason
`token_exchange`); operator without `impersonate:user` → forbidden; operator token older
than the freshness window → forbidden; self-target → invalid; on-behalf-of happy path
(sub = user, act = service's user, scopes = narrowing result, TTL = service-token TTL,
`ServiceOnBehalfIssued` published); service lacking `token-exchange:subject` → scope
error; requested scope outside service ceiling → scope error; subject with non-empty
scopes bounding the result; exchanged token re-presented as subject → refused (chain
prevention); inactive subject user → refused; no refresh token in either mode; gate
scope never appears in granted scopes.

Acceptance for M1: `cabal test shomei-core` green, including the *unmodified*
`ImpersonationSpec`.

### Milestone M2 — The grant over HTTP

Scope: wire the grant into plan 41's dispatcher and produce the RFC 8693 response. At the
end, in-process HTTP tests drive both modes end to end.

In `oauthTokenH` (`shomei-servant/src/Shomei/Servant/Handlers.hs`), add the arm
`"urn:ietf:params:oauth:grant-type:token-exchange"`. Parse the RFC parameters from the
`Form` (`subject_token`, `subject_token_type`, `actor_token`, `actor_token_type`,
`scope`, `requested_token_type`, plus extensions `reason`, `ticket_id`); reject a
`resource` parameter with `invalid_request` ("resource parameter not supported"). Attempt
client authentication with plan 41's `extractClientAuth`: if credentials are present they
must resolve to an active service account (via `ServiceAccountStore` +
`verifyServiceSecret`; failure → 401 `invalid_client`), yielding
`authenticatedService = Just svc`; if absent, `Nothing` (impersonation mode
authenticates through the actor token instead). Take the client IP from the connection
the same way `POST /auth/impersonate` does (its route uses servant's `RemoteHost`; mirror
that). Run `exchangeToken`; map errors to `oauthError` (`OAuthGrantInvalid` →
`invalid_grant`; scope errors → `invalid_scope`; malformed → `invalid_request`; client →
401 `invalid_client`; the impersonation guards surface as `ImpersonationForbidden`/
`ImpersonationTargetInvalid` from the shared workflow — map both to 400
`invalid_grant` with a generic description, since RFC callers know nothing of
impersonation policy internals).

Response: extend plan 41's `TokenResponse` with `issuedTokenType :: Maybe Text` (JSON key
`issued_token_type`, emitted only when `Just` — the exchange arm sets it to
`urn:ietf:params:oauth:token-type:access_token`; other grants leave it `Nothing`).
Update the hand-written `ToJSON`/`ToSchema`/`Arbitrary` for the field. No new route, so
the OpenAPI path count is unchanged; regenerate the spec for the schema change.

HTTP tests in `shomei-servant/test/Main.hs`: impersonation exchange happy path (mint an
operator token carrying `impersonate:user` with the test signer, POST the form, assert
200 with all four response members, decode the access token, assert sub/act; then call
`GET /auth/me` with it and see the target user; then attempt `POST /auth/password/change`
and see 403 `impersonation_action_blocked` — proving the standard path inherits the
gating); on-behalf-of happy path (seed service account with
`["kawa:ingest","token-exchange:subject"]`, login a user, exchange with
`scope=kawa:ingest`, assert the token passes a `requireScope (Scope "kawa:ingest")`
route and carries the user's sub + service's act); no client auth and no actor token →
400; service without the gate scope → `invalid_scope`; requesting
`token-exchange:subject` itself → never granted; stale operator token (advance clock) →
`invalid_grant`; `requested_token_type=...:refresh_token` → `invalid_request`.

Acceptance for M2: `cabal test shomei-servant` green (HTTP + OpenAPI conformance suites).

### Milestone M3 — Deprecation alignment and introspection consistency

Scope: make the bespoke endpoint a thin skin over the shared core, and verify the
standard observability surface agrees.

`POST /auth/impersonate`'s handler already calls `startImpersonation`; after M1's
refactor it therefore already shares the core — verify no behavior drift by running the
existing servant impersonation scenario unchanged. Mark the endpoint deprecated in
`docs/user/api.md` and `docs/user/security.md` (kept working; removal candidate at the
`/v1` boundary; the replacement is the token-exchange grant — show the equivalent curl
side by side). `DELETE /auth/impersonate` remains the stop mechanism for both paths,
since exchanged impersonation tokens are ordinary delegated sessions; state this in the
docs.

If plan 42 has landed: add a test that `/oauth/introspect` on an exchanged token returns
`active:true` with an `act` member (`{"sub": "<actor user id>"}`), and `active:false`
after `DELETE /auth/impersonate` under that token. If plan 42 has not landed, tick the
Progress item as deferred with a note.

Acceptance for M3: `cabal test shomei-servant shomei-server` green; docs updated.

### Milestone M4 — Docs, example, end-to-end proof

Scope: teach consumers, and automate the transcripts.

Docs. `docs/user/service-tokens.md` gains an "Acting on behalf of a user" section: when
to use on-behalf-of versus plain client credentials, the `token-exchange:subject` gate
scope, the narrowing rule (including the empty-subject-scope caveat verbatim from the
Decision Log), a full curl example, and the downstream contract (verify JWT via JWKS,
read `sub` for the user, `act` for the service, and remember `denyUnderImpersonation`
semantics apply inside Shōmei itself). `docs/user/security.md`'s impersonation section
gains the standard-grant equivalent and the deprecation note.
`examples/microservice-auth-stack`: at minimum extend its README/`docs` text to show
reading `act` out of the verified `AuthClaims` in `src/Downstream/Service.hs`
(`claims.actor`); if quick, change `projectsHandler` to include the actor in its response
so the example *demonstrates* act-claim reading rather than ignoring claims — record
which you did.

E2E. Extend `shomei-server/test/Shomei/Server/E2ESpec.hs`: real Postgres + Warp; seed a
service account (with the gate scope) and two users; login user A; exchange on-behalf-of;
verify the returned JWT against the served JWKS and assert `sub`/`act`/`scopes`; then the
impersonation mode with an operator token (the E2E can sign a scoped operator token
directly, as the existing impersonation E2E-style tests do, since scope granting is
host-side until plan 38); assert audit rows `service_on_behalf_issued` and
`impersonation_started` exist with both ids.

Acceptance for M4: `cabal test all` green; the Validation transcripts reproduce manually.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. Confirm
the dependency and baseline first:

```bash
grep -n "client_credentials" shomei-servant/src/Shomei/Servant/Handlers.hs
cabal test shomei-core shomei-servant
```

Expected: the plan-41 dispatcher arm exists; baseline suites pass.

M1:

```bash
cabal test shomei-core
```

Expected tail:

```text
All ... tests passed
```

with `ImpersonationSpec` unchanged and `TokenExchangeSpec` present. M2:

```bash
cabal test shomei-servant
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json   # schema-only change: issued_token_type
```

M3:

```bash
cabal test shomei-servant shomei-server
```

M4 and final:

```bash
nix fmt
cabal build all
cabal test all
```

No new migration and no new route are involved in this plan; `just create-database` needs
re-running only if plans 41/42 landed since your database was created.


## Validation and Acceptance

Two manual transcripts against a locally running server (plan 41's setup; a service
account created with
`shomei-admin service-accounts create --display-name svc-b --scope kawa:ingest --scope token-exchange:subject`).

On-behalf-of: with a user logged in (access token `$USER_AT`):

```bash
curl -si -u "$CLIENT_ID:$CLIENT_SECRET" \
  --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$USER_AT" \
  --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

Expected:

```text
HTTP/1.1 200 OK
Cache-Control: no-store

{"access_token":"<jwt>","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

Decoding the JWT shows `sub` = the user's id, `act` = the service's backing user id,
`scopes` = `["kawa:ingest"]`, and it verifies against `/.well-known/jwks.json`. The same
call *without* `token-exchange:subject` on the account returns 400
`{"error":"invalid_scope",...}`; with `scope=admin:everything` it returns
`invalid_scope`; with a garbage `subject_token` it returns `invalid_grant`.

Impersonation: with an operator token `$OP_AT` carrying `impersonate:user` issued within
the last five minutes (host-granted, e.g. via the embedding service or a test signer):

```bash
curl -si \
  --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=user_01jz..." \
  --data-urlencode 'subject_token_type=urn:shomei:params:oauth:token-type:user-id' \
  --data-urlencode "actor_token=$OP_AT" \
  --data-urlencode 'actor_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'reason=support ticket 4711' \
  http://localhost:8080/oauth/token
```

Expected: 200 with the same response shape; the token's `sub` is the target user,
`act` the operator; `GET /auth/me` under it returns the target;
`POST /auth/password/change` under it returns 403 `impersonation_action_blocked`;
`DELETE /auth/impersonate` under it returns 204 and kills the session. A stale `$OP_AT`
(older than `actorFreshnessWindow`) or one lacking the scope gets 400
`{"error":"invalid_grant",...}`. The audit log (`GET /admin/audit/events` or SQL) shows
`impersonation_started` with reason `support ticket 4711`, and `service_on_behalf_issued`
for the first transcript, each carrying both user ids.

Automated acceptance: `cabal test all` green — specifically the untouched
`ImpersonationSpec` (refactor safety), `TokenExchangeSpec` (both modes plus refusals),
the servant HTTP scenarios (including the `denyUnderImpersonation` inheritance check and
scope-narrowing refusals), the OpenAPI conformance suite, and the E2E transcript. The
old `/auth/impersonate` tests must pass without modification — that is the deprecation
window's regression gate.


## Idempotence and Recovery

The plan is additive except for the M1 refactor of `Workflow/Impersonation.hs`, whose
safety net is the existing spec suite: run `cabal test shomei-core` immediately after
extracting `mintDelegatedToken` and before writing any new code; if anything fails, fix
the refactor before proceeding — never adjust the existing spec to match new behavior.

No migrations, so no database recovery concerns. Re-running all tests and `nix fmt` is
safe. The grant is unreachable unless a caller sends the exchange URN, so deploying
mid-plan is harmless; on-behalf-of additionally requires an account that holds the gate
scope, which no existing account does.

If HTTP tests see 400 where 401 is expected (or vice versa): 401 is reserved for *failed
client authentication* (`invalid_client`); every subject/actor-token problem is 400
`invalid_grant`. If the impersonation-mode tests fail on freshness, check the in-memory
clock advancement — the freshness gate compares against the actor token's `iat`, so the
test must mint the operator token at a controlled time.

Do not modify `denyUnderImpersonation`, refresh rotation, or `stopImpersonation`
semantics. If the shared core appears to need a behavior change to fit both callers,
stop and record the conflict in Surprises & Discoveries — the deprecation guarantee
depends on the bespoke path not drifting.


## Interfaces and Dependencies

Hard dependency (plan 41): `oauthTokenH` dispatcher, `Shomei.Servant.OAuth.{oauthError,
extractClientAuth, TokenResponse}`, `Shomei.Effect.ServiceAccountStore`
(`FindServiceAccountByClientId`), `Shomei.Workflow.ServiceToken.verifyServiceSecret`,
and `serviceTokenConfig.ttl`. Soft dependency (plan 42): introspection `act`
consistency test only.

Project-local interfaces: `Shomei.Workflow.Impersonation` (refactored to expose
`mintDelegatedToken`; `startImpersonation`/`stopImpersonation` signatures unchanged),
`Shomei.Effect.TokenVerifier` (JWT → `AuthClaims` for subject/actor tokens inside the
workflow), `Shomei.Effect.{UserStore, SessionStore, TokenSigner, AuthEventPublisher,
Clock}`, `Shomei.Domain.Claims.AuthClaims` (`actor`, `scopes`, `issuedAt`),
`Shomei.Domain.Event`/`EventCodec` (new `ServiceOnBehalfIssued`; existing
`ImpersonationStarted`/`Stopped`/`ActionBlocked` reused), `Shomei.Config`
(`impersonationConfig.{impersonateScope, actorFreshnessWindow, impersonationSessionTTL}`,
`serviceTokenConfig.ttl` — no new config), and `Shomei.Id.parseId` for the user-id
subject URN.

End-of-milestone signatures: after M1 —
`Shomei.Workflow.Impersonation.mintDelegatedToken` and
`Shomei.Workflow.TokenExchange.exchangeToken` as typed in the Plan of Work; after M2 —
the exchange arm in `oauthTokenH` and `TokenResponse.issuedTokenType`; after M3 — no new
interfaces (deprecation is documentation plus shared-core verification); after M4 — no
new interfaces.

No new third-party dependencies. The Shōmei-defined URN
`urn:shomei:params:oauth:token-type:user-id` is part of the public contract from M2
onward — document it in `docs/user/api.md` and never rename it casually.
