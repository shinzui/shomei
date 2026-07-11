---
id: 49
slug: fix-sessioncheckmode-verifytokenandsession-being-a-no-op-on-authenticated-routes
title: "Fix sessionCheckMode VerifyTokenAndSession being a no-op on authenticated routes"
kind: exec-plan
created_at: 2026-07-11T18:18:43Z
intention: intention_01kx9bhj7zeheva31eswpn4grt
---

# Fix sessionCheckMode VerifyTokenAndSession being a no-op on authenticated routes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. It hands out short-lived **access tokens** (signed
JWTs, default lifetime 15 minutes) that a caller presents on protected HTTP routes. Because a JWT
is *self-describing* — a server can check its signature and expiry with nothing but a public key —
protected routes are normally answered without touching the database at all. That is fast, and it
is the usual trade-off: a token stays good until it expires, even if the account behind it was
suspended a second ago.

Shōmei offers an opt-out from that trade-off. A deployment can set a configuration knob called
`sessionCheckMode` to the value `VerifyTokenAndSession`, and the promise — written into Shōmei's
own CHANGELOG, into the Haddock on `shomei-core/src/Shomei/Workflow/Admin.hs`, and into roughly
eight pages of the `shomei-docs` documentation site — is that Shōmei will then re-read the
session row from the database on **every** request, so that suspending a user or revoking a
session takes effect **immediately** rather than up to 15 minutes later.

**That promise is not kept. The knob does nothing on protected HTTP routes.** Setting `sessionCheckMode =
VerifyTokenAndSession` changes no observable behavior on any authenticated route, because the one
function that reads the knob is never called by the server. An access token belonging to a
revoked, suspended, or deleted user's session keeps working on every protected route for its full
remaining lifetime, exactly as if the knob were left at its default. The mitigation that Shōmei
tells operators to reach for in an incident does not exist.

After this change, an operator who sets `SHOMEI_SESSION_CHECK=token-and-session` gets what
the documentation already promises. Concretely, here is the behavior you will be able to see, and
which does not happen today:

1. A user logs in and receives an access token. It is valid for 15 minutes.
2. An administrator revokes that user's sessions (via
   `DELETE /v1/admin/users/{id}/sessions`, or by suspending the account through the admin API).
3. The user's *very next* request to a protected route — for example `GET /v1/auth/me`, carrying
   the same still-unexpired access token — is refused with `401` and a problem document whose
   `code` is `session_revoked`, instead of the `200 OK` it returns today.

The heart of this plan is a test that performs exactly those three steps. It **fails** against the
current code (the third step returns `200`) and **passes** after the fix (the third step returns
`401 session_revoked`). Everything else in the plan exists to make that test pass honestly, to
extend the same guarantee to the other protected-route combinators, and to guarantee we did not
accidentally impose a database read on the *default* mode, which deployments inherit unless they
explicitly override it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**M0 — Orient and reproduce (read-only).**

- [x] Read `shomei-core/src/Shomei/Workflow.hs` lines 450–469 and confirm `verifyToken` is the
      only function that branches on `cfg.sessionCheckMode`.
- [x] Run the "no callers" grep from Concrete Steps step 0.2 and confirm
      `Shomei.Workflow.verifyToken` has zero call sites under any `src/` directory.
- [x] Read `shomei-server/src/Shomei/Server/Boot.hs` lines 377–389 and confirm `Seam.verifier` is
      built from `Shomei.Jwt.Verify.verifyToken` (the pure, session-blind JWT verifier).
- [x] Confirm the environment works: `nix develop --command cabal build all` succeeded before any
      edit. — 2026-07-11
- [x] Run the unmodified `shomei-servant-test` baseline; all 31 existing tests passed. —
      2026-07-11
- [x] Reproduce the bug without editing the tree by loading the existing `shomei-servant-test`
      harness in GHCi: after out-of-band revocation, the workflow returned `SessionRevoked` while
      `GET /v1/auth/me` returned `200`. — 2026-07-11
- [x] Audit the proposed public API and revise it so Shōmei's exported `authHandler` receives the
      whole seam `Env`, rather than continuing to accept an arbitrary verifier that an embedder
      could make session-blind. — 2026-07-11

**M1 — The failing test (the proof).**

- [x] Add `SessionCheckMode (..)` to the `Shomei.Config` import list in
      `shomei-servant/test/Main.hs`. — 2026-07-11
- [x] Add `revokeAllUserSessions` to the `Shomei.Effect.SessionStore` imports in
      `shomei-servant/test/Main.hs`. — 2026-07-11
- [x] Add the `revokeAllSessionsOf` helper to `shomei-servant/test/Main.hs`. — 2026-07-11
- [x] Add `sessionCheckCfg` and `freshSessionCheckEnv` to `main` in `shomei-servant/test/Main.hs`.
      — 2026-07-11
- [x] Add the `scenarioSessionCheckMode` scenario to `shomei-servant/test/Main.hs`. — 2026-07-11
- [x] Extend the `tests` function's positional signature and its call site in `main` with the new
      `freshSessionCheckEnv` parameter, and register the new `testCase`. — 2026-07-11
- [x] Run `nix develop --command cabal test shomei-servant-test` and observe the new case
      **FAIL** with `expected: 401 / but got: 200`. Paste the transcript into
      Surprises & Discoveries. — 2026-07-11

**M2 — The fix.**

- [x] Add `verifyRequestToken` to `shomei-servant/src/Shomei/Servant/Seam.hs` and export it. —
      2026-07-11
- [x] Delete the `verifier` field from `Shomei.Servant.Seam.Env` (and drop the now-unused
      `TokenError` import). — 2026-07-11
- [x] Change `authHandler` in `shomei-servant/src/Shomei/Servant/Auth.hs` to accept the seam
      `Env`, derive both the cookie policy and verifier from that environment, and map
      `SessionExpired` / `SessionRevoked` to their own 401 problem documents. — 2026-07-11
- [x] Change `resolveAuthUser` in `shomei-servant/src/Shomei/Servant/Auth.hs` to accept the same
      seam `Env`, so `/oauth/authorize` cannot inject a separate session-blind verifier either. —
      2026-07-11
- [x] Update the `resolveAuthUser` call site at `shomei-servant/src/Shomei/Servant/Handlers.hs`
      line ~396 to pass `env`. — 2026-07-11
- [x] Update `authContext` and `seamEnv` in `shomei-server/src/Shomei/Server/Boot.hs`; remove the
      now-dead `Shomei.Jwt.Verify (verifyToken)` import if nothing else in the module uses it. —
      2026-07-11
- [x] Update the test harness `app` and `mkEnvWith` in `shomei-servant/test/Main.hs` for the
      removed `verifier` field. — 2026-07-11
- [x] `nix develop --command cabal build all` is green. — 2026-07-11
- [x] Re-run `nix develop --command cabal test shomei-servant-test`; the M1 case now **PASSES**.
      Paste the transcript into Surprises & Discoveries. — 2026-07-11

**M3 — Extend coverage and guard the default.**

- [x] Extend `scenarioSessionCheckMode` to assert a `RequireRole` route also refuses the revoked
      token with `401 session_revoked`. — 2026-07-11
- [x] Extend it to assert a `RequireScope` route does the same. — 2026-07-11
- [x] Extend it to assert a `RequirePermission` route does the same. — 2026-07-11
- [x] Extend it to assert `GET /oauth/authorize` (the `resolveAuthUser` path) treats the revoked
      token as *unauthenticated* rather than as authenticated. — 2026-07-11
- [x] Add `scenarioDefaultModeIgnoresSessionStore`: under the **default** `VerifyTokenOnly`, a
      revoked session's access token still returns `200` on `GET /v1/auth/me`. This is the
      regression guard against silently imposing a per-request database read on everyone. —
      2026-07-11
- [x] Confirm the pre-existing `scenarioStatusCodes` (double logout → 204/204) still passes
      unchanged — it depends on default-mode semantics. — 2026-07-11
- [x] `nix develop --command cabal test shomei-servant-test` fully green (34 tests). — 2026-07-11
- [x] `nix develop --command cabal test shomei-core-test` fully green (237 tests). — 2026-07-11
- [x] `nix develop --command cabal test shomei-servant-openapi-test` fully green (56 examples). —
      2026-07-11

**M4 — Documentation, OpenAPI, and the truth-in-comments sweep.**

- [ ] Add `pcSessionExpired` and `pcSessionRevoked` to `baselineSpecs` in
      `shomei-servant/src/Shomei/Servant/OpenApi.hs` so every secured operation documents the two
      new `401`s it can now emit.
- [ ] Re-run `nix develop --command cabal test shomei-servant-openapi-test` (the conformance
      suite checks documented `(status, code)` pairs against the catalog).
- [ ] Add the CHANGELOG entry under `## Unreleased`: a **Fixed (security)** note and a
      **Breaking** note for `Seam.Env`, with the embedder migration snippet.
- [ ] Update the Haddock at `shomei-core/src/Shomei/Workflow/Admin.hs` line ~51 so it names the
      enforcement site and the `401` codes the caller now sees.
- [ ] Update the `/oauth/revoke` caveat comment at
      `shomei-servant/src/Shomei/Servant/Handlers.hs` line ~787.
- [ ] Update the Haddock at `shomei-servant/src/Shomei/Servant/Auth.hs` lines 14–16 (it still
      describes the old `TokenError` verifier shape) and the `Seam.Env` module header.
- [ ] Update `docs/user/security.md` where it describes the revocation-latency boundary.
- [ ] Run the truth-sweep grep (Concrete Steps step 4.6) and fix any remaining comment that
      describes `sessionCheckMode` as unimplemented or describes the auth handler as
      session-blind.
- [x] Record in Outcomes & Retrospective the eight `shomei-docs` content pages that mention
      `sessionCheckMode` / `VerifyTokenAndSession` (that separate repository was read through its
      mori registry entry but not edited). — 2026-07-11

**Wrap-up.**

- [ ] `nix develop --command cabal build all` green.
- [ ] `nix develop --command cabal test all` green (see Validation for the `-j2` caveat on the
      PostgreSQL-backed suites).
- [ ] Fill in Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Two discoveries were made while *authoring* this plan; they shaped the design and are recorded
here up front. Add to this section as you implement.

**Discovery A — `Seam.Env.verifier` is redundant with `Seam.Env.runPorts`, and that redundancy is
the bug.** `Env` already carries `runPorts :: forall a. Eff AppEffects a -> IO a`, and
`AppEffects` (defined in the same file, `shomei-servant/src/Shomei/Servant/Seam.hs`) already
contains `TokenVerifier`, `SessionStore`, and `Clock` — which are exactly the three effects
`Shomei.Workflow.verifyToken` requires. So the `verifier` field was never *needed*: a
session-aware verifier can be derived from `runPorts` and `config` alone. The bug exists precisely
because the codebase carries two independent ways to verify a token, and the one the HTTP layer
actually uses is the one that cannot see the session store. This is why the fix **deletes** the
field rather than changing its type (see Decision D1).

