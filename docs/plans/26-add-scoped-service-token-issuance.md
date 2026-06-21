---
id: 26
slug: add-scoped-service-token-issuance
title: "Add scoped service-token issuance"
kind: exec-plan
created_at: 2026-06-21T21:27:57Z
intention: intention_01kvp1nhv6eezaye9c05dpx9aq
---

# Add scoped service-token issuance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shomei already signs and verifies JWT access tokens that can carry scopes, roles, and an optional
`act` actor claim, but its normal signup, login, MFA, passwordless, refresh, and session workflows
intentionally issue human login tokens with empty scopes. Platform services such as connectors and
agent runtimes need a separate service-account path that can mint a short-lived access token with a
configured, coarse scope such as `kawa:ingest`, `signal:raise`, or `channel:egress`. A coarse scope
means a broad capability class: it answers "may this bearer use this doorway at all", while the
receiving service still enforces resource-level permissions locally.

After this change, an operator can configure named service accounts in the standalone Shomei server,
create or reuse a Shomei user for each service account, and call `POST /auth/service-token` with the
service account id, secret, requested scopes, and optional actor user id. A successful response
returns only an access token and `expiresIn`; it returns no refresh token, so the caller cannot
silently extend a service credential. A token bearing `kawa:ingest` verifies through the existing
JWKS and passes the existing `requireScope (Scope "kawa:ingest")` guard. A normal login token remains
empty-scoped and fails the same guard with HTTP 403.

This plan implements the improvement request at
`docs/improvement-requests/scoped-service-token-issuance.md`. The request fits the project because
Shomei already has the load-bearing JWT and authorization seams: `AuthClaims.scopes`,
`AuthClaims.actor`, `Shomei.Workflow.Session.buildClaims`, the `TokenSigner` effect,
`Shomei.Jwt.Sign.signAccessToken`, `Shomei.Jwt.Verify.verifyToken`, and
`Shomei.Servant.Authz.requireScope`. The work is a new issuance entry point, not a new verifier,
key system, session redesign, or downstream grant table.


## Progress

Use this checklist to summarize granular steps. Every stopping point must be documented here, even
if it requires splitting a partially completed task into two entries. This section must always
reflect the actual current state of the work.

- [x] M0 - Reconfirm the baseline behavior and run the focused pre-change tests. Completed 2026-06-21: `cabal test shomei-core shomei-servant shomei-jwt` passed with 105 core tests, 3 servant tests, and 20 JWT tests.
- [x] M1 - Add the core service-token configuration types, workflow command, validation errors, and unit tests. Completed 2026-06-21: added `ServiceTokenConfig`, `ServiceAccountConfig`, `Shomei.Workflow.ServiceToken`, `ServiceTokenIssued`, focused workflow tests, and event-codec coverage. `cabal test shomei-core` passed with 115 tests.
- [x] M2 - Add the Servant request/response DTOs, route, handler, and in-process HTTP tests. Completed 2026-06-21: added `POST /auth/service-token`, unprefixed DTO fields `accountId`, `secret`, `scopes`, and `actorId`, handler error mapping, and an in-process `/ingest` route guarded by `requireScope`. `cabal test shomei-servant` passed with 4 HTTP scenarios.
- [ ] M3 - Wire standalone server configuration from Dhall and environment variables, document the endpoint, and add PostgreSQL end-to-end coverage.
- [ ] M4 - Run formatting, build, and the relevant test suites; update this plan with results and retrospective notes.


## Surprises & Discoveries

The improvement request's cited seams were validated against this working tree on 2026-06-21. The
claims type in `shomei-core/src/Shomei/Domain/Claims.hs` has `scopes :: Set Scope`,
`roles :: Set Role`, `actor :: Maybe UserId`, and `extraClaims :: Object`. The reserved-key guard
includes `iss`, `sub`, `aud`, `iat`, `exp`, `sid`, `scopes`, `roles`, and `act`, so service-token
metadata must not be smuggled through those reserved names.

