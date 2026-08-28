---
id: 59
slug: embedding-parity-and-a-trustworthy-downstream-verification-template
title: "Embedding Parity and a Trustworthy Downstream Verification Template"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Embedding Parity and a Trustworthy Downstream Verification Template

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This is **EP-9** (Phase 3) of
[MasterPlan 8](../masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md).
No hard dependencies; soft dependencies EP-3 (`docs/plans/53-…`, the verifier the template inherits), EP-7
(`docs/plans/57-…`, the notifier worker), EP-8 (`docs/plans/58-…`, the proxy-aware middleware); every
"if 53/57/58 has not landed" note below says what to do either way, so nothing waits on them.


## Purpose / Big Picture

Shōmei runs two ways: as the standalone `shomei-server` binary, or *embedded* — a host Servant
application mounts Shōmei's route tree inside its own. The August 2026 review found the second way
silently loses what the first promises: `Shomei.Server.Boot.main` installs the signing-key reload, the
sweeper, the request-body cap, the per-IP rate limiter, logging, metrics, and the `defaultRoles` boot
check, while `Shomei.Server.Boot.application`, which both embedded examples build on, is a bare
`serveWithContext` — so an embedded host trusts a revoked signing key until it restarts, buffers
unbounded bodies, and advertises `429`s it can never produce. The review also found that the downstream
verification template — the file every resource service is told to copy — builds an HTTP manager that
cannot speak TLS, so an `https://` JWKS URL fails every fetch and plaintext, a token-forgery vector, is
the only working option.

After this plan a host calls two exported functions and gets exactly the standalone server's runtime
protections; both embedded examples do so and a test shows a revoked key refused after `SIGHUP`; the
template fetches over TLS, clamps a publisher's `max-age` to its own staleness bound, refreshes once
(rate-capped) when a token names a key it does not hold, answers `401` with `WWW-Authenticate: Bearer`,
and its README's en recipe authenticates against en's real API-key middleware; every runbook boots.


## Progress

- [x] (2026-08-27 18:43 PDT) M1: reproduced `TlsNotSupported` and captured the embedded before-state — after database rotation/revocation, the stale in-memory key still accepted the old token with `200`
- [x] (2026-08-27 18:38 PDT) M1: `installHostBackgroundTasks` and `hostMiddleware` exported from `Shomei.Server.Boot`; `main` uses exactly them plus `application`; MiddlewareSpec pins the edge order
- [x] (2026-08-27 18:43 PDT) M2: both embedded examples call the contract; `act` logged in both; grant route is `RequireRole "admin"` with a `subject`; revoked-key-after-SIGHUP test passes (2 cases)
- [x] (2026-08-27 18:51 PDT) M3: scheme-selected TLS manager; hard staleness cap; `max-age=0` ignored; unknown-key refresh capped and retried once; Bearer challenge; lenient decoding; all 11 tests pass
- [x] (2026-08-27 18:56 PDT) M4: socket connection string inherited; KEK in every runbook; en example drops the hs-jose pin, mirrors the constraint, pins en `bf8ffa24`, adds `ReadRelationshipPage`; CI/`just` build it; README §4 rewritten; `www/README.md` link
- [x] (2026-08-27 19:00 PDT) M5: embedding checklist in `client-and-examples.md` and `architecture.md`; `Cache-Control` paragraph; plaintext warning; ADR-17 and ADR-18 written, indexed, and strictly validated
- [x] (2026-08-27 19:00 PDT) Outcomes & Retrospective written; MasterPlan 8 registry row set to Complete


## Surprises & Discoveries

Found while planning (2026-08-27, HEAD `5dfd2a6`, code identical to `ee00382`):

- en HEAD `bf8ffa24` ships `En.Store.InMemory` (`newInMemoryWorld`, `runInMemoryStores`) — the mutable
  store plan 47's External Companion Work said the example should adopt once it existed — and `en-core`
  now depends on `relay-pagination >=0.1 && <0.2` (Hackage 0.1.1.0), `generic-lens ^>=2.3`, `lens ^>=5.3`
  (no new git pins, but "only effectful/containers/text/time" is no longer true).
