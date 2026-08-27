---
id: 51
slug: bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize
title: "Bind Sessions to Their Provenance and Refuse Non-Interactive Tokens at OAuth Authorize"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Bind Sessions to Their Provenance and Refuse Non-Interactive Tokens at OAuth Authorize

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit: it issues sessions, signs access tokens, and — when
its OpenID Connect provider is switched on — lets a registered client obtain a session for a
logged-in user through the standard authorization-code flow (`GET /oauth/authorize` hands the
browser a one-time code; `POST /oauth/token` exchanges it for tokens). The August 2026 security
review (`docs/reviews/project-security-and-performance-baseline.md`, finding 1, graded critical)
found that this flow accepts *any* token that verifies. An operator holding a delegated
impersonation token for customer C (30 minutes, no refresh token, no roles, an `act` claim naming
the operator) can present it at `/oauth/authorize`, receive a code, and exchange that code for a
brand-new 30-day refreshable session *as C* carrying C's full roles and permissions and no `act`.
The same chain launders a service's on-behalf-of token and a five-minute `client_credentials`
token. Every guard that keys on `act` — the credential-change refusals, the admin-mutation
refusals — is then gone, and every downstream that trusts `sub` sees C acting alone.

After this plan, four things a user or integrator can observe are true:

First, a session records how it was established. Every row in `shomei_sessions` carries a `kind`
of `interactive`, `machine`, or `delegated`, and every place in the code that creates a session
says which one it is making.

Second, `GET /oauth/authorize` issues a code only to a live, interactive session. A token that
carries `act`, a `client_credentials` token, or a token whose session is anything but a live
interactive one is answered `401` in the OAuth error shape (`{"error":"login_required",…}`) with
no `Location` header and no code minted — never bounced to the host's login page. A revoked or
expired session is treated as "not logged in" regardless of `sessionCheckMode`.

Third, RFC 8693 token exchange and impersonation see a revoked session or a suspended operator
immediately — again regardless of `sessionCheckMode` — because minting new privilege always
consults the session store, exactly as introspection already does.

Fourth, the authorization-code exchange honours `emailVerificationRequired` like every other
token-issuing path, closing the loop by which an unverified account could renew forever through
authorize → exchange without ever refreshing.

The proof is a servant end-to-end test that drives the exact chain the review described
(impersonate → authorize → exchange). Run against today's code it fails at the authorize step
with a `302` carrying a code; after this plan it passes with a `401` and an empty code store.
This plan also writes the repository's first Architecture Decision Record, because "only an
interactive session may authorize a client" is a durable boundary later plans must respect.

Out of scope, and owned by `docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md`:
refusing OAuth-minted refresh tokens at the bespoke `POST /v1/auth/refresh`, persisting the scopes
an authorization grant conferred, the reserved privilege-scope list, and ownership checks at
`POST /oauth/revoke`. This plan does not touch those and does not need them.


## Progress

- [x] (2026-08-27 13:57Z) M1: `SessionKind` in `Shomei.Session.Domain`; `kind` on `Session` and `NewSession`; codec, PostgreSQL interpreters, in-memory fake, and `persistNewSession` carry it
- [x] (2026-08-27 13:57Z) M1: migration `0029-sessions-kind.sql` allocated with `just new-migration sessions-kind`; 29-entry manifest check green
- [x] (2026-08-27 13:57Z) M1: every `NewSession {` construction site names its kind (four production sites, seven original `shomei-postgres` test sites); PostgreSQL round-trip tests cover all three kinds and NULL-reads-as-interactive
- [x] (2026-08-27 13:57Z) M1: `cabal build all --enable-tests` and `cabal test shomei-core shomei-postgres` green (228 core tests, 58 PostgreSQL tests); committed
- [x] (2026-08-27 14:07Z) M2: servant scenarios `scenarioNoLaunderingThroughAuthorize` and `scenarioAuthorizeProvenance` written first and run against pre-fix code; the 302-versus-401 failure transcript recorded in Surprises & Discoveries
- [x] (2026-08-27 14:07Z) M2: `requireLiveSession` in `Shomei.Session.Workflow`; `AuthorizeLoginRequired` in `Shomei.OAuth.Authorize.Workflow`; `authorize` refuses `act`, non-interactive kinds, and dead sessions
- [x] (2026-08-27 14:07Z) M2: `oauthAuthorizeH` answers `401 login_required` with no redirect for a non-interactive credential and treats a dead session as unauthenticated
- [x] (2026-08-27 14:07Z) M2: core `Shomei.OAuth.Authorize.WorkflowSpec` covers interactive, machine, delegated, `act`, revoked, expired, and unknown sessions; `OAuthCodeStoreSpec.runAuthorize` seeds a session; 236 core tests and 37 servant scenarios green; committed
- [ ] M3: `verifyTokenWith` in `Shomei.Session.Authentication.Workflow`; token exchange verifies subject and actor tokens with `VerifyTokenAndSession`; `startImpersonation` requires a live operator session and an active operator
- [ ] M3: `exchangeAuthorizationCode` calls `ensureEmailVerified`; new `Shomei.OAuth.TokenGrant.WorkflowSpec`
- [ ] M3: fixtures that hand-mint tokens now bind them to real sessions (core `TokenExchange.WorkflowSpec`, core `Delegation.WorkflowSpec`, servant `Main.hs`, server `E2ESpec.hs`); new refusal tests; `scenarioExchangeRequiresLiveSessions`; committed
- [ ] M4: `docs/user/security.md`, `docs/user/oidc.md`, `docs/user/machine-tokens.md` updated; per-package changelogs carry an Unreleased entry
- [ ] M4: `docs/adr/` bootstrapped as a profile-governed bundle; ADR-1 allocated with `okf id next` and validated with `okf validate --strict`; `mori.dhall` and `Justfile` updated
- [ ] M4: `cabal test all -j1` green; MasterPlan 8 registry row and Progress boxes for EP-1 updated; Outcomes & Retrospective written; committed


## Surprises & Discoveries

- Observation: The two servant regressions fail on the M1 commit at exactly the reviewed seam,
  while all 35 pre-existing end-to-end cases remain green.
  Evidence: `cabal test shomei-servant` on 2026-08-27 reported

  ```text
  an impersonation token cannot be laundered into a user session through authorize + code exchange: FAIL
    delegated bearer at authorize: status
    expected: 401
     but got: 302
  GET /oauth/authorize accepts only a live interactive session: FAIL
    client_credentials bearer at authorize: status
    expected: 401
     but got: 302
  ```

  The 302 is a redirect to the registered client carrying a newly minted authorization code,
  proving that both a delegated credential and a machine credential reach the vulnerable code
  mint rather than merely failing elsewhere in the test setup.


## Decision Log

- Decision: The session-kind vocabulary is `InteractiveSession`, `MachineSession`, and
  `DelegatedSession`, stored as `interactive`, `machine`, and `delegated`.
  Rationale: The three names answer the one question every guard in this plan asks — "was a
  human's credential proven to establish this session?" — and nothing more. *Interactive* is a
  session established by a human proving a password, a passkey, or a second factor, or by
  exchanging an authorization code that such a session authorized (after this plan a code cannot
  come from anywhere else, so the exchange inherits interactivity). *Machine* is `client_credentials`:
  a service acting as itself, no human involved. *Delegated* is any session whose token carries
  `act` — impersonation and RFC 8693 on-behalf-of alike, which already share one mint,
  `Shomei.Delegation.Workflow.mintDelegatedToken`. Finer distinctions (which second factor, which
  grant) are recoverable from the audit trail and would only make the authorize check harder to
  read. The `…Session` suffix follows `SessionActive`/`SessionRevoked` in the same module.
  Date: 2026-08-27

- Decision: A non-interactive credential at `GET /oauth/authorize` is answered `401` with the
  OAuth-shaped body `{"error":"login_required","error_description":"an interactive login session is required to authorize a client"}`,
  `Cache-Control: no-store`, and no `Location` header — whether or not `oauthLoginUrl` is
  configured. A missing, revoked, or expired session is instead treated exactly as no credential
  at all: a redirect to `oauthLoginUrl` when one is configured, else the existing
  `401 login_required`.
  Rationale: Bouncing a delegated or machine caller to the login page would be wrong twice over:
  the caller is not a browser (a browser never carries a bearer token), and a redirect would
  suggest that logging in is the fix, when the fix is to not use that credential here. `login_required`
  is OIDC Core §3.1.2.6's own name for "the authorization server requires end-user
  authentication", which is precisely the situation, and reusing the code the endpoint already
  emits keeps the client-facing vocabulary at one word. A dead session, by contrast, *is* the
  "not logged in" case — the session-mode test `scenarioAuthorizeRejectsRevokedSession` already
  pins that answer — so it keeps that behavior and now gets it in both `sessionCheckMode`s.
  Date: 2026-08-27

- Decision: `authorize` always reads the caller's session from the store, regardless of
  `sessionCheckMode`, and refuses when it is missing, revoked, or past `expiresAt`.
  Rationale: The kind lives on the session row, so the read is needed anyway; charging one more
  predicate on the row it already holds costs nothing. Minting a code is a privilege operation —
  it produces a fresh, refreshable, fully enriched session — and the review's verified-holds list
  notes the revoked-session refusal at authorize was tested only under `VerifyTokenAndSession`.
  This mirrors `POST /oauth/introspect`, which the Decision Log of the OIDC plan already made
  session-aware in every mode.
  Date: 2026-08-27

