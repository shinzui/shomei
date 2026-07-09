---
id: 5
slug: security-correctness-hardening-make-existing-guarantees-hold
title: "Security Correctness Hardening: Make Existing Guarantees Hold"
kind: master-plan
created_at: 2026-07-07T17:22:07Z
intention: "intention_01kx25bwnqecss3zgjtj70zpce"
---

# Security Correctness Hardening: Make Existing Guarantees Hold

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A July 2026 security review of Shōmei (recorded in this repository's review session; findings
are restated in full inside each child plan) found that the codebase's dangerous fundamentals
are correct — Argon2id with constant-time comparison, hashed-at-rest refresh tokens with
family-revocation reuse detection, alg-confusion-proof JWT verification, fully parameterized
SQL — but that several *documented guarantees silently do not hold*. This initiative makes
every promise in `docs/user/security.md` true in code.

After this initiative is complete: a session that keeps refreshing still dies at its absolute
`expiresAt` deadline; two concurrent presentations of the same refresh token (or the same
password-reset token) can never both succeed, and a lost race is treated as reuse; the
published JWKS at `/.well-known/jwks.json` carries both the active and retired signing keys
and updates without a server restart, so `shomei-admin keys activate` is genuinely
zero-downtime; an unknown login identifier costs the same wall-clock time as a wrong password,
closing the account-enumeration timing oracle; the `emailVerificationRequired` configuration
flag actually blocks unverified logins instead of being a silent no-op; the default notifier
no longer writes usable password-reset and email-verification tokens into logs; cookie-based
token transport either works end-to-end with CSRF defenses (Set-Cookie emission, SameSite,
Origin checking) or is not silently half-accepted; and signing private keys are
envelope-encrypted at rest so a database read no longer yields the ability to forge tokens for
every downstream service.

Out of scope: new features (roles, OIDC, TOTP — see the Interop Wave MasterPlan,
`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`), performance work that does
not change a security property (see `docs/masterplans/6-operational-and-performance-hardening.md`),
and the signup-existence disclosure via `409 email_taken` (accepted product behavior, recorded
in the Decision Log).


## Decomposition Strategy

The review findings cluster naturally by the *invariant* they restore rather than by file.
Each child plan restores one independently verifiable guarantee, can be implemented and tested
without the others, and touches a mostly disjoint region of the codebase — which keeps all
five plans parallelizable.

EP-1 (session expiry and atomic token-state transitions) groups three findings that are all
instances of one defect class: state transitions checked and applied non-atomically, or not
checked at all (`session.expiresAt` never enforced; `markRefreshTokenUsed` lacking a
`status = 'active'` guard; password-reset/email-verification consumption racing). They share
the same fix pattern — conditional `UPDATE … WHERE … AND status = 'active' RETURNING` treated
as a compare-and-swap — and the same test style, so splitting them would create three plans
editing adjacent statements in the same store modules.

EP-2 (JWKS publication and hot reload) is the one finding that spans the port layer
(`SigningKeyStore`), the JWT package (`Rotation`), and the server boot path; it is isolated
because it introduces a new port operation that the Operational MasterPlan and the Interop
MasterPlan both build on.

EP-3 groups three small, unrelated workflow-level fixes (dummy-hash timing equalization,
`emailVerificationRequired` enforcement, notifier token redaction) that are each too small to
be a plan on their own; they share the property of being pure workflow/interpreter edits with
no schema or API-shape change.

EP-4 (cookie transport) is a product decision plus an implementation: the cookie *read* path
is live while nothing ever sets a cookie and no CSRF defense exists. It is its own plan because
it changes the HTTP surface and requires a decision recorded in its Decision Log.

EP-5 (key encryption at rest) is isolated because it is the only plan with a migration and an
operational dependency (a key-encryption-key supplied via configuration), and the only one
where a phased rollout (re-wrap existing rows) matters.

An alternative decomposition by package (core / postgres / server) was rejected because the
session-expiry fix alone spans all three, and package-sliced plans would not be independently
verifiable behaviors.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Enforce Absolute Session Expiry and Atomic Token-State Transitions | docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md | None | None | Complete |
| 2 | Publish and Hot-Reload the Full JWKS with Retired Keys | docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md | None | None | Complete |
| 3 | Login Timing-Oracle Fix, Email-Verification Enforcement, and Notifier Token Redaction | docs/plans/30-login-timing-oracle-fix-email-verification-enforcement-and-notifier-token-redaction.md | None | None | Complete |
| 4 | Complete Cookie Token Transport with CSRF Defenses | docs/plans/31-complete-cookie-token-transport-with-csrf-defenses.md | None | None | Complete |
| 5 | Encrypt Signing Private Keys at Rest | docs/plans/32-encrypt-signing-private-keys-at-rest.md | None | EP-2 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

