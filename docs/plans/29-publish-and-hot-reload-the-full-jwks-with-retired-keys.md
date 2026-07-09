---
id: 29
slug: publish-and-hot-reload-the-full-jwks-with-retired-keys
title: "Publish and Hot-Reload the Full JWKS with Retired Keys"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md"
---

# Publish and Hot-Reload the Full JWKS with Retired Keys

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei signs its access tokens (JWTs) with a private signing key and publishes the matching
*public* keys as a JWKS — a JSON Web Key Set, the document `{"keys":[…]}` served at
`GET /.well-known/jwks.json` that downstream services fetch to verify tokens locally. Keys
have a lifecycle managed by the `shomei-admin` CLI: `pending` (exists, unused) → `active`
(signs new tokens, published) → `retired` (stops signing but **stays published and
trusted**, so tokens minted just before a rotation keep verifying until they expire) →
`revoked` (immediately distrusted). That lifecycle is documented as *zero-downtime rotation*
in `docs/user/security.md` ("Signing-key rotation (zero downtime)") and `docs/user/api.md`
(the `GET /.well-known/jwks.json` entry, ~line 150, promises "the `active` plus
still-trusted `retired` signing keys").

The July 2026 security review found that promise does not hold at the HTTP boundary:

- The server loads keys **once at boot** and never again. `shomei-admin keys activate` has
  zero effect on a running server — it keeps signing with, and trusting, whatever was
  active at startup.
- Even after a restart, the served JWKS and the server's own verifier contain **only the
  active key**: `bootstrapKeys` builds `KeySet jwk []` (no previous keys), the boot path
  publishes `jwksDocument [env.envKey]`, and even `Shomei.Jwt.Rotation.currentJwks` reads
  `listActiveSigningKeys`, which by contract returns only `status = 'active'` rows. So the
  moment a rotation completes and the server restarts, every token signed by the
  just-retired key is rejected — by Shōmei itself and by every downstream that refetches
  the JWKS. Rotation as shipped is guaranteed-downtime.

After this plan: the JWKS document and the server's verifier key set are built from **all
publishable keys** (`active` + `retired`); the server **reloads** that material from the
database both periodically (configurable interval, default 60 s) and immediately on
`SIGHUP`, so `keys activate` takes effect on a live server with no restart — it starts
signing with the new key while still trusting the retired one; `keys revoke` removes a key
from publication and trust within one reload; and the whole rotation runbook (generate →
activate → old tokens still verify → revoke → old tokens rejected) is verified end-to-end
against a running server. The JWKS endpoint keeps serving a *precomputed* JSON value
(recomputed once per reload, not per request). Key loading is centralized in one function so
plan 32 (`docs/plans/32-encrypt-signing-private-keys-at-rest.md`) can later wrap it with
envelope decryption without creating a second load path.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] M1: `ListPublishableSigningKeys` added to the `SigningKeyStore` port; Postgres
      interpreter (`status IN ('active','retired')`) and in-memory interpreter implemented;
      store tests pass. (2026-07-08)
- [x] M1: `Shomei.Jwt.Rotation.currentJwks` builds from publishable keys; its doc comment
      updated; jwt tests pass. (2026-07-08)
- [ ] M2: `Shomei.Server.Keys.loadKeyMaterial` centralizes load: picks the signer (active
      key), builds the verifier `JWKSet` and the precomputed JWKS `Value` from all
      publishable keys; `bootstrapKeys` reimplemented on top of it.
- [ ] M2: `Shomei.Server.App.Env` holds an `IORef LoadedKeys`; signer/verifier interpreters
      and the seam read through it; `Seam.Env.jwksJson` becomes `IO Value`; all assemblies
      (server, servant tests, demos) compile and pass.
- [ ] M3: periodic reload thread (interval from `SigningKeyConfig.refreshIntervalSeconds`,
      env `SHOMEI_KEY_REFRESH_INTERVAL`, 0 = disabled) and `SIGHUP` handler wired in
      `Shomei.Server.Boot`; reload failures log and keep the last good material.
- [ ] M4: rotation runbook verified end-to-end against a live server (transcript captured
      in Validation); server E2E test extended; `docs/user/security.md` /
      `docs/user/deployment.md` note the reload mechanism.
