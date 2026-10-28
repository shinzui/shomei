---
id: 65
slug: bound-database-work-and-make-bulk-session-revocation-atomic
title: "Bound Database Work and Make Bulk Session Revocation Atomic"
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

# Bound Database Work and Make Bulk Session Revocation Atomic

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Bound database work across retries and bulk operations while preserving exactly-once security state transitions. Cover REV-5 §§9,10,12, REV-2 §20, and the original unnumbered session-growth and enumeration costs.


## Progress


- [ ] M1: transaction retries terminate under attempt/time budgets and release usable pool connections.
- [ ] M2: bulk session revoke is atomic with winner-only audit; listing and machine-session state are bounded.
- [ ] M3: timestamp/clock/expiry consistency and real PostgreSQL race tests pass.


## Surprises & Discoveries





## Decision Log


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective





## Context and Orientation


`shomei-postgres/src/Shomei/Persistence/Database/Postgres.hs` uses automatic `Tx.transaction` retry. Mori source for `mori://hasql/hasql/packages/hasql-transaction` exposes `transactionNoRetry`; verify that symbol in the resolved build before using it. `shomei-core/src/Shomei/Account/Admin/Workflow.hs` enumerates all sessions and revokes/audits separately. `shomei-core/src/Shomei/Session/UnitOfWork/Store.hs` and `shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs` supply atomic workflows. [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md) require winner-returning operations, strict config, and additive schema-qualified migrations.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 adds a retry policy at the database interpreter: at most three whole attempts and a five-second total deadline by default, validated positive and configurable. Use the no-retry dependency primitive with explicit classification of 40001/40P01 only; never replay after ambiguous connection/commit failures. Generate domain IDs and hash passwords outside retried transactions. Prove cancellation/rollback and connection reuse with a real lock conflict plus deterministic injected retry outcomes before applying the helper across all unit-of-work callers. If the resolved dependency lacks no-retry support, first verify registry/tag versions and record the supported API decision; do not wrap an unbounded retry loop and claim an attempt budget.

M2 replaces admin bulk revoke with a unit-of-work operation that conditionally updates active rows and inserts audit records from returned winners in the same transaction. Return the actual winner count. Repeated/concurrent calls cannot duplicate events. Add keyset pagination (stable created_at plus session ID cursor) to session listing; HTTP defaults to 50 and caps pages at 200. Preserve a documented compatibility adapter only for library consumers, never on the HTTP hot path. Add a configurable active machine/delegated session cap per principal, default 1000, enforced atomically at mint across replicas; expired sessions do not spend the active budget. Refuse issuance above the ceiling rather than reusing sessions and changing revocation semantics. Enable and document bounded expiry cleanup with a finite expired machine/delegated retention policy; demonstrate live tokens are never swept. Quantify resulting rows as issuance rate times retention, not an alleged absolute bound if cleanup is disabled. Add supporting indexes only after query-plan evidence, and document disk capacity/retention operations.

M3 routes user and credential creation timestamps through the Clock port and stamps credential updated_at on password change/reset using the same transaction timestamp. Remove the unused unbatched authorization-code expiry port if no callers exist, otherwise convert it to bounded batches and test it. Add real database races for refresh rotation, reset/verification/recovery/ceremony consumption and sweeper versus rotation. Gate concurrency deterministically with barriers; assert persisted winners, revocation/audit outcomes, and no live rows lost. Review indexes for user list, client list, and per-user audit queries against the original REV-5 index appendix; use representative EXPLAIN evidence and avoid adding indexes to tiny tables without a benefit.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-postgres shomei-core shomei-servant shomei-server --test-show-details=failures -j1
just migration-check
just adr-validate
```


## Validation and Acceptance


Repeated retryable failures return the existing unavailable result within the configured budget and leave a connection usable. Bulk revoke has one audit event per changed row, rolls back wholly on injected failure, and remains bounded in application memory at 10,000 sessions. Paginated listing has no duplicates/skips across stable ordering. Two mints competing for the last slot have one winner. Database concurrency tests reproduce the documented one-winner/rotation theft behavior, including live sweeper interaction.


## Idempotence and Recovery


Add migrations; never rewrite old checksums. Run query-plan and race fixtures only in ephemeral databases. Preserve current data when enabling quotas or retention; do not delete active sessions to fit a quota. Document retention preview before enabling deletion. Timeout recovery must not retry an uncertain commit. Rollback code must remain compatible with additive indexes/columns.


## Interfaces and Dependencies


Owns retry policy, timestamp flow, session paging/quota ports, and bulk revoke unit of work. docs/plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md owns TOTP format/conversion; docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md owns passkey enrollment quotas. They share transaction helpers but not policy. Plan docs/plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md consumes limits in operator diagnostics. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.
