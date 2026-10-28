---
id: 9
slug: close-all-security-and-performance-review-findings
title: "Close All Security and Performance Review Findings"
kind: master-plan
created_at: 2026-10-28T18:34:37Z
intention: "intention_01m61wmy1ee659sha16r51vqcq"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-28T18:34:37Z
---

# Close All Security and Performance Review Findings

This MasterPlan is a living coordination document. Keep the registry, Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Child plans own their implementation milestones.

## Vision & Scope

The August reviews contain 108 numbered findings plus unnumbered performance observations. [REV-11](../reviews/remediation-completeness-audit.md) found that MasterPlan 8 completed its scope while several subitems remained unimplemented. [IR-3](../improvement-requests/close-residual-review-findings.md) owns those residuals. This initiative closes the gap: row-bound TOTP secrets, bounded input/state/database work, explicit OAuth/JWT contracts, real WebAuthn verification fixtures, bounded operational runtime costs, and an auditable finding-by-finding closure record.

“Everything” includes low and informational observations, compound clauses, test gaps, documentation claims, and operational costs. [The finding ledger](../review-remediation/findings.md) enumerates all original findings and initially splits the most consequential compound ones. No row is closed merely because an earlier plan is complete. The final gate forbids open, deferred, unassigned, or evidence-free rows. A parent finding closes only when every subitem closes.

Existing deliberate policies remain visible: ES256 timing risk with RS256 available, trusted OAuth clients without consent, signup existence disclosure, configurable audit retention, residual reset hit/miss cost, and migration lock windows. They require exact decision/documentation citations and a verification of their mitigations. This plan does not silently approve new risk exceptions. Any new acceptance of a confirmed defect requires an explicit owner decision and ADR; until then the item remains open and prevents completion. A new consent product, MDS device-trust service, replacement cryptographic library, and production deployment are outside this planning scope. Their absence may only close a finding when the original requirement was accurate documentation of that boundary.

The current request creates plans; it does not implement or deploy them. All child statuses start Not Started. The prior 14-suite pass at the REV-11 audit is baseline evidence only.

## Decomposition Strategy

Seven children separate independently testable invariants. Ciphertext migration needs an upgrade contract; input/enrollment bounds need domain and persistence enforcement; wire compatibility needs issuer/consumer ordering; database work needs transaction and race proof; WebAuthn needs real cryptographic fixtures; runtime operations need host parity and observable failures. A seventh child owns complete coverage and final integration rather than scattering closure judgments across implementation plans. Package-by-package plans were rejected because these boundaries cross core, interpreter, HTTP, and server packages.

Relevant decisions inspected were [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md), [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md), [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md), [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md), [ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md), [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md), and [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md). They require strict token verification, atomic state, synchronized configuration, redacted diagnostics, embedding parity, bounded JWKS work, and additive namespace-safe migrations. No cross-repository ADR is needed to change these local contracts; dependency source discovery still uses Mori.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| 1 | Bind TOTP Ciphertext to Credentials and Migrate Legacy Envelopes | [docs/plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md](../plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md) | EP-7 M1 before M2 | EP-4 transaction helpers | Not Started |
| 2 | Bound Authentication Inputs and Passkey Enrollment | [docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md](../plans/63-bound-authentication-inputs-and-passkey-enrollment.md) | EP-7 M1 before M2 | EP-4 transaction helpers | Not Started |
| 3 | Complete OAuth and JWT Wire Validation | [docs/plans/64-complete-oauth-and-jwt-wire-validation.md](../plans/64-complete-oauth-and-jwt-wire-validation.md) | EP-7 M1 before M2 | EP-2 validation | Not Started |
| 4 | Bound Database Work and Make Bulk Session Revocation Atomic | [docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md](../plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md) | EP-7 M1 before M2 | None | Not Started |
| 5 | Prove WebAuthn Ceremonies and Document Attestation Trust | [docs/plans/66-prove-webauthn-ceremonies-and-document-attestation-trust.md](../plans/66-prove-webauthn-ceremonies-and-document-attestation-trust.md) | EP-7 M1 before M2 | EP-2 enrollment | Not Started |
| 6 | Bound Runtime Costs and Complete Operational Diagnostics | [docs/plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md](../plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md) | EP-7 M1 before M2 | EP-3 actor decoding; EP-4 limits | Not Started |
| 7 | Verify Every Review Finding and Publish Closure Evidence | [docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md](../plans/68-verify-every-review-finding-and-publish-closure-evidence.md) | M1: none; M2/M3: EP-1–EP-6 complete | None | Not Started |