**Discovery B — the existing "logout is idempotent" test silently depends on the broken
behavior.** `shomei-servant/test/Main.hs` lines 820–847 (`scenarioStatusCodes`) logs out twice
with the same access token and asserts `204` both times. Its own comment explains why this works:

```haskell
-- Logout is the interesting one: it is now idempotent. A retry after a network blip, or a
-- double-tapped button, must succeed -- "you are already logged out" is what the caller asked
-- for, not a failure. The second call reaches the handler because the default @sessionCheckMode@
-- is @VerifyTokenOnly@, so the access token still verifies against a revoked session; the
-- handler then swallows exactly 'SessionNotFound'.
```

This is a *correct* observation about the default mode, and that test will keep passing (we are
not changing the default — Decision D5). But it means that **under `VerifyTokenAndSession`, HTTP
logout stops being idempotent**: the second `POST /v1/auth/logout` will be refused by the auth
handler with `401 session_revoked` before it ever reaches the handler that swallows
`SessionNotFound`. That is a real, user-visible behavior change for deployments that opt in, it is
arguably the correct behavior (the credential genuinely is dead), and it **must** be called out in
the CHANGELOG. Do not "fix" it by special-casing logout: a session check that exempts the routes
it finds inconvenient is not a session check.

**Discovery C — the bug was reproduced against the current HTTP test assembly, and the workflow
and HTTP layer disagreed on the same token.** On 2026-07-11, before editing production or test
source, the existing `shomei-servant-test` module was loaded in GHCi. The validation action built
an `Env` with `sessionCheckMode = VerifyTokenAndSession`, signed up a user over HTTP, revoked that
user's session through the in-memory `SessionStore`, then sent the same unexpired token to
`GET /v1/auth/me`. The direct workflow call correctly rejected the token while HTTP accepted it:

```text
(signup status, direct Shomei.Workflow.verifyToken result, /v1/auth/me status, problem code)
(201,"SessionRevoked",200,Nothing)
```

This isolates the fault to the HTTP wiring: token generation, signature verification, session
revocation, and `Shomei.Workflow.verifyToken` all worked in the same process and against the same
world. The baseline `nix develop --command cabal build all` also completed successfully, and the
unmodified `shomei-servant-test` suite passed all 31 existing tests.

**Discovery D — the originally proposed API did not make the bug class structurally impossible.**
The first draft removed `Seam.Env.verifier` but kept
`authHandler :: CookiePolicy -> (Text -> IO (Either AuthError AuthClaims)) -> ...`. An embedding
host could still pass a session-blind verifier of that type, so the draft's claim that a caller
"cannot supply a verifier at all" was false. The plan now makes both `authHandler` and
`resolveAuthUser` accept `Seam.Env` directly. They derive the policy and call
`verifyRequestToken` internally. A host can always replace Shōmei's exported auth handler with
entirely custom code, but it can no longer accidentally configure Shōmei's own handler through a
session-blind verifier argument. `Shomei.Servant.Seam` does not import `Shomei.Servant.Auth`, so
having `Auth` import `Seam` introduces no module cycle.

**Discovery E — two operational details in the first draft were inaccurate.** The standalone
server reads `SHOMEI_SESSION_CHECK`, not `SHOMEI_SESSION_CHECK_MODE`; and revoking every session
for a user is `DELETE /v1/admin/users/{userId}/sessions`, not `POST`. The current
`shomei-admin users` command only exposes `create`, so the manual validation must use the admin
HTTP API rather than a nonexistent `shomei-admin users suspend` command.

**Discovery F — the committed-shape acceptance test independently reproduced the validated bug.**
After adding only the M1 test changes, `nix develop --command cabal test shomei-servant-test
--test-show-details=direct` produced exactly one failure, while every pre-existing case stayed
green:

```text
sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route: FAIL
  test/Main.hs:1175:
  expected: 401
   but got: 200

1 out of 32 tests failed
```

This is the red half of the red/green security regression proof. No production source had been
changed when this output was captured.

**Discovery G — record-dot cannot select the rank-polymorphic `runPorts` field at this call
site.** The first M2 build rejected the plan's pseudocode form
`env.runPorts (Wf.verifyToken env.config ...)` because GHC could not instantiate the effect stack:

```text
No instance for HasField "runPorts" Env
Ambiguous type variable ‘es0’ arising from a use of ‘Wf.verifyToken’
```

The ordinary record selector preserves the field's rank-polymorphic application and fixes the
type at `AppEffects`: `runPorts env (Wf.verifyToken (config env) ...)`. This is a syntax-level
adjustment only; the interface and behavior in D1 are unchanged.

**Discovery H — the M2 wiring turns the same acceptance test green without moving the default.**
After deriving authentication from `Env.runPorts` and `Env.config`, the same suite reported:

```text
status codes: signup 201, lifecycle requests still 202, logout idempotent (204/204): OK
sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route: OK

All 32 tests passed
```

The pair with Discovery F is the red/green proof: only the production authentication wiring
changed between the observed `200` failure and the `401 session_revoked` success. The unchanged
double-logout result also confirms `VerifyTokenOnly` remains the default.

**Discovery I — every protected surface shares the fixed verifier, including the authorize
exception.** The M3 suite passed all 34 HTTP cases. The revoked token produced
`401 session_revoked` through `Authenticated`, `RequireRole`, `RequireScope`, and
`RequirePermission`. The separately wired `/oauth/authorize` path returned OAuth
`401 login_required`, and the in-memory authorization-code count stayed unchanged after that
refusal. The default-mode control accepted the revoked session's still-unexpired token with
`200`, while double logout remained `204` / `204`. The supporting suites also passed: 237 core
tests and 56 OpenAPI examples.


## Decision Log

Record every decision made while working on the plan.

- **D1. The fix removes `Shomei.Servant.Seam.Env.verifier`, derives verification from
  `runPorts` + `config`, and makes Shōmei's `authHandler` / `resolveAuthUser` accept `Env`
  directly.**

  Rationale: three options were weighed.

  *Option A — change the field's type* from `Text -> IO (Either TokenError AuthClaims)` to
  `Text -> IO (Either AuthError AuthClaims)`, and have each assembly build a session-aware
  verifier by hand. This works, but it leaves in place the very shape that caused the bug: two
  independent verification paths that must be kept in agreement by convention. An embedding host
  that supplies a session-blind verifier of the right *type* still compiles, still type-checks,
  and silently reintroduces exactly this vulnerability.

  *Option B — keep `verifier` and add `sessionCheck :: SessionId -> IO (Either AuthError ())`.*
  Strictly worse. It is *also* a breaking change (`authHandler` must now take both arguments, so
  its signature changes anyway), it adds a second field that must be kept in sync with the first,
  and an embedder who passes `\_ -> pure (Right ())` for `sessionCheck` has reproduced the bug
  with no compiler complaint. It makes the invariant *more* implicit, not less.

  *Option C (chosen) — delete the field and pass `Env` to the authentication entry points.*
  `Env.runPorts` already interprets `TokenVerifier`, `SessionStore`, and `Clock` (they are in
  `AppEffects`), which is precisely what `Shomei.Workflow.verifyToken` needs. So the seam gains
  one derived function,

  ```haskell
  verifyRequestToken :: Env -> Text -> IO (Either AuthError AuthClaims)
  verifyRequestToken env raw = runPorts env (Wf.verifyToken (config env) (AccessToken raw))
  ```

  and `authHandler :: Env -> AuthHandler Request AuthUser` plus
  `resolveAuthUser :: Env -> Maybe Text -> Maybe Text -> IO (Maybe AuthUser)` call it internally.
  There is exactly **one** verification path inside Shōmei's HTTP layer. An embedding host using
  Shōmei's exported handler cannot inject a session-blind verifier argument because that argument
  no longer exists. A host can, of course, replace the Shōmei handler with custom authentication
  code; no library API can prevent a consumer from bypassing it deliberately. The chosen design
  prevents accidental misassembly while making the supported path safe by construction.

  It also *deletes* code — `Boot.seamEnv`'s hand-rolled `readIORef` +
  `Jwt.Verify.verifyToken` lambda goes away, because `runPorts` (via `runAppIO`) already re-reads
  the swappable key material on every invocation (`shomei-server/src/Shomei/Server/App.hs` lines
  167–177), so key rotation keeps working with no special handling.

  The breakage is loud and trivially fixable: an embedder who wrote `Seam.Env { …, verifier = …
  }` gets a compile error naming a field that no longer exists, and a call such as
  `authHandler policy verifier` gets an arity/type error. The migration is to delete the field and
  call `authHandler env`. A loud break that cannot be ignored is exactly what a security fix
  wants; a silent one that type-checks is exactly what it does not.

  Date: 2026-07-11

- **D2. A revoked or expired session on a protected route answers `401 session_revoked` /
  `401 session_expired`, not the blanket `401 token_invalid` the auth handler emits today. But a
  session id that resolves to *no row at all* stays `401 token_invalid`.**

  Rationale: both `session_expired` and `session_revoked` already exist in the problem catalog at
  `shomei-servant/src/Shomei/Servant/Error.hs` lines 250–253, both already carry `401`, and both
  are already listed in `problemCatalog`, so surfacing them costs no new API surface and passes
  the OpenAPI conformance suite unchanged. Surfacing them leaks nothing: the caller is *holding*
  the token, so telling them "the session behind this token was revoked" tells them nothing they
  could not already infer, and it is dramatically more actionable than a generic
  `token_invalid` — a client can distinguish "re-authenticate, you were logged out" from
  "something is wrong with this credential" and stop retrying.

  The `SessionNotFound` case is deliberately *not* surfaced, for two reasons. First, correctness:
  `Shomei.Servant.Error.authErrorToServerError` maps `SessionNotFound` to
  **`404 session_not_found`** (`pcSessionNotFound = ProblemSpec "session_not_found" err404 …`,
  Error.hs line 251), and a `404` returned from an *auth handler* would be a serious bug — it
  makes a protected route look as though it does not exist, which would break clients and confuse
  operators. So the auth handler must **not** reuse `authErrorToServerError`; it needs its own
  mapping. Second, information: a `sid` claim that resolves to no session row is indistinguishable
  from a garbage or forged `sid`, so `token_invalid` is the honest answer and requires no new
  problem code, no catalog entry, and no OpenAPI change.

  Date: 2026-07-11

