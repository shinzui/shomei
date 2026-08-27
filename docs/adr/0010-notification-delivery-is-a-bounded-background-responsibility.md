---
type: Architecture Decision Record
title: Notification delivery is a bounded background responsibility
description: The standalone server separates notification delivery from request latency with a bounded in-memory queue, one supervised worker, explicit overflow, and a timed shutdown drain.
docId: ADR-10
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T21:42:36Z
originatingPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T21:42:36Z
---

# Notification delivery is a bounded background responsibility

## Context

Email-verification and password-reset request handlers previously performed SMTP or webhook
delivery inline. A registered address could therefore make the request wait for a transport
timeout or retry sequence while an unknown address returned immediately. That seconds-wide
difference exposed account existence by timing and coupled request capacity to an external
receiver.

Moving delivery out of the request path introduces a different resource boundary. An unbounded
queue can exhaust memory during an outage, a blocking bounded queue recreates the latency problem,
and immediate process exit can abandon work without an observable summary.

## Decision

The standalone server enqueues notifications into a bounded in-memory `TBQueue` with a default
capacity of 1024. Enqueue is one non-blocking STM transaction. A full queue drops the new item and
publishes `notification_delivery_failed` with reason `queue_full`; a queue closed for shutdown
drops late work with reason `shutting_down`.

One worker runs delivery through the shared supervised-loop mechanism. It skips items whose
one-time credential expired in the queue and reports `expired_in_queue`. On shutdown, the server
first stops accepting requests, closes the queue, and waits up to the configured graceful-shutdown
timeout for queued and in-flight work before releasing the database pool. A deadline reports one
structured count of abandoned items rather than producing one audit row per item.

The queue is deliberately not durable. Webhook consumers remain responsible for idempotence, and
operators who require durable retry must place it behind the webhook boundary or supply their own
interpreter.

## Consequences

SMTP and webhook latency no longer affects lifecycle request latency, and a transport outage has a
fixed memory ceiling. Overflow and shutdown loss are explicit operational outcomes rather than
hidden blocking or memory growth. Delivery ordering is single-worker FIFO except where retries
delay later items.

The remaining account hit/miss cost is database-local: a hit generates and inserts a token,
enqueues, and audits, while a miss performs only the lookup. This residual is accepted and pinned
by a cost test instead of writing fake token or audit rows on misses.

Process crashes can still lose queued work, and a shutdown deadline can expire. This is the stated
best-effort contract of the built-in transports.

## Alternatives rejected

Synchronous delivery was rejected because transport latency creates an account-existence oracle
and consumes request capacity. An unbounded queue was rejected because a receiver outage would
turn into unbounded memory use. Blocking when full was rejected because it recreates the request
stall under load. A persistent queue was rejected as disproportionate for the built-in
fire-and-forget notifier; deployments needing durable delivery can own that policy at the webhook
receiver.
