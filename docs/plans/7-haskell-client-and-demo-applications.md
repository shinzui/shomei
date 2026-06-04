---
id: 7
slug: haskell-client-and-demo-applications
title: "Haskell client and demo applications"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# Haskell client and demo applications

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei (証明, "proof / verification") is a Haskell authentication toolkit. Earlier plans built
its layers: a transport-agnostic core (`shomei-core`), a JWT/JWKS adapter (`shomei-jwt`), a
PostgreSQL adapter (`shomei-postgres`), Servant API types and route-protection combinators
(`shomei-servant`), and a standalone HTTP service (`shomei-server`). This plan — the last in
the initiative — delivers three things that together *prove the toolkit actually works the two
ways the spec promises*:

1. **`packages/shomei-client`** — a Haskell client library. It does **not** hand-write HTTP
   requests; it *derives* its request functions from the exact same `ShomeiAPI` Servant type
   the server serves, using the `servant-client` library. ("Derive a client" here means:
   given the API description as a Haskell type, `servant-client` generates Haskell functions
   that perform the matching HTTP calls and decode the JSON responses, so the client and
   server can never disagree about the wire format.) After this, a Haskell program can call
   `signup`, `login`, `refresh`, `logout`, `me`, and `session` against a running
   `shomei-server` and get back typed values.

2. **`examples/embedded-servant-app`** — a single runnable program that proves the **embedded
   deployment model**. "Embedded" means: instead of running Shōmei as its own service, an
   existing application *mounts Shōmei's auth routes inside its own Servant API* and reuses
   Shōmei's route-protection combinator to guard its *own* business routes. This demo mounts
   the Shōmei auth routes under `/auth/*` and adds an app-owned, protected `/projects` route.
   You can sign up and log in through the mounted `/auth/*` routes, then call `/projects` with
   the returned token (HTTP 200) or without it (HTTP 401).

3. **`examples/microservice-auth-stack`** — a two-process demo that proves the **microservice
   deployment model with local verification**. "Microservice mode" means Shōmei runs as a
   standalone auth service that issues JWTs, and *other* services verify those JWTs *locally*
   — without calling the auth service on every request. The downstream service
   (`example-project-service`) fetches the auth service's **JWKS** once at startup ("JWKS" =
   JSON Web Key Set, a small JSON document published at `/.well-known/jwks.json` that contains
   the *public* halves of the signing keys; anyone with it can verify a token's signature but
   cannot mint new tokens) and then verifies every incoming Bearer token offline using
   `shomei-jwt`'s `verifyToken`. You log in at the auth service, take the access token to the
   downstream service's `/projects` route, and get HTTP 200 — proven to have happened with
   **zero network calls back to the auth service** — while a tampered or expired token yields
   HTTP 401.

What someone gains after this plan: a working, runnable demonstration of both Shōmei
deployment models, plus a reusable typed Haskell client. The whole vertical slice from the
MasterPlan is then end-to-end demonstrable.

This plan **hard-depends on EP-6** (`docs/plans/6-standalone-authentication-server.md`): the
microservice demo and the client's live-server tests target a *running* `shomei-server`. It
**soft-depends on EP-5** (`docs/plans/5-servant-integration-and-route-protection.md`): the
client derivation and the embedded demo reuse the `ShomeiAPI` type and DTOs from
`shomei-servant`. Both prior plans are checked into the repository under `docs/plans/`; this
plan reproduces the key items it consumes from them so it remains self-contained.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: Confirm `shomei-server` is restructured as `library + thin executable` so the
      embedded demo can import its assembly; if EP-6 shipped exe-only, refactor it (see
      Decision Log and Context).
- [ ] M1a: Create `packages/shomei-client/shomei-client.cabal` and `Shomei.Client` deriving
      client functions from `ShomeiAPI` via `servant-client`.
- [ ] M1b: Implement the generalized-auth client approach for the `Authorization: Bearer`
      header on `Authenticated` routes (`AuthClientData` + `mkAuthenticatedRequest`).
- [ ] M1c: Add `mkClientEnv`/`shomeiClientEnv` helper from a base URL.
- [ ] M1d: `shomei-client` test round-trips `signup` → `login` → `me` → `refresh` against a
      live server (ephemeral DB + warp, or the dev server); assertions on decoded responses.
- [ ] M2a: Create `examples/embedded-servant-app/embedded-servant-app.cabal`; add to
      `cabal.project`.
- [ ] M2b: Define `AppAPI` mounting `NamedRoutes ShomeiAPI` under `/auth` plus a protected
      `/projects` route; reuse `shomei-server`'s assembly (`Env`, `runAppIO`, auth `Context`).
- [ ] M2c: Embedded demo boots against dev PostgreSQL; `/projects` returns 401 without token,
      200 with token (automated test or documented curl runbook).
- [ ] M3a: Create `examples/microservice-auth-stack/microservice-auth-stack.cabal` with the
      `example-project-service` executable; add to `cabal.project`.
- [ ] M3b: `example-project-service` fetches JWKS at startup, caches with a TTL, verifies
      Bearer tokens locally via `shomei-jwt`'s `verifyToken`; never calls the auth service per
      request.
- [ ] M3c: Two-service runbook (process-compose or shell) passes: login at auth service →
      call downstream `/projects` → 200; tampered token → 401.
- [ ] M4: Widen `mori.dhall` (`shomei-client` depends on `shomei-servant`; register the two
      example packages) and confirm `cabal build all` green in `nix develop`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `shomei-client` depends on `shomei-servant`, not only `shomei-core` as listed in
  `mori.dhall`.
  Rationale: The client derives its request functions from the single source-of-truth
  `ShomeiAPI` type (defined in `shomei-servant`) using `servant-client`. Depending only on
  `shomei-core` would force re-declaring the API and DTOs, inviting client/server drift. This
  widening was anticipated in the MasterPlan (Integration Point IP-6); `mori.dhall`'s
  dependency list for `shomei-client` must be updated in M4.
  Date: 2026-06-03

- Decision: Attach the `Authorization: Bearer <token>` header on the `Authenticated` routes
  using `servant-client`'s generalized-authentication client support, i.e. a
  `type instance AuthClientData (AuthProtect "shomei-jwt") = Token` plus
  `mkAuthenticatedRequest`, rather than a raw request-modifier or remodeling the header.
  Rationale: The server's `Authenticated` combinator is `AuthProtect "shomei-jwt"`. On the
  client side `servant-client-core` resolves `AuthProtect sym` to an `AuthenticatedRequest`
  whose data type is whatever `AuthClientData (AuthProtect sym)` is, and whose request-builder
  function applies the credential to the outgoing request. Modeling the credential as a
  `Token` newtype and using the canonical `mkAuthenticatedRequest` keeps the client honest to
  the same API type and avoids brittle manual header plumbing. A manual `Bearer` modifier is
  documented as the fallback in case the `AuthClientData` instance must be co-located awkwardly.
  Date: 2026-06-03

