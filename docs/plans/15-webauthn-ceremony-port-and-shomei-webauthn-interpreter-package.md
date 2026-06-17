---
id: 15
slug: webauthn-ceremony-port-and-shomei-webauthn-interpreter-package
title: "WebAuthn ceremony port and shomei-webauthn interpreter package"
kind: exec-plan
created_at: 2026-06-17T14:38:15Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
master_plan: "docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md"
---

# WebAuthn ceremony port and shomei-webauthn interpreter package

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. Today it logs a user in with one factor — an
email and password. The parent initiative (`docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md`)
adds **passkeys** (WebAuthn public-key credentials, the cryptographic credentials a YubiKey,
Touch ID, Windows Hello, or iCloud Keychain creates) as a second factor and as a
passwordless path. That whole initiative rests on one thing existing first: a way for
Shōmei's core to **start** a WebAuthn ceremony (produce the JSON options the browser feeds
to `navigator.credentials.create()`/`.get()`) and **finish** it (verify the signed response
the browser returns), without the core ever importing the heavyweight `webauthn` library.

This ExecPlan (EP-1, the foundation) delivers exactly that and nothing else downstream:

1. A new domain vocabulary in `shomei-core` for passkeys (`Shomei.Domain.Passkey`) and a
   new set of typed identifiers (`PasskeyId`, `CeremonyId`), plus a pending-ceremony domain
   record. These are pure data with no infrastructure dependency. Later plans persist them.
2. A new **port** (an `effectful` "dynamic effect" — an interface whose operations are run
   by an interpreter chosen at assembly time) called `WebAuthnCeremony`. Its operations
   cross the package boundary using only aeson `Value` (browser-facing JSON, already a core
   dependency) and the new Shōmei domain types, so `shomei-core` never names a `webauthn`
   type. Think of a port as a Java interface and an interpreter as a class implementing it.
3. A new infrastructure package, `shomei-webauthn`, that *interprets* that port against the
   real `tweag/webauthn` library — encoding the options, decoding the browser's credential,
   and calling the library's `verifyRegistrationResponse`/`verifyAuthenticationResponse`.
4. A new `webauthnConfig` sub-record on `ShomeiConfig` carrying the Relying Party identity
   (the `rpId` domain, allowed origins, the RP display name) and ceremony policy.
5. The wiring that threads the new port through every effect-stack list in the codebase.

How you see it working: after this plan, running `nix develop --command cabal test all`
exercises a new `shomei-webauthn` test that runs a **complete simulated passkey ceremony** —
it asks the interpreter to begin a registration, has a software authenticator (built inside
the test) sign the challenge, asks the interpreter to verify it, then begins and verifies an
authentication against the registered credential — and asserts the verification succeeded and
the persisted options blob round-tripped. A second, pure core test drives a deterministic
fake interpreter so later plans can test workflows without real cryptography.

A note on terminology used throughout, defined once:

- **Relying Party (RP).** The website/server that owns the accounts — here, the Shōmei
  service. The "RP ID" is the registrable domain the passkey is scoped to (e.g.
  `auth.example.com`); the "origin" is the full web origin the browser reports (e.g.
  `https://auth.example.com`).
