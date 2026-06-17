---
id: 24
slug: configurable-jwt-signing-algorithm-and-extensible-custom-claims
title: "Configurable JWT signing algorithm and extensible custom claims"
kind: exec-plan
created_at: 2026-06-17T22:35:51Z
intention: intention_01kvbxn57be6xa5pw2mb3zehf0
---

# Configurable JWT signing algorithm and extensible custom claims

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit (a multi-package Cabal project at
`/Users/shinzui/Keikaku/bokuno/shomei`). Today it signs every access token with one fixed
algorithm, **ES256** (ECDSA over the NIST P-256 curve, SHA-256), and it embeds one fixed,
closed set of claims (`iss`, `sub`, `aud`, `iat`, `exp`, plus the custom `sid`, `scopes`,
`roles`, and optional `act`). A service that consumes Shōmei as a library cannot change the
algorithm and cannot add its own top-level claims to the token without forking the toolkit.

This plan removes both limitations. After it is implemented a consuming service can:

1. **Choose the JWT signing algorithm** — keep the default **ES256** or select **RS256**
   (RSASSA-PKCS1-v1_5 with SHA-256). The choice is carried by configuration and reflected in
   three observable places: the key that gets generated and stored, the `alg` field of the
   JWT's protected header, and the JWKS document (the public key set published for verifiers).
   The key's `kid` (key id) keeps identifying which key signed a token, so rotation and
   multi-key verification keep working unchanged.

