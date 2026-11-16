---
id: 72
slug: make-oauth-errors-protocol-consistent-across-handlers-and-middleware
title: "Make OAuth errors protocol-consistent across handlers and middleware"
kind: exec-plan
created_at: 2026-11-16T05:08:40Z
intention: "intention_01m7hc17nwe6st49pcwr9srwvz"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-16T05:08:40Z
---


# Make OAuth errors protocol-consistent across handlers and middleware


This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Follow `agents/skills/exec-plan/FRICTION.md` when recording implementation friction, and distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Fix [GitHub issue #7](https://github.com/shinzui/shomei/issues/7): OAuth clients must receive an OAuth JSON error when Shōmei rejects their request, including rejection before a handler runs. A browser request requiring an interactive login must not receive a Basic client-authentication challenge. The same contract must hold in the standalone server, an embedded host, generated Haskell clients, and generated OpenAPI.

After implementation, an oversized `POST /oauth/token` returns HTTP 413 with `error: "invalid_request"`; a throttled request returns HTTP 429 with `error: "temporarily_unavailable"` and `Retry-After`. Both carry `application/json` and non-cacheable response headers. `GET /oauth/authorize` returning `401 login_required` no longer advertises Basic authentication. Application endpoints such as `/v1/auth/login` continue to use RFC 9457 problem documents.

This is a plan creation deliverable. Implementation is not yet performed. The plan addresses application-controlled HTTP responses; malformed HTTP rejected by Warp before WAI, socket admission failures, disconnected clients, and reverse-proxy-generated responses remain explicitly outside this application contract.


## Progress


- [ ] Milestone 1: Authentication challenges follow the authentication boundary; authorize, client authentication, and UserInfo regression tests pass.
- [ ] Milestone 2: OAuth middleware and routing rejections use one protocol policy in standalone and mounted applications, with bounded body consumption preserved.
- [ ] Milestone 3: Typed OAuth clients and generated OpenAPI agree with the actual rejection statuses, bodies, and headers.
- [ ] Milestone 4: The executable passes live OAuth contract checks, documentation explains the policy, and final validation passes.


## Surprises & Discoveries


## Decision Log


2026-11-15: Correct the response behavior rather than merely documenting the current 413/429 problem-document exception. Preserve the useful HTTP statuses and resource limits. Use `invalid_request` for 413 and `temporarily_unavailable` for 429. These status/code combinations are Shōmei's documented operational extension using the OAuth error envelope, not a claim that RFC 6749 section 5.2 prescribes 413 or 429.

2026-11-15: Make the generic OAuth error renderer challenge-free. The explicit `invalidClient` constructor owns `Basic realm="shomei"`; `missingToken` and `invalidToken` own Bearer challenges. Keep the existing 401 policy for client-authentication failures, including absent or body-supplied credentials where client authentication is required. Preserve authorize's existing login-required status and redirect policy while removing its erroneous Basic header. This avoids changing grant/authentication semantics as an incidental formatting fix.

2026-11-15: Apply haskell-jitsurei's protocol exception to problem documents, retain the OAuth `NamedRoutes` vertical slice and handwritten `MultiVerb` mappings, and make declared errors consumable by generated clients. Keep operational 413/429 errors in the shared OAuth result sum. Reuse the existing left-biased OpenAPI response merge rather than manually patching the generated JSON or introducing another rate-limit route registry.

2026-11-15: Use an explicit, shared OAuth mount policy for pre-routing response selection. A mount is the full sequence of decoded path segments identifying an OAuth namespace, such as `["oauth"]` or `["identity", "oauth"]`. Match complete segments from the start of the path, never an arbitrary occurrence of `oauth` or a raw string prefix. This permits the same boundary to serve nested embeddings and unknown paths within a registered namespace without taking over unrelated host routes.


## Outcomes & Retrospective


## Context and Orientation


The research baseline is commit `2b78861`, the same code referenced by issue #7. An unrelated untracked plan, `docs/plans/71-add-audited-administrative-recovery-for-lost-second-factors.md`, existed when this plan was created; leave it untouched. No parent MasterPlan is required. Other concurrent edits appeared during planning; recheck `git status` before implementation and preserve them.

Shōmei uses Servant to describe HTTP routes as Haskell types. `NamedRoutes` is a record whose named fields identify operations. `MultiVerb` declares the possible HTTP statuses and payload types for an operation; `AsUnion` converts a named Haskell result constructor to or from the corresponding response alternative. WAI is the HTTP application interface beneath Servant. WAI middleware can reject requests before Servant selects or executes a handler, so changing handler errors alone cannot fix this issue.

`shomei-servant/src/Shomei/Servant/Api.hs` composes `ShomeiRoutes`, including `OAuthRoutes = "oauth" :> NamedRoutes OAuthApi`. `shomei-servant/src/Shomei/OAuth/Api.hs` owns the authorize, token, UserInfo, introspection, and revocation routes. The token route carries the `RateLimited` marker. `shomei-servant/src/Shomei/Servant/Throttle.hs` derives throttled methods and paths from API types, including embedding prefixes; preserve this single source of truth.

`shomei-servant/src/Shomei/Servant/OAuth.hs` defines `OAuthErrorResponse`, `oauthError`, client-authentication parsing, and token DTOs (data types serialized on the wire). Today `oauthError` adds Basic to every 401 solely by status. `invalidToken` and `missingToken` replace its headers with Bearer-specific variants. `shomei-servant/src/Shomei/OAuth/Handler.hs` uses `oauthError status401 "login_required"` in authorization and converts handler failures through `typedOAuth` and `oauthServerErrorResult`. Thus the incorrect header survives into the typed response.

`shomei-servant/src/Shomei/OAuth/Result.hs` declares OAuth response headers and the shared `OAuthResult` alternatives for 400, 401, 404, 500, and 503. It currently lacks 413 and 429. Its `oauthServerErrorResult` maps any unrecognized status to `OAuthInternal`, so simply introducing new `ServerError` values would change their status to 500 if passed through that adapter. Its existing optional-header decoder must continue to accept absent `WWW-Authenticate` and `Retry-After`.

`shomei-server/src/Shomei/Server/Middleware/BodyLimit.hs` rejects declared and observed oversized bodies with a problem document. It rejects excessive known lengths without reading the body, meters unknown-length chunks, and avoids responding twice after a response has started. `shomei-server/src/Shomei/Server/Middleware/RateLimit.hs` sends a problem document with `Retry-After: 60` before routing. `shomei-server/src/Shomei/Server/Boot.hs` exports `hostMiddleware` and assembles body limiting before rate limiting. The bare `application` deliberately does not install this outer runtime boundary.

`shomei-servant/src/Shomei/Servant/Error.hs` installs `shomeiErrorFormatters`, currently returning problem documents for parsing and not-found failures. `shomei-servant/src/Shomei/Servant/Middleware.hs` rejects duplicate Authorization headers using the overly broad test `"oauth" elem pathInfo`, and rewrites every 405 into a problem document. Servant's content-negotiation failures, 406 and 415, bypass its error formatters. Its source was checked via [the Servant project](mori://haskell-servant/servant), project-relative `servant/servant-server/src/Servant/Server/Internal.hs` (artifact-level source URI pending), including `methodCheck`, `acceptCheck`, and the `ReqBody'` instance.

`shomei-servant/src/Shomei/Servant/OpenApi.hs` derives the document from the served API. Its `RateLimited` instance adds an application-shaped 429, but `addTypedResponses` deliberately leaves operation-owned statuses in place. Therefore a protocol-owned 429 in `TokenResponses` can override that default through existing type derivation. Pin this behavior with a test; do not assume that editing the response sum alone proves the resulting document. `shomei-client/src/Shomei/Client.hs` derives routes from the same API and exposes `OAuthResult` to callers.

The relevant local decisions are [ADR-1](../adr/0001-only-an-interactive-session-may-authorize-a-client.md), which requires live interactive sessions for authorization and forbids laundering machine/delegated credentials; [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md), which keeps credentials out of diagnostics; and [ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md), which requires standalone and embedded applications to use the same complete outer middleware. Preserve these constraints. No existing ADR directly defines protocol-specific error-envelope ownership; record that durable decision during implementation.

The required API patterns are [Servant routes](mori://shinzui/haskell-jitsurei/docs/api-servant-routes), [problem details](mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details), [OpenAPI from types](mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types), and [Hurl integration testing](mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing). Their applicable rules are: keep named vertical slices; declare operation failures and handwritten response mappings; handle pre-handler failures separately but consistently; let protocol-defined bodies take precedence over application problem documents; generate the contract from the served type; and distinguish Haskell, generated-contract, and live-executable testing. No repository-wide route refactor is necessary.

The protocol references are [RFC 6749 section 5.2](https://www.rfc-editor.org/rfc/rfc6749.html#section-5.2) for token error fields and client-authentication challenges, [RFC 6750 section 3](https://www.rfc-editor.org/rfc/rfc6750.html#section-3) for UserInfo Bearer challenges, and [RFC 6585 section 4](https://www.rfc-editor.org/rfc/rfc6585.html#section-4) for HTTP rate limiting. Preserve OAuth JSON and meaningful HTTP statuses; describe operational extensions explicitly.


## Plan of Work


### Milestone 1: Give each authentication boundary its own challenge


In `shomei-servant/src/Shomei/Servant/OAuth.hs`, remove status-driven challenge insertion from `oauthError`. Attach Basic explicitly in `invalidClient`; retain the two existing Bearer variants and shared no-store/no-cache headers. Correct the module comments that currently imply all OAuth failures are client-authentication failures. Expected failures must still cross the handler boundary as `OAuthResult` values; do not replace typed routes with bare throwing handlers.

Extend `shomei-servant/test/Main.hs` to test both the low-level renderer and the actual authorization route, with a registered client and valid redirect/PKCE parameters so the request reaches the login-required branch. Cover absent login with no configured login URL and rejected non-interactive sessions. Both remain `401 login_required` without Basic. A configured login redirect remains 302 with the original validated Location. Test failed Basic authentication, required-but-absent credentials, and body credentials on client-authenticated endpoints; these retain the existing 401 `invalid_client`/Basic policy. Missing UserInfo credentials retain a bare Bearer challenge, and invalid credentials retain Bearer with `error="invalid_token"`. A Basic header on a request that fails for an unrelated reason, such as `invalid_grant`, does not manufacture a challenge.

Acceptance is the focused Servant suite passing, with regression assertions that fail against the original generic-401 implementation. This milestone does not change token minting, session provenance, redirect validation, or credential-failure indistinguishability.


### Milestone 2: Select the protocol before middleware rejects a request


Add `shomei-servant/src/Shomei/OAuth/Boundary.hs` to own the shared OAuth mount policy, segment-safe namespace matching, and fixed safe protocol responses for edge failures. Keep it free of imports from `Shomei.Servant.Error` or server-only modules to avoid a dependency cycle. Use `OAuthErrorResponse` and the generic renderer for JSON serialization instead of copying JSON field names. Register the module in `shomei-servant/shomei-servant.cabal`.

Provide mount-aware variants of the error formatters and `problemMiddleware`, and of the body/rate middleware assembly. Retain the existing exported entry points as wrappers using the default `/oauth` mount. Add `hostMiddlewareWithOAuthMounts` in `shomei-server/src/Shomei/Server/Boot.hs`; its mount value must be passed to both edge rejection renderers. Embedding examples and tests must pass the same mount value to Servant formatters, response middleware, and host middleware. Update `examples/embedded-servant-app/app/Main.hs` and `examples/embedded-servant-app/src/Embedded/App.hs` at their middleware/context assembly sites, and update `docs/user/architecture.md` with that composition contract. OAuth namespace selection is independent of HTTP method so method errors and unknown paths inside that namespace still receive the intended envelope. Limiter eligibility remains method/path-derived through `ThrottledRoute`; namespace membership must not start throttling additional routes.

At the points where 413 and 429 are created, select OAuth JSON for a registered OAuth namespace and the existing problem response elsewhere. OAuth 413 is `invalid_request` with a constant oversized-request description; OAuth 429 is `temporarily_unavailable` with a constant throttling description and the existing `Retry-After: 60`. Neither has a challenge. Both carry `Cache-Control: no-store` and `Pragma: no-cache`. Do not alter admission decisions, bucket bookkeeping, cap size, middleware order, chunk consumption, or retry timing in this issue.

Make body/query/header parsing failures inside the namespace return 400 `invalid_request` with fixed descriptions that do not echo submitted secrets or parser diagnostics. Use the same mount selector for duplicate Authorization headers and unknown-route 404 responses. In the response middleware, normalize Servant's 405/406/415 within the OAuth namespace to JSON `invalid_request`, preserving their original HTTP status and semantic headers such as `Allow`. Replace stale content representation headers when changing the body. These operations are invalid HTTP/protocol requests, not authentication failures. Preserve existing protocol bodies and redirects; never consume a response stream or decode arbitrary downstream bodies to guess their protocol. A request with an unacceptable `Accept` header still gets a JSON error with 406, as the documented error contract.

Extend `shomei-server/test/Shomei/Server/MiddlewareSpec.hs` with deterministic known-length and chunked-body checks, cap equality, no body reads for immediate rejection, no double response, and a downstream-call counter for rate rejection. Extend `shomei-servant/test/Main.hs` for parsing, routing, duplicate-header, and mounted namespace behavior. Include `/identity/oauth/token`, `/oauth/unknown`, `/oauthish/token`, and a host path such as `/reports/oauth/token`; only configured namespaces get the OAuth policy. Execute one representative full `hostMiddleware` plus Servant token request early, then add the other cases once response headers and routing agree.

Acceptance is 413/429 OAuth JSON through the full assembly, bounded resource behavior, and problem documents on corresponding application routes. The focused server and Servant suites must pass.


### Milestone 3: Make the response types and clients tell the same story


In `shomei-servant/src/Shomei/OAuth/Result.hs`, extend `OAuthErrorResponses` and `OAuthResult` with explicit alternatives for 405, 406, 413, 415, and 429. Use descriptive constructors such as `OAuthMethodNotAllowed`, `OAuthNotAcceptable`, `OAuthPayloadTooLarge`, `OAuthUnsupportedMediaType`, and `OAuthTooManyRequests`. Extend handwritten `oauthToUnion`, `oauthFromUnion`, and `oauthServerErrorResult` mappings together. Preserve existing constructors and success payloads. The shared list can be broader than one handler's own failures; it describes the HTTP boundary that the generated client consumes. Add an optional typed `Allow` header to the error header wrapper if the 405 path carries it, updating `AsHeaders` and the specialized optional-header decoder together.

Add round-trip coverage for each new result alternative and for absent/present optional headers. In `shomei-client/test/Main.hs`, use the real assembled server boundary to force 413 and 429 through the generated token operation. The result must be `Right` with the corresponding `OAuthResult` constructor and protocol error data, not `Left FailureResponse` or a 500 result. Verify ordinary successful token issuance and existing 400/401/503 decoding still work. Generated client behavior, not merely a local JSON decoder, is the acceptance proof.

Extend `shomei-servant/test-openapi/Main.hs` to assert that `/oauth/token` declares JSON errors for the operational statuses, the OAuth body schema, cache headers, optional challenge semantics, and `Retry-After` for 429. In particular assert that `RateLimited` does not replace the protocol-owned 429 with `application/problem+json`. Assert that the application login route still declares problem-shaped 429. Keep operation IDs and route paths stable. Derive and regenerate `docs/api/openapi.json` using `shomei-openapi`; never edit that artifact by hand.

Acceptance is passing generated-client round trips and OpenAPI tests, plus two identical document generations. Adding public result constructors and a header field affects exhaustive matches/record construction downstream; document that source-compatibility impact in the affected package changelogs without cutting a release as part of this plan.


### Milestone 4: Prove the executable and document the boundary


Add `integration-tests/oauth/errors.hurl` with live request blocks for authorize's login-required response, failed client authentication, missing and invalid UserInfo Bearer credentials, oversized token bodies, throttled token requests, and a non-OAuth problem-document control. Assert status, media type, error field, relevant challenge presence/absence, cache headers, and Retry-After. Add routing/media-negotiation cases to this file where they are cheap; keep chunk-level resource accounting and all domain permutations in Haskell.

Add a packaged-server fixture to `shomei-server/test/Shomei/Server/E2ESpec.hs` (or a sibling test module registered in `shomei-server/shomei-server.cabal`). Reuse `withShomeiMigratedDatabase` and the OAuth-client setup already in that module. Start the actual `shomei-server` executable as a child process, with its absolute path supplied by `SHOMEI_TEST_SERVER_BIN`, a private temporary configuration, loopback listener, isolated database connection, and test-only key material. Use the loader described in `docs/user/deployment.md` and the fields in `config/shomei-types.dhall`; do not add production testing switches. Enable OIDC with no login URL, seed a valid public authorization client, and supply its valid request parameters to Hurl. Use separate server lifetimes for the normal and low-burst rate-limit cases to avoid order-dependent bucket exhaustion. Generate the oversized form body in the fixture's temporary directory, supply it as a Hurl variable/file input, and bound readiness waiting. Track and bracket the exact child process so failure always stops it and releases the database. Missing Hurl or a missing supplied executable must fail this live check, not silently skip it.

Add `pkgs.hurl` to the existing development tool list in `nix/haskell.nix`; use the locked Nix environment rather than a global install. Add `scripts/test-oauth-contract.sh` to build/find the executable with `cabal list-bin exe:shomei-server`, export `SHOMEI_TEST_SERVER_BIN`, and invoke the named packaged OAuth test with Tasty's pattern option. Add a `Justfile` recipe named `test-oauth-contract` invoking this script, and invoke that recipe in `.github/workflows/ci.yaml`. The ordinary all-tests command must also arrange this fixture's executable path (the fixture may resolve the already built executable with `cabal list-bin exe:shomei-server` when the environment variable is absent); avoid a mandatory test that only works through the convenience script. Build the server executable before running this test directly. The current `flake.module.nix` deliberately disables the server package's tests in its Nix derivation; keep live acceptance explicit in CI rather than assuming `nix flake check` runs Hurl. This repository currently has no Hurl suite, so this fixture and runner are part of the deliverable.

Update `docs/user/oidc.md`, `docs/user/machine-tokens.md`, `docs/user/problem-details.md`, and `docs/user/architecture.md` to explain the challenge policy, operational HTTP extension statuses, error fields, embedding mount policy, and the explicit lower-level/proxy exclusions. Add the appropriate entries in `shomei-servant/CHANGELOG.md`, `shomei-server/CHANGELOG.md`, and `shomei-client/CHANGELOG.md`. Create an ADR for protocol error ownership through the existing profiled ADR workflow, and update ADR-17 if its shared host assembly contract needs clarification. Do not edit unrelated haskell-jitsurei content as part of this repository fix.

Acceptance is a green Hurl run against the executable, final build/test/format checks, and documentation matching both generated OpenAPI and observed responses. Record concise results in this plan and triage any implementation friction before marking completion.


## Concrete Steps


Run commands from the repository root. The following establishes the working directory and the Mori connection supplied for this environment; this variable configures Mori only, not the test server's database.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
export MORI_PG_CONNECTION_STRING='host=/Users/shinzui/.local/state/postgresql dbname=mori user=shinzui connect_timeout=5'
mori registry search servant
mori registry show haskell-servant/servant --full
mori registry docs shinzui/haskell-jitsurei
mori path mori://shinzui/haskell-jitsurei/docs/api-servant-routes
```

Use Mori's returned local files for dependency API lookup. No dependency upgrade is proposed. If implementation proves one necessary, verify Hackage and upstream release tags before selecting bounds or a workaround; do not infer release availability from the local corpus. Do not inspect `/nix/store`.

Run focused checks after the corresponding milestone. These are existing suite names; the new acceptance tests must be included in them. PostgreSQL fixtures use isolated ephemeral instances. Limit concurrency to avoid the documented local ephemeral-database startup contention.

```bash
nix develop --command env TASTY_NUM_THREADS=1 cabal test \
  shomei-servant:shomei-servant-test \
  shomei-server:shomei-server-test \
  --test-show-details=failures -j1
nix develop --command env TASTY_NUM_THREADS=1 cabal test \
  shomei-servant:shomei-servant-openapi-test \
  shomei-client:shomei-client-test \
  --test-show-details=failures -j1
```

Before milestone 4 adds the packaged test, the first command needs no Hurl fixture. Afterwards the suite must locate the already built executable as described above. Each command should exit zero with every named suite passing. Demonstrate that the new focused regressions fail on the original behavior before relying on their success.

Generate the document with quiet Cabal output so compiler progress cannot corrupt JSON. Use a temporary directory and inspect the change before replacing the checked-in artifact.

```bash
set -e
nix develop --command cabal build exe:shomei-openapi
plan72_artifacts=$(mktemp -d)
nix develop --command cabal run -v0 exe:shomei-openapi > "$plan72_artifacts/openapi-one.json"
nix develop --command cabal run -v0 exe:shomei-openapi > "$plan72_artifacts/openapi-two.json"
jq empty "$plan72_artifacts/openapi-one.json"
cmp "$plan72_artifacts/openapi-one.json" "$plan72_artifacts/openapi-two.json"
cp "$plan72_artifacts/openapi-one.json" docs/api/openapi.json
jq '.paths["/oauth/token"].post.responses | {"401": .["401"], "413": .["413"], "429": .["429"]}' docs/api/openapi.json
```

The displayed responses must exist and use OAuth JSON schemas; the 429 response includes Retry-After. A failing `jq` or `cmp` stops artifact replacement.

After adding the live fixture and runner, execute final checks:

```bash
nix develop --command cabal build all
nix develop --command just test-oauth-contract
nix develop --command env TASTY_NUM_THREADS=1 cabal test all --test-show-details=failures -j1
nix develop --command just build-embedded-with-en
nix fmt -- --fail-on-change
nix flake check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

The live recipe must report successful Hurl assertions and fail on any unexpected status, media type, body, or header. Use local Apple containers if a separate Linux validation run is needed. No push, release, or issue-closing action is part of these instructions.


## Validation and Acceptance


The defining challenge regression is a valid authorize request without an interactive session and without a configured login URL: HTTP 401, `error=login_required`, and no Basic challenge. Test rejection of machine/delegated sessions too. Failed client authentication on token/introspection/revocation still returns the existing indistinguishable `invalid_client` body and Basic challenge. UserInfo preserves its two Bearer challenge variants. Successful authorization redirects and token issuance remain unchanged.

The defining middleware regressions are a token request exceeding the body cap and a token request exceeding a deterministic limiter budget. Observe respectively 413/`invalid_request` and 429/`temporarily_unavailable`, JSON rather than problem JSON, no challenge, and no-store/no-cache headers; the 429 also carries Retry-After. Both known-length and consumed unknown-length bodies must be covered. A known oversize request reads zero body chunks; a chunked request stops after crossing the cap; a rejected request does not execute the token handler. Test exact-limit acceptance and the existing no-double-response behavior.

Parsing failures and duplicate Authorization headers in an OAuth namespace yield safe 400 JSON errors; unknown paths yield 404 JSON errors. Wrong methods and unsupported representation headers yield 405/406/415 JSON errors with unchanged HTTP semantics and any original Allow header retained. No submitted credential sentinel appears in a response description or captured diagnostics. Do not weaken validation or accept a bad request to avoid producing an error.

Run the same namespace cases beneath an embedding prefix using a shared configured mount. Lookalike segments and unrelated host routes must not acquire OAuth errors. Verify application 413/429 still have RFC 9457 fields and `application/problem+json`. This proves the protocol exception is bounded and does not globally change error formatting.

The cross-component proof is a generated token client receiving `Right (OAuthPayloadTooLarge ...)` and `Right (OAuthTooManyRequests ...)` from the full HTTP assembly, paired with OpenAPI assertions for those same statuses/media types/headers. The executable/Hurl check then proves the production assembly actually installs that boundary. All three layers are required; a passing bare-handler test is insufficient for this issue.


## Idempotence and Recovery


No schema migration, account mutation in an existing deployment, or production configuration rewrite is required. Tests allocate isolated databases and temporary files, and release them through their fixture cleanup. Live fixtures own their child process handles; stop only those processes, never processes selected by broad name matching. Test-only key material must remain local to fixtures and must not appear in logs or committed generated files.

Formatting, tests, and OpenAPI generation are repeatable. Generate into a temporary file and validate before replacing the artifact. If a check fails, fix the relevant source and regenerate; do not hand-edit the generated schema. Preserve unrelated work and do not reset the working tree. A code rollback requires no database rollback, but reverting reintroduces the response interoperability defect.

Record the first implementation edit with the bundled provenance script after resolving the implementing agent's runtime model. Commits made during implementation use Conventional Commits and include both `ExecPlan: docs/plans/72-make-oauth-errors-protocol-consistent-across-handlers-and-middleware.md` and `Intention: intention_01m7hc17nwe6st49pcwr9srwvz` trailers. Stay on the current branch unless the user asks otherwise.


## Interfaces and Dependencies


The main interface changes are the new OAuth result alternatives and any added optional response-header field in `Shomei.OAuth.Result`, plus additive mount-aware variants of the exported middleware/formatter entry points. Keep existing default entry points source-compatible where possible. A proposed `OAuthMounts` value in `Shomei.OAuth.Boundary` represents non-empty lists of decoded path segments; reject an empty mount so the policy cannot silently capture the entire application. The default contains exactly `["oauth"]`. One pure matcher and one fixed edge-error mapping serve every adapter. An embedding host deliberately supplies its mounted namespace once and reuses it for routing formatters and the outer middleware.

The OAuth body remains exactly the established `error` and `error_description` representation; no application `ProblemDetails` fields or nested wrappers are added. HTTP status is independent of authentication scheme. Shared header rendering preserves cache policy and optional challenge/retry/Allow fields without duplicates. Existing grant workflows and persistence interfaces do not change.

Use the existing Servant, WAI, Aeson, `openapi-hs`, and `servant-openapi-hs` dependencies. Relevant package identities include [Servant](mori://haskell-servant/servant/packages/servant) and [servant-openapi-hs](mori://shinzui/servant-openapi-hs/packages/servant-openapi-hs). This plan selects no new Haskell dependency bounds or compatibility workaround. Hurl is a development/CI executable provided by the existing Nix lock, not a library dependency. If the packaged test needs a process-control library not already declared, locate it with Mori and verify its released API before adding the narrow test dependency.
