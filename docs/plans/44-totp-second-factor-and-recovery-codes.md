---
id: 44
slug: totp-second-factor-and-recovery-codes
title: "TOTP Second Factor and Recovery Codes"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# TOTP Second Factor and Recovery Codes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei (this repository, a Haskell authentication toolkit) supports multi-factor
authentication today, but with exactly one second factor: passkeys (WebAuthn). That
leaves a real product hole. When `webauthnConfig.mfaRequired` is on and a user has
enrolled a passkey, losing that passkey locks them out of MFA-gated login with no
fallback factor — their only recourse is the password-reset flow, which sidesteps MFA
entirely rather than completing it.

After this plan, two things exist. First, TOTP (Time-based One-Time Password, RFC 6238 —
the six-digit codes from Google Authenticator, 1Password, and every authenticator app)
is a fully supported second factor: an authenticated user enrolls at
`POST /auth/totp/enroll` (receiving an `otpauth://` URI to scan, shown once), activates
it with a first valid code at `POST /auth/totp/verify`, and thereafter login challenges
them for a code that `POST /auth/mfa/complete` accepts. Second, single-use recovery
codes exist as the lockout escape hatch: `POST /auth/recovery-codes` generates ten
codes (shown once, stored only as hashes), any of which can complete an MFA challenge
exactly once.

The login contract extends *additively*: the existing `mfa_required` response arm gains
a `methods` field advertising which factors can complete the challenge
(`"passkey"`, `"totp"`, `"recovery_code"`), while every field existing passkey-only
clients parse today keeps its exact shape and meaning. The MFA-required policy
generalizes from "has a passkey" to "has any second factor enrolled".

