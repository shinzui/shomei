---
id: 40
slug: api-v1-prefix-and-universal-problem-details-error-envelope
title: "API v1 Prefix and Universal Problem-Details Error Envelope"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# API v1 Prefix and Universal Problem-Details Error Envelope

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-3** of MasterPlan 7
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`). It has no
dependencies and can run in parallel with plan 38. It is deliberately scheduled in Phase 1
because it is **the breaking-change window**: MasterPlan 7's later plans (the admin API,
OAuth2 client-credentials, OIDC, token exchange, TOTP) must be *born under* the `/v1`
prefix and the error envelope this plan establishes, not migrated afterward. This plan
owns two MasterPlan-7 integration points: the **versioning boundary** (application routes
under `/v1`; `/.well-known/*`, future `/oauth/*`, `/health`, `/ready`, `/metrics` stay
unversioned) and the **error envelope** (every failure except the future RFC 6749 OAuth2
token-endpoint errors, which EP-4 owns).


## Purpose / Big Picture

Shōmei (a Haskell auth service: `effectful` core, hasql/PostgreSQL, Servant `NamedRoutes`
API on Warp) has an interop problem on the two surfaces every polyglot client touches
first: **URLs** and **errors**.

**No versioning.** Every route lives at its bare path (`/auth/login`,
`/admin/audit/events`); there is no `/v1` anywhere in
`shomei-servant/src/Shomei/Servant/API.hs`, and the committed OpenAPI spec
(`docs/api/openapi.json`) declares `servers: [http://localhost:8080]`. The first breaking
change — and MasterPlan 7 is full of candidates — has nowhere to go.

**A leaky error contract.** `docs/user/api.md` promises every error is
`{"error":"<code>","message":"<text>"}`, and the central mapping
(`authErrorToServerError` in `shomei-servant/src/Shomei/Servant/Error.hs`, ~30 codes)
honors it — but many paths bypass it: the token-verifying `authHandler`
(`shomei-servant/src/Shomei/Servant/Auth.hs` ~80–83) throws `401` with **plain-text**
bodies `"missing token"`/`"invalid token"` and no `Content-Type`; the
`requireRole`/`requireScope` guards throw plain `"missing required role"`
(`Authz.hs` ~44/50); `resolvePrincipal` throws plain `"loginId or email required"`
(`Handlers.hs` ~174); `meH`/`sessionH` throw plain-text 404s (~284/291); the hand-rolled
`err429` has an **empty** body (`Error.hs` ~32); the WAI rate-limit middleware
(`shomei-server/src/Shomei/Server/Middleware/RateLimit.hs` ~85) emits its own ad-hoc
`{"error":"too_many_requests"}` without a `message`; and Servant's built-in 400 (malformed
JSON body), 404 (no route), and 405 are plain text. A client that switches on the error
code breaks on **the single most common failure in any deployment: an expired bearer
token.**

**An error-blind spec.** `docs/api/openapi.json` documents almost no error responses (only
Servant's automatic `400 Invalid body` / `404` route-level entries), has no error schema
in `components`, so generated clients see none of the ~30-code error surface. It also has
spec bugs: 202/204 responses declare `content: {"application/json;charset=utf-8": {}}`
(invalid for 204), every response description is `""`, and `requestBody.required` is never
set.

After this plan:

- Application routes live under **`/v1`** (`/v1/auth/login`, `/v1/admin/audit/events`);
  `/.well-known/jwks.json`, `/health`, `/ready`, `/metrics`, the new `/openapi.json`, and
  the future `/oauth/*` remain unversioned root paths. Old paths are **gone** (404) — see
  the Decision Log.
- **Every** error, from every layer (handlers, workflows, the auth handler, authz
  combinators/guards, Servant's own 400/404/405, the rate-limit middleware), is an RFC
  7807 problem-details document, `Content-Type: application/problem+json`:

  ```json
  {"type":"about:blank","title":"Token is invalid","status":401,"code":"token_invalid"}
  ```

  with the existing stable code strings carried in the `code` extension member. 401s carry
  `WWW-Authenticate: Bearer`; 429s carry `Retry-After`.
- The OpenAPI spec gains a `Problem` component schema and **per-route error responses
  derived from the same catalog the runtime mapping uses** (they cannot drift), plus the
  nit fixes above; the server itself serves `GET /openapi.json`.
- Status-code corrections: signup `200 → 201`; `verify-email/confirm` and
  `password-reset/confirm` `202 → 200` (their work completes synchronously); logout is
  idempotent (`204` even when the session is already gone, instead of `404`). The JWKS
  response gains `Cache-Control`.

Observable outcome: `curl -i http://localhost:8080/v1/auth/me` without a token returns
`401`, `Content-Type: application/problem+json`, `WWW-Authenticate: Bearer`, and a body
whose `code` is machine-switchable — and the same request against `/auth/me` is a 404,
proving the boundary moved. Full transcripts in Validation and Acceptance.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — The universal problem-details envelope: **done 2026-07-09**

- [x] Rebuild `shomei-servant/src/Shomei/Servant/Error.hs` around `ProblemSpec` constants + `toProblemError` (adds `application/problem+json`, `WWW-Authenticate: Bearer` on 401, `Retry-After: 60` on 429); `authErrorToServerError` is now a pure dispatch over the catalog. `problemCatalog` exports all 41 specs; `problemBody`/`problemHeaders` are exported for the WAI layer, which has no `ServerError` to throw.
- [x] Convert the bypass sites: `authHandler`'s two 401s and `csrfRejected` (`Auth.hs`); the `requireRole`/`requireScope` guards **and** EP-1's `HasServer` combinator bodies, now sharing one `missingRole`/`missingScope` value (`Authz.hs`); `resolvePrincipal`, `refreshH`'s "refreshToken required", `serviceTokenH`'s two 400s, `meH`/`sessionH` 404s, the three `parseId` ceremony 400s, and `auditEventsH.badRequest` (`Handlers.hs`). Each ad-hoc message became a `detail`, keeping `title` stable for the OpenAPI catalog. `readyH`'s 503 left alone (Decision Log).
- [x] Add Servant `ErrorFormatters` to the `Context` in `Boot.hs` and in the servant test. **`ErrorFormatters` cannot reach 405** — see Surprises; `Shomei.Servant.Middleware.problemMiddleware` (new module) converts that one, and wraps the app in both `Boot.application` and the test's `app`.
- [x] Convert the WAI rate-limiter 429 body (`RateLimit.hs`) to the same document + `Retry-After`, sharing the `pcTooManyRequests` catalog constant through `problemResponse`.
- [x] Servant test `scenarioProblemEnvelope` asserts status, `Content-Type`, `code`, `type`, `title`, and the `status` member for **all seven** layers: missing token (+`WWW-Authenticate: Bearer`), invalid token, missing role (and *no* `WWW-Authenticate` — the credential was fine), a handler's own 400 with its `detail`, Servant's body-parse 400 with the parse message as `detail`, an unknown route 404, and a method-mismatch 405.
- [x] Updated the two existing assertions that read `.error` (`email_not_verified`, `csrf_rejected`) to read `.code`.
- [x] `grep -rn 'errBody = "' shomei-servant/src shomei-server/src` finds only the two base `err422`/`err429` constructors, which are never sent as-is. `cabal test all` green (12 suites).

Milestone 2 — The `/v1` boundary: **done 2026-07-09**

- [x] Split `ShomeiAPI`: new root record `ShomeiRoutes` (`v1`, `jwks`, `health`, `ready`) in `API.hs`; `jwks`/`health`/`ready` removed from `ShomeiAPI`; `AppAPI` example updated. The JWKS route gained its `Cache-Control` `Headers` here, as planned.
- [x] Handlers: `shomeiRoutes :: Env -> ShomeiRoutes (AsServerT Handler)`; `Boot.application` serves the root record.
- [x] `shomei-client`: root `shomeiRoutesClient = genericClient`, and `shomeiClient = API.v1 shomeiRoutesClient` — plain selector application, no `(//)` needed. Every curated wrapper is unchanged.
- [x] Examples updated: `examples/embedded-servant-app` (mounts `NamedRoutes ShomeiRoutes`; `www/passkeys.js` fetch paths), `examples/microservice-auth-stack` (`process-compose.yaml` curl hints; the JWKS URL is unchanged).
- [x] **Three path-literal sites the plan did not name** — all found by grep, all silent failures if missed: the rate limiter's `throttledPath` list (`RateLimit.hs`), the refresh cookie's `Path` (`Cookie.hs`), and the metrics middleware's login/signup/refresh counters (`Metrics.hs`). Plus `Notify.hs`'s verification/reset links. See Surprises.
- [x] All servant/e2e tests moved to `/v1/...`; new `scenarioVersionBoundary` asserts old paths → 404 problem doc, `/v1/auth/me` → 401 (so it routes), probes and JWKS at the root with `Cache-Control`, and `/v1/health`/`/v1/.well-known/jwks.json` → 404. New `testThrottledPathsAreVersioned` pins the limiter's list.
- [x] `OpenApi.hs` generates from `ShomeiRoutes`; `servers` gained a description. `camel` drops the leading `v1` segment so `operationId`s are unchanged by the move (Decision Log). Spec regenerated: 24 paths, byte-for-byte reproducible. `cabal test all` green (11 suites, exit 0).

Milestone 3 — Status-code corrections: **done 2026-07-09**

- [x] Signup → `Verb 'POST 201`; `verify-email/confirm` and `password-reset/confirm` → `Verb 'POST 200`; `logoutH` intercepts exactly `SessionNotFound` → 204 (via `runPort`, not `runAuth`). The two lifecycle *request* endpoints stay 202.
- [x] `Metrics.recordRequest` follows signup to 201 — a fourth instance of the path/status-literal hazard from M2. Verified live: `shomei_tokens_issued_total` reads 2 after a signup + login (it would read 1 if the table had not been updated).
- [x] Tests: nine signup assertions → 201; three confirm assertions → 200; new `scenarioStatusCodes` (servant) covers 201 + still-202 + 204/204; `E2ESpec` gains a double-logout. Spec regenerated (signup `201`, confirms `200`).
- [x] Wire-compat notes for the CHANGELOG (written up in M5):
  - `POST /v1/auth/signup` `200 → 201`. Affects any client that compares `status == 200`. Change to `status < 300`, or to `201`. The body is unchanged.
  - `POST /v1/auth/verify-email/confirm` and `POST /v1/auth/password-reset/confirm` `202 → 200`. Both always completed synchronously; the `202` advertised pending work that never existed. Clients that accept 2xx are unaffected.
  - `POST /v1/auth/logout` on an already-revoked session `404 session_not_found → 204`. A client that treated the 404 as "already logged out, fine" can drop that branch; one that treated it as an error stops seeing the error. Logout is now idempotent.
  - Note for `sessionCheckMode = VerifyTokenAndSession` deployments: the second logout is a `401` from the auth handler (the token no longer verifies against the revoked session), not a `204`. Idempotence there means "does not fail with 404", and the credential is genuinely dead.

Milestone 4 — OpenAPI truth: **done 2026-07-09**

- [x] `Problem` component schema + per-route error responses generated from the `ProblemSpec` catalog. `Error.hs` now exports every `pc*` constant; `OpenApi.hs` holds `routeErrors :: [(FilePath, Method, [ProblemSpec])]` plus `baselineSpecs`, which reads 401s off any operation carrying `security` and a 400 `body_parse_error` off any operation with a request body — so a new authenticated route documents its 401s the day it is added. 51 problem responses across 25 paths.
- [x] The per-response code list rides in `properties.code.enum` (standard JSON Schema, generator-friendly) rather than an `x-error-codes` extension — openapi-hs's `Response` has no extensions field. See Surprises.
- [x] Drift guard (`test-openapi/Main.hs`): every documented code exists in `problemCatalog`; every documented (status, code) pair exists in the catalog; every problem response lists at least one code; every bearer operation documents a 401; and (added in M5) the real runtime document of every catalog entry validates against the *published* `Problem` schema. Plus hygiene: no 204 carries content, no description is empty, every request body is required. **Verified both guards can fail**: documenting each response one status off produced 2 failures; adding an undeclared member to `problemBody` failed the schema check on all 82 cases.
- [x] Spec hygiene passes: `withSpecHygiene` drops `content` from 204s and from the `NoContent` artifacts at 200/202, fills every empty response `description`, and sets `requestBody.required: true`.
- [x] `GET /openapi.json` served from the root record (`openApiValue`, a `Value` CAF). Path count 25. Verified live: the served document is byte-equivalent to the committed `docs/api/openapi.json`.
- [x] Spec regenerated and committed; `cabal run shomei-openapi` reproduces it exactly.

Milestone 5 — Docs and closure: **done 2026-07-09**

- [x] `docs/user/api.md` rewritten: new "Versioning" and "Errors" sections (the problem document, the member table, the two exemptions), all paths versioned, the three status-code changes in their endpoint sections, logout's idempotence, `GET /openapi.json` and the JWKS `Cache-Control` documented.
- [x] Swept `security.md`, `passkeys.md`, `notifications.md`, `service-tokens.md`, `deployment.md` (paths + the two `{"error":…}` samples). `openapi-client-generation.md` rewritten: two ways to fetch the spec, the `v1`-stripped `operationId` rule, and an "Errors in the generated client" section. It also **claimed a quirk that M4 fixed** — "`POST /auth/logout` shows an empty `application/json` media type on its `204`" — verified against the regenerated spec and removed; the one-`Set-Cookie` limitation is real and stays.
- [x] `docs/user/initial-spec.md` deliberately left alone: `docs/user/index.md` frames it as the original specification under "Historical Reference". Rewriting its paths would falsify the record.
- [x] CHANGELOG "Breaking (pre-1.0 window)" block: the `/v1` move with its unversioned exceptions and the two path literals that moved with it (refresh cookie `Path`, notifier links), the envelope change with a before/after pair, a status-code table with per-row migration advice, plus an "Added" block for `/openapi.json`, the error documentation, the spec fixes, and JWKS caching.
- [x] Live transcript recorded below; every line of the plan's Validation section reproduces exactly.
- [x] MasterPlan 7 registry and Progress updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-07-09 — Servant's `ErrorFormatters` cannot format a 405.** The plan states "Servant
supports replacing these [400/404/405] via `ErrorFormatters`". It supports exactly four hooks,
and 405 is not among them:

```haskell
data ErrorFormatters = ErrorFormatters
  { bodyParserErrorFormatter :: ErrorFormatter
  , urlParseErrorFormatter :: ErrorFormatter
  , headerParseErrorFormatter :: ErrorFormatter
  , notFoundErrorFormatter :: NotFoundErrorFormatter
  }
```

A method mismatch is raised as a hardcoded, empty-bodied `err405` from `methodCheck` in
`Servant.Server.Internal`, below every hook:

```haskell
methodCheck method request
  | allowedMethod method request = pure ()
  | otherwise = delayedFail err405
```

Resolved with a new module `shomei-servant/src/Shomei/Servant/Middleware.hs`: `problemMiddleware`
is a WAI layer that rewrites any 405 response into the problem document. Shōmei never returns 405
from a handler, so the rewrite is unconditional and safe. It is applied in `Boot.application`
**and** in the servant test's `app`, so the 405 assertion exercises the real stack rather than a
test-only wrapper. The module also exports `problemResponse`, which the rate-limit middleware
uses — it too answers before Servant routes anything and has no `ServerError` to throw.

**2026-07-09 — the bypass-site list was incomplete.** Two sites the plan's Context section does
not name also emitted the old shape, and `grep -rn 'errBody' shomei-servant/src shomei-server/src`
found them: `Shomei.Servant.Auth.csrfRejected` (a hand-written
`{"error":"csrf_rejected","message":…}` JSON literal) and `refreshH`'s plain-text
`"refreshToken required"` 400. Both are converted. The lesson: run the grep, do not trust the
list — which is exactly what the plan's Concrete Steps tell you to do.

**2026-07-09 (M2) — moving the routes silently disarmed the rate limiter, and nothing failed.**
`Shomei.Server.Middleware.RateLimit.throttledPath` matches `pathInfo` against a literal list
(`["auth","login"]`, …). It answers *before* Servant routes anything, so it cannot be derived
from the route type; after the move it matched nothing, and every login, signup, and
password-reset request sailed through unthrottled. The whole suite stayed green — brute-force
protection has no positive test that a *request* is refused, only unit tests of `takeToken`.
Fixed by versioning the list, exporting `throttledPath`, and adding `testThrottledPathsAreVersioned`.
Confirmed live: 90 parallel `POST /v1/auth/login` → 32×401, 58×429 with `Retry-After: 60`.

Two more path literals in the same class, neither named by this plan's Context section, both
found only by grepping for the string rather than trusting the list:

- `Shomei.Servant.Cookie` scopes the refresh cookie to `Path=/auth/refresh`. Unversioned, the
  browser would never send it to `/v1/auth/refresh` and cookie-mode refresh would break for
  every browser client while every bearer-mode test passed. Now a named `refreshCookiePath`
  constant.
- `Shomei.Server.Observability.Metrics.recordRequest` matches `("POST","/auth/login",200)` to
  drive `shomei_logins_succeeded_total` / `shomei_tokens_issued_total`. Unversioned, the
  domain counters would flatline at zero. Verified live after the fix: a signup + login moves
  them to 2 and 1.
- `Shomei.Notify` builds the `publicBaseUrl <> "/auth/verify-email/confirm"` link that lands in
  a user's inbox. Verified live: the log line now reads `link=…/v1/auth/verify-email/confirm?token=…`.

**The lesson generalizes to every later plan in MasterPlan 7 that adds or moves a route.** A
Servant route type is not the only place a path is written down; the WAI layer (which runs
before routing), the cookie scope, and the metrics vocabulary all hard-code strings that no
type checks. `grep -rn '"/auth' --include='*.hs'` before declaring a path move done.

**2026-07-09 (M4) — `x-error-codes` is impossible: openapi-hs's `Response` has no extensions
field.** The plan preferred a vendor extension over parsing descriptions. `Data.OpenApi.Internal`'s
`Response` is `{description, content, headers, links}` — no `_responseExtensions`, so there is
nowhere to hang `x-`anything. The replacement is better than the original idea: each problem
response inlines `{"allOf": [{"$ref": "…/Problem"}], "properties": {"code": {"enum": [...]}}}`.
That is standard JSON Schema, so it needs no special support in the drift test *and* a client
generator can turn the enum into a sum type — which a vendor extension would never have given us.

**2026-07-09 (M4) — the checked-out `openapi-hs` is not the one that compiles.** `cabal.project`
pins openapi-hs to git tag `89e9ed07`; `mori` points at `/Users/shinzui/Keikaku/bokuno/openapi-hs-project`,
which is *ahead* of it. The working tree has `data HttpStatusCode = StatusCode Int | StatusRange …`;
the pinned tag has `type HttpStatusCode = Int`. Reading the working tree produced code that failed
to compile against the pin. The pinned source is unpacked at
`dist-newstyle/src/openapi-hs-<hash>/` — read *that* when a `source-repository-package` is
involved. **Applies to any later plan touching the spec** (EP-2, EP-4, EP-5, EP-7).

**2026-07-09 (M4) — a malformed `Capture` is a 400, not the 404 servant-openapi documents.**
Servant's `Capture` runs `urlParseErrorFormatter` on a parse failure, which this codebase points at
`pcBadRequest`. The generated document claimed a 404 for `DELETE /v1/auth/passkeys/{passkeyId}`.
Verified against the running server: `DELETE …/passkeys/not-a-typeid` → `400 bad_request` with
`detail: "Invalid UUID part!"`, while a well-formed but absent id → `404 passkey_not_found`. Both
are now documented. The lesson is the milestone's whole point: the spec was asserting something
nobody had ever asked the server.

**2026-07-09 (M3) — logout's idempotence depends on `sessionCheckMode`, and the default is what
makes the test meaningful.** With `VerifyTokenOnly` (the default) a revoked session's access
token still verifies, so a second `POST /v1/auth/logout` reaches `logoutH`, hits `SessionNotFound`,
and now answers `204`. With `VerifyTokenAndSession` the auth handler rejects the token first and
the caller sees `401` — never the old `404`. Both are the intended contract ("retrying a logout
does not fail"), but a deployment reading the CHANGELOG needs to know which it gets. The servant
suite runs the default, so `scenarioStatusCodes` exercises the handler branch.

**2026-07-09 (M3) — the metrics counter table was a fourth path/status literal.**
`Metrics.recordRequest` matches `("POST", "/v1/auth/signup", 200)`. Moving signup to `201`
silently zeroed `shomei_tokens_issued_total` for every signup, with the whole suite green — the
same failure shape as M2's rate limiter, now keyed on status rather than path. Caught only by
reading the table while changing the status. Live check after the fix: signup + login leaves the
counter at 2, not 1. **Any later plan that changes a route's success status must grep this
table** — EP-4's `/oauth/token` will want its own entry.

**2026-07-09 (M2) — `operationId`s are stable across the move because `camel` drops the `v1`
segment.** `withOperationIds` derives ids from the path, so `/v1/auth/me` would have become
`getV1AuthMe`, renaming every method in every generated client — and renaming them all again at
`/v2`. Dropping the version segment keeps `getAuthMe`, so the committed spec's diff is paths and
the JWKS `Cache-Control` header only. The version still reaches clients through `paths`, which is
where it belongs.

**2026-07-09 (M2) — the client nests with plain selector application.** The plan hedged between
`API.v1 shomeiRoutesClient` and servant's `(//)` helper. The selector works directly:
`Client m (NamedRoutes api)` reduces to `api (AsClientT m)`, so the `v1` field of the root client
*is* the `ShomeiAPI` client record. `shomeiClient = API.v1 shomeiRoutesClient` and no curated
wrapper changed. `embedded-servant-app-test`, which drives signup/login through the real typed
client, is the end-to-end proof that the derived paths carry `/v1`.

**2026-07-09 — `RoleNotDefined`'s message was dynamic; it is now a `title` + `detail`.** The
pre-7807 mapping produced `"Role not defined: " <> r`, folding a request-specific value into the
human message. A `ProblemSpec` title must be a constant, because the OpenAPI document quotes it.
The role name moved to the `detail` member, which is what `detail` is for (RFC 7807 §3.1: "a
human-readable explanation specific to this occurrence"). Same for every ad-hoc handler message
(`"loginId or email required"`, `"invalid ceremonyId"`, the audit query parse errors): they are
now `bad_request` + `detail`, so the catalog stays finite and the specific reason survives.


## Decision Log

Record every decision made while working on the plan.

- Decision: The envelope is **RFC 7807** (`application/problem+json`) with members
  `type` (always `"about:blank"` for now), `title` (the stable human text), `status`
  (mirrors the HTTP code), and a `code` extension member carrying the **existing** error
  strings (`token_invalid`, `invalid_login`, …) unchanged. An optional `detail` member
  carries request-specific text where a handler has it (e.g. the audit query parser's
  "invalid user parameter…"). The bespoke `{"error","message"}` shape is dropped, not
  dual-emitted.
  Rationale: 7807 is what stock middleware, API gateways, and generated clients already
  understand — the whole point of the Interop Wave — and it costs nothing beyond the
  bespoke shape. Keeping the old keys alongside would perpetuate two contracts forever.
  Shōmei is pre-1.0 and unreleased with few consumers; this plan IS the declared breaking
  window, and every existing `code` string survives verbatim so client switch-logic ports
  by renaming one field. `type` stays `about:blank` because we host no error-documentation
  URLs; `code` is the machine key. Re-evaluate `type` URIs if docs ever get stable anchors.
  Date: 2026-07-07

- Decision: Application routes move under `/v1`; `/.well-known/*`, `/health`, `/ready`,
  `/metrics` (a WAI middleware, not a Servant route), `/openapi.json`, and the future
  `/oauth/*` remain unversioned root paths. This restates and implements the MasterPlan 7
  decision of 2026-07-07: OAuth2/OIDC tooling auto-configures from *conventional*
  well-known locations, and infrastructure probes are deployment contracts, not API
  surface.
  Date: 2026-07-07

- Decision: Old (unprefixed) paths are **removed immediately** — a request to
  `/auth/login` is a plain 404 problem document. No `308` redirect period, no `410`.
  Rationale: Shōmei is pre-1.0 and has never cut a tagged release (`CHANGELOG.md`: "in
  Unreleased"); a redirect layer would have to answer hard questions (redirecting POSTs
  with bodies, auth headers across redirects, how long to keep it) for consumers that are
  all in-tree or first-party today. The CHANGELOG carries a loud migration note instead.
  Date: 2026-07-07

- Decision: `GET /openapi.json` is served at the **root** (unversioned), reflecting
  whatever the binary was built with; `GET /health` and `GET /ready` keep their existing
  structured JSON bodies (`HealthResponse`/`ReadyResponse`) — the 503 not-ready body is a
  probe status document, not an error, and is exempt from the problem envelope.
  Rationale: the spec describes the whole server including future non-v1 surface, so it
  sits beside `/.well-known`; probes are consumed by load balancers configured against the
  current shape, and 7807 would carry less information there, not more.
  Date: 2026-07-07

- Decision: Status-code corrections in this window: signup `200 → 201 Created`;
  `POST /v1/auth/verify-email/confirm` and `POST /v1/auth/password-reset/confirm`
  `202 → 200` (the verification/reset completes synchronously inside the request — 202
  falsely advertises pending work); `POST /v1/auth/logout` returns `204` even when the
  session is already gone (was `404 session_not_found`). The two lifecycle *request*
  endpoints (`verify-email/request`, `password-reset/request`) stay `202` — delivery via
  the `Notifier` genuinely happens later, and the anti-enumeration contract depends on an
  unconditional response.
  Rationale: logout-idempotence: retrying a logout (network blip, double-tap) should
  succeed; "you are already logged out" is success. Each change gets a wire-compat note in
  the CHANGELOG; all land inside the same breaking window so clients migrate once.
  Date: 2026-07-07

- Decision: JWKS `Cache-Control` is `public, max-age=300`.
  Rationale: Shōmei's key rotation is staged (`pending → active → retired → revoked`,
  `docs/user/security.md`): a retiring key stays *trusted* for verification long past five
  minutes, so a 5-minute-stale JWKS never rejects a valid token; five minutes still bounds
  how long a *revoked* key's public half lingers in caches. Verifiers that follow HTTP
  caching stop hammering the endpoint.
  Date: 2026-07-07

- Decision: The OpenAPI error documentation and the runtime mapping share **one source**:
  named `ProblemSpec` constants in `Shomei.Servant.Error`. `authErrorToServerError`
  renders them at runtime; `OpenApi.hs` renders the same constants into
  `components.schemas.Problem` + per-operation response entries via an explicit
  route→codes table. Statuses and titles therefore cannot drift; the hand-maintained part
  (which codes apply to which route) is guarded by a conformance test asserting every
  documented code exists in the catalog and every operation documents at least the generic
  set for its auth class.
  Rationale: full automation (deriving per-route codes from handler code) is not possible
  without effect-level tracking; sharing the constants gets the "cannot drift" property
  where drift is dangerous (status/title/shape) and cheap review where it is not (the
  per-route lists). This follows the spec-enrichment precedent of `withOperationIds` in
  `shomei-servant/src/Shomei/Servant/OpenApi.hs`.
  Date: 2026-07-07

- Decision: Servant's un-formattable `405` is converted by a WAI middleware
  (`Shomei.Servant.Middleware.problemMiddleware`), applied in `Boot.application` **and** in the
  servant test's `app`, rather than left as a bare empty-bodied response.
  Rationale: `ErrorFormatters` has no 405 hook (Surprises), and "every error from every layer"
  is this plan's headline promise — a 405 with no body and no `Content-Type` is precisely the
  class of bug the plan exists to remove. Wrapping the app in both places (rather than only in
  the server's middleware stack) keeps the test honest: it asserts against the same composition
  the server serves. The rewrite is unconditional because Shōmei never raises 405 from a handler.
  Date: 2026-07-09

- Decision: Request-specific text moves from `title` to the `detail` member; `title` stays a
  per-code constant.
  Rationale: the OpenAPI document quotes titles, so a title that varies per request cannot be
  documented. RFC 7807 §3.1 designates `detail` for "a human-readable explanation specific to
  this occurrence", which is exactly `RoleNotDefined`'s role name, Servant's body-parse message,
  and the audit query parser's complaint. The catalog therefore stays finite and the specific
  reason still reaches the client.
  Date: 2026-07-09

- Decision: The `token_invalid` code appears three times in `problemCatalog` (an invalid access
  token, an invalid refresh token, and the auth handler's rejection), with different titles.
  Rationale: the code is what clients switch on, and to a client those three are the same
  condition — "your credential is not usable, re-authenticate". The titles differ because the
  causes do, and a human reading a log wants to know which. The drift-guard test (M4) must
  therefore assert code *membership*, not uniqueness.
  Date: 2026-07-09

- Decision: The per-response error-code list is expressed as `properties.code.enum` inside an
  `allOf: [$ref Problem]` schema, not as an `x-error-codes` vendor extension.
  Rationale: openapi-hs's `Response` has no extensions field, so the extension was not available
  (Surprises). The enum is strictly better: it is standard JSON Schema, a generated client can
  narrow `code` to a sum type, and the drift-guard test reads it without parsing prose.
  Date: 2026-07-09

- Decision: `baselineSpecs` derives an operation's 401s from its `security` and its
  `body_parse_error` from its request body, reading the *generated document* rather than
  restating them per route in `routeErrors`.
  Rationale: those two failures follow from an operation's shape, not from its handler. Deriving
  them means a route added by EP-2/EP-4/EP-5/EP-7 documents its 401s on the day it is written,
  with no table entry, and the conformance test's "every bearer operation documents a 401" can
  never be satisfied by forgetting.
  Date: 2026-07-09

- Decision: The two flaky `SupervisorSpec` timing tests are fixed here rather than left as a
  known flake, in a separate commit outside EP-3's milestones.
  Rationale: EP-3's acceptance criterion is a green `cabal test all`, and those tests failed it
  intermittently — confirmed pre-existing by reproducing the failure on the EP-3 M3 commit. Both
  asserted "N cycles within a fixed 50 ms window", which twelve parallel suites starve. The
  rewrite waits on a condition, and the backoff test now *measures* the reset (≈50 ms vs ≈400 ms)
  instead of inferring it from a call count — strictly stronger, and confirmed to fail when the
  reset is deleted from `Supervisor.hs`. Kept out of the milestone commits because it is not
  EP-3's subject matter.
  Date: 2026-07-09

- Decision: `withOperationIds` drops the leading `v1` path segment, so every `operationId` is
  unchanged by the move (`getAuthMe`, not `getV1AuthMe`).
  Rationale: an `operationId` names what an operation *does*; generated clients turn it into a
  method name. Folding the version in renames every method the day routes move under `/v1`, and
  renames them all again at `/v2` — churn that carries no information. The version reaches
  clients through the `paths` keys, which is the part of the document that is *about* URLs.
  Date: 2026-07-09

- Decision: Three path literals outside the Servant route types move with the routes: the rate
  limiter's `throttledPath` list, the refresh cookie's `Path` attribute, and the metrics
  middleware's per-route counter table. The rate limiter's list gains a test.
  Rationale: each is a string the type system cannot check, and each fails *silently* — an
  unthrottled login endpoint, a refresh cookie the browser never sends, domain counters stuck at
  zero. The limiter's is the dangerous one (it is a security control that reports success while
  doing nothing), so it gets `testThrottledPathsAreVersioned` pinning both directions.
  Date: 2026-07-09

- Decision: `Shomei.Servant.Cookie` keeps hard-coding `/v1/auth/refresh` rather than deriving it
  from the route type; a host that mounts the bare `ShomeiAPI` record at its own prefix is
  documented as breaking cookie-mode refresh.
  Rationale: deriving the served path of one field of a `NamedRoutes` record needs a type-level
  path reifier that Servant does not export, and the embedded example — the only in-tree host —
  mounts `ShomeiRoutes` unprefixed, where the constant is correct. The trade is a named constant
  and a haddock warning against machinery no caller has asked for.
  Date: 2026-07-09

- Decision: Future `/oauth/*` token-endpoint errors (RFC 6749 §5.2 —
  `{"error":"invalid_grant",…}`) are **exempt** from the problem envelope; they belong to
  MasterPlan 7 EP-4. This plan's envelope helper and docs state the boundary explicitly.
  Rationale: RFC 6749 fixes the token-endpoint error shape; OAuth2 clients would break on
  7807 there. Restated from MasterPlan 7 Integration Points.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete, 2026-07-09.** All five milestones landed; `cabal test all` is green (12 suites);
`cabal run shomei-openapi` reproduces the committed spec byte-for-byte.

Against the original purpose — the two surfaces every polyglot client touches first:

- **URLs.** Application routes live under `/v1`; `/.well-known/jwks.json`, `/openapi.json`,
  `/health`, `/ready` (and `/metrics`, a middleware) stay at the root. Old paths are 404s.
- **Errors.** All 41 catalog entries, from all seven layers, are `application/problem+json` with a
  stable `code`. The specific failure the Purpose section named — "a client that switches on the
  error code breaks on the single most common failure in any deployment: an expired bearer
  token" — is fixed: that request now returns `{"code":"token_invalid",…}` with
  `WWW-Authenticate: Bearer`, not a plain-text `"invalid token"`.
- **The spec.** 25 paths, a `Problem` schema, 51 error responses whose `code` enums are generated
  from the runtime catalog, and a conformance test that fails when they drift (verified by
  injecting drift).

The live transcript:

```text
$ curl -si localhost:8080/v1/auth/me | sed -n '1p;/^www-auth/Ip;/^content-type/Ip;$p'
HTTP/1.1 401 Unauthorized
Content-Type: application/problem+json
WWW-Authenticate: Bearer
{"code":"missing_token","status":401,"title":"Authentication required","type":"about:blank"}

$ curl -si -XPOST localhost:8080/v1/auth/signup -H 'Content-Type: application/json' -d '{'
HTTP/1.1 400 Bad Request
Content-Type: application/problem+json
{"code":"body_parse_error","detail":"Unexpected end-of-input, expecting record key literal or }",
 "status":400,"title":"Request body could not be parsed","type":"about:blank"}

$ curl -s -o /dev/null -w '%{http_code}\n' -XPOST localhost:8080/auth/login -d '{}'   # old path
404
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/health                       # unversioned
200
$ curl -si localhost:8080/.well-known/jwks.json | grep -i cache-control
Cache-Control: public, max-age=300

$ curl -s -o /dev/null -w '%{http_code}\n' -XPOST localhost:8080/v1/auth/signup …      # created
201
$ curl -s -o /dev/null -w '%{http_code}\n' -XPOST localhost:8080/v1/auth/logout -H "Authorization: Bearer $TOK"
204
$ curl -s -o /dev/null -w '%{http_code}\n' -XPOST localhost:8080/v1/auth/logout -H "Authorization: Bearer $TOK"
204                                                                                    # idempotent

$ curl -s localhost:8080/openapi.json | jq '.openapi, (.paths|keys|length), .components.schemas.Problem.required'
"3.1.0"
25
["type","title","status","code"]
```

Two things this plan got wrong on paper, and one thing it got right:

**Wrong: the bypass-site list, twice.** M1 found two sites the Context section did not name
(`csrfRejected`, `refreshH`'s 400). M2 found three more of a different kind — the rate limiter's
path list, the refresh cookie's `Path`, the metrics counter table — none of which the plan
imagined, because none of them is a Servant route type. **A route's path is written down in four
places, and three of them fail silently.** M3 then found a fourth instance of the same shape when
signup's status moved and the metrics counters flatlined. The generalization, now in the MasterPlan
for EP-2/EP-4/EP-5/EP-7: the WAI layer runs *before* routing and cannot be derived from the route
type; grep for the string.

**Wrong: `x-error-codes`.** openapi-hs's `Response` has no extensions field. The forced
alternative — an `allOf: [$ref Problem]` schema with `properties.code.enum` — turned out better
than the plan's preference: standard JSON Schema, so a client generator can narrow `code` to a sum
type, and the drift test reads it without parsing prose.

**Right: doing the breaking window first.** M2 and M3 both changed wire behavior, and both were
one commit each covering routes + handlers + client + examples + tests + regenerated spec. The
conformance suite's path count and the byte-for-byte spec check made a half-done milestone
impossible to commit by accident. Every route EP-2/EP-4/EP-5/EP-7 adds is now born under `/v1`
with the envelope, and `baselineSpecs` documents its 401s without anyone remembering to.

**Gap: `role_not_defined` (422) and `internal` (500) are in the catalog but on no route's
documented error list.** `role_not_defined` is raised only by the `shomei-admin` CLI path, and
500s are documented nowhere per-route by design. The drift guard checks "every documented code
exists in the catalog", not the converse — deliberately, since the catalog is the superset.

**Closed during M5: the `Problem` schema is validated against `problemBody`'s real output.**
Writing this retrospective surfaced the hole — the published schema and the bytes the server
writes are built by different code — so the conformance suite now decodes
`components.schemas.Problem` back out of the serialized document (the artifact a generator reads)
and runs `validateJSON` over the actual document of all 41 catalog entries, with and without a
`detail`. Confirmed it bites: adding an undeclared member to `problemBody` fails 82 cases with
"property \"undeclared\" is found in JSON value, but it is not mentioned in Swagger schema".


## Context and Orientation

This section assumes no prior repository knowledge. Everything was verified against the
working tree on 2026-07-07. If plan 38 (roles/claims, enforcing authz combinators) has
already landed, its combinator error bodies are additional sweep targets — noted inline.

### The repository at a glance

Shōmei is a multi-package Cabal project (build inside `nix develop`: `cabal build all`,
`cabal test all`; dev database via `just create-database`). Every module imports the
custom `Shomei.Prelude`. Packages touched here:

- `shomei-servant` — the HTTP surface. `src/Shomei/Servant/API.hs` defines
  `data ShomeiAPI mode` (a Servant **NamedRoutes** record: one field per route, e.g.
  `signup :: mode :- "auth" :> "signup" :> ReqBody '[JSON] SignupRequest :> Post '[JSON]
  SignupResponse`) plus `shomeiAPI :: Proxy (NamedRoutes ShomeiAPI)` and an `AppAPI`
  embeddability example. `Handlers.hs` assembles `shomeiServer :: Env -> ShomeiAPI
  (AsServerT Handler)`. `Auth.hs` defines `Authenticated = AuthProtect "shomei-jwt"` and
  `authHandler` (the token verifier registered in the Servant `Context`). `Authz.hs` holds
  the role/scope guards. `Error.hs` holds `authErrorToServerError`. `DTO.hs` the JSON
  types. `OpenApi.hs` derives the OpenAPI 3.1 document. `Seam.hs` bridges handlers onto
  the `effectful` port stack (`runAuth` maps a workflow's `Left AuthError` through
  `authErrorToServerError`).
- `shomei-server` — Warp boot (`src/Shomei/Server/Boot.hs`: `application`,
  `authContext senv = authHandler senv.verifier :. EmptyContext`, middleware stack), the
  rate-limit middleware (`src/Shomei/Server/Middleware/RateLimit.hs`), metrics middleware
  (serves `GET /metrics` before Servant sees it), and the `shomei-admin` CLI.
- `shomei-client` — `shomei-client/src/Shomei/Client.hs`: `shomeiClient = genericClient`
  over `ShomeiAPI` plus curated wrappers (`signup`, `login`, `me`, …).
- `examples/embedded-servant-app` — a host app whose `src/Embedded/App.hs` mounts
  `NamedRoutes ShomeiAPI` directly alongside its own routes and serves static demo assets
  (`www/passkeys.js` fetches `/auth/...` paths as string literals).
- `examples/microservice-auth-stack` — a resource service that verifies Shōmei tokens via
  JWKS (`http://localhost:8080/.well-known/jwks.json`).
- Docs under `docs/user/` (`api.md` documents every route and promises the
  `{"error","message"}` shape in its opening paragraphs; `deployment.md`,
  `client-and-examples.md`, `openapi-client-generation.md`, `service-tokens.md`,
  `passkeys.md`, `security.md` all mention concrete paths).

For any exact third-party API (servant-server's `ErrorFormatters`, openapi-hs lenses),
read the installed source via `mori registry show <lib> --full`; never guess, never search
`/nix/store` or `/`.

### The current error surface, exhaustively

The good path: workflows return `Either AuthError a`; `runAuth` maps `Left` through
`authErrorToServerError` (`shomei-servant/src/Shomei/Servant/Error.hs`), which produces
`{"error":<code>,"message":<text>}` with `Content-Type: application/json` for ~30 codes
across 400/401/403/404/409/429/500. Its private `json base code msg` helper is the shape
to replace. It also hand-rolls `err429` (Servant ships no such constant) with an **empty
body**.

The bypass sites (verified line numbers approximate):

- `Auth.hs` `authHandler` (~80–83): `throwError err401 {errBody = "missing token"}` and
  `{errBody = "invalid token"}` — plain text, no Content-Type. These fire on every
  expired-token request.
- `Authz.hs` `requireRole` (~44) / `requireScope` (~50): plain `"missing required role"` /
  `"missing required scope"`. (Post-plan-38, the `HasServer` combinator instances have
  their own 403 bodies — sweep those too.)
- `Handlers.hs`: `resolvePrincipal` (~174, plain `"loginId or email required"`);
  `serviceTokenH` (~194/210, plain `"scopes must not be empty"` / `"invalid actorId"`);
  `meH` (~284) / `sessionH` (~291) plain 404s; `passkeyRegisterCompleteH` /
  `mfaCompleteH` / `passkeyLoginCompleteH` plain `"invalid ceremonyId"` 400s;
  `auditEventsH`'s `badRequest` (already JSON `{"error":"bad_request",…}` but the old
  shape); `readyH`'s 503 (a structured `ReadyResponse` body — **stays**, Decision Log).
- `RateLimit.hs` (~85): the WAI middleware answers throttled requests *before* Servant
  with `responseLBS status429 [("Content-Type","application/json")]
  "{\"error\":\"too_many_requests\"}"`.
- Servant built-ins: a malformed JSON body → plain-text 400; an unknown path → empty 404;
  a wrong method → 405. Servant supports replacing these via **`ErrorFormatters`**
  (`Servant.Server` — `defaultErrorFormatters`, fields like `bodyParserErrorFormatter`,
  `notFoundErrorFormatter`; confirm exact names in the installed servant-server), supplied
  as an extra `Context` entry.

Find any stragglers with:

```bash
grep -rn 'errBody' shomei-servant/src shomei-server/src | grep -v test
```

### The current API shape and spec pipeline

`ShomeiAPI` has 24 paths: ~20 application routes under `/auth` and `/admin`, plus three
that must NOT be versioned — `jwks :: mode :- ".well-known" :> "jwks.json" :> Get '[JSON]
Value`, `health`, `ready`. `/metrics` is a middleware, untouched by any of this.

`shomei-servant/src/Shomei/Servant/OpenApi.hs` builds `shomeiOpenApi = toOpenApi (Proxy
@(NamedRoutes ShomeiAPI)) & info… & servers .~ ["http://localhost:8080"] &
withOperationIds`. `withOperationIds` is the post-processing precedent: a lens traversal
over `O.paths` assigning operation ids. The executable `shomei-openapi`
(`shomei-servant/app/openapi/Main.hs`) pretty-prints it;
`cabal run shomei-openapi > docs/api/openapi.json` regenerates the committed spec
deterministically. The conformance suite `shomei-servant-openapi-test`
(`shomei-servant/test-openapi/Main.hs`) runs `validateEveryToJSON` (every DTO's `ToJSON`
validates against its `ToSchema`) and asserts `openapi == "3.1.0"` and **exactly 24
paths**. Known spec bugs to fix in Milestone 4 (verified in the committed file): 202/204
responses carry `content: {"application/json;charset=utf-8": {}}`; every response
`description` is `""`; `requestBody.required` is absent everywhere.

### Status-code inventory (current, verified)

`signup` → `Post '[JSON] SignupResponse` (200). `verifyEmailConfirm`,
`passwordResetConfirm` → `Verb 'POST 202 '[JSON] NoContent`. `logout` → `PostNoContent`
whose handler runs `Wf.logout`, and a missing session surfaces `SessionNotFound` → 404.
The lifecycle *request* endpoints are also 202 (correctly — they stay).


## Plan of Work

Five milestones. M1 (envelope) and M2 (paths) are independent; do M1 first so M2's moved
tests assert the final body shape once. M3 and M4 build on both. Regenerate the OpenAPI
spec in every milestone that touches routes (M2, M3, M4).

### Milestone 1 — The universal problem-details envelope

Scope: after this milestone every error from every layer is `application/problem+json`
with `type`/`title`/`status`/`code` (+ optional `detail`), 401s carry
`WWW-Authenticate: Bearer`, 429s carry `Retry-After: 60`. Paths are still unversioned.
Proof: servant tests asserting shape and headers on representative failures from each
layer.

**1.1 The catalog and builder.** Rebuild `shomei-servant/src/Shomei/Servant/Error.hs`
around:

```haskell
-- | One stable error kind: the machine 'code', HTTP status, and human 'title'.
-- These constants are the SINGLE SOURCE shared by the runtime mapping below and by
-- the OpenAPI error documentation in "Shomei.Servant.OpenApi" (EP-3 cannot-drift rule).
data ProblemSpec = ProblemSpec
  { problemCode :: !Text,
    problemStatus :: !ServerError, -- the servant base (err401, err429, …)
    problemTitle :: !Text
  }

-- | Render a spec as an RFC 7807 response. Adds @Content-Type: application/problem+json@,
-- @WWW-Authenticate: Bearer@ when the status is 401 (RFC 6750), and @Retry-After: 60@
-- when 429. 'Nothing' detail omits the member.
toProblemError :: ProblemSpec -> Maybe Text -> ServerError

-- | Shorthand for ad-hoc handler failures that still need the envelope.
problem :: ServerError -> Text -> Text -> ServerError   -- base, code, title
```

`toProblemError` builds the body with aeson (`"type" .= ("about:blank" :: Text)`,
`"title" .= problemTitle`, `"status" .= errHTTPCode`, `"code" .= problemCode`, plus
`"detail"` when given) and sets headers. Then define one named constant per existing code
(`pcInvalidEmail`, `pcTokenInvalid`, `pcMissingToken`, `pcMissingRole`, `pcMissingScope`,
`pcBadRequest`, `pcUserNotFoundHttp`, `pcNotFound`, `pcMethodNotAllowed`, …), export the
full list as `problemCatalog :: [ProblemSpec]`, and rewrite `authErrorToServerError` as a
pure dispatch `AuthError -> ServerError` via the constants (every existing
code/status/message pair survives verbatim — diff the old arms against the new constants
one by one). Keep the no-leak collapses exactly as they are (`InvalidCredentials` /
`UserNotActive` / `AccountLocked` all → the generic `invalid_login` 401). New codes needed
by the sweep: `missing_token` (401), `token_invalid` reused for the invalid-token 401,
`missing_role` / `missing_scope` (403), `bad_request` (400), `user_not_found` /
`session_not_found` reused for `meH`/`sessionH`, `not_found` (404, unknown route),
`method_not_allowed` (405), `body_parse_error` (400).

**1.2 Sweep the bypass sites.** Convert each site listed in Context to
`throwError (toProblemError pc… detail)`:

- `Auth.hs` `authHandler`: `missing token` → `pcMissingToken`, `invalid token` →
  `pcTokenInvalid` (still deliberately NOT distinguishing why verification failed). This
  module may import `Shomei.Servant.Error` (no cycle: `Error.hs` imports neither `Auth`
  nor `Handlers`).
- `Authz.hs`: guards → `pcMissingRole`/`pcMissingScope`; if plan 38's `HasServer`
  instances exist, their `delayedFailFatal` bodies too.
- `Handlers.hs`: `resolvePrincipal`, the two `serviceTokenH` 400s, `meH`/`sessionH`, the
  three `"invalid ceremonyId"` sites and `impersonateH`'s target parse (already via
  `authErrorToServerError` — fine), and `auditEventsH.badRequest` (use `pcBadRequest` with
  the parser message as `detail`). Leave `readyH` alone (Decision Log).
- `Error.hs`'s own `err429` arm: `TooManyRequests` → the catalog constant (gets the body
  and `Retry-After` for free).

**1.3 Servant's built-ins.** In `shomei-server/src/Shomei/Server/Boot.hs` extend the
context:

```haskell
authContext :: Seam.Env -> Context '[AuthHandler Request AuthUser, ErrorFormatters]
authContext senv = authHandler senv.verifier :. shomeiErrorFormatters :. EmptyContext
```

with `shomeiErrorFormatters` (put it in `Shomei.Servant.Error` so the servant test reuses
it) overriding `defaultErrorFormatters`: body-parse failures → `pcBadRequestBody` with the
parse message as `detail`; not-found → `pcNotFound`; the header/URL-parse formatters →
`pcBadRequest`. Read servant-server's `Servant.Server.Internal.ErrorFormatter` source via
mori for the exact field names and formatter signatures. Mirror the context change
wherever the test suite builds its own (`shomei-servant/test/Main.hs`).

**1.4 The middleware 429.** In `RateLimit.hs`, replace the ad-hoc body with the same
document (`code "too_many_requests"`, title "Too many requests", `Retry-After: 60`,
`Content-Type: application/problem+json`). This module cannot import shomei-servant
(dependency direction is servant ← server, which is fine — `shomei-server` already
depends on `shomei-servant`; import the builder). The token bucket refills continuously,
so `60` is an honest upper bound for a full-minute budget; state that in a comment.

**1.5 Tests.** In `shomei-servant/test/Main.hs` add a "problem envelope" test group
asserting, for each of: no token on `/auth/me`; garbage token; non-admin on the
role-gated route; malformed JSON body on `/auth/signup`; unknown path `/nope`; wrong
method (GET on `/auth/login`) — that the status is right, `Content-Type` is
`application/problem+json`, the body parses with the expected `code`, `status` mirrors
the HTTP status, and 401s carry `WWW-Authenticate: Bearer`. Assert `Retry-After` on the
login-throttle 429 (the abuse tests already trip it). Update every existing assertion
that read `.error`/`.message` to read `.code`/`.title`.

Acceptance: `cabal test shomei-servant:shomei-servant-test` green;
`grep -rn 'errBody = "' shomei-servant/src shomei-server/src` finds no plain-text
error bodies.

### Milestone 2 — The `/v1` boundary

Scope: after this milestone application routes answer only under `/v1`; probes, JWKS
stay at the root; client, examples, docs-facing tests all speak `/v1`.

**2.1 Split the record.** In `API.hs`: remove the `jwks`, `health`, `ready` fields from
`ShomeiAPI` (it becomes the pure application record) and add:

```haskell
-- | The served route tree (EP-3): application routes under /v1; protocol and
-- infrastructure endpoints at unversioned root paths (/.well-known/*, /health, /ready;
-- /metrics is WAI middleware; future /oauth/* will also live here, unversioned).
data ShomeiRoutes mode = ShomeiRoutes
  { v1 :: mode :- "v1" :> NamedRoutes ShomeiAPI,
    jwks ::
      mode
        :- ".well-known"
          :> "jwks.json"
          :> Get '[JSON] (Headers '[Header "Cache-Control" Text] Value),
    health :: mode :- "health" :> Get '[JSON] HealthResponse,
    ready :: mode :- "ready" :> Get '[JSON] ReadyResponse
  }
  deriving stock (Generic)

shomeiRoutesAPI :: Proxy (NamedRoutes ShomeiRoutes)
```

(The `Cache-Control` header lands here rather than M4 because the field moves anyway;
`addHeader "public, max-age=300"` in the handler.) Keep `shomeiAPI` exported for
embedders who want only the application record, and update the `AppAPI` example to mount
`NamedRoutes ShomeiRoutes`. In `Handlers.hs` add
`shomeiRoutes :: Env -> ShomeiRoutes (AsServerT Handler)` delegating `v1 = shomeiServer
env` (via the `NamedRoutes` server nesting — the field is simply the inner record) and
the three moved handlers. In `Boot.hs`, `application` serves `shomeiRoutesAPI` with the
same context.

**2.2 Client.** In `shomei-client/src/Shomei/Client.hs`: derive the root client
(`shomeiRoutesClient :: ShomeiRoutes (AsClientT ClientM)` via `genericClient`), and
redefine `shomeiClient :: ShomeiAPI (AsClientT ClientM)` as the `v1` field's client
record (selector application: `API.v1 shomeiRoutesClient` — the same
qualified-selector technique the module already documents for NamedRoutes fields; if the
nested-record client needs servant's `(//)` helper instead, check the installed
servant-client-core generics support via mori and use whichever compiles). Every curated
wrapper then works unchanged. `shomeiClientEnv` callers keep passing the plain base URL —
the `/v1` segment comes from the route type, which is the point.

**2.3 Examples.** `examples/embedded-servant-app/src/Embedded/App.hs`: `AppAPI` becomes
`NamedRoutes ShomeiRoutes :<|> Authenticated :> "projects" … :<|> Raw`, served with
`shomeiRoutes senv`. Update every fetch path in
`examples/embedded-servant-app/www/passkeys.js` (`/auth/...` → `/v1/auth/...`; the JWKS
path is unchanged). `examples/microservice-auth-stack`: grep for `/auth/` and
`localhost:8080` under its `src`/`app` — the JWKS URL stays, any login/token call moves
to `/v1`. Run both examples' test suites (`cabal test all` covers workspace members).

**2.4 Tests.** Mechanical path sweep in `shomei-servant/test/Main.hs` (and the examples'
tests): every request string gains `/v1` except `/.well-known/jwks.json`, `/health`,
`/ready`. Add the boundary tests: `POST /auth/login` (old path) → 404 with the problem
body from M1.3; `GET /health` still 200 at root; `GET /v1/health` → 404 (nothing bleeds
into v1).

**2.5 Spec.** Point `OpenApi.hs` at the root record: `toOpenApi (Proxy @(NamedRoutes
ShomeiRoutes))`. The `Headers` combinator changes the jwks operation (servant-openapi
documents the response header — verify output). Keep `servers` as
`["http://localhost:8080"]` but set its description to "local development server" if the
openapi-hs `Server` type allows (it does — `_serverDescription`). Regenerate; the
conformance path count stays 24 (same paths, renamed under `/v1`) — update the literal
path assertions if any test names paths.

Acceptance: full `cabal test all` green; the boundary curl checks in Validation pass.

### Milestone 3 — Status-code corrections

Scope: three wire-visible fixes, each one line of route type or handler plus tests.

In `API.hs`: `signup` → `Verb 'POST 201 '[JSON] SignupResponse`; `verifyEmailConfirm` and
`passwordResetConfirm` → `Verb 'POST 200 '[JSON] NoContent`. In `Handlers.hs` make
`logoutH` idempotent:

```haskell
logoutH :: Env -> AuthUser -> Handler NoContent
logoutH env user = do
  outcome <- runPort env (Wf.logout env.config (LogoutCommand {sessionId = user.authSessionId}))
  case outcome of
    Left SessionNotFound -> pure NoContent -- already logged out: idempotent success
    Left err -> throwError (authErrorToServerError err)
    Right () -> pure NoContent
```

(`Wf.logout` returns `Either AuthError ()` inside `Eff` — verify and adapt; the point is
to intercept exactly `SessionNotFound` instead of letting `runAuth` map it.) Update the
servant tests (the signup assertions check 200 today; the e2e logout section asserts the
404 — flip both, and add a double-logout → 204/204 case). Regenerate the spec (the
response codes change). Write the three wire-compat notes for the CHANGELOG as you go:
old code → new code, who is affected, what to change.

### Milestone 4 — OpenAPI truth

Scope: the spec documents the error surface from the shared catalog, loses its invalid
bits, and is served by the server itself.

**4.1 The `Problem` schema and per-route errors.** In `OpenApi.hs`: declare a `Problem`
schema (object; `type`/`title` strings, `status` integer, `code` string, optional
`detail`; `required: [type, title, status, code]`) and insert it under
`components.schemas`. Add a route→codes table using the M1 constants:

```haskell
routeErrors :: [(FilePath, [ProblemSpec])]   -- path (as it appears in O.paths) → codes
```

and a post-processing pass (style of `withOperationIds`: `O.paths %~ imap …`) that, for
each listed operation, adds one `responses` entry per distinct status among its specs —
description built from the codes sharing that status (e.g.
`401: "Problem document; code is one of: missing_token, token_invalid"`), content
`application/problem+json` referencing the `Problem` schema. Apply a generic baseline
automatically: every operation whose security requires bearer gets the 401 set (+403
where a role/scope table entry says so); every operation with a request body gets 400
`body_parse_error`. The per-route specifics (409 on signup, 429 on login, …) come from
the table — populate it from `docs/user/api.md`'s per-endpoint error lists and the
handler code, route by route.

**4.2 Drift guard.** In `shomei-servant/test-openapi/Main.hs` add: every `code` mentioned
in any response description/`x-` field exists in `problemCatalog`; every documented
status matches its spec constant's status; the `Problem` schema is present and its
`required` list is exactly the four members. (Implementation freedom: emitting the code
list as a vendor extension `x-error-codes` array per response makes this test trivial and
machine-readable for client generators — prefer that over parsing descriptions, and
document it.)

**4.3 Spec nits.** Add three more post-processing passes with lens traversals over
`O.allOperations` (read openapi-hs's lens surface via mori first): (a) delete the
`content` map from every 204 response and from 200/202 responses whose only media type
has an empty schema (the `NoContent` artifacts); (b) fill every empty response
`description` (derive from status: 200 "OK", 201 "Created", 202 "Accepted", 204 "No
Content", or better per-route text where the table has it — descriptions are REQUIRED by
OpenAPI, `""` is technically present but useless; make them meaningful); (c) set
`required = True` on every `requestBody` (all Shōmei bodies are mandatory). Where
openapi-hs's types make a fix impossible (e.g. if a media-type entry cannot be removed
without breaking servant-openapi's invariants), document the limit in Surprises &
Discoveries rather than fighting it.

**4.4 Serve the spec.** Add to `ShomeiRoutes`:
`openapi :: mode :- "openapi.json" :> Get '[JSON] Value` with handler
`pure openApiValue` where `openApiValue :: Value` is a top-level constant
`toJSON shomeiOpenApi` exported from `OpenApi.hs` (computed once per process; `Handlers.hs`
importing `OpenApi.hs` creates no cycle — `OpenApi.hs` imports only `API`/`DTO`/`Authz`).
Path count becomes 25 — update the conformance assertion. Note the self-reference quirk:
the served document includes `/openapi.json` itself; that is fine and true.

**4.5 Regenerate and commit.** `cabal run shomei-openapi > docs/api/openapi.json`; eyeball
the diff (`Problem` schema, error responses, descriptions, `required: true`, no 204
content, `/v1` paths, `/openapi.json`); commit.

### Milestone 5 — Documentation and closure

Rewrite `docs/user/api.md`: the opening error paragraph now shows the problem document
(with the `code` member carrying the old strings and a migration sentence), every path
gains `/v1`, the three status-code changes land in their endpoint sections, and a new
"Errors" section lists the catalog (generate the table from `problemCatalog` by hand once
— or note that `/openapi.json` is the machine-readable source). Sweep the other docs:
`grep -rn '/auth/\|{"error"' docs/user` and fix every hit (`deployment.md` probe paths
stay; `openapi-client-generation.md` gains the served `/openapi.json` URL as an
alternative to the committed file). Add the CHANGELOG "Breaking (pre-1.0 window)" block:
`/v1` move with the unversioned exceptions, envelope change with a before/after JSON
pair, the three status-code notes, and the JWKS caching note. Record the live transcript
below. Tick EP-3 in MasterPlan 7 (registry, Progress, and its Integration Points now
point at real code: the versioning boundary in `API.hs` `ShomeiRoutes`, the envelope in
`Shomei.Servant.Error`).


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shomei`, inside `nix develop`.

```bash
nix develop
just create-database          # idempotent dev DB (needed by e2e/postgres suites)

# find every error-body site before starting M1 (the sweep worklist):
grep -rn 'errBody' shomei-servant/src shomei-server/src

# iterate:
cabal build all
cabal test all

# regenerate the spec whenever API.hs / DTO.hs / OpenApi.hs change (M2, M3, M4):
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json

# docs sweep helper (M5):
grep -rn '/auth/' docs/user examples | grep -v '/v1/auth/'
```

Expected suite shape when done:

```text
shomei-core-test            ... passed (untouched)
shomei-postgres-test        ... passed (untouched)
shomei-servant-test         ... passed (problem-envelope group; /v1 paths; 404-on-old-path;
                                        201 signup; idempotent logout; Retry-After/WWW-Authenticate)
shomei-servant-openapi-test ... passed (25 paths; Problem schema; catalog drift guard;
                                        no-204-content; descriptions non-empty; requestBody required)
shomei-admin-test           ... passed (untouched — the CLI does not speak HTTP)
```

Conventional commits per milestone:

```text
feat(servant)!: RFC 7807 problem+json envelope on every error path (EP-3 M1)
feat(servant)!: move application routes under /v1; root keeps probes + well-known (EP-3 M2)
fix(servant)!: signup 201, synchronous confirms 200, idempotent logout (EP-3 M3)
feat(servant): OpenAPI error catalog, spec fixes, served /openapi.json, JWKS caching (EP-3 M4)
docs(user): document /v1 + problem-details contract; CHANGELOG breaking notes (EP-3 M5)
```


## Validation and Acceptance

Live transcript against the dev server (`cabal run shomei-server` or the process-compose
stack; port 8080):

```bash
# the envelope, from the auth layer (the commonest failure):
curl -si http://localhost:8080/v1/auth/me | sed -n '1p;/^www-authenticate/Ip;/^content-type/Ip;$p'
# HTTP/1.1 401 Unauthorized
# Content-Type: application/problem+json
# WWW-Authenticate: Bearer
# {"code":"missing_token","status":401,"title":"Authentication required","type":"about:blank"}

# the envelope, from servant's own body parser:
curl -si -XPOST http://localhost:8080/v1/auth/signup -H 'Content-Type: application/json' -d '{'
# → 400, application/problem+json, code "body_parse_error", a detail with the parse message

# the boundary:
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' -d '{}'     # → 404 (old path gone; body is a problem doc)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/health        # → 200 (unversioned)
curl -s http://localhost:8080/.well-known/jwks.json -si | grep -i cache-control
# → Cache-Control: public, max-age=300

# status codes:
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://localhost:8080/v1/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"email":"a@example.com","password":"Str0ng-Pass-123!"}'               # → 201
TOK=… # login, capture accessToken
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://localhost:8080/v1/auth/logout \
  -H "Authorization: Bearer $TOK"                                            # → 204
curl -s -o /dev/null -w '%{http_code}\n' -XPOST http://localhost:8080/v1/auth/logout \
  -H "Authorization: Bearer $TOK"                                            # → 204 (idempotent)

# the served spec:
curl -s http://localhost:8080/openapi.json | jq '.openapi, (.paths | keys | length),
  .components.schemas.Problem.required'
# "3.1.0" / 25 / ["type","title","status","code"]
```

Acceptance criteria: every transcript line behaves as shown; the M1 test group proves the
envelope from all six layers (auth handler, authz, handler ad-hoc, workflow mapping,
servant formatters, rate-limit middleware); `git grep -n '"error"' docs/user` shows no
remaining old-shape documentation; both examples build and their tests pass against
`/v1`; `cabal run shomei-openapi` output equals the committed spec byte-for-byte; the
conformance suite's new invariants (no 204 content, non-empty descriptions, required
request bodies, catalog-backed error codes) all pass.


## Idempotence and Recovery

No schema migrations and no data changes — everything here is code and documents, freely
re-runnable; `cabal test all` is the checkpoint after every step. The risky property is
*coherence*, not damage: milestones 2 and 3 change wire behavior, so land each as one
commit that updates routes + handlers + client + examples + tests + regenerated spec
together — never leave the committed `docs/api/openapi.json` describing routes the server
does not serve (the conformance suite and the byte-for-byte regeneration check are the
guards; if you must pause mid-milestone, note the exact stopping point in Progress). If a
later plan lands admin routes (plan 39) before this plan finishes, re-run the M2 path
sweep over the new routes and extend the M4 route→codes table — the path-count assertions
will refuse to let you forget. Reverting is `git revert` of the milestone commits; there
is no runtime state to unwind.


## Interfaces and Dependencies

No new external dependencies: `servant`/`servant-server` (ErrorFormatters, `Headers`,
`Verb`), `openapi-hs` + `servant-openapi` (already library deps of `shomei-servant`),
`aeson`, `wai`, `http-types` are all in the workspace. Read via mori before use:
servant-server's `ErrorFormatters`/`ErrorFormatter` record fields, servant-client-core's
NamedRoutes nesting (`(//)` or selector application), openapi-hs's `Response`,
`RequestBody`, `Server` lenses.

Must exist at the end (full module paths):

- `Shomei.Servant.Error`: `ProblemSpec (..)`, `problemCatalog :: [ProblemSpec]`,
  `toProblemError :: ProblemSpec -> Maybe Text -> ServerError`,
  `problem :: ServerError -> Text -> Text -> ServerError`,
  `authErrorToServerError :: AuthError -> ServerError` (same name/type, new body shape),
  `shomeiErrorFormatters :: ErrorFormatters`.
- `Shomei.Servant.API`: `ShomeiRoutes (..)` (fields `v1`, `jwks` with the `Cache-Control`
  `Headers`, `openapi`, `health`, `ready`), `shomeiRoutesAPI`; `ShomeiAPI` reduced to the
  application record; `AppAPI` updated.
- `Shomei.Servant.Handlers`: `shomeiRoutes :: Env -> ShomeiRoutes (AsServerT Handler)`;
  idempotent `logoutH`.
- `Shomei.Servant.OpenApi`: `shomeiOpenApi` generated from `ShomeiRoutes` with the
  `Problem` schema, catalog-derived per-route error responses (`routeErrors` table), the
  nit-fix passes, and exported `openApiValue :: Value`.
- `Shomei.Server.Boot.authContext` carrying `ErrorFormatters`;
  `Shomei.Server.Middleware.RateLimit` emitting the problem 429 + `Retry-After`.
- `Shomei.Client`: root `genericClient` with the curated wrappers reaching the nested v1
  record (public wrapper signatures unchanged).
- Regenerated `docs/api/openapi.json` (25 paths); conformance suite with the new
  invariants; updated `docs/user/*.md`, both examples, and the CHANGELOG breaking block.
