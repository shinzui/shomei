---
id: 48
slug: reorganize-shomei-into-vertical-slices-and-adopt-multiverb
title: "Reorganize shomei into vertical slices and adopt MultiVerb"
kind: exec-plan
created_at: 2026-07-09T14:41:54Z
intention: "intention_01m0r2mprpep1s12w89mb6hab5"
---

# Reorganize shomei into vertical slices and adopt MultiVerb

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is not yet adopted, so this is the point at which to make its public Haskell and HTTP
APIs coherent without compatibility shims. After this work, the repository is organized by
authentication concept inside its existing package boundaries, the top-level Servant API is a
thin composition of per-concept `NamedRoutes` records, and every expected status an operation
owns is visible in its route type. A JSON endpoint uses `MultiVerb` when it can return an
operation-owned non-success status, including a typed 503 from a store or required dependency.
Only genuinely in-process, cannot-fail, single-status routes remain ordinary `Get`, `Post`, or
`Verb` routes; `Raw` and streaming routes keep their native terminal combinators. This plan does
not introduce `MultiVerb1` merely for uniformity.

The change has four observable benefits.

First, a maintainer changing passkeys, sessions, OAuth, TOTP, or accounts can work in one
concept-shaped module subtree instead of editing large layer-first modules such as
`Shomei.Servant.API`, `Shomei.Servant.DTO`, and `Shomei.Servant.Handlers`. Cabal packages remain
the architectural layer boundaries: domain and workflows stay in `shomei-core`, PostgreSQL
interpreters stay in `shomei-postgres`, and HTTP types and handlers stay in `shomei-servant`.
Only the module layout within each package becomes concept-first.

Second, expected operation failures become ordinary typed values. For an operation such as signup,
the route type declares its `201` success plus the shared application error tail, including its
`400`, `409`, `500`, and `503` outcomes; the handler returns a named result sum; the server,
generated Haskell client, and OpenAPI document all use that same declaration. Authentication,
authorization, request-decoding, and rate-limiting failures happen before the handler and remain
centralized. Known dependency unavailability is an expected 503 value; genuinely unexpected
exceptions remain at the fault boundary. A route is not converted to `MultiVerb` solely because a
pre-handler or unexpected-fault path can reject the request.

Third, all compatibility surfaces that exist only because earlier plans assumed adopters are
removed rather than carried into the initial API. There will be no deprecated re-export modules,
old client signatures, email-as-login fallback, ambiguous MFA decoder, legacy service-token or
impersonation endpoints, legacy password-hash decoder, plaintext signing-key fallback, or unused
store operation retained for source compatibility. The supported machine-to-machine and delegation
paths are the standard OAuth `client_credentials`, token-exchange, introspection, and revocation
flows.

Fourth, Shōmei stops owning bespoke probe types and status mapping. It mounts the released
`servant-health` `HealthApi` at `/health`, supplies Shōmei-specific liveness and readiness checks,
uses the package's check combinators and path constants, and runs its conformance test kit. This
centralizes the easy-to-swap 200/503 `AsUnion` mapping and makes the runtime contract the fleet
standard: `GET /health/live` and `GET /health/ready`.

The finished behavior is visible without reading the implementation:

* `docs/api/openapi.json` is regenerated from the exact API proxy served by `shomei-server`.
  Multi-outcome handlers list all of their expected status codes and response media types.
* Application errors follow RFC 9457, the current successor to RFC 7807. They use
  `application/problem+json` and a typed `ProblemDetails` body containing `type`, `title`,
  `status`, optional `detail` and `instance`, and the Shōmei extensions `code` and `retryable`.
  OAuth protocol errors retain their RFC 6749 shape, and both health probes retain the
  `servant-health` status-report shape.
* The generated Haskell client returns route-specific result sums for MultiVerb operations and
  ordinary values for ordinary routes. It does not collapse typed error arms into `ClientError`.
* `POST /v1/auth/service-token`, `POST /v1/auth/impersonate`, and
  `DELETE /v1/auth/impersonate` no longer exist.
* The old `GET /health` and `GET /ready` routes no longer exist. There are no aliases or
  redirects; Kubernetes and examples use `GET /health/live` and `GET /health/ready`.
* Signup requires `loginId`; login accepts `loginId` rather than an alternate email field; MFA
  completion uses one explicitly tagged proof.
* A clean build, all test suites, deterministic OpenAPI generation, and the Nix flake checks pass.


## Progress

- [x] (2026-07-24) Re-audited the plan against the current working tree, current
  `haskell-jitsurei` guidance, the Mori dependency corpus, Hackage releases, and upstream tags.
- [x] (2026-07-24) Replaced the earlier blanket-MultiVerb and compatibility-preserving design
  with the selective rule and breaking pre-adoption cleanup described here.
- [x] (2026-07-24) Reviewed the error profile against RFC 9457, which obsoletes RFC 7807, and
  corrected custom problem-type identity and the RFC/MultiVerb boundary.
- [x] (2026-07-26) Reconciled the plan with the revised `haskell-jitsurei` API standards and the
  released `servant-health` 0.1.0.0 source, routes, test kit, and OpenAPI cohort.
- [x] (2026-08-23) Milestone 0: verified the released dependency cohort through Mori,
  Hackage, and upstream tags; established a green full build and serial-test baseline; refreshed
  the known OpenAPI authentication-code drift; tightened dependency bounds; normalized the
  OpenAPI test stanza; and added an exact 43-path/48-operation inventory assertion. The existing
  end-to-end admin lifecycle, session, password-reset, and role tests exercise every member of
  the same-typed handler families. The compile-time MultiVerb and operation-owned-503 witnesses
  are intentionally activated with the new route aliases in Milestone 4, when their assertions
  can be true.
- [x] (2026-08-23) Milestone 1: removed email-derived login identifiers, permissive MFA
  decoding, the bespoke service-token and impersonation operations, static machine accounts,
  unparameterized Argon2 hashes, plaintext signing keys, optional KEKs, the redundant ceremony
  cleanup effect, and their tests/documentation. Renamed MFA and machine-token configuration,
  made key encryption mandatory throughout server/admin/examples, regenerated the exact
  41-path/45-operation OpenAPI artifact, and passed the affected build and serial tests.
- [x] (2026-08-23) Milestone 2: moved the core domain, ports, workflows, PostgreSQL
  interpreters, JWT mechanics, and their tests to concept-first modules with role-last leaf
  names; removed every old layer-first module path; added typed PostgreSQL dependency failures;
  preserved them through `runAppIO` and the Servant seam; retained internal errors only for
  persisted-value reconstruction; and passed the full workspace build plus all 228 core, 56
  PostgreSQL, and 44 JWT tests serially.
- [x] (2026-08-23) Milestone 3: replaced the flat DTO, handler, and API modules with
  concept-owned `Api`, `Dto`, and `Handler` modules; added typed query/cursor inputs, enforcing
  authentication and administration combinators, pass-through pre-handler markers, a thin root
  API/server composition, and same-prefix dispatch coverage. Adopted `servant-health` at
  `/health/live` and `/health/ready`, injected independently tracked checks into every host,
  added the released testkit contract matrix plus production readiness/onset tests, and passed
  the full workspace build and focused OpenAPI/health/dispatch tests.
- [x] (2026-08-23) Milestone 4: replaced the application error envelope with an RFC 9457
  `ProblemDetails` profile and a documented 47-entry stable problem-type catalog; added one
  exhaustive shared application-error tail plus concept-owned result sums with manual `AsUnion`
  instances; converted every fallible application operation and every OAuth/OIDC operation to
  typed `MultiVerb`; retained only JWKS and OpenAPI as ordinary typed routes; and proved every
  store-backed application route owns 503 at compile time.
- [x] (2026-08-23) Milestone 5: derived all handler-owned OpenAPI responses from the exact served
  proxy; removed the path-indexed handler-error catalog; taught the generated client to return
  the typed operation sums and preserve route-specific response headers; regenerated a
  deterministic 41-path/45-operation OpenAPI artifact; and passed the focused 62-example OpenAPI,
  35-example runtime, typed-client, health, and assembly suites.
- [x] (2026-08-23) Milestone 6: rewrote current user, deployment, example, browser-demo, and
  operator material for `loginId`, tagged MFA proofs, RFC 9457, typed client results, and
  `/health/live` plus `/health/ready`; added a bearer-only OAuth userinfo authentication
  combinator and protocol-boundary coverage; corrected every current RFC 7807 comment to RFC
  9457; made the multi-package Nix server closure reproducible on the 2026-08-22
  `nixpkgs-unstable` snapshot; and passed deterministic artifact comparison, source audits,
  formatting, the full Cabal build and test suite, `nix build .#default`, and `nix flake check`.


## Surprises & Discoveries

- Observation: the repository has advanced substantially since the original version of this
  plan. Plan 40's `/v1` mount, Problem Details formatters, method-not-allowed middleware, OpenAPI
  endpoint, and status corrections are already implemented.
  Evidence: `Shomei.Servant.API` now exposes 43 paths and 48 method/path operations through
  `ShomeiRoutes`, and
  `Shomei.Servant.Error`, `Shomei.Servant.OpenApi`, and the server middleware already contain
  those facilities.

- Observation: the original route count and response inventory were stale. The current surface
  includes OAuth/OIDC, TOTP, recovery codes, passwordless passkeys, administrative operations,
  and permission management.
  Evidence: the committed `docs/api/openapi.json` contains 43 distinct paths and 48
  method/path operations, rather than the earlier plan's 24 paths.

- Observation: blanket `MultiVerb1` adoption would encode the wrong architectural boundary, but
  the earlier draft's ordinary-route exception was too broad. A store-backed route owns an
  expected 503 even if its happy path has one payload, while auth, decoder, middleware, and
  unexpected-fault responses remain outside the handler result.
  Evidence: the revised `patterns/api/servant-routes.md` exempts only cannot-fail in-process
  single-status endpoints, `Raw`, and streaming. `oauthUserinfoH`, `passkeysListH`,
  `recoveryCodesCountH`, `passkeyLoginBeginH`, audit reads, and admin reads all execute a store or
  another fallible port, so they are not one-status exemptions. Only JWKS and the OpenAPI document
  are current typed, in-process, single-status operations.

- Observation: the current route standard now makes the MultiVerb scope explicit rather than
  requiring it literally for every terminal combinator.
  Evidence: `patterns/api/servant-routes.md` names cannot-fail in-process single-status routes,
  `Raw`, and streaming as the three recorded exemptions while keeping `NamedRoutes`
  unconditional. Shōmei can therefore avoid meaningless one-arm unions without creating a
  service-specific exception to the fleet standard.

- Observation: the current health standard supersedes Shōmei's custom `/health` and `/ready`
  surface with the released `servant-health` package.
  Evidence: `servant-health` 0.1.0.0 is the sole normal Hackage version, upstream tag
  `v0.1.0.0` resolves to commit `c70bffd`, and the local checkout's public source is unchanged
  from that tag. `Servant.Health` owns `ProbeStatus`, `ProbeResponses`, the manual same-body
  `AsUnion`, `HealthApi`, and `healthServer`; `Servant.Health.Check`,
  `Servant.Health.Paths`, and the public `testkit` sublibrary own the reusable hardening,
  paths, and wiring proof. Mori now registers it canonically as `shinzui/servant-health` and
  reports no registered dependents, so there is no coordinated consumer migration to preserve.