- [ ] Living sections of this plan updated; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a new port operation `ListPublishableSigningKeys` (returns `active` +
  `retired` keys) instead of widening `ListActiveSigningKeys`.
  Rationale: callers genuinely need both queries — `ensureActiveKey`, `rotateSigningKeyFor`,
  and the `/ready` probe ask "which key signs?" (`active` only), while JWKS/verifier
  construction asks "which keys verify?" (`active` + `retired`). The admin CLI already
  distinguishes them (`Shomei.Admin.Keys.listPublishableStmt` uses
  `status IN ('active','retired')` today — that raw-SQL helper is the model, and the CLI can
  keep its local SQL since it deliberately avoids the effect stack). "Publishable" excludes
  `pending` (not yet trusted) and `revoked` (explicitly distrusted), matching
  `docs/user/security.md`.
  Date: 2026-07-07

- Decision: Reload mechanism is **both** a periodic background refresh (default every 60
  seconds, configurable, 0 disables) **and** a `SIGHUP` handler for immediate effect.
  Rationale: periodic polling alone makes rotation eventually-correct with no operator
  action and works in every deployment (including ones where sending signals is awkward);
  SIGHUP gives operators a deterministic "apply now" for runbooks and tests. Both call the
  same `loadKeyMaterial`+swap function, so there is one code path. LISTEN/NOTIFY was
  rejected as heavier machinery (a dedicated connection, reconnect logic) for no extra
  guarantee; 60 s of staleness is acceptable because a retired key remains trusted anyway —
  the only window that matters is revocation, and 60 s is an acceptable emergency-lever
  latency (tightenable via config).
  Date: 2026-07-07

- Decision: The reloaded material swaps **the signer too**, not just the verifier/JWKS:
  after `keys activate`, the running server begins signing with the new active key at the
  next reload.
  Rationale: that is what "activate is zero-downtime" means. Publishing the new key while
  still signing with the retired one would be consistent but would defeat the point of
  rotation (the old key would keep accruing signatures).
  Date: 2026-07-07

- Decision: On a reload where the database has **no active key** (or the load fails), the
  server keeps the last good `LoadedKeys` and logs a warning; it never crashes and never
  serves an empty JWKS. Boot (first load) still fails hard if no key can be established.
  Rationale: an admin mid-rotation mistake (e.g. `keys retire` on the only active key) must
  degrade gracefully — the server can still verify everything it issued and still sign
  (with the stale key, which downstreams still trust). Loud stderr logs make the state
  visible, and the `/ready` probe (which checks for an active key in the database) starts
  failing, so orchestration notices too.
  Date: 2026-07-07

- Decision: Keep the precomputed-JSON property by storing the encoded JWKS `Value` inside
  the swapped `LoadedKeys` record; the handler does one `readIORef` per request.
  Rationale: the current `jwksH` returns a precomputed `Value` from the env — regressing to
  per-request `jose` encoding would add avoidable allocation on a hot, unauthenticated,
  cacheable endpoint. An `IORef` read is effectively free.
  Date: 2026-07-07

- Decision: If several keys are `active` simultaneously (possible only by hand-editing the
  database — `keysActivate` auto-retires prior actives), the signer is the one with the
  greatest `activatedAt` (`Nothing` sorts lowest); all of them are published.
  Rationale: deterministic, matches operator intent ("the newest activation wins"), and
  avoids refusing to boot over a recoverable inconsistency.
  Date: 2026-07-07

- Decision: The refresh interval lives in the existing `SigningKeyConfig` record
  (`shomei-core/src/Shomei/Config.hs`), which grows from a `newtype` over `algorithm` to a
  two-field record with defaults, plus env override `SHOMEI_KEY_REFRESH_INTERVAL` (seconds).
  Rationale: it is signing-key policy, so it belongs beside `algorithm`; config records in
  this repo are append-only-with-defaults (MasterPlan IP-3), and every construction site is
  compiler-enumerated when the newtype becomes a record.
  Date: 2026-07-07

- Decision: `Shomei.Servant.Seam.Env.jwksJson` changes type from `Value` to `IO Value`.
  Rationale: the seam is the only consumer surface; an `IO` getter lets the server hand in
  `readIORef`-backed material while tests keep `pure staticValue`. The alternative — leaving
  the seam pure and having Boot re-create the WAI `Application` per reload — was rejected as
  far more invasive (servant context, auth handler, and middleware all rebuilt on the fly).
  Date: 2026-07-07

- Decision: This plan owns the key-loading seam; plan 32 consumes it.
  Rationale: restating the MasterPlan integration point — EP-2 (this plan) introduces "load
  all publishable keys, build signer + JWKS, refresh periodically" and the new port
  operation; EP-5 (plan 32) performs decryption *inside* the stored-key deserialization this
  loader calls (a pure `StoredSigningKey -> Either … JWK` function), and must not introduce
  a second load path. Keep `fromStoredSigningKey` the single stored→live conversion point.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project built inside a Nix devshell. Relevant
