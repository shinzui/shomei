---
title: "TOTP multi-factor authentication with recovery codes"
type: Capability
description: "Enroll RFC 6238 TOTP as a second factor with the secret encrypted at rest, and issue single-use recovery codes that complete an MFA challenge when the authenticator is lost."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-17
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
interface:
  - Shomei.Mfa.Totp.Workflow
  - Shomei.Mfa.Totp.Algorithm
  - Shomei.Mfa.RecoveryCode.Store
  - Shomei.Mfa.Workflow
requires:
  - CAP-2
  - CAP-6
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/Mfa/Totp/AlgorithmSpec.hs
    proves: The RFC 6238 computation, the plus-or-minus-one step window, and that a counter is admitted only when strictly greater than the last accepted one.
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: The TOTP secret is encrypted at rest with nonce and tag framing, and recovery codes are a replace-set with a consume-once compare-and-swap.
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: enroll, verify, mfa_required with the available methods, complete, a replayed code refused 401, recovery generation/use/count, removal, the delegated-token 403, and the freshness 403.
  - kind: test
    resource: shomei-server/test/Shomei/Server/E2ESpec.hs
    proves: The whole TOTP path against the live server, audited.
  - kind: guide
    resource: docs/user/mfa.md
    proves: The fixed parameters, the enrollment and login ceremonies, the recovery-code contract, and the encryption key's operational rules.
---

# TOTP multi-factor authentication with recovery codes

**Builds on:** [CAP-2 — password account lifecycle](password-account-lifecycle.md), [CAP-6 — postgreSQL persistence with embedded, composable migrations](postgresql-persistence-and-migrations.md).

Enrollment is two steps — `POST /v1/auth/totp/enroll` returns the shared secret **once**, and
`POST /v1/auth/totp/verify` activates it with a first valid code. Once any second factor is
confirmed and `mfaConfig.requireSecondFactor` is on (the default), a password login answers
`mfa_required` with the available methods and the client completes at `/v1/auth/mfa/complete`.

Replay is closed by construction: each credential remembers the highest time-step counter it has
accepted and admits only a strictly greater one.

`POST /v1/auth/recovery-codes` issues **ten** single-use codes, shown once and stored only as
SHA-256 hashes. They back up *any* second factor — a passkey-only user can hold them too — and
each completes an MFA challenge exactly once.

## Limits

- **The parameters are fixed and not configurable**: SHA-1, 30-second period, 6 digits, ±1 step.
  That is what mainstream authenticator apps implement; a deployment with different requirements
  cannot express them here.
- A TOTP secret must be recomputable, so it is **encrypted, not hashed** (AES-256-GCM under
  `SHOMEI_TOTP_ENCRYPTION_KEY`, a 32-byte environment secret). With `totpEnabled` set and the key
  absent or malformed, the server refuses to boot.
- **Losing that key makes every stored TOTP secret undecryptable.** Affected users must complete
  MFA with a recovery code or a passkey, remove TOTP, and re-enroll. There is no escrow.
- Regenerating recovery codes invalidates the previous set, and requires a token newer than
  `impersonationConfig.actorFreshnessWindow` (5 minutes by default) — otherwise
  `403 reauthentication_required`.
- A delegated (impersonation) token cannot enroll, remove, or regenerate; those paths answer
  `403` and are audited.