- **D3. `VerifyTokenAndSession` costs exactly one session `SELECT` per authenticated request, and
  the plan says so out loud.**

  Rationale: this is not a regression, it is the entire point of the opt-in — you are buying
  immediate revocation with a database read. Two things make it safe to state plainly. First, the
  read is genuinely conditional: `Shomei.Workflow.verifyToken` returns immediately after the JWT
  check under `VerifyTokenOnly` and never calls `findSessionById`, and
  `Shomei.Postgres.Database.runDatabasePool` is *lazy* — it interprets `RunSession` /
  `RunTransaction` with `Pool.use` only when a query is actually issued
  (`shomei-postgres/src/Shomei/Postgres/Database.hs` lines 35–38). So routing the auth handler
  through `runPorts` acquires **zero** pool connections in the default mode; the cost there is one
  `readIORef` and the construction of the effect interpreter stack, which the request's own
  handler pays anyway. Second, the connections are taken *sequentially*, not simultaneously: the
  auth handler's `runPorts` invocation completes and releases its connection before the route
  handler's `runPorts` invocation begins, so an authenticated request never holds two pool
  connections at once and `SHOMEI_DB_POOL_SIZE` (default 10) does not need to be doubled. It
  should still be sized for the extra *throughput*: under `VerifyTokenAndSession` an authenticated
  request performs one additional short `SELECT` on the primary, so a deployment turning the knob
  on should watch pool acquisition latency and raise `SHOMEI_DB_POOL_SIZE` if it climbs. M3's
  `scenarioDefaultModeIgnoresSessionStore` exists specifically to keep the "zero cost in the
  default mode" half of this claim honest.

  Date: 2026-07-11

- **D4. The fix lands in `shomei-servant` (the seam), not in `shomei-server` (the standalone
  binary), so that embedding hosts get it automatically.**

  Rationale: `shomei-servant` is the package an embedding application depends on to mount Shōmei's
  routes inside its own Servant tree; `shomei-server` is one consumer of that seam among others
  (the two `examples/` applications are the others). If the session check were wired only in
  `Shomei.Server.Boot`, then the standalone server would be fixed and every embedded deployment
  would remain vulnerable — which is the same class of mistake as the original bug. Because the
  verifier is *derived* from `Env.runPorts` inside `Shomei.Servant.Seam` (D1), an embedding host
  gets correct behavior with **no action at all beyond deleting its now-nonexistent `verifier`
  field** and building its Servant context with `authHandler env`. The one obligation on an
  embedder is the one they already have: their
  `runPorts` must interpret the full `AppEffects` stack, including `SessionStore` and `Clock`
  against the *same* store the login/refresh workflows write to. An embedder who interprets
  `SessionStore` against a throwaway in-memory world while writing sessions to PostgreSQL would
  get a session check against the wrong store — but such a host is already broken in a dozen other
  ways, and no seam design can rescue it.

  Date: 2026-07-11

- **D5. `VerifyTokenOnly` remains the default. We do not change it.**

  Rationale: `Shomei.Config.defaultShomeiConfig` sets `sessionCheckMode = VerifyTokenOnly`
  (`shomei-core/src/Shomei/Config.hs` line 507) and deployments inherit it unless they opt in.
  Flipping the default as part of a bug fix would silently add a database read to every
  authenticated request in every deployment that upgrades — a performance and capacity change
  delivered under the banner of a security patch, which is precisely the kind of surprise that
  makes operators distrust upgrades. The knob is opt-in by design: stateless verification is the
  right default for most deployments, and the ones that need immediate revocation know who they
  are. What was broken is that opting in did nothing; the fix is to make opting in work, not to
  opt everyone in. This plan therefore *adds* a regression test asserting the default still does
  not consult the session store.

  Date: 2026-07-11

- **D6. The session check runs in the auth handler, which means it also covers `RequireRole`,
  `RequireScope`, `RequirePermission`, and `/oauth/authorize` — by construction, not by
  repetition.**

  Rationale: `shomei-servant/src/Shomei/Servant/Authz.hs` implements the three authorization
  combinators through a shared helper `authorizedCheck` (lines 146–155), which runs *the very same*
  `AuthHandler` registered in the Servant context (`unAuthHandler (getContextEntry ctx)`) and only
  then applies its role/scope/permission predicate. So fixing the auth handler fixes all three
  combinators with no further edits. Likewise `/oauth/authorize` cannot use the `Authenticated`
  combinator (it must *redirect* an unauthenticated browser rather than answer `401`, so it never
  sees a WAI `Request`), and instead calls `Shomei.Servant.Auth.resolveAuthUser`. After this plan,
  that function accepts the same `Env` and calls `verifyRequestToken` internally, so it cannot
  drift onto a separately supplied verifier. M3 nonetheless adds explicit tests for all four,
  because "it follows by construction" is a claim that should be checked, not trusted.

  Date: 2026-07-11

- **D7. The auth handler gets its own `AuthError → ServerError` mapping; it does not reuse
  `authErrorToServerError`.**

  Rationale: see D2. `authErrorToServerError` is the *handler-layer* mapping and maps
  `SessionNotFound` to `404`, which is wrong for an authentication failure. The auth handler needs
  a three-line total function of its own, kept next to `authHandler` in
  `shomei-servant/src/Shomei/Servant/Auth.hs`, that maps `SessionExpired → 401 session_expired`,
  `SessionRevoked → 401 session_revoked`, and *everything else* (including `TokenInvalid` and
  `SessionNotFound`) to the existing `401 token_invalid`. Making the fallback total rather than
  enumerating every `AuthError` constructor is deliberate: `AuthError` has ~40 constructors, almost
  none of which `Shomei.Workflow.verifyToken` can return, and a fallback that fails closed to
  `401 token_invalid` is the safe behavior if that ever changes.

  Date: 2026-07-11

- **D8. `Shomei.Workflow.verifyToken` is reused as-is; no new workflow is written.**

  Rationale: the function already exists, already has the exact semantics we want, already reads
  the config knob, and is already unit-tested at `shomei-core/test/Shomei/WorkflowSpec.hs` line
  217 (`"verifyToken (token+session) rejects an expired session"`). It has simply never had a
  production caller. The whole fix is to *give it one*. Writing a second, parallel implementation
  in the servant layer would be how this bug happens again.

  Date: 2026-07-11

- **D9. Treat the reported behavior as a confirmed security bug, not a documentation-only
  mismatch.**

  Rationale: the setting is wired from configuration and explicitly documented as an immediate
  revocation control, but the production HTTP verifier does not call the only workflow that reads
  it. More importantly, the read-only GHCi reproduction exercised the existing real-HTTP / real-JWT
  test assembly and observed the direct workflow return `SessionRevoked` while the protected route
  returned `200` for the same token after the same revocation. The impact is bounded to an
  outstanding access token's remaining TTL because refresh and introspection are already
  session-aware, but a bounded bypass of an explicitly selected immediate-revocation control is
  still a security bug.

  Date: 2026-07-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Plan-validation outcome (2026-07-11).** The claimed bug is confirmed. No production or test
source was edited during validation. A clean baseline build passed, static call-site analysis
showed the workflow that reads `sessionCheckMode` has no production caller, and the live
reproduction observed `(direct workflow = SessionRevoked, protected HTTP route = 200)` after
revoking the session behind a still-unexpired token. The unmodified Servant suite passed all 31
existing tests, confirming the reproduction did not depend on an already-failing baseline.
Implementation remains pending from M1 onward.

The validation also improved the proposed fix. Removing only `Seam.Env.verifier` was insufficient
while `authHandler` still accepted an arbitrary verifier argument; the revised plan makes the
authentication entry points accept `Env` directly. It also corrected the configuration name,
admin HTTP method, nonexistent CLI example, and brittle exact test-count expectations.

The mori registry identifies `shinzui/shomei-docs` at
`/Users/shinzui/Keikaku/bokuno/shomei-docs`. The eight user-facing content pages found by the
validated search are listed below. They are outside this plan's edit scope; after the fix lands,
the follow-up is to review each for the new error codes, the now-real per-request `SELECT`, and
the embedding API migration:

- `content/docs/shomei/explanation/admin-http-api.mdx`
- `content/docs/shomei/explanation/security-model.mdx`
- `content/docs/shomei/reference/oidc-endpoints.mdx`
- `content/docs/shomei/explanation/jwt-jwks-and-local-verification.mdx`
- `content/docs/shomei/walkthrough/tokens-and-operations/02-token-verification-and-claim-recovery.mdx`
- `content/docs/shomei/reference/workflows.mdx`
- `content/docs/shomei/reference/core-config.mdx`
- `content/docs/shomei/walkthrough/api-and-client/10-oauth2-and-oidc-provider.mdx`

Keep this section current during implementation, including whether the separate `shomei-docs`
follow-up was opened. This plan deliberately does not edit that repository.


## Context and Orientation

This section assumes you have never seen this repository. Read it before touching anything.

### The repository

The working tree is a Cabal multi-package Haskell workspace at
`/Users/shinzui/Keikaku/bokuno/shomei`. The packages relevant here, in dependency order:

- **`shomei-core`** — the pure domain: configuration types, the effect *ports* (interfaces), the
  errors, and the *workflows* (the business rules). It has no HTTP and no database. Key files:
  `shomei-core/src/Shomei/Config.hs`, `shomei-core/src/Shomei/Workflow.hs`,
  `shomei-core/src/Shomei/Error.hs`.
- **`shomei-jwt`** — the JWT implementation (signing and verifying with the `jose` library).
  Key file: `shomei-jwt/src/Shomei/Jwt/Verify.hs`.
- **`shomei-postgres`** — PostgreSQL *interpreters* for the ports.
- **`shomei-servant`** — the HTTP layer: the route types, the handlers, the authentication
  combinator, and **the seam** (see below). This is the package an embedding application depends
  on.
- **`shomei-server`** — the standalone server binary: it assembles a PostgreSQL-backed
  interpreter stack and serves `shomei-servant`'s routes.

Two terms of art you must know:

- **Effect / port / interpreter.** Shōmei uses the `effectful` library. An *effect* (Shōmei calls
  them ports) is an interface — for example `SessionStore`, declared in
  `shomei-core/src/Shomei/Effect/SessionStore.hs`, which offers operations like
  `findSessionById :: SessionId -> Eff es (Maybe Session)` and
  `revokeAllUserSessions :: UserId -> UTCTime -> Eff es ()`. An *interpreter* is an
  implementation of that interface — `runSessionStorePostgres` talks to a database,
  `runSessionStore` (in-memory) talks to an `IORef`. Code written against the port runs unchanged
  over either. A type like `Eff es a` is "a computation producing `a` using the effects in the
  list `es`", and the constraint `SessionStore :> es` means "the `SessionStore` effect is
  available in `es`".
