---
id: 5
slug: servant-integration-and-route-protection
title: "Servant integration and route protection"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# Servant integration and route protection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, Shōmei has an **HTTP surface**: the `shomei-servant` library that
turns the pure authentication workflows from EP-2 (`shomei-core`) into a real, runnable
Servant web API. A developer who finishes this plan can boot an in-process web server (using
EP-2's in-memory effect interpreters plus a freshly generated ES256 signing key from EP-4) and
observe these concrete behaviors over real HTTP:

- `POST /auth/signup` with an email and password returns a JSON body containing the new user
  and a signed JWT access token plus an opaque refresh token.
- `POST /auth/login` with the same credentials returns a fresh token pair.
- `GET /auth/me` with an `Authorization: Bearer <accessToken>` header returns the
  authenticated user; the same request with **no** token or a **garbage** token returns
  `401 Unauthorized`.
- `POST /auth/refresh` rotates a refresh token and returns a new pair.
- `GET /.well-known/jwks.json` returns a public JWKS document carrying the key's `kid` and
  **no** private key material, so a downstream service can verify tokens locally.
- A route guarded by `RequireRole "admin"` returns `403 Forbidden` for a non-admin caller and
  `200 OK` for an admin.

This plan owns **Integration Point IP-6**: the `ShomeiAPI` NamedRoutes type, every
request/response DTO, and the `AuthUser` principal. It does **not** wire PostgreSQL — that is
EP-6. Its own tests run entirely in-memory. The user-visible payoff is the standalone HTTP
contract and the proof that the same `ShomeiAPI` type can be *embedded* inside a host Servant
application and that arbitrary host routes can be protected by `Authenticated` and `RequireRole`.

To keep this document self-contained, a short glossary of the Servant terms used throughout:

- **Servant combinator** — a type-level building block (e.g. `ReqBody`, `Get`, `Capture`, a
  custom one like `Authenticated`) combined with `:>` to describe an API at the *type* level.
  Servant derives the server, client, and docs from that type.
- **NamedRoutes** — a record whose fields are routes, parameterized by a `mode`
  (`data XxxRoutes mode = XxxRoutes { field :: mode :- <route> } deriving stock Generic`).
  With `AsServerT m` the record becomes a server (each field is a handler); with `AsApi` it is
  a type-level API. It gives named handlers instead of a positional `:<|>` tuple.
- **`AuthProtect "tag"`** — Servant's *generalized authentication* combinator. Putting
  `AuthProtect "tag"` in an API marks the route as needing custom auth; the server side is
  driven by an `AuthHandler` registered in the `Context` under a matching `type instance
  AuthServerData (AuthProtect "tag")`.
- **`AuthHandler Request a`** — a function (built with `mkAuthHandler`) that runs in Servant's
  `Handler` monad, inspects the incoming WAI `Request`, and either `throwError`s (e.g. `401`)
  or returns the principal value `a` (here `AuthUser`) that is then passed to the route handler.
- **`Context`** — a type-level heterogeneous list of extra values Servant threads to handlers.
  For generalized auth it carries the `AuthHandler`. We serve with `serveWithContext` and hoist
  with `hoistServerWithContext`.
- **Bearer token** — an access token presented in the HTTP header
  `Authorization: Bearer <token>`. We also accept a `shomei_session` cookie as a fallback.
- **`AuthUser`** — Shōmei's *principal*: the value produced by the `AuthHandler` after a token
  verifies, carrying the user id, session id, roles, scopes, and the raw `AuthClaims`. Every
  authenticated handler receives it as a leading argument.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Contract compiles: `shomei-servant/shomei-servant.cabal`,
      `Shomei.Servant.Auth` (`AuthUser`, `Authenticated`, `authHandler`, `extractToken`,
      `authUserFromClaims`), `Shomei.Servant.Authz` (`RequireRole`/`RequireScope` design),
      `Shomei.Servant.DTO` (all request/response DTOs + JSON instances), and
      `Shomei.Servant.API` (`ShomeiAPI`) all compile via `cabal build shomei-servant`. (2026-06-03)
- [x] Milestone 2 — Handlers compile: `Shomei.Servant.Error` (AuthError → ServerError),
      `Shomei.Servant.Seam` (`AppEffects`, `Env`, `runAuth`/`runPort` — the seam, renamed from
      the plan's `effToHandler` sketch; see Decision Log), and `Shomei.Servant.Handlers`
      (`shomeiServer`) compile against EP-2 workflows; the embedded `AppAPI` example compiles.
      `cabal build shomei-servant` green, fourmolu-clean. (2026-06-03)
- [x] Milestone 3 — In-process warp test green: `test-suite shomei-servant-test` boots the app
      on an ephemeral port with a **hybrid** stack (EP-2 in-memory stores + EP-4's real ES256
      `runTokenSignerJwt`/`runTokenVerifierJwt`) and exercises signup / login / me(+401, +garbage)
      / refresh / jwks / `RequireRole`(403/200); `cabal test shomei-servant` passes (1 sequential
      case, 8 sub-assertions). Needed `-threaded` (warp's timer manager) and exporting EP-2's
      individual in-memory interpreters (cascade — see Surprises). (2026-06-03)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **GHC2024 makes `role` a context-sensitive keyword (affects any later plan that declares a
  phantom combinator or type variable named `role`).** GHC2024 enables `RoleAnnotations`, under
  which `role` is reserved for the `type role T nominal …` syntax, so `data RequireRole role`
  (or `data RequireRole (role :: Symbol)`) fails with `GHC-58481 parse error on input 'role'`.
  Evidence: `ghc -fno-code -XGHC2024` on `data RequireRole role` fails; renaming the binder to
  `r` (with the same `-XGHC2024`) compiles. Fix: `Shomei.Servant.Authz` declares
  `type RequireRole :: Symbol -> Type; data RequireRole r` (standalone kind signature + a
  non-keyword binder). Independently, the parenthesized kinded-binder form
  `data T (a :: Symbol)` also refused to parse on this toolchain even with `KindSignatures`;
  the standalone-kind-signature form is what works.
- **The library does not need `jose` (reinforces IP-4).** EP-4's `verifyToken` has the shape
  `Text -> IO (Either TokenError AuthClaims)` over *core* types only, and the JWKS document can
  be carried as a precomputed `aeson` `Value`. So `shomei-servant`'s **library** depends only on
  `shomei-core` (+ servant/wai/cookie/aeson/…), never `shomei-jwt`/`jose`; only the **test**
  (and EP-6 at assembly) touch `shomei-jwt` to generate keys, build the verifier closure, and
  compute the document. Consequence for EP-6: build the `Env` by partially applying
  `verifyToken jwks config` into `Env.verifier` and `Aeson.decode (jwksDocument keys)` into
  `Env.jwksJson`; the handlers stay jose-free.
- **`jwksDocument :: [JWK] -> ByteString` (not `JWKSet -> Value`).** The EP-5 plan's sketch
  assumed `jwksDocument :: JWKSet -> Aeson.Value`; the real EP-4 signature is
  `jwksDocument :: [JWK] -> Data.ByteString.Lazy.ByteString` (and `keySetPublicJwks :: KeySet ->
  JWKSet` builds the public set for the verifier). The `jwks` route therefore serves a `Value`
  obtained by decoding the document once at assembly time.
- **An honest end-to-end test needs a hybrid interpreter, which required a small EP-2 cascade.**
  EP-2's `runInMemory` bundles a *fake* token signer (claims round-tripped through JSON), so a
  real `jose` `verifyToken` could never verify its output — yet the jwks case and the
  "real ES256" decision require real keys. The fix is a hybrid stack: EP-2's in-memory store
  interpreters + EP-4's `runTokenSignerJwt`/`runTokenVerifierJwt`. That hybrid can't live in
  `shomei-core` (it would import `shomei-jwt` → cycle), so it is composed in this plan's test —
  which required EP-2 to **export its individual in-memory interpreters** (`runUserStore`,
  `runCredentialStore`, …, `runTokenGen`), an additive, non-breaking change to
  `Shomei.Effect.InMemory`'s export list. The `Env.runPorts` runner is built from them in the same
  effect order as `runInMemory`, which is exactly the order `AppEffects` fixes. The in-memory
  `Clock` returns a fixed time, so the test seeds `emptyWorld` with the real current time so the
  signed tokens are not already expired under real-wall-clock verification.
- **warp's `testWithApplication` needs the threaded runtime.** Without `-threaded` the timer
  manager throws (`getSystemTimerManager: the TimerManager requires linking against the threaded
  runtime`). The test-suite stanza sets `ghc-options: -threaded -rtsopts -with-rtsopts=-N`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use Servant's built-in generalized auth (`AuthProtect` + `AuthHandler`) for the
  `Authenticated` combinator, **not** `servant-auth-server`.
  Rationale: The `AuthHandler` can call EP-4's `verifyToken :: JWKSet -> ShomeiConfig -> Text
  -> IO (Either TokenError AuthClaims)` directly, giving exact control over Bearer-vs-cookie
  precedence and precise `401`/`403` JSON bodies. It also avoids `servant-auth-server`'s extra
  dependency closure and its own JWT settings, which is one fewer set of version bounds to
  reconcile on GHC 9.12.4. Inherits the master-plan decision (2026-06-03) that picked
  `AuthProtect` over `servant-auth-server`.
  Date: 2026-06-03

- Decision: Token extraction precedence is **Bearer header first, then `shomei_session`
  cookie**.
  Rationale: API/microservice clients send `Authorization: Bearer`; browser/embedded clients
  using the HttpOnly-cookie transport send the cookie. Trying the header first matches the
  common API case and avoids a cookie shadowing an explicit Bearer credential. The cookie name
  `shomei_session` matches the transport story in `ShomeiConfig.tokenTransport`.
  Date: 2026-06-03

- Decision: Implement `RequireRole`/`RequireScope` as **handler-level guard functions**
  (`requireRole :: Role -> AuthUser -> Handler ()`, `requireScope :: Scope -> AuthUser ->
  Handler ()`) called at the top of a guarded handler, and keep `data RequireRole (r ::
  Symbol)` / `data RequireScope (s :: Symbol)` as documented *phantom combinators reserved for
  future work* (a full `HasServer` instance is sketched but not the MVP path).
  Rationale: A real type-level `HasServer (RequireRole role :> api)` instance must thread the
  `AuthUser` (which only exists *after* `Authenticated` has produced it) out of the request and
  is fiddly to get right on GHC 9.12 with `NamedRoutes`. The guard-function form is correct,
  trivially testable (it just throws `err403`), and composes with any handler that already has
  the `AuthUser` in scope. The phantom combinators are still exported so the API type can
  *document* intent (`RequireRole "admin" :> Authenticated :> ...`) and so a later plan can add
  the `HasServer` instance without changing call sites. MVP wires the guard via the function.
  Date: 2026-06-03

- Decision: Wire handlers with **style A — a per-action `effToHandler` seam** carrying an `Env`
  with the effect-interpreter runner, **not** a whole-server `hoistServer` natural transformation.
  Rationale: Mirrors kizashi's `Kizashi.Http.Seam.effToHandler`. The handlers run *in*
  `Handler`, call `effToHandler env (workflow …)` to run the `Eff` stack to `IO (Either
  AuthError result)`, and branch on the domain `Either` themselves. A global `hoistServer` over
  `Eff Effects` cannot map an `AuthError` to an HTTP status (the effect stack has no `Error
  ServerError`); the seam is the single place infrastructure/domain failure meets HTTP.
  Date: 2026-06-03

- Decision: At the HTTP layer, login (and any credential check) returns a **generic** error —
  HTTP `401` with message `"Invalid email or password"` — for both "user not found / wrong
  password" and "user not active".
  Rationale: Do not leak account existence or status. The domain may distinguish
  `InvalidCredentials` from `UserNotActive`, but the error module collapses both to the same
  `401`/message at the boundary.
  Date: 2026-06-03

- Decision: Test `shomei-servant` with **EP-2's in-memory effect interpreters plus a real ES256
  key generated in-test** (no PostgreSQL).
  Rationale: EP-5 soft-depends on EP-3; PostgreSQL wiring is EP-6. Using the in-memory
  interpreters keeps the test hermetic and fast, and a real key makes signing/verification
  actually exercise EP-4's `verifyToken`, so the `Authenticated` path is genuinely tested rather
  than stubbed.
  Date: 2026-06-03

- Decision: The `ShomeiAPI` JWKS route returns an `aeson` `Value` produced by EP-4's
  `jwksDocument`, not a bespoke JWKS newtype.
  Rationale: `jwksDocument` already emits the canonical public JWKS JSON; re-wrapping it adds no
  value and risks drift. Consumers parse standard JWKS, so `Value` (rendered as
  `application/json`) is sufficient and honest about the shape.
  Date: 2026-06-03

- Decision: The seam is `runAuth :: Env -> Eff AppEffects (Either AuthError a) -> Handler a`
  plus `runPort :: Env -> Eff AppEffects a -> Handler a`, with `Env.runPorts :: forall a. Eff
  AppEffects a -> IO a` — **not** the plan's sketched `effToHandler :: Env -> Eff AppEffects a ->
  Handler a` with `runEff :: ... -> IO (Either AuthError a)`.
  Rationale: EP-2's workflows *already* return `Eff es (Either AuthError result)` (they run a
  local `Effectful.Error.Static` internally), so the runner must not add a second `Either` layer.
  `runAuth` runs the workflow and maps a `Left AuthError` through `authErrorToServerError`;
  `runPort` runs a plain effect read (e.g. `findUserById` for `me`) whose `Maybe` the handler
  branches on itself (a missing row → `404`). `AppEffects` is the fixed, ordered effect list
  (matching EP-2's `runInMemory` order) that every assembly — the test's in-memory+jose hybrid and
  EP-6's postgres+jose stack — provides a `runPorts` for.
  Date: 2026-06-03

- Decision: The library is `jose`-free; the `Env` carries the verifier closure and a precomputed
  JWKS `Value`, so `shomei-servant`'s library `build-depends` lists `shomei-core` but **not**
  `shomei-jwt`.
  Rationale: keeps IP-4 intact (only `shomei-jwt` imports `jose`) and lets the contract +
  handlers compile against core alone. The test and EP-6 supply the jose-derived `Env` fields.
  Date: 2026-06-03

- Decision: DTO mappers target the real EP-2 shapes: `User.displayName :: Maybe Text`
  (rendered as `""` when absent), `User.status :: UserStatus` (rendered lowercase
  `active`/`suspended`/`deleted`), `TokenPair.expiresIn :: NominalDiffTime` (rendered as whole
  seconds), and commands take `Email`/`PlainPassword`/`RefreshToken` (so `signup`/`login` parse
  the request email through `mkEmail`, mapping `InvalidEmail` to `400` before the workflow runs).
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Delivered exactly the purpose: `shomei-servant` is the HTTP surface of Shōmei.
`Shomei.Servant.API` owns IP-6 — the `ShomeiAPI` NamedRoutes record, every request/response DTO,
and the `AuthUser` principal. `Shomei.Servant.Auth` provides the `Authenticated` combinator
(custom `AuthProtect "shomei-jwt"` + `AuthHandler`) with Bearer-then-cookie extraction;
`Shomei.Servant.Authz` provides the `requireRole`/`requireScope` guards (MVP) and the documented
phantom combinators; `Shomei.Servant.Error` maps `AuthError` to a structured JSON `ServerError`
(login collapses to a generic 401); `Shomei.Servant.Seam` is the per-action seam (`AppEffects`,
`Env`, `runAuth`/`runPort`); `Shomei.Servant.Handlers` is `shomeiServer`. The end-to-end test
boots the API over real HTTP with a hybrid (in-memory stores + real ES256) stack and proves every
behavior: signup, login, me(+401 on missing/garbage), refresh rotation, the public JWKS document
(kid present, no private `d`), and `RequireRole "admin"` (403 non-admin / 200 admin).

Deviations from the plan's sketch (all in the Decision Log / Surprises): the library is jose-free
(JWKS as a precomputed `Value`, verifier as a closure in `Env`); the seam runs workflows that
already yield `Eff (Either AuthError a)` rather than wrapping a second `Either`; DTO mappers target
the real EP-2 shapes; the phantom combinators avoid the `role`/`scope` names (GHC2024
`RoleAnnotations`); and an honest test required exporting EP-2's individual in-memory interpreters
(additive cascade) plus `-threaded`.

Gaps / deferred (unchanged from scope): the `RequireRole`/`RequireScope` `HasServer` instances are
left as documented future work; PostgreSQL wiring and the real signing-key bootstrap are EP-6;
`me`/`session` read the live store row but do no extra authorization beyond the verified principal.
Downstream (EP-6 serves `ShomeiAPI`; EP-7 derives the client from it) consumes IP-6 unchanged.


## Context and Orientation

This plan builds `shomei-servant`, the **HTTP surface** of Shōmei. The reader is
assumed to know nothing about the prior plans beyond what is checked into this repository under
`docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md` and the sibling ExecPlans. The
relevant pieces this plan **consumes** are reproduced below so the plan is self-contained.

What EP-2 (`shomei-core`) provides and EP-5 consumes (assume importable; do **not** redefine):

- Domain types in `Shomei.Domain.*`: `User`, `Session`, `Email` (with normalization), the
  password newtypes, `TokenPair { accessToken :: AccessToken, refreshToken :: Text, expiresIn
  :: Int }` (an access token plus an opaque refresh token and its lifetime in seconds),
  `AccessToken` (a signed JWT wrapper around `Text`), and `AuthClaims` carrying at least
  `subject :: UserId`, `sessionId :: SessionId`, `scopes :: Set Scope`, `roles :: Set Role`
  (plus issuer/audience/expiry). `Scope` and `Role` are `Text` newtypes.
- Errors `Shomei.Error`: `AuthError` (with at least `InvalidEmail`, `WeakPassword`,
  `InvalidCredentials`, `UserNotActive`, `EmailAlreadyRegistered`, the `Session*`/`RefreshToken*`
  family including `RefreshTokenReuseDetected`, `TokenInvalid`, and `InternalAuthError`) and
  `TokenError`.
- `ShomeiConfig` (IP-5): includes `tokenTransport :: TokenTransport` where `TokenTransport =
  BearerToken | HttpOnlyCookie | BearerAndCookie`, and `sessionCheckMode :: SessionCheckMode`.
- Commands `SignupCommand`, `LoginCommand`, `RefreshCommand`, `LogoutCommand`.
- The auth **workflows**, each written purely against the effects:

  ```haskell
  signup  :: (<effects> :> es) => ShomeiConfig -> SignupCommand  -> Eff es (Either AuthError (User, TokenPair))
  login   :: (<effects> :> es) => ShomeiConfig -> LoginCommand   -> Eff es (Either AuthError (User, TokenPair))
  refresh :: (<effects> :> es) => ShomeiConfig -> RefreshCommand -> Eff es (Either AuthError TokenPair)
  logout  :: (<effects> :> es) => ShomeiConfig -> LogoutCommand  -> Eff es (Either AuthError ())
  ```

  (`<effects>` abbreviates the full constraint set: `UserStore`, `CredentialStore`,
  `SessionStore`, `RefreshTokenStore`, `PasswordHasher`, `TokenSigner`, `TokenVerifier`,
  `AuthEventPublisher`, `SigningKeyStore`, `Clock`, `TokenGen`, all `:> es`.) Exact return
  shapes are confirmed against `shomei-core` during Milestone 2; the DTO mapping is the only
  thing that depends on them.
- The **effects** (IP-3) and EP-2's **in-memory interpreters** for testing, plus
  `Shomei.Id` TypeID identifiers with orphan `FromHttpApiData`/`ToHttpApiData` (so a
  `Capture "id" SessionId` parses).

What EP-4 (`shomei-jwt`) provides and EP-5 consumes:

```haskell
verifyToken  :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
jwksDocument :: JWKSet -> Aeson.Value   -- public JWKS JSON (no private material)
```

The `Authenticated` combinator's `AuthHandler` is parameterized over a verifier of shape
`Text -> IO (Either TokenError AuthClaims)`; at assembly time we partially apply EP-4's
function as `\t -> verifyToken jwks config t`.

The whole package follows the **house conventions**: GHC 9.12.4, `GHC2024`, `cabal-version:
3.0`, the two `common` stanzas (`common warnings`, `common shared`) imported by every package,
postpositive `qualified` imports, strict fields, explicit `deriving` strategies, and
`import Shomei.Prelude` instead of re-importing base. Because Servant needs them, the API,
auth, and authz modules add per-module `{-# LANGUAGE DataKinds #-}`, `{-# LANGUAGE
TypeFamilies #-}`, and `{-# LANGUAGE TypeOperators #-}` pragmas (GHC2024 enables much, but
these are made explicit per Servant practice). Modules that use `#field` add an empty
`import Data.Generics.Labels ()`.

The kizashi reference idioms confirmed on disk and mirrored here:

- `kizashi-core/src/Kizashi/Http/Seam.hs` — the per-action `effToHandler` seam (style A).
- `kizashi-core/src/Kizashi/Http/Error.hs` — a small typed `ApiError`, one `toServerError`
  emitting `{"error":<code>,"message":<text>}` with `Content-Type: application/json`, and
  constructor-matching mappings that never leak internal detail.
- `kizashi-api/src/Kizashi/Api/Team.hs` and `…/Root.hs` — NamedRoutes records
  (`data XxxRoutes mode = … deriving stock Generic`), DTOs with `FromJSON`/`ToJSON`, nested
  `NamedRoutes`, and a `Proxy (NamedRoutes …)` for `serve`.

New files created by this plan (all under `shomei-servant/`):

```text
shomei-servant/shomei-servant.cabal
shomei-servant/src/Shomei/Servant/Auth.hs      -- AuthUser, Authenticated, authHandler, extractToken
shomei-servant/src/Shomei/Servant/Authz.hs     -- RequireRole/RequireScope (guards + phantom combinators)
shomei-servant/src/Shomei/Servant/DTO.hs       -- all request/response DTOs + JSON instances
shomei-servant/src/Shomei/Servant/API.hs       -- ShomeiAPI NamedRoutes + the embedded AppAPI example
shomei-servant/src/Shomei/Servant/Error.hs     -- AuthError -> ServerError
shomei-servant/src/Shomei/Servant/Seam.hs      -- Env + effToHandler
shomei-servant/src/Shomei/Servant/Handlers.hs  -- shomeiServer + per-route handlers
shomei-servant/test/Main.hs                    -- tasty + warp + http-client end-to-end test
```


## Plan of Work

The work proceeds in three independently verifiable milestones. Each milestone ends with a
specific `cabal` command and an observable result. Edits are described file-by-file.

### Milestone 1 — The contract (combinators, principal, API, DTOs) compiles

Scope: everything *type-level* and *pure* — no handlers, no `Eff`. At the end, the API type and
all DTOs exist and `cabal build shomei-servant` succeeds (the handler modules are added in
Milestone 2, so Milestone 1's `.cabal` lists only the contract modules, or the handler modules
are present but trivially stubbed; we list them all and stub `Handlers`/`Seam` so `cabal build`
is green throughout — see Concrete Steps).

1. Create `shomei-servant/shomei-servant.cabal` (full text in Concrete Steps) with the
   two shared `common` stanzas, the dependency list, the `library` exposing the modules above,
   and the `test-suite` stanza (added now, used in Milestone 3).
2. Create `src/Shomei/Servant/Auth.hs`:
   - `data AuthUser = AuthUser { authUserId :: !UserId, authSessionId :: !SessionId, authRoles
     :: !(Set Role), authScopes :: !(Set Scope), authClaims :: !AuthClaims } deriving stock
     (Generic)`.
   - `type instance AuthServerData (AuthProtect "shomei-jwt") = AuthUser` and
     `type Authenticated = AuthProtect "shomei-jwt"`.
   - `authUserFromClaims :: AuthClaims -> AuthUser` projecting subject/sessionId/roles/scopes.
   - `extractToken :: Request -> Maybe Text` — Bearer header first, `shomei_session` cookie
     fallback.
   - `authHandler :: (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request
     AuthUser`.
3. Create `src/Shomei/Servant/Authz.hs`: the guard functions `requireRole`/`requireScope`
   (the MVP path) plus the phantom `RequireRole`/`RequireScope` combinators (documented future
   `HasServer` work), and a sketch of the `HasServer` instance in comments.
4. Create `src/Shomei/Servant/DTO.hs`: every DTO with `FromJSON`/`ToJSON`, matching the spec's
   JSON exactly (userId/email as strings, status lowercased).
5. Create `src/Shomei/Servant/API.hs`: `ShomeiAPI mode` NamedRoutes, the `shomeiAPI` proxy, and
   the embedded `AppAPI` example proving embeddability.

Acceptance: `cabal build shomei-servant` is green; `ghci` can `:t shomeiAPI` and
`:i AuthUser`.

### Milestone 2 — Handlers, the seam, and the error mapping compile against EP-2

Scope: make the API *run*. At the end the full server exists and compiles (still no test run).

1. Create `src/Shomei/Servant/Error.hs`: `authErrorToServerError :: AuthError -> ServerError`
   with the JSON body `{"error":<code>,"message":<text>}`, mapping per the table in
   Interfaces and Dependencies.
2. Create `src/Shomei/Servant/Seam.hs`: `data Env` (the runner + `ShomeiConfig` + JWKS) and
   `effToHandler :: Env -> Eff AppEffects a -> Handler a` (style A).
3. Replace the Milestone-1 stub of `src/Shomei/Servant/Handlers.hs` with the real
   `shomeiServer :: Env -> ShomeiAPI (AsServerT Handler)` and its per-route handlers; provide at
   least `signup` and `me` in full, and the rest concretely.
4. Confirm the embedded `AppAPI` example in `API.hs` still compiles with a small example
   server.

Acceptance: `cabal build shomei-servant` is green with handlers present.

### Milestone 3 — In-process warp test exercising the live HTTP behavior

Scope: prove the behaviors from Purpose over real HTTP. At the end `cabal test shomei-servant`
is green.

1. Create `test/Main.hs`: generate a real ES256 key in-test (via EP-4's key helper), build the
   `Env` over EP-2's in-memory interpreters, boot with `Network.Wai.Handler.Warp.testWithApplication`
   on an ephemeral port, then drive `http-client` requests for signup/login/me(+401, +garbage)/
   refresh/jwks/`RequireRole`(403, 200).

Acceptance: `cabal test shomei-servant` prints all green tasty cases (expected transcript in
Validation and Acceptance).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop` (the toolchain the master plan establishes). Create the package directory first.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
mkdir -p shomei-servant/src/Shomei/Servant shomei-servant/test
```

### Step 1 — `shomei-servant/shomei-servant.cabal`

```cabal
cabal-version:      3.0
name:               shomei-servant
version:            0.1.0.0
synopsis:           Servant combinators and handlers for the Shōmei auth toolkit
build-type:         Simple

common warnings
    ghc-options: -Wall -Wcompat -Widentities -Wincomplete-record-updates
                 -Wincomplete-uni-patterns -Wmissing-export-lists
                 -Wpartial-fields -Wredundant-constraints

common shared
    import:             warnings
    default-language:   GHC2024
    default-extensions: DataKinds
                        DerivingStrategies
                        DerivingVia
                        DuplicateRecordFields
                        LambdaCase
                        OverloadedLabels
                        OverloadedStrings
                        TypeFamilies
                        TypeOperators
    build-depends:      base >=4.18 && <5

library
    import:           shared
    hs-source-dirs:   src
    exposed-modules:  Shomei.Servant.Auth
                      Shomei.Servant.Authz
                      Shomei.Servant.DTO
                      Shomei.Servant.API
                      Shomei.Servant.Error
                      Shomei.Servant.Seam
                      Shomei.Servant.Handlers
    build-depends:    shomei-core
                    , shomei-jwt
                    , servant        >=0.20.2
                    , servant-server >=0.20
                    , wai
                    , http-api-data
                    , aeson
                    , text
                    , time
                    , containers
                    , bytestring
                    , cookie
                    , effectful
                    , effectful-core

test-suite shomei-servant-test
    import:           shared
    type:             exitcode-stdio-1.0
    hs-source-dirs:   test
    main-is:          Main.hs
    build-depends:    shomei-servant
                    , shomei-core
                    , shomei-jwt
                    , servant-server
                    , wai
                    , warp
                    , aeson
                    , bytestring
                    , text
                    , containers
                    , tasty
                    , tasty-hunit
                    , http-client
                    , http-types
```

Register the package in `cabal.project` if EP-1 did not already list it (it is one of the six
declared packages, so it is expected to be present):

```bash
grep -q 'shomei-servant' cabal.project || \
  printf '\npackages: shomei-servant\n' >> cabal.project
```

### Step 2 — `src/Shomei/Servant/Auth.hs` (the `Authenticated` combinator + `AuthHandler`)

This is the exact approach: Servant generalized auth, EP-4's verifier injected, Bearer-then-cookie
extraction.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The 'Authenticated' combinator (custom 'AuthProtect' + 'AuthHandler') and the
-- 'AuthUser' principal it produces (IP-6).
module Shomei.Servant.Auth
  ( AuthUser (..)
  , Authenticated
  , authHandler
  , extractToken
  , authUserFromClaims
  ) where

import Shomei.Prelude
import Data.Generics.Labels ()
import Shomei.Domain (AuthClaims, Role, Scope)   -- exact module names confirmed against shomei-core
import Shomei.Id (SessionId, UserId)
import Shomei.Error (TokenError)

import "containers" Data.Set (Set)
import "text" Data.Text qualified as Text
import "text" Data.Text.Encoding qualified as Text
import "bytestring" Data.ByteString qualified as BS

import "wai" Network.Wai (Request, requestHeaders)
import "cookie" Web.Cookie (parseCookies)

import "servant" Servant.API.Experimental.Auth (AuthProtect)
import "servant-server" Servant.Server.Experimental.Auth
  ( AuthHandler, AuthServerData, mkAuthHandler )
import "servant-server" Servant (throwError, err401, errBody)
import "servant-server" Servant.Server (Handler)
import Control.Monad.IO.Class (liftIO)

-- | Shōmei's principal: what the 'AuthHandler' hands to every authenticated route.
data AuthUser = AuthUser
  { authUserId    :: !UserId
  , authSessionId :: !SessionId
  , authRoles     :: !(Set Role)
  , authScopes    :: !(Set Scope)
  , authClaims    :: !AuthClaims
  }
  deriving stock (Generic)

-- | Register 'AuthUser' as the server-side payload of @AuthProtect "shomei-jwt"@,
-- and name the combinator. Putting 'Authenticated' before a route (or a
-- @NamedRoutes@) makes that route's handler receive a leading 'AuthUser' arg.
type instance AuthServerData (AuthProtect "shomei-jwt") = AuthUser

type Authenticated = AuthProtect "shomei-jwt"

-- | Project an 'AuthClaims' (the verified JWT body) into the principal.
authUserFromClaims :: AuthClaims -> AuthUser
authUserFromClaims claims =
  AuthUser
    { authUserId    = claims ^. #subject
    , authSessionId = claims ^. #sessionId
    , authRoles     = claims ^. #roles
    , authScopes    = claims ^. #scopes
    , authClaims    = claims
    }

-- | The auth handler. The verifier is @\\t -> verifyToken jwks config t@ from EP-4
-- ('Shomei.Jwt.verifyToken'); this module never touches @jose@. Missing token =>
-- 401; failed verification => 401 (we do not distinguish, to avoid leaking why).
authHandler :: (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request AuthUser
authHandler verify = mkAuthHandler handle
  where
    handle :: Request -> Handler AuthUser
    handle req = do
      tok <- maybe (throwError err401 { errBody = "missing token" }) pure (extractToken req)
      res <- liftIO (verify tok)
      case res of
        Left _       -> throwError err401 { errBody = "invalid token" }
        Right claims -> pure (authUserFromClaims claims)

-- | Extract the bearer token: try @Authorization: Bearer <tok>@ first, then fall
-- back to the @shomei_session@ cookie. Returns the raw token 'Text'.
extractToken :: Request -> Maybe Text
extractToken req = bearer <|> cookieToken
  where
    headers = requestHeaders req

    bearer :: Maybe Text
    bearer = do
      raw <- lookup "Authorization" headers
      let t = Text.decodeUtf8 raw
      Text.stripPrefix "Bearer " t

    cookieToken :: Maybe Text
    cookieToken = do
      raw <- lookup "Cookie" headers
      let cookies = parseCookies raw
      val <- lookup ("shomei_session" :: BS.ByteString) cookies
      pure (Text.decodeUtf8 val)
```

Note on the `Context`: at assembly the handler is registered as
`authHandler verify :. EmptyContext` with type `'[AuthHandler Request AuthUser]`. The server is
served with `serveWithContext (Proxy @api) ctx server`. When handlers must be hoisted into a
runner monad use
`hoistServerWithContext (Proxy @api) (Proxy @'[AuthHandler Request AuthUser]) nt server`. We do
**not** hoist here because style A keeps handlers in `Handler` already (see the seam).

### Step 3 — `src/Shomei/Servant/Authz.hs` (`RequireRole` / `RequireScope`)

The MVP path is the guard functions; the phantom combinators are exported for documentation and
future `HasServer` work.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Role/scope authorization. MVP: 'requireRole'/'requireScope' guard functions
-- called at the top of an authenticated handler. The phantom 'RequireRole' /
-- 'RequireScope' combinators are exported so the API type can document intent and
-- a later plan can add their 'HasServer' instances without changing call sites.
module Shomei.Servant.Authz
  ( RequireRole
  , RequireScope
  , requireRole
  , requireScope
  ) where

import Shomei.Prelude
import Shomei.Domain (Role, Scope)
import Shomei.Servant.Auth (AuthUser (..))

import "base" GHC.TypeLits (Symbol)
import "containers" Data.Set qualified as Set
import "servant-server" Servant (throwError, err403, errBody)
import "servant-server" Servant.Server (Handler)

-- | Phantom combinator: document an admin-only route as
-- @RequireRole "admin" :> Authenticated :> ...@. Reserved for a future
-- 'HasServer' instance (see the sketch below); the MVP uses 'requireRole'.
data RequireRole (role :: Symbol)

-- | Phantom combinator for a required scope. Reserved for future 'HasServer'.
data RequireScope (scope :: Symbol)

-- | Guard: fail with 403 unless the principal carries the role.
requireRole :: Role -> AuthUser -> Handler ()
requireRole role u
  | role `Set.member` authRoles u = pure ()
  | otherwise = throwError err403 { errBody = "missing required role" }

-- | Guard: fail with 403 unless the principal carries the scope.
requireScope :: Scope -> AuthUser -> Handler ()
requireScope scope u
  | scope `Set.member` authScopes u = pure ()
  | otherwise = throwError err403 { errBody = "missing required scope" }

-- Future-work sketch (NOT compiled): a type-level guard. The difficulty is that
-- the AuthUser only exists after Authenticated has run, so the instance must be
-- written for @RequireRole role :> Authenticated :> api@ and read the AuthUser out
-- of the delegated sub-server. The guard-function form above sidesteps this.
--
-- > instance (KnownSymbol role, HasServer api ctx)
-- >       => HasServer (RequireRole role :> Authenticated :> api) ctx where
-- >   type ServerT (RequireRole role :> Authenticated :> api) m =
-- >          AuthUser -> ServerT api m
-- >   route _ ctx sub = route (Proxy @(Authenticated :> api)) ctx (checked <$> sub)
-- >     where checked f user = if Role (symbolText @role) `Set.member` authRoles user
-- >                              then f user else \_ -> throwError err403
```

The admin example from the spec is realized in `API.hs`/`Handlers.hs` as
`RequireRole "admin" :> Authenticated :> "admin" :> "users" :> Get '[JSON] [User]`, whose
handler calls `requireRole (Role "admin") user` first (see Step 6).

### Step 4 — `src/Shomei/Servant/DTO.hs` (all request/response DTOs)

The JSON shapes match the spec's examples exactly: `userId`/`email` are strings, `status` is
lowercased (e.g. `"active"`).

```haskell
-- | Request/response JSON DTOs for 'ShomeiAPI' (IP-6). Pure wire contract: no
-- Handler, no Eff. Field shapes mirror the spec's JSON examples.
module Shomei.Servant.DTO
  ( SignupRequest (..)
  , SignupResponse (..)
  , LoginRequest (..)
  , LoginResponse (..)
  , RefreshRequest (..)
  , TokenPairResponse (..)
  , UserResponse (..)
  , SessionResponse (..)
  , HealthResponse (..)
  , userToResponse
  , tokenPairToResponse
  ) where

import Shomei.Prelude
import Shomei.Domain (User, Session, TokenPair)   -- module names confirmed vs shomei-core

-- | @POST /auth/signup@ body.
data SignupRequest = SignupRequest
  { email       :: !Text
  , password    :: !Text
  , displayName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A token pair as wire JSON: { accessToken, refreshToken, expiresIn }.
data TokenPairResponse = TokenPairResponse
  { accessToken  :: !Text
  , refreshToken :: !Text
  , expiresIn    :: !Int
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A user as wire JSON: { userId, email, displayName, status }.
data UserResponse = UserResponse
  { userId      :: !Text
  , email       :: !Text
  , displayName :: !Text
  , status      :: !Text   -- lowercased, e.g. "active"
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/signup@ response: the user + the token pair.
data SignupResponse = SignupResponse
  { user  :: !UserResponse
  , token :: !TokenPairResponse
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/login@ body.
data LoginRequest = LoginRequest
  { email    :: !Text
  , password :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/login@ response: the user + token pair (same shape as signup).
data LoginResponse = LoginResponse
  { user  :: !UserResponse
  , token :: !TokenPairResponse
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/refresh@ body: just the opaque refresh token.
newtype RefreshRequest = RefreshRequest { refreshToken :: Text }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET /auth/session@ response.
data SessionResponse = SessionResponse
  { sessionId :: !Text
  , userId    :: !Text
  , createdAt :: !Text
  , expiresAt :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET /health@ response.
newtype HealthResponse = HealthResponse { status :: Text }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Render a domain 'User' to the wire DTO (id/email as Text, status lowercased).
userToResponse :: User -> UserResponse
userToResponse u = UserResponse
  { userId      = renderUserId (u ^. #userId)        -- via ToHttpApiData/Show of the TypeID
  , email       = renderEmail  (u ^. #email)
  , displayName = u ^. #displayName
  , status      = lowerStatus  (u ^. #status)
  }
  -- helpers renderUserId/renderEmail/lowerStatus inlined here against shomei-core's
  -- exact field/accessor names; userId via the TypeID's text rendering, email via
  -- its normalized text, status via a lowercased Show/enum render.

-- | Render a domain 'TokenPair' to the wire DTO.
tokenPairToResponse :: TokenPair -> TokenPairResponse
tokenPairToResponse tp = TokenPairResponse
  { accessToken  = renderAccessToken (tp ^. #accessToken)
  , refreshToken = tp ^. #refreshToken
  , expiresIn    = tp ^. #expiresIn
  }
```

The exact `signup` request and response JSON (copied from the spec; the handlers must produce
and accept exactly these shapes):

```json
{
  "email": "ada@example.com",
  "password": "correct horse battery staple",
  "displayName": "Ada Lovelace"
}
```

```json
{
  "user": {
    "userId": "user_01h455vb4pex5vsknk084sn02q",
    "email": "ada@example.com",
    "displayName": "Ada Lovelace",
    "status": "active"
  },
  "token": {
    "accessToken": "eyJhbGciOiJFUzI1NiIsImtpZCI6...",
    "refreshToken": "rt_2b9d...opaque...",
    "expiresIn": 900
  }
}
```

### Step 5 — `src/Shomei/Servant/API.hs` (`ShomeiAPI` + embedded `AppAPI` example)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The Shōmei HTTP API as a servant NamedRoutes record (IP-6), plus the embedded
-- 'AppAPI' example proving the API mounts inside a host Servant app.
module Shomei.Servant.API
  ( ShomeiAPI (..)
  , shomeiAPI
  , AppAPI
  ) where

import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Authz (RequireRole)
import Shomei.Servant.DTO
  ( SignupRequest, SignupResponse, LoginRequest, LoginResponse
  , RefreshRequest, TokenPairResponse, UserResponse, SessionResponse, HealthResponse )
import Shomei.Domain (User)

import "aeson" Data.Aeson (Value)
import "servant" Servant.API

-- | The standalone API. @signup\/login\/refresh\/logout\/me\/session@ live under
-- @\/auth@ (see 'AppAPI' / the server assembly for the prefix); @jwks@ is under
-- @\/.well-known@; @health@ is at @\/health@. Authenticated routes carry the
-- 'Authenticated' combinator, so their handlers receive a leading 'AuthUser'.
data ShomeiAPI mode = ShomeiAPI
  { signup :: mode
      :- "auth" :> "signup"
      :> ReqBody '[JSON] SignupRequest :> Post '[JSON] SignupResponse        -- 200/201
  , login :: mode
      :- "auth" :> "login"
      :> ReqBody '[JSON] LoginRequest :> Post '[JSON] LoginResponse
  , refresh :: mode
      :- "auth" :> "refresh"
      :> ReqBody '[JSON] RefreshRequest :> Post '[JSON] TokenPairResponse
  , logout :: mode
      :- "auth" :> "logout"
      :> Authenticated :> PostNoContent                                       -- 204
  , me :: mode
      :- "auth" :> Authenticated :> "me"
      :> Get '[JSON] UserResponse
  , session :: mode
      :- "auth" :> Authenticated :> "session"
      :> Get '[JSON] SessionResponse
  , jwks :: mode
      :- ".well-known" :> "jwks.json"
      :> Get '[JSON] Value
  , health :: mode
      :- "health" :> Get '[JSON] HealthResponse
  }
  deriving stock (Generic)

-- | A Proxy carrying the API type for 'serveWithContext'.
shomeiAPI :: Proxy (NamedRoutes ShomeiAPI)
shomeiAPI = Proxy

-- | Embeddability proof (from the spec): mount the whole Shōmei API under @\/auth@
-- alongside a host route protected by 'Authenticated', plus an admin route using
-- the 'RequireRole' phantom combinator for documentation. Compiling this shows the
-- combinators and the API type compose inside a host Servant app.
type AppAPI =
       "auth" :> NamedRoutes ShomeiAPI
  :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
  :<|> RequireRole "admin" :> Authenticated :> "admin" :> "users" :> Get '[JSON] [User]

-- A stand-in host type so AppAPI type-checks in this library; the real host app
-- supplies its own. (Defined minimally here, or imported in the example.)
data Project
  deriving stock (Generic)
```

Note on `Authenticated :> NamedRoutes Routes`: when `Authenticated` precedes a `NamedRoutes`
record, *every* field handler in that record receives a leading `AuthUser` argument. When it is
placed on individual fields (as in `ShomeiAPI` above for `logout`/`me`/`session`), only those
handlers receive the `AuthUser`. Both styles are supported; `ShomeiAPI` uses per-field so that
`signup`/`login`/`refresh` stay public.

### Step 6 — `src/Shomei/Servant/Error.hs` (AuthError → ServerError)

```haskell
-- | The single mapping from the domain 'AuthError' to servant's 'ServerError',
-- with a structured JSON body @{"error":<code>,"message":<text>}@. Modelled on
-- kizashi's "Kizashi.Http.Error": never leak internal detail; login uses a
-- generic message so account existence/status is not disclosed.
module Shomei.Servant.Error
  ( authErrorToServerError
  ) where

import Shomei.Prelude
import Shomei.Error (AuthError (..))
import "aeson" Data.Aeson qualified as Aeson
import "servant-server" Servant
  ( ServerError (..), err400, err401, err403, err404, err409, err500 )

authErrorToServerError :: AuthError -> ServerError
authErrorToServerError = \case
  InvalidEmail _            -> json err400 "invalid_email"     "Email is not valid"
  WeakPassword _            -> json err400 "weak_password"     "Password does not meet policy"
  InvalidCredentials        -> json err401 "invalid_login"     "Invalid email or password"
  UserNotActive             -> json err401 "invalid_login"     "Invalid email or password"
  EmailAlreadyRegistered    -> json err409 "email_taken"       "Email is already registered"
  RefreshTokenReuseDetected -> json err401 "token_reuse"       "Refresh token reuse detected"
  TokenInvalid              -> json err401 "token_invalid"     "Token is invalid"
  InternalAuthError _       -> json err500 "internal"          "Internal authentication error"
  -- Session*/RefreshToken* family mapped per semantics (confirmed vs shomei-core):
  -- not-found -> 404, expired/revoked -> 401, conflict -> 409.
  e                         -> json err401 "unauthorized"      (defaultMessage e)
  where
    json base code msg = base
      { errBody    = Aeson.encode (Aeson.object
          [ "error"   Aeson..= (code :: Text)
          , "message" Aeson..= (msg  :: Text) ])
      , errHeaders = [("Content-Type", "application/json")]
      }
    defaultMessage _ = "Unauthorized"
```

### Step 7 — `src/Shomei/Servant/Seam.hs` (`Env` + `effToHandler`, style A)

```haskell
{-# LANGUAGE DataKinds #-}

-- | THE SEAM (style A, per-action). Run an 'Eff' over the effect stack to IO via the
-- runner carried in 'Env', then map a domain @Left AuthError@ to a 'ServerError'
-- through "Shomei.Servant.Error". Mirrors kizashi's 'Kizashi.Http.Seam.effToHandler'.
module Shomei.Servant.Seam
  ( Env (..)
  , effToHandler
  ) where

import Shomei.Prelude
import Shomei.Config (ShomeiConfig)
import Shomei.Error (AuthError)
import Shomei.Servant.Error (authErrorToServerError)

import "effectful-core" Effectful (Eff)
import "servant-server" Servant (Handler, throwError)
import "servant-server" Servant.Server (runHandler)  -- not used directly; here for clarity
import Control.Monad.IO.Class (liftIO)

-- | The runtime environment threaded to every handler. @runEff@ is the EP-2 effect
-- interpreter runner (in tests, the in-memory stack; in EP-6, the postgres+jwt
-- stack). @config@ is the 'ShomeiConfig'. @jwks@ is the current public 'JWKSet'
-- used by the jwks route and (partially applied) by the AuthHandler verifier.
data Env = Env
  { runEff :: !(forall a. Eff AppEffects a -> IO (Either AuthError a))
  , config :: !ShomeiConfig
  , jwks   :: !JWKSet     -- from shomei-jwt; type imported in the real module
  }

-- | Run an action and turn a domain failure into HTTP. A @Right@ flows through; a
-- @Left AuthError@ becomes the matching 'ServerError'.
effToHandler :: Env -> Eff AppEffects a -> Handler a
effToHandler env action = do
  result <- liftIO (runEff env action)
  case result of
    Right a  -> pure a
    Left err -> throwError (authErrorToServerError err)
```

(`AppEffects` is the concrete effect-list alias; in the real module it is either imported
from `shomei-core` if EP-2 exports such an alias, or defined locally as the list of the eleven
effects. `JWKSet` is from `shomei-jwt`/`jose` re-export.)

### Step 8 — `src/Shomei/Servant/Handlers.hs` (`shomeiServer`)

At least `signup` and `me` are shown in full; the others follow the same pattern.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

-- | The server for 'ShomeiAPI': handlers run in 'Handler', drive the EP-2
-- workflows through 'effToHandler', and map results to DTOs.
module Shomei.Servant.Handlers
  ( shomeiServer
  ) where

import Shomei.Prelude
import Data.Generics.Labels ()
import Shomei.Servant.API (ShomeiAPI (..))
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.DTO
  ( SignupRequest (..), SignupResponse (..), LoginRequest (..), LoginResponse (..)
  , RefreshRequest (..), TokenPairResponse, UserResponse, SessionResponse (..)
  , HealthResponse (..), userToResponse, tokenPairToResponse )
import Shomei.Servant.Seam (Env (..), effToHandler)
import Shomei.Domain (SignupCommand (..), LoginCommand (..), RefreshCommand (..), LogoutCommand (..))
import Shomei.Workflow (signup, login, refresh, logout)  -- the EP-2 workflows
import Shomei.Jwt (jwksDocument)                          -- EP-4

import "servant-server" Servant (Handler, NoContent (..))
import "servant-server" Servant.API.Generic (AsServerT)

shomeiServer :: Env -> ShomeiAPI (AsServerT Handler)
shomeiServer env = ShomeiAPI
  { signup  = signupH env
  , login   = loginH env
  , refresh = refreshH env
  , logout  = logoutH env
  , me      = meH env
  , session = sessionH env
  , jwks    = jwksH env
  , health  = healthH
  }

-- | POST /auth/signup — run the signup workflow, map (User, TokenPair) to the DTO.
signupH :: Env -> SignupRequest -> Handler SignupResponse
signupH env req = do
  let cmd = SignupCommand
        { email       = req ^. #email
        , password    = req ^. #password
        , displayName = req ^. #displayName
        }
  (user, pair) <- effToHandler env (signup (config env) cmd)
  pure SignupResponse
    { user  = userToResponse user
    , token = tokenPairToResponse pair
    }

-- | GET /auth/me — no workflow needed; the principal already carries identity.
-- (A richer version could re-read the user from the store via a workflow.)
meH :: Env -> AuthUser -> Handler UserResponse
meH env user =
  -- Either project from authClaims, or re-fetch the canonical User from the store
  -- through the seam. The MVP fetches to return the live record:
  effToHandler env (lookupUserResponse (authUserId user))
  where
    lookupUserResponse uid = fmap userToResponse <$> fetchUser uid  -- via UserStore effect
    -- 'fetchUser' is a thin Eff over the UserStore effect; on miss the workflow
    -- returns Left (a Session/Token error) which the seam maps to 401/404.

loginH   :: Env -> LoginRequest   -> Handler LoginResponse
loginH env req = do
  let cmd = LoginCommand { email = req ^. #email, password = req ^. #password }
  (user, pair) <- effToHandler env (login (config env) cmd)
  pure LoginResponse { user = userToResponse user, token = tokenPairToResponse pair }

refreshH :: Env -> RefreshRequest -> Handler TokenPairResponse
refreshH env req = do
  pair <- effToHandler env (refresh (config env) (RefreshCommand { refreshToken = req ^. #refreshToken }))
  pure (tokenPairToResponse pair)

logoutH  :: Env -> AuthUser -> Handler NoContent
logoutH env user = do
  effToHandler env (logout (config env) (LogoutCommand { sessionId = authSessionId user }))
  pure NoContent

sessionH :: Env -> AuthUser -> Handler SessionResponse
sessionH env user = effToHandler env (lookupSessionResponse (authSessionId user))
  where lookupSessionResponse = undefined  -- thin SessionStore read mapped to SessionResponse

-- | GET /.well-known/jwks.json — public JWKS from the current keys (no workflow).
jwksH :: Env -> Handler Value
jwksH env = pure (jwksDocument (jwks env))

-- | GET /health — always ok.
healthH :: Handler HealthResponse
healthH = pure (HealthResponse { status = "ok" })
```

The admin route from `AppAPI` (`RequireRole "admin" :> Authenticated :> "admin" :> "users"`)
has a handler that calls the guard first:

```haskell
adminUsersH :: Env -> AuthUser -> Handler [User]
adminUsersH env user = do
  requireRole (Role "admin") user   -- 403 unless admin (Shomei.Servant.Authz)
  effToHandler env listAllUsers
```


## Validation and Acceptance

Acceptance is **behavioral**, demonstrated over real HTTP by `test-suite shomei-servant-test`.
The test boots the app in-process and drives it with `http-client`.

### Step 9 — `test/Main.hs`

The test (a) generates a real ES256 key in-test (EP-4's key generator), (b) builds the EP-2
in-memory effect-interpreter runner and the `Env`, (c) boots via
`Network.Wai.Handler.Warp.testWithApplication` on an ephemeral port, then asserts:

```haskell
-- Behavioral assertions (tasty-hunit), against http://127.0.0.1:<ephemeral>/ :
-- a) POST /auth/signup {email,password,displayName} => 200/201, body has token.accessToken,
--    token.refreshToken, user.email == sent email, user.status == "active".
-- b) POST /auth/login  {same email,password}        => 200, body has a token pair.
-- c) GET  /auth/me  with "Authorization: Bearer <accessToken>" => 200, user.email matches.
-- d) GET  /auth/me  with NO Authorization header     => 401.
--    GET  /auth/me  with "Authorization: Bearer garbage" => 401.
-- e) POST /auth/refresh {refreshToken}               => 200, NEW pair (refreshToken differs).
-- f) GET  /.well-known/jwks.json                     => 200, JSON has keys[].kid, NO "d"
--    (no private EC scalar) anywhere in the document.
-- g) admin route with a non-admin AuthUser's token   => 403; with an admin token => 200.
```

Build the admin route into the test app (a tiny `AppAPI`-style server with one
`RequireRole "admin"` handler) so case (g) is exercised end-to-end. Mint a non-admin and an
admin token by signing claims with the in-test key (or by signing up two users and granting one
the `admin` role through the in-memory store) so both branches run.

Run the suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
cabal test shomei-servant
```

Expected transcript (shape; exact case names may differ):

```text
shomei-servant-test
  HTTP end-to-end (in-memory interpreters + in-test ES256 key)
    signup returns 200 with a token pair and active user: OK
    login with same credentials returns a token pair:     OK
    me with Bearer token returns the user:                OK
    me with no token returns 401:                         OK
    me with garbage token returns 401:                    OK
    refresh rotates the refresh token:                    OK
    jwks.json exposes the kid and no private material:    OK
    RequireRole admin: 403 for non-admin, 200 for admin:  OK

All 8 tests passed (0.42s)
```

Example HTTP transcript for **signup** (request and response):

```http
POST /auth/signup HTTP/1.1
Host: 127.0.0.1:8080
Content-Type: application/json

{"email":"ada@example.com","password":"correct horse battery staple","displayName":"Ada Lovelace"}
```

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"user":{"userId":"user_01h455vb4pex5vsknk084sn02q","email":"ada@example.com","displayName":"Ada Lovelace","status":"active"},"token":{"accessToken":"eyJhbGciOiJFUzI1NiIsImtpZCI6...","refreshToken":"rt_2b9d...opaque...","expiresIn":900}}
```

Example HTTP transcript for **`GET /auth/me` with no token (401)**:

```http
GET /auth/me HTTP/1.1
Host: 127.0.0.1:8080
```

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/octet-stream

missing token
```

Milestone-level acceptance:

- Milestone 1: `cabal build shomei-servant` is green; the contract modules compile.
- Milestone 2: `cabal build shomei-servant` is green with `Handlers`/`Seam`/`Error` present and
  the embedded `AppAPI` example compiling.
- Milestone 3: `cabal test shomei-servant` passes all cases above (proof beyond compilation).


## Idempotence and Recovery

All steps are file creations and edits under `shomei-servant/`; rerunning them is safe
(re-`Write`/re-`Edit` to the desired final content). Creating directories with `mkdir -p` is
idempotent. The `cabal.project` registration uses a `grep -q … ||` guard so it appends the
package line at most once. `cabal build`/`cabal test` are read-only with respect to source and
fully repeatable; on failure, fix the named module and re-run the same command. The warp test
binds an **ephemeral** port via `testWithApplication`, so repeated runs never collide on a fixed
port and never leave a server listening (the application is torn down when the test action
returns). No database, no external services, and no global state are touched, so there is
nothing to roll back; deleting `shomei-servant/` returns the workspace to its
pre-plan state.


## Interfaces and Dependencies

Libraries used and why:

- `servant` (>=0.20.2) — the API combinators (`ReqBody`, `Get`, `Post`, `PostNoContent`,
  `NamedRoutes`, `:>`, `:<|>`) and `AuthProtect` (generalized auth). The `>=0.20.2` floor
  matches the GHC-9.12-compatible line.
- `servant-server` (>=0.20) — `serveWithContext`, `hoistServerWithContext`, `AuthHandler`,
  `mkAuthHandler`, `AuthServerData`, `Handler`, `ServerError`/`err4xx`, `AsServerT`.
- `wai` — `Request`/`requestHeaders` for `extractToken`.
- `cookie` (`Web.Cookie`) — `parseCookies` for the `shomei_session` cookie fallback.
- `warp` (test only) — `testWithApplication` to boot the app on an ephemeral port.
- `http-api-data` — `FromHttpApiData`/`ToHttpApiData` used by `Capture` on TypeID ids (orphans
  provided by EP-2's `Shomei.Id`).
- `aeson`, `text`, `time`, `containers`, `bytestring` — DTO JSON, token text, timestamps,
  `Set Role`/`Set Scope`, raw header bytes.
- `effectful`, `effectful-core` — the `Eff` effect stack and the seam runner type.
- `shomei-core` — domain types, errors, `ShomeiConfig`, the effects, and the auth workflows.
- `shomei-jwt` — `verifyToken` (the AuthHandler verifier) and `jwksDocument` (the jwks route).
- `tasty`, `tasty-hunit`, `http-client`, `http-types` (test only) — the end-to-end harness.

Types, interfaces, and signatures that must exist at the end of each milestone (full module
paths). **IP-6 is owned here.**

End of Milestone 1:

```haskell
-- Shomei.Servant.Auth
data AuthUser = AuthUser
  { authUserId :: !UserId, authSessionId :: !SessionId
  , authRoles :: !(Set Role), authScopes :: !(Set Scope), authClaims :: !AuthClaims }
  deriving stock (Generic)
type Authenticated = AuthProtect "shomei-jwt"
type instance AuthServerData (AuthProtect "shomei-jwt") = AuthUser
authHandler        :: (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request AuthUser
extractToken       :: Request -> Maybe Text
authUserFromClaims :: AuthClaims -> AuthUser

-- Shomei.Servant.Authz
data RequireRole  (role  :: Symbol)
data RequireScope (scope :: Symbol)
requireRole  :: Role  -> AuthUser -> Handler ()
requireScope :: Scope -> AuthUser -> Handler ()

-- Shomei.Servant.DTO  (each derives FromJSON/ToJSON)
data SignupRequest;  data SignupResponse
data LoginRequest;   data LoginResponse
newtype RefreshRequest
data TokenPairResponse
data UserResponse;   data SessionResponse
newtype HealthResponse
userToResponse      :: User -> UserResponse
tokenPairToResponse :: TokenPair -> TokenPairResponse

-- Shomei.Servant.API
data ShomeiAPI mode = ShomeiAPI { signup, login, refresh, logout, me, session, jwks, health }
  deriving stock (Generic)
shomeiAPI :: Proxy (NamedRoutes ShomeiAPI)
type AppAPI = "auth" :> NamedRoutes ShomeiAPI
         :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
         :<|> RequireRole "admin" :> Authenticated :> "admin" :> "users" :> Get '[JSON] [User]
```

End of Milestone 2:

```haskell
-- Shomei.Servant.Error
authErrorToServerError :: AuthError -> ServerError

-- Shomei.Servant.Seam
data Env = Env { runEff :: forall a. Eff AppEffects a -> IO (Either AuthError a)
               , config :: ShomeiConfig, jwks :: JWKSet }
effToHandler :: Env -> Eff AppEffects a -> Handler a

-- Shomei.Servant.Handlers
shomeiServer :: Env -> ShomeiAPI (AsServerT Handler)
```

The HTTP error mapping (the contract every handler relies on through the seam and AuthHandler):

```text
InvalidEmail               -> 400  invalid_email
WeakPassword               -> 400  weak_password
InvalidCredentials         -> 401  invalid_login   ("Invalid email or password" — generic)
UserNotActive              -> 401  invalid_login   ("Invalid email or password" — generic)
EmailAlreadyRegistered     -> 409  email_taken
RefreshTokenReuseDetected  -> 401  token_reuse
TokenInvalid               -> 401  token_invalid
Session* not-found         -> 404
Session*/RefreshToken* expired/revoked -> 401
InternalAuthError          -> 500  internal       (generic message; no detail leaked)
missing/invalid Bearer (AuthHandler) -> 401
RequireRole/RequireScope failure     -> 403
```

The consumed EP-4 contract (must exist for this plan to assemble):

```haskell
verifyToken  :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
jwksDocument :: JWKSet -> Aeson.Value
```

Assembly contract (used by EP-6 and the test): the `Context` is
`authHandler verify :. EmptyContext :: Context '[AuthHandler Request AuthUser]` where
`verify = \t -> verifyToken jwks config t`; serve with
`serveWithContext shomeiAPI ctx (shomeiServer env)`.

Downstream consumers of IP-6: **EP-6** serves `ShomeiAPI` from `shomei-server`; **EP-7**'s
`shomei-client` derives `servant-client` functions from the same `ShomeiAPI` type (the
master-plan Decision Log records widening `shomei-client`'s dependency to `shomei-servant`), and
the embedded demo reuses these routes — both rely on this plan keeping the API type and DTOs
stable.

Commit trailers for every commit in this plan:

```text
MasterPlan: docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md
ExecPlan: docs/plans/5-servant-integration-and-route-protection.md
Intention: intention_01kt7xgv3pes2v675nr1pmzf6j
```