- Observation: adopting `servant-health` is a deliberate breaking cleanup, not an aliasing
  exercise.
  Evidence: Shōmei currently serves `GET /health` with custom `HealthResponse` and `GET /ready`
  with custom `ReadyResponse`; the package contract serves `/health/live` and `/health/ready`,
  rejects bare `/health`, and fixes the body to exactly `status`, `check`, and `failingSince`.
  Shōmei has no adopters, so the old routes, DTOs, handlers, schemas, client fields, and examples
  can be deleted instead of translated or redirected.

- Observation: the current persistence interpreters cannot yet express the route standard's
  503-versus-500 distinction.
  Evidence: database execution failures and persisted-row reconstruction failures both become
  `InternalAuthError`; the standalone seam then turns either into an `IOException`, so a
  store-backed route can only fault as 500. The refactor must give known dependency
  unavailability its own typed error while retaining 500 for corrupt data and impossible state.

- Observation: RFC 9457 obsoleted RFC 7807 in July 2023, while the local guidance and current
  Shōmei comments still use the older RFC number.
  Evidence: RFC 9457 states the replacement explicitly and retains the
  `application/problem+json` wire model. The plan targets RFC 9457 while remaining wire-compatible
  with clients that describe the format as RFC 7807.

- Observation: Shōmei's current `about:blank` plus a custom `code` and custom title does not
  express custom problem identity correctly.
  Evidence: RFC 9457 says consumers use `type` as the primary identifier and says
  `about:blank` means there is no additional meaning beyond the HTTP status; with
  `about:blank`, the title should be the standard reason phrase. Every Shōmei catalog entry has
  additional semantics, so it needs a stable, documented type URI.

- Observation: `servant-openapi-hs` 5.1.0 only compiles its MultiVerb `HasOpenApi` support when
  built with `servant >= 0.20.3`.
  Evidence: `src/Servant/OpenApi/Internal.hs` in the Mori-resolved
  `shinzui/servant-openapi-hs` checkout guards the instances with
  `MIN_VERSION_servant(0,20,3)`. Hackage and upstream tags contain
  `servant-0.20.3.0`, `openapi-hs` 5.0.0, and `servant-openapi-hs` 5.1.0.

- Observation: the current OpenAPI document derives success responses from route types but adds
  handler errors through a large hand-maintained `routeErrors` table.
  Evidence: `shomei-servant/src/Shomei/Servant/OpenApi.hs` defines `routeErrors`,
  `baselineSpecs`, and OAuth response decorators. The handler-error portion can disappear after
  MultiVerb; only responses emitted outside handlers still need centralized documentation.

- Observation: the committed OpenAPI artifact already has pre-existing drift from the current
  generator.
  Evidence: on 2026-07-24,
  `nix develop --command cabal run shomei-openapi > /tmp/shomei-plan48-openapi.json` succeeded,
  but comparison with `docs/api/openapi.json` showed that generated protected operations now also
  enumerate `session_expired` and `session_revoked`. The generated and committed documents still
  agree on 43 paths and 48 method/path operations. The current
  `shomei-servant-openapi-test` still passes all 56 examples because it checks the in-memory
  document, not the committed golden. Milestone 0 must preserve this as a separate baseline
  correction, and Milestone 5 must add the missing artifact-drift gate.

- Observation: several compatibility paths already exist in the code even though there are no
  adopters to protect.
  Evidence: the source explicitly labels `loginIdFromEmail`, the optional login fields, the flat
  MFA decoder, the three-part Argon2 format, plaintext signing keys, and
  `DeleteExpiredCeremonies` as compatibility behavior. The service-token and bespoke
  impersonation endpoints are documented as deprecated in favor of OAuth.

- Observation: version-tolerant decoding of append-only audit events and support for standard
  algorithms such as RS256 are not pre-adoption API shims.
  Evidence: an audit row remains persisted state after release, and RS256 is a current
  interoperable JWS algorithm. Those capabilities stay; misleading comments that call normal
  behavior “legacy” should be rewritten.

- Observation: this repository's database-backed test suites can contend when Cabal runs them in
  parallel.
  Evidence: completed ExecPlans 28, 33, 41, and 45 record green serial runs after intermittent
  parallel failures. Final acceptance therefore sets `TASTY_NUM_THREADS=1`; it does not treat a
  known resource-contention failure as a product regression.

- Observation: the dependency and behavior baseline remained stable when implementation began on
  2026-08-23.
  Evidence: Hackage and upstream tags still identify Servant 0.20.3.0, `openapi-hs` 5.0.0,
  `servant-openapi-hs` 5.1.0, and `servant-health` 0.1.0.0; `cabal build all` and the serial
  `cabal test all` passed; and the generated document still contains exactly 43 paths and 48
  method/path operations. The only committed-artifact drift was the already-recorded addition of
  `session_expired` and `session_revoked` to protected-route 401 responses.

- Observation: making `loginId` a required DTO field moves the missing-field response from an
  application handler rejection to Servant's request-decoding boundary.
  Evidence: the HTTP conformance scenario now receives `400 body_parse_error` for a structurally
  valid login object without `loginId`, while malformed JSON has the same envelope. This matches
  the plan's rule that decoding failures are pre-handler outcomes and should not become
  MultiVerb arms.

- Observation: a mandatory KEK makes the dependency on `shomei-jwt` explicit in every test
  component that constructs a standalone server environment.
  Evidence: the client and both embedding examples now parse a fixed test KEK and declare
  `shomei-jwt` in their test `build-depends`; production startup and admin key generation instead
  use the required `SHOMEI_KEY_ENCRYPTION_KEY` loader.

- Observation: the previous IO-shaped Servant runner erased the distinction between a known
  database failure and an unexpected process fault after the PostgreSQL interpreter had already
  produced an `AuthError`.
  Evidence: `runAppIO` already returned `IO (Either AuthError a)`, but `seamEnv` converted the
  `Left` to `IOException`. The seam runner now retains `Either AuthError`, flattens workflow
  errors explicitly, and allows ordinary handlers and readiness to distinguish
  `DependencyUnavailable PostgreSQL` from `InternalAuthError` without exception recovery.

- Observation: releasing a Hasql pool is not a reliable way to fabricate an unavailable
  dependency for a readiness test; a subsequent use can still complete far enough to produce
  the empty-active-key result.
  Evidence: the first production-readiness test expected `postgres` after `Pool.release` but
  received `signing-key`. Using a pool configured for an unreachable loopback port exercises the
  intended typed PostgreSQL failure deterministically, while the empty-key case remains a
  separate reachable-database assertion.

- Observation: `NamedRoutes` safely composes several concept records under the same static
  prefix without depending on record-field order.
  Evidence: the new runtime witness mounts three marker-valued records under `/shared` and
  independently reaches `/shared/account`, `/shared/session`, and `/shared/audit`; the production
  `ApplicationApi` uses the same composition for the `/v1/auth` and `/v1/admin` slices.

- Observation: Servant's generic MultiVerb client decoder cannot recover optional headers for
  every route-specific result shape without help, even though the server-side response mapping is
  unambiguous.
  Evidence: the typed client initially lost cookie and location metadata while decoding shared
  response arms. Route-specific `ServantHeaders` instances now pair each success constructor with
  exactly the headers declared by its response alternative, and the client suite round-trips both
  bearer and cookie modes.

- Observation: content negotiation for MultiVerb must distinguish the terminal problem media type
  from ordinary JSON successes.
  Evidence: declaring the response list under plain `JSON` caused client dispatch to treat
  `application/problem+json` responses as an unsupported content type. Application failures now
  use `RespondAs ProblemJSON`, while successes use `RespondAs JSON`; runtime and generated-client
  tests exercise both paths.

- Observation: OAuth userinfo authentication is itself part of the OAuth wire protocol and cannot
  reuse the application-session combinator without changing error media, body, and challenge
  semantics.
  Evidence: the dedicated `OAuthAuthenticated` combinator requires a bearer token even when the
  surrounding server runs in cookie mode and returns RFC 6750-style `invalid_token` plus
  `WWW-Authenticate`; tests prove that it never emits `ProblemDetails` and rejects an otherwise
  valid session cookie.

- Observation: `cabal run shomei-openapi > file` can put Cabal rebuild progress on standard output
  before the executable's JSON and thereby produce an invalid artifact.
  Evidence: invoking the already-built executable directly produced byte-identical documents on
  two runs, while the rebuilding wrapper contaminated its redirected output. Final generation
  therefore builds first and executes the `cabal list-bin` result directly.

- Observation: the generated Nix package definition assumed a single root Cabal package, but this
  repository is a multi-package Cabal project with no root `.cabal` file.
  Evidence: the first `nix flake check` evaluated `callCabal2nix "shomei" inputs.self` and failed
  before building Shōmei. The generated default is now `mkDefault`, and the project module defines
  the explicit local-package graph, locked source-repository inputs, and server executable output.
  During validation, the June nixpkgs snapshot also carried stale Haskell package revisions; with
  user approval the project package snapshot was advanced to `nixpkgs-unstable` revision
  `a831408e6378bc02ebf8cc09b52c96ca86f6bab4` from 2026-08-22 while the reusable dev toolchain
  remains independently pinned. That snapshot still carries Hackage revision 1 of
  `smtp-mail-0.5.0.1`, whose `ram <0.22` bound predates current Hackage revision 2's verified
  `ram <0.23`; the package therefore has one narrow metadata-only jailbreak.

- Observation: the browser demo had preserved wire assumptions that were no longer exercised by
  the Haskell assemblies.
  Evidence: its JavaScript still sent `email` as the login principal and the old flat MFA proof.
  Updating it alongside the example READMEs exposed and removed the last current-user examples of
  both compatibility formats.


## Decision Log

- Decision: Keep Cabal packages as layer boundaries and organize modules by concept within each
  package.
  Rationale: this follows `haskell-jitsurei/patterns/api/servant-routes.md` without creating circular
  dependencies between domain, persistence, and transport.
  Date: 2026-07-24.

- Decision: Name moved modules concept-first and role-last, including
  `Shomei.Passkey.{Domain,Store,Workflow,Postgres}` and
  `Shomei.SigningKey.{Sign,Verify,...}.Jwt`; use small `Shomei.Persistence.*.Postgres` and
  `Shomei.Time.*` support modules for infrastructure that genuinely spans concepts.
  Rationale: this makes ownership visible without inventing a broad concept re-export or moving
  PostgreSQL/JWT dependencies into core, and it removes all old layer-first aliases while Cabal
  continues to enforce the architectural dependency direction.
  Date: 2026-08-23.

- Decision: Replace the single flat `ShomeiAPI` record with a thin hierarchy of per-concept
  `NamedRoutes` records. Several fields may mount records under the same `"v1" :> "auth"` or
  `"v1" :> "admin"` prefix.
  Rationale: this is the documented way to compose vertical slices while retaining named,
  order-independent server records. Use `:<|>` only at an embedding boundary where genuinely
  separate APIs are combined.
  Date: 2026-07-24.