- **The seam.** `shomei-servant/src/Shomei/Servant/Seam.hs` is the boundary between the effect
  world and Servant's `Handler` monad. It defines `AppEffects` (the canonical, ordered list of
  every port Shōmei needs) and a record `Env` that every HTTP handler receives. `Env` carries,
  among other things, `runPorts :: forall a. Eff AppEffects a -> IO a` — a function that runs any
  computation over the full port stack down to `IO`. Each *assembly* (the standalone server, the
  test suite, an embedding host) builds its own `Env` with its own `runPorts`.

### The knob

`shomei-core/src/Shomei/Config.hs` line 120 declares:

```haskell
data SessionCheckMode = VerifyTokenOnly | VerifyTokenAndSession
```

It is a field of `ShomeiConfig` (line 436) and defaults to `VerifyTokenOnly` (line 507). The
standalone server reads it from the environment variable `SHOMEI_SESSION_CHECK`, accepting
the strings `token-only` and `token-and-session`
(`shomei-server/src/Shomei/Server/Config.hs` lines 1227–1234).

### The bug, with evidence

**Exactly one function in the entire codebase reads the knob.** It is
`Shomei.Workflow.verifyToken`, at `shomei-core/src/Shomei/Workflow.hs` lines 450–469:

```haskell
verifyToken ::
  (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
  ShomeiConfig ->
  AccessToken ->
  Eff es (Either AuthError AuthClaims)
verifyToken cfg token = do
  result <- verifyAccessToken token
  case result of
    Left te -> pure (Left (TokenInvalid te))
    Right claims -> case cfg.sessionCheckMode of
      VerifyTokenOnly -> pure (Right claims)
      VerifyTokenAndSession -> do
        ts <- now
        mSession <- findSessionById claims.sessionId
        case mSession of
          Nothing -> pure (Left SessionNotFound)
          Just s
            | s.expiresAt <= ts -> pure (Left SessionExpired)
            | s.status /= SessionActive -> pure (Left SessionRevoked)
            | otherwise -> pure (Right claims)
```

This function is correct. It is also **dead code in production**: it has no callers in
`shomei-core/src`, `shomei-servant/src`, `shomei-server/src`, or `shomei-client/src`. Its only
consumer anywhere is a unit test, `shomei-core/test/Shomei/WorkflowSpec.hs` line 217. You will
verify this yourself in M0 with a grep.

**What the server actually calls instead.** The standalone server builds the seam `Env` in
`shomei-server/src/Shomei/Server/Boot.hs` (lines 377–389):

```haskell
seamEnv :: Env -> Seam.Env
seamEnv env =
  Seam.Env
    { Seam.runPorts = runPorts,
      Seam.config = env.envConfig,
      Seam.verifier = \tok -> do
        keys <- readIORef env.envKeys
        verifyToken keys.verifierJwks env.envConfig tok,
      Seam.jwksJson = (.jwksBody) <$> readIORef env.envKeys,
      Seam.accountKeyOf = AccountKey . sha256Hex
    }
```

The `verifyToken` in that snippet is **not** the workflow above. Line 50 of the same file reads
`import Shomei.Jwt.Verify (verifyToken)` — it is the *pure JWT verifier* from `shomei-jwt`, whose
type is `JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)`. It checks the
signature, the issuer, the audience, and the expiry. It has no access to the session store, it
never reads `sessionCheckMode`, and it cannot possibly know whether a session was revoked. Two
different functions with the same name; the wrong one is wired in.

That `Seam.verifier` field is then handed to the authentication handler
(`shomei-server/src/Shomei/Server/Boot.hs` line 370), and
`Shomei.Servant.Auth.authHandler` (`shomei-servant/src/Shomei/Servant/Auth.hs` line 121) simply
calls it and collapses any `Left` into a `401 token_invalid`:

```haskell
authHandler :: CookiePolicy -> (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request AuthUser
authHandler policy verify = mkAuthHandler handle
  where
    handle req = do
      (source, tok) <- maybe (throwError (toProblemError pcMissingToken Nothing)) pure (extractToken policy.transport req)
      when (source == FromCookie && not (isSafeMethod req) && not (originAllowed policy.allowedOrigins req)) $
        throwError csrfRejected
      res <- liftIO (verify tok)
      case res of
        Left _ -> throwError (toProblemError pcTokenInvalidAuth Nothing)
        Right claims -> pure (authUserFromClaims claims)
```

So: **every route marked `Authenticated` is verified statelessly, regardless of
`sessionCheckMode`.** By D6's reasoning that also covers every `RequireRole` / `RequireScope` /
`RequirePermission` route (they run the same handler through `Authz.authorizedCheck`) and
`/oauth/authorize` (which calls `resolveAuthUser`, parameterized over the same verifier).

