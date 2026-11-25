---
id: 76
slug: expose-session-kind-through-oauth-token-introspection
title: "Expose session kind through OAuth token introspection"
kind: exec-plan
created_at: 2026-11-25T14:05:23Z
intention: "intention_01m89gcqycens8wdf35p17f58b"
provenance:
  created_by:
    model: "gpt-6.2-astra"
    harness: "codex-cli"
    at: 2026-11-25T14:05:23Z
  revisions:
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-25T14:24:38Z
      mode: "update"
      note: "Generalize the introspection contract and test different consumer policies over one verified token. Retain Hanmoto as an acceptance case."
    - model: "gpt-6.2-astra"
      harness: "codex-cli"
      at: 2026-11-25T14:30:11Z
      mode: "implement"
      note: "Implement stored session kind, exercise resource-server policies, and document provider acceptance."
---

# Expose session kind through OAuth token introspection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


Any service that protects an API with Shōmei access tokens can already ask whether a token is active. This change lets that service learn how the session was established, even when an interactive token and a machine token carry the same scopes and neither names an actor. A resource server (the API receiving the token) gets that evidence from its existing authenticated call to `POST /oauth/introspect`. It chooses which session kinds and scopes to accept on each operation.

For example, a resource server can require a machine session for an ingest operation and accept a delegated session for a service acting on a user's behalf. Both decisions use the same introspection response. Hanmoto's member and agent paths are one application of this contract.


## Progress


- [x] 2026-11-25. Authenticated access-token introspection reports the stored kind. The machine assertion first failed with a missing field, then all 53 Servant tests and 71 server tests passed, including PostgreSQL issuance for all three kinds, both delegated actor encodings, and revocation.
- [ ] A generic resource-server fixture demonstrates different route policies over the same verified evidence. The public guide documents the contract and shows how Hanmoto uses it.


## Surprises & Discoveries


The server suite exercises the packaged binary with Hurl and requires an executable build on a fresh checkout. The corrected commands below passed. See [FRIC-9](../friction-log/9-plan-76-omitted-the-packaged-server-test-prerequisite.md).


## Decision Log


2026-11-25. Add the `session_kind` member to active access-token introspection. The issuer already reads the authoritative row to check revocation. This gives existing tokens the new capability with one request and one session read. A JWT-only change would omit tokens already in circulation and lose that liveness check.

2026-11-25 (scope revision). Publish session kind for every authorized introspection caller through the existing OAuth endpoint. The issuer reports how the session was established. Each resource server defines accepted kinds, required scopes, identity mappings and authorization for its operations. The original consumer request supplies one acceptance case. Demonstrate reuse with a second route policy implemented entirely in the test fixture.


## Outcomes & Retrospective


## Context and Orientation


[IR-1](../improvement-requests/scoped-service-token-issuance.md) combines two requests written at different times. [ExecPlan 26](26-add-scoped-service-token-issuance.md) delivered scoped issuance. [ExecPlan 41](41-database-backed-service-accounts-with-oauth2-client-credentials-grant.md) added OAuth client credentials and [ExecPlan 48](48-reorganize-shomei-into-vertical-slices-and-adopt-multiverb.md) removed the older bespoke HTTP route. In release tag `v0.3.0.1`, an administrator provisions a service account and its allowed scopes, and the service authenticates at `POST /oauth/token`. A scope is a named capability such as `kawa:ingest`. Each explicit request must be a nonempty subset of the account's allowed set. Deployment policy owns the vocabulary. An ordinary login lacks machine grants by default, but host enrichment and OAuth grants can put scopes on interactive tokens. The baseline Servant suite passed all 53 tests on 2026-11-25, including the same ingest gate with a machine token (200) and an ordinary login (403). See [machine-token instructions](../user/machine-tokens.md) and [ExecPlan 43 on delegation](43-rfc-8693-token-exchange-endpoint.md).

A token's `sub` identifies the subject represented, `sid` identifies a session, and `act.sub`, when present, identifies a distinct actor acting for the subject. One session can issue several access tokens. A JWT is the signed token. JWKS publishes the keys that let a recipient verify the signature. `shomei-jwt/src/Shomei/SigningKey/Verify/Jwt.hs` enforces the configured issuer, audience, token type, signing policy and lifetime. The verifier returns claims. The authoritative session kind is a property of the stored session. [ADR-1](../adr/0001-only-an-interactive-session-may-authorize-a-client.md) specifies how minting sets it and how migrated sessions get their provenance. [ADR-2](../adr/0002-reserved-privilege-scopes-are-service-account-authority.md) governs reserved privilege scopes. [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md) governs token verification. [ADR-26](../adr/0026-downstream-actions-persist-verified-identity-before-reporting-success.md) distinguishes verified subject and actor in downstream attribution.

