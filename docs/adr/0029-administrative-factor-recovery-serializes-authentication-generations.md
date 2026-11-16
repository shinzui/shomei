---
type: Architecture Decision Record
title: Administrative factor recovery serializes authentication generations
description: Lost-factor recovery trusts explicit operator verification and atomically advances user state so prior proofs cannot recreate credentials or sessions.
docId: ADR-29
status: Accepted
date: 2026-11-16
timestamp: 2026-11-16T16:47:35Z
originatingPlan: docs/plans/71-add-audited-administrative-recovery-for-lost-second-factors.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-16T16:32:14Z
---

# Administrative factor recovery serializes authentication generations

## Context

Password reset preserves MFA. Owners who lose all enrolled factors and unused recovery codes
need a supported recovery operation. Deleting pending challenges alone does not exclude requests
that already consumed a challenge and verified a credential before the deletion.

## Decision

The shared recovery workflow requires independent owner-verification assertion and a bounded
non-sensitive case reference. HTTP requires administrator authority, refuses delegation and
self-targeting, validates a live backing session even in token-only mode, and derives human versus
service attribution from the principal. The CLI trusts database authority and records an asserted
local operator label. Neither assertion constitutes software-performed human identity proofing.

A bounded database transaction locks the user first, requires active status, advances a nonnegative
authentication generation, removes every factor and user-bound pending ceremony, revokes sessions
and refresh tokens, invalidates authorization codes and password-reset tokens, and records the
reset plus winning session-revocation events. Audit failure rolls back all writes. Counts describe
the transaction's own effects; every successful invocation audits and advances state, including
zero-count repeats. Case references correlate incidents and are not idempotency keys.

Proof workflows capture generation before credential verification and compare under the same user
lock at session or factor persistence. User-bound pending state retains its originating generation;
legacy pending state without one restarts. Passwordless completion captures generation when
resolving the asserted credential, before verification, and rechecks credential existence at mint.
Enrollment and recovery-code writes also require their initiating session to remain live. Refresh
and authorization-code consumption use the user-first lock order and recheck validity after it.
Cryptography, identifiers and delivery remain outside retried database-only transactions.

The transaction captures an already verified contact destination for the post-commit secret-free
notice. Server enqueue is bounded best effort; CLI waits up to 30 seconds for its configured
transport before exiting. Failure or absence of delivery does not undo committed security state.
Operators must notify through an independently established channel when no verified address exists.

Recovery preserves password, verification, roles/scopes, status and lockout state and issues no
tokens. The password-only interval lasts until supervised replacement enrollment and fresh recovery
codes. Password rotation is separate when compromise is suspected. Session-aware routes reject old
sessions immediately; offline access-token verification retains its existing expiry limitation.

The destructive reset client helper disables both reused-connection retries and redirects.
The existing [HTTP client](mori://snoyberg/http-client/packages/http-client) has no public
per-request retry switch. A request-local copy of its chosen manager keeps the shared pool,
TLS/proxy settings and hooks, while disabling the retry predicate; the original manager is
unchanged. Tests prove one server-observed POST after an ambiguous close on a reused connection
and after a redirect. FRIC-7 records this accepted internal-API dependency.

## Consequences

Generation-bearing types and guarded persistence/workflow interfaces change for direct library
consumers. Tests exercise independent PostgreSQL connections at the commit boundary, including
rollback on audit failure. The additive migration preserves credentials/sessions, but recovery
requires a maintenance rollout that drains all old writers before generation-aware code is used.
Rollback retains the schema and disables recovery; an older binary cannot uphold the new barrier.

Direct SQL credential deletion, password-reset bypasses, unaudited CLI identities, and silent
restoration of old factors were rejected because they do not establish an atomic, attributable
recovery procedure. Best-effort notification is deliberately not confirmed delivery.