**Impact.** An access token belonging to a revoked, suspended, or deleted user's session keeps
working on every protected route until it expires — 15 minutes by default — *even with
`sessionCheckMode = VerifyTokenAndSession` set*. This is exactly the mitigation Shōmei's own
CHANGELOG offers for the admin API ("outstanding access tokens ride out their TTL unless the
deployment sets `sessionCheckMode = VerifyTokenAndSession`") and that the Haddock on
`shomei-core/src/Shomei/Workflow/Admin.hs` line 51 repeats. The mitigation does not exist.

### What still holds — do not overstate the bug

Be precise about the blast radius; two other paths are genuinely session-aware and are **not**
affected:

- **`refresh` enforces session status and expiry.** `Shomei.Workflow.refresh`
  (`shomei-core/src/Shomei/Workflow.hs` lines ~362–372) loads the session and returns
  `SessionExpired` / `SessionRevoked` before rotating. So a revoked session **cannot be extended**
  — the user cannot obtain a *new* access token. This is unconditional; it does not depend on
  `sessionCheckMode`.
- **`POST /oauth/introspect` always consults the session store**, regardless of the knob
  (`shomei-servant/src/Shomei/Servant/Handlers.hs` line 741 and its Haddock, which says so
  explicitly). A resource server that introspects sees the revocation immediately.

So the blast radius is bounded: **outstanding access tokens, on protected routes, for at most one
access-token TTL.** That is still a real vulnerability — it is the difference between "revoked
now" and "revoked in up to 15 minutes", and it is the difference an operator is explicitly
promised they can buy — but it is not "revocation does not work at all".

### Where the pieces you will touch live

| What | File | Roughly |
|---|---|---|
| The workflow that reads the knob (reuse as-is) | `shomei-core/src/Shomei/Workflow.hs` | 450–469 |
| The seam `Env` (delete `verifier`, add `verifyRequestToken`) | `shomei-servant/src/Shomei/Servant/Seam.hs` | 62–110 |
| The auth handler (take `Env` + error mapping) | `shomei-servant/src/Shomei/Servant/Auth.hs` | 117–133, 173–184 |
| The problem-details catalog (`session_revoked` etc. already exist) | `shomei-servant/src/Shomei/Servant/Error.hs` | 250–253 |
| The OpenAPI baseline for secured routes | `shomei-servant/src/Shomei/Servant/OpenApi.hs` | 536–538 |
| The `/oauth/authorize` `resolveAuthUser` call | `shomei-servant/src/Shomei/Servant/Handlers.hs` | ~396 |
| The server's seam assembly | `shomei-server/src/Shomei/Server/Boot.hs` | 50, 368–389 |
| The end-to-end test suite (M1 lives here) | `shomei-servant/test/Main.hs` | 170–200, 366–461, 1223+ |


## Plan of Work

The work is five milestones. M1 comes first and deliberately produces a **failing** test: a
security fix whose test was written after the fix is a test that proves nothing, because you never
saw it fail. Everything after M1 is judged by whether it turns that red test green without turning
anything else red.

### M0 — Orient and reproduce (no edits)

Scope: confirm, with your own eyes and your own greps, every claim in Context and Orientation.
Nothing is edited. At the end of this milestone you will have personally seen that
`Shomei.Workflow.verifyToken` has no production callers and that
`shomei-server/src/Shomei/Server/Boot.hs` wires the *other* `verifyToken`. You will also have a
green `cabal build all`, which is your baseline: if it is red before you start, stop and fix the
environment first, because you will not be able to tell your breakage from pre-existing breakage.

Acceptance: the source search in Concrete Steps step 0.2 prints only comments, definitions, and
unrelated same-named helpers — no call to `Shomei.Workflow.verifyToken`; `nix develop --command
cabal build all` succeeds.

### M1 — The failing test

Scope: add one new end-to-end scenario to `shomei-servant/test/Main.hs` that configures
`sessionCheckMode = VerifyTokenAndSession`, signs a user up over real HTTP, revokes their session
out of band, and then calls `GET /v1/auth/me` with the still-unexpired access token. It asserts
`401`. Today the server answers `200`, so the test **fails**, and that failure *is* the
reproduction of the bug.

The test suite here is a real HTTP end-to-end suite: it starts a Warp server on a random port with
`testWithApplication`, serving the actual Servant tree, and drives it with an `http-client`
`Manager`. The port stack behind it is a hybrid — in-memory stores (an `IORef World`) plus the
*real* `jose` signer and verifier, so tokens are genuinely signed and genuinely verified. That
means the scenario exercises exactly the code path the bug lives in.

"Revoking the session out of band" means: reach into the same in-memory world the server is
running against and revoke the user's sessions directly through the `SessionStore` port, without
going through HTTP. The test file already does this kind of thing — `grantAdminTo` (line 235) and
`defineRoleIn` (line 261) both call `runInMemory ref` against the live world. We use
`revokeAllUserSessions`, which takes only a `UserId`, so the test never needs to extract the
session id from the token. This mirrors precisely what a real administrator does when they suspend
an account (`Shomei.Workflow.Admin.suspendUser` calls `revokeAllUserSessions`), so we are testing
the real incident scenario, not an artificial one.

At the end of this milestone, `cabal test shomei-servant-test` reports exactly one failing case,
with a message that says the route returned `200` where `401` was expected. That transcript goes
into Surprises & Discoveries.

Acceptance: the new case fails, for the stated reason, and no other case's status changes.

### M2 — The fix

Scope: give `Shomei.Workflow.verifyToken` its intended caller.

Three edits carry the whole fix. First, `shomei-servant/src/Shomei/Servant/Seam.hs` gains a
derived verifier and loses the `verifier` field:

```haskell
verifyRequestToken :: Env -> Text -> IO (Either AuthError AuthClaims)
verifyRequestToken env raw = runPorts env (Wf.verifyToken (config env) (AccessToken raw))
```

This is the entire mechanism. `env.runPorts` interprets `AppEffects`, which already contains
`TokenVerifier`, `SessionStore`, and `Clock` — the three effects the workflow needs — so the
workflow runs against whatever stores that assembly is wired to, with whatever key material it
currently holds. On the standalone server that means the live PostgreSQL pool and the *current*
signing keys (`runAppIO` re-reads them from an `IORef` on every invocation,
`shomei-server/src/Shomei/Server/App.hs` lines 167–177), so hot key rotation keeps working
untouched and we delete the hand-rolled `readIORef` in `Boot.seamEnv` that used to duplicate it.

Second, `shomei-servant/src/Shomei/Servant/Auth.hs`'s `authHandler` and `resolveAuthUser` change
from accepting a caller-supplied verifier to accepting `Shomei.Servant.Seam.Env`. Each derives the
`CookiePolicy` from `env.config` and calls `verifyRequestToken env` internally. This closes the
assembly hole discovered during plan validation: merely changing the verifier result from
`TokenError` to `AuthError` would still let an embedder inject a session-blind verifier.
`authHandler` also gains a small total mapping from `AuthError` to the right problem document
(D2, D7): `SessionExpired → 401 session_expired`, `SessionRevoked → 401 session_revoked`,
everything else → `401 token_invalid`. It must *not* call `authErrorToServerError`, which would
turn `SessionNotFound` into a `404` and make a protected route look nonexistent.

Third, the three assemblies are updated to stop passing a `verifier` and pass their existing
`Env` directly: `shomei-server/src/Shomei/Server/Boot.hs` (`authContext`, `seamEnv`),
`shomei-servant/src/Shomei/Servant/Handlers.hs` (the `resolveAuthUser` call at ~line 396), and
`shomei-servant/test/Main.hs` (`app` and `mkEnvWith`).

At the end of this milestone the M1 test passes. Nothing else may have changed status — in
particular `scenarioStatusCodes` (double logout → `204`/`204`) must still pass, because it runs
under the default mode and the default is unchanged (D5, Discovery B).

Acceptance: `cabal build all` green; the M1 case flips from FAIL to PASS; the rest of
`shomei-servant-test` is unchanged.

### M3 — Extend coverage and guard the default

Scope: two kinds of test.

The first kind extends the M1 scenario to the other protected surfaces, so that D6's
"it follows by construction" is checked rather than assumed. The test API in
`shomei-servant/test/Main.hs` (`TestAPI`, line 170) already mounts three host routes guarded
*only* by the combinators — `RequireRole "admin" :> "admin" :> "users"`,
`RequireScope "kawa:ingest" :> "ingest"`, and
`RequirePermission "projects:write" :> "host" :> "projects"` — with handlers that contain no
authorization code at all. Point the revoked token at each and assert `401 session_revoked`. Then
point it at `GET /oauth/authorize`, which authenticates through `resolveAuthUser` rather than the
combinator, and assert the revoked token is treated as *unauthenticated* (the endpoint either
redirects to the configured login URL or answers `401 login_required`, depending on the env's
`loginUrl`) rather than being handed a code.

The second kind is the regression guard, and it matters as much as the fix. Add
`scenarioDefaultModeIgnoresSessionStore`: under the **default** `VerifyTokenOnly`, revoke the
session out of band and assert `GET /v1/auth/me` still answers `200`. This is a *behavioral* proof
that the session store was not consulted — if it had been, the route would have returned `401`. It
is the tripwire that catches a future refactor silently imposing a per-request database read on
every deployment (D3, D5). A stronger version using a counting `SessionStore` interpreter is
possible but not worth the machinery; the behavioral assertion is exact and cheap.

Acceptance: `shomei-servant-test`, `shomei-core-test`, and `shomei-servant-openapi-test` all
green.

### M4 — Documentation, OpenAPI, and the truth-in-comments sweep

Scope: make the repository stop lying, and document the breaking change.

`shomei-servant/src/Shomei/Servant/OpenApi.hs` has a function `baselineSpecs` (lines 536–538) whose
comment reads "an operation that requires a bearer token can always answer `401` with no credential
or a bad one … so a new authenticated route documents its 401s the day it is added". After M2, a
secured operation can *also* answer `401 session_expired` or `401 session_revoked`, so those two
specs must be added there. Both are already in `problemCatalog`, so the conformance suite
(`shomei-servant-openapi-test`, which checks that every documented `(status, code)` pair exists in
the catalog) keeps passing.

The CHANGELOG needs two entries under `## Unreleased`: a **security fix** entry stating plainly
that `VerifyTokenAndSession` was a no-op on authenticated routes and now is not, with the honest
blast radius (bounded to outstanding access tokens for one TTL; `refresh` and `/oauth/introspect`
were always session-aware); and a **breaking change** entry for the removal of
`Shomei.Servant.Seam.Env.verifier`, with a two-line migration snippet for embedding hosts.
Because `VerifyTokenAndSession` now genuinely intercepts every request, the CHANGELOG must also
record the two consequences an operator will actually notice: one session `SELECT` per
authenticated request (D3), and HTTP logout ceasing to be idempotent under that mode (Discovery B).

Then the comment sweep. Note a subtlety: the Haddock at
`shomei-core/src/Shomei/Workflow/Admin.hs` line 51 is not *wrong* after the fix — it says
outstanding access tokens ride out their TTL "unless the deployment sets `sessionCheckMode =
VerifyTokenAndSession`, which re-reads the session on every request", and after M2 that becomes
**true for the first time**. So the job there is not to correct a falsehood but to make a
now-true sentence useful: name where the check is enforced (the auth handler) and what the caller
sees (`401 session_revoked`). The genuinely stale comments are the ones describing the *old
plumbing*: `shomei-servant/src/Shomei/Servant/Auth.hs` lines 14–16 (which describes the verifier
as `Text -> IO (Either TokenError AuthClaims)` built from `verifyToken jwks config`), the
`Seam.Env` module header (which describes a `verifier` field that no longer exists), and the
`/oauth/revoke` caveat at `shomei-servant/src/Shomei/Servant/Handlers.hs` line ~787. Finish with
the grep in step 4.6 and fix whatever else it turns up.

Finally, `docs/user/security.md` in *this* repository describes the revocation-latency boundary and
must be brought in line. The **`shomei-docs` repository is separate and out of scope for this
plan** — eight of its user-facing pages mention the mode and will need review once this lands.
Their validated paths are already recorded in Outcomes & Retrospective.

Acceptance: all suites green; `git grep` for the stale phrasing returns nothing; the CHANGELOG
entry exists and names the breaking change.


## Concrete Steps

All commands are run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`, inside the
Nix development shell. Every build/test command is prefixed with `nix develop --command`, which
enters the shell for that one command. If you prefer, run `nix develop` once to get an interactive
shell and then drop the prefix from every command below.

### Step 0 — Orient (M0)

**0.1** Confirm the baseline builds.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal build all
```

Expect it to end with a series of `Up to date` / successful compilation lines and no errors. If
this fails, stop; fix the environment before proceeding.

**0.2** Prove `Shomei.Workflow.verifyToken` has no production callers. Scope `rg` to source
directories so build artifacts are never considered:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
rg -n '\bverifyToken\b' shomei-core/src shomei-servant/src shomei-server/src shomei-client/src \
  --glob '*.hs'
```

Expected output — note that every hit is either a *comment*, the *definition itself*, or
`Shomei.Jwt.Verify`'s unrelated same-named function; there is not one call to the workflow:

```text
shomei-core/src/Shomei/Workflow.hs:4:-- (rotation with reuse detection), 'logout', and 'verifyToken'. They contain the rules of
shomei-core/src/Shomei/Workflow.hs:10:-- short-circuit on the first 'AuthError'; 'refresh'/'logout'/'verifyToken' return
shomei-core/src/Shomei/Workflow.hs:20:    verifyToken,
shomei-core/src/Shomei/Workflow.hs:450:verifyToken ::
shomei-core/src/Shomei/Workflow.hs:455:verifyToken cfg token = do
shomei-core/src/Shomei/Workflow/TokenExchange.hs:165:  actorClaims <- verifyToken rawActor
shomei-core/src/Shomei/Workflow/TokenExchange.hs:208:  subjectClaims <- verifyToken req.subjectToken
shomei-core/src/Shomei/Workflow/TokenExchange.hs:272:verifyToken ::
shomei-core/src/Shomei/Workflow/TokenExchange.hs:276:verifyToken raw =
shomei-servant/src/Shomei/Servant/Auth.hs:16:-- @\\t -> verifyToken jwks config t@); this module therefore never touches @jose@.
shomei-server/src/Shomei/Server/Boot.hs:50:import Shomei.Jwt.Verify (verifyToken)
shomei-server/src/Shomei/Server/Boot.hs:386:        verifyToken keys.verifierJwks env.envConfig tok,
```

Read those three `TokenExchange.hs` hits and satisfy yourself that they are a *different*,
module-local helper (`verifyToken :: Text -> Eff es (Either AuthError AuthClaims)`, wrapping the
`TokenVerifier` port only — no session store, no config knob). They are not callers of the
workflow.

**0.3** Prove the knob is read in exactly one place:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
rg -n 'sessionCheckMode' shomei-core/src shomei-servant/src shomei-server/src --glob '*.hs'
```

Expected: the field's *declaration* and *default* in `Shomei/Config.hs`, the `case` in
`Shomei/Workflow.hs` line 459, the env-var plumbing in `Shomei/Server/Config.hs`, and one
*comment* in `Shomei/Servant/Handlers.hs`. No other reader.

### Step 1 — The failing test (M1)

All edits in this step are in `shomei-servant/test/Main.hs`.

**1.1** Extend the `Shomei.Config` import (currently line 70) to bring in `SessionCheckMode`:

```haskell
import Shomei.Config (ImpersonationConfig (..), NotifierConfig (..), OAuthConfig (..), ServiceAccountConfig (..), ServiceAccountId (..), ServiceTokenConfig (..), SessionCheckMode (..), ShomeiConfig (..), TokenTransport (..), TotpConfig (..), defaultShomeiConfig)
```

**1.2** Import the session-store operation the out-of-band revocation needs. The file already
imports `Shomei.Effect.Clock (now)` at line 118; add alongside it:

```haskell
import Shomei.Effect.SessionStore (revokeAllUserSessions)
```

**1.3** Add the out-of-band revocation helper. Put it next to the existing `grantAdminTo` /
`defineRoleIn` helpers (around line 260), whose shape it copies exactly:

```haskell
-- | Revoke every session of a user straight against the in-memory world the server is running on,
-- without going through HTTP. This is what an administrator's suspend does
-- ('Shomei.Workflow.Admin.suspendUser' calls the very same port operation), so a scenario that
-- uses it is reproducing the real incident, not an artificial one.
revokeAllSessionsOf :: IORef World -> Text -> IO ()
revokeAllSessionsOf ref userIdText = do
  uid <- parseUserId userIdText
  runInMemory ref do
    ts <- now
    revokeAllUserSessions uid ts
```

**1.4** In `main` (around line 375, among the other `fresh*Env` definitions), add a config with the
knob turned on and an env built over its own fresh world:

```haskell
      -- The session-check knob turned ON, over its own World. The World ref comes back so the
      -- scenario can revoke the session out of band, exactly as an administrator would.
      sessionCheckCfg = cfg {sessionCheckMode = VerifyTokenAndSession}
      freshSessionCheckEnv = do
        r <- newIORef (emptyWorld t0)
        pure (r, mkEnvWith sessionCheckCfg r)
```

**1.5** Add the scenario. Place it near the other scenarios (anywhere at top level in the file):

```haskell
-- | The session-check knob, end to end.
--
-- With @sessionCheckMode = VerifyTokenAndSession@, an access token whose session has been revoked
-- must be refused on an authenticated route -- immediately, not when the token expires. This is
-- the whole promise of the knob, and before plan 49 it did not hold: the auth handler verified
-- the JWT statelessly and never looked at the session store.
--
-- The token here is deliberately still well within its 15-minute lifetime; the ONLY thing that
-- changed is the session row.
scenarioSessionCheckMode :: IORef World -> Int -> IO ()
scenarioSessionCheckMode ref port = do
  mgr <- newManager defaultManagerSettings
  let email = "sessioncheck@example.com" :: Text
      pw = "correct horse battery staple" :: Text

  -- Sign up: we get a user id and a fresh, valid access token.
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("S" :: Text)])
  sStatus @?= 201
  sresp <- must "signup body" sBody
  uid <- must "signup userId" (dig ["user", "userId"] sresp >>= asText)
  access <- must "signup accessToken" (dig ["token", "accessToken"] sresp >>= asText)

  -- The token works, as it must.
  (beforeStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer access)
  beforeStatus @?= 200

  -- An administrator revokes the session out of band. The access token is untouched and still
  -- unexpired.
  revokeAllSessionsOf ref uid

  -- THE ASSERTION. Before plan 49 this returns 200: the knob was a no-op.
  after <- getRaw mgr port "/v1/auth/me" (bearer access)
  assertProblem "a revoked session on an authenticated route" 401 "session_revoked" after