packages: `shomei-core` (domain types + *port effects* — typed capabilities in the
`effectful` library — including the signing-key store port), `shomei-jwt` (the only package
that touches the `jose` JWT library; converts stored key JSON to live `JWK` values, signs,
verifies, and builds JWKS documents), `shomei-postgres` (PostgreSQL interpreters of the
ports, via `hasql`), `shomei-servant` (the HTTP layer: routes, handlers, and the *seam* —
the record that carries the port-runner, config, verifier, and JWKS into handlers), and
`shomei-server` (the standalone server assembly: boot sequence, config loading, and the
`shomei-admin` CLI).

Exact current state (all verified against the working tree):

**The port** — `shomei-core/src/Shomei/Effect/SigningKeyStore.hs`:

```haskell
data SigningKeyStore :: Effect where
  ListActiveSigningKeys :: SigningKeyStore m [StoredSigningKey]
  FindSigningKeyByKid :: Text -> SigningKeyStore m (Maybe StoredSigningKey)
  InsertSigningKey :: StoredSigningKey -> SigningKeyStore m ()
  UpdateSigningKeyStatus :: Text -> SigningKeyStatus -> UTCTime -> SigningKeyStore m ()
```

`StoredSigningKey` (`shomei-core/src/Shomei/Domain/SigningKey.hs`) carries `keyId` (the JWK
`kid`), `algorithm`, `publicKeyJwk`/`privateKeyJwk` (opaque JWK JSON text — core never
imports jose), `status :: SigningKeyStatus` (`KeyPending | KeyActive | KeyRetired |
KeyRevoked`), and timestamps. The Postgres interpreter is
`shomei-postgres/src/Shomei/Postgres/SigningKeyStore.hs` (its `listActiveStmt` selects
`WHERE status = 'active'`); the in-memory interpreter is the `runSigningKeyStore` block in
`shomei-core/src/Shomei/Effect/InMemory.hs` (lines ~655–666, filtering
`k.status == KeyActive`).

**Key material conversion** — `shomei-jwt/src/Shomei/Jwt/Key.hs`:
`fromStoredSigningKey :: StoredSigningKey -> Either Text JWK` (decodes the private JWK
JSON), `generateSigningKeyFor`, `toStoredSigningKeyFor`. **JWKS building** —
`shomei-jwt/src/Shomei/Jwt/Jwks.hs`: `jwksDocument :: [JWK] -> BSL.ByteString` (public
projections only, private `d` stripped via `asPublicKey`), plus a `KeySet` record
(`activeKey`, `previousKeys`) and `keySetPublicJwks :: KeySet -> JWKSet`. **Rotation** —
`shomei-jwt/src/Shomei/Jwt/Rotation.hs`: `currentJwks` (lines 62–70) calls
`listActiveSigningKeys` and filters `notRevoked` — a filter that is currently vacuous
because the listing never returns retired keys; its own doc comment admits "including
retired-but-valid keys is deferred until the store gains a non-revoked query".

**Boot-time key loading** — `shomei-server/src/Shomei/Server/Keys.hs` (lines 37–48):

```haskell
bootstrapKeys :: SigningAlgorithm -> Pool -> IO (JWK, JWKSet)
bootstrapKeys alg pool = do
  ...
  $ ensureActiveKey alg          -- first boot: generate + insert an active key
  ...
  pure (jwk, keySetPublicJwks (KeySet jwk []))   -- <-- active key only, no retired keys
```

**The server env** — `shomei-server/src/Shomei/Server/App.hs` (lines ~105–111): `data Env =
Env { envPool :: !Pool, envConfig :: !ShomeiConfig, envKey :: !JWK, envJwks :: !JWKSet,
envHttpManager :: !Manager }`. `runAppIO` (same file) interprets the ports, notably
`runTokenVerifierJwt env.envJwks env.envConfig` and `runTokenSignerJwt env.envKey
env.envConfig` — both frozen at boot.

**The boot path** — `shomei-server/src/Shomei/Server/Boot.hs`: `buildEnv` calls
`bootstrapKeys` once (line ~110); `seamEnv` (lines ~131–139) builds the servant seam with
`Seam.verifier = verifyToken env.envJwks env.envConfig` (from
`shomei-jwt/src/Shomei/Jwt/Verify.hs`, `verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO
(Either TokenError AuthClaims)`) and `Seam.jwksJson = fromMaybe … (decode (jwksDocument
[env.envKey]))` — line ~137, the "active key only" publication. `main` already installs
POSIX signal handlers (`installHandler sigTERM/sigINT`, lines ~87–91), the pattern to copy
for SIGHUP.

