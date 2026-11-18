---
type: Improvement Request
title: Admit base64 2.0 in shomei-core
description: Widen shomei-core's base64 bound so consumers whose cohort already resolves base64 2.0 through tls can depend on shomei-core and shomei-jwt without an allow-newer.
timestamp: "2026-11-17T20:30:00Z"
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-11-17T20:30:00Z"
requestId: IR-5
status: completed
completedAt: "2026-11-17T23:30:00Z"
resolution: "Released as v0.3.0.1 from release/0.3: shomei-core, shomei-servant, shomei-server and shomei-client 0.3.0.1 on Hackage admit base64 >=1.0 && <2.2. A Hackage-only consumer solve with base64 ==2.0, tls and shomei-jwt 0.3.0.0 needs no allow-newer."
origin: mori://shinzui/rei/plans/292-verify-shomei-tokens-and-resolve-meibo-principals-on-rei-api-requests
---

# Improvement Request: Admit base64 2.0 in shomei-core

- **Status:** completed
- **Origin:** Rei ExecPlan 292, Milestone 1
  (`mori://shinzui/rei/plans/292-verify-shomei-tokens-and-resolve-meibo-principals-on-rei-api-requests`),
  under `mori://shinzui/rei/masterplans/32-ren-core-member-spaces-and-collaborative-notes`.
- **Size:** a bound change and a patch release.

## Problem

Rei wants to verify Shomei access tokens with `Shomei.SigningKey.Verify.Jwt.verifyTokenWith`
from `shomei-jwt` 0.3.0.0. Rei's frozen cohort (the `rei-keiro-0.24` profile of
`mori://shinzui/haskell-nix`) resolves `base64 ==2.0`, because `tls` depends on
`crypton-x509-validation`, which depends on `crypton-pem`, which requires base64 2.0. Every
consumer that makes outbound TLS calls has the same constraint.

`shomei-core` 0.3.0.0 (and HEAD `8ea001c`) declares `base64 >=1.0 && <1.1`, so the solver
rejects it:

```text
[__8] rejecting: shomei-core-0.3.0.0 (conflict: crypton-pem => base64==2.0, shomei-core => base64>=1.0 && <1.1)
```

## Evidence that the bound is stale

With a temporary `allow-newer: shomei-core:base64` in Rei's working tree, `shomei-core` and
`shomei-jwt` 0.3.0.0 (tag `v0.3.0.0`, `2b78861`) compile against base64 2.0 on GHC 9.12.4
with no source change. The only base64 use in `shomei-core` is `Shomei.Passkey.Domain`
(`extractBase64`, `encodeBase64Unpadded`, `decodeBase64UnpaddedUntyped`). Shomei's own
passkey tests have not been run against base64 2.0; that is the check this request asks for.

## Requested change

1. Widen `shomei-core`'s bound to `base64 >=1.0 && <2.1` (and any other Shomei package that
   declares base64) and run the passkey round-trip tests against base64 2.0.
2. Release a patch version (for example `shomei-core` 0.3.0.1) so consumers can pin a tag
   rather than carry an `allow-newer`.

## Acceptance

A consumer whose plan contains `base64-2.0` resolves `shomei-core` and `shomei-jwt` from the
released tag without any `allow-newer` entry, and Shomei's passkey tests pass on base64 2.0.

## Implementation

- Hackage now also carries base64 2.1, so the widened bound is `base64 >=1.0 && <2.2` rather
  than `<2.1`. Neither 2.0 nor 2.1 changes a function Shomei uses: 2.0 removes `isBase64` and
  `isValidBase64`, and 2.1 removes `isBase64Url` and `isValidBase64Url`. The encode and
  `decode*Untyped` functions keep their signatures and behavior.
- The four packages that declare base64 (`shomei-core`, `shomei-client`, `shomei-servant`,
  `shomei-server`) all take the widened bound. `shomei-jwt` uses `base64-bytestring` and
  `memory`, not `base64`.
- Master and the 0.3 patch build against base64 2.0 and 2.1 on GHC 9.12.4. Every test suite
  passes, including `shomei-core-test` (passkey codec and ceremony specs), `shomei-webauthn-test`
  and the `shomei-server-test` end-to-end suite.
- The patch release is `v0.3.0.1` on the `release/0.3` branch, cut from `v0.3.0.0`. It
  carries only this bound change, because master holds unreleased breaking `shomei-core`
  changes. `shomei-core`, `shomei-servant`, `shomei-server` and `shomei-client` move to
  0.3.0.1; the other packages stay at their v0.3.0.0 versions. All four are published
  on Hackage with Haddocks, and the GitHub release is
  `https://github.com/shinzui/shomei/releases/tag/v0.3.0.1`.
- Acceptance: a fresh Hackage-only consumer that depends on `shomei-core ==0.3.0.1`,
  `shomei-jwt ==0.3.0.0`, `tls` and `base64 ==2.0` solves without any `allow-newer`. The plan
  includes `crypton-pem` 0.3.0 and `tls` 2.4.6.
