---
type: Architecture Decision Record
title: Passkey enrollment spends an atomic account quota
description: Passkey count and insertion share one account-serialized persistence operation with an explicit finite ceiling and winner-only success audit.
docId: ADR-21
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T13:41:16Z
originatingPlan: docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T13:41:16Z
---

# Passkey enrollment spends an atomic account quota

## Context

An account can accumulate credentials indefinitely unless enrollment checks a count. A workflow
pre-read alone lets completions on different replicas both spend the final available slot.
Deleting existing credentials to meet a newly lowered limit would strand legitimate users.

## Decision

Passkey creation takes an explicit limit from 1 through 100 and returns a typed acceptance or
`PasskeyLimitReached`. The default policy is 20. PostgreSQL locks the owning user row, then
counts and inserts in one transaction. In-memory storage performs the same decision with one
atomic world update. Identifier generation precedes the transaction. The enrollment workflow
publishes a success event only after accepted persistence; full accounts receive HTTP 409.

The begin-time check is an optimization. Completion always enforces the limit independently.
Existing credentials remain readable, usable and removable after lowering a limit, while new
enrollment is refused. Operators configure the ceiling through the shared core policy, env
loader and Dhall schema. Direct persistence consumers must pass and handle that policy explicitly.

## Consequences

Competing completions have one winner at the last slot across replicas. Account-row locks must
stay short and contain database operations only. The API change is recorded in package
changelogs and all workspace fixtures are updated. A process-local lock or a separate count
read was rejected because neither enforces the invariant across deployments.