- `examples/embedded-servant-app` has no top-level README (its runbook is
  `docs/user/client-and-examples.md:54-58` plus `www/README.md`); the root `process-compose.yaml` never
  sets `SHOMEI_KEY_ENCRYPTION_KEY` either (`docs/plans/60-…`'s file). Shōmei's own `401` already carries
  `WWW-Authenticate: Bearer` (`Shomei/Servant/Error.hs:280-281`); only the template's handler omits it.
  The `admin` role is seeded by migration `0021`, so `roles grant --role admin` needs no `roles define`.

(Implementation discoveries go here, with evidence.)

- The pre-fix downstream manager failed exactly as reviewed. From `cabal repl
  lib:microservice-auth-stack`, `currentJwks` against Google's HTTPS JWKS raised:

  ```text
  JwksUnavailable "initial JWKS fetch failed: TlsNotSupported"
  ```

- EP-7 and EP-6 made a cleanup-less `IO ()` installer unsafe: the notifier must drain and its
  thread must stop, while the sweeper owns a separate pool that must be released. The implemented
  `HostBackgroundTasks` handle preserves both obligations. The focused middleware test then proved
  the promised edge order: 100 oversized requests were `413` with `X-Request-Id`, followed by 60
  small `200` responses and one `429`.

- The embedded regression test made the stale-key seam observable without a timing-dependent
  90-second process transcript. After atomic key replacement and revocation in PostgreSQL, the old
  access token remained `200` against the unchanged `IORef`; installing the host tasks and raising
  `SIGHUP` changed it to `401` within the three-second poll window. Both embedded tests passed.

- The separate `embedded-with-en` project cannot solve at its old pins: its `sumo/hs-jose` source
  requires `ram <0.22`, while current `shomei-core` requires `ram >=0.22 && <0.23`. This is the
  exact stale pin Milestone 4 removes, so the example source changes are retained and its full
  compile gate remains attached to that milestone.

- Mori located `http-client-tls` in `snoyberg/http-client`; its source confirms
  `newTlsManager :: MonadIO m => m Manager`. Hackage's current release is 0.3.6.4 while upstream
  also carries a 0.4.0 tag, so the example uses `>=0.3.6.4 && <0.5` rather than freezing the local
  corpus version. The first post-fix suite passed all 11 cases; moving the TLS negative probe from
  a plaintext listener to a refused loopback port reduced that case from 30 seconds to immediate
  failure without weakening its `TlsNotSupported` assertion.

- The hardened verifier from EP-3 already distinguishes an absent `kid` selection as
  `TokenKeyNotFound`. Matching that constructor kept the refresh trigger narrow: ordinary malformed
  or bad-signature tokens remain pure `401`s and cannot spend the network refresh budget.

- Updating the en pin exposed both sides of the intended compatibility gate: the stale `hs-jose`
  source pin made the solver fail on `ram`, while removing it and mirroring the root X.509 floor let
  `cabal build` compile en HEAD `bf8ffa24`, the new `ReadRelationshipPage` interpreter arm, and the
  embedded executable. The root `just build-embedded-with-en` recipe is therefore a real independent
  project build, not merely a root-workspace no-op.


## Decision Log

- Decision: `application` stays bare. A host that mounts `ShomeiRoutes` in its own tree serves that tree
  with `authContext` and wraps the *whole* host app with `hostMiddleware`.
  Rationale: the stack must be outermost to log, meter, and refuse (`413`/`429`) the host's own routes;
  baking it into `application` would double-wrap such hosts. `E2ESpec` and `test-health` are unchanged.
  Date: 2026-08-27
- Decision: export the two functions from `Shomei.Server.Boot`, not a new module; `hostMiddleware`
  takes `ServerSettings` though nothing reads it today.
  Rationale: Integration Point 8 names `Boot.hs` as the file EP-7 and EP-8 also edit; EP-8's proxy settings then change a body, not the contract.
  Date: 2026-08-27
- Decision: unknown-key refresh policy. On EP-3's `TokenKeyNotFound`, when the cached entry is at
  least `unknownKeyMinAge` (5 s) old and no
  unknown-key refresh ran within `unknownKeyRefreshInterval` (30 s), the handler runs one synchronous
  single-flight refresh and retries verification once; otherwise `401` at once. The interval slot is
  claimed with `atomicModifyIORef'` before the lock, so N unknown or forged keys cause ≤ 1 fetch per interval.
  Rationale: closes REV-10 finding 3's post-rotation window while keeping "no kid-triggered storms"
  a tested property; arbitrary unknown key identifiers are still attacker-controlled, hence the cap.
  Date: 2026-08-27
- Decision: `max-age` is clamped to `maxStaleness`; `max-age=0` or negative reads as "no header".
  Rationale: "do not cache" would mean a fetch per request (REV-10 finding 2's loop); the configured TTL is the operator's policy.
  Date: 2026-08-27
- Decision: bump `examples/embedded-with-en/cabal.project` to en `bf8ffa24b33de328ed7c6b19f02e9e3ad035d57f`
  and keep `runTupleStoreIORef`, adding the one new arm, rather than switch to `En.Store.InMemory`.
  Rationale: the bump closes the drift finding; the store switch changes the README transcript and the
  `mkEnEnv` story for no security value. Follow-up in Outcomes.
  Date: 2026-08-27
- Decision: `POST /demo/grants` becomes `RequireRole "admin"` and grants a caller-named `subject`; the
  transcript is 403 → an administrator grants → 200 with the user's own token.
  Rationale: a route letting a caller grant itself access is the wrong shape to copy even when labelled
  non-production; a second token is the smallest honest demonstration of a separate trust boundary.
  Date: 2026-08-27
- Decision: the JWKS manager is scheme-selected as `shomei-client` does (`Https -> newTlsManager`,
  `Http -> defaultManagerSettings`) with one warning for plaintext to a non-loopback host.
  Rationale: `newTlsManager` alone serves both schemes but silently honours `https_proxy`.
  Date: 2026-08-27
- Decision: `docs/adr/` is created as a profile-governed OKF bundle on the shared
  `documentation.architectureDecisions` profile, following the `docs/reviews` precedent; whichever
  sibling lands first creates it, later ones allocate with `okf id next`.
  Rationale: `.claude/skills/exec-plan/ADR.md` and the MasterPlan require it.
  Date: 2026-08-27
- Decision: `installHostBackgroundTasks` returns a `HostBackgroundTasks` cleanup handle rather than
  `IO ()`; its `stopHostBackgroundTasks` drains the notifier within the caller's timeout and releases
  the sweeper pool.
  Rationale: EP-7 and EP-6 landed before EP-9 and introduced owned resources whose cleanup cannot be
  recovered from an `IO ()` result. Returning the handle keeps the two-function embedding contract
  while making bounded shutdown part of that contract rather than a standalone-only implementation detail.
  Date: 2026-08-27


## Outcomes & Retrospective

The standalone executable and embedding examples now consume one exported runtime contract. Hosts
install key reload, sweeping, default-role validation, and bounded notification delivery through a
cleanup-bearing `HostBackgroundTasks` handle, then wrap the whole application in the same proxy,
logging, metrics, metered-body, and rate-limit edge. The focused edge test proves oversized bodies do
not consume limiter capacity, and the embedded PostgreSQL test proves a revoked key changes from
accepted to refused after `SIGHUP` without restarting the host.

The downstream template now fetches HTTPS JWKS documents with a TLS manager, treats maximum
staleness as a hard local bound, ignores `max-age=0`, and performs one rate-capped single-flight
refresh and one retry only for `TokenKeyNotFound`. Its eleven tests cover transport, caching,
concurrency, hostile headers, and Bearer challenges. The example runbooks carry their KEK and socket
database assumptions explicitly; the en example compiles independently at verified upstream HEAD
`bf8ffa24`, and CI now exercises that separate build.

[ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md) records the embedding
contract, while [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md) records the
downstream transport, freshness, and unknown-key policy. The planned switch from the example's
transparent `IORef` interpreter to `En.Store.InMemory` remains deferred: it would change the teaching
surface and transcript without improving this trust boundary. A future en-focused example plan can
adopt it when persistent or conformance-oriented behavior is itself the goal.


## Context and Orientation

Shōmei is a Haskell authentication toolkit built with `cabal` on GHC 9.12.4 inside a Nix dev shell
(`nix develop`; `direnv` enters it); tests use an ephemeral PostgreSQL. Terms: a **WAI middleware** is a
function `Application -> Application` wrapping an HTTP handler; a **Servant context** is the record of
authentication handlers a route tree needs (`authContext`); a **JWKS** is the public-key document at
`/.well-known/jwks.json`; a **kid** is the key id in a JWT header; **single-flight** means at most one
fetch is in progress however many callers ask. The established `docs/adr/` bundle governs the
related strict-JWT, notifier-shutdown, and proxy-edge decisions in ADR-3, ADR-10, and ADR-15. This
plan adds ADR-17 and ADR-18 for the embedding and downstream-cache contracts.

**The standalone assembly**, `shomei-server/src/Shomei/Server/Boot.hs`. `main` (86-148) loads config,
builds `Env`, then at 101-105 calls `validateDefaultRoles cfg env`, `installKeyReload cfg env`,
`installSweeper settings env`, `newRateLimiter`, `newMetrics`; 114-122 build the stack
`stack = requestLoggingMiddleware obs . withMetrics . bodyLimitMiddleware defaultBodyLimitBytes . rateLimitMiddleware rl`
(the comment at 107-113 fixes that order); 127-143 install graceful shutdown and warp settings; 145 is
`Warp.runSettings warpSettings (stack (application env liveness readiness))`. `validateDefaultRoles`
(182-206) exits when `defaultRoles` names an undefined role; `installKeyReload` (219-226) forks a
supervised reload loop and installs a process-wide `SIGHUP` handler; `installSweeper` (235-276) forks
the sweeper; `application` (370-374) is
`problemMiddleware (serveWithContext shomeiRoutesApi (authContext senv) (shomeiRoutes senv liveness readiness))`.
`Shomei.Server.App.Env` (`App.hs:134-153`) holds the pool, config, the `IORef LoadedKeys` that
`reloadKeys` swaps, and the KEK. `Shomei.Servant.PreHandler:36-44` defines `RateLimited` and
`CsrfProtected` as pass-through markers: OpenAPI documentation, no enforcement.

**The embedded examples.** `examples/embedded-servant-app/src/Embedded/App.hs:62-66` serves `AppAPI`
with `serveWithContext (Proxy @AppAPI) (authContext senv) (…)`; `app/Main.hs:14-25` calls `buildEnv`,
`buildHealthChecks`, `Warp.run`. `examples/embedded-with-en` is the same plus en: `src/EmbeddedEn/App.hs:105`
is `Authenticated :> "demo" :> "grants" :> ReqBody '[JSON] GrantRequest :> Post '[JSON] GrantResponse`
and `grantHandler` (134-149) writes a tuple for the **caller's own** subject; `src/EmbeddedEn/Authz.hs`
maps a user to an en subject (`subjectForUser`, 92-94) and interprets en's `TupleStore` over an
`IORef [Tuple]` (`runTupleStoreIORef`, 170-244). Its own `cabal.project` (it is outside the root
workspace) pins `en-core` at `d3209cb` (line 41), still pins `sumo/hs-jose` (54-58) although the root
takes jose from Hackage, and lacks the root's `constraints: crypton-x509-validation >= 1.9.1`
(root `cabal.project:71-72`, CVE-2026-9648). At en HEAD `En.Effect.TupleStore` has 15 constructors,
the pin has 14; the new one (`en-core/src/En/Effect/TupleStore.hs:410`) is

```haskell
  ReadRelationshipPage :: Revision -> ConsistencyToken -> RelationshipFilter -> PageRequest -> TupleStore m (Either CursorError (Connection TupleRow))
```

(`PageRequest`, `CursorError`, `Connection` from `relay-pagination`). `En.Conformance.Kikan` still
exports every helper `Authz.hs` copies, and its `tupleRow` fills the `pageKey` field `TupleRow` gained,
so the existing `ProbeTuples` arm compiles unchanged.

**The downstream template**, `examples/microservice-auth-stack/src/Downstream/Service.hs`.
`app/Main.hs:34` builds `HTTP.newManager HTTP.defaultManagerSettings`; in http-client 0.7.19
(`Network/HTTP/Client/Manager.hs:68`) that manager's `managerTlsConnection` is `throwHttp TlsNotSupported`.
`currentJwks` (148-158) tests `age < 0.8 * effectiveTtl` first and only `refreshWindow` (181-197)
compares with `maxStaleness`; `mkEntry` (222-228) takes `effectiveTtl` verbatim from `parseMaxAge`
(267-278), which accepts `0`. Refresh is age-driven only: `Shomei.SigningKey.Verify.Jwt.verifyToken`
(77-91) hands jose the whole set, jose ignores `kid`, and a token signed by an unheld key maps to
`TokenSignatureInvalid` (119-122). `localAuthHandler` (315-327) uses the partial `Text.decodeUtf8` and
its `401`s carry no `WWW-Authenticate`. Shōmei's JWKS handler (`shomei-servant/src/Shomei/SigningKey/Handler.hs:19-20`)
sends `Cache-Control: public, max-age=300`, which `docs/user/client-and-examples.md:131-135` denies.
`test/Main.hs:129-213` holds the seven cache tests against a stub (219-251) with a fixed body. The README's §4 (145-157) says
en-server authenticates nobody "until plan 33 ships"; at en `bf8ffa24` plan 33 is complete:
`en-server/app/Middleware.hs:111-122` requires `Authorization: Bearer <secret>` (scheme case-insensitive,
constant-time) from `EN_API_KEYS_READ_WRITE` / `EN_API_KEYS_READ_ONLY` (`name:secret,…`, secrets ≥ 16
bytes; `EN_AUTH_DISABLED=true` for local dev only); read-only keys get `403` on writes; a missing key is
`401` with `WWW-Authenticate: Bearer` (en `docs/user/service-and-operations.md:672-685`). en decided
against verifying Shōmei JWTs ("shomei therefore stays an extension point, not a dependency", en plan 33).

**Runbooks.** `examples/microservice-auth-stack/process-compose.yaml:23` hard-codes `host=localhost port=5432`;
the dev PostgreSQL is socket-only (`docs/user/deployment.md:236-239`; plan 47's Surprises record the
trap). `SHOMEI_KEY_ENCRYPTION_KEY` is fatal when unset (`shomei-server/src/Shomei/Server/Keys.hs:82`) and
appears in no example runbook. `examples/embedded-servant-app/www/README.md:12` links
`../../../docs/passkeys.md`; the page is `docs/user/passkeys.md`.

**Integration points this plan respects** (MasterPlan 8, items 3, 6, 8, 10): this plan owns
`installHostBackgroundTasks`, `hostMiddleware`, and both embedded examples' use of them; EP-7's worker
and EP-8's middleware install through those two functions (landing later, they add to them; earlier,
this plan lifts their `Boot.main` additions verbatim). The template inherits EP-3's verifier through
`verifyToken` with no verifier code of its own, and the cache's five tested properties do not change.


## Plan of Work

### Milestone 1 — Reproduce, then export the embedding contract

Scope: observe both defects on unmodified code, then export the runtime stack. At the end `Boot.main`
is `installHostBackgroundTasks` plus `hostMiddleware` around `application` (with warp settings), and a
MiddlewareSpec case pins the order.

Observations first (commands and output in Concrete Steps; paste the transcripts into Surprises): (a) a
cache built as `app/Main.hs:34-35` does, against a public TLS JWKS, throws `JwksUnavailable "initial JWKS fetch failed: TlsNotSupported"`;
(b) after `shomei-admin` rotates and revokes the key under a running `embedded-servant-app`, `/projects`
with the old token is still `200` past the 60 s reload interval and the old `kid` is still published.

Then edit `Boot.hs`: add `installHostBackgroundTasks`, `hostMiddleware`, and `validateOidcIssuer` to
the export list (11-18) and insert after `validateDefaultRoles`:

```haskell
installHostBackgroundTasks :: ShomeiConfig -> ServerSettings -> Env -> IO HostBackgroundTasks
installHostBackgroundTasks cfg settings env = do
  validateDefaultRoles cfg env
  installKeyReload cfg env
  releaseSweeper <- installSweeper settings env
  notifierWorker <- installNotifierWorker env
  pure HostBackgroundTasks
    { stopHostBackgroundTasks = \timeoutSeconds -> do
        drainNotifierWorker notifierWorker timeoutSeconds
        releaseSweeper
    }

hostMiddleware :: ShomeiConfig -> ServerSettings -> RateLimiter -> Metrics -> Middleware
hostMiddleware cfg settings =
  edgeMiddleware cfg.observabilityConfig settings.serverTrustedProxies
```

Import `RateLimiter`, `Metrics`, and `Network.Wai.Middleware`; move the order comment (107-113) onto
`hostMiddleware`. In `main`, lines 101-122 become `backgroundTasks <- installHostBackgroundTasks cfg settings env`,
`rl <- newRateLimiterFor shomeiThrottledRoutes cfg.rateLimitConfig`, `metrics <- newMetrics`; line 145 becomes
`Warp.runSettings warpSettings (hostMiddleware cfg settings rl metrics (application env liveness readiness))`;
after Warp returns, call `stopHostBackgroundTasks backgroundTasks` with the graceful-shutdown timeout.

Add one case to `shomei-server/test/Shomei/Server/MiddlewareSpec.hs` in the style of
`testOversizedBodyRejected` (281): "hostMiddleware refuses oversized bodies outside the limiter and
throttles inside it". Wrap `\_ respond -> respond (responseLBS status200 [] "ok")` with
`hostMiddleware cfg testSettings rl metrics`, where `cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")`,
`rl <- newRateLimiter cfg.rateLimitConfig`, `metrics <- newMetrics`, and `testSettings` is a
`ServerSettings` literal (`serverPort = 0`, `serverConnStr = ""`, `serverDbPoolSize = 1`,
`serverDbPoolAcquisitionTimeoutMs = 1000`, `serverSweep = defaultSweepSettings {sweepEnabled = False}`,
`serverArgon2 = defaultArgon2Params`, `serverHashingMaxConcurrency = 1`). From one `remoteHost`, 100
`POST /v1/auth/login` with `requestBodyLength = KnownLength (2 * 1024 * 1024)` are each `413` with an
`X-Request-Id` header (logging is outermost); then 60 small ones are all `200` (the flood did not drain
the bucket) and the 61st is `429`.

Acceptance: `cabal build all --enable-tests` adds no warning; `cabal test shomei-server-test` passes; `cabal run exe:shomei-server` still prints `[shomei] listening on :8080`.

```text
feat(server): export installHostBackgroundTasks and hostMiddleware as the embedding contract

Boot.main is the two exported functions around `application` and nothing else, so an embedding
host can install exactly the standalone runtime stack. A MiddlewareSpec case pins the order.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 2 — Both embedded examples use the contract, and prove it

Scope: the examples call the two functions, show the impersonation guidance in code, gate the grant
route, and a test shows a revoked key refused after `SIGHUP`.

In `examples/embedded-servant-app/app/Main.hs`, after `buildHealthChecks`, add
`installHostBackgroundTasks cfg settings env`, `rl <- newRateLimiter cfg.rateLimitConfig`,
`metrics <- newMetrics`, and make the last line
`Warp.run settings.serverPort (hostMiddleware cfg settings rl metrics (embeddedApplicationWith wwwDir env liveness readiness))`
(imports as in `Boot.hs`). `examples/embedded-with-en/app/Main.hs` gets the same four edits.

Impersonation as code (`docs/user/authorization.md:90-98`: act on `sub`, audit `act`): in `Embedded/App.hs`
replace `projectsHandler _user = pure […]` with a `do` block whose first statement is

```haskell
  forM_ user.authClaims.actor \operator -> -- delegated token: act for `sub`, audit `act`; ids only, never the token
    liftIO (hPutStrLn stderr ("[embedded-servant-app] delegated request sub=" <> Text.unpack (idText user.authUserId) <> " act=" <> Text.unpack (idText operator)))
```

(`Shomei.Id (idText)`, `System.IO`, `Data.Text qualified as Text`.) In `EmbeddedEn/App.hs` put the same
line at the top of `getProject` and `putProject`, commenting that the en check is against the subject
(`subjectForUser` reads `authUserId`, the `sub`), never the actor.

Gate the grant route: on `EmbeddedEn/App.hs:105` replace `Authenticated :>` with `RequireRole "admin" :>`
(`Shomei.Servant.Authz`; the handler still receives `AuthUser`). Add `subject :: !Text` to
`GrantRequest` (the grantee's user id as TypeID text) and in `grantHandler` use `subjectForUserId req.subject`,
adding to `EmbeddedEn/Authz.hs` and its exports `subjectForUserId :: Text -> Subject`,
`subjectForUserId uid = SubjectId (ObjectRef {objectType = ObjectType "user", objectId = uid})`. Rewrite
the README transcript (`README.md:41-89`) to the one in Concrete Steps; say in "Production notes" that
the route is admin-gated while the store remains a stand-in.

The proof. In `examples/embedded-servant-app/test/Main.hs` add "a revoked signing key stops verifying
after SIGHUP once the host installs the background tasks": after the existing login, read
`oldKid = keyKid . (.signingKey) <$> readIORef keysRef`, then rotate the way `Shomei.Server.Keys.ensureActiveKey` does:

```haskell
rotateAndRevoke :: Pool -> Text -> IO ()
rotateAndRevoke pool oldKid = do
  jwk <- generateSigningKeyFor ES256
  now <- getCurrentTime
  protected <- protectStoredSigningKey testKek (toStoredSigningKeyFor ES256 now jwk)
  r <- runEff . runErrorNoCallStack @AuthError . runDatabasePool pool . runClockIO . runSigningKeyStorePostgres $ do
    insertSigningKey protected
    updateSigningKeyStatus oldKid KeyRevoked now
  either (throwIO . userError . show) pure r
```

Assert `/projects` with the old token is still `200` (nothing reloaded — the before-state), call
`installHostBackgroundTasks cfg testSettings env` (M1's `testSettings`, sweeper off),
`raiseSignal sigHUP` (`System.Posix.Signals`), and `pollUntil 3000` (copy the helper from the
microservice suite) until the request is `401`. Add `effectful`, `effectful-core`, `hasql-pool`, `unix`,
`time` to the suite's `build-depends`. Acceptance: `cabal test embedded-servant-app` → 2 passed;
`cd examples/embedded-with-en && cabal build` succeeds at either pin; the transcript reproduces.

```text
feat(examples): embedded hosts install the runtime stack; admin-gated grant route; act logging

Both embedded examples call installHostBackgroundTasks and hostMiddleware; a test revokes the
signing key and shows the host refusing the old token after SIGHUP. The en demo's grant route
requires the admin role and grants a named subject; both examples log `act`.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 3 — A downstream template that can be copied

Scope: `examples/microservice-auth-stack` only; the seven cache tests stay as written.

**TLS.** Add to `Service.hs` and export `newJwksManager :: String -> IO HTTP.Manager`: `HTTP.parseRequest url`;
if `HTTP.secure req` then `newTlsManager` (`Network.HTTP.Client.TLS`; add `http-client-tls` to the
library and executable `build-depends`; the Haddock notes it honours `https_proxy`), else
`HTTP.newManager HTTP.defaultManagerSettings`, preceded — when `HTTP.host req` is not `127.0.0.1`,
`localhost`, or `::1` — by one `BS8.hPut stderr` line `[downstream] WARNING: JWKS over plaintext http; an
on-path attacker can substitute keys. Use https.` Use it at `app/Main.hs:34`.

**Clamp and order.** In `mkEntry`: `effectiveTtl = min cache.maxStaleness (fromMaybe cache.configuredTtl (parseMaxAge hdrs))`;
in `parseMaxAge` change `n >= 0` to `n > 0`. In `currentJwks`'s `Just entry` branch test
`age >= cache.maxStaleness` first (→ `refreshWindow cache entry age`, which kicks a refresh and throws
`JwksUnavailable`), then `age < refreshAheadFactor * entry.effectiveTtl` (→ serve), else `refreshWindow`.

**Unknown-key refresh.** Add fields `unknownKeyMinAge`, `unknownKeyRefreshInterval :: !NominalDiffTime`
and `lastUnknownKeyRefresh :: !(IORef UTCTime)` to `JwksCache`; a `JwksCacheSettings` record of the four
durations with `defaultJwksCacheSettings` = 900, 86400, 5, 30; and `newJwksCacheWith mgr url settings`.
Keep `newJwksCache mgr url ttl maxStale` as a wrapper so the seven tests and `Main.hs` do not change. Then

```haskell
-- | A token named a key we do not hold: refresh at most once per interval, synchronously, single-flight.
refreshForUnknownKey :: JwksCache -> IO Bool
refreshForUnknownKey cache = do
  now <- getCurrentTime
  mEntry <- readIORef cache.cacheEntry
  case mEntry of
    Just entry | diffUTCTime now entry.fetchedAt >= cache.unknownKeyMinAge -> do
      claimed <- atomicModifyIORef' cache.lastUnknownKeyRefresh \last ->
        if diffUTCTime now last >= cache.unknownKeyRefreshInterval then (now, True) else (last, False)
      when claimed $ withMVar cache.refreshLock \() -> refreshOnce cache (diffUTCTime now entry.fetchedAt)
      pure claimed
    _ -> pure False
```

In `localAuthHandler`: decode with `Text.decodeUtf8Lenient`; every `401` gets
`errHeaders = [("WWW-Authenticate", "Bearer")]`; on `Left TokenKeyNotFound` call
`refreshForUnknownKey` and, if `True`, re-read `currentJwks` and `verifyToken` once; any remaining
`Left` is `401`. No other verification failure reaches the network refresh path.

**Tests.** Make the stub body mutable (`stubBody :: IORef LBS.ByteString`), pass `pool`, `keysRef`,
`cenv` from `main` into `tests`, and add to `cacheTests` (under `dependentTestGroup … AllFinish`):

1. "an https JWKS URL selects a TLS-capable manager": `newJwksManager` on the plaintext stub's URL with
   `https://`; `try @JwksUnavailable (currentJwks cache)` is `Left (JwksUnavailable msg)` with
   `"TlsNotSupported"` not an infix of `msg` (the handshake fails — TLS was attempted; before M3 the message is Observation (a)'s).
2. "max-age is clamped and max-age=0 does not loop": stub `ServeOkMaxAge 100000`, cache
   `newJwksCache mgr stubUrl 900 3`, warm, `threadDelay 3_300_000`, `currentJwks` throws (before: served
   forever); then `ServeOkMaxAge 0`, a fresh cache `900 86400`, warm, 50 sequential `currentJwks`, `stubCount == 1`.
3. "an unknown key triggers one refresh and a retry; a burst causes at most one fetch": cache via
   `newJwksCacheWith` with `unknownKeyMinAge = 0`, `unknownKeyRefreshInterval = 2`; warm and `200`. Rotate
   the auth server's key (M2's helper without the revoke, then `reloadKeys testKek pool keysRef`), copy
   the new JWKS bytes into `stubBody`, log in again for `token2`: `GET /projects` → `200`, `stubCount` +1
   exactly. Immediately fire 50 concurrent requests with `token2 <> "X"` → all `401`, `stubCount` +1 at most.

Acceptance: `cabal test microservice-auth-stack` → 1 + 10 cases pass; the `https` curl in Concrete Steps answers `401` with `WWW-Authenticate: Bearer`.

```text
fix(examples/microservice): TLS-capable JWKS manager, clamped max-age, unknown-key refresh

The copy-me template selects a TLS manager by scheme, clamps a publisher's max-age to its staleness
bound and checks that bound first, ignores max-age=0, refreshes once (rate-capped, single-flight)
when a token names an unheld key and retries once, answers 401 with WWW-Authenticate: Bearer, and
decodes Authorization leniently. Three new tests.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 4 — Runbooks that boot, and a project file that matches the root

`examples/microservice-auth-stack/process-compose.yaml`: delete line 23 so the process inherits the dev
shell's socket URI, and add a header comment: run from the dev shell after `just create-database`;
`PG_CONNECTION_STRING` and `SHOMEI_KEY_ENCRYPTION_KEY` are inherited — export the KEK once
(`export SHOMEI_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)`) and keep it for the life of
that database, because another KEK cannot decrypt the key rows the first boot wrote. Put the same two
sentences in the microservice and `embedded-with-en` READMEs' run sections and in a new short
`examples/embedded-servant-app/README.md` (what it is; the run command with the KEK; pointers to
`www/README.md` and `docs/user/passkeys.md`); fix `www/README.md:12` to `../../../docs/user/passkeys.md`.

`examples/embedded-with-en/cabal.project`: set line 41's tag to `bf8ffa24b33de328ed7c6b19f02e9e3ad035d57f`
(comment: this plan, and the three Hackage dependencies `en-core` now brings); delete 54-58 (hs-jose),
replacing the comment with the root's EP-4 note; after `allow-newer` append the root's
`constraints: crypton-x509-validation >= 1.9.1` with its CVE comment verbatim; update README lines 19-25
(drop the obsolete openapi-pin sentence). In `src/EmbeddedEn/Authz.hs` import
`En.RelationshipPagination (relationshipPageFromRows)` and add, after the `ReadRelationships` arm (195-197), Kikan's own arm over the `IORef`:

```haskell
  ReadRelationshipPage _ token relationshipFilter pageRequest -> do
    tuples <- liftIO (readIORef ref)
    pure (relationshipPageFromRows token pageRequest
            [Kikan.tupleRow index t | (index, t) <- zip [1 ..] tuples, Kikan.matchesRelationshipFilter relationshipFilter t])