- Decision: Use `MultiVerb` for a normal JSON operation whenever it owns any non-success status
  or multiple success representation/header shapes. A call to a fallible store or required
  dependency owns a typed 503 even when the happy path has only one payload.
  Rationale: every status the operation can intentionally answer belongs in its contract.
  `MultiVerb1` on a total in-process one-status endpoint adds no information, but treating a
  dependency failure as an unexpected exception hides a real 503 contract. This is the scope in
  the revised fleet standard.
  Date: 2026-07-26.

- Decision: Do not use MultiVerb for a named `Raw` route, a true streaming route, or a genuinely
  in-process, cannot-fail, single-status route. The initial typed exemption list is only
  `GET /.well-known/jwks.json` and `GET /openapi.json`; the WAI `/metrics` endpoint is a recorded
  `Raw`-style boundary outside the Servant proxy.
  Rationale: those operations have no additional status contract for a response sum to express.
  Keeping the list exact and tested prevents both blanket adoption and convenient under-modelling.
  Date: 2026-07-26.

- Decision: Do not count auth combinator failures, request-decoder failures, rate-limiter
  responses, method-not-allowed responses, or unexpected faults when deciding whether a
  terminal route needs MultiVerb.
  Rationale: these occur before or around the handler. Keep them uniform in
  `ErrorFormatters`, auth/authorization combinators, middleware, and the top-level fault
  boundary, and document them separately from handler-owned alternatives.
  Date: 2026-07-24.

- Decision: Declare operation-specific pre-handler responses with pass-through Servant
  combinators that have both `HasServer` and `HasOpenApi` instances.
  Rationale: ordinary terminal verbs still need accurate OpenAPI documentation, but a
  path-indexed decorator would recreate the drift-prone catalog that MultiVerb removes. Types
  such as `PreHandlerResponses`, `CsrfProtected`, and `RateLimited` keep these responses in the
  exact served proxy without changing the handler result.
  Date: 2026-07-24.

- Decision: Use manual `AsUnion` instances for named route-result sums; do not use
  `GenericAsUnion`.
  Rationale: an explicit constructor-to-status mapping remains correct when two alternatives
  carry the same body type, which is common for `ProblemDetails`.
  Date: 2026-07-24.

- Decision: Give application MultiVerb routes one shared error tail covering 400, 401, 403, 404,
  409, 422, 429, 500, and 503, while parameterizing the success status/body/headers. Protocol and
  probe routes retain their own response vocabularies.
  Rationale: Shōmei has one closed `AuthError` sum. A single exhaustive conversion is safer than
  claiming a narrower list the type system cannot prove and then making a newly reachable error
  partial. The slightly over-broad document is the explicit fleet-standard tradeoff; it does not
  make a cannot-fail route MultiVerb.
  Date: 2026-07-26.

- Decision: RFC 9457 Problem Details, the current successor to RFC 7807, is the application error
  format. OAuth endpoints retain RFC 6749 errors, and health/readiness endpoints retain
  probe-specific payloads.
  Rationale: RFC 9457 is the current IETF specification and explicitly allows an existing
  domain-specific protocol error format when it is more appropriate. OAuth and probe clients
  must receive the shapes their protocols specify.
  Date: 2026-07-24.

- Decision: Mount `Servant.Health.HealthApi` under the top-level `"health"` field and use the
  released package without copying or wrapping its wire types, response list, `AsUnion`, server,
  check combinators, path literals, or test matrix.
  Rationale: both probe alternatives carry the same body type, so duplicating the manual status
  mapping is risky. The dependency also supplies a fixed fleet wire contract, exact path
  constants, OpenAPI schema, and a conformance kit that detects swapped live/ready wiring.
  Date: 2026-07-26.

- Decision: Replace `/health` and `/ready` outright with `/health/live` and `/health/ready`.
  Rationale: the old names collapse or obscure Kubernetes' restart-versus-traffic-gating
  semantics. There are no adopters to protect, and compatibility aliases would preserve the API
  ambiguity this pre-adoption polish is meant to remove.
  Date: 2026-07-26.

- Decision: Give every Shōmei problem code a stable HTTPS problem-type URI under the public
  repository documentation; reserve `about:blank` for a future error with no semantics beyond
  its HTTP status.
  Rationale: the type URI, not the extension `code`, is the RFC 9457 primary identifier. The
  `code` remains a convenient short extension and must correspond one-to-one with the URI
  fragment. The public documentation page makes each type dereferenceable.
  Date: 2026-07-24.

- Decision: Split known dependency unavailability from genuine internal failure in the core error
  vocabulary and PostgreSQL interpreters. The former is HTTP 503 and retryable; invalid persisted
  data, impossible state, and other internal failures are HTTP 500 and not retryable.
  Rationale: changing every internal error to 503 invites unsafe retries, while allowing a known
  database outage to escape as an exception hides an expected operation status.
  Date: 2026-07-26.

- Decision: Remove compatibility code instead of adding deprecated aliases, re-export shims,
  client folds, migration branches, or dual request decoders.
  Rationale: Shōmei has no adopted API or persisted production population, so preserving an
  unpolished surface creates permanent cost without protecting a user.
  Date: 2026-07-24.

- Decision: Delete the bespoke service-token and impersonation HTTP operations while retaining
  their reusable domain capabilities behind OAuth.
  Rationale: OAuth `client_credentials`, RFC 8693 token exchange, RFC 7662 introspection, and
  RFC 7009 revocation are the canonical machine-token and delegation API.
  Date: 2026-07-24.

- Decision: Require a key-encryption key and encrypted `enc:v1:` private-key rows in server and
  key-rotation paths.
  Rationale: there is no production plaintext key population to migrate, and a secure initial
  default is preferable to an optional-at-rest protection mode.
  Date: 2026-07-24.

- Decision: Retain tolerant audit-event decoding, all current database migrations, OAuth
  interoperability, and standard JWS algorithms.
  Rationale: those are data-evolution and protocol requirements, not compatibility layers for
  an obsolete Shōmei API.
  Date: 2026-07-24.

- Decision: Add the exact route/method inventory and dependency baseline in Milestone 0, but add
  the closed `ResponseModel` and operation-owned-503 witnesses atomically with the route aliases
  and MultiVerb response lists in Milestone 4.
  Rationale: before conversion, every application route is still a plain terminal verb, so the
  final classification witnesses would either fail the milestone's green-build requirement or
  assert the obsolete model. The existing HTTP suite already exercises every same-typed admin
  family through distinct observable behavior, while the exact inventory prevents silent route
  loss during the intermediate refactor.
  Date: 2026-08-23.

- Decision: Implement application route results as concept-owned success sums followed by one
  fixed, exhaustive application-error tail, with a single `AuthError` conversion and explicit
  manual `AsUnion` mappings.
  Rationale: this keeps each concept's success vocabulary local while ensuring every newly
  reachable closed-domain error remains representable, including the typed 503, without partial
  conversions or repeated same-body mappings.
  Date: 2026-08-23.

- Decision: Model application failures as `RespondAs ProblemJSON` and successful JSON bodies as
  `RespondAs JSON` in each MultiVerb list, and specialize `ServantHeaders` only where a route owns
  response headers.
  Rationale: media type is part of the typed response contract, and route-specific header
  recovery is narrower and safer than weakening client decoding globally.
  Date: 2026-08-23.

- Decision: Protect OAuth userinfo with a dedicated bearer-only `OAuthAuthenticated` combinator.
  Rationale: reusing application cookie/session authentication would leak RFC 9457 responses into
  an OAuth resource endpoint and would incorrectly make cookie mode change the endpoint's
  protocol. The dedicated combinator keeps RFC 6750 errors and challenges at the pre-handler
  boundary.
  Date: 2026-08-23.

- Decision: Make the generated Nix package default overridable and define Shōmei's multi-package
  server closure in `flake.module.nix`, with source-repository inputs locked in `flake.lock` and
  the project package set on the current `nixpkgs-unstable` snapshot.
  Rationale: the repository has no root Cabal file, and Cabal's source-repository pins are not
  visible to `callCabal2nix`. Explicit composition gives `packages.default`, the OCI image, and
  `nix flake check` the same reproducible server closure without changing the independently cached
  development toolchain.
  Date: 2026-08-23.


## Outcomes & Retrospective

Implementation completed on 2026-08-23. The existing Cabal package boundaries remain intact, but
domain, workflow, store, PostgreSQL, JWT, HTTP API, DTO, result, handler, and test modules now use
recognizable concept prefixes. The root Servant modules are thin `NamedRoutes` compositions, and
runtime witnesses prove sibling concepts sharing `/v1/auth` and `/v1/admin` dispatch to the right
handler. No old layer-first re-export modules remain.

The final served proxy contains 41 paths and 45 method/path operations. Every normal fallible
application operation and every OAuth/OIDC operation uses `MultiVerb`; the only ordinary typed
routes are `GET /.well-known/jwks.json` and `GET /openapi.json`, while `/metrics` remains a WAI
boundary. Application handlers return concept-owned sums backed by one exhaustive RFC 9457 error
tail with typed 503. OAuth routes retain OAuth-shaped errors, `/oauth/userinfo` is bearer-only at
its protocol boundary, and the imported `servant-health` API owns `/health/live` and
`/health/ready`. The generated client exposes those typed results and preserves operation-owned
headers. The obsolete service-token, impersonation, bare-probe, email-login fallback, flat MFA,
plaintext-key, optional-KEK, and legacy Argon2 surfaces are absent.

The released API cohort is Servant 0.20.3.0, `openapi-hs` 5.0.0,
`servant-openapi-hs` 5.1.0, and `servant-health` 0.1.0.0. Nix now composes the multi-package server
closure explicitly, locks Cabal source-repository dependencies as non-flake inputs, and uses
`nixpkgs-unstable` revision `a831408e6378bc02ebf8cc09b52c96ca86f6bab4` for project packages.
The reusable development toolchain remains independently pinned. The only metadata workaround is
the verified Hackage-revision relaxation for `smtp-mail-0.5.0.1` described above.

Final validation passed `nix fmt -- --fail-on-change`, `nix develop --command cabal build all`,
the complete serial `cabal test all --test-show-details=direct` run, byte-for-byte OpenAPI
regeneration, the 41-path/45-operation invariant query, `nix build .#default --no-link`,
`nix flake check`, source-hygiene audits, and `git diff --check`. Highlighted coverage includes
228 core tests, 56 PostgreSQL tests, 44 JWT tests, 35 Servant runtime tests, and 62 OpenAPI
examples. The principal lessons were to model response media types as part of the MultiVerb
contract, specialize client header decoding at the route result, keep OAuth authentication errors
out of the application envelope, and execute an already-built generator when standard output is
the artifact.


## Context and Orientation

Run all commands from `/Users/shinzui/Keikaku/bokuno/shomei`. Never inspect `/nix/store` or
search the filesystem root. Use Mori to locate dependencies before reading their APIs:

```bash
mori registry list
mori registry search servant
mori registry show haskell-servant/servant --full
mori registry show shinzui/openapi-hs --full
mori registry show shinzui/servant-openapi-hs --full
mori registry show shinzui/servant-health --full
mori registry docs shinzui/haskell-jitsurei
```

Before choosing bounds, verify Mori's local checkout against Hackage and upstream release tags.
As of 2026-07-26, the relevant released cohort is:

