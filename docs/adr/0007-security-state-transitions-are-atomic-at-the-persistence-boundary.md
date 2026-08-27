---
type: Architecture Decision Record
title: Security state transitions are atomic at the persistence boundary
description: Single-use and monotonic transitions use conditional writes, while read-modify-write serialization uses transaction-scoped advisory locks.
docId: ADR-7
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T20:08:25Z
originatingPlan: docs/plans/55-atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T20:08:25Z
---

# Security state transitions are atomic at the persistence boundary

## Context

Authentication state is routinely consumed or advanced by concurrent requests. A read followed by
an unconditional write lets multiple requests observe the same token, counter, user status, or
lockout budget and all behave as winners. Likewise, splitting a credential change from its token
consumption, session revocation, and audit event can commit a security-sensitive half-state.

These races cannot be repaired in an HTTP handler or by an in-process lock: Shōmei may run several
processes, and embedding hosts may use the persistence ports directly. The authoritative decision
must therefore happen where all writers meet.

## Decision

Every single-use or monotonic security transition is one conditional database statement that
returns whether it changed a row. Its predicate includes the complete valid source state: token
status, expected counter, allowed user status, or unrevoked session state. A missing returned row
is a normal compare-and-swap loss, not a dependency failure, and the workflow performs winner-only
side effects only after that result.

When serialization must enclose a read and its dependent write, the PostgreSQL interpreter uses a
transaction-scoped advisory lock derived from the stable domain key. Login-failure recording and
windowed counting acquire that per-account lock, insert the attempt, count the authoritative rows,
and update the lockout in one transaction. The lock is released automatically at transaction end.

Multi-row credential tails run through an explicit unit-of-work port. Token consumption, password
replacement, sibling-token and session revocation, and the corresponding audit event either commit
together or roll back together. Password hashing and other expensive pure work remain outside the
transaction.

## Consequences

Concurrent callers have an observable, deterministic winner. Replayed one-time tokens, stale TOTP
or passkey counters, repeated revocations, and competing user-status changes cannot all succeed.
Lockout counts cannot be bypassed by racing a separate count and insert, even across processes.

Persistence ports expose compare-and-swap results and transaction-shaped operations, which is a
breaking API change for direct library callers. In-memory interpreters must preserve the same
atomic semantics so their concurrency tests remain meaningful specifications of PostgreSQL.

Advisory-lock keys and lock acquisition order become persistence contracts. Transactions holding
them must stay short; password hashing, notification delivery, and token generation must not occur
inside the locked region.

## Alternatives rejected

Read-then-write workflow checks were rejected because two requests can pass the read before either
writes. Process-local mutexes were rejected because they do not coordinate replicas or external
writers. Serializable isolation for every authentication transaction was rejected as broader and
costlier than the exact predicates and per-key serialization the invariants require.

Treating a compare-and-swap loss as a PostgreSQL outage was rejected because losing is an expected
domain outcome. Publishing audit events after the transaction was rejected because it can describe
a state change that rolled back or omit one that committed.
