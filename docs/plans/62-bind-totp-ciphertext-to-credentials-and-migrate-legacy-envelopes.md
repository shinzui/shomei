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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T06:09:13Z
      verdict: "changes-requested"
      note: "Security review: upsert identifier contract, pending rows, nonce freshness, keyless --check missing"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T06:09:13Z
      mode: "update"
      note: "Added verified upsert behavior, pending-row coverage, nonce freshness, keyless --check"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T13:10:19Z
      mode: "implement"
      note: "Accept clause inventory and begin MasterPlan 9 implementation"
---

# Bind TOTP Ciphertext to Credentials and Migrate Legacy Envelopes

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Prevent a valid encrypted TOTP secret from being copied to another account while preserving legitimate enrollments during upgrade. TOTP is the time-based one-time password second factor; authenticated associated data (AAD) is context authenticated with the ciphertext. This closes REV-2 §19, including the upgrade path.


## Progress


- [x] (2026-11-05) M1: versioned row binding rejects pending/confirmed transplants, credential-ID changes, and marker/nonce/ciphertext/tag tampering; PostgreSQL binding and re-enrollment regressions pass.
- [x] (2026-11-05) M2: migration 0038, keyless inspection, offline CLI conversion, and strict startup/read behavior implemented. Wrong-key/tag and lock-barrier stale-snapshot tests pass; conversion resumes after a 100-row batch and reruns change zero converted rows.
- [x] (2026-11-05) M3: real MFA completion preserves the secret across conversion; core/PostgreSQL/server suites, CLI build/help, migration and ADR checks pass. The MFA guide documents offline sequencing, backup provenance and rollback.


## Surprises & Discoveries

2026-11-05: The first PostgreSQL pass verified the new binding/conversion cases but nine unrelated cases timed out starting ephemeral servers at unrestricted Tasty concurrency. Explicit `--test-options=-j2` passed the suite; FRIC-1 in `docs/friction-log/` records the environment constraint. Cabal `-j1` limits builds, not Tasty cases.

2026-11-05: Fresh dependency resolution exposed smtp-mail 0.5.0.1 failing against network >=3.2.10. Hackage release 0.5.0.2 fixes that exact conflict and its sdist was inspected; the upstream tag listing has no matching release tag. The lower bound now selects the released fix rather than excluding current network. FRIC-2 in `docs/friction-log/` records the detour.





## Decision Log

2026-11-05: Version 1 authenticates a fixed domain label plus two fixed-width canonical TypeIDs and carries a matching six-byte envelope marker. Schema version 0 is converter-only; both pending and confirmed legacy rows prevent shared server startup. ADR-20 records this upgrade contract.

2026-11-05: Use `transactionNoRetry` for converter batches and require hasql-transaction >=1.2.1. The 1.2 upstream source lacks this export; 1.2.1 exports it. Hackage latest and upstream latest release tag both identify 1.2.3.1.


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective

2026-11-05: Implemented and verified at `7242c45` (82 PostgreSQL cases and 283 core cases in the final rerun). Delivered row-bound TOTP encryption and a resumable offline upgrade with no runtime legacy fallback. `cabal test shomei-postgres shomei-core shomei-server --test-show-details=failures --test-options=-j2 -j1` passed, followed by a final core/PostgreSQL rerun after the last assertions. `cabal build shomei-admin -j1`, CLI help, `just migration-check`, and `just adr-validate` pass. ADR-20 holds the durable format/upgrade contract. Historical transplants cannot be detected retroactively, so trusted backup associations remain an explicit limitation. FRIC-1 is accepted with explicit Tasty concurrency; FRIC-2 is resolved by requiring released smtp-mail 0.5.0.2.





## Context and Orientation

The context below records the starting snapshot; Progress and Outcomes describe the completed implementation.


