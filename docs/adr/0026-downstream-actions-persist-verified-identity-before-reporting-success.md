---
type: Architecture Decision Record
title: Downstream actions persist verified identity before reporting success
description: The runnable resource-service example synchronously appends secret-free actor and subject records and fails closed when its audit sink fails.
docId: ADR-26
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T17:12:34Z
originatingPlan: docs/plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T17:12:34Z
---

# Downstream actions persist verified identity before reporting success

## Context

Returning actor identity in a project response does not create an audit trail. A resource server
needs to retain both the verified subject it acts for and any verified actor, without persisting
bearer credentials or trusting claims from rejected tokens.

## Decision

The runnable downstream example injects an AuditSink into its local verification and protected
projects read. Each action records time, subject, actor, fixed action/resource, result and bounded
request correlation. Identity comes only from successful JWT verification, including the strict
actor and lifetime policies in ADR-3. Authentication rejections record no attributed identities.
Key unavailability has a separate outcome. The example's synchronous file sink creates/appends
with owner-only permissions, serializes writers, flushes and fsyncs each complete JSON line before
acknowledging persistence. A sink exception returns 503 before the demonstrated action can report
success; exception details do not cross the HTTP boundary. Async cancellation still propagates.

One sink instance in one process owns a file in an existing private directory. Rotation and
forwarding belong to the operator; the sink reopens the configured path for each append. The
older verification-only application builders remain compatibility adapters and provide no durable
audit guarantee. The runnable executable always uses the explicit file sink.

## Consequences

The example now demonstrates persisted ordinary and delegated actions, rejected requests,
concurrent intact lines and fail-closed storage errors. The AuthProtect principal carries verified
claims and sanitized request correlation together. A generated correlation is process-local;
forward a unique proxy correlation when traces span processes.

This is a demonstration of an audited read, not a general compliance or multi-process storage
product. A file and a future business database do not share an atomic transaction. A real mutation
needs its own transactional/outbox contract; this example makes no claim about cross-system
atomicity, transport delivery, tamper-proof retention or filesystem crash guarantees beyond the
reported flush/fsync. The record reports the application's decision, not proof the client received
its response.

## Alternatives rejected

Logging raw claims or tokens would cross the diagnostic trust boundary. Auditing after returning
success would hide sink failures. A no-op sink in the runnable service would preserve the original
missing-evidence defect. A shared append path across uncoordinated processes is outside this small
sink's ownership contract; use a collector or transactional audit service instead.
