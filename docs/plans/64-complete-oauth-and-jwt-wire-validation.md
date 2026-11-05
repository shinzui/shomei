---
id: 64
slug: complete-oauth-and-jwt-wire-validation
title: "Complete OAuth and JWT Wire Validation"
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
      note: "Security review: non-string act verifies as ordinary token today; verifier lifetime ceiling optional; REV-3/REV-10 rows unnamed"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T06:09:13Z
      mode: "update"
      note: "Actor fail-closed moved to M1; lifetime ceiling required finite; challenge-shape fact; REV-3/REV-10 rows enumerated"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T13:10:19Z
      mode: "implement"
      note: "Accept clause inventory and begin MasterPlan 9 implementation"
---

# Complete OAuth and JWT Wire Validation

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Make OAuth/JWT wire behavior explicit and bounded: standards-shaped PKCE and actor claims, robust bearer parsing, bounded accepted token lifetimes, and intentional correlation semantics. Cover REV-2 §23, REV-3 §§7,9, and REV-7 §§13,16 rather than closing only one subitem.


## Progress


- [x] (2026-11-05) M1: digest-matching invalid PKCE inputs fail, bearer syntax is shared by server/downstream, malformed Basic percent escapes fail, and present malformed actors are rejected by both verifier and downstream HTTP tests. Core/JWT/Servant/downstream gates pass with Tasty -j2.
- [x] (2026-11-05) M2: object actors and finite legacy read/emission windows pass real issuer → standalone verifier → introspection and independent downstream HTTP tests. Legacy emission fits expiry plus skew before cutoff. Required finite lifetime policy, cutoff/default/config negatives, and direct extension-bag protection pass. The downstream CLI builds and refuses a zero ceiling at startup.
- [x] (2026-11-05) M3: HTTP/CSRF/protocol cases and strict JWT/JWKS cases pass. Newly added tests cover Origin-null, Origin-over-Referer precedence, native HEAD/OPTIONS auth, malformed percent escapes, lowercase/multi-space bearer and duplicate headers. Existing refresh/revoke/UserInfo/freshness/chunked-body cases were checked against source and rerun.


- [x] (2026-11-05) M4: additive migration 0043 repairs populated legacy actor, machine and missing-refresh provenance, defaults omitted writes to machine and rejects NULL/unknown kinds. The core refuses a stored actor even if act is omitted. Core, PostgreSQL and migration suites pass, including per-row upgrade assertions and a corrupt-schema read negative. Historical clause ownership remains EP-7.

## Surprises & Discoveries

2026-11-05: Migration 0029 defaulted existing machine rows to interactive. Integration adds additive 0043 to recover actor/service-account provenance and give unknown writers a conservative default, plus a populated old-schema upgrade regression.

2026-11-05: Using the same instant for the last legacy emission and last legacy read would strand still-valid tokens minted just before cutoff. Legacy issuance now requires the token expiry plus issuer skew to fit inside the read window; otherwise it automatically emits an object. ADR-3 and the upgrade guide preserve this constraint.

2026-11-05: Existing HTTP coverage lacked Origin-null, foreign-Origin/allowed-Referer precedence, and native HEAD/OPTIONS auth-handler checks. They are now explicit. Duplicate Authorization headers are rejected before Servant collapses them to one Header value, retaining OAuth error bodies on OAuth paths.





## Decision Log

2026-11-05: Actor fail-closed validation is committed before any object emission or compatibility change. Shared bearer syntax follows RFC 6750 section 2.1: case-insensitive scheme, ASCII space separators, token alphabet and terminal padding. Explicit malformed/duplicate Authorization is invalid credentials and never falls back to a cookie. Basic form components are decoded once after splitting the separator; malformed percent escapes fail before credential comparison.


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective

