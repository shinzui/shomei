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
- [Every credential proof participates in one abuse budget](0005-every-credential-proof-participates-in-one-abuse-budget.md) - Password, second-factor, passkey, password-change, and TOTP-removal proofs share one account lockout and the API-derived edge throttle.
- [Authentication freshness is based on credential proof time](0006-authentication-freshness-is-based-on-credential-proof-time.md) - Sessions persist the last credential-proof instant as auth_time, refresh preserves it, and sensitive gates never use token issue time as proof.
- [Security state transitions are atomic at the persistence boundary](0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) - Single-use and monotonic transitions use conditional writes, while read-modify-write serialization uses transaction-scoped advisory locks.