The signing seam is exactly the one the request expects. `shomei-jwt/src/Shomei/Jwt/Sign.hs`
exports `signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)`, and the
`TokenSigner` effect already exposes a workflow-friendly `signAccessToken` operation over
`AuthClaims`. `claimsFromAuth` serializes the `scopes` list and optional `act` claim; no verifier
change is needed for scoped service tokens.

The normal session workflow still issues empty scopes by design. `buildClaims` in
`shomei-core/src/Shomei/Workflow/Session.hs` sets `scopes = Set.empty`, `roles = Set.empty`, and
`actor = Nothing`. This is good: the new service-token workflow must be separate from login,
signup, refresh, MFA, and passwordless flows so the human-token behavior stays observable and
unchanged.

There is no existing service-account persistence model. Users are already generic principals after
SH-25: `SignupRequest` and `LoginRequest` accept a `loginId` with optional email, and tests prove a
login id such as `agent-x` can exist without email. Adding a new database table for service
accounts would make this change much larger than the request's "minor addition" framing. The plan
therefore uses an append-only `serviceTokenConfig` in `ShomeiConfig`: each service account entry
names an existing `UserId`, a shared secret hash, and the allowed scopes for that account.

The impersonation workflow is related but not reusable wholesale. `Shomei.Workflow.Impersonation`
already mints a refresh-less access token with an `act` claim, but it intentionally targets human
support impersonation, enforces a caller-held `impersonate:user` scope and token freshness, creates
a delegated session for a target user, and emits impersonation audit events. Service-token issuance
needs the same low-level pattern of a refresh-less signed token, but different policy and different
audit semantics.

The repository follows the record conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`: new records should not
prefix every field with the type name, fields stay strict, command and event data put the entity id
first, and new modules that use `#field` lenses import `Data.Generics.Labels ()` locally. The M1
implementation therefore uses fields such as `accountId`, `userId`, `secretHash`, `allowedScopes`,
`enabled`, `ttl`, `accounts`, `secret`, `scopes`, and `actorId` rather than
`serviceAccountSecretHash` or `requestedScopes`.


## Decision Log

- Decision: Implement service-token issuance as a separate core workflow module,
  `shomei-core/src/Shomei/Workflow/ServiceToken.hs`, rather than modifying
  `Shomei.Workflow.Session.issueSession`.
  Rationale: Human login/session workflows must keep issuing empty-scoped tokens. A dedicated
  workflow gives service-token policy its own command type, tests, and errors while still reusing
  `buildClaims` and the `TokenSigner` effect.
  Date: 2026-06-21

- Decision: Store service-account authorization policy in append-only runtime configuration for
  this iteration, not in a new PostgreSQL service-account table.
  Rationale: The request is for the missing issuance path and explicitly calls it a minor addition.
  Existing users can already model service-account principals through `loginId`; configuration is
  enough to map a service account id to an existing `UserId`, a secret hash, and allowed scopes.
  Persistence can be added later without changing the token wire shape.
  Date: 2026-06-21

- Decision: The HTTP endpoint response returns an access token and lifetime only, with no refresh
  token.
  Rationale: Service tokens are machine credentials for coarse capability checks. Making them
  refreshable would introduce rotation and theft semantics that are not requested and would blur the
  boundary between service-account issuance and user sessions.
  Date: 2026-06-21

- Decision: Use a configured hashed secret per service account, verified with constant-time byte
  comparison, instead of treating a human password login as service-account authentication.
  Rationale: Reusing the login workflow would issue an ordinary token first, interact with MFA and
  lockout behavior, and would still need a second path to add scopes. A scoped issuance endpoint
  should authenticate the service account directly and only mint allowed scopes.
  Date: 2026-06-21

- Decision: Allow the optional `actorId` request field to populate `AuthClaims.actor` after
  checking that the actor user exists and is active.
  Rationale: The improvement request asks for optional `act` attribution for agent tokens. Requiring
  an existing active user avoids emitting actor ids that Shomei itself cannot resolve.
  Date: 2026-06-21

