# Changelog for shomei-webauthn

All notable changes to `shomei-webauthn` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## Unreleased

Not yet published to Hackage: the library depends on a fork of `webauthn`
that builds against GHC 9.12.4, `crypton >= 1.1`, and `jose 0.13`. Upstream
`webauthn` 0.11.0.0 constrains `base < 4.20` and `jose < 0.12`. This package
ships once a compatible `webauthn` is on Hackage.

Initial release contents:

- Interprets Shōmei's passkey ceremony port with the `webauthn` library:
  challenge generation, attestation and assertion verification, origin and
  relying-party checks, and signature-counter handling.
- Backs passkey enrollment, passwordless login, and password-then-passkey
  step-up.
