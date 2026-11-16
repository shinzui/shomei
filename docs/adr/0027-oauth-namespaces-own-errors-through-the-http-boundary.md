---
type: Architecture Decision Record
title: OAuth namespaces own errors through the HTTP boundary
description: Shared decoded namespace mounts select OAuth errors at routing and middleware boundaries independently of authentication challenges.
docId: ADR-27
status: Accepted
date: 2026-11-16
timestamp: 2026-11-16T15:16:13Z
originatingPlan: docs/plans/72-make-oauth-errors-protocol-consistent-across-handlers-and-middleware.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-16T15:04:02Z
---

# OAuth namespaces own errors through the HTTP boundary

## Context

Stock OAuth clients parse `error` and `error_description`. A problem document emitted before a
handler runs breaks that contract just as a handler returning the wrong body would. HTTP status
alone also cannot identify an authentication scheme: interactive authorization and client
credential authentication both use 401 for different reasons.

## Decision

`Shomei.OAuth.Boundary` owns validated mount prefixes and fixed safe error responses. Prefixes
match complete decoded segments from the start of a path, independently of method. The default
mount is `/oauth`; a host can register `/identity/oauth` without capturing `/reports/oauth` or
`/oauthish`. Empty mount segments and root mounts are rejected. Hosts reuse one mount value in
Servant formatters, response middleware and `hostMiddlewareWithOAuthMounts` (see [ADR-17](0017-embedded-hosts-install-the-complete-runtime-boundary.md)).
Servant formatters decode `rawPathInfo`, since routing may already have consumed `pathInfo`.

OAuth namespaces use JSON error bodies for parsing, duplicate credentials, unknown paths,
method/content negotiation, body limits and throttling. Descriptions at these boundaries are
fixed and never include submitted values or parser diagnostics. Response normalization is
limited to 404/405/406/415 (including a host Raw/static fallback
that bypasses Servant's not-found formatter); it does not read streams, guess from arbitrary bodies, or change redirects.
It replaces representation headers and preserves semantic headers such as `Allow`.

413 `invalid_request` and 429 `temporarily_unavailable` are Shōmei operational extensions using
the OAuth envelope, retaining useful HTTP status and the existing limits. Both are non-cacheable;
429 retains `Retry-After: 60`. Namespace selection does not determine limiter eligibility: the
API's `RateLimited` markers remain authoritative. Other application routes retain RFC 9457.

The generic OAuth renderer adds no challenge. `invalidClient` owns Basic for all existing
client-authentication failures, including required absent and body credentials. UserInfo owns
Bearer, distinguishing missing credentials from `invalid_token`. Authorize's 401 `login_required`
has no authentication challenge and preserves its existing interactive-session policy.

## Consequences

Shared typed results declare the operational and routing statuses, optional challenge/retry/Allow
headers, and handwritten union mappings. Generated clients and OpenAPI describe the same HTTP
boundary. Adding constructors or header record fields requires downstream source updates.

The application contract excludes malformed HTTP rejected before WAI, socket admission failures,
disconnected clients and reverse-proxy-generated responses. These cannot reliably be assigned an
application protocol. Packaged-executable Hurl checks complement typed and generated-contract tests.

## Alternatives rejected

Documenting middleware problem responses as an exception would leave ordinary OAuth clients
unable to decode them. Searching for an arbitrary `oauth` segment would take over unrelated host
routes. Deriving a challenge from status would conflate browser login with client authentication.
