---
type: Review
title: August security and performance remediation completeness audit
description: MasterPlan 8 completed its scope, but residual findings prevent blanket closure of the original reviews.
generated:
  by: process:codex
  at: "2026-10-28T18:06:42Z"
reviewId: REV-11
subject: mori://shinzui/shomei
subjectKind: project
reviewedSha: 65d21a3433d0ea329390c6737d0af4e35fee53b9
coverage: incremental
baseSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
previousReview: mori://shinzui/shomei/okf/reviews/concepts/REV-1
reviewedAt: "2026-10-28T18:06:42Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-6
effort: unspecified
outcome: changes-requested
dimensions:
  - security
  - performance
  - test-coverage
  - documentation
context: >-
  Compared the 108 numbered findings in REV-1 through REV-10, plus the unnumbered
  performance discussion, with MasterPlan 8, its child plans, current source,
  and test inventory. This is a remediation completeness audit, not a new
  full-source review or independent reproduction of every historical exploit.
---

# Remediation completeness audit

## Verdict

**Not all findings are addressed.** The major remediations are present, including
the critical session-provenance guard. Completion of MasterPlan 8's planned scope
does not close every original finding or every subitem of a compound finding.
[IR-3](../improvement-requests/close-residual-review-findings.md) tracks remaining work.
The original reviews remain assessments of their original commit.

## Confirmed residuals

| Original finding | Current evidence | Remaining work |
|---|---|---|
| REV-2 §19, low: TOTP ciphertext transplant | `shomei-postgres/src/Shomei/Mfa/Totp/Postgres.hs`: `encryptSecret` and `decryptSecret` use empty AEAD data; `rebuildCredential` does not authenticate either row identifier. | Bind ciphertext to credential and user; version and migrate existing envelopes. An indefinite unbound fallback would preserve the weakness. |
| REV-7 §8; REV-2 §23: input and credential limits | `mkLoginId` and `mkEmail` impose no length ceiling; `Shomei.Passkey.Workflow` imposes no passkey-count ceiling. | Define field and persisted-state budgets, including direct library callers and login password input. Streamed body caps do not replace these bounds. |
| REV-2 §23: PKCE verifier shape | `Shomei.OAuth.TokenGrant.Workflow.verifyPkce` checks presence and S256 digest only. | Check verifier length and alphabet before hashing; challenge validation does not validate the original verifier. |
| REV-5 §9, low: transaction retry budget | `Shomei.Persistence.Database.Postgres.runDatabasePool` calls `Tx.transaction` without a deadline or retry budget. | Bound total attempts or elapsed time, including cleanup. Statement and idle-transaction timeouts do not bound repeated transactions. |
| REV-7 §14, informational: OpenAPI encoding | `openApiValue` caches a `Value`; `Shomei.Servant.Server` returns it through `Get '[JSON] Value`. | Cache serialized bytes while preserving content and media type. |
| REV-4 §3, low: direct attestation | `Shomei.WebAuthn.Ceremony.completeRegistration` supplies an empty metadata registry and uses only `rrEntry`; the user guide lists `direct` without explaining the absence of an authenticator-trust decision. | Document this limitation explicitly or implement a trust policy. |
| REV-4 §5, informational: ceremony coverage | `CeremonySpec` covers begin blobs, required UV in options, malformed registration input, and empty origins. | Add signed registration/assertion fixtures and negative origin/rpId/UV/counter/signature completion cases. Options tests do not prove completion behavior. |
| REV-1 Performance; REV-2 §20 | `Shomei.Account.Admin.Workflow.revokeUserSessions` loads all sessions and performs revoke plus audit per active row; machine/delegated mints still create a row per token. | Bound enumeration/revocation work and state growth, or explicitly accept the operational costs. |
| REV-2 §23; REV-7 §13: interop | `Sign/Jwt.hs` still emits string-valued `act`; `Servant/Auth.hs` matches literal `Bearer `. | Explicitly resolve these wire-compatibility observations. Other subitems, including refresh introspection fallback and token-exchange discovery, have landed. |
| REV-5 §10, informational: persistence details | Credential password updates do not stamp `updated_at`; user/credential creation still uses `getCurrentTime` directly; the unused authorization-code expiry operation remains unbatched. | Fix or explicitly dispose of each subitem. |
| REV-10 §6, low: delegated-action audit example | `Downstream.Service` returns `onBehalfOf` in a response; that is not a durable actor/subject audit record. | Demonstrate an audit sink or explicitly accept the template omission. |
| REV-3 §7, low: maximum token lifetime | `claimsToAuth` reads `iat` and `exp` without bounding their difference. Plan 53 explicitly leaves maximum `exp - iat` outside MasterPlan 8. | Track as deferred; do not mark the whole claim-shape finding fixed. |

