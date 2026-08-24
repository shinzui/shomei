---
title: "Sessions with refresh-token rotation and reuse detection"
type: Capability
description: "Long-lived sessions backed by single-use refresh tokens that rotate on every use, where replaying a spent token revokes the whole family and its session."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
interface:
  - Shomei.Session.Domain
  - Shomei.Session.RefreshToken.Domain
  - Shomei.Session.Workflow
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: Refresh rotation marks the parent used and inserts a child, reuse revokes the family and the session, and mark-used is a genuine compare-and-swap.
  - kind: test
    resource: shomei-core/test/Shomei/Session/Authentication/ConcurrencySpec.hs
    proves: Concurrent refreshes of one token resolve to exactly one winner.
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: Over HTTP — refresh rotates, logout is idempotent, and sessionCheckMode=VerifyTokenAndSession refuses an access token whose session was revoked.
  - kind: guide
    resource: docs/user/security.md
    proves: The revocation model, what a revocation reaches immediately, and what rides out an access-token TTL.
---

# Sessions with refresh-token rotation and reuse detection

**Builds on:** [CAP-1 — transport-agnostic authentication core](transport-agnostic-auth-core.md).

Logging in creates a **session** row and a **refresh token**. Every refresh marks the presented
token used and issues a child in the same family, in one transaction. Presenting a token that was
already spent is treated as theft: the entire family and the session behind it are revoked, so a
stolen refresh token buys at most one use before it locks both parties out and leaves an audit
trail.

Refresh, unlike access-token verification, has always been stateful — it enforces session status
and expiry on every call. Access tokens are stateless by default: revoking a session stops
*refresh* immediately, while an outstanding access token rides out its TTL (15 minutes by
default). Deployments that cannot accept that window set:

```dhall
sessionCheckMode = VerifyTokenAndSession
```

which re-reads the session on every authenticated request and answers `401 session_revoked` or
`401 session_expired`.

Sessions carry a status and a `revokedAt`, and both are visible on `GET /v1/auth/session` and in
the admin session listing, so a live session is distinguishable from a revoked one.

## Limits

- `VerifyTokenAndSession` costs **one session `SELECT` per authenticated request**. It also makes
  HTTP logout non-idempotent: a second `POST /v1/auth/logout` with the same access token is
  refused `401 session_revoked` by the auth handler. Under the default `VerifyTokenOnly`, logout
  is idempotent.
- Reuse detection depends on the compare-and-swap `markUsed`, which is a PostgreSQL guarantee
  ([CAP-6](postgresql-persistence-and-migrations.md)). The in-memory interpreter does not model
  concurrent writers the same way.
- Delegated (impersonation) sessions deliberately have **no** refresh token — see
  [CAP-15](token-exchange-delegation.md).
- This setting was documented before it worked: until the fix recorded in the current changelog,
  `VerifyTokenAndSession` had no production caller and changed no behavior on guarded routes. It
  is enforced now; a deployment that set it before that fix was not getting it.
