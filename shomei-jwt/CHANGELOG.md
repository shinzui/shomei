# Changelog for shomei-jwt

All notable changes to `shomei-jwt` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

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
