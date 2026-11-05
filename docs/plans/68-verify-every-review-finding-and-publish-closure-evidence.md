---
id: 68
slug: verify-every-review-finding-and-publish-closure-evidence
title: "Verify Every Review Finding and Publish Closure Evidence"
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
      note: "Security review: M1 bundles inventory gate with full historical re-verification, delaying confirmed defect fixes"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T06:09:13Z
      mode: "update"
      note: "Split M1 into inventory gate and parallel historical verification; renumbered M3/M4; row-ownership rule; load result redaction"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T13:10:19Z
      mode: "implement"
      note: "Accept clause inventory and begin MasterPlan 9 implementation"
---

# Verify Every Review Finding and Publish Closure Evidence

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Make “all findings addressed” a verifiable statement. Every one of the 108 numbered original findings, each compound subitem, and the unnumbered performance observations receives an owner, disposition, and commit-pinned evidence. A new review closes IR-3 only when no unexplained or deferred defect remains.


## Progress


- [x] (2026-11-05) M1: all 108 original findings and the compound/performance clauses are assigned and explicitly named by their owner plans; `python3 scripts/check-review-inventory.py` verifies source-derived parent coverage, uniqueness, ownership, and child-plan coverage. Behavioral dispositions are recorded separately with commit-pinned evidence.
- [ ] M2: existing fix or risk evidence for every row this plan owns is independently checked against the current tree. Partial: refresh/access nested diagnostics and client bearer diagnostics have explicit passing tests; suspended-account library/HTTP distinction is confirmed against the timing test, error mapper and security guide. HTTP role/scope 128/129 boundaries pass. The remaining historical clauses are being audited.
- [ ] M3: integrated tests, performance checks, upgrades, and documentation validate the completed child changes.
- [ ] M4: commit-pinned closure review and IR-3/plan status accurately reflect zero unexplained residuals.


## Surprises & Discoveries

2026-11-05: Independent historical verification found the ID-token exception in ADR-13 still present. `IdToken` now redacts diagnostics and no longer has generic JSON instances; the OAuth handler explicitly unwraps it. The core regression passes, and ADR-13 documents the completed follow-up. Remaining historical rows still require their own evidence.





## Decision Log


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective





## Context and Orientation


The sources are the ten original documents in `docs/reviews`, the follow-up `docs/reviews/remediation-completeness-audit.md`, and `docs/improvement-requests/close-residual-review-findings.md`. [The ledger](../review-remediation/findings.md) enumerates all original numbered findings with initial ownership. Plans 51–60 contain historical remediation evidence, but their completion is not proof for every compound subitem. [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md) [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) [ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md) [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md) [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md) preserve the established security, configuration, embedding, and migration constraints. Read a relevant decision fully before treating it as a risk disposition.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 runs first, before broad implementation, and is an inventory gate only. Read every finding paragraph, including informational clauses, appendices, and the unnumbered performance section. Split compound findings into subrows; keep the parent open until all subrows close. The supplied ledger gives initial assignments, not automatic closure. In particular enumerate all REV-2 §23, REV-3 §§9,10, REV-5 §§9,10,12 and index observations, REV-7 §§13,16, and REV-8 §17 subitems. Route any uncovered defect to the responsible existing child and update its acceptance; do not park findings under a generic future-work label. A row owned by a behavior child must be named in that child's Plan of Work or Validation and Acceptance; reassign a row only by editing the ledger and both affected plans in the same commit. M1 is accepted when every row has an owner whose plan names it. That acceptance is the prerequisite the behavior children wait on before expanding past their first regression.

M2 runs alongside the behavior children and needs none of them complete. Associate existing tests and source locations with every claimed fix on the rows this plan owns and rerun relevant tests if evidence is stale. Existing documented decisions about ES256, consent, signup disclosure, audit retention, reset timing, migration locks, and library-level suspended-account errors need exact source/decision citations and stated residual exposure. Any newly proposed acceptance of an actual defect remains open until explicitly decided by the project owner.

M3 starts only after all six behavior plans are complete. Add `scripts/review-remediation-load.sh` as a reproducible driver around an isolated ephemeral server/database, with a fixed 10,000-session fixture and 1,000 repeated OpenAPI requests. It must refuse non-loopback targets, set finite concurrency/duration, and record JSON results that contain no tokens, cookies, or credentials; the intended command is `scripts/review-remediation-load.sh --scenario all --output /tmp/shomei-review-load.json`. Include the existing `scripts/argon2-load-test.sh` scenario after correcting its stale configuration instructions to the current schema. Compare functional query counts/encoding counts as stable acceptance and report latency/RSS as measurements with noise limits; require no unbounded growth when input size is fixed. Run the full 14-suite workspace gate, separately build `examples/embedded-with-en`, check migration and ADR/review profiles, and validate user-facing configuration/CLI examples. Repeat the Argon2 bounded-load check and newly added OpenAPI/session workloads with captured configuration, fixture size, wall time, allocations or RSS, and error counts. Compare results to pre-change baselines rather than claiming improvements from passing unit tests. Check upgrade sequencing for TOTP envelopes and actor claims against the deployed compatibility contract using ephemeral old/new fixtures. Verify no secret-bearing fixture leaks to logs. If integration exposes a regression, reopen its owning child and rerun affected acceptance before continuing.