- Decision: Publish a `ServiceTokenIssued` audit event on successful issuance.
  Rationale: Shomei already persists security-relevant events through `AuthEventPublisher`, and
  service-token issuance is a credential minting action. The event can be added to the existing
  JSONB audit-event codec without a database migration.
  Date: 2026-06-21

- Decision: Follow the local Haskell record-pattern guide for all new service-token records by
  avoiding type-name field prefixes and using `#field` lens access in new code.
  Rationale: Shomei already enables `DuplicateRecordFields`, `OverloadedLabels`, `generic-lens`,
  and `lens`. The local guide explicitly rejects old-style record prefixes and keeps the generic
  lens orphan import local to modules that use it.
  Date: 2026-06-21


## Outcomes & Retrospective

To be filled during and after implementation. At completion this section must state which endpoint
shape shipped, which tests prove the token passes `verifyToken` and `requireScope`, and any follow-up
work deferred to a later plan.


## Context and Orientation

The repository is a Haskell multi-package Cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/shomei`. Its `mori.dhall` identifies Shomei as a Haskell
authentication toolkit with packages for core domain logic, JWT signing and verification, Servant
HTTP handlers, PostgreSQL interpreters, migrations, a standalone server, a Haskell client, and
examples.

The core package lives in `shomei-core/`. It contains transport-independent domain types,
workflow functions, and effect ports. An effect port is an abstract capability such as "find a
user", "create a session", or "sign a token"; workflows depend on ports and tests run them with
in-memory interpreters. The relevant files are:

`shomei-core/src/Shomei/Domain/Claims.hs` defines `Scope`, `Role`, and `AuthClaims`. A scope is a
text label carried in a JWT claim and enforced later by a receiving service. `AuthClaims.subject`
is the `sub` user id, `AuthClaims.sessionId` is the `sid` session id, and `AuthClaims.actor` is the
optional `act` user id for "on behalf of" attribution.

`shomei-core/src/Shomei/Workflow/Session.hs` defines `buildClaims` and `buildClaimsWith`. These
functions create ordinary login claims with issuer, audience, subject, session id, issue time, and
expiry. `buildClaims` currently sets empty scopes, empty roles, no actor, and no extra claims.
Service-token issuance must reuse this function as a base and then populate `scopes` and `actor`.

`shomei-core/src/Shomei/Workflow/Impersonation.hs` is the closest existing workflow pattern for
minting a refresh-less access token. It creates a session row, builds `AuthClaims`, calls the
`TokenSigner` effect, and publishes audit events. Read it before implementing M1, but keep the
service-token workflow separate because its authorization policy is different. Add the new audit
event constructor in `shomei-core/src/Shomei/Domain/Event.hs` and wire it through
`shomei-core/src/Shomei/Domain/EventCodec.hs`, where the event-to-`event_type` mapping is defined.

`shomei-core/src/Shomei/Config.hs` defines `ShomeiConfig`, the append-only runtime configuration
record. Existing plans have added sub-config records such as `ImpersonationConfig` and
`WebAuthnConfig`; service-token policy should follow that style by adding a `ServiceTokenConfig`
sub-record with defaults.

The JWT package lives in `shomei-jwt/`. `shomei-jwt/src/Shomei/Jwt/Sign.hs` turns `AuthClaims` into
a signed compact JWT; `shomei-jwt/src/Shomei/Jwt/Verify.hs` turns a valid compact JWT back into
`AuthClaims`. Do not change either module for this plan unless a test reveals a bug. The feature is
implemented by constructing the right `AuthClaims` before signing.

The Servant package lives in `shomei-servant/`. Servant is the Haskell web API library used here.
`shomei-servant/src/Shomei/Servant/API.hs` defines the route record `ShomeiAPI`. `DTO.hs` defines
JSON request and response types. `Handlers.hs` maps each route to a `Handler`. `Seam.hs` defines
`Env`, which carries the config, verifier, JWKS document, and the effect runner used by handlers.
`Authz.hs` exports `requireScope :: Scope -> AuthUser -> Handler ()`; this must keep working
unchanged for service tokens.

The standalone server package lives in `shomei-server/`. `shomei-server/src/Shomei/Server/Config.hs`
loads defaults, optional Dhall config, and environment variables into `ShomeiConfig`.
`config/shomei-types.dhall` is the typed shape for a config file, and `config/shomei.example.dhall`
is the example operators copy. `shomei-server/test/Shomei/Server/E2ESpec.hs` runs the real
standalone server against an ephemeral PostgreSQL database.


## Plan of Work

Milestone 0 confirms the baseline. From the repository root, run focused tests that should already
pass before any changes:

```bash
cabal test shomei-core shomei-servant shomei-jwt
```

The expected result is that all three suites finish successfully. If unrelated working-tree changes
make this fail, record the exact failure in Surprises & Discoveries and continue only after deciding
whether the failure touches this plan's files.

Milestone 1 adds the core workflow. In `shomei-core/src/Shomei/Config.hs`, add these public types
and defaults:

```haskell
newtype ServiceAccountId = ServiceAccountId Text