```

Build it in CI: add a `justfile` recipe `build-embedded-with-en:` with body `cd examples/embedded-with-en && cabal build`,
and in `.github/workflows/ci.yaml` after "Build all packages" a step `run: nix develop --command just build-embedded-with-en`,
adding `examples/embedded-with-en/cabal.project` to the cache `hashFiles` list on line 49.

Rewrite `examples/microservice-auth-stack/README.md` §4 (145-157) as "Security posture — authenticate to
en-server with an API key": the operator sets on en-server `EN_API_KEYS_READ_ONLY='downstream:<32 random bytes, base64>'`
(read-only suffices for `check`; `EN_API_KEYS_READ_WRITE` only for a tuple-writing service;
`EN_AUTH_DISABLED=true` is local development only; TLS via `EN_TLS_CERT_FILE`/`EN_TLS_KEY_FILE` or a
private network) and on the downstream `EN_API_KEY` (the secret half). Replace §3's `ClientEnv` with

```haskell
mkEnClientEnv :: String -> ByteString -> IO ClientEnv
mkEnClientEnv enServerUrl apiKey = do
  base <- parseBaseUrl enServerUrl
  mgr <- newManager tlsManagerSettings {managerModifyRequest = \req ->
           pure req {requestHeaders = ("Authorization", "Bearer " <> apiKey) : requestHeaders req}}
  pure (mkClientEnv mgr base)
