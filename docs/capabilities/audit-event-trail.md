---
title: "Audit event trail"
type: Capability
description: "Every security-relevant action writes a typed, queryable audit event - who did it, to whom, and when - readable over HTTP, from the CLI, or directly from PostgreSQL."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-23
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
  - shomei-servant
interface:
  - Shomei.Audit.Event.Domain
  - Shomei.Audit.Publisher.Store
  - Shomei.Audit.Reader.Store
requires:
  - CAP-6
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/Audit/Event/CodecSpec.hs
    proves: Every event type round-trips through its payload codec, and older payloads written without newer fields still decode.
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: Publishing lands a row, and the reader filters by type, orders newest-first, pages by keyset, and reconstructs the typed event.
  - kind: test
    resource: shomei-server/test/Admin/Main.hs
    proves: The CLI returns published events with working type filters and counts.
  - kind: guide
    resource: docs/user/security.md
    proves: How to read the trail and what each event family means.
---

# Audit event trail

**Builds on:** [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md).

Logins, logouts, lockouts, throttles, session revocations, role grants and revocations, key
lifecycle changes, service-account and OAuth-client management, machine-token issuance,
impersonation, MFA changes, and notification-delivery failures all publish a typed event with a
structured payload.

Three ways to read it:

```bash
shomei-admin audit events --type login_failed --json   # NDJSON, newest first
shomei-admin audit user <user-id>
shomei-admin audit count --type impersonation_started
```

`GET /v1/admin/audit/events` exposes the same reader over HTTP behind the `admin` role, and the
rows are ordinary PostgreSQL rows if you would rather query them directly. Reading is keyset
paginated, so a large trail pages without the offset drift a `LIMIT/OFFSET` reader has.

Admin mutations name the acting administrator (`payload.actor`, `payload.revokedBy`), which is
what distinguishes an operator's action from the user's own.

## Limits

- **It is a table in the same database, not an append-only ledger.** Anything with write access to
  PostgreSQL can alter or delete rows; there is no hash chain, no signature, and no export to an
  external sink. It is an operational trail, not tamper-evident evidence.
- Retention is opt-in. With no window configured the sweeper leaves audit rows alone and the table
  grows unbounded; with one configured, old rows are deleted with no archival step.
- `payload.actor` and `payload.revokedBy` are `null` both for genuine self-service actions and for
  events written before those fields existed, so absence is ambiguous on old rows.
- Publishing is in the request path against the same database. There is no queue and no external
  audit sink; a database problem is a request problem.
