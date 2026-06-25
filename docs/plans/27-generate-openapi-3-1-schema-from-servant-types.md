---
id: 27
slug: generate-openapi-3-1-schema-from-servant-types
title: "Generate OpenAPI 3.1 schema from Servant types"
kind: exec-plan
created_at: 2026-06-25T02:47:48Z
intention: "intention_01kvyaehf5etmb554vhvmgp27w"
---

# Generate OpenAPI 3.1 schema from Servant types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei's HTTP contract is defined once, in Haskell, as the Servant API type
`ShomeiAPI` (file `shomei-servant/src/Shomei/Servant/API.hs`). Today there is no
machine-readable description of that contract, so a developer who wants to call
the auth service from TypeScript, Python, Go, Rust, etc. must read the Haskell
source and hand-write a client.

After this change, the project produces an **OpenAPI 3.1** document
(`docs/api/openapi.json`) that is generated *directly from the Servant types*, so
it cannot drift from the server. A developer in any language can then run a
standard tool — [OpenAPI Generator](https://openapi-generator.tech/) or
[Swagger Codegen](https://swagger.io/tools/swagger-codegen/) — against that file
to produce a typed client.

Concretely, after this plan is implemented you can:

1. Regenerate the schema from source:

    ```bash
    cabal run shomei-openapi > docs/api/openapi.json
    ```

2. See that it is a valid OpenAPI **3.1.0** document whose `paths` cover every
   route in `ShomeiAPI` (signup, login, refresh, service-token, passkeys, MFA,
   impersonation, audit, JWKS, health, ready), with a `bearerAuth` security
   scheme attached to every authenticated route.

3. Generate a client in another language from the committed file, e.g.:

    ```bash
    npx @openapitools/openapi-generator-cli generate \
      -i docs/api/openapi.json -g typescript-fetch -o /tmp/shomei-ts-client
    ```

The mechanism is the local library at
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`
(Haskell package **`servant-openapi`** version `4.0.0`), which provides
`toOpenApi :: HasOpenApi api => Proxy api -> OpenApi` and emits OpenAPI 3.1.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Dependencies wired.** Added `source-repository-package` pins for
  `servant-openapi` (`shinzui/servant-openapi` @ `558b7b9`) and `openapi-hs`
  (`shinzui/openapi-hs` @ `89e9ed0`) to `cabal.project`; added `servant-openapi`,
  `openapi-hs`, and `lens` to `shomei-servant.cabal` `build-depends`. Package set
  solves (no `allow-newer` needed) and `cabal build shomei-servant` succeeds.
- [x] **M2 — Schemas and combinator instances.** Created
  `shomei-servant/src/Shomei/Servant/OpenApi.hs` with: `ToSchema` instances for
  every DTO, a `ToSchema Value` mapping (named `AnyValue`, empty schema),
  `ToParamSchema PasskeyId`, a hand-written `oneOf` `ToSchema LoginResponse`,
  `HasOpenApi` instances for the custom combinators (`AuthProtect "shomei-jwt"`,
  `RequireRole`, `RequireScope`), and `shomeiOpenApi :: OpenApi` (enriched with
  info/servers + per-operation `operationId`s). Module compiles; `encode
  shomeiOpenApi` produces a document with 24 paths and a `bearerAuth` security
  scheme.
- [ ] **M3 — Generator executable and committed spec.** Add an `executable
  shomei-openapi` to `shomei-servant.cabal`; generate `docs/api/openapi.json`;
  verify `openapi` field is `3.1.0` and all routes are present.
- [ ] **M4 — Conformance test and external lint.** Add a test in
  `shomei-servant/test` using `Servant.OpenApi.Test.validateEveryToJSON` and an
  assertion on the version/path count; lint the generated file with an external
  OpenAPI validator.
- [ ] **M5 — Client-generation proof and documentation.** Document the codegen
  workflow under `docs/user/`; prove it by generating one client (e.g.
  `typescript-fetch`). (Optional) serve the spec at `GET /openapi.json` from
  `shomei-server`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M1:** At implementation time `github.com/shinzui/servant-openapi` did not yet
  exist (the local clone had no remote). The user pushed the local clone (commit
  `558b7b9`) to `shinzui/servant-openapi` so the git pin could be used as the
  Decision Log intended; no local `packages:` fallback was needed. `openapi-hs` @
  `89e9ed0` was already reachable from `shinzui/openapi-hs` master. The solver
  pulled in `insert-ordered-containers-0.2.7` transitively; no `allow-newer` was
  required.
- **M2:** Two API-shape deviations from the plan sketch, both because `openapi-hs`
  is a true 3.1 model (JSON-Schema-2020-12), not the 3.0 `openapi3`/`swagger2`
  API: (1) a `Schema`'s `type_` is `Maybe OpenApiTypeValue`, so it is set with
  `?~ OpenApiTypeSingle OpenApiString` (not `?~ OpenApiString`); (2)
  `components.securitySchemes` targets the `SecurityDefinitions` newtype which has
  no `At` instance, so the scheme is registered with `<>~ SecurityDefinitions
  (IOHM.singleton "bearerAuth" …)` rather than `. at "bearerAuth" ?~`. This needed
  a direct `insert-ordered-containers` dep (added to `shomei-servant.cabal`).
  Also: under GHC2024 `role` is a reserved word (RoleAnnotations), so the
  `RequireRole` instance binds its symbol var as `r`, matching `Authz.hs`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the local `servant-openapi` (v4.0.0) at
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`, pinned
  into `cabal.project` via `source-repository-package` git stanzas pointing at the
  GitHub forks `shinzui/servant-openapi` and `shinzui/openapi-hs`, mirroring the
  existing convention in `cabal.project` (jose, codd, webauthn, ephemeral-pg are
  all pinned the same way).
  Rationale: The two packages are not on Hackage in the versions required (the
  servant-openapi cabal advertises Hackage but the 3.1 line depends on the
  `openapi-hs` fork, which is git-only); git pins keep the build reproducible on
  CI and other machines, unlike a local `packages:` path that escapes the repo
  tree. `openapi-hs` is already pinned by servant-openapi's own `cabal.project` at
  tag `89e9ed07e0dd3e1eaa9b3efea28b3c722f8c60c8`; reuse that tag.
  Date: 2026-06-25

- Decision: Concentrate all OpenAPI-specific instances in a single new module
  `Shomei.Servant.OpenApi`, using `{-# OPTIONS_GHC -Wno-orphans #-}`, rather than
  scattering `ToSchema`/`HasOpenApi` instances across `DTO.hs`, `Auth.hs`,
  `Authz.hs`.
  Rationale: Keeps the OpenAPI dependency and its orphan instances contained in
  one place, leaves the existing transport/DTO modules untouched, and makes the
  spec assembly easy to find and test. The orphans are only ever resolved at the
  `toOpenApi` call site inside this same module and its executable/test, so there
  is no incoherence risk.
  Date: 2026-06-25

- Decision: Generate the spec from `Proxy (NamedRoutes ShomeiAPI)` (the
  standalone service contract that `shomei-server` actually serves), not from the
  `AppAPI` embedding example.
  Rationale: `ShomeiAPI` is the reusable, published auth contract; `AppAPI`
  (in `examples/embedded-servant-app`) is a host-app demo. `servant-openapi`
  supports `NamedRoutes` via `instance HasOpenApi (ToServantApi sub) => HasOpenApi
  (NamedRoutes sub)` (verified in `Servant/OpenApi/Internal.hs:432`).
  Date: 2026-06-25

- Decision: Commit the generated `docs/api/openapi.json` to the repository.
  Rationale: Downstream client developers should be able to run codegen without a
  Haskell toolchain; a committed artifact is the deliverable. The conformance
  test (M4) guards it against drift.
  Date: 2026-06-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the project beyond Haskell basics.

**What is Shōmei?** A self-contained authentication service. It is a Cabal
multi-package project (GHC 9.12.4) defined by `cabal.project` at the repo root.
The packages relevant here are:

- `shomei-servant` — defines the HTTP API as Servant types, the DTOs
  (data-transfer objects) that cross the wire, custom Servant combinators, and the
  handlers. **All new code in this plan lands here.**
- `shomei-server` — the Warp executable (`shomei-server`) that serves the API.
  Only touched in the optional M5 endpoint.

**What is Servant?** A Haskell library where an HTTP API is a *type*. Routes are
built from type-level combinators with `:>` (path/segment composition), `:<|>`
(alternative routes), `ReqBody`, `Capture`, `QueryParam`, `Get`/`Post`/`Verb`,
etc. Shōmei uses the **`NamedRoutes` record style**: the API is a record
(`ShomeiAPI`) whose fields are individual routes.

**The API type** — `shomei-servant/src/Shomei/Servant/API.hs` defines:

```haskell
data ShomeiAPI mode = ShomeiAPI
  { signup       :: mode :- "auth" :> "signup"  :> ReqBody '[JSON] SignupRequest  :> Post '[JSON] SignupResponse
  , login        :: mode :- "auth" :> "login"   :> RemoteHost :> ReqBody '[JSON] LoginRequest :> Post '[JSON] LoginResponse
  , refresh      :: mode :- "auth" :> "refresh" :> ReqBody '[JSON] RefreshRequest :> Post '[JSON] TokenPairResponse
  , serviceToken :: mode :- "auth" :> "service-token" :> ReqBody '[JSON] ServiceTokenRequest :> Post '[JSON] ServiceTokenResponse
  -- ... ~27 routes total: verify-email, password-reset, password change/logout,
  --     me, session, passkeys (register/list/delete/login), mfa, impersonate,
  --     admin/audit/events, .well-known/jwks.json, health, ready ...
  } deriving stock (Generic)
```

The standalone server serves `Proxy (NamedRoutes ShomeiAPI)` (see
`shomei-server/src/Shomei/Server/Boot.hs`, which calls `serveWithContext`).

**Custom combinators** (these have *no* `HasOpenApi` instance in the library, so
we must provide them — see Plan of Work M2):

- `Authenticated` — a synonym for `AuthProtect "shomei-jwt"`, defined in
  `shomei-servant/src/Shomei/Servant/Auth.hs`. Marks a route as requiring a JWT
  bearer token.
- `RequireRole (role :: Symbol)` and `RequireScope (scope :: Symbol)` — phantom
  combinators defined in `shomei-servant/src/Shomei/Servant/Authz.hs`. They appear
  in the type as `RequireRole "admin" :> ...` and are transparent at runtime.
- `RemoteHost` — from `Servant.API`; the library already handles it as a no-op
  (`Servant/OpenApi/Internal.hs:285`).

**The DTOs** — `shomei-servant/src/Shomei/Servant/DTO.hs` defines every request
and response record. Almost all derive JSON with **default options**:

```haskell
data SignupRequest = SignupRequest { ... }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)
```

Two complications to handle:

1. Several records carry a field of aeson's `Value` type (free-form JSON):
   `MfaCompleteRequest.assertion`, `PasskeyLoginBeginResponse.options`,
   `PasskeyLoginCompleteRequest.assertion`, `PasskeyRegisterBeginResponse.options`,
   `PasskeyRegisterCompleteRequest.credential`, plus the `jwks` route returns a
   bare `Value`. **`openapi-hs` provides no `ToSchema Value` instance** (verified:
   no such instance exists in its source), so we add one mapping `Value` to a
   free-form object schema.
2. `LoginResponse` (file `DTO.hs` ~line 128) is a **sum type with a hand-written
   `ToJSON`/`FromJSON`** (a tagged union: a completed login vs. an
   "MFA required" response carrying `options :: Value`). Generic `ToSchema`
   derivation would not match its custom JSON, so it needs a hand-written
   `ToSchema` describing a `oneOf`.

**Path capture types** — the only non-primitive capture is `PasskeyId`
(`passkeyDelete` route). `PasskeyId = KindID "passkey"` (a TypeID/KindID), defined
in `shomei-core/src/Shomei/Id.hs:75`. Captures require a `ToParamSchema` instance
(string). Query params in the `auditEvents` route are `Text`/`Int`, which already
have `ToParamSchema`.

**The library** — `servant-openapi` 4.0.0 lives at
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`. Key facts
verified from its source:

- Module `Servant.OpenApi` exports `toOpenApi :: HasOpenApi api => Proxy api ->
  OpenApi` and `subOperations`.
- The `OpenApi` type and the schema classes (`ToSchema`, `ToParamSchema`,
  `SecurityScheme`, etc.) come from `openapi-hs`'s `Data.OpenApi` module.
- It emits OpenAPI **3.1.0** (the `OpenApiSpecVersion` `Monoid` default is
  `[3,1,0]`; `encode spec` yields `{"openapi":"3.1.0", ...}`).
- Security-scheme types available in `Data.OpenApi`:
  `SecurityScheme`, `SecuritySchemeType (SecuritySchemeHttp HttpSchemeType)`,
  `HttpSchemeType (HttpSchemeBearer (Just "jwt") | ...)`,
  `SecurityRequirement`.
- It ships a reference generator at
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs/app/GenOpenApi.hs`
  — read it; our `shomei-openapi` executable mirrors its structure (info, servers,
  tags, `withOperationIds`, `encode` to stdout).
- It ships `Servant.OpenApi.Test.validateEveryToJSON` for round-trip conformance
  testing (JSON produced by `ToJSON` validates against the generated schema).

**Version compatibility** — `servant-openapi` requires `servant >=0.17 && <0.21`;
Shōmei pins `servant >=0.20.2` (compatible). It is tested with GHC 9.12.4 /
9.14.1; Shōmei uses 9.12.4. `aeson <2.3` and `lens <5.4` constraints are
compatible with the current package set; watch for solver conflicts in M1.


## Plan of Work

The work is five milestones. Each ends in a buildable, independently verifiable
state. Run all commands from the repo root
`/Users/shinzui/Keikaku/bokuno/shomei` unless stated otherwise.

### Milestone M1 — Wire dependencies

Scope: make `servant-openapi` and its `Data.OpenApi` types available to
`shomei-servant` and prove the package set still solves and builds. No OpenAPI
code yet.

1. Edit `cabal.project`. Append a new override block at the end (do not rewrite
   existing blocks — the file's convention is "each plan appends its own block"):

    ```cabal
    -- ============================================================
    -- EP-27 (OpenAPI): generate an OpenAPI 3.1 schema from the Servant types.
    -- servant-openapi (3.1 line) depends on the openapi-hs fork, which is git-only,
    -- so both are pinned here, mirroring the other source-repository-package pins.
    -- openapi-hs tag matches servant-openapi's own cabal.project pin.
    -- ============================================================
    source-repository-package
      type: git
      location: https://github.com/shinzui/servant-openapi.git
      tag: <servant-openapi-commit>

    source-repository-package
      type: git
      location: https://github.com/shinzui/openapi-hs.git
      tag: 89e9ed07e0dd3e1eaa9b3efea28b3c722f8c60c8
    ```

   For `<servant-openapi-commit>`, use the commit currently checked out in the
   local clone — obtain it with:

    ```bash
    git -C /Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs rev-parse HEAD
    ```

   (At plan-authoring time this is `558b7b9ee3aaf3bff70a4cf1d6c8e2ed4eaccbde`.)
   **Verify that commit is pushed to `github.com/shinzui/servant-openapi`** before
   relying on it (`git ls-remote https://github.com/shinzui/servant-openapi.git`).
   If it is not yet pushed, either push it or, as a temporary local-only fallback,
   add `packages: ../openapi-hs-project/servant-openapi-hs` instead and record the
   deviation in Surprises & Discoveries. If the solver complains about upper
   bounds, add an `allow-newer:` line in this same block and record why.

2. Edit `shomei-servant/shomei-servant.cabal`. In the **library** stanza's
   `build-depends`, add:

    ```cabal
    , servant-openapi
    , openapi-hs
    , lens
    ```

   (`openapi-hs` provides `Data.OpenApi`; `lens` is needed for the `&`/`.~`/`?~`
   spec-enrichment operators. `aeson`, `text`, `bytestring` are already present.)
   Also expose the new module once it exists (M2): add
   `Shomei.Servant.OpenApi` under `exposed-modules`.

3. Prove the solve and build:

    ```bash
    cabal build shomei-servant
    ```

   Acceptance: the build succeeds and the dependency plan now lists
   `servant-openapi` and `openapi-hs`. (Adding the modules to `exposed-modules`
   before they exist will fail the build; add the `exposed-modules` line together
   with the file in M2, or create an empty stub module now.)

Commit M1.

### Milestone M2 — Schemas and combinator instances

Scope: create `shomei-servant/src/Shomei/Servant/OpenApi.hs` containing every
instance needed for `toOpenApi (Proxy @(NamedRoutes ShomeiAPI))` to typecheck,
plus the assembled, enriched `shomeiOpenApi :: OpenApi`. At the end, the module
compiles and the full spec value is forced without error.

Create the module with `{-# OPTIONS_GHC -Wno-orphans #-}`. It must provide:

1. **`ToSchema` for every DTO.** For records that derive JSON with default
   options, an empty instance using the generic default suffices:

    ```haskell
    instance ToSchema SignupRequest
    instance ToSchema SignupResponse
    instance ToSchema TokenPairResponse
    instance ToSchema UserResponse
    -- ... one per DTO in DTO.hs: LoginRequest, RefreshRequest, VerifyEmailRequest,
    -- ConfirmEmailVerificationRequest, PasswordResetRequest,
    -- ConfirmPasswordResetRequest, ChangePasswordRequest, MfaCompleteRequest,
    -- SessionResponse, HealthResponse, ReadyResponse,
    -- PasskeyRegisterBeginResponse, PasskeyRegisterCompleteRequest, PasskeyResponse,
    -- PasskeyLoginBeginResponse, PasskeyLoginCompleteRequest,
    -- ImpersonateRequest, ImpersonateResponse,
    -- ServiceTokenRequest, ServiceTokenResponse,
    -- AuditEventResponse, AuditEventsPage
    ```

   Each DTO already derives `Generic`, so the generic `declareNamedSchema` default
   produces a schema matching the default-options JSON. **The schema must match
   the JSON encoding** — since the DTOs use plain `deriving anyclass (ToJSON)`
   (default options, no field-label modifier), the generic schema matches with no
   custom `SchemaOptions`. The M4 conformance test enforces this.

2. **`ToSchema Value`** — `openapi-hs` has none. Add a free-form-object mapping:

    ```haskell
    instance ToSchema Value where
      declareNamedSchema _ = pure (NamedSchema (Just "AnyValue") mempty)
    ```

   (`mempty :: Schema` is the empty schema, which OpenAPI 3.1 treats as
   "any JSON value" — correct for these opaque WebAuthn/JWKS payloads.) Confirm
   the exact constructor name (`NamedSchema`) against `Data.OpenApi`.

3. **`ToSchema LoginResponse`** — hand-written to mirror its custom `ToJSON`
   (read `DTO.hs` lines ~128–158 for the exact discriminator field and shapes).
   Describe it as a `oneOf` of the completed-login object and the MFA-required
   object. A minimal acceptable form references the two branch schemas; an exact,
   discriminator-aware schema is preferred. Whatever shape is chosen **must pass
   the `validateEveryToJSON` conformance test in M4** against real `LoginResponse`
   values.

4. **`ToParamSchema PasskeyId`** (capture in `passkeyDelete`). `PasskeyId =
   KindID "passkey"`; its wire form is a string. Provide:

    ```haskell
    instance ToParamSchema PasskeyId where
      toParamSchema _ = mempty & type_ ?~ OpenApiString
    ```

   (Confirm `type_` lens and `OpenApiString` constructor names against
   `Data.OpenApi`.)

5. **`HasOpenApi` for the custom combinators.** None exist in the library.

   - `Authenticated = AuthProtect "shomei-jwt"`. Add a bearer-JWT security
     scheme to every operation of the sub-API and register it in components:

    ```haskell
    instance HasOpenApi sub => HasOpenApi (AuthProtect "shomei-jwt" :> sub) where
      toOpenApi _ =
        toOpenApi (Proxy @sub)
          & components . securitySchemes . at "bearerAuth"
              ?~ SecurityScheme (SecuritySchemeHttp (HttpSchemeBearer (Just "jwt")))
                                (Just "JWT access token")
          & allOperations . security
              %~ (SecurityRequirement (IOHM.singleton "bearerAuth" []) :)
    ```

     (Names to confirm against `Data.OpenApi`: `securitySchemes`, `at`,
     `SecurityScheme`, `SecuritySchemeHttp`, `HttpSchemeBearer`, `allOperations`,
     `security`, `SecurityRequirement`. `IOHM` is
     `Data.HashMap.Strict.InsOrd` from `insert-ordered-containers`; check whether
     `Data.OpenApi` re-exports a helper so the dependency is unnecessary.)

   - `RequireRole` and `RequireScope` are phantom — transparent to the schema:

    ```haskell
    instance HasOpenApi sub => HasOpenApi (RequireRole role :> sub) where
      toOpenApi _ = toOpenApi (Proxy @sub)
    instance HasOpenApi sub => HasOpenApi (RequireScope scope :> sub) where
      toOpenApi _ = toOpenApi (Proxy @sub)
    ```

   (`RequireRole`/`RequireScope` appear in `AppAPI`, not in `ShomeiAPI` itself; if
   only `ShomeiAPI` is generated, these two are optional. Include them so the
   embedding example can also be described later.)

6. **`shomeiOpenApi :: OpenApi`** — assemble and enrich, mirroring
   `app/GenOpenApi.hs` from the library:

    ```haskell
    shomeiOpenApi :: OpenApi
    shomeiOpenApi =
      toOpenApi (Proxy @(NamedRoutes ShomeiAPI))
        & info . title       .~ "Shōmei Authentication API"
        & info . version     .~ "<version>"      -- pull from shomei-servant.cabal
        & info . description ?~ "Authentication, session, passkey, and token API."
        & servers            .~ [Server "http://localhost:8080" Nothing mempty]
    ```

   Optionally add `applyTags` and a `withOperationId` pass (copy the
   `withOperationIds` helper from the library's `app/GenOpenApi.hs`) so generated
   clients get stable method names. Operation IDs materially improve generated
   client ergonomics — include them.

Verification: add a temporary `main`-less check or use `cabal repl shomei-servant`
and force the value:

    ```bash
    cabal repl shomei-servant
    ghci> :set -XTypeApplications
    ghci> import Shomei.Servant.OpenApi
    ghci> import Data.Aeson (encode)
    ghci> Data.ByteString.Lazy.Char8.putStrLn (encode shomeiOpenApi)
    ```

Acceptance: the module compiles and `encode shomeiOpenApi` prints a JSON document
beginning `{"openapi":"3.1.0",...}`. Commit M2.

### Milestone M3 — Generator executable and committed spec

Scope: a CLI that writes the schema to stdout, and the committed artifact.

1. Add an executable stanza to `shomei-servant/shomei-servant.cabal`:

    ```cabal
    executable shomei-openapi
      import:           <shared-warnings-import-if-any>
      main-is:          Main.hs
      hs-source-dirs:   app/openapi
      build-depends:    base
                      , shomei-servant
                      , aeson
                      , aeson-pretty
                      , bytestring
      default-language: GHC2021
    ```

   (Match the `default-language`, `ghc-options`, and any `import:` common stanza
   already used by other executables in the repo — inspect `shomei-server.cabal`
   for the project's conventions.)

2. Create `shomei-servant/app/openapi/Main.hs`:

    ```haskell
    module Main (main) where

    import qualified Data.ByteString.Lazy.Char8 as BL
    import           Data.Aeson.Encode.Pretty (encodePretty)
    import           Shomei.Servant.OpenApi (shomeiOpenApi)

    main :: IO ()
    main = BL.putStrLn (encodePretty shomeiOpenApi)
    ```

   (Pretty output keeps the committed file diff-friendly. If `aeson-pretty` is not
   in the package set, use `Data.Aeson.encode` instead and drop the dep.)

3. Generate and commit the artifact:

    ```bash
    mkdir -p docs/api
    cabal run shomei-openapi > docs/api/openapi.json
    ```

Acceptance:

```bash
# version is 3.1.0
grep -m1 '"openapi"' docs/api/openapi.json        # => "openapi": "3.1.0",
# all top-level route prefixes appear
grep -c '"/auth/' docs/api/openapi.json           # => > 0
grep -q '"/health"' docs/api/openapi.json && echo health-ok
grep -q '"/ready"'  docs/api/openapi.json && echo ready-ok
grep -q '"/.well-known/jwks.json"' docs/api/openapi.json && echo jwks-ok
grep -q 'bearerAuth' docs/api/openapi.json && echo security-ok
```

Commit M3 (executable, `Main.hs`, and `docs/api/openapi.json`).

### Milestone M4 — Conformance test and external lint

Scope: guard the spec against drift and validate it with an authoritative tool.

1. Add a test to `shomei-servant`'s existing test suite (inspect
   `shomei-servant/test` and `shomei-servant.cabal`'s `test-suite` stanza for the
   framework in use — likely `hspec`/`tasty`). Two checks:

   - **Round-trip conformance** using
     `Servant.OpenApi.Test.validateEveryToJSON`. This requires `Arbitrary`
     instances for the DTOs (use `generic-arbitrary` or `QuickCheck` generics;
     `generic-lens` is already a test dep elsewhere). Example shape:

    ```haskell
    spec :: Spec
    spec = describe "OpenAPI 3.1 schema" $ do
      it "every ToJSON value validates against the generated schema" $
        validateEveryToJSON (Proxy @(NamedRoutes ShomeiAPI))
    ```

   - **Smoke assertions** on `shomeiOpenApi`: the serialized `openapi` field
     equals `"3.1.0"`, and the number of paths equals the number of distinct route
     prefixes (currently ~24 paths). Use the `Data.OpenApi` lenses to count
     `_openApiPaths`.

   Add the test-suite `build-depends`: `servant-openapi`, `openapi-hs`,
   `QuickCheck`, and whichever `Arbitrary`-deriving helper you choose.

2. Lint the committed file with an external validator. Prefer the tool the
   library itself documents (`vacuum`), e.g.:

    ```bash
    nix run nixpkgs#vacuum-go -- lint -d docs/api/openapi.json
    ```

   or, if `nix`/`vacuum` is unavailable:

    ```bash
    npx @redocly/cli lint docs/api/openapi.json
    ```

Acceptance:

```bash
cabal test shomei-servant
```

passes, and the external linter reports no errors (warnings about missing
descriptions are acceptable; record them in Surprises & Discoveries). Commit M4.

### Milestone M5 — Client-generation proof and documentation

Scope: make the deliverable usable by a non-Haskell developer, and prove it.

1. Write `docs/user/openapi-client-generation.md` (place it alongside the other
   guides moved under `docs/user/` — see commit `af09ace`). It must cover:
   - where the schema lives (`docs/api/openapi.json`) and how to regenerate it
     (`cabal run shomei-openapi > docs/api/openapi.json`);
   - that it is OpenAPI 3.1 (note that some generators still lag on 3.1 — call out
     using a recent `openapi-generator-cli`);
   - copy-paste codegen commands for at least TypeScript, Python, and Go.

2. Prove codegen end-to-end with one language:

    ```bash
    npx @openapitools/openapi-generator-cli generate \
      -i docs/api/openapi.json -g typescript-fetch -o /tmp/shomei-ts-client
    ```

   Record the result (success / any generator 3.1 caveats) in Outcomes &
   Retrospective. Do **not** commit the generated client.

3. (Optional) Serve the spec at runtime. In
   `shomei-server/src/Shomei/Server/Boot.hs`, add a WAI route (or a small
   middleware) that responds to `GET /openapi.json` with the bytes of
   `shomeiOpenApi` (`encode shomeiOpenApi`). Keep it *outside* `ShomeiAPI` so the
   embeddable contract is unchanged, or, if added to the Servant API, regenerate
   `docs/api/openapi.json` so it includes the new route. Mark this optional; the
   committed file + CLI already satisfy the purpose.

Acceptance: the docs exist, the codegen command produces a client without errors,
and (if M5.3 done) `curl localhost:8080/openapi.json | head -c 40` shows the
`{"openapi":"3.1.0"` prefix. Commit M5 (docs and any endpoint code).


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei`.

```bash
# --- M1 ---
git -C /Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs rev-parse HEAD
git ls-remote https://github.com/shinzui/servant-openapi.git | head      # confirm pushed
# edit cabal.project (append EP-27 block) and shomei-servant.cabal (build-depends)
cabal build shomei-servant
# expect: Resolving dependencies... lists servant-openapi, openapi-hs; build OK
git add cabal.project shomei-servant/shomei-servant.cabal
git commit   # see commit-message template below

# --- M2 ---
# create shomei-servant/src/Shomei/Servant/OpenApi.hs (see Plan of Work M2)
# add Shomei.Servant.OpenApi to exposed-modules in shomei-servant.cabal
cabal build shomei-servant
cabal repl shomei-servant   # force `encode shomeiOpenApi`, expect {"openapi":"3.1.0",...}
git add -A && git commit

# --- M3 ---
# add executable stanza + app/openapi/Main.hs
mkdir -p docs/api
cabal run shomei-openapi > docs/api/openapi.json
grep -m1 '"openapi"' docs/api/openapi.json     # => "openapi": "3.1.0",
git add -A && git commit

# --- M4 ---
# add conformance + smoke test to shomei-servant/test
cabal test shomei-servant
npx @redocly/cli lint docs/api/openapi.json     # or vacuum
git add -A && git commit

# --- M5 ---
# write docs/user/openapi-client-generation.md ; prove codegen
npx @openapitools/openapi-generator-cli generate \
  -i docs/api/openapi.json -g typescript-fetch -o /tmp/shomei-ts-client
git add -A && git commit
```

Commit-message template (every commit on this plan):

```text
feat(servant): generate OpenAPI 3.1 schema from Servant types

<what this commit did>

ExecPlan: docs/plans/27-generate-openapi-3-1-schema-from-servant-types.md
Intention: intention_01kvyaehf5etmb554vhvmgp27w
```


## Validation and Acceptance

The change is effective (not merely compiling) when:

1. **Generation works and is reproducible.**
   `cabal run shomei-openapi > docs/api/openapi.json` yields a file whose first
   `"openapi"` field is exactly `"3.1.0"`. Running it twice yields byte-identical
   output (the generator is deterministic).

2. **Coverage.** `docs/api/openapi.json` contains a `paths` entry for every route
   in `ShomeiAPI`: the `/auth/*` family, `/admin/audit/events`,
   `/.well-known/jwks.json`, `/health`, `/ready`. Authenticated routes (e.g.
   `/auth/me`, `/auth/logout`, `/auth/passkeys`, `/admin/audit/events`) carry a
   `security` requirement referencing `bearerAuth`, and `components.securitySchemes.bearerAuth`
   describes an HTTP bearer (JWT) scheme.

3. **Conformance.** `cabal test shomei-servant` passes, including
   `validateEveryToJSON (Proxy @(NamedRoutes ShomeiAPI))` — i.e. every DTO's
   actual JSON encoding validates against its generated schema (this is what
   catches schema/JSON drift, including the `LoginResponse` `oneOf` and the
   `Value` fields).

4. **External validity.** An OpenAPI validator (`vacuum` or `@redocly/cli lint`)
   reports no errors against `docs/api/openapi.json`.

5. **The actual goal — clients in other languages.**
   `npx @openapitools/openapi-generator-cli generate -i docs/api/openapi.json -g
   typescript-fetch -o /tmp/shomei-ts-client` completes and emits a client with
   typed operations for the Shōmei routes.


## Idempotence and Recovery

- **`cabal.project` edits** are append-only blocks; re-running the edit must not
  duplicate the EP-27 block (check before appending). If the solver fails after
  the pins, the recovery is to add a targeted `allow-newer:` in the EP-27 block,
  or fall back to the local `packages:` path (record in Surprises). Reverting the
  block fully restores the prior build.
- **Schema regeneration** is safe to repeat: `cabal run shomei-openapi >
  docs/api/openapi.json` overwrites the file deterministically. If output differs
  from the committed file, that is a *signal* (the API or a DTO changed) — review
  the diff, do not blindly commit. The M4 test will fail if a DTO's JSON no longer
  matches its schema.
- **No destructive operations** are involved; all new files are additive. To roll
  back the whole feature, revert the plan's commits — nothing in existing modules
  changes except `cabal.project`, the two `.cabal` files, and (optionally, M5)
  `Boot.hs`.
- If `validateEveryToJSON` fails for a specific DTO, the fix is local to that
  DTO's `ToSchema` (most likely `LoginResponse` or a `Value` field) — adjust the
  instance and rerun `cabal test shomei-servant`.


## Interfaces and Dependencies

**External packages (added):**

- `servant-openapi` (4.0.0, git-pinned `shinzui/servant-openapi`) — provides
  `Servant.OpenApi.toOpenApi :: HasOpenApi api => Proxy api -> OpenApi`,
  `Servant.OpenApi.subOperations`, and `Servant.OpenApi.Test.validateEveryToJSON`.
  Chosen because it derives an OpenAPI **3.1** document directly from Servant
  types and supports `NamedRoutes`.
- `openapi-hs` (4.0, git-pinned `shinzui/openapi-hs` @
  `89e9ed07e0dd3e1eaa9b3efea28b3c722f8c60c8`) — provides `Data.OpenApi`
  (`OpenApi`, `Schema`, `NamedSchema`, `ToSchema`, `ToParamSchema`,
  `SecurityScheme`, `SecuritySchemeType`, `HttpSchemeType`, `SecurityRequirement`,
  and the lenses `info`, `servers`, `paths`, `components`, `securitySchemes`,
  `allOperations`, `security`, `type_`).
- `lens` — for `&`, `.~`, `?~`, `%~` spec enrichment.
- `aeson-pretty` — pretty JSON for the committed artifact (executable + test
  only; optional).

**New module — `Shomei.Servant.OpenApi`** (file
`shomei-servant/src/Shomei/Servant/OpenApi.hs`). Public interface at end of M2:

```haskell
-- | The complete, enriched OpenAPI 3.1 document for the Shōmei auth service,
--   derived from 'ShomeiAPI'.
shomeiOpenApi :: Data.OpenApi.OpenApi
```

Internally it also defines (orphan, `-Wno-orphans`):
`ToSchema` for every DTO, `ToSchema Value`, `ToSchema LoginResponse`,
`ToParamSchema PasskeyId`, and `HasOpenApi` for `AuthProtect "shomei-jwt" :> sub`,
`RequireRole role :> sub`, `RequireScope scope :> sub`.

**New executable — `shomei-openapi`** (file
`shomei-servant/app/openapi/Main.hs`, stanza in `shomei-servant.cabal`).
Interface: `main :: IO ()` writes `encodePretty shomeiOpenApi` to stdout.

**New test** — in `shomei-servant/test`, asserting `validateEveryToJSON
(Proxy @(NamedRoutes ShomeiAPI))` and that the serialized `openapi` field is
`"3.1.0"`. Requires `Arbitrary` instances for the DTOs.

**New artifact** — `docs/api/openapi.json` (committed).

**Existing code consumed (unchanged):**

- `Shomei.Servant.API` (`ShomeiAPI`, `AppAPI`) — the source of truth for routes.
- `Shomei.Servant.DTO` — every request/response type, including the custom
  `LoginResponse` JSON instances that the hand-written `ToSchema` must mirror.
- `Shomei.Servant.Auth` (`Authenticated = AuthProtect "shomei-jwt"`) and
  `Shomei.Servant.Authz` (`RequireRole`, `RequireScope`) — the combinators needing
  `HasOpenApi` instances.
- `Shomei.Id` (`PasskeyId = KindID "passkey"`) — the only non-primitive capture.

**Optional (M5) touch point:** `shomei-server/src/Shomei/Server/Boot.hs` — add a
`GET /openapi.json` route serving `encode shomeiOpenApi`.
