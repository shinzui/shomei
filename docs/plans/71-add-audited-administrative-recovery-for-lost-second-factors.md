---
id: 71
slug: add-audited-administrative-recovery-for-lost-second-factors
title: "Add audited administrative recovery for lost second factors"
kind: exec-plan
created_at: 2026-11-16T05:06:41Z
intention: "intention_01m7hbzef1ex6avd7fw21qtx4c"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-16T05:06:41Z
---

# Add audited administrative recovery for lost second factors

This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into `docs/adr/` before completion.

## Purpose / Big Picture


Fix [issue #3](https://github.com/shinzui/shomei/issues/3): a user who loses every enrolled second factor and has no unused recovery code cannot recover through the documented password-reset procedure. Add an audited administrator operation to clear the user's factors through both HTTP and `shomei-admin`, invalidate prior authentication state, and let the verified owner sign in with their password and enroll replacements. Correct the documentation immediately as part of this work. Password reset must continue to preserve MFA protection.

MFA means requiring a second proof after the password. TOTP is a time-based code generated from an authenticator application's shared secret. Recovery codes are previously generated single-use alternatives to that second proof. Administrator recovery is an exceptional, privileged removal of protection; the software cannot establish that a support caller is the account owner. The runbook must require independent identity verification and notification through an established contact channel.

## Progress


- [ ] Milestone 1: An atomic, audited reset clears factors and sessions, and real PostgreSQL tests prove rollback and exclusion of stale authentication/enrollment work.
- [ ] Milestone 2: Authorized HTTP and CLI callers recover a fixture account through the shared workflow; unauthorized and malformed requests make no changes.
- [ ] Milestone 3: Notification, documentation, client/schema coverage, and an end-to-end recovery/re-enrollment test establish the supported operator procedure.

Planning only: implementation has not begun. The linked intention was created with `mina ci --json 'Recover accounts after loss of all second factors'`.

## Surprises & Discoveries


## Decision Log


2026-11-15: Choose the issue's administrative recovery option, including CLI, HTTP, and corrected documentation. Merely documenting direct SQL would leave operators without a supported atomic and audited operation.

2026-11-15: Keep password reset independent of factor reset. Require an explicit operator assertion of identity verification, a bounded case reference, and a server-derived actor. Never issue tokens or mark email verified as a consequence of administrator recovery. This preserves the distinction between changing a password and removing MFA.

2026-11-15: Use a per-user authentication generation plus transaction checks to reject work begun before recovery. Deleting pending challenges alone is insufficient because an in-flight request may already have consumed its challenge and loaded a credential.

2026-11-15: Preserve existing access-token verification modes. Refresh tokens are revoked immediately; already issued access tokens can survive their expiry window under `VerifyTokenOnly`. Recovery-sensitive routes must check a live backing session even in that mode. Do not claim immediate rejection by offline token verifiers.

## Outcomes & Retrospective


## Context and Orientation


`shomei-core/src/Shomei/Session/Authentication/Workflow.hs` computes `hasSecondFactor = passkeyCount > 0 || totpEnrolled`. `shomei-core/src/Shomei/Mfa/Workflow.hs` consumes a pending challenge before checking the factor and delegates successful session issuance to `shomei-core/src/Shomei/Session/Workflow.hs`. `shomei-core/src/Shomei/Account/Lifecycle/Workflow.hs` handles password reset without removing those factors. Therefore the last recovery section of `docs/user/passkeys.md` is incorrect.

`shomei-core/src/Shomei/Account/Admin/Workflow.hs` already provides audited account operations. Its workflows do not authenticate callers: HTTP enforces authority in `shomei-servant/src/Shomei/Servant/Authz.hs` (`RequireAdmin` accepts role `admin` or scope `shomei:admin`). `shomei-servant/src/Shomei/Account/Admin/Api.hs`, `shomei-servant/src/Shomei/Account/Handler.hs`, and `shomei-servant/src/Shomei/Account/Result.hs` own the routes, handlers, and typed responses. Administrative handlers also reject delegated authority on sensitive mutations. `shomei-server/app/Admin.hs` and `shomei-server/app/Shomei/Admin/Users.hs` own user CLI commands; the CLI's authority is database access, not an authenticated HTTP identity.

`shomei-core/src/Shomei/Session/UnitOfWork/Store.hs` defines operations whose multiple writes must succeed or fail together. `shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs` implements them in database transactions; `shomei-core/src/Shomei/Test/InMemory.hs` implements equivalent atomic updates for tests. The project's `shomei-postgres/src/Shomei/Persistence/Transaction/Postgres.hs` provides bounded, database-only transactions. Use it rather than sequencing independent store calls or holding a transaction across cryptography or network delivery.

Factor storage lives in `shomei-postgres/src/Shomei/Passkey/Postgres.hs`, `shomei-postgres/src/Shomei/Passkey/Ceremony/Postgres.hs`, `shomei-postgres/src/Shomei/Mfa/Totp/Postgres.hs`, and `shomei-postgres/src/Shomei/Mfa/RecoveryCode/Postgres.hs`. Core ports are the corresponding `Store.hs` modules. Passkey enrollment already locks the owning user row. Audit types and encoding live in `shomei-core/src/Shomei/Audit/Event/Domain.hs` and `shomei-core/src/Shomei/Audit/Event/Codec.hs`. Notifications currently cover verification and password reset in `shomei-core/src/Shomei/Account/Notification/Domain.hs`; delivery is implemented by `shomei-server/src/Shomei/Notify.hs` and `shomei-server/src/Shomei/Notify/Queue.hs`.

Relevant consulted decisions are [ADR-2](../adr/0002-reserved-privilege-scopes-are-service-account-authority.md), which prevents OAuth clients from granting administrator scope; [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md), requiring atomic credential transitions and audits; [ADR-10](../adr/0010-notification-delivery-is-a-bounded-background-responsibility.md), defining bounded best-effort notifications; [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md), prohibiting secret-bearing diagnostics; [ADR-14](../adr/0014-administrative-bootstrap-shares-the-deployment-authentication-policy.md), preserving policy across CLI and HTTP; [ADR-21](../adr/0021-passkey-enrollment-spends-an-atomic-account-quota.md), establishing user-row enrollment serialization; and [ADR-23](../adr/0023-database-budgets-and-audited-revocation-share-persistence-boundaries.md), requiring transaction budgets and winner-only revocation audit. No existing ADR defines administrator factor recovery.

[OWASP's MFA guidance](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html#resetting-mfa) treats recovery as a potential authentication bypass and recommends planned recovery methods, rigorous support verification, and notification of factor changes. Here that means retaining recovery codes as self-service fallback, requiring verified operator intervention when all alternatives are lost, and documenting the remaining password-only interval until re-enrollment. This plan does not claim a particular identity-assurance certification or implement an identity-proofing service.

## Plan of Work


### Milestone 1: Atomic recovery and exclusion of stale work


Add `shomei-core/src/Shomei/Account/Admin/Recovery.hs` for the validated command, actor, result, and workflow. Define `RecoveryActor` with distinct authenticated-principal and local-operator constructors: a CLI operator label is asserted attribution, never proof of a human account's authentication. Require `identityVerified = true`, a case reference of 1–128 ASCII letters/digits or `._:/-`, and a CLI operator label with the same bounded character set. Reject invalid inputs before any write. Do not accept free-form identity evidence, passwords, or recovery secrets in audit metadata.

Extend `AuthUnitOfWork` with `ResetUserSecondFactors`, returning `Either AuthError RecoveryResult`. Inside one bounded transaction lock the user row, refuse unknown users and non-active users, increment an authentication generation, delete all passkeys, confirmed and pending TOTP material and recovery-code hashes, delete user-bound pending ceremonies, revoke all sessions and their refresh tokens, invalidate outstanding authorization codes and password-reset tokens for this user, and insert `user_second_factors_reset` plus session-revocation events for the sessions actually transitioned. Include actor kind/identifier, target, case reference, timestamp, and removal/revocation counts in the event. Do not alter password, email verification, roles, scopes, lockout budgets, or user status. A successful operation may have zero removal counts and must still have its own audit record. Generate identifiers before entering the transaction. Audit failure rolls back the entire operation.

Add an additive migration via `just new-migration add-authentication-generation`. Store a nonnegative monotonically increasing generation on the user, initially zero, and carry the captured generation in pending user-bound challenges and pending enrollment state. A generation is a counter identifying the authentication state observed before checking a proof. Read it before password/factor verification; compare it under the same user-row lock when persisting a session, activating or inserting a factor, or replacing recovery codes. A mismatch returns a typed stale-authentication failure with no successful mutation. Never re-read a newer generation and attach it to an older proof. For userless passwordless challenges capture the generation when resolving the asserted credential, before verifying it; recheck that credential still exists at commit. Pending MFA challenges must retain the generation from the password step. Reject legacy pending state without a generation after rollout, requiring the user to restart that short-lived flow.

Thread these checks through `shomei-core/src/Shomei/Session/Workflow.hs`, `shomei-core/src/Shomei/Passkey/Workflow.hs`, `shomei-core/src/Shomei/Mfa/Workflow.hs`, and `shomei-core/src/Shomei/Mfa/Totp/Workflow.hs`, with the corresponding persistence interpreters. Sensitive authenticated enrollment and recovery-code operations must also validate the initiating session is still live at commit: a stale JWT must not create a new post-reset challenge or factor. Coordinate refresh rotation and authorization-code consumption with recovery's user-row lock and recheck session/token validity after acquiring it. Acquire locks consistently user first, then session/token/factor rows. Keep expensive proof checks outside the lock.

Update core domain/row decoders and all fixtures affected by the generation field, including `shomei-core/src/Shomei/Account/User/Domain.hs` and `shomei-core/src/Shomei/Passkey/Domain.hs`. Extend the in-memory interpreter with identical semantics. Use persisted tests in `shomei-postgres/test/Main.hs` to prove reset versus an already verified MFA completion before expanding HTTP work. This early check succeeds only when a completion committed before reset is revoked, and one attempting to commit afterward is rejected. Then cover enrollment, recovery-code regeneration, passwordless completion, refresh, and authorization-code exchange with synchronization barriers rather than timing sleeps. Inject an audit insert failure to prove all state is restored by rollback.

### Milestone 2: Supported operator surfaces


Add `POST /v1/admin/users/{userId}/mfa/reset` with body `{"identityVerified":true,"caseReference":"INC-1234"}`. Reuse `RequireAdmin`, `CsrfProtected`, typed application responses, and delegation rejection. Refuse HTTP self-targeting; a locked-out administrator uses a second administrator or the local CLI. Validate a live backing session for this destructive route even under token-only verification. Derive HTTP actor identity from the verified principal, never from the request body. Preserve supported service-account administrator scope and identify it as a service actor rather than implying human identity verification was performed by Shōmei.

Return 200 with reset timestamp and counts, no credentials. Return existing problem-document responses for missing/invalid authentication (401), insufficient authority/delegation/self-target (403), invalid body (400), unknown user (404), and non-active target (409); use the repository's dependency failure mapping for rolled-back database errors. Add the route to account API/handler/result/DTO modules, update `shomei-client/src/Shomei/Client.hs`, and extend `shomei-servant/test/Main.hs` and OpenAPI tests. Authorization rejection must occur before writes.

Add `shomei-admin users reset-mfa --user USER_ID --operator OPERATOR --case-reference CASE --identity-verified --confirm-user USER_ID`. Require the confirmation ID to equal the target; missing assertions or mismatches fail before database work. Wire `shomei-server/app/Admin.hs` and `shomei-server/app/Shomei/Admin/Users.hs` to the same core workflow and transaction interpreter. Never use a fake user ID or bypass audit to make the CLI work. Print only target, timestamp, and counts. Extend `shomei-server/test/Admin/Main.hs` with parsing, rejection, and persisted successful recovery tests. Update Cabal module lists for new modules.

### Milestone 3: Notification, runbook, and complete recovery proof


Add a secret-free `SecondFactorsReset` notification carrying the established destination, occurrence time, and support instructions. Enqueue it only after committed recovery and only to an already verified contact address; never allow this request to choose a destination. Handle its absence of token/expiry explicitly in transport rendering and queue logic. Extend SMTP, webhook, null/log modes, and `shomei-server/test/Shomei/Server/NotifySpec.hs`. Use the existing notification delivery/failure contract; transport failure cannot reverse committed security state or cause the API to report an uncommitted reset. CLI must use the configured delivery path with bounded shutdown/drain, not silently discard the notice. For no verified address, return/document that operator notification through an independently established channel is required. Do not describe best-effort enqueue as confirmed delivery.

Replace the incorrect advice in `docs/user/passkeys.md`. Update `docs/user/mfa.md`, `docs/user/api.md`, `docs/user/security.md`, `docs/user/notifications.md`, and the operator CLI documentation found under `docs/user/`. Explain that another enrolled factor or unused recovery code can complete MFA; password reset alone cannot. The operator procedure verifies the owner independently, records a non-sensitive case reference, checks the exact target, performs the reset, notifies the owner, and supervises password login and immediate replacement enrollment plus new recovery codes. Recovery preserves the password and does not unlock a suspended or rate-locked account. If compromise is suspected, rotate the password through the separate supported flow. Explicitly describe the password-only interval and offline access-token expiry limitation. Do not recommend disabling MFA globally or editing credential tables directly.

In `shomei-server/test/Shomei/Server/E2ESpec.hs`, enroll factors, demonstrate that password reset still produces an MFA challenge, perform administrator recovery, prove old proofs/refresh tokens/challenges fail, log in with the password, enroll a replacement, generate new codes, and prove MFA is required again. Cover passkey-only, TOTP-only, both, and no-email accounts. Update affected package changelogs for public type changes without publishing a release. Create a recovery ADR using the allocation and validation procedure in `agents/skills/exec-plan/ADR.md`; describe operator trust, atomicity, generation checks, notification limitations, and the password-only interval.

## Concrete Steps


Run from the repository root. The development shell provides GHC, Cabal, PostgreSQL, and formatting tools. The test fixtures start isolated ephemeral PostgreSQL databases; do not point tests at an operator database.

```bash
nix develop
cabal build all
just new-migration add-authentication-generation
```

Create that migration only once, then fill the generated file and use the existing manifest workflow. After milestone 1 edits:

```bash
cabal test shomei-core-test shomei-postgres-test --test-show-details=direct --test-options='-j2'
just migration-check
```

After adapter and notification edits:

```bash
cabal test shomei-servant-test shomei-servant-openapi-test shomei-admin-test shomei-server-test --test-show-details=direct --test-options='-j2'
cabal run shomei-admin -- users reset-mfa --help
```

The help output must expose the target, operator, case reference, identity assertion, and target confirmation flags. Test suites must exit zero and include the observable cases specified below; no skipped database tests count as acceptance. At the final candidate:

```bash
nix fmt
cabal build all
cabal test all --test-show-details=direct --test-options='-j2'
just migration-check
just adr-validate
nix flake check
git diff --check
```

Record actual results in Progress. Run on the supported local platform; use local Apple containers if a required Linux-specific check arises. No remote builder is required by this plan. Commits use Conventional Commits and both `ExecPlan: docs/plans/71-add-audited-administrative-recovery-for-lost-second-factors.md` and `Intention: intention_01m7hbzef1ex6avd7fw21qtx4c` trailers.

## Validation and Acceptance


Success is a recovered account through each supported operator surface without direct SQL. Core tests in `shomei-core/test/Shomei/Account/Admin/WorkflowSpec.hs` establish input/status behavior and audit metadata. Real PostgreSQL tests must verify complete removal, target isolation, transactional rollback, and races at the final commit boundary, not merely interpreter call counts. Run each race with independent connections; inspect surviving session/factor/token rows and committed audit events. Two reset requests may both succeed serially, but their counts must describe their actual effects and each event must retain its actor.

HTTP tests exercise anonymous, ordinary user, administrator, administrator service account, delegated, self-target, invalid body, and invalid cookie-CSRF requests. The rejected requests leave factors, sessions, and audit success events untouched. CLI tests establish matching results and audit attribution without manufacturing an HTTP administrator. Verify sentinel secrets never appear in response bodies, command output, audit JSON, or notification payloads.

The end-to-end test must fail against the original recovery behavior and pass after implementation. It must demonstrate password reset does not remove MFA, administrator recovery issues no tokens, existing factors/codes are unusable, password login works subject to existing account policy, and replacement enrollment restores MFA. Session-aware protected routes reject pre-reset access tokens immediately; token-only offline verification is tested/documented as retaining its existing expiry limitation. Enrollment and reset routes still refuse revoked sessions regardless of verification mode.

Notification tests cover successful rendering, configured transport failure, queue overflow, and missing verified destination without undoing the reset. Migration tests cover an existing user with factors and pending challenges as well as a fresh database. Preserve factors/sessions on migration itself; only the explicit recovery operation removes them.

## Idempotence and Recovery


Read-only checks and test suites are repeatable. Migration creation allocates a new file, so do not rerun its scaffolding command on resume; migration application itself uses the existing migration ledger. Do not edit previously applied migrations.

A reset deliberately invalidates authentication state on every invocation, even if removal counts are zero. Therefore it is not a harmless retry after re-enrollment. After an ambiguous client timeout, query the audit trail by target and case reference before repeating the operation; the case reference is correlation, not an idempotency key. No automatic transport retry may repeat this destructive request. Never restore deleted factors or spent recovery codes from a backup to undo recovery: verify the owner and enroll fresh credentials instead.

Deploy the additive schema first, drain all old application/worker instances, and then deploy generation-aware readers/writers before enabling either reset surface. Mixed old writers can bypass the generation check. Rollback must retain the schema and disable recovery surfaces; an older binary cannot safely enforce the new barrier after resets. Use a maintenance window when upgrading, and invalidate unsupported legacy pending challenges explicitly without deleting enrolled factors.

## Interfaces and Dependencies


This is an independent plan. Existing `docs/plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md` concerns refresh delivery, not lost factors; preserve its eventual rotation contract if that work lands first. No Kafka outbox or new dependency is required.

The proposed shared interface is `resetUserSecondFactors :: RecoveryActor -> UserId -> RecoveryCommand -> Eff es (Either AuthError RecoveryResult)` in `shomei-core/src/Shomei/Account/Admin/Recovery.hs`. The command contains the validated identity assertion and case reference. The result contains occurrence time, removal/revocation counts, and whether a verified notification destination exists. Authority remains enforced at the calling surface; validation, user status, atomic mutation, and audit are shared. A caller must not treat a local-operator label as authenticated identity. The unit-of-work returns committed counts and does not deliver notifications itself.

Mori discovery verified existing dependencies [Effectful](mori://effectful/effectful/packages/effectful-core) and [Hasql transactions](mori://hasql/hasql/packages/hasql-transaction). Source inspection confirmed dynamic effect dispatch and `transactionNoRetry`; implementation should extend the project's existing effect interpreters and bounded transaction wrapper. No dependency bounds or pins are selected here. Before any later dependency change, consult Mori sources and verify releases against Hackage and upstream tags. For this environment, use the user-provided connection configuration:

```bash
export MORI_PG_CONNECTION_STRING='host=/Users/shinzui/.local/state/postgresql dbname=mori user=shinzui connect_timeout=5'
mori registry list
mori registry search hasql
mori registry show hasql/hasql --full
mori registry docs hasql/hasql
```