All five plans can start immediately and proceed in parallel; none produces a type or module
another plan needs to compile.

The single soft dependency is EP-5 on EP-2: both touch the key-loading path in
`shomei-server/src/Shomei/Server/Keys.hs` and the stored-key serialization in
`shomei-jwt/src/Shomei/Jwt/Key.hs`. EP-2 restructures *which* keys are loaded and when they
are refreshed; EP-5 changes *how* each stored row is decrypted on load. Implementing EP-2
first means EP-5 wraps a single, already-centralized load function; implementing them in the
other order works but forces EP-2 to re-plumb the decryption hook. If they end up in flight
simultaneously, reconcile on the shape of the key-loading function before either merges (see
Integration Points).

EP-1 and EP-3 both edit `shomei-core/src/Shomei/Workflow.hs` (the `refresh` and `login`
functions respectively) but in disjoint functions; ordinary rebase discipline is sufficient.


## Integration Points

Key-loading seam (`shomei-server/src/Shomei/Server/Keys.hs`, `shomei-jwt/src/Shomei/Jwt/Key.hs`):
involved plans EP-2 and EP-5. EP-2 owns the seam: it introduces the "load all publishable
keys, build signer + JWKS, refresh periodically" function and the new
`ListPublishableSigningKeys` operation on the `SigningKeyStore` port
(`shomei-core/src/Shomei/Effect/SigningKeyStore.hs`). EP-5 consumes it: decryption of
`private_key_jwk` happens inside the stored-key deserialization that EP-2's loader calls, so
EP-5 must not introduce a second load path. If EP-5 starts before EP-2 lands, it should write
the decryption as a pure `StoredSigningKey -> Either KeyDecryptError JWK` function so EP-2 can
call it from wherever the loader ends up.

Refresh workflow (`shomei-core/src/Shomei/Workflow.hs`, `refresh`): involved plans EP-1 here
and EP-1 of the Operational MasterPlan
(`docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md`), which
wraps the same workflow tail in a single database transaction. This plan (EP-1) owns the
compare-and-swap semantics of `markRefreshTokenUsed` — the conditional UPDATE with
`RETURNING` — because that alone closes the security race even without cross-statement
transactions. The Operational plan layers transaction batching on top and must preserve the
CAS statement shape. Whichever lands second reconciles against the other's store-module edits
in `shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`.

`ShomeiConfig` (`shomei-core/src/Shomei/Config.hs`) and the server config loader
(`shomei-server/src/Shomei/Server/Config.hs`): EP-3 (activates the existing
`emailVerificationRequired` field), EP-4 (activates the existing `TokenTransport` field and
adds cookie/CSRF settings), and EP-5 (adds the key-encryption-key setting) all extend these
records. Additive, order-independent; each plan adds its own fields and defaults and must not
rename existing ones.


## Progress

- [x] EP-1: Session absolute-expiry enforced in `refresh` and `verifyToken`, with regression tests (2026-07-08)
- [x] EP-1: Refresh-token mark-used converted to compare-and-swap; lost race treated as reuse (2026-07-08)
- [x] EP-1: One-time token consumption (password reset, email verification) made atomic (2026-07-08)
- [x] EP-2: `ListPublishableSigningKeys` port operation and interpreters (Postgres, in-memory) (2026-07-08)
- [x] EP-2: JWKS built from active + retired keys; served document and verifier key set agree (2026-07-08)
- [x] EP-2: Periodic (or signal-driven) key reload without restart; rotation runbook re-verified end-to-end (2026-07-08)
- [x] EP-3: Dummy-hash verification on unknown-account login path; timing test (2026-07-08)
- [x] EP-3: `emailVerificationRequired` enforced at login/token issuance (2026-07-08)
- [x] EP-3: `LogNotifier` redacts one-time tokens (hash prefix only) (2026-07-08)
- [x] EP-4: Decision recorded: complete cookie transport (vs. remove read path) (2026-07-08)
- [x] EP-4: Set-Cookie emission on login/refresh/logout honoring `TokenTransport`, with `HttpOnly`/`Secure`/`SameSite` (2026-07-08)
- [x] EP-4: CSRF defense for cookie-authenticated mutations (2026-07-08)
- [x] EP-5: Envelope encryption of `private_key_jwk` behind a configured key-encryption key (2026-07-08)
- [x] EP-5: Migration/backfill path for existing plaintext rows; `shomei-admin` support (2026-07-08)


