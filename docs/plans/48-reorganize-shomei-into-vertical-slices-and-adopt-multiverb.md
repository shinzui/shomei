---
id: 48
slug: reorganize-shomei-into-vertical-slices-and-adopt-multiverb
title: "Reorganize shomei into vertical slices and adopt MultiVerb"
kind: exec-plan
created_at: 2026-07-09T14:41:54Z
intention: "intention_01kx3mms1zevyvwvaspxcrm3cd"
---

# Reorganize shomei into vertical slices and adopt MultiVerb

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. It ships as a set of `cabal` packages under
`/Users/shinzui/Keikaku/bokuno/shomei`: a transport-agnostic core (`shomei-core`), a JWT
package (`shomei-jwt`), a WebAuthn package (`shomei-webauthn`), a PostgreSQL adapter layer
(`shomei-postgres`), a Servant HTTP layer (`shomei-servant`), a standalone executable
(`shomei-server`), and a generated client (`shomei-client`). It is consumed as a library by
several sibling services (meibo, kawa, nagare, kanmon, kikan).

Two things about shomei's HTTP surface fall short of the fleet-wide Servant conventions
recorded in `haskell-jitsurei/api/servant-routes.md` (the canonical best-practices document
this plan implements; it is registered in the mori registry under the key
`api-servant-routes`). This plan closes both gaps and, deliberately, leaves alone the one
thing shomei already does right.

First, **every terminal route in `shomei-servant/src/Shomei/Servant/API.hs` ends in a plain
verb** — `Post '[JSON] X`, `Verb 'POST 202 '[JSON] NoContent`, `Get '[JSON] X` — and every
error is *thrown* as a `ServerError` from inside the handler (through
`Shomei.Servant.Seam.runAuth`, which calls `Shomei.Servant.Error.authErrorToServerError`).
Because the error statuses are produced by a thrown exception rather than declared in the
route type, they appear nowhere in the generated OpenAPI document
(`docs/api/openapi.json`), nowhere in the generated client's result type
(`shomei-client`), and nothing forces a handler to actually be able to produce them. After
this change, each operation's response statuses are a **type-level list** (`MultiVerb`), the
handler returns a **plain sum value** (one constructor per status) instead of throwing, and
the OpenAPI document and the Haskell client both gain the error statuses as first-class
facts. You will see this working by regenerating `docs/api/openapi.json` and observing new
`400`/`404`/`409`/`503` response entries under each operation, and by driving the running
server with `curl` to see a duplicate signup answer `409` with a typed JSON envelope and a
malformed request body answer `400` with *the same* envelope shape rather than Servant's
default plain-text body.

