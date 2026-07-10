---
id: 42
slug: oidc-provider-subset-discovery-authorization-code-with-pkce-introspection
title: "OIDC Provider Subset: Discovery, Authorization Code with PKCE, Introspection"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# OIDC Provider Subset: Discovery, Authorization Code with PKCE, Introspection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei (this repository, a Haskell authentication toolkit) currently exposes a bespoke
HTTP API: every consumer writes Shōmei-specific integration code to log users in and
verify tokens. OpenID Connect (OIDC) is the industry-standard identity layer on top of
OAuth 2.0; a service that publishes an OIDC *discovery document* and implements a small,
well-known set of endpoints can be consumed by stock middleware with zero custom code —
Envoy's JWT filter, oauth2-proxy, Spring Security, ASP.NET Core, and every OIDC client
library auto-configure themselves from a single URL.

After this plan, Shōmei is such a provider — deliberately a *subset* (see Decision Log for
what is excluded and why). A deployment publishes `GET /.well-known/openid-configuration`;
implements the authorization-code grant with PKCE (S256 only, mandatory for public
clients); issues signed ID tokens through the existing key machinery; and serves
`/oauth/userinfo`, `/oauth/introspect` (RFC 7662), and `/oauth/revoke` (RFC 7009). OAuth
clients are registered statically with `shomei-admin oauth-clients` subcommands — there is
no dynamic registration and no consent UI: Shōmei stays headless, and this plan specifies
precisely how the host application's login UI participates in the authorize flow.

The observable end state is a complete transcript: create a client, hit
`/oauth/authorize` with a valid session, receive a `302` carrying a single-use code,
exchange it at `/oauth/token` with a PKCE verifier, verify the returned ID token against
`/.well-known/jwks.json`, call `/oauth/userinfo`, introspect the access token
(`active: true`), revoke the refresh token, and introspect again (`active: false`).

This plan hard-depends on plan 41
(`docs/plans/41-database-backed-service-accounts-with-oauth2-client-credentials-grant.md`),
which created `POST /oauth/token`, its `grant_type` dispatcher, the client-authentication
helper (`Shomei.Servant.OAuth.extractClientAuth`), and the RFC 6749 error shape
(`oauthError`). This plan registers two more grants in that dispatcher. It soft-depends on
plan 38 (persistent roles/scopes): userinfo and ID-token claims include role/scope data
when the claims-enrichment hook exists, and work correctly with empty sets when it does
not.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `shomei_oauth_clients` migration; `OAuthClient` domain type; `OAuthClientStore` port; in-memory + Postgres interpreters; audit events.
- [x] M1: `shomei-admin oauth-clients create|list|revoke` subcommands.
- [x] M1: `OAuthConfig` sub-record in `ShomeiConfig` + server Dhall/env wiring.
- [x] M1: `GET /.well-known/openid-configuration` route + handler + tests.
- [x] M2: `shomei_oauth_authorization_codes` migration; `OAuthCodeStore` port; both interpreters (Postgres consume is one atomic `UPDATE … RETURNING`, proven under a gated 8-way race).
- [x] M2: `GET /oauth/authorize` handler: parameter validation, PKCE checks, authenticated path issues code redirect, unauthenticated path follows the login-redirect contract.
- [x] M2: In-process tests: happy redirect, invalid client/redirect (no redirect leak), error redirects with `state`, login-redirect round trip.
- [x] M2 (beyond plan): `DeleteExpiredAuthorizationCodes` wired into the plan-34 sweeper (`authorization_codes` in `SweepReport`), reusing the ceremony grace window.
- [x] M3: `grant_type=authorization_code` in the token dispatcher: code consumption (single-use), PKCE S256 verification, session + refresh issuance, `oauth_client_id` session binding.
- [x] M3: ID-token issuance (`SignIdToken` on the `TokenSigner` effect + jwt interpreter + in-memory fake); `nonce`/`auth_time` plumbed from authorize to token.
- [x] M3: `grant_type=refresh_token` mapped onto the existing rotation/reuse-detection workflow with client binding.
- [ ] M4: `GET /oauth/userinfo` (bearer).
- [ ] M4: `POST /oauth/introspect` (client-authenticated, RFC 7662 response, session-aware).
- [ ] M4: `POST /oauth/revoke` (RFC 7009; refresh → family+session revocation; access → session revocation with documented caveat).
- [ ] M5: OpenAPI (schemas, path count updated — recount at implementation time), spec regenerated.
- [ ] M5: `docs/user/oidc.md` written; `docs/user/api.md` and `docs/user/security.md` updated.
- [ ] M5: Postgres E2E: the full transcript from Purpose, automated.
- [ ] Final: `nix fmt`, `cabal build all`, `cabal test all` green; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-07-10 (M1) — this plan's own `just new-migration name=<slug>` invocations are wrong.**
The `Justfile` recipe takes the slug *positionally* and explicitly rejects a `name=` prefix
(`grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "Invalid slug"; exit 1; }`). The Concrete Steps and
Milestone sections below say `just new-migration name=shomei-oauth-clients`; the working command is
`just new-migration shomei-oauth-clients`. M2 and M3 add migrations and must use the positional
form.

**2026-07-10 (M1) — the OpenAPI OAuth-exemption list had to become path-keyed, and the plan's
"just add it to `oauthPaths`" is not sufficient.** `Shomei.Servant.OpenApi.oauthPaths` was a bare
`[FilePath]` whose members all received `oauthErrorResponses` — the *token endpoint's* statuses
(400/401/500). Putting `/.well-known/openid-configuration` on that list would have documented it as
emitting `invalid_client` and `unsupported_grant_type`. It is now
`oauthErrorResponsesByPath :: [(FilePath, [(Int, [Text])])]` with `oauthPaths = map fst …`, so each
OAuth-shaped path declares the statuses it can actually answer with (discovery: `404 not_found`
alone). **M4's `/oauth/introspect` and `/oauth/revoke` each need their own entry** — introspection
never errors on a bad token (RFC 7662 → `{"active": false}` at 200), so its only entries are the
`401 invalid_client` and `500`; revocation's are the same. `/oauth/userinfo` stays off the list
entirely: it uses the ordinary `Authenticated` combinator and answers ordinary problem documents.

**2026-07-10 (M1) — the discovery document is a pure function of config, not an `Env` field.**
The plan says to precompute it at `seamEnv` construction "as `jwksJson` does". That analogy does not
hold: `jwksJson` is an `IO Value` because the served key material is swapped at runtime by
`reloadKeys`. The discovery document is derived from `ShomeiConfig` alone, so it is
`Shomei.Servant.Oidc.discoveryDocument :: ShomeiConfig -> Value`, evaluated per request. Adding a
field to `Shomei.Servant.Seam.Env` would have forced an edit at every host assembly (boot, the
servant suite, the embedded example) to precompute a small constant object. Recorded in the
Decision Log.

**2026-07-10 (M1) — `nix fmt` still degrades `Shomei.Servant.OpenApi`'s module haddock, exactly as
EP-4 warned.** Running it escaped the leading `|` of the module comment (`-- \| The OpenAPI 3.1
description …`) and promoted the orphan-instances note into the module-doc position. The header was
restored by hand after formatting. `nix fmt` also reformats `shomei-server/test/Shomei/Server/NotifySpec.hs`,
untouched by this plan; it was reverted with `git checkout --`. **M2–M5 must do the same**: run
`nix fmt`, then `git checkout --` every file the milestone did not semantically change, and re-read
the `OpenApi.hs` header.

**2026-07-10 (M2) — the `MultilineString` literal drops its trailing newline, and
`"""…RETURNING""" <> selectCols` compiled into `RETURNINGcode_hash`.** PostgreSQL answered
`42601 syntax error at or near "RETURNINGcode_hash"` at runtime — nothing at compile time. The fix
is an explicit `<> " "`. **Any later plan concatenating a column list onto a multiline SQL literal
is exposed**; M3/M4 build statements the same way. Caught only because the store has an integration
test that actually executes the statement.

