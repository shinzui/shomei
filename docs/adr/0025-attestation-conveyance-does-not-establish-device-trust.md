---
type: Architecture Decision Record
title: Attestation conveyance does not establish device trust
description: WebAuthn direct attestation requests evidence without imposing an authenticator trust policy or device allow-list.
docId: ADR-25
status: Accepted
date: 2026-11-05
timestamp: 2026-11-05T16:50:41Z
originatingPlan: docs/plans/66-prove-webauthn-ceremonies-and-document-attestation-trust.md
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-05T16:50:41Z
---

# Attestation conveyance does not establish device trust

## Context

The WebAuthn adapter requests either none or direct attestation. It passes an empty Metadata
Service registry to registration verification and keeps the credential entry, without enforcing
the returned attestation trust verdict. Describing direct as trusted-device enforcement would
promise a security property that the application does not implement.

## Decision

Keep none as the default. Direct requests attestation evidence and preserves the library's
response/format checks, but does not require a trusted device, vendor or hardware authenticator.
Document the boundary at the configuration surface and ceremony implementation. An MDS service,
trust anchors, allow-list and enforcement policy are a separate feature, outside this remediation.
This records the existing product boundary, not an exception for a newly accepted defect.

Production verification must continue enforcing origin, RP ID, challenge, ceremony type,
presence, requested UV, signature and user/credential binding. Passwordless always requires UV,
even when step-up prefers or discourages it. Nonzero counters must advance; counterless (0,0)
authenticators remain supported. A cloned/regressed counter is the typed WebAuthnCounterCloned
failure, consumed by the shared MFA failure, abuse-budget and audit path. There is no successful
verification carrying a clone warning, so the unreachable boolean field and branch are removed.

## Consequences

Consumers must remove VerifiedAuthentication.cloneWarning when adapting to the breaking port
change. Successful registration cannot be used as a device-management or hardware-trust claim.
Signed, test-only ES256 wire fixtures exercise the production decoder/verifier and enrollment,
step-up and passwordless workflows; upgrades must rerun their policy negatives. Fixture private
scalars and fixed signing nonces are public test material and must never become real credentials.

## Alternatives rejected

A permanent success-with-warning clone path would conflict with fail-closed counter policy.
Adding a device trust service solely to justify existing wording would introduce a new product
and operational contract. Reusing upstream-only tests would leave the application's adapter,
error mapping and workflow policy unverified.
