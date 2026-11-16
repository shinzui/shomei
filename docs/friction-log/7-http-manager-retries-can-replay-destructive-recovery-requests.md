---
type: Friction Entry
title: "HTTP manager retries can replay destructive recovery requests"
description: "The HTTP client retry policy belongs to the manager and can replay POST after an ambiguous reused-connection failure, requiring request-local isolation."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-16T16:44:04Z"
frictionId: FRIC-7
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/shomei"
affects: "mori://snoyberg/http-client/packages/http-client"
plan: "docs/plans/71-add-audited-administrative-recovery-for-lost-second-factors.md"
workaround: "Use an operation-local copy of the manager with retries disabled, preserve its pool and custom settings, and disable redirects for the destructive request."
resolution: "Isolate the supplied HTTP manager for recovery requests, disabling automatic retries and redirects while preserving its connection pool and deployment settings."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-16T16:45:19Z"
    change: "Accept a narrowly scoped http-client internal manager override until a per-request retry API exists."
---
# HTTP manager retries can replay destructive recovery requests

## Attempted

Use the derived administrator reset client with a caller-provided ClientEnv and no automatic destructive retry.

## Encountered

http-client retries any method after a retryable exception on a reused connection; the public per-request API has no retry switch.

```text
Left e | managedReused mconn && mRetryableException m e -> action req m
```

## Workaround

Use an operation-local copy of the manager with retries disabled, preserve its pool and custom settings, and disable redirects for the destructive request.