```

Two notes on the helpers used, so you can find them: `bearer` builds the `Authorization` header
list, `getJSON` returns `(status, Maybe Value)`, `getRaw` returns
`(status, headers, Maybe Value)`, and `assertProblem` asserts an RFC 7807 problem document with a
given status and `code`. All four already exist in this file and are used by the surrounding
scenarios; `assertProblem` is used, for example, at line 798.

**1.6** Register the scenario. The `tests` function (line 1223) takes its environments as
*positional* parameters, so three things must change together, or it will not compile:

- its type signature gains one `IO (IORef World, Env)` argument,
- its parameter list gains the matching name (call it `freshSessionCheckEnv`),
- the call in `main` (line 461) passes the new value in the same position.

Put the new parameter immediately after `freshPermissionEnv` in all three places to keep the
ordering readable. Then add the case to the `testGroup` list:

```haskell
      testCase "sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route" $ do
        (r, e) <- freshSessionCheckEnv
        testWithApplication (pure (app e)) (scenarioSessionCheckMode r),
```

**1.7** Run it, and watch it fail.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal test shomei-servant-test
```

Expected — the new case fails because the server answered `200 OK` to a token whose session is
revoked, which is the bug:

```text
HTTP end-to-end (in-memory interpreters + in-test ES256 key)
  ...
  sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route: FAIL
    test/Main.hs:NNN:
    a revoked session on an authenticated route: status
    expected: 401
     but got: 200

The new test failed; all pre-existing tests passed.
```

If instead it *passes*, stop: either the knob was not actually applied to the env you built (check
that the `testCase` uses `freshSessionCheckEnv`, not `freshEnv`), or the revocation did not reach
the world the server is running on (check that the `IORef World` passed to `scenarioSessionCheckMode`
is the same one `mkEnvWith` was given). A test that passes before the fix proves nothing.

Copy the failing transcript into Surprises & Discoveries.

### Step 2 — The fix (M2)

**2.1** `shomei-servant/src/Shomei/Servant/Seam.hs`. Add `verifyRequestToken` to the export list,
delete the `verifier` field from `Env`, and add the function. You will need three new imports —
`Shomei.Domain.Token (AccessToken (..))`, `Shomei.Workflow qualified as Wf`, and `AuthError` is
already imported — and you should drop `TokenError` from the `Shomei.Error` import if nothing else
in the module uses it (the compiler's `-Wunused-imports` will tell you).

```haskell
-- | Verify a presented access token the way the seam's configuration says to.
--
-- This is the ONLY way the HTTP layer verifies a token, and it is derived rather than supplied:
-- 'runPorts' already interprets 'TokenVerifier', 'SessionStore' and 'Clock' (they are in
-- 'AppEffects'), which is exactly what 'Shomei.Workflow.verifyToken' needs. So the session check
-- that @sessionCheckMode = VerifyTokenAndSession@ asks for actually happens, against the same
-- stores the login and refresh workflows write to.
--
-- Under the default @VerifyTokenOnly@ the workflow returns straight after the JWT check and
-- issues no query, so this costs no database round trip; under @VerifyTokenAndSession@ it costs
-- exactly one session SELECT per authenticated request, which is the trade the knob exists to
-- make.
--
-- There is deliberately no @verifier@ field on 'Env' for an assembly to supply. Before plan 49
-- there was, and every assembly filled it with the session-blind JWT verifier, which is why the
-- knob was a no-op on every authenticated route.
verifyRequestToken :: Env -> Text -> IO (Either AuthError AuthClaims)
verifyRequestToken env raw = runPorts env (Wf.verifyToken (config env) (AccessToken raw))
```

**2.2** `shomei-servant/src/Shomei/Servant/Auth.hs`. Import
`Shomei.Servant.Seam (Env (..), verifyRequestToken)` and change both authentication entry points
to receive that environment directly:

```haskell
authHandler :: Env -> AuthHandler Request AuthUser
authHandler env = mkAuthHandler handle
  where
    policy = cookiePolicyFromConfig env.config
    verify = verifyRequestToken env
    -- existing handle body, with the Left branch changed below

resolveAuthUser ::
  Env ->
  Maybe Text ->   -- Authorization header
  Maybe Text ->   -- Cookie header
  IO (Maybe AuthUser)
resolveAuthUser env mAuthorization mCookie =
  case extractTokenFromHeaders policy.transport mAuthorization mCookie of
    Nothing -> pure Nothing
    Just (_source, tok) ->
      either (const Nothing) (Just . authUserFromClaims) <$> verifyRequestToken env tok
  where
    policy = cookiePolicyFromConfig env.config
```

This module direction is acyclic: `Shomei.Servant.Seam` imports `Shomei.Servant.Error`, but it
does not import `Shomei.Servant.Auth`. Drop the now-unused `TokenError` import, import
`AuthError (..)` instead, import `pcSessionExpired` and `pcSessionRevoked` from
`Shomei.Servant.Error`, and give the handler its own error mapping:

```haskell
-- | How an authentication failure becomes an HTTP response.
--
-- Deliberately NOT 'Shomei.Servant.Error.authErrorToServerError': that is the handler-layer
-- mapping, and it maps 'SessionNotFound' to a 404. A 404 from an auth handler would make a
-- protected route look as though it does not exist.
--
-- 'SessionExpired' and 'SessionRevoked' are surfaced rather than collapsed, because they are
-- actionable ("log in again") and leak nothing: the caller is holding the token, so they learn
-- nothing about it they could not already infer. Everything else -- a bad signature, a garbage
-- token, and a @sid@ that resolves to no session row at all (indistinguishable from a forged one)
-- -- is the undifferentiated @401 token_invalid@, and the fallback is total so that a future
-- 'AuthError' constructor fails closed.
authFailure :: AuthError -> ServerError
authFailure = \case
  SessionExpired -> toProblemError pcSessionExpired Nothing
  SessionRevoked -> toProblemError pcSessionRevoked Nothing
  _ -> toProblemError pcTokenInvalidAuth Nothing
```

In `authHandler`'s `handle`, replace
`Left _ -> throwError (toProblemError pcTokenInvalidAuth Nothing)` with
`Left e -> throwError (authFailure e)`.

`resolveAuthUser` still discards the `Left`, which is the correct behavior for
`/oauth/authorize`: a revoked session means "not logged in", so the browser gets redirected to
the login page rather than an error. The important change is that it no longer receives a
caller-selected policy or verifier.

**2.3** `shomei-servant/src/Shomei/Servant/Handlers.hs`, line ~396. Pass the environment directly:

```haskell
  mUser <- liftIO (resolveAuthUser env mAuthHeader mCookie)
```

Remove `cookiePolicyFromConfig` from this module's `Shomei.Servant.Auth` import; this is its only
use. No qualified seam import is needed here.

**2.4** `shomei-server/src/Shomei/Server/Boot.hs`. In `authContext` (line ~370):

```haskell
authContext :: Seam.Env -> Context '[AuthHandler Request AuthUser, ErrorFormatters]
authContext senv =
  authHandler senv
    :. shomeiErrorFormatters
    :. EmptyContext
```

In `seamEnv` (line ~384), delete the whole `Seam.verifier = …` field, including its `readIORef`.
Then delete `import Shomei.Jwt.Verify (verifyToken)` at line 50 **if** nothing else in the module
uses it (the compiler will warn), and remove `cookiePolicyFromConfig` from the
`Shomei.Servant.Auth` import. Note that `jwksJson` keeps its `readIORef` — that one is still needed,
and key rotation for *verification* is now handled by `runPorts`/`runAppIO`, which re-reads
`envKeys` on every invocation.

**2.5** `shomei-servant/test/Main.hs`. In `mkEnvWith` (line ~375) delete the
`verifier = verifyToken jwkset cfg',` line, and in `app` (line ~194) replace the two-argument
`authHandler` call with `authHandler env`. Remove `cookiePolicyFromConfig` from the Auth import.
The
`import Shomei.Jwt.Verify (runTokenVerifierJwt, verifyToken)` at line 126 keeps
`runTokenVerifierJwt` (the hybrid runner still needs it) but can drop `verifyToken`.

**2.6** Build and re-run.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal build all
nix develop --command cabal test shomei-servant-test
```

Expected — the case from step 1.7 has flipped:

```text
HTTP end-to-end (in-memory interpreters + in-test ES256 key)
  ...
  status codes: signup 201, lifecycle requests still 202, logout idempotent (204/204): OK
  ...
  sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route: OK

All tests passed
```

Note that `logout idempotent (204/204)` must still be `OK`. It runs under the default mode, which
we did not change. If it broke, you changed the default — undo that (D5).

Copy this transcript into Surprises & Discoveries next to the failing one. The pair — same test,
red before, green after — is the evidence that this plan did what it claims.

### Step 3 — Extend coverage and guard the default (M3)

**3.1** Extend `scenarioSessionCheckMode` (the function from step 1.5) to cover the authorization
combinators. The revoked token must be refused *before* the role/scope/permission check runs, so
the answer is `401 session_revoked`, not `403 missing_role`. Append to the scenario:

```haskell
  -- The authorization combinators run the very same AuthHandler (Shomei.Servant.Authz's
  -- 'authorizedCheck' calls it through 'unAuthHandler'), so the revoked session must stop the
  -- request BEFORE the role/scope/permission predicate is ever consulted: 401, not 403.
  roleR <- getRaw mgr port "/admin/users" (bearer access)
  assertProblem "a revoked session on a RequireRole route" 401 "session_revoked" roleR
  scopeR <- getRaw mgr port "/ingest" (bearer access)
  assertProblem "a revoked session on a RequireScope route" 401 "session_revoked" scopeR
  permR <- getRaw mgr port "/host/projects" (bearer access)
  assertProblem "a revoked session on a RequirePermission route" 401 "session_revoked" permR
```

Those three paths are the host routes already mounted on `TestAPI` at line 170; their handlers
contain no authorization code, so a `401` here can only have come from the auth handler.

**3.2** Cover the `/oauth/authorize` path, which authenticates through `resolveAuthUser` rather
than the combinator. This one needs an OIDC-enabled env with a registered client, so it is a
*separate* scenario built on `freshAuthorizeEnv` (line ~433) with `sessionCheckMode` turned on.
Model it on the existing `scenarioAuthorizeIssuesCode` (registered at line ~1284): authenticate,
confirm `/oauth/authorize` issues a code for a live session, then revoke the session out of band
and confirm the *same* token no longer authenticates — the endpoint must treat the caller as
anonymous (redirecting to the configured `loginUrl`, or answering `401 login_required` when none
is configured — see the branch at `Handlers.hs` lines ~398–401) and must **not** mint a code.

**3.3** Add the regression guard for the default mode. This is the tripwire that keeps us honest
about D3 and D5:

```haskell
-- | The DEFAULT mode must not have grown a database read.
--
-- Under 'VerifyTokenOnly' (the default every existing deployment inherits), the auth handler must
-- not consult the session store at all. We prove that behaviorally: revoke the session out of
-- band, and the still-unexpired access token must STILL be accepted. If some refactor ever routes
-- the default mode through the session store, this returns 401 and this test goes red -- which is
-- exactly the alarm we want, because it would mean we had silently imposed a per-request SELECT on
-- every deployment.
--
-- (This is also the property the idempotent-logout scenario quietly depends on.)
scenarioDefaultModeIgnoresSessionStore :: IORef World -> Int -> IO ()
scenarioDefaultModeIgnoresSessionStore ref port = do
  mgr <- newManager defaultManagerSettings
  let email = "defaultmode@example.com" :: Text
      pw = "correct horse battery staple" :: Text
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= email, "password" .= pw, "displayName" .= ("D" :: Text)])
  sStatus @?= 201
  sresp <- must "signup body" sBody
  uid <- must "signup userId" (dig ["user", "userId"] sresp >>= asText)
  access <- must "signup accessToken" (dig ["token", "accessToken"] sresp >>= asText)

  revokeAllSessionsOf ref uid

  -- Still 200: the default mode is stateless, by design.
  (afterStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer access)
  afterStatus @?= 200
