---
title: "Embeddable Servant auth API"
type: Capability
description: "Mount Shomei's entire authentication route tree inside your own Servant application, sharing one signing key, one verifier, and one effect stack with your own routes."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-7
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-servant
interface:
  - Shomei.Servant.Api
  - Shomei.Servant.Server
  - Shomei.Servant.Seam
  - Shomei.Servant.Auth
requires:
  - CAP-1
  - CAP-4
evidence:
  - kind: example
    resource: examples/embedded-servant-app/src/Embedded/App.hs
    proves: A host application mounting ShomeiRoutes beside its own /projects route, reusing shomei-server's Env and auth Context.
  - kind: test
    resource: examples/embedded-servant-app/test/Main.hs
    proves: A token minted by the mounted /v1/auth/login is accepted by the host's own guarded route; without one it is 401.
  - kind: module
    resource: shomei-servant/src/Shomei/Servant/Seam.hs
    proves: The single seam between the effect stack and Servant Handler, and why HTTP verification is derived from it rather than passed in.
  - kind: guide
    resource: docs/user/architecture.md
    proves: The standalone-versus-embedded model and the layer each package occupies.
---

# Embeddable Servant auth API

**Builds on:** [CAP-1 — transport-agnostic authentication core](transport-agnostic-auth-core.md), [CAP-4 — jWT access tokens with a published JWKS](jwt-access-tokens-and-jwks.md).

`ShomeiRoutes` is a `NamedRoutes` record — the whole API, versioned application routes under
`/v1` plus the unversioned `/oauth/*`, `/.well-known/*`, `/health/*`, and `/openapi.json`. A host
mounts it beside its own routes and guards those routes with the same combinators, so one token
works across both.

```haskell
type AppAPI =
  NamedRoutes ShomeiRoutes
    :<|> Authenticated :> "projects" :> Get '[JSON] [Project]

app env liveness readiness =
  serveWithContext (Proxy @AppAPI) (authContext senv)
    (shomeiRoutes senv liveness readiness :<|> projectsHandler)
  where senv = seamEnv env
```

The load-bearing piece is `Shomei.Servant.Seam.Env`: it carries the runner for the canonical port
stack, the config, and the precomputed JWKS document. HTTP token verification is **derived** from
that environment (`verifyRequestToken`) rather than supplied by the host, which is what stops an
embedding host from accidentally wiring the auth handler to a session-blind verifier and silently
losing `sessionCheckMode = VerifyTokenAndSession`.

## Limits

- The `Env`/`seamEnv`/`authContext` assembly a host reuses lives in **`shomei-server`**, not in
  `shomei-servant`. Embedding in practice means depending on the server package too — the split
  is not as clean as the package names suggest.
- Mounting is all-or-nothing at the record level. There is no supported way to mount only some of
  the route families; a host that wants a subset serves the record and blocks paths upstream.
- `ShomeiRoutes` carries its own prefixes (`/v1`, `/oauth`, `/.well-known`, `/health`). Mounting
  it under an extra prefix moves the protocol endpoints off the conventional locations that OAuth
  and OIDC tooling looks for them at.
- The host must supply its own liveness and readiness `ProbeCheck`s.