Status values are Not Started, In Progress, Complete, Cancelled. Dependencies name milestones deliberately; a whole-child dependency requires the child to be Complete.

## Dependency Graph

Start with EP-7 M1: accept the complete clause inventory and assign every row. Each behavior child may establish its M1 regression independently, but its M2 expansion waits for that inventory so small subitems cannot disappear again. Then implement EP-1 through EP-6 in registry order by default. Their behavior work has no hard inter-child dependencies; soft relationships describe useful reuse, not permission to skip acceptance. If work is later delegated, serialize allocation of migration files and coordinate shared configuration changes.

After EP-1 through EP-6 are Complete, EP-7 M2 runs final integration and performance/upgrade checks; EP-7 M3 publishes the new review and closes the initiative. This explicit milestone sequence avoids a cycle between inventory-first and evidence-last work. Integration failures reopen the responsible child and invalidate affected final evidence.

## Integration Points

EP-1 owns TOTP envelope/version columns and the offline conversion command. EP-4 owns transaction retry/deadline helpers. EP-1 first proves enrollment upsert stores the exact identifier authenticated in the envelope; it must not wait for generic retry work to define that security contract. Both use additive migrations through `just new-migration`; allocate at implementation time, never reserve numeric filenames now.

EP-2 owns field limits and passkey quota operations. EP-4 owns session quota/paging and bulk-revocation operations. Both enforce quotas atomically in PostgreSQL and mirror them in the in-memory interpreter. A pre-read count is not enforcement. EP-5 owns signed WebAuthn fixtures and validates the production ceremony interpreter; EP-2 owns cap behavior even when those fixtures are not yet available.

EP-3 owns PKCE, bearer parsing, actor wire shape, and verifier lifetime policy. EP-6 consumes decoded actor/subject identities for audit, never raw token claims. Their first integration check is issuer → downstream verification → persisted actor/subject audit, with old and new actor forms. No child may turn an invalid actor into an ordinary token.

Each child adding configuration owns its named fields in `shomei-core/src/Shomei/Config.hs`, `shomei-server/src/Shomei/Server/Config.hs`, and `config/shomei-types.dhall`, together with default/example/documentation edits. EP-7 checks the combined schema. EP-6 owns shared Warp assembly so admission/bind settings reach both standalone and embedded hosts. Source changes in shared files must preserve other children's changes.

EP-4 owns PostgreSQL concurrency evidence; EP-5 owns signed ceremony evidence; EP-3 owns HTTP protocol negatives; EP-6 owns performance/admission/audit-sink evidence. EP-7 owns ledger structure and final review. Each owner supplies exact tests, commands, tested commit, result, and residual exposure. API breaks require package changelog/version-policy notes and updates to workspace examples; actual release publication is separate authorization.

New ADRs are expected for TOTP envelope migration, atomic quota/retention policy, bounded retry semantics, and the attestation trust boundary. Update ADR-3 for actor/lifetime compatibility, ADR-8 for configuration contracts, ADR-7 for bulk atomic behavior, and ADR-17 for host settings where needed. Use `agents/skills/exec-plan/ADR.md` before allocation or edits. Proposed decisions here become durable records when implemented and verified, not blanket risk approvals.

## Progress

Planning is complete: seven child ExecPlans and the initial coverage ledger are authored, all implementation remains Not Started. First executable milestone is EP-7 M1. Final acceptance still requires the new behavior, candidate-commit test/benchmark evidence, upgrade proof, and a commit-pinned closure review. No runtime changes were made while drafting.

## Surprises & Discoveries

REV-11 showed that all 108 parent findings can appear covered by historical plans while individual clauses remain open. Therefore completeness is checked at clause level, including informational observations and index/performance appendices. ADR-13 additionally names ID-token diagnostics as a deferred related item; EP-7 must explicitly reconcile that boundary rather than infer all token wrappers are redacted.

The intention was created with `mina ci --json` as requested. Mina warned that its default parent was outside the Shōmei Rei project scope; the intention ID was successfully returned and is attached to all plans. Project-scope synchronization is an administrative follow-up, not an implementation prerequisite.

## Decision Log

2026-10-28: Separate historical verification from behavior implementation and require inventory acceptance before expanding fixes. The previous completion claim omitted compound subitems; a final-only document sweep is insufficient.

2026-10-28: Plan a finite, explicit compatibility transition for ciphertext and actor formats. Permanent permissive fallbacks would retain the original security weakness or make interoperability migration untestable.

2026-10-28: Retain existing explicit product/risk decisions with evidence, but forbid silently converting new defects into accepted risks. The user requested comprehensive resolution, not an unreviewed reduction of scope.

## Outcomes & Retrospective
