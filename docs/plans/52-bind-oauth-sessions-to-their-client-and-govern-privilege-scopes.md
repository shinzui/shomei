---
id: 52
slug: bind-oauth-sessions-to-their-client-and-govern-privilege-scopes
title: "Bind OAuth Sessions to Their Client and Govern Privilege Scopes"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Bind OAuth Sessions to Their Client and Govern Privilege Scopes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit that can act as an OpenID Connect provider: a
registered *OAuth client* (a web app such as Grafana or oauth2-proxy) sends a user's browser to
`GET /oauth/authorize`, receives a one-time *authorization code*, and exchanges it at
`POST /oauth/token` for an access token, a refresh token, and an ID token. The session that
exchange creates is supposed to belong to that client and to carry exactly the *scopes* (the
space-separated permission words such as `openid` or `kawa:read`) the client was granted. The
August 2026 review found that neither holds. After this plan:

1. A refreshed access token keeps the granted scopes. Today the session row does not store
   them, so the first refresh — at either refresh endpoint — silently drops `openid` and every
   other granted scope, and the OAuth refresh grant answers `"scope": ""`. Afterwards the session
   persists its granted set, both refresh paths re-apply it, and the grant echoes the real value.
2. A refresh token minted for an OAuth client rotates only through that client.
   `POST /v1/auth/refresh` (Shōmei's own, non-OAuth endpoint) today rotates it with no client
   authentication, contradicting `docs/user/oidc.md`; afterwards it answers `401 token_invalid`.
3. `POST /oauth/revoke` revokes only tokens the caller owns (RFC 7009 §2.1); today any
   authenticated client or service account can revoke any session it has seen.
4. The three scopes that are really privilege gates — `impersonate:user`, `shomei:admin`, and
   `token-exchange:subject` — cannot be registered on an OAuth client or requested at authorize,
   so a client can no longer make every user who signs in through it an administrator. Service
   accounts may still hold them (that is what they are for), with a CLI warning.
5. `GET /oauth/userinfo` returns `email`/`email_verified` only under the `email` scope and
   `roles` only under `profile` (OIDC Core §5.4).
6. Presenting an already-used authorization code revokes the session that code minted
   (RFC 6749 §4.1.2), so a code stolen from a browser history cannot coexist with the legitimate
   session.
7. Four interoperability corrections: `client_secret_basic` credentials are form-urldecoded, the
   discovery document advertises the token-exchange grant, introspection recognizes a refresh
   token without a hint, and a missing bearer at userinfo gets an RFC 6750 challenge without
   `error=`.

You can see it working by running `cabal test shomei-servant`, whose new scenarios drive every
behavior above over HTTP, and by the transcripts in Validation and Acceptance.


## Progress

- [x] (2026-08-27 15:09Z) M1: `grantedScopes` on `Session`/`NewSession`; migration via `just new-migration sessions-granted-scopes`; Postgres and in-memory interpreters round-trip it; every `NewSession` literal updated
- [x] (2026-08-27 15:09Z) M1: `RefreshOrigin`/`refreshFrom`; bespoke `refresh` refuses client-bound sessions; both refresh paths re-apply granted scopes; `refreshViaOAuth` returns `Refreshed`; refresh grant echoes `scope`
- [x] (2026-08-27 15:09Z) M1: core tests (bespoke refusal observed failing first), Postgres round-trip, servant inverse scenario; `oidc.md` and `api.md` refresh text corrected. `cabal test shomei-core` (246), `cabal test shomei-servant` (38 plus 62 OpenAPI examples), and the new Postgres case pass; the full Postgres run's sole ephemeral-start timeout passed on immediate isolated retry.
- [x] (2026-08-27 15:18Z) M2: `Shomei.Authorization.Scope.Domain`; servant and token-exchange modules re-export its constants
- [x] (2026-08-27 15:18Z) M2: `registerOAuthClient` refuses privilege scopes; CLI uses it (refusal observed failing first); `resolveScopes` refuses them; service-account CLI warns; tests
- [x] (2026-08-27 15:18Z) M2: `security.md` subsection; `machine-tokens.md` note; ADR-2 written and indexed; strict OKF validation, all 252 core tests, all 27 admin tests, and `cabal build all` green
- [x] (2026-08-27 15:34Z) M3: `mayRevokeSession`; `oauthRevokeH` enforces ownership, `200` on mismatch; servant ownership scenario (observed failing first); impersonation scenario revokes as `shomei:admin`
- [x] (2026-08-27 15:34Z) M3: userinfo gated by `email`/`profile`; servant scenario (observed leaking email first)
- [x] (2026-08-27 15:34Z) M3: `session_id` on codes via migration 0031; bind/find-consumed port ops; replay revokes and audits `oauth_code_replayed`. All 260 core, 59 Postgres, 40 servant, and 62 OpenAPI cases pass; `cabal build all` is green.
- [x] (2026-08-27 15:42Z) M4: Basic credentials urldecoded; token-exchange in `grant_types_supported`; hint-less refresh introspection; `missingToken` challenge; assertions updated
- [x] (2026-08-27 15:42Z) M4: `oidc.md` trust model, ownership, userinfo claims; `api.md`; changelogs; `just adr-validate` and `cabal test all` green; Outcomes written


## Surprises & Discoveries

- The M1 regression test reproduced the bespoke-refresh binding failure before the fix:

  ```text
  bespoke refresh refuses a client-bound session without spending its token: FAIL
    expected: Left RefreshTokenInvalid
     but got: Right (TokenPair {…})
  ```

  This proves that the non-OAuth endpoint spends an OAuth client's refresh token today; the
  corrected guard must run after the active token resolves its session but before rotation.

- The M2 CLI regression also reproduced the privilege escalation path before policy enforcement:

  ```text
  oauth-clients create refuses a privilege scope without inserting a row: FAIL
    registering shomei:admin on an OAuth client: expected the command to abort
  ```

  Registration accepted `shomei:admin` and persisted the client, confirming that the refusal must
  live in the core registration workflow rather than only in the CLI parser.

- The three M3 HTTP regressions each failed at the intended boundary before their fixes:

  ```text
  POST /oauth/revoke: callers can revoke only sessions they own, except shomei:admin: FAIL
    expected: 200
     but got: 400

  POST /oauth/token: authorization_code + PKCE + ID token; replay, wrong verifier, and a stolen code are one invalid_grant: FAIL
    expected: Just (Bool False)
     but got: Just (Bool True)

  GET /oauth/userinfo: email and roles appear only under the email and profile scopes: FAIL
    expected: Nothing
     but got: Just (String "userinfo-scope@example.com")
  ```

  The first failure shows another client had already revoked the refresh token; the second shows
  the first exchange's session remained active after replay; the third confirms an `openid`-only
  token disclosed the email claim.


## Decision Log

- Decision: `POST /v1/auth/refresh` refuses a client-bound session with the existing
  `RefreshTokenInvalid` (`401 token_invalid`), not a new code, and without reuse detection.
  Rationale: The OAuth grant already collapses "not issued to this client" into one
  `invalid_grant`; a distinct bespoke code would tell whoever holds a stolen token which endpoint
  to try next and would add catalog and OpenAPI entries for a case only a misconfigured integrator
  hits. The token is *active* and the refusal is a binding mismatch, not a replay, so it is checked
  inside the active branch after the session loads; a replayed (used) token still trips family
  revocation exactly as today.
  Date: 2026-08-27

- Decision: The binding lives in core as `refreshFrom :: RefreshOrigin -> …`; `refresh` becomes
  `refreshFrom BespokeRefresh`; `refreshViaOAuth` keeps its pre-check and calls
  `refreshFrom (OAuthClientRefresh clientId)`.
  Rationale: `RefreshCommand` is built positionally at some twenty call sites; a new function leaves every
  caller of `refresh` untouched and makes the core self-sufficient. The pre-check stays because it
  runs *before* the token's used/revoked status is examined, which is what stops another client
  from weaponizing reuse detection; the inner check is defense in depth.
  Date: 2026-08-27

- Decision: The refresh grant always echoes the session's persisted grant in `scope`;
  `TokenResponse.scope` stays a required `Text`.
  Rationale: RFC 6749 §5.1 makes `scope` optional only when identical to what the client
  *requested*, and the grant ignores a `scope` parameter, so "always present" is correct on every
  request and needs no OpenAPI or client change. A session minted before the column exists echoes
  `""` once; re-authorizing fixes it.
  Date: 2026-08-27

- Decision: Revocation ownership: an OAuth client owns a session whose `oauthClientId` is its
  `client_id`; a service account owns a session whose subject *or* actor is its backing user (its
  `client_credentials` and on-behalf-of sessions); a service account whose `allowed_scopes`
  contains `shomei:admin` owns every session. A mismatch is a `200` no-op.
  Rationale: RFC 7009 models revocation as a client acting on its own tokens; a resource server
  that merely observed a user's access token has no standing to end that session. The
  `shomei:admin` escape hatch mirrors `RequireAdmin` and is the documented way a database-less
  support console administers; gate scopes are read from `allowed_scopes` because
  `token-exchange:subject` set that precedent. RFC 7009 §2.2 forbids distinguishing an invalid
  token, and a token another client owns is, to this caller, invalid.
  Date: 2026-08-27

- Decision: The reserved list is `{impersonationConfig.impersonateScope, shomei:admin,
  token-exchange:subject}`, defined once in `Shomei.Authorization.Scope.Domain` as a function of
  `ShomeiConfig`, refused on OAuth clients at registration (new `registerOAuthClient` workflow)
  and at authorize (`resolveScopes`), and *allowed* on service accounts with a CLI warning.
  Rationale: An OAuth-client scope is unioned into the authorizing *user's* token
  (`issueSessionWith`, line 206) and so becomes that user's privilege at `RequireAdmin`,
  `startImpersonation`, and on-behalf-of exchange. A service account's scopes are the account's
  own privilege — the Kikan contract in `docs/improvement-requests/scoped-service-token-issuance.md`
  (IR-1) and `diagnostic-identities-and-scopes.md` (IR-2) has service accounts hold coarse gates,
  so refusing them there would break the intended holders. Ports stay policy-free (none sees
  config); the workflow is the seam and authorize is the backstop for rows inserted by hand or by
  an older CLI. This is the ADR-worthy decision.
  Date: 2026-08-27

- Decision: Userinfo returns `sub` and `scopes` always, `email`/`email_verified` only with
  `email`, and `roles` only with `profile`.
  Rationale: `scopes` describes the presented token, which the client already holds; `roles` is a
  fact about the user and belongs with the `profile` bundle. Both are documented as Shōmei
  extensions.
  Date: 2026-08-27

- Decision: `/oauth/authorize` issues a code to every active registered client without a consent
  step; `docs/user/oidc.md` records "every registered client is fully trusted with every user's
  identity" as the trust model, unchanged.
  Rationale: MasterPlan 8's Decision Log; a consent UI is a feature with its own product decisions.
  Date: 2026-08-27


## Outcomes & Retrospective

EP-2 is complete. OAuth authorization-code sessions now persist their granted scopes, carry those
scopes through refresh, and rotate only through the client that minted them. Revocation applies the
OAuth-client or service-account ownership model without revealing mismatches; authorization-code
replay revokes the first exchange's session and emits `oauth_code_replayed`; and UserInfo releases
email and roles only under their OIDC scopes.

The privilege boundary is centralized in `Shomei.Authorization.Scope.Domain`: OAuth-client
registration and authorize both refuse Shōmei's reserved privilege scopes, while service accounts
remain their intended holders and receive a CLI warning. [ADR-2](../adr/0002-reserved-privilege-scopes-are-service-account-authority.md)
records that principal distinction. The OIDC guide now states the provider's no-consent trust model
and documents revocation ownership and claim release explicitly.

The four interoperability defects are closed as part of the same HTTP surface: Basic credentials
are form-decoded, discovery advertises token exchange, introspection recognizes an opaque refresh
token without a hint, and a missing UserInfo bearer uses the RFC 6750 challenge without an `error`
attribute. The regression-first tests reproduced the bespoke-refresh, revocation-ownership,
consumed-code, scope-release, and client-registration failures before their fixes. Final validation
passed strict ADR validation and `cabal test all`, including 260 core tests, 59 PostgreSQL tests, 40
Servant scenarios, 62 OpenAPI examples, and every server, client, JWT, WebAuthn, and example suite.


## Context and Orientation

Shōmei is a multi-package Cabal project built inside `nix develop`. Packages touched:
`shomei-core` (domain types, `effectful` *port* effects such as `SessionStore`, workflows, and the
in-memory test interpreter `shomei-core/src/Shomei/Test/InMemory.hs`), `shomei-postgres` (the
PostgreSQL interpreters), `shomei-migrations` (numbered SQL under
`shomei-migrations/migrations/shomei/`, listed in `manifest`), `shomei-servant` (HTTP handlers),
and `shomei-server` (the `shomei-admin` CLI under `shomei-server/app/Shomei/Admin/`). Tests are
tasty: core workflow tests run against the in-memory interpreter with a fresh `World` per case
(`shomei-core/test/Shomei/Session/Authentication/WorkflowSpec.hs` shows the style), the Postgres
suite uses an ephemeral database, and `shomei-servant/test/Main.hs` drives the real Servant tree
over HTTP. Several records share field names (`clientId`, `userId`, `status`, `scopes`); where two
are in scope the code reads fields through generic-lens labels (`x ^. #clientId`) or record
patterns — copy whichever style the file already uses.

Terms. A *session* is the `shomei_sessions` row a login or code exchange creates; a *refresh
token* is an opaque secret bound to one session and rotated on use; an *access token* is a signed
JWT whose claims come from `Shomei.Authorization.Claims.Domain.AuthClaims`. A *service account* is
a machine credential with its own backing user row (its token's `sub`); an *OAuth client* has no
user row and is never a subject. A *privilege scope* is a scope some Shōmei code treats as an
authorization gate.

Exact current state (HEAD `5dfd2a6`, code identical to the reviewed `ee00382`):

- `shomei-core/src/Shomei/Session/Domain.hs` lines 27-31 document `oauthClientId` and admit "The
  bespoke `/v1/auth/refresh` ignores it."; `NewSession` (36-44) has no scopes field.
  `shomei-core/src/Shomei/Session/Workflow.hs` line 206 unions `opts.extraScopes` into the claims
  but persists nothing, so `refresh` in `shomei-core/src/Shomei/Session/Authentication/Workflow.hs`
  (line 415, `signAccessToken =<< buildEnrichedClaims cfg s.userId s.sessionId ts`) drops them.
  `refreshViaOAuth` (`shomei-core/src/Shomei/OAuth/TokenGrant/Workflow.hs` 245-258) delegates to
  it; `shomei-servant/src/Shomei/OAuth/Handler.hs` 358-360 answer `scope = ""`.
- `shomei-servant/src/Shomei/Session/Handler.hs` line 100 calls
  `Authentication.refresh env.config (RefreshCommand (RefreshToken presented))` with no client
  identity; `scenarioOAuthRefreshRejectsUnboundSession` (`test/Main.hs` 2163-2187) asserts only the
  opposite direction and that "the bespoke endpoint still rotates it".
- `oauthRevokeH` (`Handler.hs` 563-589) revokes whatever it recognizes after
  `authenticateOAuthCaller` (597-613), which returns `()`. The impersonation scenario at
  `test/Main.hs` 1690-1697 revokes an operator's delegated token as the `svcgate` service account.
- `resolveScopes` (`shomei-core/src/Shomei/OAuth/Authorize/Workflow.hs` 190-195) grants any subset
  of `allowedScopes`; `shomei-server/app/Shomei/Admin/OAuthClients.hs` `parseScopes` (274-281)
  checks only blanks; `shomei-servant/src/Shomei/Servant/Authz.hs` 129-130 define
  `adminScope = Scope "shomei:admin"`, accepted by `RequireAdmin`;
  `shomei-core/src/Shomei/Delegation/Workflow.hs` line 72 gates on the configurable
  `impersonateScope`; `shomei-core/src/Shomei/OAuth/TokenExchange/Workflow.hs` 84-85 define
  `tokenExchangeSubjectScope`.
- `oauthUserinfoH` (`Handler.hs` 494-504) returns `roles`, `scopes`, and the email pair
  regardless of scopes.
- `shomei-core/src/Shomei/OAuth/AuthorizationCode/Domain.hs` has no session id;
  `consumeAuthorizationCode` returns `Nothing` for unknown, consumed, and expired alike
  (`Store.hs` 28-34); consumed rows are retained until expiry
  (`shomei-postgres/src/Shomei/OAuth/AuthorizationCode/Postgres.hs` 138-153; in-memory 969-982).
- Interop: `Shomei.Servant.OAuth.extractClientAuth` (175-182) does not urldecode Basic
  credentials; `Shomei.Servant.Oidc.discoveryDocument` line 77 lists three grant types;
  `oauthIntrospectH` (522-526) honors `refresh_token` only as a hint; `Shomei.Servant.Auth` line
  136 answers a *missing* bearer with `OAuth.invalidToken`, whose challenge (`Servant/OAuth.hs`
  line 125) carries `error="invalid_token"`.
- Migrations end at `0028-shomei-role-permissions.sql`; `just new-migration <slug>` (`justfile`
  35-42) allocates the next number and appends to the manifest;
  `0025-shomei-sessions-oauth-client.sql` is the model for a one-column session change.

Architecture Decision Records: this repository has no `docs/adr/` bundle (`mori.dhall` declares
`improvement-requests`, `capabilities`, and `reviews` only), so no local ADR applies. The
cross-repository records that constrain this plan are
`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-1` and
`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-2`. MasterPlan 8 flags "the reserved
privilege-scope list and where it is enforced" as ADR-worthy, so M2 creates `docs/adr/` following
`.claude/skills/exec-plan/ADR.md`. Coordination:
`docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md`
also creates `docs/adr/` on first use; whichever lands first creates the directory, profile, and
`mori.dhall` entry, and the second allocates the next handle with `okf id next`.

Integration with docs/plans/51 (MasterPlan 8, Integration Points 1 and 2, verbatim): that plan
owns the `Session`/`NewSession` shape and adds `kind`; this plan appends `grantedScopes` as the
*last* field of both records, never reorders or renames `kind`, and appends after it if it is
already present. Every `NewSession` literal is a site both plans touch; run
`rg -n "NewSession$" --type haskell` before and after. Out of scope: the session `kind` and
refusing non-interactive callers at authorize (docs/plans/51); throttling `/oauth/token`
(`docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md`).


## Plan of Work

Four milestones, each ending in one commit. M1 and M2 are independent; M3's replay assertions
use M1's scopes; M4 is last.

### Milestone M1 — persist granted scopes; bind refresh to the minting client

After M1 an OAuth-minted session stores its granted scopes, both refresh paths re-apply them, the
refresh grant echoes them, and the bespoke endpoint refuses client-bound sessions.

1. Migration. Run `just new-migration sessions-granted-scopes` (Concrete Steps) and make the
   generated file's body (`0029-…` unless docs/plans/51 landed first):

   ```sql
   SET search_path TO shomei, pg_catalog;

   -- The scopes the authorization-code grant granted this session, re-applied to every access
   -- token refresh mints for it. Empty for every session no OAuth client minted and for every
   -- row that predates the column: those sessions never had a granted set to lose.
   ALTER TABLE shomei_sessions
     ADD COLUMN IF NOT EXISTS granted_scopes text[] NOT NULL DEFAULT '{}';
   ```

2. Domain. In `Shomei/Session/Domain.hs` import `Data.Set (Set)` and `Scope`; append to
   `Session` after `oauthClientId` (line 31) and to `NewSession` after line 43:

   ```haskell
       -- | the scopes the authorization-code grant granted (docs/plans/52), re-applied on every
       --     refresh so a rotated access token keeps @openid@ and friends. Empty for every other
       --     flow and for every row that predates the column.
       grantedScopes :: !(Set Scope)
   ```

   Rewrite lines 27-30 so they say the bespoke endpoint *refuses* a session that carries one.

3. Construction sites (`rg -n "NewSession$" --type haskell`): `Session/Workflow.hs` line 187
   sets `grantedScopes = opts.extraScopes` (the grant's `extraScopes` *is* the granted set — say
   so on `SessionOptions.extraScopes`, lines 141-143); `Session/Authentication/Workflow.hs` 160,
   `Delegation/Workflow.hs` 143, `ServiceAccount/ClientCredentials/Workflow.hs` 99, and the seven
   literals in `shomei-postgres/test/Main.hs` set `Set.empty`. `mkSession` in
   `shomei-postgres/src/Shomei/Session/Postgres.hs` (74-85) and `Test/InMemory.hs` (437-449)
   copy `ns.grantedScopes`.

4. Postgres (`Shomei/Session/Postgres.hs`). Widen `SessionRow` (line 34) with a trailing
   `[Text]`; add it to the `CreateSession` tuple (52), `rebuildSession` (88; rebuild with
   `Set.fromList (map Scope ts)`), `sessionRowDecoder` (112; decoder
   `D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))` — `listArray` is exported by
   hasql 1.10's `Hasql.Decoders`), `insertSessionStmt` (add `granted_scopes` and `$9`,
   `contrazip8` → `contrazip9`, encoder `E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text)))`
   as in `Shomei/Authorization/Role/Postgres.hs` line 208), and both `SELECT` lists (140, 152).
   `Shomei/Session/UnitOfWork/Postgres.hs` `sessionRow` (110-120) gains the ninth component.

5. Core refresh. In `Shomei/Session/Command.hs` add:

   ```haskell
   -- | Which endpoint is rotating. The bespoke endpoint has no client identity, so it may not
   -- rotate a session an OAuth client minted; the OAuth grant may rotate only its own.
   data RefreshOrigin = BespokeRefresh | OAuthClientRefresh Text
     deriving stock (Generic, Eq, Show)
   ```

   In `Shomei/Session/Authentication/Workflow.hs` add and export:

   ```haskell
   data Refreshed = Refreshed
     { tokens :: !TokenPair,
       -- | the session's persisted OAuth grant (empty for non-OAuth sessions); the grant's echo
       grantedScopes :: !(Set Scope)
     }
     deriving stock (Generic, Show)

   refreshFrom :: (…refresh's constraints…) => RefreshOrigin -> ShomeiConfig -> RefreshCommand -> Eff es (Either AuthError Refreshed)
   refresh cfg cmd = fmap (\r -> r.tokens) <$> refreshFrom BespokeRefresh cfg cmd
   ```

   Move `refresh`'s body into `refreshFrom origin`. Make the *first* guard under `Just s` (366)
   `| not (originMayRefresh origin s) -> pure (Left RefreshTokenInvalid)`, with
   `originMayRefresh BespokeRefresh s = isNothing s.oauthClientId` and
   `originMayRefresh (OAuthClientRefresh cid) s = s.oauthClientId == Just cid`. In the `Rotated _`
   branch (415) build `claims` as `buildEnrichedClaims …` with
   `scopes = c.scopes <> s.grantedScopes`, sign it, and return
   `Refreshed {tokens = TokenPair {…}, grantedScopes = s.grantedScopes}`.

6. OAuth grant. `refreshViaOAuth` returns `Either TokenGrantError Wf.Refreshed`; line 257 calls
   `Wf.refreshFrom (OAuthClientRefresh (cmd ^. #clientId)) cfg …`. In `Handler.hs`
   `refreshTokenGrant` (347-368) read `refreshed ^. #tokens . #accessToken` etc. and set
   `scope = Text.unwords [s | Scope s <- Set.toList (refreshed ^. #grantedScopes)]`; delete the
   comment at 358-360. `Shomei/Servant/OAuth.hs` 218-219 now hold; `TokenResponse` is unchanged.

7. Tests. Core (`Session/Authentication/WorkflowSpec.hs`): after `signup`, mint an OAuth-bound
   session with `issueSessionWith cfg SessionOptions {oauthClientId = Just "oauthclient_x", extraScopes = Set.fromList [Scope "openid", Scope "kawa:read"]} user fixedTime`;
   assert `refresh cfg (RefreshCommand pair.refreshToken)` is `Left RefreshTokenInvalid` and the
   token stays `RefreshTokenActive` (no revocation); assert
   `refreshFrom (OAuthClientRefresh "oauthclient_x")` succeeds with that `grantedScopes` and that
   decoding the new access token with `verifyAccessToken` under `runInMemory` (the fake verifier
   parses the claims back) yields both scopes; assert `OAuthClientRefresh "oauthclient_y"` is
   `Left RefreshTokenInvalid`. Write these *before* step 5 and run once: the refusal case fails
   with `expected Left RefreshTokenInvalid, got Right …` and the scope case with `fromList []` —
   record both in Surprises & Discoveries. Postgres (beside `testSessionActorRoundTrip`,
   `shomei-postgres/test/Main.hs` 946): a session with two scopes round-trips; a row inserted by
   raw SQL without the column reads `Set.empty`. Servant:
   `scenarioBespokeRefreshRejectsClientBoundSession` (register beside line 1428 with
   `freshAuthorizeEnv Nothing`) runs authorize+exchange as `scenarioOAuthUserinfoIntrospectRevoke`
   does, posts the refresh token to `/v1/auth/refresh` expecting `401` with `code: "token_invalid"`,
   then rotates the *same* token at `/oauth/token` as `confId` expecting `200` and
   `"scope": "openid profile"` — no reuse detection fired, scopes survived.

8. Docs. `docs/user/oidc.md` 123-125: "it cannot be rotated by another client, and cannot be
   rotated at `POST /v1/auth/refresh` at all (`401 token_invalid`)". `docs/user/api.md` line 139:
   add "→ `401 token_invalid` for a refresh token an OAuth client minted; rotate it at
   `POST /oauth/token` as that client."

Commit:

```text
feat(session): persist OAuth granted scopes and bind refresh to the minting client

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M2 — reserve the privilege scopes

After M2 an OAuth client cannot be registered with, or granted at authorize, any privilege scope;
service accounts still can, with a warning; the decision is an ADR.

1. New `shomei-core/src/Shomei/Authorization/Scope/Domain.hs` (add to `exposed-modules`):

   ```haskell
   adminScope :: Scope                          -- Scope "shomei:admin"
   tokenExchangeSubjectScope :: Scope           -- Scope "token-exchange:subject"

   -- | The scopes that are privilege gates rather than capabilities. A scope minted onto a user's
   -- token by an OAuth client becomes that user's own privilege, so these may never be registered
   -- on a client; a service account is their intended holder (docs/plans/52 Decision Log).
   privilegeScopes :: ShomeiConfig -> Set Scope
   privilegeScopes cfg = Set.fromList [cfg.impersonationConfig.impersonateScope, adminScope, tokenExchangeSubjectScope]

   privilegeScopesIn :: ShomeiConfig -> Set Scope -> Set Scope   -- intersection
   ```

   `Shomei.Servant.Authz` re-exports `adminScope` from here (delete 127-130);
   `Shomei.OAuth.TokenExchange.Workflow` deletes 81-85 and re-exports the core constant.

2. New `shomei-core/src/Shomei/OAuth/Client/Workflow.hs`:

   ```haskell
   data ClientRegistrationError = PrivilegeScopesRefused (Set Scope)
   registerOAuthClient :: (OAuthClientStore :> es) => ShomeiConfig -> NewOAuthClient -> Eff es (Either ClientRegistrationError OAuthClient)
   ```

   refusing when `privilegeScopesIn cfg (new ^. #allowedScopes)` is non-empty, else
   `createOAuthClient`. `Shomei/Admin/OAuthClients.hs` `createAction` (166-177) calls it with
   `env.config` and `die`s on `Left` with
   `refused: <scope> is a privilege scope and cannot be registered on an OAuth client (it would make every user who authorizes through it hold it); grant it to a service account instead`.

3. Authorize backstop. `resolveScopes` (190-195): the absent arm returns
   `allowedScopes \\ privilegeScopes cfg` and throws `AuthorizeInvalidScope` if empty; the
   present arm also throws it when `privilegeScopesIn cfg requested` is non-empty.

4. Service accounts. `Shomei/Admin/ServiceAccounts.hs` `createAction` (147): after
   `parseScopes`, for each member of `privilegeScopesIn env.config scopes` print to stderr
   `shomei-admin: warning: <scope> is a privilege scope; this account holds it as its own authority (see docs/user/security.md, "Scopes are principal privilege")`.

5. Tests. New `shomei-core/test/Shomei/OAuth/Client/WorkflowSpec.hs` (register in the cabal
   `other-modules` and `test/Main.hs`): each of the three scopes refused; a config with
   `impersonateScope = Scope "support:act-as"` refuses that word instead; `openid`+`kawa:read`
   accepted. `shomei-server/test/Admin/Main.hs`: `oauth-clients create --scope shomei:admin exits nonzero and inserts no row`
   via `expectExitFailure` and `scalarInt pool "SELECT count(*) FROM shomei.shomei_oauth_clients"`
   — run it against HEAD once (fails with `expected the command to abort`) and record it; and
   `service-accounts create --scope impersonate:user` stores the scope. In
   `shomei-core/test/Shomei/OAuthCodeStoreSpec.hs`'s authorize group: a client hand-inserted with
   `[openid, shomei:admin]` gets `openid` alone on an absent `scope` and `AuthorizeInvalidScope` on
   `scope=openid shomei:admin`.

6. Docs. `docs/user/security.md`, after "Administering over HTTP" (ends 454): add
   `### Scopes are principal privilege; three are reserved` — a token's `scopes` claim is the
   bearer's own authority; a service account's `allowed_scopes` are the account's privilege; an
   OAuth client's `allowed_scopes` are unioned into the *authorizing user's* token, so
   `impersonate:user` (or the configured `impersonateScope`), `shomei:admin`, and
   `token-exchange:subject` are refused at `oauth-clients create` and at `/oauth/authorize`
   (`invalid_scope`); a service account receiving one gets a warning, not a refusal.
   `docs/user/machine-tokens.md`: note the warning under "Create an account" and add "never
   register them on an OAuth client" to the checklist (125).

7. ADR. If `docs/adr/` does not exist: `mkdir docs/adr`; write `docs/adr/profile.dhall` pinning
   the shared `documentation.architectureDecisions` profile from `shinzui/okf-profiles` exactly as
   `docs/reviews/profile.dhall` pins the reviews one (find the path and sha256 with
   `mori registry show shinzui/okf-profiles --full` and `mori registry docs shinzui/okf-profiles`;
   never guess); add an `okfBundles` entry to `mori.dhall` copying the `reviews` entry (362-369)
   with `name = "adrs"`, `path = "docs/adr"`, `profile = Some "docs/adr/profile.dhall"`; add a
   `just adr-validate` recipe mirroring `reviews-validate` (justfile 45). Then
   `okf id next docs/adr --profile docs/adr/profile.dhall ADR` prints the handle; write
   `docs/adr/reserved-privilege-scopes.md` with the profile's frontmatter
   (`type: Architecture Decision Record`, `title`, `docId`, `status: accepted`, `date`,
   one-sentence `description`, `timestamp`) and the Decision Log entry's list, rationale, two
   enforcement seams, service-account stance, and IR-1/IR-2 constraint; record it with
   `okf log add` (`okf log add --help`; `docs/reviews/log.md` shows the shape); run
   `just adr-validate`.

Commit:

```text
feat(authz): reserve the privilege scopes and refuse them on OAuth clients

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M3 — revocation ownership, userinfo gating, consumed-code replay

1. Ownership. New `shomei-core/src/Shomei/OAuth/Revocation/Domain.hs`:

   ```haskell
   data RevocationCaller = RevokingOAuthClient !Text | RevokingServiceAccount !ServiceAccount
   -- | RFC 7009 §2.1: may this caller revoke this session? (Decision Log for the rule.)
   mayRevokeSession :: RevocationCaller -> Session -> Bool
   ```

   Read `ServiceAccount` fields by record pattern. In `Handler.hs` make `authenticateOAuthCaller`
   return `RevocationCaller` (introspection discards it); in `oauthRevokeH` load the session with
   `findSessionById` in both arms and, when `mayRevokeSession caller session` is `False`, do nothing
   and answer `200`. Add `shomei-core/test/Shomei/OAuth/Revocation/DomainSpec.hs` (registered)
   covering all five arms.

2. Servant. Add `freshRevokeEnv` beside `freshExchangeEnv` (`test/Main.hs` 497): the two clients
   from `seedOAuthClients`, a second confidential client `otherConfId` with the same
   `confidentialClientSecret`, a plain account via `seedExchangeAccount … "svcplain" (Set.singleton ingestScope)`,
   and `"svcadmin" (Set.singleton adminScope)`. `scenarioRevokeOwnership`: mint through `confId`;
   revoke the refresh token as `otherConfId` → `200` and it still rotates as `confId`; revoke the
   access token as `svcplain` → `200`, introspection still `active: true`; as `svcadmin` → `200`
   and introspection flips to `false`. Run once before step 1 (the first rotation fails with
   `invalid_grant`); record it. Fix the impersonation scenario: `freshExchangeEnv` seeds a third
   account `"svcadmin" (Set.singleton adminScope)` and the revoke at 1690-1697 authenticates as it
   (the operator's own path is `POST /v1/auth/logout` with the delegated token, which revokes the
   session its `sid` names).

3. Userinfo. `oauthUserinfoH` (497-504): emit `roles` only when
   `Scope "profile"` is in `user.authScopes` and the email pair only under `Scope "email"`;
   `sub` and `scopes` stay. Give the seeded confidential client `email` (`seedOAuthClients`
   line 1533). `scenarioUserinfoScopeGating`: sign up with an email; `scope=openid` → `sub` and
   `scopes` only; `scope=openid profile email` → `email`, `email_verified: false`, `roles`.

4. Replay. `just new-migration oauth-codes-session-id`; body:

   ```sql
   SET search_path TO shomei, pg_catalog;

   -- The session the exchange of this code minted, stamped after consumption, so a second
   -- presentation of a consumed code (RFC 6749 §4.1.2) can revoke what the first produced.
   -- No foreign key: the sweeper deletes codes and sessions on independent schedules.
   ALTER TABLE shomei_oauth_authorization_codes
     ADD COLUMN IF NOT EXISTS session_id uuid NULL;
   ```

   Add `sessionId :: !(Maybe SessionId)` to `AuthorizationCode` (not `NewAuthorizationCode`);
   add to `OAuthCodeStore` `BindAuthorizationCodeSession :: Text -> SessionId -> OAuthCodeStore m ()`
   and `FindConsumedAuthorizationCode :: Text -> UTCTime -> OAuthCodeStore m (Maybe AuthorizationCode)`
   (the row iff `consumed_at IS NOT NULL AND expires_at > $2`) with `send` wrappers; implement in
   Postgres (an `UPDATE … SET session_id = $2 WHERE code_hash = $1`; a `SELECT` over `selectCols`
   plus `session_id` — extend `CodeRow`, the decoder, `rebuildCode`, and `consumeStmt`'s
   `RETURNING`) and in memory. In `exchangeAuthorizationCode` (155-157), on a consume miss call
   `findConsumedAuthorizationCode`; when it yields a row with `sessionId = Just sid`, run
   `revokeSession sid ts`, `revokeSessionRefreshTokens sid ts`, publish a new
   `Event.OAuthCodeReplayed OAuthCodeReplayedData {clientId, presentedBy, userId, sessionId, occurredAt}`
   (model on `OAuthCodeIssuedData`, `Audit/Event/Domain.hs` 462-469; codec type
   `oauth_code_replayed` with user and session columns set, `Codec.hs` 73 and 185-186; a
   `CodecSpec` case beside line 148), then throw the same `GrantInvalidGrant` — the wire answer
   must not change. After `issueSessionWith`, `bindAuthorizationCodeSession (row ^. #codeHash) sid`.
   Add `SessionStore`, `RefreshTokenStore`, `AuthEventPublisher` to the constraints (`AppEffects`
   and `runInMemory` already interpret them). Tests: store cases in `OAuthCodeStoreSpec`; in
   `scenarioOAuthCodeExchange` step (2) add, after the replay, introspection of the first access
   token → `active: false` and rotation of its refresh token → `invalid_grant`; run that once
   before the change (it fails with `active: true`).

Commit:

```text
fix(oauth): enforce revocation ownership, gate userinfo by scope, and revoke on code replay

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M4 — interop corrections and documentation

1. `Shomei.Servant.OAuth.decodeBasic` (175-182): after splitting on the first colon,
   `urlDecode True` (`Network.HTTP.Types.URI`, already a dependency) each half before
   `decodeUtf8'`; failures stay `invalidClient`. Test in `scenarioOAuthToken`: a Basic header built
   from `urlEncode True` of id and secret succeeds.
2. `Shomei.Servant.Oidc.discoveryDocument` line 77: append
   `"urn:ietf:params:oauth:grant-type:token-exchange"`; update `test/Main.hs` 1488-1489.
3. `oauthIntrospectH` 526-537: on `Left _` from `verifyAccessToken` fall through to
   `introspectRefresh env presented`. Test: `introspect mgr port basic refreshToken` without a
   hint → `active: true`, `token_type: "refresh_token"`.
4. `Shomei.Servant.OAuth`: add `missingToken :: ServerError`, identical to `invalidToken` except
   the challenge `Bearer realm="shomei"`; `Shomei.Servant.Auth` line 136 uses it; update
   `test/Main.hs` 2266-2267 to `Just "Bearer realm=\"shomei\""`.
5. `docs/user/oidc.md`: a `## Trust model` section after "Registering clients" — every active
   registered client is fully trusted with every user's identity; there is no consent screen, so
   registering a client is the consent and should be treated like granting an administrator;
   "Registering clients" gains the reserved-scope refusal; "Introspection and revocation" gains the
   ownership rule and the hint-less refresh lookup; a `## Userinfo` paragraph lists claims by
   scope; the discovery grant list is mentioned. `docs/user/api.md` "OIDC provider endpoints"
   (253) gets one sentence each on userinfo scopes and ownership. Add "Unreleased" entries to
   `CHANGELOG.md`, `shomei-core/CHANGELOG.md`, `shomei-postgres/CHANGELOG.md`,
   `shomei-migrations/CHANGELOG.md`, and `shomei-servant/CHANGELOG.md` naming the bespoke refresh
   refusal, revocation ownership, reserved scopes, and userinfo gating as integrator-visible.

Commit:

```text
fix(oauth): interop corrections and the client-binding trust model documentation

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

Allocate a migration (M1; M3 repeats it with `oauth-codes-session-id`), then rebuild so the
embedded manifest picks it up:

```bash
just new-migration sessions-granted-scopes
tail -2 shomei-migrations/migrations/shomei/manifest
cabal build shomei-migrations shomei-postgres
```

```text
0028-shomei-role-permissions.sql
0029-sessions-granted-scopes.sql
```

Find construction sites after a record change, then build and test per milestone:

```bash
rg -n "NewSession$" --type haskell
rg -n "oauthClientId = " --type haskell
cabal build all
cabal test shomei-core          # M1, M2, M3 workflow and store specs
cabal test shomei-postgres      # M1, M3 round-trips (ephemeral PostgreSQL)
cabal test shomei-servant       # M1, M3, M4 HTTP scenarios
cabal test shomei-admin         # M2 CLI refusal and warning
cabal test all
```

A passing servant run prints, among others:

```text
  POST /v1/auth/refresh: refuses a session an OAuth client minted; the client still rotates it with its scopes: OK
  POST /oauth/revoke: a client revokes only its own sessions; a plain service account nothing it does not own; shomei:admin anything: OK
  GET /oauth/userinfo: email and roles appear only under the email and profile scopes: OK
```

Observing a negative failing first (every case a milestone marks): write the test, run the
suite, confirm the failure, then implement. M1's core case reads:

```text
  the bespoke origin refuses a client-bound session: FAIL
    expected: Left RefreshTokenInvalid
     but got: Right (TokenPair {…})
```

ADR bootstrap (M2 step 7), only if `docs/adr/` does not yet exist:

```bash
mkdir -p docs/adr
mori registry show shinzui/okf-profiles --full     # locate the architecture-decisions profile to pin
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

`okf id next` prints `ADR-1` on a fresh bundle; the validation prints nothing and exits 0.

Manual check of the refusal against a real database (optional; needs `DATABASE_URL`):

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run shomei-admin -- oauth-clients create \
  --display-name evil --type confidential --redirect-uri https://evil.test/cb --scope openid --scope shomei:admin
```

```text
shomei-admin: refused: shomei:admin is a privilege scope and cannot be registered on an OAuth client (it would make every user who authorizes through it hold it); grant it to a service account instead
```

with exit status 1.


## Validation and Acceptance

Acceptance is behavioral, over HTTP where the review found the defects:

1. Scopes survive refresh. Authorize with `scope=openid profile`, exchange, rotate at
   `POST /oauth/token` as the same client: the response carries `"scope":"openid profile"` and the
   new access token introspects with the same scope. Before: `"scope":""` and an empty scope.
2. Client binding. The same refresh token at `POST /v1/auth/refresh` answers
   `401 {"code":"token_invalid",…}`; it then still rotates at `/oauth/token`. Before: `200`.
3. Ownership. Another confidential client revoking it gets `200` and it still rotates; a
   service account without `shomei:admin` revoking the access token gets `200` and introspection
   stays `active: true`; a `shomei:admin` account flips it to `false`. Before: everyone flips it.
4. Reserved scopes. `oauth-clients create … --scope shomei:admin` exits 1 with the refusal and
   inserts no row; a client hand-inserted with `shomei:admin` gets `error=invalid_scope` when it
   requests it and only the non-privileged scopes when it requests nothing;
   `service-accounts create --scope impersonate:user` succeeds and warns.
5. Userinfo. `scope=openid` → `sub` and `scopes` only; `scope=openid profile email` adds `roles`,
   `email`, `email_verified`.
6. Replay. Exchanging a code twice answers `invalid_grant` both times (unchanged) and the first
   exchange's access token then introspects `active: false`; an `oauth_code_replayed` audit row
   names the session. Before: it stays active.
7. Interop. Discovery lists four grant types; a refresh token introspects without a hint; a
   percent-encoded Basic header authenticates; userinfo with no bearer answers
   `WWW-Authenticate: Bearer realm="shomei"`.
8. `cabal test all` green, including the Postgres refresh round-trip budget (five), which is
   unchanged because the session the scopes come from is already loaded.


## Idempotence and Recovery

Every source change is compiler-checked and re-runnable; record-field additions make GHC list
every missed construction site. Both migrations are `ADD COLUMN IF NOT EXISTS` with a default or
nullable column, so re-running them is a no-op and existing rows read as the pre-change value.
Rolling back the code without the migrations is safe (extra columns are ignored); rolling back
the migrations means dropping the two columns *after* the code is rolled back, because the
interpreters select them by name. If `just new-migration` runs twice for one slug, delete the
duplicate file and its manifest line before building. If docs/plans/51 lands mid-flight, rebase:
append `grantedScopes` after `kind` in both records, re-run the two `rg` commands, and let the
compiler find the rest; migration numbers do not matter because each column is named.

Deploy effects: sessions minted before `granted_scopes` exists lose their scopes on the next
refresh once (today's behavior) and re-authorize; a relying party rotating OAuth refresh tokens
at `/v1/auth/refresh` starts receiving `401 token_invalid` and must use `/oauth/token`; an
integrator that revoked other clients' tokens or read `email` without the `email` scope must
adjust. The changelog entries name all three.


## Interfaces and Dependencies

No new library dependencies: hasql 1.10's `Hasql.Decoders.listArray` and
`Hasql.Encoders.foldableArray` carry the `text[]` column; http-types' `urlDecode` decodes Basic
credentials. Definitions that must exist at the end:

- `Shomei.Session.Domain.Session.grantedScopes` and `NewSession.grantedScopes :: Set Scope`, last
  fields of both records, persisted in `shomei_sessions.granted_scopes text[] NOT NULL DEFAULT '{}'`.
- `Shomei.Session.Command.RefreshOrigin` (`BespokeRefresh | OAuthClientRefresh Text`).
- `Shomei.Session.Authentication.Workflow.Refreshed` (`tokens`, `grantedScopes`),
  `refreshFrom :: RefreshOrigin -> ShomeiConfig -> RefreshCommand -> Eff es (Either AuthError Refreshed)`;
  `refresh` unchanged in type and equal to `refreshFrom BespokeRefresh` projected to `tokens`.
- `Shomei.OAuth.TokenGrant.Workflow.refreshViaOAuth :: … -> Eff es (Either TokenGrantError Refreshed)`;
  `exchangeAuthorizationCode` additionally requires `SessionStore`, `RefreshTokenStore`, and
  `AuthEventPublisher`.
- `Shomei.Authorization.Scope.Domain.{adminScope, tokenExchangeSubjectScope, privilegeScopes, privilegeScopesIn}`,
  re-exported by `Shomei.Servant.Authz` and `Shomei.OAuth.TokenExchange.Workflow`.
- `Shomei.OAuth.Client.Workflow.registerOAuthClient`, the only registration path `shomei-admin`
  uses; `Shomei.OAuth.Authorize.Workflow.resolveScopes` refusing privilege scopes.
- `Shomei.OAuth.Revocation.Domain.{RevocationCaller, mayRevokeSession}`, consulted by
  `Shomei.OAuth.Handler.oauthRevokeH`.
- `Shomei.OAuth.AuthorizationCode.Domain.AuthorizationCode.sessionId :: Maybe SessionId`;
  `Shomei.OAuth.AuthorizationCode.Store.{bindAuthorizationCodeSession, findConsumedAuthorizationCode}`;
  `Shomei.Audit.Event.Domain.OAuthCodeReplayed` with codec type `oauth_code_replayed`.
- `Shomei.Servant.OAuth.missingToken :: ServerError` (challenge `Bearer realm="shomei"`).
- `docs/adr/` as an OKF bundle under the shared architecture-decisions profile, holding the
  reserved-privilege-scopes record.

Relations: docs/plans/51 owns the `Session`/`NewSession` shape (this plan appends one field and
never touches `kind`); docs/plans/54 owns throttling `/oauth/token`; docs/plans/60 reconciles any
documentation this plan does not touch.
