---
title: "Admin HTTP API"
type: Capability
description: "Administer a deployed Shomei over HTTP - list, suspend, reinstate, and soft-delete users, manage their sessions and roles, and trigger a password reset - gated on the admin role or the shomei:admin scope."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-18
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-servant
  - shomei-client
interface:
  - Shomei.Account.Admin.Api
  - Shomei.Session.Admin.Api
  - Shomei.Authorization.Api
requires:
  - CAP-9
  - CAP-10
evidence:
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: The role-or-scope gate (401 without a token, 403 with an ordinary one); suspend kills login and revokes sessions; a repeat suspend is 409; reinstate and soft delete; session revocation naming the acting admin; role PUT idempotent and DELETE of an unheld role 404; delegated tokens refused and self-targeting refused; keyset paging that is disjoint and complete.
  - kind: test
    resource: shomei-core/test/Shomei/Account/Admin/WorkflowSpec.hs
    proves: The status-transition rules and the self-target refusal at the workflow level.
  - kind: test
    resource: shomei-client/test/Main.hs
    proves: Every admin operation has a typed client wrapper that reaches its route.
  - kind: guide
    resource: docs/user/api.md
    proves: Each operation's request shape, status codes, and authorization rule.
---

# Admin HTTP API

**Builds on:** [CAP-9 — type-level authorization guards](type-level-authorization-guards.md), [CAP-10 — built-in RBAC: roles, permissions, and time-bound grants](built-in-rbac-roles-and-permissions.md).

Eleven operations under `/v1/admin`, so a deployed Shōmei is administrable without shell access
to the box: list and get users (keyset-paginated, `?status=` filtered), suspend, reinstate,
soft-delete, list and revoke sessions, revoke one session, trigger a password reset for a user by
id, and grant or revoke a role.

**The gate is the `admin` role OR the `shomei:admin` scope.** The role is for humans, granted from
the store; the scope is minted onto a service token, so a database-less support console can
administer too.

Two refusals are structural rather than configurable:

- A delegated (impersonation) token cannot perform an admin mutation —
  `403 impersonation_action_blocked`, itself audited. Otherwise impersonation would launder
  privilege.
- An administrator cannot suspend or delete their own account (`403 self_target_forbidden`), so
  one mistyped id cannot lock the last admin out. Revoking your own sessions is still allowed.

Transitions are strict: suspending an already-suspended user is `409 invalid_user_status`, not a
silent success, so two administrators handling one incident can tell which of them changed the
state. Every mutation is audited with the acting administrator.

## Limits

- There is **no admin UI**. This is an API; the console is yours to build (or use the
  [CLI](shomei-admin-operations-cli.md)).
- Delete is a **soft** delete: the row and its audit trail survive. There is no operation that
  erases a user, which matters if you need a hard-delete story for a data-subject request.
- Suspending or deleting revokes sessions immediately, so the user cannot refresh — but their
  outstanding *access* tokens ride out their TTL unless the deployment sets
  `sessionCheckMode = VerifyTokenAndSession`.
- The role operations here grant and revoke; **defining** roles and mapping them to permissions
  is CLI-only.
- `payload.actor` and `payload.revokedBy` are `null` for self-service actions and for events
  written before those fields existed, so an old audit row cannot be attributed.