**The seam** — `shomei-servant/src/Shomei/Servant/Seam.hs`: `data Env = Env { runPorts …,
config …, verifier :: !(Text -> IO (Either TokenError AuthClaims)), jwksJson :: !Value,
accountKeyOf … }`. The JWKS handler (`shomei-servant/src/Shomei/Servant/Handlers.hs` lines
447–448) is `jwksH env = pure env.jwksJson` — the precomputed-`Value` property to preserve.
The `/ready` probe (`readyH`, same file) calls `listActiveSigningKeys` and must keep doing
so (readiness means "can sign").

**The admin CLI** — `shomei-server/app/Shomei/Admin/Keys.hs` implements the
`pending → active → retired → revoked` lifecycle with module-local raw `hasql` SQL,
including `listPublishableStmt` (`status IN ('active','retired')`, lines ~204–212) — the
exact query the new port operation adopts. `shomei-admin` subcommands: `keys generate
[--alg]`, `keys activate <kid>`, `keys retire <kid>`, `keys revoke <kid>`, `keys list`,
plus `migrate` (see `shomei-server/app/Admin.hs`).

**Config** — `shomei-core/src/Shomei/Config.hs`: `newtype SigningKeyConfig =
SigningKeyConfig {algorithm :: Text}` (line ~54), defaulted in `defaultShomeiConfig` to
`SigningKeyConfig {algorithm = "ES256"}`. The server env-var loader is
`shomei-server/src/Shomei/Server/Config.hs` (patterns to copy: `intEnvMaybe` for an
integer env var, `signingAlgEnv` for an existing `SHOMEI_*` signing-key variable; the Dhall
`FileConfig` record there takes flat optional fields like `signingAlgorithm`).

**Why the finding matters**, spelled out: `keys activate` on a live server does nothing
(the server keeps signing with the old key). Restarting after activate makes the server
load only the *new* active key — so every outstanding token signed minutes ago by the
now-retired key fails verification at the server (`401`) and at every downstream that
refetches `/.well-known/jwks.json`. This contradicts `docs/user/security.md`'s "stays in
the JWKS and stays trusted" and `docs/user/api.md` ~line 150.

Build/test commands (repository root, inside `nix develop`): `cabal build all`,
`cabal test all` (or per-package). Database for live runs: `just create-database` (creates
`$PGDATABASE` if needed and migrates; the server also migrates idempotently at boot), or
`cabal run shomei-admin -- migrate`.


## Plan of Work

Four milestones: M1 gives the port/JWT layer the "publishable keys" vocabulary; M2
centralizes loading and threads mutable key material through the server; M3 adds the two
reload triggers; M4 proves the runbook end-to-end and updates docs.

### Milestone M1 — the `ListPublishableSigningKeys` port operation

Scope: after this milestone the operation exists with both interpreters and
`Rotation.currentJwks` uses it; nothing served over HTTP changes yet.

1. `shomei-core/src/Shomei/Effect/SigningKeyStore.hs`: add the constructor and helper,
   documenting the contract precisely:

   ```haskell
   -- | Every key that belongs in the published JWKS and the verifier key set:
   -- @active@ and @retired@ (they overlap during a rotation window). Excludes
   -- @pending@ (not yet trusted) and @revoked@ (explicitly distrusted).
   ListPublishableSigningKeys :: SigningKeyStore m [StoredSigningKey]

   listPublishableSigningKeys :: (SigningKeyStore :> es) => Eff es [StoredSigningKey]
   listPublishableSigningKeys = send ListPublishableSigningKeys
   ```

2. `shomei-postgres/src/Shomei/Postgres/SigningKeyStore.hs`: handle the new case with a
   `listPublishableStmt` adopting the admin CLI's proven query (order by `created_at` for
   stable output):

   ```haskell
   listPublishableStmt :: Statement () [KeyRow]
   listPublishableStmt =
     preparable
       """
       SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
              created_at, activated_at, retired_at
       FROM shomei.shomei_signing_keys
       WHERE status IN ('active','retired')
       ORDER BY created_at
       """
       E.noParams
       (D.rowList keyRowDecoder)
   ```

   Handler case mirrors the existing `ListActiveSigningKeys` one (`runSession` →
   `traverse rebuild`).

3. `shomei-core/src/Shomei/Effect/InMemory.hs`, `runSigningKeyStore`: add

   ```haskell
   ListPublishableSigningKeys ->
     liftIO (publishable <$> readIORef ref)
   ```

   with `publishable w = [k | k <- Map.elems w.signingKeys, k.status `elem` [KeyActive,
   KeyRetired]]` in the local `where` (the module already imports
   `SigningKeyStatus (..)`).

