---
id: 66
slug: prove-webauthn-ceremonies-and-document-attestation-trust
title: "Prove WebAuthn Ceremonies and Document Attestation Trust"
kind: exec-plan
created_at: 2026-10-28T18:34:46Z
intention: "intention_01m61wmy1ee659sha16r51vqcq"
master_plan: "docs/masterplans/9-close-all-security-and-performance-review-findings.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-28T18:34:46Z
---

# Prove WebAuthn Ceremonies and Document Attestation Trust

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Prove that actual signed WebAuthn ceremonies enforce origin, relying-party identity, user verification, and replay counters. Document direct attestation accurately rather than implying a device trust policy. Cover REV-4 §§3,5 and the dead clone-warning observation in REV-2 §23.


## Progress


- [ ] M1: deterministic signed registration and assertion fixtures succeed through the real interpreter.
- [ ] M2: mutated origin/rpId/UV/signature/counter inputs fail with the intended domain outcomes.
- [ ] M3: step-up/passwordless integration and explicit attestation documentation pass review.


## Surprises & Discoveries





## Decision Log


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective





## Context and Orientation


`shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs` wraps the pinned library; `shomei-webauthn/test/Shomei/WebAuthn/CeremonySpec.hs` currently lacks successful completion fixtures. `shomei-core/src/Shomei/Mfa/Workflow.hs` and `shomei-core/src/Shomei/Passkey/Workflow.hs` consume results. `cabal.project` pins the compatible fork under `mori://tweag/webauthn/repos/webauthn-shomei-fork`. [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) constrain counter atomicity and diagnostic hygiene. Consult the local passkey guidance; no existing ADR defines device attestation trust.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 locates the fork and its test fixture APIs with Mori before choosing helpers. Use a deterministic software authenticator fixture in the package tests that generates the credential key and signs authenticator/client data; no browser or physical key is required. Freeze challenge/time in the fixture without replacing the production verification interpreter. Demonstrate registration produces a credential that then successfully asserts through the actual wrapper. Keep private fixture keys clearly test-only and never copy deployment credentials.

M2 mutates one authenticated property at a time: origin, relying-party hash, challenge, UV/user-presence flags, signature, credential owner, and stored/returned counters. Re-sign mutated payloads where needed so a test reaches the intended policy rather than failing on a generic bad signature first. Cover counterless (0,0), advancing counters, repeated/non-advancing nonzero counters, malformed blobs, empty origins, and expiry/consume-once at the workflow boundary. Verify passwordless assertions require UV even when step-up is configured preferred or discouraged. Resolve the unreachable cloneWarning branch: propagate a meaningful typed clone result if auditing needs it, or remove dead logic and test the existing error/audit path.

M3 makes the attestation contract explicit in `docs/user/passkeys.md` and the ceremony module: direct asks for attestation evidence but does not establish a trusted-device policy while metadata is empty and the trust verdict is unused. Preserve none as the default. Adding an MDS service or authenticator allow-list is a separate feature, not a prerequisite to truthfully closing this documentation finding. Record the deliberate boundary in an ADR. Link negative fixtures to the ledger so later dependency upgrades rerun them.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-webauthn shomei-core shomei-postgres --test-show-details=failures -j1
just adr-validate
```


## Validation and Acceptance


The suite contains at least one fully valid registration followed by assertion and targeted negatives that reach each named policy. A correct signature with forbidden origin or absent required UV must fail. Counterless authenticators continue working; nonzero replay fails. Workflow lockout/audit semantics remain intact. No test claims device trust merely because registration succeeds.


## Idempotence and Recovery


Fixtures are local and repeatable. Do not update the fork or package bounds just to make the fixtures easier. If a real dependency defect is exposed, record the failing case, verify upstream releases/tags, and carry the fix through the dependency workflow before claiming completion.


## Interfaces and Dependencies


No hard dependency. Integrates with docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md on enrollment cap behavior and docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md on persisted counter races. This plan owns real cryptographic fixture generation; those plans reuse it only where needed and retain their own persistence tests. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.
