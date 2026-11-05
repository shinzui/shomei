---
id: 67
slug: bound-runtime-costs-and-complete-operational-diagnostics
title: "Bound Runtime Costs and Complete Operational Diagnostics"
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
      note: "Security review: admission cap unpaired with slow-client timeout; k-anonymity prefix not in redaction list; REV-8.17 key-state rows unnamed"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T06:09:13Z
      mode: "update"
      note: "Paired admission cap with slow-client timeout; HIBP prefix redaction; REV-8.17 and REV-10.7.1 rows enumerated"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T13:10:19Z
      mode: "implement"
      note: "Accept clause inventory and begin MasterPlan 9 implementation"
---

# Bound Runtime Costs and Complete Operational Diagnostics

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Remove recurring OpenAPI encoding work and make operational behavior observable and bounded in standalone and embedded hosts. Complete the downstream delegated-action audit example and each remaining operational subitem of REV-8 §17, plus REV-7 §14 and REV-10 §6.


## Progress


- [ ] M1: OpenAPI bytes are cached without changing API schema or media type.
- [ ] M2: shared host runtime exposes admission/bind policy and secret-free failure diagnostics.
- [ ] M3: audit CLI identities and downstream actor/subject audit records work end to end.


## Surprises & Discoveries





## Decision Log


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective





## Context and Orientation


`shomei-servant/src/Shomei/Servant/OpenApi.hs` caches a JSON Value; `Servant/Api.hs` and `Servant/Server.hs` serve it. `shomei-server/src/Shomei/Server/Boot.hs` owns Warp assembly (it sets port, proxy protocol, graceful shutdown, and exception handling, but no `Warp.setTimeout`, so the slow-client timeout is Warp's default), `Server/Observability/Logging.hs` emits info for all responses, and `Server/BreachChecker.hs` handles password breach lookups. `shomei-server/app/Shomei/Admin/Audit.hs` parses audit CLI identifiers. `examples/microservice-auth-stack/src/Downstream/Service.hs` currently returns actor identity only. [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) [ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md) [ADR-18](../adr/0018-downstream-jwks-refresh-is-bounded-by-local-policy.md) require synchronized settings, secret-free diagnostics, host parity, and bounded JWKS work.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 introduces a cached serialized OpenAPI representation with the same application/json response. Preserve typed schema generation and the client route contract, using a dedicated response wrapper or a carefully documented route change rather than double-encoding bytes as a JSON string. Compare response bytes to the generated schema and measure repeated-request allocations at a fixed request count; require encoding to occur once per document version. Do not add an endpoint-specific cache that only works in the standalone executable.

M2 exposes an explicit bind host and connection admission setting through shared Warp settings assembly used by standalone and embedded examples. Default bind behavior remains documented; admission defaults to a finite 1024 simultaneous accepted connections, with positive configurable limits. Verify actual connection lifecycle hooks through Mori-located Warp source before choosing the implementation. Release permits on disconnect, exceptions, and shutdown; reject surplus connections promptly rather than accumulating waiting threads. An admission cap is an availability control that an attacker holding idle connections can fill, so it ships together with an explicit, documented slow-client timeout in the same shared settings, and the capacity documentation states that per-client limits belong at the reverse proxy. HTTP request concurrency and reverse-proxy admission are separate limits and must not be described as equivalent. Hosts using another server receive an explicit equivalent contract. Use error severity for 5xx, warning for 429, and info for ordinary responses including 401; document why attacker-triggered 401s do not each become warnings. Expose HIBP dependency failures through a bounded reason-code metric/log without passwords, hashes, the five-character k-anonymity prefix, query strings, or raw exceptions. Keep the existing configured fail-open/closed policy. Document that boot migration plus entrypoint invocation is idempotent and serialized; remove redundant invocation in shipped deployment assembly where both are currently enabled, without removing embedded-host migration guarantees.

M3 lets the audit CLI accept canonical TypeIDs as well as legacy UUID input and emit canonical TypeIDs consistently with role commands. Add an injectable downstream audit sink and a runnable example that writes structured actor, subject, action/resource, result, and request correlation to a local append-only event file. Never log bearer tokens. For the demonstrated protected action, failed audit persistence fails the action before success is returned. Test both ordinary and delegated tokens, rejected actions, sink failures, and concurrent complete-line writes. Document file permissions, rotation, forwarding, and that the example is not a general compliance storage product. Reconcile SMTP plain-with-credentials warnings, non-loopback webhook HTTP warnings, inherited HTTP proxy behavior, and trimmed secret inputs against existing tests rather than assuming all of REV-8 §§11,12,17 are closed. M3 also closes, with named tests or exact decision citations, the remaining ledger rows this plan owns: REV-8.17.1 atomic key activation, REV-8.17.2 atomic key rewrap, REV-8.17.3 multiple active keys failing closed ([ADR-4](../adr/0004-one-active-signing-key-is-a-database-invariant.md) is the decision citation; the rows still need test names and the tested commit), REV-8.17.7 sanitized admin database errors, and REV-10.7.1 JWKS cache-control documentation.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-servant shomei-client shomei-server microservice-auth-stack embedded-servant-app --test-show-details=failures -j1
cabal run -v0 shomei-openapi > /tmp/shomei-mp9-openapi.json
just adr-validate
```


## Validation and Acceptance


Inventory acceptance includes every assigned ledger row: REV-7.14, REV-8.17, REV-10.6, REV-8.17.1, REV-8.17.2, REV-8.17.3, REV-8.17.4, REV-8.17.5, REV-8.17.6, REV-8.17.7, REV-8.17.8, REV-8.17.9, REV-8.17.10, REV-10.7.1, EXTRA-3. Each row needs its own exact evidence or an explicit cross-reference to evidence covering the same clause; parent closure also requires all child rows.


OpenAPI responses parse to the same document and repeated requests do not reserialize it. Filling the connection limit rejects the next connection, then disconnecting one admits another with no leaked permit. Standalone and embedding settings exercise the same implementation. HIBP outages are visible without sensitive input. Copying a role CLI user ID into audit filters works. A delegated action produces a persisted record with distinct actor and subject; sink failure cannot be reported as an audited success.


## Idempotence and Recovery


Keep default public routes stable. Deploy stricter connection settings with a documented capacity calculation and monitoring; rollback changes configuration rather than bypassing shared runtime assembly. The audit file fixture is temporary and private. Do not mutate production logs or perform external notifications during tests.


## Interfaces and Dependencies


Owns cached response representation, shared Warp settings, operational logs, CLI presentation, and downstream audit sink. Integrates with docs/plans/64-complete-oauth-and-jwt-wire-validation.md on actor wire decoding and docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md on database-limit diagnostics. No hard dependency; demonstrate existing string actor first, then reconcile the new object form before both complete. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.


## Revision Notes


2026-11-03: Security-focused review paired the admission cap with an explicit slow-client timeout, added the k-anonymity prefix to the HIBP redaction list, and enumerated the REV-8.17 key-state and REV-10.7.1 ledger rows this plan owns.