## Surprises & Discoveries

- **EP-1 changed the guard order in `refresh`, which every later plan touching that function
  must preserve (affects EP-3 here and plan 33 in the Operational MasterPlan).** `refresh` now
  looks the session up *before* checking the presented token's own expiry, and evaluates
  `session.expiresAt` → `session.status` → `token.expiresAt`. This was forced by EP-1's own
  cap (a rotated token expires exactly when its session does), which would otherwise have made
  `SessionExpired` unreachable. Do not reorder these guards back.

- **The in-memory interpreter's `World` is now mutated exclusively through atomic helpers
  (`modifyWorld` / `casWorld` in `shomei-core/src/Shomei/Effect/InMemory.hs`), and
  `Data.IORef.modifyIORef'` is no longer imported there.** Any later plan adding an in-memory
  handler must use these helpers, or it silently reintroduces lost updates under the
  concurrency tests. This is a repository-wide convention now, not an EP-1 detail.

- **Three port operations changed signature from `()` to `Bool`:** `MarkRefreshTokenUsed`,
  `MarkPasswordResetTokenConsumed`, `MarkVerificationTokenConsumed`. Plans that add new
  interpreters of `RefreshTokenStore`, `PasswordResetTokenStore`, or `VerificationTokenStore`
  (notably EP-5's key work does not, but the Operational MasterPlan's transactional wrapper
  does) must implement the compare-and-swap semantics, not merely return `True`.

- **`cabal test all` run in parallel is flaky for `shomei-postgres` — unrelated to any plan
  here.** Under twelve suites building and running at once, the ephemeral-pg harness times out
  starting a database (60 s `ConnectionTimeout`), failing tests that were never touched. Use
  `cabal test all -j1`, or `cabal test shomei-postgres` alone, when validating. Bounding the
  harness's startup concurrency is a candidate item for
  `docs/masterplans/6-operational-and-performance-hardening.md`.

- **The email-verification table is `shomei.shomei_email_verification_tokens`.** EP-1's plan
  text called it `shomei.shomei_verification_tokens`; plans writing SQL against it should use
  the real name.

- **EP-2 replaced `Shomei.Server.App.Env`'s `envKey :: JWK` / `envJwks :: JWKSet` with a
  single `envKeys :: IORef LoadedKeys`, and `bootstrapKeys` now returns `IO LoadedKeys`.**
  Every assembly that builds an `Env` by hand must create the `IORef`: `shomei-client/test`,
  `shomei-server/test/Shomei/Server/E2ESpec.hs`, and both `examples/*/test/Main.hs`. Any later
  plan adding an assembly (or a demo) inherits this. `runAppIO` reads the ref once per
  invocation, so a reload reaches the next request with no application rebuild.

- **`Shomei.Servant.Seam.Env.jwksJson` changed type from `Value` to `IO Value`** (and
  `Seam.verifier` now closes over a `readIORef`). Plans touching the seam — notably EP-4
  (cookie transport), which extends the same record — must construct `jwksJson` with `pure …`
  in test assemblies. This is the only seam-shape change EP-2 makes.

- **EP-5's decryption hook is ready and has exactly one place to go.**
  `Shomei.Server.Keys.loadKeyMaterial` is now the single stored→live load path, and it funnels
  every row through `Shomei.Jwt.Key.fromStoredSigningKey`. EP-5 should make that function (or
  a successor in the same module) perform envelope decryption and must not add a second place
  that parses `privateKeyJwk`. Note `loadKeyMaterial` treats a row that fails conversion as a
  hard error, not a skip — EP-5's "cannot decrypt this row" must therefore surface as a
  `Left`, which on reload takes the keep-last-good path and at boot is fatal.

- **`activated_at` is genuinely nullable in practice, not just in the schema.** The dev
  database holds an `active` key with `activated_at = NULL`. EP-2's signer selection ("greatest
  `activatedAt`, `Nothing` sorts lowest") tolerates it; any plan that sorts or filters on that
  column must not assume `Just`.

