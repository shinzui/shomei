---
type: Architecture Decision Record
title: Transport exception text is never persisted
description: Outbound transports map failures to a closed reason vocabulary before logging or persistence because dependency exceptions may contain secret payloads and URLs.
docId: ADR-9
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T21:23:06Z
originatingPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T21:23:06Z
---

# Transport exception text is never persisted

## Context

Shomei sends one-time account credentials through SMTP messages and signed webhook bodies. The
libraries implementing those transports attach request context to exceptions for diagnostics.
That context is not a safe logging boundary: smtp-mail includes the entire rendered message in a
failed `DATA` command, while http-client includes the request URL and query string in its `Request`
rendering. A relay rejection therefore exposed a quoted-printable one-time token, and a refused
webhook connection exposed a receiver secret carried in the URL.

Truncating these exception strings does not make them safe. Secret offsets vary with message
headers, quoted-printable encoding can split tokens across soft line breaks, and future dependency
versions may render different request fields.

## Decision

Every outbound transport maps dependency failures to a closed, secret-free reason vocabulary
before writing a log line or publishing an audit event. Notification delivery uses
`DeliveryReason` values such as `connect_failed`, `timeout`, `rejected_at_data:451`, and
`http_status:500`. Raw `displayException` or `show` output from a transport exception never reaches
stderr or persistent storage.

Classifiers may inspect exception constructors and text in memory to select a reason, then discard
the exception rendering. The notification's own token and any `token=` parameter are scrubbed as a
defence in depth before even a reason is emitted. This rule applies to all outbound transports,
including the password-breach checker, rather than only SMTP and notification webhooks.

## Consequences

Operators receive stable reason codes suitable for alerts and aggregation. Detailed relay or
receiver diagnosis belongs in the remote transport's own logs; Shomei deliberately gives up
arbitrary dependency error text at this trust boundary.

Adding a new transport requires a classifier and tests that prove request URLs, headers, response
bodies, payloads, and credentials are absent from both its operational log and audit event. A new
failure category extends the closed vocabulary instead of forwarding free text.

## Alternatives rejected

Truncating exception text was rejected because the SMTP token occurred within the existing cap and
its position is not stable. Searching for the raw token was rejected because quoted-printable
encoding rewrites and splits it. Replacing only `token=` parameters was rejected because webhook
secrets can appear in query parameters with arbitrary names and exception renderings can include
headers or echoed response bodies.
