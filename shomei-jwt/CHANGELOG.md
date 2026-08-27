# Changelog for shomei-jwt

All notable changes to `shomei-jwt` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

- **Breaking:** `toStoredSigningKey` and `toStoredSigningKeyFor` now return `Either Text
  StoredSigningKey` and refuse keys without a public projection; generated and published JWKs
  explicitly carry their signing `alg`.
- Verification is pinned to ES256/RS256 and selects exactly by `kid`; missing and unknown key IDs,
  malformed list claims, multi-valued audiences, and access-token `typ` mismatches are rejected.
- JWT numeric dates are emitted at whole-second precision, access tokens carry `typ: at+jwt`, and
  configurable clock skew applies to `exp`, `nbf`, and `iat`.
- Key rotation uses the store's atomic active-key replacement operation and keeps retired overlap
  keys trusted while immediately excluding revoked keys.

## 0.1.0.0 — 2026-08-24

Initial release. Interprets Shōmei's signing-key effects with `jose`.

- ES256 and RS256 access-token signing and verification, and OpenID Connect
  ID tokens. RSA signing is pinned to RS256 rather than PSS.
- JWKS publishing over the full publishable key set, with hot reload, so
  relying services can verify tokens offline.
- Key rotation with an overlap window: a retired key keeps verifying
  outstanding tokens until they expire.
- Envelope encryption for signing keys at rest, with decrypt-at-load and
  rewrap.
- An extensible custom-claims bag on `AuthClaims`, plus the `act` actor
  claim for delegated tokens and the reserved `permissions` claim.