- Decision: Restructure `shomei-server` as a library component (`shomei-server` library) plus
  a thin executable (`shomei-server` exe) so the embedded demo can `import` the assembly
  (`Env`, `runAppIO`, the auth `Context`, `mkApp`/`application`) instead of copying it.
  Rationale: The embedded demo must reuse the exact adapter assembly (postgres pool, signing
  keys, the auth `Context` that the `Authenticated` combinator needs) to faithfully prove the
  embedded model. Duplicating the assembly would let it drift from the real server. If EP-6
  shipped `shomei-server` as executable-only, this plan refactors it to library+exe (a small,
  mechanical change) and records it here. This is a coordination point with EP-6.
  Date: 2026-06-03

- Decision: The downstream `example-project-service` verifies JWTs **locally** using a
  `JWKSet` it fetches once at startup and refetches on a cache TTL (default 15 minutes, within
  the spec's 5–30 minute range); it never calls the auth service per request.
  Rationale: This is the entire point of the microservice model with asymmetric (ES256)
  signing — downstream services scale independently of the auth service and do not add a
  per-request round trip. A TTL bounds how long a rotated-out key stays trusted and how long a
  newly-rotated key takes to become verifiable downstream; 15 minutes balances rotation
  latency against refetch traffic.
  Date: 2026-06-03

- Decision: Register the two example packages (`examples/embedded-servant-app`,
  `examples/microservice-auth-stack`) in the root `cabal.project` `packages:` list, and in
  `mori.dhall` as `Application` packages.
  Rationale: They must build with `cabal build all` and be discoverable by project tooling.
  Examples are applications (deployable demos), not libraries.
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section describes the repository as it is when this plan begins, assuming you know
nothing about it. Read it fully before editing.

**The repository.** Shōmei is a multi-package Haskell workspace (a "Cabal workspace" — several
Haskell packages built together, listed in a single `cabal.project` file at the repository
root, `/Users/shinzui/Keikaku/bokuno/shomei/cabal.project`). The build uses GHC 9.12.4 inside a
Nix development shell entered with `nix develop` from the repository root. The house language
edition is **GHC2024** (a bundle of default language extensions), with strict record fields and
a custom prelude module `Shomei.Prelude` (exposed by `shomei-core`) imported in place of the
standard `Prelude`. Two shared Cabal "common stanzas" — reusable blocks named `common warnings`
and `common shared` declared once in each `.cabal` file or imported from the project — carry the
shared GHC options and base dependencies; every package's components write
`import: warnings, shared` to inherit them. Qualified imports are written *postpositive*
(`import Data.Text qualified as Text`, the modern syntax), and external module imports use
`PackageImports` where the house style requires it.

**What earlier plans already provide (you consume these; key items are reproduced here so this
plan is self-contained).**

From EP-5, package `packages/shomei-servant` (a Haskell library):

- `ShomeiAPI` — the API described as a Haskell *record of routes* using Servant's
  **NamedRoutes** feature. "NamedRoutes" means the API is a Haskell record type whose fields
  are individual endpoints, parameterised over a "mode"; in *server* mode the fields are
  handlers, and in *client* mode (what we use here) the fields are client functions. Sketch of
  the shape EP-5 defines (reproduced for orientation; use the real definition from
  `packages/shomei-servant/src/Shomei/Servant/API.hs`):

    ```haskell
    -- In shomei-servant (EP-5). Reproduced here for orientation only.
    data ShomeiAPI mode = ShomeiAPI
      { signup  :: mode :- "auth" :> "signup"  :> ReqBody '[JSON] SignupRequest  :> Post '[JSON] SignupResponse
      , login   :: mode :- "auth" :> "login"   :> ReqBody '[JSON] LoginRequest   :> Post '[JSON] LoginResponse
      , refresh :: mode :- "auth" :> "refresh" :> ReqBody '[JSON] RefreshRequest :> Post '[JSON] TokenPairResponse
      , logout  :: mode :- "auth" :> "logout"  :> Authenticated :> Post '[JSON] NoContent
      , me      :: mode :- "auth" :> "me"      :> Authenticated :> Get  '[JSON] UserResponse
      , session :: mode :- "auth" :> "session" :> Authenticated :> Get  '[JSON] SessionResponse
      , health  :: mode :- "health"            :> Get '[JSON] HealthResponse
      }
      deriving stock Generic
    ```

  The DTOs ("Data Transfer Objects" — plain records with `ToJSON`/`FromJSON` instances that
  define the JSON request and response bodies) are `SignupRequest`/`SignupResponse`,
  `LoginRequest`/`LoginResponse`, `RefreshRequest`, `TokenPairResponse`, `UserResponse`,
  `SessionResponse`, and `HealthResponse`. `LoginResponse`/`TokenPairResponse` carry an
  *access token* (a signed JWT string) and a *refresh token* (an opaque string). The principal
  type `AuthUser` is the value the `Authenticated` combinator hands a server handler after a
  successful token check.

- `Authenticated` — a Servant route combinator defined as `type Authenticated = AuthProtect
  "shomei-jwt"`. "AuthProtect sym" is Servant's built-in hook for custom authentication: on
  the *server* it runs an `AuthHandler` that reads the request, validates the Bearer token (or
  HttpOnly cookie), and yields an `AuthUser`; on the *client* it requires you to supply the
  credential. EP-5 also defines `RequireRole` and `RequireScope`, combinators that further
  restrict a route to principals holding a named role or scope (used optionally by the
  embedded demo's `/projects`).

- An example `AppAPI` shape (EP-5) showing how a host app combines its own routes with the
  mounted Shōmei routes; the embedded demo elaborates this into a runnable program.

From EP-6, package `packages/shomei-server`:

- The running standalone service exposing `POST /auth/signup`, `/auth/login`, `/auth/refresh`,
  `/auth/logout`, `GET /auth/me`, `/auth/session`, `GET /.well-known/jwks.json`, and
  `GET /health`.
- An assembly layer: an environment record `Env` (holding the postgres connection pool, the
  loaded `ShomeiConfig`, the signing keys, etc.), an effect runner `runAppIO :: Env ->
  AppEffects a -> IO a` (`AppEffects` is the fixed `effectful` effect stack the workflows run
  in), and `serveWithContext` wiring that supplies the Servant `Context` carrying the
  `AuthHandler` the `Authenticated` combinator needs. EP-6 also handles env-var configuration,
  database migration, and signing-key bootstrap at startup.
- **Coordination point:** the embedded demo imports this assembly. If EP-6 exposed it only
  from an executable's `Main`, M0 of this plan refactors `shomei-server` into a library
  component (exposing the assembly modules) plus a thin executable. See the Decision Log.

From EP-4, package `packages/shomei-jwt`:

- `verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)` — given
  the public **JWKS** as a `JWKSet` (the in-memory parse of the JWKS document), the runtime
  config (issuer/audience/algorithm), and a raw JWT string, it validates the signature and
  claims **offline** and returns the decoded `AuthClaims` or a `TokenError`. The downstream
  service uses exactly this; it makes **no** network call to the auth service per request.
- The JWKS document is the JSON at `GET /.well-known/jwks.json`. `JWKSet` is `jose`'s type for
  a parsed set of JWKs; the downstream service fetches the document with `http-client`, decodes
  it with `aeson` into a `JWKSet`, and passes it to `verifyToken`.

From EP-3, package `packages/shomei-migrations` (test-support sublibrary):

- `withShomeiMigratedDatabase` — a bracket-style helper that spins up an *ephemeral*
  PostgreSQL instance ("ephemeral" = a throwaway database created for the duration of a test
  and torn down after), runs the schema migrations, and hands your callback a connection
  string. Any DB-backed test or demo here can reuse it.

**Where new code goes.** Three new directories under the repository root:

- `/Users/shinzui/Keikaku/bokuno/shomei/packages/shomei-client/` — the client library.
- `/Users/shinzui/Keikaku/bokuno/shomei/examples/embedded-servant-app/` — the embedded demo.
- `/Users/shinzui/Keikaku/bokuno/shomei/examples/microservice-auth-stack/` — the two-service
  demo.

Each gets its own `.cabal` file and is added to the root `cabal.project` `packages:` list.

**Key terms used throughout this plan.**

- *servant-client*: the Haskell library that turns a Servant API type into Haskell functions
  that perform the corresponding HTTP requests and decode responses. Core entry point: `client
  (Proxy :: Proxy api)`. For a NamedRoutes API, `client` returns a *record* whose fields are
  the per-endpoint client functions.
- *ClientEnv*: `servant-client`'s runtime handle bundling an HTTP `Manager` (a connection pool
  from `http-client`) and a `BaseUrl` (scheme/host/port/path). Client functions run in the
  `ClientM` monad and are executed with `runClientM action env :: IO (Either ClientError a)`.
- *JWKS / JWKSet*: defined above — the public-key set used for offline token verification.
- *downstream service*: a service that *consumes* tokens issued by the auth service to protect
  its own routes. Here, `example-project-service`. It is downstream of the auth service in the
  trust chain but is an independent process.
- *embedded vs microservice*: *embedded* = Shōmei's auth routes and guards live inside one
  application process (the `embedded-servant-app`). *microservice* = the auth service is a
  separate process, and other services verify its tokens locally using the JWKS (the
  `microservice-auth-stack`).


## Plan of Work

The work is four milestones. M0 is a small prerequisite/coordination step; M1, M2, M3 are the
three deliverables; M4 finalizes project metadata. Each milestone is independently verifiable.

**Milestone 0 — Ensure `shomei-server` exposes its assembly as a library.** Before the
embedded demo can reuse the real assembly, `shomei-server` must expose `Env`, `runAppIO`, the
auth `Context`, and the WAI `Application` builder from a *library* component, not buried in an
executable's `Main`. Inspect `packages/shomei-server/shomei-server.cabal`. If it already has a
`library` stanza exposing modules such as `Shomei.Server.Env`, `Shomei.Server.App`
(`mkApp`/`application`), and `Shomei.Server.Run` (`runAppIO`), nothing to do — note it in
Progress and proceed. If `shomei-server` is executable-only, refactor: move the assembly
modules from the executable's `other-modules`/`Main` into a new `library` stanza
(`exposed-modules:` the assembly modules), and reduce the executable to a thin `Main` that
imports the library and calls its `main`/`runServer`. At the end of M0, `cabal build
shomei-server` is green and `cabal repl shomei-server:lib:shomei-server` can `import
Shomei.Server.App`. Acceptance: `cabal build shomei-server` succeeds and the library's
`exposed-modules` includes the assembly modules the demo needs.

**Milestone 1 — `shomei-client` builds and round-trips against a live server.** Create
`packages/shomei-client` with a `.cabal` depending on `shomei-core`, `shomei-servant`,
`servant-client (>=0.20)`, `servant-client-core`, `http-client`, `http-client-tls`, `text`,
and `time`. Write `Shomei.Client` (file
`packages/shomei-client/src/Shomei/Client.hs`). It derives the record of client functions from
`ShomeiAPI` via `servant-client`, defines the generalized-auth client data instance so the
`Authenticated` routes accept a Bearer token, and exposes ergonomic IO wrappers. Add a test
(`packages/shomei-client/test/Main.hs` plus a `test-suite` stanza) that, against a live
`shomei-server` (started over an ephemeral DB with `withShomeiMigratedDatabase` + warp, or
pointed at the dev server via an env var), runs `signup` → `login` → `me` → `refresh` and
asserts on the decoded responses. At the end of M1, `cabal test shomei-client` passes (or the
documented manual run does). Acceptance: the test prints a passing round-trip; an HTTP login
transcript (below) is reproducible.

**Milestone 2 — `examples/embedded-servant-app` boots and guards `/projects`.** Create the
package with an executable `embedded-servant-app`. Define `AppAPI` combining the mounted
Shōmei routes under `/auth` with an app-owned, `Authenticated`-guarded `/projects` route
returning a trivial `[Project]`. Reuse `shomei-server`'s library (`Env`, `runAppIO`, the auth
`Context`) so the auth routes and the guard share the real adapter assembly. Boot it against
the dev PostgreSQL. At the end of M2, you can sign up and log in through `/auth/*`, then call
`/projects` and observe 401 without a token and 200 with one. Acceptance: the documented curl
runbook (and/or an automated warp test) shows the 401-then-200 behavior.

