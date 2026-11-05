---
type: Friction Entry
title: "Released pool cancellation fix requires an incompatible driver generation"
description: "Repeated caller interruption lost pool capacity and the released fix requires a driver version excluded by the current migration and harness releases."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-05T16:03:13Z"
frictionId: FRIC-4
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shomei"
affects: "mori://hasql/hasql/packages/hasql-pool"
affectedVersion: "1.4.2.3"
plan: "docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md"
workaround: "Own a finite managed pool over public Hasql 1.10 connections with masked ownership transfer, interruptible query work, conservative failure disposal and generation-aware release."
---
# Released pool cancellation fix requires an incompatible driver generation

## Attempted

Repeat the real lock/caller-cancellation/sole-connection reuse acceptance under the supported Hasql 1.10 and hasql-pool 1.4.2.3 stack.

## Encountered

Connection reuse timed out after interruption. Pool 1.5.1.0 documents fixes for interruption capacity leaks, but latest 1.5.1.1 requires Hasql 2; latest [pg-migrate](mori://shinzui/pg-migrate/packages/pg-migrate) 1.2.0.0 and [ephemeral-pg](mori://shinzui/ephemeral-pg/packages/ephemeral-pg) 0.3.1.0 require Hasql below 1.11.

```text
test/Main.hs: expected Just 0, got Nothing after caller cancellation. Authoritative Hackage package metadata and 1.5.1.1 CHANGELOG confirm the fixed lifecycle and Hasql 2 dependency. Upstream has no published 1.5 tags.
```

## Workaround

Own a finite managed pool over public Hasql 1.10 connections with masked ownership transfer, interruptible query work, conservative failure disposal and generation-aware release.
