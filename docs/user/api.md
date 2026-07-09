# Shōmei HTTP API

All routes are defined by the `ShomeiAPI` `NamedRoutes` record in
`shomei-servant/src/Shomei/Servant/API.hs` and served by `shomei-server` (default port
`8080`). Request and response bodies are JSON. Authenticated routes require an
`Authorization: Bearer <access-token>` header.

Errors are returned as `{"error":"<code>","message":"<text>"}`. Authentication errors are
deliberately **generic** — a wrong password, an unknown account, and a locked account all return
the same `401 {"error":"invalid_login","message":"Invalid email or password"}` so the API never
discloses which emails are registered (see [security.md](security.md)).

## Account & session

### `POST /auth/signup`
Body `{"loginId"?,"email"?,"password","displayName"?}`. The principal is a free-form, case-insensitive **login identifier** (`loginId`); `email` is optional. At least one of `loginId`/`email` must be present (`400 "loginId or email required"` otherwise); when only `email` is supplied, `loginId` defaults to the normalized email text (backward-compatible for email-first callers). → `200` `{"user":{…},"token":{"accessToken","refreshToken","expiresIn"}}` where `user` carries `loginId` and a nullable `email`. `409 login_id_taken` if the identifier exists (`409 email_taken` if a supplied email collides); `400 weak_password` / `invalid_login_id` / `invalid_email` on policy/format failures.