* `servant`, `servant-server`, and `servant-client` 0.20.3.0;
* `openapi-hs` 5.0.0;
* `servant-openapi-hs` 5.1.0;
* `servant-health` 0.1.0.0, with its public `testkit` sublibrary used only by tests.

Use PVP bounds that select that feature cohort:

```cabal
servant            >= 0.20.3 && < 0.21
servant-client     >= 0.20.3 && < 0.21
servant-server     >= 0.20.3 && < 0.21
openapi-hs         >= 5.0   && < 5.1
servant-openapi-hs >= 5.1   && < 5.2
servant-health     >= 0.1   && < 0.2
```

Add `servant-health` directly to `shomei-servant`, whose public route type mentions `HealthApi`;
to `shomei-client`, whose generated public client mentions `ProbeResult`; and to `shomei-server`,
which builds checks and imports the path constants. Add `servant-health:testkit` only to the
`shomei-server-test` stanza. Do not add a local `packages:` path or source-repository pin: 0.1.0.0
is released. Do not restore old git pins or the obsolete `servant-openapi` package name. Re-run
the authoritative registry and tag checks when implementing because release state can change.

The standards applied by this plan are:

* `haskell-jitsurei/patterns/core/standards.md`: GHC 9.12 or newer, GHC2024, one imported common stanza
  for every component, project prelude, and postpositive qualified imports.
* `haskell-jitsurei/patterns/api/servant-routes.md`: `NamedRoutes`, concept-first vertical slices,
  thin composition roots, field-local auth, runtime dispatch tests, typed operation outcomes, and
  only the three recorded terminal-combinator exemptions.
* `haskell-jitsurei/patterns/api/openapi-from-types.md`: derive from the exact served proxy, keep one
  deterministic generator, commit its artifact, and fail CI on drift.
* `haskell-jitsurei/patterns/api/rfc9457-problem-details.md`: the application Problem Details
  profile. Its `about:blank` default applies until a service hosts error documentation; this plan
  creates that documentation before minting stable type URIs. The URI remains the RFC problem-type
  identifier, with `code` as a one-to-one fleet extension and convenient short alias.
* `haskell-jitsurei/patterns/api/health-endpoints.md`: mount the released `servant-health`
  `HealthApi`; keep liveness dependency-free; make readiness dependency-aware; harden checks with
  the package combinators; use package path constants; and prove wiring with its test kit.
* `haskell-jitsurei/patterns/api/request-logging.md`: exclude the two package-owned probe paths
  from routine request logs using `Servant.Health.Paths.healthRawPaths`.

`shomei-core` owns domain types, effect ports, and workflows. `shomei-postgres` interprets ports
with Hasql. `shomei-jwt` owns signing, verification, and key protection.
`shomei-servant` owns the HTTP contract, DTOs, response sums, handler adapters, error formatters,
and OpenAPI derivation. `shomei-client` derives a client from the same route types.
`shomei-server` assembles the standalone runtime and configuration. Keep those dependency
directions.

### Target concept layout

The layer name is the final module component. The following table is the ownership map, not a
requirement to put every listed concern in one file; split a concept further when a module would
remain unwieldy.

| Concept | `shomei-core` ownership | `shomei-postgres` ownership | `shomei-servant` ownership |
| --- | --- | --- | --- |
| Account | user, login id, email, password, account lifecycle and one-time-token workflows/ports | user, credential, verification-token, reset-token stores | signup, profile, email verification, password reset/change, admin account lifecycle |
| Session | session, refresh token, login attempt, signup/login/refresh/logout workflows and unit of work | session, refresh-token, login-attempt stores and auth transaction runner | login, refresh, logout, current session, admin session operations |
| Passkey | passkey, pending ceremony, registration/passwordless workflows and WebAuthn port | passkey and ceremony stores | passkey registration, login, list, and removal |
| MFA | TOTP, recovery code, second-factor workflow and stores | TOTP and recovery-code stores | enrollment, verification, removal, recovery codes, challenge completion |
| Authorization | roles, permissions, grants, authorization workflows and stores | role/permission grant store | enforcing combinators and admin grant/revoke routes |
| ServiceAccount | service-account domain, credential verification, client-credentials workflow and store | service-account store | OAuth-facing machine credential adapter only; no bespoke route |
| OAuth | OAuth clients, authorization codes, token grants/exchange, OIDC claims and stores | OAuth-client and authorization-code stores | authorize, token, introspect, revoke, userinfo, and discovery |
| Delegation | delegated-token policy and token-exchange workflow | no separate adapter beyond session/audit stores | RFC 8693 grant arm only; no `/auth/impersonate` routes |
| Audit | event model, codec, query, publisher/reader ports | event publisher and query store | admin audit query |
| SigningKey | signing-key domain/store port | signing-key store | JWKS route; signing mechanics remain in `shomei-jwt` |
| Health | no domain aggregate | readiness reuses the signing-key store port | imported `HealthApi` mount only; concrete service checks are assembled in `Shomei.Health.Server` |

Genuinely cross-cutting modules remain small and explicitly named: `Shomei.Config`,
`Shomei.Error`, `Shomei.Id`, and `Shomei.Prelude` in core; transport plumbing such as cookies,
error formatters, and method middleware in servant. Do not preserve the layer-first
`Shomei.Domain.*`, `Shomei.Effect.*`, `Shomei.Workflow.*`, `Shomei.Postgres.*`, or monolithic
`Shomei.Servant.DTO` modules as re-export aliases after their declarations move.

The target transport composition is concept-shaped. Names are illustrative where the existing
domain language offers a better exact noun, but the hierarchy is required:

```haskell
data ShomeiRoutes mode = ShomeiRoutes
  { application :: mode :- "v1" :> NamedRoutes ApplicationApi
  , oauth :: mode :- NamedRoutes OAuthApi
  , wellKnown :: mode :- ".well-known" :> NamedRoutes WellKnownApi
  , health :: mode :- "health" :> NamedRoutes HealthApi
  , openapi :: mode :- "openapi.json" :> Get '[JSON] Value
  }
  deriving stock Generic

data ApplicationApi mode = ApplicationApi
  { account :: mode :- "auth" :> NamedRoutes AccountApi
  , session :: mode :- "auth" :> NamedRoutes SessionApi
  , passkey :: mode :- "auth" :> NamedRoutes PasskeyApi
  , mfa :: mode :- "auth" :> NamedRoutes MfaApi
  , adminAccount :: mode :- "admin" :> NamedRoutes AdminAccountApi
  , adminSession :: mode :- "admin" :> NamedRoutes AdminSessionApi
  , authorization :: mode :- "admin" :> NamedRoutes AuthorizationApi
  , audit :: mode :- "admin" :> NamedRoutes AuditApi
  }
  deriving stock Generic
```

Multiple fields intentionally share the `"auth"` and `"admin"` prefixes. Runtime dispatch tests
must prove that same-shaped siblings reach the intended named handler. `AppAPI` examples may use
`:<|>` only to mount the complete Shōmei API beside a host application's distinct API.

`HealthApi` is imported from `Servant.Health`; do not define a Shōmei copy. The umbrella record
mounts it directly because the package fixes the relative `live` and `ready` fields. OpenAPI and
client generation use this same `ShomeiRoutes` proxy, so the package-owned 200/503 alternatives
and `ProbeStatus` schema appear without a route decorator.

### Compatibility surfaces to remove

Delete the obsolete path and its tests/documentation in the same milestone that deletes its
implementation. Do not leave deprecated declarations.

| Existing surface | Final surface |
| --- | --- |
| optional `SignupRequest.loginId` plus email fallback | required `loginId :: Text`; optional `email :: Maybe Text` |
| optional `LoginRequest.loginId` plus alternate `email` | required `loginId :: Text`; no email field |
| `loginIdFromEmail` and `resolvePrincipal` | explicit `mkLoginId`; explicit optional `mkEmail` |
| `LoginResponse` decoder defaulting a missing `methods` field | `methods` is required on the MFA arm |
| flat `MfaCompleteRequest` with three optional proof fields | `ceremonyId` plus one tagged `MfaProof` sum |
| `WebAuthnConfig.mfaRequired` with widened MFA semantics | `MfaConfig.requireSecondFactor` |
| `POST /v1/auth/service-token` and static account-secret config | OAuth `client_credentials`; database-backed service accounts |
| `POST`/`DELETE /v1/auth/impersonate` | OAuth token exchange and `/oauth/revoke` |
| three-part `argon2id$salt$digest` verifier | PHC-formatted Argon2id only |
| optional KEK and plaintext private JWK rows | required KEK and encrypted `enc:v1:` rows |
| `rotateSigningKeyFor` compatibility wrapper | one encrypted-key rotation entry point |
| unused `DeleteExpiredCeremonies` store effect | maintenance sweeper is the sole bulk-delete path |
| custom `/health` and `/ready`, `HealthResponse`, `ReadyResponse`, `healthH`, and `readyH` | `servant-health` at `/health/live` and `/health/ready` |
| old module paths and old client wrapper signatures | new concept modules and result types only |

The MFA wire shape is:

```json
{
  "ceremonyId": "ceremony_...",
  "proof": {
    "type": "totp",
    "code": "123456"
  }
}
```

The other proof tags are `"passkey"` with an `assertion` field and `"recovery_code"` with a
`code` field. Unknown tags, missing payloads, and extra proof arms are decoding failures; there is
no fallback decoder for the earlier flat object.

### Selective response-model rule

Classify an endpoint from its complete operation contract after moving parsing and authorization
to their proper Servant boundaries:

1. If a normal JSON operation can produce any operation-owned non-success status, or more than
   one success status or representation/header shape, use a named MultiVerb response list, a
   named result sum, and a manual `AsUnion` instance.
2. Treat known unavailability of a store or required dependency as an operation-owned, retryable
   503. A store-backed route is therefore MultiVerb even when its happy path has only one payload.
   Make the interpreter return a typed dependency error; do not manufacture 503 from arbitrary
   exceptions.
3. Use an ordinary terminal verb only for a genuinely in-process, cannot-fail, single-status
   endpoint. Keep `Raw` and true streaming routes in their native forms. Record every exemption
   by operation ID and fail conformance tests if the inventory changes silently.
4. Authentication/authorization combinators, `FromHttpApiData`/`FromJSON` failures, the WAI rate
   limiter, 404/405 routing, and the unexpected-fault boundary do not themselves require
   MultiVerb. Document operation-specific pre-handler responses with typed pass-through
   combinators, not fake handler alternatives.
5. If a later feature adds or removes an operation-owned status, change the terminal combinator,
   result sum, client contract, and exemption inventory together.

RFC 9457 does not determine the terminal Servant combinator. It determines the representation
after an application error has been selected. The source of the response determines MultiVerb:

| Response source | Wire representation | MultiVerb? |
| --- | --- | --- |
| expected application failure selected by the handler | RFC 9457 `ProblemDetails` | yes, as a `RespondAs ProblemJSON` alternative |
| successful handler with two meaningful statuses or body/header shapes | the operation's success DTOs | yes |
| authentication, authorization, request decoding, CSRF, or rate limiting before the handler | RFC 9457 `ProblemDetails` | no; declare it on the enforcing/pass-through combinator |
| unexpected exception caught by the application fault boundary | RFC 9457 500 `ProblemDetails` without internal detail | no; it is not an expected handler result |
| known store or required-dependency unavailability | RFC 9457 503 `ProblemDetails` | yes; it is an expected operation fault |
| OAuth/OIDC protocol failure | the RFC 6749/OIDC error shape | based on handler outcomes, but never converted to `ProblemDetails` |
| either `servant-health` probe verdict | `ProbeStatus` at 200 or 503 | yes, already declared and mapped by `HealthApi` |
| one total, in-process handler success | the success DTO | no; use an ordinary verb |
| `Raw` or streaming response | its native representation | no; retain `Raw` or `Stream` |