- Decision: Token exchange and impersonation verify with the session policy *forced* to
  `VerifyTokenAndSession`, through a new mode-parameterized form of the existing session-aware
  verifier (`Shomei.Session.Authentication.Workflow.verifyTokenWith`), of which the config-aware
  `verifyToken` becomes a one-line wrapper. Impersonation additionally requires the operator's
  user row to be active.
  Rationale: MasterPlan 8, Integration Point 3, gives this plan ownership of *which* workflows
  call *which* verifier and forbids a third verification path. Parameterizing the one
  session-aware verifier by mode adds no path: the JWS check, the liveness predicate, and the
  error vocabulary stay in one place. The alternative — calling the config-aware `verifyToken` —
  would make the fix disappear in the default `VerifyTokenOnly` deployment, which is exactly the
  deployment the review graded. The liveness predicate itself is factored into
  `Shomei.Session.Workflow.requireLiveSession` so `authorize`, `verifyTokenWith`, and
  `startImpersonation` cannot drift on what "live" means. In impersonation mode the operator's
  session is read twice (once by the exchange's verifier, once by `startImpersonation`); the
  second read is kept because `startImpersonation` is also the guard for library callers that
  hand it already-verified claims, and one extra read on a rare privileged operation is cheap.
  Date: 2026-08-27

- Decision: `exchangeAuthorizationCode` refuses an unverified account with the existing
  `GrantInvalidGrant` (wire: `invalid_grant`, the one generic description), not a new error code.
  Rationale: The caller at `POST /oauth/token` is the client application, not the user; the
  application-envelope decision that made `email_not_verified` a distinct 403 (plan 30) was about
  not stranding a *user*. The user will meet that 403 the moment they log in again. Adding an
  OAuth error code that RFC 6749 does not define would buy the client nothing it can act on.
  Date: 2026-08-27

- Decision: The `kind` column is `text NULL DEFAULT 'interactive'`, read as `interactive` when
  NULL, always written explicitly by the interpreter, with no `CHECK` constraint and no index.
  Rationale: MasterPlan 8, Integration Point 1, prescribes nullable-with-default so every
  pre-existing row reads as the pre-change value and so EP-2's column can land in either order.
  A nullable column with a default is a metadata-only change in PostgreSQL (no table rewrite),
  and a binary built before this plan keeps inserting successfully after the migration because
  its `INSERT` names no `kind`. The interpreter refuses an unknown value on read exactly as it
  refuses an unknown `status`; `docs/plans/55-atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails.md`
  owns `CHECK` constraints on status-like columns and should include this one. Nothing looks a
  session up by kind, so no index.
  Date: 2026-08-27

- Decision: The servant handler refuses a token carrying `act` before calling the workflow, in
  addition to the workflow's own refusal.
  Rationale: MasterPlan 8's Progress entry for EP-1 asks for the refusal "in core and at the
  handler". The handler check costs no store read and mirrors `denyUnderDelegation`, which every
  mutation route applies; the core check is the guard a library embedder gets without the HTTP
  layer. Two layers, one rule.
  Date: 2026-08-27

- Decision: `docs/adr/` is bootstrapped as an OKF bundle governed by the shared
  `documentation.architectureDecisions` profile (pinned to a published `okf-profiles` tag),
  with `index.md`, `log.md`, a `mori.dhall` entry, and a `just adr-validate` recipe, and ADR-1
  is allocated with `okf id next`.
  Rationale: `.claude/skills/exec-plan/ADR.md` says to preserve an established filesystem
  convention when no profiled bundle exists; this repository has *no* ADR convention of any kind
  (`docs/adr/` does not exist), while its three existing documentation bundles
  (`improvement-requests`, `capabilities`, `reviews`) are all profile-governed, and the reviews
  bundle was bootstrapped by hand in commit `ee00382` with exactly these five pieces. Following
  that precedent is the repository's convention. If `okf` or the profile pin cannot be made to
  work on the implementer's machine, fall back to a bare `docs/adr/0001-<slug>.md` with the same
  frontmatter and record the fallback here.
  Date: 2026-08-27

- Decision: The admin session listing (`SessionResponse` in `shomei-servant/src/Shomei/Session/Dto.hs`)
  does not expose `kind`, and no audit event is published for a refused authorize.
  Rationale: Both would be useful and both are additive later; each changes a public surface
  (`docs/api/openapi.json` and the audit-event codec) with its own conformance test, which is
  scope this security fix does not need. `docs/plans/60-reconcile-the-user-documentation-and-the-en-integration-story-with-the-code.md`
  or a later plan can add them.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project built inside a Nix devshell. Every command in
this plan runs from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.
The packages this plan touches are `shomei-core` (the domain: records, workflows, and *ports* —
`effectful` effect interfaces such as `SessionStore` and `TokenVerifier` that name a capability
without saying how it is provided — plus a complete in-memory interpreter of every port in
`shomei-core/src/Shomei/Test/InMemory.hs`, whose mutable `World` record the tests read and
mutate directly), `shomei-postgres` (the PostgreSQL interpreters of those ports, using `hasql`),
`shomei-migrations` (the ordered SQL manifest in `shomei-migrations/migrations/shomei/`, embedded
at compile time and driven by the `shomei-migrate` executable), and `shomei-servant` (the HTTP
layer). Tests are tasty + tasty-hunit. Core workflow tests run against the in-memory
interpreter; `shomei-postgres` tests provision an ephemeral PostgreSQL per case; the servant suite
in `shomei-servant/test/Main.hs` boots the real Servant tree over the in-memory stores with a real
ES256 key, so its scenarios are genuine HTTP round trips.

Architecture Decision Records: this repository has **no** `docs/adr/` directory and no ADR
bundle (checked at HEAD `5dfd2a6`; `mori.dhall` declares only `improvement-requests`,
`capabilities`, and `reviews` under `okfBundles`, lines 346–371). No local ADR applies to this
work. MasterPlan 8 names the decision this plan makes — session provenance as the boundary
between interactive and non-interactive credentials, and the rule that only interactive sessions
may authorize — as one that deserves an ADR, and assigns creating `docs/adr/` on first use to
this plan; Milestone M4 does that. The cross-repository records MasterPlan 8 cites
(`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-1` and `IR-2`) concern scoped
service-token issuance and diagnostic identities and constrain EP-2's scope policy, not this
plan.

The review evidence for this plan's scope is `docs/reviews/shomei-core-security-and-performance.md`
(REV-2: finding 1, critical; finding 3, stateless exchange and delegation; finding 18, the email
gate; and the "Verified holds" list, which this plan must not regress),
`docs/reviews/shomei-servant-security-and-performance.md` (REV-7: finding 1), and
`docs/reviews/project-security-and-performance-baseline.md` (REV-1: finding 1 and the trust
model — every downstream, including the `en` authorization service, maps a subject to
`user:<JWT sub>` and trusts `act`, `roles`, `scopes`, and `permissions` exactly as Shōmei signs
them). All line numbers below are as of HEAD `5dfd2a6`, whose code is identical to the reviewed
commit `ee00382`.

### The vocabulary this plan uses

A **session** is a server-side row (`shomei_sessions`) recording one authenticated login, with an
absolute `expires_at` and a `status` of `active`, `revoked`, or `expired`. An **access token** is
a signed JWT naming the user (`sub`), the session (`sid`), scopes, roles, permissions, and —
only on a **delegated token** — an `act` claim naming the real operator acting on the subject's
behalf. A **refresh token** is an opaque secret bound to a session that rotates for a new access
token; delegated and machine sessions deliberately have none, so they die at their TTL. A
**machine token** is what the `client_credentials` grant issues to a service account acting as
itself. An **authorization code** is a 60-second single-use secret that `GET /oauth/authorize`
hands to a browser and `POST /oauth/token` (grant `authorization_code`) redeems, with **PKCE**
(the client proves it started the flow by presenting the preimage of a hash it sent earlier).
`sessionCheckMode` is a configuration switch: `VerifyTokenOnly` (the default) verifies access
tokens by signature alone; `VerifyTokenAndSession` also reads the session row on every request.
A **unit of work** (`Shomei.Session.UnitOfWork.Store.AuthUnitOfWork`) is the port whose
`persistNewSession` writes a session, its first refresh token, and the audit events in one
transaction.

### Where sessions are minted today

Every session begins as a `NewSession` value (`shomei-core/src/Shomei/Session/Domain.hs`, lines
36–46: `userId`, `createdAt`, `expiresAt`, `actor :: Maybe UserId`, `oauthClientId :: Maybe Text`)
and becomes a `Session` (lines 17–34, the same fields plus `sessionId`, `status`, `revokedAt`).
`grep -rn "NewSession" --include='*.hs'` finds exactly four production construction sites and
seven test sites, and this plan touches every one:

1. `shomei-core/src/Shomei/Session/Authentication/Workflow.hs`, line 160, in `signup` — a human
   just chose a password: **interactive**.
2. `shomei-core/src/Shomei/Session/Workflow.hs`, line 187, in `issueSessionWith` — the shared
   tail behind password login (`login`), second-factor completion (`Shomei.Mfa.Workflow.completeMfa`),
   passwordless passkey login (`completePasswordlessLogin`), and the authorization-code exchange
   (`Shomei.OAuth.TokenGrant.Workflow.exchangeAuthorizationCode`, lines 170–175): **interactive**.
   There is no `NewSession` literal in `Shomei/Mfa/Workflow.hs`; both completions reach this site.
3. `shomei-core/src/Shomei/Delegation/Workflow.hs`, line 143, in `mintDelegatedToken` — the one
   mint behind impersonation (`startImpersonation`) and RFC 8693 on-behalf-of
   (`Shomei.OAuth.TokenExchange.Workflow.onBehalfOfMode`); note `actor = Just mint.actorUserId`
   at line 147: **delegated**.
4. `shomei-core/src/Shomei/ServiceAccount/ClientCredentials/Workflow.hs`, line 99, in
   `grantClientCredentials`: **machine**.
5. `shomei-postgres/test/Main.hs`, lines 902, 903, 904, 941, 963, and 980 (ordinary sessions:
   **interactive**) and lines 955–961 (a session with `actor = Just operator.userId`:
   **delegated**).

The PostgreSQL interpreter is `shomei-postgres/src/Shomei/Session/Postgres.hs`: `SessionRow` is
an 8-tuple (line 34), `CreateSession` builds the row at lines 44–53, `mkSession` (74–85) and
`rebuildSession` (87–100) convert, `sessionRowDecoder` (102–112) decodes, `insertSessionStmt`
(114–132) names eight columns, and the two `SELECT`s at lines 140 and 152 list them.
`shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs` reuses `insertSessionStmt` inside
the `persistNewSession` transaction and builds its tuple in `sessionRow` (lines 110–120). The
status enum's text codec lives in `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs`
(`sessionStatusToText`/`sessionStatusFromText`, lines 52–63). The in-memory fake converts in
`mkSession` at `shomei-core/src/Shomei/Test/InMemory.hs` lines 438–449. The table was created by
`shomei-migrations/migrations/shomei/0004-shomei-sessions.sql`; `0025-shomei-sessions-oauth-client.sql`
is the model for adding a nullable column, and the manifest's last line is
`0028-shomei-role-permissions.sql`. Migrations are allocated with `just new-migration <slug>`
(Justfile lines 36–42), which computes the next number from the manifest and calls
`shomei-migrate new`, which creates the file and appends it to the manifest in one step. Never
hand-number.

### The laundering chain, line by line

`GET /oauth/authorize` is `oauthAuthorizeH` in `shomei-servant/src/Shomei/OAuth/Handler.hs`
(lines 127–223). After validating `client_id` and `redirect_uri` (the no-redirect regime, lines
143–151), it authenticates with `resolveAuthUser` (line 167; defined in
`shomei-servant/src/Shomei/Servant/Auth.hs` lines 246–258), which accepts any token
`verifyRequestToken` accepts — and `authUserFromClaims` (lines 164–173) copies `claims.actor`
into the principal without looking at it. With a user, the handler calls the core workflow (line
173) and redirects with the code (186–193). The core, `Shomei.OAuth.Authorize.Workflow.authorize`
(`shomei-core/src/Shomei/OAuth/Authorize/Workflow.hs`, lines 127–168), validates `response_type`,
PKCE, and scope, then stores a code whose `userId = claims.subject` (line 151). The module never
mentions `actor`. Its error type `AuthorizeError` (lines 69–76) has three constructors, every one
of which the handler renders as an *error redirect* to the validated `redirect_uri`. At the
exchange, `exchangeAuthorizationCode` (`shomei-core/src/Shomei/OAuth/TokenGrant/Workflow.hs`,
lines 138–180) checks the user is active (165–168) and calls `issueSessionWith` (170–175), which
persists a session with `actor = Nothing` (Session/Workflow.hs line 191), a refresh token
(194–198), and claims from `buildEnrichedClaims` (203) — the subject's stored roles and
permissions. Nothing in the chain ever asks what kind of token started it.

### The stateless verifications

`Shomei.OAuth.TokenExchange.Workflow.verifyToken` (`shomei-core/src/Shomei/OAuth/TokenExchange/Workflow.hs`,
lines 272–277) is `verifyAccessToken` alone — the pure JWS check from
`Shomei.SigningKey.Verifier` — although `SessionStore` is in `exchangeToken`'s constraint (line
121) and never consulted. `Shomei.Delegation.Workflow.startImpersonation`
(`shomei-core/src/Shomei/Delegation/Workflow.hs`, lines 57–105) checks the caller's scope (72),
the caller token's freshness (74), self-targeting (76), and the *target's* existence and status
(78–79) — never the caller's own session or status. Contrast
`Shomei.Session.Authentication.Workflow.verifyToken` (`shomei-core/src/Shomei/Session/Authentication/Workflow.hs`,
lines 450–469), the one session-aware verifier: it reads the session under
`VerifyTokenAndSession` and maps a dead one to `SessionNotFound`/`SessionExpired`/`SessionRevoked`.
The HTTP layer reaches it through `Shomei.Servant.Seam.verifyRequestToken`. Introspection
(`oauthIntrospectH`, Handler.hs lines 517–537) already reads the session in every mode with its
own `sessionIsLive` predicate (line 635).