data ServiceAccountConfig = ServiceAccountConfig
  { accountId :: !ServiceAccountId,
    userId :: !UserId,
    secretHash :: !Text,
    allowedScopes :: !(Set Scope)
  }

data ServiceTokenConfig = ServiceTokenConfig
  { enabled :: !Bool,
    ttl :: !NominalDiffTime,
    accounts :: ![ServiceAccountConfig]
  }
```

Add `serviceTokenConfig :: !ServiceTokenConfig` to `ShomeiConfig`. `defaultServiceTokenConfig`
should disable issuance, set a short default TTL such as five minutes, and contain no accounts.
The default keeps existing deployments closed until an operator opts in.

In `shomei-core/src/Shomei/Error.hs`, add narrow errors rather than overloading impersonation
errors: `ServiceTokenDisabled`, `ServiceAccountNotFound`, `ServiceAccountSecretInvalid`,
`ServiceTokenScopeDenied`, and `ServiceTokenActorInvalid`. Map these later to HTTP 403 or 400 in
the Servant layer.

In `shomei-core/src/Shomei/Domain/Event.hs`, add `ServiceTokenIssuedData` with the service-account
user id, session id, service account id text, requested scopes, optional actor user id, and
occurred-at timestamp. Add a `ServiceTokenIssued ServiceTokenIssuedData` constructor to
`AuthEvent`. In `shomei-core/src/Shomei/Domain/EventCodec.hs`, map it to event type
`service_token_issued` in both `projectAuthEvent` and `reconstructAuthEvent`. No SQL migration is
needed because the existing audit table stores event type text plus JSON payload.

Create `shomei-core/src/Shomei/Workflow/ServiceToken.hs`. Define:

```haskell
data IssueServiceToken = IssueServiceToken
  { accountId :: !ServiceAccountId,
    secret :: !Text,
    scopes :: !(Set Scope),
    actorId :: !(Maybe UserId)
  }

data IssuedServiceToken = IssuedServiceToken
  { accessToken :: !AccessToken,
    expiresIn :: !NominalDiffTime,
    sessionId :: !SessionId
  }

