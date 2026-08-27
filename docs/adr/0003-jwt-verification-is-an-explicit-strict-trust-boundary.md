---
type: Architecture Decision Record
title: JWT verification is an explicit strict trust boundary
description: Shōmei pins algorithms, selects one key by kid, validates token type and claim shapes, and applies bounded clock skew.
docId: ADR-3
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T17:02:48Z
originatingPlan: docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T17:02:48Z
---

# JWT verification is an explicit strict trust boundary

## Context

Shōmei issues access tokens for offline verification against a rotating JWKS. A verifier that
falls back across keys, accepts shapes the issuer never emits, or relies on algorithm inference
turns representational flexibility into attack surface and makes failed verification more
expensive as the key set grows.

The `jose` dependency ([package](mori://frasertweedale/hs-jose/packages/jose)) provides safe
cryptographic primitives, but its generic verification and claim types support more policies than
Shōmei intends. The application must therefore state its own accepted algorithms, key-selection
rule, claim shapes, token type, and clock tolerance.

## Decision

The verifier accepts only ES256 and RS256. The protected `kid` header selects exactly one key; an
unknown or absent `kid` is `TokenKeyNotFound` and never causes trial verification against other
keys. An access token's `typ`, when present, must be `at+jwt` or `application/at+jwt`, compared
case-insensitively. Shōmei emits `typ: at+jwt` now; absence remains temporarily compatible behind
`VerifierSettings.requireTokenType = False`.

Issuer and audience must equal the configured values, and `aud` must contain exactly one value.
The `roles`, `scopes`, and `permissions` claims must be arrays when present; malformed values are
not treated as empty. Registered and Shōmei-owned claims, including `nbf` and `jti`, cannot enter
through `extraClaims`.

Numeric dates are emitted at whole-second precision. Verification applies one bounded
`allowedClockSkewSeconds` value, default 30 seconds, to `exp`, `nbf`, and `iat`. Issuer and audience
are validated as RFC 7519 StringOrURI values at process boot so the signer never reaches `jose`'s
partial string conversion with malformed input.

## Consequences

Verification cost is independent of the number of published keys, and a token cannot choose an
unapproved algorithm or exploit a permissive claim representation. Failures remain the existing
wire-level `401 token_invalid`; the more precise `TokenKeyNotFound` distinction is internal and
allows a later JWKS-refresh policy to distinguish an unknown key from a bad signature.

Thirty seconds of skew tolerates ordinary clock drift but widens both ends of the validity window.
Operators that require exact comparisons can configure zero. Flipping `requireTokenType` to true
is deferred until typ-less access tokens from older issuers have aged out across a coordinated
upgrade.

## Alternatives rejected

Trying every key when `kid` is absent or unknown was rejected because Shōmei always emits a key ID
and the fallback makes unauthenticated work grow with the JWKS. Accepting any algorithm compatible
with key material was rejected because the service supports exactly two configured algorithms.

Treating malformed list claims as empty or accepting any audience containing the configured value
was rejected because those shapes are not emitted by Shōmei and silently discard security-relevant
input. Disabling issued-at validation was rejected; bounded skew fixes clock drift without losing
the check.