In `shomei-servant/src/Shomei/OAuth/Handler.hs`, `oauthIntrospectH` authenticates a confidential client or service account, verifies the presented token, looks up `claims.sessionId`, checks the row's status and expiry, then calls `activeAccess claims s`. In the release and current source, `activeAccess claims _s` discards that row. The response includes `active`, `token_type`, `iss`, `aud`, `iat`, `exp`, `scope`, `sub`, `sid`, and optional `act`. The current-session DTO in `shomei-servant/src/Shomei/Session/Dto.hs` also omits kind. This is the missing input reported by `mori://shinzui/hanmoto/okf/friction-log/concepts/FRIC-9` for `mori://shinzui/hanmoto/plans/4-authorize-management-commands-and-ship-the-publishing-cli`. Existing plans for OAuth issuance, delegation and session provenance cover their individual parts. The remaining deliverable is the public read and its consumer contract.


## Plan of Work


**Milestone 1 — Return the stored kind.** Start in `shomei-servant/test/Main.hs` with a real access token from the existing client-credentials scenario. Post it to `/oauth/introspect` using an authenticated client and assert `session_kind == "machine"`. Run the Servant suite below and observe the missing field before changing the handler. In `activeAccess`, serialize the supplied session's `kind` using an exhaustive mapping of `InteractiveSession`, `MachineSession` and `DelegatedSession` to `interactive`, `machine` and `delegated`. The constructors live in `shomei-core/src/Shomei/Session/Domain.hs`. Match the spellings already used by `sessionKindToText` in `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs` while keeping the HTTP package independent of the PostgreSQL interpreter. The new field belongs only to the verified, live access-token branch. Extend the interactive, machine and delegated round trips, including a revocation followed by introspection under the default stateless request mode. Check that the inactive object is exactly `{"active":false}` and the live opaque refresh response remains `{"active":true,"token_type":"refresh_token"}`. Run the Servant suite and the PostgreSQL-backed server suite to verify the returned kind agrees with actual issuance.

**Milestone 2 — Exercise the contract as a resource server.** In `shomei-servant/test/Main.hs`, parse a real introspection response once into verified evidence. Give the test consumer an expected issuer and audience, and let each test route specify the session kinds and scopes it accepts. Use two illustrative policies. One protects a machine-only ingest route requiring `kawa:ingest`. The other accepts either machine or delegated sessions with that same scope. Present the same scoped on-behalf-of token to both. The first route must refuse it and the second must accept it, using the identical provider reply. A member-only route accepts an interactive token and refuses the machine token. These are test policies; the production issuer needs only the existing session and verified claims.

Obtain credentials through the existing interactive, client-credentials and on-behalf-of flows. Check the returned subject, actor and session IDs against the issuing fixtures, then exercise the rejection cases below. Make the tests runnable from this repository alone. Use the documented Hanmoto case to show which of those decisions its adapter needs.

In `docs/user/oidc.md`, document the field on active access-token responses, the three profiles, a redacted form request, sample replies, how to match scopes and what to do when verification or introspection fails. Put the general contract first. Follow it with the Hanmoto example from IR-1, including the identifiers its optional directory integration can use. Link the guide from `docs/user/machine-tokens.md` and `docs/user/token-compatibility.md`. Identify `v0.3.0.1` as the baseline lacking the field and name the first supporting release when available. Record provider acceptance evidence in IR-1. Each consumer owns its deployment tests.


## Concrete Steps


From the repository root, enter the project shell and run the HTTP suites. The server suite uses disposable PostgreSQL instances. Use one test worker to bound concurrent database startup. Confirm the database-backed exchange and introspection cases actually ran.

```bash
nix develop
cabal test shomei-servant:test:shomei-servant-test --enable-tests --test-options='-j1' --test-show-details=direct
cabal build shomei-server:exe:shomei-server --enable-tests
cabal test shomei-server:test:shomei-server-test --enable-tests --test-options='-j1' --test-show-details=direct
git diff --check
```

The first new assertion should initially report a missing `session_kind`. Both suites must pass after implementation. `shomei-server/test/Shomei/Server/E2ESpec.hs` already obtains and introspects delegated credentials using disposable service accounts. Extend its assertions on those replies, and on its interactive and machine scenarios, to cover persistence. Avoid printing credentials in test output.

For a deployed smoke check, set `SHOMEI_BASE_URL` to the trusted issuer's HTTPS base URL, use a confidential introspecting client's credentials and supply a short-lived access token. The following command prints only kind and active status.

