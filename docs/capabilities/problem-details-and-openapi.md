---
title: "RFC 9457 problem details and a drift-checked OpenAPI 3.1 document"
type: Capability
description: "Every application failure answers as one problem+json document whose code and status are generated from the same catalog the served OpenAPI 3.1 spec declares, with a test that fails when the two drift."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-11
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-servant
interface:
  - Shomei.Servant.Error
  - Shomei.Servant.OpenApi
requires:
  - CAP-7
evidence:
  - kind: conformance
    resource: shomei-servant/test-openapi/Main.hs
    proves: Every DTO's ToJSON validates against its generated schema; every documented error code exists in the runtime catalog at the documented status; the runtime problem body validates against the published Problem schema; and the hygiene invariants a generated client depends on hold.
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: The problem+json envelope is produced by every layer - auth handler, authz combinator, handler, Servant's own formatters, and the method check.
  - kind: guide
    resource: docs/user/problem-details.md
    proves: Every application problem type and the safe client action for it.
  - kind: guide
    resource: docs/user/openapi-client-generation.md
    proves: How to generate typed clients in other languages from the served document.
---

# RFC 9457 problem details and a drift-checked OpenAPI 3.1 document

**Builds on:** [CAP-7 — embeddable Servant auth API](embeddable-servant-auth-api.md).

Every application failure is one document:

```jsonc
// Content-Type: application/problem+json
{"type": "https://github.com/shinzui/shomei/blob/master/docs/user/problem-details.md#token_invalid",
 "title": "Token is invalid", "status": 401, "code": "token_invalid", "retryable": false}
```

`type` dereferences to the documented entry for that failure; `code` is the same anchor without
the URL prefix, and is the stable machine member client switch-logic reads. `retryable` is a
Shōmei extension that tells a client whether retrying can ever help. A `401` carries
`WWW-Authenticate: Bearer`; a `429` carries `Retry-After`. Failures that used to escape the
envelope entirely — an expired bearer token, a missing role, a malformed JSON body, an unknown
route, a wrong method, a throttled request — all return this same shape now.

`GET /openapi.json` serves the OpenAPI 3.1 document **for the binary that is running**, so a
generated client matches the deployment rather than a committed file. The committed copy at
`docs/api/openapi.json` exists for offline codegen.

What makes the document trustworthy is the conformance suite: the error responses'
`properties.code.enum` are generated from the same constants the server renders at runtime, and
the test asserts that every documented code exists in the runtime catalog at the documented
status *and* that the body the server actually writes validates against the published `Problem`
schema. The spec cannot promise a code or a status the server never sends.

## Limits

- **`/oauth/*` is deliberately outside the envelope.** Those endpoints answer with RFC 6749
  §5.2's `{"error", "error_description"}` object as `application/json`, because stock OAuth2
  clients parse those fields by name. This is permanent, and the document declares a separate
  `OAuthError` schema for it.
- `GET /health/ready`'s `503` is also exempt: it stays a `{"status","database","signingKey"}`
  probe document.
- `type` points at a documentation page in this repository's `master` branch. It is a stable
  identifier, but it is a GitHub URL, not a versioned or self-hosted one — a fork or a private
  mirror inherits URIs pointing at the upstream repository.
- The conformance test pins the path count (currently 41). Adding a route is a deliberate,
  test-updating act — which is the intent, but it does mean the suite fails on any route change
  until the count is updated.
