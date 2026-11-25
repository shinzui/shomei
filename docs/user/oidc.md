# OpenID Connect provider

Shōmei can act as an [OpenID Connect](https://openid.net/connect/) provider: it publishes a
discovery document, implements the authorization-code flow with PKCE, issues signed ID tokens, and
serves userinfo, introspection, and revocation. A relying party configured with only the issuer URL
— Spring Security, ASP.NET Core, Envoy's JWT filter, oauth2-proxy, or any conformant OIDC client
library — auto-configures itself and needs no Shōmei-specific code.

This is a deliberate **subset**. Implemented: discovery, authorization code + PKCE, refresh, ID
tokens, userinfo, introspection, revocation. Not implemented (and not planned): the implicit and
hybrid flows (discouraged by the OAuth 2.0 Security BCP), dynamic client registration, request
objects, PAR, session management / front- and back-channel logout, `prompt`/`max_age`/ACR handling,
and any consent or login UI. Shōmei is headless — **the host owns the login UI** — which is what the
authorize contract below is built around.

## Enabling it

OIDC is off by default. Turn it on and set the issuer to this deployment's public base URL:

```bash
SHOMEI_OIDC_ENABLED=true SHOMEI_ISSUER=https://auth.example.com shomei-server
```

or in the Dhall config:

```dhall
{ issuer = "https://auth.example.com"
, oidcEnabled = True
, oauthLoginUrl = Some "https://app.example.com/login"   -- see "The authorize contract"
, oauthAuthorizationCodeTtlSeconds = 60
, oauthIdTokenTtlSeconds = 900
, …
}
```

**The issuer is the base URL.** OIDC Core requires the discovery document to live at
`{issuer}/.well-known/openid-configuration` and ID tokens to carry `iss = issuer`, so every endpoint
URL is derived from `issuer`. There is no separate "public base URL" setting to keep in sync. If
`oidcEnabled` is set and `issuer` is not an absolute `http(s)` URL, **the server refuses to start**
— otherwise it would advertise a relative path like `shomei/oauth/token` that no client can fetch.

With `oidcEnabled = false` (the default) the discovery document and `/oauth/authorize` answer `404`,
so it is safe to deploy the code before flipping the flag.

Environment overrides: `SHOMEI_OIDC_ENABLED`, `SHOMEI_OAUTH_LOGIN_URL`, `SHOMEI_OAUTH_CODE_TTL`,
`SHOMEI_OAUTH_ID_TOKEN_TTL`.

## Registering clients

Clients are registered from the CLI — there is no dynamic registration and no config-file source
(that would recreate the dual-source problem [service accounts](machine-tokens.md) are deprecating).

```bash
# A confidential client (a server-side web app). Its secret is printed once.
shomei-admin oauth-clients create \
  --display-name grafana --type confidential \
  --redirect-uri https://grafana.example.com/login/generic_oauth \
  --scope openid --scope profile --scope email

# A public client (a browser SPA or a native/CLI app). No secret; PKCE is mandatory.
shomei-admin oauth-clients create \
  --display-name my-spa --type public \
  --redirect-uri https://app.example.com/callback \
  --scope openid

shomei-admin oauth-clients list
shomei-admin oauth-clients revoke <client_id>
```

`--redirect-uri` is repeatable and each must be an absolute `http(s)` URL with no fragment. Redirect
URIs are matched by **exact string equality** at authorize time — no prefix matching, no wildcards.
A confidential client's secret is shown once and only its SHA-256 digest is stored; there is no
rotate command (revoke and re-register). A public client is issued no secret at all.

The scopes `impersonate:user` (or the configured impersonation scope), `shomei:admin`, and
`token-exchange:subject` are principal-level privilege gates. They are refused when an OAuth client
is registered and again at authorize time. Grant those scopes only to service accounts, which hold
them as their own authority; see [Scopes are principal privilege](security.md#scopes-are-principal-privilege-three-are-reserved)
and [ADR-2](../adr/0002-reserved-privilege-scopes-are-service-account-authority.md).

## Trust model

Every active registered OAuth client is fully trusted with every user's identity. There is no
consent screen: once a user has an interactive session, authorize issues a code immediately for
any active client with a matching redirect URI and allowed scopes. Registering a client is the
operator's consent decision and should be treated with the same care as granting an administrator
access to the identity system. Register only controlled applications, use exact redirect URIs, and
revoke a client that is no longer trusted.

## The authorize contract (host-owned login)

`GET /oauth/authorize` authenticates the browser with the **same** credential machinery as every
other authenticated route — a Shōmei bearer token, or the `shomei_session` cookie when
`tokenTransport` is `cookie` or `both`. Shōmei ships no login page and stores no "pending authorize"
state; the request parameters round-trip through the URL.

1. An **authenticated** request immediately `302`s to `redirect_uri` with `?code=…&state=…&iss=…`.
2. An **unauthenticated** request `302`s to your configured `oauthLoginUrl` with the complete
   original authorize URL in a `return_to` query parameter. **Your login page must preserve
   `return_to` across its own flow** and navigate back to it once the user is logged in; the
   authorize request then finds a session and issues the code. If no `oauthLoginUrl` is configured,
   an unauthenticated request is `401`.
3. The credential must name a **live interactive session** established by signup, password or
   passkey login, MFA completion, or a previous authorization-code exchange. A
   `client_credentials` token, a delegated token, or any token carrying `act` is `401
   login_required` in the OAuth error shape with **no redirect**. A missing, revoked, or expired
   session is treated as unauthenticated in every `sessionCheckMode`; [ADR-1](../adr/0001-only-an-interactive-session-may-authorize-a-client.md)
   records this provenance boundary.
4. An **unknown/revoked `client_id`, or a `redirect_uri` that is not registered**, is `400` **with
   no redirect** — redirecting an unvalidated URI would make the endpoint an open redirector. Every
   *other* error (bad `response_type`, missing PKCE for a public client, a disallowed scope) is an
   error redirect to the validated `redirect_uri` carrying `?error=…&error_description=…&state=…`.

How each consumer class integrates:

- **Server-side relying party** (oauth2-proxy, Spring): the browser navigates to `/oauth/authorize`
  and carries the session cookie when the cookie transport is on; under bearer transport the
  login-redirect path covers it.
- **SPA (public client)** already holding a bearer token: call authorize with
  `fetch(url, { headers: { Authorization: "Bearer …" }, redirect: "manual" })` and apply the
  `Location` yourself.
- **Native / CLI client**: open the system browser to the authorize URL with a loopback
  `redirect_uri`; the host login page authenticates the user and navigates back.

## PKCE

PKCE is **S256 only**, and **mandatory for public clients** (with no secret, the code challenge is
their only binding between the authorize and token requests). For confidential clients it is
optional but verified whenever a challenge was supplied.

```bash
verifier=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=' | cut -c1-64)
challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
```

Send `code_challenge=$challenge&code_challenge_method=S256` at authorize, and the raw
`code_verifier=$verifier` at token. A `code_challenge` sent without an explicit `S256` method is
rejected — Shōmei never silently falls back to `plain`.

## Authorization-code replay

Authorization codes are single-use. Redeeming a still-live consumed code again returns
`invalid_grant` and revokes the session and refresh tokens created by its first successful
exchange. Discard the code after exchanging it; retrying a successful exchange can invalidate
the relying party's new session. Outstanding access tokens still follow the
[session-revocation rules](security.md#session-revocation).

## Refresh

An authorization-code session always gets a refresh token (the `offline_access` scope is accepted
and ignored). Refresh at `POST /oauth/token` with `grant_type=refresh_token`, authenticated as the
same client. **A refresh token is bound to the client that minted it**: another client cannot rotate
it, and it cannot be rotated at `POST /v1/auth/refresh` at all (`401 token_invalid`). A session
created by any non-OIDC flow (password login, passkey, service account) cannot be refreshed at
`/oauth/token` — it is refreshed at the endpoint that created it. Rotation and reuse detection are
the standard Shōmei machinery: replaying a used refresh token revokes the whole family and the
session. The refreshed access token and the response's `scope` field retain the session's original
grant.

## Introspection and revocation

`POST /oauth/introspect` (RFC 7662) and `POST /oauth/revoke` (RFC 7009) are client-authenticated —
by a confidential OAuth client or a [service account](machine-tokens.md), via `client_secret_basic`
or `client_secret_post`. A public client cannot use them.

Introspection is **session-aware**: a token is `active` only if it verifies *and* its session is
unrevoked and unexpired — regardless of `sessionCheckMode`. This is the point of RFC 7662: a
resource server sees a revocation that stateless JWT verification cannot. Anything invalid, expired,
or revoked returns `{"active": false}` at `200` (never an error, to prevent probing). Refresh
tokens are recognized with or without `token_type_hint=refresh_token`; the hint is only an
optimization.

Revocation of a refresh token revokes its family and session; of an access token, its session and
that session's refresh tokens, but only when the caller owns that session. An OAuth client owns
sessions minted under its `client_id`. A service account owns sessions in which its backing user is
the subject or actor; a service account holding `shomei:admin` may revoke any session. A caller that
does not own the presented token still receives the indistinguishable RFC-required `200`, with no
state change. **Caveat**: because access tokens are stateless JWTs, a deployment
verifying statelessly (`sessionCheckMode = VerifyTokenOnly`, the default) keeps accepting a revoked
access token until it expires; only `VerifyTokenAndSession` — and the introspection endpoint —
reject it immediately. Revocation always returns `200`, even for an unknown token.

### Session kind for resource servers

To learn how a bearer session started, send the presented token to the configured issuer's
HTTPS introspection endpoint. Authenticate with the resource server's own confidential client
or service account credential. A redacted request looks like this.

```http
POST /oauth/introspect HTTP/1.1
Host: auth.example.com
Authorization: Basic <redacted>
Content-Type: application/x-www-form-urlencoded

token=<redacted>
```

For a verified access token with a live session, the Shōmei extension `session_kind` comes
from the stored session identified by `sid`. Every authorized caller receives the same fields.
For a service acting on behalf of a user, the resource server receives a reply like this
(IDs abbreviated).

```json
{
  "active": true, "token_type": "Bearer",
  "iss": "https://auth.example.com", "aud": "ingest-api",
  "iat": 1795600000, "exp": 1795600300, "scope": "kawa:ingest",
  "session_kind": "delegated", "sid": "session_…",
  "sub": "user_represented…", "act": {"sub": "user_service…"}
}
```

| `session_kind` | How the session started | Identity |
| --- | --- | --- |
| `interactive` | Signup, password or passkey login, MFA completion, or authorization-code exchange | `sub` is the user. An interactive token can carry scopes. |
| `machine` | Client credentials | `sub` is the service account's backing user. There is no actor. |
| `delegated` | Service on-behalf-of exchange or operator impersonation | `sub` is the represented user and `act.sub` identifies the service or operator. Operator impersonation grants no scopes. |

Require HTTP 200 directly from the configured endpoint, `active: true` and `token_type: "Bearer"`.
Check that `iss` and `aud` exactly match the configured issuer and resource audience, that `exp` is an integer Unix
timestamp in the future, and that `sub` and `sid` are valid Shōmei user and session IDs.
Require a recognized kind and a valid user ID in `act.sub` for delegation. Interactive and
machine profiles expect `act` to be absent. Match every required scope as a whole,
case-sensitive word in the space-delimited `scope` string. Apply the route's allowed kinds.
For the example above, a machine-only ingest route denies the request. An ingest route
allowing machine and delegated sessions can accept the same evidence. The service still
checks permission for the specific resource.

A missing, revoked or expired session, or an invalid access token, yields
`{"active":false}`. A live opaque refresh token yields `{"active":true,"token_type":"refresh_token"}`.
Both deny access. A timeout, TLS failure, non-200 response (including caller-authentication
failure), or malformed reply also denies access. Report a failed lookup as a dependency or
configuration error so an operator can distinguish it from an inactive token.

Release `v0.3.0.1` omits `session_kind`. Support is in the unreleased provider.
Upgrade the issuer before enabling routes that require the field. Existing live access
tokens work immediately. During a mixed-version rollout or rollback, deny the operation
when the reply omits the required evidence.

### Hanmoto member and agent credentials

For Hanmoto's person path, require an interactive session and resolve the verified `sub`
to a member. For its direct agent path, require a machine or service on-behalf-of credential with the configured scope and a
binding to a provisioned agent. Keep `sid` for session correlation and retain both subject
and actor on delegated operations. Hanmoto checks membership, publication permissions and
standalone ownership through its configured En provisioning and authorization policy.
See the Hanmoto contract in `mori://shinzui/hanmoto/plans/4-authorize-management-commands-and-ship-the-publishing-cli`.

In a Kikan deployment, validate the issuer before passing a Shōmei user ID to Meibo's
`GET /v1/principals/by-credential/{sub}`. For a machine session send `sub`. For scoped
service delegation send `act.sub`, the service account's backing user ID. Require one linked, active agent and
usable directory ownership evidence. Refuse an absent, ambiguous or unusable mapping.
A shared runtime credential identifies only the runtime, so per-agent attribution requires
a distinct verified binding. Accountable ownership comes from the directory.
See `mori://shinzui/kikan/okf/use-cases/concepts/UC-42` and
`mori://shinzui/meibo/okf/improvement-requests/concepts/IR-3`.

## Userinfo

`GET /oauth/userinfo` always returns `sub` and the Shōmei `scopes` extension describing the
presented token. It returns `email` and `email_verified` only when the token has the `email` scope,
and the Shōmei `roles` extension only when it has `profile`. A missing bearer credential receives
`WWW-Authenticate: Bearer realm="shomei"`; an invalid credential additionally carries
`error="invalid_token"`.

## Worked example: oauth2-proxy

Point oauth2-proxy at the issuer and give it a confidential client's credentials. It reads
everything else from the discovery document.

```bash
shomei-admin oauth-clients create --display-name oauth2-proxy --type confidential \
  --redirect-uri https://proxy.example.com/oauth2/callback --scope openid --scope email
# -> client_id: oauthclient_…   client_secret: … (store it now)
```

```
--provider=oidc
--oidc-issuer-url=https://auth.example.com
--client-id=oauthclient_…
--client-secret=…
--redirect-url=https://proxy.example.com/oauth2/callback
--email-domain=*
```

That is the whole integration: no Shōmei-specific code, because the discovery document told
oauth2-proxy where the authorize, token, and JWKS endpoints are and which algorithms, PKCE methods,
and grant types this provider supports. The advertised grants include authorization code, refresh,
client credentials, and RFC 8693 token exchange.

## ID tokens

An ID token is returned as `id_token` alongside the access token when the granted scopes include
`openid`. It is a JWS signed by the same active key (and `kid`) as access tokens, so it verifies
against `/.well-known/jwks.json`. It carries `iss`, `sub`, `aud` (the `client_id`), `exp`, `iat`,
`nonce` (echoed verbatim from the authorize request when one was sent), and `auth_time`. It carries
**no** `sid`, scopes, or roles, and its `aud` is the `client_id` — so presenting an ID token as a
bearer credential to a resource server is refused. It is a statement *to the client* that a user
authenticated, not an API credential.

## Error and challenge contract

OAuth errors contain `error` and `error_description`, including failures before handlers run.
Interactive authorization's `401 login_required` carries no `WWW-Authenticate` challenge.
Client-authenticated token, introspection and revocation failures retain `401 invalid_client`
and `Basic realm="shomei"`, including required absent or body-supplied credentials. UserInfo
uses `Bearer realm="shomei"` for missing credentials and adds `error="invalid_token"` for invalid
credentials. Supplying Basic on an unrelated grant failure does not add a challenge.

Machine and delegated session quota exhaustion at `POST /oauth/token` returns
503 `temporarily_unavailable` without `Retry-After` or an authentication challenge. Revoke an
unused session or wait for expiry; there is no fixed recovery delay. Impersonation refusals
return generic 400 `invalid_grant`. See [served OAuth mappings](problem-details.md#served-oauth-errors)
for the authoritative quota and impersonation error contract, distinct from throttling below.

OAuth errors have JSON media type, `Cache-Control: no-store` and `Pragma: no-cache`.
Parsing and duplicate-Authorization errors return safe 400 `invalid_request`; unknown namespace
paths return 404 `invalid_request`; method, Accept and Content-Type failures preserve 405, 406
and 415 with `invalid_request`. Even an unacceptable Accept header receives a JSON error.
Semantic headers such as `Allow` are preserved when supplied by the router.

Oversized bodies return **413 `invalid_request`**. Throttling returns **429
`temporarily_unavailable`** with `Retry-After: 60`. These are Shōmei operational extensions
using the OAuth envelope; RFC 6749 section 5.2 does not prescribe these HTTP status/code pairs.
Both have the cache headers above and no authentication challenge. Limits and eligibility are
unchanged. See [architecture](architecture.md) for mount configuration and [the live contract
suite](../../integration-tests/oauth/README.md) for validation.

This contract covers application-controlled HTTP responses. Malformed HTTP rejected by Warp
before WAI, socket admission failures, disconnected clients and reverse-proxy-generated responses
are outside it.
