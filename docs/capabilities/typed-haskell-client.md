---
title: "Typed Haskell client"
type: Capability
description: "Call a deployed Shomei from Haskell through functions derived from the same Servant API record the server serves, so a route change is a compile error rather than a runtime 404."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-12
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-client
interface:
  - Shomei.Client
requires:
  - CAP-7
evidence:
  - kind: test
    resource: shomei-client/test/Main.hs
    proves: signup, login, me, and refresh against a live in-process server, and every admin wrapper reaching its route.
  - kind: guide
    resource: docs/user/client-and-examples.md
    proves: How to construct the client environment and call it.
---

# Typed Haskell client

**Builds on:** [CAP-7 — embeddable Servant auth API](embeddable-servant-auth-api.md).

`shomei-client` derives its functions from `ShomeiAPI` itself, so the client and the server
cannot disagree about a path, a method, or a body shape. When the application routes moved under
`/v1`, client call sites did not change at all — the segment lives in the route type.

Every admin operation has a typed wrapper, and the client test drives all of them against a live
in-process server, so "the wrapper exists" and "the wrapper reaches its route" are both checked.

## Limits

- Haskell only. Other languages generate a client from the OpenAPI document
  ([CAP-11](problem-details-and-openapi.md)) instead.
- It is a thin `servant-client` derivation: no retry policy, no token refresh loop, no connection
  pooling beyond what the caller's `Manager` provides. Handling `401` by refreshing is the
  caller's job.
- Errors arrive as `ClientError` with the problem document in the body; the client does not
  decode them into a typed error union for you.
