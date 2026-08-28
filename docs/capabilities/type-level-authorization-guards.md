---
title: "Type-level authorization guards"
type: Capability
description: "Guard a Servant route by writing a combinator in its type - Authenticated, RequireRole, RequireScope, or RequirePermission - with no in-handler check to forget."
generated:
  by: claude-opus-5/1
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-9
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-servant
interface:
  - Shomei.Servant.Auth
  - Shomei.Servant.Authz
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: RequireRole and RequireScope answer 401 without a token and 403 without the role or scope; RequirePermission does the same and re-wiring the role's permissions changes the outcome without touching the route.
  - kind: module
    resource: shomei-servant/src/Shomei/Servant/Authz.hs
    proves: The HasServer instances that make the combinators enforce rather than merely annotate.
  - kind: example
    resource: examples/embedded-with-en/src/EmbeddedEn/Authz.hs
    proves: A host reusing the same fail-closed outcome mapping (Allowed proceeds, Denied and Conditional are 403, an engine error is 503) as a term-level Handler guard for its own fine-grained checks; it is not a type-level combinator.
---

# Type-level authorization guards

**Builds on:** [CAP-4 — jWT access tokens with a published JWKS](jwt-access-tokens-and-jwks.md).

Four combinators, written in the route type:

```haskell
Authenticated                  :> "me"       :> Get '[JSON] UserResponse
RequireRole       "admin"      :> "admin" :> "users" :> Get '[JSON] [User]
RequireScope      "kawa:ingest":> "ingest"   :> Post '[JSON] ()
RequirePermission "projects:write" :> "projects" :> Put '[JSON] Project
```

Each authenticates the caller and refuses one that lacks the role, scope, or permission —
`401` with no token, `403` with the wrong one — before the handler runs. They **replace**
`Authenticated` on a route rather than accompanying it, and the guarded handler receives the
resolved `AuthUser`.

`RequirePermission` is the one to reach for in a host service. It checks a flat `resource:verb`
capability rather than a role name, so which roles imply it stays a central, re-wireable decision
([CAP-10](built-in-rbac-roles-and-permissions.md)) and no consumer redeploys when it changes.

## Limits

- These were **phantom types with no `HasServer` instance** before the fix recorded in the
  current changelog: a route carrying one compiled and enforced nothing. Any route type written
  against an older checkout needs re-reading, not trusting.
- The claims are a snapshot from mint time. Granting a role or a permission does not affect an
  outstanding access token; it takes effect at the next login or refresh. Revoke the user's
  sessions when it must bite now.
- Checks are exact string matches over the claim sets. There is no hierarchy, no wildcard, and no
  resource-instance awareness — `projects:write` is a global capability, not "may write *this*
  project". Per-instance decisions belong to a relationship-based authorization layer, not here.
- The combinators live in `shomei-servant`, so they are for Servant hosts. A non-Haskell
  downstream service reads the `roles`/`scopes`/`permissions` claims itself.
