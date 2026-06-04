---
id: 4
slug: jwt-signing-verification-and-jwks-publishing
title: "JWT signing, verification, and JWKS publishing"
kind: exec-plan
created_at: 2026-06-03T23:50:58Z
intention: "intention_01kt7xgv3pes2v675nr1pmzf6j"
master_plan: "docs/masterplans/1-bootstrap-shomei-authentication-toolkit.md"
---

# JWT signing, verification, and JWKS publishing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan builds the cryptographic heart of the Shōmei authentication toolkit: the package
`packages/shomei-jwt`. After this plan is done, Shōmei can take a set of authentication
claims (who the user is, which session they are in, what they are allowed to do) and turn
them into a signed, tamper-evident **access token** that any other service can verify on its
own — without ever calling back to Shōmei. It can also generate fresh signing keys, rotate
them on a schedule, and publish the public half of those keys as a standard **JWKS document**
that downstream services fetch once and cache.

Before defining anything else, here is the vocabulary used throughout this plan. A **JWT**
(JSON Web Token, pronounced "jot") is a compact, URL-safe string carrying a JSON payload of
**claims** (statements such as "the subject is user X", "this token expires at time T"). A
**JWS** (JSON Web Signature) is a JWT that has been cryptographically signed; the wire form
is three Base64URL-encoded segments joined by dots — `header.payload.signature`. A **JWK**
(JSON Web Key) is a JSON object describing one cryptographic key (for an elliptic-curve key
it has fields like `"kty":"EC"`, `"crv":"P-256"`, `"x"`, `"y"`, and — for the *private* key
only — `"d"`). A **JWKS** (JSON Web Key Set) is a JSON object `{"keys":[ ... ]}` containing
several public JWKs; this is the document a verifier downloads. A **kid** ("key ID") is a
short string that labels one key so that a token's header can say "I was signed by the key
named kid", letting the verifier pick the right public key out of the set. **Asymmetric
signing** means the key used to *sign* (the private key) is different from the key used to
*verify* (the public key); only Shōmei holds the private key, but anyone holding the public
JWKS can verify. This asymmetry is exactly what lets downstream services verify tokens
locally, and it is why Shōmei uses asymmetric signing rather than a shared secret.

You can see the result working three ways. First, a unit test generates an elliptic-curve
key, converts it to Shōmei's storage record and back, and confirms the key's `kid` is stable
across the round trip. Second, a test signs a set of claims into an access token, verifies
that token against the matching public key set, and confirms every field survived
(subject, session, scopes, roles, issuer, audience). Third, a test prints a JWKS document
and confirms it is valid JSON containing the right `kid` and **no** private field (`"d"`),
then proves a token signed by key A verifies against a JWKS that contains both key A and an
unrelated key B — demonstrating that selection by `kid` works. The final acceptance is the
command `cabal test shomei-jwt` printing `All N tests passed`.

This package is deliberately narrow. It depends only on `shomei-core` (for the domain types
and the port effect interfaces) plus the `jose` cryptography library and its `crypton`
backend. It must **not** depend on `shomei-postgres`: signing keys reach this package as
plain records through the `SigningKeyStore` port effect, and the PostgreSQL implementation
of that port is wired up by a later, separate plan (EP-6). Keeping `shomei-jwt` ignorant of
the database is what lets it be tested in complete isolation and reused in the embedded
deployment mode where there may be no Shōmei database at all.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Build spike: `packages/shomei-jwt` with `jose` compiles on GHC 9.12.4
      and a throwaway `genJWK (ECGenParam P_256)` + sign + verify proves `jose` works.
      (2026-06-03; `spike: ok`, jose-0.13 + crypton-1.1.3 + ram-0.21.1, no `allow-newer` needed.)
- [x] Milestone 1 — Record the build outcome and any `allow-newer` bump in the Decision Log
      and Surprises & Discoveries. (2026-06-03)
- [x] Milestone 2 — `Shomei.Jwt.Key`: `generateSigningKey`, `toStoredSigningKey`,
      `fromStoredSigningKey`, kid computation; round-trip test green. (2026-06-03; scenario (a))
- [x] Milestone 2 — `Shomei.Jwt.Jwks`: `jwksDocument` and the `KeySet` abstraction; JWKS
      JSON contains the right kid(s) and no private `d` field. (2026-06-03; scenario (g) shape
      half; the kid-selection half moves to M3's SignVerifySpec since it needs the signer)
- [ ] Milestone 3 — `Shomei.Jwt.Sign`: ClaimsSet builder + `runTokenSignerJwt` interpreter.
- [ ] Milestone 3 — `Shomei.Jwt.Verify`: `verifyToken` (the EP-5 contract) +
      `runTokenVerifierJwt` interpreter; jose `JWTError` mapped to `TokenError`.
- [ ] Milestone 3 — `Shomei.Jwt.Rotation`: rotation service over `SigningKeyStore` + `Clock`.
- [ ] Milestone 3 — `test-suite shomei-jwt-test`: all eight test scenarios (a–h) green via
      `cabal test shomei-jwt`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The PR-#137 commit is not on a branch/tag of the canonical repo, but the `sumo/hs-jose`
  fork carries it as `master` HEAD.** `git ls-remote https://github.com/frasertweedale/hs-jose.git`
  shows `4726d077a13b24cd1d78fb94b2db5a86c79e3f0f` only under `refs/pull/137/head`. cabal's
  `source-repository-package` does a plain clone (which does **not** fetch `refs/pull/*`), so
  pinning the canonical repo at that commit would fail to check out. `git ls-remote
  https://github.com/sumo/hs-jose.git` shows the same commit as `refs/heads/master` / `HEAD`,
  so `location: https://github.com/sumo/hs-jose.git` (the URL the Decision Log already named)
  is the one that actually resolves. Evidence: the build log printed
  `branch 4726d077… -> FETCH_HEAD` / `HEAD is now at 4726d07 Update to crypton >= 1.1.0 and ram
  instead of memory`.
- **No `allow-newer` was needed.** `cabal build shomei-jwt-spike` resolved and built jose-0.13,
  crypton-1.1.3, crypton-x509-1.9.0, ram-0.21.1, monad-time-0.4.0.0, and concise-0.1.0.1 on
  GHC 9.12.4 (base 4.21) with the existing `cabal.project` — no `base`/`lens` bound relaxation
  required. Risk 2 from the Plan of Work did not materialize. The pre-existing `allow-newer:
  haxl:time` (from EP-3) is untouched.
- **jose's signing/verification monad is `JOSE e m` (run with `runJOSE`), NOT `ExceptT e IO`.**
  crypton's `MonadRandom` (`Crypto.Random.Types`) has instances only for `IO` and
  `MonadPseudoRandom` — there is no `MonadRandom (ExceptT e m)`. jose supplies its own newtype
  `JOSE e m = JOSE (ExceptT e m)` (`Crypto.JOSE.Error`) with `instance MonadRandom m =>
  MonadRandom (JOSE e m)`, and its own test suite (`test/JWT.hs`) runs `signClaims`/`verifyClaims`
  inside `runJOSE $ do …`. `MonadTime (JOSE e IO)` is satisfied via monad-time's overlappable
  `MonadTrans`-based instance (`JOSE e` is a `MonadTrans`). Consequence: the draft spike in the
  Plan of Work using `runExceptT @JWTError` is wrong; real signing/verification code uses
  `runJOSE` (see the corrected Decision Log entry). The spike was written this way and prints
  `spike: ok`.
- **jose API names differing from the Plan-of-Work drafts (confirmed against the on-disk jose
  0.12 source, identical surface in 0.13):** signing headers are built with
  `newJWSHeaderProtected :: ProtectionSupport p => Alg -> JWSHeader p` (giving the
  `RequiredProtection` header `signClaims` needs) — *not* `newJWSHeader (Protected, ES256)`,
  which yields `OptionalProtection`. Even better, `makeJWSHeader :: (MonadError e m, AsError e,
  ProtectionSupport p) => JWK -> m (JWSHeader p)` picks the alg via `bestJWSAlg` and copies the
  key's `kid` into the protected header automatically. `JWTError` has exactly 7 constructors:
  `JWSError Error`, `JWTClaimsSetDecodeError String`, `JWTExpired`, `JWTNotYetValid`,
  `JWTNotInIssuer`, `JWTNotInAudience`, `JWTIssuedAtFuture`. `JWSInvalidSignature` and
  `CompactDecodeError` are constructors of the **inner** `Crypto.JOSE.Error.Error` (wrapped by
  `JWSError`), not of `JWTError`. `StringOrURI` ⇄ `Text` uses the `string :: Prism' StringOrURI
  Text` prism (and the `IsString` instance for the other direction); `Audience` is `Audience
  [StringOrURI]` with prism `_Audience`; `NumericDate` is `NumericDate UTCTime` with prism
  `_NumericDate`. The `JWKSet` `VerificationKeyStore` instance returns **all** keys (no kid
  filtering), so verification simply tries each key — including the signing key in a multi-key
  set is what makes scenario (g) pass.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the `jose` library (also published as `crypton-jose`) for all JWS/JWK/JWKS
  work, pulled from the **PR #137 revision** (`crypton >= 1.1.0`, `ram` instead of `memory`;
  jose version 0.13) via a `cabal.project` `source-repository-package`, NOT from Hackage.
  Rationale: It is the standard JWT/JWK/JWKS library on the `crypton` cryptography stack that
  the rest of Shōmei already uses (`mori.dhall` lists `kazu-yamamoto/crypton`). It implements
  RFC 7515 (JWS), RFC 7517 (JWK/JWKS), RFC 7519 (JWT), and RFC 7638 (thumbprints) directly, so
  we do not hand-roll cryptography. The Hackage release (jose 0.12) cannot be used: it depends
  on `memory` and `crypton >= 0.31`, but the corpus `crypton` is **1.1.2**, which replaced the
  `memory` package with **`ram`** (a drop-in fork that keeps the `Data.ByteArray` module and
  `constEq`). jose 0.12 compiled against crypton 1.1.x would import a *different* `ByteArray`
  class than crypton exposes and fail to type-check. `frasertweedale/hs-jose` PR #137 ("Update
  to crypton >= 1.1.0 and ram instead of memory", commit
  `4726d077a13b24cd1d78fb94b2db5a86c79e3f0f`, still OPEN as of this writing) is exactly the fix.
  Use it via:
  ```cabal
  source-repository-package
    type: git
    location: https://github.com/sumo/hs-jose.git
    tag: 4726d077a13b24cd1d78fb94b2db5a86c79e3f0f
  ```
  Swap `location` to a `shinzui/hs-jose` fork if one is maintained (mirroring the
  `shinzui/codd-project`/`shinzui/ephemeral-pg` pattern). This `source-repository-package` is
  EP-4's contribution to `cabal.project` (MasterPlan IP-8), alongside EP-3's codd/ephemeral-pg
  entries — add it in the EP-1 placeholder section, do not duplicate the block. This decision
  was confirmed at the MasterPlan level; the crypton-1.1/`ram`/PR-137 detail was confirmed with
  the user after the corpus `jose`/`crypton` versions were checked.
  Date: 2026-06-03