2. **Attach custom top-level claims** to every signed token without forking Shōmei. A service
   supplies a small bag of extra JSON fields (for example TAN's `userId`, `userInfo`,
   `impersonated`, `clientAccountId`, or a service token's `type` and `serviceInfo`). Those
   fields serialize alongside the standard claims, survive a verify round trip, and are handed
   back to the service after verification.

The change is **library-internal but observably testable**: the acceptance test signs an
**RS256** token that carries a custom claim, decodes the compact token to prove the header says
`"alg":"RS256"` and the payload contains the custom field, then verifies the token through the
public JWKS path and shows the custom claim is preserved. A novice can run one `cabal test`
command and read the pass/fail lines.

This plan is the **SH-24 prerequisite** named in the shared brief at
`/Users/shinzui/Keikaku/work/microtan/auth-service/.claude/skills/exec-plan/PLANS.md`'s sibling
brief `/tmp/auth-v2-brief.md`. It is consumed by **auth-service-v2 EP-3**, whose plan file is
`/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/4-token-claims-key-endpoint-compatibility.md`
(EP-3 in the brief's numbering). EP-3 needs Shōmei to emit RS256 JWTs whose payload exactly
matches the legacy Node auth-service claim shape; this plan supplies the two mechanisms — the
RS256 option and the custom-claims bag — that EP-3 builds on. EP-3 does not modify Shōmei; it
only configures and calls the seams this plan adds.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 — Read the affected modules and confirm the current behavior with a baseline build/test. (2026-06-17: `cabal build all` exit 0; `cabal test shomei-jwt` → all 11 tests PASS.)
- [x] M1 — Add the `SigningAlgorithm` type and thread it through key generation, storage, and the JWKS. (2026-06-17: `SigningAlgorithm`/`signingAlgorithmToText`/`signingAlgorithmFromText` in `shomei-core`; `generateSigningKeyFor`/`toStoredSigningKeyFor` in `shomei-jwt`; new `KeySpec` RS256 case PASS — 12 tests.)
- [x] M2 — Make signing honor the configured algorithm (fix the `bestJWSAlg` PSS pitfall for RSA). (2026-06-17: `algForKey` picks RS256 for RSA / ES256 for EC; header built with `newJWSHeaderProtected`; 3 new SignVerify cases PASS, ES256 header unchanged — 15 tests.)
- [x] M3 — Add the extensible custom-claims bag to `AuthClaims`, serialize and recover it. (2026-06-17: `extraClaims`/`mkExtraClaims`/`noExtraClaims`/`reservedClaimKeys` in `shomei-core`; `claimsFromAuth` folds extras in *first* so standard claims override; `claimsToAuth` recovers them; `buildClaimsWith` added; all `AuthClaims{}` sites updated. New round-trip + reserved-key cases PASS — shomei-jwt 17, shomei-core 103.)
- [x] M4 — Wire algorithm + custom claims through `Config`, the server bootstrap, and `shomei-admin`. (2026-06-17: `configSigningAlgorithm`, `SHOMEI_SIGNING_ALG`/Dhall `signingAlgorithm` (both validated), `bootstrapKeys alg`, `keys generate --alg`, `rotateSigningKeyFor`. Committed f98895c; six test call sites of the changed signatures fixed in 0dd0c93. The `configSigningAlgorithm` parse/fallback test passes.)
- [x] M5 — Acceptance: RS256 token carrying a custom claim round-trips through the JWKS verify path. (2026-06-17: `RsaCustomClaimSpec` committed c2ce915. Validated in an isolated `git worktree` at the SH-24 head — `cabal build all` clean and `cabal test all` EXIT=0, all 10 suites PASS including the `RsaCustomClaim` group.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`bestJWSAlg` does not return `RS256` for an RSA key.** The current signer
  (`shomei-jwt/src/Shomei/Jwt/Sign.hs`) builds the JWS header with `makeJWSHeader`, which calls
  `bestJWSAlg` (in the vendored `jose` library at
  `/Users/shinzui/Keikaku/hub/haskell/jose-project/hs-jose/src/Crypto/JOSE/JWK.hs`). For an RSA
  key `bestJWSAlg` walks the list `[PS512, PS384, PS256, RS512, RS384, RS256]` and returns the
  first usable one — i.e. **PS512**, an RSASSA-PSS algorithm, *not* RS256. Evidence, from the
  `chooseJWSAlg` definition in that file:

  ```haskell
  RSAKeyMaterial k
    | n < 2 ^ (2040 :: Integer) -> throwing_ _KeySizeTooSmall
    | otherwise                 -> maybe negoFail pure (find ok rsaAlgs)
    where
      rsaAlgs =
        [ JWA.JWS.PS512 , JWA.JWS.PS384 , JWA.JWS.PS256
        , JWA.JWS.RS512 , JWA.JWS.RS384 , JWA.JWS.RS256 ]
  ```

  Consequence: simply generating an RSA key and reusing `makeJWSHeader` would emit `alg: PS512`,
  which the legacy Node gateway (which verifies **RS256** only) would reject. M2 must pin the
  algorithm explicitly with `newJWSHeader (Protected, RS256)` and copy the `kid` by hand, **not**
  rely on `makeJWSHeader`/`bestJWSAlg`. This is the single most important discovery in the plan.

- **`Crypto.JOSE.Header.Protection` is a deprecated type synonym, not a data type.** In the
  vendored jose fork (`/Users/shinzui/Keikaku/hub/haskell/jose-project/hs-jose/src/Crypto/JOSE/Header.hs`)
  the protection sum type is now `data OptionalProtection = Protected | Unprotected`, and
  `Protection` survives only as `type Protection = OptionalProtection` carrying a
  `{-# DEPRECATED #-}` pragma. A type synonym has no constructors, so the original M2 import
  `Crypto.JOSE.Header (Protection (Protected))` would **fail to compile**. The correct import is
  `OptionalProtection (Protected)`. `newJWSHeader :: (p, Alg) -> JWSHeader p` then takes the
  `(Protected, alg)` pair as written. (`HeaderParam(..)` is exported from `Crypto.JOSE.Header`.)

- **Plan-wide jose-API audit (2026-06-17).** Every jose name this plan relies on was confirmed
  to exist in the vendored fork: `KeyMaterialGenParam(ECGenParam, RSAGenParam)` is re-exported
  from `Crypto.JOSE.JWK` (so the M1 import path is correct); `genRSA size = RSA.generate size
  65537` takes the modulus **in bytes**, so `RSAGenParam 256` → 2048 bits as the plan states;
  `bestJWSAlg`/`chooseJWSAlg`, `jwkMaterial`, `KeyMaterial(RSAKeyMaterial, ECKeyMaterial)`,
  `newJWSHeader`, the `kid` lens, and `Alg(ES256, RS256)` all exist. The `chooseJWSAlg` RSA
  preference list quoted above matches the source verbatim.

- **`publicJwks` is a test-support helper, not a `Jwks` module export.** The M3/M5 test snippets
  call `publicJwks jwk []`; that function lives in `shomei-jwt/test/Shomei/Jwt/TestSupport.hs`
  (which the new test modules already import), **not** in `Shomei.Jwt.Jwks`. The production JWKS
  surface in `Shomei.Jwt.Jwks` is `jwksDocument`, the `KeySet` type, and `keySetPublicJwks`. Tests
  may keep using the `TestSupport.publicJwks` helper unchanged.

- **M2 implementation: `signClaims` requires `JWSHeader RequiredProtection`, not
  `OptionalProtection`.** The plan's M2 snippet built the header with
  `newJWSHeader (Protected, alg)`, which yields a `JWSHeader OptionalProtection`;
  `Crypto.JWT.signClaims` expects `JWSHeader RequiredProtection`, so that form fails
  to compile with `Couldn't match type 'OptionalProtection' with 'RequiredProtection'`.
  The clean fix is to use jose's protection-polymorphic constructors:
  `newJWSHeaderProtected :: ProtectionSupport p => Alg -> JWSHeader p` for the header and
  `newHeaderParamProtected :: ProtectionIndicator p => a -> HeaderParam p a` for the `kid`
  param. `signClaims` then fixes `p ~ RequiredProtection` by inference — no explicit
  `Protected`/`OptionalProtection`/`HeaderParam` imports needed. Implemented in
  `shomei-jwt/src/Shomei/Jwt/Sign.hs`. Evidence: the three M2 SignVerify cases pass and
  the decoded header reads exactly `"alg":"RS256"` (RSA) / `"alg":"ES256"` (EC).

- **Test base64url decoding uses the `ram` package (a `memory` fork), not `memory`.**
  `Data.ByteArray.Encoding` is provided to `shomei-jwt` by `ram` (see `mori registry show
  ram`); the M2/M5 header-decoding tests therefore add `ram` (not `memory`) to the
  `shomei-jwt-test` `build-depends`.

- **M3: the plan's `claimsFromAuth` snippet applied `addExtra` outermost, which would
  let custom keys WIN — the opposite of the documented guarantee.** With
  `addExtra extra $ (emptyClaimsSet & ... & addClaim "sid" ...)`, `addExtra` runs last and
  overwrites `sid`/`scopes`/`roles`. Corrected to seed the base first
  (`addExtra extra emptyClaimsSet & claimIss ?~ ... & addClaim "sid" ...`) so the standard
  chain is applied on top and always overrides a colliding custom key. The reserved-key
  test (`sid`/`act` etc.) now genuinely passes by ordering, not just by `mkExtraClaims`.

- **jose itself strips registered claim keys from the unregistered map on BOTH encode and
  decode** (`Crypto.JWT.filterUnregistered` over `registeredClaims = aud/exp/iat/iss/jti/
  nbf/sub`). So a custom `"sub"`/`"iss"`/… in the extra bag can never reach the wire or be
  recovered as a standard claim — registered-claim forgery is impossible even if a caller
  bypasses `mkExtraClaims`. The `sid`/`scopes`/`roles`/`act` claims are NOT registered in
  jose, so their protection relies on Shōmei's `addExtra`-first ordering (above) plus
  `mkExtraClaims` dropping them at construction.

- **M4: a concurrent agent is implementing plan 25 in the SAME working tree, in a
  non-compiling intermediate state.** Partway through M4, `cabal build all` began failing
  in `shomei-core` files this plan never touches (`Workflow/Account.hs`, `Workflow/Passkey.hs`,
  `Workflow.hs`). Cause: uncommitted plan-25 edits (`docs/plans/25-...`) changed
  `User.email`/`Credential.email` from `Email` to `Maybe Email`, added a `loginId :: LoginId`
  field + a new `Shomei.Domain.LoginId` module, and added `InvalidLoginId`/
  `LoginIdAlreadyRegistered` to `Shomei.Error` — and the dependent workflows had not yet been
  updated, so the tree does not compile. These are NOT this plan's changes. Verified the file
  sets are disjoint: SH-24's M4 files (`Shomei/Config.hs`, `Server/Config.hs`, `Server/Keys.hs`,
  `Server/Boot.hs`, `app/Admin.hs`, `app/Shomei/Admin/Keys.hs`, `Jwt/Rotation.hs`) contain no
  plan-25 content, and SH-24's M1–M3 commits never included a plan-25 code file. **Decision:**
  do not touch any plan-25 file; commit only SH-24 files; validate M4/M5 in an isolated
  `git worktree` checked out at the SH-24 commit (which excludes plan-25's uncommitted breakage),
  so the build there compiles against the committed baseline `User`/`Credential` shape this plan
  was written against.

- (Add further discoveries here as work proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Build auth-service-v2 on top of Shōmei and make all token/claim enhancements in the
  Shōmei repository via this plan (SH-24); do not fork Shōmei.
  Rationale: Locked decision 1 of the shared brief (`/tmp/auth-v2-brief.md`). auth-service-v2 EP-3
  (`/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/4-token-claims-key-endpoint-compatibility.md`)
  depends on RS256 + extensible claims being available *as library features*.
  Date: 2026-06-17

- Decision: Pin the JWS algorithm explicitly when signing RSA keys instead of relying on
  `makeJWSHeader`/`bestJWSAlg`.
  Rationale: `bestJWSAlg` prefers RSASSA-PSS (PS512) over RS256 for RSA keys (see Surprises &
  Discoveries). The legacy gateway and 28 downstream services verify RS256 only (brief §"Legacy
  JWT claims"). We must emit exactly `alg: RS256`.
  Date: 2026-06-17

- Decision: Model the algorithm as a closed sum type `SigningAlgorithm = ES256 | RS256` in
  `shomei-core` rather than free-form `Text`.
  Rationale: Type safety. The existing `SigningKeyConfig{algorithm :: Text}` and the
  `StoredSigningKey{algorithm :: Text}` text columns stay as the *storage* representation (the DB
  column is `text`, and `shomei-core`/`shomei-postgres` must not import `jose`), but the in-memory
  decision is a closed enum parsed at the edges. See "Plan of Work" for why both forms coexist.
  Date: 2026-06-17

- Decision: Represent custom claims as an `Aeson.Object` ("extra claims map") carried on
  `AuthClaims`, defaulting to empty.
  Rationale: It is the least invasive, fully backward-compatible extension. An empty object
  serializes to byte-identical tokens as today (we only add keys when the map is non-empty), it
  needs no new type-class machinery, and it lets a consuming service add arbitrary JSON top-level
  claims (TAN's `userInfo`, `serviceInfo`, etc.) without Shōmei knowing their shape. Alternatives
  considered and rejected are recorded below.
  Date: 2026-06-17

- Decision (rejected alternative A): A type-class `ToExtraClaims a` parameterizing `AuthClaims`
  over a service-defined claims type.
  Rationale for rejection: It would make `AuthClaims`, `TokenSigner`, `TokenVerifier`, and every
  workflow polymorphic in `a`, rippling a type parameter through the whole effect stack and the
  Servant layer. Far more invasive for no practical gain over an `Aeson.Object`, which the
  consuming service can still build from its own typed record via `toJSON`.
  Date: 2026-06-17

- Decision (rejected alternative B): Inject custom claims only at the `TokenSigner` interpreter
  seam (a fixed `Aeson.Object` baked into `runTokenSignerJwt`) instead of carrying them on
  `AuthClaims`.
  Rationale for rejection: TAN's custom claims are *per-token*, not per-process — `userId`,
  `userInfo`, `impersonated`, `clientAccountId` differ for every user, and service tokens carry a
  *different* claim shape (`type`, `serviceInfo`) than user tokens. A process-wide injected object
  cannot express per-token variation. The claims must travel with the per-call `AuthClaims`. We
  *also* keep a small static-injection convenience (a config-level constant-claims object) for
  truly process-wide claims, but the primary mechanism is per-`AuthClaims`.
  Date: 2026-06-17

- Decision: Reserved-claim protection — when serializing the extra-claims object we must not let a
  custom key silently overwrite a standard claim (`iss`, `sub`, `aud`, `iat`, `exp`, `sid`,
  `scopes`, `roles`, `act`). The signer adds the standard claims *after* the custom ones, so
  standard claims win; and verification reads the standard claims from their typed accessors, so a
  malicious "sub" inside the extra bag cannot move the subject. We document this ordering as a
  guarantee and test it.
  Rationale: Safety. A consuming service or attacker-influenced input must never be able to forge a
  standard claim via the extension bag.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-17.** All six milestones (M0–M5) are done and the feature meets its
original purpose: a consuming service can now (1) choose the JWT signing algorithm —
default **ES256** or **RS256** — carried by config and reflected in the generated/stored
key, the JWT protected header's `alg`, and the published JWKS, with the `kid` unchanged; and
(2) attach arbitrary top-level custom claims to every token via `AuthClaims.extraClaims`,
which serialize alongside the standard claims, survive a verify round trip, and are returned
to the service — with a reserved-key guarantee so a standard claim can never be forged
through the bag. This delivers exactly the two seams auth-service-v2 EP-3 consumes.

**Validation.** `cabal build all` is clean and `cabal test all` is green (10 suites, EXIT=0),
including the headline `RsaCustomClaim` acceptance group (RS256 token carrying a custom claim,
header proven `alg:RS256`, payload proven to carry the custom + standard claims, verified
through the public JWKS) and the `configSigningAlgorithm` parse/fallback unit test. Existing
ES256 behavior is unchanged (the prior `SignVerify` cases still pass; empty-`extraClaims`
tokens serialize as before).

**Key technical outcomes / lessons.**
- The single most important pitfall held: `jose`'s `bestJWSAlg`/`makeJWSHeader` prefers PSS
  (PS512) for RSA keys. Pinning `RS256` explicitly via `newJWSHeaderProtected` + key-material
  inspection (`algForKey`) was essential. (The plan's `OptionalProtection`/`HeaderParam` import
  recipe didn't type-check against `signClaims`, which needs `RequiredProtection`; the
  protection-polymorphic `newJWSHeaderProtected`/`newHeaderParamProtected` are the right tools.)
- Custom-claim safety is layered: `mkExtraClaims` drops reserved keys at construction; the
  signer seeds extras *before* the standard chain so Shōmei's values override `sid/scopes/
  roles/act`; and `jose` itself filters the registered keys (`iss/sub/aud/iat/exp`) from the
  unregistered map on both encode and decode, so registered-claim forgery is impossible.
- The `algorithm` text column / config string already existed but were inert; this plan made
  them meaningful with no schema migration, exactly as scoped.

**Process note / gap.** Throughout M4–M5 the working tree was concurrently modified by an
unrelated, in-progress, non-compiling **plan-25** change set (login-identifier/optional-email),
which broke `cabal build all` in the shared tree. SH-24 was kept strictly isolated (no plan-25
file touched; explicit per-file `git add`, never `git add -A` for code after this was noticed)
and validated in a dedicated `git worktree` checked out at the SH-24 head, where the tree
compiles against the committed baseline. **Open item for the operator:** a final `cabal test
all` on the integrated trunk should be re-run once plan-25 is itself complete and compiling;
SH-24's own correctness is fully established by the isolated-worktree run.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**The repository.** Shōmei lives at `/Users/shinzui/Keikaku/bokuno/shomei`. It is a multi-package
Cabal project built with GHC 9.12.4 and the GHC2024 language edition. You build and test it from
inside a Nix development shell. From the repo root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal build all
nix develop --command cabal test all
```

If `nix develop` is unavailable in your environment, a Cabal toolchain with GHC 9.12.4 on `PATH`
works too; replace `nix develop --command ` with nothing in every command below. All commands in
this plan are written to be run from the repo root unless a different working directory is named.

**Packages you will touch (full paths).** A "package" is one sub-directory with its own `.cabal`
file:

- `shomei-core` — the pure domain types, the effect *ports* (interfaces), and the workflows. It
  must **never** depend on the `jose` JWT library (that is an architectural rule stated in
  `shomei-core/src/Shomei/Domain/SigningKey.hs`). Key files:
  - `shomei-core/src/Shomei/Domain/Claims.hs` — the `AuthClaims` record (the claims of a token).
  - `shomei-core/src/Shomei/Domain/SigningKey.hs` — `StoredSigningKey` (the storage-agnostic key
    record that crosses the store port) with its `algorithm :: Text` field.
  - `shomei-core/src/Shomei/Config.hs` — `ShomeiConfig`, including `SigningKeyConfig{algorithm ::
    Text}`.
  - `shomei-core/src/Shomei/Effect/TokenSigner.hs` and `.../TokenVerifier.hs` — the two ports a
    token signer/verifier must implement.
  - `shomei-core/src/Shomei/Workflow.hs`, `.../Workflow/Session.hs` — where workflows build
    `AuthClaims` (via `buildClaims`) and call `signAccessToken`.

- `shomei-jwt` — the **only** package that imports `jose`. It turns an `AuthClaims` into a signed
  compact JWT and back. Key files:
  - `shomei-jwt/src/Shomei/Jwt/Key.hs` — generates a key, computes its `kid` (RFC 7638 JWK
    thumbprint), and converts to/from `StoredSigningKey`.
  - `shomei-jwt/src/Shomei/Jwt/Sign.hs` — `claimsFromAuth` (builds the `jose` `ClaimsSet`),
    `signAccessToken`, and the `TokenSigner` interpreter `runTokenSignerJwt`.
  - `shomei-jwt/src/Shomei/Jwt/Verify.hs` — `verifyToken`, `claimsToAuth` (recovers `AuthClaims`
    from a verified `ClaimsSet`), and the `TokenVerifier` interpreter `runTokenVerifierJwt`.
  - `shomei-jwt/src/Shomei/Jwt/Jwks.hs` — the published JWKS document and the `KeySet` type.
  - `shomei-jwt/src/Shomei/Jwt/Rotation.hs` — key rotation and the live JWKS.
  - `shomei-jwt/test/Shomei/Jwt/SignVerifySpec.hs` and `.../TestSupport.hs` — the round-trip tests
    you will extend.

- `shomei-server` — boots the standalone server and the `shomei-admin` CLI. Key files:
  - `shomei-server/src/Shomei/Server/Keys.hs` — `bootstrapKeys`: on first boot generate one key,
    persist it Active, then load the active private key + the public JWKS.
  - `shomei-server/src/Shomei/Server/App.hs` — `Env`, the `AppEffects` effect stack, and
    `runAppIO` which wires `runTokenSignerJwt` and `runTokenVerifierJwt`.
  - `shomei-server/src/Shomei/Server/Config.hs` — loads config from defaults → Dhall file → env.
  - `shomei-server/app/Shomei/Admin/Keys.hs` — the `shomei-admin keys generate/activate/...` CLI.

- `shomei-postgres` — the PostgreSQL interpreters of the ports.
  `shomei-postgres/src/Shomei/Postgres/SigningKeyStore.hs` reads/writes the `algorithm` text
  column.

- `shomei-migrations` — embedded SQL migrations. The signing-keys table is created in
  `shomei-migrations/sql-migrations/2026-06-03-00-00-05-shomei-signing-keys.sql`; the table already
  has a `algorithm text NOT NULL` column, so **no new migration is required** for the algorithm.

**Terms used in this plan, defined in plain language.**

- *JWT / access token.* A signed, base64url-encoded string in three dot-separated parts:
  `header.payload.signature`. The header is a small JSON object; the most relevant field is
  `"alg"` (the signing algorithm) and `"kid"` (which key signed it). The payload is the JSON
  *claims*.
- *Claim.* One top-level field in the payload JSON. "Standard" claims are the registered ones
  (`iss` issuer, `sub` subject, `aud` audience, `iat` issued-at, `exp` expiry). Shōmei adds custom
  claims `sid` (session id), `scopes`, `roles`, and optionally `act` (the impersonation operator).
- *ES256.* ECDSA signature over the NIST P-256 curve with SHA-256. Shōmei's current and default
  algorithm. Keys are small.
- *RS256.* RSASSA-PKCS1-v1_5 signature with SHA-256, using an RSA key. The algorithm the legacy
  TAN gateway and 28 downstream services expect.
- *PS256 / PS512.* RSASSA-PSS variants — a *different* RSA scheme. Important because the `jose`
  library's `bestJWSAlg` prefers PSS over PKCS1-v1_5; we must avoid it for RS256 (see Surprises &
  Discoveries).
- *JWK / JWKS.* A JWK is one key encoded as JSON. A JWKS ("JWK Set") is `{"keys":[...]}`, the
  *public* keys a verifier downloads. Shōmei serves it at `GET /.well-known/jwks.json`.
- *kid (key id).* A short string in the JWT header naming which key signed the token, so a verifier
  with several keys can pick the right one. Shōmei sets it to the RFC 7638 thumbprint (a SHA-256
  hash of the key's canonical JSON).
- *Port / effect / interpreter.* Shōmei is built on the `effectful` library. A *port* (e.g.
  `TokenSigner`) is an interface — a small GADT of operations. An *interpreter* (e.g.
  `runTokenSignerJwt`) gives the operations real behavior. Workflows depend only on ports, so the
  same workflow runs against an in-memory test interpreter or the real JWT one.

**The current claim flow, end to end (read this to know what you are changing).** A workflow such
as `Shomei.Workflow.Session.buildClaims` constructs an `AuthClaims` value (subject, session id,
issuer, audience, timestamps, scopes, roles, optional actor). It calls `signAccessToken` on the
`TokenSigner` port. The JWT interpreter `runTokenSignerJwt` (in `shomei-jwt/.../Sign.hs`) holds
the active private `JWK`; it calls `claimsFromAuth` to turn the `AuthClaims` into a `jose`
`ClaimsSet` (standard claims via lenses, custom `sid`/`scopes`/`roles`/`act` via `addClaim`), then
`makeJWSHeader` + `signClaims` to produce the compact token. Verification is the mirror:
`verifyToken` in `shomei-jwt/.../Verify.hs` decodes the compact token, validates it against the
public `JWKSet` (issuer + audience predicates, zero clock skew), and `claimsToAuth` rebuilds an
`AuthClaims` (standard claims from typed accessors, custom claims read out of the
`unregisteredClaims` map).

**What is already in place that helps you.** `SigningKeyConfig` already has an `algorithm :: Text`
field (default `"ES256"`), `StoredSigningKey` already has `algorithm :: Text`, and the
`shomei_signing_keys` table already has an `algorithm` column. So the *storage and config plumbing
for an algorithm string exists but is inert* — `generateSigningKey` always produces ES256 and
hard-codes `algorithm = "ES256"` in `toStoredSigningKey`. This plan makes that string meaningful.


## Plan of Work

The work proceeds in six milestones. M0 is a baseline. M1–M3 are the library core (key,
algorithm, signing, verification, custom claims) and are each independently verifiable in
`shomei-jwt`. M4 wires the new knobs through config, server bootstrap, and the admin CLI. M5 is the
end-to-end acceptance test that proves an RS256 token carrying a custom claim round-trips through
the JWKS verify path.

Throughout, keep two architectural rules: (1) only `shomei-jwt` may import `jose`; `shomei-core`
and `shomei-postgres` keep the algorithm as `Text`/a small enum with no `jose` dependency. (2)
Every change is additive and backward-compatible — existing ES256 tokens with no custom claims must
stay byte-for-byte identical, which the existing tests in
`shomei-jwt/test/Shomei/Jwt/SignVerifySpec.hs` will enforce.


### Milestone M0 — Baseline: confirm current behavior

**Scope.** No code changes. Establish that the tree builds and the JWT tests pass *before* you
start, so later you can attribute any failure to your change. **At the end** you will have a green
baseline and notes on the exact current token shape.

**Work.** From the repo root run the build and the `shomei-jwt` test suite. Then, optionally, read
the existing round-trip test to internalize the assertions you must not break.

**Acceptance.** `cabal build all` succeeds and `cabal test shomei-jwt` reports all
`SignVerify`/`Jwks`/`Key`/`Interpreter` cases passing. See "Concrete Steps" for exact commands and
expected output.


### Milestone M1 — A `SigningAlgorithm` type threaded through key generation, storage, and the JWKS

**Scope.** Introduce a closed enum for the algorithm in `shomei-core`, make key generation in
`shomei-jwt` able to produce *either* an ES256 (P-256) or an RS256 (RSA-2048) key, record the
chosen algorithm string on the stored key, and keep the `kid` and JWKS working for RSA keys. **At
the end** you can generate an RSA signing key whose `StoredSigningKey.algorithm` is `"RS256"` and
whose public form appears in a JWKS document.

**Work.**

1. In `shomei-core/src/Shomei/Domain/SigningKey.hs` add a closed sum type and two total
   conversions to/from the storage `Text`:

   ```haskell
   data SigningAlgorithm = ES256 | RS256
       deriving stock (Generic, Eq, Show)
       deriving anyclass (FromJSON, ToJSON)

   signingAlgorithmToText :: SigningAlgorithm -> Text
   signingAlgorithmToText ES256 = "ES256"
   signingAlgorithmToText RS256 = "RS256"

   -- | Parse the stored algorithm text. Unknown values are an error rather than a
   -- silent default, so a corrupt/forward-incompatible key is caught loudly.
   signingAlgorithmFromText :: Text -> Either Text SigningAlgorithm
   signingAlgorithmFromText "ES256" = Right ES256
   signingAlgorithmFromText "RS256" = Right RS256
   signingAlgorithmFromText other   = Left ("unknown signing algorithm: " <> other)
   ```

   Export `SigningAlgorithm(..)`, `signingAlgorithmToText`, `signingAlgorithmFromText` from the
   module's export list. Leave `StoredSigningKey.algorithm :: Text` unchanged (storage stays
   text). The reason to keep both forms: `shomei-core`/`shomei-postgres` and the SQL column already
   speak `Text`, and changing the column/record type is a needless, risky migration; the enum is
   the *decided* form used in code, parsed at the JWT seam.

2. In `shomei-jwt/src/Shomei/Jwt/Key.hs` generalize key generation. Replace the parameterless
   `generateSigningKey :: IO JWK` with one that takes the algorithm, and keep a thin
   backward-compatible alias so existing call sites and tests keep compiling:

   ```haskell
   import Shomei.Domain.SigningKey (SigningAlgorithm (..))
   import Crypto.JOSE.JWA.JWK (Crv (P_256))
   import Crypto.JOSE.JWK (KeyMaterialGenParam (ECGenParam, RSAGenParam))

   -- | Generate a fresh signing key for the requested algorithm, marked for
   -- signature use, with its @kid@ set to its RFC 7638 thumbprint. ES256 -> a
   -- P-256 EC key; RS256 -> a 2048-bit RSA key (256 bytes; comfortably above
   -- jose's 2040-bit minimum).
   generateSigningKeyFor :: SigningAlgorithm -> IO JWK
   generateSigningKeyFor alg = do
       k0 <- genJWK (genParam alg)
       let tp  = view thumbprint k0 :: Digest SHA256
           kid = Text.decodeUtf8 (convertToBase Base64URLUnpadded tp :: ByteString)
       pure (k0 & jwkUse ?~ Sig & jwkKid ?~ kid)
     where
       genParam ES256 = ECGenParam P_256
       genParam RS256 = RSAGenParam 256  -- 256 bytes == 2048-bit modulus

   -- | Back-compat: the original ES256 generator, defined in terms of the new one.
   generateSigningKey :: IO JWK
   generateSigningKey = generateSigningKeyFor ES256
   ```

   `RSAGenParam` and the `Crv`/`KeyMaterialGenParam` constructors come from `jose`
   (`/Users/shinzui/Keikaku/hub/haskell/jose-project/hs-jose/src/Crypto/JOSE/JWA/JWK.hs`); the
   `RSAGenParam Int` argument is the modulus size **in bytes**, so 256 → 2048 bits.

3. Still in `Key.hs`, make `toStoredSigningKey` record the *actual* algorithm of the key instead of
   the hard-coded `"ES256"`. Detect it from the key material with `bestJWSAlg`-free logic — read
   the key's curve/type — or, more simply and robustly, pass the algorithm in. The minimally
   invasive choice is to add an algorithm parameter:

   ```haskell
   import Shomei.Domain.SigningKey (SigningAlgorithm, signingAlgorithmToText, StoredSigningKey (..))

   toStoredSigningKeyFor :: SigningAlgorithm -> UTCTime -> JWK -> StoredSigningKey
   toStoredSigningKeyFor alg t k =
       (toStoredSigningKey t k) { algorithm = signingAlgorithmToText alg }
   ```

   Keep the existing `toStoredSigningKey t k` (which writes `"ES256"`) as the ES256 convenience so
   no current caller breaks; new code that generates RS256 keys calls `toStoredSigningKeyFor RS256`.
   Export `generateSigningKeyFor` and `toStoredSigningKeyFor`.

4. Confirm the JWKS still works for RSA. The JWKS code in `shomei-jwt/src/Shomei/Jwt/Jwks.hs`
   strips private material with `asPublicKey` and serializes via `JWKSet`. `jose` already supports
   RSA public keys in a JWKS, so no change is needed here — but the M1 test below will *prove* it by
   building a JWKS from an RSA key and checking it contains an `"RSA"`-type key.

**Acceptance.** A new test in `shomei-jwt` generates an RS256 key, asserts
`toStoredSigningKeyFor RS256 t k` has `algorithm == "RS256"` and a non-empty `kid`, and asserts the
JWKS document built from the public key parses and reports key type RSA. `cabal test shomei-jwt`
passes including the new case. (Exact assertions in "Concrete Steps".)


### Milestone M2 — Sign with the configured algorithm (the RS256 / PSS pitfall)

**Scope.** Make `signAccessToken` produce a token whose header `alg` equals the key's actual
algorithm — specifically `RS256` for an RSA key, never `PS256`/`PS512`. **At the end** an RSA key
signs a token whose decoded header reads `"alg":"RS256"`, and verification of that token still
succeeds.

**Work.**

1. In `shomei-jwt/src/Shomei/Jwt/Sign.hs`, stop relying on `makeJWSHeader` (which uses
   `bestJWSAlg` and would pick `PS512` for RSA — see Surprises & Discoveries). Instead build the
   header explicitly from the key's algorithm. Determine the algorithm from the *key material* so
   the signer never disagrees with the key:

   ```haskell
   import Crypto.JOSE.JWA.JWS (Alg (ES256, RS256))
   import Crypto.JOSE.JWS (newJWSHeader, kid)
   -- NOTE: import the constructor via 'OptionalProtection', NOT 'Protection'.
   -- In this jose fork 'Protection' is a *deprecated type synonym*
   -- (@type Protection = OptionalProtection@); a type synonym has no
   -- constructors, so @Protection (Protected)@ does not compile. See Surprises.
   import Crypto.JOSE.Header (HeaderParam (HeaderParam), OptionalProtection (Protected))
   import Crypto.JOSE.JWK (bestJWSAlg)  -- still used for the EC path
   import Shomei.Jwt.Key (keyKid)

   -- | Choose the JWS algorithm for a key: RS256 for RSA (NOT the PSS variants
   -- jose's bestJWSAlg would prefer), otherwise whatever bestJWSAlg picks (ES256
   -- for our P-256 keys).
   algForKey :: JWK -> Either JWTError Alg
   algForKey jwk = case runExcept (bestJWSAlg jwk) of
       Right ES256 -> Right ES256
       Right _rsaOrOther
           | isRsa jwk -> Right RS256   -- force PKCS1-v1_5, not PSS
       Right a -> Right a
       Left e -> Left e
   ```

   Where `isRsa` inspects `view jwkMaterial jwk` for `RSAKeyMaterial`. (`jwkMaterial`,
   `RSAKeyMaterial`, and `Alg` are exported from `jose`'s `Crypto.JOSE.JWK` /
   `Crypto.JOSE.JWA.JWK` / `Crypto.JOSE.JWA.JWS`.) The cleanest, least error-prone implementation
   simply pattern-matches the key material directly:

   ```haskell
   import Crypto.JOSE.JWA.JWK (KeyMaterial (RSAKeyMaterial, ECKeyMaterial))
   import Crypto.JOSE.JWK (jwkMaterial)

   algForKey :: JWK -> Alg
   algForKey jwk = case view jwkMaterial jwk of
       RSAKeyMaterial _ -> RS256
       ECKeyMaterial _  -> ES256
       _                -> ES256  -- our generators only ever produce EC or RSA
   ```

   Prefer this direct form; it has no failure mode and needs no `MonadError` plumbing.

2. Build the header from that algorithm and copy the `kid` by hand (replacing `makeJWSHeader`):

   ```haskell
   signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)
   signAccessToken jwk ac = do
       let hdr = newJWSHeader (Protected, algForKey jwk)
                   & kid ?~ HeaderParam Protected (keyKid jwk)
       result <- runJOSE @JWTError $ do
           signed <- signClaims jwk hdr (claimsFromAuth ac)
           pure (encodeCompact (signed :: SignedJWT))
       pure $ case result of
           Left e     -> Left e
           Right wire -> Right (AccessToken (Text.decodeUtf8 (BSL.toStrict wire)))
   ```

   `newJWSHeader`, `kid`, `HeaderParam`, and `Protection(Protected)` are from `jose`'s
   `Crypto.JOSE.JWS`/`Crypto.JOSE.Header`. The original `signAccessToken` used `hdr <-
   makeJWSHeader jwk` inside `runJOSE`; this replaces it with a pure header so the `alg` is under
   our control. Keep the rest (`signClaims`, `encodeCompact`) identical so ES256 behavior is
   unchanged.

3. `runTokenSignerJwt` and `verifyToken` need no change: verification already accepts whatever
   algorithm the JWKS key supports — `jose`'s `verifyClaims` validates an RS256 signature against
   an RSA public key in the JWKS automatically.

**Acceptance.** Two new tests in `shomei-jwt`: (a) an RSA key signs a token; decoding the first
(header) segment of the compact token as JSON shows `"alg":"RS256"` and a `"kid"` equal to the
key's kid; (b) that same token verifies via `verifyToken` against the RSA public JWKS and recovers
the claims. Existing ES256 tests still pass (their header still reads `"alg":"ES256"`). Exact steps
in "Concrete Steps".


### Milestone M3 — Extensible custom claims on `AuthClaims`

**Scope.** Add an "extra claims" bag to `AuthClaims`, serialize it alongside the standard claims
on sign, and recover it on verify, with standard claims always winning over any colliding custom
key. **At the end** a token can carry arbitrary top-level JSON claims that survive a round trip.

**Work.**

1. In `shomei-core/src/Shomei/Domain/Claims.hs` add a field to `AuthClaims`:

   ```haskell
   import Data.Aeson (Object)
   import Data.Aeson.KeyMap qualified as KeyMap

   data AuthClaims = AuthClaims
       { subject     :: !UserId
       , sessionId   :: !SessionId
       , issuer      :: !Issuer
       , audience    :: !Audience
       , issuedAt    :: !UTCTime
       , expiresAt   :: !UTCTime
       , scopes      :: !(Set Scope)
       , roles       :: !(Set Role)
       , actor       :: !(Maybe UserId)
       , extraClaims :: !Object
       -- ^ additional top-level JWT claims a consuming service attaches (e.g. TAN's
       -- @userId@, @userInfo@, @impersonated@, @clientAccountId@, or a service token's
       -- @type@/@serviceInfo@). Empty ('mempty') for ordinary tokens, which then
       -- serialize byte-identically to before this field existed. Keys that collide
       -- with a standard claim are overridden by the standard claim at sign time.
       }
       deriving stock (Generic, Eq, Show)
       deriving anyclass (FromJSON, ToJSON)
   ```

   `Object` is `Data.Aeson.KeyMap.KeyMap Value`. Provide a tiny smart constructor and a helper to
   keep call sites tidy and to centralize the reserved-key rule. Add these to `Claims.hs` and
   export them:

   ```haskell
   -- | The standard claim keys Shōmei owns; custom claims using these are dropped
   -- so a service (or attacker-influenced input) can never forge a standard claim.
   reservedClaimKeys :: [Text]
   reservedClaimKeys = ["iss", "sub", "aud", "iat", "exp", "sid", "scopes", "roles", "act"]

   -- | Build an extra-claims object, dropping any reserved key.
   mkExtraClaims :: Object -> Object
   mkExtraClaims = KeyMap.filterWithKey (\k _ -> Key.toText k `notElem` reservedClaimKeys)

   noExtraClaims :: Object
   noExtraClaims = KeyMap.empty
   ```

   (`Key` is `Data.Aeson.Key`.) Because every existing `AuthClaims{...}` literal in the codebase
   must now set `extraClaims`, you will touch each construction site (see step 4). Setting it to
   `noExtraClaims` (i.e. `mempty`) preserves current behavior exactly.

2. In `shomei-jwt/src/Shomei/Jwt/Sign.hs`, in `claimsFromAuth`, fold the extra claims into the
   `ClaimsSet` **before** adding the standard custom claims, so the standard ones win on collision.
   The function currently ends with the `addClaim "sid"/"scopes"/"roles"` chain and the `withActor`
   wrapper; prepend the extra-claims insertion:

   ```haskell
   import Data.Aeson.KeyMap qualified as KeyMap
   import Data.Aeson.Key qualified as Key

   claimsFromAuth :: AuthClaims -> ClaimsSet
   claimsFromAuth ac =
       withActor $
           addExtra ac.extraClaims $   -- custom claims first; standard claims below override
               emptyClaimsSet
                   & claimIss ?~ sou (issuerText ac.issuer)
                   & claimSub ?~ sou (idText ac.subject)
                   & claimAud ?~ Audience [sou (audienceText ac.audience)]
                   & claimIat ?~ NumericDate ac.issuedAt
                   & claimExp ?~ NumericDate ac.expiresAt
                   & addClaim "sid"    (Aeson.String (idText ac.sessionId))
                   & addClaim "scopes" (Aeson.toJSON (Set.toList ac.scopes))
                   & addClaim "roles"  (Aeson.toJSON (Set.toList ac.roles))
     where
       addExtra obj cs =
           KeyMap.foldrWithKey (\k v -> addClaim (Key.toText k) v) cs obj
       withActor cs = case ac.actor of
           Just uid -> cs & addClaim "act" (Aeson.String (idText uid))
           Nothing  -> cs
   ```

   Note the *ordering guarantee*: `addExtra` runs first (it inserts the custom keys into
   `unregisteredClaims`), but the standard *registered* claims (`iss`/`sub`/`aud`/`iat`/`exp`) live
   in their own typed slots and cannot be overwritten by `addClaim` at all; and `sid`/`scopes`/
   `roles`/`act` are added *after* `addExtra`, so they override any same-named custom key.
   Combined with `mkExtraClaims` (step 1) which drops reserved keys at construction, this is
   defense in depth. Because `addClaim` is deprecated-by-`jose`-but-deliberately-used here, the
   `{-# OPTIONS_GHC -Wno-deprecations #-}` pragma already at the top of `Sign.hs` covers it.

3. In `shomei-jwt/src/Shomei/Jwt/Verify.hs`, in `claimsToAuth`, recover the extra claims by taking
   the `unregisteredClaims` map and removing the keys Shōmei itself manages, then store the rest in
   `extraClaims`. The function already binds `claims = cs ^. unregisteredClaims`; add:

   ```haskell
   import Data.Aeson.KeyMap qualified as KeyMap
   import Data.Aeson.Key qualified as Key
   import Shomei.Domain.Claims (reservedClaimKeys)

   -- inside claimsToAuth, after computing scs/rls/actor', build:
   let managed = ["sid", "scopes", "roles", "act"]  -- registered iss/sub/... are not in the map
       extra =
           KeyMap.fromList
               [ (Key.fromText k, v)
               | (k, v) <- Map.toList claims
               , k `notElem` managed
               ]
   ...
   pure AuthClaims { ..., extraClaims = extra }
   ```

   (`claims :: Map Text Aeson.Value` is jose's unregistered-claims map; the standard registered
   claims `iss/sub/aud/iat/exp` are not in it, so only `sid/scopes/roles/act` need excluding.) Add
   `extraClaims = extra` to the returned `AuthClaims`. This means whatever custom keys the token
   carried are returned to the caller verbatim — TAN's EP-3 reads `userId`/`userInfo`/etc. straight
   out of `extraClaims`.

4. Fix every `AuthClaims{...}` construction site to set `extraClaims`. Find them with
   `grep -rn "AuthClaims" --include=*.hs shomei-core shomei-jwt shomei-server`. The known sites are:
   - `shomei-core/src/Shomei/Workflow/Session.hs` — `buildClaims`: set `extraClaims = noExtraClaims`.
   - `shomei-core/src/Shomei/Workflow/Impersonation.hs` — the delegated-token claims builder (if it
     constructs `AuthClaims` directly): set `extraClaims = noExtraClaims`.
   - `shomei-jwt/test/Shomei/Jwt/TestSupport.hs` — `mkClaimsWith`: set `extraClaims = noExtraClaims`.
   - Any other site grep reports.

   To let a consuming service *inject* per-token custom claims without each workflow knowing them,
   add one optional builder helper in `Shomei.Workflow.Session` that the service (or EP-3's own
   minting code) can use:

   ```haskell
   import Data.Aeson (Object)
   import Shomei.Domain.Claims (mkExtraClaims, noExtraClaims)

   -- | Like 'buildClaims' but with a service-supplied custom-claims object.
   buildClaimsWith :: ShomeiConfig -> Object -> UserId -> SessionId -> UTCTime -> AuthClaims
   buildClaimsWith cfg extra uid sid ts =
       (buildClaims cfg uid sid ts) { extraClaims = mkExtraClaims extra }
   ```

   Keep `buildClaims` (no extra claims) as the default the existing workflows call, so login/refresh
   stay unchanged. EP-3 in auth-service-v2 calls `buildClaimsWith` (or sets `extraClaims` on its own
   `AuthClaims`) to attach the TAN claim shape.

**Acceptance.** A new `shomei-jwt` test signs claims with a non-empty `extraClaims` (e.g.
`{"impersonated": false, "userInfo": {"userRole":"agent"}}`), verifies them, and asserts the
recovered `extraClaims` equals the input; a second case asserts that a custom `"sub"` in the bag is
*ignored* (the real subject wins) — proving the reserved-key guarantee. Exact steps in "Concrete
Steps".


### Milestone M4 — Wire algorithm + custom claims through config, server bootstrap, and the admin CLI

**Scope.** Make the algorithm selectable from configuration and used by the server's key
bootstrap and by `shomei-admin keys generate`, so an operator running auth-service-v2 actually gets
RS256 keys end to end. **At the end** setting the algorithm in config (or a CLI flag) produces RS256
keys, and the server signs/serves them.

**Work.**

1. `SigningKeyConfig{algorithm :: Text}` already exists in
   `shomei-core/src/Shomei/Config.hs`. Add a helper that parses it to the enum, so the server reads
   the operator's choice safely:

   ```haskell
   import Shomei.Domain.SigningKey (SigningAlgorithm (ES256), signingAlgorithmFromText)

   -- | The signing algorithm a config selects, defaulting to ES256 on absent/invalid text.
   configSigningAlgorithm :: ShomeiConfig -> SigningAlgorithm
   configSigningAlgorithm cfg =
       either (const ES256) id (signingAlgorithmFromText cfg.signingKeyConfig.algorithm)
   ```

   Export it from `Shomei.Config`.

2. In `shomei-server/src/Shomei/Server/Config.hs`, add an env override `SHOMEI_SIGNING_ALG`
   (`ES256`|`RS256`) and a Dhall `FileConfig` field `signingAlgorithm :: Maybe Text`, both flowing
   into `signingKeyConfig.algorithm`. Mirror the existing pattern used for, e.g.,
   `SHOMEI_TOKEN_TRANSPORT`/`transportEnv`: add `signingAlgEnv :: IO (Maybe Text)` reading
   `SHOMEI_SIGNING_ALG`, validate it is `ES256`/`RS256` (error otherwise), and set
   `signingKeyConfig = base.signingKeyConfig { algorithm = fromMaybe ... }` in `overlayCoreFromEnv`,
   plus the `baseFromFile` merge for the Dhall field. This keeps the twelve-factor precedence
   (defaults → Dhall → env) intact.

3. In `shomei-server/src/Shomei/Server/Keys.hs`, make `bootstrapKeys` generate the *configured*
   algorithm on first boot. `ensureActiveKey` currently calls `generateSigningKey` (ES256) and
   `toStoredSigningKey` (writes `"ES256"`). Thread the algorithm in:

   ```haskell
   import Shomei.Domain.SigningKey (SigningAlgorithm)
   import Shomei.Jwt.Key (generateSigningKeyFor, toStoredSigningKeyFor)

   bootstrapKeys :: SigningAlgorithm -> Pool -> IO (JWK, JWKSet)
   bootstrapKeys alg pool = do ... ensureActiveKey alg ...

   ensureActiveKey alg = do
       active <- listActiveSigningKeys
       case active of
           (k : _) -> pure k                 -- reuse existing key (idempotent across restarts)
           []      -> do
               t   <- now
               jwk <- liftIO (generateSigningKeyFor alg)
               let sk = toStoredSigningKeyFor alg t jwk
               insertSigningKey sk
               pure sk
   ```

   Update the caller in `shomei-server/src/Shomei/Server/Boot.hs` to pass
   `configSigningAlgorithm cfg`. **Idempotence note:** because generation is guarded on "no active
   key", changing `SHOMEI_SIGNING_ALG` after a key already exists does *not* silently switch
   algorithms — you must rotate keys (via the admin CLI / `rotateSigningKey`) to move to a new
   algorithm. State this in the operator-facing notes.

4. In `shomei-server/app/Shomei/Admin/Keys.hs`, make `keysGenerate` accept an algorithm. It
   currently calls `generateSigningKey` + `toStoredSigningKey`. Change its signature to
   `keysGenerate :: SigningAlgorithm -> Pool -> IO ()` (using `generateSigningKeyFor` /
   `toStoredSigningKeyFor`), and update `shomei-server/app/Admin.hs` (the CLI option parser) to add
   an `--alg ES256|RS256` option for `keys generate`, defaulting to `ES256`. Print the algorithm in
   the success line (`"generated pending RS256 key: <kid>"`). `rotateSigningKey` in
   `shomei-jwt/src/Shomei/Jwt/Rotation.hs` similarly should generate the configured algorithm; give
   it a `SigningAlgorithm` parameter and update its callers, or add `rotateSigningKeyFor alg` and
   keep `rotateSigningKey = rotateSigningKeyFor ES256` for back-compat.

**Acceptance.** `cabal build all` succeeds. A unit test in `shomei-server` (or a focused
`shomei-jwt` test, if a DB is not available in the harness) proves `configSigningAlgorithm` parses
`"RS256"` to `RS256` and an unknown string to `ES256`. The CLI parser test (if present) accepts
`keys generate --alg RS256`. Exact commands in "Concrete Steps".


### Milestone M5 — Acceptance: an RS256 token carrying a custom claim round-trips through the JWKS verify path

**Scope.** One end-to-end test that ties everything together exactly as auth-service-v2 EP-3 will
use it. **At the end** there is a single test case (and one command to run it) that proves the whole
feature.

**Work.** Add a test (e.g. `shomei-jwt/test/Shomei/Jwt/RsaCustomClaimSpec.hs`, registered in the
`shomei-jwt` test suite's `other-modules` and aggregated in `test/Main.hs`) that does:

1. Generate an RS256 key: `jwk <- generateSigningKeyFor RS256`.
2. Build claims with a custom claim bag mirroring the TAN user-token shape, using `mkExtraClaims`:
   `{"userId":"u-123","impersonated":false,"userInfo":{"userRole":"agent","username":"alice"}}`.
3. Sign: `Right (AccessToken wire) <- signAccessToken jwk ac`.
4. Decode the compact token's **header** segment (split on `"."`, base64url-decode the first part,
   `Aeson.decode`) and assert it contains `"alg":"RS256"` and a `"kid"` equal to `keyKid jwk`.
5. Decode the **payload** segment and assert it contains the custom top-level claim
   (`"userId":"u-123"`) *and* the standard claims (`"sub"`, `"sid"`).
6. Build the **public JWKS** from the key (`publicJwks jwk []`) and verify:
   `res <- verifyToken (publicJwks jwk []) testConfig wire`. Assert `res` is `Right ac'` and that
   `ac'.extraClaims` equals the input bag and the standard fields match.
7. A negative sub-case: put `"sub":"attacker"` into the extra bag *before* `mkExtraClaims`, sign,
   verify, and assert the recovered `subject` is the legitimate one (proving reserved keys cannot be
   forged).

**Acceptance.** `cabal test shomei-jwt` shows the new `RsaCustomClaim` group passing, and the full
`cabal test all` is green. The transcript in "Concrete Steps" shows the expected lines.


## Concrete Steps

Run everything from the repo root `/Users/shinzui/Keikaku/bokuno/shomei` unless noted. Each block
shows the command and a short *expected* transcript so you can compare. If `nix develop` is not
available, drop the `nix develop --command ` prefix.

**M0 baseline.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal build all
nix develop --command cabal test shomei-jwt
```

Expected (abridged):

```text
Build profile: -w ghc-9.12.4 -O1
...
All N tests passed (0.10s)
Test suite shomei-jwt-test: PASS
```

**M1 — verify RSA key generation, stored algorithm, and JWKS.** After editing `SigningKey.hs` and
`Key.hs`, add a `shomei-jwt` test case (in a new `KeyAlgSpec` module or appended to `KeySpec`)
asserting:

```haskell
testCase "generates an RS256 key recorded as RS256 with a kid and an RSA JWKS" $ do
    jwk <- generateSigningKeyFor RS256
    t   <- getCurrentTime
    let sk = toStoredSigningKeyFor RS256 t jwk
    sk.algorithm @?= "RS256"
    assertBool "kid set" (not (Text.null sk.keyId))
    -- JWKS contains an RSA key
    let doc = jwksDocument [jwk]
    assertBool "JWKS mentions RSA" ("\"kty\":\"RSA\"" `Text.isInfixOf`
        Text.decodeUtf8 (BSL.toStrict doc))
```

Run:

```bash
nix develop --command cabal test shomei-jwt
```

Expected: the new case passes alongside the existing ones.

**M2 — verify the `alg` header is RS256.** Add a helper to base64url-decode the header segment and
a test:

```haskell
testCase "RS256 key signs a token whose header alg is RS256" $ do
    jwk <- generateSigningKeyFor RS256
    t   <- getCurrentTime
    ac  <- mkClaims testConfig t
    Right (AccessToken wire) <- signAccessToken jwk ac
    hdr <- decodeHeader wire   -- split on '.', b64url-decode [0], Aeson.decode
    KeyMap.lookup "alg" hdr @?= Just (Aeson.String "RS256")
    KeyMap.lookup "kid" hdr @?= Just (Aeson.String (keyKid jwk))
```

Run `nix develop --command cabal test shomei-jwt`. Expected: passes, and the *existing* ES256
round-trip test still passes (its header shows `ES256`).

**M3 — verify custom claims round-trip and reserved-key safety.**

```haskell
testCase "custom claims round-trip" $ do
    jwk <- generateSigningKey
    t   <- getCurrentTime
    base <- mkClaims testConfig t
    let extra = mkExtraClaims (KeyMap.fromList
                  [("impersonated", Aeson.Bool False), ("userId", Aeson.String "u-123")])
        ac = base { extraClaims = extra }
    Right (AccessToken wire) <- signAccessToken jwk ac
    Right ac' <- verifyToken (publicJwks jwk []) testConfig wire
    ac'.extraClaims @?= extra

testCase "a custom sub cannot forge the subject" $ do
    jwk <- generateSigningKey
    t   <- getCurrentTime
    base <- mkClaims testConfig t
    let ac = base { extraClaims = mkExtraClaims
                      (KeyMap.fromList [("sub", Aeson.String "attacker")]) }
    Right (AccessToken wire) <- signAccessToken jwk ac
    Right ac' <- verifyToken (publicJwks jwk []) testConfig wire
    idText ac'.subject @?= idText base.subject   -- legitimate subject preserved
```

Run `nix develop --command cabal test shomei-jwt`. Expected: both pass.

**M4 — verify config parsing.** Add a `shomei-server` (or `shomei-core`) test:

```haskell
testCase "configSigningAlgorithm parses RS256 and falls back to ES256" $ do
    let cfg = defaultShomeiConfig (Issuer "i") (Audience "a")
        rs  = cfg { signingKeyConfig = SigningKeyConfig { algorithm = "RS256" } }
        bad = cfg { signingKeyConfig = SigningKeyConfig { algorithm = "nope" } }
    configSigningAlgorithm rs  @?= RS256
    configSigningAlgorithm bad @?= ES256
```

Run `nix develop --command cabal build all` then the relevant `cabal test`. Expected: passes.

**M5 — the headline acceptance test.**

```bash
nix develop --command cabal test shomei-jwt
```

Expected transcript (abridged):

```text
RsaCustomClaim
  RS256 token with a custom claim round-trips via JWKS: OK
  reserved keys cannot be forged via the extra bag:    OK
All N tests passed
Test suite shomei-jwt-test: PASS
```

Then the full suite:

```bash
nix develop --command cabal test all
```

Expected: every package's test suite reports `PASS`.


## Validation and Acceptance

The feature is accepted when **all** of the following hold, each observable by a human running a
named command and reading its output:

1. **Build is clean.** `nix develop --command cabal build all` completes with no errors.
2. **Existing behavior is preserved.** The pre-existing `shomei-jwt` `SignVerify` cases still pass,
   proving ES256 tokens and the `act`-claim behavior are unchanged, and that empty-`extraClaims`
   tokens are unaffected.
3. **RS256 is selectable and correct.** The M2 test shows a token whose decoded header reads
   `"alg":"RS256"` (not `PS256`/`PS512`) with the right `kid`, and that token verifies. This is the
   exact behavior auth-service-v2 EP-3 and the legacy gateway require.
4. **Custom claims work.** The M3 tests show an arbitrary JSON claim bag survives sign→verify, and
   that a forged standard claim in the bag is ignored.
5. **End-to-end acceptance.** The M5 `RsaCustomClaim` test signs an RS256 token carrying a custom
   claim, proves the header/payload contents by decoding the compact token, and verifies it through
   the public JWKS path with the custom claim preserved.
6. **Wiring is real.** The M4 config test shows `configSigningAlgorithm` maps `"RS256"` → `RS256`,
   so an operator's config actually drives RSA key generation in the server bootstrap and the
   `shomei-admin keys generate --alg RS256` CLI.

All test commands are `cabal test <suite>`; success is the `PASS`/`All tests passed` line and
failure is any `FAIL`/`tests failed` line with the named case.


## Idempotence and Recovery

- **Builds and tests** are naturally idempotent — rerun them freely.
- **Code edits** are additive: new constructors (`RS256`), new functions (`generateSigningKeyFor`,
  `toStoredSigningKeyFor`, `buildClaimsWith`, `configSigningAlgorithm`), and one new record field
  (`extraClaims`). The original `generateSigningKey`/`toStoredSigningKey`/`buildClaims`/
  `rotateSigningKey` remain as ES256/no-extra aliases so nothing that already compiled breaks. If a
  build fails because a literal `AuthClaims{...}` is missing the new field, the compiler names the
  exact file and line; add `extraClaims = noExtraClaims` there.
- **No migration is needed.** The `shomei_signing_keys.algorithm` column already exists
  (`shomei-migrations/sql-migrations/2026-06-03-00-00-05-shomei-signing-keys.sql`). RSA keys are
  stored as opaque JWK JSON in the same columns ES256 keys use.
- **Key-algorithm changes are guarded.** `bootstrapKeys` only generates a key when none is active,
  so flipping `SHOMEI_SIGNING_ALG` on an already-keyed database has no effect until you rotate.
  Recovery from an unwanted algorithm: run `shomei-admin keys generate --alg <desired>` then
  `keys activate <kid>` (which auto-retires the old key); the JWKS publishes both during overlap so
  tokens signed under the old key keep verifying until they expire (zero-downtime).
- **Safe to abandon mid-way.** Each milestone leaves the tree compiling and the test suite green;
  stopping after any milestone is safe.


## Interfaces and Dependencies

**Libraries.** Only `shomei-jwt` depends on `jose` (the JWT/JOSE library, vendored from a fork at
`/Users/shinzui/Keikaku/hub/haskell/jose-project`; the project pins `jose` 0.13 via the
`source-repository-package` block in `cabal.project`). The `jose` names this plan uses:
`Crypto.JOSE.JWK` (`JWK`, `JWKSet`, `KeyMaterialGenParam(ECGenParam, RSAGenParam)`, `genJWK`,
`jwkUse`, `jwkKid`, `jwkMaterial`, `thumbprint`, `asPublicKey`, `bestJWSAlg`),
`Crypto.JOSE.JWA.JWK` (`Crv(P_256)`, `KeyMaterial(ECKeyMaterial, RSAKeyMaterial)`),
`Crypto.JOSE.JWA.JWS` (`Alg(ES256, RS256, PS256, ...)`), `Crypto.JOSE.JWS`
(`newJWSHeader`, `signClaims`, `kid`), `Crypto.JOSE.Header`
(`HeaderParam`, `OptionalProtection(Protected)` — note: `Protected` is a
constructor of `OptionalProtection`; `Protection` is a deprecated synonym and
must not be used in the import), `Crypto.JWT` (`ClaimsSet`, `addClaim`,
`unregisteredClaims`, the `claim*` lenses, `verifyClaims`, etc.). `aeson`'s `Object`,
`Data.Aeson.KeyMap`, and `Data.Aeson.Key` carry the extra-claims bag.

**Signatures that must exist at each milestone's end (full module paths).**

- After M1, in `Shomei.Domain.SigningKey`:
  `data SigningAlgorithm = ES256 | RS256`,
  `signingAlgorithmToText :: SigningAlgorithm -> Text`,
  `signingAlgorithmFromText :: Text -> Either Text SigningAlgorithm`.
  In `Shomei.Jwt.Key`: `generateSigningKeyFor :: SigningAlgorithm -> IO JWK`,
  `generateSigningKey :: IO JWK` (= `generateSigningKeyFor ES256`),
  `toStoredSigningKeyFor :: SigningAlgorithm -> UTCTime -> JWK -> StoredSigningKey`,
  and the existing `toStoredSigningKey`, `keyKid`, `fromStoredSigningKey` unchanged.

- After M2, in `Shomei.Jwt.Sign`: `signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError
  AccessToken)` (now choosing `RS256` for RSA keys), with an internal `algForKey :: JWK -> Alg`.
  `runTokenSignerJwt` unchanged in signature.

- After M3, in `Shomei.Domain.Claims`: `AuthClaims` gains `extraClaims :: !Object`;
  `mkExtraClaims :: Object -> Object`, `noExtraClaims :: Object`,
  `reservedClaimKeys :: [Text]` exported. In `Shomei.Jwt.Sign`: `claimsFromAuth` folds in
  `extraClaims`. In `Shomei.Jwt.Verify`: `claimsToAuth` recovers `extraClaims`. In
  `Shomei.Workflow.Session`:
  `buildClaimsWith :: ShomeiConfig -> Object -> UserId -> SessionId -> UTCTime -> AuthClaims`
  (and `buildClaims` unchanged).

- After M4, in `Shomei.Config`:
  `configSigningAlgorithm :: ShomeiConfig -> SigningAlgorithm`. In `Shomei.Server.Keys`:
  `bootstrapKeys :: SigningAlgorithm -> Pool -> IO (JWK, JWKSet)`. In `Shomei.Admin.Keys`:
  `keysGenerate :: SigningAlgorithm -> Pool -> IO ()`. In `Shomei.Jwt.Rotation`:
  `rotateSigningKeyFor :: SigningAlgorithm -> ...` (with `rotateSigningKey` as the ES256 alias).

**Consumers.** auth-service-v2 EP-3
(`/Users/shinzui/Keikaku/work/microtan/auth-service/docs/plans/4-token-claims-key-endpoint-compatibility.md`)
configures `signingKeyConfig.algorithm = "RS256"` and builds `AuthClaims` with `extraClaims` set to
the exact legacy TAN claim shape (user token: `userId`, `clientAccountId?`, `impersonated`,
`userInfo`; service token: `type`, `serviceInfo`). It serves the resulting public key at the legacy
`/.well-known/jwt` endpoint and the JWKS at `/.well-known/jwks.json`. EP-3 must not modify Shōmei;
it only uses the seams this plan adds.


---

**Revision note (2026-06-17).** Initial authored version of SH-24. Key research findings baked in:
(1) `SigningKeyConfig.algorithm`, `StoredSigningKey.algorithm`, and the `shomei_signing_keys.algorithm`
column already exist but are inert; this plan makes them meaningful rather than adding new storage.
(2) `jose`'s `bestJWSAlg` returns a PSS algorithm (PS512) for RSA keys, so the signer must pin
`RS256` explicitly via `newJWSHeader` instead of `makeJWSHeader` — this is recorded in Surprises &
Discoveries and drove the M2 design. (3) Custom claims are carried as an `Aeson.Object` on
`AuthClaims` (rejected alternatives: a `ToExtraClaims` type class, and signer-seam-only injection)
with a reserved-key guarantee so standard claims can never be forged via the bag.

**Revision note (2026-06-17, validation pass).** Validated the plan end-to-end against the live
shomei tree and the vendored jose fork. Confirmed accurate: `AuthClaims` fields and JSON deriving;
`StoredSigningKey.algorithm :: Text` and its `keyId` field; `SigningKeyConfig{algorithm :: Text}`
default `"ES256"` and `defaultShomeiConfig`; `generateSigningKey`/`toStoredSigningKey` (hard-codes
`"ES256"`)/`keyKid`/`fromStoredSigningKey`; `signAccessToken`/`claimsFromAuth`/`runTokenSignerJwt`
using `makeJWSHeader` with the `addClaim` chain; the `-Wno-deprecations` pragma at the top of
`Sign.hs`; `verifyToken`/`claimsToAuth`; `bootstrapKeys :: Pool -> IO (JWK, JWKSet)` and its
`Boot.hs` call site; `keysGenerate :: Pool -> IO ()` and the `Admin.hs` parser; the
`transportEnv`/`overlayCoreFromEnv`/`FileConfig`/`baseFromFile` env-overlay pattern in
`Server/Config.hs`; the `2026-06-03-00-00-05-shomei-signing-keys.sql` migration with `algorithm
text NOT NULL`; the tasty test harness with `TestSupport.mkClaims`/`mkClaimsWith`/`testConfig`;
`buildClaims` in `Workflow/Session.hs`; and `Workflow/Impersonation.hs` constructing `AuthClaims`
directly (a construction site M3 step 4 must update). One corrective change was applied: the M2
header import and the Interfaces list now use `OptionalProtection (Protected)` instead of the
deprecated/non-constructor `Protection (Protected)` synonym (see Surprises & Discoveries), and a
note clarifies that `publicJwks` is a `TestSupport` helper. No milestone structure changed; the
plan fits the project.