```

and note that a rejected key is a `Left FailureResponse` (`401`, `WWW-Authenticate: Bearer`) which the
existing `Left _ -> throwError err503` already maps fail-closed. Delete the "when plan 33 ships"
paragraph and its Shōmei-JWT promise; say en decided against it. While there, correct §1's migration
sentence to en's `pg-migrate` (`cabal run en-migrate -- up`); `authorization.md`'s "current en-side
gaps" belong to `docs/plans/60-…`. Acceptance: the example's `process-compose … up` reaches
`example-project-service` healthy from a dev shell with the KEK exported; `cd examples/embedded-with-en && cabal build`
succeeds at en `bf8ffa24`; `just build-embedded-with-en` works from the root; CI runs it.

```text
chore(examples): runbooks boot from the dev shell; en example tracks root pins and en HEAD

process-compose inherits the socket connection string; every example runbook states
SHOMEI_KEY_ENCRYPTION_KEY; embedded-with-en drops the hs-jose pin, mirrors the crypton-x509-validation
constraint, pins en bf8ffa24 (TupleStore gains ReadRelationshipPage), and is built by CI from its own
directory; the microservice README's en recipe sends an API key against en's real authentication.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 5 — The embedding checklist and the ADR

In `docs/user/client-and-examples.md`, after "Embedded Servant App", add "Embedding checklist" in prose:
what `serveWithContext` with `authContext` alone gives (token verification with the key material loaded
at boot, CSRF origin checks, problem-detail errors, the database-backed lockout and per-IP failure
counter) and what only the two functions give (`installHostBackgroundTasks`: periodic and `SIGHUP` key
reload so `keys revoke` reaches the host, the sweeper, the `defaultRoles` boot check, after EP-7 the
notifier worker; `hostMiddleware`: logging with `X-Request-Id`, metrics and `/metrics`, the 1 MiB body
cap, the per-IP limiter). Say plainly that the `RateLimited`/`CsrfProtected` markers describe responses
produced only when the middleware is installed, so an embedded OpenAPI document's `429`s are truthful
only with `hostMiddleware` — and, once `docs/plans/54-…` derives the throttled paths from `RateLimited`,
only then for routes beyond today's literal list. Two caveats: the limiter matches Shōmei's paths at the
root (mount `ShomeiRoutes` unprefixed, as both examples do), and `installKeyReload` installs a
process-wide `SIGHUP` handler. Give M2's `main` as the snippet; add the KEK to the run blocks at 54-58
and 83-90. Rewrite 131-135: Shōmei sends `Cache-Control: public, max-age=300`, so against Shōmei the
effective TTL is 300 s and `DOWNSTREAM_JWKS_TTL_SECONDS` applies only to publishers sending no header;
`max-age` is clamped and `max-age=0` ignored; add a bullet for the unknown-key refresh and a warning that
a plaintext JWKS URL is a full token-forgery vector. In `docs/user/architecture.md:60-63` insert the body
cap into the order and say the stack is exported as `hostMiddleware`, the tasks as `installHostBackgroundTasks`.

