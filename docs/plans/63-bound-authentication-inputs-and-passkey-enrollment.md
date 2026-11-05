---
id: 63
slug: bound-authentication-inputs-and-passkey-enrollment
title: "Bound Authentication Inputs and Passkey Enrollment"
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
      note: "Security review: login never applies password maximum; oversized-input semantics under ADR-5 unspecified"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T06:09:13Z
      mode: "update"
      note: "Added login-path gap, request-shape semantics for oversized login input, unused passkey count port"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-05T13:10:19Z
      mode: "implement"
      note: "Accept clause inventory and begin MasterPlan 9 implementation"
---

# Bound Authentication Inputs and Passkey Enrollment

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current.


## Purpose / Big Picture


Bound attacker-controlled field sizes and passkey enrollment growth at the library and HTTP boundaries, including concurrent requests. This closes REV-7 §8 and the uncapped-passkey part of REV-2 §23 without allowing malformed JSON to bypass smart constructors.


## Progress


- [x] (2026-11-05) M1: bounded constructors/JSON and signup/store validation enforce Unicode and UTF-8 budgets; oversized login passwords produce HTTP 400 with zero real/dummy hash calls, attempts, lockout changes or audit. Boundary and legacy HTTP tests pass.
- [x] (2026-11-05) M2: account-row serialization and atomic fake storage enforce the explicit 1–100 ceiling (default 20). Eight database racers have one winner; two workflow completions produce one success audit. HTTP quota refusal returns 409 with the documented code; lowered limits preserve existing credential access/removal. Core/PostgreSQL/Servant/server gates pass with Tasty -j2.
- [x] (2026-11-05) M3: explicit persisted-user/credential/audit compatibility decoders and login/recovery parsing preserve legacy identities. Migration 0039 bounds only inserted/changed fields; real PostgreSQL tests preserve oversized rows through status updates. Read-only count report and rollout guide are published. All eight focused suites pass.


## Surprises & Discoveries

2026-11-05: The OpenAPI regression gate caught the new quota error missing its public anchor. The runtime catalog and problem-details guide now include `passkey_limit_reached`, and the focused HTTP/OpenAPI rerun passes.





## Decision Log

2026-11-05: The owner chose to preserve password login for existing long login IDs while capping new identity writes at 256 characters. Login uses compatibility parsing; new writes use the bounded constructor. Oversized passwords remain request-shape failures before any proof work.

2026-11-05: Passkey creation now takes an explicit 1–100 ceiling and returns `Either AuthError PasskeyCredential`. PostgreSQL locks the persisted account row before counting and inserting; the in-memory interpreter makes one atomic world update. No unbounded compatibility operation is retained. ADR-21 records this contract.


2026-10-28: Deliver the stated behavior with explicit upgrade and failure semantics; preserve established product policies unless an owner explicitly changes them. New risk acceptance is not a substitute for implementing a confirmed defect.


## Outcomes & Retrospective

Accepted the owner’s legacy-login choice without truncating identities. `cabal test shomei-core shomei-postgres shomei-servant shomei-server --test-show-details=failures --test-options=-j2 -j1` passes all eight suites, including `new identity limits count Unicode code points and email UTF-8 bytes`, `legacy identity snapshots and password login survive new-write limits`, `oversized passwords reject known and unknown accounts without proof work or state changes`, `new-write field budgets preserve legacy rows and security updates`, and `input boundaries and legacy HTTP login`. ADR-22 and `docs/user/input-limits.md` distinguish compatibility parsers from new writes. No new friction under this milestone. Ledger closure awaits the implementation commit identifier.





## Context and Orientation


