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
---

# Complete OAuth and JWT Wire Validation

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Make OAuth/JWT wire behavior explicit and bounded: standards-shaped PKCE and actor claims, robust bearer parsing, bounded accepted token lifetimes, and intentional correlation semantics. Cover REV-2 §23, REV-3 §§7,9, and REV-7 §§13,16 rather than closing only one subitem.


## Progress


- [ ] M1: PKCE and HTTP credential parsing reject malformed values and accept valid interoperability cases.
- [ ] M2: actor claims, token lifetime policy, and correlation behavior have upgrade-safe producer/consumer tests.
- [ ] M3: every original HTTP interoperability and negative-test subitem has evidence.


## Surprises & Discoveries





## Decision Log


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective





## Context and Orientation


`shomei-core/src/Shomei/OAuth/TokenGrant/Workflow.hs` hashes verifiers without shape validation. `shomei-jwt/src/Shomei/SigningKey/Sign/Jwt.hs` emits string `act`; `Verify/Jwt.hs` parses claims. `shomei-servant/src/Shomei/Servant/Auth.hs`, `Servant/OAuth.hs`, and `Shomei/OAuth/Handler.hs` parse bearer/client credentials. `examples/microservice-auth-stack/src/Downstream/Service.hs` is an independent verifier consumer. [ADR-3](../adr/0003-jwt-verification-is-an-explicit-strict-trust-boundary.md) [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md) preserve strict algorithm/key selection, configuration consistency, redaction, and bounded unknown-key refresh.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 checks PKCE verifiers as 43–128 ASCII characters from letters, digits, hyphen, dot, underscore, and tilde before hashing. Test invalid verifiers whose S256 digest deliberately matches a stored challenge. Parse the bearer scheme case-insensitively while rejecting empty, multiple, ambiguous, or control-character credentials. Apply the same rule to the downstream example. Decode client_secret_basic form-encoded components according to the OAuth contract, testing separators and malformed encodings without exposing secrets. Consult the authoritative RFCs during implementation before modifying exact whitespace/percent-decoding behavior.

M2 emits actor as an object with a single `sub` identity and teaches the verifier to accept both that form and the legacy string during one documented compatibility window. Malformed present actor claims must fail closed rather than become an ordinary token. First demonstrate issuer → standalone verifier → downstream verifier → introspection with both forms. Keep actor chains refused. Introduce an explicit maximum accepted access-token lifetime defaulting to the maximum configured human, machine, and delegation issuance TTL; deployments using the standalone verifier set a finite value matching their issuer. Reject exp <= iat and exp - iat above the configured maximum; skew affects timestamp comparisons, not the lifetime budget. Validate policy before startup and document upgrade ordering. Retain `sid` as the correlation identifier: absence of a minted `jti` is an explicit design disposition, not an unfinished promise of per-token revocation. Reserve `jti` against extension injection. Retain ADR-3's existing typ compatibility window unless the deployment has separately coordinated expiry of old tokens.

M3 enumerates REV-7 §§13,16 and proves Origin null, disallowed Origin plus allowed Referer, HEAD/OPTIONS handling, cross-client revoke, bespoke OAuth refresh refusal, non-UTF-8 headers, chunked bodies, plain PKCE refusal, scoped UserInfo, and freshness after refresh. Reuse existing passing cases when they assert the exact behavior. Consent remains the documented trusted-client model. Malformed admin captures may keep returning 400 before authentication only with an explicit rationale that parsing reveals syntax, not resource existence. Check the now-implemented token-exchange discovery, refresh introspection fallback, and missing-credential challenge rather than rewriting them.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-core shomei-jwt shomei-servant microservice-auth-stack --test-show-details=failures -j1
cabal test shomei-server-config-test --test-show-details=failures
just adr-validate
```


## Validation and Acceptance


PKCE boundary values and all legal alphabet characters work; too-short/long/illegal but digest-matching inputs fail. Lowercase bearer succeeds where uppercase did. No malformed actor can lose its delegation identity. Old/new actor forms verify during the documented window; unsupported shapes fail. Excess-lifetime tokens signed by a trusted key are rejected. Existing key-selection/algorithm/unknown-key protections remain intact.


## Idempotence and Recovery


Deploy dual-reading verifiers before object-emitting issuers, and preserve old-string reading until the longest accepted old token has expired. A tightened lifetime ceiling requires an inventory of issuer TTLs; do not accidentally invalidate longer legitimate machine tokens. Keep any temporary compatibility switch bounded and documented. Do not alter signing algorithms or keys as part of this plan.


## Interfaces and Dependencies


Owns actor wire representation, bearer parser, verifier lifetime setting, and PKCE policy. Integrates with docs/plans/63-bound-authentication-inputs-and-passkey-enrollment.md on errors/configuration and docs/plans/67-bound-runtime-costs-and-complete-operational-diagnostics.md on downstream audit actor extraction. No hard dependency; agree claim representation before auditing consumers. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.
