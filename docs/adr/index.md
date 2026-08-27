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
- [Runtime configuration is open strict and synchronized](0008-runtime-configuration-is-open-strict-and-synchronized.md) - Dhall record completion keeps partial files evolvable while unknown keys fail closed and a test keeps the schema equal to the loader.
- [Transport exception text is never persisted](0009-transport-exception-text-is-never-persisted.md) - Outbound transports map failures to a closed reason vocabulary before logging or persistence because dependency exceptions may contain secret payloads and URLs.
- [Notification delivery is a bounded background responsibility](0010-notification-delivery-is-a-bounded-background-responsibility.md) - The standalone server separates notification delivery from request latency with a bounded in-memory queue, one supervised worker, explicit overflow, and a timed shutdown drain.
- [Runtime secrets stay outside printable configuration](0011-runtime-secrets-stay-outside-printable-configuration.md) - SMTP and webhook credentials are non-printable runtime values carried beside ShomeiConfig, with secure transport posture enforced at boot.
- [Webhook signatures bind a bounded attempt time](0012-webhook-signatures-bind-a-bounded-attempt-time.md) - Each notification webhook attempt signs its Unix timestamp together with the exact body so receivers can enforce a bounded replay window.
- [Credential values and submitted identifiers do not cross diagnostic boundaries](0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) - Secret-bearing token values are non-serializable and redacted, while failed-login audit data retains only a hashed account key and resolved user identity.
- [Administrative bootstrap shares the deployment authentication policy](0014-administrative-bootstrap-shares-the-deployment-authentication-policy.md) - Bootstrap users enter passwords outside argv and pass through the same configured validation and breach checks as HTTP signups.
- [Forwarded client identity requires an explicit trusted proxy](0015-forwarded-client-identity-requires-an-explicit-trusted-proxy.md) - Shomei trusts forwarded client addresses only from configured proxy CIDRs and selects the rightmost untrusted X-Forwarded-For hop.
- [Secure transport cookies use browser-enforced name prefixes](0016-cookie-name-prefixes.md) - Shomei uses __Host- for its secure session cookie and __Secure- for its path-scoped secure refresh cookie, with bare names only when Secure is disabled.