The transaction dependency was located with Mori. Source for
`mori://hasql/hasql/packages/hasql-transaction` retains a `fix` retry loop on
40001/40P01 in `Hasql.Transaction.Private.Sessions`. No dependency bounds or
workaround are chosen here; implementation must check the resolved dependency API.

## Coverage reconciliation

This table accounts for all 108 numbered findings. Plan coverage identifies the
existing remediation evidence, not independent reproduction of every claim in
this follow-up. Compound findings remain partial if any subitem is open.

| Review | Findings | Existing coverage and limits |
|---|---|---|
| REV-1 | 1–12 | Plans 51–60 cover the cross-cutting findings. §11 retains documented hit/miss cost differences. Unnumbered performance costs remain above. |
| REV-2 | 1–23 | Plans 51, 52, 54–57 cover 1–18 and 20–22. §6 is mitigated, not constant-cost. §§19,20,23 retain the residuals above; token redaction in §23 did land. |
| REV-3 | 1–10 | Plans 53 and 56 cover verifier/key policy, state, timestamps, rewrap, boot validation, and regression tests. §2 is documented risk; §7's maximum lifetime is deferred. Absence of a minted `jti` in §9 still needs an explicit disposition. |
| REV-4 | 1–5 | Plans 54 and 56 address 1–2; plan 60 covers origin/counter documentation in 4. §§3,5 remain above. |
| REV-5 | 1–12 | Plans 53, 55–57 cover hashing, atomic transitions, schema, timestamps, and audit hygiene; plan 60 covers 11. §§8–10 retain limits noted here. §12 gained counter and lockout races, but the remaining original database-race list needs case-by-case closure. |
| REV-6 | 1–4 | Plans 53, 55, 56 add indexes and constraints. Plan 60 documents the server floor and migration locks. Transactional index builds still require operational planning. |
| REV-7 | 1–16 | Plans 51–54, 58, 60 cover principal HTTP fixes and documentation. §§8,13 remain partial; §14 remains open. §16 gained regression cases but requires case-by-case reconciliation, including lowercase bearer. |
| REV-8 | 1–17 | Plans 53–59 cover the principal runtime fixes. §17 is compound: atomic keys and sanitized errors landed; remaining CLI/logging/admission/operational observations require explicit disposition before blanket closure. |
| REV-9 | 1–2 | Plan 57 redacts client `Token`; plan 60 reconciles admin documentation. |
| REV-10 | 1–7 | Plans 53, 59, 60 cover TLS/cache policy, runbooks, en integration, headers, and documentation. §6 remains above. |

## Existing explicit dispositions

- ES256 timing risk is documented, with RS256 as an alternative. This review
  neither demonstrates remote exploitation nor re-audits the crypto dependencies.
- Reset and verification delivery is queued, but a hit still inserts a token and
  audit event while a miss only looks up the user. `CostSpec` explicitly pins
  that residual; the guide no longer promises indistinguishable work.
- Audit retention is configurable and off by default. Failed-identifier hashing
  does not remove all audit PII.
- OAuth clients remain trusted without consent UI; signup existence disclosure
  remains documented product policy.

These are existing dispositions, not new risk acceptances by this audit.

## Validation and limits

- `cabal test all --test-show-details=failures -j1`: passed all 14 suites,
  including PostgreSQL, admin/server, and both workspace examples.
- `just reviews-validate`: passed strict profile and log enforcement (11 concepts).
- Improvement-request profile/log validation: passed in normal mode (3 concepts).
  Strict mode reports missing recommended review provenance on IR-1, IR-2, and
  the newly authored, not independently reviewed IR-3.
- `git diff --check`: passed; local links in the two new documents resolve.

A passing suite does not close an untested finding. This pass does not repeat historical load benchmarks or verify
live external SMTP, reverse-proxy, or en deployments. Concurrent workspace edits
to Nix/Seihou configuration appeared during the audit and were left untouched;
the source findings above refer to the recorded commit.
