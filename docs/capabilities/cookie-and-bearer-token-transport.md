---
title: "Cookie, bearer, or dual token transport with CSRF defenses"
type: Capability
description: "Choose per deployment whether tokens travel as Authorization bearer headers, as HttpOnly cookies with an Origin/Referer CSRF gate, or both."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-8
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-servant
interface:
  - Shomei.Servant.Cookie
  - Shomei.Servant.Auth
  - Shomei.Config
requires:
  - CAP-7
evidence:
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: All three transports over HTTP - cookies set and cleared, body tokens present or absent, a cookie rejected as a credential under bearer transport, the CSRF gate across Origin/Referer/absent/foreign, and a CSRF-gated cookie refresh.
  - kind: module
    resource: shomei-servant/src/Shomei/Servant/Cookie.hs
    proves: How the session and refresh cookies are built, scoped, and cleared.
  - kind: guide
    resource: docs/user/security.md
    proves: The cookie and CSRF threat model, and the SameSite policy choices.
---

# Cookie, bearer, or dual token transport with CSRF defenses

**Builds on:** [CAP-7 — embeddable Servant auth API](embeddable-servant-auth-api.md).

One configuration field decides how tokens reach the client:

```dhall
tokenTransport = BearerToken     -- API clients; tokens in the response body only
              -- HttpOnlyCookie  -- browsers; HttpOnly cookies, no body tokens
              -- BearerAndCookie -- both, for a mixed estate
```

Under cookie transport, login sets an `HttpOnly` session cookie and a refresh cookie scoped to
`Path=/v1/auth/refresh`, omits the tokens from the response body, and logout clears both. Because
cookies are sent ambiently, mutating requests are gated on `Origin`/`Referer`: a request from a
foreign origin is refused, and so is one with neither header. `SameSite` is configurable.

Under bearer transport the server sets no cookies at all, and a cookie presented by a client is
**not** accepted as a credential — so enabling cookies later is a deliberate change, not
something a client can opt into unilaterally.

## Limits

- The CSRF defense is `Origin`/`Referer` checking, not a synchronizer token. It relies on the
  browser sending one of those headers on cross-origin mutating requests; a client that strips
  both is refused rather than allowed.
- The refresh cookie's `Path` is a literal (`/v1/auth/refresh`). A deployment that reverse-proxies
  Shōmei under a different path prefix has to rewrite the cookie path itself.
- The transport setting gates **cookies only**. An `Authorization: Bearer` header is accepted
  under every transport, including `HttpOnlyCookie`, and takes precedence over a cookie when both
  are present. Selecting cookie transport hides tokens from browser JavaScript; it does not close
  the bearer path.
- The CSRF gate applies only to cookie-sourced credentials, and only to unsafe methods. A
  bearer-authenticated request is never origin-checked — correctly, since it is not ambiently
  attached, but it does mean the gate is not a blanket request filter.
