---
id: 41
slug: database-backed-service-accounts-with-oauth2-client-credentials-grant
title: "Database-Backed Service Accounts with OAuth2 Client-Credentials Grant"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# Database-Backed Service Accounts with OAuth2 Client-Credentials Grant

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei (this repository) is a Haskell authentication toolkit. Today it can mint scoped,
short-lived machine tokens for services, but only through a bespoke endpoint
(`POST /auth/service-token`) whose service accounts live in static runtime configuration.
That has two consequences an operator feels immediately. First, creating, rotating, or
revoking a service credential requires editing config and redeploying the server — there is
no runtime lifecycle. Second, no off-the-shelf OAuth2 client library can talk to the bespoke
endpoint, so every consumer writes custom token-fetching code.

After this plan, both problems are gone. Service accounts become rows in PostgreSQL that an
operator manages at runtime with `shomei-admin service-accounts create|rotate-secret|revoke|list`,
with the secret generated server-side and shown exactly once. And Shōmei gains
`POST /oauth/token`, the standard OAuth2 token endpoint (RFC 6749), accepting
`application/x-www-form-urlencoded` bodies with `grant_type=client_credentials` and standard
client authentication (`client_secret_basic` and `client_secret_post`). Any stock OAuth2
client — Spring, ASP.NET, Go's `clientcredentials` package, `curl` — can fetch a token with
zero Shōmei-specific code:

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=client_credentials&scope=kawa:ingest' \
  http://localhost:8080/oauth/token
# -> {"access_token":"<jwt>","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

The returned token is signed by the existing key machinery, verifies against the existing
`/.well-known/jwks.json`, carries the requested scopes, and passes the existing
`requireScope` guard downstream — exactly like today's service tokens. The old
config-defined accounts and `POST /auth/service-token` keep working through a deprecation
window (see Decision Log), so nothing breaks for existing deployments.

