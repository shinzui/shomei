---
title: "JWT access tokens with a published JWKS"
type: Capability
description: "Mint ES256 or RS256 access tokens carrying identity, roles, scopes, permissions, and arbitrary custom claims, and let any service verify them offline against a published JWKS document."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-4
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-jwt
  - shomei-core
interface:
  - Shomei.SigningKey.Sign.Jwt
  - Shomei.SigningKey.Verify.Jwt
  - Shomei.SigningKey.Jwks.Jwt
  - Shomei.Authorization.Claims.Domain
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shomei-jwt/test/Shomei/SigningKey/Sign/JwtSpec.hs
    proves: Signing and verification round-trip for the standard claim set, and what a tampered or expired token does.
  - kind: test
    resource: shomei-jwt/test/Shomei/SigningKey/Sign/RsaCustomClaimSpec.hs
    proves: RS256 is selected explicitly (never the PSS variant) and custom top-level claims survive sign/verify.
  - kind: test
    resource: shomei-jwt/test/Shomei/SigningKey/Jwks/JwtSpec.hs
    proves: The JWKS document publishes exactly the keys a verifier is meant to trust.
  - kind: example
    resource: examples/microservice-auth-stack/test/Main.hs
    proves: A downstream service verifying Shomei tokens offline against a fetched, TTL-cached JWKS — including single-flight cold start, refresh-ahead, stale-on-error, and failing closed past max staleness.
  - kind: guide
    resource: docs/user/security.md
    proves: The claim set, the reserved-claim guard, and how a verifier is expected to behave.
---

# JWT access tokens with a published JWKS

**Builds on:** [CAP-1 — transport-agnostic authentication core](transport-agnostic-auth-core.md).

Access tokens are ordinary JWTs, **ES256** (ECDSA P-256) by default or **RS256** by
configuration, signed by the active key and verifiable by anyone who can fetch
`GET /.well-known/jwks.json`. No shared secret, no call back to Shōmei on the hot path.

The claim set is `sub`, `iss`, `aud`, `iat`, `exp`, `sid`, `roles`, `scopes`, `permissions`, and
`act` when the token is delegated. `AuthClaims.extraClaims` lets an embedding host attach
arbitrary top-level JSON claims; the reserved names cannot be forged through that bag. An
ordinary token with an empty `extraClaims` is byte-for-byte what it was before the bag existed.

Downstream verification is the intended integration for services that are not Haskell too: the
JWKS document is served with `Cache-Control: public, max-age=300`, and key rotation is staged so
a retiring key stays trusted far longer than any cache lifetime
([CAP-5](signing-key-rotation-and-encryption.md)).

`examples/microservice-auth-stack` is a runnable downstream service built on this: it fetches the
JWKS once, caches it, refreshes ahead of expiry, keeps serving from a stale copy when the auth
service is down, and fails closed (`503`) once the copy is too old to trust.

## Limits

- Verification is **stateless**. A token stays valid until `exp` unless the deployment opts into
  the per-request session check ([CAP-3](session-refresh-rotation.md)). Roles and permissions are
  likewise a snapshot taken at mint time: a role change bites at the next login or refresh.
- The JWKS caching, single-flight, and stale-on-error behavior lives in the **example**, not in a
  shipped package. A consumer adopting that pattern copies it; there is no `shomei-verify`
  library to depend on.
- Only ES256 and RS256 are offered. RS256 is pinned to RSASSA-PKCS1-v1_5 explicitly, because
  `jose` would otherwise prefer PSS for an RSA key.
- Tokens are not encrypted (JWS, not JWE). Every claim is readable by anyone holding the token.