```

Register it with an env built from the *plain* `cfg` (a `freshAdminEnv`-shaped helper returning
the World ref will do; do **not** use `freshSessionCheckEnv`).

**3.4** Run the three suites.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal test shomei-servant-test
nix develop --command cabal test shomei-core-test
nix develop --command cabal test shomei-servant-openapi-test
```

All green. `shomei-core-test` should be unaffected (we did not change `shomei-core`), and its
existing `verifyToken (token+session) rejects an expired session` case at
`shomei-core/test/Shomei/WorkflowSpec.hs` line 217 keeps passing — it always did; the workflow was
never the broken part.

### Step 4 — Docs, OpenAPI, and the sweep (M4)

**4.1** `shomei-servant/src/Shomei/Servant/OpenApi.hs`, `baselineSpecs` (line ~536). A secured
operation can now answer two more `401`s:

```haskell
baselineSpecs :: O.Operation -> [ProblemSpec]
baselineSpecs op =
  [spec | not (null (op ^. O.security)), spec <- [pcMissingToken, pcTokenInvalidAuth, pcSessionExpired, pcSessionRevoked]]
    <> [pcBodyParseError | has (O.requestBody . _Just) op]
```

`pcSessionExpired` is already imported in that module (line 119); add `pcSessionRevoked` to the
import list. Both are already members of `problemCatalog`, so the conformance suite's
"documented `(status, code)` pairs ⊆ catalog pairs" check passes.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal test shomei-servant-openapi-test
```

**4.2** `CHANGELOG.md`, under `## Unreleased`. Add the following (adjust the heading style to match
the surrounding entries). The outer fence below is four backticks because the entry itself contains
fenced Haskell blocks — copy the *contents*, not the outer fence:

````markdown
### Fixed — security: `sessionCheckMode = VerifyTokenAndSession` was a no-op on authenticated routes

`sessionCheckMode = VerifyTokenAndSession` is documented to re-read the session on every request,
so that revoking a session or suspending a user takes effect **immediately** rather than when the
outstanding access token expires. It did not. `Shomei.Workflow.verifyToken` — the only function
that reads the setting — had no callers: every assembly wired the auth handler to the pure,
session-blind JWT verifier from `Shomei.Jwt.Verify`. Setting the knob changed no behavior on any
route guarded by `Authenticated`, `RequireRole`, `RequireScope`, or `RequirePermission`, nor on
`GET /oauth/authorize`. The advertised mitigation for a compromised or suspended account did not
exist.

The HTTP layer now verifies through `Shomei.Workflow.verifyToken`, so the setting does what it
says. With it enabled, a request bearing an access token whose session has been revoked or has
expired is refused with `401 session_revoked` / `401 session_expired` (previously it was accepted;
an unresolvable `sid` remains the undifferentiated `401 token_invalid`).

Blast radius of the bug, stated precisely: it affected **outstanding access tokens on protected
routes, for at most one access-token TTL** (15 minutes by default). It did **not** affect
`refresh`, which has always enforced session status and expiry — a revoked session could never be
*extended* — nor `POST /oauth/introspect`, which has always consulted the session store regardless
of the setting. `VerifyTokenOnly` remains the default, and is unchanged: it still performs no
session lookup.

Two consequences for deployments that enable `VerifyTokenAndSession`:

- It now costs **one session `SELECT` per authenticated request** — that is the trade the setting
  exists to make. Watch `SHOMEI_DB_POOL_SIZE` (default 10) under load.
- HTTP logout is **no longer idempotent** under this mode. A second `POST /v1/auth/logout` with the
  same access token is refused with `401 session_revoked` by the auth handler instead of returning
  `204`, because the credential genuinely is dead. Under the default `VerifyTokenOnly` logout
  remains idempotent.

### Changed (breaking) — `Shomei.Servant.Seam.Env.verifier` removed

The `verifier` field is gone. It was redundant — `Env.runPorts` already interprets `TokenVerifier`,
`SessionStore` and `Clock` — and its existence is what allowed the HTTP layer to verify tokens
through a code path that could not see the session store. Verification is now *derived*:

```haskell
Shomei.Servant.Seam.verifyRequestToken :: Env -> Text -> IO (Either AuthError AuthClaims)
```

`Shomei.Servant.Auth.authHandler` and `Shomei.Servant.Auth.resolveAuthUser` now take `Seam.Env`
directly and invoke the derived verifier internally. This prevents an embedding host from
accidentally wiring Shōmei's own auth handler to a session-blind verifier.

**Migration for embedding hosts.** Delete the `verifier = …` line from your `Seam.Env`
construction, and pass the environment directly when building your Servant context:

```haskell
-- before
authHandler (cookiePolicyFromConfig env.config) env.verifier
-- after
authHandler env
```

No other change is required: because the verifier is derived from your `runPorts`, an embedded host
gets the session check automatically, provided (as it already must) that its `runPorts` interprets
`SessionStore` against the same store the login and refresh workflows write to.
````

