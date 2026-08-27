---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Architecture Decision Record

- [Sessions carry their provenance and only an interactive session may authorize a client](0001-only-an-interactive-session-may-authorize-a-client.md) - Every session records whether a human established it, and OAuth authorization codes are minted only for live interactive sessions.
- [Reserved privilege scopes are service-account authority and never OAuth-client grants](0002-reserved-privilege-scopes-are-service-account-authority.md) - Shōmei refuses its three privilege-gate scopes on OAuth clients while allowing service accounts to hold them as their own authority.
- [JWT verification is an explicit strict trust boundary](0003-jwt-verification-is-an-explicit-strict-trust-boundary.md) - Shōmei pins algorithms, selects one key by kid, validates token type and claim shapes, and applies bounded clock skew.
- [One active signing key is a database invariant](0004-one-active-signing-key-is-a-database-invariant.md) - PostgreSQL enforces one active signing key, and every replacement retires and activates atomically while retaining retired overlap keys.
