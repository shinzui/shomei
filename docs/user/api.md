# Shōmei HTTP API

All routes are defined by the `ShomeiRoutes` `NamedRoutes` record in
`shomei-servant/src/Shomei/Servant/API.hs` and served by `shomei-server` (default port
`8080`). Request and response bodies are JSON. Authenticated routes require an
`Authorization: Bearer <access-token>` header — or, in cookie transport, the `shomei_session`
cookie (see below).

## Versioning

Application routes live under **`/v1`**: `/v1/auth/login`, `/v1/admin/audit/events`. Protocol
and infrastructure endpoints keep unversioned root paths, because that is where the tools that
consume them look:

| Unversioned | Why |
|---|---|
| `GET /.well-known/jwks.json` | OAuth2/OIDC verifiers auto-configure from the conventional location |
| `GET /openapi.json` | describes the whole server, including the non-`/v1` surface |
| `GET /health`, `GET /ready` | deployment contracts a load balancer is configured against |
| `GET /metrics` | scrape target (a WAI middleware; it never reaches the router) |

The unprefixed paths are **gone**, not redirected: `POST /auth/login` is a `404`. See the
CHANGELOG for the migration.

## Errors

Every error — from a handler, a workflow, the token verifier, an authorization combinator,
Servant's own request parser, or the rate limiter — is an [RFC 7807][rfc7807] problem document
served as `Content-Type: application/problem+json`:

```json
{"type":"about:blank","title":"Token is invalid","status":401,"code":"token_invalid"}
```

| Member | Meaning |
|---|---|
| `code` | the machine key. **Switch on this.** These are the same strings the old `{"error":…}` shape carried |
| `title` | stable human text for the error kind |
| `status` | mirrors the HTTP status |
| `type` | always `about:blank` — Shōmei hosts no error-documentation URLs |
| `detail` | *optional*; explains this occurrence (a parse message, the offending role name) |

A `401` carries `WWW-Authenticate: Bearer`; a `429` carries `Retry-After`.

Which codes a given endpoint can return is machine-readable in the OpenAPI document
(`GET /openapi.json`, or the committed `docs/api/openapi.json`): each error response narrows the
`Problem` schema with `properties.code.enum`.

Authentication errors are deliberately **generic** — a wrong password, an unknown account, and a
locked account all return the same `401` with `code: "invalid_login"`, so the API never discloses
which emails are registered (see [security.md](security.md)).

Two responses are exempt from the envelope. `GET /ready` answers `503` with a
`{"status","database","signingKey"}` probe document — a status report, not an error. The future
`POST /oauth/token` will use RFC 6749 §5.2's `{"error":"invalid_grant",…}` shape, which OAuth2
clients require.

[rfc7807]: https://www.rfc-editor.org/rfc/rfc7807

## Token transport

`SHOMEI_TOKEN_TRANSPORT` selects how tokens travel. **Bearer is the default and is unchanged.**

| Mode | Response bodies | Cookies set | Cookies accepted as credentials |
|------|-----------------|-------------|-------------------------------|
| `bearer` (default) | carry `accessToken` + `refreshToken` | never | **never** |
| `cookie` | omit both token fields (`expiresIn` remains) | yes | yes |
| `both` | carry both token fields | yes | yes |

A bearer token is accepted in *every* mode: a foreign page cannot set an `Authorization` header,
and service/CLI callers need it.

The two cookies, set together by every response that issues a token pair (`signup`, `login`'s
`complete` arm, `refresh`, `mfa/complete`, `login/passkey/complete`):

```text
Set-Cookie: shomei_session=<jwt>;   Path=/;              Max-Age=900;     HttpOnly; Secure; SameSite=Lax
Set-Cookie: shomei_refresh=<token>; Path=/v1/auth/refresh;  Max-Age=2592000; HttpOnly; Secure; SameSite=Lax
```