**Milestone 3 — `examples/microservice-auth-stack` verifies tokens locally.** Create the
package with an executable `example-project-service`: a separate downstream Servant service
that does **not** depend on `shomei-postgres` and never calls the auth service per request. On
startup it fetches `GET <auth-service>/.well-known/jwks.json`, parses it into a `JWKSet`,
caches it with a TTL (default 15 min), and protects its own `/projects` route by verifying the
Bearer JWT locally with `verifyToken jwks config`. Provide a runbook (and optionally a
process-compose file) that (1) starts `shomei-server`, (2) starts `example-project-service`
pointed at the auth service's JWKS URL, (3) logs in to get a token, (4) calls the downstream
`/projects` with that token → 200 (verified locally, no auth-service call), (5) shows a
tampered token → 401. At the end of M3, the two-service runbook passes. Acceptance: the
downstream `/projects` returns 200 for a valid token and 401 for a tampered one, demonstrably
without a per-request call to the auth service.

**Milestone 4 — Project metadata and workspace build.** Widen `mori.dhall` so `shomei-client`
declares a dependency on `shomei-servant` and the two example packages are registered. Confirm
the whole workspace builds. Acceptance: `mori show --full` reflects the new dependency and
packages, and `cabal build all` is green inside `nix develop`.


## Concrete Steps

Run all commands from the repository root
`/Users/shinzui/Keikaku/bokuno/shomei` inside the Nix shell unless noted. Enter the shell once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop
```

### Step 0 — Verify / restructure `shomei-server` (Milestone 0)

Check whether the assembly is already a library:

```bash
grep -nE "^(library|executable)" packages/shomei-server/shomei-server.cabal
```

If you see a `library` stanza whose `exposed-modules:` lists the assembly modules (for
example `Shomei.Server.Env`, `Shomei.Server.App`, `Shomei.Server.Run`), record "M0: already
library+exe" in Progress and skip to Step 1. If you see only an `executable` stanza, refactor
it. The target shape of `packages/shomei-server/shomei-server.cabal`:

```cabal
library
  import:           warnings, shared
  hs-source-dirs:   src
  exposed-modules:  Shomei.Server.Env
                    Shomei.Server.App
                    Shomei.Server.Run
                    Shomei.Server.Config
  build-depends:    base, shomei-core, shomei-jwt, shomei-postgres, shomei-servant
                  , effectful, warp, wai, servant-server, hasql, hasql-pool, text
  default-language: GHC2024

