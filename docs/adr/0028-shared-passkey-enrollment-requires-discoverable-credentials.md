---
type: Architecture Decision Record
title: Shared passkey enrollment requires discoverable credentials
description: New passkeys require discoverability independently of user verification so the shared enrollment supports username-free passwordless login.
docId: ADR-28
status: Accepted
date: 2026-11-16
timestamp: 2026-11-16T15:55:00Z
originatingPlan: docs/plans/74-require-discoverable-credentials-for-passwordless-passkey-login.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-16T15:55:00Z
---

# Shared passkey enrollment requires discoverable credentials

## Context

The built-in WebAuthn interpreter serves one enrollment workflow for both password step-up
and passwordless login. Passwordless begin has no account and supplies no credential IDs;
the authenticator must discover the credential. Requesting discouraged residency permitted
credentials that worked for known-account step-up but could not support this login path.
User verification (UV), the local PIN or biometric check, does not establish discoverability.

## Decision

Require discoverable credentials for every new enrollment through the built-in interpreter.
Set the library's resident-key requirement to required and let its encoder emit both
`residentKey: "required"` and the legacy `requireResidentKey: true`. Preserve the configured
UV preference for enrollment and step-up, and mandatory UV for passwordless login. Keep
passwordless begin free of account lookup and credential restrictions.

This is a browser creation requirement, not a server-verifiable claim about credential storage.
Preserve the verifier contract and stored credentials: no migration, deletion, retroactive
rejection of pending options, or mandatory credential-properties extension is introduced.
The attestation and verification boundaries in
[ADR-25](0025-attestation-conveyance-does-not-establish-device-trust.md) continue to apply.

## Consequences

Authenticators without resident-key support fail new enrollment. Existing non-discoverable
credentials remain available to known-account step-up, but need replacement enrollment for
passwordless use; a server upgrade cannot convert them. Users must sign in with a usable
factor, enroll and verify a replacement before removing the old credential, and respect the
atomic quota in [ADR-21](0021-passkey-enrollment-spends-an-atomic-account-quota.md).
Password reset does not bypass MFA. Encoded browser and persisted options, signed workflow
tests, and browser authenticator checks must protect this contract.

## Alternatives rejected

Preferred residency permits non-discoverable fallback and retains the failure. A standalone
residency setting permits configurations incompatible with the always-available passwordless
flow. A separate step-up-only deployment mode needs its own design. JSON patching duplicates
the dependency's encoder, weakening UV changes an independent security property, and account
lookup at passwordless begin changes the login contract.
