# Shōmei HTTP API

All routes are defined by the `ShomeiRoutes` `NamedRoutes` record in
`shomei-servant/src/Shomei/Servant/Api.hs` and served by `shomei-server` (default port
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
| `GET /health/live`, `GET /health/ready` | Kubernetes restart and traffic-gating probes |
| `GET /metrics` | scrape target (a WAI middleware; it never reaches the router) |
| `POST /oauth/token` | OAuth2 clients expect the token endpoint at a conventional location |
| `GET /.well-known/openid-configuration` | OIDC relying parties auto-configure from this exact path |
| `GET /oauth/authorize` | the authorization-code flow's browser leg |
| `GET /oauth/userinfo` | OIDC Core §5.3 |
| `POST /oauth/introspect` | RFC 7662 |
| `POST /oauth/revoke` | RFC 7009 |

The unprefixed paths are **gone**, not redirected: `POST /auth/login` is a `404`. See the
CHANGELOG for the migration.

## Errors

Application failures — from a handler, workflow, token verifier, authorization combinator,
Servant request parser, or rate limiter — use the [RFC 9457][rfc9457] Problem Details profile and
`Content-Type: application/problem+json`:

```json
{"type":"https://github.com/shinzui/shomei/blob/master/docs/user/problem-details.md#token_invalid","title":"Token is invalid","status":401,"code":"token_invalid","retryable":false}
```

| Member | Meaning |
|---|---|
| `type` | stable HTTPS identity; this is the primary problem kind and links to [the catalog](problem-details.md) |
| `title` | stable human text for the error kind |
| `status` | mirrors the HTTP status |
| `code` | short, stable Shōmei alias for `type` |
| `retryable` | whether retrying later can succeed without changing the request |
| `detail` | *optional*; explains this occurrence (a parse message, the offending role name) |
| `instance` | *optional* opaque occurrence URI; currently omitted |

A `401` carries `WWW-Authenticate` only when the response is an authentication challenge. A
`429` carries `Retry-After`; a `503` carries it only when the server knows an honest interval.
Clients must ignore unknown extension members.

The per-client-IP edge limiter guards every HTTP operation that proves or presents a credential:

- `POST /v1/auth/login`, `/signup`, `/refresh`, and `/mfa/complete`
- `POST /v1/auth/login/passkey/begin` and `/v1/auth/login/passkey/complete`
- `POST /v1/auth/password/change`
- `POST /v1/auth/verify-email/request` and `/v1/auth/verify-email/confirm`
- `POST /v1/auth/password-reset/request` and `/v1/auth/password-reset/confirm`
- `DELETE /v1/auth/totp`
- `POST /oauth/token`

Over-rate requests return `429` with `Retry-After: 60` before routing. The first twelve use the
Problem Details shape described above. `/oauth/token` normally speaks OAuth errors, but this edge
response is a Problem Details document because the limiter answers before the OAuth handler.

The OpenAPI document (`GET /openapi.json`, or `docs/api/openapi.json`) derives declared statuses,
media types, and headers from the exact served route types. Application MultiVerb routes share a
closed error tail (400, 401, 403, 404, 409, 422, 429, 500, and 503), so their Haskell client calls
return named result sums. A declared error is a normal result value, not a transport failure.

Authentication errors are deliberately **generic** — a wrong password, an unknown account, and a
locked account all return the same `401` with `code: "invalid_login"`, so the API never discloses
which emails are registered (see [security.md](security.md)).

Two protocol surfaces are exempt. Both health probes use servant-health's
`{"status","check","failingSince"}` report at 200 and 503. Everything under **`/oauth/*`**
answers with RFC 6749 §5.2's
`{"error":"invalid_client","error_description":"…"}` shape, served as `application/json`, because
that is what every stock OAuth2 client parses by field name. The boundary is exact and permanent:
the OAuth/OIDC routes (including `/.well-known/openid-configuration`) speak their protocol wire
format; health speaks its package-owned format; application routes speak the Problem Details
envelope. The OpenAPI document declares a separate `OAuthErrorResponse` schema for OAuth failures.

[rfc9457]: https://www.rfc-editor.org/rfc/rfc9457

The only ordinary JSON terminal routes are the in-process, single-status
`GET /.well-known/jwks.json` and `GET /openapi.json`. Application and OAuth/OIDC operations use
MultiVerb result sums because they own non-success outcomes; health uses servant-health's
package-owned MultiVerb sum. Shōmei intentionally does not use `MultiVerb1`.

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
403 {"type":"https://github.com/shinzui/shomei/blob/master/docs/user/problem-details.md#csrf_rejected","title":"Origin not allowed for cookie-authenticated request","status":403,"code":"csrf_rejected","retryable":false}
```

Configure the allow-list with `SHOMEI_CSRF_ALLOWED_ORIGINS` (comma-separated). Requests with
*neither* header fail closed. **Bearer-authenticated requests are never CSRF-gated**, in any
mode. The same gate applies to `POST /v1/auth/refresh` when the refresh token comes from its cookie.

## Account & session

### `POST /v1/auth/signup`
Body `{"loginId","email"?,"password","displayName"}`. The required principal is a free-form,
case-insensitive login identifier; `email` is optional. → `201 Created`
`{"user":{…},"token":{"accessToken","refreshToken","expiresIn"}}` where `user` carries `loginId`
and a nullable `email`. `409 login_id_taken` if the identifier exists (`409 email_taken` if a
supplied email collides); `400 weak_password` / `invalid_login_id` / `invalid_email` on
policy/format failures. In cookie transport this response also sets the
`shomei_session`/`shomei_refresh` cookies and omits body token values.

### `POST /v1/auth/login`
Body `{"loginId","password"}`. → `200` with a tagged response:
`{"status":"complete","user":{…},"token":{…}}`, or
`{"status":"mfa_required","ceremonyId":"…","options":{…},"methods":[…]}` when the account
has an enrolled second factor and `mfaConfig.requireSecondFactor` is enabled. `methods` is required
and names the factors that can complete the challenge: `passkey`, `totp`, or `recovery_code`.
Credential and lockout failures are the same `401 invalid_login`; the per-IP failure throttle is
`429 too_many_requests`; an enforced unverified email is `403 email_not_verified`.

### `POST /v1/auth/refresh`
Body `{"refreshToken"}` — **optional**: in cookie transport the token is read from the `shomei_refresh` cookie instead and a browser client posts `{}`. A body value takes precedence. A cookie-borne token is CSRF-gated (an allow-listed `Origin`/`Referer` is required, else `403 csrf_rejected`). → `200` `{"accessToken","refreshToken","expiresIn"}` (the old refresh token is rotated and invalidated). The new access token gets a new `iat`, but preserves the session's `auth_time`, the instant the last credential was proven; refresh therefore never satisfies a recent-authentication gate. → `401 token_invalid` for a refresh token an OAuth client minted; rotate it at `POST /oauth/token` as that client. Presenting a reused token revokes the whole token family and the session (`401 token_reuse`); so does losing a race, since two concurrent presentations of one token can never both rotate it. A token already revoked by logout, password recovery, or another session revocation instead answers `401 session_revoked` and does not report theft. Once the session reaches its absolute lifetime (`sessionTTL`, default 30 days from login) refreshing no longer works: `401 session_expired` — the client must log in again. → `403 email_not_verified` when `emailVerificationRequired` is enabled and the account's email is unverified.

### `POST /oauth/token`

The standard OAuth2 token endpoint (RFC 6749). **Unversioned**, form-encoded, and exempt from the
problem-details envelope — see [Errors](#errors). Any stock OAuth2 client can use it with no
Shōmei-specific code.

Request: `Content-Type: application/x-www-form-urlencoded`. The `grant_type` parameter selects the
flow; this deployment implements **`client_credentials`** (RFC 6749 §4.4). The client authenticates
as itself with either method from §2.3.1:

- `client_secret_basic` — form-encode `client_id` and `client_secret` separately, join them with
  `:`, then send `Authorization: Basic base64(encoded_client_id:encoded_client_secret)`. Preferred;
  if the header is present it is used, even when body parameters also appear.
- `client_secret_post` — `client_id` and `client_secret` as body parameters.

| Parameter | Required | Meaning |
|---|---|---|
| `grant_type` | yes | `client_credentials` |
| `scope` | no | Space-delimited. **Omit it** to be granted every scope the account is allowed. A present value must be a non-empty subset of `allowed_scopes`; `scope=` (empty) is `invalid_scope`. |
| `client_id`, `client_secret` | only for `client_secret_post` | |

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=client_credentials&scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

→ `200`, with `Cache-Control: no-store` and `Pragma: no-cache` (RFC 6749 §5.1 forbids caching a
token response):

```json
{"access_token":"eyJ...","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

`scope` is always present and names exactly what was granted. The token has **no refresh token**:
its session is refresh-less, so the credential cannot outlive its TTL (`machineTokenTtlSeconds`,
default 300). Its `sub` is the service account's backing user id, its `scopes` claim carries the
granted scopes, and it is signed by the same key and verifies against the same
`GET /.well-known/jwks.json` as any other Shōmei token. A normal login token still carries empty
scopes, so a route guarded by `requireScope (Scope "kawa:ingest")` accepts this token and rejects
a human's with `403`.

Errors are RFC 6749 §5.2 objects, never problem documents:

| `error` | HTTP | When |
|---|---|---|
| `invalid_client` | 401 | Unknown `client_id`, wrong secret, revoked account, inactive backing user, no credentials, or a malformed `Authorization` header. Carries `WWW-Authenticate: Basic realm="shomei"`. All of these are byte-identical: nothing discloses whether a `client_id` exists. |
| `invalid_scope` | 400 | The requested scope is empty, or exceeds `allowed_scopes`. |
| `invalid_grant` | 400 | An invalid, expired, replayed, or wrong-client code or refresh token, a PKCE mismatch (`authorization_code`/`refresh_token` grants), or a bad subject/actor token or refused impersonation (`token-exchange` grant). One indistinguishable answer for all of them. |
| `invalid_request` | 400 | A required parameter is missing or malformed. |
| `unsupported_grant_type` | 400 | A `grant_type` this deployment does not implement. |
| `server_error` | 500 | An unexpected condition, still in the OAuth shape. |

`grant_type=client_credentials` is documented here; the `authorization_code` and `refresh_token`
grants are part of the OIDC provider surface — see [oidc.md](oidc.md).

Every successful `client_credentials` issuance writes a `service_token_issued` audit event whose
`accountId` is the `client_id`. `/oauth/token` is rate-limited per client IP like every other
credential proof; the `429` is the Problem Details document from the edge, not an OAuth error. See
[machine-tokens.md](machine-tokens.md) for operating and security guidance.

Manage accounts with `shomei-admin service-accounts create|rotate-secret|revoke|list`. See
[machine-tokens.md](machine-tokens.md) for the full guide.

### Token exchange (RFC 8693)

`POST /oauth/token` also accepts `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, which
mints a **delegated token** (`sub` = the represented user, `act` = the acting party) in one of two
modes. A successful response is the usual token response plus the required
`issued_token_type` member, always `urn:ietf:params:oauth:token-type:access_token` — Shōmei's
exchange issues access tokens only (no refresh tokens, no ID tokens). Errors use the RFC 6749 §5.2
shape above (`invalid_grant` for a bad subject/actor token, `invalid_scope` for a narrowing
violation, `invalid_request` for a malformed request, `invalid_client` for failed client auth). A
`resource` parameter is rejected (`invalid_request`); an `audience` parameter is ignored.

**Service on-behalf-of.** A service account (the same accounts the `client_credentials` grant uses)
authenticates with its client credentials and presents a *user's* access token as the
`subject_token`; it receives a narrowed token carrying the user's `sub` and the service's identity
in `act`. The account must hold the dedicated `token-exchange:subject` scope in its `allowed_scopes`,
which is never itself copied into an issued token. This is the paved road for propagating user
identity across service hops. Full guide and narrowing rules:
[machine-tokens.md](machine-tokens.md#acting-on-behalf-of-a-user).

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$USER_ACCESS_TOKEN" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

**Impersonation.** An operator holding the `impersonate:user` scope exchanges a bare user id — sent
as the `subject_token` with the Shōmei-defined type
`subject_token_type=urn:shomei:params:oauth:token-type:user-id` — plus their own access token as the
`actor_token`, for a token whose `sub` is the target and `act` is the operator. The grant enforces
the scope gate, freshness gate, and `impersonation_started` audit event. Optional `reason` and
`ticket_id` parameters feed the audit trail (`reason` defaults to `token_exchange`). Revoke the
result through `POST /oauth/revoke`.

```bash
curl -s \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=user_01jz..." \
  -d 'subject_token_type=urn:shomei:params:oauth:token-type:user-id' \
  --data-urlencode "actor_token=$OPERATOR_ACCESS_TOKEN" \
  -d 'actor_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'reason=support ticket 4711' \
  http://localhost:8080/oauth/token
```

Chained exchanges are refused: a token already carrying `act` cannot be presented as a `subject_token`
or `actor_token`.

### OIDC provider endpoints

When `oidcEnabled` is set, Shōmei is a standards-consumable OpenID Connect provider:
`GET /.well-known/openid-configuration`, `GET /oauth/authorize`, the `authorization_code` and
`refresh_token` grants at `POST /oauth/token`, `GET /oauth/userinfo`, `POST /oauth/introspect`, and
`POST /oauth/revoke`. Stock middleware (Spring Security, ASP.NET Core, Envoy, oauth2-proxy)
auto-configures from the discovery URL alone. The full guide, including the headless authorize
contract and a worked oauth2-proxy configuration, is [oidc.md](oidc.md). Userinfo requires a
bearer token; missing or invalid credentials produce OAuth `invalid_token` JSON with an RFC 6750
`WWW-Authenticate: Bearer` challenge, never an application problem document. It always returns
`sub` and `scopes`, adds the email pair only under `email`, and adds `roles` only under `profile`.
Revocation changes state only for a session the calling OAuth client or service account owns;
`shomei:admin` service accounts may revoke any session, and every mismatch remains a `200` no-op.

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
Body `{"token"}`. → `200`. Marks the account verified (`email_verified_at`) and revokes its other outstanding verification links; the work completes inside the request. `400 verification_token_invalid` for an unknown/consumed/expired token; `429 too_many_requests` when the client-IP budget is exhausted.

### `POST /v1/auth/password-reset/request`
Body `{"email"}`. → `202` (byte-identical for known and unknown emails). Logs a reset link for a real account.

### `POST /v1/auth/password-reset/confirm`
Body `{"token","newPassword"}`. → `200`. Changes the password, revokes **all** of the user's sessions and refresh tokens, and revokes every other outstanding reset link. `400 password_reset_token_invalid` on a bad or superseded token; `429 too_many_requests` when the client-IP budget is exhausted.

### `POST /v1/auth/password/change` *(authenticated)*
Body `{"currentPassword","newPassword"}`. → `204`. Verifies the current password, changes it, and revokes the user's other sessions. `401 invalid_login` if the current password is wrong; `429 too_many_requests` when the client-IP budget is exhausted.

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
Completes a step-up after login returned `mfa_required`. Body carries `ceremonyId` and exactly one
tagged `proof`: `{"type":"passkey","assertion":…}`, `{"type":"totp","code":"123456"}`, or
`{"type":"recovery_code","code":"…"}`. Unknown tags, missing payloads, and extra proof fields
are decoding failures. → `200` `{"accessToken","refreshToken","expiresIn"}`;
`404 ceremony_not_found`; `401 mfa_failed` / `totp_code_invalid` / `recovery_code_invalid` on a
failed factor; `403 email_not_verified` when email verification is enforced.
`429 too_many_requests` when the client-IP budget is exhausted.

### `POST /v1/auth/login/passkey/begin`
Empty body (passwordless). → `200` `{"ceremonyId","options"}`. The browser feeds `options` to `navigator.credentials.get()`. `429 too_many_requests` when the client-IP budget is exhausted.

### `POST /v1/auth/login/passkey/complete`
Body `{"ceremonyId","assertion"}`. → `200` `{"accessToken","refreshToken","expiresIn"}` — the passkey is the strong factor, so this returns a token pair directly (never an MFA challenge). `404 ceremony_not_found`; `401 mfa_failed` on a failed assertion. → `403 email_not_verified` when `emailVerificationRequired` is enabled and the account's email is unverified; `429 too_many_requests` when the client-IP budget is exhausted. Sets the cookies in cookie transport.

## TOTP & recovery codes (MasterPlan 7, EP-7)

The TOTP second factor (RFC 6238) and single-use recovery codes. Enabled by `totpEnabled`; the
login `mfa_required` arm's `methods` list advertises `"totp"` / `"recovery_code"` when the account
has them, and `POST /v1/auth/mfa/complete` accepts a tagged `totp` or `recovery_code` proof. See
[mfa.md](mfa.md) for the full guide.

### `POST /v1/auth/totp/enroll` *(authenticated)*
Empty body. → `200` `{"secret","otpauthUri"}` — the Base32 secret and `otpauth://` URI, shown **once**. `403 totp_disabled` if TOTP is off; `409 totp_already_enrolled` if a confirmed credential exists (remove it first); `403 impersonation_action_blocked` under a delegated token.

### `POST /v1/auth/totp/verify` *(authenticated)*
Body `{"code"}`. Activates a pending enrollment with a first valid code. → `200`. `404 totp_enrollment_not_found` (no pending/unexpired enrollment); `401 totp_code_invalid`.

### `DELETE /v1/auth/totp` *(authenticated)*
Body carries **exactly one** of `code` (a current TOTP code) or `recoveryCode` — proof of possession. The access token's `auth_time` must also be within `impersonationConfig.actorFreshnessWindow`; refresh does not renew it. → `204`. `404 totp_enrollment_not_found`; `401 totp_code_invalid` / `401 recovery_code_invalid`; `403 reauthentication_required` when stale; `403 impersonation_action_blocked` under a delegated token; `429 too_many_requests` when the client-IP budget is exhausted.

### `POST /v1/auth/recovery-codes` *(authenticated)*
Empty body. Generates ten single-use codes, shown **once**, replacing any previous set. → `200` `{"codes":[…10…]}`. Requires recent credential proof: the token's `auth_time` must be within `impersonationConfig.actorFreshnessWindow`, and refreshing does not change it. Otherwise → `403 reauthentication_required`; `403 impersonation_action_blocked` under a delegated token.

### `GET /v1/auth/recovery-codes` *(authenticated)*
→ `200` `{"remaining":N}` — how many unused recovery codes remain.

## Impersonation / delegated tokens

A *delegated token* lets an authorized internal operator act **on behalf of** a customer while
keeping their own identity attached. The minted access token carries **two identities**: `sub`
is the customer being acted upon and `act` is the real operator (mirroring RFC 8693). The
delegated session is a brand-new, short-lived row with **no refresh token**, so it cannot be
silently renewed and expires at its TTL. Shōmei gates only its own credential-changing endpoints
against delegated tokens; who-may-impersonate-whom policy and business-action gating live in the
embedding service, which reads `act`/`sub` from the verified token. See
[security.md](security.md#impersonation--delegated-tokens).

Create delegated tokens with the [RFC 8693 token-exchange grant](#token-exchange-rfc-8693):

```bash
curl -s \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$TARGET_USER_ID" \
  -d 'subject_token_type=urn:shomei:params:oauth:token-type:user-id' \
  --data-urlencode "actor_token=$OPERATOR_ACCESS_TOKEN" \
  -d 'actor_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'reason=support ticket 4711' \
  http://localhost:8080/oauth/token
```

Revoke the delegated token or its session with `POST /oauth/revoke`.

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
→ `200` the public JWKS document (the `active` plus still-trusted `retired` signing keys). Downstream services fetch this to verify Shōmei's tokens locally. Every entry explicitly carries `kid` and `alg`; keys are EC (`"kty":"EC"`, `"alg":"ES256"`) or RSA (`"kty":"RSA"`, `"alg":"RS256"`) depending on the configured signing algorithm. Verifiers select by `kid`, so a mixed set during an algorithm rotation verifies correctly. A host service embedding Shōmei may also attach its own top-level claims to issued tokens (`AuthClaims.extraClaims`); these appear in the JWT payload beside the standard `sub`/`sid`/`scopes`/`roles` claims and are preserved on verification.

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

### `GET /health/live` (liveness)
→ `200 {"status":"ok","check":"all","failingSince":null}` while the in-process liveness check
passes. It is dependency-free and drives restart decisions.

### `GET /health/ready` (readiness)
→ the same healthy 200 body only when PostgreSQL is reachable and an active signing key exists.
Otherwise it returns `503 {"status":"failed","check":"postgres|signing-key","failingSince":"…"}`.
`failingSince` preserves the onset of the current failure run. Use readiness to gate traffic and
liveness to decide restarts. Bare `/health` and `/ready` do not exist.

### `GET /metrics`
→ `200` Prometheus text exposition (raw WAI, bypassing the typed API): `http_requests_total{method,status}`, `http_requests_in_flight`, the `http_request_duration_seconds` histogram, and the domain counters `shomei_logins_succeeded_total` / `shomei_logins_failed_total` / `shomei_tokens_issued_total`.

## Correlation ids

Every non-probe response carries an `X-Request-Id` header (echoed from the request if supplied,
else generated). The same id appears in the server's structured JSON log line. Health probes
bypass request logging and request-id decoration to avoid per-probe noise.