The initial ordinary-route allow-list is:

| Route | Handler-owned result |
| --- | --- |
| `GET /.well-known/jwks.json` | 200 JWKS with cache header |
| `GET /openapi.json` | 200 OpenAPI document |

The WAI `/metrics` endpoint is also exempt as an explicit non-Servant/`Raw` boundary, not as a
third ordinary typed route. This list is deliberately exact and enforced in tests. Re-evaluate
any route whose handler still calls `throwError` or runs a fallible port: expected operation
errors must become MultiVerb alternatives, parsing/policy must move to a pre-handler boundary,
and dependency failure must become a typed 503. Unexpected exceptions alone do not justify
MultiVerb.

Examples that must use MultiVerb include signup, login, refresh, confirmation flows, credential
mutations, `me`, current-session lookup, passkey completion/removal, every TOTP mutation, MFA
completion, every store-backed list/read, administrative lookup/mutation routes, OIDC discovery,
OAuth authorize/token/userinfo/introspect/revoke, and both health probes. The OAuth alternatives
use OAuth response types, not `ProblemDetails`. The probe alternatives use package-owned
`ProbeStatus` and `ProbeResult`, not a Shōmei result or problem document.


## Plan of Work

### Milestone 0: freeze behavior and enforce the standards baseline

Start from a green tree. Run the build and tests before edits and record any pre-existing failure
in Surprises & Discoveries rather than silently changing expectations.

Add a route inventory test in `shomei-servant/test-openapi/Main.hs` that asserts the exact method
and path set. Add a response-classification test that asserts the ordinary-route allow-list above
and asserts that every other JSON terminal handler route uses MultiVerb after Milestone 4. Record
the WAI `/metrics` boundary separately. The test must recognize the package-owned `HealthApi` as
MultiVerb rather than attempting to inspect or reproduce its response list. Add
same-typed dispatch tests for sibling records that share `/v1/auth` or `/v1/admin`; give each
stub handler a distinct marker and call every path.

Regenerate `docs/api/openapi.json` once before changing route types and inspect the known
`session_expired`/`session_revoked` drift. Land or at least record that baseline delta separately
so the later MultiVerb diff can be reviewed against generated current behavior rather than a
stale artifact.

Export a route type alias for every record field. In the test suite define a closed
`ResponseModel` type family that recursively strips `:>` combinators, reduces `MultiVerb` to a
`MultiOutcome` marker, and reduces `Verb`/`Get`/`Post` to a `SingleOutcome` marker. Give every
route alias an explicit `ResponseModel Route :~: ExpectedMarker` witness. These compile-time
witnesses, rather than inference from OpenAPI, enforce the classification table.

Define a second closed family over a MultiVerb response list that recognizes `Respond`,
`RespondAs`, `RespondEmpty`, and `WithHeaders` alternatives by status. Give every store-backed
route alias an explicit `OperationOwnsStatus 503 Route :~: 'True` witness. This is distinct from
the pre-handler OpenAPI checks: it proves 503 is in the operation's own response list rather than
merely added by a decorator. The two ordinary route aliases must instead prove
`ResponseModel ... :~: SingleOutcome`; `HealthApi` is asserted as imported MultiVerb without
copying its list.

Normalize Cabal component settings while touching the package files. Every library, executable,
and test suite must import its package's GHC2024 shared stanza. In particular,
`shomei-servant-openapi-test` currently imports only `warnings`; make it import `shared` and keep
only genuinely test-local extensions in that stanza. Retain the existing project prelude and make
all moved/touched imports postpositive qualified.

Raise the Servant/OpenAPI bounds to the released cohort in Context and Orientation and add
released `servant-health` 0.1.0.0 to the three packages named there. Let Cabal solve them; do not
add a local path or source-repository-package pin. Confirm `cabal freeze --dry-run` or a normal
build does not select a pre-0.20.3 Servant package and that `servant-health` resolves the same
OpenAPI 5.x cohort.

Acceptance for this milestone is a green pre-refactor build plus tests that would fail if a route
were lost, dispatched to the wrong handler, or classified as ordinary/MultiVerb contrary to the
decision table.

### Milestone 1: remove compatibility surfaces

Delete dead public surface before reorganizing what remains.

In the account DTO and handlers, require `SignupRequest.loginId`, retain signup's optional email,
require `LoginRequest.loginId`, and delete login's email field. Validate these fields once and
pass typed values to workflows. Delete `Shomei.Domain.LoginId.loginIdFromEmail`,
`resolvePrincipal`, email-only request tests, and compatibility comments. Update all internal test
fixtures to construct a `LoginId` explicitly; do not add a differently named conversion helper.

Make `LoginResponse` decode exactly what it encodes. The MFA arm requires `methods`. Replace the
flat optional-field `MfaCompleteRequest` with `MfaProof = PasskeyProof | TotpProof |
RecoveryCodeProof` and the tagged wire shape specified above. Update schema, golden, client, and
round-trip tests and delete legacy-shape tests.

Move the policy now called `WebAuthnConfig.mfaRequired` into
`MfaConfig.requireSecondFactor`, because it governs passkey or TOTP factors rather than WebAuthn
alone. Rename the file/Dhall and environment settings to the MFA concept, including
`SHOMEI_MFA_REQUIRE_SECOND_FACTOR`; do not read the old name as a fallback.

Remove the bespoke `serviceToken` API field, DTOs, handler, OpenAPI entries, generated-client
wrapper, tests, and user documentation. Delete `Shomei.Workflow.ServiceToken.issueServiceToken`
and the file/env `ServiceTokenConfig` fields that define static accounts. Move only reusable
constant-time secret verification and hashing into the ServiceAccount concept. Rename the
remaining token lifetime setting to a machine-token/OAuth name if `client_credentials` or token
exchange still needs it; do not keep the old config field as an alias.

Remove both bespoke impersonation API fields, DTOs, handlers, OpenAPI entries, client wrappers,
tests, and user documentation. Keep the delegation policy, audit events, `act` claim, and minting
logic under Delegation/OAuth token exchange. Stop delegated access through `/oauth/revoke`.

In `shomei-postgres/src/Shomei/Crypto.hs`, accept only the PHC Argon2id form with embedded
parameters. Delete `legacyArgonOptions`, the three-part branch, and its tests. In
`shomei-jwt`, require `KeyEncryptionKey` rather than `Maybe KeyEncryptionKey`, reject anything
without the `enc:v1:` prefix, remove the unencrypted rotation wrapper, and update server/admin
configuration and tests to require a KEK. Because there are no adopted databases, do not add a
backfill or plaintext fallback.

Delete `DeleteExpiredCeremonies` from the pending-ceremony effect, in-memory interpreter, and
PostgreSQL interpreter. Keep the batched maintenance sweep as the sole bulk cleanup. Rewrite
comments in the env loader, event codec, login result, MFA workflow, and signing algorithm code
when “legacy” describes current behavior rather than an actual compatibility branch.

Run a scoped search at the end:

```bash
rg -n --glob '*.hs' --glob '*.cabal' --glob '*.md' \
  'DEPRECATED|deprecated|backward compatibility|source compatibility|legacy|service-token|/v1/auth/impersonate' \
  shomei-core shomei-postgres shomei-jwt shomei-servant shomei-client shomei-server docs/user
```

Every hit must either disappear or be recorded in the Decision Log with a concrete explanation
of why it is protocol/data evolution rather than compatibility with an old Shōmei surface.

### Milestone 2: reorganize core, persistence, and JWT support by concept

Move declarations according to the Target concept layout. Do one concept at a time: add the new
module, update its Cabal `exposed-modules`/`other-modules`, update imports and tests, build the
affected packages, then delete the old module. Use `git mv` for traceable moves when most of a
module moves intact. Split mixed modules with patches.

Name leaf modules for their role: for example, `Shomei.Passkey.Domain`,
`Shomei.Passkey.Store`, `Shomei.Passkey.Workflow`,
`Shomei.Passkey.Postgres`, and corresponding test paths. Do not create a broad
`Shomei.Passkey` re-export. Keep cross-concept dependencies pointing toward stable domain/port
types rather than importing another concept's HTTP or PostgreSQL modules.

Decompose the current aggregate workflow/export modules rather than preserving them. Any caller
that imported `Shomei.Workflow` or an old `Shomei.Domain.*`/`Shomei.Effect.*` path must move to the
owning concept module in the same commit. Do not add deprecated re-exports.

Keep the event codec capable of reading every event shape that the final clean schema can write.
Keep migration files so a new database can be constructed deterministically. This milestone is a
module/API reorganization, not a database-history squash.

While moving the error and persistence modules, separate known dependency failure from internal
corruption. Add `AuthDependency = PostgreSQL` and
`DependencyUnavailable !AuthDependency` to the closed error vocabulary, and make every Hasql
command failure use that constructor. Keep row-reconstruction, codec, invariant, and
impossible-state failures under `InternalAuthError`. Do not expose Hasql messages or SQL in either
public problem. Preserve the distinction through `runAppIO` and the Servant seam so route-local
total mappings can return a generic retryable 503 for the former and a non-retryable 500 for the
latter; do not turn the typed error into `IOException` first. Extend the closed dependency enum
only when another required dependency has an intentional operation-level availability contract.

Acceptance is that `shomei-core`, `shomei-postgres`, `shomei-jwt`, and their tests build without
any old layer-first compatibility module, and module dependency directions remain acyclic.

### Milestone 3: create vertical HTTP slices and a thin API root

Create concept-owned `Api`, `Dto`, `Result`, and `Handler` modules under `shomei-servant`, using
the Target concept layout. A `Result` module is needed only for slices with MultiVerb routes.
Keep the root `Shomei.Api`/`Shomei.Servant.Api` module limited to record composition, proxies, and
public API aliases. Keep the root server assembly limited to constructing the parallel hierarchy
of handler records.

Move request parsing into types where Servant can perform it before the handler. Add
`FromHttpApiData` newtypes for audit user/session IDs, timestamps, cursors, admin status filters,
and pagination cursors. Introduce an enforcing `RequireAdmin` combinator for the existing
admin-role-or-scope disjunction so handlers do not each call `requireAdmin`. Keep authentication
on the individual field or the smallest record whose every route shares it; do not authenticate
an unrelated parent record.

Replace the `Authenticated` type alias with an enforcing custom combinator that delegates to the
existing context `AuthHandler` and contributes its 401 responses through `HasOpenApi`.
Give `RequireRole`, `RequirePermission`, and the new `RequireAdmin` equivalent `HasOpenApi`
instances. Add pass-through `PreHandlerResponses responses`, `CsrfProtected`, and `RateLimited`
combinators: their `HasServer` instances leave handler types unchanged, while their `HasOpenApi`
instances add the declared response types to the operation. `CsrfProtected` marks unsafe
cookie-authenticated methods that the auth handler can reject with 403; do not add that response
to safe authenticated GETs. Put the markers in the route type wherever JSON/query/capture
decoding, CSRF policy, or WAI rate limiting can reject the request. Test that the rate-limiter's
runtime path/method inventory exactly matches routes carrying `RateLimited`.