The ADR. If `docs/adr/` does not exist yet: copy the frozen descriptor
`blueprints/adopt-architecture-decisions/files/architecture-decisions-profile.dhall` from the
`shinzui/okf-profiles` checkout (`mori path shinzui/okf-profiles`) to `docs/adr/profile.dhall` — it pins
`v0.8.0/package.dhall` with a `dhall freeze` hash, so nothing is guessed — run
`okf index docs/adr --write --okf-version 0.2`, add a `log.md`, add an `okfBundles`
entry to `mori.dhall` (`name = "adrs"`, `path = "docs/adr"`, `okfVersion = "0.2"`) beside `reviews`, and
a `just adr-validate` recipe mirroring `reviews-validate`. Allocate the handle with `okf id next`, write
`docs/adr/000N-the-embedding-contract-is-two-exported-functions.md` with frontmatter `type: Architecture Decision Record`,
`title`, `description`, `timestamp`, `docId: ADR-N`, `status: Accepted`, `date`, and sections Context / Decision /
Consequences / Alternatives (bare `application`; `application` taking the stack; a `ShomeiHost` record);
regenerate `index.md`, add a `log.md` entry, validate strictly (Concrete Steps).

```text
docs(embedding): embedding checklist, JWKS cache truths, and ADR for the embedding contract

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```


