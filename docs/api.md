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
Body `{"email","password","displayName"?}`. → `200` `{"user":{…},"token":{"accessToken","refreshToken","expiresIn"}}`. `409 email_taken` if the email exists; `400 weak_password` / `invalid_email` on policy/format failures.

### `POST /auth/login`
Body `{"email","password"}`. → `200` with a **tagged** response: `{"status":"complete","user":{…},"token":{…}}` for an account with no passkey (unchanged behavior), or `{"status":"mfa_required","ceremonyId":"…","options":{…}}` when the account has a passkey and `webauthnConfig.mfaRequired` is set — complete the WebAuthn assertion at `POST /auth/mfa/complete` to obtain tokens (see [Passkeys & MFA](#passkeys--mfa-masterplan-3)). → `401 invalid_login` on any credential/lockout failure. → `429 too_many_requests` if the per-IP failure throttle has tripped.

### `POST /auth/refresh`
Body `{"refreshToken"}`. → `200` `{"accessToken","refreshToken","expiresIn"}` (the old refresh token is rotated and invalidated). Presenting a reused token revokes the whole token family and the session (`401 token_reuse`).

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

## Operational endpoints

### `GET /.well-known/jwks.json`
→ `200` the public JWKS document (the `active` plus still-trusted `retired` signing keys). Downstream services fetch this to verify Shōmei's tokens locally.

### `GET /health`  (liveness)
→ `200 {"status":"ok"}` as long as the process is alive. Dependency-free.

### `GET /ready`  (readiness)
→ `200 {"status":"ready","database":true,"signingKey":true}` only when PostgreSQL is reachable **and** an active signing key exists; otherwise `503` with the failing check. Use this to gate traffic; use `/health` to decide restarts.

### `GET /metrics`
→ `200` Prometheus text exposition (raw WAI, bypassing the typed API): `http_requests_total{method,status}`, `http_requests_in_flight`, the `http_request_duration_seconds` histogram, and the domain counters `shomei_logins_succeeded_total` / `shomei_logins_failed_total` / `shomei_tokens_issued_total`.

## Correlation ids

Every response carries an `X-Request-Id` header (echoed from the request if supplied, else
generated). The same id appears in the server's structured JSON log line for that request.