Write the runtime dispatch tests before deleting the flat `ShomeiAPI` handler record. Mount
several records under the same prefix and prove all methods/paths reach distinct markers. The
exact served proxy used by the standalone server, embedded examples, OpenAPI generator, and
client must be one exported value.

Split `Shomei.Servant.DTO` and `Shomei.Servant.Handlers` completely. Delete the old modules after
all callers move. No aggregate re-export shim remains.

Replace the custom operations fields `health` and `ready` with one top-level field:

```haskell
health :: mode :- "health" :> NamedRoutes HealthApi
```

Import `HealthApi`, `ProbeCheck`, and `healthServer` from `Servant.Health`. Delete
`HealthResponse`, `ReadyResponse`, `healthH`, `readyH`, their custom OpenAPI instances and
arbitraries, and every Shōmei-owned response sum or `AsUnion` proposed for readiness. Change the
root handler constructor to accept liveness and readiness `ProbeCheck`s, in that order, and mount
them with `healthServer`. Keep the checks injectable instead of closing over production state so
the package test kit and embedding hosts can prove their own wiring.

Create `Shomei.Health.Server` in `shomei-server` for the concrete checks. Build liveness from an
in-process `boolCheck`, wrap it in `safeCheck`, put `withProbeTimeout` outside that wrapper, and
give it its own `newFailureTracker`. Build readiness from the existing signing-key store call:
an execution failure is named `postgres`, while a successful empty key set is named
`signing-key`; put that composite check through `sequenceChecks` and a distinct failure tracker.
The intended composition is:

```haskell
liveness =
  trackLiveness
    . withProbeTimeout 2_000_000 "liveness"
    . safeCheck "liveness"
    $ boolCheck "liveness" (pure True)

readiness =
  trackReadiness . sequenceChecks $
    [ safeCheck "postgres" $
        boolCheck "signing-key" (not . null <$> runSigningKeyQuery)
    ]
```

`runSigningKeyQuery` is the service-owned IO bridge for `listActiveSigningKeys`; it is not a new
library function. Keep the timeout in microseconds and outside `safeCheck` so its asynchronous
interrupt is not swallowed. Do not add downstream HTTP or incidental infrastructure checks.
Construct the two tracked checks once during server startup, not once per request.

Make the WAI application builder explicit about injection, for example
`application :: Env -> ProbeCheck -> ProbeCheck -> Application`. Production startup passes the
checks from `Shomei.Health.Server`; embedded hosts pass their own; tests pass controlled checks.
Do not retain the old one-argument application builder as a compatibility wrapper.

Use `probeContractTests` from `Servant.Health.TestKit` against that application builder. Retain a
separate Shōmei integration test for the production readiness check: a reachable database with an
active signing key is healthy, a reachable database with no active signing key fails under
`signing-key`, and an unavailable pool fails under `postgres`. Call a tracked failing check twice
and assert `failingSince` remains the first onset, then make it healthy and prove the next failure
starts a new run. The library test kit proves route wiring; these service tests prove Shōmei's
readiness policy.

Acceptance is that a contributor can locate a route, its wire DTO, response result, and handler
adapter under one concept prefix, changing field order cannot change routing, and Shōmei owns no
probe wire type or 200/503 mapping.

### Milestone 4: implement typed problem details and selective MultiVerb

Replace the hand-built Problem Details `Value` with an RFC 9457 profile:

```haskell
data ProblemDetails = ProblemDetails
  { problemType :: !Text
  , title :: !Text
  , status :: !Int
  , detail :: !(Maybe Text)
  , problemInstance :: !(Maybe Text)
  , code :: !Text
  , retryable :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data ProblemJSON
```

Give `ProblemJSON` `Accept` and `MimeRender`/`MimeUnrender` instances for
`application/problem+json`. Use shared Aeson options to encode `problemType` as `"type"` and omit
absent `detail` and `problemInstance`, encoding the latter as `"instance"`; use the same options
for `ToJSON`, `FromJSON`, and `ToSchema`. The schema marks `type` as a URI reference, constrains
`status` to 100 through 599, allows extension members, and requires Shōmei's profile fields
`type`, `title`, `status`, `code`, and `retryable`.

Define the problem-type URI from the public repository and the stable code:

```haskell
problemTypeFor :: Text -> Text
problemTypeFor code =
  "https://github.com/shinzui/shomei/blob/master/docs/user/problem-details.md#" <> code
```

Create `docs/user/problem-details.md` with an explicit HTML anchor for every code, its stable
title, HTTP status, retryability, safe client behavior, and whether `Retry-After` can accompany
it. Restrict codes to lowercase ASCII letters, digits, and underscore; with the fixed HTTPS base,
that makes every constructed type a valid URI reference without adding a URI library. The
catalog test must verify the base and code alphabet, verify that every URI has a matching
document anchor, and verify a one-to-one mapping between `type` and `code`.
`about:blank` is not emitted by the catalog because every current entry conveys Shōmei-specific
semantics. `code` and `retryable` are RFC 9457 extension members, not standard members; decoders
must ignore additional unknown extensions. `retryable` does not replace the standard
`Retry-After` header on 429 or a 503 for which the server knows an honest retry interval.

Extend `ProblemSpec` with `retryable` and make both
`toProblemError` (pre-handler paths) and returned MultiVerb problems call the same
`problemDetails` constructor. Test every catalog entry for HTTP/body status equality, stable code,
type URI, title, media type, and retryability. `detail` contains only occurrence-specific,
client-actionable text and is never a machine key or an implementation/debugging message.
`problemInstance` is absent until the request context has a safe opaque occurrence URI; never put
a stack trace, database identifier, token, or other secret into either optional field. Add a
decoder test with an unknown extension member and require successful decoding, as RFC 9457
requires clients to ignore extensions they do not recognize.

Define one application error tail and result vocabulary, then give each multi-outcome application
operation a named response-list alias and named result alias in its concept's `Result` module. A
representative shape is:

```haskell
type ApplicationErrorResponses =
  '[ RespondAs ProblemJSON 400 "Bad request" ProblemDetails
   , WithHeaders WwwAuthenticateHeaders ProblemWithAuthenticate
       (RespondAs ProblemJSON 401 "Authentication failed" ProblemDetails)
   , RespondAs ProblemJSON 403 "Forbidden" ProblemDetails
   , RespondAs ProblemJSON 404 "Not found" ProblemDetails
   , RespondAs ProblemJSON 409 "Conflict" ProblemDetails
   , RespondAs ProblemJSON 422 "Unprocessable content" ProblemDetails
   , WithHeaders RetryAfterHeaders ProblemWithRetryAfter
       (RespondAs ProblemJSON 429 "Too many requests" ProblemDetails)
   , RespondAs ProblemJSON 500 "Internal server error" ProblemDetails
   , WithHeaders RetryAfterHeaders ProblemWithRetryAfter
       (RespondAs ProblemJSON 503 "Required dependency unavailable" ProblemDetails)
   ]

type SignupResponses =
  WithHeaders CookieHeaders SignupCreatedResponse
    (Respond 201 "Account created" SignupResponse)
    ': ApplicationErrorResponses

type SignupResult = ApplicationResult SignupCreatedResponse
```

Define `CookieHeaders` with MultiVerb's `DescHeader`/`OptHeader` and an explicit `AsHeaders`
instance so cookie-bearing success alternatives preserve both `Set-Cookie` headers in cookie
mode and omit them in bearer mode. Do not wrap an existing Servant `Headers` value blindly;
MultiVerb's `WithHeaders` return type is controlled by `AsHeaders`.

Define `ApplicationResult a` with one success constructor and one constructor for each status in
`ApplicationErrorResponses`. Write a load-bearing manual `AsUnion` instance for every route's
complete response alias; keep the shared tail in one fixed order and never use `GenericAsUnion`.
Apply the same tail to every application MultiVerb route so
`AuthError -> ApplicationResult a` is total. When two failures share a status but have different
machine codes, the one status constructor carries `ProblemDetails`; the type URI is the primary
distinction and `code` is its short alias. OAuth, OIDC protocol, and health routes do not use this
application tail.

Define `WwwAuthenticateHeaders` and `RetryAfterHeaders` with `OptHeader`/`DescHeader`, plus
explicit `AsHeaders` return wrappers. Populate `WWW-Authenticate` only for problems that actually
challenge bearer authentication. Populate `Retry-After` for 429 and only for a 503 whose retry
interval is honest; leave either optional header absent otherwise. The shared tail is deliberately
over-broad in statuses, but it must not invent headers on occurrences where they do not apply.

Refactor the handler seam so workflows return `Either AuthError a` to a route-local total mapping.
Expected domain failures become result constructors. An unclassified error fails a test; do not
silently map a newly added `AuthError` to the wrong status. Known unavailable dependencies map to
503, genuine internal failures map to 500. The top-level exception boundary still catches
unanticipated exceptions and produces a 500 problem response for application routes.

Concretely, change the seam environment's runner from
`forall a. Eff AppEffects a -> IO a` to
`forall a. Eff AppEffects a -> IO (Either AuthError a)`. Plain port actions use the outer result;
workflows that already return `Either AuthError a` flatten the interpreter and workflow results
before route-local mapping. The authentication combinator maps the same typed result to a thrown
pre-handler problem because it runs before an operation handler. Delete `runPortChecked` and the
old HTTP-rendering `runAuth`/plain `runPort` helpers, and delete the standalone server's `ioError`
conversion: typed failures must not become exceptions before the route decides 500 versus 503.
An actual IO exception remains unexpected and reaches the fault boundary.

Use dedicated result sums for protocol endpoints:

* OAuth authorize models redirect headers and RFC 6749 errors.
* OAuth token/introspection/revocation model their success and RFC 6749 failure shapes.
* OIDC discovery models 200 and protocol-shaped 404.
* `servant-health` already models both probe routes at 200 and 503; Shōmei must not define a
  parallel result sum.

Leave the ordinary-route allow-list as ordinary verbs. Add a test that rejects `MultiVerb1` and
fails if an allow-listed route becomes MultiVerb without updating the Decision Log and test
fixture. Add a complementary test that a non-allow-listed JSON terminal route is MultiVerb, that
every store-backed route declares 503, and that the imported health sub-API remains package-owned
MultiVerb. `Raw` and streaming markers are checked separately rather than forced through this
binary assertion.

Acceptance is demonstrated by server tests that pattern-match result constructors before HTTP
serialization, integration tests for every status, and the classification tests.

### Milestone 5: derive OpenAPI and client behavior from the reorganized API

Make `Shomei.Servant.OpenApi` derive from the exact `shomeiRoutesAPI` proxy used by
`shomei-server`. Delete `routeErrors`, `baselineSpecs`, and every path-indexed response decorator.
MultiVerb supplies handler outcomes; `Authenticated`, authorization combinators,
`PreHandlerResponses`, `CsrfProtected`, and `RateLimited` supply operation-specific pre-handler
responses from the served proxy itself. Keep only document-wide metadata and
schema/operation-ID enrichment in the OpenAPI assembly. A global 404/405 or unexpected 500 need
not be copied onto every operation, because it is not an outcome of a matched operation.

