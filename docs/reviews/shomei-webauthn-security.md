---
type: Review
title: shomei-webauthn ceremony interpreter and the pinned webauthn fork
description: >-
  The interpreter delegates origin, rpId, challenge, counter, and signature checks to
  tweag/webauthn correctly and the fork's patch is confined to jose 0.13 header types, but
  the passwordless flow inherits the step-up's "preferred" user-verification policy, so a
  stolen PIN-less key is a full login, an empty origins list crashes every completion, and no
  real cryptographic ceremony is tested — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-4
subject: mori://shinzui/shomei/packages/shomei-webauthn
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - correctness
  - test-coverage
  - documentation
context: >-
  One reader agent read Shomei.WebAuthn.Ceremony and its spec, the Passkey ceremony port in
  shomei-core, the MFA and passkey workflows that call it, and the pinned shinzui/webauthn
  checkout under dist-newstyle (Operation/Authentication.hs, Operation/Registration.hs,
  Model/Types.hs) diffed against the upstream tweag/webauthn mirror in the mori corpus to
  establish the fork's patch scope. The three-case shomei-webauthn suite passed at the
  commit; it does not exercise a cryptographic ceremony.
---

# shomei-webauthn ceremony interpreter and the pinned webauthn fork

## Verdict

Changes requested. The interpreter is a thin, correct adapter: origins and the rpId hash come
from configuration (`src/Shomei/WebAuthn/Ceremony.hs:216-220`), the library verifies challenge,
origin membership, rpId hash, user presence, user verification when required, and the signature
over `authData || SHA256(clientDataJSON)`; the challenge is 16 random bytes; only ES256 and
RS256 are requested and enforced at registration; counter regressions map to
`WebAuthnCounterCloned`, which the workflow fails closed. The fork pinned in `cabal.project`
differs from upstream in exactly two source files (jose 0.13 `RequiredProtection` header types
in the SafetyNet and metadata modules) plus a `memory → ram` cabal change; the verification
modules are byte-identical to upstream master as mirrored on 2026-06-17, and upstream has since
changed only build infrastructure. The findings are about policy, not primitives.

## Findings

**1. Medium — passwordless login accepts assertions without user verification under the
default policy.** Both the MFA step-up and the passwordless begin call
`beginAuthenticationCeremony`, which sets `coaUserVerification` from the single
`userVerification` setting (`Ceremony.hs:132`), whose default is `preferred`
(`shomei-core/src/Shomei/Config.hs:412`). tweag/webauthn enforces UV only for `Required`
(`Operation/Authentication.hs:345-346`: `(Preferred, False) -> pure ()`). So under defaults a
roaming key enrolled without a PIN, once stolen, mints a full token pair through
`/v1/auth/login/passkey/*` with no password and no second challenge — exactly the flow
`passkeys.md` describes as "the passkey is the strong factor". Remedy: force `Required` for the
passwordless begin (a per-flow argument to `beginAuthenticationCeremony` or a separate
`passwordlessUserVerification` setting defaulting to required); document that `preferred` is a
second-factor-only posture.

**2. Low — an empty `origins` list crashes every ceremony completion.** `originsOf` is
`NE.fromList` (`Ceremony.hs:216-217`); the env loader drops blank entries so
`SHOMEI_WEBAUTHN_ORIGINS=","` becomes `[]`, and a Dhall `webauthnOrigins = []` is accepted as
is. Misconfiguration surfaces as a `500` at `register/complete` rather than a boot error.

**3. Low — `attestation = direct` yields no trust decision.** The MDS registry passed to
`verifyRegistrationResponse` is `mempty` and `rrAttestationStatement` is discarded
(`Ceremony.hs:147-149`); the attestation format's signature is checked but
`Verified`/`Unverified` is never consulted, so the setting changes only what the browser is asked
to convey. The module header says this is deferred; `passkeys.md` does not say `direct` is inert.

**4. Info — documentation.** `passkeys.md:129` says the browser refuses ceremonies whose origin
is not in `origins`; the allow-list is enforced server-side (`Authentication.hs:311-313`,
`Registration.hs:411-413`) — the browser enforces rpId scoping. `security.md:277-279` says a
counter that "does not advance past the stored value" fails closed; the (stored 0, returned 0)
case is accepted per the specification (`Authentication.hs:390-391`; `Ceremony.hs:171`).

**5. Info — test coverage.** `CeremonySpec.hs:16-20` states that it covers begin-blob round
trips and a garbage credential only. No test performs a real register or assert ceremony, so
the origin, rpId, UV, counter, and signature behaviors this record attributes to the library
are attested by reading the library, not by a test in this repository.

## Verified holds

- Origin and rpId from config; SHA-256 of `rpId` (`Ceremony.hs:216-222`).
- Challenge = 16 bytes from `MonadRandom` (`Model/Types.hs:713-714`); `Origin`/`RpId` compared as
  exact `Text` (`:581-583, 777-779`).
- Verification steps at `Operation/Authentication.hs:198-402` and
  `Operation/Registration.hs:345-511`, both unchanged from upstream.
- Counter semantics: (0,0) accepted unchanged, increase updates, otherwise
  `SignatureCounterPotentiallyCloned` → `Left WebAuthnCounterCloned` → `failMfa`
  (`Ceremony.hs:170-175`; `shomei-core/src/Shomei/Mfa/Workflow.hs:339-344`).
- Credential → user binding: MFA step-up looks the passkey up by credential id and requires
  `pkUid == uid` on top of the library's `allowCredentials` check; passwordless derives the user
  from the credential row and the library enforces `userHandle == owner` when present
  (`Authentication.hs:261-267`); registration takes the user handle from the server-side options
  blob (`Registration.hs:504`).
- Algorithms: ES256 and RS256 only requested (`Ceremony.hs:103-106`) and enforced
  (`Registration.hs:464-468`); crypton's ECDSA verify range-checks `r` and `s`.
- Fork scope: `diff -r` against upstream shows only `AttestationStatementFormat/AndroidSafetyNet.hs`,
  `Metadata/Service/Processing.hs`, and `webauthn.cabal` changed; Hackage's latest remains
  0.11.0.0 (2025-06-05) with no pending upstream security fix.

## Not examined

`Encoding/WebAuthnJson` decoding (clientData `type` check, base64url), COSE public-key parsing,
the RSA verify path, every attestation format other than `none`, and the Metadata modules of
the library; the pending-ceremony store's consume-once semantics (REV-5).