Observable outcome: a full transcript — enroll TOTP, compute a code from the shared
secret, log in, receive `mfa_required` advertising `totp`, complete with the code,
receive tokens; then complete a second login with a recovery code and watch the
remaining-codes count drop; then watch a replayed TOTP code get rejected.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-10): Pure TOTP module `Shomei.Totp` (HMAC-SHA1 over crypton, RFC 6238 vectors pass); Base32 via `ram`'s `Data.ByteArray.Encoding` (no `base32` dep); otpauth URI builder. `TotpSpec` green (14 cases), `cabal test shomei-core` = 225 passed.
- [x] M2 (2026-07-10): Migrations `shomei_totp_credentials` + `shomei_recovery_codes`; `TotpCredentialStore` + `RecoveryCodeStore` ports; in-memory + Postgres interpreters (AES-256-GCM at the Postgres boundary); `TotpConfig` sub-record; new TypeIDs `totp`/`recovery`; all five effect-stack sites + `App.Env.envTotpKey` (dummy key in Boot, real load deferred to M4).
- [x] M2 (2026-07-10): Postgres round-trip tests incl. encryption-at-rest (ciphertext ≠ plaintext, nonce+tag framed) and atomic recovery-code consume-once. `cabal test shomei-core` = 228; `TASTY_NUM_THREADS=1 cabal test shomei-postgres` = 53, both green.
- [x] M3 (2026-07-10): Enrollment/verify/removal workflows + routes (`Shomei.Workflow.Totp`); recovery-code generate/count workflows + routes; `denyUnderImpersonation` on enroll/remove/regenerate; `requireFreshAuth` gate on regenerate.
- [x] M3 (2026-07-10): Login generalization (challenge if any factor enrolled); `LoginResponse` `methods` field (DTO hand-written JSON + OpenAPI oneOf + Arbitrary); `MfaCompleteRequest` union (passkey/totp/recovery_code, exactly-one FromJSON); `MfaCompletion` dispatch in `completeMfa`; replay defense via `last_used_counter`.
- [x] M3 (2026-07-10): Audit events (TotpEnrolled/TotpRemoved/RecoveryCodesGenerated/RecoveryCodeUsed) + codec + spec (39 constructors); `TokenGen.GenerateRandomBytes`; 5 new `AuthError`s + problem specs; in-process HTTP scenario covering enroll→verify→mfa_required(methods)→complete, replay 401, recovery gen/use/count, arity 400, impersonation 403, remove, freshness 403. Also did the OpenAPI schema/path-count/routeErrors work here (planned for M4) to keep every commit's `cabal test shomei-servant` green. `cabal test shomei-core` = 232, `shomei-servant` = 30 + 56, `shomei-postgres` = 53, all green.
- [x] M4 (2026-07-10): Server config wiring — `TotpConfig` merged through `FileConfig`/Dhall (`totpEnabled`, `totpEnrollmentTtlSeconds`) and env (`SHOMEI_TOTP_ENABLED`, `SHOMEI_TOTP_ENROLLMENT_TTL`); `Boot.loadTotpKeyFromEnv` loads `SHOMEI_TOTP_ENCRYPTION_KEY` and fails the boot loudly when TOTP is on and the key is absent/malformed; Dhall types + example updated (type-checks via `dhall-to-json`). `docs/api/openapi.json` regenerated (+557 lines; the +4 path count landed in M3). `docs/user/mfa.md` written; `docs/user/passkeys.md` + `docs/user/api.md` updated.
- [x] M4 (2026-07-10): Postgres E2E transcript automated (`E2ESpec` "EP-7"): signup → enroll → verify → login(mfa)→complete → me(200) → recovery gen → login→complete(recovery) → count 9, real-clock (present the next counter's code), with audit-row and encrypted-at-rest assertions.
- [x] Final (2026-07-10): `cabal build all` OK; `TASTY_NUM_THREADS=1 cabal test all` — all 12 suites PASS. `nix fmt` run; its reformats of files this milestone did not semantically change were reverted per the EP-4 precedent. Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-07-10 (M1) — the `base32` package is unnecessary; `ram`'s `Data.ByteArray.Encoding`
already provides RFC 4648 Base32.** `shomei-core` already depends on `ram` (the memory fork
crypton uses; the tree forbids `memory`). Its `Data.ByteArray.Encoding` exports
`Base (Base16 | Base32 | Base64 | Base64URLUnpadded | Base64OpenBSD)`, so
`convertToBase Base32` / `convertFromBase Base32` give the uppercase RFC 4648 alphabet with
zero new dependencies and no hand-rolled encoder. A 20-byte secret is 160 bits = exactly 32
Base32 chars, so the output is unpadded (no trailing `=` to strip). Verified:
`secretToBase32 (TotpSecret "12345678901234567890") == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"`.
No `cabal.project`/`shomei-core.cabal` dependency block was needed. **M2's AES-256-GCM uses
the same `ram`/crypton surface** (`Crypto.Cipher.AES`, `Crypto.Cipher.Types`), following the
ChaChaPoly1305 AEAD pattern already in `shomei-jwt/src/Shomei/Jwt/KeyProtection.hs`.

**2026-07-10 (M2) — crypton's `aeadSimpleEncrypt` returns `(AuthTag, ciphertext)`, NOT
`(ciphertext, AuthTag)`.** The tag comes first (verified in the crypton source,
`Crypto/Cipher/Types/AEAD.hs`: `aeadSimpleEncrypt aeadIni header input taglen = (tag, output)`).
The compiler catches the swap, but the error message ("expected ByteString, got AuthTag") is
easy to misread. `aeadSimpleDecrypt` takes them in the opposite order (ciphertext then tag).

**2026-07-10 (M2) — the effect stack is FIVE sites and `App.Env` grew a field.** The two new
ports (`TotpCredentialStore`, `RecoveryCodeStore`) went into all five stack declarations the
EP-4/EP-5 notes enumerate, plus `Shomei.Server.App.Env` gained `envTotpKey :: TotpEncryptionKey`
(threaded into `runTotpCredentialStorePostgres` in `runAppIO`, constructed in `Boot.buildEnv`).
The `shomei-postgres` test-suite needed `bytestring` added to its `build-depends` (it had none —
the round-trip tests inspect the raw `secret_enc` bytea). **EP-9 adds a port + column and will
hit the same five-plus sites.**

**2026-07-10 (M3) — the servant HTTP test's clock split: jose validates tokens against the REAL
wall clock, but the app reads the in-memory World clock.** The deterministic World clock means a
confirmed TOTP code cannot be reused for a login at the same time-step counter (the
strictly-greater replay rule), so the test must advance the World clock to move the counter. But
advancing it *forward* past real time makes minted tokens' `nbf`/`iat` future-dated, and jose
rejects them (`401`). The fix: base the scenario's clock ~120 s in the PAST
(`start = now - 120`) and step forward through `[start, start+60, start+120]` — every mint stays
inside jose's `[nbf ≤ realNow ≤ exp]` window while counters still advance. The freshness gate
(`requireFreshAuth`, which uses the World clock's `now`) is then exercised by jumping the World
clock to `start + 660`: the earlier token stays jose-valid (real-time `exp`) yet reads as stale
(`403 reauthentication_required`). **Any future servant test that mints tokens under an advanced
World clock hits this.**

**2026-07-10 (M3) — the login round-trip budget rose 8 → 9.** The generalized MFA gate reads
`findTotpByUser` alongside `countPasskeysByUser` on every login, so `testLoginRoundTripBudget`
tripped (as EP-1 warned it would for factor/claims additions). The `recovery-codes` count is read
only inside the challenge branch, so a no-factor login is +1, not +2. **EP-9's permission claim
will touch the same mint path and trip this again — raise the constant only after justifying the
new round-trip.**

**2026-07-10 (M3) — `TotpEnrolled` fires on confirmation, not on enrollment start.** The plan's
M3 text put `publish TotpEnrolled` in `enrollTotp`, but an abandoned unconfirmed enrollment
should not emit "enrolled". `Shomei.Workflow.Totp.verifyTotpEnrollment` publishes it on the
first-valid-code success instead (matching the event's "a confirmed credential now exists"
meaning); the E2E's `totp_enrolled` assertion still holds because it runs after verify.

**2026-07-10 (M3) — OpenAPI schema work landed in M3, not M4.** `cabal test shomei-servant` runs
the conformance suite (`validateEveryToJSON`, path-count) continuously, so the new DTOs' `ToSchema`
/ `Arbitrary` / `Show`, the `LoginResponse` `methods` branch, the `routeErrors` entries, and the
path-count bump (39 → 43) had to land with the routes to keep every commit green. M4 keeps only
the openapi.json regeneration + docs + server config. `MfaCompleteRequest` and `TotpRemoveRequest`
keep a generic `ToSchema` (all-optional object) rather than a hand-written `oneOf`: the exactly-one
rule lives in `FromJSON`, and an all-optional schema still validates every `ToJSON` output.


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement TOTP by hand over `crypton`'s `Crypto.MAC.HMAC` (already a
  `shomei-core` dependency) rather than adding a TOTP package from Hackage.
  Rationale: The algorithm is ~30 lines (see the embedded RFC 6238 description in
  Context), and the candidate packages are unattractive: `one-time-password` builds on
  the deprecated `cryptonite` and is effectively unmaintained; `OTP`/`hotp`-family
  packages are similarly stale. A hand-rolled implementation pinned by the RFC's own
  test vectors is smaller than the dependency-vetting work and keeps the crypto
  dependency surface unchanged. The `base32` package (same maintainer family as the
  `base64` package already used by `shomei-core`) is added only for RFC 4648 Base32,
  which authenticator apps require for the shared secret.
  Date: 2026-07-07
  **Superseded 2026-07-10 (M1):** no `base32` package was added. `shomei-core` already
  depends on `ram`, whose `Data.ByteArray.Encoding` provides RFC 4648 Base32 via
  `convertToBase Base32` / `convertFromBase Base32`. See Surprises & Discoveries.

- Decision: TOTP secrets are stored *encrypted* (AES-256-GCM), never hashed — and this
  plan supplies its own standalone key handling because no encryption-at-rest machinery
  exists in the tree yet.
  Rationale: A verifier must recompute HMAC(secret, counter) on every login, so it needs
  the secret *back*: hashing (which is one-way) is mathematically incompatible with TOTP
  — this is the opposite of recovery codes, which are compared and can therefore be
  hashed. `docs/plans/32-encrypt-signing-private-keys-at-rest.md` (the plan that would
  introduce a key-encryption-key, "KEK", for signing keys) is an unwritten skeleton as
  of 2026-07-07, verified by its empty Progress section and the absence of any
  KEK/AES/GCM code in the repo. So this plan defines a 32-byte key supplied via
  `SHOMEI_TOTP_ENCRYPTION_KEY` (base64), performs AES-256-GCM with a random 96-bit nonce
  per row (storing `nonce || ciphertext || tag` in one `bytea`), and notes that when
  plan 32 lands, its KEK becomes the natural source for this key — the column format
  will not need to change.
  Date: 2026-07-07

- Decision: Encryption/decryption happens at the Postgres-interpreter boundary
  (`Shomei.Postgres.TotpCredentialStore` takes the key; the port and workflows handle
  raw secrets), and the in-memory interpreter stores raw secrets.
  Rationale: Workflows must stay pure policy over ports (house architecture); pushing
  crypto into the interpreter mirrors how hashing already lives at storage boundaries
  (`Shomei.Postgres.Crypto`), and the in-memory tests should exercise TOTP logic, not
  AES.
  Date: 2026-07-07

- Decision: Fixed TOTP parameters: SHA-1, 30-second period, 6 digits, acceptance window
  of ±1 step; not configurable.
  Rationale: These are the parameters every mainstream authenticator app implements;
  Google Authenticator historically ignores `algorithm`/`digits`/`period` URI overrides,
  so configurability would produce configs that silently break enrollment. ±1 step
  tolerates clock skew up to ~30 s each way, the industry norm.
  Date: 2026-07-07

- Decision: Replay defense is a persisted `last_used_counter` per credential: a code is
  accepted only if its time-step counter is strictly greater than the stored value, which
  is updated on every acceptance.
  Rationale: RFC 6238 §5.2 requires that a verified code must not be accepted twice. A
  strictly-greater rule is stronger than remember-last-only (it also rejects the
  *earlier* window code after a later one succeeded) and needs one bigint column rather
  than a code cache.
  Date: 2026-07-07

- Decision: One TOTP credential per user (`UNIQUE (user_id)`); re-enrolling while an
  unconfirmed enrollment exists replaces it; enrolling while a *confirmed* credential
  exists is refused (remove first).
  Rationale: Multiple authenticators per user multiply the replay-state and UX surface
  for negligible benefit (a second device can scan the same QR at enrollment time);
  refusing silent replacement of a confirmed credential prevents an attacker with a
  stolen session from swapping the factor without notice — removal is a separate,
  audited, impersonation-blocked step.
  Date: 2026-07-07

- Decision: `DELETE /auth/totp` requires a *currently valid* TOTP code (or an unused
  recovery code) in the request body — not merely a fresh session.
  Rationale: Removal is factor-downgrade; proving possession of the factor (or its
  designated fallback) is a stronger gate than token freshness and matches what major
  providers do. The impersonation guard (`denyUnderImpersonation`) additionally blocks
  it under delegated tokens, per the explicit TODO in
  `shomei-servant/src/Shomei/Servant/Handlers.hs` naming TOTP enrollment.
  Date: 2026-07-07

- Decision: `POST /auth/recovery-codes` (regeneration) requires a fresh session: the
  presented access token's `issuedAt` must be within
  `impersonationConfig.actorFreshnessWindow` (default 5 minutes) of now, reusing the
  freshness idiom from `Shomei.Workflow.Impersonation` (factored into a helper).
  Rationale: Regeneration invalidates the old set and prints new secrets; unlike
  removal, there is no "current code" to demand (recovery codes exist for users who
  lost their factor), so token freshness is the strongest gate available. Reusing the
  existing config window avoids a new knob.
  Date: 2026-07-07

- Decision: Recovery codes are ten per set, format `XXXXX-XXXXX` over the Crockford
  base32 alphabet (10 random chars ≈ 50 bits), stored as lowercase SHA-256 hex,
  consumed atomically via compare-and-set (`UPDATE ... WHERE used_at IS NULL RETURNING`).
  Rationale: Ten 50-bit codes is the de-facto industry shape (GitHub-style); Crockford
  base32 avoids ambiguous characters for codes users type by hand; SHA-256 of a 50-bit
  random value is the same defensible pattern the repo already uses for service-token
  secrets; the CAS consumption makes double-spend impossible even under concurrent
  requests.
  Date: 2026-07-07

- Decision: `MfaCompleteRequest` becomes a hand-written union over one flat JSON object:
  `ceremonyId` stays required; exactly one of `assertion` (passkey, the existing field),
  `totpCode`, or `recoveryCode` must be present. The legacy shape
  `{"ceremonyId": ..., "assertion": ...}` parses unchanged.
  Rationale: Existing clients send the legacy shape today; a tagged-union redesign
  (like `LoginResponse`'s `status` tag) would break them. Optional fields with an
  exactly-one validation rule keep the wire compatible while the OpenAPI schema
  documents the three shapes as a `oneOf`.
  Date: 2026-07-07

- Decision: The `mfa_required` login arm always creates a pending ceremony (the existing
  consume-once `PendingCeremonyStore` record) regardless of which factors the user has;
  for passkey-holders it carries WebAuthn options as today, for TOTP-only users
  `options` is the empty JSON object `{}`. The new `methods` array tells clients what to
  do; `ceremonyId` and `options` remain required fields.
  Rationale: The ceremony record is what binds the half-finished login to a user and
  makes completion single-use — TOTP needs that binding exactly as much as WebAuthn
  does. Keeping `options` present (if sometimes empty) preserves the existing arm's
  required-field contract, so current clients keep parsing; a TOTP-only user is a state
  no existing deployment has, so no current client can receive `{}` options unexpectedly.
  Date: 2026-07-07

- Decision: `webauthnConfig.mfaRequired` keeps its name and Dhall/env spelling but its
  documented meaning generalizes to "users with *any* enrolled second factor must
  complete MFA at login".
  Rationale: Renaming the field would break existing configs for zero functional gain;
  the semantics are the natural reading once more factors exist. The docs change is
  explicit (M4).
  Date: 2026-07-07


- Decision (2026-07-10, M3): `TotpEnrolled` is published on confirmation
  (`verifyTotpEnrollment`), not on `enrollTotp`.
  Rationale: an unconfirmed enrollment that a user abandons should not appear in the audit
  trail as "enrolled"; the event's meaning is "a confirmed credential now exists". The E2E's
  `totp_enrolled` assertion runs after verify, so it is unaffected.
  Date: 2026-07-10

- Decision (2026-07-10, M3): the recovery-code normalization+hash is centralized in
  `Shomei.Workflow.Totp.recoveryCodeHash` (`sha256Hex . toLower . filter (/= '-')`), imported by
  `Shomei.Workflow.Mfa`, so generation and consumption cannot drift on normalization.
  Rationale: the code is stored hashed at generation and compared hashed at consumption in two
  different modules; a single definition removes the drift risk the plan flagged.
  Date: 2026-07-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Delivered (2026-07-10).** Every item in the Purpose exists and is proven end-to-end. TOTP
(RFC 6238) is a first-class second factor: enroll at `POST /v1/auth/totp/enroll` (secret shown
once as Base32 + `otpauth://` URI), activate at `POST /v1/auth/totp/verify`, and complete a login
challenge at `POST /v1/auth/mfa/complete` with a `totpCode`. Ten single-use recovery codes back
it (and passkey-only users) as the lockout escape hatch. The `mfa_required` login arm extended
purely additively — a `methods` list was added; every field passkey-only clients parse keeps its
shape — and the MFA-required policy generalized from "has a passkey" to "has any confirmed
factor". Secrets are AES-256-GCM-encrypted at rest under a key held outside the database
(`SHOMEI_TOTP_ENCRYPTION_KEY`); recovery codes are stored SHA-256-hashed; replay is defended by a
persisted `last_used_counter`. The full transcript reproduces in the automated Postgres E2E.

**Against the original purpose:** the observable outcome the Purpose named — enroll, compute a
code, log in, receive `mfa_required` advertising `totp`, complete, then complete a second login
with a recovery code and watch the count drop, then watch a replayed code get rejected — is
exactly what `shomei-servant`'s in-process HTTP scenario and `shomei-server`'s real-Postgres E2E
assert.

**Scope deltas from the plan, all recorded in the Decision Log / Surprises:** (a) the `base32`
package was unnecessary — `ram`'s `Data.ByteArray.Encoding` already provides RFC 4648 Base32; (b)
`TotpEnrolled` fires on confirmation, not on enroll start; (c) the OpenAPI schema work (planned
for M4) landed in M3 to keep every commit's conformance suite green; (d) `MfaCompleteRequest` /
`TotpRemoveRequest` use a generic all-optional `ToSchema` rather than a hand-written `oneOf`
(the exactly-one rule lives in `FromJSON`).

**Lessons for later plans (EP-9 especially).** The effect stack is five-plus sites and
`App.Env` grew a field; the login round-trip budget guard trips on any mint-path read (8 → 9
here); crypton's `aeadSimpleEncrypt` returns `(tag, ciphertext)`; and the servant test harness's
jose-real-clock vs. World-clock split forces token-minting steps to sit in the past. All are in
Surprises & Discoveries.


## Context and Orientation

The repository is a multi-package Haskell Cabal project at
`/Users/shinzui/Keikaku/bokuno/shomei` (GHC 9.12.4; work inside `nix develop`;
`cabal build all`; `cabal test all`; dev database `just create-database`; format
`nix fmt`). `shomei-core` holds domain types, workflows, and `effectful` effect ports
(GADTs, dynamic dispatch, `send`-wrapper smart constructors) with in-memory test
interpreters in `shomei-core/src/Shomei/Effect/InMemory.hs` (a `World` record behind an
`IORef`; add fields to `World` + `emptyWorld` + a `runXStore` + `runInMemory`);
`shomei-postgres` holds hasql interpreters (pattern:
`shomei-postgres/src/Shomei/Postgres/PasskeyStore.hs`); `shomei-migrations` holds codd
SQL migrations, embedded at compile time (`just migrate` touches the cabal file to force
re-embedding; scaffold with `just new-migration name=<slug>`); `shomei-servant` is the
HTTP layer; `shomei-server` the Warp server and config loader. Any new effect must be
registered, in the same position, in three ordered stacks:
`Shomei.Servant.Seam.AppEffects`, `Shomei.Server.App.AppEffects` + `runAppIO`, and
`Shomei.Effect.InMemory.runInMemory`.

The MFA machinery this plan extends, verified in the working tree:

*Login decision.* There is no `Workflow/Login.hs`; `login` lives in
`shomei-core/src/Shomei/Workflow.hs`. After the password factor succeeds (lines ~227-234):

```haskell
passkeyCount <- countPasskeysByUser user.userId
if mfaRequired (webauthnConfig cfg) && passkeyCount > 0
    then do
        (cid, optionsJson) <- prepareMfaChallenge cfg user ts
        pure (MfaRequired MfaChallenge {ceremonyId = cid, options = optionsJson})
    else do
        (_sid, pair) <- issueSession cfg user ts
        pure (LoginComplete user pair)
```

`LoginResult = LoginComplete User TokenPair | MfaRequired MfaChallenge` with
`MfaChallenge { ceremonyId :: CeremonyId, options :: Value }`.

*Pending ceremonies.* `Shomei.Effect.PendingCeremonyStore`
(`shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs`) is the consume-once binding
between a challenge and its completion: `PutPendingCeremony`,
`TakePendingCeremony :: CeremonyId -> UTCTime -> ... m (Maybe PendingCeremony)` (removes
the row, returns it only if unexpired — an expired row is deleted and unrecoverable),
`DeleteExpiredCeremonies`. `PendingCeremony` carries `ceremonyId`,
`userId :: Maybe UserId`, `kind :: CeremonyKind (RegistrationCeremony |
AuthenticationCeremony)`, `optionsBlob :: ByteString`, `createdAt`, `expiresAt`
(TTL from `webauthnConfig.pendingCeremonyTTL`).

*Challenge and completion.* `shomei-core/src/Shomei/Workflow/Mfa.hs`:
`prepareMfaChallenge cfg user ts` finds the user's passkeys, begins a WebAuthn
authentication ceremony, stores the pending record, publishes `Event.MfaChallenged`, and
returns `(CeremonyId, Value)`. `completeMfa cfg ceremonyId assertion` consumes the
ceremony (`takePendingCeremony`, miss → `PendingCeremonyNotFound`), requires
`kind == AuthenticationCeremony` and a bound `userId`, verifies the WebAuthn assertion,
and issues the session via the shared `Shomei.Workflow.Session.issueSession`, publishing
`Event.MfaSucceeded`.

*Wire shapes.* `shomei-servant/src/Shomei/Servant/DTO.hs` (~lines 128-164) defines the
status-tagged union with hand-written JSON instances — you must extend BOTH the
instances and the matching hand-written OpenAPI schema:

```haskell
data LoginResponse
    = LoginCompleteResponse { user :: !UserResponse, token :: !TokenPairResponse }
    | LoginMfaRequiredResponse { ceremonyId :: !Text, options :: !Value }
```

serialized as `{"status":"complete","user":...,"token":...}` and
`{"status":"mfa_required","ceremonyId":"...","options":{...}}`. And the flat

```haskell
data MfaCompleteRequest = MfaCompleteRequest { ceremonyId :: !Text, assertion :: !Value }
```

handled by `mfaCompleteH` in `Handlers.hs` (parses `ceremonyId` with `parseId`, calls
`Mfa.completeMfa`). `POST /auth/mfa/complete` is unauthenticated (the ceremony *is* the
credential).

*OpenAPI.* `shomei-servant/src/Shomei/Servant/OpenApi.hs` hand-writes a
`ToSchema LoginResponse` as a `oneOf` of the two branch object schemas (required fields
listed per branch). The conformance suite `shomei-servant/test-openapi/Main.hs` runs
`validateEveryToJSON`, asserts the path count (24 at authoring time — recount, since
plans 41/42 may have landed first), and holds hand-written `Arbitrary` instances
including one for `LoginResponse` — every new variant/field must appear in all three
places or the suite fails.

*Impersonation guard.* `denyUnderImpersonation :: Env -> Text -> AuthUser -> Handler ()`
in `Handlers.hs` refuses delegated tokens (claims carry `actor`) with 403 + an
`ImpersonationActionBlocked` audit event; it is already called by password-change and
passkey enroll/remove handlers, and its comment explicitly lists TOTP enrollment as a
future call site.

*Crypto available.* `shomei-core` already depends on `crypton` (`Crypto.Hash`,
`Crypto.MAC.HMAC` available; no HMAC use exists yet) and `base64`; **no `base32` package
is present** (needed for the otpauth secret — M1 adds it). The SHA-256-hex pattern to
copy for recovery-code hashing is `sha256Hex` in
`shomei-core/src/Shomei/Workflow/ServiceToken.hs`. No encryption-at-rest machinery
exists anywhere (see Decision Log).

*Freshness idiom.* The only "recent authentication" gate in the tree is inline in
`Shomei.Workflow.Impersonation`:
`when (ts > addUTCTime imp.actorFreshnessWindow caller.issuedAt) ...` — M3 factors it
into a reusable helper.

*Audit events.* `Shomei.Domain.Event` already has factor-agnostic `MfaChallenged`
(carries a `CeremonyId` — fine, since this plan always creates a ceremony),
`MfaSucceeded`, `MfaFailed { userId :: Maybe UserId, reason :: Text, ... }`; the codec
(`Shomei.Domain.EventCodec`) maps constructors to `event_type` strings with a pinned
round-trip spec.

Embedded algorithm knowledge — RFC 6238 TOTP, complete enough to implement from this
text alone. TOTP is HOTP (RFC 4226) applied to time. Let `K` be a shared secret
(20 random bytes here), `T0 = 0`, `X = 30` seconds. The *time-step counter* is
`C = floor(unixTime / X)`. Compute `H = HMAC-SHA1(K, C_bytes)` where `C_bytes` is `C` as
an 8-byte big-endian integer. *Dynamic truncation*: let `o` = the low 4 bits of the last
byte of `H` (an offset 0..15); take the 4 bytes `H[o..o+3]` as a big-endian integer and
clear its top bit (`.&. 0x7fffffff`), giving a 31-bit number `S`. The code is
`S mod 10^6`, rendered as exactly 6 digits with leading zeros. Verification: compute the
expected code for counters `C-1`, `C`, `C+1` (the ±1 window) and accept a match whose
counter is strictly greater than the credential's `last_used_counter`, then persist that
counter. The enrollment URI understood by authenticator apps is
`otpauth://totp/{issuerLabel}:{account}?secret={BASE32(K)}&issuer={issuerLabel}` where
BASE32 is RFC 4648 (uppercase, unpadded), `issuerLabel` is Shōmei's configured issuer
text made label-safe, and `account` is the user's login id. RFC 6238 Appendix B provides
test vectors with the ASCII secret `12345678901234567890` and 8-digit output — e.g.
Unix time 59 → `94287082`, 1111111109 → `07081804`, 1234567890 → `89005924`,
2000000000 → `69279037` — implement the code function with a digits parameter so the
tests pin these exactly, while production fixes digits at 6.


## Plan of Work

Four milestones, each independently verifiable.

### Milestone M1 — A proven TOTP primitive

Scope: a pure module with no I/O, pinned by the RFC's own vectors, plus Base32 and the
otpauth URI. Nothing else in the system changes yet.

Add `base32` to `shomei-core/shomei-core.cabal` (it is in the pinned nixpkgs Haskell set;
if `cabal build shomei-core` fails to resolve it, record the failure and fall back to
hand-rolling RFC 4648 Base32 in the same module — 20 lines — noting the choice in the
Decision Log).

Create `shomei-core/src/Shomei/Totp.hs`:

```haskell
newtype TotpSecret = TotpSecret ByteString   -- 20 raw bytes; Show instance redacts

totpCode :: Int -> TotpSecret -> Int64 -> Text
-- totpCode digits secret counter: HMAC-SHA1 + dynamic truncation, zero-padded

totpCounter :: UTCTime -> Int64
-- floor(unixTime / 30)

verifyTotp :: TotpSecret -> Maybe Int64 -> UTCTime -> Text -> Maybe Int64
-- verifyTotp secret lastUsedCounter now presented:
-- tries counters [c-1, c, c+1]; returns Just acceptedCounter when the presented
-- 6-digit code matches AND acceptedCounter > lastUsedCounter (Nothing bound = any);
-- comparison of code text uses constant-time equality (Data.ByteArray.constEq).

secretToBase32 :: TotpSecret -> Text
otpauthUri :: Text -> Text -> TotpSecret -> Text
-- otpauthUri issuerLabel accountLabel secret
```

HMAC via `Crypto.MAC.HMAC` (`hmac :: ByteString -> ByteString -> HMAC SHA1`, then
`Data.ByteArray.convert` to bytes). Add `shomei-core/test/Shomei/TotpSpec.hs` pinning the
four RFC vectors above at 8 digits, a 6-digit derivation of one of them, the window
behavior (code for `c-1` accepted at `c`, code for `c-2` rejected), the
strictly-greater-counter rule, and a Base32 round-trip.

Acceptance for M1: `cabal test shomei-core` green with `TotpSpec`.

### Milestone M2 — Storage: encrypted secrets, hashed recovery codes

Scope: schema, ports, both interpreters, config. At the end, Postgres round-trips an
encrypted secret and consumes recovery codes atomically.

Two migrations (`just new-migration name=shomei-totp-credentials`, then
`...name=shomei-recovery-codes`; scaffolder emits the codd header):

```sql
CREATE TABLE IF NOT EXISTS shomei_totp_credentials (
  totp_credential_id uuid PRIMARY KEY,
  user_id            uuid NOT NULL UNIQUE REFERENCES shomei_users(user_id),
  secret_enc         bytea NOT NULL,
  last_used_counter  bigint NULL,
  confirmed_at       timestamptz NULL,
  created_at         timestamptz NOT NULL
);
```

```sql
CREATE TABLE IF NOT EXISTS shomei_recovery_codes (
  recovery_code_id uuid PRIMARY KEY,
  user_id          uuid NOT NULL REFERENCES shomei_users(user_id),
  code_hash        text NOT NULL,
  created_at       timestamptz NOT NULL,
  used_at          timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_recovery_codes_user_id_idx
  ON shomei_recovery_codes (user_id);
```

`secret_enc` layout: `nonce (12 bytes) || ciphertext || GCM tag (16 bytes)`.
`confirmed_at IS NULL` marks an unactivated enrollment; rows older than
`totpConfig.enrollmentTTL` with NULL `confirmed_at` are treated as absent (and replaced
on re-enroll). New TypeIDs in `Shomei.Id`: `type TotpCredentialId = KindID "totp"`,
`type RecoveryCodeId = KindID "recovery"` (plus gen/UUID helpers per the file's pattern).

Ports (`shomei-core/src/Shomei/Effect/TotpCredentialStore.hs` and
`.../RecoveryCodeStore.hs`):

```haskell
data TotpCredentialStore :: Effect where
  UpsertTotpEnrollment :: NewTotpCredential -> TotpCredentialStore m TotpCredential
  FindTotpByUser :: UserId -> TotpCredentialStore m (Maybe TotpCredential)
  ConfirmTotp :: TotpCredentialId -> UTCTime -> TotpCredentialStore m ()
  SetTotpLastUsedCounter :: TotpCredentialId -> Int64 -> TotpCredentialStore m ()
  DeleteTotpByUser :: UserId -> TotpCredentialStore m ()

data RecoveryCodeStore :: Effect where
  ReplaceRecoveryCodes :: UserId -> [NewRecoveryCode] -> RecoveryCodeStore m ()
  ConsumeRecoveryCode :: UserId -> Text -> UTCTime -> RecoveryCodeStore m Bool
  CountUnusedRecoveryCodes :: UserId -> RecoveryCodeStore m Int
```

`TotpCredential` carries the *raw* `TotpSecret` (Decision Log: crypto at the interpreter
boundary). `ConsumeRecoveryCode userId codeHash now` is the CAS:
`UPDATE shomei_recovery_codes SET used_at = $3 WHERE user_id = $1 AND code_hash = $2 AND
used_at IS NULL RETURNING recovery_code_id` → `True` iff a row returned; the in-memory
interpreter mirrors the same single-winner semantics. `ReplaceRecoveryCodes` deletes the
user's existing rows and inserts the new set in one transaction.

Postgres interpreters `shomei-postgres/src/Shomei/Postgres/TotpCredentialStore.hs`
(signature `runTotpCredentialStorePostgres :: (...) => TotpEncryptionKey -> Eff (TotpCredentialStore : es) a -> Eff es a`,
where `TotpEncryptionKey` is a 32-byte newtype defined beside the interpreter's AES
helper — encrypt on write, decrypt on read using crypton's `Crypto.Cipher.AES.AES256` +
`Crypto.Cipher.Types` AEAD-GCM; nonce from `Crypto.Random.getRandomBytes`) and
`.../RecoveryCodeStore.hs`. In-memory: new `World` fields
(`totpCredentials :: Map UserId TotpCredential`,
`recoveryCodes :: Map RecoveryCodeId RecoveryCode`), interpreters, `runInMemory`
registration; plus the two `AppEffects` lists in `Shomei.Servant.Seam` and
`Shomei.Server.App` (thread the key from `Env` in `runAppIO`).

Config: add to `Shomei.Config`:

```haskell
data TotpConfig = TotpConfig
  { totpEnabled :: !Bool,              -- default False
    enrollmentTTL :: !NominalDiffTime  -- default 15*60
  }
```

(the encryption *key* is deliberately not in `ShomeiConfig` — it is a secret, loaded by
`shomei-server` from `SHOMEI_TOTP_ENCRYPTION_KEY` in M4 and carried in the server `Env`).

Tests: Postgres round-trip (enroll → find returns the same raw secret → confirm →
counter update → delete), encryption sanity (the stored `secret_enc` bytea differs from
the plaintext and decrypts back), recovery-code CAS (consume succeeds once, second
consume of the same code returns `False`, count drops), replace-set semantics.

Acceptance for M2: `cabal test shomei-core shomei-postgres` green; `just migrate` applies
both migrations (remember the `embedDir` recompile caveat — `just migrate` handles it).

### Milestone M3 — Workflows, routes, and the generalized login

Scope: the user-facing feature. At the end, the whole flow works in-process: enroll,
verify, challenge, complete via TOTP and via recovery code, remove, regenerate, count —
with every guard.

Workflows in a new `shomei-core/src/Shomei/Workflow/Totp.hs`:

`enrollTotp cfg user ts` — refuse when `totpConfig.totpEnabled` is off
(new error `TotpDisabled`) or a *confirmed* credential exists (`TotpAlreadyEnrolled`);
generate 20 random bytes via the existing `TokenGen` port (add a
`GenerateRandomBytes :: Int -> TokenGen m ByteString` operation if the port lacks one —
check `shomei-core/src/Shomei/Effect/TokenGen.hs` first and reuse what exists);
`UpsertTotpEnrollment`; publish `TotpEnrolled` (audit events for this plan:
`TotpEnrolled`, `TotpRemoved`, `RecoveryCodesGenerated { count }`, `RecoveryCodeUsed` —
each with userId/occurredAt, wired through `Event.hs`, `EventCodec.hs` with event types
`totp_enrolled`, `totp_removed`, `recovery_codes_generated`, `recovery_code_used`, and
the codec spec); return the raw secret + otpauth URI (shown once — never retrievable
again).

`verifyTotpEnrollment cfg user ts code` — load the unconfirmed, unexpired enrollment
(`TotpEnrollmentNotFound` otherwise); `verifyTotp` with `Nothing` bound; on success
`ConfirmTotp` + `SetTotpLastUsedCounter` (activation consumes the code's counter too);
failure → `TotpCodeInvalid` + publish `MfaFailed` with reason `"totp_invalid"`.

`removeTotp cfg user ts proof` — where `proof` is a current TOTP code or a recovery
code (Decision Log); verify whichever is presented (recovery path consumes the code and
publishes `RecoveryCodeUsed`); `DeleteTotpByUser`; publish `TotpRemoved`.

`regenerateRecoveryCodes cfg user ts` — generate ten codes (random bytes → Crockford
base32 → `XXXXX-XXXXX`); store SHA-256 hex hashes via `ReplaceRecoveryCodes`; publish
`RecoveryCodesGenerated`; return the plaintext codes once. Recovery codes may be
generated whether or not TOTP is enrolled (they also back up passkey-only users).

Generalize the login decision in `shomei-core/src/Shomei/Workflow.hs`: replace the
passkey-count condition with

```haskell
passkeyCount <- countPasskeysByUser user.userId
totpEnrolled <- maybe False (isJust . (.confirmedAt)) <$> findTotpByUser user.userId
let hasSecondFactor = passkeyCount > 0 || totpEnrolled
if mfaRequired (webauthnConfig cfg) && hasSecondFactor then {- challenge -} else {- issue -}
```

and generalize `prepareMfaChallenge` in `Workflow/Mfa.hs`: it now computes the method
list (`"passkey"` when `passkeyCount > 0`, `"totp"` when confirmed TOTP exists,
`"recovery_code"` when the unused count is positive); when passkeys exist it begins the
WebAuthn ceremony exactly as today; when none do, it creates the pending ceremony with
`kind = AuthenticationCeremony`, the user bound, and an empty `optionsBlob` — no WebAuthn
call. `MfaChallenge` gains a `methods :: [Text]` field; `LoginResult` is otherwise
unchanged.

Extend `completeMfa` into a dispatch on a new completion type:

```haskell
data MfaCompletion = MfaPasskey Value | MfaTotp Text | MfaRecoveryCode Text
```

Common prefix: `takePendingCeremony` (consume-once), kind/user checks, load user, require
active. `MfaPasskey` → the existing assertion verification (refuse when the ceremony's
`optionsBlob` is empty — no ceremony was begun). `MfaTotp` → load confirmed credential,
`verifyTotp` against `last_used_counter`, persist the accepted counter
(`SetTotpLastUsedCounter`), failure → `TotpCodeInvalid` + `MfaFailed`. `MfaRecoveryCode`
→ normalize (strip the dash, casefold), hash, `ConsumeRecoveryCode` (CAS), `False` →
`RecoveryCodeInvalid` + `MfaFailed`; on success also publish `RecoveryCodeUsed`. All
three converge on `issueSession` + `MfaSucceeded`, exactly as today. Note the consume-once
ceremony means a failed TOTP attempt spends the ceremony — the client re-logs-in to get a
fresh one; this matches the existing passkey behavior and keeps brute-force bounded to
one guess per password proof (state this in the docs).

HTTP layer. New routes on `ShomeiAPI` (all `Authenticated` except none — these manage
the *caller's own* factors):

```haskell
totpEnroll   :: mode :- "auth" :> "totp" :> "enroll" :> Authenticated :> Post '[JSON] TotpEnrollResponse
totpVerify   :: mode :- "auth" :> "totp" :> "verify" :> Authenticated :> ReqBody '[JSON] TotpVerifyRequest :> Post '[JSON] NoContent
totpDelete   :: mode :- "auth" :> "totp" :> Authenticated :> ReqBody '[JSON] TotpRemoveRequest :> Delete '[JSON] NoContent
recoveryCodesGenerate :: mode :- "auth" :> "recovery-codes" :> Authenticated :> Post '[JSON] RecoveryCodesResponse
recoveryCodesCount    :: mode :- "auth" :> "recovery-codes" :> Authenticated :> Get '[JSON] RecoveryCodesCountResponse
```

DTOs: `TotpEnrollResponse { secret :: Text, otpauthUri :: Text }` (Base32 secret, shown
once), `TotpVerifyRequest { code :: Text }`,
`TotpRemoveRequest { code :: Maybe Text, recoveryCode :: Maybe Text }` (exactly one),
`RecoveryCodesResponse { codes :: [Text] }`,
`RecoveryCodesCountResponse { remaining :: Int }`. Handlers call
`denyUnderImpersonation env "totp_enroll" user` (and `"totp_remove"`,
`"recovery_codes_generate"`) first, per the existing guard's TODO;
`recoveryCodesGenerate` additionally enforces the freshness gate — factor the
impersonation freshness check into `requireFreshAuth :: Env -> AuthUser -> Handler ()`
(comparing `authClaims.issuedAt` against `impersonationConfig.actorFreshnessWindow`) and
call it here. New `AuthError`s (`TotpDisabled`, `TotpAlreadyEnrolled`,
`TotpEnrollmentNotFound`, `TotpCodeInvalid`, `RecoveryCodeInvalid`) map in
`Shomei.Servant.Error` to 403/409/404/401/401 with distinct machine codes.

The additive DTO change, exact JSON. `LoginMfaRequiredResponse` gains
`methods :: [Text]`. Before this plan a passkey-holder's login returns:

```json
{"status":"mfa_required","ceremonyId":"webauthn_ceremony_01...","options":{"publicKey":{"...":"..."}}}
```

After this plan, the same user sees one added field, nothing else changed:

```json
{"status":"mfa_required","ceremonyId":"webauthn_ceremony_01...","options":{"publicKey":{"...":"..."}},"methods":["passkey","totp"]}
```

and a TOTP-only user sees:

```json
{"status":"mfa_required","ceremonyId":"webauthn_ceremony_01...","options":{},"methods":["totp","recovery_code"]}
```

Update the hand-written `ToJSON`/`FromJSON` (`FromJSON` treats a missing `methods` as
`["passkey"]` for compatibility with recorded fixtures), the hand-written OpenAPI
`oneOf` branch (add `methods` to the mfa branch's properties and required list), and the
test-suite `Arbitrary`. `MfaCompleteRequest` becomes
`{ ceremonyId :: Text, assertion :: Maybe Value, totpCode :: Maybe Text, recoveryCode :: Maybe Text }`
with a hand-written `FromJSON` enforcing exactly-one (else 400) and mapping to
`MfaCompletion`; its OpenAPI schema becomes a `oneOf` of the three shapes; the legacy
two-field JSON parses as the passkey arm unchanged.

In-process HTTP tests (`shomei-servant/test/Main.hs`): enroll → verify with a code
computed by `Shomei.Totp.totpCode` from the returned secret (the deterministic test
clock makes this exact) → login → `mfa_required` with `methods` containing `totp` →
complete with the code → tokens; replay the same code at a fresh challenge → 401
`totp_code_invalid`; complete with a recovery code → tokens, count drops by one, same
code again → 401; wrong exactly-one arity in `MfaCompleteRequest` → 400; enroll under a
delegated token → 403 `impersonation_action_blocked`; `DELETE /auth/totp` with a valid
code → 204, then login no longer challenges (no other factor); regenerate with a stale
token (advance clock beyond the freshness window) → 403; passkey completion still works
(existing scenario untouched).

Acceptance for M3: `cabal test shomei-core shomei-servant` green with all of the above.

### Milestone M4 — Server wiring, spec, docs, E2E

Scope: configuration surface, OpenAPI, documentation, and the live proof.

Server config (`shomei-server/src/Shomei/Server/Config.hs` + `config/shomei-types.dhall`
+ `config/shomei.example.dhall`): `totpEnabled` (Dhall + `SHOMEI_TOTP_ENABLED`),
`totpEnrollmentTTL` seconds, and the key env var `SHOMEI_TOTP_ENCRYPTION_KEY`
(base64 of exactly 32 bytes; decoded at boot into the server `Env`; boot fails loudly
when TOTP is enabled and the key is absent/malformed — copy the loud-failure style of
the existing service-token config validation). Document generating a key:

```bash
openssl rand -base64 32
```

Update `Shomei.Server.App.Env` with the key field and thread it into
`runTotpCredentialStorePostgres` inside `runAppIO` (when TOTP is disabled, pass a dummy
key — the store is unreachable because enrollment is refused, but the interpreter stack
shape stays fixed).

OpenAPI: five new routes = four new paths (`/auth/totp/enroll`, `/auth/totp/verify`,
`/auth/totp`, `/auth/recovery-codes` — the last carries GET and POST on one path). Add
`ToSchema`/`Arbitrary`/`Show` for the five DTOs, update the path-count assertion by +4
from whatever it currently is, regenerate `docs/api/openapi.json`
(`cabal run shomei-openapi > docs/api/openapi.json`), and confirm the conformance suite
validates the new `oneOf` schemas against the hand-written JSON instances.

Docs: write `docs/user/mfa.md` — factor overview (passkeys link out to
`docs/user/passkeys.md`), TOTP enrollment walkthrough with the otpauth QR note, the
fixed parameters, replay/lockout semantics (one completion guess per ceremony), recovery
codes (shown once, count endpoint, regeneration invalidates), removal proof requirement,
the `mfa_required` wire contract before/after JSON (copy from M3), and the
`SHOMEI_TOTP_ENCRYPTION_KEY` operational note (key loss = users must re-enroll TOTP;
recovery codes and passkeys unaffected). Update `docs/user/passkeys.md`'s "Recovery:
losing a passkey" section to point at recovery codes and TOTP as the in-MFA fallback,
and its `mfaRequired` config row to the generalized meaning. Update `docs/user/api.md`
with the five endpoints.

E2E (`shomei-server/test/Shomei/Server/E2ESpec.hs`, real Postgres + Warp, with
`totpEnabled = True` and a test key in the config): signup → login (no MFA) → enroll →
verify (compute the code with `Shomei.Totp` against the real clock — allow the ±1
window) → login again → `mfa_required` → complete with a fresh code → tokens verify
against JWKS → generate recovery codes → complete another login with one → remaining
count is 9 → audit rows `totp_enrolled`, `mfa_succeeded`, `recovery_codes_generated`,
`recovery_code_used` exist.

Acceptance for M4: `cabal test all` green; the Validation transcript reproduces.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. Baseline:

```bash
cabal build all
cabal test shomei-core shomei-servant
```

M1:

```bash
cabal build shomei-core          # resolves the new base32 dependency
cabal test shomei-core
```

Expected: `TotpSpec` passing, including lines naming the RFC vectors, e.g.:

```text
Shomei.Totp
  matches RFC 6238 vector at t=59 ... OK
  rejects a replayed counter ... OK
```

M2:

```bash
just new-migration name=shomei-totp-credentials
just new-migration name=shomei-recovery-codes
just create-database
cabal test shomei-core shomei-postgres
```

M3:

```bash
cabal test shomei-core shomei-servant
```

M4 and final:

```bash
cabal run shomei-openapi > docs/api/openapi.json
git diff --stat docs/api/openapi.json     # expect the four new paths + schema changes
nix fmt
cabal build all
cabal test all
```


## Validation and Acceptance

Manual transcript against a locally running server
(`SHOMEI_TOTP_ENABLED=true SHOMEI_TOTP_ENCRYPTION_KEY=$(openssl rand -base64 32)`,
database via `just create-database`; `$TOKEN` is a fresh login's access token):

```bash
# 1. Enroll — secret shown once
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:8080/auth/totp/enroll
# -> {"secret":"JBSWY3DPEHPK3PXP...","otpauthUri":"otpauth://totp/shomei:alice?secret=...&issuer=shomei"}

# 2. Activate with a current code (oathtool ships in nixpkgs: nix run nixpkgs#oath-toolkit)
oathtool --totp -b "JBSWY3DPEHPK3PXP..."     # -> e.g. 492039
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"code":"492039"}' \
  http://localhost:8080/auth/totp/verify
# -> 200

# 3. Login now challenges
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"loginId":"alice","password":"..."}' http://localhost:8080/auth/login | jq '{status, methods}'
# -> {"status":"mfa_required","methods":["totp","recovery_code"]}   (plus ceremonyId/options)

# 4. Complete with a fresh code
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"ceremonyId":"webauthn_ceremony_01...","totpCode":"719402"}' \
  http://localhost:8080/auth/mfa/complete | jq 'keys'
# -> ["accessToken","expiresIn","refreshToken"]   (the existing TokenPairResponse shape)

# 5. Replaying the same code at a new challenge fails
# -> HTTP 401 {"error":"totp_code_invalid",...}

# 6. Recovery codes
curl -s -X POST -H "Authorization: Bearer $FRESH_TOKEN" http://localhost:8080/auth/recovery-codes
# -> {"codes":["7Q2FK-9XPRD", ... 10 total]}   (shown once)
# complete a login with {"ceremonyId":"...","recoveryCode":"7Q2FK-9XPRD"} -> tokens
curl -s -H "Authorization: Bearer $TOKEN2" http://localhost:8080/auth/recovery-codes
# -> {"remaining":9}
# the same recovery code again -> 401 {"error":"recovery_code_invalid",...}
```

Backward compatibility is itself acceptance: a passkey user's `mfa_required` response
differs from before *only* by the added `methods` field, and the legacy
`{"ceremonyId","assertion"}` completion body still works — both proven by the untouched
pre-existing passkey scenarios plus a fixture assertion on the exact JSON. Enrollment
and removal under a delegated (impersonation) token return 403 with an
`impersonation_action_blocked` audit row. `psql` shows `secret_enc` as opaque bytes and
`shomei_recovery_codes.code_hash` as hex — no plaintext secret at rest anywhere.

Automated acceptance: `cabal test all` green — `TotpSpec` (RFC vectors), the Postgres
round-trips (encryption, CAS), the workflow specs, the in-process HTTP scenarios, the
OpenAPI conformance suite (new path count, `oneOf` validation), and the E2E transcript.


## Idempotence and Recovery

All schema and code changes are additive; `totpEnabled = False` (the default) leaves
every existing flow byte-identical — enrollment refuses, login checks
`findTotpByUser` (cheap, returns Nothing), and no client sees new behavior beyond the
`methods` field on MFA challenges for passkey users. Re-running migrations, tests, and
`nix fmt` is safe. The `embedDir` caveat: if Postgres tests fail with SQLSTATE 42P01 on
the new tables, run `just migrate` to force the compile-time re-embedding.

Key management is the one operational risk: losing `SHOMEI_TOTP_ENCRYPTION_KEY` makes
stored TOTP secrets undecryptable. Recovery path (document it, and it falls out of the
design): affected users complete MFA with recovery codes or passkeys, remove TOTP, and
re-enroll. Never log the key, a secret, or a plaintext recovery code anywhere — the
`Show` instance for `TotpSecret` must redact, and handlers must not trace request
bodies.

If the login generalization breaks the existing passkey tests, the likely cause is the
challenge branch running for users with zero factors (check the `hasSecondFactor`
conjunction) or `prepareMfaChallenge` calling the WebAuthn ceremony for TOTP-only users
(it must not). If `verifyTotp` fails against a real authenticator app but passes the RFC
vectors, check the counter serialization (8-byte big-endian) and that the secret handed
to the app was Base32 of the *raw bytes*, not of hex text.

Do not modify passkey verification, `PendingCeremonyStore` semantics, `issueSession`, or
the password-reset flow. A failed TOTP completion must consume the ceremony (existing
consume-once semantics) — do not "fix" that by re-inserting the ceremony.


## Interfaces and Dependencies

Project-local interfaces (verified): `Shomei.Effect.PendingCeremonyStore`
(`takePendingCeremony` consume-once), `Shomei.Workflow.Mfa`
(`prepareMfaChallenge`/`completeMfa` — extended in place),
`Shomei.Workflow.Session.issueSession` (unchanged),
`Shomei.Effect.PasskeyStore.countPasskeysByUser` (login decision),
`Shomei.Effect.TokenGen` (random bytes — extend if it lacks a bytes operation),
`Shomei.Workflow.ServiceToken.sha256Hex` (recovery-code hashing),
`denyUnderImpersonation` in `shomei-servant/src/Shomei/Servant/Handlers.hs`
(call sites added), `Shomei.Domain.Event`/`EventCodec` (four new events),
`Shomei.Config` (new `TotpConfig`; `webauthnConfig.mfaRequired` re-documented;
`impersonationConfig.actorFreshnessWindow` reused by `requireFreshAuth`), and the three
ordered effect stacks (`Seam.AppEffects`, `Server.App.AppEffects`/`runAppIO`,
`InMemory.runInMemory`).

End-of-milestone interfaces: after M1 — `Shomei.Totp` exporting `TotpSecret`,
`totpCode`, `totpCounter`, `verifyTotp`, `secretToBase32`, `otpauthUri`; after M2 —
`Shomei.Effect.TotpCredentialStore` (five ops), `Shomei.Effect.RecoveryCodeStore`
(three ops, CAS consume), `Shomei.Postgres.TotpCredentialStore` (key-taking
interpreter), `Shomei.Config.TotpConfig`; after M3 —
`Shomei.Workflow.Totp.{enrollTotp, verifyTotpEnrollment, removeTotp,
regenerateRecoveryCodes}`, `MfaCompletion`, the five new `ShomeiAPI` route fields, the
widened `LoginMfaRequiredResponse`/`MfaCompleteRequest`, and
`requireFreshAuth` in the servant layer; after M4 — the `Env` key field and the config
surface.

Third-party dependencies: `base32` added to `shomei-core` (the only new package —
present in the pinned nixpkgs Haskell set; verify with `cabal build shomei-core` and
record any surprise); `crypton` (HMAC-SHA1, AES-256-GCM, random) and `base64` are
already dependencies. No new Nix overrides expected.

Relations to other plans: independent of the protocol plans 41-43. Soft interaction with
plan 40 (`/v1` prefix) — these routes are application routes and will be swept under
`/v1` by that plan's rules if it lands later; born under whatever prefix the tree has
when this plan is implemented. Related-but-independent:
`docs/plans/32-encrypt-signing-private-keys-at-rest.md` (future KEK; see Decision Log)
and `docs/plans/30-...-notifier-token-redaction.md` (unrelated surface; this plan simply
never logs secrets).
