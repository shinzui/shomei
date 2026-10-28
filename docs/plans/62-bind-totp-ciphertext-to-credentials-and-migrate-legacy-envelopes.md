---
id: 62
slug: bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes
title: "Bind TOTP Ciphertext to Credentials and Migrate Legacy Envelopes"
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

# Bind TOTP Ciphertext to Credentials and Migrate Legacy Envelopes

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Prevent a valid encrypted TOTP secret from being copied to another account while preserving legitimate enrollments during upgrade. TOTP is the time-based one-time password second factor; authenticated associated data (AAD) is context authenticated with the ciphertext. This closes REV-2 §19, including the upgrade path.


## Progress


- [ ] M1: versioned, row-bound encryption rejects ciphertext transplants and tampering.
- [ ] M2: resumable offline conversion upgrades legacy rows and strict runtime rejects all legacy blobs.
- [ ] M3: upgrade, interrupted conversion, and factor-login integration tests pass with an operator runbook.


## Surprises & Discoveries





## Decision Log


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective





## Context and Orientation


`shomei-postgres/src/Shomei/Mfa/Totp/Postgres.hs` owns `encryptSecret`, `decryptSecret`, `rebuildCredential`, and enrollment upsert. Its current blob is nonce + ciphertext + authentication tag with empty AAD. `shomei-postgres/test/Main.hs` has round-trip/encryption tests but no transplant case. `shomei-server/app/Admin.hs` and `shomei-server/app/Shomei/Admin/Env.hs` assemble operator commands. `shomei-core/src/Shomei/Mfa/Totp/Domain.hs` defines the typed credential/user identifiers. [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md) require atomic persistence, secret-free diagnostics, and append-only schema-qualified migrations. No current ADR specifies TOTP envelope binding; add one when implementing it.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 changes the encryption boundary to require credential ID and user ID. Authenticate a fixed domain/version label and unambiguous fixed-width encodings of both IDs. Add an explicit format version rather than guessing whether random nonce bytes are a prefix. Prefer a schema version column with a constrained vocabulary and a matching envelope marker; never fall back to legacy decoding after a versioned authentication failure. Check the upsert conflict path: authenticate the identifier actually persisted, including re-enrollment of an existing user. Exercise that path before expanding the migration command. Keep key material and plaintext out of error strings.

M2 adds an additive migration using `just new-migration add-totp-envelope-version`, with old rows explicitly marked legacy. Add `shomei-admin totp migrate-envelopes` as a dedicated operator command that reads the existing TOTP key through the secret loader. Require an offline window: stop all Shōmei writers and use a transaction-scoped migration lock plus conditional updates on the original blob/version. Process at most 100 rows per transaction, decrypt/re-encrypt outside long-lived locks, compare-and-swap the original values, and retry conflicts rather than overwriting a concurrent enrollment. Print only counts and opaque identifiers needed for recovery. Provide a read-only `--check` mode reporting legacy/invalid-version counts. Normal runtime accepts only the new version and refuses readiness/startup when legacy rows remain; legacy decryption exists only in the explicit converter. The converter must be usable before normal strict boot checks, with the deployment key and schema checks intact.

M3 tests genuine second-factor login before and after conversion using the same secret. Cover interruption between batches, a wrong key, an invalid tag, a row changed between read/write, repeated conversion, zero rows, and a transplant after conversion. Document that a ciphertext already transplanted before conversion cannot be retroactively detected; conversion binds existing database associations, so backup provenance matters.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-postgres shomei-core shomei-server --test-show-details=failures -j1
just migration-check
just adr-validate
```


## Validation and Acceptance


Two independently enrolled users must not accept each other's stored blob. Changes to either authenticated identifier, version, nonce, ciphertext, or tag must fail closed. Conversion reruns change zero already-converted rows; failures never overwrite unreadable material. A partially converted database cannot serve authentication with a permanent legacy fallback. The existing factor flow and re-enrollment both continue to work.


## Idempotence and Recovery


Take a database backup and retain the deployment TOTP key before the maintenance window. Do not remove or rewrite released SQL history. A failed batch rolls back; rerun the converter against the same snapshot/version conditions. Once converted, old binaries cannot read new envelopes: rollback requires restoring the matching backup during the outage, never downgrading individual rows in a live database.


## Interfaces and Dependencies


Owns the encrypted-row version and converter API. Integrates with plan docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md for persistence time/deadline helpers, but has no hard dependency on that plan. Do not place conversion work inside request transactions. The first producer/consumer check is re-enrollment upsert followed by strict row reconstruction. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.
