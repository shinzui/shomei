---
id: 5
slug: security-correctness-hardening-make-existing-guarantees-hold
title: "Security Correctness Hardening: Make Existing Guarantees Hold"
kind: master-plan
created_at: 2026-07-07T17:22:07Z
---

# Security Correctness Hardening: Make Existing Guarantees Hold

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A July 2026 security review of Shōmei (recorded in this repository's review session; findings
are restated in full inside each child plan) found that the codebase's dangerous fundamentals
are correct — Argon2id with constant-time comparison, hashed-at-rest refresh tokens with
family-revocation reuse detection, alg-confusion-proof JWT verification, fully parameterized
SQL — but that several *documented guarantees silently do not hold*. This initiative makes
every promise in `docs/user/security.md` true in code.

After this initiative is complete: a session that keeps refreshing still dies at its absolute
`expiresAt` deadline; two concurrent presentations of the same refresh token (or the same
password-reset token) can never both succeed, and a lost race is treated as reuse; the
published JWKS at `/.well-known/jwks.json` carries both the active and retired signing keys
and updates without a server restart, so `shomei-admin keys activate` is genuinely
zero-downtime; an unknown login identifier costs the same wall-clock time as a wrong password,
closing the account-enumeration timing oracle; the `emailVerificationRequired` configuration
flag actually blocks unverified logins instead of being a silent no-op; the default notifier
no longer writes usable password-reset and email-verification tokens into logs; cookie-based
token transport either works end-to-end with CSRF defenses (Set-Cookie emission, SameSite,
Origin checking) or is not silently half-accepted; and signing private keys are
envelope-encrypted at rest so a database read no longer yields the ability to forge tokens for
every downstream service.

Out of scope: new features (roles, OIDC, TOTP — see the Interop Wave MasterPlan,
`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`), performance work that does
not change a security property (see `docs/masterplans/6-operational-and-performance-hardening.md`),
and the signup-existence disclosure via `409 email_taken` (accepted product behavior, recorded
in the Decision Log).


## Decomposition Strategy

The review findings cluster naturally by the *invariant* they restore rather than by file.
Each child plan restores one independently verifiable guarantee, can be implemented and tested
without the others, and touches a mostly disjoint region of the codebase — which keeps all
five plans parallelizable.

EP-1 (session expiry and atomic token-state transitions) groups three findings that are all
instances of one defect class: state transitions checked and applied non-atomically, or not
checked at all (`session.expiresAt` never enforced; `markRefreshTokenUsed` lacking a
`status = 'active'` guard; password-reset/email-verification consumption racing). They share
the same fix pattern — conditional `UPDATE … WHERE … AND status = 'active' RETURNING` treated
as a compare-and-swap — and the same test style, so splitting them would create three plans
editing adjacent statements in the same store modules.

EP-2 (JWKS publication and hot reload) is the one finding that spans the port layer
(`SigningKeyStore`), the JWT package (`Rotation`), and the server boot path; it is isolated
because it introduces a new port operation that the Operational MasterPlan and the Interop
MasterPlan both build on.

EP-3 groups three small, unrelated workflow-level fixes (dummy-hash timing equalization,
`emailVerificationRequired` enforcement, notifier token redaction) that are each too small to
be a plan on their own; they share the property of being pure workflow/interpreter edits with
no schema or API-shape change.

EP-4 (cookie transport) is a product decision plus an implementation: the cookie *read* path
is live while nothing ever sets a cookie and no CSRF defense exists. It is its own plan because
it changes the HTTP surface and requires a decision recorded in its Decision Log.

EP-5 (key encryption at rest) is isolated because it is the only plan with a migration and an
operational dependency (a key-encryption-key supplied via configuration), and the only one
where a phased rollout (re-wrap existing rows) matters.

An alternative decomposition by package (core / postgres / server) was rejected because the
session-expiry fix alone spans all three, and package-sliced plans would not be independently
verifiable behaviors.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Enforce Absolute Session Expiry and Atomic Token-State Transitions | docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md | None | None | Not Started |
| 2 | Publish and Hot-Reload the Full JWKS with Retired Keys | docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md | None | None | Not Started |
| 3 | Login Timing-Oracle Fix, Email-Verification Enforcement, and Notifier Token Redaction | docs/plans/30-login-timing-oracle-fix-email-verification-enforcement-and-notifier-token-redaction.md | None | None | Not Started |
| 4 | Complete Cookie Token Transport with CSRF Defenses | docs/plans/31-complete-cookie-token-transport-with-csrf-defenses.md | None | None | Not Started |
| 5 | Encrypt Signing Private Keys at Rest | docs/plans/32-encrypt-signing-private-keys-at-rest.md | None | EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

All five plans can start immediately and proceed in parallel; none produces a type or module
another plan needs to compile.

The single soft dependency is EP-5 on EP-2: both touch the key-loading path in
`shomei-server/src/Shomei/Server/Keys.hs` and the stored-key serialization in
`shomei-jwt/src/Shomei/Jwt/Key.hs`. EP-2 restructures *which* keys are loaded and when they
are refreshed; EP-5 changes *how* each stored row is decrypted on load. Implementing EP-2
first means EP-5 wraps a single, already-centralized load function; implementing them in the
other order works but forces EP-2 to re-plumb the decryption hook. If they end up in flight
simultaneously, reconcile on the shape of the key-loading function before either merges (see
Integration Points).