**4.3** `shomei-core/src/Shomei/Workflow/Admin.hs`, the Haddock at line ~51. It is *becoming true*
rather than being corrected (see M4's narrative). Make it useful:

```haskell
-- | Suspend an active user and kill their sessions.
--
-- Their outstanding /access/ tokens still ride out their short TTL under the default
-- @sessionCheckMode = VerifyTokenOnly@, which verifies a token statelessly. A deployment that
-- cannot tolerate that window sets @sessionCheckMode = VerifyTokenAndSession@: the HTTP auth
-- handler then re-reads the session on every request (through 'Shomei.Workflow.verifyToken'), and
-- a suspended user's next request is refused with @401 session_revoked@ — at the cost of one
-- session SELECT per authenticated request.
--
-- The refresh path is closed immediately either way, so under the default the blast radius is one
-- access-token lifetime.
```

**4.4** `shomei-servant/src/Shomei/Servant/Handlers.hs`, the `/oauth/revoke` caveat at line ~787
("documented caveat: a stateless verifier keeps accepting the access token…"). Qualify it: that is
true under the default mode, and *not* true under `VerifyTokenAndSession`, where the auth handler
now rejects it on the next request.

**4.5** `shomei-servant/src/Shomei/Servant/Auth.hs` lines 14–16 and the `Shomei.Servant.Seam`
module header (lines 1–10). Both describe the plumbing we just deleted — a `verifier` field of
type `Text -> IO (Either TokenError AuthClaims)` built from `verifyToken jwks config`. Rewrite
them to describe `verifyRequestToken` and to say, in one sentence, that the session check happens
here and is governed by `sessionCheckMode`.

**4.6** The sweep. Find anything else that describes the auth handler as stateless or the knob as
unimplemented:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
rg -ni 'sessionCheckMode|stateless verifier|cannot revoke access before the token expires' \
  shomei-core shomei-servant shomei-server shomei-client docs README.md CHANGELOG.md \
  --glob '*.hs' --glob '*.md'
```

Read every hit and make it true. Pay particular attention to `docs/user/security.md` (the
revocation-latency boundary) and to `shomei-servant/src/Shomei/Servant/Authz.hs` lines 26–29,
which say the combinators "cannot revoke access before the token expires" — true under the
default, but now qualifiable.

**4.7** The `shomei-docs` repository (a *separate* checkout; **do not edit it from this plan**)
carries eight user-facing pages that mention `sessionCheckMode` or `VerifyTokenAndSession`. Plan
validation located it through `mori registry show shinzui/shomei-docs --full` and recorded the
eight paths in Outcomes & Retrospective. Re-run the scoped search when implementing in case that
repository has changed, then leave the actual edits for its own follow-up plan.

### Step 5 — Wrap up

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal build all
nix develop --command cabal test all
```

Then fill in Outcomes & Retrospective. Do not commit unless you were asked to.


## Validation and Acceptance

Everything below is run from `/Users/shinzui/Keikaku/bokuno/shomei` inside the Nix dev shell.

### The acceptance test — the one that matters

The single fact this plan must establish is: **with `sessionCheckMode = VerifyTokenAndSession`, a
revoked session's still-unexpired access token is refused on an authenticated route.** It is
established by one test case, and it is established *only* if you watched it fail first.

Before the fix (after M1, before M2):

```bash
nix develop --command cabal test shomei-servant-test
```

```text
sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route: FAIL
  test/Main.hs:NNN:
  a revoked session on an authenticated route: status
  expected: 401
   but got: 200
```

After the fix (after M2):

```text
sessionCheckMode=VerifyTokenAndSession: a revoked session is refused on an authenticated route: OK
```

If you never see the `FAIL`, the test is not testing what you think it is. Go back to step 1.7's
troubleshooting notes.

### The full suite

```bash
nix develop --command cabal build all
nix develop --command cabal test shomei-servant-test
nix develop --command cabal test shomei-core-test
nix develop --command cabal test shomei-servant-openapi-test
nix develop --command cabal test shomei-server-test
```

`shomei-server-test` and the other PostgreSQL-backed suites spin up an ephemeral PostgreSQL
instance. If they hang or fail on database startup contention, restrict their parallelism:

```bash
nix develop --command cabal test shomei-server-test --test-options='-j2'
```

What each suite is telling you:

- **`shomei-servant-test`** is the primary evidence. Both the new session-check scenario *and* the
  new default-mode regression guard live here, as does `scenarioStatusCodes` (double logout →
  `204`/`204`), which must remain green and is your proof that the default mode's semantics did not
  move.
- **`shomei-core-test`** should be untouched — no `shomei-core` source changes. Its
  `verifyToken (token+session) rejects an expired session` case
  (`shomei-core/test/Shomei/WorkflowSpec.hs` line 217) passed before this plan and passes after:
  the workflow was always correct, it just had no caller.
- **`shomei-servant-openapi-test`** guards the `baselineSpecs` change. It asserts that every
  `(status, code)` pair the OpenAPI document advertises exists in `Shomei.Servant.Error.problemCatalog`.
  Since `session_expired` and `session_revoked` are already catalog members at `401`, adding them to
  the secured-route baseline is safe; if this suite goes red, you added a spec that is not in the
  catalog.
- **`shomei-server-test`** exercises the standalone binary against a real database. It proves the
  `Boot.hs` rewiring compiles and serves.

### Behavior a human can verify by hand

Beyond the tests, the change is observable on the real server. Start the standalone server with the
knob on, sign up, revoke, and watch the same token flip from `200` to `401`:

```bash
export SHOMEI_SESSION_CHECK=token-and-session
# ...plus the usual SHOMEI_DATABASE_URL / key configuration; see docs/user/configuration.md
nix develop --command cabal run shomei-server
```

```bash
# 1. Sign up; keep the access token.
curl -s -X POST localhost:8080/v1/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"email":"demo@example.com","password":"correct horse battery staple","displayName":"Demo"}'
# -> 201, {"user":{"userId":"..."},"token":{"accessToken":"eyJ..."}}

# 2. The token works.
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/v1/auth/me -H "Authorization: Bearer $ACCESS"
# -> 200

# 3. Revoke every session for the user with an already-provisioned administrator token.
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE \
  "localhost:8080/v1/admin/users/$USER_ID/sessions" \
  -H "Authorization: Bearer $ADMIN_ACCESS"
# -> 204

# 4. The SAME, still-unexpired token, immediately:
curl -s localhost:8080/v1/auth/me -H "Authorization: Bearer $ACCESS"
# BEFORE this plan: 200 OK, with the user's profile. For up to 15 more minutes.
# AFTER  this plan: 401
#   {"type":"...","title":"Session revoked","status":401,"code":"session_revoked"}
```

Then unset `SHOMEI_SESSION_CHECK` (returning to the default `token-only`), repeat, and observe
that step 4 answers `200` — the default is unchanged, stateless, and costs no database read. That
contrast, seen by hand, is the whole feature.


## Idempotence and Recovery

Every step of this plan is safe to repeat. There are no migrations, no destructive operations, and
no data touched: the change is confined to Haskell source, a test file, the CHANGELOG, and
comments. The only state involved is the build cache.

- **Re-running any `cabal build` or `cabal test` command is free.** They are pure functions of the
  working tree.
- **A failed or partial milestone is recoverable with `git`.** Nothing here is committed for you.
  `git diff` shows exactly what you have changed; `git checkout -- <path>` reverts a single file;
  `git stash` parks everything. Because M1 is test-only and M2 is source-only, they can be
  reverted independently.
- **If M2 leaves the tree not compiling**, the most likely cause is a missed `verifier` reference:
  the field was read in four places (`Boot.hs` `authContext`, `Boot.hs` `seamEnv`, `Handlers.hs`
  `resolveAuthUser`, `test/Main.hs` `app` + `mkEnvWith`). Find any survivors with
  `rg -n '\.verifier|verifier =' shomei-servant shomei-server examples --glob '*.hs'`,
  ignoring the many unrelated hits for PKCE's `code_verifier`.
- **If the build cache misbehaves** (stale interface files after a record-field removal),
  `nix develop --command cabal clean` followed by `nix develop --command cabal build all` resets
  it. This costs a full rebuild but is otherwise harmless.
- **If the ephemeral-PostgreSQL suites are flaky**, that is environmental, not caused by this
  change (this plan adds no database code). Re-run with `--test-options='-j2'`.
- **Rolling back the whole plan** is `git checkout -- .` from a clean starting point. The fix is
  additive and localized; there is no half-applied state that leaves the system worse than it
  started. Note, though, that rolling back restores the vulnerability.


## Interfaces and Dependencies

No new package dependencies are introduced. Every module and function used already exists in the
workspace; the fix is a rewiring, not a new capability.

### Existing interfaces this plan consumes unchanged

- **`Shomei.Workflow.verifyToken`** (`shomei-core/src/Shomei/Workflow.hs`, line 450) — the fix's
  entire mechanism. Reused exactly as it stands (D8):

  ```haskell
  verifyToken ::
    (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
    ShomeiConfig ->
    AccessToken ->
    Eff es (Either AuthError AuthClaims)
  ```

- **`Shomei.Servant.Seam.AppEffects`** (`shomei-servant/src/Shomei/Servant/Seam.hs`, line 62) —
  already contains `SessionStore`, `Clock`, and `TokenVerifier`, which is why no effect-stack
  change is needed anywhere.
- **`Shomei.Effect.SessionStore.revokeAllUserSessions :: UserId -> UTCTime -> Eff es ()`** — used
  by the tests to revoke out of band, and the same operation `Shomei.Workflow.Admin.suspendUser`
  calls.
- **`Shomei.Servant.Error.pcSessionExpired`** and **`pcSessionRevoked`**
  (`shomei-servant/src/Shomei/Servant/Error.hs`, lines 252–253) — both already `401`, both already
  in `problemCatalog`. No new problem code is created by this plan.
- **`Shomei.Domain.Token.AccessToken`** — the newtype the workflow takes.

### Interfaces that must exist at the end of M2

```haskell
-- shomei-servant/src/Shomei/Servant/Seam.hs (NEW, exported)
verifyRequestToken :: Env -> Text -> IO (Either AuthError AuthClaims)

-- shomei-servant/src/Shomei/Servant/Seam.hs (CHANGED — the `verifier` field is GONE)
data Env = Env
  { runPorts :: !(forall a. Eff AppEffects a -> IO a),
    config :: !ShomeiConfig,
    jwksJson :: !(IO Value),
    accountKeyOf :: !(Text -> AccountKey)
  }

-- shomei-servant/src/Shomei/Servant/Auth.hs (CHANGED — derives policy and verification from Env)
authHandler :: Env -> AuthHandler Request AuthUser

resolveAuthUser ::
  Env ->
  Maybe Text ->   -- the Authorization header
  Maybe Text ->   -- the Cookie header
  IO (Maybe AuthUser)

-- shomei-servant/src/Shomei/Servant/Auth.hs (NEW, module-private)
authFailure :: AuthError -> ServerError
```

`Shomei.Servant.Seam` gains imports of `Shomei.Domain.Token (AccessToken (..))` and
`Shomei.Workflow qualified as Wf`. There is no import cycle: `Shomei.Workflow` lives in
`shomei-core`, which `shomei-servant` already depends on (`Shomei.Servant.Handlers` imports it at
line 168). `Shomei.Servant.Auth` now imports `Shomei.Servant.Seam`, but the seam does not import
Auth (it imports only `Shomei.Servant.Error` from the HTTP package), so that direction is acyclic.

### Interfaces that must exist at the end of M4

```haskell
-- shomei-servant/src/Shomei/Servant/OpenApi.hs (CHANGED)
baselineSpecs :: O.Operation -> [ProblemSpec]
-- now yields [pcMissingToken, pcTokenInvalidAuth, pcSessionExpired, pcSessionRevoked]
-- for any operation carrying a security requirement.
```

### Downstream consumers this plan breaks (deliberately, and loudly)

Any code constructing a `Shomei.Servant.Seam.Env` or calling
`Shomei.Servant.Auth.authHandler` / `resolveAuthUser`. Inside this repository the affected
references are `shomei-server/src/Shomei/Server/Boot.hs` (`authContext` and `seamEnv`),
`shomei-servant/src/Shomei/Servant/Handlers.hs` (`resolveAuthUser`), and
`shomei-servant/test/Main.hs` (`app` and `mkEnvWith`).
The two applications under `examples/` do not construct a `Seam.Env` and are unaffected — verify
this with the grep in Idempotence and Recovery rather than taking it on faith.

Outside this repository, embedding hosts break at compile time with an error naming a field that no
longer exists. That is the intended design (D1): a security fix that an embedder can accidentally
*not* adopt is not a fix. The migration is two lines and is in the CHANGELOG.


## Revision Note — 2026-07-11

Validated the bug against the current working tree rather than relying on the plan's static
argument. Recorded the successful baseline build and a read-only GHCi reproduction in which
`Shomei.Workflow.verifyToken` returned `SessionRevoked` while `GET /v1/auth/me` returned `200` for
the same revoked session. Revised the fix so `authHandler` and `resolveAuthUser` accept `Seam.Env`
directly, closing the embedder misassembly hole left by the original arbitrary-verifier signature.
Corrected `SHOMEI_SESSION_CHECK`, the admin session-revocation method, the unsupported admin-CLI
example, and exact test-count assertions throughout the plan. These changes were made because the
reported behavior is a confirmed security bug, but the first draft's proposed public API and
operational examples were not yet safe or accurate enough to implement verbatim.