**2026-07-10 (M2) — the racing-consume test needs a start gate, and even then it only
opportunistically proves atomicity.** Two `forkIO`d consumes of one code almost always serialize,
so the case passed against a hypothetical read-then-write implementation until the contenders were
made to block on a shared `MVar` and grown to eight. What actually guarantees the property is that
the consume is ONE statement (`UPDATE … WHERE consumed_at IS NULL … RETURNING`); the test is a
regression guard against someone splitting it, not a proof. The assertion that exactly one row ends
up with `consumed_at IS NOT NULL` is the part that would catch a two-statement rewrite deterministically.

**2026-07-10 (M3) — `issueSession`'s signature was kept; the OAuth knobs went on a new
`issueSessionWith`.** The plan suggested "add a `Maybe Text` oauth-client parameter, existing
callers passing `Nothing`". A parameter would have churned all three call sites (login, MFA,
passwordless) and every private interpreter chain. Instead `issueSession` delegates to
`issueSessionWith cfg defaultSessionOptions`, which additionally returns the `AuthClaims` it signed
— because the authorization-code grant must build its ID token from the *same* `buildEnrichedClaims`
output as the access token (the MasterPlan's claims integration point), and returning them is how it
gets that without re-reading the role store in the HTTP layer. The `SessionOptions` record also
carries `extraScopes`, so the OAuth-granted scopes land on the access token's claims through one
path.

**2026-07-10 (M3) — the code is consumed BEFORE the client/PKCE/redirect checks that can fail, on
purpose.** `exchangeAuthorizationCode` calls `consumeAuthorizationCode` immediately after
authenticating the client, then checks the client binding, redirect_uri, and PKCE against the
consumed row. So a wrong-PKCE or wrong-client attempt still burns the code: an attacker who steals a
code from the redirect cannot grind verifiers against it. The alternative — validate, then consume —
would let a thief retry indefinitely.

**2026-07-10 (M3) — `refreshViaOAuth` checks the client binding before delegating, and a mismatch
does NOT run reuse detection.** Reuse detection revokes the whole token family and the session. If a
binding mismatch went through the normal `refresh` path, any client that merely *observed* another
client's refresh token could revoke that user's session by presenting it — turning a theft defense
into a DoS tool. So the binding is a gate in front of `Wf.refresh`, and a session with a NULL
`oauth_client_id` (every password/passkey/impersonation/service session) is refusable at
`/oauth/token` outright while the bespoke `/v1/auth/refresh` keeps rotating it.

**2026-07-10 (M3) — an EP-4 servant test asserted `grant_type=authorization_code` was
`unsupported_grant_type`; M3 makes it supported.** The assertion in
`scenarioOAuthTokenEndpoint` had to be updated, not just extended. **Any plan that turns a
previously-unsupported grant into a real arm (EP-6's token-exchange) will hit the same stale
assertion.** Left `password` there as the permanently-unsupported example.

**2026-07-10 (M3) — the round-trip budget guards did NOT trip, because the OAuth exchange is not
the login/refresh path they pin.** `testLoginRoundTripBudget`/`testRefreshRoundTripBudget` count the
bespoke flows; `exchangeAuthorizationCode` is a distinct path (consume + issueSessionWith), so it
does not touch those constants. EP-6 and EP-9, which add work to the *shared* mint, still will.

**2026-07-10 (M2) — the session cookie is `Path=/`, so `/oauth/authorize` already inherits the
cookie transport.** EP-3's "a route's path is written down in four places" check was run for this
route: the refresh cookie is scoped to `/v1/auth/refresh` but the *session* cookie
(`Shomei.Servant.Cookie.tokenCookies`) is `Path=/`, which is what `resolveAuthUser` reads at
authorize. The rate limiter (`RateLimit.throttledPath`) and the metrics table were deliberately not
extended: authorize guesses no credential (it needs a valid token or it bounces to the login page).
**`/oauth/token` remains unthrottled too** — it *does* accept a guessable client secret, and
throttling it is a real gap this MasterPlan should pick up somewhere.

**2026-07-10 (M1) — `cabal test all` failed once on `shomei-core`'s "100 concurrent refreshes:
exactly one winner", and it is load flakiness, not a regression.** It reproduces neither in
isolation (4/4 green at `HEAD` before any change, 3/3 on this tree) nor across two further full-suite
runs on this tree; `cabal` runs the twelve suites concurrently, and `TASTY_NUM_THREADS=1` bounds
parallelism only *within* a suite. Same class as the `SupervisorSpec` and ephemeral-PostgreSQL
flakes the MasterPlan already records. Do not chase it.


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement a deliberate OIDC subset: discovery, authorization code + PKCE,
  refresh, ID tokens, userinfo, introspection, revocation. Excluded: implicit and hybrid
  flows, dynamic client registration (RFC 7591), request objects/JAR, PAR, session
  management/front- and back-channel logout, `prompt`/`max_age`/ACR handling, and any
  consent or login UI.
  Rationale: The subset is exactly what stock relying-party middleware needs to
  auto-configure. Implicit/hybrid are deprecated by the OAuth Security BCP. Shōmei's
  differentiator is headless host-owns-the-UI (MasterPlan Decision Log); consent screens
  and hosted login would erase it.
  Date: 2026-07-07

- Decision: PKCE is S256-only and mandatory for public clients; for confidential clients
  it is optional but verified whenever the authorize request supplied a challenge.
  Rationale: MasterPlan decision. The `plain` method exists only for legacy clients that
  cannot hash; every modern library does S256. A public client (no secret) has no other
  binding between the authorize and token requests, so PKCE is its only code-theft
  defense.
  Date: 2026-07-07

- Decision: The headless authorize contract: `GET /oauth/authorize` authenticates the
  browser/user with the *same* credential machinery as every other authenticated route
  (the `AuthProtect "shomei-jwt"` handler, i.e. a bearer token today and the cookie
  transport when `docs/plans/31-...` lands). An authenticated request immediately 302s to
  `redirect_uri` with the code. An unauthenticated request 302s to the operator-configured
  `oauthConfig.loginUrl` with the complete original authorize URL in a `return_to` query
  parameter; the host logs the user in with its own UI and navigates back to `return_to`.
  If no `loginUrl` is configured, unauthenticated requests get HTTP 401 with an OAuth
  error body. Shōmei persists no server-side "pending authorize request" state.
  Rationale: This is the thinnest contract that works for real integrations, and it keeps
  Shōmei stateless until code issuance (the authorize parameters round-trip in the
  `return_to` URL, which the host treats as opaque). For background comparison only:
  Zitadel persists an auth-request row and bounces the browser to
  `/login?authRequestID=...`, whose UI later redirects back into an OP callback endpoint
  that issues the code (`/Users/shinzui/Keikaku/hub/zitadel/internal/api/oidc/auth_request.go`,
  login handlers under `internal/ui/login/`) — that design exists because Zitadel *ships*
  the login UI and must hand mid-flow state to it. Shōmei ships no UI, so the state can
  live in the URL. The cost: the host login page must preserve `return_to` across its own
  flow — documented as the integration contract in `docs/user/oidc.md`.
  Date: 2026-07-07

- Decision: How each consumer class integrates (spelled out so the contract is testable).
  A server-side relying party (oauth2-proxy, Spring): browser navigation to
  `/oauth/authorize` carries the session cookie once plan 31's cookie transport is
  enabled (`tokenTransport = HttpOnlyCookie|BearerAndCookie` in `Shomei.Config`); until
  then the login-redirect path covers it. A SPA (public client) already holding a Shōmei
  bearer token: it calls `/oauth/authorize` with
  `fetch(url, { headers: { Authorization: "Bearer ..." }, redirect: "manual" })` and
  applies the `Location` itself. A native/CLI client: system-browser navigation plus the
  host login page, standard loopback redirect_uri. This plan's tests exercise the
  bearer-header path (the only one testable without plan 31) and the login-redirect path.
  Rationale: The authorize endpoint must not invent a second authentication mechanism;
  reusing the existing `AuthUser` handler means every current and future transport
  (bearer, cookie) works identically, and `sessionCheckMode` semantics apply unchanged.
  Date: 2026-07-07

- Decision: Authorization codes get a dedicated table and port
  (`shomei_oauth_authorization_codes`, `OAuthCodeStore`) rather than reusing the
  one-time-token tables of email-verification/password-reset or `PendingCeremonyStore`.
  Rationale: A code must be bound to client id, redirect URI, PKCE challenge, user,
  scopes, nonce, and auth_time — none of which the existing single-purpose token tables
  carry — and consumption must atomically return all of it. The consume-once semantics do
  copy the proven `TakePendingCeremony` shape (return-if-unexpired, never twice).
  Date: 2026-07-07

- Decision: The `refresh_token` grant reuses the existing rotating refresh-token
  machinery (opaque tokens, `parentTokenId` families, reuse detection revoking family and
  session) — no parallel store. Client binding is added with a nullable
  `oauth_client_id text` column on `shomei_sessions`: sessions minted by the
  authorization-code grant record the issuing client, and the `refresh_token` grant
  refuses rotation when the authenticated (or asserted, for public clients) client does
  not match. The bespoke `/auth/refresh` endpoint ignores the column and keeps working.
  Rationale: The rotation/reuse-detection code in `Shomei.Workflow.refresh` is the most
  security-sensitive machinery in the repo; duplicating it for OIDC clients would fork
  its invariants. A session-level binding suffices because Shōmei's refresh tokens are
  already session-scoped. Nullable keeps every existing row and flow byte-identical.
  Date: 2026-07-07

- Decision: A refresh token is issued to authorization-code sessions unconditionally (as
  the existing `issueSession` already does for logins); the `offline_access` scope is
  accepted and ignored.
  Rationale: Shōmei's session model always pairs access+refresh; gating refresh on
  `offline_access` would create a session variant the rest of the codebase (rotation,
  revocation, sweeper) has never seen, for no security gain in a subset without consent
  screens. Recorded so a future plan can revisit when consent semantics exist.
  Date: 2026-07-07

- Decision: The OIDC issuer is `ShomeiConfig.issuer`, and operators using OIDC must set
  it to the public HTTPS base URL of the deployment; discovery derives every endpoint URL
  from it.
  Rationale: OIDC Core mandates that the discovery document live at
  `{issuer}/.well-known/openid-configuration` and that ID tokens carry `iss = issuer`, so
  the issuer *is* the base URL by construction. Adding a second "public base URL" field
  (one already exists inside `notifierConfig` for email links) would create two values
  that must agree. Boot-time validation fails loudly when OIDC is enabled and the issuer
  does not parse as an absolute http(s) URL.
  Date: 2026-07-07

- Decision: ID-token signing is a new `SignIdToken` operation on the existing
  `TokenSigner` effect (with a small `IdTokenClaims` record in `shomei-core`), interpreted
  by `shomei-jwt` with the same active key and `kid` as access tokens.
  Rationale: Every workflow-visible signing capability in this repo is a `TokenSigner`
  operation; signing ID tokens directly with jose from the HTTP layer would bypass the
  port discipline and the in-memory test fake. Reusing the key means zero new JWKS or
  rotation work.
  Date: 2026-07-07

- Decision: Introspection always consults the session store (a token is `active` only if
  its signature verifies, it is unexpired, *and* its `sid` resolves to an unrevoked,
  unexpired session), regardless of the global `sessionCheckMode`.
  Rationale: RFC 7662 exists precisely so resource servers can see revocation that
  stateless JWT verification cannot; an introspection endpoint blind to revocation would
  be misleading. This is also what makes the revoke→introspect acceptance transcript
  observable.
  Date: 2026-07-07

- Decision: Revocation of an access token revokes its session (best-effort), and the
  documentation states plainly: deployments verifying statelessly
  (`sessionCheckMode = VerifyTokenOnly`, the default) keep accepting the JWT until
  `exp`; deployments with `VerifyTokenAndSession` reject it immediately. Revocation of a
  refresh token revokes the token family and the session. Both return HTTP 200 always
  (RFC 7009 §2.2 — invalid tokens do not error, to prevent probing).
  Rationale: This is the honest semantics of a stateless-JWT provider; hiding it would be
  worse than documenting it.
  Date: 2026-07-07

- Decision: Client registration is static: the `shomei-admin oauth-clients` CLI managing
  database rows only. No dynamic registration endpoint; no Dhall-defined clients in this
  plan.
  Rationale: MasterPlan decision (no dynamic registration). A second, config-file source
  of clients would repeat the dual-source situation plan 41 is deprecating for service
  accounts. If a bootstrap-from-config need appears, record it here and add it later.
  Date: 2026-07-07

- Decision: The discovery document is a pure `discoveryDocument :: ShomeiConfig -> Value` in a
  new `Shomei.Servant.Oidc`, evaluated per request, rather than a precomputed field on
  `Shomei.Servant.Seam.Env`.
  Rationale: It is derived from configuration alone, which never changes while the process runs.
  The `jwksJson` precomputation this plan pointed at exists because key material *is* swapped at
  runtime (`reloadKeys`), which is why that field is an `IO Value`. An `Env` field would have
  forced an edit at every host assembly to cache a constant.
  Date: 2026-07-10

- Decision: An OAuth client gets no backing `shomei_users` row, and its lifecycle audit events
  carry no `user_id` (the audit row's `user_id` column stays NULL).
  Rationale: A service account (EP-4) *is* a token subject, so it needs a user row for
  `AuthClaims.subject` and the `shomei_sessions.user_id` foreign key. An OAuth client is never a
  subject: the token it exchanges a code for belongs to whoever authenticated at
  `/oauth/authorize`. Giving it a user row would put a principal in the table that can never log
  in and can never be a `sub`.
  Date: 2026-07-10

- Decision: There is no `oauth-clients rotate-secret` subcommand in this plan; a compromised
  client secret is handled by `revoke` plus re-registration.
  Rationale: A service account's secret is held by a machine an operator may not be able to
  redeploy quickly, which is what rotation-without-downtime buys. An OAuth client's secret lives
  in an application the same operator configures, and re-registration is a config change either
  way. Recorded so a future plan can add rotation if this proves wrong.
  Date: 2026-07-10

- Decision: A public client is issued no secret at all, rather than one that is stored and never
  checked; its `secret_hash` is a SQL NULL.
  Rationale: A credential that exists but is never verified is worse than none, because an
  operator will store and protect it under the belief that it does something.
  Date: 2026-07-10

- Decision: `issueSession`'s public signature is unchanged; a new `issueSessionWith` /
  `SessionOptions` carries the OAuth client binding and extra scopes, and returns the signed
  `AuthClaims`.
  Rationale: The plan proposed an added parameter with existing callers passing `Nothing`, but
  that churns three call sites and every interpreter chain. Delegation keeps one issuance path.
  Returning the claims is what lets the authorization-code grant build its ID token from the same
  `buildEnrichedClaims` output as the access token, per the MasterPlan claims integration point,
  instead of re-reading stores in the HTTP layer.
  Date: 2026-07-10

- Decision: The authorization code is consumed before the redirect_uri / client / PKCE checks that
  can fail.
  Rationale: A stolen code must be single-use even against an attacker who does not know the
  verifier: consuming first means a failed PKCE attempt still burns the code, so it cannot be
  ground against.
  Date: 2026-07-10

- Decision: No ID token is minted on the `refresh_token` grant.
  Rationale: An ID token's `nonce` and `auth_time` belong to the authorize request, and Shōmei
  persists neither past the code. A client needing a fresh ID token re-runs the authorize flow.
  Date: 2026-07-10

- Decision: `authorize`'s failures are a dedicated `AuthorizeError` in the workflow, not new
  `AuthError` constructors.
  Rationale: Every one of them becomes an `error=` parameter on a redirect back to the client, so
  none can ever render as a problem document. Adding them to `AuthError` would force entries in
  `problemCatalog` (which the conformance suite requires) describing errors the envelope can never
  carry.
  Date: 2026-07-10

- Decision: A `code_challenge` supplied without an explicit `code_challenge_method` is refused,
  rather than defaulting to `plain` as RFC 7636 §4.3 specifies.
  Rationale: This provider accepts only S256. Honoring the spec's default would silently downgrade
  a client that meant S256 and forgot the parameter, and `plain` offers no protection against a
  code intercepted together with the authorize request.
  Date: 2026-07-10

- Decision: An absent `scope` at authorize grants the client's entire registered allow-list; a
  present but empty one (`scope=`) is `invalid_scope`.
  Rationale: RFC 6749 §3.3 lets the server pick a default for an absent scope, and "what this
  client is registered for" is the least surprising one. It matches what EP-4's `client_credentials`
  grant already does. An empty `scope` parameter is a malformed request, not a request for nothing.
  Date: 2026-07-10

- Decision: All new endpoints are unversioned root paths (`/oauth/*`, `/.well-known/*`),
  and all their errors use the RFC 6749/7662/7009 wire shapes, not the application
  envelope.
  Rationale: Same versioning and error-boundary rules as plan 41 (MasterPlan Integration
  Points): protocol tooling expects conventional locations and field names.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository is a multi-package Haskell Cabal project at
`/Users/shinzui/Keikaku/bokuno/shomei` (GHC 9.12.4, `nix develop`, `cabal build all`,
`cabal test all`, dev database via `just create-database`, formatting via `nix fmt`).
Package roles: `shomei-core` (domain types, workflows, effect ports — GADTs dispatched
dynamically via the `effectful` library, with in-memory test interpreters in
`shomei-core/src/Shomei/Effect/InMemory.hs`), `shomei-postgres` (hasql interpreters, one
module per port), `shomei-migrations` (codd SQL migrations in
`shomei-migrations/sql-migrations/`, embedded at compile time — `just migrate` touches the
cabal file to force re-embedding; scaffold with `just new-migration name=<slug>`),
`shomei-jwt` (claims↔JWT, keys, JWKS), `shomei-servant` (the `ShomeiAPI` NamedRoutes
record in `shomei-servant/src/Shomei/Servant/API.hs`, DTOs, handlers, OpenAPI),
`shomei-server` (Warp wiring in `Shomei.Server.Boot`/`Shomei.Server.App`, the
`shomei-admin` CLI in `shomei-server/app/Admin.hs`), `shomei-client` (servant-client via
`genericClient`).

What this plan builds on, verified in the working tree as of authoring (plan 41 items are
its committed deliverables — reverify they exist before starting):

Plan 41's deliverables (hard dependency): `POST /oauth/token` as an `oauthToken` field on
`ShomeiAPI` taking `Header "Authorization" Text` and `ReqBody '[FormUrlEncoded] Form`;
the dispatcher in `Handlers.hs` (`oauthTokenH`) switching on `grant_type`;
`Shomei.Servant.OAuth` with `oauthError :: Status -> Text -> Text -> ServerError` (the
RFC 6749 §5.2 JSON error shape `{"error","error_description"}` — deliberately distinct
from the application envelope in `Shomei.Servant.Error`), `extractClientAuth`
(client_secret_basic + client_secret_post), and `TokenResponse`; plus the
`shomei_service_accounts` table and `ServiceAccountStore` port.

Authentication of users: routes marked `Authenticated` (a synonym for
`AuthProtect "shomei-jwt"`) run the handler in `shomei-servant/src/Shomei/Servant/Auth.hs`
which verifies the presented credential and yields an `AuthUser` carrying `authUserId`,
`authSessionId`, and the full `authClaims :: AuthClaims`. `AuthClaims`
(`shomei-core/src/Shomei/Domain/Claims.hs`) has `subject`, `sessionId`, `issuer`,
`audience`, `issuedAt`, `expiresAt`, `scopes :: Set Scope`, `roles :: Set Role`,
`actor :: Maybe UserId`, `extraClaims :: Object`.

Sessions and refresh: `Shomei.Workflow.Session.issueSession cfg user ts` creates a session
row plus a rotating opaque refresh token and returns `(SessionId, TokenPair)`. Rotation
and reuse detection live in `Shomei.Workflow.refresh`
(`shomei-core/src/Shomei/Workflow.hs`): a presented refresh token is hashed and looked up;
a used/revoked token triggers `revokeRefreshTokenFamily` + `revokeSession` + a
`RefreshTokenReuseDetected` audit event; an active one is marked used and a child token
minted with `parentTokenId` linking the family. `SessionStore` exposes `revokeSession`;
`RefreshTokenStore` exposes `findRefreshTokenByHash`, `revokeRefreshTokenFamily`,
`revokeSessionRefreshTokens`.

Signing and keys: `Shomei.Effect.TokenSigner` currently has one operation,
`SignAccessToken :: AuthClaims -> TokenSigner m AccessToken`, interpreted by
`runTokenSignerJwt` (`shomei-jwt`), which signs with the active key, pins ES256/RS256 via
`algForKey`, and stamps the `kid` (the RFC 7638 thumbprint, `Shomei.Jwt.Key.keyKid`).
JWKS is served at `GET /.well-known/jwks.json` from a precomputed `Env.jwksJson`
(`Shomei.Server.Boot.seamEnv`).

Claims construction: `buildClaims`/`buildClaimsWith` in `Shomei.Workflow.Session` mint
empty scope/role sets today. Plan 38 (soft dependency,
`docs/plans/38-persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment.md`)
introduces an enrichment hook there; this plan's ID-token and userinfo claims must flow
through whatever `issueSession`/`buildClaims` produce — never re-read stores in the HTTP
layer. When plan 38 has not landed, role/scope claims are simply empty, and everything
here still works.

Config: `ShomeiConfig` (`shomei-core/src/Shomei/Config.hs`) is an append-only record of
sub-configs (`webauthnConfig`, `impersonationConfig`, `serviceTokenConfig`, ...); every
field has a default so existing constructions keep compiling. Server-side loading
(defaults → Dhall via `$SHOMEI_CONFIG` → `SHOMEI_*` env vars) is
`shomei-server/src/Shomei/Server/Config.hs`. `TokenTransport`
(`BearerToken | HttpOnlyCookie | BearerAndCookie`) and
`SessionCheckMode (VerifyTokenOnly | VerifyTokenAndSession)` already exist there.

OpenAPI: `shomei-servant/src/Shomei/Servant/OpenApi.hs` +
`shomei-servant/test-openapi/Main.hs` (conformance suite: `validateEveryToJSON`, a
version assertion, and a hard-coded path count); regenerate the committed
`docs/api/openapi.json` with `cabal run shomei-openapi > docs/api/openapi.json`.

Embedded protocol knowledge (everything needed to implement, in this plan's own words so
no external document is required):

*Discovery* (OIDC Core / RFC 8414): a JSON document at
`{issuer}/.well-known/openid-configuration` whose fields name the provider's endpoints
and capabilities. The fields this plan serves: `issuer`, `authorization_endpoint`,
`token_endpoint`, `jwks_uri`, `userinfo_endpoint`, `introspection_endpoint`,
`revocation_endpoint`, `response_types_supported` (`["code"]`),
`grant_types_supported` (`["authorization_code","refresh_token","client_credentials"]`),
`code_challenge_methods_supported` (`["S256"]`),
`id_token_signing_alg_values_supported` (the configured algorithm, `ES256` or `RS256`),
`subject_types_supported` (`["public"]`), `scopes_supported`
(`["openid","profile","email","offline_access"]`), and
`token_endpoint_auth_methods_supported` (`["client_secret_basic","client_secret_post"]`).

*Authorization-code grant* (RFC 6749 §4.1): the client sends the browser to
`GET /oauth/authorize?response_type=code&client_id=...&redirect_uri=...&scope=...&state=...&nonce=...&code_challenge=...&code_challenge_method=S256`.
The server authenticates the user, then redirects to `redirect_uri` with
`?code=...&state=...`. The client then POSTs to the token endpoint
`grant_type=authorization_code&code=...&redirect_uri=...&code_verifier=...` (plus client
authentication for confidential clients, or `client_id` alone for public ones) and
receives the token response. Two validation regimes at authorize: if `client_id` is
unknown or `redirect_uri` is not exactly one of the client's registered URIs, the server
MUST NOT redirect (that would be an open redirector) — respond 400 with an error body.
For any *other* error (bad `response_type`, missing PKCE for a public client, disallowed
scope), the server redirects to the (validated) `redirect_uri` with
`?error=<code>&error_description=...&state=...` using codes `invalid_request`,
`unsupported_response_type`, `invalid_scope`, `unauthorized_client`, `access_denied`,
`server_error`.

*PKCE* (RFC 7636): the client generates a random `code_verifier` (43–128 chars of
`[A-Za-z0-9-._~]`), sends
`code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))` (no padding) with
`code_challenge_method=S256` at authorize, and the raw `code_verifier` at token. The
server stores the challenge with the code and verifies
`BASE64URL(SHA256(verifier)) == stored challenge` byte-for-byte; a mismatch, or a missing
verifier when a challenge was stored, is `invalid_grant`.

*ID token* (OIDC Core §2): a JWT signed by the provider with claims `iss` (the issuer),
`sub` (the user id), `aud` (the `client_id`), `exp`, `iat`, `nonce` (echoed verbatim from
the authorize request iff one was sent — the client uses it to bind the token to its own
session and prevent replay), and `auth_time` (Unix time the user authenticated — Shōmei
uses the authenticating access token's `issuedAt`, captured at authorize time). It is
returned as `id_token` alongside the access token when the granted scopes include
`openid`.

*Userinfo* (OIDC Core §5.3): a bearer-protected endpoint returning JSON with at least
`sub` matching the ID token's `sub`. Shōmei returns `sub`, `email` and `email_verified`
when the user row has them, and Shōmei-flavored `roles` and `scopes` arrays taken from
the presented token's claims.

*Introspection* (RFC 7662): `POST /oauth/introspect` with form fields `token` and
optional `token_type_hint`, authenticated as a client (Basic or post — reuse
`extractClientAuth`; both oauth clients and plan-41 service accounts may call it). The
response is `{"active": false}` for anything invalid/expired/revoked (never an error, to
prevent probing), or
`{"active": true, "scope": "a b", "client_id": ..., "sub": ..., "sid": ..., "exp": ...,
"iat": ..., "iss": ..., "aud": ..., "token_type": "Bearer", "username": ..., "act": {...}}`
for a live token (fields present when known; `act` per the RFC 8693 convention when the
token is delegated). For background: Zitadel's introspection
(`/Users/shinzui/Keikaku/hub/zitadel/internal/api/oidc/introspect.go`) likewise requires
client auth, returns bare `{"active": false}` on *any* token-side failure, and merges
identity claims into the active response — the same failure-shape discipline is adopted
here.

*Revocation* (RFC 7009): `POST /oauth/revoke` with form fields `token` and optional
`token_type_hint` (`refresh_token` or `access_token`), client-authenticated. The server
revokes what it recognizes and returns HTTP 200 with an empty body even when the token is
unknown or already dead; only failed client authentication (401 `invalid_client`) is a
real error.


## Plan of Work

Five milestones. Each ends observable. Work from the repository root inside `nix develop`.

### Milestone M1 — OAuth clients, config, CLI, and discovery

Scope: everything needed before any browser flow: client storage, its CLI, the
`OAuthConfig` sub-record, and the discovery document. At the end,
`curl /.well-known/openid-configuration` returns a valid document and an operator can
register a client.

Migration (`just new-migration name=shomei-oauth-clients`; the scaffolder emits the
`-- codd: in-txn` and `SET search_path TO shomei, pg_catalog;` header):

```sql
CREATE TABLE IF NOT EXISTS shomei_oauth_clients (
  oauth_client_id uuid PRIMARY KEY,
  client_id       text NOT NULL UNIQUE,
  secret_hash     text NULL,
  client_type     text NOT NULL,
  display_name    text NOT NULL,
  redirect_uris   jsonb NOT NULL,
  allowed_scopes  jsonb NOT NULL,
  status          text NOT NULL,
  created_at      timestamptz NOT NULL,
  revoked_at      timestamptz NULL
);
```

`client_type` is `'confidential'` or `'public'`; `secret_hash` is NULL exactly for public
clients (otherwise lowercase SHA-256 hex, the same format as service accounts — reuse
`sha256Hex`/`verifyServiceSecret` from `Shomei.Workflow.ServiceToken`). `client_id` is the
TypeID text of the primary key with a new prefix added to
`shomei-core/src/Shomei/Id.hs` (`type OAuthClientId = KindID "oauthclient"`, plus
`gen`/`ToUUID`/`FromUUID` helpers per the existing pattern there).

Domain type `shomei-core/src/Shomei/Domain/OAuthClient.hs`
(`OAuthClient { oauthClientId, clientId, secretHash :: Maybe Text, clientType, displayName, redirectUris :: [Text], allowedScopes :: Set Scope, status, createdAt, revokedAt }`
with `ClientType = ConfidentialClient | PublicClient` and a status enum); port
`shomei-core/src/Shomei/Effect/OAuthClientStore.hs`
(`CreateOAuthClient`, `FindOAuthClientByClientId`, `ListOAuthClients`,
`RevokeOAuthClient`); in-memory interpreter (new `World` field + `emptyWorld` init);
Postgres interpreter `shomei-postgres/src/Shomei/Postgres/OAuthClientStore.hs`; and
registration in the three effect-stack lists (`Shomei.Servant.Seam.AppEffects`,
`Shomei.Server.App.AppEffects` + `runAppIO`, `runInMemory`) in identical positions. Audit
events `OAuthClientCreated` / `OAuthClientRevoked` in `Event.hs` + `EventCodec.hs` (event
types `oauth_client_created`, `oauth_client_revoked`) + the codec round-trip spec.

Config: add to `Shomei.Config` an append-only sub-record with defaults:

```haskell
data OAuthConfig = OAuthConfig
  { oidcEnabled :: !Bool,               -- default False: discovery/authorize answer 404 when off
    loginUrl :: !(Maybe Text),          -- host login page for the unauthenticated-authorize redirect
    authorizationCodeTTL :: !NominalDiffTime,   -- default 60
    idTokenTTL :: !NominalDiffTime      -- default 15*60, matching the access-token default
  }
```

Wire `oauthConfig` into `ShomeiConfig` + `defaultShomeiConfig`, then into
`shomei-server/src/Shomei/Server/Config.hs` (`FileConfig` fields and env overrides
`SHOMEI_OIDC_ENABLED`, `SHOMEI_OAUTH_LOGIN_URL`, following the existing
`boolEnv`/`textEnv` helpers) and into `config/shomei-types.dhall` /
`config/shomei.example.dhall` (disabled in the example). At boot, when `oidcEnabled` and
the issuer text does not start with `http://` or `https://`, fail loudly with a clear
message (the issuer doubles as the endpoint base URL — Decision Log).

CLI: `shomei-admin oauth-clients create --display-name NAME --type confidential|public
--redirect-uri URI [--redirect-uri URI ...] --scope S [--scope S ...]`, `list`, and
`revoke CLIENT_ID`, in a new `shomei-server/app/Shomei/Admin/OAuthClients.hs` following
plan 41's `Shomei/Admin/ServiceAccounts.hs`. For confidential clients generate and print
the secret once (32 random bytes, base64url); for public clients print only the client
id. Note oauth clients do *not* get a backing `shomei_users` row — unlike service
accounts they never appear as a token subject; users do.

Discovery route on `ShomeiAPI`:

```haskell
oidcDiscovery ::
  mode :- ".well-known" :> "openid-configuration" :> Get '[JSON] Value
```

The handler builds the document from `env.config` (issuer + fixed relative endpoint
paths + the configured signing algorithm from `configSigningAlgorithm`). When
`oidcEnabled` is `False`, respond 404 with a small JSON body — a disabled provider must
not advertise. Precompute the document at `seamEnv` construction time (the `jwksJson`
precomputation in `Shomei.Server.Boot` is the pattern).

Acceptance for M1: `cabal test shomei-core shomei-postgres shomei-server` green including
new specs; manually,

```bash
SHOMEI_OIDC_ENABLED=true SHOMEI_ISSUER=http://localhost:8080 cabal run shomei-server &
curl -s http://localhost:8080/.well-known/openid-configuration | jq .authorization_endpoint
```

prints `"http://localhost:8080/oauth/authorize"`.

### Milestone M2 — `/oauth/authorize` and code issuance

Scope: the headless authorize endpoint and the single-use code store. At the end, an
authenticated request yields a 302 with a code; an unauthenticated one follows the login
contract; every parameter violation behaves per the two validation regimes.

Code store. Migration (`just new-migration name=shomei-oauth-authorization-codes`):

```sql
CREATE TABLE IF NOT EXISTS shomei_oauth_authorization_codes (
  code_hash       text PRIMARY KEY,
  client_id       text NOT NULL,
  redirect_uri    text NOT NULL,
  user_id         uuid NOT NULL REFERENCES shomei_users(user_id),
  scopes          jsonb NOT NULL,
  nonce           text NULL,
  code_challenge  text NULL,
  auth_time       timestamptz NOT NULL,
  created_at      timestamptz NOT NULL,
  expires_at      timestamptz NOT NULL,
  consumed_at     timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_oauth_authorization_codes_expires_at_idx
  ON shomei_oauth_authorization_codes (expires_at);
```

The code itself is a high-entropy opaque string from the existing `TokenGen` port
(`generateOpaqueToken`); only its SHA-256 hex is stored, so a database leak leaks no
usable codes. Port `shomei-core/src/Shomei/Effect/OAuthCodeStore.hs`:

```haskell
data OAuthCodeStore :: Effect where
  PutAuthorizationCode :: NewAuthorizationCode -> OAuthCodeStore m ()
  ConsumeAuthorizationCode :: Text -> UTCTime -> OAuthCodeStore m (Maybe AuthorizationCode)
  DeleteExpiredAuthorizationCodes :: UTCTime -> OAuthCodeStore m ()
```

`ConsumeAuthorizationCode hash now` follows the `TakePendingCeremony` discipline. In
Postgres it must be one atomic statement so two racing exchanges cannot both win:
`UPDATE ... SET consumed_at = $2 WHERE code_hash = $1 AND consumed_at IS NULL AND
expires_at > $2 RETURNING ...`. Both interpreters, effect-stack registration, and a
domain record `AuthorizationCode` mirroring the columns go in the usual places.

Workflow `shomei-core/src/Shomei/Workflow/OAuthAuthorize.hs`: given config, the resolved
client, the caller's `AuthClaims`, and the parsed parameters, it enforces PKCE policy
(public client without `code_challenge` → error; `code_challenge_method` other than
`S256` → error; challenge must be exactly 43 unpadded base64url chars), checks requested
scopes against the client's `allowedScopes`, mints and stores the code with
`auth_time = claims.issuedAt`, publishes a new `OAuthCodeIssued` audit event (event type
`oauth_code_issued`; payload: clientId, userId, scopes, occurredAt — never the code), and
returns the redirect target.

Route and handler. Add to `ShomeiAPI`:

```haskell
oauthAuthorize ::
  mode
    :- "oauth"
      :> "authorize"
      :> Header "Authorization" Text
      :> QueryParam "response_type" Text
      :> QueryParam "client_id" Text
      :> QueryParam "redirect_uri" Text
      :> QueryParam "scope" Text
      :> QueryParam "state" Text
      :> QueryParam "nonce" Text
      :> QueryParam "code_challenge" Text
      :> QueryParam "code_challenge_method" Text
      :> Verb 'GET 302 '[JSON] (Headers '[Header "Location" Text] NoContent)
```

The handler authenticates *manually* rather than via the route-level combinator, because
unauthenticated must redirect, not 401: factor the token-extraction-plus-verification
core of `shomei-servant/src/Shomei/Servant/Auth.hs` into an exported function (for
example `resolveAuthUser :: ... -> Handler (Maybe AuthUser)`) used by both the
`AuthHandler` and this route — when plan 31's cookie transport lands in that module,
authorize inherits it automatically. Handler order:

1. Look up `client_id`; require status active. Unknown/revoked client, or `redirect_uri`
   not *exactly equal* (string equality, no prefix matching) to one of `redirectUris` →
   HTTP 400 JSON `{"error":"invalid_request",...}` and **no redirect**.
2. Any other parameter violation (`response_type /= "code"`, PKCE policy, scope not
   allowed) → 302 to `redirect_uri` with `error`, `error_description`, and the echoed
   `state`.
3. No authenticated user: if `loginUrl` is configured → 302 to
   `loginUrl <> "?return_to=" <> urlEncode(originalUrl)` where the original URL is
   reconstructed from the validated query parameters (never trust a client-supplied
   copy); else 401 with an OAuth error body.
4. Authenticated → run the workflow → 302 to `redirect_uri <> "?code=...&state=..."`.

Also append the `iss` authorization-response parameter (`&iss=<issuer>`, RFC 9207) — one
line, and modern clients use it to detect mix-up attacks.

Tests (in-process, `shomei-servant/test/Main.hs` style): happy path with a bearer token →
302, `Location` parses, `code` present, `state` echoed, `iss` present; unknown client →
400 without `Location`; mismatched redirect_uri → 400; public client missing
`code_challenge` → 302 with `error=invalid_request`; `response_type=token` → 302 with
`error=unsupported_response_type`; unauthenticated with `loginUrl` configured → 302 whose
`Location` starts with the login URL and whose `return_to` decodes to the original URL;
unauthenticated without `loginUrl` → 401; the stored code row has `consumed_at IS NULL`
and a 60-second expiry.

Acceptance for M2: `cabal test shomei-servant shomei-core` green with the above.

### Milestone M3 — Code and refresh grants at the token endpoint, ID tokens

Scope: the exchange leg. At the end, a stored code plus the right PKCE verifier yields
access + refresh + ID tokens, and refresh rotation works through `/oauth/token`.

Session binding first: migration `just new-migration name=shomei-sessions-oauth-client`
containing `ALTER TABLE shomei_sessions ADD COLUMN IF NOT EXISTS oauth_client_id text NULL;`.
Thread the field through `Session`/`NewSession` in `shomei-core` (a `Maybe Text`,
`Nothing` at every existing construction site — the compiler enumerates them), the
Postgres codec, and the in-memory store. This mirrors exactly how the `actor` column was
added (`2026-06-17-12-07-46-shomei-sessions-actor.sql`).

ID-token signing: add `shomei-core/src/Shomei/Domain/IdTokenClaims.hs`:

```haskell
data IdTokenClaims = IdTokenClaims
  { issuer :: !Issuer,
    subject :: !UserId,
    audience :: !Text,        -- the client_id
    issuedAt :: !UTCTime,
    expiresAt :: !UTCTime,
    nonce :: !(Maybe Text),
    authTime :: !UTCTime
  }
```

Extend the `TokenSigner` effect with
`SignIdToken :: IdTokenClaims -> TokenSigner m IdToken` (an `IdToken` newtype over `Text`
beside `AccessToken`), implement it in `shomei-jwt`'s `runTokenSignerJwt` (a
`claimsFromIdToken :: IdTokenClaims -> ClaimsSet` mirroring `claimsFromAuth`: `iss`,
`sub`, `aud`, `iat`, `exp` in the typed slots; `nonce` and `auth_time` via `addClaim`,
`auth_time` as a JSON number of Unix seconds; same key, `alg`, `kid`), and in the
in-memory fake signer (render the claims as JSON, as the fake already does for access
tokens). Add a `shomei-jwt` test: sign, verify the signature against the public JWK,
assert each claim.

Workflow `shomei-core/src/Shomei/Workflow/OAuthTokenGrant.hs`:

`exchangeAuthorizationCode` — inputs: config plus the form-derived
`{ code, redirectUri, codeVerifier :: Maybe Text, client authentication result }`.
Steps: authenticate the client (confidential: `verifyServiceSecret` against
`secretHash`; public: the `client_id` form field must name a public client — no secret
expected or accepted); `ConsumeAuthorizationCode (sha256Hex code) now` (miss →
`invalid_grant`); the consumed row's `client_id` must equal the authenticated client and
its `redirect_uri` must equal the presented one (else `invalid_grant`); PKCE: if the row
stored a challenge, require `codeVerifier` and check
`base64urlNoPad (sha256 verifier) == challenge` with `Data.ByteArray.constEq`; if the row
stored none (a confidential client that skipped PKCE), a supplied verifier is ignored;
load the user, require `UserActive`; issue the session — extend
`Shomei.Workflow.Session.issueSession` with the optional client binding (add a
`Maybe Text` oauth-client parameter, existing callers passing `Nothing`, or add a sibling
`issueSessionForClient` delegating to a shared core; prefer the parameter so there stays
one issuance path); if the granted scopes include `openid`, sign the ID token with
`nonce`/`authTime` from the row. `issueSession` already publishes
`SessionStarted`/`LoginSucceeded`. Output: access token, refresh token, expires-in,
granted scopes, optional ID token.

`refreshViaOAuth` — authenticate the client the same way, then delegate to the existing
`Shomei.Workflow.refresh` with one added check: the presented token's session must carry
`oauth_client_id == Just thisClient` (mismatch or `Nothing` → `invalid_grant`). Reuse
detection stays entirely inside the existing workflow — do not reimplement it.

Dispatcher: in plan 41's `oauthTokenH` case expression, add `"authorization_code"` and
`"refresh_token"` arms, mapping workflow errors to `oauthError` codes (`invalid_grant`,
`invalid_client`, `invalid_scope`, `invalid_request`). Extend `TokenResponse` with
optional fields `refreshToken :: Maybe Text` (JSON key `refresh_token`) and
`idToken :: Maybe Text` (JSON key `id_token`), omitted when `Nothing` (hand-written
`ToJSON`; update its `ToSchema` and `Arbitrary` accordingly; the client-credentials arm
returns both as `Nothing`).

Tests: full happy path (seed client + user + bearer token, drive authorize in-process,
parse the code from `Location`, exchange with the correct verifier → 200 with all three
tokens; the ID token verifies against the test key and carries `nonce` and
`aud = client_id`); code replay → `invalid_grant` and the second attempt mints nothing;
expired code (advance the in-memory clock past 60 s) → `invalid_grant`; wrong verifier →
`invalid_grant`; verifier absent when a challenge was stored → `invalid_grant`; a
different client exchanging a stolen code → `invalid_grant`; redirect_uri mismatch at
exchange → `invalid_grant`; the refresh grant rotates, and replaying the old refresh
token revokes the family; a refresh token presented by a different client →
`invalid_grant`.

Acceptance for M3: `cabal test shomei-core shomei-servant shomei-jwt` green with the
above.

### Milestone M4 — userinfo, introspection, revocation

Scope: the resource-side endpoints. At the end the revoke→introspect flip is observable.

Routes on `ShomeiAPI`:

```haskell
oauthUserinfo ::
  mode :- "oauth" :> "userinfo" :> Authenticated :> Get '[JSON] Value

oauthIntrospect ::
  mode :- "oauth" :> "introspect" :> Header "Authorization" Text
       :> ReqBody '[FormUrlEncoded] Form :> Post '[JSON] Value

oauthRevoke ::
  mode :- "oauth" :> "revoke" :> Header "Authorization" Text
       :> ReqBody '[FormUrlEncoded] Form :> Post '[JSON] NoContent
```

Userinfo handler: from the `AuthUser`, return an object with `sub` (`idText`), `roles`
and `scopes` (from `authClaims`, possibly empty pre-plan-38), and — after a `UserStore`
lookup — `email` plus `email_verified` when present. It uses the standard `Authenticated`
combinator, so bearer (and later cookie) transports both work, and its 401s are the
ordinary ones.

Introspection handler: client-authenticate via `extractClientAuth`, verifying against
*either* a confidential oauth client or a plan-41 service account — factor a helper
`authenticateOAuthCaller :: Env -> Maybe Text -> Form -> Handler AuthedCaller` in
`Shomei.Servant.OAuth`, shared with revoke. Then: read `token`; run the `TokenVerifier`
effect (the same verification the auth handler uses); on *any* failure return
`{"active": false}` with HTTP 200; on success additionally load the session by the
claims' `sid` and require it unrevoked and unexpired (Decision Log — introspection is
session-aware regardless of `sessionCheckMode`); then respond with the active object
(fields listed in Context and Orientation; `scope` is the space-joined claim scopes;
`username` is the user's login id from a `UserStore` lookup; include `act` as
`{"sub": <actor id>}` when `claims.actor` is set). Also honor
`token_type_hint=refresh_token`: hash the presented token, look it up in
`RefreshTokenStore`, and report `active` from its status plus its session's liveness.

Revocation handler: client-authenticate the same way; read `token` and the optional hint.
Try it as a refresh token first (hash → `findRefreshTokenByHash`): revoke the family
(`revokeRefreshTokenFamily`) and its session (`revokeSession`) — the existing
`SessionRevoked` event fires. Otherwise try to verify it as an access JWT: revoke its
`sid` session and its refresh tokens (`revokeSessionRefreshTokens`). Otherwise do
nothing. Always 200 with an empty body (except failed client authentication → 401
`invalid_client`).

Tests: introspect the M3 access token → `active:true` with correct `sub`/`scope`/`sid`;
introspect garbage → `active:false` (HTTP 200); introspect without client auth → 401;
revoke the refresh token → 200; that refresh token no longer rotates (`invalid_grant`);
introspect the access token again → `active:false` (its session is revoked and
introspection is session-aware); revoke an unknown token → 200; userinfo with the access
token → `sub` matches the ID token's `sub`; userinfo without a token → 401.

Acceptance for M4: `cabal test shomei-servant` green with the above.

### Milestone M5 — OpenAPI, docs, end-to-end conformance

Scope: spec, documentation, and the automated transcript.

OpenAPI: add `ToSchema` instances (or `Value`-typed free-form schemas, following the
existing `Value` instance) for the new response shapes, `HasOpenApi` coverage for the new
routes, update the conformance suite's hard-coded path count (five new paths on top of
plan 41's count — recount at implementation time and record the number in Progress),
extend `Arbitrary` instances for changed DTOs (`TokenResponse` gained optional fields),
and regenerate `docs/api/openapi.json` with
`cabal run shomei-openapi > docs/api/openapi.json`.

Docs: write `docs/user/oidc.md` — enabling OIDC (`oidcEnabled`, the
issuer-as-base-URL requirement, `loginUrl`), registering clients with the CLI, the
headless authorize contract with a walk-through for the three consumer classes
(server-side RP, SPA, native), the PKCE requirement, refresh semantics,
introspection/revocation including the `sessionCheckMode` caveat verbatim, and a worked
oauth2-proxy-style configuration example (issuer URL + client id + secret only). Update
`docs/user/api.md`'s endpoint list and `docs/user/security.md` with the
revocation-visibility caveat.

E2E: extend `shomei-server/test/Shomei/Server/E2ESpec.hs` with the full transcript
against real Postgres and Warp: create a confidential client (through the store or the
Admin module), signup + login a user, GET authorize with the bearer token (`http-client`
with redirects disabled), parse `code` from `Location`, POST the token exchange with a
locally computed S256 verifier pair, verify the ID-token signature against the served
JWKS document, GET userinfo, POST introspect (`active:true`), POST revoke, POST
introspect (`active:false`).

Acceptance for M5: `cabal test all` green; `git diff docs/api/openapi.json` shows exactly
the new surface; the manual transcript in Validation reproduces.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. Confirm plan 41
has landed before starting:

```bash
grep -n "oauthToken" shomei-servant/src/Shomei/Servant/API.hs
cabal test shomei-core shomei-servant
```

Expected: the route field exists and the baseline suites pass. Then per milestone:

```bash
# M1
just new-migration name=shomei-oauth-clients
just create-database
cabal test shomei-core shomei-postgres shomei-server

# M2
just new-migration name=shomei-oauth-authorization-codes
just create-database
cabal test shomei-core shomei-servant

# M3
just new-migration name=shomei-sessions-oauth-client
just create-database
cabal test shomei-core shomei-servant shomei-jwt shomei-postgres

# M4
cabal test shomei-servant

# M5
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json
nix fmt
cabal build all
cabal test all
```

Expected final output: every suite passes; the OpenAPI diff adds exactly
`/.well-known/openid-configuration`, `/oauth/authorize`, `/oauth/userinfo`,
`/oauth/introspect`, `/oauth/revoke`, plus the widened `/oauth/token` response schema.

A PKCE verifier pair for manual testing:

```bash
verifier=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=' | cut -c1-64)
challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
echo "verifier=$verifier"; echo "challenge=$challenge"
```


## Validation and Acceptance

The acceptance is the end-to-end transcript, runnable by hand against a local server
started with `SHOMEI_OIDC_ENABLED=true SHOMEI_ISSUER=http://localhost:8080` after
`just create-database`:

```bash
# 1. Register a client (secret printed once; capture $CID/$CSECRET)
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shomei-admin -- oauth-clients create \
  --display-name demo --type confidential \
  --redirect-uri http://localhost:9999/callback --scope openid --scope profile

# 2. Sign up and log in a user (docs/user/api.md); capture the access token as $TOKEN

# 3. Authorize (authenticated) — expect 302
curl -si -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/oauth/authorize?response_type=code&client_id=$CID&redirect_uri=http://localhost:9999/callback&scope=openid%20profile&state=xyz&nonce=n-0S6&code_challenge=$challenge&code_challenge_method=S256"
```

Expected:

```text
HTTP/1.1 302 Found
Location: http://localhost:9999/callback?code=<opaque>&state=xyz&iss=http%3A%2F%2Flocalhost%3A8080
```

```bash
# 4. Exchange — expect 200 with three tokens
curl -s -u "$CID:$CSECRET" \
  -d "grant_type=authorization_code&code=$CODE&redirect_uri=http://localhost:9999/callback&code_verifier=$verifier" \
  http://localhost:8080/oauth/token | jq 'keys'
# -> ["access_token","expires_in","id_token","refresh_token","scope","token_type"]

# 5. The id_token verifies against /.well-known/jwks.json; iss/aud/nonce as sent.

# 6. Userinfo
curl -s -H "Authorization: Bearer $AT" http://localhost:8080/oauth/userinfo | jq .sub
# -> "user_01..."   (same sub as the id_token)

# 7. Introspect — active
curl -s -u "$CID:$CSECRET" -d "token=$AT" http://localhost:8080/oauth/introspect | jq .active
# -> true

# 8. Revoke the refresh token — 200 empty
curl -s -o /dev/null -w '%{http_code}\n' -u "$CID:$CSECRET" \
  -d "token=$RT&token_type_hint=refresh_token" http://localhost:8080/oauth/revoke
# -> 200

# 9. Introspect again — inactive (session revoked)
curl -s -u "$CID:$CSECRET" -d "token=$AT" http://localhost:8080/oauth/introspect | jq .active
# -> false
```

Also observable: replaying step 4's code returns 400 `{"error":"invalid_grant",...}`; a
wrong verifier does too; an unauthenticated step 3 with `SHOMEI_OAUTH_LOGIN_URL` set 302s
to that URL with a decodable `return_to`, and re-entering the decoded URL with a valid
token succeeds; and with `oidcEnabled=false` the discovery document is 404 while every
pre-existing route is untouched. The same transcript runs automatically in the E2E suite;
`cabal test all` is the automated gate.

Failure modes a novice can diagnose: 415 at the token endpoint means the body was not
form-encoded; an application-envelope error (`{"error":...,"message":...}`) at any
`/oauth/*` path means a handler leaked past `oauthError`; `active:false` for a
just-minted token usually means introspection's session lookup used the wrong `sid`.


## Idempotence and Recovery

All schema changes are additive (`IF NOT EXISTS`, plus one nullable column on
`shomei_sessions`), so `just migrate` re-runs safely and existing rows/flows are
untouched — sessions with `oauth_client_id NULL` behave exactly as before. With
`oidcEnabled = False` (the default) the entire new surface is inert, so deploying the
code before enabling it is safe; enabling is a config flip.

The `embedDir` caveat applies to every new migration: if a Postgres-backed test fails
with SQLSTATE 42P01/42703, run `just migrate` (it touches the migrations cabal file to
force re-embedding) before rebuilding.

The `Session`/`NewSession` field addition is the one change that touches existing code
paths; the compiler enumerates every construction site. If a test constructs `NewSession`
positionally, convert it to record syntax rather than guessing field order.

Milestones land independently — M1 alone (discovery + clients) is shippable and harmless;
M2 without M3 leaves codes nothing can exchange (they expire in 60 seconds; wire
`DeleteExpiredAuthorizationCodes` into the expired-data sweeper if
`docs/plans/34-...` has landed, otherwise leave it exported and note it). If M3 must be
rolled back after deployment, flip `oidcEnabled` off: codes stop being issued and the new
grant arms are unreachable without authorize.

Never weaken the two validation regimes at authorize while debugging: an error redirect
to an *unvalidated* redirect_uri is an open redirector. If a test wants to observe an
error for an unknown client, it must expect 400, not 302.


## Interfaces and Dependencies

Hard dependency: plan 41's `Shomei.Servant.OAuth` (`oauthError`, `extractClientAuth`,
`TokenResponse`), the `oauthToken` dispatcher in `Handlers.hs`, and
`Shomei.Workflow.ServiceToken.sha256Hex`/`verifyServiceSecret`. Soft dependencies: plan
38's claims enrichment (consumed transparently through `issueSession`); plan 31's cookie
transport (consumed transparently through the shared authentication core factored out of
`Shomei.Servant.Auth`).

Project-local interfaces used: `Shomei.Workflow.Session.issueSession` (extended with an
optional client binding), `Shomei.Workflow.refresh` (unchanged rotation/reuse core),
`Shomei.Effect.SessionStore.revokeSession`,
`Shomei.Effect.RefreshTokenStore.{findRefreshTokenByHash, revokeRefreshTokenFamily, revokeSessionRefreshTokens}`,
`Shomei.Effect.TokenGen.generateOpaqueToken`, `Shomei.Effect.TokenVerifier`,
`Shomei.Id` (new `OAuthClientId`), `Shomei.Domain.Event`/`EventCodec` (new
`OAuthClientCreated`, `OAuthClientRevoked`, `OAuthCodeIssued` events),
`Shomei.Jwt.Sign` (new `claimsFromIdToken` beside `claimsFromAuth`), and the three
effect-stack lists that must stay ordered identically
(`Shomei.Servant.Seam.AppEffects`, `Shomei.Server.App.AppEffects`/`runAppIO`,
`Shomei.Effect.InMemory.runInMemory`).

End-of-milestone interfaces: after M1 — `Shomei.Effect.OAuthClientStore` (four
operations), `Shomei.Config.OAuthConfig`, the `oidcDiscovery` route; after M2 —
`Shomei.Effect.OAuthCodeStore` (three operations, atomic consume),
`Shomei.Workflow.OAuthAuthorize`, the `oauthAuthorize` route, and the exported shared
authentication core in `Shomei.Servant.Auth`; after M3 —
`Shomei.Domain.IdTokenClaims`, `SignIdToken` on `TokenSigner`,
`Shomei.Workflow.OAuthTokenGrant.{exchangeAuthorizationCode, refreshViaOAuth}`, and the
widened `TokenResponse`; after M4 — the `oauthUserinfo`/`oauthIntrospect`/`oauthRevoke`
routes and `authenticateOAuthCaller` in `Shomei.Servant.OAuth`.

No new third-party dependencies beyond plan 41's (`http-api-data`, `base64` in
`shomei-servant`); PKCE hashing uses `crypton` (`Crypto.Hash`, SHA256) already in
`shomei-core`. Downstream, plan 43 relies on this plan only softly — for introspection
returning consistent `act` fields on exchanged tokens — and registers its own grant in
the same dispatcher.