```bash
curl --silent --show-error --fail-with-body \
  --user "$INTROSPECTION_CLIENT_ID:$INTROSPECTION_CLIENT_SECRET" \
  --data-urlencode "token=$ACCESS_TOKEN" "$SHOMEI_BASE_URL/oauth/introspect" |
  jq -e '{active,session_kind} | select(.active == true and .session_kind == "machine")'
```

A live client-credentials token produces `{"active":true,"session_kind":"machine"}`. Use the HTTP tests for repeatable acceptance with no deployed secrets.


## Validation and Acceptance


The consumer sends the presented bearer to its configured Shōmei endpoint over an authenticated TLS connection, using its own introspection credential. It requires HTTP 200, `active:true`, `token_type:"Bearer"`, the expected `iss` and `aud`, a valid `exp` (Unix seconds), valid `sub` and `sid`, and a recognized `session_kind`. If the route requires a coarse scope, match a whole word of the space-delimited `scope` field. Apply the route's accepted session kinds. Session kind records how the session started. Membership, ownership, and permission to act on a particular resource require the consumer's own authorization decision.

| Presented credential or response | Observable result under the fixture policies |
| --- | --- |
| Interactive access token | The member-only route accepts the verified subject and session. Both service routes refuse it, even with the required scope. |
| Machine token with `kawa:ingest` | Both service routes accept the backing user in `sub` and the live `sid`. The actor is absent. The member-only route refuses it. |
| Scoped service on-behalf-of token with `kawa:ingest` | The machine-only ingest route refuses it. The machine-or-delegated route accepts it and retains the represented user in `sub`, the service in `act.sub`, and the delegated `sid`. |
| Operator impersonation token | Introspection reports the delegated kind, target subject and operator actor. Its empty scope set fails both scoped service routes. |
| Missing required scope, unknown/missing required kind, or delegated reply missing a valid actor | Refuse the protected operation, including when an older issuer omits evidence the route requires. |
| Wrong issuer, wrong audience, or expired access token | Refuse. Include a valid token issued for a different audience and a signed expired token beyond allowed skew. |
| Revoked, missing or expired session, invalid bearer, or active refresh token | Refuse. A refresh token can introspect as active and lacks the Bearer access-token profile. |
| Caller authentication fails, introspection times out or returns an error, or the reply is malformed | Refuse the protected operation. Distinguish a dependency or configuration failure from a valid inactive answer. |

**Hanmoto acceptance case.** Its person path accepts an interactive member credential. Its direct agent path accepts scoped machine or on-behalf-of credentials bound to a provisioned agent and rejects the interactive member credential. The wrong-audience and expired-token cases apply to both paths. The generic fixture above supplies the credential proof for these policies. Hanmoto owns publication permissions and agent provisioning.

For the optional Kikan integration, document the exact verified credential ID the adapter can send to the directory's by-credential lookup. For a machine credential this is the service account's backing user `sub`. For scoped service on-behalf-of delegation it is the service's backing user in `act.sub`. Retain both identities for attribution. Validate the issuer before using its IDs in that directory, require a linked active agent, and refuse an absent, ambiguous or unusable mapping. A shared runtime credential alone identifies that runtime. It cannot distinguish the individual agents it hosts. Use `sid` for session correlation. Accountable ownership comes from the directory in Kikan and from the configured En provisioning policy in standalone Hanmoto. The integration requirements are `mori://shinzui/kikan/okf/use-cases/concepts/UC-42` and `mori://shinzui/meibo/okf/improvement-requests/concepts/IR-3`.


## Idempotence and Recovery


The field is additive and reads the existing session on each introspection. No migration or token reissue is required. Run each suite with its own fresh fixtures. Deploy the provider before enabling the consumer's kind requirement. During a mixed-version deployment or provider rollback, missing evidence must deny the protected operation. Restore a compatible issuer before resuming kind-dependent traffic.


## Interfaces and Dependencies


The HTTP interface is the existing form-encoded `POST /oauth/introspect` from `shomei-servant/src/Shomei/OAuth/Api.hs`. Its successful payload is a JSON value in `shomei-servant/src/Shomei/OAuth/Result.hs`. Document and test the three literal values as a Shōmei extension. Preserve the OAuth error semantics of [ADR-27](../adr/0027-oauth-namespaces-own-errors-through-the-http-boundary.md). `shomei-core/src/Shomei/ServiceAccount/ClientCredentials/Workflow.hs` and `shomei-core/src/Shomei/OAuth/TokenExchange/Workflow.hs` supply the supported machine and delegation profiles. The wire response is identical for authorized callers inspecting the same live token. The handler serializes the stored session kind independently of client identity, audience-specific policy or directory mappings. Any resource server can consume the response using its HTTP and JSON tools.