Second, **`shomei-core` is organized layer-first**: `Shomei/Domain/*.hs`,
`Shomei/Effect/*.hs`, `Shomei/Workflow/*.hs`, and (in `shomei-postgres`)
`Shomei/Postgres/*.hs`. Everything about "the passkey concept" is smeared across
`Shomei/Domain/Passkey.hs`, `Shomei/Effect/PasskeyStore.hs`,
`Shomei/Effect/PendingCeremonyStore.hs`, `Shomei/Postgres/PasskeyStore.hs`,
`Shomei/Workflow/Passkey.hs`, and `Shomei/Workflow/Mfa.hs`. The convention says organize by
domain concept, not by layer, with the layer as the *leaf* of the module path. This plan
moves the modules that genuinely belong to one concept under that concept's prefix (for
example `Shomei/Passkey/Domain.hs`, `Shomei/Passkey/Store.hs`, `Shomei/Passkey/Workflow.hs`)
and, crucially, is **honest that shomei is a weaker fit for full vertical slicing than a
typical aggregate-shaped service** — a large fraction of its modules are cross-cutting
toolkit code (claims, tokens, JWT, crypto, the shared error sum, the shared port stack) with
no single owning concept, and those stay exactly where they are. The section
[The vertical-slice analysis](#the-vertical-slice-analysis) works this out module by module.

**What this plan does NOT touch, and why.** `Shomei/Servant/API.hs` is already a
`NamedRoutes` record (`ShomeiAPI`) with the auth combinator on the individual field — it was
the model for the convention's "auth goes on the field, not the record" rule, and the
document cites it. It is not converted; it is only edited to change each field's terminal
verb into a `MultiVerb`. The file contains two `:<|>` operators, inside the `AppAPI` type at
the bottom. Those are the **embeddability example** — mounting the whole `ShomeiAPI` record
alongside other routes in a host application — which is the one place `:<|>` is *correct* per
the convention (the alternatives have distinct types, so there is no misordering hazard).
**Leave the `AppAPI` `:<|>` operators alone. They are not a defect. Do not "fix" them.**

**Shōmei already derives its OpenAPI document the right way, and this plan must not regress it —
only complete it.** Unlike a service that needs OpenAPI *introduced*, shomei already meets most
of the canonical recipe (`haskell-jitsurei/api/openapi-from-types.md`, the companion to the
servant-routes document): `shomei-servant/src/Shomei/Servant/OpenApi.hs` derives the document
from `Proxy (NamedRoutes ShomeiAPI)` by `toOpenApi` (never hand-written), confines its orphan
`ToSchema`/`ToParamSchema`/`HasOpenApi` instances to that one module under `-Wno-orphans`,
assigns stable `operationId`s (`withOperationIds`), enriches title/version/description/servers,
emits the document from a dedicated executable (`shomei-openapi`,
`shomei-servant/app/openapi/Main.hs`), checks the artifact in at `docs/api/openapi.json`, and
pins the **`shinzui` forks — `servant-openapi` and `openapi-hs`, not Hackage
`servant-openapi3`/`openapi3`** (verify: the `cabal.project` `source-repository-package` blocks
for `github.com/shinzui/servant-openapi.git` and `github.com/shinzui/openapi-hs.git`, and
`shomei-servant.cabal` depending on `servant-openapi`/`openapi-hs`). That fork pin is
load-bearing precisely because this plan adds `MultiVerb`: Hackage `servant-openapi3` has no
`HasOpenApi` instance for `MultiVerb`, so on it every error response the conversion declares
would be silently dropped from the document. Shomei is correctly on the fork, which is why the
`MultiVerb` conversion below will actually *surface* the new statuses rather than lose them — do
not "simplify" the pin back to Hackage.

Because the `MultiVerb` conversion changes the API *type* the document is derived from (it adds
response alternatives to every operation), the generated document **will** change, and that
change is the visible proof the conversion worked: `docs/api/openapi.json` gains
`400/401/403/404/409/429/503` responses under each operation. Milestone 3 regenerates and
reviews that diff. Where shomei falls *short* of the recipe is narrow, and Milestone 3 closes
it: the `shomei-openapi` executable does not sort keys (so a regenerated artifact can reshuffle
rather than show a clean diff), there is no CI drift check, and the conformance test asserts a
path *count* and `ToJSON`/`ToSchema` agreement but not the exact path *set* nor that every
operation declares its error responses. Those are strengthened, not rebuilt.


## Progress

- [ ] Milestone 1 (spike): prove a single route (`signup`) can be a `MultiVerb` that still
      emits the two `Set-Cookie` headers on success. Pin the exact servant-0.20.2 combinator
      names for response headers by reading servant's source. Nothing else changes.
- [ ] Milestone 2: first add a runtime dispatch test pinning the same-typed admin families
      (`adminSuspendUser`/`adminReinstateUser`/`adminDeleteUser`/`adminRevokeSessions`/`adminPasswordReset`,
      all `AuthUser -> UserId -> Handler NoContent`; `adminGrantRole`/`adminRevokeRole`, both
      `AuthUser -> UserId -> Text -> Handler NoContent`) each to its own handler — `NamedRoutes`
      does not catch a same-typed transposition (falsified in meibo; see Surprises). Then add the
      shared response vocabulary (`Shomei.Servant.Response`) and convert
      every `ShomeiAPI` field to `MultiVerb`; rewrite the handlers to return the result sum;
      wire `ErrorFormatters` into the server assembly. `cabal build all && cabal test all`
      passes, the dispatch test included (OpenAPI conformance test updated in Milestone 3).
- [ ] Milestone 3: regenerate `docs/api/openapi.json` and review the diff (new
      `400/401/403/404/409/429/503` responses per operation); harden the `shomei-openapi`
      executable to emit **sorted keys and a trailing newline** so the artifact is byte-diffable;
      add a CI drift check (`cabal run shomei-openapi … && git diff --exit-code`) to
      `.github/workflows/ci.yaml`; strengthen the conformance test
      (`shomei-servant/test-openapi/Main.hs`) to assert the **exact 24-path set** (not just the
      count) and that **every operation declares its error responses**, keeping the existing
      `validateEveryToJSON` (`ToJSON` vs `ToSchema`); and fold the new typed error arms inside the
      `shomei-client` wrappers so their public signatures — and therefore nagare — are unchanged.
- [ ] Milestone 4: behavioral validation with `curl` against the running server (signup,
      login, duplicate-signup 409 envelope, malformed-body 400 envelope, combinator 401), and
      an OpenAPI regeneration diff.
- [ ] Milestone 5: vertical-slice `shomei-core` and `shomei-postgres` along the genuine
      concept seams (User/Account, Session, RefreshToken, Credential, Passkey, LoginAttempt,
      Audit, Verification, PasswordReset), leaving the cross-cutting toolkit modules in place.
      Add deprecated re-export shims for any moved module a downstream repo imports.
- [ ] Milestone 6: vertical-slice the `shomei-servant` DTOs by concept, leaving a deprecated
      `Shomei.Servant.DTO` re-export shim so nagare and `shomei-client` keep building. Keep
      the `ShomeiAPI` record and the `shomei-client` field structure stable.
- [ ] Milestone 7: reconcile this plan with roadmap plan 40
      (`docs/plans/40-api-v1-prefix-and-universal-problem-details-error-envelope.md`), which
      independently claims the "universal error envelope" integration point; amend docs; note
      remaining work in Outcomes.


## Surprises & Discoveries

Findings from the pre-implementation audit that shape the plan. Add to this as work proceeds.

- **2026-07-10 — `NamedRoutes` does not stop a same-typed transposition, and shomei has two such
  families.** A claim repeated across the fleet's ExecPlans — that a `NamedRoutes` record means
  "you cannot transpose two same-typed routes by accident" — was **falsified by experiment** in the
  meibo service. Meibo converted to `NamedRoutes`, swapped its two genuinely same-typed handlers
  (`byHandle`/`byCredential`, both `AuthUser -> Text -> Handler (MeiboResult PrincipalView)`), and
  `cabal build` **succeeded**: the swap compiles, serves, and silently returns the wrong data; only
  a runtime dispatch test caught it. (Meibo also moved a field to be first with all 43 tests still
  green, disproving the related claim that record field order governs static-segment-versus-capture
  precedence — servant hoists a literal segment above a sibling `Capture` regardless of declaration
  order.) A record removes only the *positional* failure mode; a differing-typed transposition is a
  compile error naming the field, while a same-typed transposition is caught only by a runtime
  dispatch test. Shomei's `ShomeiAPI` has two same-typed sibling families in its admin surface:
  five routes reduce to `AuthUser -> UserId -> Handler NoContent` (`adminSuspendUser`,
  `adminReinstateUser`, `adminDeleteUser`, `adminRevokeSessions`, `adminPasswordReset` — the exact
  transposition pairs are {`adminSuspendUser`, `adminReinstateUser`} at POST 204 and
  {`adminDeleteUser`, `adminRevokeSessions`} at DELETE 204, which differ only by their static
  segment), and two reduce to `AuthUser -> UserId -> Text -> Handler NoContent` (`adminGrantRole`,
  `adminRevokeRole`). The Milestone 2 handler rewrite is where one could be bound to the wrong field
  and compile clean, so Milestone 2 now requires a runtime dispatch test pinning each admin path to
  its own handler, written *before* the rewrite. Every non-admin route has a distinct handler type
  (the three cookie-issuing token routes `refresh`/`mfaComplete`/`passkeyLoginComplete` all *return*
  `WithCookies TokenPairResponse` but differ by request body, so they are distinct), so only the
  admin families need pinning. (The `AppAPI` `:<|>` operators are unaffected: those alternatives
  have distinct types, which is the one case where `:<|>` carries no misordering hazard.)

- **shomei already JSON-encodes its domain errors.** `Shomei/Servant/Error.hs` builds every
  `ServerError` with `errBody = Aeson.encode (object ["error" .= code, "message" .= msg])` and
  `Content-Type: application/json`. So a duplicate signup *already* returns
  `409 {"error":"login_id_taken","message":"…"}`, not Servant's plain-text default. The
  before/after that `MultiVerb` most visibly changes is therefore twofold: (a) routing-layer
  errors — a malformed JSON body or an unmatched route — currently return Servant's *plain*
  body, and `ErrorFormatters` will bring them under the same envelope; and (b) the statuses
  become visible in the OpenAPI document and the generated client instead of being an
  invisible property of `authErrorToServerError`. The validation in Milestone 4 shows both.

- **`MultiVerb` changes the generated client's result type, and that reaches nagare.** The
  `shomei-client` wrappers in `shomei-client/src/Shomei/Client.hs` call the `genericClient`
  field functions and today get back the plain body type
  (`ClientM (WithCookies TokenPairResponse)` etc.). Under `MultiVerb`, `genericClient` returns
  the *union* — the handler's result sum. nagare
  (`nagare/cli/nagare-access/src/Nagare/Access/ShomeiClient.hs`) pattern-matches
  `Shomei.login`/`Shomei.refresh`/`Shomei.mfaComplete` results as `Either ClientError X` with
  `X` the plain DTO. To keep nagare source-compatible, the `shomei-client` wrappers must fold
  the union's error arms back into a `Left`-shaped failure and keep their existing signatures.
  This is a real, load-bearing part of Milestone 3, not an afterthought.

- **shomei is a genuinely poor fit for full vertical slicing**, and the plan says so out loud
  (see [The vertical-slice analysis](#the-vertical-slice-analysis)). Its authentication
  "aggregate" is not partitioned the way meibo's Principal/Team/Role is: a single `signup` or
  `login` workflow atomically touches User, Credential, Session, RefreshToken, LoginAttempt,
  and Audit-Event state through one `AuthUnitOfWork` port. Many candidate concepts are a lone
  domain type plus one store plus one Postgres adapter and no routes of their own. And a large
  share of the code is cross-cutting toolkit (Claims, Token, Jwt, Crypto, Error, Config,
  Id, the in-memory interpreter). The plan slices the concepts that are genuinely cohesive and
  explicitly parks the rest.

- **shomei's OpenAPI setup is already forks-based and mostly recipe-complete — the fork pin is
  what makes the `MultiVerb` conversion safe.** `cabal.project` pins the `shinzui` forks
  (`servant-openapi` and `openapi-hs`), *not* Hackage `servant-openapi3`/`openapi3`; the
  `shinzui/servant-openapi` fork carries the `HasOpenApi` instance for `MultiVerb` (its own
  `cabal` describes it as a fork of biocad `servant-openapi3` retargeted at OpenAPI 3.1 via
  `openapi-hs`). This is why adding `MultiVerb` here will *surface* the error responses in the
  document rather than silently drop them, as it would on the Hackage packages. Three small gaps
  remain against the recipe, all closed in Milestone 3: the `shomei-openapi` executable uses
  `encodePretty` with the default config (so keys are **not sorted** and a regenerated artifact
  can reshuffle rather than diff cleanly — the recipe wants `confCompare = compare` and a
  trailing newline); `.github/workflows/ci.yaml` has no step that regenerates the artifact and
  fails on drift; and `test-openapi/Main.hs` asserts the path *count* (24) but not the exact path
  *set*, and does not assert that every operation declares its error responses.

- **Roadmap plan 40 already owns the "error envelope" integration point.** Plans 37–47 under
  `docs/plans/` are unimplemented roadmap (the routes still live under `/auth`, not `/v1`, and
  no `ProblemDetails`/envelope type exists yet). Plan 40,
  `40-api-v1-prefix-and-universal-problem-details-error-envelope.md`, is EP-3 of MasterPlan 7
  and declares itself "the breaking-change window" for both a `/v1` prefix and a universal
  error envelope. This plan introduces an error-envelope wire type too, so the two overlap and
  must be reconciled (Milestone 7 and the Decision Log).


## Decision Log

- Decision: Do not convert `Shomei/Servant/API.hs` away from `NamedRoutes`, and do not remove
  the two `:<|>` operators in its `AppAPI` type.
  Rationale: `ShomeiAPI` is already the convention-correct `NamedRoutes` record with the auth
  combinator on each field; the document holds it up as the model. The `AppAPI` `:<|>`
  operators mount the whole record alongside a host app's own routes, which is exactly the
  case the convention names as the *correct* use of `:<|>` (distinct-typed alternatives, no
  misordering hazard). Converting either would be churn with no benefit and would contradict
  the source-of-truth document.
  Date: 2026-07-09

- Decision: Milestone 2 must add a runtime dispatch test for shomei's same-typed admin route
  families, written *before* the handler rewrite.
  Rationale: `ShomeiAPI` contains two same-typed sibling families —
  `adminSuspendUser`/`adminReinstateUser`/`adminDeleteUser`/`adminRevokeSessions`/`adminPasswordReset`,
  all `AuthUser -> UserId -> Handler NoContent`, and `adminGrantRole`/`adminRevokeRole`, both
  `AuthUser -> UserId -> Text -> Handler NoContent` — whose fields differ only by a static path
  segment. `NamedRoutes` does **not** make a swap between same-typed fields a compile error; that
  claim was falsified by experiment in meibo (the swap compiled and served the wrong data; only a
  runtime dispatch test caught it — see Surprises & Discoveries). Milestone 2 rewrites every handler
  in one pass, which is exactly where an admin handler could be bound to a sibling's field and
  compile clean, so a runtime dispatch test pinning each admin path to its own handler must exist
  before that rewrite. No non-admin route needs it: each has a distinct handler type, so a
  transposition elsewhere is already a compile error. There was no field-order-versus-capture claim
  in this plan to correct.
  Date: 2026-07-10

- Decision: Adopt a single shared error-envelope wire type `ErrorEnvelopeWire { code, message,
  retryable }` (matching the `en-servant` reference and meibo), superseding the ad-hoc
  `{"error":…,"message":…}` bodies currently built in `Shomei/Servant/Error.hs`,
  `Shomei/Servant/Auth.hs` (`csrfRejected`), and the `auditEvents` handler.
  Rationale: The convention says `code` is the machine-readable field clients branch on and
  `retryable` distinguishes "fix your request" from "try again"; the whole fleet uses this
  shape. No downstream consumer parses shomei's error *body* today (nagare maps any `Left` to a
  generic failure without reading the body), so renaming the `error` field to `code` breaks no
  Haskell consumer. This is the moment to standardize because every route is already being
  edited. The field rename is a visible wire change for non-Haskell clients and is called out
  in Milestone 7's reconciliation with plan 40.
  Date: 2026-07-09

- Decision: The success arm of a cookie-carrying route (signup, login, refresh, logout, MFA
  complete, passkey login complete) keeps emitting the two `Set-Cookie` headers, modeled with
  servant `MultiVerb`'s response-header support rather than by dropping `WithCookies`.
  Rationale: The cookie transport is a security feature (EP-4/plan 31); the response must still
  carry `Set-Cookie` on success. `MultiVerb` supports per-alternative headers. Milestone 1 is a
  spike that proves this compiles on one route before the bulk conversion, because the exact
  combinator spelling in servant 0.20.2 is the one real unknown in this plan.
  Date: 2026-07-09

- Decision: The tagged-union `LoginResponse` (`complete` vs `mfa_required`, both HTTP 200)
  stays a single `Respond 200` alternative carrying `LoginResponse`; `MultiVerb` does not split
  it into two status alternatives.
  Rationale: Both arms are 200. The union is *within one status* and is already expressed by
  `LoginResponse`'s hand-written `ToJSON` and the hand-written `ToSchema` (a `oneOf`) in
  `Shomei/Servant/OpenApi.hs`. `MultiVerb` alternatives are keyed by status, so the two 200
  shapes are not two alternatives. Both hand-written instances are preserved unchanged.
  Date: 2026-07-09

- Decision: The `401` for a missing or invalid bearer token stays produced by the
  `Authenticated` combinator (`Shomei/Servant/Auth.hs`), *upstream* of the handler, and is NOT
  a `MultiVerb` response alternative. Likewise the `403 csrf_rejected` produced by the CSRF
  gate before the token is even verified.
  Rationale: No handler runs to *return* a combinator-raised error, so it cannot be a value in
  the handler's result sum. `MultiVerb` can only enumerate statuses a handler produces. These
  are documented in OpenAPI via the security scheme, not the response list. (A *domain* `401`
  — `InvalidCredentials` from `login` — is different: the handler produces it, so it can be a
  `MultiVerb` alternative; see Milestone 2.)
  Date: 2026-07-09

- Decision: Do not split the `ShomeiAPI` record into per-concept sub-records, and keep the
  `shomei-client` field structure flat.
  Rationale: `shomei-client`'s `genericClient` derives its record shape from `ShomeiAPI`, and
  nagare calls the flat client functions (`Shomei.login`, `Shomei.refresh`). Splitting the
  record into mounted sub-records would nest the client fields and break nagare's call sites for
  no gain — the API is a single toolkit surface, not a multi-aggregate service. Vertical slicing
  in shomei applies to `shomei-core`/`shomei-postgres` module trees and the DTO module, not the
  route record.
  Date: 2026-07-09

- Decision: For downstream compatibility use **deprecated re-export shims**, not a coordinated
  version bump.
  Rationale: shomei is a published library with external consumers (meibo, kawa, nagare,
  kanmon, kikan). The only module a downstream repo imports that this plan *moves* is
  `Shomei.Servant.DTO` (nagare imports it qualified; `shomei-client` re-exports its types). A
  one-line `Shomei.Servant.DTO` module that re-exports the new per-concept DTO modules, carrying
  a `{-# DEPRECATED #-}` pragma, keeps nagare and `shomei-client` building with zero changes on
  their side and gives them a release to migrate. A coordinated bump would force simultaneous
  edits across five repos for a mechanical rename — higher risk, no upside. Every other module a
  downstream imports is cross-cutting and does not move (see the analysis), so it needs no shim.
  Date: 2026-07-09

- Decision: Keep shomei on the `shinzui` OpenAPI forks (`servant-openapi`, `openapi-hs`) and,
  in Milestone 3, strengthen the *existing* artifact and conformance test to the full canonical
  recipe rather than treating any of it as new work.
  Rationale: shomei already derives its document, checks in `docs/api/openapi.json`, has the
  `shomei-openapi` executable, assigns stable `operationId`s, and pins the forks (whose
  `HasOpenApi (MultiVerb …)` instance is exactly what lets this plan's new error responses reach
  the document — on Hackage `servant-openapi3` they would silently vanish). The recipe's
  remaining requirements it does *not* yet meet are three and small: (1) the executable must sort
  keys (`confCompare = compare`) and end with a trailing newline so the checked-in artifact is
  byte-diffable and a reviewer sees a real contract change, not a hash-order reshuffle; (2) CI
  must regenerate and `git diff --exit-code` so an un-regenerated API change fails the build; and
  (3) the conformance test must pin the *exact* path set and assert every operation declares its
  error responses — not merely the path count. These are folded into Milestone 3, which already
  regenerates the document and edits the conformance test, so no new milestone is needed. The
  derivation module `Shomei/Servant/OpenApi.hs` and its `withOperationIds` are unchanged.
  Date: 2026-07-09

- Decision: `Shomei.Domain.Claims`, `Shomei.Domain.Token`, `Shomei.Domain.SigningKey`,
  `Shomei.Error`, `Shomei.Id`, `Shomei.Config`, the whole `shomei-jwt` package, `Shomei.Crypto`,
  `Shomei.Effect.InMemory`, and the aggregate-agnostic ports (`Clock`, `TokenGen`, `Notifier`,
  `PasswordHasher`, `PasswordBreachChecker`, `TokenSigner`, `TokenVerifier`, `AuthUnitOfWork`)
  are cross-cutting and are NOT moved.
  Rationale: Each is either shared vocabulary consumed by every workflow and by downstream
  repos (Claims, Token, Error, Id, Config, SigningKey), or infrastructure with no single owning
  concept (Crypto, InMemory, the ports). Moving them would break downstream imports for a change
  the convention does not ask for — the convention slices *concept-owned* modules, and these
  have no owning concept. This is the honest core of shomei being a partial-slice case.
  Date: 2026-07-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What shomei is, package by package

All paths below are relative to the repository root
`/Users/shinzui/Keikaku/bokuno/shomei`. Each package is a directory with its own `.cabal`
file; the workspace is pinned by `cabal.project` at the root (GHC 9.12.4, plus several
`source-repository-package` pins for `codd`, `ephemeral-pg`, `hs-jose`, `webauthn`,
`servant-openapi`, and `openapi-hs`).

- `shomei-core` — the transport-agnostic domain: types, commands, events, the `AuthError`
  sum, the effect *ports* (interfaces), the in-memory interpreter, and the workflows. No
  Servant, WAI, PostgreSQL, or JWT dependency.
- `shomei-jwt` — JWT signing/verification and JWKS publishing (`Shomei.Jwt.{Key,Sign,Verify,
  Jwks,Rotation,KeyProtection}`).
- `shomei-webauthn` — the passkey ceremony interpreter over `tweag/webauthn`.
- `shomei-postgres` — PostgreSQL implementations of the core ports, plus `Shomei.Crypto`.
- `shomei-migrations` — `codd`-managed embedded SQL migrations plus a test-support sublibrary.
- `shomei-servant` — the HTTP layer: the `ShomeiAPI` record, the `Authenticated` and
  `RequireRole`/`RequireScope` combinators, the DTOs, the handlers, the effect→`Handler` seam,
  and the OpenAPI derivation.
- `shomei-server` — the standalone executable and its admin CLI.
- `shomei-client` — the generated Haskell client, derived from `ShomeiAPI` via `genericClient`.

### Terms of art used in this plan

Define these before using them.

**Servant** is the Haskell library that describes an HTTP API as a *type* built from
combinators joined by `:>`. `"auth" :> "login" :> ReqBody '[JSON] LoginRequest :> Post '[JSON]
LoginResponse` describes `POST /auth/login`.

**`NamedRoutes` record** is Servant's way of writing an API as a Haskell *record*, one field
per route, each field's type joined to the field name by the `:-` operator, and the record
parameterized by a `mode` type variable. `mode` is filled in differently to get different
things: `AsServerT Handler` yields a record of handlers, `AsClientT ClientM` yields a record of
client functions, `AsApi` yields a description. Because handlers are supplied by *field name*
rather than by position, the record removes the *positional* failure mode: you cannot miscount,
and inserting a route mid-record cannot shift every later handler. It does **not**, on its own,
stop you transposing two *same-typed* routes — binding one same-typed field's handler to another's
typechecks, compiles, and silently misroutes (falsified by experiment in meibo; see Surprises &
Discoveries). A transposition is a compile error only where the two fields have *different* handler
types; where they coincide, only a runtime dispatch test catches a swap. This is not academic for
shomei: `ShomeiAPI` contains same-typed admin families — five routes reduce to
`AuthUser -> UserId -> Handler NoContent` (`adminSuspendUser`, `adminReinstateUser`,
`adminDeleteUser`, `adminRevokeSessions`, `adminPasswordReset`) and two to
`AuthUser -> UserId -> Text -> Handler NoContent` (`adminGrantRole`, `adminRevokeRole`) — so those
must be pinned by a runtime dispatch test (see Milestone 2). `ShomeiAPI` is such a record.

**`MultiVerb`** is a Servant combinator that replaces a single terminal verb (`Post '[JSON]
X`) with a *type-level list of response alternatives*, one per HTTP status the operation can
return, and pairs it with a plain Haskell sum type the handler returns — one constructor per
alternative. The mapping between the sum's constructors and the response list is given by an
`AsUnion` instance. Example from the convention:

```haskell
type OkResponses (desc :: Symbol) a =
  '[ Respond 200 desc a,
     Respond 400 "Malformed request" ErrorEnvelopeWire,
     Respond 404 "Not found" ErrorEnvelopeWire,
     Respond 409 "Conflict" ErrorEnvelopeWire,
     Respond 503 "Store unavailable" ErrorEnvelopeWire
   ]
```

Here `Respond status description bodyType` is one alternative; `RespondEmpty status
description` is an alternative with no body (for `202`/`204`). The handler returns a sum like
`data Result a = Ok a | BadRequest ErrorEnvelopeWire | NotFound ErrorEnvelopeWire | …`, and an
`AsUnion` instance written *by hand* maps each constructor onto its position in the list.

**`AsUnion` / the union constructors `Z`, `S`, `I`.** A response list of length *n* is
represented at the value level as an *n*-ary sum (`NS` from the SOP — "sum of products" —
generics vocabulary). `Z (I x)` is "the first alternative, carrying `x`"; `S (Z (I x))` is
"the second"; each extra `S` shifts one position right. `I` is the identity wrapper. The
`en-servant` reference (`/Users/shinzui/Keikaku/bokuno/en/en-servant/src/En/Servant/API.hs`,
lines ~146–188) imports these and writes the instance out longhand. The final clause of
`fromUnion` matches the *one-past-the-end* shift into an empty `case impossible of {}` — the
**exhaustiveness witness**. If the response list grows, that clause stops compiling, which is
the point: a new status must be handled deliberately.

**`ErrorFormatters`** is a Servant context value that customizes the body Servant emits for
errors raised by its *routing layer* — a request body that fails to parse, or a path that
matches no route — *before any handler runs*. Supplying one lets those errors speak the same
JSON envelope as handler-produced errors. It is installed with `serveWithContext api
(envelopeFormatters :. authContext) server`.

**A vertical slice** means every module belonging to one domain concept shares one module
prefix named for that concept, with the *layer* (`Domain`, `Store`, `Postgres`, `Workflow`) as
the *last* path component. `Shomei/Passkey/Domain.hs`, never `Shomei/Domain/Passkey.hs`.

**A port / effect** in shomei is an `effectful` effect: an interface (`Shomei.Effect.UserStore`
etc.) with an in-memory interpreter (`Shomei.Effect.InMemory`) for tests and a PostgreSQL
interpreter (`Shomei.Postgres.UserStore`) in production. The full ordered stack an assembly
must provide is `Shomei.Servant.Seam.AppEffects`.

**`WithCookies a`** (`Shomei/Servant/Cookie.hs`) is a type alias for `Headers '[Header
"Set-Cookie" Text, Header "Set-Cookie" Text] a` — a response body carrying the two
`Set-Cookie` headers. In bearer-only deployments `applyCookies` sets them to no-ops; in cookie
transport they carry the session and refresh cookies.

### The current HTTP surface

`Shomei/Servant/API.hs` defines the `ShomeiAPI mode` record with **25 route fields spanning 24
distinct URL paths** (the `impersonate` and `stopImpersonate` fields share `/auth/impersonate`,
differing only by method). The fields, their terminal verbs today, and the statuses their
handlers can produce:

- `signup` → `Post '[JSON] (WithCookies SignupResponse)` (200; domain 400 invalid
  email/login-id, 400 weak password, 409 email/login-id taken).
- `login` → `Post '[JSON] (WithCookies LoginResponse)` (200 complete *or* 200 mfa_required;
  domain 400, 401 invalid credentials, 403 email-not-verified, 429 too-many-requests).
- `refresh` → `Post '[JSON] (WithCookies TokenPairResponse)` (200; 400, 401 token
  invalid/expired/reuse, 403 csrf from its own gate).
- `serviceToken` → `Post '[JSON] ServiceTokenResponse` (200; 400, 403 disabled/invalid/scope).
- `verifyEmailRequest`, `verifyEmailConfirm`, `passwordResetRequest`, `passwordResetConfirm` →
  `Verb 'POST 202 '[JSON] NoContent` (202; 400 malformed/invalid token, 409 already verified).
- `passwordChange` → `Authenticated :> … :> PostNoContent` (204; 400, 401, 403 blocked under
  impersonation).
- `logout` → `Authenticated :> … :> Verb 'POST 204 '[JSON] (WithCookies NoContent)` (204 with
  cleared cookies).
- `me`, `session` → `Authenticated :> … :> Get '[JSON] X` (200; 404 if the verified principal's
  row is gone).
- `passkeyRegisterBegin`/`Complete`, `passkeyList`, `passkeyDelete` → passkey enrollment
  (200/204; 400, 404 ceremony/passkey not found, 403 under impersonation).
- `mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete` → `Post '[JSON] (WithCookies
  TokenPairResponse)` / `Post '[JSON] PasskeyLoginBeginResponse` (200; 400, 401, 404).
- `impersonate`, `stopImpersonate` → 200 / 204 (400, 403).
- `auditEvents` → `Authenticated :> … :> Get '[JSON] AuditEventsPage` (200; 400 bad
  cursor/param; the handler enforces the `admin` role with `requireRole`, a 403).
- `jwks` → `Get '[JSON] Value` (200 always).
- `health`, `ready` → `Get '[JSON] X` (200; `/ready` returns 503 on a failed dependency, built
  by throwing `err503` today).

`Shomei/Servant/Handlers.hs` builds the `shomeiServer` record; each handler runs the workflow
through `Shomei.Servant.Seam.runAuth`, which turns a `Left AuthError` into a thrown
`ServerError` via `Shomei.Servant.Error.authErrorToServerError`. `Shomei/Servant/Error.hs`
maps all ~35 `AuthError` constructors to statuses (400/401/403/404/409/429/500) and encodes
`{"error":code,"message":msg}`.

`Shomei/Servant/OpenApi.hs` derives the document from `Proxy (NamedRoutes ShomeiAPI)`, with a
`ToSchema` per DTO, a free-form `ToSchema Value`, the hand-written `ToSchema LoginResponse`
(`oneOf`), a `ToParamSchema PasskeyId`, and hand-written `HasOpenApi` instances for the
`AuthProtect "shomei-jwt"` and `RequireRole`/`RequireScope` combinators. The `shomei-openapi`
executable (`shomei-servant/app/openapi/Main.hs`) serializes it; the conformance test
(`shomei-servant/test-openapi/Main.hs`) runs `validateEveryToJSON` over the API and asserts
`openapi == "3.1.0"` and **exactly 24 paths**.

### The vertical-slice analysis

This is the honest, module-by-module judgment the convention demands. Shōmei's authentication
"aggregate" is not cleanly partitioned — one `signup`/`login` workflow atomically spans User,
Credential, Session, RefreshToken, LoginAttempt, and Audit state through the `AuthUnitOfWork`
port. So the slicing here is *by cohesive concept where one genuinely exists*, and a large,
explicitly-named remainder stays put.

**Concepts that get a slice** (each owns a domain type, at least one store port, its Postgres
adapter, and — where one exists — a workflow):

- **User / Account.** `Shomei/Domain/User.hs`, `Shomei/Effect/UserStore.hs`,
  `Shomei/Postgres/UserStore.hs`, `Shomei/Workflow/Account.hs` (email verification, password
  reset, password change) → `Shomei/User/{Domain,Store,Postgres}.hs` and
  `Shomei/User/Account.hs`. `Shomei/Domain/LoginId.hs` and `Shomei/Domain/Email.hs` (the user's
  identity value types) go under `Shomei/User/` as `LoginId.hs` and `Email.hs`.
- **Credential (password).** `Shomei/Domain/Credential.hs`, `Shomei/Domain/Password.hs`,
  `Shomei/Domain/CommonPasswords.hs`, `Shomei/Effect/CredentialStore.hs`,
  `Shomei/Postgres/CredentialStore.hs`, `Shomei/Workflow/Breach.hs` →
  `Shomei/Credential/{Domain,Password,CommonPasswords,Store,Postgres,Breach}.hs`.
- **Session.** `Shomei/Domain/Session.hs`, `Shomei/Effect/SessionStore.hs`,
  `Shomei/Postgres/SessionStore.hs`, `Shomei/Workflow/Session.hs` →
  `Shomei/Session/{Domain,Store,Postgres,Workflow}.hs`.
- **RefreshToken.** `Shomei/Domain/RefreshToken.hs`, `Shomei/Effect/RefreshTokenStore.hs`,
  `Shomei/Postgres/RefreshTokenStore.hs` → `Shomei/RefreshToken/{Domain,Store,Postgres}.hs`.
- **Passkey.** `Shomei/Domain/Passkey.hs`, `Shomei/Effect/PasskeyStore.hs`,
  `Shomei/Effect/PendingCeremonyStore.hs`, `Shomei/Effect/WebAuthnCeremony.hs`,
  `Shomei/Postgres/PasskeyStore.hs`, `Shomei/Postgres/PendingCeremonyStore.hs`,
  `Shomei/Workflow/Passkey.hs`, `Shomei/Workflow/Mfa.hs`, and (in `shomei-webauthn`)
  `Shomei/WebAuthn/Ceremony.hs` → `Shomei/Passkey/{Domain,Store,PendingCeremony,Ceremony,
  Postgres,PostgresPending,Workflow,Mfa}.hs`. (`shomei-webauthn`'s `Shomei/WebAuthn/Ceremony.hs`
  can stay, or move to `Shomei/Passkey/WebAuthn.hs`; it is a separate package with a separate
  concern — the ceremony *interpreter* — so this plan leaves it as `Shomei/WebAuthn/Ceremony.hs`
  and notes the option.)
- **LoginAttempt (abuse throttling / lockout).** `Shomei/Domain/LoginAttempt.hs`,
  `Shomei/Effect/LoginAttemptStore.hs`, `Shomei/Postgres/LoginAttemptStore.hs` →
  `Shomei/LoginAttempt/{Domain,Store,Postgres}.hs`.
- **Verification (email verification tokens).** `Shomei/Domain/VerificationToken.hs`,
  `Shomei/Effect/VerificationTokenStore.hs`, `Shomei/Postgres/VerificationTokenStore.hs` →
  `Shomei/Verification/{Domain,Store,Postgres}.hs`.
- **PasswordReset.** `Shomei/Domain/PasswordResetToken.hs`,
  `Shomei/Effect/PasswordResetTokenStore.hs`, `Shomei/Postgres/PasswordResetTokenStore.hs` →
  `Shomei/PasswordReset/{Domain,Store,Postgres}.hs`.
- **Audit (auth events).** `Shomei/Domain/Event.hs`, `Shomei/Domain/EventCodec.hs`,
  `Shomei/Effect/AuthEventPublisher.hs`, `Shomei/Effect/AuthEventReader.hs`,
  `Shomei/Postgres/AuthEventPublisher.hs`, `Shomei/Postgres/AuthEventReader.hs` →
  `Shomei/Audit/{Event,EventCodec,Publisher,Reader,PostgresPublisher,PostgresReader}.hs`.

**Modules that stay put, and why** (this is most of the cross-cutting surface):

- `Shomei/Domain/Claims.hs` — `AuthClaims`, `Role`, `Scope`, `Audience`, `Issuer`: the shared
  token-claims vocabulary consumed by every workflow, by `shomei-jwt`, and by *three* downstream
  repos (meibo, kawa, nagare). No single owning concept.
- `Shomei/Domain/Token.hs` — `AccessToken`, `TokenPair`: shared currency across session,
  refresh, service-token, impersonation, and MFA. Consumed by meibo.
- `Shomei/Domain/SigningKey.hs` — the JWT key material vocabulary; paired with the whole
  `shomei-jwt` package. Consumed by nagare and the E2E test. Cross-cutting with JWT.
- `Shomei/Domain/OneTimeToken.hs` — shared by both Verification and PasswordReset; belongs to
  neither. Stays as a shared token type (e.g. keep at `Shomei/Domain/OneTimeToken.hs`).
- `Shomei/Domain/Command.hs` — `SignupCommand`, `LoginCommand`, `RefreshCommand`,
  `LogoutCommand`: the cross-concept command vocabulary the top-level `Shomei.Workflow` builds
  from. Spans concepts; stays.
- `Shomei/Domain/Notification.hs` — notifier payloads paired with the `Notifier` port; a
  cross-cutting delivery concern.
- `Shomei/Error.hs` (`AuthError`, `TokenError`, `PasswordPolicyViolation`) — one closed sum
  shared by *every* workflow and imported by nagare. Moving it would fragment the error
  vocabulary and break downstream. Stays.
- `Shomei/Id.hs`, `Shomei/Config.hs`, `Shomei/Prelude.hs` — shared identifiers, configuration,
  and prelude. Imported across the fleet. Stay.
- `Shomei/Workflow.hs` — the top-level `signup`/`login`/`refresh`/`logout`/`verifyToken`
  umbrella that composes many concepts; it is the cross-concept orchestrator. Stays at the root
  (optionally renamed `Shomei/Auth/Workflow.hs`, but this plan leaves it to avoid churn).
- `Shomei/Workflow/Impersonation.hs`, `Shomei/Workflow/ServiceToken.hs` — token-issuance flows
  that read many concepts and own no store of their own. This plan keeps them as feature
  workflows; they may move to `Shomei/Impersonation/Workflow.hs` /
  `Shomei/ServiceToken/Workflow.hs` if desired, but with no domain/store to accompany them the
  slice is one file, so the plan leaves them and notes the option.
- `Shomei/Effect/InMemory.hs` — the in-memory interpreter assembly spanning *all* ports.
  Cross-cutting. Stays.
- `Shomei/Effect/AuthUnitOfWork.hs` — the atomic write tail spanning User + Session +
  RefreshToken; the direct analogue of meibo's cross-aggregate `OrgStore`. No single owner.
  Stays.
- `Shomei/Effect/{Clock,TokenGen,Notifier,PasswordHasher,PasswordBreachChecker,TokenSigner,
  TokenVerifier}.hs` — aggregate-agnostic infrastructure ports. Stay (the analogue of meibo's
  `Clock`/`IdGen`).
- `Shomei/Postgres/{Codec,Database,Pool,Maintenance}.hs` and `Shomei/Crypto.hs` — Postgres
  plumbing and crypto helpers with no owning concept. Stay. `Shomei/Postgres/Pool.hs` is
  imported by nagare.
- The whole `shomei-jwt` package (`Shomei/Jwt/*`) — a cohesive crypto toolkit consumed directly
  by meibo, kawa, and nagare; not one aggregate. Stays.
- `Shomei/Servant/{Auth,Authz,Cookie,Error,Seam}.hs` — the servant combinators and seam are
  cross-cutting toolkit; `Auth` and `Authz` are imported by meibo and kawa. Stay.

**The honest bottom line.** After slicing, roughly nine cohesive concepts get a home, and an
equally large set of genuinely cross-cutting modules stay at their layer paths. That ratio is
the opposite of a clean aggregate service like meibo (three aggregates, almost everything
slices). It is stated here so a future reader does not mistake the remaining `Shomei/Domain/*`
and `Shomei/Effect/*` modules for unfinished work: they are cross-cutting by nature, and the
convention explicitly exempts them.

### Downstream consumers (who breaks on a move)

Verified by grepping the sibling repos under `/Users/shinzui/Keikaku/bokuno` for `import
Shomei.*` and `shomei-*` cabal dependencies:

- **meibo** imports `Shomei.Domain.Claims`, `Shomei.Domain.Token`, `Shomei.Id`,
  `Shomei.Config`, `Shomei.Jwt.Verify`, and `Shomei.Servant.Auth` (`AuthUser`,
  `authUserFromClaims`, `extractToken`, `Authenticated`). All cross-cutting, none moved →
  **meibo is unaffected.**
- **kawa** imports `Shomei.Domain.Claims`, `Shomei.Id`, `Shomei.Config`, `Shomei.Jwt.Verify`,
  `Shomei.Servant.Auth` (`AuthUser`, `Authenticated`, `authHandler`), and
  `Shomei.Servant.Authz` (`requireScope`). All cross-cutting, none moved → **kawa is
  unaffected.**
- **nagare** imports `Shomei.Client`, `Shomei.Config`, `Shomei.Domain.Claims`,
  `Shomei.Domain.SigningKey`, `Shomei.Error`, `Shomei.Id`, `Shomei.Jwt.Verify`,
  `Shomei.Postgres.Pool`, `Shomei.Migrations.TestSupport`, `Shomei.Server.{App,Boot,Keys}`, and
  — the one that matters — **`Shomei.Servant.DTO`** (qualified, constructing `SignupRequest`/
  `LoginRequest`/`RefreshRequest`/`MfaCompleteRequest` and pattern-matching
  `LoginCompleteResponse`/`LoginMfaRequiredResponse`/`TokenPairResponse`). nagare also depends
  on the `Shomei.Client` wrapper *result types* being the plain DTOs. → **nagare is the repo at
  risk**, on two axes: (a) the `Shomei.Servant.DTO` module move, mitigated by the re-export shim
  (Milestone 6); and (b) the `MultiVerb` client-type change, mitigated by folding the union arms
  inside the `shomei-client` wrappers so their signatures stay identical (Milestone 3).
- **kanmon** and **kikan** — flagged as project-level dependents by `mori registry dependents
  shinzui/shomei`, but neither has a `shomei-*` cabal dependency or an `import Shomei.*` in its
  sources (kanmon reimplements verification behind its own `Kanmon.Egress.Identity`). →
  **unaffected.**

Net: with the shim (Milestone 6) and the wrapper fold (Milestone 3), **no downstream repo
requires any change**. Absent those two mitigations, nagare would fail to build.

### Build, test, and run commands

All from the repository root inside the nix dev shell. The `justfile` provides recipes.

```bash
cabal build all
cabal test all
```

Test suites of interest: `shomei-servant-test` and `shomei-servant-openapi-test` (in
`shomei-servant/`), `shomei-core`'s hspec suite, and `shomei-server`'s `E2ESpec`
(`shomei-server/test/Shomei/Server/E2ESpec.hs`), which boots the real server over an ephemeral
PostgreSQL via `Shomei.Migrations.TestSupport.withShomeiMigratedDatabase` and drives it with
`http-client`. Database recipes: `just create-database` (idempotent), `just migrate`. The
OpenAPI document is produced by `cabal run shomei-openapi > docs/api/openapi.json`.


## Plan of Work

### Milestone 1 — Spike: one `MultiVerb` route that still sets cookies

Scope: prove, on the single `signup` route, that a `MultiVerb` success alternative can still
emit the two `Set-Cookie` headers, and pin the exact servant-0.20.2 combinator spelling. This
is the one genuine unknown; everything else in the plan is mechanical once it is resolved. At
the end of this milestone `signup` is a `MultiVerb`, the server still sets cookies on success,
and `cabal build all` succeeds. Nothing else has changed.

First read servant's `MultiVerb` source to learn the header combinator. Use mori to locate it
rather than guessing:

```bash
mori registry show haskell-servant/servant --full   # find the servant source path on disk
# then read Servant/API/MultiVerb.hs for the header combinators (WithHeaders / AsHeaders)
```

servant 0.20.2 (pinned as `servant >=0.20.2` in `shomei-servant.cabal`) provides response
headers inside `MultiVerb` via a header-carrying `Respond` variant. Read the module and record
the exact names in Surprises & Discoveries. The design you are proving is: the success arm is a
*header-carrying* `200` alternative whose body is `SignupResponse` and whose headers are the two
`Set-Cookie` values, and the handler's `Ok` constructor carries a value that both the body and
the headers are projected from.

Add a throwaway `signup`-only response type and result sum next to `ShomeiAPI` (you will
generalize it in Milestone 2). Convert only the `signup` field:

```haskell
-- Illustrative shape; confirm the header combinator name from servant's source in this
-- milestone and correct it before relying on it.
signup ::
  mode
    :- "auth"
      :> "signup"
      :> ReqBody '[JSON] SignupRequest
      :> MultiVerb 'POST '[JSON]
           (SignupResponses "Signed up")
           (AuthResult (WithCookies SignupResponse))
```

Rewrite `signupH` to return `AuthResult (WithCookies SignupResponse)` instead of running
through `runAuth` (which throws): run the workflow with a variant of the seam that yields
`Either AuthError a`, and map a `Left` through `faultToResult` (defined in Milestone 2) to the
error arm, a `Right` to `AuthOk (applyCookies …)`.

Acceptance: `cabal build all` succeeds; start the server (see Concrete Steps) and confirm
`curl -i -X POST …/auth/signup …` still returns `200` **and** the two `Set-Cookie` headers when
cookie transport is on. Record the exact combinator names and any type-inference wrinkles in
Surprises & Discoveries. Do not proceed to Milestone 2 until the cookie headers are proven to
survive the `MultiVerb` conversion.

### Milestone 2 — The shared response vocabulary and the full conversion

Scope: introduce a new module `shomei-servant/src/Shomei/Servant/Response.hs` holding the
error envelope, the response-list aliases, the result sum, the hand-written `AsUnion`
instances, and the total `faultToResult :: AuthError -> AuthResult a`. Convert every remaining
`ShomeiAPI` field to `MultiVerb`. Rewrite every handler in `Shomei/Servant/Handlers.hs` to
return the result sum instead of throwing. Install `ErrorFormatters` in the server assembly. At
the end, `cabal build all` succeeds and `cabal test all` passes except the OpenAPI conformance
test, which Milestone 3 updates.

**Before rewriting the handlers, pin the same-typed admin families with a runtime dispatch test.**
`ShomeiAPI` has two families whose fields share one handler type and differ only by a static path
segment: five routes reduce to `AuthUser -> UserId -> Handler NoContent` (`adminSuspendUser`,
`adminReinstateUser`, `adminDeleteUser`, `adminRevokeSessions`, `adminPasswordReset` — the closest
transposition risks are the exact-verb pairs {`adminSuspendUser`, `adminReinstateUser`} at POST 204
and {`adminDeleteUser`, `adminRevokeSessions`} at DELETE 204), and two reduce to
`AuthUser -> UserId -> Text -> Handler NoContent` (`adminGrantRole`, `adminRevokeRole`). Because
`NamedRoutes` does **not** make a same-typed transposition a compile error (falsified in meibo; see
Surprises & Discoveries), rewriting every handler in one pass is exactly the moment one admin
handler could be bound to a sibling's field and compile clean. Add a runtime dispatch test that
drives each of these admin paths against the real server and asserts each reaches its *own* handler
(suspending a user leaves the user suspended, not reinstated; granting a role grants it, not revokes
it), written *before* the handler rewrite, and keep it green through the conversion. Every non-admin
`ShomeiAPI` route has a distinct handler type (distinct `ReqBody` or distinct response — e.g. the
three cookie-issuing token routes differ by request body), so only the admin families need pinning.

`Shomei/Servant/Response.hs` defines the envelope exactly as the convention and the
`en-servant` reference specify:

```haskell
-- | The one error-body shape. `code` is stable and machine-readable; `retryable`
-- distinguishes "fix your request" (False) from "try again" (True).
data ErrorEnvelopeWire = ErrorEnvelopeWire
  { code :: !Text,
    message :: !Text,
    retryable :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Then the shared error tail, plus the success-status variants shomei needs (200, 202, 204,
and the two header-carrying variants for cookie-setting routes). The error tail is shared —
slightly over-broad per operation, but that is the price of a *total* `faultToResult`, exactly
the tradeoff the convention and the `en-servant` reference make:

```haskell
-- The statuses a shomei handler can *return* (not the combinator-raised 401/403; see below).
type ErrorTail =
  '[ Respond 400 "Invalid request"      ErrorEnvelopeWire,
     Respond 401 "Authentication failed" ErrorEnvelopeWire,
     Respond 403 "Forbidden"            ErrorEnvelopeWire,
     Respond 404 "Not found"            ErrorEnvelopeWire,
     Respond 409 "Conflict"             ErrorEnvelopeWire,
     Respond 429 "Too many requests"    ErrorEnvelopeWire,
     Respond 503 "Dependency unavailable" ErrorEnvelopeWire
   ]

type OkResponses      (desc :: Symbol) a = Respond 200 desc a  ': ErrorTail
type AcceptedResponses (desc :: Symbol)  = RespondEmpty 202 desc ': ErrorTail
type NoContentResponses (desc :: Symbol) = RespondEmpty 204 desc ': ErrorTail
```

The result sum has one constructor per position. Note the success constructor is polymorphic in
the body so the same sum serves every operation:

```haskell
data AuthResult a
  = AuthOk a                         -- 200 (or the empty-body successes; see below)
  | AuthBadRequest    !ErrorEnvelopeWire  -- 400
  | AuthUnauthorized  !ErrorEnvelopeWire  -- 401 (domain, e.g. InvalidCredentials)
  | AuthForbidden     !ErrorEnvelopeWire  -- 403
  | AuthNotFound      !ErrorEnvelopeWire  -- 404
  | AuthConflict      !ErrorEnvelopeWire  -- 409
  | AuthTooManyRequests !ErrorEnvelopeWire -- 429
  | AuthUnavailable   !ErrorEnvelopeWire  -- 503
  deriving stock (Generic, Eq, Show)
```

Write the `AsUnion` instance out **by hand**, following the `en-servant` reference longhand,
with the exhaustiveness witness as the final clause. Do NOT use `GenericAsUnion`: the
constructor-to-status correspondence is the load-bearing fact, and a change to the list must
break the build loudly. For the empty-body successes (`202`/`204`), provide a second `AsUnion`
instance whose `AuthOk` maps onto the `RespondEmpty` head (the body type is `()` /
`NoContent`).

The total fault conversion maps every `AuthError` constructor to a status. It is total because
`AuthError` is one closed sum and the error tail covers every status any handler can produce:

```haskell
faultToResult :: AuthError -> AuthResult a
faultToResult = \case
  InvalidEmail            -> AuthBadRequest   (env "invalid_email" "Email is not valid" False)
  InvalidLoginId          -> AuthBadRequest   (env "invalid_login_id" "Login identifier is not valid" False)
  WeakPassword _          -> AuthBadRequest   (env "weak_password" "Password does not meet policy" False)
  EmailAlreadyRegistered  -> AuthConflict     (env "email_taken" "Email is already registered" False)
  LoginIdAlreadyRegistered-> AuthConflict     (env "login_id_taken" "Login identifier is already registered" False)
  InvalidCredentials      -> AuthUnauthorized (env "invalid_login" "Invalid email or password" False)
  UserNotActive           -> AuthUnauthorized (env "invalid_login" "Invalid email or password" False)
  AccountLocked           -> AuthUnauthorized (env "invalid_login" "Invalid email or password" False)
  TooManyRequests         -> AuthTooManyRequests (env "too_many_requests" "Too many requests" True)
  SessionNotFound         -> AuthNotFound     (env "session_not_found" "Session not found" False)
  -- … one arm per AuthError constructor, transcribed from Shomei/Servant/Error.hs …
  InternalAuthError _     -> AuthUnavailable  (env "internal" "Internal authentication error" True)
  where env c m r = ErrorEnvelopeWire c m r
```

Transcribe every arm directly from the existing `authErrorToServerError` in
`Shomei/Servant/Error.hs` so the status/`code`/`message` for each error is unchanged (only the
field name `error` → `code` and the added `retryable` differ). Map `InternalAuthError` to `503`
`retryable = True` rather than `500`: the convention says a failed *dependency* is a 503 the
caller can retry, and shomei's only remaining true-500 case (a genuine internal bug) is not a
documented response alternative. Note this status change (500 → 503 for `InternalAuthError`) in
Surprises & Discoveries; it is the single behavioral status change in the conversion.

`Shomei/Servant/Error.hs` can be retained for the CSRF/combinator path (it still builds the
combinator-raised errors) but its `authErrorToServerError` is now only used where errors are
still thrown upstream of a handler; the handler path uses `faultToResult`. Keep `csrfRejected`
and the combinator 401s exactly as they are — they are not `MultiVerb` alternatives.

Convert every field in `Shomei/Servant/API.hs`:

- Body-returning `Post`/`Get` → `MultiVerb 'POST '[JSON] (OkResponses "…" X) (AuthResult X)` (or
  the header-carrying variant proven in Milestone 1 for the `WithCookies` routes).
- `Verb 'POST 202 '[JSON] NoContent` → `MultiVerb 'POST '[JSON] (AcceptedResponses "…")
  (AuthResult ())`.
- `PostNoContent` / `Verb 'POST 204 …` → `MultiVerb 'POST '[JSON] (NoContentResponses "…")
  (AuthResult …)` (the `logout` route keeps its `Set-Cookie`-clearing headers via the
  header-carrying `204` variant).
- `login`'s success stays a single `Respond 200 "…" LoginResponse` alternative carrying the
  tagged-union `LoginResponse`; `MultiVerb` does not split its two 200 arms.
- `jwks`, `health` produce no domain errors; they may keep a plain verb *or* use a
  degenerate one-alternative `MultiVerb`. Keep them plain to minimize churn (the convention's
  target shape is a guide, not a mandate to add error arms an endpoint cannot produce). Record
  this choice in the Decision Log if you deviate.
- `ready` already returns 503 by throwing; model it as `MultiVerb` with a `200` success and the
  `503` arm so the readiness contract is typed.

Rewrite each handler in `Shomei/Servant/Handlers.hs` to return `AuthResult …`. Replace the
`runAuth` calls (which throw) with a variant that yields `Either AuthError a` and maps `Left`
through `faultToResult`, `Right` through `AuthOk`. Add a seam helper in
`Shomei/Servant/Seam.hs`, e.g. `runResult :: Env -> Eff AppEffects (Either AuthError a) ->
Handler (AuthResult a)`, so handlers stay thin. Pre-workflow validation that currently throws
`err400` (malformed ceremony id, empty scopes, missing loginId/email, bad audit cursor) returns
`AuthBadRequest (env "…" "…" False)` instead. The `requireRole` admin gate in `auditEventsH`
returns `AuthForbidden …` instead of throwing.

Install `ErrorFormatters` in the server assembly. Find where the app is served — the standalone
executable assembles it in `shomei-server/src/Shomei/Server/{App,Boot}.hs`, and the
embeddability example and tests call `serveWithContext`. Add an `envelopeFormatters ::
ErrorFormatters` (modeled on the `en-servant` reference, lines ~245–255) that emits
`ErrorEnvelopeWire` for `bodyParserErrorFormatter`, `urlParseErrorFormatter`, and
`notFoundErrorFormatter`, and prepend it to the existing context:

```haskell
serveWithContext shomeiAPI (envelopeFormatters :. authContext) (shomeiServer env)
```

Keep whatever `AuthHandler` context entry the assembly already passes for the `Authenticated`
combinator; `ErrorFormatters` is *added*, not a replacement.

Acceptance: `cabal build all` succeeds; `cabal test all` passes except
`shomei-servant-openapi-test` (updated next). The `en-servant` reference file is the model for
every piece here — read it alongside.

### Milestone 3 — Regenerate OpenAPI, fix the conformance test, fold the client arms

Scope: bring the generated document and its test back to green, and keep `shomei-client`'s
public signatures — and therefore nagare — unchanged. At the end, `cabal test all` passes
fully and `docs/api/openapi.json` reflects the new response statuses.

First, harden the `shomei-openapi` executable so the checked-in artifact is byte-diffable. Today
`shomei-servant/app/openapi/Main.hs` uses `encodePretty` (default config) and relies on a shell
redirect, which does **not** sort keys — so a regenerated document can reshuffle object members
and produce a noisy diff that hides the real contract change. The recipe requires sorted keys and
a trailing newline. Change it to write the file directly with a sorted, 2-space-indented config,
mirroring meibo's `meibo-api/app/OpenApi.hs`:

```haskell
-- shomei-servant/app/openapi/Main.hs
module Main (main) where

import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import Shomei.Servant.OpenApi (shomeiOpenApi)
import System.Directory (createDirectoryIfMissing)

main :: IO ()
main = do
  createDirectoryIfMissing True "docs/api"
  BSL.writeFile "docs/api/openapi.json" (encodePretty' config shomeiOpenApi <> "\n")
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare, confTrailingNewline = False}
```

Add `directory` to the `shomei-openapi` executable's `build-depends` (it already has
`aeson-pretty`, `bytestring`, and `shomei-servant`). Now the executable *writes* the artifact
rather than printing it, so regenerate by running it (no redirect):

```bash
cabal run shomei-openapi
git diff docs/api/openapi.json      # expect NEW 400/401/403/404/409/429/503 responses per op
```

Because keys are now sorted, the *first* regeneration under this config may reorder the whole
existing file — commit that reordering together with the new response entries, and note in the
commit body that the reshuffle is the one-time cost of switching to sorted output; every
subsequent diff is a real change only.

Add the drift check to CI. `.github/workflows/ci.yaml` already builds and tests under
`nix develop`; add a step after the build (mirroring meibo's "Check the OpenAPI artifact is in
sync") so an un-regenerated API change fails the build:

```yaml
      - name: Check the OpenAPI artifact is in sync
        run: |
          nix develop --command cabal run -v0 shomei-openapi
          git diff --exit-code -- docs/api/openapi.json
```

`Shomei/Servant/OpenApi.hs` needs a `ToSchema ErrorEnvelopeWire` instance (add it next to the
other DTO `ToSchema` instances — a plain `instance ToSchema ErrorEnvelopeWire` suffices, its
generic derivation matches the derived `ToJSON`). `MultiVerb`'s `HasOpenApi` instance ships in
`servant-openapi`, so no new combinator instance is required for the response lists; verify this
by building the `shomei-openapi` executable. The document's *path count* is unchanged (24) —
`MultiVerb` adds responses to existing operations, it does not add paths.

Update `shomei-servant/test-openapi/Main.hs`. The suite today runs `validateEveryToJSON` (the
recipe's third property — every DTO's `ToJSON` validates against its `ToSchema`, in strong form),
asserts `openapi == "3.1.0"`, and asserts a path *count* of 24. Keep those and add the two
properties the recipe requires that are currently missing:

- **Assert the exact path *set*, not just the count.** A count of 24 passes even if an endpoint
  was renamed or swapped for another. Replace (or supplement) the `pathCount == 24` assertion
  with an equality against the sorted list of all 24 expected paths, so a renamed or dropped
  route fails loudly:

  ```haskell
  it "covers exactly the served path set" $
    sort (pathKeys shomeiOpenApi) `shouldBe` servedPaths   -- the 24 literal "/auth/..." paths
  ```

- **Assert every operation declares its error responses.** This is the test that gives the
  `MultiVerb` conversion its teeth and would catch a silent regression to Hackage
  `servant-openapi3` (on which every error response vanishes at once). For each
  `(path, method, operation)` in the document, assert the operation's response codes include at
  least one `>= 400` status (the health/jwks routes that were deliberately kept plain — see the
  Milestone 2 Decision Log — are the documented exceptions; scope the assertion to the
  domain-error operations or list the plain routes explicitly):

  ```haskell
  it "every domain operation declares at least one error response" $
    for_ (operationsOf shomeiOpenApi) $ \(path, method, op) ->
      when (path `notElem` plainRoutes) $
        any (>= 400) (responseCodesOf op) `shouldBe` True
  ```

- `validateEveryToJSON` now also traverses the `ErrorEnvelopeWire` response bodies; add an
  `Arbitrary ErrorEnvelopeWire` and `Show ErrorEnvelopeWire` orphan (test-only, like the
  others) so the property can generate them.
- The `pathCount == 24` invariant still holds (`MultiVerb` adds responses to existing
  operations, not paths); keep it too if you prefer, but the exact-set assertion subsumes it.
- The existing `NoContent` orphan handling stays; the empty-body `MultiVerb` successes still
  present as `NoContent` to the validator.

Fold the typed error arms inside the `shomei-client` wrappers so nagare is untouched. Under
`MultiVerb`, `API.login shomeiClient body` now returns `ClientM (AuthResult (WithCookies
LoginResponse))` (or the header-carrying union). The wrappers in
`shomei-client/src/Shomei/Client.hs` must keep their existing signatures — e.g. `login ::
ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)` — by mapping the union:
`AuthOk withCookies -> Right (getResponse withCookies)`, and every error arm →
`Left (mkFailure envelope)`. Introduce one helper, `resultToEither :: AuthResult a -> Either
ClientError a`, that turns an error arm into the `ClientError` shape servant-client already
produces for a non-2xx (a `FailureResponse` carrying the status and the encoded envelope), so
callers that only look at `Left`/`Right` (nagare does) see no change. Document at the top of
`Shomei.Client` that the *wire* now advertises typed error statuses but the Haskell wrappers
preserve the `Either ClientError X` ergonomics; a future major version may expose `AuthResult`
directly.

Acceptance: `cabal test all` passes, including `shomei-servant-openapi-test`. Build nagare
against the working tree (`cabal build all` in `/Users/shinzui/Keikaku/bokuno/nagare`) to
confirm `Shomei.Client` still satisfies `Nagare.Access.ShomeiClient` — it must compile with no
nagare edits. Record the nagare build result in Surprises & Discoveries.

### Milestone 4 — Behavioral validation

Scope: prove the behavior end-to-end with `curl` and an OpenAPI diff. This milestone adds no
code; it demonstrates the change is real. See [Validation and Acceptance](#validation-and-acceptance)
for the full transcript. In brief: start the server, sign up a user (`200` + `Set-Cookie`), log
in (`200`), attempt a *duplicate* signup and observe `409` with `{"code":"login_id_taken",…,
"retryable":false}`, POST a malformed JSON body and observe `400` with the same envelope shape
(this is the `ErrorFormatters` win — before this plan it was Servant's plain-text body), and
call an `Authenticated` route with no token and observe `401` still coming from the combinator.
Then regenerate the OpenAPI document and confirm the diff shows the new response statuses.

### Milestone 5 — Vertical-slice `shomei-core` and `shomei-postgres`

Scope: move the concept-owned modules under their concept prefix per
[The vertical-slice analysis](#the-vertical-slice-analysis); leave the cross-cutting modules in
place; update every module header, the `exposed-modules` in `shomei-core.cabal` and
`shomei-postgres.cabal`, and all imports. Use `git mv` so history follows. No behavior changes.
`cabal build all && cabal test all` passes.

Move only the modules listed as "concepts that get a slice." For example, for the Passkey
concept:

```bash
git mv shomei-core/src/Shomei/Domain/Passkey.hs        shomei-core/src/Shomei/Passkey/Domain.hs
git mv shomei-core/src/Shomei/Effect/PasskeyStore.hs   shomei-core/src/Shomei/Passkey/Store.hs
git mv shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs shomei-core/src/Shomei/Passkey/PendingCeremony.hs
git mv shomei-core/src/Shomei/Workflow/Passkey.hs      shomei-core/src/Shomei/Passkey/Workflow.hs
git mv shomei-core/src/Shomei/Workflow/Mfa.hs          shomei-core/src/Shomei/Passkey/Mfa.hs
git mv shomei-postgres/src/Shomei/Postgres/PasskeyStore.hs shomei-postgres/src/Shomei/Passkey/Postgres.hs
# … then rename the `module Shomei.Domain.Passkey` header to `module Shomei.Passkey.Domain`,
#     fix the two cabal exposed-modules lists, and let GHC name every broken import.
```

Repeat for User/Account, Credential, Session, RefreshToken, LoginAttempt, Verification,
PasswordReset, and Audit. Do **not** move any module in the "stays put" list — most importantly
`Shomei.Domain.Claims`, `Shomei.Domain.Token`, `Shomei.Domain.SigningKey`, `Shomei.Error`,
`Shomei.Id`, `Shomei.Config`, `Shomei.Effect.InMemory`, `Shomei.Effect.AuthUnitOfWork`, and the
infrastructure ports.

For any moved module that a **downstream** repo imports, add a deprecated re-export shim at the
old path. Per the downstream analysis, `shomei-core`'s moved modules are all internal-only
(downstream imports Claims/Token/SigningKey/Error/Id/Config from core, none of which move), so
**no `shomei-core` shim is required**. Confirm this by grepping the sibling repos again after the
move; if any moved module turns out to be imported downstream, add a shim:

```haskell
-- shomei-core/src/Shomei/Domain/Passkey.hs  (shim, only if a downstream imports it)
{-# DEPRECATED "Import Shomei.Passkey.Domain instead; this alias is temporary." #-}
module Shomei.Domain.Passkey (module Shomei.Passkey.Domain) where
import Shomei.Passkey.Domain
```

Update `shomei-core/app/…`, the `shomei-core` test suite modules, `shomei-postgres`'s tests,
and `shomei-server`'s modules that import the moved modules. Build after each concept's move so
GHC's errors name the next site.

Acceptance: `cabal build all && cabal test all` passes. `git status` shows renames (`R`), not
delete+add. `find shomei-core/src shomei-postgres/src -name '*.hs' | grep -iE 'passkey|session'`
shows the concept as a *directory* component, not a filename, for the sliced concepts.

### Milestone 6 — Vertical-slice the `shomei-servant` DTOs

Scope: split `Shomei/Servant/DTO.hs` (one 467-line module holding every DTO) into per-concept
DTO modules, leaving a deprecated `Shomei.Servant.DTO` re-export shim so nagare and
`shomei-client` keep building unchanged. Keep the `ShomeiAPI` record and the `shomei-client`
field structure flat and stable. `cabal build all && cabal test all` passes.

Split by the same concepts as Milestone 5 — for instance `Shomei/User/Dto.hs`
(`SignupRequest`/`Response`, `UserResponse`, `LoginRequest`), `Shomei/Session/Dto.hs`
(`SessionResponse`), `Shomei/Credential/Dto.hs` (`ChangePasswordRequest`,
`ConfirmPasswordResetRequest`, `PasswordResetRequest`), `Shomei/Passkey/Dto.hs` (the passkey and
MFA DTOs), `Shomei/Audit/Dto.hs` (`AuditEventResponse`, `AuditEventsPage`), plus shared wire
types (`TokenPairResponse`, the tagged-union `LoginResponse` with its hand-written instances,
`HealthResponse`, `ReadyResponse`) in `Shomei/Servant/Dto/Shared.hs`. Move the mapping functions
(`userToResponse`, `tokenPairToResponse`, etc.) alongside the DTOs they build.

Then make `Shomei/Servant/DTO.hs` a shim that re-exports every symbol from the new modules,
preserving the exact export list nagare and `shomei-client` rely on, with a `{-# DEPRECATED #-}`
pragma:

```haskell
{-# DEPRECATED "Import the per-concept Shomei.*.Dto modules; this aggregate re-export is temporary." #-}
module Shomei.Servant.DTO (module X) where
import Shomei.User.Dto as X
import Shomei.Session.Dto as X
import Shomei.Credential.Dto as X
import Shomei.Passkey.Dto as X
import Shomei.Audit.Dto as X
import Shomei.Servant.Dto.Shared as X
```

Update `Shomei/Servant/OpenApi.hs`, `Shomei/Servant/Handlers.hs`, and
`shomei-client/src/Shomei/Client.hs` to import the new modules directly (they are inside the
shomei repo). Leave nagare importing the shim.

Acceptance: `cabal build all && cabal test all` passes. Building nagare against the working tree
still succeeds with no nagare edits (the shim carries it). `git status` shows the DTO split as
renames plus one new small shim file.

### Milestone 7 — Reconcile with roadmap plan 40; amend docs

Scope: resolve the overlap with the unimplemented roadmap plan
`docs/plans/40-api-v1-prefix-and-universal-problem-details-error-envelope.md`, and update any
in-repo docs that describe the pre-`MultiVerb` shape. No code beyond doc edits.

Plan 40 (EP-3 of MasterPlan 7) declares itself the owner of a "universal problem-details error
envelope" and a `/v1` prefix, and calls itself "the breaking-change window." This plan
introduces `ErrorEnvelopeWire` first. Append a dated revision note to plan 40 stating that the
error-envelope integration point is now established by this plan
(`docs/plans/48-reorganize-shomei-into-vertical-slices-and-adopt-multiverb.md`) as
`ErrorEnvelopeWire { code, message, retryable }` delivered through `MultiVerb` + Servant
`ErrorFormatters`, and that plan 40's remaining scope narrows to the `/v1` path prefix and any
RFC-7807 `application/problem+json` content-type framing it still wants on top of this envelope.
If the two envelope shapes are meant to differ (RFC 7807 uses `type`/`title`/`detail`/`status`),
record in this plan's Decision Log which one wins fleet-wide; do not leave two competing
envelope conventions in the tree.

Search for and update any user-facing docs in the repo that show the old thrown-error shape or
the old verb types:

```bash
grep -rn "Post '\[JSON\]\|authErrorToServerError\|\"error\":" docs/ README.md 2>/dev/null
```

Acceptance: plan 40 carries a dated revision note naming plan 48; no in-repo doc still presents
the pre-`MultiVerb` route types as current.


## Concrete Steps

Work from the repository root inside the nix dev shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
cabal build all    # baseline: must succeed before you start
cabal test all     # baseline: must pass before you start
```

Milestone 1 (spike). Read servant's `MultiVerb` source first:

```bash
mori registry show haskell-servant/servant --full
# read Servant/API/MultiVerb.hs; note the response-header combinator names.
```

Edit only `Shomei/Servant/API.hs` (the `signup` field) and `Shomei/Servant/Handlers.hs`
(`signupH`). Build, then run the server and check the cookie headers survive:

```bash
just create-database        # ephemeral/local PostgreSQL, idempotent
cabal run shomei-server &   # or the project's run recipe
curl -i -X POST http://localhost:8080/auth/signup \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'
# expect: HTTP/1.1 200, and two `Set-Cookie: shomei_session=…` / `shomei_refresh=…` headers
#         (in cookie transport; bearer transport sets no cookies — configure accordingly).
```

Milestones 2–3. Add `Shomei/Servant/Response.hs`; convert the remaining fields; rewrite
handlers; add the seam helper; install `ErrorFormatters`; regenerate and test:

```bash
cabal build all
cabal run shomei-openapi                 # writes docs/api/openapi.json (sorted keys, trailing newline)
cabal test all
cabal run shomei-openapi && git diff --exit-code -- docs/api/openapi.json   # drift check: clean
git add -A && git commit    # message form below
```

Every commit on this plan must carry both trailers:

```text
feat(servant): adopt MultiVerb response lists and the shared error envelope

<body>

ExecPlan: docs/plans/48-reorganize-shomei-into-vertical-slices-and-adopt-multiverb.md
Intention: intention_01kx3mms1zevyvwvaspxcrm3cd
```

Milestones 5–6 use `git mv` so history follows the file. Commit each concept's slice, or each
milestone, separately — never combine a `MultiVerb` type change with a file move in one commit;
a reviewer cannot read that diff. Example commit for the slice work:

```text
refactor(core): vertical-slice the passkey concept under Shomei/Passkey

<body>

ExecPlan: docs/plans/48-reorganize-shomei-into-vertical-slices-and-adopt-multiverb.md
Intention: intention_01kx3mms1zevyvwvaspxcrm3cd
```

After the slice milestones, re-verify no downstream broke:

```bash
( cd /Users/shinzui/Keikaku/bokuno/nagare && cabal build all )   # must succeed, no nagare edits
```


## Validation and Acceptance

Beyond `cabal build all && cabal test all`, prove the behavior against the running server. Start
it (Milestone 4):

```bash
just create-database
just migrate
cabal run shomei-server        # serves on http://localhost:8080
```

Sign up a user:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/auth/signup \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'
```

Expected: `200`.

Log in:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/auth/login \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice","password":"correct horse battery staple"}'
```

Expected: `200`.

Duplicate signup — the typed conflict. Re-run the signup command and capture the body:

```bash
curl -s -w '\n%{http_code}\n' -X POST http://localhost:8080/auth/signup \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple","displayName":"Alice"}'
```

Expected: body `{"code":"login_id_taken","message":"Login identifier is already registered",
"retryable":false}` followed by `409`. This is a returned value now, and it appears in the
OpenAPI document under `POST /auth/signup` as a `409` response — not an invisible thrown error.

Malformed request body — the `ErrorFormatters` win. This is the clearest before/after, because
shomei already JSON-encoded *domain* errors but not *routing* errors:

```bash
curl -s -w '\n%{http_code}\n' -X POST http://localhost:8080/auth/signup \
  -H 'content-type: application/json' \
  -d '{"loginId":"alice", NOT VALID JSON'
```

Expected: `400` with a body in the **same** `ErrorEnvelopeWire` shape
(`{"code":"invalid_request_body",…,"retryable":false}`), not Servant's default plain-text
`"Error in $: …"`. Before this plan, this request returned Servant's plain body.

Combinator 401 — unchanged, and deliberately NOT a `MultiVerb` alternative:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/auth/me
```

Expected: `401`, produced by the `Authenticated` combinator upstream of the handler. Confirm the
OpenAPI document does *not* list a `401` under `GET /auth/me`'s response *content* as a handler
alternative — it is expressed via the bearer security scheme instead. (A domain `401` like
`login`'s `InvalidCredentials` *does* appear as a response alternative, because a handler returns
it.)

OpenAPI regeneration diff — the type-level win:

```bash
git stash -- docs/api/openapi.json 2>/dev/null || true   # or inspect against HEAD
cabal run shomei-openapi
git --no-pager diff docs/api/openapi.json | head -40
```

Expected: added `400`/`401`/`403`/`404`/`409`/`429`/`503` response entries under the operations,
each referencing the `ErrorEnvelopeWire` schema; the `paths` object still has 24 entries; and the
document still begins `"openapi": "3.1.0"` (proof it is on the `shinzui` forks — a `3.0.x`
version would mean Hackage `servant-openapi3` had slipped in and the `MultiVerb` errors were
being dropped). After committing, the drift check is clean and stays clean:

```bash
cabal run shomei-openapi && git diff --exit-code -- docs/api/openapi.json
```

This is the same check CI runs (Milestone 3); a red result means an API change was not
regenerated.

Structural acceptance for the slices:

```bash
find shomei-core/src shomei-postgres/src -name '*.hs' | grep -iE '/(Passkey|Session|Credential|User|Audit)/'
```

Expected: the sliced concepts appear as directory components (`Shomei/Passkey/Domain.hs`), and
no line matches `Shomei/(Domain|Effect|Postgres|Workflow)/(Passkey|Session)`.

Downstream acceptance:

```bash
( cd /Users/shinzui/Keikaku/bokuno/nagare && cabal build all )
```

Expected: success, with zero edits to nagare — proving the DTO shim (Milestone 6) and the
client-wrapper fold (Milestone 3) preserved compatibility.


## Idempotence and Recovery

Milestones 1–4 are ordinary edits and additions; re-running the build is safe and repeated edits
converge. `cabal run shomei-openapi > docs/api/openapi.json` is deterministic, so regenerating it
repeatedly is a no-op once the types are stable.

Milestones 5–6 are file moves. `git mv` fails loudly on a repeated run ("bad source") rather than
corrupting anything. If a move goes wrong mid-way, the working tree is recoverable with `git
checkout -- .` (uncommitted) or `git reset --hard HEAD` (to the last commit). Commit after each
concept's slice so there is always a clean point to return to.

The database is untouched by this plan — no migration runs, no schema changes. The migration
files under `shomei-migrations/sql-migrations/` are not edited. If you have already run `just
migrate`, nothing here invalidates it.

The riskiest step is the Milestone 1 spike: if servant 0.20.2's `MultiVerb` cannot cleanly carry
the `Set-Cookie` headers on a success alternative, stop and record the finding. The fallback,
recorded here so the plan does not dead-end: keep the six cookie-setting routes as plain verbs
returning `WithCookies X` (their success path is unchanged) and apply `MultiVerb` only to their
*error* modeling via a thrown-to-returned bridge, or defer those six routes to a follow-up and
convert the remaining nineteen. Do not block the whole plan on the six cookie routes.


## Interfaces and Dependencies

No new library dependencies. `MultiVerb` lives in `servant` (already `>=0.20.2`), its
`HasOpenApi` instance in **`servant-openapi`** — the `shinzui` fork pinned in `cabal.project`,
*not* Hackage `servant-openapi3`; that instance is exactly what carries this plan's new
`MultiVerb` error responses into the document — and its `HasClient` instance in `servant-client`
(already used by `shomei-client`). `ErrorFormatters` lives in `servant-server` (already a
dependency). The one dependency edit is on the `shomei-openapi` *executable* stanza: add
`directory` (for `createDirectoryIfMissing`) alongside its existing `aeson-pretty`/`bytestring`,
so it can write the artifact to disk with sorted keys and a trailing newline (Milestone 3).

At the end of Milestone 2 these must exist:

```haskell
-- shomei-servant/src/Shomei/Servant/Response.hs
data ErrorEnvelopeWire = ErrorEnvelopeWire { code :: !Text, message :: !Text, retryable :: !Bool }
data AuthResult a = AuthOk a | AuthBadRequest !ErrorEnvelopeWire | … | AuthUnavailable !ErrorEnvelopeWire
type OkResponses       (desc :: Symbol) a
type AcceptedResponses (desc :: Symbol)
type NoContentResponses (desc :: Symbol)
faultToResult :: AuthError -> AuthResult a          -- total
-- hand-written `instance AsUnion (OkResponses …) (AuthResult a)` with the exhaustiveness witness

-- shomei-servant/src/Shomei/Servant/Seam.hs
runResult :: Env -> Eff AppEffects (Either AuthError a) -> Handler (AuthResult a)

-- shomei-servant/src/Shomei/Servant/API.hs — every field now ends in MultiVerb
-- shomei-servant/src/Shomei/Servant/Handlers.hs — every handler returns AuthResult …
-- the server assembly serves with (envelopeFormatters :. authContext)
```

At the end of Milestone 3, `docs/api/openapi.json` carries the new response entries and is
emitted with sorted keys and a trailing newline (so `cabal run shomei-openapi && git diff
--exit-code` is clean); `.github/workflows/ci.yaml` runs that drift check; the conformance test
passes and now asserts the exact 24-path *set* and that every domain operation declares an error
response (alongside the existing `validateEveryToJSON`); and `shomei-client`'s public wrapper
signatures are byte-for-byte the same as before (`login :: ClientEnv -> LoginRequest -> IO
(Either ClientError LoginResponse)`, etc.), backed by `resultToEither :: AuthResult a -> Either
ClientError a`.

At the end of Milestone 5, the sliced concepts exist as `Shomei/<Concept>/<Layer>.hs` in
`shomei-core` and `shomei-postgres`, the cross-cutting modules named in the analysis are
unchanged, and `Shomei.Domain.Claims`, `Shomei.Domain.Token`, `Shomei.Domain.SigningKey`,
`Shomei.Error`, `Shomei.Id`, and `Shomei.Config` still resolve at their original paths (no shim
needed, since no downstream-visible core module moved).

At the end of Milestone 6, the per-concept `Shomei/<Concept>/Dto.hs` modules exist,
`Shomei/Servant/Dto/Shared.hs` holds the shared wire types, and `Shomei.Servant.DTO` remains as a
deprecated re-export shim exporting the exact symbol set nagare and `shomei-client` consume.


## Revision Notes

- 2026-07-09 — Aligned this plan with the canonical OpenAPI recipe
  (`haskell-jitsurei/api/openapi-from-types.md`). Shomei already derives its document
  (`Shomei.Servant.OpenApi.shomeiOpenApi = toOpenApi (Proxy @(NamedRoutes ShomeiAPI))`), confines
  its orphans, assigns stable `operationId`s, emits a checked-in `docs/api/openapi.json` from the
  `shomei-openapi` executable, and pins the **`shinzui` forks (`servant-openapi`, `openapi-hs`),
  not Hackage** — verified against `cabal.project`. So no generation, no fork change, and no new
  milestone is introduced. What was added: (1) an explicit Purpose statement that the derivation
  must not regress, naming the module and the fork pin, and noting that the `MultiVerb`
  conversion changes the derived document (new `4xx/5xx` per operation) — which is the visible
  proof it worked, reviewed in Milestone 3; and (2) three targeted strengthenings folded into the
  existing Milestone 3 (which already regenerates the artifact and edits the conformance test),
  because shomei's setup fell just short of the recipe there: the `shomei-openapi` executable now
  emits **sorted keys and a trailing newline** (it used `encodePretty`'s default, so a
  regenerated artifact could reshuffle instead of diffing cleanly); a **CI drift check**
  (`cabal run shomei-openapi && git diff --exit-code`) is added to `.github/workflows/ci.yaml`;
  and the conformance test now asserts the **exact 24-path set** (not just the count) and that
  **every domain operation declares its error responses**, keeping the existing
  `validateEveryToJSON`. Reflected across Purpose, Progress (M3), Surprises & Discoveries,
  Decision Log, Milestone 3, Concrete Steps, Validation, and Interfaces & Dependencies. Reason:
  adopting `MultiVerb` makes the fork pin and the per-operation-error conformance property
  load-bearing, and a byte-diffable artifact plus a CI drift check are what keep the derived
  document honest as the API grows.

- 2026-07-10 — Corrected the "you cannot transpose two same-typed routes by accident" claim and
  added a dispatch test. The *Terms of art* definition of a `NamedRoutes` record previously stated
  that "you cannot transpose two same-typed routes by accident." That is false: a record does not
  turn a swap of two identically-typed fields into a compile error — the meibo service proved it by
  experiment (the swap compiled and served the wrong data; only a runtime dispatch test caught it),
  and meibo separately disproved the related field-order-versus-capture-precedence claim. The
  definition now states the honest property (a record removes the positional failure mode; a
  differing-typed transposition is a compile error naming the field; a same-typed transposition is
  caught only by a runtime dispatch test). This matters concretely for shomei, which — an audit
  found — has two same-typed admin families: `adminSuspendUser`/`adminReinstateUser`/
  `adminDeleteUser`/`adminRevokeSessions`/`adminPasswordReset` (all
  `AuthUser -> UserId -> Handler NoContent`) and `adminGrantRole`/`adminRevokeRole` (both
  `AuthUser -> UserId -> Text -> Handler NoContent`). Because Milestone 2 rewrites every handler in
  one pass, a new Surprises & Discoveries entry, a new Decision Log entry, and additions to
  Milestone 2 and the Progress list now require a runtime dispatch test pinning each admin path to
  its own handler, written *before* the rewrite. Shomei stays on `NamedRoutes` and the `AppAPI`
  `:<|>` operators are untouched (their alternatives have distinct types — the one hazard-free use
  of `:<|>`). Reflected in *Terms of art used in this plan*, *Surprises & Discoveries*, the Decision
  Log, Milestone 2, Progress, and this note.
