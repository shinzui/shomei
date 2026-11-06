# Changelog for shomei-client

All notable changes to `shomei-client` are documented here. This package adheres to the
[PVP](https://pvp.haskell.org/) and is versioned independently of the other
Shōmei packages.

## 0.3.0.0 — 2026-11-05

- **Breaking:** internal dependency bounds follow the 0.3 API series; migration dependencies require `shomei-migrations ^>=0.2.0.1`.
- First Hackage publication; earlier version sections describe repository development milestones.

- **Breaking:** `adminListSessions` takes optional limit/cursor parameters and returns the bounded session page.

## 0.2.0.0 — 2026-08-27

Not yet published to Hackage: the library itself resolves cleanly, but its
test-suite depends on `shomei-server`, which is blocked on a Hackage release
of `webauthn` compatible with GHC 9.12.4 and `jose 0.13`. This package ships
alongside `shomei-server`.

Initial release contents:

- Bearer `Token` values render as `Token <redacted>` so assertion failures and diagnostic output
  cannot disclose the credential.
- A typed Haskell client derived from the same `ShomeiAPI` definition that
  `shomei-servant` serves, so client and server cannot drift apart.
- Connection management and token handling for calling a standalone
  `shomei-server` from another service.