issueServiceToken ::
  ( UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  IssueServiceToken ->
  Eff es (Either AuthError IssuedServiceToken)
```

The workflow checks `enabled`, finds the configured service account by `ServiceAccountId`,
verifies the supplied secret against `secretHash`, rejects an empty requested scope set, rejects
any requested scope outside the configured allowed set, checks that the service account user exists
and is active, checks that the optional actor user exists and is active, creates a session row for
the service account user with `actor = actorId`, builds
claims with `buildClaims cfg serviceUserId sessionId ts`, overrides `expiresAt` to
`ts + ttl`, populates `scopes = scopes`, sets `actor = actorId`, and signs
with the existing `TokenSigner.signAccessToken`. It does not create a refresh token.
After signing, publish `ServiceTokenIssued` with the service account id, subject user id, session
id, requested scopes, optional actor id, and timestamp.

Use a constant-time comparison for the shared secret. A practical implementation is to store
`secretHash` as a SHA-256 hex digest in configuration, hash the presented secret with
the same SHA-256 helper used for account keys if one is available in this tree, and compare the
encoded bytes with a constant-time equality function from existing crypto dependencies. If no
project helper exists, add a tiny helper in the service-token workflow or a private core module and
document the exact format in `docs/api.md`. Do not store plaintext service secrets in
`ShomeiConfig`.

Add `shomei-core/test/Shomei/Workflow/ServiceTokenSpec.hs` and include it from
`shomei-core/test/Main.hs`. Mirror the style of `Workflow/ImpersonationSpec.hs`: use
`emptyWorld`, `runInMemory`, deterministic time, and the in-memory signer that renders claims as
JSON. Test at least the happy path, disabled config, unknown account id, bad secret, disallowed
scope, inactive service-account user, invalid actor, empty requested scope set, "no refresh token
was created", and "a `ServiceTokenIssued` event was published only on success".

Milestone 2 exposes the route in the Servant package. In
`shomei-servant/src/Shomei/Servant/DTO.hs`, add:

```haskell
data ServiceTokenRequest = ServiceTokenRequest
  { accountId :: !Text,
    secret :: !Text,
    scopes :: ![Text],
    actorId :: !(Maybe Text)
  }

data ServiceTokenResponse = ServiceTokenResponse
  { accessToken :: !Text,
    expiresIn :: !Int
  }
```

In `shomei-servant/src/Shomei/Servant/API.hs`, add an unauthenticated route under the existing
`/auth` namespace:

```haskell
serviceToken ::
  mode
    :- "auth"
      :> "service-token"
      :> ReqBody '[JSON] ServiceTokenRequest
      :> Post '[JSON] ServiceTokenResponse
```

Unauthenticated here means the endpoint does not require a bearer access token. It authenticates
with the service-account id and secret in the JSON body. In
`shomei-servant/src/Shomei/Servant/Handlers.hs`, parse requested scopes into `Scope`, parse
`actorId` with `parseId`, call `ServiceToken.issueServiceToken`, and render
`ServiceTokenResponse`. Return JSON `400` for malformed ids or empty scopes and mapped `403` for
disabled issuance, unknown account, bad secret, or disallowed scope.

Extend `shomei-servant/test/Main.hs`. Add a host test route such as:

```haskell
"ingest" :> Authenticated :> Get '[JSON] [UserResponse]
```

or a simpler response type, guarded by `requireScope (Scope "kawa:ingest")`. Configure one service
account in the test `cfg`, seed its user in the in-memory world, call `POST /auth/service-token`
requesting `kawa:ingest`, verify the response contains an access token and no refresh token, call
the guarded route with the service token and observe HTTP 200, then call the same guarded route
with a normal login token and observe HTTP 403. Also test requesting an unconfigured scope returns
403.

Milestone 3 wires standalone configuration and documentation. In
`shomei-server/src/Shomei/Server/Config.hs`, add optional `FileConfig` fields for service-token
settings. Because `FileConfig` is flat today, prefer a JSON-friendly Dhall-rendered list for service
accounts if `dhall-to-json` decodes it cleanly:

```haskell
data FileServiceAccount = FileServiceAccount
  { accountId :: !Text,
    userId :: !Text,
    secretSha256 :: !Text,
    allowedScopes :: ![Text]
  }
```

Then add optional service-token fields without type-name prefixes where the surrounding
`FileConfig` shape allows it, such as an optional nested service-token config containing `enabled`,
`ttlSeconds`, and `accounts :: Maybe [FileServiceAccount]`. Parse `userId` with `parseId`, parse
each scope as `Scope`, and fail boot loudly if a configured id is malformed or an enabled service
account has no allowed scopes. Add environment-variable support for simple deployments, for example
`SHOMEI_SERVICE_TOKEN_ENABLED`, `SHOMEI_SERVICE_TOKEN_TTL`, and
`SHOMEI_SERVICE_ACCOUNTS_JSON` containing the same list shape as compact JSON. If this JSON env
shape proves too awkward, document Dhall-only service account configuration and keep environment
variables to the global enabled/TTL toggles.

Update `config/shomei-types.dhall` and `config/shomei.example.dhall` with the new fields. Keep the
example disabled by default and use placeholder ids and hashes.

Update `docs/api.md` with `POST /auth/service-token`, request and response bodies, error codes,
the SHA-256 secret hash format, and the key behavioral guarantee: normal login tokens still carry
empty scopes, while service tokens carry only scopes allowed by the configured account.

Extend `shomei-server/test/Shomei/Server/E2ESpec.hs` only if the test can seed the service-account
user id into configuration after signup. The easiest path is to start with a config containing no
accounts, sign up a service principal through the normal API, then run a smaller in-process app for
the service-token scenario with a config that references the created user id and the known secret
hash. If that makes the PostgreSQL scenario too tangled, keep the full behavior in
`shomei-servant/test/Main.hs` and add a `Shomei.Server.ConfigSpec` case proving Dhall/env parsing
builds the intended `ServiceTokenConfig`.

Milestone 4 validates and records the outcome. Run formatting first, then build and tests:

```bash
nix fmt
cabal build all
cabal test shomei-core shomei-servant shomei-server shomei-jwt
```

If `nix fmt` is unavailable, run the repository's established formatter command from the
`Justfile` or `flake.nix`, record the substitute command here, and include the result in Progress.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
```

Before editing, inspect the current files:

```bash
sed -n '1,220p' shomei-core/src/Shomei/Config.hs
sed -n '1,180p' shomei-core/src/Shomei/Workflow/Session.hs
sed -n '1,220p' shomei-core/src/Shomei/Workflow/Impersonation.hs
sed -n '1,260p' shomei-servant/src/Shomei/Servant/API.hs
sed -n '1,260p' shomei-servant/src/Shomei/Servant/DTO.hs
sed -n '1,360p' shomei-servant/src/Shomei/Servant/Handlers.hs
```

Run the baseline tests:

```bash
cabal test shomei-core shomei-servant shomei-jwt
```

Expected high-level output:

```text
All tests passed
```

Implement Milestone 1. Add `ServiceTokenConfig` and service account types to
`shomei-core/src/Shomei/Config.hs`, add service-token errors to
`shomei-core/src/Shomei/Error.hs`, add `shomei-core/src/Shomei/Workflow/ServiceToken.hs`, expose the
module in `shomei-core/shomei-core.cabal`, and add the service-token spec to
`shomei-core/test/Main.hs`.

Validate Milestone 1:

```bash
cabal test shomei-core
```

Implement Milestone 2. Add DTOs, route, handler, error mapping, and in-process HTTP tests in
`shomei-servant/`.

Validate Milestone 2:

```bash
cabal test shomei-servant
```

Implement Milestone 3. Add server configuration parsing, update Dhall examples, update
`docs/api.md`, and add either a config test or a PostgreSQL E2E scenario depending on which gives a
clear, maintainable proof.

Validate Milestone 3:

```bash
cabal test shomei-server
```

Finish with the full checks:

```bash
nix fmt
cabal build all
cabal test shomei-core shomei-servant shomei-server shomei-jwt
```


## Validation and Acceptance

The implementation is accepted when these behaviors are observable:

A configured service account can mint a token with an allowed scope. With a service account whose
allowed scopes include `kawa:ingest`, this request succeeds:

```json
{
  "accountId": "connector:shinzui/rei",
  "secret": "test-secret",
  "scopes": ["kawa:ingest"],
  "actorId": null
}
```

The response has this shape and contains no refresh token:

```json
{
  "accessToken": "<compact-jwt>",
  "expiresIn": 300
}
```

The token verifies through `Shomei.Jwt.Verify.verifyToken` with the existing JWKS and decodes to
claims whose `scopes` set contains exactly `Scope "kawa:ingest"` plus any other requested allowed
scopes, whose `subject` is the configured service-account user id, and whose `actor` equals the
optional `actorId` only when provided.

A Servant route guarded by `requireScope (Scope "kawa:ingest")` returns HTTP 200 when called with
the service token. The same route returns HTTP 403 when called with a normal login token created by
`POST /auth/login`, proving the human login flow still issues empty scopes.

Unauthorized issuance requests fail closed. Unknown service account ids, invalid secrets, disabled
service-token issuance, and scopes outside the account's allowed set return 403 with a structured
JSON error body. Malformed actor ids and syntactically bad requests return 400. No failing request
creates a session or signs a token.

The JWT signing and verification modules do not need downstream changes. No changes are made to
`Shomei.Jwt.Verify.verifyToken`, JWKS publication, key rotation, login/signup/session refresh,
WebAuthn/passkeys, or consumer-side fine-grained grant tables.


## Idempotence and Recovery

The implementation is additive. Re-running the tests is safe. Re-running formatting is safe. The
new configuration defaults must leave service-token issuance disabled, so simply deploying the new
binary without service-token config must preserve current behavior.

If tests fail after editing `ShomeiConfig`, inspect every record construction of `ShomeiConfig` and
add the new `serviceTokenConfig` field. Most call sites use `defaultShomeiConfig`; direct record
constructions in tests are the likely failures.

If route-level tests fail with 401 instead of 403, the token did not authenticate. Inspect the
verifier configuration, issuer, audience, and JWKS used by the test app. If they fail with 403
instead of 200, inspect the decoded `AuthClaims.scopes` from the minted service token and verify
that the route uses exactly the same `Scope` text.

If standalone config parsing becomes too large, keep service-account lists Dhall-only for this plan
and document that choice in the Decision Log. The endpoint and core workflow should not depend on
which external configuration source populated `ServiceTokenConfig`.

Do not remove or rewrite existing session, refresh-token, impersonation, or JWT verification code
while implementing this plan. If a change appears necessary there, record the evidence in Surprises
& Discoveries before editing.


## Interfaces and Dependencies

The plan relies on project-local modules and existing dependencies:

`Shomei.Domain.Claims` supplies `Scope`, `AuthClaims`, and the `actor` field. Service-token issuance
must construct ordinary `AuthClaims`; it must not introduce a parallel JWT claim type.

`Shomei.Workflow.Session.buildClaims` supplies the base issuer, audience, subject, session id,
issued-at, expiry, roles, actor, and extra-claims behavior. The service-token workflow should call
it and override only `expiresAt`, `scopes`, and `actor`.

`Shomei.Effect.TokenSigner.signAccessToken` is the workflow-level signing dependency. The workflow
must use this effect rather than importing `Shomei.Jwt.Sign.signAccessToken`, so it remains
transport- and interpreter-independent.

`Shomei.Effect.SessionStore.createSession` records the service-token session. The workflow must not
call `Shomei.Effect.RefreshTokenStore.createRefreshToken`.

`Shomei.Effect.AuthEventPublisher.publishAuthEvent` records successful issuance through the existing
audit trail. Add `ServiceTokenIssued` to `Shomei.Domain.Event` and keep
`Shomei.Domain.EventCodec.projectAuthEvent` and `reconstructAuthEvent` in lockstep.

`Shomei.Effect.UserStore.findUserById` verifies that the configured service account user and
optional actor user exist and are active.

`Shomei.Servant.Authz.requireScope` is the unchanged downstream gate used in tests to prove the
token works.

`shomei-server/src/Shomei/Server/Config.hs` owns Dhall and environment parsing. It should convert
textual configured ids and scopes into typed `UserId` and `Scope` values before they reach request
handlers.

The only dependency-sensitive code is the shared-secret hash and constant-time comparison. Before
implementing that helper, inspect the existing project and registered dependencies with `mori` and
the local source tree. Prefer existing cryptographic packages already depended on by Shomei, such
as `crypton` or a project-local helper, over adding a new package.
