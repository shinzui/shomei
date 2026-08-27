---
type: Architecture Decision Record
title: Secure transport cookies use browser-enforced name prefixes
description: Shomei uses __Host- for its secure session cookie and __Secure- for its path-scoped secure refresh cookie, with bare names only when Secure is disabled.
docId: ADR-16
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T23:03:34Z
originatingPlan: docs/plans/58-proxy-aware-wai-edge-trusted-forwarded-headers-metered-bodies-and-bounded-metrics.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T23:03:34Z
---

# Secure transport cookies use browser-enforced name prefixes

## Context

Cookie attributes are security policy only if the browser receives and preserves them. An
attacker who can inject a less constrained cookie with the same name can create ambiguous cookie
selection and undermine assumptions about host scope, transport security, or path. Browser cookie
name prefixes make those invariants part of cookie acceptance instead of relying only on the
server's `Set-Cookie` renderer.

The access token must be available across the origin, while the long-lived refresh token is
deliberately presented only to `/v1/auth/refresh`. The two credentials therefore cannot use the
same prefix without weakening refresh-token path isolation.

## Decision

When `cookieConfig.secure` is enabled, Shōmei emits and accepts `__Host-shomei_session` for the
access token. It always carries `Secure`, has `Path=/`, and has no `Domain`, satisfying the
browser-enforced `__Host-` contract.

The path-scoped refresh credential uses `__Secure-shomei_refresh`. It carries `Secure` but retains
`Path=/v1/auth/refresh`; `__Host-` is unavailable because that prefix requires `Path=/`.

When `cookieConfig.secure` is explicitly disabled, Shōmei emits and accepts the bare
`shomei_session` and `shomei_refresh` names. A prefix whose invariant cannot be met must not be
used. Emission, authentication, refresh, and clearing all derive names from the same runtime
cookie policy.

## Consequences

Upgrading a secure cookie-transport deployment logs existing browser sessions out once because
the old bare cookies are intentionally no longer credentials. The underlying server sessions
remain valid, and bearer tokens are unaffected. Operators should announce the one-time browser
reauthentication when deploying this change.

Secure browser sessions gain user-agent enforcement of the session cookie's host-only root path
and both cookies' secure transport. Local development can still disable `Secure`, but doing so
also visibly selects the weaker bare names.

## Alternatives rejected

Keeping the bare names was rejected because it leaves the invariants solely to server behavior.
Using `__Host-` for both cookies was rejected because it would force the refresh token onto every
path. Using prefixed names while `Secure` is disabled was rejected because conforming browsers
discard such cookies. Accepting both old and new names during a transition was rejected because
it preserves the weaker ambiguous-cookie surface and makes the migration boundary indefinite.
