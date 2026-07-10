# Changelog

All notable changes to Shōmei are documented here. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versioning is date-based pre-1.0 and will move
to semantic versioning (`MAJOR.MINOR.PATCH`) and git tags (`vMAJOR.MINOR.PATCH`) at the first
tagged release.

## Unreleased

### Added — MasterPlan 7 (Interop Wave), EP-2: the admin HTTP API

A deployed Shōmei is now administrable over HTTP, not only with the `shomei-admin` CLI on the box.

- **Eleven operations under `/v1/admin`**: list and get users (keyset-paginated, `?status=`
  filtered), suspend, reinstate, soft-delete, list and revoke sessions, revoke one session,
  trigger a password reset for a user by id, and grant/revoke a role. All eleven have typed
  `shomei-client` wrappers and are documented in the OpenAPI spec.
- **The gate is the `admin` role OR the `shomei:admin` scope.** The role is for humans (granted
  from the store); the scope is minted onto a service token, so a database-less support console
  can administer too.
- **Two refusals.** A delegated (impersonation) token cannot perform an admin mutation
  (`403 impersonation_action_blocked`, itself audited) — otherwise impersonation would launder
  privilege. An administrator cannot suspend or delete their own account
  (`403 self_target_forbidden`), so one mistyped id cannot lock the last admin out; revoking your
  own sessions is still allowed.
- **Strict status transitions.** Suspending an already-suspended user is `409 invalid_user_status`,
  not a silent success: two administrators handling one incident must be able to tell which of
  them changed the state. Delete is a soft delete; the row and its audit trail survive.
- **Every mutation is audited with the acting administrator.** `user_suspended`,
  `user_reinstated` (new) and `user_deleted` carry `payload.actor`; `session_revoked` carries
  `payload.revokedBy`. Both are `null` for self-service revocations (logout, refresh-token reuse,
  stopping an impersonation) and for events written before this release.
- **`SessionResponse` gains `status` and `revokedAt`** (additive). Without them an admin listing a
  user's sessions could not tell a live one from a revoked one. `GET /v1/auth/session` returns
  them too.

Suspending or deleting a user revokes their sessions immediately, so they cannot refresh. Their
outstanding *access* tokens ride out their TTL unless the deployment sets
`sessionCheckMode = VerifyTokenAndSession`.

### Breaking (pre-1.0 window) — MasterPlan 7 (Interop Wave), EP-3: `/v1` and problem-details errors

Shōmei has never cut a tagged release. These changes land together, deliberately, so that a
consumer migrates once rather than three times. Every later MasterPlan-7 endpoint (the admin API,
OAuth2, OIDC, token exchange, TOTP) is born under the contract established here.

**1. Application routes moved under `/v1`.** `POST /auth/login` is now `POST /v1/auth/login`, and
so on for every `/auth/*` and `/admin/*` route. The old paths are **gone** — they answer `404`,
with no redirect. Prefix your base URL, or upgrade the typed `shomei-client` (its function
signatures are unchanged; the segment lives in the route type).

Unversioned, and staying that way: `GET /.well-known/jwks.json`, `GET /health`, `GET /ready`,
`GET /metrics`, `GET /openapi.json`, and the future `/oauth/*`. Protocol and infrastructure
endpoints are consumed by tools that look for them at conventional locations.

Two path literals move with the routes and are worth checking in your own deployment: the
`shomei_refresh` cookie is now scoped to `Path=/v1/auth/refresh`, and the account-lifecycle email
links now point at `<publicBaseUrl>/v1/auth/{verify-email,password-reset}/confirm`.

**2. Every error is now an RFC 7807 problem document.** The `{"error":"…","message":"…"}` shape is
gone, not dual-emitted:

```jsonc
// before
{"error": "token_invalid", "message": "Token is invalid"}

// after — Content-Type: application/problem+json
{"type": "about:blank", "title": "Token is invalid", "status": 401, "code": "token_invalid"}
```

**Every existing error string survives verbatim in the `code` member**, so client switch-logic
ports by reading `code` instead of `error`. A `401` now carries `WWW-Authenticate: Bearer`; a
`429` carries `Retry-After`. Failures that previously escaped the envelope entirely — an expired
bearer token (plain-text `"invalid token"`), a missing role, a malformed JSON body, an unknown
route, a wrong method, a throttled request — now return the same document as everything else.