The email gate is `Shomei.Session.Workflow.ensureEmailVerified` (`shomei-core/src/Shomei/Session/Workflow.hs`,
lines 55–61), called by `login` (Authentication/Workflow.hs line 267), `refresh` (384), and both
MFA completions (Mfa/Workflow.hs lines 178 and 303) — and not by `exchangeAuthorizationCode`.

### Tests that hand-mint tokens

Several existing tests sign an access token by hand with a *random* session id and present it
to token exchange or impersonation. After Milestone M3 such a token is refused (its session does
not exist), so those fixtures must mint tokens bound to real sessions. They are:
`shomei-core/test/Shomei/OAuth/TokenExchange/WorkflowSpec.hs` (`freshOperatorToken`, lines 100–105,
and every `usid <- genSessionId` subject session); `shomei-core/test/Shomei/Delegation/WorkflowSpec.hs`
(`freshOperator`, lines 86–90); `shomei-core/test/Shomei/OAuthCodeStoreSpec.hs` (`runAuthorize`,
lines 199–221, builds claims for a session that does not exist — affected by M2, not M3);
`shomei-servant/test/Main.hs` (`mkImpersonatorToken`, lines 401–422, whose `impToken` and
`staleImpToken` feed `scenarioTokenExchange`); and `shomei-server/test/Shomei/Server/E2ESpec.hs`
(lines 140–163, `opSid <- genSessionId` for the operator). Tokens hand-minted for routes behind
the `Authenticated` combinator (`mkTokenFor` in the admin and TOTP scenarios) are unaffected:
the auth handler stays config-aware.

Helpers the new servant scenarios reuse, all in `shomei-servant/test/Main.hs`: `signupTokenAndId`
(line 1603), `verifyIdToken` (2202, returns a claims map for any JWT signed by the test key),
`parseUserId` (301), `revokeAllSessionsOf` (309), `defineRoleIn` (319), `grantRoleIn` (339),
`seedOAuthClients` (1519, one confidential and one public client), `seedExchangeAccount` (579, a
service account whose secret is `oauthClientSecret`), `getNoRedirect` (1567), `locationOf`
(1578), `authorizeUrl` (1564), `assertOAuthError` (1259), `postForm` (1247), `bearer` (3112), and
`pkceChallengeFor` from `Shomei.OAuth.TokenGrant.Workflow`. Core specs reuse `runInMemory`,
`emptyWorld`, and `World` from `Shomei.Test.InMemory`.


## Plan of Work

Four milestones, in order. M1 is the data-model change everything else reads; M2 closes the
critical finding; M3 closes the two stateless verifications and the email gate; M4 writes the
documentation and the ADR. Each milestone ends in a commit whose message is spelled out in
Concrete Steps.

### Milestone M1 — every session knows how it was established

Scope: after this milestone `Session` and `NewSession` carry `kind :: SessionKind`, the column
exists with a default, both interpreters and the fake round-trip it, and each of the eleven
construction sites names its kind. Nothing refuses anything yet; the whole existing suite stays
green, which is the point — this is the additive half.

Add the type and the fields in `shomei-core/src/Shomei/Session/Domain.hs`. Export `SessionKind (..)`
from the module header (lines 3–8) and insert the type after `SessionStatus`:

```haskell
-- | How a session was established. This is the provenance every privilege-minting operation
-- consults: only an 'InteractiveSession' may authorize an OAuth client (see
-- 'Shomei.OAuth.Authorize.Workflow.authorize'), and the audit trail can tell a login from a
-- machine credential from a delegation without decoding a token.
data SessionKind
  = -- | a human proved a credential — password, passkey, or second factor — or exchanged an
    -- authorization code that such a session authorized (the exchange inherits interactivity,
    -- because after plan 51 a code can be minted by nothing else)
    InteractiveSession
  | -- | @client_credentials@: a service acting as itself. No human, no refresh token.
    MachineSession
  | -- | a session whose access token carries @act@: impersonation and RFC 8693 on-behalf-of,
    -- both minted by 'Shomei.Delegation.Workflow.mintDelegatedToken'. No refresh token.
    DelegatedSession
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Then add, as the *last* field of both `Session` (after `oauthClientId`, line 31) and `NewSession`
(after `oauthClientId`, line 43), `kind :: !SessionKind` with a one-line haddock ("how this
session was established; see 'SessionKind'"). Keep it last: EP-2 will append `grantedScopes` after
it and must not reorder.

Teach the codec: in `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs`, widen the import
on line 31 to `Shomei.Session.Domain (SessionKind (..), SessionStatus (..))`, export
`sessionKindToText` and `sessionKindFromText` beside the status pair (lines 8–9), and add after
line 63:

```haskell
sessionKindToText :: SessionKind -> Text
sessionKindToText = \case
  InteractiveSession -> "interactive"
  MachineSession -> "machine"
  DelegatedSession -> "delegated"

sessionKindFromText :: Text -> Either Text SessionKind
sessionKindFromText = \case
  "interactive" -> Right InteractiveSession
  "machine" -> Right MachineSession
  "delegated" -> Right DelegatedSession
  t -> Left ("unknown session kind: " <> t)
```

Teach the PostgreSQL session interpreter, `shomei-postgres/src/Shomei/Session/Postgres.hs`. The
row grows a ninth, nullable text column. Change the import on line 17 to
`Contravariant.Extras (contrazip2, contrazip9)` (the repository already uses arities up to
`contrazip10`), the import on line 28 to also bring `sessionKindFromText, sessionKindToText`, and
the import on line 31 to also bring `SessionKind (..)`. Then: `SessionRow` (line 34) becomes
`(UUID, UUID, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UUID, Maybe Text, Maybe Text)`; the
`CreateSession` row (lines 44–53) gains `Just (sessionKindToText ns.kind)` as its ninth element;
`mkSession` (74–85) gains `kind = ns.kind`; `rebuildSession` (87–100) destructures the ninth
element as `mKind` and computes `kind <- maybe (Right InteractiveSession) sessionKindFromText mKind`
before building the record (with `kind` in it); `sessionRowDecoder` (102–112) gains a ninth
`<*> D.column (D.nullable D.text)`; `insertSessionStmt` (114–132) names `kind` after
`oauth_client_id`, adds `$9`, uses `contrazip9`, and adds a ninth `(E.param (E.nullable E.text))`;
and both `SELECT` column lists (lines 140 and 152) end with `, kind`. Exactly this shape, so the
column order in every statement matches the tuple.

Teach the unit-of-work interpreter, `shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs`:
import `sessionKindToText` beside `sessionStatusToText` (line 38) and add
`Just (sessionKindToText session.kind)` as the ninth element of `sessionRow` (lines 110–120).
Nothing else changes there — it reuses `insertSessionStmt`, which is why the two column lists
cannot drift.

Teach the fake: in `shomei-core/src/Shomei/Test/InMemory.hs`, `mkSession` (lines 438–449) gains
`kind = ns.kind`. `persistNewSession`'s in-memory arm (line 596 onward) calls `mkSession`, so it
is covered.

Now the construction sites. Add `kind = InteractiveSession` to the literal in `signup`
(Authentication/Workflow.hs lines 160–166) and to the literal in `issueSessionWith`
(Session/Workflow.hs lines 187–193), importing `SessionKind (..)` from `Shomei.Session.Domain` in
both modules; leave a one-line comment on the `issueSessionWith` literal that every caller of
this tail is an interactive login or the exchange of a code an interactive session authorized.
Add `kind = DelegatedSession` in `mintDelegatedToken` (Delegation/Workflow.hs lines 143–149) and
`kind = MachineSession` in `grantClientCredentials` (ClientCredentials/Workflow.hs lines 99–105),
importing `SessionKind (..)` in each. Then the seven `shomei-postgres/test/Main.hs` literals:
`kind = InteractiveSession` at lines 902, 903, 904, 941, 963, and 980, and
`kind = DelegatedSession` in the actor literal at lines 955–961; import `SessionKind (..)` there
too. Do not pass `SessionKind` through `SessionOptions`: the kind is a property of the *path*, not
a knob, and a knob is how a future caller would mint an interactive session by mistake.

Allocate the migration with `just new-migration sessions-kind` (transcript in Concrete Steps).
The tool creates `shomei-migrations/migrations/shomei/NNNN-sessions-kind.sql` containing only the
header comment `-- sessions-kind` and appends the file name to the manifest. `NNNN` is whatever it
allocates — `0029` if this lands before EP-2, `0030` otherwise; this plan says `0029` below and
means "the allocated number". Replace the file's contents with:

```sql
-- sessions-kind