Assert:

* every MultiVerb alternative appears at its declared status;
* `RespondAs ProblemJSON` alternatives advertise `application/problem+json`;
* every application problem schema includes `type`, `title`, `status`, optional `detail` and
  `instance`, and extension members `code` and `retryable`;
* every catalog type is a documented HTTPS URI, no catalog entry uses `about:blank`, and each
  body `status` equals its HTTP response status;
* OAuth alternatives advertise the OAuth JSON shape and required headers;
* cookie/redirect/cache headers appear on only the relevant alternatives;
* ordinary routes have their one handler success plus applicable pre-handler responses, without
  a fake MultiVerb union;
* every store-backed operation declares its retryable 503, and every operation whose total fault
  mapping accepts `InternalAuthError` declares a non-retryable 500;
* `/health/live` and `/health/ready` each advertise package-owned 200 and 503
  `application/json` responses with the `ProbeStatus` schema, while `/health` and `/ready` are
  absent;
* the OpenAPI path/method set exactly matches the served proxy;
* no removed route appears;
* every `operationId` is stable and unique;
* two consecutive generator runs are byte-identical.

Update `shomei-client` from the reorganized records. MultiVerb calls return the named result sum
as their success value; ordinary calls return the ordinary response. Remove wrappers for deleted
routes and old signatures. The two generated probe calls return `ProbeResult`; do not recreate
`HealthResponse`, `ReadyResponse`, or old-path wrapper functions. Do not convert a
`ProblemDetails` result constructor into
`Left ClientError`: `ClientError` is reserved for transport failure, decoding failure, or a
response that violates the declared API.

Update `shomei-server`, `shomei-admin`, all embedded examples, and tests directly to the new
modules and client results. There are no downstream compatibility shims to add. Mori
`dependents` can identify registered local projects for a separate coordinated change if any
current workspace project imports Shōmei, but that work must not alter this clean initial API.

Change `requestLoggingMiddleware` to skip `rawPathInfo` values in
`Servant.Health.Paths.healthRawPaths` when request logging is enabled. Use the same constants in
the Problem Details conformance exemption; do not restate `"/health/live"` and
`"/health/ready"` in Haskell. Keep failed probes observable through Kubernetes, metrics, and the
probe response rather than re-enabling per-request noise.

### Milestone 6: documentation, artifact generation, and final cleanup

Rewrite current user documentation, examples, and curl transcripts for the final API. Remove
service-token and bespoke impersonation pages or replace their content with OAuth
`client_credentials`, token exchange, and revocation. Document the required login ID, tagged MFA
proof, typed result sums, the RFC 9457 Problem Details profile, stable problem-type URIs, and
which routes are intentionally ordinary. Replace every current operational reference to
`/health` or `/ready` with `/health/live` or `/health/ready` according to its restart-versus-
traffic-gating purpose, document the exact `ProbeStatus` body, and update Kubernetes manifests,
process-compose checks, examples, smoke tests, and security/key-rotation guidance. Do not add a
transition period, redirect, or alias for the old paths.
Historical completed ExecPlans may continue to describe the state they implemented; add a note
only when a reader could mistake one for current user documentation.

Regenerate `docs/api/openapi.json` with the repository command. Inspect the diff for the removed
paths, exact new responses, problem media type, response headers, and unchanged unrelated paths.
Run formatting, build, all tests, and flake checks. Search for old modules/routes/symbols and bare
unqualified imports. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes &
Retrospective with evidence before marking the plan complete.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei`.

1. Establish the baseline and record versions.

   ```bash
   git status --short
   mori registry show haskell-servant/servant --full
   mori registry show shinzui/openapi-hs --full
   mori registry show shinzui/servant-openapi-hs --full
   mori registry show shinzui/servant-health --full
   curl -fsSL https://hackage.haskell.org/package/servant-health/preferred.json
   git ls-remote --tags https://github.com/shinzui/servant-health.git
   nix develop --command cabal build all
   nix develop --command env TASTY_NUM_THREADS=1 cabal test all
   ```

   Expected: only user-owned pre-existing changes are shown by Git; every package and test suite
   passes. If not, record the exact failure before refactoring.

2. Capture the current route and OpenAPI baseline.

   ```bash
   nix develop --command cabal run shomei-openapi > /tmp/shomei-openapi-before.json
   jq -r '.paths | to_entries[] | .key as $p | .value | keys[] | [$p, .] | @tsv' \
     /tmp/shomei-openapi-before.json | sort
   ```

   Expected: the baseline includes 43 paths and 48 method/path operations, including the old
   `/health` and `/ready`, before the three obsolete operations on two paths are removed and the
   two probe paths are replaced; record any changed count caused by intervening work.

3. Implement Milestones 0 through 5 one concept at a time. After each concept or route family:

   ```bash
   nix develop --command cabal build \
     shomei-core shomei-postgres shomei-jwt shomei-servant shomei-client shomei-server
   nix develop --command cabal test \
     shomei-core:shomei-core-test \
     shomei-postgres:shomei-postgres-test \
     shomei-jwt:shomei-jwt-test
   nix develop --command cabal test \
     shomei-servant:shomei-servant-test \
     shomei-servant:shomei-servant-openapi-test \
     shomei-client:shomei-client-test \
     shomei-server:shomei-server-test
   ```

   Expected: affected packages remain green. If a component name differs, obtain it with
   `cabal list-bin` or from the package's `.cabal` file and update this plan.

4. Regenerate OpenAPI deterministically.

   ```bash
   nix develop --command cabal run shomei-openapi > /tmp/shomei-openapi-one.json
   nix develop --command cabal run shomei-openapi > /tmp/shomei-openapi-two.json
   cmp /tmp/shomei-openapi-one.json /tmp/shomei-openapi-two.json
   cp /tmp/shomei-openapi-one.json docs/api/openapi.json
   jq empty docs/api/openapi.json
   ```

   Expected: `cmp` is silent, `jq` exits zero, and the committed artifact changes only as
   explained by this plan.

5. Inspect response and removal invariants.

   ```bash
   jq -e '
     (.paths["/v1/auth/service-token"] == null) and
     (.paths["/v1/auth/impersonate"] == null) and
     (.paths["/health"] == null) and
     (.paths["/ready"] == null) and
     (.paths["/health/live"].get.responses["200"] != null) and
     (.paths["/health/live"].get.responses["503"] != null) and
     (.paths["/health/ready"].get.responses["200"] != null) and
     (.paths["/health/ready"].get.responses["503"] != null) and
     (.paths["/v1/auth/signup"].post.responses["201"] != null) and
     (.paths["/v1/auth/signup"].post.responses["400"] != null) and
     (.paths["/v1/auth/signup"].post.responses["409"] != null) and
     (.paths["/v1/auth/signup"].post.responses["500"] != null) and
     (.paths["/v1/auth/signup"].post.responses["503"] != null)
   ' docs/api/openapi.json

   jq -e '
     .paths["/v1/auth/signup"].post.responses["409"].content
     ["application/problem+json"] != null
   ' docs/api/openapi.json
   ```

   Expected: both commands print `true`.
   The final document has 41 paths and 45 method/path operations: removing the service-token path
   removes one operation, removing the shared impersonation path removes two operations, and
   replacing two probe paths with two package paths is count-neutral. If intervening intentional
   API work changes the baseline, update the exact route-inventory test and this arithmetic in the
   same revision rather than weakening it to a lower bound.

6. Run source hygiene checks.

   ```bash
   rg -n --glob '*.hs' \
     'Shomei\.(Domain|Effect|Workflow|Postgres)\.|Shomei\.Servant\.(DTO|Handlers)|loginIdFromEmail|resolvePrincipal|legacyArgonOptions|DeleteExpiredCeremonies|HealthResponse|ReadyResponse|healthH|readyH|runPortChecked' \
     shomei-core shomei-postgres shomei-jwt shomei-servant shomei-client shomei-server

   rg -n --glob '*.hs' 'import qualified ' \
     shomei-core shomei-postgres shomei-jwt shomei-servant shomei-client shomei-server

   rg -n --glob '*.hs' 'MultiVerb1' shomei-servant shomei-client
   ```

   Expected: no old module/symbol imports, no prepositive qualified imports, and no
   `MultiVerb1`.

   Run a second path search over current code and user/deployment artifacts:

   ```bash
   rg -n '(/health([^/]|$)|/ready([^/]|$))' \
     shomei-core shomei-postgres shomei-jwt shomei-servant shomei-client shomei-server \
     docs/user process-compose.yaml flake.module.nix .github
   ```

   Expected: no current operational reference uses the removed bare paths. Historical completed
   plans may still contain them.

7. Run final repository gates.

   ```bash
   nix fmt -- --fail-on-change
   nix develop --command cabal build all
   nix develop --command env TASTY_NUM_THREADS=1 cabal test all
   nix flake check
   git diff --check
   git status --short
   ```

   Expected: all commands exit zero. Git lists only the intended source, test, documentation,
   OpenAPI, Cabal, and plan changes plus any pre-existing user-owned changes.


## Validation and Acceptance

Acceptance is behavioral, structural, and documentary.

The HTTP integration suite must cover every result constructor. At minimum it proves:

* signup returns 201, semantic validation returns 400, and a duplicate login ID returns 409;
* login and refresh return their documented result arms, including MFA and cookie headers;
* handler-returned problems use `application/problem+json`, contain the required `type`, `title`,
  `status`, `code`, and `retryable` fields, contain `detail` and `instance` only when the
  occurrence supplies them, and permit unknown extension members;
* every `type` is the documented HTTPS URI for its `code`, clients treat `type` as the primary
  identifier, and `about:blank` is absent from the Shōmei catalog;
* every body `status` equals the HTTP status, `title` is stable for a type, `detail` is
  client-actionable rather than machine-parsed, and internal 500 responses disclose no
  implementation detail;
* malformed JSON, malformed captures/query parameters, missing credentials, insufficient
  authorization, rate limiting, 404, and 405 use the same application problem constructor even
  though they are not MultiVerb handler arms;
* OAuth errors remain RFC 6749 JSON and carry `WWW-Authenticate` where required;
* the `servant-health:testkit` matrix passes against Shōmei's assembled application: both probes
  healthy; readiness alone failing at 503 while liveness stays 200; and liveness alone failing at
  503 while readiness stays 200. Bodies and `application/json` match `ProbeStatus`, and liveness
  has no external dependency;
* Shōmei's integration suite separately proves the removed `/health` and `/ready` paths return
  404 and that no redirect or compatibility handler intercepts them;
* removed service-token and impersonation paths return 404;
* OAuth client credentials and token exchange still provide the retained capabilities;
* plaintext signing keys and legacy Argon2 hashes are rejected;
* request bodies missing `loginId`, missing MFA `methods`, or using the old flat MFA proof are
  rejected.

The response-classification test must fail on both kinds of drift: using MultiVerb for one of the
two allow-listed in-process single-outcome routes, or using a plain verb for an operation-owned
error/status set. It must specifically fail when a store-backed route lacks 503. It must not infer
classification only from generated OpenAPI because pre-handler responses also appear there, and
it must treat package `HealthApi`, `Raw`, and streaming routes according to their recorded forms.

The OpenAPI conformance suite must compare the exact served path/method set with the generated
document, validate all response references, and check media types and headers per alternative.
There must be no path-indexed error catalog parallel to the route types.

The vertical-slice review is accepted when:

* every concept's domain/port/workflow, PostgreSQL interpreter, API/DTO/result/handler, and tests
  share a recognizable concept prefix;
* package boundaries and dependency directions are unchanged;
* root API and server modules only compose named records;
* no large `DTO`, `Handlers`, `Domain`, `Effect`, `Workflow`, or `Postgres` compatibility
  aggregator remains;
* same-prefix runtime dispatch tests pass;
* every Cabal component imports its GHC2024 shared stanza.

The final user-visible smoke test is:

```bash
nix develop --command cabal run shomei-openapi > /tmp/final-openapi.json
cmp /tmp/final-openapi.json docs/api/openapi.json
nix develop --command env TASTY_NUM_THREADS=1 cabal test all
nix flake check
```

All commands must exit zero without modifying the working tree.


## Idempotence and Recovery

Module moves are recoverable when performed one concept at a time and committed only after the
affected packages pass. Re-running formatters, generators, builds, and tests is safe. OpenAPI
generation is deterministic; generate into `/tmp`, compare, and copy only after validation so a
failed run cannot truncate the committed artifact.

Do not use `git reset --hard`, `git checkout -- .`, broad recursive deletion, or any command that
would discard user-owned changes. Before each milestone inspect `git status --short` and preserve
unrelated changes such as the currently untracked `assets/` directory.

If a move is interrupted, use `git status --short`, `git diff --name-status`, and the package's
Cabal module list to determine whether both old and new modules exist. Complete the imports and
Cabal change or reverse only the specific move with another `git mv`; never restore the entire
tree.

If the dependency solver selects Servant older than 0.20.3, stop and inspect all local bounds with
`cabal build --dry-run -v1`. Do not compensate by reintroducing the old manual OpenAPI response
catalog or a git pin. Align the released dependency cohort.

If a MultiVerb route fails to compile because two alternatives carry the same type, correct its
manual `AsUnion` mapping. Do not switch to `GenericAsUnion` or merge semantically distinct status
arms. If headers fail to round-trip, fix the route-specific `AsHeaders` instance and test both
cookie and bearer modes.

If a supposedly ordinary route still has an expected `throwError` or invokes a fallible port,
either move parsing/policy to a proper pre-handler combinator or reclassify the route as MultiVerb
with its typed failure status. Do not catch arbitrary exceptions as 503, add a hidden
classification exception, or preserve an old probe route as a recovery shortcut.


## Interfaces and Dependencies

The following interfaces are required, though concept prefixes may be refined consistently
during Milestone 2.

```haskell
data ProblemDetails = ProblemDetails
  { problemType :: !Text
  , title :: !Text
  , status :: !Int
  , detail :: !(Maybe Text)
  , problemInstance :: !(Maybe Text)
  , code :: !Text
  , retryable :: !Bool
  }

