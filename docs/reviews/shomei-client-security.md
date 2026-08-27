---
type: Review
title: shomei-client credential handling and admin wrappers
description: >-
  The typed client attaches tokens only as a per-call bearer header, selects TLS by URL
  scheme, derives every route from ShomeiRoutes, and sends the right credential to every
  admin wrapper; the one observation is that Token derives Show and so prints a raw JWT.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-9
subject: mori://shinzui/shomei/packages/shomei-client
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: commented
dimensions:
  - security
  - correctness
  - documentation
context: >-
  The integration reader agent read Shomei.Client and its test in full, the admin route types
  in shomei-servant the wrappers target, and servant-client-core's Request module in source
  for how ClientError renders credentials. The shomei-client suite passed at the commit
  (it depends on shomei-server, which is why the package is not on Hackage yet).
---

# shomei-client credential handling and admin wrappers

## Verdict

Commented; nothing to change before the package can be relied on. Tokens are a per-call `Token`
newtype attached only as `Authorization: Bearer` (`src/Shomei/Client.hs:193-196`); the client
holds no state and never logs or prints a credential; the manager is chosen by the base URL's
scheme so an `https` base gets TLS (`:236-242`); `refresh` posts to the route derived from
`ShomeiRoutes` (`:269-270`), so the refresh token cannot be sent to a wrong endpoint except
through a wrong base URL; every admin wrapper passes `bearer tok` (`:346-422`) to a route that
carries `RequireAdmin`, and the test asserts `403` rather than `404`/`405` for all eleven of them
(`test/Main.hs:89-99`). `ClientError`'s `Show` is safe: servant-client-core redacts the
`Authorization` header (`Servant/Client/Core/Request.hs:93-95`), which also covers the `Basic`
header `oauthToken` sends.

## Findings

**1. Low — `Token` derives `Show`** (`src/Shomei/Client.hs:132-133`), so a `show` or `print` of a
`Token` or of any record holding one emits the raw JWT. `shomei-core`'s `PlainPassword` has a
redacting instance; the same shape here would make "never in logs" structural for consumers.

**2. Info — `Client.hs:52`'s comment on admin access** matches `security.md:437` (`admin` role or
`shomei:admin` scope) and the `RequireAdmin` instance; no drift found.

## Verified holds

- Bearer attachment `:193-196`; TLS by scheme `:236-242`; route derivation `:269-270`; admin
  wrappers `:346-422` against `Account/Admin/Api.hs:19`, `Session/Admin/Api.hs:19-23`,
  `Authorization/Api.hs:13-15`, `Audit/Api.hs:13`.
- servant-client-core `redactSensitiveHeader ("Authorization", _) = ("Authorization", "<REDACTED>")`.

## Not examined

The wrappers' request bodies against the DTOs they serialize (the OpenAPI document is generated
from the same types, so drift would surface in the openapi test); any consumer outside this
repository.
