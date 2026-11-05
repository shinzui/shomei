---
type: Review
title: MasterPlan 9 security and performance finding closure
description: All 240 finding rows have terminal evidence and the final candidate passes the integrated remediation gates.
generated:
  by: process:codex
  at: "2026-11-05T18:27:04Z"
reviewId: REV-12
subject: mori://shinzui/shomei
subjectKind: project
reviewedSha: 1daf36ca2652e320c343754c84656688ab5af1d6
coverage: incremental
baseSha: 65d21a3433d0ea329390c6737d0af4e35fee53b9
previousReview: mori://shinzui/shomei/okf/reviews/concepts/REV-11
reviewedAt: "2026-11-05T18:27:04Z"
reviewerKind: model
reviewer: process:codex
provider: openai
model: gpt-6.1-sol
effort: unspecified
outcome: approved
dimensions:
  - security
  - correctness
  - performance
  - operability
  - test-coverage
  - documentation
context: >-
  Finding-by-finding implementation acceptance by the implementing model, not an
  independent security review. Reconciled all 108 original numbered findings and
  240 parent, compound and performance rows against current source, actual test
  assertions, existing decisions and fresh integration results. Read dependency
  APIs through Mori-discovered sources and checked authoritative releases where
  compatibility choices required them. Ran all 14 workspace suites, separate en
  build, migration/profile checks and the isolated fixed load at reviewedSha.
  Editorial closure records, the final aggregate receipt and an upgrade-order
  clarification are added after this tested candidate without changing code.
---

# MasterPlan 9 finding closure

## Verdict

Approved for the requested remediation scope. [The ledger](../review-remediation/findings.md)
contains all 108 numbered parents and 240 total rows: **223 Fixed, 16 Existing decision verified,
and one Inapplicable with proof**. There are no open, deferred, unassigned or evidence-free rows.
Every compound parent includes its accepted leaves. [IR-3](../improvement-requests/close-residual-review-findings.md)
is satisfied. REV-1 through REV-11 retain their original outcomes and commit pins.

This is implementation acceptance by the authoring model. It is not an independent assessment,
security certification, claim of exhaustive vulnerability discovery or production deployment.

## Clause evidence and implementation

| Scope | Concrete result | Evidence |
|---|---|---|
| TOTP | Versioned AES-GCM row/user binding, strict startup/reads and resumable offline conversion; actual factor completion survives upgrade | [Plan 62](../plans/62-bind-totp-ciphertext-to-credentials-and-migrate-legacy-envelopes.md), ADR-20, `7242c45` |
| Input and enrollment | New-write budgets, early password-size refusal, legacy identity authentication and atomic passkey quota | [Plan 63](../plans/63-bound-authentication-inputs-and-passkey-enrollment.md), ADR-21/22, `3cf27a0` / `c615215` |
| OAuth/JWT | Strict shared bearer/Basic/PKCE, finite lifetime, actor objects and bounded legacy compatibility, complete protocol negatives | [Wire evidence](../review-remediation/oauth-jwt-evidence.md), ADR-3, `4fea508` / `2472483` |
| Persistence | Finite database-only retries/deadlines, cancellation-safe managed pool, atomic audited bulk revoke, stable pages, session capacity and real persisted races | [Database evidence](../review-remediation/database-evidence.md), ADR-7/23/24, `f039373` / `ab922c0` / `9c095e6` |
| WebAuthn | Independent signed software authenticator, production verifier negatives and workflow integration; accurate direct-attestation boundary | [Plan 66](../plans/66-prove-webauthn-ceremonies-and-document-attestation-trust.md), ADR-25, `522abcc` |
| Runtime/operations | Cached OpenAPI bytes, shared admission/timeouts, embedded parity, secret-free diagnostics, durable actor/subject audit and atomic key CLI | [Operational evidence](../review-remediation/operational-evidence.md), ADR-4/17/26, `2372a53` / `a05b4e6` / `9aa1972` / `0dcd5ba` |
| Historical clauses | 156 remaining clauses independently checked in 54 source/test/policy groups, plus prior explicit diagnostic acceptance | [Historical evidence](../review-remediation/historical-evidence.md), `1e3bbae` / `ea5d942` / `195f114` |

Historical verification found two further gaps rather than assuming earlier completion was enough.
ID-token diagnostics still had the exception described in ADR-13; the wrapper now redacts and
requires explicit wire serialization. The original session-kind migration also defaulted legacy
machine rows to interactive. Additive 0043 repairs actor/service-account associations and sessions
without refresh-token evidence, makes unknown writers default to machine, rejects NULL/unknown
kinds and removes the interactive read fallback. Authorize separately refuses a stored actor
when the token omits act. The populated pre-0043 fixture asserts each row's actual kind, and
corrupt-schema plus core mismatch regressions pass. EP-3 was reopened and reaccepted for this fix.

