---
type: Architecture Decision Record
title: Embedded hosts install the complete runtime boundary
description: Hosts embedding Shomei install its background services and wrap the whole application in the standalone edge middleware.
docId: ADR-17
status: Accepted
date: 2026-08-27
timestamp: 2026-08-28T01:58:26Z
originatingPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-28T01:58:26Z
---

# Embedded hosts install the complete runtime boundary

## Context

Shōmei can run as its standalone Warp server or as a route tree mounted inside a host Servant
application. The route tree contains the authentication handlers and context, but it does not own
process-wide signal handlers, background workers, rate-limit state, observability state, or the
outer WAI edge. Treating the bare application as the complete embedding API left signing keys stale
until restart and put host-owned routes outside the body, rate-limit, logging, and metrics boundary.

Some background services also own resources: notification delivery needs a bounded shutdown drain,
and the expiry sweeper uses a separate PostgreSQL pool. A fire-and-forget installer cannot express
those cleanup obligations.

## Decision

The bare Shōmei `application` remains composable and does not install process services or WAI
middleware. An embedding host calls `installHostBackgroundTasks` exactly once after `buildEnv`. The
installer validates configured default roles, installs periodic and `SIGHUP` signing-key reload,
starts expiry sweeping, and starts notification delivery. It returns `HostBackgroundTasks`; after
the host HTTP server drains, the host calls `stopHostBackgroundTasks` with its graceful-shutdown
budget to drain notification work and release the sweeper pool.

The host creates the Shōmei limiter and metrics values, then wraps its whole WAI application with
`hostMiddleware`. The middleware order is the standalone order: trusted-proxy resolution,
request-ID and structured logging, HTTP metrics and the metrics endpoint, metered request-body cap,
then per-client rate limiting. The mounted Shōmei routes and host-owned routes therefore share one
edge policy and one resolved client identity.

The standalone executable consumes these same exported functions. It is the reference consumer,
not a separate assembly with private protections.

## Consequences

Embedded and standalone deployments now reload revoked signing keys, run maintenance and
notification work, validate startup roles, and enforce the same request boundary. A host must keep
the returned cleanup handle and arrange to call it after its server stops accepting requests.

Wrapping only the mounted authentication routes is unsupported because it leaves the rest of the
host outside the trust boundary. Installing the contract twice is also unsupported: signal handlers,
workers, and their resources are process-level responsibilities.

Future standalone edge or background protections must be added through these exported functions so
the executable and embedding examples remain mechanically aligned.

## Alternatives rejected

Baking middleware into `application` was rejected because a host must wrap its own routes and would
otherwise need to double-wrap Shōmei. Exporting only the bare route tree was rejected because it
makes security parity depend on copying private startup code. Returning `IO ()` from the background
installer was rejected because it loses the notifier-drain and sweeper-pool cleanup obligations.