SET search_path TO shomei, pg_catalog;

-- How the session was established: 'interactive' (a human proved a credential, or exchanged an
-- authorization code that an interactive session authorized), 'machine' (client_credentials), or
-- 'delegated' (impersonation or RFC 8693 on-behalf-of; the session's access token carries `act`).
--
-- Nullable with a default so that every row predating the column reads as 'interactive' -- the
-- only kind that existed before machine and delegated sessions were distinguishable -- and so a
-- binary built before this column keeps inserting after it is applied (its INSERT names no `kind`
-- and the default fills it). The interpreter always writes an explicit value and refuses an unknown
-- one on read, as it does for `status`.
--
-- The column exists so GET /oauth/authorize can refuse to mint an authorization code for anything
-- but an interactive session. A code becomes a brand-new, refreshable, fully privileged session;
-- a machine or delegated credential must not be able to obtain one (plan 51).
ALTER TABLE shomei_sessions
  ADD COLUMN IF NOT EXISTS kind text NULL DEFAULT 'interactive';
```

Rebuild so the embedded manifest picks the file up, and run the manifest check. Then add two
PostgreSQL test cases to `shomei-postgres/test/Main.hs` next to `testSessionActorRoundTrip`
(lines 948–975), registered wherever that one is registered. The first creates one session of
each kind and reads each back, asserting `kind`. The second proves the pre-column read: create
an interactive session, run `execSql pool "UPDATE shomei.shomei_sessions SET kind = NULL"`
(`execSql` is at line 437), then `findSessionById` it and assert `kind == InteractiveSession`.
Create the NULL-ed session *before* the machine and delegated ones, or the blanket `UPDATE` will
null those too.

Acceptance: `cabal build all --enable-tests` compiles with no warnings about missing fields (the
compiler is your grep — a missed `NewSession` literal is a hard error under the repository's
warning set); `cabal test shomei-core` and `cabal test shomei-postgres` pass, including the two
new cases; `cabal run shomei-migrate -- check --manifest shomei-migrations/migrations/shomei/manifest`
lists twenty-nine entries. Commit.

### Milestone M2 — only a live interactive session may authorize a client

Scope: after this milestone the laundering chain is closed at authorize, in the core and at the
handler, with tests at both layers. Write the HTTP scenarios *first* and run them against the
M1 code to watch them fail, as plan 30 did with its timing test; the failure transcript is the
evidence that the test detects the vulnerability and belongs in Surprises & Discoveries.

Start with the servant helpers in `shomei-servant/test/Main.hs`. Generalize `mkTokenFor` (line
378): extract `mkTokenForSession :: JWK -> ShomeiConfig -> UserId -> SessionId -> Set Role -> Set Scope -> Maybe UserId -> UTCTime -> IO Text`
that signs the same `AuthClaims` with a caller-supplied session id and issue time, and make
`mkTokenFor` call it with `genSessionId` and `getCurrentTime`. Add `signupPrincipal :: Manager -> Int -> JWK -> Text -> IO (Text, UserId, SessionId)`,
which calls `signupTokenAndId`, verifies the returned access token with `verifyIdToken jwk`,
reads its `sid` claim, and parses both ids (`parseUserId` for the user; `Shomei.Id.parseId` for
the session). Every token a new scenario hand-mints is bound to a session `signupPrincipal`
created, so the scenarios are valid before and after M3. Add an environment builder beside
`freshAuthorizeEnv` (line 476):

```haskell
      -- Plan 51: OIDC on, a login URL configured (so a wrongful bounce would be visible as a 302),
      -- both clients, and a service account holding the exchange gate scope.
      freshProvenanceEnv = do
        r <- newIORef (emptyWorld t0)
        let c = oidcCfg {oauthConfig = oidcCfg.oauthConfig {loginUrl = Just "https://host.test/login"}}
        (confId, pubId) <- seedOAuthClients r jwk jwkset c t0
        svcId <- seedExchangeAccount r jwk jwkset c t0 "svcprov" (Set.fromList [ingestScope, tokenExchangeSubjectScope])
        pure (r, confId, pubId, svcId, mkEnvWith c r)
```

Thread it through `tests` like the other builders, and register two cases.

The first, `scenarioNoLaunderingThroughAuthorize :: IORef World -> JWK -> ShomeiConfig -> UTCTime -> Text -> Int -> IO ()`
(the `Text` is the public client id; the `UTCTime` is `t0`, the world's frozen clock, which the
operator token must be issued at so the five-minute freshness gate passes), is the review's
chain as a regression test. It signs up a target and grants them a role
(`defineRoleIn ref (Role "support-viewer")`, `grantRoleIn ref (idText targetUid) (Role "support-viewer")`)
so a laundered session would visibly carry privilege; signs up an operator and mints
`opTok <- mkTokenForSession jwk cfg opUid opSid Set.empty (Set.singleton cfg.impersonationConfig.impersonateScope) Nothing t0`;
exchanges it for a delegated token in impersonation mode (`postForm … "/oauth/token" Nothing`
with `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token` = the target's
id text, `subject_token_type=urn:shomei:params:oauth:token-type:user-id`, `actor_token`,
`actor_token_type=urn:ietf:params:oauth:token-type:access_token`), asserts `200` and that the
delegated token's claims carry `act` and no roles; then presents it at authorize for the public
client with a valid PKCE pair (`pkceChallengeFor verifier`, `code_challenge_method=S256`,
`scope=openid`). The assertions that must hold after the fix:

```haskell
  r <- getNoRedirect mgr port (authorizeUrl params) (bearer delegated)
  assertOAuthError "delegated bearer at authorize" 401 "login_required" r
  headerValue "Location" (headersOf r) @?= Nothing
  codes <- Map.size . oauthCodes <$> readIORef ref
  codes @?= 0
```

The second, `scenarioAuthorizeProvenance :: IORef World -> JWK -> ShomeiConfig -> UTCTime -> Text -> Text -> Text -> Int -> IO ()`
(confidential id, public id, service-account id), is the matrix. In order: an interactive signup
token authorizes the confidential client and receives a `302` with a code (the control; code
count 1); a `client_credentials` token from `postForm … (Just (svcId, oauthClientSecret)) [("grant_type","client_credentials")]`
is `401 login_required` with no `Location`; an on-behalf-of token (the service exchanges the
user's token with `scope=kawa:ingest`) is `401`; an impersonation token minted as in the first
scenario is `401`; a hand-minted token with `actor = Just opUid` and a random session id
(`mkTokenFor`) is `401` — proving `act` is refused before any store read; then
`revokeAllSessionsOf ref (idText userUid)` and the *interactive* token again, in this default
`VerifyTokenOnly` environment, is a `302` whose `Location` begins with `https://host.test/login`
and carries no `code` — a dead session is "not logged in", and the store is consulted in every
mode. Finish by asserting the code count is still 1.

Run `cabal test shomei-servant` now, before touching any source. Both new cases must fail: the
first at "delegated bearer at authorize: status" with `expected: 401` / `but got: 302`, the second
at its `client_credentials` step the same way. Record the transcript in Surprises & Discoveries.
Optionally, to record the full laundering for posterity, temporarily append to the first scenario
(and delete before committing) a block that takes the `code` out of the `302`'s `Location`,
exchanges it at `/oauth/token` as the public client (`client_id`, `code`, `redirect_uri`,
`code_verifier`), and prints the exchanged token's claims: you will see `sub` = the target, no
`act`, `roles` containing `support-viewer`, and a `refresh_token` in the body — a 30-day
refreshable session for the customer, obtained with a 30-minute delegated token.

Now the core. In `shomei-core/src/Shomei/Session/Workflow.hs`, add and export the shared
liveness predicate, importing `Shomei.Session.Store (SessionStore, findSessionById)`,
`SessionStatus (SessionActive)` from `Shomei.Session.Domain`, and widening the `Shomei.Error`
import to `AuthError (..)`:

```haskell
-- | Is this session usable right now? 'Nothing' → 'SessionNotFound'; past its absolute deadline →
-- 'SessionExpired' (checked first: at the deadline both status and expiry fail, and "log in
-- again" is the informative answer); not active → 'SessionRevoked'.
--
-- The one definition of "live" that 'Shomei.Session.Authentication.Workflow.verifyTokenWith',
-- 'Shomei.OAuth.Authorize.Workflow.authorize', and 'Shomei.Delegation.Workflow.startImpersonation'
-- share, so a privilege-minting path cannot drift from the request-time verifier.
requireLiveSession :: (SessionStore :> es) => UTCTime -> SessionId -> Eff es (Either AuthError Session)
requireLiveSession ts sid = do
  mSession <- findSessionById sid
  pure $ case mSession of
    Nothing -> Left SessionNotFound
    Just s
      | s.expiresAt <= ts -> Left SessionExpired
      | s.status /= SessionActive -> Left SessionRevoked
      | otherwise -> Right s
```

In `shomei-core/src/Shomei/OAuth/Authorize/Workflow.hs`, extend the error type (lines 69–76) and
its two renderers (78–88):

```haskell
-- | Why an otherwise-verifying credential may not authorize a client.
data AuthorizeRefusal
  = -- | the token carries @act@, or its session is a machine or delegated session
    NonInteractiveCredential
  | -- | the token's session is missing, revoked, or past its absolute expiry
    SessionNotLive
  deriving stock (Generic, Eq, Show)

data AuthorizeError
  = UnsupportedResponseType
  | AuthorizeInvalidRequest !Text
  | AuthorizeInvalidScope
  | -- | the caller is not a live interactive end-user login. Unlike the three above this is
    -- never rendered as an error redirect: the HTTP layer answers @401@ (see
    -- "Shomei.OAuth.Handler"). It lives here because the /decision/ is policy, not HTTP shape.
    AuthorizeLoginRequired !AuthorizeRefusal
  deriving stock (Generic, Eq, Show)
```

with `authorizeErrorCode (AuthorizeLoginRequired _) = "login_required"` and descriptions
"an interactive login session is required to authorize a client" for `NonInteractiveCredential`
and "the session is no longer valid" for `SessionNotLive`. Export `AuthorizeRefusal (..)`. Amend
the module header's "Errors here are not AuthError" paragraph (lines 11–14) to say every error
but `AuthorizeLoginRequired` becomes a redirect. Then change `authorize`: add `SessionStore :> es`
to its constraint (lines 128–132), import `Shomei.Session.Store (SessionStore)`,
`Shomei.Session.Workflow (requireLiveSession)`, and `Shomei.Session.Domain (SessionKind (..))`
(import the `Session` type without `(..)`, for the same `OverloadedRecordDot` reason the header
gives for `OAuthClient`, and read the field with the generic-lens label the module already uses),
and make the body begin:

```haskell
authorize cfg client claims params = runErrorNoCallStack do
  -- Provenance before policy. A code becomes a brand-new, refreshable, fully privileged
  -- session, so only a credential that IS a live interactive login may mint one: never a token
  -- carrying `act`, never a machine or delegated session, never a dead one. The session is read
  -- whatever sessionCheckMode says — minting privilege is not an ordinary request.
  when (isJust claims.actor) (throwError (AuthorizeLoginRequired NonInteractiveCredential))
  ts <- now
  session <-
    either (const (throwError (AuthorizeLoginRequired SessionNotLive))) pure
      =<< requireLiveSession ts claims.sessionId
  unless ((session ^. #kind) == InteractiveSession) $
    throwError (AuthorizeLoginRequired NonInteractiveCredential)
  unless (params.responseType == Just "code") (throwError UnsupportedResponseType)
  challenge <- resolvePkce
  granted <- resolveScopes
  -- (delete the original `ts <- now` on line 142; the one above is reused for the code row)
```

Then the handler, `oauthAuthorizeH` in `shomei-servant/src/Shomei/OAuth/Handler.hs`. Replace the
`case mUser of` block (lines 168–193) so that the unauthenticated branch is a local `loginRequired`
(bound with `let` inside the `do`, because it needs `params` and `clientId`), a principal whose
claims carry `act` is refused before the workflow runs, and the two refusals the workflow can
return are mapped, with everything else unchanged:

```haskell
  let loginRequired = case env.config.oauthConfig.loginUrl of
        Just loginUrl -> redirectTo (loginUrl `withQuery` [("return_to", TE.encodeUtf8 (reconstructedAuthorizeUrl params clientId))])
        Nothing -> throwError (OAuth.oauthError status401 "login_required" "no authenticated user and no login URL is configured")
  mUser <- liftIO (resolveAuthUser env mAuthHeader mCookie)
  case mUser of
    Nothing -> loginRequired
    -- Defense in depth: the workflow refuses a delegated credential too, but refusing it here
    -- costs no store read and mirrors 'denyUnderDelegation' on every mutation route.
    Just user | isJust user.authClaims.actor -> throwError notInteractive
    Just user -> do
      outcome <- runOAuthPort env (OAuthAuthorize.authorize env.config client user.authClaims params)
      case outcome of
        -- A machine or delegated session is refused outright: it is not a browser, and logging
        -- in is not the fix. Never bounced to the login page, never given a code.
        Left (OAuthAuthorize.AuthorizeLoginRequired OAuthAuthorize.NonInteractiveCredential) ->
          throwError notInteractive
        -- A dead session is "not logged in": the same answer an anonymous browser gets.
        Left (OAuthAuthorize.AuthorizeLoginRequired OAuthAuthorize.SessionNotLive) -> loginRequired
        Left e -> {- the existing error redirect, unchanged -}
        Right issued -> {- the existing success redirect, unchanged -}
  where
    notInteractive =
      OAuth.oauthError status401 "login_required" "an interactive login session is required to authorize a client"
```

Add a step "3b" to the handler's numbered haddock (lines 108–126) describing the refusal. No
route type changes, so `docs/api/openapi.json` and the `shomei-servant-openapi` suite are
untouched (a `401` OAuth-shaped answer was already among the endpoint's documented responses).

Core tests. First repair `shomei-core/test/Shomei/OAuthCodeStoreSpec.hs`: `runAuthorize` (lines
199–221) builds claims naming a session that was never created, which the workflow now refuses.
Inside its `runInMemory` block, before `authorize`, create a session
(`createSession NewSession {userId = uid, createdAt = t0, expiresAt = addUTCTime 3600 t0, actor = Nothing, oauthClientId = Nothing, kind = InteractiveSession}`,
importing `createSession` from `Shomei.Session.Store` and `NewSession (..)`, `SessionKind (..)`
from `Shomei.Session.Domain`) and pass its `sessionId` to `claimsFor`. Then add a new module
`shomei-core/test/Shomei/OAuth/Authorize/WorkflowSpec.hs`, registered in
`shomei-core/shomei-core.cabal` under the test-suite's `other-modules` (line 157 onward,
alphabetical) and in `shomei-core/test/Main.hs`. Its fixtures: `cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")`;
`fixedTime = UTCTime (fromGregorian 2026 1 1) 0`; a `seedPrincipal :: IORef World -> Text -> IO (UserId, AuthClaims)`
that signs up through `Shomei.Session.Authentication.Workflow.signup` (copy `seedUser` from
`TokenExchange/WorkflowSpec.hs` lines 71–75) and decodes the signup access token's claims with
the JSON round trip that spec's `decodeAccess` (159–164) uses; a `seedClient` that registers one
confidential client through `createOAuthClient` (copy lines 203–216 of `OAuthCodeStoreSpec.hs`,
with `secretHash = Just (sha256Hex "secret")` and `allowedScopes = Set.singleton (Scope "openid")`);
a fixed `AuthorizeParams` with `responseType = Just "code"`, the registered redirect URI, and
everything else `Nothing`; and `authorizeWith ref client claims = runInMemory ref (authorize cfg client claims params)`.
The cases, each asserting the exact `Left` and that `Map.size (oauthCodes world) == 0` afterward
unless noted:

- an interactive signup session authorizes the client: `Right`, and one code is stored;
- an impersonation token is refused: seed an operator, set `scopes = Set.singleton cfg.impersonationConfig.impersonateScope`
  on its claims, `startImpersonation cfg StartImpersonation {actorClaims, targetUserId, reason = "test", ticketId = Nothing, clientIp = Nothing}`,
  decode the returned access token, authorize → `Left (AuthorizeLoginRequired NonInteractiveCredential)`;
- an on-behalf-of token is refused: build a `ServiceAccount` value as `mkServiceAccount` does
  (`TokenExchange/WorkflowSpec.hs` lines 108–123) holding `token-exchange:subject` and
  `kawa:ingest`, `exchangeToken cfg` with the user's signup token as `subjectToken`
  (`accessTokenType`), decode, authorize → `NonInteractiveCredential`;
- a `client_credentials` token is refused: `createServiceAccount NewServiceAccount {…, secretHash = sha256Hex "s3cret", allowedScopes = Set.singleton (Scope "kawa:ingest")}`
  backed by a seeded user (see the servant suite's `seedOAuthAccount`, lines 540–560, for the
  record's fields), `grantClientCredentials cfg ClientCredentialsGrant {clientId, clientSecret = "s3cret", requestedScopes = Nothing}`,
  decode `accessToken`, authorize → `NonInteractiveCredential`;
- an `act` claim on an otherwise interactive session is refused, and is refused even when the
  session id names nothing (`claims {actor = Just ghost, sessionId = ghostSid}`) —
  `NonInteractiveCredential`, proving the actor check precedes the store read;
- a revoked interactive session is refused: `revokeSession claims.sessionId fixedTime` then
  authorize → `Left (AuthorizeLoginRequired SessionNotLive)`;
- an unknown session id is refused: `claims {sessionId = ghostSid}` → `SessionNotLive`.

Acceptance: `cabal test shomei-core` passes with the new group; `cabal test shomei-servant`
passes including the two scenarios that failed before; every pre-existing authorize scenario
(`scenarioAuthorizeIssuesCode`, `scenarioAuthorizeRejectsRevokedSession`,
`scenarioAuthorizeLoginRedirect`, `scenarioAuthorizeNoLoginUrl`, `scenarioOAuthCodeExchange`)
still passes unchanged, which proves interactive callers are unaffected. Commit.

### Milestone M3 — exchange and delegation see revocation and suspension at once

Scope: after this milestone every token presented to RFC 8693 exchange, and every operator
starting an impersonation, is checked against the session store and the user table whatever
`sessionCheckMode` says, and the authorization-code exchange refuses an unverified account when
the flag is on.

In `shomei-core/src/Shomei/Session/Authentication/Workflow.hs`, split `verifyToken` (lines
450–469) into a mode-parameterized worker and the config-aware wrapper, export both, and use the
shared predicate (import `requireLiveSession` on line 92):

```haskell
-- | 'verifyToken' with the session policy chosen by the caller rather than by configuration.
--
-- The privilege-minting workflows — RFC 8693 exchange and impersonation — pass
-- 'VerifyTokenAndSession': they must see a revocation immediately whatever the deployment chose
-- for ordinary requests, because they are about to mint a new credential. This is the one
-- session-aware verifier in the code base; add callers, not siblings.
verifyTokenWith ::
  (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
  SessionCheckMode ->
  AccessToken ->
  Eff es (Either AuthError AuthClaims)
verifyTokenWith mode token = do
  result <- verifyAccessToken token
  case result of
    Left te -> pure (Left (TokenInvalid te))
    Right claims -> case mode of
      VerifyTokenOnly -> pure (Right claims)
      VerifyTokenAndSession -> do
        ts <- now
        fmap (const claims) <$> requireLiveSession ts claims.sessionId

verifyToken ::
  (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
  ShomeiConfig ->
  AccessToken ->
  Eff es (Either AuthError AuthClaims)
verifyToken cfg = verifyTokenWith cfg.sessionCheckMode
```

The behavior of `verifyToken` is byte-for-byte what it was; `Shomei.Servant.Seam.verifyRequestToken`
and every `Authenticated` route keep their config-aware semantics.

In `shomei-core/src/Shomei/OAuth/TokenExchange/Workflow.hs`, replace `verifyToken` (lines
272–277) so both the actor token (impersonation mode, line 165) and the subject token
(on-behalf-of mode, line 208) are verified statefully. Import
`Shomei.Session.Authentication.Workflow qualified as Wf`, add `SessionCheckMode (..)` to the
`Shomei.Config` import on line 54, drop `verifyAccessToken` from the line-68 import (keep
`TokenVerifier`), and write:

```haskell
-- | Verify a presented compact token back into its claims, or fail the whole exchange with
-- @invalid_grant@. Always session-aware: a subject or actor token whose session has been revoked
-- or has expired is a bad grant the moment it is revoked, whatever @sessionCheckMode@ says,
-- because this grant mints a new credential from it. Every reason it might fail is
-- indistinguishable on the wire.
verifyToken ::
  (TokenVerifier :> es, SessionStore :> es, Clock :> es, Error AuthError :> es) =>
  Text ->
  Eff es AuthClaims
verifyToken raw =
  either (const (throwError OAuthGrantInvalid)) pure
    =<< Wf.verifyTokenWith VerifyTokenAndSession (AccessToken raw)
```

Both mode functions already carry `SessionStore` and `Clock` in their constraints. The actor of
on-behalf-of mode is the service's backing user, which `requireActiveUser (svc ^. #userId)` at
line 213 already checks; the actor of impersonation mode is the operator, checked next.

In `shomei-core/src/Shomei/Delegation/Workflow.hs`, `startImpersonation`: import
`Shomei.Session.Workflow (requireLiveSession)` and insert after the freshness check (line 74)
and before the self check (line 76):

```haskell
  -- Liveness: the operator's own session must still be live -- always, whatever sessionCheckMode
  -- says, because this mints a new credential. A logged-out or revoked operator may not start an
  -- impersonation for the rest of their access token's life.
  _ <- either (const (throwError ImpersonationForbidden)) pure =<< requireLiveSession ts caller.sessionId
  -- Status: the operator must still exist and be active. A suspended operator holding a
  -- not-yet-expired token is exactly who this check is for.
  operator <- maybe (throwError ImpersonationForbidden) pure =<< findUserById caller.subject
  unless (operator.status == UserActive) (throwError ImpersonationForbidden)
```

Both refusals are `ImpersonationForbidden` (403 in the application envelope, `invalid_grant` at
`/oauth/token` through `exchangeErrorFor`), the same answer as a missing scope: the caller may not
impersonate, and why is their own business. Update the function's haddock (lines 53–56) to list
the six checks.

In `shomei-core/src/Shomei/OAuth/TokenGrant/Workflow.hs`, `exchangeAuthorizationCode`: import
`ensureEmailVerified` beside `issueSessionWith` (line 67) and add, inside the `user <- do` block
after the active check (line 167):

```haskell
    -- The emailVerificationRequired gate, like every other token-issuing path (login, refresh,
    -- MFA completion). Without it an unverified account renews forever through authorize →
    -- exchange without ever refreshing: each exchange mints a fresh interactive session whose
    -- access token can authorize the next code.
    either (const (throwError (GrantInvalidGrant "the code's user has not verified their email"))) pure (ensureEmailVerified cfg u)
```

Now the fixtures, which is most of this milestone's work. In
`shomei-core/test/Shomei/OAuth/TokenExchange/WorkflowSpec.hs` add
`seedPrincipal :: IORef World -> Text -> IO (UserId, SessionId)` (sign up, decode the signup
access token, return the ids) and route every token that must get *past* verification through
it: `freshOperatorToken` (100–105) and the subject tokens in `testOnBehalfHappyPath`,
`testOnBehalfDefaultScopes`, `testOnBehalfMissingGateScope`, `testOnBehalfScopeOutsideCeiling`,
`testOnBehalfGateNeverGranted`, `testOnBehalfSubjectScopeBoundOk`, `testOnBehalfSubjectScopeBoundViolation`,
`testOnBehalfChainRefused`, `testOnBehalfInactiveSubject`, and the operators in
`testImpersonationSelfTarget` and `testImpersonationDelegatedActorRefused`.
`testImpersonationMissingScope` and `testImpersonationStaleActor` fail at the scope and freshness
checks, which precede the session read, and may keep their fake ids. Add three cases: on-behalf-of
with a subject whose session was revoked (`revokeSession sid fixedTime` through `runInMemory`) →
`Left OAuthGrantInvalid`; impersonation whose operator session was revoked → `Left OAuthGrantInvalid`
(the exchange's verifier refuses it first); impersonation by an operator suspended with
`updateUserStatus op UserSuspended` → `Left ImpersonationForbidden`. Name each "… under the
default VerifyTokenOnly" — `cfg` is the default configuration, and that is the point.

In `shomei-core/test/Shomei/Delegation/WorkflowSpec.hs`, make `freshOperator` (86–90) sign the
operator up (reuse `seedCustomer`'s shape with a second email) and build `callerClaims` from the
real user id and the signup token's session id; `testMissingScope` and `testStaleCaller` may keep
fake ids. Add `testRevokedOperatorSession` and `testSuspendedOperator`, both expecting
`Left ImpersonationForbidden`.

In `shomei-servant/test/Main.hs`, delete `mkImpersonatorToken` (401–422) and the `impToken`/
`staleImpToken` bindings in `main` (509–512), remove those two parameters from `tests` (line
1338) and from `scenarioTokenExchange` (1629), give the scenario `cfg` and `t0` instead, and mint
both tokens inside it from a `signupPrincipal` operator with `mkTokenForSession` — the fresh one
at `t0`, the stale one at `addUTCTime (negate 1000) t0`. Then add
`scenarioExchangeRequiresLiveSessions :: IORef World -> JWK -> ShomeiConfig -> UTCTime -> Text -> Int -> IO ()`
over an exchange environment (change `freshExchangeEnv`, line 496, to also return its `IORef World`
and update its one call site): an on-behalf-of exchange of a user's signup token succeeds (`200`);
after `revokeAllSessionsOf ref (idText userUid)` the same request is `400 invalid_grant`; an
impersonation with a fresh operator succeeds; after revoking the operator's sessions it is
`400 invalid_grant`; a new operator suspended through a small `suspendUserIn ref uid` helper
(`runInMemory ref (updateUserStatus uid UserSuspended)`) is `400 invalid_grant`. All under the
default configuration.

In `shomei-server/test/Shomei/Server/E2ESpec.hs`, the operator at lines 140–163 gets a real
session: after `seedOperatorUser`, create one through a runner shaped like `seedOperatorUser`'s
(lines 468–480) with `runSessionStorePostgres` in the stack, using
`createSession NewSession {userId = opUid, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing, oauthClientId = Nothing, kind = InteractiveSession}`,
and use its `sessionId` in place of `opSid <- genSessionId`.

Finally the email gate's tests, a new module `shomei-core/test/Shomei/OAuth/TokenGrant/WorkflowSpec.hs`
registered like the M2 module. Reuse the M2 spec's fixtures (copy them; the two modules are
small) and `gatedCfg = cfg {notifierConfig = cfg.notifierConfig {emailVerificationRequired = True}}`
as `Shomei.Account.Verification.WorkflowSpec` defines it. Cases: with the flag on, a signup with
an email (unverified) authorizes and its code's exchange —
`exchangeAuthorizationCode gatedCfg ExchangeAuthorizationCode {clientId = client ^. #clientId, clientSecret = Just "secret", code = issued.code, redirectUri = callback, codeVerifier = Nothing}`
— is `Left (GrantInvalidGrant _)`; with the flag off the same exchange is `Right`; with the flag
on, a login-id-only signup (no email) exchanges successfully, because the gate exempts accounts
that can never verify one.

Acceptance: `cabal test shomei-core`, `cabal test shomei-servant`, `cabal test shomei-server`
green; the three new core refusal cases and `scenarioExchangeRequiresLiveSessions` pass; the
review's verified holds for exchange (chained exchanges refused, gate scope stripped, delegated
tokens refresh-less) still pass because those cases were kept and only re-seeded. Commit.

### Milestone M4 — documentation, the first ADR, and closing the plan

Scope: the documentation says what the code now does, the decision is recorded durably, and the
MasterPlan's ledger reflects EP-1 complete.

`docs/user/security.md`: add a section `## Session provenance` between "Session revocation"
(ends line 265) and "Passkeys & MFA" (line 267). It explains the three kinds and which flows
produce each, states the rule **only a live interactive session may authorize an OAuth client**,
says that `GET /oauth/authorize` reads the session in every `sessionCheckMode`, and says that
RFC 8693 exchange and impersonation verify the presented token's session and the operator's
account status in every mode. In "Impersonation / delegated tokens" (289–328), extend the
"Two identities, always" bullet with a sentence that a delegated token cannot be turned into an
ordinary session through `/oauth/authorize` (it is answered `401 login_required`), extend
"Short-lived, no refresh" with "and cannot be laundered into a refreshable session through the
authorization-code flow", and extend "Scope + freshness gate" with the new liveness and
operator-status checks. `docs/user/oidc.md`, "The authorize contract" (75–102): after item 2 add
an item stating which credentials authorize accepts — a live interactive session (password,
passkey, MFA completion, or a session minted by a previous code exchange) — and that a
`client_credentials` token, a delegated token, or any token carrying `act` is `401` with an OAuth
error body and no redirect, while a revoked or expired session is treated as unauthenticated in
every `sessionCheckMode`. `docs/user/machine-tokens.md`: at line 118, "cannot be exchanged
again" becomes "cannot be exchanged again and cannot authorize an OAuth client at
`GET /oauth/authorize`"; after line 56 add that a `client_credentials` token identifies a machine
session and is likewise refused at authorize; at line 80 add that token exchange refuses a
subject or actor token whose session has been revoked, immediately and in every mode. Add an
`## Unreleased` section at the top of `shomei-core/CHANGELOG.md` (breaking: `Session` and
`NewSession` gain `kind`; `authorize` refuses non-interactive credentials; exchange and
impersonation are session-aware; the code exchange honours `emailVerificationRequired`),
`shomei-postgres/CHANGELOG.md` (the interpreters read and write `kind`),
`shomei-migrations/CHANGELOG.md` (the migration), and `shomei-servant/CHANGELOG.md` (the `401`
at authorize). Do not bump versions; releases are separate work.

Then the ADR bundle, following `.claude/skills/exec-plan/ADR.md` and the precedent of commit
`ee00382`. Create `docs/adr/profile.dhall` pinning the shared profile
(`mori://shinzui/okf-profiles/profiles/documentation/architecture-decisions`; the checkout at
`/Users/shinzui/Keikaku/bokuno/okf-profiles` carries it at tags `v0.11.0` through `v0.13.1`; pin
the newest tag that `dhall freeze` can fetch, and fall back to `v0.11.0`, which the reviews bundle
already trusts):

```dhall
--| Shared architecture-decisions profile, pinned to its published profile version.
--
-- Source: mori://shinzui/okf-profiles/profiles/documentation/architecture-decisions
https://raw.githubusercontent.com/shinzui/okf-profiles/v0.13.1/profiles/documentation/architecture-decisions.dhall
```

and run `dhall freeze --inplace docs/adr/profile.dhall` to append the `sha256:` integrity check
(Concrete Steps has the transcript). Write `docs/adr/index.md` with the same shape as
`docs/reviews/index.md` (`okf_version: "0.2"` frontmatter, a heading, a Files list naming
`profile.dhall`, and an "Authoring a decision" section giving the two `okf id` commands with
`ADR` as the prefix), and `docs/adr/log.md` with one dated `Addition` entry in the reviews
bundle's format. Add to `mori.dhall`'s `okfBundles` (after the `reviews` entry, line 370):

```dhall
      , Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Shomei architecture decision records"
        }
```

and to the `Justfile` (after `reviews-validate`, line 46) a recipe `adr-validate` running
`okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`.
Allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` (it prints
`ADR-1`) and write `docs/adr/0001-only-an-interactive-session-may-authorize-a-client.md`:

```markdown
---
type: Architecture Decision Record
title: Sessions carry their provenance and only an interactive session may authorize a client
description: Every session records whether a human established it, and OAuth authorization codes are minted only for live interactive sessions.
docId: ADR-1
status: Accepted
date: 2026-08-27
originatingPlan: docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md
generated:
  by: process:claude-code
  at: "2026-08-27T00:00:00Z"
---
```

(replace `at` with the real timestamp and `by` with `human:nadeem` if a person writes it). The
body has four sections. *Context*: three credential classes share one verifier and one
`sub`-keyed trust model downstream; the authorization-code flow turns any verifying credential
into a fresh, refreshable, fully enriched session; the review's critical finding. *Decision*:
every session carries `kind ∈ {interactive, machine, delegated}` decided by the minting path,
never by a caller-supplied option; `GET /oauth/authorize` mints a code only for a token without
`act` whose session is live and interactive, reading the session in every `sessionCheckMode`;
operations that mint new privilege from a presented token (RFC 8693 exchange, impersonation)
verify that token's session and the actor's account status in every mode. *Consequences*: a
delegated or machine credential can never become an ordinary session; the interactive/
non-interactive boundary is a column, so future minting paths must choose a kind (the record
field makes forgetting a compile error); one more session read at authorize, exchange, and
impersonation; EP-2's client binding and scope policy build on this boundary. *Alternatives
rejected*: refusing only `act` (a machine token has none); a claim in the JWT instead of a column
(a stateless claim cannot be revoked or corrected, and tokens minted before the change would be
unclassifiable); checking only under `VerifyTokenAndSession` (the default deployment would keep
the hole). Validate with `just adr-validate` and fix whatever it reports until it is clean.

Close out: tick the three EP-1 boxes in MasterPlan 8's Progress and set the EP-1 registry row
to Complete; update this plan's Progress, Surprises & Discoveries (the pre-fix failure
transcript, and anything else found), and Outcomes & Retrospective; run `cabal test all -j1`.
Commit.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. The `-j1` on
the final full run is deliberate: every database suite provisions its own ephemeral PostgreSQL,
and plan 50 recorded that parallel suites lose cases to a 60-second startup timeout on a loaded
machine — a red parallel run whose failures all read `Failed to start ephemeral PostgreSQL` is
contention, not a regression.

Milestone M1. After the source edits:

```bash
cabal build all --enable-tests
just new-migration sessions-kind
```

The second prints one line and exits 0:

```text
created shomei-migrations/migrations/shomei/0029-sessions-kind.sql
```

and `tail -1 shomei-migrations/migrations/shomei/manifest` now prints `0029-sessions-kind.sql`.
Edit the file to the SQL in M1, then:

```bash
cabal build shomei-migrations
cabal run shomei-migrate -- check --manifest shomei-migrations/migrations/shomei/manifest
```

The check prints one line per manifest entry — twenty-nine of them, the last being
`0029-sessions-kind.sql checksum=…` — and exits 0; a stray or missing file is a non-zero exit with
a manifest error naming it. Then:

```bash
cabal test shomei-core
cabal test shomei-postgres
git add -A && git commit -F - <<'EOF'
feat(session): record how every session was established

Add SessionKind (interactive | machine | delegated) to Session and NewSession,
a nullable-with-default `kind` column on shomei_sessions (existing rows read
as interactive), and carry it through both PostgreSQL interpreters, the
in-memory fake, and persistNewSession. Every NewSession construction site now
names its kind: signup, login, MFA completion, and the authorization-code
exchange are interactive; client_credentials is machine; impersonation and
RFC 8693 on-behalf-of are delegated.

Nothing consults the kind yet; that is the next commit. This one is purely
additive and the whole suite is unchanged.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
EOF
```

Milestone M2. Write the two servant scenarios and their helpers first, then run the suite
against the M1 code:

```bash
cabal test shomei-servant
```

Expect two failures and nothing else red. The laundering scenario's failure reads, in tasty's
format:

```text
  an impersonation token cannot be laundered into a user session through authorize + code exchange: FAIL
    delegated bearer at authorize: status
    expected: 401
     but got: 302
```

and the provenance matrix fails at its `client_credentials` step the same way. Copy both into
Surprises & Discoveries. Make the M2 source edits, then:

```bash
cabal build all --enable-tests
cabal test shomei-core
cabal test shomei-servant
git add -A && git commit -F - <<'EOF'
fix(oauth)!: refuse non-interactive credentials at GET /oauth/authorize

An impersonation, on-behalf-of, or client_credentials token could authorize
a client and, through the authorization-code exchange, become a 30-day
refreshable session with the subject's full roles and no `act` (REV-1 #1,
REV-2 #1, REV-7 #1). authorize now refuses a token carrying `act`, reads the
caller's session in every sessionCheckMode, and refuses any session that is
not live and interactive. The handler answers 401 login_required in the OAuth
error shape with no redirect for a non-interactive credential and treats a
dead session as unauthenticated. The servant scenario driving the exact
chain fails on the previous commit and passes here.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
EOF
```

Milestone M3. After the source and fixture edits:

```bash
cabal build all --enable-tests
cabal test shomei-core
cabal test shomei-servant
cabal test shomei-server
git add -A && git commit -F - <<'EOF'
fix(oauth): verify exchange and delegation tokens against the session store

Token exchange verified subject and actor tokens by signature alone and
impersonation never checked the operator's own session or status, so a
revoked session or a suspended operator kept minting delegated sessions for
one access-token TTL (REV-1 #8, REV-2 #3). Both now verify through
verifyTokenWith VerifyTokenAndSession — the existing session-aware verifier,
parameterized by mode — and startImpersonation requires a live operator
session and an active operator. exchangeAuthorizationCode now applies the
emailVerificationRequired gate like every other token-issuing path
(REV-2 #18). Test fixtures that hand-minted tokens for sessions that never
existed now bind them to real sessions.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
EOF
```

Milestone M4. The ADR bundle, in order:

```bash
mkdir -p docs/adr
# write docs/adr/profile.dhall as shown in M4 (the bare URL, no hash yet), then:
dhall freeze --inplace docs/adr/profile.dhall
cat docs/adr/profile.dhall
```

After freezing, the file ends with the URL followed by an indented `sha256:` line. If the fetch
fails, change the tag to `v0.11.0` and freeze again. Then write `index.md` and `log.md`, add the
`mori.dhall` and `Justfile` entries, and allocate the handle:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

The first prints nothing (no handles yet); the second prints `ADR-1`. Write the record, then:

```bash
just adr-validate
```

which must exit 0 with no diagnostics; a complaint about a missing frontmatter field, a wrong
`type`, or an unlogged change names the file and the rule — fix and rerun. Finish with the
documentation sweep, the MasterPlan ledger, the full suite, and the commit:

```bash
rg -n "login_required|Session provenance|cannot authorize" docs/user/security.md docs/user/oidc.md docs/user/machine-tokens.md
cabal test all -j1
git add -A && git commit -F - <<'EOF'
docs(security): document session provenance and record ADR-1

security.md, oidc.md, and machine-tokens.md now state the rule that only a
live interactive session may authorize an OAuth client, that delegated and
machine tokens are answered 401 login_required without a redirect, and that
exchange and impersonation are session-aware in every sessionCheckMode.
Bootstraps docs/adr as a bundle under the shared architectureDecisions
profile and records the decision as ADR-1. Per-package changelogs carry the
Unreleased entries; MasterPlan 8 marks EP-1 complete.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
EOF
```

Sweeps to run whenever a record or error type changes, so nothing is missed:

```bash
rg -n "NewSession" --type haskell -g '!dist-newstyle'      # every construction site names a kind
rg -n "verifyAccessToken" --type haskell -g '!dist-newstyle' # only the verifier, introspection, revoke, and verifyTokenWith remain
rg -n "genSessionId" shomei-core/test shomei-servant/test shomei-server/test  # each hit is a token that must not reach exchange or authorize
```


## Validation and Acceptance

Acceptance is behavioral. Each item names the inputs and the exact observable result.

Provenance is recorded. After M1, `cabal test shomei-postgres` shows the two new cases green:

```text
  create session persists its kind (machine, delegated, interactive):        OK
  a session row whose kind is NULL reads as interactive:                      OK
```

and `SELECT kind, count(*) FROM shomei.shomei_sessions GROUP BY kind` on any database the new
code has written to shows only `interactive`, `machine`, and `delegated` (plus NULL for rows that
predate the column).

The laundering chain is closed. The servant case "an impersonation token cannot be laundered
into a user session through authorize + code exchange" fails on the M1 commit with
`expected: 401 / but got: 302` and passes from M2 on. Over HTTP the observable contract is:
`GET /oauth/authorize?client_id=…&response_type=code&redirect_uri=…&code_challenge=…&code_challenge_method=S256`
with `Authorization: Bearer <delegated or machine token>` answers

```text
HTTP/1.1 401 Unauthorized
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache
WWW-Authenticate: Basic realm="shomei"

{"error":"login_required","error_description":"an interactive login session is required to authorize a client"}
```

with no `Location` header and no new row in the authorization-code store, whether or not
`oauthLoginUrl` is configured; the same request with an interactive login token answers `302` to
the registered `redirect_uri` with `code`, `state`, and `iss`; and the same interactive token
after its session is revoked, under the default `sessionCheckMode`, answers `302` to
`oauthLoginUrl` with `return_to` (or `401 login_required` when no login URL is configured) and no
code. The core group `Shomei.OAuth.Authorize.Workflow` lists seven cases, all green.

Exchange and delegation are session-aware. `cabal test shomei-core` shows, in
`Shomei.OAuth.TokenExchange.Workflow`, the cases for a revoked subject session, a revoked actor
session, and a suspended operator green under the default `VerifyTokenOnly`; in
`Shomei.Delegation.Workflow`, the revoked-operator-session and suspended-operator cases green. The
servant case `scenarioExchangeRequiresLiveSessions` shows a `200` exchange become `400`
`{"error":"invalid_grant",…}` the moment the session is revoked, and `400 invalid_grant` for a
suspended operator. The existing `scenarioTokenExchange` still passes with its operator re-seeded,
which proves a legitimate operator is unaffected.

The email gate holds at the exchange. `Shomei.OAuth.TokenGrant.Workflow` shows an unverified
account's code exchange refused with the flag on, accepted with it off, and accepted for an
email-less account with it on.

Nothing else moved. `cabal test all -j1` is green — thirteen suites — and the review's
verified-holds list for the OAuth workflows (single-use codes, PKCE, client authentication, ID
token shape, chained-exchange refusal, gate-scope stripping, refresh-less delegated tokens,
constant-time client secrets) is covered by the pre-existing cases that this plan re-seeded but
did not weaken.

The decision is durable. `just adr-validate` exits 0; `okf id list docs/adr --profile docs/adr/profile.dhall`
prints `ADR-1`; `rg -n "interactive" docs/user/security.md docs/user/oidc.md docs/user/machine-tokens.md`
finds the new sentences.


## Idempotence and Recovery

Every source edit is an ordinary compiler-checked change; `cabal build` and `cabal test` rerun
safely, and adding a record field means the compiler lists every missed construction site as an
error rather than letting one slip. The migration is `ADD COLUMN IF NOT EXISTS` with a default:
applying it to a database that already has the column is a no-op, and `shomei-migrate up` skips
an already-applied migration by its ledger anyway. Deploy order matters in one direction only:
apply the migration *before* starting a binary built from M1 or later, because that binary's
`INSERT` names the `kind` column. A binary built before M1 keeps working after the migration —
its `INSERT` omits `kind` and the default supplies `interactive` — so rolling the code back never
requires rolling the schema back. If the column must go, `ALTER TABLE shomei.shomei_sessions DROP COLUMN kind`
is safe once no post-M1 binary is running.

`just new-migration` is the one step that is *not* idempotent: running it twice allocates a
second file and manifest line. If that happens, delete the extra `.sql` file and its manifest
line and rerun the manifest check. Never renumber a migration that has been committed.

The behavior changes are safe to deploy incrementally. M1 changes no behavior. M2 changes the
answer only for callers that present a machine or delegated token at authorize — which no
legitimate client does; a relying party that was doing so is, by construction, the vulnerability.
M3 refuses exchanges and impersonations whose session is already dead or whose operator is
suspended; a legitimate caller sees no difference. There is no configuration switch to disable
these checks, deliberately: a switch would be a way to reopen the laundering hole.

The ADR bundle bootstrap is re-runnable: `dhall freeze --inplace` is stable once frozen,
`okf id next` is read-only, and `just adr-validate` only reads. If `okf` or the profile pin cannot
be made to work, write `docs/adr/0001-only-an-interactive-session-may-authorize-a-client.md` with
the frontmatter shown and skip the profile, index, log, and `mori.dhall` pieces, and record in the
Decision Log that the bundle is unprofiled and why.

If a milestone is interrupted, the Progress section says which boxes are ticked; each milestone's
commit is independently green, so resume from the last commit, rerun that milestone's test
command, and continue from the first unticked box.


## Interfaces and Dependencies

No new library dependencies. `contravariant-extras` already provides `contrazip9` (the
repository uses `contrazip10` elsewhere), `hasql` decodes a nullable text column with
`D.nullable D.text`, and the OKF tooling (`okf` 0.8.0.0, `dhall`) is already in the devshell
and already governs three bundles.

Definitions that must exist at the end, by full module path:

`Shomei.Session.Domain` exports `SessionKind (..)` with constructors `InteractiveSession`,
`MachineSession`, `DelegatedSession`; `Session` and `NewSession` each gain a final field
`kind :: !SessionKind`.

`Shomei.Persistence.Codec.Postgres` exports `sessionKindToText :: SessionKind -> Text` and
`sessionKindFromText :: Text -> Either Text SessionKind`.

`Shomei.Session.Postgres.SessionRow` is the nine-tuple ending in `Maybe Text`; `insertSessionStmt`
names nine columns; `mkSession` and `rebuildSession` carry `kind`, the latter reading NULL as
`InteractiveSession`. `Shomei.Session.UnitOfWork.Postgres.sessionRow` emits the ninth element.
`Shomei.Test.InMemory.mkSession` carries `kind`.

`Shomei.Session.Workflow` exports
`requireLiveSession :: (SessionStore :> es) => UTCTime -> SessionId -> Eff es (Either AuthError Session)`.

`Shomei.Session.Authentication.Workflow` exports
`verifyTokenWith :: (TokenVerifier :> es, SessionStore :> es, Clock :> es) => SessionCheckMode -> AccessToken -> Eff es (Either AuthError AuthClaims)`
and `verifyToken cfg = verifyTokenWith cfg.sessionCheckMode` with its existing signature.

`Shomei.OAuth.Authorize.Workflow` exports `AuthorizeRefusal (..)` (`NonInteractiveCredential`,
`SessionNotLive`) and `AuthorizeError` gains `AuthorizeLoginRequired !AuthorizeRefusal`;
`authorize` gains `SessionStore :> es` and refuses, in this order, a claim with `actor /= Nothing`,
a session that `requireLiveSession` rejects, and a session whose `kind /= InteractiveSession`,
before any parameter validation.

`Shomei.OAuth.TokenExchange.Workflow.verifyToken` (internal) calls
`Wf.verifyTokenWith VerifyTokenAndSession`. `Shomei.Delegation.Workflow.startImpersonation`
requires `requireLiveSession` to accept `actorClaims.sessionId` and `findUserById actorClaims.subject`
to return an active user, both on pain of `ImpersonationForbidden`.
`Shomei.OAuth.TokenGrant.Workflow.exchangeAuthorizationCode` calls `ensureEmailVerified cfg user`
and maps a refusal to `GrantInvalidGrant`.

`Shomei.OAuth.Handler.oauthAuthorizeH` answers `401` via `OAuth.oauthError status401 "login_required" …`
with no redirect for a principal whose claims carry `act` and for
`AuthorizeLoginRequired NonInteractiveCredential`, and takes the unauthenticated branch for
`AuthorizeLoginRequired SessionNotLive`. `Shomei.Servant.Auth.resolveAuthUser` and
`authUserFromClaims` are unchanged; `Shomei.Servant.Error` is unchanged because `/oauth/*` does
not speak the problem envelope.

Test modules that must exist: `Shomei.OAuth.Authorize.WorkflowSpec` and
`Shomei.OAuth.TokenGrant.WorkflowSpec` in `shomei-core`, registered in the cabal file and
`test/Main.hs`; the servant scenarios `scenarioNoLaunderingThroughAuthorize`,
`scenarioAuthorizeProvenance`, and `scenarioExchangeRequiresLiveSessions`; the helpers
`mkTokenForSession` and `signupPrincipal`.

Files that must exist: `shomei-migrations/migrations/shomei/NNNN-sessions-kind.sql` (listed in
the manifest); `docs/adr/profile.dhall`, `docs/adr/index.md`, `docs/adr/log.md`, and
`docs/adr/0001-only-an-interactive-session-may-authorize-a-client.md` with `docId: ADR-1`;
the `adrs` entry in `mori.dhall`; the `adr-validate` recipe in the `Justfile`.

Relations to sibling plans, by path. `docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md`
appends `grantedScopes` after `kind` on the same two records and adds its own migration; it must
not reorder or rename `kind`, and its tests may assume the refusal at authorize exists.
`docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md` changes
the settings under the pure verifier `Shomei.SigningKey.Verify.Jwt.verifyToken`, which
`verifyTokenWith` calls through the `TokenVerifier` port and therefore inherits without edits.
`docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md`
adds `authTime` to `AuthClaims`; this plan adds no claim and reads only `actor` and `sessionId`,
so the two do not conflict. `docs/plans/55-atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails.md`
owns `CHECK` constraints on status-like columns and should cover `kind`.
`docs/plans/60-reconcile-the-user-documentation-and-the-en-integration-story-with-the-code.md`
runs last and may lift the `Session provenance` section's sentences into `authorization.md`.
