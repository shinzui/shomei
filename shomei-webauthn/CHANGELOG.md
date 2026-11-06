# Changelog for shomei-webauthn

All notable changes to `shomei-webauthn` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## 0.3.0.0 — 2026-11-05

- **Breaking:** internal dependency bounds follow the 0.3 API series.
- First Hackage publication; earlier version sections describe repository development milestones.
- Require released [`webauthn >=0.12 && <0.13`](mori://tweag/webauthn/packages/webauthn); the compatible upstream release replaces the development fork.
- The workspace permits `time` 1.14 through a version-scoped `allow-newer` override; this project setting is not part of the published package's dependency metadata.

- **Breaking:** remove `VerifiedAuthentication.cloneWarning`; cloned/regressed counters return `WebAuthnCounterCloned` through the MFA failure/audit path.
- Add deterministic signed ES256 registration/assertion wire fixtures and real-verifier workflow tests.
- Document that direct attestation requests evidence without enforcing device trust (ADR-25).

## 0.2.0.0 — 2026-08-27

Not yet published to Hackage: the library depends on a fork of `webauthn`
that builds against GHC 9.12.4, `crypton >= 1.1`, and `jose 0.13`. Upstream
`webauthn` 0.11.0.0 constrains `base < 4.20` and `jose < 0.12`. This package
ships once a compatible `webauthn` is on Hackage.

Initial release contents:

- Empty WebAuthn origin sets fail closed with a typed ceremony error instead of calling the partial
  `NonEmpty.fromList` constructor.
- Interprets Shōmei's passkey ceremony port with the `webauthn` library:
  challenge generation, attestation and assertion verification, origin and
  relying-party checks, and signature-counter handling.
- Backs passkey enrollment, passwordless login, and password-then-passkey
  step-up.
