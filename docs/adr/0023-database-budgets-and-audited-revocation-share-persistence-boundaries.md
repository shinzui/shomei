---
type: Architecture Decision Record
title: Database budgets and audited revocation share persistence boundaries
description: Database-only transactions enforce shrinking finite deadlines and bulk revocation records exactly its winning transitions without materializing rows in the application.
docId: ADR-23
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T15:20:57Z
originatingPlan: docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T15:20:57Z
---

# Database budgets and audited revocation share persistence boundaries

## Context

Unbounded dependency retries and per-row administrative revocation allow work to grow with
contention or account history. A client timeout alone is insufficient: Hasql interruption
cleanup drains a running query before cancellation, observed as a 30-second lock wait under a
100ms client deadline (FRIC-3). The authoritative registry reports Hasql 2.0.1.0 as latest;
its release sdist retains the same drain-before-cancel order. Upstream tags verify supported
1.10.3.7; no 2.0 tags are published. The wrapper supports the current 1.10 API line without
requiring an unrelated major dependency migration.

## Decision

The database interpreter defaults to three whole attempts and a five-second total budget.
Only SQLSTATE 40001 and 40P01 permit replay. Timeouts, connection failures, ambiguous commits,
and other server errors never replay. The dependency's automatic retry loop is disabled.
Server deployment settings expose positive attempt and deadline overrides; direct library
callers use a validated policy or the finite defaults. Administrative CLI operations retain
the same finite default policy.

Transactions use an abstract database-only statement wrapper, with no MonadIO instance or
raw Hasql transaction constructor. Each attempt installs a local server deadline. Before each
prepared statement, it shrinks statement_timeout to the remaining budget, also respecting a
stricter configured statement timeout. Commit/rollback resets the local settings. An outer
monotonic deadline covers pool checkout, retry backoff and all attempts. Domain identifiers,
password hashing, signing, notifications and external audit publication remain outside retried
bodies. Database audit inserts roll back with their state transitions.

Bulk administrative revocation uses the existing winner-producing session update inside a
single SQL CTE: update active sessions, revoke their refresh tokens, insert one audit event per
winner, return a count. Winners never cross the application boundary as a list. The session's
unique UUID is also the bulk audit row key, stable across retry; active-to-revoked CAS permits
one event per session. Other audit writers retain their UUIDv4 keys. A failed audit insert
rolls back all revocations. Single-session administration uses the existing atomic audited
unit of work, making repeated requests audit-silent.

The bulk payload persists its session UUID, matching the native session_id column. The typed
audit decoder accepts this representation and the existing TypeID representation; public
payloads encode the canonical TypeID. The actor and application timestamp are prepared once
outside the transaction. The event's user_id remains NULL as before, since the event names a
session and an actor rather than an account subject.

Session listing uses a stable (created_at, session_id) keyset, default 50 and maximum 200 rows.
HTTP returns a sessions array and nextCursor in a page object. The old unbounded library
listing remains a documented compatibility operation; HTTP never calls it.

## Consequences

The abstract transaction type, winning-ID revocation result and HTTP page shape are API
changes. Each bounded statement pays one small budget-setting query in the same checkout.
Deployments can narrow budgets to shed contention; exhaustion maps to the existing sanitized
dependency-unavailable result. Deadline precision includes scheduler and driver cleanup overhead,
so tests assert finite wall time with tolerance as well as actual rollback and connection reuse.