### `POST /auth/login`
Body `{"loginId"?,"email"?,"password"}`. Identify by `loginId`; an `email`-only body resolves to the same default identifier as signup. → `200` with a **tagged** response: `{"status":"complete","user":{…},"token":{…}}` for an account with no passkey (unchanged behavior), or `{"status":"mfa_required","ceremonyId":"…","options":{…}}` when the account has a passkey and `webauthnConfig.mfaRequired` is set — complete the WebAuthn assertion at `POST /auth/mfa/complete` to obtain tokens (see [Passkeys & MFA](#passkeys--mfa-masterplan-3)). → `401 invalid_login` on any credential/lockout failure. → `429 too_many_requests` if the per-IP failure throttle has tripped.

### `POST /auth/refresh`
Body `{"refreshToken"}`. → `200` `{"accessToken","refreshToken","expiresIn"}` (the old refresh token is rotated and invalidated). Presenting a reused token revokes the whole token family and the session (`401 token_reuse`); so does losing a race, since two concurrent presentations of one token can never both rotate it. Once the session reaches its absolute lifetime (`sessionTTL`, default 30 days from login) refreshing no longer works: `401 session_expired` — the client must log in again.

### `POST /auth/service-token`
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
`scopes` array or malformed `actorId` returns `400`. Normal `POST /auth/login` tokens still carry
empty scopes, so a host route guarded by `requireScope (Scope "kawa:ingest")` accepts a service
token with that scope and rejects a normal login token with `403`.

See [service-tokens.md](service-tokens.md) for configuration and operating guidance.

### `POST /auth/logout` *(authenticated)*
→ `204`. Revokes the caller's session and its refresh tokens.

### `GET /auth/me` *(authenticated)*
→ `200` the caller's user record. `404` if the user row is missing.

### `GET /auth/session` *(authenticated)*
→ `200` the caller's session record.

## Account lifecycle (EP-1)

The two *request* endpoints always return `202 Accepted` regardless of whether the email exists
(no account-existence leak); when the account exists a one-time link is delivered through the
`Notifier` (the development sender logs it). The *confirm* endpoints also return `202`. Shōmei
does not send email itself — see [notifications.md](notifications.md) for delivering these links
through your own provider.

### `POST /auth/verify-email/request`
Body `{"email"}`. → `202`. Logs a verification link for a real, unverified account.

### `POST /auth/verify-email/confirm`
Body `{"token"}`. → `202`. Marks the account verified (`email_verified_at`). `400 verification_token_invalid` for an unknown/consumed/expired token.

### `POST /auth/password-reset/request`
Body `{"email"}`. → `202` (byte-identical for known and unknown emails). Logs a reset link for a real account.

### `POST /auth/password-reset/confirm`
Body `{"token","newPassword"}`. → `202`. Changes the password **and revokes all of the user's sessions and refresh tokens**. `400 password_reset_token_invalid` on a bad token.

### `POST /auth/password/change` *(authenticated)*
Body `{"currentPassword","newPassword"}`. → `204`. Verifies the current password, changes it, and revokes the user's other sessions. `401 invalid_login` if the current password is wrong.

## Passkeys & MFA (MasterPlan 3)

A *passkey* is a public-key credential held by the user's device (Touch ID/Face ID, Windows
Hello, a YubiKey, or a synced provider). After enrolling one, an account is protected by both a
password and the device — `POST /auth/login` no longer returns tokens for that account until the
WebAuthn assertion is completed. All `options`/`credential`/`assertion` values are the standard
`@github/webauthn-json` browser payloads, passed through verbatim as JSON. See
[passkeys.md](passkeys.md) for the full guide.

### `POST /auth/passkeys/register/begin` *(authenticated)*
Empty body. → `200` `{"ceremonyId":"webauthn_ceremony_…","options":{…creation options…}}`. The browser feeds `options` to `navigator.credentials.create()`.

### `POST /auth/passkeys/register/complete` *(authenticated)*
Body `{"ceremonyId","credential","label"?}`. → `200` `{"passkeyId","label","transports","createdAt","lastUsedAt"}` (never the public-key bytes). `404 ceremony_not_found` (missing/expired/consumed); `400 webauthn_verification_failed` (verification failed).

### `GET /auth/passkeys` *(authenticated)*
→ `200` an array of the `PasskeyResponse` object above.

### `DELETE /auth/passkeys/{passkeyId}` *(authenticated)*
→ `204`. `404 passkey_not_found` if the passkey is not owned by the caller.

### `POST /auth/mfa/complete`
Completes a step-up after `POST /auth/login` returned `mfa_required`. Body `{"ceremonyId","assertion"}`. → `200` `{"accessToken","refreshToken","expiresIn"}`. `404 ceremony_not_found`; `401 mfa_failed` if the assertion does not verify; `400` if `ceremonyId` is malformed. (There is no `/auth/mfa/begin` — the challenge rides in the `mfa_required` arm of the login response.)

### `POST /auth/login/passkey/begin`
Empty body (passwordless). → `200` `{"ceremonyId","options"}`. The browser feeds `options` to `navigator.credentials.get()`.

### `POST /auth/login/passkey/complete`
Body `{"ceremonyId","assertion"}`. → `200` `{"accessToken","refreshToken","expiresIn"}` — the passkey is the strong factor, so this returns a token pair directly (never an MFA challenge). `404 ceremony_not_found`; `401 mfa_failed` on a failed assertion.

## Impersonation / delegated tokens

A *delegated token* lets an authorized internal operator act **on behalf of** a customer while
keeping their own identity attached. The minted access token carries **two identities**: `sub`
is the customer being acted upon and `act` is the real operator (mirroring RFC 8693). The
delegated session is a brand-new, short-lived row with **no refresh token**, so it cannot be
silently renewed and expires at its TTL. Shōmei gates only its own credential-changing endpoints
against delegated tokens; who-may-impersonate-whom policy and business-action gating live in the
embedding service, which reads `act`/`sub` from the verified token. See
[security.md](security.md#impersonation--delegated-tokens).

### `POST /auth/impersonate` *(authenticated)*
Body `{"userId","reason","ticketId"?}`. The caller must hold the `impersonate:user` scope and
their own access token must have been issued within the freshness window (default 5 minutes). →
`200` `{"accessToken","subjectUserId","actorUserId","expiresAt"}` — `accessToken` is the delegated
token (`sub`=customer, `act`=operator). `403 impersonation_forbidden` if the caller lacks the
scope or is not fresh enough; `400 impersonation_target_invalid` if the target is missing, not
active, or is the caller themselves.

### `DELETE /auth/impersonate` *(authenticated)*
Presented with a delegated token. → `204`. Revokes the delegated session named by the token.
`400 impersonation_target_invalid` if the presented token is not a delegated token (no `act`).

Credential-changing endpoints (`POST /auth/password/change`, `POST /auth/passkeys/register/begin`,
`POST /auth/passkeys/register/complete`, `DELETE /auth/passkeys/{passkeyId}`) **refuse** any request
bearing a delegated token with `403 impersonation_action_blocked` and write an audit record. An
operator can look but cannot change the customer's credentials.

## Audit log (EP-7)

### `GET /admin/audit/events` *(admin role required)*
Read the append-only security audit trail (`shomei_auth_events`), newest first. Query params,
all optional: `user` (UUID), `session` (UUID), `type` (repeatable — `?type=login_failed&type=account_locked`),
`since` (ISO-8601, inclusive), `until` (ISO-8601, exclusive), `limit` (default 50, clamped to
1000), and `before` (an opaque cursor from a previous page's `nextCursor`). → `200`
`{"events":[{"eventId","eventType","userId","sessionId","createdAt","payload"},…],"nextCursor":"…|null"}`;
page by passing `nextCursor` back as `?before=`. → `400` on a malformed UUID/timestamp/cursor.
Gated by `requireRole (Role "admin")`: → `403` for a non-admin token, `401` with no token.

> **Admin-role limitation.** Signup/login do not issue roles, so no production flow yields an
> admin token yet; this endpoint is exercised by tests and out-of-band-minted tokens. The
> supported operator path today is the `shomei-admin audit …` CLI (see [security.md](security.md)).

## Operational endpoints

### `GET /.well-known/jwks.json`
→ `200` the public JWKS document (the `active` plus still-trusted `retired` signing keys). Downstream services fetch this to verify Shōmei's tokens locally. Keys are EC (`"kty":"EC"`, for ES256) or RSA (`"kty":"RSA"`, for RS256) depending on the configured signing algorithm; verifiers select by `kid` and read the `alg`/`kty` from the key, so a mixed set during an algorithm rotation verifies correctly. A host service embedding Shōmei may also attach its own top-level claims to issued tokens (`AuthClaims.extraClaims`); these appear in the JWT payload beside the standard `sub`/`sid`/`scopes`/`roles` claims and are preserved on verification.

### `GET /health`  (liveness)
→ `200 {"status":"ok"}` as long as the process is alive. Dependency-free.

### `GET /ready`  (readiness)
→ `200 {"status":"ready","database":true,"signingKey":true}` only when PostgreSQL is reachable **and** an active signing key exists; otherwise `503` with the failing check. Use this to gate traffic; use `/health` to decide restarts.

### `GET /metrics`
→ `200` Prometheus text exposition (raw WAI, bypassing the typed API): `http_requests_total{method,status}`, `http_requests_in_flight`, the `http_request_duration_seconds` histogram, and the domain counters `shomei_logins_succeeded_total` / `shomei_logins_failed_total` / `shomei_tokens_issued_total`.

## Correlation ids

Every response carries an `X-Request-Id` header (echoed from the request if supplied, else
generated). The same id appears in the server's structured JSON log line for that request.