## Concrete Steps

All commands run inside `nix develop` from the repository root unless a `cd` is shown, with the dev
database created (`just create-database`) and a KEK exported once per database
(`export SHOMEI_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)`; keep it — a new KEK cannot read
old key rows). `SIGNUP`/`LOGIN` abbreviate `curl -s -XPOST localhost:<port>/v1/auth/{signup,login} -H 'content-type: application/json' -d <json>`.

Observation (a), before M3, in `cabal repl microservice-auth-stack`:

```text
ghci> import Network.HTTP.Client qualified as HTTP
ghci> mgr <- HTTP.newManager HTTP.defaultManagerSettings
ghci> c <- newJwksCache mgr "https://www.googleapis.com/oauth2/v3/certs" 900 86400
ghci> currentJwks c
*** Exception: JwksUnavailable "initial JWKS fetch failed: TlsNotSupported"
```

Observation (b), before M1/M2 (terminal 1: `cd examples/embedded-servant-app && cabal run embedded-servant-app`; terminal 2 from the root):

```bash
SIGNUP '{"loginId":"ann","email":"ann@example.com","password":"correct horse battery staple","displayName":"Ann"}' >/dev/null
TOK=$(LOGIN '{"loginId":"ann","password":"correct horse battery staple"}' | jq -r .token.accessToken)
export DATABASE_URL="$PG_CONNECTION_STRING"
OLD=$(cabal run -v0 shomei-admin -- keys list | grep KeyActive | awk '{print $1}')
NEW=$(cabal run -v0 shomei-admin -- keys generate | sed 's/.*key: //')
cabal run -v0 shomei-admin -- keys activate "$NEW" && cabal run -v0 shomei-admin -- keys revoke "$OLD"
sleep 90; curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/projects -H "Authorization: Bearer $TOK"   # 200 pre-fix (after M2: 401)
curl -s localhost:8080/.well-known/jwks.json | jq -r '.keys[].kid'                                            # $OLD still listed pre-fix (after M2: only $NEW)
```