executable shomei-server
  import:           warnings, shared
  hs-source-dirs:   app
  main-is:          Main.hs
  build-depends:    base, shomei-server
  default-language: GHC2024
```

The thin `packages/shomei-server/app/Main.hs` becomes:

```haskell
module Main (main) where

import Shomei.Server.Run qualified as Server

main :: IO ()
main = Server.main
```

Confirm:

```bash
cabal build shomei-server
```

Expected tail:

```text
Building executable 'shomei-server' for shomei-server-0.1.0.0..
Linking ... shomei-server ...
```

### Step 1 — Create `packages/shomei-client` (Milestone 1)

Create `packages/shomei-client/shomei-client.cabal`:

```cabal
cabal-version:      3.0
name:               shomei-client
version:            0.1.0.0
synopsis:           Haskell client for the standalone Shōmei auth service
build-type:         Simple

common warnings
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates
               -Wincomplete-uni-patterns -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions: OverloadedStrings, OverloadedLabels, DataKinds, TypeFamilies
                      DerivingStrategies, RecordWildCards, NamedFieldPuns
  build-depends:      base, text, time

library
  import:           warnings, shared
  hs-source-dirs:   src
  exposed-modules:  Shomei.Client
  build-depends:    shomei-core
                  , shomei-servant
                  , servant
                  , servant-client      >= 0.20
                  , servant-client-core
                  , http-client
                  , http-client-tls

test-suite shomei-client-test
  import:           warnings, shared
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  build-depends:    shomei-client
                  , shomei-core
                  , shomei-servant
                  , shomei-server
                  , shomei-migrations:test-support
                  , servant-client
                  , http-client
                  , warp
                  , hspec
                  , async
```

Create `packages/shomei-client/src/Shomei/Client.hs`. The essential pieces, in order:

First, derive the record of client functions from the single source-of-truth API. For a
NamedRoutes API, applying `client` to `Proxy @(NamedRoutes ShomeiAPI)` yields a value of type
`ShomeiAPI (AsClientT ClientM)` — a record whose fields are the client functions:

```haskell
{-# LANGUAGE TypeApplications #-}
module Shomei.Client
  ( ShomeiClient
  , shomeiClient
  , mkClientEnv
  , shomeiClientEnv
  , Token (..)
  , signup
  , login
  , refresh
  , logout
  , me
  , session
  ) where

import Shomei.Prelude

import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as TLS
import Servant.API (NamedRoutes)
import Servant.API.Generic (type (:-))
import Servant.Auth.Server ()  -- not used; see note below
import Servant.Client
  ( BaseUrl (..), Scheme (..), ClientEnv, ClientError, ClientM
  , runClientM, mkClientEnv, parseBaseUrl )
import Servant.Client.Generic (AsClientT, genericClient)
import Servant.Client.Core
  ( AuthClientData, AuthenticatedRequest, mkAuthenticatedRequest
  , addHeader )

import Shomei.Servant.API (ShomeiAPI (..))
import Shomei.Servant.DTO
  ( SignupRequest, SignupResponse, LoginRequest, LoginResponse
  , RefreshRequest, TokenPairResponse, UserResponse, SessionResponse )
```

(Use the actual module paths EP-5 chose for `ShomeiAPI` and the DTOs; the imports above name
the symbols, adjust the module names to match `packages/shomei-servant/src/...`.)

The generalized-auth client data instance — this is *the* mechanism that lets the client put a
Bearer token on the `Authenticated` (`AuthProtect "shomei-jwt"`) routes. We model the
credential as a `Token` newtype and tell `servant-client-core` that the client data for our
auth scheme is a `Token`:

```haskell
-- A Bearer access token (the signed JWT string the server returned from /auth/login).
newtype Token = Token { unToken :: Text }
  deriving stock (Eq, Show)

-- Tell servant-client what credential the "shomei-jwt" auth scheme needs on the client side.
type instance AuthClientData (AuthProtect "shomei-jwt") = Token

-- Build an AuthenticatedRequest that attaches "Authorization: Bearer <jwt>" to the request.
bearer :: Token -> AuthenticatedRequest (AuthProtect "shomei-jwt")
bearer tok =
  mkAuthenticatedRequest tok $ \(Token jwt) req ->
    addHeader "Authorization" ("Bearer " <> jwt) req
```

The derived client record and the ergonomic wrappers:

```haskell
type ShomeiClient = ShomeiAPI (AsClientT ClientM)

-- The record of client functions, derived from the API type. Field names match ShomeiAPI.
shomeiClient :: ShomeiClient
shomeiClient = genericClient

-- Run any ClientM action against a ClientEnv.
run :: ClientEnv -> ClientM a -> IO (Either ClientError a)
run env act = runClientM act env

-- Build a ClientEnv from a base URL string, e.g. "http://localhost:8080".
shomeiClientEnv :: String -> IO ClientEnv
shomeiClientEnv url = do
  base <- parseBaseUrl url
  mgr  <- case baseUrlScheme base of
            Https -> HTTP.newManager TLS.tlsManagerSettings
            Http  -> HTTP.newManager HTTP.defaultManagerSettings
  pure (mkClientEnv mgr base)

signup :: ClientEnv -> SignupRequest -> IO (Either ClientError SignupResponse)
signup env body = run env (signup shomeiClient body)   -- field accessor 'signup' of the record

login :: ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)
login env body = run env (login shomeiClient body)

refresh :: ClientEnv -> RefreshRequest -> IO (Either ClientError TokenPairResponse)
refresh env body = run env (refresh shomeiClient body)

-- Authenticated routes take the AuthenticatedRequest built from the Bearer token.
logout :: ClientEnv -> Token -> IO (Either ClientError ())
logout env tok = fmap (fmap (const ())) (run env (logout shomeiClient (bearer tok)))

me :: ClientEnv -> Token -> IO (Either ClientError UserResponse)
me env tok = run env (me shomeiClient (bearer tok))

session :: ClientEnv -> Token -> IO (Either ClientError SessionResponse)
session env tok = run env (session shomeiClient (bearer tok))
```

Note on naming: the wrapper functions share names with the `ShomeiAPI` record fields. Because
the field accessor is applied to `shomeiClient` (`signup shomeiClient`), and the wrapper is the
exported top-level `signup`, qualify or rename if GHC's `DuplicateRecordFields`/ambiguity
rules complain — for example export the wrappers and access fields via the `OverloadedLabels`
or a `let ShomeiAPI{..} = shomeiClient in ...` binding inside each wrapper. The simplest robust
form binds the record once:

```haskell
login env body =
  let ShomeiAPI{login = loginC} = shomeiClient
   in run env (loginC body)
```

Fallback approach (documented, in case the `AuthClientData` instance is inconvenient to place):
instead of `mkAuthenticatedRequest`, set the header with a `servant-client` request modifier on
the `ClientEnv` via `ClientEnv`'s `makeClientRequest`, or run the action under a manager that
injects `Authorization`. The `mkAuthenticatedRequest` route is preferred and listed first
because it keeps the credential typed at the call site.

Create the test `packages/shomei-client/test/Main.hs`. It starts a real `shomei-server` over
an ephemeral migrated database (or targets `SHOMEI_TEST_URL` if set), then round-trips:

```haskell
module Main (main) where

import Shomei.Prelude

import Control.Concurrent.Async qualified as Async
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (lookupEnv)
import Test.Hspec