EP-1 and EP-3 both edit `shomei-core/src/Shomei/Workflow.hs` (the `refresh` and `login`
functions respectively) but in disjoint functions; ordinary rebase discipline is sufficient.


## Integration Points

Key-loading seam (`shomei-server/src/Shomei/Server/Keys.hs`, `shomei-jwt/src/Shomei/Jwt/Key.hs`):
involved plans EP-2 and EP-5. EP-2 owns the seam: it introduces the "load all publishable
keys, build signer + JWKS, refresh periodically" function and the new
`ListPublishableSigningKeys` operation on the `SigningKeyStore` port
(`shomei-core/src/Shomei/Effect/SigningKeyStore.hs`). EP-5 consumes it: decryption of
`private_key_jwk` happens inside the stored-key deserialization that EP-2's loader calls, so
EP-5 must not introduce a second load path. If EP-5 starts before EP-2 lands, it should write
the decryption as a pure `StoredSigningKey -> Either KeyDecryptError JWK` function so EP-2 can
call it from wherever the loader ends up.

Refresh workflow (`shomei-core/src/Shomei/Workflow.hs`, `refresh`): involved plans EP-1 here
and EP-1 of the Operational MasterPlan
(`docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md`), which
wraps the same workflow tail in a single database transaction. This plan (EP-1) owns the
compare-and-swap semantics of `markRefreshTokenUsed` — the conditional UPDATE with
`RETURNING` — because that alone closes the security race even without cross-statement
transactions. The Operational plan layers transaction batching on top and must preserve the
CAS statement shape. Whichever lands second reconciles against the other's store-module edits
in `shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`.

`ShomeiConfig` (`shomei-core/src/Shomei/Config.hs`) and the server config loader
(`shomei-server/src/Shomei/Server/Config.hs`): EP-3 (activates the existing
`emailVerificationRequired` field), EP-4 (activates the existing `TokenTransport` field and
adds cookie/CSRF settings), and EP-5 (adds the key-encryption-key setting) all extend these
records. Additive, order-independent; each plan adds its own fields and defaults and must not
rename existing ones.


## Progress

- [ ] EP-1: Session absolute-expiry enforced in `refresh` and `verifyToken`, with regression tests
- [ ] EP-1: Refresh-token mark-used converted to compare-and-swap; lost race treated as reuse
- [ ] EP-1: One-time token consumption (password reset, email verification) made atomic
- [ ] EP-2: `ListPublishableSigningKeys` port operation and interpreters (Postgres, in-memory)
- [ ] EP-2: JWKS built from active + retired keys; served document and verifier key set agree
- [ ] EP-2: Periodic (or signal-driven) key reload without restart; rotation runbook re-verified end-to-end
- [ ] EP-3: Dummy-hash verification on unknown-account login path; timing test
- [ ] EP-3: `emailVerificationRequired` enforced at login/token issuance
- [ ] EP-3: `LogNotifier` redacts one-time tokens (hash prefix only)
- [ ] EP-4: Decision recorded: complete cookie transport (vs. remove read path)
- [ ] EP-4: Set-Cookie emission on login/refresh/logout honoring `TokenTransport`, with `HttpOnly`/`Secure`/`SameSite`
- [ ] EP-4: CSRF defense for cookie-authenticated mutations
- [ ] EP-5: Envelope encryption of `private_key_jwk` behind a configured key-encryption key
- [ ] EP-5: Migration/backfill path for existing plaintext rows; `shomei-admin` support


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Group the three non-atomic state-transition findings (session expiry, refresh CAS,
  one-time-token consumption) into one plan (EP-1) instead of three.
  Rationale: One defect class, one fix pattern (conditional UPDATE … RETURNING as
  compare-and-swap, modeled on the already-correct `PendingCeremonyStore`), shared test
  approach; three plans would edit adjacent code in the same modules.
  Date: 2026-07-07

- Decision: Keep the refresh compare-and-swap in this MasterPlan and the transaction batching
  in the Operational MasterPlan, rather than merging them.
  Rationale: The CAS alone closes the exploitable race (security property); transactions are a
  round-trip optimization that also improves crash behavior (operational property). The CAS is
  small and must not wait on the larger transaction refactor. The shared code is documented as
  an integration point in both MasterPlans.
  Date: 2026-07-07

- Decision: Signup existence disclosure (`409 email_taken` / `login_id_taken`) is accepted and
  will not be changed in this initiative.
  Rationale: Standard product behavior for signup flows; the review rated it Low and noted the
  deliberately non-enumerating reset/verify flows are unaffected. Documenting the asymmetry in
  `docs/user/security.md` is folded into EP-3's documentation touch-ups.
  Date: 2026-07-07

- Decision: EP-4 plans for *completing* cookie transport rather than removing the cookie read
  path.
  Rationale: `TokenTransport` (`HttpOnlyCookie`/`BearerAndCookie`) already exists in config and
  docs; removal would be a breaking retreat from a documented feature. The plan still records
  removal as the fallback if CSRF scope balloons.
  Date: 2026-07-07


## Outcomes & Retrospective

(To be filled during and after implementation.)