data ProblemSpec = ProblemSpec
  { code :: !Text
  , status :: !Status
  , title :: !Text
  , retryable :: !Bool
  }

data ProblemOccurrence = ProblemOccurrence
  { detail :: !(Maybe Text)
  , instanceUri :: !(Maybe Text)
  , wwwAuthenticate :: !(Maybe Text)
  , retryAfterSeconds :: !(Maybe Natural)
  }

problemTypeFor :: Text -> Text
problemDetails :: ProblemSpec -> ProblemOccurrence -> ProblemDetails
toProblemError :: ProblemSpec -> ProblemOccurrence -> ServerError
```

`ProblemJSON` must implement the Servant content-type classes for
`application/problem+json`. `problemDetails` is the only application-problem constructor used by
returned handler results, auth combinators, error formatters, and middleware. `problemTypeFor`
uses the fixed public documentation base and the catalog code; callers cannot supply an arbitrary
or deployment-specific type URI. The JSON options map `problemType` to `"type"` and
`problemInstance` to `"instance"`.

`problemDetails` uses only the body fields of `ProblemOccurrence`; `toProblemError` and returned
MultiVerb wrappers additionally render `wwwAuthenticate` and `retryAfterSeconds` as
`WWW-Authenticate` and `Retry-After`. Constructors for ordinary occurrences default both to
`Nothing`. Tests assert that the two rendering styles produce the same body and the same
applicable headers for an equivalent occurrence.

The core error interface additionally defines `data AuthDependency = PostgreSQL` and adds
`DependencyUnavailable !AuthDependency` to the existing `AuthError` sum. PostgreSQL execution
failures use that constructor; persisted-value reconstruction failures remain
`InternalAuthError`.

Application MultiVerb routes share `ApplicationErrorResponses` and `ApplicationResult a` from
Milestone 4, then export named aliases and an explicit mapping at the route boundary:

```haskell
type SignupResponses =
  WithHeaders CookieHeaders SignupCreatedResponse
    (Respond 201 "Account created" SignupResponse)
    ': ApplicationErrorResponses

type SignupResult = ApplicationResult SignupCreatedResponse

instance AsUnion SignupResponses SignupResult
```

Cookie-bearing alternatives additionally use:

```haskell
type CookieHeaders =
  '[ OptHeader (DescHeader "Set-Cookie" "Session cookie" Text)
   , OptHeader (DescHeader "Set-Cookie" "Refresh cookie" Text)
   ]

data CookieResponse a = CookieResponse
  { body :: !a
  , sessionCookie :: !(Maybe Text)
  , refreshCookie :: !(Maybe Text)
  }

instance AsHeaders CookieHeaders a (CookieResponse a)
```

Adjust the field names if needed to avoid duplicate-record ambiguity, but preserve optional
headers in bearer mode and two headers in cookie mode.

The route-classification boundary requires three kinds of mappings:

```haskell
-- Expected handler outcome: returned as a route result.
authErrorToApplicationResult :: AuthError -> ApplicationResult a

-- Pre-handler application rejection: thrown centrally as RFC 9457.
toProblemError :: ProblemSpec -> ProblemOccurrence -> ServerError

-- Unexpected exception/fault: caught by the server boundary as HTTP 500.
internalProblemError :: SomeException -> ServerError
```

The transport environment preserves typed interpreter faults:

```haskell
data Env = Env
  { runPorts :: !(forall a. Eff AppEffects a -> IO (Either AuthError a))
  -- existing configuration and in-process fields follow
  }

runPortResult :: Env -> Eff AppEffects a -> Handler (Either AuthError a)
runWorkflowResult :: Env -> Eff AppEffects (Either AuthError a) -> Handler (Either AuthError a)
```

`runWorkflowResult` flattens the interpreter and workflow layers. It does not render HTTP; each
operation applies a total result mapping. Pre-handler authentication is the exception to that
return style because it must reject before a handler runs, but it consumes the same typed runner.

OAuth defines parallel protocol-specific results and does not depend on `ProblemDetails`.
Health defines no Shōmei response sum. The required package-owned and service-owned seams are:

```haskell
-- Imported from servant-health.
health :: mode :- "health" :> NamedRoutes HealthApi

shomeiRoutes :: Env -> ProbeCheck -> ProbeCheck -> ShomeiRoutes (AsServerT Handler)

-- Owned by shomei-server; constructed once at startup.
shomeiProbeChecks :: Env -> IO (ProbeCheck, ProbeCheck)

application :: Env -> ProbeCheck -> ProbeCheck -> Application
```

`shomeiProbeChecks` uses `Servant.Health.Check`; `application` and `shomeiRoutes` preserve the
liveness-then-readiness argument order. `requestLoggingMiddleware` and the Problem Details
exemption use `Servant.Health.Paths.healthRawPaths`. No Shōmei module defines `ProbeStatus`,
`ProbeResponses`, `ProbeResult`, or their `AsUnion` instance.

Pre-handler documentation is expressed in the served API:

```haskell
data PreHandlerResponses (responses :: [Type])
data CsrfProtected
data RateLimited

instance HasServer api context
      => HasServer (PreHandlerResponses responses :> api) context

instance (KnownPreHandlerResponses responses, HasOpenApi api)
      => HasOpenApi (PreHandlerResponses responses :> api)
```

`PreHandlerResponses` changes neither the handler arguments nor its return type. Its OpenAPI
instance folds the same `RespondAs ProblemJSON ... ProblemDetails` descriptions used by the
runtime problem catalog. `CsrfProtected` and `RateLimited` are specialized 403 and 429 markers
whose server behavior is already implemented by the auth handler and WAI middleware,
respectively. `Authenticated`, `RequireRole`, `RequirePermission`, and `RequireAdmin` enforce
their checks and add their own typed problem responses. Use Mori-resolved
`servant-openapi-hs` source when implementing `HasOpenApi`; do not guess at its lenses or
internal classes.

The exact dependency bounds are the released cohort recorded in Context and Orientation. The
implementation must use Mori-resolved source for API details and re-verify releases before
changing bounds. The only new production dependency is released `servant-health`; its `testkit`
sublibrary is test-only.

Revision note (2026-07-24): Rewrote the plan against the current 43-path/48-operation API and
current `haskell-jitsurei` standards. Replaced blanket MultiVerb conversion with an explicit
handler-outcome rule and ordinary-route allow-list; replaced the old wire envelope with typed
RFC 7807 `ProblemDetails`; updated the released Servant/OpenAPI cohort; expanded vertical slicing
to the route-record and handler composition roots; removed all compatibility shims and identified
existing pre-adoption API, config, crypto, key-storage, and store compatibility paths for
deletion. This revision was requested because Shōmei has not yet been adopted and its initial API
should be polished rather than compatibility-constrained.

Revision note (2026-07-24, Problem Details review): Reviewed the error contract against the
current IETF specification after the user asked how RFC 7807 relates to selective MultiVerb.
Changed the normative target to RFC 9457, which obsoletes RFC 7807; replaced the
custom-semantics-plus-`about:blank` design with documented HTTPS problem-type URIs; added optional
`instance`, extension-member and disclosure rules, and type/status conformance tests; and added a
response-source matrix showing that Problem Details controls error representation while
MultiVerb is used for operation-owned alternatives rather than pre-handler or unexpected-fault
responses.

Revision note (2026-07-26, API standards and health review): Reconciled the plan with the revised
`haskell-jitsurei` API standards and `servant-health` 0.1.0.0. Narrowed ordinary terminal routes
to the fleet's genuine exemptions; made typed dependency 503s part of store-backed operation
contracts; replaced custom `/health` and `/ready`, DTOs, handlers, and status mapping with the
package-owned `/health/live` and `/health/ready` `HealthApi`; added service-owned hardened checks,
path-constant logger exclusions, and the testkit wiring matrix; and explicitly rejected probe
aliases or redirects because Shōmei has no adopters.

Revision note (2026-08-23, Milestone 0 implementation): Associated implementation with intention
`intention_01m0r2mprpep1s12w89mb6hab5`; re-verified the released dependency cohort; recorded the
green build/test and 43-path/48-operation baseline; refreshed the pre-existing OpenAPI drift;
tightened dependency bounds; and added an exact route inventory test. Deferred only the final
compile-time response-model witnesses to the atomic MultiVerb conversion, because they cannot
truthfully pass against the pre-conversion API.