M4 creates a new review using `okf id next` and the exact tested commit, with previousReview linking to REV-11 and coverage/limits stated. Never rewrite the original review outcomes. Resolve IR-3 only when all parent/subrows are fixed with evidence, explicitly accepted under an existing or newly approved decision, or shown inapplicable with evidence; “deferred” is not closure. Distill durable decisions into ADRs through the profile workflow, triage implementation friction, update the MasterPlan and every child outcome, and link the final review from the review index. Record strict-validation provenance warnings honestly; do not invent independent reviews to make a profile pass.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal build all
cabal test all --test-show-details=failures -j1
just build-embedded-with-en
just migration-check
just reviews-validate
just adr-validate
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
nix fmt -- --fail-on-change
git diff --check
```


## Validation and Acceptance


Inventory acceptance includes every assigned ledger row: REV-1.1, REV-1.2, REV-1.3, REV-1.4, REV-1.5, REV-1.6, REV-1.7, REV-1.8, REV-1.9, REV-1.10, REV-1.11, REV-1.12, REV-2.1, REV-2.2, REV-2.3, REV-2.4, REV-2.5, REV-2.6, REV-2.7, REV-2.8, REV-2.9, REV-2.10, REV-2.11, REV-2.12, REV-2.13, REV-2.14, REV-2.15, REV-2.16, REV-2.17, REV-2.18, REV-2.21, REV-2.22, REV-3.1, REV-3.2, REV-3.3, REV-3.4, REV-3.5, REV-3.6, REV-3.8, REV-3.10, REV-4.1, REV-4.2, REV-4.4, REV-5.1, REV-5.2, REV-5.3, REV-5.4, REV-5.5, REV-5.6, REV-5.7, REV-5.8, REV-5.11, REV-6.1, REV-6.2, REV-6.3, REV-6.4, REV-7.1, REV-7.2, REV-7.3, REV-7.4, REV-7.5, REV-7.6, REV-7.7, REV-7.9, REV-7.10, REV-7.11, REV-7.12, REV-7.15, REV-8.1, REV-8.2, REV-8.3, REV-8.4, REV-8.5, REV-8.6, REV-8.7, REV-8.8, REV-8.9, REV-8.10, REV-8.11, REV-8.12, REV-8.13, REV-8.14, REV-8.15, REV-8.16, REV-9.1, REV-9.2, REV-10.1, REV-10.2, REV-10.3, REV-10.4, REV-10.5, REV-10.7, REV-2.23.3, REV-2.23.6, REV-3.10.1, REV-3.10.2, REV-3.10.3, REV-3.10.4, REV-3.10.5, REV-3.10.6, REV-3.10.7, REV-3.10.8, REV-3.10.9, REV-3.10.10, EXTRA-4, EXTRA-5, EXTRA-7, EXTRA-8, EXTRA-9, EXTRA-10, EXTRA-11, EXTRA-12, REV-1.10.1, REV-1.10.2, REV-1.10.3, REV-1.12.1, REV-1.12.2, REV-1.12.3, REV-1.12.4, REV-1.12.5, REV-2.22.1, REV-2.22.2, REV-2.22.3, REV-4.4.1, REV-4.4.2, REV-5.11.1, REV-5.11.2, REV-5.11.3, REV-5.11.4, REV-6.1.1, REV-6.1.2, REV-6.3.1, REV-6.3.2, REV-6.4.1, REV-6.4.2, REV-7.10.1, REV-7.10.2, REV-7.15.1, REV-7.15.2, REV-7.15.3, REV-7.15.4, REV-7.15.5, REV-8.9.1, REV-8.9.2, REV-8.9.3, REV-8.9.4, REV-8.10.1, REV-8.10.2, REV-8.11.1, REV-8.11.2, REV-8.12.1, REV-8.12.2, REV-8.12.3, REV-8.12.4, REV-8.15.1, REV-8.15.2, REV-8.16.1, REV-8.16.2, REV-8.16.3. Each row needs its own exact evidence or an explicit cross-reference to evidence covering the same clause; parent closure also requires all child rows.


A source-derived count finds exactly 108 original numbered handles and no missing or duplicate ledger parent. Every compound clause has a subrow or explicit evidence covering it. No pending/open/deferred row is allowed at final closure. The full tests and scoped performance/upgrade checks pass at the recorded candidate commit. The final report distinguishes fixed behavior from retained product/risk decisions and does not generalize model review into a security certification.


## Idempotence and Recovery


The ledger and plans are append/update documentation; preserve source review history. A failed gate keeps IR-3 and the MasterPlan open. Do not delete a failed result; add the corrective commit and rerun evidence. If a policy decision is missing, continue other ready work while leaving its row open.


## Interfaces and Dependencies


M1 has no hard dependency and must be accepted before M2 of any behavior child begins expanding implementation. M2 has no hard dependency and runs alongside the behavior children. M3 and M4 have hard dependencies on completion of docs/plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md, docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md, docs/plans/64-complete-oauth-and-jwt-wire-validation.md, docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md, docs/plans/66-prove-webauthn-ceremonies-and-document-attestation-trust.md, docs/plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md. This milestone-level sequence avoids a dependency cycle. This plan owns the ledger schema and closure verdict; behavior children supply evidence for their rows.


## Revision Notes


2026-11-03: Security-focused review split the first milestone into an inventory gate (M1) and parallel historical verification (M2), renumbering integration to M3 and closure to M4, so confirmed defects are not held behind historical re-verification. Added the row-ownership rule and result redaction for the load driver.