Build and test after each milestone; the en example from its own directory (M4), then the recipe:

```bash
cabal build all --enable-tests
cabal test shomei-server-test embedded-servant-app microservice-auth-stack --test-options='-j2'
cd examples/embedded-with-en && cabal build --dry-run 2>&1 | grep -E 'en-core|relay-pagination|hs-jose'; cabal build; cd ../..
just build-embedded-with-en
```

```text
Test suite shomei-server-test: PASS            (… "hostMiddleware refuses oversized bodies outside the limiter …": OK)
Test suite embedded-servant-app-test: PASS     (2 tests: 401/200, revoked key after SIGHUP)
Test suite microservice-auth-stack-test: PASS  (1 end-to-end + 10 cache cases)
 - en-core-0.1.0.0 (lib) …      <- from https://github.com/shinzui/en.git at bf8ffa24, with relay-pagination-0.1.1.0; no hs-jose line
```

The 403 → admin grants → 200 transcript (M2; `SHOMEI_PORT=8085 cabal run embedded-with-en` in `examples/embedded-with-en`):

```text
$ ANN_ID=$(SIGNUP '{"loginId":"ann","email":"ann@example.com","password":"Str0ng-Pass-123!","displayName":"Ann"}' | jq -r .userId)
$ ROOT_ID=$(SIGNUP '{"loginId":"root","email":"root@example.com","password":"Str0ng-Pass-123!","displayName":"Root"}' | jq -r .userId)
$ DATABASE_URL="$PG_CONNECTION_STRING" cabal run -v0 shomei-admin -- roles grant --user "$ROOT_ID" --role admin
$ TOK=$(LOGIN '{"loginId":"ann","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken); ADMIN=$(LOGIN '{"loginId":"root","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8085/projects/roadmap -H "Authorization: Bearer $TOK"
403
$ GRANT="{\"subject\":\"$ANN_ID\",\"projectId\":\"roadmap\",\"relation\":\"editor\"}"
$ curl -s -o /dev/null -w '%{http_code}\n' -XPOST localhost:8085/demo/grants -H "Authorization: Bearer $TOK" -H 'content-type: application/json' -d "$GRANT"
403
$ curl -s -XPOST localhost:8085/demo/grants -H "Authorization: Bearer $ADMIN" -H 'content-type: application/json' -d "$GRANT"
{"consistencyToken":"embedded-en-write","granted":"editor","object":"project:roadmap"}
$ curl -s -o /dev/null -w '%{http_code}\n' -XPUT localhost:8085/projects/roadmap -H "Authorization: Bearer $TOK" -H 'content-type: application/json' -d '{"projectName":"Roadmap v2"}'
200
```