`shomei-postgres/src/Shomei/Mfa/Totp/Postgres.hs` owns `encryptSecret`, `decryptSecret`, `rebuildCredential`, and enrollment upsert. Its current blob is nonce + ciphertext + authentication tag with empty AAD. `shomei-postgres/test/Main.hs` has round-trip/encryption tests but no transplant case. `shomei-server/app/Admin.hs` and `shomei-server/app/Shomei/Admin/Env.hs` assemble operator commands. `shomei-core/src/Shomei/Mfa/Totp/Domain.hs` defines the typed credential/user identifiers. [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md) require atomic persistence, secret-free diagnostics, and append-only schema-qualified migrations. No current ADR specifies TOTP envelope binding; add one when implementing it.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 changes the encryption boundary to require credential ID and user ID. Authenticate a fixed domain/version label and unambiguous fixed-width encodings of both IDs. Add an explicit format version rather than guessing whether random nonce bytes are a prefix. Prefer a schema version column with a constrained vocabulary and a matching envelope marker; never fall back to legacy decoding after a versioned authentication failure. Check the upsert conflict path: authenticate the identifier actually persisted, including re-enrollment of an existing user. Today `upsertStmt` resolves `ON CONFLICT (user_id)` by writing `EXCLUDED.totp_credential_id` into the existing row, so the persisted credential identifier equals the one the workflow generated; the regression asserts that equality after re-enrollment and after conversion, and fails if a future statement keeps the old identifier. Unconfirmed enrollment rows (`confirmed_at IS NULL`) hold ciphertext too and receive the same version, binding, and conversion treatment as confirmed rows. Exercise that path before expanding the migration command. Keep key material and plaintext out of error strings.

M2 adds an additive migration using `just new-migration add-totp-envelope-version`, with old rows explicitly marked legacy. Add `shomei-admin totp migrate-envelopes` as a dedicated operator command that reads the existing TOTP key through the secret loader. Require an offline window: stop all Shōmei writers and use a transaction-scoped migration lock plus conditional updates on the original blob/version. Process at most 100 rows per transaction, decrypt/re-encrypt outside long-lived locks, compare-and-swap the original values, and retry conflicts rather than overwriting a concurrent enrollment. Print only counts and opaque identifiers needed for recovery. Provide a read-only `--check` mode reporting legacy/invalid-version counts; it reads the version column only and must work without the TOTP key. Every re-encryption draws a fresh 96-bit nonce; the converter never reuses a legacy nonce or one nonce for two rows. Normal runtime accepts only the new version and refuses readiness/startup when legacy rows remain; legacy decryption exists only in the explicit converter. The converter must be usable before normal strict boot checks, with the deployment key and schema checks intact.

M3 tests genuine second-factor login before and after conversion using the same secret. Cover interruption between batches, a wrong key, an invalid tag, a row changed between read/write, repeated conversion, zero rows, and a transplant after conversion. Document that a ciphertext already transplanted before conversion cannot be retroactively detected; conversion binds existing database associations, so backup provenance matters.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-postgres shomei-core shomei-server --test-show-details=failures -j1
just migration-check
just adr-validate
```


## Validation and Acceptance


Inventory acceptance includes every assigned ledger row: REV-2.19. Each row needs its own exact evidence or an explicit cross-reference to evidence covering the same clause; parent closure also requires all child rows.


Two independently enrolled users must not accept each other's stored blob, whether the rows are confirmed or still pending. Changes to either authenticated identifier, version, nonce, ciphertext, or tag must fail closed. Conversion reruns change zero already-converted rows; failures never overwrite unreadable material. A partially converted database cannot serve authentication with a permanent legacy fallback. The existing factor flow and re-enrollment both continue to work.


## Idempotence and Recovery


Take a database backup and retain the deployment TOTP key before the maintenance window. Do not remove or rewrite released SQL history. A failed batch rolls back; rerun the converter against the same snapshot/version conditions. Once converted, old binaries cannot read new envelopes: rollback requires restoring the matching backup during the outage, never downgrading individual rows in a live database.


## Interfaces and Dependencies


Owns the encrypted-row version and converter API. Integrates with plan docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md for persistence time/deadline helpers, but has no hard dependency on that plan. Do not place conversion work inside request transactions. The first producer/consumer check is re-enrollment upsert followed by strict row reconstruction. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.


## Revision Notes


2026-11-03: Security-focused review under MasterPlan 9 added the verified upsert identifier behavior, pending-row coverage, nonce freshness, and the keyless `--check` mode. Scope and acceptance obligations are otherwise unchanged.