- Decision: Default signing algorithm is **ES256** (ECDSA over the NIST P-256 curve, with
  SHA-256). Generated via `genJWK (ECGenParam P_256)`; signed with `Alg = ES256`.
  Rationale: ES256 is asymmetric (private key signs, public key verifies), which is mandatory
  for downstream local verification via a published JWKS. Its keys and signatures are far
  smaller than RSA's (a P-256 signature is 64 bytes versus 256+ for RSA-2048), and ES256 is
  universally supported by JWKS consumers. Alternatives considered: **EdDSA** (Ed25519) — even
  smaller and faster, but slightly less universal verifier support; **RS256** (RSA) — the most
  universally supported but with much larger keys/signatures and slower keygen. Both remain
  available by changing the `KeyMaterialGenParam` and the `Alg` value; the algorithm tag is
  stored per-key in `StoredSigningKey.algorithm`, so a future migration to another algorithm
  can coexist with old keys.
  Date: 2026-06-03

- Decision: The `kid` (key identifier) for each generated key is the RFC 7638 JWK thumbprint
  (the SHA-256 hash of the key's canonical JSON, Base64URL-encoded), computed via jose's
  `thumbprint` getter.
  Rationale: A thumbprint is deterministic and collision-resistant: the same public key always
  yields the same `kid`, and different keys yield different `kid`s. This makes the `kid` stable
  across a `StoredSigningKey` round trip (a property a test asserts) and means we never have to
  invent or track an external counter for key naming.
  Date: 2026-06-03

- Decision: Store JWK material as opaque JSON `Text` inside `StoredSigningKey`
  (`privateKeyJwk` and `publicKeyJwk` fields), using `aeson`'s `encode`/`decode`.
  Rationale: `shomei-core` defines `StoredSigningKey` with `Text` key material precisely so
  that the core and the postgres package never import `jose` (MasterPlan IP-4). `shomei-jwt`
  is the only package that converts between this `Text` and a live `jose` `JWK`. JWK is itself
  a JSON format, so serializing to JSON `Text` is lossless and is what the standard expects.
  Date: 2026-06-03

- Decision: Map jose's `JWTError` to the core's `TokenError` sum at the verification boundary.
  Specifically: expired token → `TokenExpired`; audience mismatch → `TokenAudienceInvalid`;
  issuer mismatch → `TokenIssuerInvalid`; any signature/verification failure (including "no
  key matched the kid") → `TokenSignatureInvalid`; a malformed/undecodable compact token →
  `TokenMalformed`; anything else → `TokenOtherError <shown error>`.
  Rationale: The core's `TokenError` is the transport-agnostic vocabulary the rest of the
  system (and EP-5's HTTP layer) reasons about. Translating jose's internal error type at the
  boundary keeps jose out of every other package's error handling and gives precise,
  stable semantics (e.g. a 401 for a bad signature versus a 401 with a different reason for an
  expired token).
  Date: 2026-06-03

- Decision: Expose a plain `verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either
  TokenError AuthClaims)` in `Shomei.Jwt.Verify`, in addition to the `effectful` interpreter.
  Rationale: This is the **EP-4 ↔ EP-5 contract**. EP-5's Servant `Authenticated` combinator
  runs inside a Servant `AuthHandler`, which lives in `Handler`/`IO` and is **not** an
  `effectful` `Eff` computation. It therefore needs a verifier with an ordinary `IO` shape it
  can call directly. The `effectful` `runTokenVerifierJwt` interpreter is implemented on top of
  the same `verifyToken` so there is a single source of verification truth.
  Date: 2026-06-03

- Decision: Key rotation policy is intentionally simple: generate a new key, insert it with
  status `KeyActive`, and mark the previously-active key as `KeyRetired` with `retiredAt =
  now`. The published JWKS includes all keys that are not `KeyRevoked` (i.e. active **and**
  retired), so tokens signed by the just-retired key still verify until they expire.
  Rationale: Including retired-but-not-revoked keys in the JWKS is what makes rotation
  zero-downtime — a verifier that fetched the JWKS before rotation, or a token minted seconds
  before rotation, keeps working. A `KeyRevoked` key (compromised) is excluded immediately.
  More elaborate policies (overlap windows, scheduled promotion of `KeyPending` keys) are out
  of scope for this bootstrap.
  Date: 2026-06-03

- Decision: Run all jose signing/verification in jose's own `JOSE e m` monad via `runJOSE`,
  not in `ExceptT e IO` as the Plan-of-Work draft code showed.
  Rationale: `signClaims` requires `MonadRandom`, and crypton's `MonadRandom`
  (`Crypto.Random.Types`) has instances only for `IO` and `MonadPseudoRandom` — there is no
  `MonadRandom (ExceptT e m)`, so `runExceptT @JWTError (signClaims …)` does not type-check.
  jose ships `newtype JOSE e m = JOSE (ExceptT e m)` (`Crypto.JOSE.Error`) with `instance
  MonadRandom m => MonadRandom (JOSE e m)` and exports `runJOSE :: JOSE e m a -> m (Either e
  a)`; `MonadTime (JOSE e IO)` comes from monad-time's overlappable `MonadTrans` instance.
  jose's own test suite signs and verifies inside `runJOSE`. The error type is pinned with a
  type application or a result annotation (`:: IO (Either JWTError a)`). Confirmed against the
  jose source and proven by the Milestone-1 spike (`spike: ok`).
  Date: 2026-06-03

- Decision: Pin jose at `location: https://github.com/sumo/hs-jose.git`, `tag:
  4726d077a13b24cd1d78fb94b2db5a86c79e3f0f`.
  Rationale: PR #137's head commit exists on the canonical `frasertweedale/hs-jose` only under
  `refs/pull/137/head`, which cabal's plain-clone `source-repository-package` fetch does not
  retrieve; checkout would fail. The `sumo/hs-jose` fork carries that exact commit as its
  `master` HEAD, so cabal resolves and checks it out cleanly (verified by `git ls-remote` on
  both repos and by the successful build). This matches the URL the original jose Decision Log
  entry already named.
  Date: 2026-06-03

- Decision: Split test scenario (g) across milestones. The JWKS-shape assertions (two keys,
  right `kid`s, no private `"d"`) ship in M2's `Shomei.Jwt.JwksSpec`; the kid-selection
  assertion (sign with key A, verify against a `JWKSet` containing both A and B) ships in M3's
  `Shomei.Jwt.SignVerifySpec`, because it needs `Shomei.Jwt.Sign`/`Shomei.Jwt.Verify`, which do
  not exist until M3. The behavioral coverage of (g) is unchanged; only its home module differs.
  Date: 2026-06-03

- Decision: `shomei-jwt` depends only on `shomei-core` plus `jose`/`crypton` and supporting
  libraries; it does **not** depend on `shomei-postgres`.
  Rationale: Signing keys cross into this package through the `SigningKeyStore` port effect as
  storage-agnostic `StoredSigningKey` records (MasterPlan IP-3, IP-4). The PostgreSQL
  interpreter of that port is provided by `shomei-postgres` and assembled by EP-6. Keeping the
  dependency out preserves isolated testability and the embedded deployment mode.
  Date: 2026-06-03


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan operates inside the Shōmei repository, a Haskell **monorepo** (a single Git
repository containing several related but separately-built packages). The repository root is
`/Users/shinzui/Keikaku/bokuno/shomei`. A prior plan, EP-1
(`docs/plans/1-project-scaffolding-and-multi-package-build-foundation.md`), creates the cabal
workspace, the shared build conventions, and a package skeleton at `packages/shomei-jwt`. A
prior plan, EP-2 (`docs/plans/2-core-domain-model-ports-and-auth-workflows.md`), fills the
`shomei-core` package with the domain types and the **port effects** this plan consumes and
interprets. If you are starting and those packages do not yet exist on disk, that is expected
only if EP-1/EP-2 have not run; this plan assumes they have, and the precise types it depends
on are reproduced below so you do not have to read the other plans.

The `jose` library source is registered in the `mori` corpus and readable on disk at
`/Users/shinzui/Keikaku/hub/haskell/jose-project/hs-jose` (find it any time with `mori registry
show frasertweedale/hs-jose --full`). Read it there to confirm exact module/function/accessor
names rather than guessing — in particular the `StringOrURI`/`Audience` accessors and the
`JWTError` constructor names that this plan marks as "confirm against jose" below. **Caveat: the
corpus copy is jose 0.12, which still depends on the deprecated `memory` package and
`crypton >= 0.31`. Shōmei does NOT build against that copy.** The corpus is for *reading the
API*; the *build* resolves `jose` from the PR #137 `source-repository-package`
(`crypton >= 1.1.0`, `ram` instead of `memory`; see the Decision Log) so it links against the
corpus `crypton` 1.1.2. Use the on-disk 0.12 source to learn the API, but the `ram`/crypton-1.1
build dependencies and the source-repository pin are mandatory.

A **package** here is a directory under `packages/` with its own `.cabal` file. The build tool
is **cabal** (invoked as `cabal build`, `cabal test`), and the compiler is **GHC 9.12.4**. The
project is built inside a **Nix development shell**: run `nix develop` from the repository root
once to enter a shell that has the correct GHC, cabal, and system libraries on `PATH`; all
cabal commands in this plan assume you are inside that shell with the working directory at the
repository root unless stated otherwise.

The library this plan revolves around is **`effectful`**, an "effect system" for Haskell. In
plain terms, an effect system lets you write a function that *uses* a capability (say "sign a
token") without committing to *how* that capability is implemented; the implementation
("interpreter") is plugged in later. `effectful` represents a computation that uses effects as
the type `Eff es a`, where `es` is a type-level list of the effects in play and `a` is the
result. An **effect** is declared as a small GADT (generalized algebraic data type) whose
constructors name the operations; you invoke an operation with `send`, and you supply an
implementation with an interpreter built from `interpret_`. EP-2 owns the effect declarations;
this plan writes interpreters for two of them (`TokenSigner`, `TokenVerifier`) and *consumes*
a third (`SigningKeyStore`) plus a `Clock` effect.

### Exactly what `shomei-core` (EP-2) provides

The following types and effects are defined in `shomei-core` and imported by `shomei-jwt`.
They are reproduced here verbatim in shape so this plan is self-contained; do not redefine
them in `shomei-jwt`, import them.

The claims a token carries (`Shomei.Domain.AuthClaims`):

```haskell
data AuthClaims = AuthClaims
  { subject   :: !UserId       -- the authenticated user (a TypeID identifier)
  , sessionId :: !SessionId    -- the session this token belongs to (a TypeID identifier)
  , issuer    :: !Issuer       -- who minted the token (newtype over Text)
  , audience  :: !Audience     -- who the token is intended for (newtype over Text)
  , issuedAt  :: !UTCTime      -- when the token was minted
  , expiresAt :: !UTCTime      -- when the token stops being valid
  , scopes    :: !(Set Scope)  -- permission strings (Scope is a newtype over Text)
  , roles     :: !(Set Role)   -- role strings (Role is a newtype over Text)
  }
```

The token wire types and the error vocabulary (`Shomei.Domain.AccessToken`, `Shomei.Error`):

```haskell
newtype AccessToken = AccessToken Text   -- the compact JWS string on the wire

data TokenError
  = TokenMalformed          -- could not parse the compact token at all
  | TokenSignatureInvalid   -- signature did not verify (or no key matched the kid)
  | TokenExpired            -- the exp claim is in the past
  | TokenIssuerInvalid      -- iss did not match the configured issuer
  | TokenAudienceInvalid    -- aud did not contain the configured audience
  | TokenOtherError Text    -- any other failure, message preserved
```

The identifiers (`Shomei.Id`) are **TypeID** values — UUIDs with a human-readable type prefix
such as `user_…` and `session_…`. The functions you need are `idText :: KindID p -> Text`
(render to its prefixed string form) and `parseId :: Text -> Either Text (KindID p)` (parse it
back). A token's `sub` claim stores `idText subject`; verification parses it back with
`parseId`.

The storage-agnostic signing-key record and its status (`Shomei.Domain.SigningKey`):

```haskell
data StoredSigningKey = StoredSigningKey
  { keyId         :: !Text               -- the kid
  , algorithm     :: !Text               -- e.g. "ES256"
  , publicKeyJwk  :: !Text               -- the PUBLIC JWK as JSON text (no private "d")
  , privateKeyJwk :: !Text               -- the FULL JWK as JSON text (includes private "d")
  , status        :: !SigningKeyStatus
  , createdAt     :: !UTCTime
  , activatedAt   :: !(Maybe UTCTime)
  , retiredAt     :: !(Maybe UTCTime)
  }

data SigningKeyStatus = KeyPending | KeyActive | KeyRetired | KeyRevoked
```

Crucially, `shomei-core` **never imports jose**: the key material is opaque `Text` holding JWK
JSON. Converting that `Text` to and from a live `jose` `JWK` is this package's job.

The runtime configuration (`Shomei.Config`) — only the fields this plan uses:

```haskell
data ShomeiConfig = ShomeiConfig
  { issuer         :: !Issuer
  , audience       :: !Audience
  , accessTokenTTL :: !NominalDiffTime  -- how long a freshly minted token stays valid
  , signingKeyConfig :: !SigningKeyConfig
  -- ... other fields used by other plans ...
  }
```

The port effects (`Shomei.Port.*`), each a dynamic `effectful` effect. This plan **interprets**
`TokenSigner` and `TokenVerifier`, and **consumes** `SigningKeyStore` and `Clock`:

```haskell
data TokenSigner :: Effect where
  SignAccessToken :: AuthClaims -> TokenSigner m AccessToken

data TokenVerifier :: Effect where
  VerifyAccessToken :: AccessToken -> TokenVerifier m (Either TokenError AuthClaims)

data SigningKeyStore :: Effect where
  ListActiveSigningKeys  :: SigningKeyStore m [StoredSigningKey]
  FindSigningKeyByKid    :: Text -> SigningKeyStore m (Maybe StoredSigningKey)
  InsertSigningKey       :: StoredSigningKey -> SigningKeyStore m ()
  UpdateSigningKeyStatus :: Text -> SigningKeyStatus -> UTCTime -> SigningKeyStore m ()

data Clock :: Effect where
  Now :: Clock m UTCTime
```

EP-2 also provides `send`-based smart constructors for each operation (e.g.
`listActiveSigningKeys :: (SigningKeyStore :> es) => Eff es [StoredSigningKey]`); use those in
the rotation service rather than calling `send` directly where they exist.

### House conventions reproduced

These conventions are established by EP-1 and apply to every module written here. The compiler
is GHC 9.12.4 with the `GHC2024` language edition. The `.cabal` file uses `cabal-version: 3.0`
and two `common` stanzas — `warnings` (enabling `-Wall` and friends) and `shared` (the shared
`default-extensions`). The shared extensions are: `DeriveAnyClass`, `DuplicateRecordFields`,
`BlockArguments`, `MultilineStrings`, `OverloadedLabels`, `OverloadedRecordDot`,
`OverloadedStrings`, `PackageImports`, `QualifiedDo`, `TemplateHaskell`. Every module imports
the custom prelude `Shomei.Prelude` (re-exported from `shomei-core`) instead of importing base
modules directly. Imports are written **postpositive-qualified**, i.e.
`import Data.Aeson qualified as Aeson`. Record fields are **strict** (the `!` above). Any module
that uses an `#field` overloaded label must add `import Data.Generics.Labels ()` to bring the
label instances into scope. Deriving uses explicit strategies (`deriving stock`,
`deriving anyclass`, `deriving newtype`).


## Plan of Work

The work proceeds in three milestones. Milestone 1 is a deliberate **build spike** — a small
throwaway program whose only purpose is to prove that the chosen library compiles and runs on
this exact compiler before any real code is written, because there is a known version risk
(detailed below). Milestone 2 builds the key machinery (generation, conversion, JWKS).
Milestone 3 builds signing, verification, the effect interpreters, the rotation service, and
the full test suite.

### The jose / crypton-1.1 / GHC 9.12.4 risk (read first)

There are two stacked risks; the first is the dominant one.

**Risk 1 — jose must come from PR #137, not Hackage.** The corpus `crypton` is **1.1.2**, which
replaced its dependency on the `memory` package with **`ram`** (a drop-in fork — same
`Data.ByteArray` module, same `constEq`/`convert`). The released `jose` 0.12 on Hackage still
depends on `memory >= 0.7` and `crypton >= 0.31`; compiled against crypton 1.1.x it would import
a *different* `ByteArray` class than crypton exposes and fail to type-check. The fix is
`frasertweedale/hs-jose` **PR #137** ("Update to crypton >= 1.1.0 and ram instead of memory",
commit `4726d077a13b24cd1d78fb94b2db5a86c79e3f0f`, jose 0.13). You MUST pull jose from that
revision via a `cabal.project` `source-repository-package` (see the Decision Log entry for the
exact block) — do not rely on `cabal`'s Hackage resolver picking jose. Likewise, every Shōmei
package that uses `Data.ByteArray` (here, and `shomei-postgres` in EP-3) depends on **`ram`**,
not `memory`.

**Risk 2 — GHC 9.12.4 version bounds.** jose's tested GHC ceiling is 9.12.2 and it constrains
`base < 5`. GHC 9.12.4 ships `base` 4.21 (which is `< 5`), so it should compile; but if any
upper bound on `base`, `lens`, or a transitive dependency is tighter than 9.12.4 provides, cabal
refuses to build. The mitigation is the cabal `allow-newer` mechanism in the workspace-level
`cabal.project` (created by EP-1). For example:

```text
allow-newer: jose:base
```

If a different package's bound is the blocker, the error names it; relax that one instead (e.g.
`allow-newer: jose:base, some-dep:lens`). Record exactly what you had to relax in the Decision
Log and Surprises & Discoveries so the next contributor knows. **Both risks are why Milestone 1
exists and must be completed before writing real code.**

### Milestone 1 — Build spike (de-risk jose + crypton-1.1 on GHC 9.12.4)

Scope: get `packages/shomei-jwt` to compile against the PR-#137 `jose` (on the corpus
crypton 1.1.2 / `ram`) on GHC 9.12.4 and prove the library works at runtime with a minimal
generate-sign-verify cycle. At the end of this milestone, the package builds and either a
temporary `main` or a single temporary test prints success.

First add the jose `source-repository-package` block (Decision Log) to `cabal.project`. Then
write the `.cabal` file (full text in Concrete Steps) declaring the dependencies (`crypton >=
1.1.0`, `ram` — NOT `memory`, and `jose` with no Hackage version constraint since it resolves
from the source-repository). Add a throwaway module `packages/shomei-jwt/spike/Spike.hs` (or a
temporary test) that calls `genJWK (ECGenParam P_256)`, signs an empty claims set, and verifies
it, printing `spike: ok`. Run `cabal build shomei-jwt`. If it fails on a version bound, apply
`allow-newer` as above and retry. Run the spike and confirm it prints `spike: ok`. Record the
outcome (including whether the jose source-repository resolved cleanly). Then delete the spike
module (it is replaced by the real modules and tests in later milestones).

Acceptance: `cabal build shomei-jwt` succeeds, and running the spike prints `spike: ok`.

### Milestone 2 — Keys and the JWKS document

Scope: implement `Shomei.Jwt.Key` and `Shomei.Jwt.Jwks`. At the end, you can generate an
ES256 key, convert it to a `StoredSigningKey` and back without losing the `kid`, and render a
JWKS document that contains the public key and no private material. The two relevant tests
((a) key round trip and (g) JWKS shape) pass.

`Shomei.Jwt.Key` provides `generateSigningKey :: IO JWK` (generate a P-256 key, mark it for
signing use, and set its `kid` to its RFC 7638 thumbprint), `toStoredSigningKey :: UTCTime ->
JWK -> StoredSigningKey` (serialize the full key and its public-only projection to JSON text,
copy the kid and `"ES256"` algorithm tag, set status `KeyActive`), and `fromStoredSigningKey
:: StoredSigningKey -> Either Text JWK` (parse `privateKeyJwk` back to a `JWK`, returning a
human-readable error string on failure). `Shomei.Jwt.Jwks` provides `jwksDocument :: [JWK] ->
ByteString` (encode a `JWKSet` of the *public* projection of each key) and a small `KeySet`
record bundling the active key plus any retired-but-still-valid keys, with a helper to expose
its public `JWKSet`.

Acceptance: tests (a) and (g) (defined in Validation and Acceptance) pass.

### Milestone 3 — Signing, verification, interpreters, rotation, and tests

Scope: implement `Shomei.Jwt.Sign`, `Shomei.Jwt.Verify`, and `Shomei.Jwt.Rotation`, and the
complete `test-suite shomei-jwt-test`. At the end, signing produces a verifiable token, every
claim round-trips, tampering and expiry and wrong-audience/issuer are rejected with the correct
`TokenError`, the `effectful` interpreters work, and `cabal test shomei-jwt` is green.

`Shomei.Jwt.Sign` builds a jose `ClaimsSet` from an `AuthClaims` (mapping issuer→`iss`,
subject→`sub`, audience→`aud`, issuedAt→`iat`, expiresAt→`exp`, and adding custom claims `sid`,
`scopes`, `roles`), signs it with the active private `JWK` propagating that key's `kid` into the
JWS header, and returns `AccessToken`. It also provides the `effectful` interpreter
`runTokenSignerJwt`. `Shomei.Jwt.Verify` provides the plain `verifyToken` IO function (the EP-5
contract), the `effectful` interpreter `runTokenVerifierJwt`, and the jose-error-to-`TokenError`
mapping. `Shomei.Jwt.Rotation` implements `rotateSigningKey`, a service written against the
`SigningKeyStore` and `Clock` effects that generates a new active key and retires the prior one,
plus `currentJwks`, which builds the published JWKS from all non-revoked stored keys.

Acceptance: `cabal test shomei-jwt` prints `All 8 tests passed` (or the exact count of test
cases written), covering scenarios (a) through (h) below.


## Concrete Steps

All commands assume you are inside `nix develop` with the working directory at the repository
root `/Users/shinzui/Keikaku/bokuno/shomei` unless a different directory is stated.

### Step 1 — Write the package cabal file

Create `packages/shomei-jwt/shomei-jwt.cabal` with the following contents. The two `common`
stanzas mirror the house conventions; if EP-1 placed the shared stanzas in an importable form,
prefer importing them, but the self-contained version below is safe to use as written.

```cabal
cabal-version:      3.0
name:               shomei-jwt
version:            0.1.0.0
synopsis:           JWT access-token signing/verification and JWKS publishing for Shōmei
build-type:         Simple

common warnings
    ghc-options: -Wall -Wcompat -Widentities -Wincomplete-record-updates
                 -Wincomplete-uni-patterns -Wmissing-export-lists
                 -Wpartial-fields -Wredundant-constraints

common shared
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        BlockArguments
        MultilineStrings
        OverloadedLabels
        OverloadedRecordDot
        OverloadedStrings
        PackageImports
        QualifiedDo
        TemplateHaskell

library
    import:           warnings, shared
    hs-source-dirs:   src
    exposed-modules:
        Shomei.Jwt.Key
        Shomei.Jwt.Sign
        Shomei.Jwt.Verify
        Shomei.Jwt.Jwks
        Shomei.Jwt.Rotation
    build-depends:
        base
      , shomei-core
      , jose                 -- resolves from the PR-#137 source-repository-package (jose 0.13)
      , lens
      , aeson
      , bytestring
      , text
      , time
      , mtl
      , crypton              >= 1.1.0   -- corpus crypton is 1.1.2 (uses ram, not memory)
      , ram                             -- drop-in fork of memory; provides Data.ByteArray*
      , base64-bytestring
      , containers
      , effectful
      , effectful-core
      , monad-time

test-suite shomei-jwt-test
    import:           warnings, shared
    type:             exitcode-stdio-1.0
    hs-source-dirs:   test
    main-is:          Main.hs
    other-modules:
        Shomei.Jwt.KeySpec
        Shomei.Jwt.SignVerifySpec
        Shomei.Jwt.JwksSpec
        Shomei.Jwt.InterpreterSpec
    build-depends:
        base
      , shomei-core
      , shomei-jwt
      , jose
      , lens
      , aeson
      , bytestring
      , text
      , time
      , containers
      , effectful
      , tasty
      , tasty-hunit
```

### Step 2 — Build spike

Create the throwaway spike at `packages/shomei-jwt/spike/Spike.hs` and (temporarily) add a
matching `executable shomei-jwt-spike` stanza, or place the spike body directly in a temporary
test `main`. The spike body:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import "lens" Control.Lens ((?~), (&))
import "mtl" Control.Monad.Except (runExceptT)
import "jose" Crypto.JOSE.JWK (genJWK, KeyMaterialGenParam (ECGenParam), jwkUse, KeyUse (Sig))
import "jose" Crypto.JOSE.JWA.JWK (Crv (P_256))
import "jose" Crypto.JOSE.JWS (newJWSHeader, Alg (ES256))
import "jose" Crypto.JOSE.Header (Protection (Protected))
import "jose" Crypto.JOSE.Compact (encodeCompact, decodeCompact)
import "jose" Crypto.JWT
  ( emptyClaimsSet, signClaims, defaultJWTValidationSettings, verifyClaims
  , JWTError, SignedJWT, ClaimsSet )
import Control.Monad.Time ()  -- MonadTime IO instance for verification

main :: IO ()
main = do
  jwk <- (\k -> k & jwkUse ?~ Sig) <$> genJWK (ECGenParam P_256)
  signed <- runExceptT @JWTError $ do
    let hdr = newJWSHeader (Protected, ES256)
    signClaims jwk hdr emptyClaimsSet
  case signed of
    Left e  -> putStrLn ("spike: sign failed: " <> show e)
    Right s -> do
      let wire = encodeCompact (s :: SignedJWT)
      verified <- runExceptT @JWTError $ do
        s' <- decodeCompact wire
        verifyClaims (defaultJWTValidationSettings (const True)) jwk (s' :: SignedJWT)
      case (verified :: Either JWTError ClaimsSet) of
        Left e  -> putStrLn ("spike: verify failed: " <> show e)
        Right _ -> putStrLn "spike: ok"
```

Run it:

```bash
cabal build shomei-jwt
cabal run shomei-jwt-spike
```

Expected final line:

```text
spike: ok
```

If `cabal build` fails citing a version bound, edit `cabal.project` at the repository root and
add `allow-newer: jose:base` (or whichever package the error names), then re-run. After
`spike: ok`, delete `packages/shomei-jwt/spike/Spike.hs` and remove the temporary executable
stanza; record the result in the living-document sections.

### Step 3 — Implement `Shomei.Jwt.Key`

Create `packages/shomei-jwt/src/Shomei/Jwt/Key.hs`. This module generates keys, computes the
`kid` from the RFC 7638 thumbprint, and converts to/from `StoredSigningKey`.

```haskell
module Shomei.Jwt.Key
  ( generateSigningKey
  , toStoredSigningKey
  , fromStoredSigningKey
  , keyKid
  ) where

import Shomei.Prelude
import Shomei.Domain.SigningKey (StoredSigningKey (..), SigningKeyStatus (KeyActive))

import "lens" Control.Lens ((^.), (^?), (?~), (&), view)
import "jose" Crypto.JOSE.JWK
  ( JWK, genJWK, KeyMaterialGenParam (ECGenParam), jwkUse, KeyUse (Sig)
  , jwkKid, asPublicKey, thumbprint )
import "jose" Crypto.JOSE.JWA.JWK (Crv (P_256))
import "ram" Data.ByteArray.Encoding (convertToBase, Base (Base64URLUnpadded))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text

-- | Generate a fresh ES256 (P-256) signing key, marked for signature use,
-- with its kid set to its RFC 7638 thumbprint (Base64URL, unpadded).
generateSigningKey :: IO JWK
generateSigningKey = do
  k0 <- genJWK (ECGenParam P_256)
  let tp  = view thumbprint k0 :: Digest SHA256
      kid = Text.decodeUtf8 (convertToBase Base64URLUnpadded tp)
  pure (k0 & jwkUse ?~ Sig & jwkKid ?~ kid)

-- | The kid stored on a key (empty if absent — generateSigningKey always sets it).
keyKid :: JWK -> Text
keyKid k = maybe "" id (k ^. jwkKid)

-- | Convert a live JWK to the storage-agnostic record. Serializes the full key
-- (with private "d") to privateKeyJwk and the public-only projection to publicKeyJwk.
toStoredSigningKey :: UTCTime -> JWK -> StoredSigningKey
toStoredSigningKey now k =
  let pub = maybe k id (k ^? asPublicKey . _Just)  -- public projection; falls back to k
      enc = Text.decodeUtf8 . BSL.toStrict . Aeson.encode
   in StoredSigningKey
        { keyId         = keyKid k
        , algorithm     = "ES256"
        , publicKeyJwk  = enc pub
        , privateKeyJwk = enc k
        , status        = KeyActive
        , createdAt     = now
        , activatedAt   = Just now
        , retiredAt     = Nothing
        }

-- | Parse a stored key's full (private) JWK JSON back into a live JWK.
fromStoredSigningKey :: StoredSigningKey -> Either Text JWK
fromStoredSigningKey sk =
  case Aeson.eitherDecodeStrict (Text.encodeUtf8 sk.privateKeyJwk) of
    Left err -> Left (Text.pack err)
    Right k  -> Right k
```

Note on `thumbprint` and `Digest SHA256`/`_Just`: import `Crypto.Hash` (`Digest`, `SHA256`) and
the `Control.Lens` `_Just` prism as needed; the exact getter is jose's `thumbprint :: (...)
=> Getter JWK (Digest SHA256)`. If `view thumbprint` requires a type annotation to pick
`SHA256`, the annotation above provides it.

### Step 4 — Implement `Shomei.Jwt.Jwks`

Create `packages/shomei-jwt/src/Shomei/Jwt/Jwks.hs`.

```haskell
module Shomei.Jwt.Jwks
  ( jwksDocument
  , KeySet (..)
  , keySetPublicJwks
  ) where

import Shomei.Prelude

import "lens" Control.Lens ((^?), _Just)
import "jose" Crypto.JOSE.JWK (JWK, JWKSet (JWKSet), asPublicKey)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (mapMaybe)

-- | A live set of signing keys: the current active key plus any retired-but-valid keys.
data KeySet = KeySet
  { activeKey   :: !JWK
  , previousKeys :: ![JWK]
  }

-- | All keys in a KeySet (active first), as live JWKs.
keySetAll :: KeySet -> [JWK]
keySetAll ks = ks.activeKey : ks.previousKeys

-- | The public JWKSet a verifier should use (private material stripped).
keySetPublicJwks :: KeySet -> JWKSet
keySetPublicJwks ks = JWKSet (mapMaybe publicOf (keySetAll ks))
  where publicOf k = k ^? asPublicKey . _Just

-- | Encode a list of keys as a published JWKS document (public material only).
jwksDocument :: [JWK] -> BSL.ByteString
jwksDocument keys = Aeson.encode (JWKSet (mapMaybe publicOf keys))
  where publicOf k = k ^? asPublicKey . _Just
```

### Step 5 — Implement `Shomei.Jwt.Sign`

Create `packages/shomei-jwt/src/Shomei/Jwt/Sign.hs`. It builds the `ClaimsSet`, signs, and
provides the `TokenSigner` interpreter.

```haskell
module Shomei.Jwt.Sign
  ( claimsFromAuth
  , signAccessToken
  , runTokenSignerJwt
  ) where

import Shomei.Prelude
import Shomei.Domain.AuthClaims (AuthClaims (..))
import Shomei.Domain.AccessToken (AccessToken (AccessToken))
import Shomei.Config (ShomeiConfig)
import Shomei.Id (idText)
import Shomei.Port.TokenSigner (TokenSigner (SignAccessToken))

import "lens" Control.Lens ((?~), (&), (^.), set)
import "mtl" Control.Monad.Except (runExceptT)
import "jose" Crypto.JOSE.JWK (JWK, jwkKid)
import "jose" Crypto.JOSE.JWS (newJWSHeader, Alg (ES256))
import "jose" Crypto.JOSE.Header (Protection (Protected), kid, HeaderParam (HeaderParam))
import "jose" Crypto.JOSE.Compact (encodeCompact)
import "jose" Crypto.JWT
  ( ClaimsSet, emptyClaimsSet, claimIss, claimSub, claimAud, claimIat, claimExp
  , Audience (Audience), NumericDate (NumericDate), addClaim, signClaims, JWTError )
import Data.Aeson qualified as Aeson
import Data.Set qualified as Set
import Data.Text.Encoding qualified as Text
import Data.ByteString.Lazy qualified as BSL

-- | Build a jose ClaimsSet from Shōmei's AuthClaims. Standard claims map directly;
-- session id, scopes, and roles travel as custom claims "sid", "scopes", "roles".
claimsFromAuth :: AuthClaims -> ClaimsSet
claimsFromAuth ac =
  emptyClaimsSet
    & claimIss ?~ fromString (toString ac.issuer)
    & claimSub ?~ fromString (toString (idText ac.subject))
    & claimAud ?~ Audience [fromString (toString ac.audience)]
    & claimIat ?~ NumericDate ac.issuedAt
    & claimExp ?~ NumericDate ac.expiresAt
    & addClaim "sid"    (Aeson.String (idText ac.sessionId))
    & addClaim "scopes" (Aeson.toJSON (Set.toList ac.scopes))
    & addClaim "roles"  (Aeson.toJSON (Set.toList ac.roles))

-- | Sign an AuthClaims into an AccessToken using the given (active, private) key.
-- The key's kid is propagated into the protected JWS header so verifiers can select it.
signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)
signAccessToken jwk ac = do
  let hdr0 = newJWSHeader (Protected, ES256)
      hdr  = case jwk ^. jwkKid of
               Just k  -> hdr0 & kid ?~ HeaderParam Protected k
               Nothing -> hdr0
  result <- runExceptT @JWTError (signClaims jwk hdr (claimsFromAuth ac))
  pure $ case result of
    Left e  -> Left e
    Right s -> Right (AccessToken (Text.decodeUtf8 (BSL.toStrict (encodeCompact s))))

-- | Interpret the TokenSigner effect by signing with a fixed active private key.
runTokenSignerJwt
  :: (IOE :> es)
  => JWK -> ShomeiConfig -> Eff (TokenSigner : es) a -> Eff es a
runTokenSignerJwt jwk _cfg = interpret_ \case
  SignAccessToken ac -> do
    r <- liftIO (signAccessToken jwk ac)
    case r of
      Right tok -> pure tok
      Left e    -> liftIO (throwIO (userError ("token signing failed: " <> show e)))
```

The helpers `toString`/`fromString` above convert the `Issuer`/`Audience`/`Scope`/`Role`
newtypes (over `Text`) to and from `String`/`StringOrURI`; if `Shomei.Prelude` does not export
a `toString` for these newtypes, unwrap them explicitly (e.g. with the newtype accessor) and
use `Data.Text` conversions. The `IOE`, `Eff`, `interpret_`, `liftIO`, and `throwIO` names come
from `effectful`. The `(:)` in `Eff (TokenSigner : es) a` is the effect-list cons that adds
`TokenSigner` to the front of the remaining effects `es`.

### Step 6 — Implement `Shomei.Jwt.Verify`

Create `packages/shomei-jwt/src/Shomei/Jwt/Verify.hs`. It exposes the plain `verifyToken` IO
function (the EP-5 contract), the `effectful` interpreter, and the error mapping.

```haskell
module Shomei.Jwt.Verify
  ( verifyToken
  , runTokenVerifierJwt
  , jwtErrorToTokenError
  ) where

import Shomei.Prelude
import Shomei.Domain.AuthClaims (AuthClaims (..))
import Shomei.Domain.AccessToken (AccessToken (AccessToken))
import Shomei.Config (ShomeiConfig)
import Shomei.Error (TokenError (..))
import Shomei.Id (parseId)
import Shomei.Port.TokenVerifier (TokenVerifier (VerifyAccessToken))

import "lens" Control.Lens ((^.), (.~), (&), view)
import "mtl" Control.Monad.Except (runExceptT)
import "jose" Crypto.JOSE.JWK (JWKSet)
import "jose" Crypto.JOSE.Compact (decodeCompact)
import "jose" Crypto.JWT
  ( ClaimsSet, claimIss, claimSub, claimAud, claimIat, claimExp
  , defaultJWTValidationSettings, verifyClaims, issuerPredicate, allowedSkew
  , unregisteredClaims, NumericDate (NumericDate), JWTError (..), SignedJWT )
import Control.Monad.Time ()  -- MonadTime IO instance
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.ByteString.Lazy qualified as BSL

-- | THE EP-4 ↔ EP-5 CONTRACT.
-- Verify a compact JWT string against a public JWKSet, applying issuer and audience
-- checks from the config. The JWKSet selects the right key by the token's kid header.
verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
verifyToken jwks cfg raw = do
  let settings =
        defaultJWTValidationSettings (== fromString (toString cfg.audience))
          & issuerPredicate .~ (\iss -> iss == fromString (toString cfg.issuer))
          & allowedSkew .~ 0
      bytes = BSL.fromStrict (Text.encodeUtf8 raw)
  result <- runExceptT @JWTError $ do
    signed <- decodeCompact bytes
    verifyClaims settings jwks (signed :: SignedJWT)
  pure $ case result of
    Left e   -> Left (jwtErrorToTokenError e)
    Right cs -> claimsToAuth cs

-- | Interpret the TokenVerifier effect over a fixed public JWKSet.
runTokenVerifierJwt
  :: (IOE :> es)
  => JWKSet -> ShomeiConfig -> Eff (TokenVerifier : es) a -> Eff es a
runTokenVerifierJwt jwks cfg = interpret_ \case
  VerifyAccessToken (AccessToken raw) -> liftIO (verifyToken jwks cfg raw)

-- | Map jose's JWTError into the core's transport-agnostic TokenError.
jwtErrorToTokenError :: JWTError -> TokenError
jwtErrorToTokenError = \case
  JWTExpired              -> TokenExpired
  JWTNotYetValid          -> TokenOtherError "token not yet valid"
  JWTNotInIssuer          -> TokenIssuerInvalid
  JWTNotInAudience        -> TokenAudienceInvalid
  JWTIssuedAtFuture       -> TokenOtherError "iat in the future"
  JWSError _              -> TokenSignatureInvalid   -- includes no-key-matched-kid
  JWSInvalidSignature     -> TokenSignatureInvalid
  CompactDecodeError _    -> TokenMalformed
  other                   -> TokenOtherError (Text.pack (show other))

-- | Decode a verified jose ClaimsSet back into Shōmei's AuthClaims.
claimsToAuth :: ClaimsSet -> Either TokenError AuthClaims
claimsToAuth cs = do
  subTxt  <- note "missing sub" (claimText (cs ^. claimSub))
  subj    <- mapLeft (const TokenMalformed) (parseId subTxt)
  sidTxt  <- note "missing sid" (lookupString "sid")
  sess    <- mapLeft (const TokenMalformed) (parseId sidTxt)
  iss     <- note "missing iss" (claimText (cs ^. claimIss))
  aud     <- note "missing aud" (firstAudience (cs ^. claimAud))
  iat     <- note "missing iat" (dateOf (cs ^. claimIat))
  exp_    <- note "missing exp" (dateOf (cs ^. claimExp))
  let scs = Set.fromList (map fromString (lookupStringList "scopes"))
      rls = Set.fromList (map fromString (lookupStringList "roles"))
  pure AuthClaims
    { subject = subj, sessionId = sess
    , issuer = fromString (toString iss), audience = fromString (toString aud)
    , issuedAt = iat, expiresAt = exp_, scopes = scs, roles = rls }
  where
    note msg = maybe (Left (TokenOtherError msg)) Right
    mapLeft f = either (Left . f) Right
    claimText = fmap (Text.pack . show)              -- StringOrURI -> Text
    dateOf    = fmap (\(NumericDate t) -> t)
    firstAudience _ = Just (error "extract first Audience entry as Text")
    lookupString k =
      case Map.lookup k (cs ^. unregisteredClaims) of
        Just (Aeson.String s) -> Just s
        _                     -> Nothing
    lookupStringList k =
      case Map.lookup k (cs ^. unregisteredClaims) of
        Just v  -> either (const []) id (Aeson.parseEither Aeson.parseJSON v)
        Nothing -> []
```

The helpers marked with `error`/comments above (`claimText`, `firstAudience`) are placeholders
for the exact `StringOrURI` and `Audience` accessors jose exposes; when implementing, convert
`StringOrURI` to `Text` via its `Show`/`getString` accessor and pull the first entry out of
`Audience [..]`. The data-constructor list for `JWTError` in the case expression must match the
constructors jose actually exports on the installed version — adjust names the compiler reports
as unknown, keeping the same mapping intent recorded in the Decision Log. `Data.Aeson`'s
`parseEither`/`parseJSON` come from `Data.Aeson.Types`.

### Step 7 — Implement `Shomei.Jwt.Rotation`

Create `packages/shomei-jwt/src/Shomei/Jwt/Rotation.hs`. It is written against the
`SigningKeyStore` and `Clock` effects only — no IO key storage of its own.

```haskell
module Shomei.Jwt.Rotation
  ( rotateSigningKey
  , currentJwks
  ) where

import Shomei.Prelude
import Shomei.Domain.SigningKey
  (StoredSigningKey (..), SigningKeyStatus (KeyActive, KeyRetired, KeyRevoked))
import Shomei.Port.SigningKeyStore
  (SigningKeyStore, listActiveSigningKeys, insertSigningKey, updateSigningKeyStatus)
import Shomei.Port.Clock (Clock, now)
import Shomei.Jwt.Key (generateSigningKey, toStoredSigningKey, fromStoredSigningKey)
import Shomei.Jwt.Jwks (jwksDocument)

import "jose" Crypto.JOSE.JWK (JWK)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (rights)

-- | Generate a new active key and retire whatever was active. Returns the new live JWK.
rotateSigningKey
  :: (IOE :> es, SigningKeyStore :> es, Clock :> es)
  => Eff es JWK
rotateSigningKey = do
  t        <- now
  priorAct <- listActiveSigningKeys
  newJwk   <- liftIO generateSigningKey
  let stored = toStoredSigningKey t newJwk
  insertSigningKey stored
  for_ priorAct \k ->
    updateSigningKeyStatus k.keyId KeyRetired t
  pure newJwk

-- | Build the published JWKS from all stored keys that are not revoked.
currentJwks
  :: (SigningKeyStore :> es)
  => Eff es BSL.ByteString
currentJwks = do
  -- listActiveSigningKeys returns active+retired (non-revoked) per the store contract.
  keys <- listActiveSigningKeys
  let live = rights (map fromStoredSigningKey (filter notRevoked keys))
  pure (jwksDocument live)
  where notRevoked k = k.status /= KeyRevoked
```

If the `SigningKeyStore` contract's `listActiveSigningKeys` returns *only* `KeyActive` keys (not
retired ones), add a `ListNonRevokedSigningKeys` query in EP-2 or fetch retired keys via
repeated `FindSigningKeyByKid`; record whichever path you take in the Decision Log. For the
bootstrap, the simplest correct behavior is: the JWKS includes every non-revoked stored key.

### Step 8 — Write the tests

Create `packages/shomei-jwt/test/Main.hs` plus the spec modules. `Main.hs` wires the tasty
tree:

```haskell
module Main (main) where

import "tasty" Test.Tasty (defaultMain, testGroup)
import Shomei.Jwt.KeySpec qualified as KeySpec
import Shomei.Jwt.SignVerifySpec qualified as SignVerifySpec
import Shomei.Jwt.JwksSpec qualified as JwksSpec
import Shomei.Jwt.InterpreterSpec qualified as InterpreterSpec

main :: IO ()
main = defaultMain $ testGroup "shomei-jwt"
  [ KeySpec.tests
  , SignVerifySpec.tests
  , JwksSpec.tests
  , InterpreterSpec.tests
  ]
```

`Shomei.Jwt.KeySpec` covers scenario (a) — key round trip with stable kid:

```haskell
module Shomei.Jwt.KeySpec (tests) where

import "tasty" Test.Tasty (TestTree, testGroup)
import "tasty-hunit" Test.Tasty.HUnit (testCase, (@?=), assertBool)
import Data.Time (getCurrentTime)
import Shomei.Jwt.Key (generateSigningKey, toStoredSigningKey, fromStoredSigningKey, keyKid)
import Shomei.Domain.SigningKey (StoredSigningKey (..))

tests :: TestTree
tests = testGroup "Key"
  [ testCase "round-trips a key with stable kid" $ do
      jwk <- generateSigningKey
      now <- getCurrentTime
      let stored = toStoredSigningKey now jwk
      assertBool "kid is non-empty" (not (null (keyId stored)))
      case fromStoredSigningKey stored of
        Left err  -> fail ("decode failed: " <> show err)
        Right jwk' -> keyKid jwk' @?= keyId stored
  ]
```

`Shomei.Jwt.SignVerifySpec` covers scenarios (b)–(f): a full round trip and each rejection.
Construct a `ShomeiConfig` with a known issuer/audience and a short TTL, build an `AuthClaims`,
sign with the private `JWK`, wrap the public key(s) in a `JWKSet`, and assert. For tampering,
flip one character in the token's payload segment and assert `Left TokenSignatureInvalid`. For
expiry, set `expiresAt` to one hour in the past and `allowedSkew` 0 and assert `Left
TokenExpired`. For wrong audience/issuer, verify against a config with a different
audience/issuer and assert `TokenAudienceInvalid`/`TokenIssuerInvalid`.

`Shomei.Jwt.JwksSpec` covers scenario (g): generate keys A and B, build the JWKS with
`jwksDocument [a, b]`, decode it as JSON, assert it has two entries with the right `kid`s and
that **no** entry contains a `"d"` field, then sign a token with A and verify it against the
two-key `JWKSet`, proving kid-based selection.

`Shomei.Jwt.InterpreterSpec` covers scenario (h): run `runTokenSignerJwt` to mint a token and
`runTokenVerifierJwt` to verify it, both inside an `Eff` computation discharged with
`runEff`/`runIOE`, and assert the claims round-trip.

### Step 9 — Build and test

```bash
cabal build shomei-jwt
cabal test shomei-jwt
```


## Validation and Acceptance

Validation is behavioral: a generated key signs a token that a separate public key set
verifies, with every claim intact, and with every tamper/expiry/mismatch rejected by the
correct error. The eight test scenarios, each phrased as input → observable output, are:

(a) **Key round trip.** Generate an ES256 key; convert to `StoredSigningKey`; parse back with
`fromStoredSigningKey`. Expected: the parsed key's `keyKid` equals the stored `keyId`, and that
`keyId` is non-empty. This proves kid stability across storage.

(b) **Sign/verify round trip.** Build an `AuthClaims` with a known subject, session, two
scopes, one role, the config's issuer/audience, and a future expiry; sign; verify against a
`JWKSet` containing the public key. Expected: `Right AuthClaims` whose subject, sessionId,
scopes, roles, issuer, and audience equal the originals.

(c) **Tampered token.** Take a valid token, alter one character in its payload segment, verify.
Expected: `Left TokenSignatureInvalid`.

(d) **Expired token.** Sign claims whose `expiresAt` is in the past, with `allowedSkew` 0;
verify. Expected: `Left TokenExpired`.

(e) **Wrong audience.** Verify a valid token against a config whose audience differs from the
token's `aud`. Expected: `Left TokenAudienceInvalid`.

(f) **Wrong issuer.** Verify a valid token against a config whose issuer differs from the
token's `iss`. Expected: `Left TokenIssuerInvalid`.

(g) **JWKS document.** For a set of two keys A and B, `jwksDocument [a, b]` is valid JSON with a
top-level `"keys"` array of two objects carrying the correct `kid`s and **no** `"d"` field in
any object; and a token signed by A verifies against a `JWKSet` containing both A and B,
proving the verifier selects by `kid`.

(h) **Effect interpreters.** Inside an `Eff` computation, `runTokenSignerJwt` mints a token and
`runTokenVerifierJwt` verifies it; the recovered claims equal the originals.

Run the suite:

```bash
cabal test shomei-jwt
```

Expected output (the count matches the number of `testCase`s you write; eight scenarios may map
to eight or more cases):

```text
shomei-jwt> test (suite: shomei-jwt-test)

shomei-jwt
  Key
    round-trips a key with stable kid:           OK
  SignVerify
    round-trips all claims:                      OK
    rejects a tampered token:                    OK
    rejects an expired token:                    OK
    rejects a wrong audience:                    OK
    rejects a wrong issuer:                      OK
  Jwks
    publishes public-only JWKS with right kids:  OK
    selects the signing key by kid:              OK
  Interpreter
    sign-then-verify in Eff round-trips:         OK

All 9 tests passed (0.12s)
```

### The JWKS document shape (reference)

A published JWKS for one ES256 key looks like this (the exact `kid`/`x`/`y` values vary per
key; note there is **no** `"d"` field — that would be the private key):

```json
{
  "keys": [
    {
      "kty": "EC",
      "crv": "P-256",
      "use": "sig",
      "alg": "ES256",
      "kid": "3FZ9c2u8b9rT-example-thumbprint",
      "x": "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
      "y": "x_FEzRu9m36HLN_tue659LNpUm6xUE_5wQ_PRAEFvE0"
    }
  ]
}
```

This is exactly what EP-6 serves at `GET /.well-known/jwks.json` and what a downstream service
fetches and caches to verify Shōmei's tokens locally.


## Idempotence and Recovery

Every step here is safe to repeat. `cabal build` and `cabal test` are idempotent. Re-running
`generateSigningKey` simply produces a different fresh key each time — keys are never
overwritten, and because the `kid` is the key's thumbprint, two independently generated keys
cannot collide on a `kid` unless they are byte-identical (vanishingly unlikely). The build
spike (Milestone 1) is explicitly throwaway: if you have already deleted it, do not recreate
it once the real modules build; if the real build fails later for an unrelated reason, you do
not need the spike to diagnose it.

The one risky area is the `allow-newer` relaxation in `cabal.project`. If you add a relaxation
and the build still fails, the error names the next offending bound; relax that one too rather
than reverting. If a relaxation later causes a runtime problem (it should not, since `base`
4.21 is genuinely `< 5`), the safe fallback is to pin `jose` to a known-good revision via a
`source-repository-package` entry or an `index-state` in `cabal.project`; record that in the
Decision Log if it becomes necessary. No step in this plan touches a database, deletes data,
or performs any destructive operation — signing keys exist only in memory and in the test
process here, with persistence deferred entirely to EP-6.

If a test fails, re-run just that suite with `cabal test shomei-jwt --test-show-details=direct`
to see per-case output, fix the offending module, and re-run. Tests are pure and
self-contained (they generate their own keys), so they can be run any number of times.


## Interfaces and Dependencies

This package depends on `shomei-core` (for `AuthClaims`, `AccessToken`, `TokenError`,
`StoredSigningKey`, `SigningKeyStatus`, `ShomeiConfig`, the `Shomei.Id` helpers, and the
`TokenSigner`/`TokenVerifier`/`SigningKeyStore`/`Clock` port effects) and on the cryptography
stack: `jose` (JWS/JWK/JWKS), `lens` (jose's API is lens-based), `aeson` (JWK/claim JSON),
`crypton` (>=1.1.0)/`ram`/`base64-bytestring` (hashing and Base64URL for thumbprints; `ram`
is the maintained drop-in for the deprecated `memory` package), `mtl` (the
`ExceptT` jose runs in), `time`, `text`, `bytestring`, `containers` (the `Set`/`Map` for
scopes/roles/custom claims), `effectful`/`effectful-core` (the interpreters), and `monad-time`
(the `MonadTime IO` instance jose's `verifyClaims` requires). It depends on `tasty` and
`tasty-hunit` for tests. It must **not** depend on `shomei-postgres`: signing keys arrive
through the `SigningKeyStore` port effect, whose PostgreSQL interpreter is supplied separately
by `shomei-postgres` and assembled by EP-6.

The interfaces that must exist at the end of each milestone, by full module path, are:

After Milestone 2 — `Shomei.Jwt.Key` and `Shomei.Jwt.Jwks` export:

```haskell
generateSigningKey  :: IO JWK
toStoredSigningKey  :: UTCTime -> JWK -> StoredSigningKey
fromStoredSigningKey :: StoredSigningKey -> Either Text JWK
keyKid              :: JWK -> Text

jwksDocument        :: [JWK] -> Data.ByteString.Lazy.ByteString
data KeySet = KeySet { activeKey :: JWK, previousKeys :: [JWK] }
keySetPublicJwks    :: KeySet -> JWKSet
```

After Milestone 3 — `Shomei.Jwt.Sign`, `Shomei.Jwt.Verify`, and `Shomei.Jwt.Rotation` export:

```haskell
-- Shomei.Jwt.Sign
signAccessToken   :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)
runTokenSignerJwt :: (IOE :> es) => JWK -> ShomeiConfig
                  -> Eff (TokenSigner : es) a -> Eff es a

-- Shomei.Jwt.Verify  -- the EP-4 ↔ EP-5 CONTRACT is verifyToken
verifyToken         :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
runTokenVerifierJwt :: (IOE :> es) => JWKSet -> ShomeiConfig
                    -> Eff (TokenVerifier : es) a -> Eff es a
jwtErrorToTokenError :: JWTError -> TokenError

-- Shomei.Jwt.Rotation
rotateSigningKey :: (IOE :> es, SigningKeyStore :> es, Clock :> es) => Eff es JWK
currentJwks      :: (SigningKeyStore :> es) => Eff es Data.ByteString.Lazy.ByteString
```

The single most important downstream contract is `verifyToken :: JWKSet -> ShomeiConfig ->
Text -> IO (Either TokenError AuthClaims)`. EP-5's Servant `Authenticated` combinator calls
exactly this shape from inside its `AuthHandler` (which is not an `effectful` computation), so
its type must not change without a cascading Decision Log entry in both this plan and EP-5.
