---
title: "Passkey enrollment, step-up MFA, and passwordless login"
type: Capability
description: "Enroll WebAuthn passkeys against a user, require one as a second factor after a password, or log in with a passkey alone - with a runnable browser demo of all three ceremonies."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-16
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-webauthn
  - shomei-core
  - shomei-postgres
interface:
  - Shomei.WebAuthn.Ceremony
  - Shomei.Passkey.Workflow
  - Shomei.Passkey.Ceremony.Port
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shomei-webauthn/test/Shomei/WebAuthn/CeremonySpec.hs
    proves: The registration and authentication ceremonies over the tweag/webauthn interpreter, including passwordless UV-required policy even when step-up discourages verification.
  - kind: test
    resource: shomei-core/test/Shomei/Passkey/WorkflowSpec.hs
    proves: Enrollment, listing, deletion, the step-up path, and the passwordless path over the in-memory world.
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: Passkey rows persist and are found by user, credential id, and user handle; the sign counter updates; deletion is user-scoped; a pending ceremony is consumed exactly once and an expired one is not returned.
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: Passkey CRUD, MFA step-up, and passwordless login end to end over HTTP.
  - kind: example
    resource: examples/embedded-servant-app/www
    proves: A runnable browser page driving all three real ceremonies against a live server.
  - kind: guide
    resource: docs/user/passkeys.md
    proves: The ceremonies, the webauthnConfig settings, the security properties, and the rpId/origin operator caveat.
---

# Passkey enrollment, step-up MFA, and passwordless login

**Builds on:** [CAP-2 — password account lifecycle](password-account-lifecycle.md).

Three ceremonies, all built on `tweag/webauthn` behind a `WebAuthnCeremony` port:

1. **Enroll** — an authenticated user registers a passkey
   (`/v1/auth/passkeys/register/{begin,complete}`), lists them, and deletes them.
2. **Step-up** — a password login for a user who has a passkey answers `mfa_required` with the
   available methods; the client completes at `/v1/auth/mfa/complete`.
3. **Passwordless** — `/v1/auth/login/passkey/{begin,complete}` authenticates with the passkey
   alone and always requires the authenticator's local user verification (PIN, biometric, or
   equivalent), regardless of the configurable step-up policy.

The pending-ceremony challenge is server-side state consumed exactly once and expiring on its own,
so a challenge cannot be replayed. The user handle is derived from the user id, never from the
email, so it survives an email change.

`examples/embedded-servant-app/www/` is a complete enroll-and-step-up page that drives the real
ceremonies against a live server, served from the same warp process so its origin matches the
default `origins` with no extra configuration.

## Limits

- **`rpId` and `origins` must match your real domain.** A passkey is bound to the relying-party
  id at enrollment; changing `rpId` later invalidates every enrolled passkey. The defaults are
  localhost values for the demo and are wrong for any deployment.
- Losing every passkey is recovered through the password path — passkeys are an added factor, not
  a replacement for account recovery. A user with no password and no remaining passkey has no
  recovery path Shōmei can offer.
- Attestation is not verified against a metadata service; Shōmei does not restrict which
  authenticators are acceptable.
- The demo page loads `@github/webauthn-json` from a CDN and is a demo, not a shipped client
  library. There is no packaged browser SDK.
- The sign counter is stored and updated, but a counter regression is not by itself treated as a
  cloned-authenticator alarm.