4. `shomei-jwt/src/Shomei/Jwt/Rotation.hs`, `currentJwks`: switch to
   `listPublishableSigningKeys` and drop the now-redundant `notRevoked` filter; update the
   doc comment (the deferral note is now resolved).

5. Tests: in `shomei-postgres/test/Main.hs`, extend the signing-key coverage: insert four
   keys and drive them to `active` / `retired` / `pending` / `revoked` via
   `insertSigningKey` + `updateSigningKeyStatus`, then assert
   `listPublishableSigningKeys` returns exactly the active + retired kids while
   `listActiveSigningKeys` still returns only the active one. Mirror the same assertion
   over the in-memory interpreter wherever the suites already exercise
   `runSigningKeyStore` (locate with `rg -n "SigningKey" shomei-core/test shomei-jwt/test
   shomei-postgres/test`). In `shomei-jwt`'s test suite, assert `currentJwks` output
   contains the retired key's `kid` and never a revoked one.

Acceptance: `cabal test shomei-core shomei-jwt shomei-postgres` pass with the new cases.

### Milestone M2 — one loader, mutable key material in the server

Scope: at the end the server builds signer + verifier + JWKS from one function into an
`IORef`, and every consumer reads through it. Behavior at rest is identical to today except
the JWKS/verifier now include retired keys after a restart; hot reload arrives in M3.

1. `shomei-server/src/Shomei/Server/Keys.hs` — the centralized seam. Define:

   ```haskell
   -- | Everything derived from the signing-key table in one load: the private key that
   -- signs new tokens, the public key set the verifier trusts, and the precomputed JWKS
   -- document served at /.well-known/jwks.json. Swapped atomically on reload.
   data LoadedKeys = LoadedKeys
     { signingKey :: !JWK,
       verifierJwks :: !JWKSet,
       jwksBody :: !Value
     }

   -- | Load all publishable keys and assemble 'LoadedKeys'. THE single stored→live load
   -- path (plan 32 hooks private-key decryption into the per-row conversion used here).
   loadKeyMaterial :: Pool -> IO (Either Text LoadedKeys)
   ```

   Implementation sketch: run `listPublishableSigningKeys` over the same minimal stack
   `bootstrapKeys` already assembles (`runEff . runErrorNoCallStack . runDatabasePool pool
   . runClockIO . runSigningKeyStorePostgres`); convert every row with
   `fromStoredSigningKey`, failing (`Left`) on any corrupt row — a corrupt key row is an
   operator emergency, not something to skip silently; the signer is the `KeyActive` row
   with the greatest `activatedAt` (Decision Log; `Left "no active signing key"` when none);
   `verifierJwks` = `JWKSet` of the public projections (`asPublicKey`) of every publishable
   key; `jwksBody` = `fromMaybe (Object KM.empty) (Aeson.decode (jwksDocument liveKeys))` —
   moving the decode that `Boot.hs` line ~137 does today into the loader.

   Rework `bootstrapKeys :: SigningAlgorithm -> Pool -> IO LoadedKeys`: run
   `ensureActiveKey alg` (unchanged first-boot generation guard) then `loadKeyMaterial`,
   `ioError`-ing on `Left` (boot fails hard, unlike reloads).