This plan also owns, on behalf of the sibling plans in the same MasterPlan
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`), the token-endpoint
skeleton: the `grant_type` dispatcher that later plans extend with `authorization_code` and
`refresh_token` (plan `docs/plans/42-oidc-provider-subset-discovery-authorization-code-with-pkce-introspection.md`)
and `urn:ietf:params:oauth:grant-type:token-exchange`
(plan `docs/plans/43-rfc-8693-token-exchange-endpoint.md`); the client-authentication
helper; and the RFC 6749 §5.2 error shape, which is deliberately distinct from the
application-wide error envelope.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `shomei_service_accounts` migration written and applied (`just migrate` shows it).
- [ ] M1: `ServiceAccountDbId` TypeID and `ServiceAccount` domain record added to `shomei-core`.
- [ ] M1: `ServiceAccountStore` effect port with smart constructors.
- [ ] M1: In-memory interpreter (`Shomei.Effect.InMemory`) with new `World` field.
- [ ] M1: Postgres interpreter `Shomei.Postgres.ServiceAccountStore` with round-trip test.
- [ ] M1: Audit events `ServiceAccountCreated` / `ServiceAccountSecretRotated` / `ServiceAccountRevoked` in `Event.hs` + `EventCodec.hs` + codec spec.
- [ ] M2: `Shomei.Workflow.ClientCredentials` workflow with unit tests (happy path, bad secret, revoked account, scope violations, no refresh token).
- [ ] M2: New `AuthError` constructors and their HTTP mappings.
- [ ] M3: `http-api-data` + `base64` added to `shomei-servant.cabal`; `FormUrlEncoded` route compiles.
- [ ] M3: `Shomei.Servant.OAuth` module: RFC 6749 error rendering, client-auth extraction, grant dispatcher.
- [ ] M3: `POST /oauth/token` route + handler wired; in-process HTTP tests for both client-auth methods and all error codes.
- [ ] M3: OpenAPI: route documented, path-count assertion bumped to 25, spec regenerated.
- [ ] M4: `shomei-admin service-accounts create|rotate-secret|revoke|list` subcommands with admin test coverage.
- [ ] M5: Deprecation notes + migration path in `docs/user/service-tokens.md` and `docs/user/api.md`.
- [ ] M5: `shomei-client` support for the token endpoint.
- [ ] M5: Postgres E2E scenario: create account, fetch token over HTTP, call a scope-guarded route.
- [ ] Final: `nix fmt`, `cabal build all`, `cabal test all` green; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Store service-account secrets as SHA-256 hex digests of server-generated
  256-bit random secrets, compared in constant time — not Argon2id.
  Rationale: Argon2id exists to slow brute-force of low-entropy, human-chosen passwords.
  These secrets are never human-chosen: the CLI generates 32 random bytes and prints them
  once, so a preimage attack on SHA-256 of a 256-bit value is computationally infeasible.
  This also matches the existing config-defined accounts (`Shomei.Workflow.ServiceToken`
  already stores lowercase 64-char SHA-256 hex and compares with `Data.ByteArray.constEq`),
  letting both paths share one verification function, and keeps the token endpoint fast
  (an Argon2id verify per token request would be a self-inflicted DoS vector).
  Date: 2026-07-07

- Decision: Every database-backed service account owns a dedicated row in `shomei_users`
  (created automatically by `shomei-admin service-accounts create`, `login_id` set to the
  account's `client_id`, no password credential).
  Rationale: `AuthClaims.subject` is a `UserId`, and `shomei_sessions.user_id` has a foreign
  key to `shomei_users(user_id)` — a token cannot be minted without a user row backing its
  session. Users are already generic principals (login id without email is supported), so
  this reuses `/auth/me`, session revocation, and audit queries unchanged. The config-defined
  accounts already work exactly this way (operator supplies a `userId`); the CLI merely
  automates the provisioning.
  Date: 2026-07-07

- Decision: `POST /oauth/token` lives at the unversioned root path `/oauth/token`.
  Rationale: The MasterPlan's versioning rule (Integration Points in
  `docs/masterplans/7-interop-wave-standards-based-auth-surface.md`): `/oauth/*` and
  `/.well-known/*` are protocol-conventional locations that OAuth2/OIDC tooling expects;
  versioning them would break the auto-configuration that motivates this wave. Application
  routes move under `/v1` in plan 40; this endpoint is exempt.
  Date: 2026-07-07

- Decision: Token-endpoint errors use the RFC 6749 §5.2 JSON shape
  (`{"error": "...", "error_description": "..."}`, HTTP 400, or 401 for `invalid_client`),
  NOT the application-wide error envelope produced by
  `Shomei.Servant.Error.authErrorToServerError` (and not the plan-40 problem-details
  envelope once that lands).
  Rationale: Stock OAuth2 clients parse the RFC shape by field name; wrapping it would break
  them. This boundary is deliberate and permanent: everything under `/oauth/*` speaks the
  OAuth wire protocol, everything else speaks the application envelope. Both this plan and
  plan 40 document the boundary.
  Date: 2026-07-07

- Decision: If the `scope` parameter is omitted from a `client_credentials` request, the
  issued token carries all of the account's `allowed_scopes`; if present, the requested set
  must be a non-empty subset of `allowed_scopes` or the request fails with `invalid_scope`.
  Rationale: RFC 6749 §3.3 permits a server-defined default when `scope` is absent, and
  "everything the account is allowed" is the least surprising default for machine
  credentials. The subset rule reproduces the existing `Set.isSubsetOf` check in
  `Shomei.Workflow.ServiceToken`. The response always echoes the granted `scope` so clients
  need not guess.
  Date: 2026-07-07

- Decision: `allowed_scopes` is stored as a `jsonb` array column, not `text[]`.
  Rationale: House style — the existing schema stores list-shaped data as `jsonb` (see
  `transports jsonb` in `2026-06-18-10-33-55-shomei-webauthn-credentials.sql`), and the
  hasql codecs in `shomei-postgres` already have patterns for jsonb round-trips. No query
  in this plan needs SQL-level array operators.
  Date: 2026-07-07

- Decision: Successful issuance through the new grant publishes the existing
  `ServiceTokenIssued` audit event, with `accountId` carrying the `client_id` text.
  Rationale: `ServiceTokenIssuedData.accountId :: ServiceAccountId` is a newtype over
  `Text`, so the wire shape is unchanged and audit consumers see one event type for
  "a machine token was minted" regardless of which path minted it. New lifecycle events
  (created/rotated/revoked) are added separately.
  Date: 2026-07-07

- Decision: Config-defined service accounts and `POST /auth/service-token` keep working
  unchanged through a deprecation window; removal is deferred to the `/v1` major-version
  boundary established by plan 40's successors.
  Rationale: Per the MasterPlan Decision Log — both are documented, shipped surface, and the
  standards-based replacement must prove itself before removal. This plan adds deprecation
  notes and a concrete migration recipe to `docs/user/service-tokens.md`.
  Date: 2026-07-07

- Decision: The token endpoint accepts the raw `Form` type
  (`Web.FormUrlEncoded.Form` from `http-api-data`) rather than a typed request record.
  Rationale: The endpoint is a dispatcher: plans 42 and 43 add grants whose parameter sets
  differ (`code`, `code_verifier`, `subject_token`, ...). A raw `Form` lets each grant
  extract its own parameters and return precise `invalid_request` errors, without a
  parameter union that changes shape every plan. Typed records remain in the response
  direction, where the shape is fixed.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository is a multi-package Haskell Cabal project rooted at
`/Users/shinzui/Keikaku/bokuno/shomei`, built with GHC 9.12.4 inside a Nix dev shell
(`nix develop`). Build with `cabal build all`; test with `cabal test all`. The dev database
is created and migrated with `just create-database` (which needs the Nix shell's Postgres
environment). Formatting is `nix fmt`.

The packages you will touch, and what each does:

- `shomei-core/` — transport-independent domain types, workflows, and *effect ports*. An
  effect port is a typed capability declared with the `effectful` library as a GADT (for
  example `SessionStore` in `shomei-core/src/Shomei/Effect/SessionStore.hs`: constructors
  like `CreateSession :: NewSession -> SessionStore m Session`, a
  `type instance DispatchOf SessionStore = Dynamic`, and one `send`-wrapping smart
  constructor per operation). Workflows depend on ports; tests run them against in-memory
  interpreters in `shomei-core/src/Shomei/Effect/InMemory.hs` (a `World` record of `Map`s
  behind an `IORef`, one `runXStore` interpreter per port, all composed in `runInMemory`).
- `shomei-postgres/` — hasql-based Postgres interpreters, one module per port (for example
  `shomei-postgres/src/Shomei/Postgres/SessionStore.hs`), each written as
  `interpret_ \case ...` issuing SQL through the `Database` effect.
- `shomei-migrations/` — SQL migrations managed by the `codd` tool. Files live in
  `shomei-migrations/sql-migrations/` and are named
  `YYYY-MM-DD-HH-MM-SS-shomei-<name>.sql`. Critically, they are embedded into the binary at
  compile time by a Template Haskell `embedDir` splice, so a new `.sql` file is invisible
  until `shomei-migrations` recompiles — `just migrate` touches
  `shomei-migrations/shomei-migrations.cabal` first for exactly this reason. Scaffold new
  files with `just new-migration name=<slug>`.
- `shomei-servant/` — the HTTP layer: the `ShomeiAPI` NamedRoutes record in
  `shomei-servant/src/Shomei/Servant/API.hs`, DTOs in `DTO.hs`, handlers in `Handlers.hs`,
  the error mapping in `Error.hs`, and the OpenAPI assembly in `OpenApi.hs`.
- `shomei-server/` — the standalone Warp server. `Shomei.Server.App` defines the full
  effect stack (`AppEffects`) and `runAppIO`; `Shomei.Server.Boot` wires config, pool, keys,
  and the WAI application. `shomei-server/app/Admin.hs` is the `shomei-admin` CLI
  (optparse-applicative; existing subcommands: `migrate`, `keys ...`, `users create`,
  `audit ...`), which connects via `Shomei.Admin.Env.loadAdminEnv` reading `DATABASE_URL`.
- `shomei-client/` — a servant-client derived with `genericClient` from the same
  `ShomeiAPI` record, plus thin ergonomic wrappers in `shomei-client/src/Shomei/Client.hs`.

What exists today for service tokens (verified against the working tree):

`shomei-core/src/Shomei/Config.hs` defines `ServiceTokenConfig { enabled, ttl, accounts }`
where each `ServiceAccountConfig` carries `accountId :: ServiceAccountId` (a newtype over
`Text`), `userId :: UserId`, `secretHash :: Text` (lowercase 64-char SHA-256 hex), and
`allowedScopes :: Set Scope`. Defaults: disabled, five-minute TTL, no accounts.

`shomei-core/src/Shomei/Workflow/ServiceToken.hs` implements
`issueServiceToken :: (UserStore :> es, SessionStore :> es, TokenSigner :> es, AuthEventPublisher :> es, Clock :> es) => ShomeiConfig -> IssueServiceToken -> Eff es (Either AuthError IssuedServiceToken)`.
It checks `enabled`, looks up the config account, verifies the secret with

```haskell
verifyServiceSecret :: Text -> Text -> Bool
verifyServiceSecret expectedHash presentedSecret =
    let expected = TE.encodeUtf8 (Text.toLower expectedHash)
        actual = TE.encodeUtf8 (sha256Hex presentedSecret)
     in expected `BA.constEq` actual
```

(`sha256Hex` is exported from the same module; `BA.constEq` is `Data.ByteArray.constEq`,
a constant-time comparison), rejects empty requested scopes, enforces that the requested
scopes are a subset of `account.allowedScopes`, requires the backing user (and optional
actor) to be `UserActive`, creates a *refresh-less* session (a `NewSession` for which no
refresh token is ever minted, so the credential dies at its TTL), builds claims with
`Shomei.Workflow.Session.buildClaims` overriding `expiresAt`/`scopes`/`actor`, signs via
the `TokenSigner` effect, and publishes `Event.ServiceTokenIssued`.

`shomei-servant/src/Shomei/Servant/API.hs` exposes it as `POST /auth/service-token` (JSON
body). The route record has no `/v1` prefix (that arrives with plan 40) and no form-encoded
route anywhere: a repo-wide grep for `FormUrlEncoded`, `ToForm`, `FromForm` returns nothing,
and `http-api-data` is a direct dependency only of `shomei-core` (for TypeID
`FromHttpApiData` orphans). Adding the OAuth endpoint therefore requires new dependencies
in `shomei-servant` (Milestone 3).

IDs use the TypeID pattern from `shomei-core/src/Shomei/Id.hs`: `mmzk-typeid`'s
`KindID` with a type-level prefix, for example `type UserId = KindID "user"` with
`genUserId = KindID.genKindID @"user"`, `idText` to render, `parseId` to parse, and
`getUUID`/`decorateKindID` to convert to and from the plain `uuid` stored in Postgres.

Error mapping: `Shomei.Servant.Error.authErrorToServerError :: AuthError -> ServerError`
renders `{"error": <code>, "message": <text>}` JSON. That envelope is *not* used at
`/oauth/token` (see Decision Log) — the new `Shomei.Servant.OAuth` module renders the
RFC 6749 shape instead.

OpenAPI: `shomei-servant/src/Shomei/Servant/OpenApi.hs` builds `shomeiOpenApi` from the
route record via `servant-openapi`/`openapi-hs` (pinned forks in `cabal.project`); the
committed spec is `docs/api/openapi.json`, regenerated byte-identically with
`cabal run shomei-openapi > docs/api/openapi.json`; and the conformance suite
`shomei-servant/test-openapi/Main.hs` asserts spec version 3.1.0, validates every JSON
body's `ToJSON` against its `ToSchema`, and hard-codes the path count (currently 24 — this
plan makes it 25).

Embedded protocol knowledge — RFC 6749 in brief, so no external reading is needed. The
token endpoint is a POST accepting `application/x-www-form-urlencoded` parameters. The
`grant_type` parameter selects the flow; this plan implements `client_credentials` (§4.4):
the client authenticates as itself and receives an access token for its own identity, with
no user interaction and no refresh token. Client authentication (§2.3.1) comes in two forms
this plan supports: `client_secret_basic` — an
`Authorization: Basic base64(client_id:client_secret)` header — and `client_secret_post` —
`client_id` and `client_secret` as body parameters. A successful response (§5.1) is HTTP
200 JSON with `access_token`, `token_type` (here always `Bearer`), `expires_in` (seconds),
and `scope` (space-delimited), and MUST carry `Cache-Control: no-store`. An error response
(§5.2) is JSON `{"error": <code>, "error_description": <human text>}` with codes
`invalid_request` (malformed/missing parameters), `invalid_client` (client authentication
failed — HTTP 401, and if the client attempted Basic auth the response includes
`WWW-Authenticate: Basic realm="shomei"`), `invalid_grant`, `unauthorized_client`
(this client may not use this grant type), `unsupported_grant_type`, and `invalid_scope`;
all except `invalid_client` are HTTP 400.

Background study only (no code reuse — different language and license): Zitadel's client
credentials handler at
`/Users/shinzui/Keikaku/hub/zitadel/internal/api/oidc/token_client_credentials.go`
follows the same shape: upstream client-secret authentication resolves a machine account,
requested scopes are validated against what the client may hold, and the response is a
standard access-token response with no refresh token. This confirms the protocol mapping
chosen here is the conventional one.


## Plan of Work

The work is five milestones. Each is independently verifiable with the commands shown in
Concrete Steps. Run everything from the repository root inside `nix develop`.

### Milestone M1 — Service accounts persist in PostgreSQL

Scope: the database table, domain type, effect port, both interpreters, and lifecycle audit
events. At the end, a round-trip test proves a service account can be created, found by
client id, secret-rotated, and revoked, in both the in-memory and Postgres interpreters —
no HTTP yet.

Create the migration with `just new-migration name=shomei-service-accounts`, then fill the
generated file (it already carries the `-- codd: in-txn` pragma and
`SET search_path TO shomei, pg_catalog;` header):

```sql
CREATE TABLE IF NOT EXISTS shomei_service_accounts (
  service_account_id uuid PRIMARY KEY,
  client_id          text NOT NULL UNIQUE,
  user_id            uuid NOT NULL REFERENCES shomei_users(user_id),
  secret_hash        text NOT NULL,
  display_name       text NOT NULL,
  allowed_scopes     jsonb NOT NULL,
  status             text NOT NULL,
  created_at         timestamptz NOT NULL,
  rotated_at         timestamptz NULL,
  revoked_at         timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_service_accounts_user_id_idx
  ON shomei_service_accounts (user_id);
```

`status` is `'active'` or `'revoked'`. `client_id` is the TypeID text rendering of
`service_account_id` (prefix `svcacct`), so it is unique and copy-pasteable; secrecy lives
entirely in the secret, not the identifier.

In `shomei-core/src/Shomei/Id.hs`, add the id type following the existing pattern exactly:

```haskell
type ServiceAccountDbId = KindID "svcacct"

genServiceAccountDbId :: (MonadIO m) => m ServiceAccountDbId
genServiceAccountDbId = KindID.genKindID @"svcacct"

serviceAccountDbIdToUUID :: ServiceAccountDbId -> UUID
serviceAccountDbIdToUUID = getUUID

serviceAccountDbIdFromUUID :: UUID -> ServiceAccountDbId
serviceAccountDbIdFromUUID = decorateKindID
```

(The name carries `Db` to avoid clashing with the existing config-side
`ServiceAccountId` newtype in `Shomei.Config`, which stays untouched.)

Create `shomei-core/src/Shomei/Domain/ServiceAccount.hs` with the domain record and a
status enum, following the record conventions used everywhere in this tree (no type-name
field prefixes, strict fields):

```haskell
data ServiceAccountStatus = ServiceAccountActive | ServiceAccountRevoked

data ServiceAccount = ServiceAccount
  { serviceAccountId :: !ServiceAccountDbId,
    clientId :: !Text,
    userId :: !UserId,
    secretHash :: !Text,
    displayName :: !Text,
    allowedScopes :: !(Set Scope),
    status :: !ServiceAccountStatus,
    createdAt :: !UTCTime,
    rotatedAt :: !(Maybe UTCTime),
    revokedAt :: !(Maybe UTCTime)
  }

data NewServiceAccount = NewServiceAccount
  { serviceAccountId :: !ServiceAccountDbId,
    clientId :: !Text,
    userId :: !UserId,
    secretHash :: !Text,
    displayName :: !Text,
    allowedScopes :: !(Set Scope),
    createdAt :: !UTCTime
  }
```

Create the port `shomei-core/src/Shomei/Effect/ServiceAccountStore.hs`:

```haskell
data ServiceAccountStore :: Effect where
  CreateServiceAccount :: NewServiceAccount -> ServiceAccountStore m ServiceAccount
  FindServiceAccountByClientId :: Text -> ServiceAccountStore m (Maybe ServiceAccount)
  ListServiceAccounts :: ServiceAccountStore m [ServiceAccount]
  RotateServiceAccountSecret :: ServiceAccountDbId -> Text -> UTCTime -> ServiceAccountStore m ()
  RevokeServiceAccount :: ServiceAccountDbId -> UTCTime -> ServiceAccountStore m ()

type instance DispatchOf ServiceAccountStore = Dynamic
```

plus one `send`-wrapping smart constructor per operation, mirroring
`Shomei/Effect/SessionStore.hs`. `RotateServiceAccountSecret` takes the *new hash* and the
timestamp; `RevokeServiceAccount` sets status and `revoked_at`.

Add the in-memory interpreter: a `serviceAccounts :: !(Map ServiceAccountDbId ServiceAccount)`
field on `World` in `shomei-core/src/Shomei/Effect/InMemory.hs`, initialized in
`emptyWorld`, a `runServiceAccountStore` interpreter, and its inclusion in `runInMemory`.
Add the Postgres interpreter `shomei-postgres/src/Shomei/Postgres/ServiceAccountStore.hs`
(`runServiceAccountStorePostgres`, constraints `(Database :> es, IOE :> es, Error AuthError :> es)`),
copying the statement/codec style of `Shomei/Postgres/PasskeyStore.hs`; scopes encode as a
jsonb array of scope texts.

Add the three lifecycle audit events in `shomei-core/src/Shomei/Domain/Event.hs`
(`ServiceAccountCreatedData { serviceAccountId :: Text, clientId :: Text, userId :: UserId, allowedScopes :: Set Scope, occurredAt :: UTCTime }`,
and analogous `ServiceAccountSecretRotatedData` / `ServiceAccountRevokedData` with
`serviceAccountId`, `clientId`, `occurredAt`), map them in `Shomei/Domain/EventCodec.hs` to
event types `service_account_created`, `service_account_secret_rotated`,
`service_account_revoked` (in both `projectAuthEvent` and `reconstructAuthEvent`), and
extend `shomei-core/test/Shomei/Domain/EventCodecSpec.hs` so the round-trip stays pinned.
No new migration is needed for events — the audit table stores type text plus JSONB payload.

Finally, register the new effect in all three stack declarations that must stay in the same
order: `AppEffects` in `shomei-servant/src/Shomei/Servant/Seam.hs`, `AppEffects` plus the
interpreter composition `runAppIO` in `shomei-server/src/Shomei/Server/App.hs`, and the
inline stack in `runInMemory`. Place `ServiceAccountStore` adjacent to the other stores
(for example right after `PasskeyStore`) identically in all three.

Acceptance for M1: `cabal test shomei-core` passes including a new
`ServiceAccountStoreSpec`; `cabal test shomei-postgres` passes including a Postgres
round-trip (create → find by client id → rotate → find shows new hash and `rotatedAt` →
revoke → status revoked); `just migrate` applies the new migration.

### Milestone M2 — Client-credentials workflow in the core

Scope: a pure-policy workflow that authenticates a database-backed client and mints the
token, sharing the signing path with the existing service tokens. At the end, unit tests
prove issuance and every refusal, still with no HTTP.

Create `shomei-core/src/Shomei/Workflow/ClientCredentials.hs`:

```haskell
data ClientCredentialsGrant = ClientCredentialsGrant
  { clientId :: !Text,
    clientSecret :: !Text,
    requestedScopes :: !(Maybe (Set Scope))   -- Nothing = scope parameter absent
  }

data GrantedToken = GrantedToken
  { accessToken :: !AccessToken,
    expiresIn :: !NominalDiffTime,
    grantedScopes :: !(Set Scope),
    sessionId :: !SessionId
  }

grantClientCredentials ::
  ( ServiceAccountStore :> es, UserStore :> es, SessionStore :> es,
    TokenSigner :> es, AuthEventPublisher :> es, Clock :> es ) =>
  ShomeiConfig -> ClientCredentialsGrant -> Eff es (Either AuthError GrantedToken)
```

The workflow: find the account by `clientId` (absent → new error `OAuthClientInvalid`);
verify the secret by reusing `verifyServiceSecret` — export it from
`Shomei.Workflow.ServiceToken` (it is already written there next to the exported
`sha256Hex`) so there is exactly one constant-time comparison in the codebase; a wrong
secret is also `OAuthClientInvalid` (indistinguishable from unknown client, matching the
existing no-disclosure policy where unknown account and bad secret share one error code);
require `status == ServiceAccountActive` (revoked → `OAuthClientInvalid` too — a revoked
credential must look exactly like a wrong one); resolve granted scopes per the Decision Log
(absent → all `allowedScopes`; present → must be non-empty and a subset, else
`OAuthScopeInvalid`); require the backing user to exist and be `UserActive`
(else `OAuthClientInvalid`); create a refresh-less session exactly as `issueServiceToken`
does (`NewSession` with `expiresAt = addUTCTime cfg.serviceTokenConfig.ttl ts` and
`actor = Nothing`, and never a refresh token); build claims with
`Shomei.Workflow.Session.buildClaims` then override `expiresAt` and `scopes`; sign via the
`TokenSigner` effect; publish `Event.ServiceTokenIssued` with
`accountId = ServiceAccountId account.clientId`. The TTL deliberately reuses
`serviceTokenConfig.ttl` (default five minutes) so both machine-token paths age
identically. Note the DB path does not consult `serviceTokenConfig.enabled` — that flag
gates only the config-account endpoint; database accounts are "enabled" by existing.

Add the `AuthError` constructors in `shomei-core/src/Shomei/Error.hs`:
`OAuthClientInvalid`, `OAuthScopeInvalid`, `OAuthGrantUnsupported`,
`OAuthRequestMalformed Text` (the text is a safe parameter-name hint for
`error_description`). Extend `authErrorToServerError` in
`shomei-servant/src/Shomei/Servant/Error.hs` with mappings (401/400) so the total `\case`
still compiles — but note the OAuth handler itself renders these through the RFC shape in
M3, not through this function; the mapping exists only so the constructors are total
everywhere.

Add `shomei-core/test/Shomei/Workflow/ClientCredentialsSpec.hs` mirroring
`Workflow/ServiceTokenSpec.hs` (in-memory `runInMemory`, deterministic clock, fake signer):
happy path with scope subset; happy path with omitted scope granting all allowed scopes;
unknown client; wrong secret; revoked account; inactive backing user; requested scope
outside allowed set; empty requested scope set; no refresh token created; audit event only
on success.

Acceptance for M2: `cabal test shomei-core` passes with the new spec.

### Milestone M3 — `POST /oauth/token` over HTTP

Scope: the form-encoded route, client authentication in both styles, the grant dispatcher,
the RFC 6749 error shape, and OpenAPI coverage. At the end, in-process HTTP tests fetch a
token both ways and observe every error code.

Dependencies first. In `shomei-servant/shomei-servant.cabal`, add `http-api-data` (for
`Web.FormUrlEncoded.Form` and the `FromForm`/`ToForm` classes that servant's
`FormUrlEncoded` content type needs) and `base64` (to decode the Basic header; `shomei-core`
already depends on this exact package, so no new transitive dependency enters the build
plan).

Create `shomei-servant/src/Shomei/Servant/OAuth.hs` and put all OAuth wire mechanics there,
keeping `Handlers.hs` thin:

```haskell
-- The RFC 6749 §5.2 error shape. NOT the application envelope: /oauth/* speaks
-- the OAuth wire protocol; see this plan's Decision Log.
oauthError :: Status -> Text -> Text -> ServerError
-- e.g. oauthError status400 "invalid_scope" "requested scope exceeds allowed_scopes"
-- Renders {"error":..., "error_description":...} with Content-Type: application/json
-- and Cache-Control: no-store. For status401 also add WWW-Authenticate: Basic realm="shomei".

data ClientAuth = ClientAuth { clientId :: !Text, clientSecret :: !Text }

-- Extract client credentials: Authorization Basic header wins; otherwise
-- client_id/client_secret body parameters; neither -> Left (invalid_client 401).
extractClientAuth :: Maybe Text -> Form -> Either ServerError ClientAuth

data TokenResponse = TokenResponse
  { accessToken :: !Text, tokenType :: !Text, expiresIn :: !Int, scope :: !Text }
-- Hand-written ToJSON/FromJSON with snake_case keys: access_token, token_type,
-- expires_in, scope (the RFC field names are not Haskell-style).
```

`extractClientAuth` for Basic: strip the `"Basic "` prefix, decode base64 with the
`base64` package, split on the first `:`. A malformed header is `invalid_client` 401 with
`WWW-Authenticate`. Build the JSON error bodies with `Data.Aeson.encode` of an object,
matching how `Error.hs` builds `ServerError` bodies today.

Add the route to `ShomeiAPI` in `shomei-servant/src/Shomei/Servant/API.hs`:

```haskell
oauthToken ::
  mode
    :- "oauth"
      :> "token"
      :> Header "Authorization" Text
      :> ReqBody '[FormUrlEncoded] Form
      :> Post '[JSON] (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] TokenResponse)
```

The `Header "Authorization" Text` is a plain optional header (`Maybe Text` in the handler),
deliberately *not* the `AuthProtect "shomei-jwt"` combinator — the caller is not a bearer
of a Shōmei token; it is an OAuth client authenticating with its own credentials. The
`Headers` wrapper exists because RFC 6749 §5.1 requires `Cache-Control: no-store` (and
conventionally `Pragma: no-cache`) on success; the handler returns
`addHeader "no-store" (addHeader "no-cache" body)`.

The handler in `Handlers.hs`, `oauthTokenH :: Env -> Maybe Text -> Form -> Handler (...)`,
is the *grant dispatcher* this plan owns. Read `grant_type` from the form
(`Web.FormUrlEncoded.lookupUnique`); absent → `invalid_request` 400. Dispatch:

- `"client_credentials"` → extract client auth, parse the optional `scope` parameter
  (split on single spaces into `Set Scope`; an explicitly empty `scope=` is
  `invalid_scope`), run `grantClientCredentials` through `env.runPorts` — and map failures
  through a local OAuth-specific mapping, not `authErrorToServerError`:
  `OAuthClientInvalid` → `oauthError status401 "invalid_client" ...`,
  `OAuthScopeInvalid` → `oauthError status400 "invalid_scope" ...`, anything else → a
  generic `invalid_request` 400 or 500 with a body in the same shape.
- any other value → `oauthError status400 "unsupported_grant_type" ...`. Plans 42 and 43
  extend exactly this case expression; leave a comment saying so.

Response on success: `TokenResponse` with `tokenType = "Bearer"`,
`expiresIn = round grantedToken.expiresIn`, `scope` = space-joined granted scopes.

OpenAPI: in `shomei-servant/src/Shomei/Servant/OpenApi.hs`, add a `ToSchema TokenResponse`
(hand-written to match the snake_case `ToJSON`). Check whether the pinned `servant-openapi`
fork provides `HasOpenApi` for `ReqBody '[FormUrlEncoded] Form`; if it does not, add an
instance in `OpenApi.hs` alongside the existing custom-combinator instances (the
`AuthProtect "shomei-jwt"` instance there is the pattern) that documents an
`application/x-www-form-urlencoded` request body with a free-form object schema. Then bump
the hard-coded path-count assertion in `shomei-servant/test-openapi/Main.hs` from 24 to 25,
add `Arbitrary`/`Show` for `TokenResponse`, and regenerate the committed spec.

HTTP tests in `shomei-servant/test/Main.hs`, following its existing in-process style: seed
a service account into the in-memory world (create the backing user too), then assert —
Basic-auth happy path returns 200 with
`access_token`/`token_type=Bearer`/`expires_in`/`scope` and `Cache-Control: no-store`;
`client_secret_post` happy path; the minted token passes a `requireScope`-guarded route;
wrong secret → 401 `{"error":"invalid_client",...}` with `WWW-Authenticate`; unknown
client → the same 401 body shape; scope outside allowed set → 400 `invalid_scope`; missing
`grant_type` → 400 `invalid_request`; `grant_type=password` → 400
`unsupported_grant_type`; and a normal login token still fails the scope-guarded route
with 403 (human tokens remain empty-scoped).

Acceptance for M3: `cabal test shomei-servant` passes (all three suites: the HTTP suite,
the OpenAPI conformance suite with count 25, and `validateEveryToJSON` including
`TokenResponse`); `git diff docs/api/openapi.json` shows exactly the new path.

### Milestone M4 — `shomei-admin service-accounts` lifecycle

Scope: runtime management. At the end, an operator with `DATABASE_URL` set can create,
list, rotate, and revoke accounts, and the secret is printed exactly once at creation and
rotation.

In `shomei-server/app/Admin.hs`, add a `ServiceAccounts ServiceAccountsCommand` arm to
`Command` and a subparser:

```haskell
data ServiceAccountsCommand
  = ServiceAccountsCreate { displayName :: Text, scopes :: [Text] }
  | ServiceAccountsRotateSecret { clientId :: Text }
  | ServiceAccountsRevoke { clientId :: Text }
  | ServiceAccountsList
```

Implement in a new `shomei-server/app/Shomei/Admin/ServiceAccounts.hs` (pattern:
`Shomei/Admin/Users.hs`). `create`: generate the id (`genServiceAccountDbId`), render
`client_id = idText`, generate a 32-byte random secret with `Crypto.Random.getRandomBytes`
(crypton — check the `shomei-admin` executable's `build-depends`; add `crypton` and a
base-encoding package if missing) rendered as unpadded base64url text, hash it with
`sha256Hex` (import from `Shomei.Workflow.ServiceToken`), create the backing user with
`login_id` set to the client id and no password credential, insert the account, publish
`ServiceAccountCreated`, and print:

```text
client_id:     svcacct_01jz9k7m3ne5rv0q4x8w2b6y1c
client_secret: kJ8vX... (shown once - store it now, it cannot be retrieved)
scopes:        kawa:ingest signal:raise
```

`rotate-secret`: look up by client id, generate and print a fresh secret once, update the
hash and `rotated_at`, publish `ServiceAccountSecretRotated`; the old secret stops working
immediately (single-secret model — if an operator needs overlap, they create a second
account, and the docs say so explicitly). `revoke`: set status revoked plus `revoked_at`,
publish `ServiceAccountRevoked`. `list`: print client id, display name, scopes, status,
created/rotated timestamps — never hashes.

Extend `shomei-server/test/Admin/Main.hs` with create → list → token issuance through the
workflow → rotate (old secret now refused) → revoke (any issuance refused).

Acceptance for M4: `cabal test shomei-server` passes including the admin suite.

### Milestone M5 — Deprecation path, client support, end-to-end proof

Scope: documentation, `shomei-client`, and the live E2E scenario.

Docs. Rewrite `docs/user/service-tokens.md`: database-backed accounts and `/oauth/token`
are the primary path; the config-defined accounts and `POST /auth/service-token` are
retained but marked deprecated (removal candidate at the `/v1` major boundary, per the
MasterPlan decision), with a migration recipe — for each config account, run
`shomei-admin service-accounts create` with the same scopes, hand out the new secret,
point the consumer at `/oauth/token`, then delete the config entry. Update
`docs/user/api.md` with the endpoint (request form fields, both auth methods, the RFC error
table) and state the error-shape boundary explicitly: `/oauth/*` returns RFC 6749 errors,
everything else returns the application envelope.

Client. In `shomei-client/src/Shomei/Client.hs`, the `genericClient` derivation picks the
new route up automatically once the API record has it; add an ergonomic wrapper
`oauthToken :: ClientEnv -> Text -> Text -> [Text] -> IO (Either ClientError TokenResponse)`
that builds the `Form` and the Basic header, and export it. If the servant-client plumbing
for the optional header plus `Form` body proves fiddly, a plain `http-client` helper in
the same module is acceptable — record whichever you do in the Decision Log.

E2E. Extend `shomei-server/test/Shomei/Server/E2ESpec.hs` (real ephemeral Postgres via
`withShomeiMigratedDatabase`, real Warp via `testWithApplication`): insert a service
account through the store (or drive the Admin code path), POST the form to `/oauth/token`
with Basic auth using `http-client`, verify the JWT against the served
`/.well-known/jwks.json`, and assert the audit table contains `service_token_issued` and
`service_account_created` rows.

Acceptance for M5: `cabal test all` green; the Validation transcript below reproducible
against a locally started server.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside the dev shell:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop
```

Baseline before any edits:

```bash
cabal build all
cabal test shomei-core shomei-servant shomei-postgres
```

Expected: all suites pass. If not, record the failure in Surprises & Discoveries before
proceeding.

M1: scaffold the migration, then implement the domain type, port, and interpreters:

```bash
just new-migration name=shomei-service-accounts
# edit the generated shomei-migrations/sql-migrations/<ts>-shomei-service-accounts.sql
just create-database   # idempotent; applies the migration to the dev DB
cabal test shomei-core shomei-postgres
```

Expected tail of the migration run:

```text
Database shomei already exists
... applying 2026-...-shomei-service-accounts.sql ...
```

M2:

```bash
cabal test shomei-core
```

M3 (after editing the cabal file, build first so the new deps resolve):

```bash
cabal build shomei-servant
cabal test shomei-servant
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json   # expect: one file changed, /oauth/token added
```

M4:

```bash
cabal test shomei-server
```

Manual check against the dev database:

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shomei-admin -- service-accounts create \
  --display-name "rei connector" --scope kawa:ingest --scope signal:raise
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shomei-admin -- service-accounts list
```

M5 and final:

```bash
nix fmt
cabal build all
cabal test all
```

Expected: every suite passes; a second `nix fmt` run produces no diff.


## Validation and Acceptance

Acceptance is behavioral. Start the standalone server (the dev shell exports `PGHOST` and
`PGDATABASE`; `just create-database` has been run), create an account, and fetch a token:

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shomei-admin -- service-accounts create \
  --display-name "demo" --scope kawa:ingest
# note the printed client_id and client_secret
cabal run shomei-server &
curl -si -u "svcacct_01...:THE_SECRET" \
  -d 'grant_type=client_credentials&scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

Expected response (whitespace aside):

```text
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache

{"access_token":"eyJhbGciOiJFUzI1NiIsImtpZCI6...","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

The `access_token` decodes as a JWT whose header carries the active `kid`, verifies against
`GET /.well-known/jwks.json`, and whose claims contain `scopes:["kawa:ingest"]` and a `sub`
equal to the account's backing user id. Failure behavior, each observable with curl:
a wrong secret returns

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Basic realm="shomei"

{"error":"invalid_client","error_description":"client authentication failed"}
```

a scope not in `allowed_scopes` returns 400 `{"error":"invalid_scope",...}`; a missing
`grant_type` returns 400 `{"error":"invalid_request",...}`; `grant_type=password` returns
400 `{"error":"unsupported_grant_type",...}`. After
`shomei-admin service-accounts rotate-secret <client_id>`, the old secret gets 401 and the
newly printed one gets 200. After `revoke`, both get 401. Meanwhile
`POST /auth/service-token` with a config-defined account behaves exactly as before this
plan — the pre-existing `shomei-servant` service-token tests prove it.

Automated acceptance: `cabal test all` green, including the new core workflow spec, the
Postgres round-trip, the in-process HTTP scenarios above, the admin CLI test, the E2E
scenario, and the OpenAPI conformance suite at 25 paths.


## Idempotence and Recovery

Everything here is additive; no existing table or route changes. Re-running tests,
`nix fmt`, `just create-database`, and `just migrate` is safe (migrations are applied
once, keyed by filename). The default-configuration change surface is zero: with no
service accounts in the database, `/oauth/token` simply answers `invalid_client`, and
deployments that never run the new CLI see no behavioral difference.

If the new migration seems not to apply in tests, remember the compile-time `embedDir`
splice: the SQL is embedded when `shomei-migrations` compiles, so
`touch shomei-migrations/shomei-migrations.cabal && cabal build shomei-migrations` (or just
`just migrate`) forces re-embedding. The symptom is SQLSTATE 42P01 (missing table) in
Postgres-backed tests.

If `cabal build shomei-servant` fails after adding `http-api-data`/`base64`, check that the
two packages appear in the `build-depends` of the *library* stanza (test suites need them
listed separately if they import the modules directly).

If HTTP tests return 415 Unsupported Media Type, the request is not sending
`Content-Type: application/x-www-form-urlencoded` — servant dispatches content types
strictly. If they return the application envelope (`{"error":...,"message":...}`) instead
of the RFC shape at `/oauth/token`, the handler leaked through
`authErrorToServerError`; route all OAuth failures through `Shomei.Servant.OAuth.oauthError`.

Do not modify `Shomei.Jwt.Sign`, `Shomei.Jwt.Verify`, JWKS publication, refresh rotation,
or the existing `issueServiceToken` behavior (beyond exporting `verifyServiceSecret`). If
a change there looks necessary, record the evidence in Surprises & Discoveries first.


## Interfaces and Dependencies

Project-local interfaces this plan relies on (all verified in the working tree):

`Shomei.Workflow.ServiceToken` supplies `sha256Hex` (exported) and `verifyServiceSecret`
(to be exported) — the single secret-hash format and constant-time comparison shared by
config-defined and database-backed accounts.

`Shomei.Workflow.Session.buildClaims :: ShomeiConfig -> UserId -> SessionId -> UTCTime -> AuthClaims`
is the claims base; the workflow overrides only `expiresAt` and `scopes`.
`Shomei.Effect.TokenSigner.signAccessToken` signs;
`Shomei.Effect.SessionStore.createSession` records the refresh-less session;
`Shomei.Effect.RefreshTokenStore` is deliberately unused.

`Shomei.Id` supplies the TypeID pattern (`KindID`, `genKindID`, `idText`, `parseId`,
`getUUID`, `decorateKindID`) for `ServiceAccountDbId`.

`Shomei.Domain.Event` / `Shomei.Domain.EventCodec` carry the three new lifecycle events and
the reused `ServiceTokenIssued`; keep `projectAuthEvent` and `reconstructAuthEvent` in
lockstep and extend the round-trip spec.

`Shomei.Servant.Seam.Env` (`runPorts`) executes workflows from handlers;
`Shomei.Servant.Authz.requireScope` is the unchanged downstream gate used in tests.

End-of-milestone signatures that must exist: after M1,
`Shomei.Effect.ServiceAccountStore` with the five operations above and
`Shomei.Postgres.ServiceAccountStore.runServiceAccountStorePostgres`; after M2,
`Shomei.Workflow.ClientCredentials.grantClientCredentials` as typed above; after M3,
`Shomei.Servant.OAuth.oauthError`, `extractClientAuth`, `TokenResponse`, and the
`oauthToken` field on `ShomeiAPI`; after M4, the `service-accounts` subcommand tree in
`shomei-server/app/Admin.hs`.

New third-party dependencies: `http-api-data` and `base64` in `shomei-servant` (both
already in the build plan via `shomei-core`); possibly `crypton` in the `shomei-admin`
executable stanza for `getRandomBytes`. No new Nix work is expected since all are already
in the pinned set; if a version conflict appears, record it in Surprises & Discoveries.

Downstream plans consume this plan's artifacts: plan 42 registers `authorization_code` and
`refresh_token` in the `oauthTokenH` dispatcher and reuses `extractClientAuth` and
`oauthError`; plan 43 registers the token-exchange grant and reads `ServiceAccountStore`
for actor authentication. Keep those seams stable.
