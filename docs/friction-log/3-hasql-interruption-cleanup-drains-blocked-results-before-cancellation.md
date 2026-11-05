---
type: Friction Entry
title: "Hasql interruption cleanup drains blocked results before cancellation"
description: "Hasql cancellation cleanup forced statement-level server deadline enforcement after repeated 30-second lock waits."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T15:12:52Z"
frictionId: FRIC-3
status: "logged"
impact: detour
kind: interface
origin: "mori://shinzui/shomei"
affects: "mori://hasql/hasql/packages/hasql"
affectedVersion: "1.10.3.7"
plan: "docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md"
workaround: "Use the database-only transaction wrapper with a shrinking statement_timeout before each prepared statement, plus outer checkout/backoff deadline. Hackage latest 2.0.1.0 sdist retains drain-before-cancel; upstream tag 1.10.3.7 confirms the supported line and no 2.0 tags are published."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-05T15:24:30Z"
    change: "Verified authoritative current registry and release source; changing to the latest major release would not remove the cleanup limitation."
---
# Hasql interruption cleanup drains blocked results before cancellation

## Attempted

Bound a real PostgreSQL advisory-lock wait with a 100ms Haskell timeout around a no-retry transaction.

## Encountered

Both attempts returned after roughly 30 seconds, the pool statement timeout; Hasql cleanup drains results before cancel.

```text
transaction deadline cancels a real lock wait: FAIL (30.67s); total deadline is finite assertion failed. Hasql.Comms.Session.cleanUpAfterInterruption executes drainResults before cancel.
```

## Workaround

Introduce a database-only transaction wrapper that shrinks PostgreSQL statement_timeout before each prepared statement; retain the outer deadline for checkout and backoff.