2026-11-05: All wire implementation milestones are accepted. Core/JWT/Servant/server/downstream suites pass with explicit Tasty -j2; the last validation reran JWT, Servant, server and downstream after the additional HTTP cases. `example-project-service` builds, and a zero `DOWNSTREAM_MAX_TOKEN_LIFETIME_SECONDS` fails startup with the named configuration error. ADR-3 and the token-compatibility guide define the format transition, finite lifetime policy and session correlation contract. The compound REV-2.23 parent is now terminal: plan 66 removed the dead clone branch at `522abcc`, and plan 68 verified redaction plus the documented direct-library suspended-account distinction at `1e3bbae`. All owned ledger rows are terminal. EP-7 later reopened this child for the legacy default gap; M4 now passes and ADR-1 plus deployment.md describe the stricter upgrade. No implementation friction was recorded under this child.





## Context and Orientation


`shomei-core/src/Shomei/OAuth/TokenGrant/Workflow.hs` hashes verifiers without shape validation; `shomei-core/src/Shomei/OAuth/Authorize/Workflow.hs` already requires `code_challenge_method=S256` and checks that the challenge is 43 unpadded base64url characters (`isValidS256Challenge`), so only the verifier side is open. `shomei-jwt/src/Shomei/SigningKey/Sign/Jwt.hs` emits string `act`; `Verify/Jwt.hs` parses claims, and its `claimsToAuth` originally read `act` through `lookupString`, silently treating non-string JSON as absent. M1 now checks presence directly and rejects unsupported objects, arrays, numbers and null instead of discarding the actor. `VerifierSettings` now requires a finite lifetime ceiling and an optional finite legacy actor deadline; object emission and bounded legacy emission are coordinated through `SigningKeyConfig`. `shomei-servant/src/Shomei/Servant/Auth.hs`, `Servant/OAuth.hs`, and `Shomei/OAuth/Handler.hs` parse bearer/client credentials. `examples/microservice-auth-stack/src/Downstream/Service.hs` is an independent verifier consumer. [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md) [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md) preserve strict algorithm/key selection, configuration consistency, redaction, and bounded unknown-key refresh.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 first makes a present actor fail closed: any `act` value that is not a parseable identity in an accepted form is `TokenMalformed`, never `Nothing`, with regressions for object, array, number, null, and empty-string actors in the `shomei-jwt` tests and in the downstream example. This is a defect in the current verifier, not part of the compatibility window, so it lands before any issuer change. M1 then checks PKCE verifiers as 43–128 ASCII characters from letters, digits, hyphen, dot, underscore, and tilde before hashing. Test invalid verifiers whose S256 digest deliberately matches a stored challenge. Parse the bearer scheme case-insensitively while rejecting empty, multiple, ambiguous, or control-character credentials. Apply the same rule to the downstream example. Decode client_secret_basic form-encoded components according to the OAuth contract, testing separators and malformed encodings without exposing secrets. Consult the authoritative RFCs during implementation before modifying exact whitespace/percent-decoding behavior.

M2 emits actor as an object with a single `sub` identity and teaches the verifier to accept both that form and the legacy string during one documented compatibility window. Malformed present actor claims must fail closed rather than become an ordinary token. First demonstrate issuer → standalone verifier → downstream verifier → introspection with both forms. Keep actor chains refused. Introduce an explicit maximum accepted access-token lifetime. On the issuer it defaults to the maximum configured human, machine, and delegation issuance TTL. In `VerifierSettings` for standalone and downstream verifiers it is a required finite field with no unbounded option; constructing settings without it fails, and the downstream example and documentation show the value matching the issuer's longest TTL. Reject exp <= iat and exp - iat above the configured maximum; skew affects timestamp comparisons, not the lifetime budget. Validate policy before startup and document upgrade ordering. Retain `sid` as the correlation identifier: absence of a minted `jti` is an explicit design disposition, not an unfinished promise of per-token revocation. Reserve `jti` against extension injection. Retain ADR-3's existing typ compatibility window unless the deployment has separately coordinated expiry of old tokens.

