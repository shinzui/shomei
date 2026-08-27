---
type: Review
title: shomei-servant combinators, auth handler, CSRF, OAuth endpoints, and admin API
description: >-
  The combinators enforce, the one HTTP verifier honours sessionCheckMode, the CSRF origin
  check and cookie attributes match the documentation, and no error path leaks internals,
  but /oauth/authorize authenticates with a helper that accepts delegated and machine tokens,
  OAuth refresh tokens rotate unauthenticated at the bespoke endpoint, /oauth/revoke accepts
  any client's tokens, userinfo ignores scopes, and per-IP keys are the TCP peer — so changes
  are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-7
subject: mori://shinzui/shomei/packages/shomei-servant
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - correctness
  - performance
  - design
  - test-coverage
  - documentation
context: >-
  One reader agent read every module under src/ (the Servant/* infrastructure and each
  concept's Api, Dto, Handler, and Result modules), the OpenAPI executable and its test, and
  the named scenarios in test/Main.hs covering cookie and bearer transports, CSRF, session
  checks, the error envelope, userinfo/introspect/revoke, OAuth refresh binding, and the
  authorize no-redirect rule (about a third of the suite's 3,000 lines); it read servant-server
  0.20.3 (Delayed.hs stage order, header lookup, ReqBody) and warp 3.4.15
  (defaultOnExceptionResponse) in source. The review of record re-read OAuth/Handler.hs and
  Servant/Auth.hs around resolveAuthUser before grading the top finding. Both shomei-servant
  suites passed at the commit.
---

# shomei-servant combinators, auth handler, CSRF, OAuth endpoints, and admin API

## Verdict

Changes requested. The two fixes the changelog advertises are real and complete: every
authenticated route resolves through the one context `AuthHandler`, which verifies via
`Seam.verifyRequestToken` → `Shomei.Session.Authentication.Workflow.verifyToken`, so
`VerifyTokenAndSession` costs one session read per request and answers `401 session_revoked` on
`Authenticated`, `RequireRole`, `RequireScope`, and `RequirePermission` routes alike (tested); and
`Authenticated`, `OAuthAuthenticated`, and the four `Require*` combinators all carry `HasServer`
instances built on `addAuthCheck … delayedFailFatal`, with 401 before 403 and `RequireAdmin` =
role `admin` or scope `shomei:admin`. The CSRF gate is exactly as documented — `Origin` exact
match, `Referer` only when `Origin` is absent, the allowed origin must end at `/` or the string's
end, neither header is `403 csrf_rejected`, all methods but GET/HEAD/OPTIONS, and it covers every
`Authenticated`/`Require*` route plus cookie-sourced `/v1/auth/refresh`. Cookies are `HttpOnly`,
`Secure`, `SameSite` with the refresh cookie scoped to its route, logout clears both, and
cookie-only mode suppresses body tokens. Nothing internal reaches a client: hasql and
`InternalAuthError` render without detail, OAuth infrastructure failures are `server_error`
or `temporarily_unavailable`, and `SessionNotFound` is indistinguishable from a forged token.

## Findings

**1. Critical (shared with REV-2) — `GET /oauth/authorize` authenticates with `resolveAuthUser`,
which returns an `AuthUser` for any verifying token.** `OAuth/Handler.hs:167-173` passes
`user.authClaims` to `authorize` with no check of `actor`, and neither `authUserFromClaims` nor
`resolveAuthUser` (`Servant/Auth.hs:164-173, 246-256`) distinguishes a delegated or machine token
from a login token. The core lacks the guard too; the handler is the second place it should be
refused (`401 login_required` for a token with `act`, and for a machine session once the core can
name one). There is no `denyUnderDelegation` on this route.

**2. Medium — OAuth-issued refresh tokens rotate at `POST /v1/auth/refresh` with no client
authentication** (`Session/Handler.hs:89-101`; the core `refresh` never reads
`session.oauthClientId`). The test `scenarioOAuthRefreshRejectsUnboundSession` proves only that a
password session cannot refresh at `/oauth/token` and even asserts that "the bespoke endpoint
still rotates it". `oidc.md:123-125` promises the opposite. Remedy: refuse tokens whose session
carries `oauthClientId` at the bespoke endpoint; add the inverse test.

**3. Medium — every per-IP control is keyed by the TCP peer.** `loginH` feeds
`ClientIp (clientIpText peer)` from `RemoteHost` (`Session/Handler.hs:69-77, 134-138`); the
token-exchange audit does the same; nothing in this package or shomei-server reads
`Forwarded`/`X-Forwarded-For`. Behind the TLS terminator a production deployment needs, twenty
wrong passwords from anyone throttle every user's login for the window. The IP is also rendered
by `show host` on a `HostAddress`, i.e. a decimal `Word32` for IPv4 — `16777343` rather than
`127.0.0.1` in login attempts and audit payloads (plausible; the `network` package was not read).

**4. Low — `POST /oauth/revoke` revokes whatever token is presented once the caller
client-authenticates** (`OAuth/Handler.hs:563-589`), with no check that the token was issued to
that client (RFC 7009 §2.1). A low-privilege service account that sees users' access tokens as a
resource server can revoke every session it sees.

**5. Low — the "recent authentication" gate is satisfied by any refresh.** `requireFreshAuth`
compares `now` to `authClaims.issuedAt` (`Mfa/Handler.hs:80-85`), which `/v1/auth/refresh` renews
without a credential; there is no `auth_time` claim. `POST /v1/auth/recovery-codes` after a refresh
regenerates the set with no password or MFA prompt. `problem-details.md` says "Authenticate again".

**6. Low — `GET /oauth/userinfo` returns `email`, `email_verified`, `roles`, and `scopes`
regardless of granted scopes** (`OAuth/Handler.hs:494-504`; OIDC Core §5.4 ties `email` to the
`email` scope).

**7. Low — invalid UTF-8 in `Authorization`, `Cookie`, `Origin`, or `Referer` escapes the RFC 9457
envelope.** `Text.decodeUtf8` at `Servant/Auth.hs:218, 278` throws inside the auth handler and
warp answers its plain-text `500 Something went wrong` (no `setOnExceptionResponse` is installed).
Remedy: `decodeUtf8Lenient` or `decodeUtf8'` → `401`; a problem-shaped exception response.

**8. Low — no length caps on inbound text.** `loginId`, `email`, `displayName`, passkey `label`,
and role captures are unbounded at the DTO and constructor level (`Account/Handler.hs:71-88`;
`LoginId/Domain.hs:35-40`; `Email/Domain.hs:26-34`); only the server's 1 MiB `Content-Length` cap
applies, chunked bodies bypass it, and an embedding host has none. Password max 256 is enforced on
signup, change, and reset but login hashes whatever it receives.

**9. Low — cookie names carry no `__Host-`/`__Secure-` prefix** (`Cookie.hs:66-70`); a
sibling-subdomain page can set a `Domain=` cookie of the same name that browsers may present
first (`Auth.hs:236-239` takes the first match). Plausible, browser-ordering dependent.

**10. Low — no boot-time warning when cookie transport is on with the default
`http://localhost:8080` allow-list**, and origin matching is case-sensitive with no
normalization, so a configured trailing slash or uppercase host fails closed for every browser
user (`Auth.hs:284`).

**11. Low — `POST /v1/auth/login/passkey/begin` is unauthenticated, unthrottled, and writes a
pending-ceremony row per call**; the `RateLimited` marker on routes is a documented no-op
(`PreHandler.hs:36-44`).

**12. Low — `refresh_token` grant responds with `"scope": ""`** (`OAuth/Handler.hs:358-360`),
which RFC 6749 §5.1 makes neither the omitted nor the real value; the module comment in
`Servant/OAuth.hs:218-219` claims the field "tells the client exactly what it was granted".

**13. Info — interop and shape.** `Bearer` scheme match is case-sensitive single-space
(`Auth.hs:233`); `client_secret_basic` credentials are not form-urldecoded (harmless for
Shōmei-issued base64url secrets); `/oauth/authorize` issues a code to any registered, active client
with no consent step, so every registered client is fully trusted with every user's identity —
true by design, undocumented; `grant_types_supported` omits token-exchange; introspection
recognizes a refresh token only with the hint; `OAuthAuthenticated` sends `error="invalid_token"`
even when no credential was presented; captures are parsed before authentication, so a malformed
admin id answers `400` without a token.

**14. Info — performance.** `GET /openapi.json` JSON-encodes a ~7.6k-line `Value` on every
unauthenticated request (`OpenApi.hs:516-517` caches the `Value`, not the bytes). Everything else
on the hot path is fine: `VerifyTokenOnly` performs no query, the key set is an `IORef` read, the
JWKS document is precomputed, and the admin user list is one query.

**15. Info — documentation.** `security.md:668-673` and `api.md:478, 485` say the audit route is
`RequireRole "admin"`; it is `RequireAdmin`. `api.md:490-492` "no production flow yields an admin
token yet" is stale. The changelog's EP-4 entry names a `POST /v1/auth/service-token` route that
does not exist. `api.md:98` documents the refresh cookie path without the mount-prefix caveat
that only `Cookie.hs:72-79` carries. `api.md:385-388`'s delegation-blocked list omits the TOTP
and recovery-code routes (which are blocked) and `totp/verify` is not blocked at all (benign).

**16. Info — test coverage gaps.** `Origin: null`; a disallowed `Origin` with an allowed
`Referer`; HEAD/OPTIONS exemption; an OAuth session's token at `/v1/auth/refresh`; cross-client
revoke; lowercase `bearer`; non-UTF-8 headers; chunked bodies; `code_challenge_method=plain` at
the HTTP layer; userinfo scope gating; the freshness gate after a refresh.

## Verified holds

- `sessionCheckMode`: `Seam.hs:120-123`; `Authentication/Workflow.hs:450-468`; `Auth.hs:191`;
  `Authz.hs:159-162`; tests `test/Main.hs:1293-1335, 1972`.
- Combinators: `Auth.hs:96-139`; `Authz.hs:164-241`; 401 before 403; `RequireAdmin` `:235-241`;
  OpenAPI contributions `OpenApi.hs:379-404`.
- Servant stage order captures → method → auth → … → body (`Delayed.hs:250-265`): an
  unauthenticated request never has its body parsed.
- Transport gate: bearer mode ignores cookies (`Auth.hs:230`; test 2532-2549); cookie modes accept
  bearer first, documented; bearer plus cookie → bearer wins → no CSRF gate (test 2489-2492).
- CSRF: `Auth.hs:261-262, 283-292`; tests 2468-2484, 2508-2530; `/oauth/*` mutations never read
  cookies (`OAuth/Api.hs:19-27`).
- Cookies: `Cookie.hs:82-115`; path matches the served route; logout clears (`:98-105`; test
  2451-2461); body tokens suppressed (`Session/Dto.hs:106-116`); `mfa_required` sets no cookies.
- 401 vocabulary and `WWW-Authenticate: Bearer` (`Auth.hs:202-206`; `Error.hs:280-314`).
- Envelope: `Error.hs:591-592`; `OAuth/Handler.hs:76-79`; combinator 401/403 use it
  (`Authz.hs:118-121`; tests 788-841).
- OAuth/OIDC: client and `redirect_uri` validated by exact equality before any redirect
  (`OAuth/Handler.hs:144-151`; test 1809-1839); `state` echoed on both branches; S256 only;
  `Cache-Control: no-store` on redirects and token responses plus `Pragma: no-cache`; public
  clients only for `authorization_code`/`refresh_token` with no `Authorization` header;
  introspection and revocation require a confidential client or active service account with a
  constant-time compare; introspection consults the session store regardless of mode and answers
  `{"active": false}` at 200 for every failure; userinfo is bearer-only.
- Admin: `RequireAdmin` on every route; every mutation `denyUnderDelegation` (audited);
  self-target refusal on suspend and delete; limits clamped in the store; no credential material
  in any DTO; the TOTP secret appears only in the enroll response.
- Passkey/MFA: passwordless begin takes no username; `mfa_required` reveals methods only after a
  correct password; ceremonies consumed on every outcome; credential endpoints deny delegated
  tokens.
- OpenAPI served from a CAF; `docs/api/openapi.json` contains no secrets.

## Not examined

The remaining ~2,000 lines of `test/Main.hs` (admin lifecycle and pagination, token exchange,
TOTP, code-exchange scenarios); `test-openapi/Main.hs` beyond its first 120 lines;
`docs/api/openapi.json` (grepped); the `cookie` 0.5.1 parser, text 2.1.4 `decodeUtf8`
strictness, and http-api-data 0.7 header parsing (not in the mori corpus; the decode-throw is
plausible, the 500 shape confirmed).