- **`SigningKeyConfig` grew from a newtype to a two-field record**
  (`algorithm`, `refreshIntervalSeconds`). EP-3, EP-4, and EP-5 all extend `ShomeiConfig`
  records per IP-3; construction sites of `SigningKeyConfig` itself are now
  `shomei-core/src/Shomei/Config.hs` and `shomei-jwt/test/Shomei/Jwt/RsaCustomClaimSpec.hs`.

- **`shomei-admin-test` now depends on the `shomei-server` library** (it exercises
  `loadKeyMaterial`/`reloadKeys` beside the CLI's key actions). Also: `Shomei.Admin.Keys`
  exports its own `listPublishableSigningKeys` raw-SQL helper, which now collides by name with
  the new port helper — import one qualified.

- **`kill -HUP $(pgrep -f exe:shomei-server)` signals the `cabal run` wrapper, not the
  server.** Any runbook in any plan that sends signals must target the binary from
  `cabal list-bin exe:shomei-server`. Related: port 8080 may be held by an unrelated local
  service; `SHOMEI_PORT` moves the server.

- **EP-3 added `AuthError.EmailNotVerified` (→ `403 email_not_verified`) and
  `NotifierConfig.logRawTokens`.** Any plan that pattern-matches `AuthError` exhaustively, or
  constructs a `NotifierConfig` literal, must handle them. `Shomei.Workflow.refresh` also gained
  a `UserStore :> es` constraint (the user row is loaded only when the flag is on) — plan 33's
  transactional wrapper in the Operational MasterPlan wraps that same function and must carry
  the constraint through.

- **`Shomei.Workflow.Session.ensureEmailVerified :: ShomeiConfig -> User -> Either AuthError ()`
  is the single gate.** Any future token-issuing path (OIDC, TOTP — see the Interop MasterPlan)
  must call it, or it silently becomes a bypass of `emailVerificationRequired`.

- **Dot access on a config record requires importing that record's field selectors,** not just
  its type: `Shomei.Workflow` had to import `NotifierConfig (..)` before
  `cfg.notifierConfig.emailVerificationRequired` would resolve. This is the same
  `DuplicateRecordFields`/`HasField` interaction recorded in MasterPlan 3, and it will bite any
  plan reaching into a nested config record for the first time.

- **`Shomei.Effect.InMemory` now exports `runTokenSigner`/`runTokenVerifier`** (the fake
  interpreters), so a spec can rebuild the `runInMemory` stack with one interpreter swapped —
  how EP-3's `TimingSpec` counts hasher invocations.

- **There is no `SHOMEI_EMAIL_VERIFICATION_REQUIRED` environment variable**; the flag is
  Dhall-file-only. Do not document one without adding it. (A one-line `boolEnv` addition in
  `Shomei.Server.Config.overlayCoreFromEnv` is an easy follow-up, noted in EP-3's Outcomes.)

- **The EP-2 ↔ EP-5 integration contract held exactly as written, and EP-5 corrected EP-2's
  loader.** EP-2's `assembleKeys` parsed the *private* column for every publishable key and then
  stripped it to public; EP-5 repointed publication and the verifier key set at
  `publicJwkFromStored` so only the signer is decrypted. Net rule for every later plan:
  **`private_key_jwk` is parsed in exactly one place** —
  `Shomei.Jwt.KeyProtection.decryptStoredSigningKey`, called only from
  `Shomei.Server.Keys.loadKeyMaterial`. `Shomei.Jwt.Key.fromStoredSigningKey` does *not*
  decrypt and now survives only in tests. Verify with
  `rg -n "fromStoredSigningKey|privateKeyJwk" --type haskell` before adding a key reader.

- **`Shomei.Server.App.Env` gained `envKek :: Maybe KeyEncryptionKey`** (needed so `reloadKeys`
  can decrypt the signer), and `bootstrapKeys` / `loadKeyMaterial` / `reloadKeys` all take a
  `Maybe KeyEncryptionKey` as their first argument. The four hand-built `Env` assemblies pass
  `Nothing`. `KeyEncryptionKey` has no `Show`/`ToJSON` by design — a secret in a loggable record
  is one debug line from disclosure, which is also why it is deliberately *not* in `ShomeiConfig`.

- **A wrong or missing key-encryption key cannot break token verification, only signing.**
  Publication and the verifier key set come from `public_key_jwk`, which is never encrypted. Any
  plan touching key loading must preserve that asymmetry: it is what makes a KEK misconfiguration
  a failed boot rather than a fleet-wide outage of outstanding tokens.

- **`shomei-admin` (the executable) now depends on the `shomei-server` library**, for
  `loadKekFromEnv`/`loadNamedKekFromEnv`. `shomei-admin-test` additionally depends on `ram` (for
  `Data.ByteArray.Encoding` in its KEK fixtures).

- **`Shomei.Admin.Keys.keysGenerate` changed shape to `Maybe KeyEncryptionKey -> SigningAlgorithm
  -> Pool -> IO ()`,** and `Shomei.Jwt.Rotation` gained `rotateSigningKeyForWith`.
  `rotateSigningKeyFor` still writes plaintext (no in-tree callers); library consumers of an
  encrypted deployment must use the `…With` variant.

- **A plaintext `pending` signing key does not trigger the at-rest warning**, because the boot
  check inspects only publishable (`active`/`retired`) rows. Closing this needs a
  `ListAllSigningKeys` port operation — a candidate for a future plan, recorded in EP-5's
  Surprises & Discoveries.

- **Running EP-5's M4 runbook encrypts the dev database under a throwaway key.** If the KEK is
  not preserved, the next `exe:shomei-server` boot refuses to start (correctly). Recovery on a
  dev database: `DELETE FROM shomei.shomei_signing_keys` and boot once without a KEK to
  regenerate a plaintext active key.

- **EP-4 changed the HTTP surface: five responses gained `Set-Cookie` headers and two DTOs
  changed shape.** `TokenPairResponse.accessToken`/`refreshToken` are now `Maybe Text` (omitted,
  not nulled, in cookie-only mode) and `RefreshRequest.refreshToken` is optional. `logout` is
  `Verb 'POST 204 '[JSON] (WithCookies NoContent)` rather than `PostNoContent`, because servant's
  `NoContentVerb` cannot carry headers. Any plan touching these routes or consuming these DTOs
  (including `shomei-client`) inherits the `Maybe`s and must call `getResponse` to unwrap.

- **`Shomei.Servant.Auth.authHandler` now takes a `CookiePolicy` first argument**, built by
  `cookiePolicyFromConfig`. Every assembly that registers the servant `Context`
  (`Shomei.Server.Boot.authContext`, the servant test app, any embedded host) must pass it, or
  the transport and CSRF policy silently do not apply.

- **The CSRF gate is `originHeaderAllowed`, called from two places**: the `AuthHandler` (which has
  a WAI `Request`) and `refreshH` (which receives `Origin`/`Referer` as servant `Header` inputs
  because it is unauthenticated yet reads a cookie). A future token-issuing route that accepts a
  cookie must call it too — nothing enforces this structurally.

- **`config/shomei-types.dhall` is a closed Dhall record and is stale.** It omits
  `signingAlgorithm` (pre-existing), `keyRefreshIntervalSeconds` (EP-2), and EP-4's four cookie
  keys. The loader accepts all of them — every `FileConfig` field is optional — but a config file
  annotated `: ./shomei-types.dhall` cannot use them. Widening it would force every existing
  annotated file to supply the new keys. **Follow-up plan: make the schema's fields `Optional`.**

- **`http-api-data` supplies `ToHttpApiData SetCookie`.** EP-4's plan asserted otherwise and
  budgeted a hand-rolled renderer. Verify a plan's claims about third-party libraries the same way
  you verify its claims about this repo.


## Decision Log

- Decision: Group the three non-atomic state-transition findings (session expiry, refresh CAS,
  one-time-token consumption) into one plan (EP-1) instead of three.
  Rationale: One defect class, one fix pattern (conditional UPDATE … RETURNING as
  compare-and-swap, modeled on the already-correct `PendingCeremonyStore`), shared test
  approach; three plans would edit adjacent code in the same modules.
  Date: 2026-07-07

- Decision: Keep the refresh compare-and-swap in this MasterPlan and the transaction batching
  in the Operational MasterPlan, rather than merging them.
  Rationale: The CAS alone closes the exploitable race (security property); transactions are a
  round-trip optimization that also improves crash behavior (operational property). The CAS is
  small and must not wait on the larger transaction refactor. The shared code is documented as
  an integration point in both MasterPlans.
  Date: 2026-07-07

- Decision: Signup existence disclosure (`409 email_taken` / `login_id_taken`) is accepted and
  will not be changed in this initiative.
  Rationale: Standard product behavior for signup flows; the review rated it Low and noted the
  deliberately non-enumerating reset/verify flows are unaffected. Documenting the asymmetry in
  `docs/user/security.md` is folded into EP-3's documentation touch-ups.
  Date: 2026-07-07

- Decision: EP-4 plans for *completing* cookie transport rather than removing the cookie read
  path.
  Rationale: `TokenTransport` (`HttpOnlyCookie`/`BearerAndCookie`) already exists in config and
  docs; removal would be a breaking retreat from a documented feature. The plan still records
  removal as the fallback if CSRF scope balloons.
  Date: 2026-07-07


## Outcomes & Retrospective

All five child plans are complete (EP-1 on 2026-07-08 in an earlier session; EP-2 through EP-5 on
2026-07-08). `cabal test all -j1` is green across 12 suites. Every guarantee named in Vision &
Scope now holds in code, and each was demonstrated against a running server or a real database
rather than only unit-tested.

**What was actually wrong.** The review's framing was right: the dangerous fundamentals were
correct, and the failures were all *promises the code did not keep*. Three distinct shapes:

1. **Checked non-atomically, or not at all** (EP-1): `session.expiresAt` never enforced;
   `markRefreshTokenUsed` without a status guard; one-time tokens consumable twice.
2. **A documented feature with no consumer** (EP-3's `emailVerificationRequired`) — or worse, a
   feature with a live *consumer* and no producer (EP-4's cookie read path, accepted as a
   credential in every deployment while nothing ever set a cookie and no CSRF defense existed).
   The half-built one was the more dangerous.
3. **A guarantee whose proof was never checked** (EP-2's "zero-downtime rotation", which was
   guaranteed-*downtime* even across a restart, because the restarted server published only the
   active key and rejected every token signed minutes earlier) and one that was simply absent
   (EP-5: the most powerful secret in the system stored in plaintext beside hashed passwords).

**Method that paid off.** Every plan asked for the security-relevant negative to be observed
failing against pre-fix code, once. That discipline caught real things:

- EP-3's `TimingSpec` failed on the *suspended-account* path too, not just the unknown-identifier
  path the review named — confirming the finding understated the oracle.
- EP-4's two negatives reproduced exactly (`expected 401, got 200`; `expected 403, got 204`),
  which is the only evidence that the tests test the fix rather than the implementation.
- EP-5's claim is checkable in one query: after backfill, `SELECT count(*) … WHERE
  private_key_jwk LIKE '%"d"%'` returns `0`.

**Cross-plan integration held.** The EP-2 ↔ EP-5 contract — "decryption is a pure
`StoredSigningKey -> Either KeyDecryptError JWK`, and the loader keeps exactly one stored→live
conversion point" — meant EP-5 changed one call site. It also let EP-5 *correct* EP-2, whose
loader had been building the published JWKS out of private material; publication now reads the
public column and needs no key-encryption key, so a KEK misconfiguration is a failed boot rather
than a fleet-wide outage of outstanding tokens. Contracts that name a function signature work;
contracts that gesture at a seam do not.

**Follow-ups this initiative deliberately did not do:**

- `config/shomei-types.dhall` is a closed Dhall record and now lags six loader-accepted keys.
  Making its fields `Optional` is a small plan of its own (EP-4 Discoveries).
- No `SHOMEI_EMAIL_VERIFICATION_REQUIRED` env var, though every sibling knob has one (EP-3).
- The at-rest boot warning inspects only publishable rows, so a plaintext `pending` key goes
  unremarked until activated; closing it wants a `ListAllSigningKeys` port operation (EP-5).
- EP-2's periodic reload is a hand-rolled `forkIO` loop pending
  `Shomei.Server.Supervisor.supervisedLoop`, which `docs/plans/34-…` owns.
- `rotateSigningKeyFor` still writes plaintext by default (no in-tree callers); library consumers
  of an encrypted deployment must use `rotateSigningKeyForWith`.
- Reload-failure log lines embed the failing SQL. Verbose, no secrets; operational polish.

**Lesson for the next initiative.** The most reliable signal that something is broken was a
*documentation sentence with no test behind it*. `docs/user/security.md` described the intended
property precisely enough to test in four of five cases — and in the fifth (log redaction), fixing
the code falsified a sentence elsewhere in the tree that nothing but grep would have caught.
Treat the docs as the specification, and treat changing an output format as a docs-wide search.