An `https` JWKS working after M3 (a bad token: `401` proves the keys were fetched over TLS and judged; before M3 it is `503`), then the ADR bundle (M5):

```bash
SHOMEI_JWKS_URL=https://www.googleapis.com/oauth2/v3/certs cabal run example-project-service &
curl -si localhost:8090/projects -H 'Authorization: Bearer not-a-token' | head -3   # HTTP/1.1 401 … WWW-Authenticate: Bearer
dhall hash <<< 'https://raw.githubusercontent.com/shinzui/okf-profiles/v0.11.0/profiles/documentation/architecture-decisions.dhall'
okf id next docs/adr --profile docs/adr/profile.dhall ADR          # ADR-1 unless a sibling landed first
okf index docs/adr --write --okf-version 0.2
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

An embedded host loses trust in a revoked key without a restart: `cabal test embedded-servant-app` passes
the SIGHUP case, and Observation (b) re-run after M2 prints `401` and a JWKS without the old `kid` within
60 s (or right after `kill -HUP <pid>`). An embedded host refuses a 2 MiB body and throttles:
`cabal test shomei-server-test` pins the order, and `curl -i -XPOST localhost:8080/v1/auth/login -H 'Content-Length: 2097152'`
against a running example answers `413` with an `X-Request-Id` header. `E2ESpec` and `test-health` pass unchanged.

The template is copyable: `cabal test microservice-auth-stack` shows eleven passing cases; the `https`
curl answers `401` with `WWW-Authenticate: Bearer`; after `keys generate`/`keys activate` on the auth
service a fresh login's token is accepted by the downstream on its first request (one fetch), while
fifty `curl … -H "Authorization: Bearer ${TOKEN}X"` in a loop give fifty `401`s and at most one more fetch.
The runbooks boot: both process-compose files and the three README run commands work from a dev shell
with the KEK exported; `cd examples/embedded-with-en && cabal build` succeeds at en `bf8ffa24`; CI's new
step is green; the en recipe applied to a copy of the service against an `en-server` started with
`EN_API_KEYS_READ_ONLY` returns `200` for a granted subject and `503` (never `200`) when `EN_API_KEY` is
wrong. `client-and-examples.md` has the checklist and the corrected `Cache-Control` paragraph,
`architecture.md` names the body cap and the two functions, and `docs/adr/` validates strictly.


## Idempotence and Recovery

Every edit is a plain file change; re-running a milestone re-applies the same text. Tests create their
own ephemeral PostgreSQL. The manual observations write to the dev database: a second signup is `409`
(use another `loginId`), and the rotation leaves a harmless revoked row. If the KEK is lost the key rows
are unreadable: `dropdb shomei && just create-database` and export a new KEK. If the en example fails to
solve after the bump, run `cabal build --dry-run -v2`, check whether `relay-pagination`, `generic-lens ^>=2.3`,
or `lens ^>=5.3` collide with a root bound, record the resolution in Surprises, and add any `constraints:`
line to the example's project file only; reverting the tag to `d3209cb` and removing the
`ReadRelationshipPage` arm restores the previous build. If the SIGHUP test is flaky, keep it last in its
group with `pollUntil` at 3000 ms; if M3's unknown-key test sees two fetches, the 2 s interval elapsed —
start the burst immediately after the `200`. If a sibling already created `docs/adr/`, skip the bundle
setup and use the handle `okf id next` returns; never fill a gap or reuse a number.


## Interfaces and Dependencies

End of M1, `Shomei.Server.Boot` (shomei-server) exports, beyond today's five:

```haskell
newtype HostBackgroundTasks = HostBackgroundTasks
  { stopHostBackgroundTasks :: Int -> IO ()
  }
installHostBackgroundTasks :: ShomeiConfig -> ServerSettings -> Env -> IO HostBackgroundTasks
hostMiddleware :: ShomeiConfig -> ServerSettings -> RateLimiter -> Metrics -> Network.Wai.Middleware
validateOidcIssuer :: ShomeiConfig -> IO ()
```

with `RateLimiter`/`newRateLimiterFor :: Set ThrottledRoute -> RateLimitConfig -> IO RateLimiter`
(`Shomei.Server.Middleware.RateLimit`)
and `Metrics`/`newMetrics :: IO Metrics` (`Shomei.Server.Observability.Metrics`); `application` is
unchanged. EP-7's worker is installed inside `installHostBackgroundTasks`; EP-8's trusted-proxy
settings are read by `hostMiddleware`; neither changed the contract. End of M2, `EmbeddedEn.Authz`
also exports `subjectForUserId :: Text -> Subject` and `EmbeddedEn.App.GrantRequest` has `subject`,
`projectId`, `relation`. End of M3, `Downstream.Service` (microservice-auth-stack) exports, beyond today's list:

```haskell
newJwksManager :: String -> IO Network.HTTP.Client.Manager
data JwksCacheSettings = JwksCacheSettings { configuredTtl, maxStaleness, unknownKeyMinAge, unknownKeyRefreshInterval :: NominalDiffTime }
defaultJwksCacheSettings :: JwksCacheSettings                 -- 900, 86400, 5, 30
newJwksCacheWith :: Manager -> String -> JwksCacheSettings -> IO JwksCache   -- newJwksCache stays as a wrapper
refreshForUnknownKey :: JwksCache -> IO Bool
```

Verification stays `Shomei.SigningKey.Verify.Jwt.verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)`;
the handler matches EP-3's `TokenKeyNotFound` and never refreshes for ordinary signature failure. New
dependencies: `http-client-tls >=0.3.6.4 && <0.5` for the example library and executable; the example test
suites add `effectful`, `effectful-core`, `hasql-pool`, `unix`, `time`; `examples/embedded-with-en` takes
`en-core` at `bf8ffa24b33de328ed7c6b19f02e9e3ad035d57f` (bringing `relay-pagination 0.1.1.0`, `generic-lens`,
`lens` from Hackage) and its interpreter must cover the 15-constructor `En.Effect.TupleStore.TupleStore`.
The ADR bundle uses `okf` v0.8.0.0 and the shared profile from `mori://shinzui/okf-profiles` (`profiles/documentation/architecture-decisions.dhall`).