import Shomei.Client qualified as Client
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Server.App qualified as Server   -- mkApp/application from the EP-6 library
import Shomei.Servant.DTO

main :: IO ()
main = hspec $
  describe "shomei-client round-trip" $
    it "signup -> login -> me -> refresh" $
      withLiveServer $ \env -> do
        Right su <- Client.signup env (SignupRequest "a@example.com" "S3cret-passw0rd!")
        Right li <- Client.login  env (LoginRequest  "a@example.com" "S3cret-passw0rd!")
        let tok = Client.Token (accessToken li)
        Right meR <- Client.me env tok
        userEmail meR `shouldBe` "a@example.com"
        Right tp <- Client.refresh env (RefreshRequest (refreshToken li))
        accessToken tp `shouldSatisfy` (not . nullText)
  where
    nullText = (== "") . id

-- Start a server (or use SHOMEI_TEST_URL) and hand the test a ClientEnv.
withLiveServer :: (Client.ClientEnv -> IO a) -> IO a
withLiveServer k = do
  mUrl <- lookupEnv "SHOMEI_TEST_URL"
  case mUrl of
    Just url -> Client.shomeiClientEnv url >>= k
    Nothing  -> withShomeiMigratedDatabase $ \connStr -> do
      app <- Server.application connStr   -- build the WAI app from the EP-6 assembly
      Warp.testWithApplication (pure app) $ \port -> do
        env <- Client.shomeiClientEnv ("http://localhost:" <> show port)
        k env
```

(Adjust `SignupRequest`/`LoginResponse`/`accessToken`/`refreshToken`/`userEmail` to the actual
DTO field names from EP-5; the shapes above match the DTOs the MasterPlan describes.)

Build and test:

```bash
cabal build shomei-client
cabal test shomei-client
```

Expected:

```text
shomei-client round-trip
  signup -> login -> me -> refresh [✔]

Finished in 0.84 seconds
1 example, 0 failures
```

### Step 2 — Create `examples/embedded-servant-app` (Milestone 2)

Create `examples/embedded-servant-app/embedded-servant-app.cabal`:

```cabal
cabal-version:      3.0
name:               embedded-servant-app
version:            0.1.0.0
synopsis:           Demo: Shōmei auth routes embedded inside a host Servant app
build-type:         Simple

common warnings
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates
               -Wincomplete-uni-patterns -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions: OverloadedStrings, DataKinds, TypeOperators
                      DeriveGeneric, DerivingStrategies, RecordWildCards
  build-depends:      base, text, aeson

executable embedded-servant-app
  import:           warnings, shared
  hs-source-dirs:   app
  main-is:          Main.hs
  other-modules:    Embedded.Api, Embedded.Projects
  build-depends:    shomei-core
                  , shomei-servant
                  , shomei-server          -- the EP-6 library: Env, runAppIO, the auth Context
                  , servant
                  , servant-server
                  , warp
                  , wai
                  , effectful
```

Create `examples/embedded-servant-app/app/Embedded/Api.hs` — the combined API. It mounts the
Shōmei routes under `/auth` and adds the app's own protected route:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
module Embedded.Api (AppAPI, Project (..)) where

import Shomei.Prelude

import Data.Aeson (FromJSON, ToJSON)
import Servant.API
  ( NamedRoutes, Get, JSON, type (:>), type (:<|>) )
import Shomei.Servant.API (ShomeiAPI)
import Shomei.Servant.Auth (Authenticated)   -- the AuthProtect "shomei-jwt" combinator (EP-5)

-- A trivial demo business type the app owns.
data Project = Project { projectId :: Text, projectName :: Text }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- The host application's API:
--   * under /auth: all Shōmei auth routes (signup/login/refresh/logout/me/session)
--   * /projects: an app-owned route, guarded by the same Authenticated combinator.
type AppAPI =
       "auth" :> NamedRoutes ShomeiAPI
  :<|> Authenticated :> "projects" :> Get '[JSON] [Project]
```

(Optionally tighten `/projects` to `Authenticated :> RequireScope "projects:read" :> ...` to
demonstrate scope enforcement; EP-5 provides `RequireScope`/`RequireRole`.)

Create `examples/embedded-servant-app/app/Embedded/Projects.hs` — the `/projects` handler. It
receives the `AuthUser` principal that the `Authenticated` guard produced:

```haskell
module Embedded.Projects (projectsHandler) where

import Shomei.Prelude

import Servant (Handler)
import Shomei.Servant.Auth (AuthUser)   -- principal from the guard (EP-5)
import Embedded.Api (Project (..))

projectsHandler :: AuthUser -> Handler [Project]
projectsHandler _user =
  pure [ Project "proj_demo_1" "Shōmei Demo Project" ]
```

Create `examples/embedded-servant-app/app/Main.hs`. It reuses the EP-6 assembly to build the
auth server pieces, then serves `AppAPI` with the same auth `Context`:

```haskell
module Main (main) where

import Shomei.Prelude

import Network.Wai.Handler.Warp qualified as Warp
import Servant
  ( Application, Proxy (..), Server, serveWithContext, (:<|>) (..) )
import System.Environment (getEnv)

import Shomei.Server.Env qualified as Server   -- Env, loadEnvFromEnviron (EP-6 library)
import Shomei.Server.App qualified as Server   -- authContext, shomeiServer, runAppIO (EP-6)
import Shomei.Servant.API (ShomeiAPI)
import Embedded.Api (AppAPI, Project)
import Embedded.Projects (projectsHandler)

main :: IO ()
main = do
  dbUrl <- getEnv "SHOMEI_DATABASE_URL"
  env   <- Server.loadEnvFromEnviron dbUrl     -- builds pool, loads config + signing keys
  let ctx = Server.authContext env             -- Servant Context carrying the AuthHandler
  Warp.run 8080 (application env ctx)

application :: Server.Env -> _Context -> Application
application env ctx =
  serveWithContext (Proxy @AppAPI) ctx (server env)

-- Mount the real Shōmei handlers under /auth, plus the app's /projects handler.
server :: Server.Env -> Server AppAPI
server env =
       Server.shomeiServer env          -- the EP-6 record of auth handlers (ShomeiAPI mode=Server)
  :<|> projectsHandler                   -- AuthUser -> Handler [Project]
```

(`_Context` stands for the concrete `Context '[AuthHandler Request AuthUser]` type EP-6
exposes; name it exactly as EP-6 does. `Server.shomeiServer`/`Server.authContext`/
`Server.loadEnvFromEnviron` are the assembly entry points the M0 library exposes — match their
real names.)

Add to `cabal.project`:

```cabal
packages:
  packages/shomei-core
  packages/shomei-jwt
  packages/shomei-postgres
  packages/shomei-servant
  packages/shomei-server
  packages/shomei-client
  packages/shomei-migrations
  examples/embedded-servant-app
  examples/microservice-auth-stack
```

(Add only the two `examples/...` lines if the others already exist; keep the existing list
intact.)

Build and boot:

```bash
cabal build embedded-servant-app
export SHOMEI_DATABASE_URL="postgres://localhost/shomei_dev"
cabal run embedded-servant-app
```

Expected boot line:

```text
embedded-servant-app listening on http://localhost:8080
```

### Step 2b — Embedded demo curl walkthrough

