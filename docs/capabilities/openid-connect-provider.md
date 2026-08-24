---
title: "OpenID Connect provider"
type: Capability
description: "Run Shomei as a standards-consumable OIDC provider: discovery, the authorization-code flow with mandatory S256 PKCE for public clients, ID tokens, userinfo, introspection, and revocation."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-14
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
  - shomei-servant
interface:
  - Shomei.OAuth.Authorize.Workflow
  - Shomei.OAuth.TokenGrant.Workflow
  - Shomei.OAuth.Client.Store
  - Shomei.Servant.Oidc
requires:
  - CAP-4
  - CAP-6
evidence:
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: Discovery derived from the issuer (404 when disabled); an unknown client or unregistered redirect_uri is 400 and never redirects; authorization_code + PKCE + ID token; replay, wrong verifier, and a stolen code collapse to one invalid_grant; refresh bound to the minting client; userinfo, introspection, and the revoke-then-introspect flip.
  - kind: test
    resource: shomei-server/test/Shomei/Server/E2ESpec.hs
    proves: The whole flow against the live server, verifying the id_token against the published JWKS.
  - kind: test
    resource: shomei-core/test/Shomei/OAuthCodeStoreSpec.hs
    proves: An authorization code is consumed exactly once, and two racing consumers produce one winner.
  - kind: guide
    resource: docs/user/oidc.md
    proves: Enabling it, registering clients, the host-owned authorize contract, and a worked oauth2-proxy configuration.
---

# OpenID Connect provider

**Builds on:** [CAP-4 — jWT access tokens with a published JWKS](jwt-access-tokens-and-jwks.md), [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md).

With `oidcEnabled = True` and `issuer` set to the deployment's public base URL, Shōmei serves
`/.well-known/openid-configuration` and the authorization-code flow. Every endpoint URL in the
discovery document is derived from `issuer`, and the server **refuses to start** if `oidcEnabled`
is set without an absolute `http(s)` issuer.

Clients are registered from the CLI:

```bash
shomei-admin oauth-clients create --display-name grafana --type confidential \
  --redirect-uri https://grafana.example.com/login/generic_oauth --scope openid
```

PKCE is **S256 only** and **mandatory for public clients**; a `code_challenge` with no explicit
`S256` method is rejected rather than falling back to `plain`. Authorization codes are single-use
and short-lived, and replay, a wrong verifier, and a stolen code are all one `invalid_grant` — a
client cannot distinguish them.

Introspection (`POST /oauth/introspect`) is **session-aware**: a token is `active` only if it
verifies *and* its session is live, regardless of `sessionCheckMode`. That is what lets a resource
server see a revocation stateless JWT verification cannot.

## Limits

- **Shōmei ships no login page.** `GET /oauth/authorize` authenticates with the same credential
  machinery as any other route and, when unauthenticated, `302`s to your configured
  `oauthLoginUrl` with the original authorize URL in `return_to`. Your login page must preserve
  and return to it. With no `oauthLoginUrl` configured, an unauthenticated authorize is `401`.
- Only the authorization-code grant is offered. There is no implicit flow, no hybrid flow, no
  device-code flow, and **no dynamic client registration** — clients are CLI-registered.
- `redirect_uri` matching is **exact string equality**. No wildcards, no path-prefix matching.
- A refresh token is bound to the client that minted it, and a session created by any non-OIDC
  flow cannot be refreshed at `/oauth/token` at all.
- A revoked *access* token keeps being accepted by stateless verifiers until it expires. Only
  `sessionCheckMode = VerifyTokenAndSession` ([CAP-3](session-refresh-rotation.md)) or the
  introspection endpoint reject it immediately.
- `offline_access` is accepted and ignored — an authorization-code session always gets a refresh
  token.