`shomei-core/src/Shomei/Account/LoginId/Domain.hs` and `Account/Email/Domain.hs` normalize values but currently derive JSON decoding and impose no size ceiling. `shomei-core/src/Shomei/Account/Password/Domain.hs` defines the 256-code-point maximum, but `validatePassword` is applied only by `signup` in `shomei-core/src/Shomei/Session/Authentication/Workflow.hs` and by the change/reset paths in `Account/Lifecycle/Workflow.hs`; `login` and `shomei-servant/src/Shomei/Account/Handler.hs` build `PlainPassword` straight from the request. `Shomei.Passkey.Store` exposes `countPasskeysByUser`, but the authentication workflow uses it only to route login and no caller enforces a ceiling. `shomei-core/src/Shomei/Passkey/Workflow.hs` registers after ceremony verification; `shomei-core/src/Shomei/Passkey/Store.hs` and `shomei-postgres/src/Shomei/Passkey/Postgres.hs` own storage. `shomei-servant/src/Shomei/Account/Handler.hs` and the passkey/role handlers are HTTP entry points. [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) require database-enforced races, synchronized strict configuration, and redacted diagnostics.

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`. Use the existing development shell when tools are absent (`nix develop`), without searching or reading `/nix/store`. Tests use the existing ephemeral PostgreSQL harness; never aim destructive fixtures at a deployment database. Locate dependency APIs with `mori registry search`, `mori registry show --full`, and `mori registry docs`; read source before coding. Before changing dependency bounds or choosing a compatibility workaround, verify the current released version against the authoritative registry and upstream tags. Preserve concurrent workspace edits and the current branch.

Each milestone updates its rows in [the finding ledger](../review-remediation/findings.md) with actual test names, commands, result, and commit. A historical plan marked complete is not fresh acceptance evidence. Update public guides and package changelogs for behavior/API changes. Record durable decisions through `agents/skills/exec-plan/ADR.md`, and implementation friction through `agents/skills/exec-plan/FRICTION.md`.


## Plan of Work


M1 introduces shared validation functions for new writes: normalized login IDs at most 256 Unicode code points, email at most 254 UTF-8 bytes, display name at most 256 code points, passkey label at most 128 code points, and role/scope names at most 128 Unicode code points while preserving the current accepted character vocabulary. Preserve the current password policy maximum of 256 code points and enforce it for login as well as creation/change/reset. At login, an oversized password is a request-shape rejection made before user lookup and before any real or dummy Argon2 work: it uses the existing invalid-input error vocabulary, its status and timing do not vary with account existence, it records no login attempt and changes no lockout state because no credential proof was presented ([ADR-5](../adr/0005-every-credential-proof-participates-in-one-abuse-budget.md) budgets proofs, not malformed requests), and it still passes through the edge request throttle. Validate before normalization copies or expensive hashing where possible; also validate the normalized result. Login identifiers above the new-write ceiling remain admissible for legacy authentication under the owner decision on 2026-11-05; do not rename or truncate them. Do not echo rejected values. Replace derived JSON decoders that bypass constructors; map errors to the established domain/HTTP vocabulary and update OpenAPI schemas. Check role captures and CLI inputs, not only JSON bodies.

M2 adds a default maximum of 20 passkeys per account, configurable to 1–100 through the core config, environment loader, and Dhall schema. A begin-time check is only an optimization. The persistence operation must atomically lock the account enrollment namespace, count, and insert, returning a typed limit result; mirror this in the in-memory interpreter. Two completions racing for the last slot must yield exactly one stored credential and one success audit event. Do not delete a user's existing credentials to satisfy a lowered cap; existing credentials remain usable and removable while further enrollment is refused.

M3 supplies a read-only compatibility report for oversized legacy identifiers/labels and documents new-write enforcement. Persisted legacy identities must remain readable and usable for authentication without silently truncating or renaming them; distinguish compatibility decoding from new-value construction. Prove this for direct callers and wire DTOs before making generic JSON stricter. Legacy credentials with passwords beyond the established maximum require a documented reset flow rather than silently modifying password bytes. Add boundary tests using multibyte text and concurrent enrollment.


## Concrete Steps


Run the focused gates after implementing the milestone assertions; expected result is passing suites and no new profile or migration errors. The previous full workspace pass is a baseline, not evidence for new changes.

```bash
cabal test shomei-core shomei-postgres shomei-servant shomei-server --test-show-details=failures -j1
just adr-validate
```


## Validation and Acceptance


Inventory acceptance includes every assigned ledger row: REV-7.8, REV-2.23.5. Each row needs its own exact evidence or an explicit cross-reference to evidence covering the same clause; parent closure also requires all child rows.


For each field, the exact boundary is accepted and one unit over is refused through both direct calls and HTTP. Oversized login passwords do not reach real or dummy Argon2 work; preserve existing constant-work behavior for normal-sized invalid credentials. Concurrent enrollment cannot exceed the configured limit. Existing oversized stored identifiers and existing passkeys are not rendered unreadable or deleted.


## Idempotence and Recovery


Validation changes need no destructive cleanup. Run the compatibility report before rollout; fix configuration rather than truncating stored data. New persistence operations and any constraints must permit existing rows to be read. Roll back code together with public API version changes; retain additive schema.


## Interfaces and Dependencies


Owns common field validation and passkey quota policy. Plan docs/plans/64-complete-oauth-and-jwt-wire-validation.md owns PKCE and bearer parsing and must reuse error conventions. Plan docs/plans/65-bound-database-work-and-make-bulk-session-revocation-atomic.md owns generic transaction policy; enrollment atomicity must work independently. Schema/loader changes follow ADR-8 with explicit field ownership. Before M2, require the accepted ledger/subitem allocation from M1 of `docs/plans/68-verify-every-review-finding-and-publish-closure-evidence.md`. M1 may establish the representative regression first. This is a milestone prerequisite, not a dependency on the whole closure plan.


## Revision Notes


2026-11-03: Security-focused review added the verified login-path gap (the password maximum is applied at signup, change, and reset but not at login), the request-shape semantics of oversized login input under ADR-5, and the existing unused passkey count port. Scope unchanged.
