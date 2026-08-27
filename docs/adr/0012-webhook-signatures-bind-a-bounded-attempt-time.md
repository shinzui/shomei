---
type: Architecture Decision Record
title: Webhook signatures bind a bounded attempt time
description: Each notification webhook attempt signs its Unix timestamp together with the exact body so receivers can enforce a bounded replay window.
docId: ADR-12
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T21:58:23Z
originatingPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T21:58:23Z
---

# Webhook signatures bind a bounded attempt time

## Context

Notification webhooks carry live one-time account credentials. HMAC over the body proved origin
and integrity but gave a captured valid request no protocol-level replay limit. Token expiry
eventually stops redemption, yet a receiver cannot distinguish a current delivery attempt from a
recorded one while the token remains live.

Retries also happen seconds after the initial attempt, so signing only the enqueue time would
consume part of a receiver's replay window before the request is sent.

## Decision

Every attempt sends `X-Shomei-Timestamp` as integral Unix seconds and computes
`X-Shomei-Signature: sha256=<hex>` as HMAC-SHA256 over
`<timestamp bytes>.<exact raw body bytes>`. Each retry reads the clock again and produces a new
timestamp and signature over the unchanged body.

Receivers verify against the raw request body, compare the signature in constant time, reject a
timestamp more than 300 seconds from their clock, and de-duplicate successful work by the stable
notification token.

## Consequences

A captured request has a bounded useful replay window at a conforming receiver. Receiver clocks
must be synchronized, and existing webhook consumers must update their signature input; the
header format remains `sha256=<hex>`, but body-only verification is intentionally incompatible.

Retries remain idempotent by token while being independently fresh for timestamp validation.
Changing the replay window is receiver policy; five minutes is the documented interoperability
default rather than a server-side rejection rule.

## Alternatives rejected

Body-only HMAC was rejected because it permits replay for the token's full lifetime. Signing the
initial enqueue time was rejected because queueing and retry delay reduce the receiver's usable
window. A random delivery nonce was rejected because it requires durable receiver state even to
detect freshness; receivers already need token de-duplication for timeout retries.