In a second terminal (server still running). First, the protected route *without* a token must
be rejected:

```bash
curl -i http://localhost:8080/projects
```

Expected (HTTP transcript — 401 because no Bearer token was supplied):

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json;charset=utf-8

{"error":"missing or invalid authorization"}
```

Now sign up and log in through the *mounted* auth routes:

```bash
curl -s -X POST http://localhost:8080/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"email":"dev@example.com","password":"S3cret-passw0rd!"}'

curl -s -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"dev@example.com","password":"S3cret-passw0rd!"}'
```

Expected login transcript (the `accessToken` is the JWT you will reuse):

```json
{
  "accessToken": "eyJhbGciOiJFUzI1NiIsImtpZCI6...",
  "refreshToken": "rt_9f2c...opaque...",
  "tokenType": "Bearer",
  "expiresIn": 900
}
```

Call the protected route *with* the Bearer token:

```bash
TOKEN="eyJhbGciOiJFUzI1NiIsImtpZCI6..."   # paste accessToken from above
curl -i http://localhost:8080/projects -H "Authorization: Bearer $TOKEN"
```

Expected (200 — the embedded guard accepted the token and ran the app handler):

```http
HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8

[{"projectId":"proj_demo_1","projectName":"Shōmei Demo Project"}]
```

### Step 3 — Create `examples/microservice-auth-stack` (Milestone 3)

Create `examples/microservice-auth-stack/microservice-auth-stack.cabal`:

```cabal
cabal-version:      3.0
name:               microservice-auth-stack
version:            0.1.0.0
synopsis:           Demo: downstream service verifying Shōmei JWTs locally via fetched JWKS
build-type:         Simple

common warnings
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates
               -Wincomplete-uni-patterns -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions: OverloadedStrings, DataKinds, TypeOperators
                      DeriveGeneric, DerivingStrategies, RecordWildCards
  build-depends:      base, text, time, aeson

executable example-project-service
  import:           warnings, shared
  hs-source-dirs:   app
  main-is:          Main.hs
  other-modules:    Downstream.Jwks
  -- NOTE: deliberately NO dependency on shomei-postgres. This service has no database.
  build-depends:    shomei-core
                  , shomei-jwt              -- verifyToken + JWKSet
                  , servant
                  , servant-server
                  , warp
                  , wai
                  , http-client
                  , http-client-tls
                  , bytestring
```

Create `examples/microservice-auth-stack/app/Downstream/Jwks.hs` — fetch + cache the JWKS:

```haskell
module Downstream.Jwks
  ( JwksCache, newJwksCache, currentJwks ) where

import Shomei.Prelude

import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Data.Aeson qualified as Aeson
import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime, NominalDiffTime)
import Network.HTTP.Client qualified as HTTP
import Crypto.JOSE.JWK (JWKSet)   -- from jose, re-exported via shomei-jwt if convenient

-- The cache stores the parsed JWKSet and the time it was fetched.
data JwksCache = JwksCache
  { cacheManager :: !HTTP.Manager
  , cacheUrl     :: !String
  , cacheTtl     :: !NominalDiffTime          -- default 900s = 15 min (spec: 5-30 min)
  , cacheState   :: !(MVar (Maybe (JWKSet, UTCTime)))
  }

newJwksCache :: HTTP.Manager -> String -> JwksCache
newJwksCache mgr url = JwksCache mgr url 900 <$> undefined  -- see real impl below

-- currentJwks returns the cached JWKSet, refetching if older than the TTL.
-- This is the ONLY place the downstream service talks to the auth service, and it happens
-- at most once per TTL window — never per request.
currentJwks :: JwksCache -> IO JWKSet
currentJwks JwksCache{..} = do
  now <- getCurrentTime
  modifyMVar cacheState $ \st ->
    case st of
      Just (jwks, fetchedAt) | diffUTCTime now fetchedAt < cacheTtl ->
        pure (st, jwks)
      _ -> do
        jwks <- fetchJwks cacheManager cacheUrl
        pure (Just (jwks, now), jwks)

fetchJwks :: HTTP.Manager -> String -> IO JWKSet
fetchJwks mgr url = do
  req  <- HTTP.parseRequest url
  resp <- HTTP.httpLbs req mgr
  case Aeson.eitherDecode (HTTP.responseBody resp) of
    Right jwks -> pure jwks
    Left err   -> error ("JWKS parse failed: " <> err)
```

(The `newJwksCache` body above is sketched; the real one allocates the `MVar` with
`newMVar Nothing`. Re-exporting `JWKSet` from `shomei-jwt` avoids importing `jose` directly
here — prefer that to keep the example's deps minimal.)

Create `examples/microservice-auth-stack/app/Main.hs` — the downstream Servant service. It
protects `/projects` by verifying the Bearer token *locally* with `verifyToken`:

```haskell
module Main (main) where

import Shomei.Prelude

import Data.Aeson (ToJSON)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.Wai (Request, requestHeaders)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
import Servant.Server.Experimental.Auth
  ( AuthHandler, AuthServerData, mkAuthHandler )
import System.Environment (getEnv)

import Shomei.Config (defaultShomeiConfig)          -- ShomeiConfig with issuer/audience (EP-2)
import Shomei.Jwt (verifyToken)                      -- JWKSet -> ShomeiConfig -> Text -> IO (...)
import Shomei.Domain.Claims (AuthClaims)             -- decoded claims (EP-2)
import Downstream.Jwks (JwksCache, newJwksCache, currentJwks)

data Project = Project { projectId :: Text, projectName :: Text }
  deriving stock Generic
  deriving anyclass ToJSON

-- This service's own protected API. The combinator is a LOCAL AuthProtect: the AuthHandler
-- below verifies the JWT offline using the fetched JWKS. There is no Shōmei dependency here
-- beyond the verifier and config types.
type DownstreamAPI =
  AuthProtect "downstream-jwt" :> "projects" :> Get '[JSON] [Project]

type instance AuthServerData (AuthProtect "downstream-jwt") = AuthClaims

main :: IO ()
main = do
  jwksUrl <- getEnv "SHOMEI_JWKS_URL"               -- e.g. http://localhost:8080/.well-known/jwks.json
  mgr     <- HTTP.newManager HTTP.defaultManagerSettings
  cache   <- newJwksCache mgr jwksUrl               -- fetches lazily, caches with TTL
  let ctx = localAuthHandler cache :. EmptyContext
  putStrLn "example-project-service listening on http://localhost:8090"
  Warp.run 8090 (serveWithContext (Proxy @DownstreamAPI) ctx (projectsHandler))

-- The local guard: pull "Authorization: Bearer <jwt>", verify with the cached JWKS, NO call
-- back to the auth service.
localAuthHandler :: JwksCache -> AuthHandler Request AuthClaims
localAuthHandler cache = mkAuthHandler $ \req -> do
  jwt <- case lookup "Authorization" (requestHeaders req) of
           Just v | Just b <- Text.stripPrefix "Bearer " (Text.decodeUtf8 v) -> pure b
           _ -> throwError err401 { errBody = "missing bearer token" }
  jwks <- liftIO (currentJwks cache)                -- cached; refetch only past TTL
  res  <- liftIO (verifyToken jwks defaultShomeiConfig jwt)
  case res of
    Right claims -> pure claims
    Left _err    -> throwError err401 { errBody = "invalid token (local verification failed)" }

