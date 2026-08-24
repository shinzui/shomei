---
title: "Built-in RBAC: roles, permissions, and time-bound grants"
type: Capability
description: "Define roles in a registry, map them to flat resource:verb permissions, grant them to users with an optional expiry, and have every minted token carry the resolved union."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-10
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
  - shomei-server
interface:
  - Shomei.Authorization.Role.Store
  - Shomei.Authorization.Role.Workflow
  - Shomei.Authorization.Claims.Store
  - Shomei.Session.Workflow
requires:
  - CAP-4
  - CAP-6
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/Authorization/Role/WorkflowSpec.hs
    proves: Granting an undefined role fails loudly rather than minting a role nothing checks.
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: The registry seeds admin, grants are idempotent, foreign keys reject undefined roles and unknown users, permissions union across roles, and an expiring grant drops out of the as-of filter.
  - kind: test
    resource: shomei-server/test/Admin/Main.hs
    proves: The CLI round-trips define/allow/show/grant/revoke, audits each grant, applies configured default roles at user creation, and refuses an undefined default role while writing nothing.
  - kind: guide
    resource: docs/user/security.md
    proves: The role model, token-size guidance, and where built-in RBAC stops being the right tool.
---

# Built-in RBAC: roles, permissions, and time-bound grants

**Builds on:** [CAP-4 — jWT access tokens with a published JWKS](jwt-access-tokens-and-jwks.md), [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md).

Roles have a source of truth: a registry (seeded with `admin`) and a grant table, both behind a
`RoleStore` port with PostgreSQL and in-memory interpreters. A role may imply flat `resource:verb`
permissions. Every token mint resolves the subject's roles to the **union of their permissions**
and puts both in the token.

```bash
shomei-admin roles define editor --description 'May edit projects'
shomei-admin roles allow  editor projects:write
shomei-admin roles grant  --user <user-id> --role editor --expires-in 8h
```

The indirection is the point: a downstream service checks `projects:write`, and which roles imply
it is re-wired centrally without redeploying any consumer.

Granting a role that is not in the registry **fails**, so a typo cannot mint a role nothing
checks. New users can be given `defaultRoles` from configuration, applied inside the signup
workflow before the first token is minted; the server refuses to start when a configured default
role is not defined.

`ClaimsEnricher` is the extension point for an embedding host: add roles, scopes, or custom
claims at mint time. The delta is merged, never substituted, and reserved claims (`sub`, `iss`,
`roles`, `scopes`, `permissions`, …) cannot be forged through it.

## Limits

- **Expiry is passive.** An expired grant simply stops appearing in tokens at the next mint. No
  event fires, no status flips, and an outstanding token keeps the permission until it expires.
  The sweeper deletes long-expired grant rows as hygiene, not as enforcement.
- Every role's permissions travel in every token. A subject with many roles makes for a large
  token; the security guide gives sizing guidance, but nothing enforces a bound.
- Permissions are flat strings with no hierarchy, wildcards, or resource instances. Fine-grained,
  per-object authorization is explicitly out of scope for this tier; a deployment that needs it
  composes Shōmei with a relationship-based authorization system, which is a claim of the
  consuming repository rather than of this one.
- Pre-`permissions` tokens verify with an empty permission set, so a mixed fleet degrades to
  "no permissions" rather than failing — safe, but silent.