2. `shomei-server/src/Shomei/Server/App.hs`: replace the frozen fields —

   ```haskell
   data Env = Env
     { envPool :: !Pool,
       envConfig :: !ShomeiConfig,
       envKeys :: !(IORef LoadedKeys),
       envHttpManager :: !Manager
     }
   ```

   In `runAppIO`, read once per invocation (one invocation ≈ one request's port batch):
   `keys <- readIORef env.envKeys` in the runner's `IO` prelude, then
   `runTokenVerifierJwt keys.verifierJwks env.envConfig` and
   `runTokenSignerJwt keys.signingKey env.envConfig`. (Both interpreter functions keep
   their pure-argument signatures; freshness comes from re-reading the `IORef` each run.)
   Fix every other `envKey`/`envJwks` consumer the compiler reports
   (`rg -n "envKey|envJwks" --type haskell` — expect `Boot.hs`, tests under
   `shomei-server/test/`, and any demo/embedded assemblies; each becomes a `readIORef` or
   takes a `LoadedKeys`).

3. `shomei-server/src/Shomei/Server/Boot.hs`: `buildEnv` becomes `keys <- bootstrapKeys
   (configSigningAlgorithm cfg) pool; ref <- newIORef keys; … envKeys = ref …`. `seamEnv`
   builds the live views:

   ```haskell
   Seam.verifier = \t -> do
     keys <- readIORef env.envKeys
     verifyToken keys.verifierJwks env.envConfig t,
   Seam.jwksJson = (.jwksBody) <$> readIORef env.envKeys,
   ```

4. `shomei-servant/src/Shomei/Servant/Seam.hs`: change `jwksJson :: !Value` to
   `jwksJson :: !(IO Value)` (Decision Log) and update the handler in
   `shomei-servant/src/Shomei/Servant/Handlers.hs`: `jwksH env = liftIO env.jwksJson`.
   Fix every `Seam.Env` construction site (`rg -n "jwksJson" --type haskell`): test
   assemblies wrap their static value in `pure`.

5. Tests: `cabal build all`; run the full suite. Extend the server-side test
   (`shomei-server/test/Shomei/Server/E2ESpec.hs` / `shomei-server/test/Admin/Main.hs` —
   whichever already boots against an ephemeral database) with: create an active key, then
   generate + activate a second key via the `Shomei.Admin.Keys` functions, re-run
   `loadKeyMaterial`, and assert the resulting `jwksBody` lists both kids and
   `signingKey`'s kid is the new one.

Acceptance: `cabal test all` green; a server booted against a database containing an active
and a retired key serves both in the JWKS, and a token signed by the retired key verifies
(fully demonstrated by M4's transcript).

### Milestone M3 — periodic and signal-driven reload

Scope: the running server picks up key-lifecycle changes without restart.

1. Config: in `shomei-core/src/Shomei/Config.hs` grow `SigningKeyConfig`:

   ```haskell
   data SigningKeyConfig = SigningKeyConfig
     { algorithm :: !Text,
       -- | seconds between background reloads of signing-key material from the
       -- database (signer + verifier set + JWKS). 0 disables the periodic reload
       -- (SIGHUP still reloads). Default 60.
       refreshIntervalSeconds :: !Int
     }
     deriving stock (Generic, Eq, Show)
     deriving anyclass (FromJSON, ToJSON)
   ```

   Set `refreshIntervalSeconds = 60` in `defaultShomeiConfig`. Fix construction sites the
   compiler lists (`rg -n "SigningKeyConfig" --type haskell` — at minimum
   `defaultShomeiConfig` and the algorithm overlays in `Shomei/Server/Config.hs`, which
   must now use record update instead of rebuilding the newtype).

2. `shomei-server/src/Shomei/Server/Config.hs`: read `SHOMEI_KEY_REFRESH_INTERVAL` with the
   existing `intEnvMaybe` helper and overlay it in `overlayCoreFromEnv`; add an optional
   `keyRefreshIntervalSeconds :: Maybe Int` field to `FileConfig` and merge it in
   `baseFromFile` (both mirroring how `gracefulShutdownTimeoutSeconds` flows).

3. `shomei-server/src/Shomei/Server/Keys.hs`: add the swap-with-fallback:

   ```haskell
   -- | Reload key material and swap it in; on failure keep the last good material and
   -- log to stderr. Safe from any thread: a plain writeIORef of an immutable record —
   -- readers see old-or-new, never a torn value.
   reloadKeys :: Pool -> IORef LoadedKeys -> IO ()
   ```

   (`loadKeyMaterial` → `either warn (writeIORef ref)`; `warn` prints
   `[shomei] key reload failed: <reason>; keeping previous key material`.)

4. `shomei-server/src/Shomei/Server/Boot.hs`, in `main` after `buildEnv`:
   - Periodic: when `cfg.signingKeyConfig.refreshIntervalSeconds > 0`, fork a daemon loop.
     The supervised-background-thread idiom for `shomei-server` is owned by
     `docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md`
     (`Shomei.Server.Supervisor.supervisedLoop`: catch-log-continue per cycle, thread dies
     with the process). If that module has landed, use it:
     `supervisedLoop "key-reload" interval (reloadKeys env.envPool env.envKeys)`. If it has
     not, fork the same shape inline (`Control.Concurrent.forkIO`;
     `forever (threadDelay (interval * 1_000_000) >> reloadKeys env.envPool env.envKeys)`
     with the body wrapped in an exception guard so one failed cycle never kills the loop)
     and leave a note for plan 34 to migrate it onto `supervisedLoop` when the module
     exists. Either way no shutdown plumbing is needed.
   - Signal: alongside the existing `sigTERM`/`sigINT` handlers, install
     `installHandler sigHUP (Signals.Catch (stderr-line >> reloadKeys env.envPool
     env.envKeys)) Nothing` (`sigHUP` from the already-imported `System.Posix.Signals`),
     logging `[shomei] SIGHUP: reloading signing keys`.
   - After a successful reload that changed the kid set, log
     `[shomei] signing keys reloaded: active=<kid> published=<kid,kid,…>` (compare old/new
     kid sets to keep steady-state logs quiet).

5. Tests: unit-test the fallback by pointing `reloadKeys` at a released/bogus pool and
   asserting the `IORef` still holds the previous material afterward. In the server test
   suite add a reload-visibility case: boot material with one key, rotate via
   `Shomei.Admin.Keys`, call `reloadKeys`, assert the swapped `LoadedKeys` shows the new
   signer and both published kids (signals themselves are exercised manually in M4 — test
   the function the handler calls, not the signal delivery).

Acceptance: `cabal test all` green.

### Milestone M4 — end-to-end rotation runbook and docs

Scope: no new code; prove the operator story against a live server and document it. Execute
the transcript in Validation and Acceptance verbatim and paste the real output there. Then
update docs: `docs/user/security.md` ("Signing-key rotation" section — add a paragraph that
the server refreshes key material every `refreshIntervalSeconds` (default 60) and on
`SIGHUP`, so `keys activate`/`keys revoke` take live effect without restart);
`docs/user/deployment.md` — document `SHOMEI_KEY_REFRESH_INTERVAL`. Re-read
`docs/user/api.md`'s JWKS entry and confirm it is now simply true (no edit expected). Write
the Outcomes & Retrospective.


## Concrete Steps

All commands from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`, inside
`nix develop`.

```bash
cabal build all                              # after each milestone
cabal test shomei-core shomei-jwt            # M1
cabal test shomei-postgres                   # M1 (ephemeral throwaway databases)
cabal test all                               # M2, M3
```

Compiler-driven edit sweeps (run after the respective change; fix everything listed):

```bash
rg -n "envKey|envJwks" --type haskell        # M2: Env field replacement fallout
rg -n "jwksJson" --type haskell              # M2: seam field type change fallout
rg -n "SigningKeyConfig" --type haskell      # M3: newtype→record fallout
```

Live-server run for M4 (PostgreSQL provided by the devshell; see `justfile`):

```bash
just create-database                 # idempotent create + migrate of $PGDATABASE
cabal run exe:shomei-server          # terminal 1; expect "[shomei] listening on :8080"
```

Expected boot log gains nothing new; after a `kill -HUP <pid>`:

```text
[shomei] SIGHUP: reloading signing keys
[shomei] signing keys reloaded: active=Fa9k… published=Fa9k…,q71x…
```


## Validation and Acceptance

Unit/integration acceptance: the M1–M3 test additions pass; `cabal test all` is green.

The definitive acceptance is the rotation runbook against the running server (M4). With the
server from Concrete Steps running and `PG_CONNECTION_STRING` exported for `shomei-admin`:

1. **Baseline.** `curl -s http://localhost:8080/.well-known/jwks.json | jq '.keys | length'`
   → `1`. Sign up and keep the token:

   ```bash
   curl -s -X POST http://localhost:8080/auth/signup -H 'Content-Type: application/json' \
     -d '{"email":"rot@example.com","password":"correct horse battery staple","displayName":"Rot"}' \
     | jq -r .token.accessToken > /tmp/old-token
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/auth/me \
     -H "Authorization: Bearer $(cat /tmp/old-token)"        # → 200
   ```

2. **Rotate.** In terminal 2:

   ```bash
   cabal run shomei-admin -- keys generate            # → "generated pending ES256 key: <NEWKID>"
   cabal run shomei-admin -- keys activate <NEWKID>   # → "activated <NEWKID>" + "retired (auto) <OLDKID>"
   kill -HUP $(pgrep -f exe:shomei-server)            # or wait one refresh interval
   ```

3. **Zero downtime holds.** `curl -s http://localhost:8080/.well-known/jwks.json | jq -r
   '.keys[].kid'` lists **both** kids. The pre-rotation token still works
   (`/auth/me` → `200`). A fresh login's access token carries the new key's kid in its JWT
   header (`curl … login … | jq -r .token.accessToken | cut -d. -f1 | base64 -d` shows
   `"kid":"<NEWKID>"`) — the server now signs with the new key.
   **Before this plan** this step fails twice over: without a restart the JWKS never gains
   `<NEWKID>` and signing never moves; after a restart the old token gets `401`. Either
   way, not zero-downtime.

4. **Revocation is the emergency lever.** `cabal run shomei-admin -- keys revoke <OLDKID>`,
   `kill -HUP …` again → the JWKS lists only `<NEWKID>` and the old token now gets `401`
   at `/auth/me` (deliberately broken, as `docs/user/security.md` documents for revoked
   keys).

5. **Degraded reload.** Stop PostgreSQL and send SIGHUP: the server logs
   `key reload failed … keeping previous key material`, keeps serving, and the JWKS is
   unchanged. Restart PostgreSQL; the next reload succeeds.

Paste the actual transcript into this section when executed. Acceptance = steps 1–5
observed as described, plus a green `cabal test all`.


## Idempotence and Recovery

All source edits are compiler-checked; `cabal build`/`cabal test` re-run safely. There is
no schema migration (the `status` column and its values already exist) and no data change.

`loadKeyMaterial`/`reloadKeys` are read-only against the database and idempotent; reloading
twice is harmless. The swap is a single `writeIORef` of an immutable record: a concurrent
request sees the old or the new `LoadedKeys` in full, never a mixture, and requests already
in flight finish with the material they started with. A failed reload never degrades the
server below its last good state (Decision Log), so the recovery path for any mid-rotation
mistake is: fix the key table with `shomei-admin`, send `SIGHUP` (or wait one interval).

`ensureActiveKey` keeps its existing guard ("generate only when no active key exists"), so
repeated boots never mint spurious keys. If a database's only keys are `retired` (operator
error), boot fails with a clear message — restore signing with `shomei-admin keys generate`
+ `keys activate` and boot again.

The rotation runbook is safe to re-run: extra `pending` keys are harmless (publishable
excludes them), `keys activate` auto-retires prior actives at one timestamp, and
`keys revoke` refuses double-revocation.


## Interfaces and Dependencies

No new library dependencies: `effectful`, `jose`, `hasql`, `aeson`, `unix`
(`System.Posix.Signals`, already used by `Shomei.Server.Boot`) and `base`'s
`Control.Concurrent` cover everything.

Signatures that must exist at the end (full module paths):

- `Shomei.Effect.SigningKeyStore.ListPublishableSigningKeys :: SigningKeyStore m
  [StoredSigningKey]` + helper `listPublishableSigningKeys`, implemented by
  `Shomei.Postgres.SigningKeyStore.runSigningKeyStorePostgres` (SQL
  `status IN ('active','retired')`) and `Shomei.Effect.InMemory.runSigningKeyStore`.
- `Shomei.Jwt.Rotation.currentJwks` built from publishable keys.
- `Shomei.Server.Keys.LoadedKeys { signingKey :: JWK, verifierJwks :: JWKSet,
  jwksBody :: Value }`; `loadKeyMaterial :: Pool -> IO (Either Text LoadedKeys)`;
  `reloadKeys :: Pool -> IORef LoadedKeys -> IO ()`;
  `bootstrapKeys :: SigningAlgorithm -> Pool -> IO LoadedKeys`.
- `Shomei.Server.App.Env.envKeys :: IORef LoadedKeys` (replacing `envKey`/`envJwks`);
  `runAppIO` reads it per invocation.
- `Shomei.Servant.Seam.Env.jwksJson :: IO Value`.
- `Shomei.Config.SigningKeyConfig { algorithm :: Text, refreshIntervalSeconds :: Int }`
  (default 60); env override `SHOMEI_KEY_REFRESH_INTERVAL` in `Shomei.Server.Config`.

Integration points with other plans (restated from the MasterPlan): **this plan owns the
key-loading seam.** Plan 32 (`docs/plans/32-encrypt-signing-private-keys-at-rest.md`) hooks
private-key decryption into the per-row stored→live conversion that `loadKeyMaterial`
performs — keep that conversion funneled through `Shomei.Jwt.Key.fromStoredSigningKey` (or
a successor in the same module) and do not add any other place that parses
`privateKeyJwk`. If plan 32 is in flight simultaneously, reconcile on that function's shape
before either merges. Downstream MasterPlans build on `ListPublishableSigningKeys` as named
here; do not rename it casually.

---

Revision note (2026-07-07): During the cross-plan consistency review at authoring time, the
periodic-reload step was amended to reuse the supervised-background-thread idiom
(`Shomei.Server.Supervisor.supervisedLoop`) owned by
`docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md` when that
module is available, instead of unconditionally hand-rolling an equivalent loop. Reason: the
Operational MasterPlan (`docs/masterplans/6-operational-and-performance-hardening.md`)
designates plan 34 as the owner of that idiom so `shomei-server` grows exactly one way to run
supervised maintenance threads.