M3 enumerates REV-7 §§13,16 and proves Origin null, disallowed Origin plus allowed Referer, HEAD/OPTIONS handling, cross-client revoke, bespoke OAuth refresh refusal, non-UTF-8 headers, chunked bodies, plain PKCE refusal, scoped UserInfo, and freshness after refresh. Reuse existing passing cases when they assert the exact behavior. Consent remains the documented trusted-client model. Malformed admin captures may keep returning 400 before authentication only with an explicit rationale that parsing reveals syntax, not resource existence. Check the now-implemented token-exchange discovery, refresh introspection fallback, and missing-credential challenge rather than rewriting them. M3 also closes, with named tests or exact decision citations, the ledger rows this plan owns beyond REV-7: REV-3.7.1 strict list claims (`lookupStringList` fails closed today), REV-3.7.2 exact single audience, REV-3.7.4 `nbf`/`jti` reserved against extension claims, REV-3.9.1 JWKS `alg` metadata, REV-3.9.3 public-key projection failing closed, REV-10.7.2 safe `Authorization` decoding in the downstream example (it decodes leniently today), REV-10.7.3 the 401 Bearer challenge, and REV-10.7.4 skew and algorithm policy. [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md) is the decision citation for the rows it already covers; each row still needs the test name and tested commit.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-core shomei-jwt shomei-servant microservice-auth-stack --test-show-details=failures -j1
cabal test shomei-server-config-test --test-show-details=failures
just adr-validate
```


## Validation and Acceptance


Inventory acceptance includes every assigned ledger row: REV-2.23, REV-3.7, REV-3.9, REV-7.13, REV-7.16, REV-2.23.1, REV-2.23.2, REV-3.7.1, REV-3.7.2, REV-3.7.3, REV-3.7.4, REV-3.9.1, REV-3.9.2, REV-3.9.3, REV-7.13.1, REV-7.13.2, REV-7.13.3, REV-7.13.4, REV-7.13.5, REV-7.13.6, REV-7.13.7, REV-7.16.1, REV-7.16.2, REV-7.16.3, REV-7.16.4, REV-7.16.5, REV-7.16.6, REV-7.16.7, REV-7.16.8, REV-7.16.9, REV-7.16.10, REV-7.16.11, REV-10.7.2, REV-10.7.3, REV-10.7.4. Each row needs its own exact evidence or an explicit cross-reference to evidence covering the same clause; parent closure also requires all child rows.


PKCE boundary values and all legal alphabet characters work; too-short/long/illegal but digest-matching inputs fail. Lowercase bearer succeeds where uppercase did. No malformed actor can lose its delegation identity: a present non-string or unparseable `act` is rejected by both the standalone verifier and the downstream example. A verifier cannot be constructed without a finite lifetime ceiling. Old/new actor forms verify during the documented window; unsupported shapes fail. Excess-lifetime tokens signed by a trusted key are rejected. Existing key-selection/algorithm/unknown-key protections remain intact.


## Idempotence and Recovery


Deploy dual-reading verifiers before object-emitting issuers, and preserve old-string reading until the longest accepted old token has expired. A tightened lifetime ceiling requires an inventory of issuer TTLs; do not accidentally invalidate longer legitimate machine tokens. Keep any temporary compatibility switch bounded and documented. Do not alter signing algorithms or keys as part of this plan.


## Interfaces and Dependencies


Owns actor wire representation, bearer parser, verifier lifetime setting, and PKCE policy. Integrates with docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md on errors/configuration and docs/plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md on downstream audit actor extraction. No hard dependency; agree claim representation before auditing consumers. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.


## Revision Notes


2026-11-03: Security-focused review moved the fail-closed actor check into M1 because the current verifier silently drops any non-string `act`, made the verifier lifetime ceiling a required finite setting, recorded that `/authorize` already validates challenge shape, and enumerated the REV-3 and REV-10 ledger rows this plan owns. Acceptance gained the actor and lifetime assertions; scope is otherwise unchanged.