Exempt: `GET /ready`'s `503` remains a `{"status","database","signingKey"}` probe document, and the
future `POST /oauth/token` will use RFC 6749 §5.2's `{"error":"invalid_grant",…}` shape, which
OAuth2 clients require.

**3. Three status codes corrected.**

| Endpoint | Was | Now | What to change |
|---|---|---|---|
| `POST /v1/auth/signup` | `200` | `201 Created` | it creates a user; compare `< 300`, not `== 200`. Body unchanged |
| `POST /v1/auth/verify-email/confirm` | `202` | `200` | the work completes inside the request; `202` promised pending work that never existed |
| `POST /v1/auth/password-reset/confirm` | `202` | `200` | as above |
| `POST /v1/auth/logout` on an already-revoked session | `404 session_not_found` | `204` | logout is now idempotent; drop any "already logged out" special case |

The two lifecycle *request* endpoints (`verify-email/request`, `password-reset/request`) stay
`202`: delivery genuinely happens later, and their unconditional response is the anti-enumeration
contract.

### Added — MasterPlan 7 (Interop Wave), EP-3

- **`GET /openapi.json`.** The server serves the OpenAPI 3.1 document for the binary that is
  running, so a generated client matches the deployment rather than a committed file.
- **The spec documents the error surface.** A `Problem` component schema, and per-operation error
  responses whose `properties.code.enum` names exactly the codes that operation can return. Both
  are generated from the same constants the server renders at runtime, so status and title cannot
  drift; a conformance test enforces it.
- **Spec fixes.** `204` responses no longer carry a `content` map (which was invalid), every
  response has a real description, and every request body is marked `required`.
- **`Cache-Control: public, max-age=300` on the JWKS document.** Key rotation is staged, so a
  retiring key stays trusted far longer than five minutes: a stale cache can never reject a valid
  token, while five minutes bounds how long a revoked key's public half lingers.

### Added — MasterPlan 7 (Interop Wave), EP-1: persistent roles and claims enrichment

- **Roles have a source of truth.** A `shomei_roles` registry (seeded with `admin`) and a
  `shomei_role_grants` table, behind a new `RoleStore` port with PostgreSQL and in-memory
  interpreters. Grants and revocations are audited (`role_granted` / `role_revoked`).
- **The `roles` claim is finally populated.** Every user-session token mint — signup, login, MFA
  completion, passwordless login, refresh — builds its claims through the new
  `Shomei.Workflow.Session.buildEnrichedClaims`, which reads the subject's roles from the store.
  A role change takes effect at the **next mint** (login or refresh), never on an outstanding
  access token; revoke the user's sessions when you need it to bite immediately.
- **A claims-enrichment hook for embedding hosts.** The new `ClaimsEnricher` effect lets a host
  add roles, scopes, and custom claims at mint time, exactly as `Notifier` lets it deliver mail.
  The delta is merged, never substituted: reserved claims (`sub`, `iss`, `roles`, …) cannot be
  forged through it.
- **`shomei-admin roles define | list-defined | grant | revoke | list`.** The bootstrap path for
  the first administrator. Granting a role absent from the registry fails loudly rather than
  minting a role nothing checks (`roles grant --role adminn` → exit 1).
- **Default roles for new users.** `defaultRoles` in the Dhall config, or
  `SHOMEI_DEFAULT_ROLES=member,beta-tester`. Applied inside the signup workflow before the first
  token is minted, audited with no acting admin. The server refuses to start — and
  `shomei-admin users create` refuses to run — when a configured role is not in the registry.

### Fixed — MasterPlan 7 EP-1

- **`RequireRole` / `RequireScope` now enforce.** They were phantom types with no `HasServer`
  instance: a route type that carried one compiled and enforced *nothing*, so a route author who
  wrote the type but forgot the in-handler guard shipped a silently unprotected route. They are
  now real combinators that authenticate the caller and reject a principal lacking the role or
  scope with `403`, with no handler code at all. They **replace** `Authenticated` on a route
  rather than accompanying it.
- **`GET /admin/audit/events` is reachable.** It was gated on an `admin` role that no production
  flow could mint — the endpoint was unsatisfiable outside of tests. It now carries
  `RequireRole "admin"`, and `shomei-admin roles grant` mints the role. The OpenAPI document is
  unchanged: the route was, and remains, documented as bearer-secured.
