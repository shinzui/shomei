---
title: "Observability: structured logs, metrics, and health probes"
type: Capability
description: "Operate the service with one-line JSON request logs carrying correlation ids, a Prometheus /metrics endpoint, distinct liveness and readiness probes, graceful shutdown, and supervised background loops."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-22
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-server
interface:
  - Shomei.Server.Observability.Logging
  - Shomei.Server.Observability.Metrics
  - Shomei.Health.Server
  - Shomei.Server.Supervisor
requires:
  - CAP-20
evidence:
  - kind: test
    resource: shomei-server/test/Shomei/Server/MiddlewareSpec.hs
    proves: One valid JSON line per request, control characters stripped, health paths excluded, 200 concurrent writers producing 1000 intact lines, the in-flight gauge returning to zero even when a handler throws, bounded method-label cardinality, and a structured warp exception log.
  - kind: test
    resource: shomei-server/test-health/Main.hs
    proves: Readiness distinguishes an active signing key, missing keys, and PostgreSQL being unavailable; tracked readiness preserves onset, one-second caching shares a query, and a slow query times out as a PostgreSQL failure.
  - kind: test
    resource: shomei-server/test/Shomei/Server/SupervisorSpec.hs
    proves: A crashing background cycle is retried rather than fatal, backoff resets after a clean cycle, and an async exception stops the loop.
  - kind: guide
    resource: docs/user/deployment.md
    proves: The operational endpoints and what an orchestrator should probe.
---

# Observability: structured logs, metrics, and health probes

**Builds on:** [CAP-20 — standalone authentication service](standalone-auth-service.md).

- **`GET /health/live`** — the process is up.
- **`GET /health/ready`** — PostgreSQL is reachable *and* an active signing key exists. A `503`
  answers with a `{"status","database","signingKey"}` document naming which check failed, so an
  orchestrator's probe output says *why*.
- **`GET /metrics`** — a hand-rolled Prometheus exposition: request counts, an in-flight gauge,
  and latency. The gauge is decremented even when a handler throws, method labels have a fixed
  vocabulary, and label values are escaped for the exposition format.
- **Request logs** — one JSON object per line with a correlation id, safe to ship to any
  line-oriented collector. Control characters are stripped, health paths are skipped so probe
  traffic does not drown the log, and concurrent writers cannot interleave a line.

Background work — the retention sweeper and the signing-key reloader — runs under
`supervisedLoop`: a failed cycle logs loudly and backs off rather than taking the server down, and
backoff resets after a clean cycle. `SIGTERM` and `SIGINT` trigger warp's graceful shutdown with a
configurable timeout.

## Limits

- The Prometheus exposition is **hand-rolled**, not `prometheus-client`. The metric set is what
  the module implements; there is no registry a host can add its own metrics to.
- `/metrics` is served by middleware with **no authentication**. Do not expose it publicly.
- Readiness is bounded to two seconds and cached for one second. Cache refresh is single-flight,
  so concurrent probes share one database round-trip; this intentionally permits a verdict to be
  at most one second stale.
- There is **no tracing**. No OpenTelemetry spans, no context propagation; the correlation id in
  the log line is the only request-stitching mechanism.
- Supervised loops die with the process and are not respawned by a monitor. That is safe only
  because every cycle is idempotent — an interrupted cycle simply did not happen.