projectsHandler :: AuthClaims -> Handler [Project]
projectsHandler _claims =
  pure [ Project "proj_ms_1" "Downstream-verified Project" ]
```

(`defaultShomeiConfig` must carry the *same* issuer/audience/algorithm the auth service signs
with, so local verification matches. In a real deployment these come from config; for the demo
they can be the EP-2 defaults shared by both processes. Match the real module/symbol names from
EP-2/EP-4.)

Add the package to `cabal.project` (already shown in Step 2). Build:

```bash
cabal build microservice-auth-stack
```

### Step 3b — Two-service runbook

A `process-compose` file makes the demo one command (`process-compose` is a small process
manager that starts and supervises several processes from a YAML file; it is enabled in this
repo's dev shell per `.seihou/config.dhall`). Create
`examples/microservice-auth-stack/process-compose.yaml`:

```yaml
version: "0.5"
processes:
  shomei-server:
    command: "cabal run shomei-server"
    environment:
      - "SHOMEI_DATABASE_URL=postgres://localhost/shomei_dev"
    readiness_probe:
      http_get:
        host: 127.0.0.1
        port: 8080
        path: /health
      initial_delay_seconds: 2
      period_seconds: 1
  example-project-service:
    command: "cabal run example-project-service"
    depends_on:
      shomei-server:
        condition: process_healthy
    environment:
      - "SHOMEI_JWKS_URL=http://localhost:8080/.well-known/jwks.json"
```

Start both:

```bash
process-compose -f examples/microservice-auth-stack/process-compose.yaml up
```

Or run the two `cabal run` commands in separate terminals (auth service first, then the
downstream service with `SHOMEI_JWKS_URL` set). Then drive the scenario from a third terminal.

Log in at the **auth service** and capture the token:

```bash
curl -s -X POST http://localhost:8080/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"email":"ms@example.com","password":"S3cret-passw0rd!"}' >/dev/null