`HttpOnly` keeps them out of page JavaScript, so an XSS payload cannot read the session.
`shomei_refresh` is scoped to the one endpoint that consumes it. `POST /v1/auth/logout` re-sets both
with an empty value and `Max-Age=0`. `Secure` and `SameSite` are configurable
(`SHOMEI_COOKIE_SECURE`, `SHOMEI_COOKIE_SAMESITE`).

**CSRF.** Because browsers attach cookies automatically, any **cookie-authenticated mutating
request** (anything but `GET`/`HEAD`/`OPTIONS`) must carry an allow-listed `Origin` header — or,
if `Origin` is absent, a `Referer` under an allowed origin. Otherwise:

```text
403 {"type":"about:blank","title":"Origin not allowed for cookie-authenticated request","status":403,"code":"csrf_rejected"}
```

Configure the allow-list with `SHOMEI_CSRF_ALLOWED_ORIGINS` (comma-separated). Requests with
*neither* header fail closed. **Bearer-authenticated requests are never CSRF-gated**, in any
mode. The same gate applies to `POST /v1/auth/refresh` when the refresh token comes from its cookie.

## Account & session

### `POST /v1/auth/signup`
Body `{"loginId"?,"email"?,"password","displayName"?}`. The principal is a free-form, case-insensitive **login identifier** (`loginId`); `email` is optional. At least one of `loginId`/`email` must be present (`400 "loginId or email required"` otherwise); when only `email` is supplied, `loginId` defaults to the normalized email text (backward-compatible for email-first callers). → `201 Created` `{"user":{…},"token":{"accessToken","refreshToken","expiresIn"}}` where `user` carries `loginId` and a nullable `email`. `409 login_id_taken` if the identifier exists (`409 email_taken` if a supplied email collides); `400 weak_password` / `invalid_login_id` / `invalid_email` on policy/format failures. In cookie transport this response also sets the `shomei_session`/`shomei_refresh` cookies and omits the body token values (see [Token transport](#token-transport)).

### `POST /v1/auth/login`
Body `{"loginId"?,"email"?,"password"}`. Identify by `loginId`; an `email`-only body resolves to the same default identifier as signup. → `200` with a **tagged** response: `{"status":"complete","user":{…},"token":{…}}` for an account with no passkey (unchanged behavior), or `{"status":"mfa_required","ceremonyId":"…","options":{…}}` when the account has a passkey and `webauthnConfig.mfaRequired` is set — complete the WebAuthn assertion at `POST /v1/auth/mfa/complete` to obtain tokens (see [Passkeys & MFA](#passkeys--mfa-masterplan-3)). → `401 invalid_login` on any credential/lockout failure. → `429 too_many_requests` if the per-IP failure throttle has tripped. → `403 email_not_verified` when `emailVerificationRequired` is enabled and the account's email is unverified. The `complete` arm sets the cookies in cookie transport; the `mfa_required` arm sets none (no token was issued).

### `POST /v1/auth/refresh`
Body `{"refreshToken"}` — **optional**: in cookie transport the token is read from the `shomei_refresh` cookie instead and a browser client posts `{}`. A body value takes precedence. A cookie-borne token is CSRF-gated (an allow-listed `Origin`/`Referer` is required, else `403 csrf_rejected`). → `200` `{"accessToken","refreshToken","expiresIn"}` (the old refresh token is rotated and invalidated). Presenting a reused token revokes the whole token family and the session (`401 token_reuse`); so does losing a race, since two concurrent presentations of one token can never both rotate it. Once the session reaches its absolute lifetime (`sessionTTL`, default 30 days from login) refreshing no longer works: `401 session_expired` — the client must log in again. → `403 email_not_verified` when `emailVerificationRequired` is enabled and the account's email is unverified.

### `POST /v1/auth/service-token`
Body `{"accountId","secret","scopes","actorId"?}`. This endpoint is unauthenticated by bearer token:
the configured service account id and shared secret in the JSON body are the credential. The
server hashes `secret` with SHA-256, encodes the digest as lowercase hex, and compares it with the
configured account `secretSha256` using constant-time byte comparison. A successful request returns
`200 {"accessToken","expiresIn"}` with **no refresh token**. The access token's `sub` is the
configured service-account user id, `scopes` contains exactly the requested allowed scopes, and
`act` is set to `actorId` only when supplied and when that user exists and is active.

Service-token issuance is disabled unless `serviceToken.enabled` or
`SHOMEI_SERVICE_TOKEN_ENABLED=true` enables it and the account is configured. Unknown account ids,
bad secrets, disabled issuance, and scopes outside the account allow-list return `403`; an empty
`scopes` array or malformed `actorId` returns `400`. Normal `POST /v1/auth/login` tokens still carry
empty scopes, so a host route guarded by `requireScope (Scope "kawa:ingest")` accepts a service
token with that scope and rejects a normal login token with `403`.

See [service-tokens.md](service-tokens.md) for configuration and operating guidance.

### `POST /v1/auth/logout` *(authenticated)*
→ `204`. Revokes the caller's session and its refresh tokens. In cookie transport the response
clears both cookies (`Max-Age=0`), and — being a mutating request — a cookie-authenticated logout
requires an allow-listed `Origin`.

**Idempotent:** logging out a session that is already gone is also `204`, not `404`. Retrying
after a network blip succeeds. (Under `sessionCheckMode = VerifyTokenAndSession` the second call
is a `401` instead, because the access token no longer verifies against the revoked session.)

### `GET /v1/auth/me` *(authenticated)*
→ `200` the caller's user record. `404` if the user row is missing.

### `GET /v1/auth/session` *(authenticated)*
→ `200` the caller's session record: `{"sessionId","userId","createdAt","expiresAt","status","revokedAt"}`.

## Account lifecycle (EP-1)

The two *request* endpoints always return `202 Accepted` regardless of whether the email exists
(no account-existence leak); when the account exists a one-time link is delivered through the
`Notifier` (the development sender logs it). The *confirm* endpoints also return `202`. Shōmei
does not send email itself — see [notifications.md](notifications.md) for delivering these links
through your own provider.

### `POST /v1/auth/verify-email/request`
Body `{"email"}`. → `202`. Logs a verification link for a real, unverified account.

### `POST /v1/auth/verify-email/confirm`
Body `{"token"}`. → `200`. Marks the account verified (`email_verified_at`); the work completes inside the request. `400 verification_token_invalid` for an unknown/consumed/expired token.

### `POST /v1/auth/password-reset/request`
Body `{"email"}`. → `202` (byte-identical for known and unknown emails). Logs a reset link for a real account.

### `POST /v1/auth/password-reset/confirm`
Body `{"token","newPassword"}`. → `200`. Changes the password **and revokes all of the user's sessions and refresh tokens**. `400 password_reset_token_invalid` on a bad token.

### `POST /v1/auth/password/change` *(authenticated)*
Body `{"currentPassword","newPassword"}`. → `204`. Verifies the current password, changes it, and revokes the user's other sessions. `401 invalid_login` if the current password is wrong.

## Passkeys & MFA (MasterPlan 3)

A *passkey* is a public-key credential held by the user's device (Touch ID/Face ID, Windows
Hello, a YubiKey, or a synced provider). After enrolling one, an account is protected by both a
password and the device — `POST /v1/auth/login` no longer returns tokens for that account until the
WebAuthn assertion is completed. All `options`/`credential`/`assertion` values are the standard
`@github/webauthn-json` browser payloads, passed through verbatim as JSON. See
[passkeys.md](passkeys.md) for the full guide.

### `POST /v1/auth/passkeys/register/begin` *(authenticated)*
Empty body. → `200` `{"ceremonyId":"webauthn_ceremony_…","options":{…creation options…}}`. The browser feeds `options` to `navigator.credentials.create()`.

### `POST /v1/auth/passkeys/register/complete` *(authenticated)*
Body `{"ceremonyId","credential","label"?}`. → `200` `{"passkeyId","label","transports","createdAt","lastUsedAt"}` (never the public-key bytes). `404 ceremony_not_found` (missing/expired/consumed); `400 webauthn_verification_failed` (verification failed).

### `GET /v1/auth/passkeys` *(authenticated)*
→ `200` an array of the `PasskeyResponse` object above.

### `DELETE /v1/auth/passkeys/{passkeyId}` *(authenticated)*
→ `204`. `404 passkey_not_found` if the passkey is not owned by the caller.

### `POST /v1/auth/mfa/complete`
Completes a step-up after `POST /v1/auth/login` returned `mfa_required`. Body `{"ceremonyId","assertion"}`. → `200` `{"accessToken","refreshToken","expiresIn"}`. `404 ceremony_not_found`; `401 mfa_failed` if the assertion does not verify; `400` if `ceremonyId` is malformed. → `403 email_not_verified` when `emailVerificationRequired` is enabled and the account's email is unverified. Sets the cookies in cookie transport. (There is no `/v1/auth/mfa/begin` — the challenge rides in the `mfa_required` arm of the login response.)

### `POST /v1/auth/login/passkey/begin`
Empty body (passwordless). → `200` `{"ceremonyId","options"}`. The browser feeds `options` to `navigator.credentials.get()`.

### `POST /v1/auth/login/passkey/complete`
Body `{"ceremonyId","assertion"}`. → `200` `{"accessToken","refreshToken","expiresIn"}` — the passkey is the strong factor, so this returns a token pair directly (never an MFA challenge). `404 ceremony_not_found`; `401 mfa_failed` on a failed assertion. → `403 email_not_verified` when `emailVerificationRequired` is enabled and the account's email is unverified. Sets the cookies in cookie transport.

## Impersonation / delegated tokens

A *delegated token* lets an authorized internal operator act **on behalf of** a customer while
keeping their own identity attached. The minted access token carries **two identities**: `sub`
is the customer being acted upon and `act` is the real operator (mirroring RFC 8693). The
delegated session is a brand-new, short-lived row with **no refresh token**, so it cannot be
silently renewed and expires at its TTL. Shōmei gates only its own credential-changing endpoints
against delegated tokens; who-may-impersonate-whom policy and business-action gating live in the
embedding service, which reads `act`/`sub` from the verified token. See
[security.md](security.md#impersonation--delegated-tokens).

### `POST /v1/auth/impersonate` *(authenticated)*
Body `{"userId","reason","ticketId"?}`. The caller must hold the `impersonate:user` scope and
their own access token must have been issued within the freshness window (default 5 minutes). →
`200` `{"accessToken","subjectUserId","actorUserId","expiresAt"}` — `accessToken` is the delegated
token (`sub`=customer, `act`=operator). `403 impersonation_forbidden` if the caller lacks the
scope or is not fresh enough; `400 impersonation_target_invalid` if the target is missing, not
active, or is the caller themselves.

### `DELETE /v1/auth/impersonate` *(authenticated)*
Presented with a delegated token. → `204`. Revokes the delegated session named by the token.
`400 impersonation_target_invalid` if the presented token is not a delegated token (no `act`).

Credential-changing endpoints (`POST /v1/auth/password/change`, `POST /v1/auth/passkeys/register/begin`,
`POST /v1/auth/passkeys/register/complete`, `DELETE /v1/auth/passkeys/{passkeyId}`) **refuse** any request
bearing a delegated token with `403 impersonation_action_blocked` and write an audit record. An
operator can look but cannot change the customer's credentials.

## Admin API

Eleven operations for managing users and sessions over HTTP, so a deployed Shōmei is
administrable without shell access to the box.

**Authorization.** Every route below requires the `admin` **role** *or* the `shomei:admin`
**scope**. The role is granted from the store (`shomei-admin roles grant`, or
`PUT /v1/admin/users/{userId}/roles/admin` below); the scope is minted onto a service token, so a
database-less support console or back-office job can administer too. Without either: `403` with
`code: "missing_role"`. Without any token: `401`.

**Two refusals.**

- Every *mutation* refuses a **delegated (impersonation) token** — one carrying an `act` claim —
  with `403 impersonation_action_blocked`, and audits the refusal. An operator impersonating a
  customer must not be able to administer as that customer. Reads are allowed.
- An administrator cannot **suspend or delete their own account** (`403 self_target_forbidden`),
  so one mistyped id cannot lock the last admin out. They *may* revoke their own sessions, which
  is what you do when a laptop is stolen.

**Status transitions are strict, not idempotent.** Suspending an already-suspended user is
`409 invalid_user_status`, not a silent success — two administrators responding to one incident
must be able to tell which of them changed the state. Delete is a **soft delete**: the status
becomes `deleted`, the row survives (sessions, role grants and audit events reference it), and the
user still appears in listings.

**Token staleness.** Suspending or deleting a user revokes their sessions immediately, so they
cannot refresh. Their outstanding *access* tokens still work until they expire (default 15
minutes) unless the deployment sets `sessionCheckMode = VerifyTokenAndSession`, which re-reads the
session on every request. See [security.md](security.md).

Every mutation is audited with the acting administrator's id: `user_suspended`, `user_reinstated`,
`user_deleted` carry `payload.actor`; `session_revoked` carries `payload.revokedBy`.

### `GET /v1/admin/users`
`?status=active|suspended|deleted` `?limit=<n>` (default 50, clamped to 1000) `?before=<cursor>`.
→ `200 {"users":[…],"nextCursor":"…"|null}`, newest first. Keyset-paginated on
`(createdAt, userId)`: pass a page's `nextCursor` back as `?before=` for the next one. `nextCursor`
is present whenever the page came back full. `400 bad_request` on an unknown status or a malformed
cursor.

### `GET /v1/admin/users/{userId}`
→ `200 {"user":{…},"roles":["admin",…]}` — the user plus the roles actually granted in the store,
which is not necessarily what an outstanding token of theirs carries. `404 user_not_found`.

### `POST /v1/admin/users/{userId}/suspend`
→ `204`. Suspends an active user and revokes all their sessions. `409 invalid_user_status` if they
are not active; `403 self_target_forbidden` if they are you.

### `POST /v1/admin/users/{userId}/reinstate`
→ `204`. Returns a suspended user to service. Their old sessions stay revoked; they log in again.
`409 invalid_user_status` if they are not suspended.

### `DELETE /v1/admin/users/{userId}`
→ `204`. Soft-deletes the user and revokes their sessions. `409` if already deleted; `403` if they
are you.

### `GET /v1/admin/users/{userId}/sessions`
→ `200` every session of the user, newest first, in every status
(`{"sessionId","userId","createdAt","expiresAt","status","revokedAt"}`). Unpaginated: sessions per
user are bounded small. `404 user_not_found`.

### `DELETE /v1/admin/users/{userId}/sessions`
→ `204`. Revokes every *active* session of the user. `404 user_not_found`.

### `DELETE /v1/admin/sessions/{sessionId}`
→ `204`. Revokes one session, whoever owns it. `404 session_not_found`.

### `POST /v1/admin/users/{userId}/password-reset`
→ `202`. Drives the ordinary reset flow (same token table, same `Notifier` delivery, same audit
event) for a user named by id. `409 user_has_no_email` if they have no address — unlike the public
endpoint, an authorized admin who already holds the user id learns nothing from a real error.

### `PUT /v1/admin/users/{userId}/roles/{role}`
→ `204`. Grants a role. **Idempotent**: re-granting a held role is still `204`, and no duplicate
audit event is written. `422 role_not_defined` if the role is not in the registry (define it with
`shomei-admin roles define`); `400 bad_request` on a blank name.

### `DELETE /v1/admin/users/{userId}/roles/{role}`
→ `204`. `404 role_not_granted` if the user did not hold it — unlike the idempotent grant,
revoking something that was never there is a request you got wrong, and silently succeeding would
hide a typo in the role name.

**Roles reach the next token, not the current one.** A grant takes effect at the target's next
login or refresh. Revoke their sessions if you need it to bite immediately.

## Audit log (EP-7)

### `GET /v1/admin/audit/events` *(admin role required)*
Read the append-only security audit trail (`shomei_auth_events`), newest first. Query params,
all optional: `user` (UUID), `session` (UUID), `type` (repeatable — `?type=login_failed&type=account_locked`),
`since` (ISO-8601, inclusive), `until` (ISO-8601, exclusive), `limit` (default 50, clamped to
1000), and `before` (an opaque cursor from a previous page's `nextCursor`). → `200`
`{"events":[{"eventId","eventType","userId","sessionId","createdAt","payload"},…],"nextCursor":"…|null"}`;
page by passing `nextCursor` back as `?before=`. → `400` on a malformed UUID/timestamp/cursor.
Gated by the `RequireRole "admin"` route combinator: → `401` with no token, `403` for a token
whose principal lacks the role. Grant it with `shomei-admin roles grant --user <id> --role admin`
(see [security.md](security.md#granting-roles)); the role reaches the token at the next login or
refresh, not on one already issued.

> **Admin-role limitation.** Signup/login do not issue roles, so no production flow yields an
> admin token yet; this endpoint is exercised by tests and out-of-band-minted tokens. The
> supported operator path today is the `shomei-admin audit …` CLI (see [security.md](security.md)).

## Operational endpoints

### `GET /.well-known/jwks.json`
→ `200` the public JWKS document (the `active` plus still-trusted `retired` signing keys). Downstream services fetch this to verify Shōmei's tokens locally. Keys are EC (`"kty":"EC"`, for ES256) or RSA (`"kty":"RSA"`, for RS256) depending on the configured signing algorithm; verifiers select by `kid` and read the `alg`/`kty` from the key, so a mixed set during an algorithm rotation verifies correctly. A host service embedding Shōmei may also attach its own top-level claims to issued tokens (`AuthClaims.extraClaims`); these appear in the JWT payload beside the standard `sub`/`sid`/`scopes`/`roles` claims and are preserved on verification.

The response carries `Cache-Control: public, max-age=300`. Key rotation is staged
(`pending → active → retired → revoked`, see [security.md](security.md)), so a retiring key stays
*trusted* for verification far longer than five minutes: a stale copy of this document can never
reject a valid token, and five minutes bounds how long a revoked key's public half lingers in
verifier caches.

### `GET /openapi.json`
→ `200` the OpenAPI 3.1 document for **the binary that is answering**, so a generated client
matches the deployment rather than a spec file someone remembered to commit. Identical in content
to `docs/api/openapi.json` for the same build. See
[openapi-client-generation.md](openapi-client-generation.md).

### `GET /health`  (liveness)
→ `200 {"status":"ok"}` as long as the process is alive. Dependency-free.

### `GET /ready`  (readiness)
→ `200 {"status":"ready","database":true,"signingKey":true}` only when PostgreSQL is reachable **and** an active signing key exists; otherwise `503` with the failing check. Use this to gate traffic; use `/health` to decide restarts.

### `GET /metrics`
→ `200` Prometheus text exposition (raw WAI, bypassing the typed API): `http_requests_total{method,status}`, `http_requests_in_flight`, the `http_request_duration_seconds` histogram, and the domain counters `shomei_logins_succeeded_total` / `shomei_logins_failed_total` / `shomei_tokens_issued_total`.

## Correlation ids

Every response carries an `X-Request-Id` header (echoed from the request if supplied, else
generated). The same id appears in the server's structured JSON log line for that request.