- **Ceremony.** One full WebAuthn exchange: *registration* (create a new passkey) or
  *authentication* (prove possession of an existing passkey). Each has a *begin* step
  (server emits options containing a random *challenge*) and a *complete* step (server
  verifies the browser's signed response).
- **Challenge.** Random bytes the server puts in the options and the authenticator signs
  over. The challenge is what makes a ceremony safe against replay; it lives *inside* the
  serialized options, not in any id we hand the browser.
- **`effectful` port / effect / interpreter.** `effectful` is the effect-system library
  Shōmei already uses. A *dynamic effect* is a GADT (`data X :: Effect where …`) whose
  constructors name operations; *smart constructors* call `send` to invoke them; an
  *interpreter* (`run…`) pattern-matches the constructors and supplies behavior. The list of
  effects a computation may use is its *effect stack*.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 0 — build/verification spike (de-risk the heavy dependency): **COMPLETE (2026-06-17).**

- [x] Add the `webauthn` source-repository-package / `allow-newer` block to `cabal.project`
      (its own block; do not edit other plans' blocks). — pinned `shinzui/webauthn-project`
      @ `a8b5636`, subdir `webauthn`, `allow-newer: webauthn:*`, `tests: False`.
- [x] Confirm `nix develop --command cabal build webauthn` succeeds on GHC 9.12.4 — succeeds
      after four fork patches (memory→ram, jose 0.13 RequiredProtection, SignedJWT annotation,
      validation toEither); see Decision Log.
- [x] Drive begin-registration → simulated authenticator → verify-registration →
      begin-authentication → simulated authenticator → verify-authentication. — Done by reusing
      the fork's own pure software-authenticator emulation test (`Emulation > None > succeeds`),
      which passes 100/100 on this build (real ECDSA verify). A bespoke throwaway harness was
      unnecessary given the library ships a complete emulator.
- [x] Validate the chosen `optionsBlob` serialization round-trips — confirmed via the fork's
      `Encoding > … can be roundtripped` WJ JSON props (options + credentials), 100 cases each,
      0 failures. This is exactly the `encode`/`decode` Internal.WebAuthnJson path the M2
      interpreter uses for the persisted options blob.
- [x] Record the spike outcome (allow-newer set, serialization choice proven) in the Decision
      Log and Surprises sections.

Milestone 1 — core domain, port, config, fake interpreter, wiring: **COMPLETE (2026-06-17).**

- [x] Add `PasskeyId`, `CeremonyId` (+ `gen…` + uuid conversions) to `Shomei.Id`.
- [x] Add `Shomei.Domain.Passkey` with the credential/ceremony domain types (plus the
      `b64urlEncode`/`b64urlDecode` helpers, using the `base64` package — NOT
      `base64-bytestring`; see Surprises).
- [x] Add `Shomei.Effect.WebAuthnCeremony` (port + smart constructors + error type + records).
- [x] Add `WebAuthnConfig`/`UserVerificationPolicy`/`AttestationPolicy`/`defaultWebAuthnConfig`
      and the `webauthnConfig` field to `Shomei.Config.ShomeiConfig`/`defaultShomeiConfig`.
- [x] Add the in-memory **fake** `runWebAuthnCeremonyFake` to `Shomei.Effect.InMemory`,
      extend `World` (`ceremonyCounter`), and slot `WebAuthnCeremony` into `runInMemory`'s list/chain.
- [x] Slot `WebAuthnCeremony` into `Shomei.Servant.Seam.AppEffects` and the servant test's
      `runHybrid`, and into `Shomei.Server.App.AppEffects` (right after `Notifier`). The
      server's `runAppIO` interprets it with a temporary `runWebAuthnCeremonyStub` in M1
      (no ceremony routes exist yet); M2 swaps in the real `runWebAuthnCeremonyLibrary`.
- [x] Slot `WebAuthnCeremony` into the `shomei-postgres` test `AppEffects` list and its runners
      (`runWebAuthnCeremonyFake` over a per-run `World` ref).
- [x] Add a core unit test (`Shomei.WebAuthnCeremonySpec`) that drives the fake deterministically
      (begin→complete registration; begin→complete authentication bumps the counter to 1; a wrong
      challenge yields `Left WebAuthnChallengeMismatch`) and asserts `defaultShomeiConfig`'s
      `webauthnConfig` equals `defaultWebAuthnConfig`.
- [x] `nix develop --command cabal build all` and `… cabal test all` stay green (all suites pass;
      shomei-core-test: 23 OK including the 2 new ceremony/config cases).

Milestone 2 — the `shomei-webauthn` package and the real interpreter:

- [ ] Create `shomei-webauthn/` (`.cabal`, `src/Shomei/WebAuthn/Ceremony.hs`, `test/`).
- [ ] Implement `runWebAuthnCeremonyLibrary` against `webauthn` + `crypton`.
- [ ] Register `shomei-webauthn` in `cabal.project` and `mori.dhall`.
- [ ] Wire `runWebAuthnCeremonyLibrary env.envConfig.webauthnConfig` into
      `Shomei.Server.App.runAppIO`.
- [ ] Add the `shomei-webauthn` end-to-end ceremony test (promote the M0 harness) asserting a
      verified result and an optionsBlob round-trip.
- [ ] `nix develop --command cabal build all` / `… cabal test all` green; `mori show --full`
      lists `shomei-webauthn`.
- [ ] Record the IP-1 final signatures and IP-3 final field shape back into the MasterPlan's
      Integration Points if they drifted from the canonical contract below.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Pre-implementation findings from reading the `tweag/webauthn` source on disk
(`/Users/shinzui/Keikaku/hub/haskell/webauthn-project/webauthn`, version `0.11.0.0`) and the
Shōmei tree. They are recorded now because they shape the milestones; confirm or correct each
as implementation proceeds.

- **The library's cabal bounds conflict with Shōmei's dependency set.** `webauthn.cabal`
  declares `crypton >= 0.32 && < 1.1`, `jose >= 0.11 && < 0.12`, and depends on the
  deprecated `memory` package. Shōmei uses `crypton >= 1.1.0`, a pinned `jose 0.13` (via the
  `sumo/hs-jose` source-repository-package), and the project rule forbids `memory` (use
  `ram`). This is the single biggest risk and is exactly why M0 is a build spike: it must be
  resolved with `allow-newer` (relaxing the *upper* bounds on `crypton`/`jose`) and, if
  `memory` cannot be tolerated alongside `crypton >= 1.1`, possibly a patched
  source-repository-package of `webauthn`. The outcome is recorded in the Decision Log
  placeholder below.

- **There is no public function that decodes options back from JSON.** The public
  `Crypto.WebAuthn.Encoding.WebAuthnJson` module exports `wjEncodeCredentialOptionsRegistration`
  / `wjEncodeCredentialOptionsAuthentication` (options → JSON-serializable intermediate
  type) and `wjDecodeCredentialRegistration` / `wjDecodeCredentialAuthentication` (browser
  credential → library `Credential`). It does **not** export a "decode options" function.
  However, the intermediate option types (`WJCredentialOptionsRegistration`,
  `WJCredentialOptionsAuthentication`) derive `ToJSON`/`FromJSON`, and the *exposed* internal
  module `Crypto.WebAuthn.Encoding.Internal.WebAuthnJson` exports a `Decode` type class with
  instances that turn `PublicKeyCredentialCreationOptions`/`PublicKeyCredentialRequestOptions`
  back into `CredentialOptions`. This makes a JSON-based serialization viable without
  `Codec.Serialise` orphans — see the Decision Log.

- **The example server stores the *entire* options and recovers them via the challenge.**
  `server/src/PendingCeremonies.hs` keeps `CredentialOptions` in a `TVar` keyed by the
  challenge, encoding an expiry into the challenge bytes. Shōmei instead generates an opaque
  `CeremonyId` and hands the browser both the options JSON and that id; the server later
  looks the blob up by id (EP-2 persists it). The challenge inside the blob still does the
  security work — the id is just a lookup handle. (Recorded so the reader does not copy the
  example's challenge-as-key scheme.)

- **`verifyRegistrationResponse`/`verifyAuthenticationResponse` return `Validation`, not
  `Either`.** The result type is `Data.Validation.Validation (NonEmpty …Error) …Result`
  (`Failure errs` / `Success result`). The interpreter must pattern-match on
  `Failure`/`Success` (not `Left`/`Right`) and collapse the `NonEmpty` error list to one
  `WebAuthnError`.

Implementation surprises (M0, 2026-06-17):

- **`allow-newer: webauthn:*` alone was insufficient; four source patches were needed.** The
  bounds wildcard resolved the solver, but the build then failed to *compile* against the bumped
  deps. See the Decision Log `allow-newer` entry for the full list. The headline cause is that
  `crypton >= 1.1` provides its `ByteArrayAccess (Digest h)` instance via `ram`, not `memory`;
  the secondary cause is jose 0.13's `RequiredProtection` JWS-header protection parameter.

- **The on-disk webauthn is the user's own fork (`shinzui/webauthn-project`), not `tweag/webauthn`
  directly.** It is a `git subtree` import of tweag `ad0f088` under the `webauthn/` subdir. The
  patches were committed and pushed to that fork's `master`
  (`a8b56361dc9c359186c88daec065e91a409b39f3`) and pinned via `source-repository-package` with
  `subdir: webauthn`.

- **The webauthn test-suite needs the library's project dir as CWD.** `tests/MetadataSpec.hs`
  reads `tests/golden-metadata/**` at spec-construction time, so running the test binary from the
  Shōmei repo root throws `withBinaryFile: does not exist`. This only affects running the *fork's*
  test-suite directly (used in M0 to prove the ceremony); `cabal test all` does not build it
  because the pin sets `package webauthn { tests: False }`. M2's `shomei-webauthn` test is
  self-contained and does not read golden files.

- **The full ceremony crypto was never the real risk.** The fork's emulation tests
  (`Emulation > None > succeeds`) drive a real software authenticator (ECDSA P-256 via crypton)
  through `verifyRegistrationResponse`/`verifyAuthenticationResponse` and pass 100/100; the
  bump to crypton 1.1 did not disturb the primitives. The real M0 value was confirming the WJ
  JSON serialization round-trips on this build (it does — 4 props, 100 cases each).

Implementation surprises (M1, 2026-06-17):

- **`shomei-core` depends on `base64`, not `base64-bytestring`.** The plan's contract note
  suggested `base64-bytestring`, but the core's actual dependency is the modern `base64` (1.0)
  package. Its base64url API is typed: `Data.ByteString.Base64.URL.encodeBase64Unpadded ::
  ByteString -> Base64 'UrlUnpadded Text` (unwrap with `Data.Base64.Types.extractBase64`) and
  `decodeBase64UnpaddedUntyped :: ByteString -> Either Text ByteString`. `b64urlEncode`/
  `b64urlDecode` in `Shomei.Domain.Passkey` are written against that.

- **aeson's `(.=)` clashes with lens's `(.=)` in core modules.** `Shomei.Prelude` re-exports all
  of `Control.Lens`, which includes the state-assign `(.=)`. In `Shomei.Effect.InMemory` the
  aeson object builder had to be qualified (`Aeson..=`) to disambiguate.

- **`OverloadedRecordDot`/`HasField` does not fire for a record whose field name is duplicated
  across records in the SAME module.** `stored.credentialId` on `StoredCredentialForVerify`
  failed with "No instance for HasField ... credentialId" because `Shomei.Effect.WebAuthnCeremony`
  defines `credentialId` on both `StoredCredentialForVerify` and `VerifiedRegistration`. The fix
  is to destructure with a named-field pattern (`StoredCredentialForVerify{credentialId = …}`)
  rather than dot-access. Equality comparisons in the spec sidestep field access entirely.

- **The Seam/Server/InMemory/servant-test stacks are tightly coupled and must move together.**
  `Shomei.Servant.Seam.Env.runPorts` is `forall a. Eff AppEffects a -> IO a`, so adding
  `WebAuthnCeremony` to `runInMemory`'s concrete list forces the same insertion into
  `Seam.AppEffects`, the servant test's `runHybrid`, and `Shomei.Server.App` (both the type and
  the `runAppIO` chain) in lock-step — a partial change does not type-check. The plan's
  suggestion to "defer the Server.App change to M2" is therefore not literally possible; M1
  instead inserts the entry everywhere and uses a temporary stub runner in the server (see the
  M1 Decision Log entry).


## Decision Log

Record every decision made while working on the plan.

- Decision: **Serialize the pending `optionsBlob` as the JSON bytes of the WebAuthn-JSON
  encoded options**, not via `Codec.Serialise` and not by storing only a hand-picked subset
  of fields.
  Rationale: The library has no public "decode options" function, but the WJ intermediate
  option types derive `ToJSON`/`FromJSON`, and the exposed
  `Crypto.WebAuthn.Encoding.Internal.WebAuthnJson` module provides a `Decode` instance that
  reconstructs `CredentialOptions` from those intermediate types. So the begin step computes
  `opts :: CredentialOptions k`, encodes it with `wjEncodeCredentialOptions*` to the WJ type,
  and the interpreter stores BOTH `Data.Aeson.toJSON wjOpts` (the browser-facing `optionsJson`)
  and `Data.Aeson.encode wjOpts` (the persisted `optionsBlob` bytes — the same JSON, as a
  `ByteString`). The complete step `Data.Aeson.decode`s the blob to the WJ type and runs the
  `Decode` instance to recover `CredentialOptions` for `verify*`. This keeps the blob
  self-describing, avoids orphan `Serialise` instances, and a round-trip is provable in a test
  (encode opts → decode blob → re-encode → byte-compare). Alternatives rejected: `Codec.Serialise`
  on `CredentialOptions` (no instance ships; writing one couples us to library internals);
  storing only `{challenge, rpId, userVerification, allowCredentials}` (re-deriving the rest is
  fragile and duplicates the library's option construction).
  Date: 2026-06-17

- Decision: **Map `SignatureCounterPotentiallyCloned` to `Left WebAuthnCounterCloned`
  (fail closed), not to a `cloneWarning = True` success.**
  Rationale: A decreased/equal signature counter is the library's clone-detection signal; the
  canonical contract offers two options and recommends failing closed by default. The example
  server aborts the login on clone (`Scotty.status 401`). For an MFA/security toolkit the safe
  default is to reject the assertion outright rather than hand the caller a "verified but
  warned" result they might ignore. `VerifiedAuthentication` therefore still carries a
  `cloneWarning :: Bool` field for forward compatibility, but the library interpreter sets it
  only on `SignatureCounterZero` mapped to `cloneWarning = False` and never returns a success
  for `SignatureCounterPotentiallyCloned`. (If a future plan wants a "warn, don't fail"
  policy it can flip this with a Decision Log entry in the MasterPlan IP-1.)
  Date: 2026-06-17

- Decision (M1, 2026-06-17): **The server's `runAppIO` interprets `WebAuthnCeremony` with a
  temporary stub in M1, replaced by the real `runWebAuthnCeremonyLibrary` in M2.**
  Rationale: `Shomei.Servant.Seam.Env.runPorts` fixes the whole port stack as one type, so
  `WebAuthnCeremony` cannot be added to `runInMemory`/`Seam.AppEffects` without also adding it to
  `Shomei.Server.App.AppEffects` and its `runAppIO` chain (otherwise nothing type-checks). The
  real interpreter lives in `shomei-webauthn`, which does not exist until M2. To keep M1's
  `cabal build all`/`test all` green, `runAppIO` uses `runWebAuthnCeremonyStub` (an
  `interpret_ \case _ -> error …`); it is never invoked because no passkey ceremony routes exist
  before EP-3/EP-4. M2 deletes the stub and wires `runWebAuthnCeremonyLibrary
  env.envConfig.webauthnConfig`. The plan's preference for "defer the Server.App change to M2"
  (Plan of Work step 7, option a) was infeasible given that coupling; option (b) was taken.
  The `shomei-postgres` and servant test stacks use the real fake (`runWebAuthnCeremonyFake`)
  over a fresh `World` ref, so only the production server carries a stub.
  Date: 2026-06-17

- Decision: **Put the `webauthn` library behind a dedicated `shomei-webauthn` package**
  (mirroring `shomei-jwt`), not in `shomei-core` and not folded into `shomei-postgres`.
  Rationale: `shomei-core` has zero infrastructure dependencies by design; `webauthn` drags in
  `crypton-x509`, `cborg`, `serialise`. Isolation matches the MasterPlan's IP-7 and the
  hexagonal layering. The package depends only on `shomei-core` + `webauthn` + `crypton`.
  Date: 2026-06-17

- Decision: **`allow-newer` outcome — RESOLVED at M0 (2026-06-17).** `webauthn 0.11.0.0`
  builds on GHC 9.12.4 with a **patched fork** plus a single wildcard `allow-newer`. The exact
  `cabal.project` block now reads:

  ```text
  source-repository-package
    type: git
    location: https://github.com/shinzui/webauthn-project.git
    tag: a8b56361dc9c359186c88daec065e91a409b39f3
    subdir: webauthn

  package webauthn
    tests: False
    benchmarks: False

  allow-newer:
    webauthn:*
  ```

  `allow-newer: webauthn:*` (relax all of webauthn's dependency upper bounds) was sufficient on
  the bounds side — the only enumerated conflict was `crypton-x509 1.9.1` vs webauthn's
  `crypton-x509 < 1.9` (jose pulls `crypton-x509 1.9.1`). The wildcard avoids enumerating the
  whole `crypton-*`/`jose`/`base`/`containers`/`singletons` set; it is safe because `allow-newer`
  only relaxes version bounds, never the API (API breaks surface as compile errors regardless).

  Four **source patches** to the fork were required (committed as
  `a8b56361dc9c359186c88daec065e91a409b39f3` on `shinzui/webauthn-project` master, pushed):
  1. **`memory` → `ram`.** With `crypton >= 1.1`, the `ByteArrayAccess (Digest h)` instance comes
     from `ram` (crypton's byte-array dependency), not the standalone `memory` package, so
     webauthn's `Data.ByteArray (convert)` over a `Digest` failed with "No instance for
     `memory-0.18.0:…ByteArrayAccess (Digest h)`". Swapping the `memory` build-dep for `ram`
     (same `Data.ByteArray*` module names) aligns the class. Done in both the `library` and
     `test-suite` stanzas of `webauthn.cabal`.
  2. **jose 0.13 protection parameter.** jose 0.13 changed the JWS header protection type from
     `()` to `RequiredProtection` (`type CompactJWS = JWS Identity RequiredProtection`). The two
     `VerificationKeyStore … (JWSHeader ()) …` instances (`RootCertificate` in
     `Metadata/Service/Processing.hs`; `VerificationHostName` in `…/AndroidSafetyNet.hs`) became
     `(JWSHeader RequiredProtection)`, and the SafetyNet `HeaderParam () x5c` pattern became
     `HeaderParam _ x5c`.
  3. **`verifyJWT` is header-polymorphic** in jose 0.13; annotate the decoded JWT as `SignedJWT`
     in `Processing.hs:jwtToAdditionalData` to fix `h ~ JWSHeader`.
  4. **`validation` dropped `toEither`** (only used by the test-suite); defined locally in
     `tests/Emulation.hs` and `tests/Main.hs`.

  Patches 2–4 touch only the MDS/SafetyNet/test code (deferred for consumer passkeys per the
  MasterPlan scope); the registration/authentication ceremony crypto path is unchanged. M0
  proof: the fork's own emulation test-suite passes on this build —
  `Emulation > None > succeeds` (full register→authenticate, real ECDSA, 100 cases, 0 failures)
  and the four `Encoding > … can be roundtripped` WJ JSON props (options + credentials, 100
  cases each), validating the `optionsBlob` serialization strategy. The library is pinned as a
  `source-repository-package` (not a local path) so the build is reproducible.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section orients a reader who has never seen this repository. Everything you need is in
the working tree plus this file; do not consult other plans.

Shōmei is a Cabal multi-package project built with **GHC 9.12.4** inside a Nix dev shell.
Every build/test command in this plan is run from the repository root and prefixed with
`nix develop --command` so it runs in that shell. The package list lives in `cabal.project`.
The current packages are `shomei-core`, `shomei-jwt`, `shomei-postgres`, `shomei-migrations`,
`shomei-servant`, `shomei-server`, `shomei-client`, and two examples.

The architecture is **hexagonal**: `shomei-core` holds domain types, the effect *ports*, and
the workflows, with **no infrastructure dependencies** (no Servant, no PostgreSQL, no JWT, no
`webauthn`). Infrastructure packages interpret the ports: `shomei-jwt` interprets the
signing/verification ports against the `jose` library; `shomei-postgres` interprets the store
ports against `hasql`. This plan adds a third such package, `shomei-webauthn`, for the
ceremony port. The `shomei-jwt` package is the structural template for the new one — read
`shomei-jwt/shomei-jwt.cabal` (a `library` stanza exposing `Shomei.Jwt.*` and depending on
`shomei-core` + `jose` + `crypton`, plus a `test-suite`).

Concepts you will touch, with their exact locations:

- **The shared prelude.** Every Shōmei module imports `Shomei.Prelude`
  (`shomei-core/src/Shomei/Prelude.hs`) instead of the standard `Prelude`. It re-exports
  aeson's `FromJSON`/`ToJSON`/`Options`, `GHC.Generics.Generic`, `Data.Text.Text`,
  `Data.Time.UTCTime`, `Control.Lens`, and helpers. It is compiled with `PackageImports`, so
  do not add `import "base" Prelude`. New core modules begin with `import Shomei.Prelude`.

- **Typed identifiers.** `shomei-core/src/Shomei/Id.hs` defines ids as `mmzk-typeid`
  `KindID`s — a UUIDv7 with a type-level prefix, so `UserId = KindID "user"` and
  `SessionId = KindID "session"` are distinct types. Each id has a generator
  (`genUserId :: MonadIO m => m UserId`) and a pair of UUID conversions
  (`userIdToUUID`/`userIdFromUUID`) for the PostgreSQL `uuid` column. This plan adds two new
  ids the same way.

- **A port and its interpreters.** `shomei-core/src/Shomei/Effect/TokenGen.hs` is the simplest
  example to copy: it declares `data TokenGen :: Effect where …`, sets
  `type instance DispatchOf TokenGen = Dynamic`, and exports `send`-based smart constructors.
  `shomei-core/src/Shomei/Effect/VerificationTokenStore.hs` is a richer example with several
  operations and domain arguments. The in-memory (fake) interpreters for **all** ports live in
  one module, `shomei-core/src/Shomei/Effect/InMemory.hs`, which holds a mutable `World`
  record (an `IORef`) and a `runInMemory` function that stacks one `run…` per port over `IOE`.
  Study how `runTokenSigner`/`runTokenVerifier` fake real cryptography by round-tripping
  `AuthClaims` through JSON — the WebAuthn fake follows the same "echo and accept" idea.

- **The config record.** `shomei-core/src/Shomei/Config.hs` holds `ShomeiConfig`, an
  append-only record where every newer feature added a sub-record with a default. Read how
  `notifierConfig`/`rateLimitConfig`/`observabilityConfig` are each a `data …Config` with
  `deriving (Generic, Eq, Show)` + `deriving anyclass (FromJSON, ToJSON)` and a
  `default…Config` value, all wired into `defaultShomeiConfig`. This plan adds a
  `webauthnConfig` field the same way.

- **The effect-stack lists (IP-6).** Several places enumerate the canonical ordered port
  stack and must stay identical to each other. They are:
  `shomei-servant/src/Shomei/Servant/Seam.hs` (`type AppEffects`),
  `shomei-server/src/Shomei/Server/App.hs` (`type AppEffects` *and* the `runAppIO`
  interpreter chain, which additionally has `Database` and `Error AuthError` below the ports),
  `shomei-core/src/Shomei/Effect/InMemory.hs` (`runInMemory`'s explicit `Eff '[…]` type and its
  composition), and the `shomei-postgres` test `AppEffects` (find it with the search command in
  Concrete Steps). This plan inserts `WebAuthnCeremony` into all of them at one fixed position.

- **The infra crypto helper.** `shomei-postgres/src/Shomei/Crypto.hs` shows the `crypton`
  idioms the real interpreter reuses: `Crypto.Hash.hashWith SHA256`, `Crypto.Random.getRandomBytes`,
  base64url via `Data.ByteArray.Encoding`. The real WebAuthn interpreter needs SHA-256 (to
  build the RP ID hash) and the library's own randomness; it can reuse these patterns.

- **The `webauthn` library, on disk.** Registered in `mori` as `tweag/webauthn` at
  `/Users/shinzui/Keikaku/hub/haskell/webauthn-project`, with the library package at
  `…/webauthn/`. Its umbrella module is `Crypto.WebAuthn` (re-exporting `Model`, `Encoding`,
  `Operation`, `Metadata`). The canonical RP example is `…/webauthn/server/src/Main.hs`. The
  facts the interpreter needs from it are embedded below so you need not re-read it.

The end state of this plan: `shomei-core` gains passkey domain types, two ids, a config
sub-record, and a ceremony port with a deterministic fake; `shomei-webauthn` exists and
interprets the port against the real library; every effect-stack list carries
`WebAuthnCeremony`; and two tests prove both interpreters work. No HTTP routes, no database
tables, no workflow changes — those belong to EP-2..EP-5.


## The canonical shared contract (authoritative names and signatures)

This plan **owns** the following names. Other plans in MasterPlan 3 depend on them verbatim;
do not rename without a Decision Log entry here and in the MasterPlan's IP-1/IP-3.

### Domain types — `shomei-core/src/Shomei/Domain/Passkey.hs` (new)

A new module with no `webauthn` import (it uses only `Shomei.Prelude`, `Data.ByteString`, and
`Shomei.Id`). `ByteString` here is strict `Data.ByteString.ByteString`; aeson has no default
`ByteString` JSON instance, so each newtype over `ByteString` derives JSON via a base64url
text representation (see the implementation note after the block).

```haskell
{-# LANGUAGE DataKinds #-}

module Shomei.Domain.Passkey (
    WebAuthnCredentialId (..),
    UserHandle (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    CeremonyKind (..),
    PendingCeremony (..),
) where

import Shomei.Prelude
import Data.ByteString (ByteString)
import Data.Word (Word32)
import Shomei.Id (UserId, PasskeyId, CeremonyId)

-- | The authenticator-assigned credential id (stored as bytea). Opaque bytes.
newtype WebAuthnCredentialId = WebAuthnCredentialId ByteString
    deriving stock (Generic, Eq, Show)

-- | The RP-assigned per-user handle (random bytes the authenticator returns at login).
newtype UserHandle = UserHandle ByteString
    deriving stock (Generic, Eq, Show)

-- | The COSE public-key bytes exactly as the webauthn library serializes them.
newtype PublicKeyBytes = PublicKeyBytes ByteString
    deriving stock (Generic, Eq, Show)

-- | The authenticator's signature counter (clone-detection aid).
newtype SignatureCounter = SignatureCounter Word32
    deriving stock (Generic, Eq, Show)
    deriving newtype (FromJSON, ToJSON)

-- | A freshly verified registration, ready for EP-2's store to persist.
data NewPasskeyCredential = NewPasskeyCredential
    { userId :: !UserId
    , credentialId :: !WebAuthnCredentialId
    , userHandle :: !UserHandle
    , publicKey :: !PublicKeyBytes
    , signCounter :: !SignatureCounter
    , transports :: ![Text]
    , label :: !(Maybe Text)
    , createdAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | A persisted passkey (EP-2 reads/writes this; EP-1 only defines it).
data PasskeyCredential = PasskeyCredential
    { passkeyId :: !PasskeyId
    , userId :: !UserId
    , credentialId :: !WebAuthnCredentialId
    , userHandle :: !UserHandle
    , publicKey :: !PublicKeyBytes
    , signCounter :: !SignatureCounter
    , transports :: ![Text]
    , label :: !(Maybe Text)
    , createdAt :: !UTCTime
    , lastUsedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | Which ceremony a pending blob belongs to.
data CeremonyKind = RegistrationCeremony | AuthenticationCeremony
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | The short-lived challenge/options state (EP-1 defines; EP-2 persists).
data PendingCeremony = PendingCeremony
    { ceremonyId :: !CeremonyId
    , userId :: !(Maybe UserId)
    , kind :: !CeremonyKind
    , optionsBlob :: !ByteString
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
```

Implementation note on the `ByteString` newtypes' JSON. Give
`WebAuthnCredentialId`, `UserHandle`, and `PublicKeyBytes` `FromJSON`/`ToJSON` instances that
encode the bytes as a base64url-without-padding `Text` (the same encoding the rest of the
codebase uses — see `convertToBase Base64URLUnpadded` in `shomei-postgres/src/Shomei/Crypto.hs`,
but core may not depend on `crypton`, so use a pure base64 dependency such as `base64-bytestring`,
already in the dependency set). Write these as hand-written instances (not `deriving anyclass`),
e.g.:

```haskell
instance ToJSON WebAuthnCredentialId where
    toJSON (WebAuthnCredentialId bs) = toJSON (b64urlEncode bs)
instance FromJSON WebAuthnCredentialId where
    parseJSON v = WebAuthnCredentialId <$> (parseJSON v >>= either fail pure . b64urlDecode)
```

where `b64urlEncode :: ByteString -> Text` / `b64urlDecode :: Text -> Either String ByteString`
are small local helpers. `NewPasskeyCredential`/`PasskeyCredential` then derive JSON via
`anyclass` using those field instances. Keep these helpers in `Shomei.Domain.Passkey` (or a
tiny `Shomei.Domain.Base64` module) so EP-2 can reuse them. The reason JSON instances matter at
all is that the deterministic fake interpreter (M1) and the workflows (EP-3/EP-4) move these
values around; they are not stored as JSON in PostgreSQL (EP-2 uses `bytea`).

### New identifiers — `shomei-core/src/Shomei/Id.hs` (edit)

Add, mirroring `VerificationTokenId` exactly (type alias, generator, two UUID conversions, and
the export list entries):

```haskell
type PasskeyId = KindID "passkey"
type CeremonyId = KindID "webauthn_ceremony"

genPasskeyId :: (MonadIO m) => m PasskeyId
genPasskeyId = KindID.genKindID @"passkey"

genCeremonyId :: (MonadIO m) => m CeremonyId
genCeremonyId = KindID.genKindID @"webauthn_ceremony"

passkeyIdToUUID :: PasskeyId -> UUID
passkeyIdToUUID = getUUID
passkeyIdFromUUID :: UUID -> PasskeyId
passkeyIdFromUUID = decorateKindID

ceremonyIdToUUID :: CeremonyId -> UUID
ceremonyIdToUUID = getUUID
ceremonyIdFromUUID :: UUID -> CeremonyId
ceremonyIdFromUUID = decorateKindID
```

Add `PasskeyId`, `CeremonyId`, `genPasskeyId`, `genCeremonyId`, and the four conversions to the
module export list. The KindID prefix must satisfy `ValidPrefix`; `"passkey"` and
`"webauthn_ceremony"` are lowercase + underscore, matching `"verification_token"`, so they are
valid.

### The port — `shomei-core/src/Shomei/Effect/WebAuthnCeremony.hs` (new)

The port crosses the boundary using `Data.Aeson.Value` plus the new domain types. Core never
names a `webauthn` type.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

module Shomei.Effect.WebAuthnCeremony (
    WebAuthnCeremony (..),
    WebAuthnError (..),
    CredentialUserInfo (..),
    BeginCeremony (..),
    StoredCredentialForVerify (..),
    VerifiedRegistration (..),
    VerifiedAuthentication (..),
    beginRegistrationCeremony,
    completeRegistrationCeremony,
    beginAuthenticationCeremony,
    completeAuthenticationCeremony,
) where

import Shomei.Prelude
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Passkey (
    WebAuthnCredentialId, UserHandle, PublicKeyBytes, SignatureCounter )

-- | The verification failure modes, mapped from the library's
-- RegistrationError/AuthenticationError families to a small stable closed set.
data WebAuthnError
    = WebAuthnDecodeError Text
    | WebAuthnChallengeMismatch
    | WebAuthnOriginMismatch
    | WebAuthnRpIdMismatch
    | WebAuthnUserNotPresent
    | WebAuthnUserNotVerified
    | WebAuthnSignatureInvalid
    | WebAuthnCounterCloned
    | WebAuthnOtherError Text
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | The user identity baked into a registration's options.
data CredentialUserInfo = CredentialUserInfo
    { userHandle :: !UserHandle
    , accountName :: !Text
    , displayName :: !Text
    }
    deriving stock (Generic, Eq, Show)

-- | The two outputs of a begin step: the JSON for the browser and the opaque
-- blob for PendingCeremonyStore (EP-2).
data BeginCeremony = BeginCeremony
    { optionsJson :: !Value
    , optionsBlob :: !ByteString
    }
    deriving stock (Generic, Eq, Show)

-- | The stored fields the authentication verify step needs (EP-4 reads them
-- from PasskeyStore and hands them here).
data StoredCredentialForVerify = StoredCredentialForVerify
    { credentialId :: !WebAuthnCredentialId
    , userHandle :: !UserHandle
    , publicKey :: !PublicKeyBytes
    , signCounter :: !SignatureCounter
    , transports :: ![Text]
    }
    deriving stock (Generic, Eq, Show)

data VerifiedRegistration = VerifiedRegistration
    { credentialId :: !WebAuthnCredentialId
    , userHandle :: !UserHandle
    , publicKey :: !PublicKeyBytes
    , signCounter :: !SignatureCounter
    , transports :: ![Text]
    }
    deriving stock (Generic, Eq, Show)

data VerifiedAuthentication = VerifiedAuthentication
    { credentialId :: !WebAuthnCredentialId
    , newSignCounter :: !SignatureCounter
    , cloneWarning :: !Bool
    }
    deriving stock (Generic, Eq, Show)

data WebAuthnCeremony :: Effect where
    -- 2nd arg = excludeCredentials (ids already enrolled for this user).
    BeginRegistrationCeremony
        :: CredentialUserInfo -> [WebAuthnCredentialId] -> WebAuthnCeremony m BeginCeremony
    -- optionsBlob, then the browser's credential JSON.
    CompleteRegistrationCeremony
        :: ByteString -> Value -> WebAuthnCeremony m (Either WebAuthnError VerifiedRegistration)
    -- allowCredentials ([] = passwordless discovery).
    BeginAuthenticationCeremony
        :: [WebAuthnCredentialId] -> WebAuthnCeremony m BeginCeremony
    CompleteAuthenticationCeremony
        :: ByteString -> StoredCredentialForVerify -> Value
        -> WebAuthnCeremony m (Either WebAuthnError VerifiedAuthentication)

type instance DispatchOf WebAuthnCeremony = Dynamic

beginRegistrationCeremony
    :: (WebAuthnCeremony :> es) => CredentialUserInfo -> [WebAuthnCredentialId] -> Eff es BeginCeremony
beginRegistrationCeremony u xs = send (BeginRegistrationCeremony u xs)

completeRegistrationCeremony
    :: (WebAuthnCeremony :> es) => ByteString -> Value -> Eff es (Either WebAuthnError VerifiedRegistration)
completeRegistrationCeremony b v = send (CompleteRegistrationCeremony b v)

beginAuthenticationCeremony
    :: (WebAuthnCeremony :> es) => [WebAuthnCredentialId] -> Eff es BeginCeremony
beginAuthenticationCeremony = send . BeginAuthenticationCeremony

completeAuthenticationCeremony
    :: (WebAuthnCeremony :> es)
    => ByteString -> StoredCredentialForVerify -> Value -> Eff es (Either WebAuthnError VerifiedAuthentication)
completeAuthenticationCeremony b c v = send (CompleteAuthenticationCeremony b c v)
```

### Config — `shomei-core/src/Shomei/Config.hs` (edit, append-only)

Add three types and a default, then add one field to `ShomeiConfig` and one entry to
`defaultShomeiConfig`, exporting the new names. `NominalDiffTime` is already imported.

```haskell
data UserVerificationPolicy = UVRequired | UVPreferred | UVDiscouraged
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data AttestationPolicy = AttestationNone | AttestationDirect
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data WebAuthnConfig = WebAuthnConfig
    { rpId :: !Text
    , rpName :: !Text
    , origins :: ![Text]
    , userVerification :: !UserVerificationPolicy
    , attestation :: !AttestationPolicy
    , ceremonyTimeout :: !NominalDiffTime
    , pendingCeremonyTTL :: !NominalDiffTime
    , mfaRequired :: !Bool
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultWebAuthnConfig :: WebAuthnConfig
defaultWebAuthnConfig =
    WebAuthnConfig
        { rpId = "localhost"
        , rpName = "Shōmei"
        , origins = ["http://localhost:8080"]
        , userVerification = UVPreferred
        , attestation = AttestationNone
        , ceremonyTimeout = 300
        , pendingCeremonyTTL = 300
        , mfaRequired = True
        }
```

Add `webauthnConfig :: !WebAuthnConfig` as the last field of `ShomeiConfig` and
`webauthnConfig = defaultWebAuthnConfig` as the last entry in `defaultShomeiConfig`. Export
`WebAuthnConfig (..)`, `UserVerificationPolicy (..)`, `AttestationPolicy (..)`, and
`defaultWebAuthnConfig`. Because the field has a default and JSON via Generic, older config
files still parse (append-only per IP-3). `EP-4` reads `mfaRequired`; the interpreter reads
`rpId`/`rpName`/`origins`/`userVerification`/`attestation`/`ceremonyTimeout`.

### The interpreters

The library interpreter, defined in M2, has this signature in
`shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs`:

```haskell
runWebAuthnCeremonyLibrary
    :: (IOE :> es) => WebAuthnConfig -> Eff (WebAuthnCeremony : es) a -> Eff es a
```

The deterministic fake interpreter, defined in M1 in `Shomei.Effect.InMemory`, has this
signature (it needs the test `World` for time/determinism):

```haskell
runWebAuthnCeremonyFake
    :: (IOE :> es) => IORef World -> Eff (WebAuthnCeremony : es) a -> Eff es a
```


## Plan of Work

The work is three milestones. M0 de-risks the heavy dependency and proves the serialization
strategy with a throwaway harness. M1 adds all the `shomei-core` surface (domain, ids, config,
port) plus a deterministic fake interpreter and wires the port into every effect-stack list.
M2 builds the real `shomei-webauthn` package and proves a full simulated ceremony verifies.

### Milestone 0 — build/verification spike

Scope: prove `webauthn 0.11.0.0` builds in the Nix dev shell on GHC 9.12.4, and that a full
register→authenticate ceremony round-trips through a throwaway harness, including the
`optionsBlob` serialization. Nothing in `shomei-*` changes permanently in M0 except the
`cabal.project` dependency block (which M2 keeps). At the end of M0 you will have either a
green spike printing `ceremony verified` or a recorded blocking failure and a revised plan.

What will exist: a `cabal.project` block making `webauthn` resolvable, and a temporary harness
(throwaway `Main` or test) demonstrating the ceremony and the serialization. The harness is
deleted or promoted into the `shomei-webauthn` test in M2.

Add to `cabal.project` (its own block, appended; do not edit other plans' blocks):

```text
-- ============================================================
-- MasterPlan 3 / EP-1 (WebAuthn): the tweag/webauthn library is registered in
-- mori as tweag/webauthn and lives on disk; pin it as a source-repository-package
-- (or local path) and relax its upper bounds to build on GHC 9.12.4.
-- ============================================================
source-repository-package
  type: git
  location: https://github.com/tweag/webauthn.git
  tag: <PIN-A-COMMIT-OR-USE-A-LOCAL-PATH>

allow-newer:
  webauthn:base,
  webauthn:crypton,
  webauthn:jose,
  webauthn:containers,
  webauthn:text,
  webauthn:time,
  webauthn:mtl,
  webauthn:lens
```

The exact `allow-newer` set is a guess to be refined in M0: build, read the solver's
complaint, add the one package it names, repeat. The library declares `crypton < 1.1` and
`jose < 0.12`; Shōmei carries `crypton >= 1.1.0` and a pinned `jose 0.13`, so `webauthn:crypton`
and `webauthn:jose` are the most likely required relaxations. `webauthn` also depends on the
deprecated `memory`; if `memory` cannot coexist with `crypton >= 1.1` in the solve, you must
patch the library (fork it, swap `memory` for `ram`/`crypton`'s `Data.ByteArray`) and pin the
fork. **Record the final lines and any fork commit in the Decision Log `allow-newer` placeholder.**

If `mori show --full` or `mori registry show tweag/webauthn --full` reports a usable local path
or a known-good fork/commit, prefer pinning that. The on-disk copy at
`/Users/shinzui/Keikaku/hub/haskell/webauthn-project/webauthn` is the source you read; you may
also reference it as a local `packages:` path during M0 to iterate quickly, then convert to a
proper `source-repository-package` pin for M2.

The harness logic (model on `…/webauthn/server/src/Main.hs` and its `tests/Emulation` which
build a software authenticator). Embed these library facts (verified by reading the source):

The RP id hash is SHA-256 of the UTF-8 `rpId`, wrapped:

```haskell
import Crypto.Hash (hash)
import qualified Crypto.WebAuthn as WA
import Data.Text.Encoding (encodeUtf8)

mkRpIdHash :: Text -> WA.RpIdHash
mkRpIdHash rpId = WA.RpIdHash (hash (encodeUtf8 rpId))
```

A registration options value is built with `defaultPkcco`-style construction and a fresh
challenge/user handle:

```haskell
user <- do
  uh <- WA.generateUserHandle          -- :: IO WA.UserHandle  (16 random bytes)
  pure WA.CredentialUserEntity
    { WA.cueId = uh
    , WA.cueDisplayName = WA.UserAccountDisplayName "Ada Lovelace"
    , WA.cueName = WA.UserAccountName "ada@example.com"
    }
challenge <- WA.generateChallenge       -- :: IO WA.Challenge  (16 random bytes)
let opts = defaultPkcco user challenge  -- :: WA.CredentialOptions 'WA.Registration
    wjOpts = WA.wjEncodeCredentialOptionsRegistration opts   -- has To/FromJSON
```

(`defaultPkcco` is reproduced in this plan's example facts below; it sets `corRp`,
`corPubKeyCredParams` to ES256 + RS256, `corAttestation`, etc.)

The serialization round-trip to validate in M0:

```haskell
import qualified Data.Aeson as Aeson
-- begin: persist this blob
let blob = Aeson.encode wjOpts                       -- :: LBS.ByteString
-- complete: recover the options from the blob
case Aeson.eitherDecode blob of
  Left e   -> error ("blob decode failed: " <> e)
  Right (wjOpts' :: WA.WJCredentialOptionsRegistration) -> do
    -- prove the JSON round-trips identically
    when (Aeson.encode wjOpts' /= blob) (error "round-trip mismatch")
    -- recover CredentialOptions for verify via the internal Decode class
    -- (Crypto.WebAuthn.Encoding.Internal.WebAuthnJson exposes `decode`)
    pure ()
```

To turn the WJ option type back into `WA.CredentialOptions 'WA.Registration`, use the `Decode`
instance from the *exposed* internal module:

```haskell
import qualified Crypto.WebAuthn.Encoding.Internal.WebAuthnJson as WJI
import Control.Monad.Except (runExcept)
-- wjOpts' :: WA.WJCredentialOptionsRegistration  (newtype over WJI.PublicKeyCredentialCreationOptions)
-- unwrap it to the inner PublicKeyCredentialCreationOptions, then:
recoverReg :: WJI.PublicKeyCredentialCreationOptions
           -> Either Text (WA.CredentialOptions 'WA.Registration)
recoverReg = runExcept . WJI.decode
```

If the `WJCredentialOptionsRegistration` newtype does not expose its inner field publicly,
note it in Surprises and instead store/recover via the inner `PublicKeyCredentialCreationOptions`
directly (it also has `To/FromJSON`): the begin step holds `inner = WJI.encode opts` and the
blob is `Aeson.encode inner`; complete is `Aeson.eitherDecode blob >>= runExcept . WJI.decode`.
Whichever path works, M0 must end with a proven encode→persist→decode→`verify*` round-trip.

The simulated authenticator (signing the challenge) is the fiddliest part. Prefer reusing the
library's own test emulator: read `…/webauthn/tests/Emulation/Authenticator.hs` and
`…/webauthn/tests/Emulation/Client.hs`, which construct a `Credential 'Registration 'True`
and a `Credential 'Authentication 'True` from options without a real device. If wiring the
test emulator into the spike is impractical (it is in the library's `test-suite`, not the
`library`), the fallback for M0 is to capture one real browser `create()`/`get()` JSON payload
pair (or a recorded fixture from `…/webauthn/tests/responses/`) and feed it through
`wjDecodeCredential*` + `verify*` against the matching stored options. Either way, the
acceptance is the same: the harness prints `ceremony verified`.

Acceptance for M0: from the repo root,

```bash
nix develop --command cabal build webauthn
```

succeeds, and running the spike prints `ceremony verified`. Expected transcript tail:

```text
Resolving dependencies...
Building library for webauthn-0.11.0.0...
...
ceremony verified
```

If the build fails irrecoverably, record the exact solver error in the Decision Log
placeholder and Surprises, and revise the MasterPlan (whose Surprises section already flags
this) before proceeding.

### Milestone 1 — core domain, port, config, fake interpreter, wiring

Scope: everything that lives in `shomei-core` (and the two non-core effect-stack lists), with
no dependency on `webauthn`. At the end, `cabal build all` and the existing `cabal test all`
stay green, plus a new core unit test drives the deterministic fake `WebAuthnCeremony`
interpreter. This milestone unblocks EP-2..EP-4 to start coding against the port and domain
types even before the real interpreter exists.

What will exist that did not before: the modules `Shomei.Domain.Passkey` and
`Shomei.Effect.WebAuthnCeremony`; the ids `PasskeyId`/`CeremonyId`; the `webauthnConfig`
sub-record; `runWebAuthnCeremonyFake` in `Shomei.Effect.InMemory`; and `WebAuthnCeremony`
present in all four effect-stack lists.

Edits, in order:

1. `shomei-core/src/Shomei/Id.hs` — add the two ids exactly as shown in the contract section.

2. `shomei-core/src/Shomei/Domain/Passkey.hs` — new module exactly as in the contract section,
   plus the base64url JSON helpers. Add the module to `exposed-modules` in
   `shomei-core/shomei-core.cabal` (find the `exposed-modules` list and add `Shomei.Domain.Passkey`
   alphabetically near the other `Shomei.Domain.*`). If `base64-bytestring` is not yet a
   `build-depends` of `shomei-core`, add it (it is already in the project's dependency set via
   `shomei-jwt`).

3. `shomei-core/src/Shomei/Effect/WebAuthnCeremony.hs` — new module exactly as in the contract
   section; add `Shomei.Effect.WebAuthnCeremony` to `exposed-modules`.

4. `shomei-core/src/Shomei/Config.hs` — add the config types/default/field as in the contract
   section.

5. `shomei-core/src/Shomei/Effect/InMemory.hs` — add the fake interpreter and wire it into
   `runInMemory`. Concretely:
   - Import `Shomei.Effect.WebAuthnCeremony (..)` and the `Shomei.Domain.Passkey` types.
   - Decide what the fake stores. The fake must be **deterministic** and crypto-free so
     EP-3/EP-4 tests are reproducible. Model it on `runTokenSigner`/`runTokenVerifier`
     (round-trip through JSON). Concretely, the fake's behavior is:
     - `BeginRegistrationCeremony userInfo _exclude`: build a canned options `Value` that
       embeds a deterministic challenge derived from a counter (reuse/extend the existing
       `tokenCounter` in `World`, or add a `ceremonyCounter`), and set the `optionsBlob` to the
       UTF-8/`Data.Aeson.encode` of that same `Value` (so begin's blob and json agree). Return
       `BeginCeremony{optionsJson, optionsBlob}`.
     - `CompleteRegistrationCeremony blob credentialJson`: treat the `credentialJson` as
       carrying the fields a test wants verified. The fake **accepts** any credential JSON
       whose embedded challenge matches the one inside `blob` (decode both via aeson) and
       returns `Right VerifiedRegistration{…}` with the `credentialId`/`userHandle`/`publicKey`
       taken from fields the test placed in `credentialJson` (e.g. base64url strings under keys
       `credentialId`, `userHandle`, `publicKey`); a mismatched/absent challenge returns
       `Left WebAuthnChallengeMismatch`. Initial `signCounter` is `SignatureCounter 0`.
     - `BeginAuthenticationCeremony _allow`: same canned-options pattern as registration begin.
     - `CompleteAuthenticationCeremony blob stored credentialJson`: if the challenge in
       `credentialJson` matches `blob` and `stored.credentialId` equals the `credentialId` in
       `credentialJson`, return `Right VerifiedAuthentication{ credentialId = stored.credentialId,
       newSignCounter = SignatureCounter (n+1) where n = unwrap stored.signCounter,
       cloneWarning = False }`; otherwise `Left WebAuthnSignatureInvalid` (or
       `WebAuthnChallengeMismatch` on challenge mismatch).
   - Make this contract **explicit in the module haddock** for the fake so EP-3/EP-4 authors
     know exactly what JSON shape to feed it. The point of the fake is that a test can call
     `beginRegistrationCeremony` then hand `optionsBlob`'s challenge back inside a tiny crafted
     credential `Value`, and `completeRegistrationCeremony` will succeed deterministically.
   - Write `runWebAuthnCeremonyFake :: (IOE :> es) => IORef World -> Eff (WebAuthnCeremony : es) a -> Eff es a`
     using `interpret_ \case …`.
   - In `runInMemory`, insert `WebAuthnCeremony` into the explicit `Eff '[…]` type list
     **immediately after `Notifier`** and add `. runWebAuthnCeremonyFake ref` into the
     composition at the matching position (the composition is right-to-left; place it directly
     adjacent to `runNotifier ref` on the `Notifier` side). The resulting list head segment
     becomes: `… , LoginAttemptStore , Notifier , WebAuthnCeremony , PasswordHasher , …`.
   - If you add a `ceremonyCounter` field to `World`, also set it in `emptyWorld`.

6. `shomei-servant/src/Shomei/Servant/Seam.hs` — add `import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)`
   and insert `, WebAuthnCeremony` into `type AppEffects` immediately after `Notifier`.

7. `shomei-server/src/Shomei/Server/App.hs` — add the same import and insert `, WebAuthnCeremony`
   into `type AppEffects` immediately after `Notifier`. **Do not** add a runner here yet beyond
   what M2 wires; in M1, to keep `cabal build all` green, the server's `runAppIO` must still
   interpret the new effect. Since the real interpreter lands in M2, M1 can either (a) defer
   the server-stack change to M2, or (b) temporarily interpret it with a stub that `error`s
   ("WebAuthnCeremony not yet wired"). Prefer (a): make the `Seam`, `InMemory`, and
   `shomei-postgres` test stacks carry the effect in M1 (they have interpreters: the fake for
   the first two; see step 8 for postgres-test), and add the `Server.App` list entry **and** its
   `runWebAuthnCeremonyLibrary` runner together in M2 so the server package only ever compiles
   with a real runner. Record this sequencing choice in Progress.

8. The `shomei-postgres` test `AppEffects` — locate it (search command in Concrete Steps).
   Insert `WebAuthnCeremony` after `Notifier` in its list and wire its runner. The postgres
   test does not need real WebAuthn crypto, so interpret `WebAuthnCeremony` there with the
   in-memory fake `runWebAuthnCeremonyFake` (it is exported from `Shomei.Effect.InMemory`).
   If the postgres test stack does not currently hold an `IORef World`, the simplest path is to
   give that test its own tiny `World` `IORef` (or a standalone deterministic interpreter) — do
   the minimum to keep the test compiling and green; this is test plumbing, not production.

9. Add a core unit test driving the fake. Put it where `shomei-core`'s tests live (search for
   the test-suite stanza in `shomei-core/shomei-core.cabal` and an existing spec module to copy
   the harness shape). The test:
   - Creates an `emptyWorld someFixedTime` `IORef`.
   - Runs, under `runWebAuthnCeremonyFake`, a `beginRegistrationCeremony` with a sample
     `CredentialUserInfo`, captures `optionsBlob`, crafts a credential `Value` echoing the
     blob's challenge plus sample `credentialId`/`userHandle`/`publicKey`, calls
     `completeRegistrationCeremony`, and asserts `Right VerifiedRegistration{…}` with the
     expected fields and `signCounter = SignatureCounter 0`.
   - Then `beginAuthenticationCeremony [credId]`, crafts a matching credential `Value`, calls
     `completeAuthenticationCeremony blob (StoredCredentialForVerify …) credentialJson`, and
     asserts `Right VerifiedAuthentication{ newSignCounter = SignatureCounter 1, cloneWarning = False }`.
   - Asserts a deliberately wrong challenge yields `Left WebAuthnChallengeMismatch`.

Acceptance for M1:

```bash
nix develop --command cabal build all
nix develop --command cabal test all
```

both succeed; the new core spec passes. Expected tail:

```text
shomei-core> Test suite ... PASS
All N tests passed (... )
```

Because M1 touches the canonical effect-stack lists, a build that fails with
"No instance for (WebAuthnCeremony :> es)" means a list or runner was missed — the
`build all` is the proof that every stack is consistent.

### Milestone 2 — the `shomei-webauthn` package and the real interpreter

Scope: create the new package, implement `runWebAuthnCeremonyLibrary` against the real
library, register it everywhere, wire it into the server, and prove a full simulated ceremony
verifies through it. At the end, `cabal build all`/`cabal test all` are green, `mori show --full`
lists `shomei-webauthn`, and the package's test runs register→authenticate end to end.

What will exist that did not before: the directory `shomei-webauthn/` with
`shomei-webauthn.cabal`, `src/Shomei/WebAuthn/Ceremony.hs`, and `test/`; the package in
`cabal.project` and `mori.dhall`; and the server's `runAppIO` interpreting the ceremony via
the real interpreter.

Create `shomei-webauthn/shomei-webauthn.cabal` (model on `shomei-jwt/shomei-jwt.cabal`):

```cabal
cabal-version: 3.0
name:          shomei-webauthn
version:       0.1.0.0
synopsis:      WebAuthn (passkey) registration/authentication ceremony interpreter
license:       MIT
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
category:      Web, Security

common warnings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions:
    BlockArguments
    DataKinds
    DeriveAnyClass
    DuplicateRecordFields
    LambdaCase
    OverloadedLabels
    OverloadedRecordDot
    OverloadedStrings

library
  import:          warnings, shared
  hs-source-dirs:  src
  exposed-modules: Shomei.WebAuthn.Ceremony
  build-depends:
    , aeson
    , base               >=4.18 && <5
    , base64-bytestring
    , bytestring
    , crypton            >=1.1.0
    , effectful
    , effectful-core
    , shomei-core
    , text
    , time
    , validation
    , webauthn

test-suite shomei-webauthn-test
  import:         warnings, shared
  type:           exitcode-stdio-1.0
  hs-source-dirs: test
  main-is:        Main.hs
  other-modules:  Shomei.WebAuthn.CeremonySpec
  build-depends:
    , aeson
    , base
    , bytestring
    , effectful
    , shomei-core
    , shomei-webauthn
    , tasty
    , tasty-hunit
    , text
    , webauthn
```

Implement `shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs`. The interpreter closes over a
`WebAuthnConfig`, derives the RP id hash and origins once, and uses `getCurrentTime` (via
`IOE`) and the library's randomness in begin. Skeleton (fill bodies):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary) where

import Shomei.Prelude
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import Data.Validation (Validation (Failure, Success))
import Crypto.Hash (hash)
import Data.Text.Encoding (encodeUtf8)
import qualified Crypto.WebAuthn as WA
import qualified Crypto.WebAuthn.Encoding.Internal.WebAuthnJson as WJI  -- for decode of options
import Control.Monad.Except (runExcept)

import Effectful (Eff, Effect, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret_)

import Shomei.Config (WebAuthnConfig (..), UserVerificationPolicy (..), AttestationPolicy (..))
import Shomei.Domain.Passkey
import Shomei.Effect.WebAuthnCeremony

runWebAuthnCeremonyLibrary :: (IOE :> es) => WebAuthnConfig -> Eff (WebAuthnCeremony : es) a -> Eff es a
runWebAuthnCeremonyLibrary cfg = interpret_ \case
    BeginRegistrationCeremony userInfo excludeIds -> liftIO (beginRegistration cfg userInfo excludeIds)
    CompleteRegistrationCeremony blob credJson    -> liftIO (completeRegistration cfg blob credJson)
    BeginAuthenticationCeremony allowIds          -> liftIO (beginAuthentication cfg allowIds)
    CompleteAuthenticationCeremony blob stored credJson ->
        liftIO (completeAuthentication cfg blob stored credJson)
```

The four IO helpers, with the library facts they rely on (all verified against the source):

- `beginRegistration cfg userInfo excludeIds`:
  - `challenge <- WA.generateChallenge`.
  - Build `WA.CredentialUserEntity{ cueId = toWAUserHandle userInfo.userHandle,
    cueDisplayName = WA.UserAccountDisplayName userInfo.displayName,
    cueName = WA.UserAccountName userInfo.accountName }` (the `userHandle` comes from EP-3's
    workflow; if a caller wants the library to mint one, the workflow calls `WA.generateUserHandle`
    upstream and passes it in `CredentialUserInfo` — EP-1 keeps `UserHandle` caller-supplied).
  - Build `opts :: WA.CredentialOptions 'WA.Registration` like `defaultPkcco` (reproduced
    below), but set `corRp = WA.CredentialRpEntity{ creId = Just (WA.RpId cfg.rpId), creName = cfg.rpName }`,
    `corChallenge = challenge`, `corExcludeCredentials = map mkDescriptor excludeIds`,
    `corAttestation = mapAttestation cfg.attestation`, and the authenticator-selection user
    verification from `mapUV cfg.userVerification`, and `corTimeout` from `cfg.ceremonyTimeout`
    (the library's `Timeout` is in milliseconds; convert the `NominalDiffTime` seconds × 1000).
  - `let wjOpts = WA.wjEncodeCredentialOptionsRegistration opts`.
  - `pure BeginCeremony{ optionsJson = Aeson.toJSON wjOpts, optionsBlob = LBS.toStrict (Aeson.encode wjOpts) }`.

- `completeRegistration cfg blob credJson`:
  - Recover options: `wjOpts <- either (… WebAuthnDecodeError) pure (Aeson.eitherDecodeStrict' blob)`,
    then `opts <- either (Left . WebAuthnDecodeError) Right (recoverRegOptions wjOpts)` where
    `recoverRegOptions` unwraps the WJ newtype to `WJI.PublicKeyCredentialCreationOptions` and
    runs `runExcept . WJI.decode`.
  - Decode the browser credential: `wjCred <- case Aeson.fromJSON credJson of Aeson.Success c -> Right c; Aeson.Error e -> Left (WebAuthnDecodeError (Text.pack e))`
    (the input type is the WJ credential newtype with `FromJSON`), then
    `cred <- either (Left . WebAuthnDecodeError) Right (WA.wjDecodeCredentialRegistration wjCred)`.
  - `now <- getCurrentTime`; convert to the library's `DateTime` (it uses `Data.Hourglass.DateTime`
    from `time-hourglass`; convert via `Time.System.dateCurrent` directly in IO instead of
    `getCurrentTime`+conversion — the example uses `dateCurrent`).
  - `case WA.verifyRegistrationResponse origins rpIdHash mempty now opts cred of` —
    `Failure errs -> Left (mapRegError (NE.head errs))`;
    `Success (WA.RegistrationResult entry _att) ->` build `VerifiedRegistration` from
    `WA.rrEntry`'s `CredentialEntry`: `credentialId = fromWACredId (WA.ceCredentialId entry)`,
    `userHandle = fromWAUserHandle (WA.ceUserHandle entry)`,
    `publicKey = fromWAPubKey (WA.cePublicKeyBytes entry)`,
    `signCounter = fromWACounter (WA.ceSignCounter entry)`,
    `transports = map WA.encodeAuthenticatorTransport (WA.ceTransports entry)`. Return `Right`.
  - `origins = WA.Origin <$> (NE.fromList cfg.origins)` and `rpIdHash = WA.RpIdHash (hash (encodeUtf8 cfg.rpId))`,
    `mempty :: WA.MetadataServiceRegistry` (consumer passkeys; MDS deferred per MasterPlan scope).

- `beginAuthentication cfg allowIds`:
  - `challenge <- WA.generateChallenge`.
  - `let opts = WA.CredentialOptionsAuthentication{ coaRpId = Just (WA.RpId cfg.rpId), coaTimeout = …,
    coaChallenge = challenge, coaAllowCredentials = map mkDescriptor allowIds,
    coaUserVerification = mapUV cfg.userVerification, coaHints = [], coaExtensions = Nothing }`.
    (`allowIds = []` means passwordless discovery; pass `[]` straight through.)
  - `let wjOpts = WA.wjEncodeCredentialOptionsAuthentication opts`; return
    `BeginCeremony{ optionsJson = Aeson.toJSON wjOpts, optionsBlob = LBS.toStrict (Aeson.encode wjOpts) }`.

- `completeAuthentication cfg blob stored credJson`:
  - Recover options from `blob` (the authentication WJ option type, decode via `WJI`).
  - Decode the credential via `WA.wjDecodeCredentialAuthentication` (same FromJSON path as above).
  - Build a `WA.CredentialEntry` from `stored`:
    `ceCredentialId = toWACredId stored.credentialId`, `ceUserHandle = toWAUserHandle stored.userHandle`,
    `cePublicKeyBytes = toWAPubKey stored.publicKey`, `ceSignCounter = toWACounter stored.signCounter`,
    `ceTransports = mapMaybe decodeTransport stored.transports` (use `WA.decodeAuthenticatorTransport`
    if present, else map known strings; an unknown string maps to `AuthenticatorTransportUnknown`).
  - `case WA.verifyAuthenticationResponse origins rpIdHash (Just (toWAUserHandle stored.userHandle)) entry opts cred of`
    `Failure errs -> Left (mapAuthError (NE.head errs))`;
    `Success (WA.AuthenticationResult counterResult) -> case counterResult of`
      `WA.SignatureCounterZero -> Right VerifiedAuthentication{ credentialId = stored.credentialId, newSignCounter = stored.signCounter, cloneWarning = False }`;
      `WA.SignatureCounterUpdated c -> Right VerifiedAuthentication{ credentialId = stored.credentialId, newSignCounter = fromWACounter c, cloneWarning = False }`;
      `WA.SignatureCounterPotentiallyCloned -> Left WebAuthnCounterCloned`  -- fail closed (Decision Log).

Error mapping (`mapRegError`/`mapAuthError`): pattern-match the library error constructors to
the closed `WebAuthnError` set. `RegistrationChallengeMismatch …`/`AuthenticationChallengeMismatch …`
→ `WebAuthnChallengeMismatch`; `*OriginMismatch …` → `WebAuthnOriginMismatch`;
`*RpIdHashMismatch …` → `WebAuthnRpIdMismatch`; `RegistrationUserNotPresent`/`AuthenticationUserNotPresent`
→ `WebAuthnUserNotPresent`; `*UserNotVerified` → `WebAuthnUserNotVerified`;
`AuthenticationSignatureInvalid _` → `WebAuthnSignatureInvalid`; everything else (attestation-format
errors, public-key algorithm disallowed, decode errors, user-handle mismatches) → `WebAuthnOtherError (Text.pack (show err))`.

Type-bridge helpers (`toWAUserHandle`/`fromWAUserHandle`/`toWACredId`/`fromWACredId`/`toWAPubKey`/
`fromWAPubKey`/`toWACounter`/`fromWACounter`) are one-line newtype (un)wrappers:
`WA.UserHandle` over `ByteString` ↔ `Shomei.Domain.Passkey.UserHandle`; `WA.CredentialId` over
`ByteString` ↔ `WebAuthnCredentialId`; `WA.PublicKeyBytes` over `ByteString` ↔ `PublicKeyBytes`;
`WA.SignatureCounter` over `Word32` ↔ `SignatureCounter`. (All the library newtypes are at
`src/Crypto/WebAuthn/Model/Types.hs` lines noted in this plan's facts.)

The example's `defaultPkcco` (reproduced so you need not open the source), to copy and adapt:

```haskell
defaultPkcco :: WA.CredentialUserEntity -> WA.Challenge -> WA.CredentialOptions 'WA.Registration
defaultPkcco userEntity challenge =
  WA.CredentialOptionsRegistration
    { WA.corRp = WA.CredentialRpEntity { WA.creId = Nothing, WA.creName = "ACME" }
    , WA.corUser = userEntity
    , WA.corChallenge = challenge
    , WA.corPubKeyCredParams =
        [ WA.CredentialParameters { WA.cpTyp = WA.CredentialTypePublicKey, WA.cpAlg = WA.CoseAlgorithmES256 }
        , WA.CredentialParameters { WA.cpTyp = WA.CredentialTypePublicKey, WA.cpAlg = WA.CoseAlgorithmRS256 }
        ]
    , WA.corTimeout = Nothing
    , WA.corExcludeCredentials = []
    , WA.corAuthenticatorSelection =
        Just WA.AuthenticatorSelectionCriteria
          { WA.ascAuthenticatorAttachment = Nothing
          , WA.ascResidentKey = WA.ResidentKeyRequirementDiscouraged
          , WA.ascUserVerification = WA.UserVerificationRequirementPreferred
          }
    , WA.corHints = []
    , WA.corAttestation = WA.AttestationConveyancePreferenceDirect
    , WA.corExtensions = Nothing
    }
```

`mapUV`: `UVRequired → WA.UserVerificationRequirementRequired`, `UVPreferred → …Preferred`,
`UVDiscouraged → …Discouraged`. `mapAttestation`: `AttestationNone → WA.AttestationConveyancePreferenceNone`,
`AttestationDirect → WA.AttestationConveyancePreferenceDirect`. The MasterPlan scope says the
interpreter defaults to no MDS (`mempty :: WA.MetadataServiceRegistry`) and is suitable for
consumer passkeys, so attestation defaults to `None` per `defaultWebAuthnConfig`.

Register the package:

- `cabal.project`: add `shomei-webauthn` to the `packages:` list (after `shomei-jwt`).
- `mori.dhall`: add a `Schema.Package::{…}` entry copying the `shomei-jwt` shape:
  `name = "shomei-webauthn"`, `type = Library`, `language = Haskell`, `path = Some "shomei-webauthn"`,
  `description = Some "WebAuthn (passkey) ceremony interpreter over tweag/webauthn"`,
  `dependencies = [ Schema.Dependency.ByName "shomei-core" ]`. Also add
  `"tweag/webauthn"` to the top-level `dependencies = [ … ]` list at the bottom of `mori.dhall`
  (alongside `"frasertweedale/hs-jose"`), so `mori` records the external dependency.

Wire the server (the M1 step-7 deferral lands here):

- `shomei-server/src/Shomei/Server/App.hs`: ensure `, WebAuthnCeremony` is in `type AppEffects`
  immediately after `Notifier` (add it now if M1 deferred it), add
  `import Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary)`, and insert
  `. runWebAuthnCeremonyLibrary env.envConfig.webauthnConfig` into the `runAppIO` composition at
  the position matching `Notifier` (i.e. adjacent to `runNotifierFromConfig env.envConfig` on the
  ports side, above `runDatabasePool`). Add `shomei-webauthn` to `shomei-server`'s
  `build-depends` in `shomei-server/shomei-server.cabal`. Add `shomei-webauthn` to
  `shomei-server`'s `mori.dhall` `dependencies` list too.

The package test `shomei-webauthn/test/Shomei/WebAuthn/CeremonySpec.hs` promotes the M0 harness:
it runs `runWebAuthnCeremonyLibrary defaultWebAuthnConfig` (with `rpId`/`origins` matching the
simulated authenticator's clientData), performs begin-registration, drives the simulated
authenticator (reuse whatever the M0 spike used: the library's test emulator or a recorded
fixture), calls complete-registration and asserts `Right VerifiedRegistration{…}`, then
begin-authentication + simulated assertion + complete-authentication asserting
`Right VerifiedAuthentication{…}`. It also asserts the `optionsBlob` returned by begin decodes
back to options that `verify*` accepts (the round-trip). Because driving a *real* COSE signature
in a unit test is involved, if the M0 fallback used recorded browser fixtures, the test pins
those fixtures under `shomei-webauthn/test/fixtures/` and the `rpId`/`origin`/challenge in
`defaultWebAuthnConfig`-for-the-test are set to match the fixtures.

Acceptance for M2:

```bash
nix develop --command cabal build all
nix develop --command cabal test all
nix develop --command mori show --full
```

`build all`/`test all` are green; the `shomei-webauthn-test` prints a passing
register→authenticate run; and `mori show --full` lists `shomei-webauthn` among the packages.
Expected `test` tail:

```text
shomei-webauthn> Shomei.WebAuthn.Ceremony
shomei-webauthn>   register then authenticate: OK
shomei-webauthn>   optionsBlob round-trips:    OK
shomei-webauthn> All 2 tests passed
```


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`.

Find the `shomei-postgres` test `AppEffects` and its runner (needed in M1 step 8):

```bash
grep -rn "AppEffects\|WebAuthnCeremony\|runInMemory\|runNotifier" shomei-postgres/test
```

Find the `shomei-core` test-suite stanza and an existing spec to copy (M1 step 9):

```bash
grep -n "test-suite\|other-modules\|main-is" shomei-core/shomei-core.cabal
ls shomei-core/test 2>/dev/null || grep -rn "hs-source-dirs" shomei-core/shomei-core.cabal
```

Confirm the webauthn library location and mori registration (M0):

```bash
mori registry show tweag/webauthn --full
ls /Users/shinzui/Keikaku/hub/haskell/webauthn-project/webauthn
```

Build just the dependency first (M0), then everything (M1/M2):

```bash
nix develop --command cabal build webauthn
nix develop --command cabal build all
nix develop --command cabal test all
```

Inspect the embedded effect-stack lists you must edit:

```bash
grep -rn "Notifier" \
  shomei-servant/src/Shomei/Servant/Seam.hs \
  shomei-server/src/Shomei/Server/App.hs \
  shomei-core/src/Shomei/Effect/InMemory.hs
```

After registering the package, confirm `mori` sees it:

```bash
nix develop --command mori show --full | grep -A2 shomei-webauthn
```


## Validation and Acceptance

The plan is done when all of the following hold and are demonstrated by the commands above:

1. `nix develop --command cabal build all` compiles every package including the new
   `shomei-webauthn`, with `WebAuthnCeremony` present and interpreted in every effect-stack
   (servant seam, server app, in-memory, postgres test). A missing list/runner shows up as a
   `WebAuthnCeremony :> es` instance error at build time.

2. `nix develop --command cabal test all` is green, including:
   - the new `shomei-core` spec that drives `runWebAuthnCeremonyFake` deterministically
     (begin→complete registration succeeds; begin→complete authentication bumps the counter to
     `SignatureCounter 1`; a wrong challenge yields `Left WebAuthnChallengeMismatch`); and
   - the new `shomei-webauthn` spec that runs a real register→authenticate ceremony through
     `runWebAuthnCeremonyLibrary` and asserts `Right VerifiedRegistration`/`Right
     VerifiedAuthentication` plus the `optionsBlob` round-trip.

3. The M0 spike printed `ceremony verified`, and the Decision Log `allow-newer` placeholder is
   filled with the exact `cabal.project` lines used (and any fork commit).

4. `nix develop --command mori show --full` lists `shomei-webauthn` with a `shomei-core`
   dependency.

5. The config loads: `defaultShomeiConfig` produces a `webauthnConfig` equal to
   `defaultWebAuthnConfig`, and a `ShomeiConfig` with a missing `webauthn_config` key in its
   Dhall/JSON still parses (the field defaults). If `shomei-core` has a config round-trip test,
   extend it; otherwise add a one-line assertion in the new core spec that
   `(defaultShomeiConfig iss aud).webauthnConfig == defaultWebAuthnConfig`.

Observable behavior beyond compilation: the `shomei-webauthn` test is the end-to-end proof that
a passkey can be registered and then used to authenticate, entirely server-side, through the
port the rest of MasterPlan 3 will call. The fake-interpreter test is the proof that downstream
plans can exercise the ceremony deterministically.


## Idempotence and Recovery

Every step is additive and safe to re-run. The `cabal.project` and `mori.dhall` edits are
append-only; re-running a build after a partial edit simply recompiles. If M0's build fails,
nothing in `shomei-*` has changed yet (only `cabal.project`'s new block), so you can iterate on
`allow-newer` freely or revert the block with no other cleanup. If M1's `build all` fails with a
missing-instance error, you missed one effect-stack list or runner — re-run the `grep` over the
four locations and add the missing entry; the change is local and reversible. The throwaway M0
harness is deleted (or promoted into the M2 test) and leaves no trace. Adding a `ceremonyCounter`
to `World` requires updating `emptyWorld`; if you forget, the build fails immediately (record
construction is total), so there is no silent drift.

If the library cannot be made to build on GHC 9.12.4 at all (worst case), stop at M0, record the
blocking solver/compiler error in the Decision Log and Surprises, and revise the MasterPlan
(`docs/masterplans/3-…`, whose Surprises already anticipates this) before doing any M1/M2 work —
M1 is safe to do regardless (it has no `webauthn` dependency), but M2 and the whole MasterPlan
depend on the library building, so a hard failure is a MasterPlan-level event.


## Interfaces and Dependencies

Libraries used and why:

- `effectful` / `effectful-core` — the effect system; the port is a dynamic effect and the
  interpreters use `interpret_`. Already a `shomei-core` dependency.
- `aeson` — the `Value` boundary and the options-blob JSON serialization. Already core.
- `base64-bytestring` — base64url encoding of the `ByteString` newtypes' JSON (core) and any
  fixture handling (test). Already in the project dependency set.
- `webauthn` (`tweag/webauthn`, `0.11.0.0`) — the real ceremony/verification library, used
  ONLY in `shomei-webauthn`. Pinned in `cabal.project` with `allow-newer` per M0.
- `crypton` (`>= 1.1.0`) — SHA-256 for the RP id hash in the interpreter. `shomei-webauthn` only.
- `validation` — the library's `verify*` returns `Validation`; the interpreter pattern-matches
  `Failure`/`Success`. `shomei-webauthn` only.
- `tasty`/`tasty-hunit` — the test harnesses, matching the rest of the repo's test style.

Types/interfaces that must exist at the end of each milestone:

- End of M0: `webauthn 0.11.0.0` resolves and builds under `nix develop` on GHC 9.12.4; the
  options-blob JSON serialization round-trips and feeds `verify*`.
- End of M1: in `shomei-core` — `Shomei.Id.{PasskeyId,CeremonyId,genPasskeyId,genCeremonyId,…ToUUID,…FromUUID}`;
  `Shomei.Domain.Passkey.{WebAuthnCredentialId,UserHandle,PublicKeyBytes,SignatureCounter,
  NewPasskeyCredential,PasskeyCredential,CeremonyKind,PendingCeremony}`;
  `Shomei.Effect.WebAuthnCeremony.{WebAuthnCeremony,WebAuthnError,CredentialUserInfo,
  BeginCeremony,StoredCredentialForVerify,VerifiedRegistration,VerifiedAuthentication,
  beginRegistrationCeremony,completeRegistrationCeremony,beginAuthenticationCeremony,
  completeAuthenticationCeremony}`;
  `Shomei.Config.{WebAuthnConfig,UserVerificationPolicy,AttestationPolicy,defaultWebAuthnConfig}`
  and the `webauthnConfig` field; `Shomei.Effect.InMemory.runWebAuthnCeremonyFake` and
  `WebAuthnCeremony` slotted (after `Notifier`) into `runInMemory`, the servant `AppEffects`, the
  server `AppEffects` (list entry; runner may land in M2), and the postgres-test `AppEffects`.
- End of M2: package `shomei-webauthn` exposing
  `Shomei.WebAuthn.Ceremony.runWebAuthnCeremonyLibrary :: (IOE :> es) => WebAuthnConfig -> Eff (WebAuthnCeremony : es) a -> Eff es a`;
  registered in `cabal.project` + `mori.dhall`; interpreted in `Shomei.Server.App.runAppIO` via
  `runWebAuthnCeremonyLibrary env.envConfig.webauthnConfig`.

Boundary rule (from MasterPlan IP-1/IP-6): EP-1 owns the `WebAuthnCeremony` signatures, the
domain types, and the `webauthnConfig` shape. EP-2 will insert `PasskeyStore` and
`PendingCeremonyStore` into each effect-stack list **right after `LoginAttemptStore`** (before
`Notifier`/`WebAuthnCeremony`); EP-1 must leave the relative ordering consistent so EP-2's
insertion does not disturb `WebAuthnCeremony`'s position. EP-3/EP-4 consume the port and must
not change its signatures without a Decision Log entry here and in the MasterPlan.
