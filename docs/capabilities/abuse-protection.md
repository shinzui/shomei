---
title: "Abuse protection: lockout, throttling, and rate limits"
type: Capability
description: "Slow down credential attacks with a per-account brute-force lockout, a per-IP failure throttle, a per-IP request-rate limiter, and a request body-size cap - none of which leak whether an account exists."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-21
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-server
interface:
  - Shomei.Session.LoginAttempt.Store
  - Shomei.Server.Middleware.RateLimit
  - Shomei.Server.Middleware.BodyLimit
requires:
  - CAP-2
  - CAP-20
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/LockoutSpec.hs
    proves: Lock after N failures, unlock after the cooldown, and that a locked account is indistinguishable from a wrong password.
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: The same lockout behavior over the real PostgreSQL store, with windowed failure counting and lockout upsert/clear.
  - kind: test
    resource: shomei-core/test/Shomei/Session/Authentication/TimingSpec.hs
    proves: Every login attempt invokes the password hasher exactly once whatever the reason for failure, closing the timing oracle that would otherwise enumerate accounts.
  - kind: test
    resource: shomei-server/test/Shomei/Server/MiddlewareSpec.hs
    proves: The token bucket throttles only the versioned unauthenticated auth endpoints, evicts idle buckets losslessly, stays bounded under 10k one-shot IPs, and that an oversized Content-Length is 413.
  - kind: guide
    resource: docs/user/security.md
    proves: What each layer defends against and the no-leak guarantees.
---

# Abuse protection: lockout, throttling, and rate limits

**Builds on:** [CAP-2 — password account lifecycle](password-account-lifecycle.md), [CAP-20 — standalone authentication service](standalone-auth-service.md).

Four independent layers:

| Layer | Keyed by | State | Rejects with |
|---|---|---|---|
| Brute-force lockout | account | PostgreSQL, survives restart | the generic login error |
| Failure throttle | client IP | PostgreSQL attempt log | `429` |
| Request-rate limiter | client IP | in-process token bucket | `429` before Servant or the database |
| Body-size cap | request | none | `413` |

None of them leak account existence. A locked account returns exactly the same error as a wrong
password — never `AccountLocked` — and a login for an account that does not exist performs a dummy
Argon2id verification with the *configured* parameters, so a miss costs what a hit costs. The
per-IP throttle is checked before any attempt is recorded, so an attacker cannot keep a victim
throttled by failing on their behalf.

The token bucket prunes itself: every `sweepEvery` throttled requests it deletes, inside the same
STM transaction, every bucket that has refilled to capacity. That is semantically lossless — an
absent key is treated as a fresh full bucket — so it needs no tuning knob and a slow scan of the
address space cannot grow the map forever.

## Limits

- The request-rate limiter is **in-process and in-memory**, deliberately not backed by Redis. It
  targets a single-instance deployment: N replicas mean N times the limit, and a restart resets
  the state. The account lockout, which is the one that matters for credential attacks, is
  PostgreSQL-backed and does survive.
- It is scoped to the unauthenticated `POST` auth endpoints. Authenticated traffic bearing a valid
  token is never throttled by it.
- The body-size cap reads `Content-Length`. A **chunked** request body passes through — a
  documented caveat, asserted by a test rather than papered over.
- **Client IP is the socket peer address.** `X-Forwarded-For` is explicitly not consulted — a
  trusted-proxy policy is out of scope for the single-instance target. Behind a reverse proxy
  every request therefore shares the proxy's address, which collapses both per-IP layers into one
  global bucket. Rate-limit at the proxy instead.
