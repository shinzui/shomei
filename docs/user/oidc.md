# OpenID Connect provider

Shōmei can act as an [OpenID Connect](https://openid.net/connect/) provider: it publishes a
discovery document, implements the authorization-code flow with PKCE, issues signed ID tokens, and
serves userinfo, introspection, and revocation. A relying party configured with only the issuer URL
— Spring Security, ASP.NET Core, Envoy's JWT filter, oauth2-proxy, or any conformant OIDC client
library — auto-configures itself and needs no Shōmei-specific code.

This is a deliberate **subset**. Implemented: discovery, authorization code + PKCE, refresh, ID
tokens, userinfo, introspection, revocation. Not implemented (and not planned): the implicit and
hybrid flows (deprecated by the OAuth 2.0 Security BCP), dynamic client registration, request
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
(that would recreate the dual-source problem [service accounts](service-tokens.md) are deprecating).

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

## The authorize contract (host-owned login)

`GET /oauth/authorize` authenticates the browser with the **same** credential machinery as every
other authenticated route — a Shōmei bearer token today, and the cookie transport once
`tokenTransport` includes cookies. Shōmei ships no login page and stores no "pending authorize"
state; the request parameters round-trip through the URL.

1. An **authenticated** request immediately `302`s to `redirect_uri` with `?code=…&state=…&iss=…`.
2. An **unauthenticated** request `302`s to your configured `oauthLoginUrl` with the complete
   original authorize URL in a `return_to` query parameter. **Your login page must preserve
   `return_to` across its own flow** and navigate back to it once the user is logged in; the
   authorize request then finds a session and issues the code. If no `oauthLoginUrl` is configured,
   an unauthenticated request is `401`.
3. An **unknown/revoked `client_id`, or a `redirect_uri` that is not registered**, is `400` **with
   no redirect** — redirecting an unvalidated URI would make the endpoint an open redirector. Every
   *other* error (bad `response_type`, missing PKCE for a public client, a disallowed scope) is an
   error redirect to the validated `redirect_uri` carrying `?error=…&error_description=…&state=…`.

How each consumer class integrates:

- **Server-side relying party** (oauth2-proxy, Spring): the browser navigates to `/oauth/authorize`
  and carries the session cookie once the cookie transport is enabled; until then the login-redirect
  path covers it.
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

## Refresh

An authorization-code session always gets a refresh token (the `offline_access` scope is accepted
and ignored). Refresh at `POST /oauth/token` with `grant_type=refresh_token`, authenticated as the
same client. **A refresh token is bound to the client that minted it**: another client cannot rotate
it, and a session created by any non-OIDC flow (password login, passkey, service account) cannot be
refreshed at `/oauth/token` at all — it is refreshed at the endpoint that created it. Rotation and
reuse detection are the standard Shōmei machinery: replaying a used refresh token revokes the whole
family and the session.

## Introspection and revocation

`POST /oauth/introspect` (RFC 7662) and `POST /oauth/revoke` (RFC 7009) are client-authenticated —
by a confidential OAuth client or a [service account](service-tokens.md), via `client_secret_basic`
or `client_secret_post`. A public client cannot use them.

Introspection is **session-aware**: a token is `active` only if it verifies *and* its session is
unrevoked and unexpired — regardless of `sessionCheckMode`. This is the point of RFC 7662: a
resource server sees a revocation that stateless JWT verification cannot. Anything invalid, expired,
or revoked returns `{"active": false}` at `200` (never an error, to prevent probing).

Revocation of a refresh token revokes its family and session; of an access token, its session and
that session's refresh tokens. **Caveat**: because access tokens are stateless JWTs, a deployment
verifying statelessly (`sessionCheckMode = VerifyTokenOnly`, the default) keeps accepting a revoked
access token until it expires; only `VerifyTokenAndSession` — and the introspection endpoint —
reject it immediately. Revocation always returns `200`, even for an unknown token.

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
oauth2-proxy where the authorize, token, and JWKS endpoints are and which algorithms and PKCE
methods this provider supports.

## ID tokens

An ID token is returned as `id_token` alongside the access token when the granted scopes include
`openid`. It is a JWS signed by the same active key (and `kid`) as access tokens, so it verifies
against `/.well-known/jwks.json`. It carries `iss`, `sub`, `aud` (the `client_id`), `exp`, `iat`,
`nonce` (echoed verbatim from the authorize request when one was sent), and `auth_time`. It carries
**no** `sid`, scopes, or roles, and its `aud` is the `client_id` — so presenting an ID token as a
bearer credential to a resource server is refused. It is a statement *to the client* that a user
authenticated, not an API credential.
