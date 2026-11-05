---
type: Architecture Decision Record
title: Machine and delegated mints spend active principal budgets
description: Non-interactive issuance atomically spends finite actor and subject budgets while expiry and bounded retention preserve revocation semantics.
docId: ADR-24
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T15:41:39Z
originatingPlan: docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T15:41:39Z
---

# Machine and delegated mints spend active principal budgets

## Context

Machine and delegated mints intentionally create distinct revocable sessions. Reusing an old
session would change revocation semantics. Expiry alone does not bound active state or retained
history when a principal mints rapidly.

## Decision

The shared policy defaults to 1000 active non-interactive sessions per principal, configurable
as a positive integer. A machine mint spends its subject's budget. A delegated mint spends
both the subject and distinct actor's budgets, preventing unlimited growth by changing either
side of a delegation. Interactive login sessions do not spend this budget.

PostgreSQL locks all participating account rows in UUID order, counts unexpired active machine
and delegated sessions, then inserts in the same bounded transaction. Counts stop at the
configured ceiling and avoid double-counting a row that names a principal in both positions.
The in-memory interpreter makes the same count-and-insert decision atomically. IDs are
allocated before the transaction. Only the accepted mint reaches signing and success audit.
All machine grants and both delegated mint entry points share this operation.

Expiry frees capacity independently of deletion. Lowering a limit preserves existing sessions;
further mints fail until capacity becomes available. The bespoke API returns HTTP 429 with
session_limit_reached; OAuth grants return HTTP 503 temporarily_unavailable in the OAuth shape.
No refresh token is added and no existing session is silently reused or purged.

The existing enabled sweeper supplies finite expired-session retention, default 30 days, with
bounded delete batches and a 10ms yield after each successful batch on its dedicated connection. The same policy covers expired
machine/delegated rows. It never selects an unexpired active session. Retention and sweep
interval determine disk history; the active cap is not an absolute disk-row cap.

## Consequences

Capacity planning includes issuance rate times (token lifetime + retention + sweep lag), plus
audit history under its separate policy. Disabling or underprovisioning cleanup permits
unbounded historical growth. Operators can revoke unused sessions or wait for expiry; a lowered
limit does not invalidate existing tokens. Raw CreateSession remains a migration/testing seam;
production non-interactive workflows must use createSessionWithinLimit.