- **`shomei-admin users create` honors `SHOMEI_DEFAULT_ROLES`.** Its config loader built a
  `defaultShomeiConfig` directly and ignored the variable, so a CLI-created user silently
  differed from an API-created one.

### Added — MasterPlan 2 (Production Hardening, Account Lifecycle, and Adoption)

- **Account lifecycle (EP-1):** email verification and password reset/change behind a pluggable
  `Notifier` effect. Shōmei emits each notification (recipient, one-time link/token, expiry) and
  ships a development log-only sender; it does not deliver email — operators forward the
  notification to their own provider (SendGrid, Resend, SES, an SMTP relay, …) via their own
  `Notifier` interpreter. A future `shomei-email` package may add in-tree senders.
- **Abuse protection (EP-2):** per-account brute-force lockout, per-IP failure throttle, and a
  per-IP request-rate WAI token bucket; all responses generic (no account-existence leak).
- **Observability (EP-3):** structured JSON request logs with correlation ids, a hand-rolled
  Prometheus `/metrics` endpoint, a `/ready` readiness probe distinct from `/health`, and
  graceful shutdown on SIGTERM/SIGINT.
- **Operational CLI (EP-4):** `shomei-admin` with `migrate`, `keys
  generate/activate/retire/revoke/list`, and `users create`; zero-downtime signing-key rotation
  (`pending → active → retired → revoked`) with overlapping-key JWKS verification.
- **Packaging & config (EP-5):** typed Dhall + environment configuration loader; a production
  OCI image via the Nix flake; a local `process-compose` stack (PostgreSQL on a Unix socket +
  the server) for development/test; and a CI pipeline.

### Changed — Generalized login identifier with optional email (SH-25)

- **The principal is now a free-form login identifier (`LoginId`), not the email.** A new
  `Shomei.Domain.LoginId` newtype (case-insensitive, trimmed, no `@`/dot requirement) is the
  unique handle a user signs up and logs in with; `email` becomes an **optional attribute** on
  `User`/`NewUser`/`Credential`. Callers can now sign up and log in as `agent-4815162342` with no
  email at all. Lookups key on the login id (`FindUserByLoginId` /
  `FindPasswordCredentialByLoginId`; `CreatePasswordCredential :: UserId -> LoginId -> Maybe Email
  -> PasswordHash`), while lookup-by-email is retained for the reset/verification paths.
- **Email-dependent behavior is preserved when an email is present:** password-reset and
  email-verification delivery, the "resembles identity" password rule, and the HIBP breach
  context all still consume the email; the WebAuthn passkey user-handle was always user-id-derived
  and is unaffected.
- **Database (expand/contract migrations):** `shomei_users` and `shomei_password_credentials`
  gain a `login_id text NOT NULL UNIQUE` column (backfilled from `email`), and `email` is relaxed
  to nullable with a partial unique index (`WHERE email IS NOT NULL`) so multiple NULL emails
  coexist. Migrations are idempotent and re-runnable.
- **HTTP wire (backward-compatible):** `SignupRequest`/`LoginRequest` accept optional
  `loginId`/`email` (at least one required); `UserResponse` carries `loginId` and a nullable
  `email`. An `email`-only request defaults `loginId` to the email text, so existing email-first
  clients are unchanged. New error codes `invalid_login_id` (`400`) and `login_id_taken` (`409`).

### Added — Configurable JWT signing algorithm and extensible custom claims (SH-24)

- **Selectable signing algorithm:** keys are **ES256** (ECDSA P-256) by default or **RS256**
  (RSASSA-PKCS1-v1_5), chosen via `SHOMEI_SIGNING_ALG` / the Dhall `signingAlgorithm` field /
  `shomei-admin keys generate --alg`. The choice drives key generation, the JWT header `alg`, and
  the published JWKS; the `kid` is unchanged so rotation and multi-key verification still work.
  RS256 is pinned explicitly (never the PSS variant `jose` would otherwise prefer for RSA keys).
- **Extensible custom claims:** a host service can attach arbitrary top-level JSON claims to every
  token via `AuthClaims.extraClaims` / `buildClaimsWith`; they round-trip through sign/verify.
  Reserved standard claims cannot be forged through the bag. Ordinary (empty-`extraClaims`) ES256
  tokens are byte-for-byte unchanged.