TOKEN=$(curl -s -X POST http://localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"ms@example.com","password":"S3cret-passw0rd!"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["accessToken"])')
echo "$TOKEN"
```

Call the **downstream service** with the token — verified locally, no call to the auth service:

```bash
curl -i http://localhost:8090/projects -H "Authorization: Bearer $TOKEN"
```

Expected (HTTP transcript — 200, local verification succeeded):

```http
HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8

[{"projectId":"proj_ms_1","projectName":"Downstream-verified Project"}]
```

To *prove* no per-request call to the auth service happened, stop the auth service after the
downstream service has fetched the JWKS once, then call `/projects` again — it still returns
200:

```bash
# In the auth-service terminal: Ctrl-C to stop shomei-server.
curl -i http://localhost:8090/projects -H "Authorization: Bearer $TOKEN"
# Still HTTP/1.1 200 OK — the JWKS is cached and verification is offline.
```

A *tampered* token (flip one character of the signature) yields 401:

```bash
BAD="${TOKEN%?}X"   # corrupt the last character
curl -i http://localhost:8090/projects -H "Authorization: Bearer $BAD"
```

Expected (HTTP transcript — 401, the local signature check failed):

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/octet-stream

invalid token (local verification failed)
```

### Step 4 — Project metadata (Milestone 4)

Widen `mori.dhall`. Change the `shomei-client` package's `dependencies` to add
`shomei-servant`, and append two `Application` packages for the examples:

```dhall
, Schema.Package::{
  , name = "shomei-client"
  , type = Schema.PackageType.Client
  , language = Schema.Language.Haskell
  , path = Some "packages/shomei-client"
  , description = Some "Haskell client for the standalone Shōmei auth service"
  , dependencies =
    [ Schema.Dependency.ByName "shomei-core"
    , Schema.Dependency.ByName "shomei-servant"   -- widened: derives client from ShomeiAPI
    ]
  }
, Schema.Package::{
  , name = "embedded-servant-app"
  , type = Schema.PackageType.Application
  , language = Schema.Language.Haskell
  , path = Some "examples/embedded-servant-app"
  , description = Some "Demo: Shōmei auth routes embedded inside a host Servant app"
  , dependencies =
    [ Schema.Dependency.ByName "shomei-servant"
    , Schema.Dependency.ByName "shomei-server"
    ]
  }
, Schema.Package::{
  , name = "example-project-service"
  , type = Schema.PackageType.Application
  , language = Schema.Language.Haskell
  , path = Some "examples/microservice-auth-stack"
  , description = Some "Demo: downstream service verifying Shōmei JWTs locally via fetched JWKS"
  , dependencies =
    [ Schema.Dependency.ByName "shomei-core"
    , Schema.Dependency.ByName "shomei-jwt"
    ]
  }
```

Confirm metadata and the whole workspace:

```bash
mori show --full
cabal build all
```

Expected: `mori show --full` lists `shomei-client` depending on `shomei-core` and
`shomei-servant`, and the two example packages; `cabal build all` ends with all packages
built, no errors.

Commit with the required trailers:

```bash
git add packages/shomei-client examples cabal.project mori.dhall \
        packages/shomei-server docs/plans/7-haskell-client-and-demo-applications.md
git commit -m "feat: shomei-client and embedded + microservice demo apps

Derive a typed servant-client from ShomeiAPI; embedded demo mounts the
auth routes and guards /projects; microservice demo verifies JWTs locally
via a fetched JWKS with a refetch TTL.

MasterPlan: docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md
ExecPlan: docs/plans/7-haskell-client-and-demo-applications.md
Intention: intention_01kt7xgv3pes2v675nr1pmzf6j"
```


## Validation and Acceptance

Acceptance is phrased as observable behavior; "demonstrable" means a human runs the command and
sees the stated output.

**Milestone 0.** `cabal build shomei-server` succeeds, and `cabal repl
shomei-server:lib:shomei-server` can `:m + Shomei.Server.App` without error — proving the
assembly is importable as a library.

**Milestone 1 — client round-trip.** Run `cabal test shomei-client`. It must report
`1 example, 0 failures`. The test performs `signup` → `login` → `me` (authenticated with the
Bearer token via the `AuthClientData`/`mkAuthenticatedRequest` path) → `refresh`, asserting
that `me` returns the signed-up email and that `refresh` returns a non-empty access token. If
`SHOMEI_TEST_URL` is set, the test targets that running server instead of an ephemeral one. A
representative client login transcript (the wire bytes the derived client sends/receives):

```http
POST /auth/login HTTP/1.1
Host: localhost:8080
Content-Type: application/json
Accept: application/json

{"email":"a@example.com","password":"S3cret-passw0rd!"}

HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8

{"accessToken":"eyJhbGciOiJFUzI1Ni...","refreshToken":"rt_...","tokenType":"Bearer","expiresIn":900}
```

**Milestone 2 — embedded `/projects` 401-then-200.** With `embedded-servant-app` running
against the dev PostgreSQL, the Step 2b walkthrough must reproduce exactly: `curl
http://localhost:8080/projects` with no header returns `HTTP/1.1 401 Unauthorized`; after
signing up and logging in via `/auth/*` and supplying `Authorization: Bearer <accessToken>`,
the same route returns `HTTP/1.1 200 OK` with the `[{"projectId":...}]` body. This proves the
embedded model: the mounted auth routes issued a token and the app's own guarded route accepted
it. Optionally add a warp-based hspec test mirroring `shomei-client`'s test that boots the
embedded app and asserts the 401-then-200 sequence programmatically.

**Milestone 3 — downstream local verification.** With both services running per the runbook,
the Step 3b transcript must reproduce: a valid token yields `HTTP/1.1 200 OK` from
`http://localhost:8090/projects`; the same call still returns 200 *after the auth service is
stopped* (proving verification is offline and the JWKS is cached, with no per-request call to
the auth service); a tampered token yields `HTTP/1.1 401 Unauthorized`. The downstream-service
log shows at most one JWKS fetch per TTL window, never one per request — confirm by watching its
output while issuing several `/projects` calls within the TTL: no new fetch line appears.

**Milestone 4.** `mori show --full` reflects the widened `shomei-client` dependency and the two
example packages; `cabal build all` is green inside `nix develop`.

**Whole-plan acceptance.** All three HTTP transcripts above (client login; embedded
401-then-200; downstream local-verification 200) are reproducible by a reader following only
this file and the working tree.


## Idempotence and Recovery

Re-running any milestone is safe. The example executables hold no persistent state of their own;
re-running them just re-serves. `cabal build`/`cabal test`/`cabal run` are idempotent.

The `shomei-client` test uses `withShomeiMigratedDatabase`, which creates a fresh **ephemeral**
PostgreSQL per run and tears it down afterward, so repeated test runs never collide or leave
residue. When targeting a shared server via `SHOMEI_TEST_URL`, the test signs up a fixed email;
if a previous run already created it, either point at a fresh database or change the email — the
test treats a pre-existing-user signup error as a setup failure, so prefer the ephemeral path
for repeatability.

The embedded demo writes to the dev PostgreSQL (`SHOMEI_DATABASE_URL`). Signing up the same
email twice will return a conflict from the auth workflow (HTTP 409); this is expected and not
a corruption — pick a new email or reset the dev database (`dropdb shomei_dev && createdb
shomei_dev` then re-run migrations) to start clean.

The microservice demo's JWKS cache is in-memory; restarting `example-project-service` simply
refetches on the next request. If the auth service rotates signing keys, the downstream service
will reject newly-signed tokens until its cache TTL (default 15 min) expires and it refetches;
to force an immediate refresh during a demo, restart `example-project-service`. If
`process-compose` is unavailable, run the two `cabal run` processes manually in separate
terminals — the runbook works identically.

If a build fails because a symbol/module name in the snippets above does not match what EP-5 or
EP-6 actually exported (the snippets name the *roles* of those symbols; the real names live in
`packages/shomei-servant/src/...` and `packages/shomei-server/src/...`), open those source
files, find the exposed name, and adjust the import — no design change is implied. Record any
such rename in the Decision Log.


## Interfaces and Dependencies

**`Shomei.Client` (module `packages/shomei-client/src/Shomei/Client.hs`).** Exposes, at the end
of Milestone 1:

```haskell
newtype Token = Token { unToken :: Text }
type instance AuthClientData (AuthProtect "shomei-jwt") = Token

type ShomeiClient = ShomeiAPI (AsClientT ClientM)
shomeiClient    :: ShomeiClient
shomeiClientEnv :: String -> IO ClientEnv

signup  :: ClientEnv -> SignupRequest  -> IO (Either ClientError SignupResponse)
login   :: ClientEnv -> LoginRequest   -> IO (Either ClientError LoginResponse)
refresh :: ClientEnv -> RefreshRequest -> IO (Either ClientError TokenPairResponse)
logout  :: ClientEnv -> Token          -> IO (Either ClientError ())
me      :: ClientEnv -> Token          -> IO (Either ClientError UserResponse)
session :: ClientEnv -> Token          -> IO (Either ClientError SessionResponse)
```

Why these libraries: `servant-client` (>= 0.20) derives the client functions from `ShomeiAPI`
so the client cannot drift from the server; `servant-client-core` provides the
`AuthClientData`/`mkAuthenticatedRequest` machinery that attaches the Bearer header to the
`Authenticated` routes; `http-client` provides the connection `Manager`; `http-client-tls`
enables HTTPS base URLs. It imports `ShomeiAPI` and all DTOs from **`shomei-servant`** (the
widening recorded in the Decision Log and MasterPlan IP-6) and the domain types it re-exposes
from **`shomei-core`**.

**`embedded-servant-app` (executable; modules under
`examples/embedded-servant-app/app/`).** At the end of Milestone 2: `Embedded.Api` exports
`type AppAPI = "auth" :> NamedRoutes ShomeiAPI :<|> Authenticated :> "projects" :> Get '[JSON]
[Project]` and `data Project`; `Embedded.Projects` exports `projectsHandler :: AuthUser ->
Handler [Project]`; `Main` builds `application :: Env -> Context ... -> Application` via
`serveWithContext`. It imports `ShomeiAPI`/`Authenticated`/`AuthUser` from **`shomei-servant`**
and the assembly (`Env`, `loadEnvFromEnviron`, `authContext`, `shomeiServer`) from the
**`shomei-server`** library (Milestone 0). It depends on `servant-server` and `warp` to serve.

**`example-project-service` (executable; modules under
`examples/microservice-auth-stack/app/`).** At the end of Milestone 3: `Downstream.Jwks`
exports `newJwksCache :: Manager -> String -> IO JwksCache` and `currentJwks :: JwksCache -> IO
JWKSet` (the only code that contacts the auth service, at most once per TTL); `Main` exports a
`DownstreamAPI` with a *local* `AuthProtect "downstream-jwt"` whose `AuthHandler` calls
`verifyToken jwks config jwt` and yields `AuthClaims`. It imports `verifyToken`/`JWKSet` from
**`shomei-jwt`** and `ShomeiConfig`/`AuthClaims` from **`shomei-core`**. It deliberately does
**not** depend on `shomei-postgres` (it has no database) and makes **no** per-request call to
the auth service. It depends on `http-client`(+`-tls`) for the JWKS fetch and
`servant-server`/`warp` to serve.

**`cabal.project`.** Adds `examples/embedded-servant-app` and
`examples/microservice-auth-stack` to `packages:`.

**`mori.dhall`.** Widens `shomei-client` to depend on `shomei-servant`; registers the two
example packages as `Application` packages.

**Dependency relationships to other plans.** This plan **hard-depends on EP-6**
(`docs/plans/6-standalone-authentication-server.md`): the microservice runbook and the client's
live-server test run against a real `shomei-server`, and the embedded demo imports
`shomei-server`'s assembly library. It **soft-depends on EP-5**
(`docs/plans/5-servant-integration-and-route-protection.md`): the client derivation and the
embedded `AppAPI` reuse `ShomeiAPI`, the DTOs, `Authenticated`, and `AuthUser` from
`shomei-servant`. It also consumes `verifyToken`/`JWKSet` from EP-4
(`docs/plans/4-jwt-signing-verification-and-jwks-publishing.md`) and
`withShomeiMigratedDatabase` from EP-3's test-support
(`docs/plans/3-postgresql-persistence-and-migrations.md`). The only structural change this plan
asks of an earlier plan is the EP-6 library/executable split (Milestone 0), recorded as a
coordination point in the Decision Log.