The owner's input compatibility choice is preserved: existing long login IDs still authenticate;
new identity writes have the 256-character cap. No truncation or forced renaming was introduced.

## Tested candidate

At `1daf36ca2652e320c343754c84656688ab5af1d6`, these passed:

```bash
cabal build all
cabal test all --test-show-details=failures --test-options=-j2 -j1
just build-embedded-with-en
just migration-check
just adr-validate
just reviews-validate
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
okf validate docs/friction-log --strict --profile docs/friction-log/profile.dhall --profile-enforce --log-enforce
nix fmt -- --fail-on-change
python3 scripts/check-review-inventory.py --closed
git diff --check
scripts/review-remediation-load.sh --scenario all --output /tmp/shomei-review-load-candidate.json
```

All **14 workspace suites** passed. The independently solved embedded en library/executable builds.
The manifest and namespace checks cover all 43 migrations; ADR and friction strict enforcement pass
26 and four concepts respectively. Review enforcement at the candidate covers the preserved 11
reviews; the closure commit validates all 12. The real CLI help/obsolete-password-argv/empty-input
checks and the shipped Dhall example also pass. See [integration receipt](../review-remediation/integration-evidence.md).

The final load completed in **18,016.481 ms**, with zero unexpected HTTP errors. It paged all
10,000 sessions in 51 requests at 200/page, revoked all 10,000 and persisted 10,000 audit events
in 379.982 ms. All 1,000 OpenAPI responses exactly matched the cached 104,380-byte document;
post-warmup RSS growth was 6,272 KiB against the fixed 32,768 KiB limit. Four Argon2 login workers
completed 209 attempts over ten seconds with two hashing permits, 100 probes and peak process RSS
207,056 KiB. The 70 deliberate preflight 401 responses are separately counted. Idle/loaded probe
p50 was 1.08/47.39 ms, with loaded p95/p99 113.54/172.88 ms. These are local measurements,
not latency SLOs. [Whitelisted aggregate JSON](../review-remediation/load-candidate.json) contains
no credentials or raw exceptions.

Stable performance comparisons are structural: a 200-row page replaces an unbounded 10,000-row
response; one audited SQL unit of work replaces per-row application revocation/audit dispatches;
1,000 cached renderer calls allocate 32,000 bytes versus 2,945,392,000 uncached. SQL still performs
necessary per-row mutation/audit work. Query counters measure logical interpreter operations,
not physical wire round trips. Historical MasterPlan 6 measurements are explicitly superseded
as current guarantees, with original outcomes preserved.

## Upgrade requirements and retained exposure

Stop old writers for the TOTP envelope/state upgrade, retain a trusted matching database/key
backup, migrate, inspect/convert offline, verify no legacy envelopes remain, then start new hosts.
A historical ciphertext transplant cannot be detected retroactively. Old binaries cannot read
converted envelopes. Migration 0043 can require affected backing-account users to authenticate
again; old or direct SQL writers cannot silently create interactive authority. Table scans,
backfills and index/constraint locks require a populated-host maintenance window.

After those state prerequisites, configure bounded dual actor readers before allowing object
emission. Legacy emission must expire plus skew before the read cutoff. Keep upgraded readers
during format rollback; do not roll the issuer back across the state-migration boundary.
The final documentation clarification makes this ordering explicit in token-compatibility.md.

Existing deliberate policies remain visible, with mitigations tested: ES256's plausible timing
exposure with RS256 available, fully trusted registered OAuth clients without per-user consent,
signup duplicate disclosure, reset/verification hit/miss database cost, default indefinite audit
PII retention, and the direct-library suspended-account distinction. The one inapplicable index
observation concerns parent hard deletes the soft-delete model never executes; a future hard-delete
feature must supply its own measured indexes. No new defect was converted into a risk waiver.

Direct attestation conveyance does not implement device trust. The downstream audit file contract
is single process/file with synchronous append/fsync and fail-closed reads, not a cross-system
transaction or general compliance guarantee. Fixed-load RSS is a bounded-duration observation
including the co-resident generator; it does not prove long-duration behavior for arbitrary load.
PostgreSQL 17 was exercised here; the documented dependency contract also supports 18, which was
not run in this session. Reader-applied standalone en-client guidance was source-checked; no
production en-server or external HIBP service was used.

Strict improvement-request validation reports missing recommended review provenance on unrelated
IR-1, IR-2 and IR-4 after IR-3 receives its actual implementation review entry. Profile/log
enforcement passes all four requests. No human verification or independent review provenance was
invented. FRIC-1 is accepted with explicit Tasty concurrency, FRIC-2 resolved by released smtp-mail,
and FRIC-3/4 accepted with tested server deadlines/managed-pool workarounds; no friction remains logged.
