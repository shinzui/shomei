---
id: 55
slug: atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails
title: "Atomic State Transitions, Round Two: Lockout, Counters, and Transactional Credential Tails"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Atomic State Transitions, Round Two: Lockout, Counters, and Transactional Credential Tails

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. The July 2026 hardening (plans 28 and 33 under
`docs/plans/`) set two conventions: every single-use secret changes state through one
*compare-and-swap* (CAS) statement — an `UPDATE … WHERE status = 'active' RETURNING …` whose
empty result means "someone else got there first" — and every multi-table write tail runs in one
transaction through the `AuthUnitOfWork` port. The August 2026 review (`docs/reviews/` REV-2,
REV-5, REV-6) found where newer code did not follow them; this is EP-5 of MasterPlan 8
(`docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md`).

Afterwards an operator can observe: sixty parallel wrong-password requests against one account
evaluate at most `maxFailedLoginsPerAccount` (default five) guesses against the stored hash, the
rest are refused before the hash is consulted, and the account locks exactly once. Two
simultaneous submissions of one TOTP code or one passkey assertion yield exactly one login. A
password reset or change either fully completes (new hash, every session and refresh token
revoked, every other outstanding reset link dead) or changes nothing. A refresh token revoked by
logout answers `401 session_revoked` without the theft response, and a hundred racing refreshes
publish one `RefreshTokenReuseDetected` event. Two administrators suspending one user at once
produce one audit event and one `409`. Signup with a registered email answers `409 email_taken`,
not `503`. The schema refuses unknown status values and case-variant duplicate identifiers from
any writer. Each is pinned by a test observed failing on the pre-fix code.


## Progress

- [x] (2026-08-27T18:41:26Z) M1 regression added and observed red: 100 racing wrong passwords
      exceeded the three-verification stored-hash budget before the record-first change
- [x] (2026-08-27T18:49:30Z) M1 EP-4 integration resolved: correct password proofs that advance
      to MFA discard their provisional row without resetting the shared failure budget
- [x] (2026-08-27T18:53:00Z) M1 PostgreSQL race observed red without the advisory lock and green
      with it; the eight returned counts serialize exactly as `1..8` and one caller locks
- [x] (2026-08-27T18:58:10Z) M1: in-memory fake atomic; `LoginAttemptId`; `RecordLoginFailure` and
      `ConvertLoginAttemptToSuccess` replace `RecordLoginAttempt`; advisory-lock transaction;
      `login` records before hashing
- [x] (2026-08-27T18:58:10Z) M1: `ConcurrencySpec` 100 wrong passwords (red first); Postgres budget + lock race;
      `TimingSpec` locked case; docs
- [x] (2026-08-27T19:05:16Z) M1 gate: `nix fmt`, `cabal build all`, and the serialized
      all-package test matrix pass
- [x] (2026-08-27T19:14:47Z) M2 in-memory regression observed red: after synchronizing every
      credential read, 100 submissions of one TOTP code all completed successfully
- [x] (2026-08-27T19:14:47Z) M2 PostgreSQL controls observed red without the predicates: all
      stale/lower writes returned `True`, and all eight racing TOTP and passkey updates won
- [x] (2026-08-27T19:23:12Z) M2: counter CAS statements, `Bool` ports, replay handling,
      `casWorld`; 100-way workflow race and eight-way PostgreSQL races pass
- [x] (2026-08-27T19:23:12Z) M2 gate: `nix fmt`, `cabal build all`, and the serialized
      all-package test matrix pass (core 269; PostgreSQL 67)
- [x] (2026-08-27T19:35:46Z) M3 regression observed red: a 100-way refresh race published 55
      reuse events without the session-scoped revoke CAS
- [x] (2026-08-27T19:41:16Z) M3: three unit-of-work operations; `revokeSessionStmt` guarded;
      `RefreshTokenRevoked → SessionRevoked`; sibling verification tokens revoked;
      one-reuse-event assertion; budgets
- [x] (2026-08-27T19:41:16Z) M3 gate: `nix fmt`, `cabal build all`, and the serialized
      all-package test matrix pass (core 272; PostgreSQL 70)
- [x] (2026-08-27T19:43:26Z) M4 regression observed red: 100 concurrent suspends produced five
      successful transitions before the user-status compare-and-swap
- [x] (2026-08-27T19:51:55Z) M4: `UpdateUserStatus` conditional; concurrent-suspend tests in
      core and Postgres
- [x] (2026-08-27T19:51:55Z) M4 gate: `nix fmt`, `cabal build all`, and the serialized
      all-package test matrix pass (core 273; PostgreSQL 72)
- [x] (2026-08-27T19:54:45Z) M5 regressions observed red: duplicate email signup returned 201,
      and a duplicate PostgreSQL login id collapsed to `DependencyUnavailable PostgreSQL`
- [x] (2026-08-27T20:02:40Z) M5: `findUserByEmail` guard; SQLSTATE 23505 mapped to typed
      conflicts; tests
- [x] (2026-08-27T20:02:40Z) M5 gate: `nix fmt`, `cabal build all`, and the serialized
      all-package test matrix pass (core 273; PostgreSQL 72; Servant 42)
- [ ] M6: migration (number allocated by `just new-migration`; `0029` at the time of writing); PostgreSQL 17/18 floor documented; CHANGELOGs; ADR distillation


## Surprises & Discoveries

- The regression-first in-memory race exceeded the configured three stored-hash evaluations on
  the pre-fix workflow. The scheduler let six requests pass the read-only gate before the first
  lockout write became visible; the exact number is schedule-dependent, while any value above
  three proves the bypass.

  ```text
  100 concurrent wrong passwords: at most 3 real verifications, one lock: FAIL
    real verifications exceeded the budget: 6
  ```

- The first full core run exposed an integration case absent from the draft: a correct password
  that advances into MFA cannot remain a `failure` row (that double-counts one authentication
  attempt), and it cannot become `success` (that resets earlier factor failures before MFA
  succeeds). The failing evidence was `successful login clears the failure counter` returning
  `InvalidCredentials`, a suspended account's threshold attempt changing from `UserNotActive` to
  `InvalidCredentials`, and the five-bad-passkey setup locking during its third password proof.
  A provisional-row discard is the only transition that preserves EP-4's shared-budget rule.

- Removing the advisory-lock statement reproduced the READ COMMITTED race exactly: four
  transactions observed count one and four later transactions observed count five, rather than
  each observing its unique post-insert count. Restoring the statement made the test green.

  ```text
  lockout: eight racing failures count 1..8 and lock once: FAIL
    expected: [1,2,3,4,5,6,7,8]
     but got: [1,1,1,1,5,5,5,5]
  ```

- The TOTP workflow race initially depended on lucky scheduling: without synchronizing reads,
  the first completion could advance the fake before the other green threads loaded it. A
  test-only `interpose` barrier now makes all 100 completions return the same stale credential
  before allowing any update. Against the unconditional fake this made every request mint a
  session, rather than exactly one.

  ```text
  100 concurrent submissions of one TOTP code: exactly one winner: FAIL
    expected: 1
     but got: 100
  ```

- Removing the PostgreSQL counter predicates made both eight-thread races return eight winners;
  sequential stale and lower values also returned `True`. Restoring the predicates made all six
  focused counter tests pass.

  ```text
  passkey counter: eight racing nonzero updates have one winner: FAIL
    expected: 1
     but got: 8
  totp counter: eight racing updates have one winner: FAIL
    expected: 1
     but got: 8
  ```

- The complete PostgreSQL gate caught a restoration error in the deliberate red control: the
  TOTP monotonic predicate had been reapplied to `confirmStmt` instead of `setCounterStmt`.
  Confirmation then failed on an invalid timestamp/integer comparison while counter writes
  remained unconditional. Moving the predicate to the counter statement restored all six
  focused tests and all 67 PostgreSQL tests. The product implementation was not otherwise
  changed; the failure demonstrates why the full suite follows destructive red controls.

- The 100-way refresh race does not deterministically publish all 99 possible duplicate reuse
  events: in the observed red run it published 55. Threads that load the token after an earlier
  theft response has revoked it take a different branch, while threads holding a stale `used`
  view each publish. The exact excess is scheduling-dependent; any value above one proves the
  missing session-level linearization point.

  ```text
  100 concurrent refreshes: exactly one winner: FAIL
    expected: 1
     but got: 55
  ```

- The pre-fix in-memory admin race produced five successful suspensions in the observed run.
  As with the refresh race, the precise duplicate count depends on scheduling; the important
  evidence is that multiple callers crossed the read-only status check and each published the
  success tail.

  ```text
  100 concurrent suspends have one winner and one audit event: FAIL
    expected: 1
     but got: 5
  ```

- Before M5, the in-memory workflow accepted a second account with the same email because it
  checked only the principal login id; the HTTP regression therefore returned 201 instead of
  `409 email_taken`. PostgreSQL enforced uniqueness, but the adapter erased SQLSTATE 23505 into
  `DependencyUnavailable PostgreSQL`, so a genuine client conflict appeared retryable.


## Decision Log

- Decision: The atomic lockout is a per-account-key **advisory-lock transaction** that keeps
  `shomei_login_attempts` as the source of truth — not the MasterPlan's first suggestion of
  `INSERT … RETURNING (SELECT count(*) …)`, and not a counter column on `shomei_account_lockouts`.
  Rationale: under READ COMMITTED (what `runTransaction` opens), concurrent `INSERT`s into an
  append-only table never conflict, and each statement's snapshot excludes the other's
  uncommitted row *and* its own, so sixty racing inserts compute the same count and none reaches
  the threshold: that shape is not atomic. A `failed_count` upsert *is* atomic (ON CONFLICT DO
  UPDATE locks and re-reads the row) but turns "failures within `lockoutWindow` since the last
  success" into "consecutive failures with no gap longer than the window" and writes a lockout
  row on every attempt of every account. Taking `pg_advisory_xact_lock(hashtextextended($1, 0))`
  first, then inserting and running the existing `countByAccountStmt` verbatim, serializes
  failures per key and makes the count exact (every earlier holder committed before releasing);
  the lock needs no row, survives transaction pooling, and leaves EP-4's contract untouched.
  Date: 2026-08-27

- Decision: **Record before hashing.** `login` records a provisional failure and learns the
  post-insert count before it looks the credential up; a correct password converts that row to a
  success (`UPDATE … WHERE attempt_id = $1`). The locked branch performs `verifyPasswordDummy`.
  Rationale: the review's scenario is sixty parallel guesses passing a read-only gate. With
  record-after-hash plus an atomic count, all sixty are still evaluated against the stored hash —
  and if one is right, it logs in — so the budget holds only across bursts. Recording first
  refuses guess six before the stored hash is consulted, bounding an attacker to the budget per
  window regardless of parallelism. Converting (not inserting a success) keeps the per-IP count
  honest and reuses the "failures strictly after the latest success" predicate. Every failing
  request still performs exactly one Argon2 operation; the locked branch was the one exception.
  Date: 2026-08-27

- Decision: The request whose provisional row first reaches `maxFailures` owns the lock
  transition but may still evaluate the stored hash. Only a `priorLockout` that remains live
  refuses the hash. If the threshold request proves the password, it converts or discards its
  provisional row and clears the lock it just reserved.
  Rationale: the configured threshold is the number of failed proofs allowed, not one less. The
  original draft's `lockedNow || lockedBefore` branch refused the third proof under a threshold
  of three before knowing whether it was a failure, broke successful reset-at-threshold behavior,
  and changed suspended-account errors on the threshold request. Prior-lock refusal still bounds
  100 concurrent requests to at most the configured number of stored-hash evaluations.
  Date: 2026-08-27

- Decision: `RecordLoginAttempt` is removed from `LoginAttemptStore`; `RecordLoginFailure` and
  `ConvertLoginAttemptToSuccess` replace it; the count and lockout reads stay; a
  `LoginAttemptId` (`KindID "loginattempt"`) is added to `Shomei.Id`.
  Rationale: plan 28's reasoning — the unconditional append is the bypass being closed, and the
  compiler enumerates every caller. If `docs/plans/54-…` lands first and records second-factor
  failures through `recordLoginAttempt`, rebase those calls onto `recordLoginFailure` and its
  success recording onto the convert.
  Date: 2026-08-27

- Decision: Add `DiscardLoginAttempt :: LoginAttemptId -> LoginAttemptStore m ()`. A correct
  password that advances into an MFA challenge discards its provisional row; if reserving that
  row created the lock, it also removes that newly-created lockout. The eventual factor failure
  records one failure, while full MFA success records the success that resets the budget.
  Rationale: EP-4 landed before this plan and deliberately makes only full authentication reset
  the shared budget. Converting the password row to success would violate that invariant; leaving
  it as failure would count a correct proof and double-charge each bad-MFA attempt. Deleting only
  the provisional row preserves both rules without expanding the persisted outcome vocabulary.
  Date: 2026-08-27

- Decision: `SetTotpLastUsedCounter` and `UpdatePasskeySignCounter` return `Bool`; `False` is
  replay, reported as `MfaFailed` plus `TotpCodeInvalid` or `MfaAssertionInvalid`. The passkey
  predicate is `sign_counter < $2 OR ($2 = 0 AND sign_counter = 0)`.
  Rationale: plan 28's `Bool` convention; authenticators without a counter always report zero,
  and zero-to-zero is admitted exactly as the WebAuthn library's clone check admits it.
  Date: 2026-08-27

- Decision: `RevokeSessionWithTokens` is **session-scoped**: it CASes the session
  `active → revoked` and only on success revokes the session's tokens and inserts the caller's
  events, returning `True`. `reuseDetected` switches from family to session scope, and a
  presented token in status `revoked` answers `Left SessionRevoked` with no theft response;
  only `used` and a lost rotation swap trigger `reuseDetected`.
  Rationale: a rotation family never crosses a session, so revoking by `session_id` (one indexed
  `UPDATE`) is a superset of the recursive family walk; making the session transition the CAS is
  what turns ninety-nine reuse events into one. Tokens are only ever revoked alongside their
  session, so `session_revoked` is the informative `401` and a replay after logout is a benign
  retry (REV-2 finding 20). `revokeRefreshTokenFamily` stays on the port for
  `shomei-servant/src/Shomei/OAuth/Handler.hs:576` (EP-2's); token statements' guards are untouched.
  Date: 2026-08-27

- Decision: `CompletePasswordReset` and `CompletePasswordChange` take an already-computed
  `PasswordHash`; no interpreter of the port may hash; events travel in as a list.
  `confirmEmailVerification` revokes sibling tokens with the existing per-table operation, not
  a fourth unit-of-work operation.
  Rationale: Integration Point 5 (`docs/plans/56-…` keeps Argon2 outside every transaction); the
  workflows already hash before the consume CAS. A surviving verification link can only answer
  `EmailAlreadyVerified`, so its atomicity buys nothing.
  Date: 2026-08-27

- Decision: `UpdateUserStatus :: UserId -> [UserStatus] -> UserStatus -> UTCTime -> UserStore m Bool`,
  executed as `… WHERE user_id = $1 AND status = ANY ($3) RETURNING user_id`; `updated_at` takes
  the workflow's clock instead of `now()`.
  Rationale: the allowed-list is what `transition` already checks; the loser sees
  `InvalidUserStatus`, exactly what a sequential second suspend sees, so `409` holds.
  Date: 2026-08-27

- Decision: Duplicate email is closed at both ends: a `findUserByEmail` guard in `signup` and a
  boundary mapping of SQLSTATE 23505 on the identity indexes to `LoginIdAlreadyRegistered` /
  `EmailAlreadyRegistered`, inspecting only the constraint name.
  Rationale: the guard answers the common case; only the mapping makes two racing signups
  answer `409` rather than `503`; no driver text crosses the boundary.
  Date: 2026-08-27

- Decision: Case-insensitive uniqueness uses expression indexes on `lower(...)` beside the raw
  indexes, not `citext`. CHECK lists come from the codecs; `shomei_signing_keys.algorithm` is
  excluded (EP-3's state machine, `shomei-jwt`'s codec).
  Rationale: `citext` needs `CREATE EXTENSION` privileges, changes the column type through every
  encoder and predicate, and compares via `lower()` internally anyway. Haskell `toLower` and
  PostgreSQL `lower()` can disagree on rare Unicode; the index is then the stricter side and a
  write it refuses surfaces as `409` through M5. A new EP-4 outcome value extends the `CHECK`.
  Date: 2026-08-27

- Decision: Race tests run in both suites: in-memory `ConcurrencySpec` (100 racers × 10 rounds)
  and Postgres store-level races with eight gated threads modeled on
  `testAuthorizationCodeConsumeIsAtomicUnderRace`.
  Rationale: plan 28 pinned PostgreSQL only sequentially and called it a gap; the gated pattern is stable in CI.
  Date: 2026-08-27


## Outcomes & Retrospective

- M1 closed the parallel password-guess bypass. One serialized operation now appends the
  provisional failure, returns the exact post-insert windowed count, and creates at most one
  lockout before stored-hash verification. The 100-racer in-memory regression went from six
  real verifications on the pre-fix workflow to at most three, with all 100 requests performing
  exactly one real-or-dummy verification and one `AccountLocked` event. The eight-transaction
  PostgreSQL regression went from duplicate counts `[1,1,1,1,5,5,5,5]` without the advisory
  lock to `1..8` with exactly one lock owner. The complete core (268 tests) and PostgreSQL (63
  tests) suites pass, as do `cabal build all` and the serialized all-package test matrix.

- M2 made TOTP and passkey counter advancement a compare-and-swap at both persistence
  boundaries. A stale or losing write returns `False`, and each MFA workflow reports the proof
  as replayed before any session can be minted. The synchronized 100-request TOTP workflow
  regression now has exactly one winner; both PostgreSQL counter families have one winner in
  their eight-thread nonzero races and reject sequential stale/lower writes. Counterless
  WebAuthn authenticators retain the required zero-to-zero behavior. The complete core (269
  tests) and PostgreSQL (67 tests) suites pass, as do `cabal build all` and the serialized
  all-package test matrix.

- M3 moved password reset, password change, logout, and refresh-reuse revocation tails behind
  three atomic unit-of-work operations in both interpreters. Reset confirmation now consumes
  exactly one link, revokes its siblings, changes the credential, and revokes every session and
  refresh token in one transaction; email confirmation likewise revokes sibling links. Session
  revocation is a compare-and-swap, so a 100-racer refresh regression fell from 55 duplicate
  reuse events to exactly one, while already-revoked tokens report `SessionRevoked` without a
  false theft signal. PostgreSQL keeps logout at two round-trips and reset confirmation at
  three. The complete core (272 tests) and PostgreSQL (70 tests) suites pass, as do `cabal build
  all` and the serialized all-package test matrix.

- M4 made the user-status write conditional on its allowed source states and threaded its one
  clock reading through the store. The admin workflow retains its pre-read to distinguish a
  missing user, but only the compare-and-swap winner now revokes sessions and publishes the
  lifecycle event; every loser receives `InvalidUserStatus`. The in-memory 100-racer regression
  fell from five successful suspensions to one, and the eight-connection PostgreSQL race also
  has exactly one winner. The complete core (273 tests) and PostgreSQL (72 tests) suites pass,
  as do `cabal build all` and the serialized all-package test matrix.

- M5 restored identity conflicts at both layers. Signup now rejects an existing email before
  hashing or writing, and the HTTP boundary answers duplicate email and login id with their
  existing 409 problem codes. A narrow Hasql SQLSTATE 23505 classifier extracts only the quoted
  constraint name and maps the known user and credential indexes to the same typed conflicts;
  every unknown constraint or driver failure remains `DependencyUnavailable PostgreSQL` with no
  SQL detail exposed. The complete core (273), PostgreSQL (72), and Servant (42) suites pass, as
  do `cabal build all` and the serialized all-package test matrix.


## Context and Orientation

Shōmei is a multi-package Cabal project built inside `nix develop`. `shomei-core` holds the
domain, the *ports* (effect signatures for the `effectful` library — a GADT such as
`LoginAttemptStore` whose constructors are the operations), the workflows, and an in-memory fake
of every port in `shomei-core/src/Shomei/Test/InMemory.hs` (one `IORef World`; mutations go
through `modifyWorld`, an `atomicModifyIORef'`, or `casWorld`, the conditional variant returning
whether it transitioned — lines 313–322). `shomei-postgres` holds the `hasql` interpreters, one
module per port, each operation one prepared statement in its own pool checkout via
`runSession`, except `Session/UnitOfWork/Postgres.hs`, which composes *exported* statements into
one `hasql-transaction` `Transaction` via `runTransaction` (`Persistence/Database/Postgres.hs:42-45`:
READ COMMITTED; retries only on 40001/40P01). `shomei-migrations` holds SQL under
`shomei-migrations/migrations/shomei/` plus a manifest; new files come only from
`just new-migration <slug>`. `shomei-servant` maps `AuthError` to problem documents in
`Servant/Error.hs` (`EmailAlreadyRegistered -> pcEmailTaken`, a `409`, at line 543). Tests:
`cabal test shomei-core` (in-memory), `cabal test shomei-postgres` (ephemeral PostgreSQL 17),
`cabal test shomei-servant` (in-memory `World` behind a real WAI app); run the matrix as
`cabal test all -j1 --test-options="-j1"`, since plans 28 and 33 found the parallel form flaky.

Architecture Decision Records: this repository has no `docs/adr/` bundle (`mori.dhall` declares
`improvement-requests`, `capabilities`, and `reviews` only), so no local ADR applies; M6 ends
with the distillation pass `.claude/skills/exec-plan/ADR.md` requires. Incorporated by
reference: `docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md`
(the CAS convention, `Bool` returns, `casWorld`, a CAS loser may observe `SessionRevoked`) and
`docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md` (the
`AuthUnitOfWork` port, `RotationConflict` as a signal, exported statements so the transaction
module writes no SQL, hashing outside the transaction).

The defects at HEAD `5dfd2a6` (code identical to reviewed `ee00382`), paths under
`shomei-core/src/Shomei/` and `shomei-postgres/src/Shomei/`. *Lockout:*
`Session/Authentication/Workflow.hs:227-239` reads the lockout row and refuses if locked,
244–252 look up and verify, `failLogin` (317–334) records, counts, and locks — three checkouts,
and the gate is a read; `countByAccountStmt` (`Session/LoginAttempt/Postgres.hs:99-111`) counts
failures in the window and strictly after the latest success, as the in-memory
`countAccountFailures` (`InMemory.hs:761-772`) does.
*Counters:* `Mfa/Totp/Postgres.hs:226-235` and `Passkey/Postgres.hs:207-220` are unconditional
`UPDATE`s; `completeTotp` (`Mfa/Workflow.hs:206-214`) compares against a value read one
statement earlier. *Tails:* `Account/Lifecycle/Workflow.hs:197-207` and 234–239 issue four
autocommits after the consume CAS; `revokeUser{PasswordReset,Verification}Tokens` have no
caller; `reuseDetected` (`Authentication/Workflow.hs:421-426`) and `logout` (443–447) are three
autocommits each; line 360 maps `RT.RefreshTokenRevoked -> reuseDetected`; `revokeSessionStmt`
(`Session/Postgres.hs:159-168`) has no status guard. *Admin:* `transition`
(`Account/Admin/Workflow.hs:99-109`) reads then writes through an unconditional statement
(`Account/User/Postgres.hs:177-183`). *Signup:* `Authentication/Workflow.hs:145-150` checks only
the login id; `EmailAlreadyRegistered` (`Error.hs:58`) is constructed nowhere; the `0017` index
fires and `postgresUnavailable` (`Database/Postgres.hs:36-37`) collapses every `UsageError` to
`DependencyUnavailable PostgreSQL`. *Schema:* no `CHECK` at `0002:7`, `0004:6`, `0005:8`,
`0006:10`, `0009:7`, `0010:7`, `0011:7`, `0015:6`, `0022:31`, `0023:32,36`; raw-text unique
indexes at `0016:16-17`, `0017:12-14`, `0018:16-17`, `0019:12-14` while the domain lowercases
before every write; pg-migrate refuses any server whose major is not 17 or 18 and
`docs/user/deployment.md` does not say so. *Fake:* `InMemory.hs:1188-1200`, 1236–1242, 830–838, and 361–363 read then write in two steps.

Terms: a *provisional failure* is a login-attempt row inserted with outcome `failure` before the
password is checked; *converting* it updates that row's outcome to `success`; a
*transaction-scoped advisory lock*, `pg_advisory_xact_lock(bigint)`, is a PostgreSQL mutex keyed
by a number, held until COMMIT or ROLLBACK, with no row behind it.


## Plan of Work

Each milestone ends with one commit whose subject is given at its end; every commit carries the
three trailers listed in Concrete Steps.

### Milestone 1 — An honest fake and an atomic, record-first lockout

First make every remaining in-memory mutation atomic (the concurrency tests added next would
otherwise assert on corrupted state), then replace the read-then-act lockout with one operation
that records, counts, and locks in a single serialized step before any password work. At the
end, `ConcurrencySpec` runs one hundred parallel wrong passwords and observes at most three real
verifications (`LockoutSpec`'s threshold), one `AccountLocked` event, and a locked account.

Fake hygiene, `InMemory.hs`: rewrite `GenerateOpaqueToken` and `GenerateRandomBytes`
(1188–1200) as `n <- liftIO (atomicModifyIORef' ref \w -> (w & #tokenCounter %~ (+ 1), w.tokenCounter))`,
`mkCannedCeremony` (1236–1242) likewise over `#ceremonyCounter`, `TakePendingCeremony`
(830–838) as one `atomicModifyIORef'` that looks up, deletes, and returns the row only if
`pcExpiresAt pc > now'`, and `UpdateUserStatus` (361–363) as a `casWorld` (tightened in M4).

The id and the port. Add `LoginAttemptId = KindID "loginattempt"` with `genLoginAttemptId`,
`loginAttemptIdToUUID`, `loginAttemptIdFromUUID` to `Shomei/Id.hs`, following the `PasskeyId`
trio (lines 91, 136–137, 198–202). Give `LoginAttempt` in `Session/LoginAttempt/Domain.hs` an
`attemptId :: !LoginAttemptId`; leave `NewLoginAttempt` alone (EP-4 may add a factor). Add:

```haskell
-- | What 'RecordLoginFailure' may do once the windowed count reaches 'maxFailures'.
data LockPolicy = LockPolicy {maxFailures :: !Int, lockUntil :: !UTCTime}

-- | The account key's state immediately after this failure was recorded.
data FailureOutcome = FailureOutcome
  { attemptId :: !LoginAttemptId,
    failures :: !Int,                        -- windowed, after the latest success, including this one
    priorLockout :: !(Maybe AccountLockout), -- read in the same step, before any lock set here
    lockedNow :: !Bool }                     -- this call transitioned unlocked → locked
```

In `Session/LoginAttempt/Store.hs` delete `RecordLoginAttempt`; add
`RecordLoginFailure :: NewLoginAttempt -> UTCTime -> Maybe LockPolicy -> LoginAttemptStore m FailureOutcome`
(the `UTCTime` is the window start; `Nothing` means record and count but never lock — the
`rateLimitEnabled = False` branch) and `ConvertLoginAttemptToSuccess :: LoginAttemptId ->
LoginAttemptStore m ()`, each with its lower-case `send` wrapper. Add
`DiscardLoginAttempt :: LoginAttemptId -> LoginAttemptStore m ()` as the EP-4 integration:
when a correct password advances to MFA, deleting only that provisional row avoids charging a
correct factor or resetting the shared failure budget before full authentication succeeds.

Postgres, `Session/LoginAttempt/Postgres.hs`: two new statements —
`lockAccountKeyStmt :: Statement Text Int32` (`D.singleRow (D.column (D.nonNullable D.int4))`)
and `convertAttemptStmt :: Statement UUID ()` (`D.noResult`) — and the existing three lifted
into one transaction:

```sql
SELECT 1 FROM pg_advisory_xact_lock(hashtextextended($1, 0))
UPDATE shomei.shomei_login_attempts SET outcome = 'success' WHERE attempt_id = $1
```

```haskell
RecordLoginFailure na windowStart mPolicy -> do
  aid <- genLoginAttemptId
  let AccountKey k = na.accountKey; ClientIp ip = na.clientIp; row = (loginAttemptIdToUUID aid, k, ip, loginOutcomeToText na.outcome, na.occurredAt)
  res <- runTransaction do
    _ <- Tx.statement k lockAccountKeyStmt                    -- serialization point for this key
    Tx.statement row insertAttemptStmt
    n <- Tx.statement (k, windowStart) countByAccountStmt     -- exact: earlier holders committed
    prior <- Tx.statement k findLockoutStmt
    let stillLocked = maybe False (\(_, lu, _) -> maybe False (> na.occurredAt) lu) prior
    lockedNow <- case mPolicy of
      Just p | fromIntegral n >= p.maxFailures, not stillLocked ->
        True <$ Tx.statement (k, fromIntegral n, Just p.lockUntil, na.occurredAt) upsertLockoutStmt
      _ -> pure False
    pure (FailureOutcome aid (fromIntegral n) (rebuildLockout na.accountKey <$> prior) lockedNow)
  either dbFail pure res
```

`ConvertLoginAttemptToSuccess` is one `runSession` of `convertAttemptStmt`;
`DiscardLoginAttempt` is a guarded delete of only that failure row. Update
`Session/UnitOfWork/Postgres.hs`'s haddock (lines 4–6 claim it is the only `runTransaction`
user): this port operation is one transaction because its serialization point must enclose its
count; it is not a workflow tail. In memory, `RecordLoginFailure` is one `atomicModifyIORef'`:
generate the id outside, prepend `toAttempt aid na`, compute `countAccountFailures` on the new
world, read the prior lockout, insert `AccountLockout k n (Just lockUntil) occurredAt` when the
policy says so and the key is not still locked, return the outcome; the convert is a
`modifyWorld` over the matching `attemptId`.

Workflow, `Authentication/Workflow.hs`. Replace 227–263 so that after the per-IP throttle
(230–233, unchanged) comes:

```haskell
  outcome <-
    recordLoginFailure
      NewLoginAttempt {accountKey = ctx.accountKey, clientIp = ctx.clientIp, outcome = LoginFailure, occurredAt = ts}
      cutoff
      (if rl.rateLimitEnabled then Just (LockPolicy rl.maxFailedLoginsPerAccount (addUTCTime rl.lockoutDuration ts)) else Nothing)
  let lockedBefore = maybe False (\lo -> maybe False (> ts) lo.lockedUntil) outcome.priorLockout
  when lockedBefore do
    verifyPasswordDummy cmd.password   -- locked accounts pay the same Argon2 cost (REV-2 finding 12)
    failLogin outcome ctx cmd.loginId ts
```

then 244–252 unchanged. `failLogin` becomes `FailureOutcome -> ClientContext -> LoginId ->
UTCTime -> Eff es a`: after the proof has failed, publish `AccountLocked` when
`outcome.lockedNow`, publish `LoginFailed`, and throw `InvalidCredentials`; record nothing.
The threshold-owning request must evaluate the proof: the threshold is the number of failures
allowed, not one fewer, and publishing `AccountLocked` before that proof would emit a false lock
event when the password is correct.
`failLoginTimed` keeps its dummy call. On success replace the `recordLoginAttempt … LoginSuccess`
block with `convertLoginAttemptToSuccess outcome.attemptId`; clear a prior lockout or the one
reserved by this threshold request. If password verification instead advances to MFA, discard
the provisional row and clear only a lock reserved by this request. The successful-login budget
stays at ten (the lockout read becomes the transaction, the success insert becomes the convert);
a wrong password costs four.

Tests. `shomei-core/test/Shomei/Session/Authentication/ConcurrencySpec.hs`:
`testConcurrentWrongPasswordsRespectTheBudget` — seed Alice under `LockoutSpec`'s config
(`maxFailedLoginsPerAccount = 3`), install a counting `PasswordHasher` as
`TimingSpec.hs:148-157` does but with separate `VerifyPassword` and `VerifyPasswordDummy`
counters, `mapConcurrently` 100 wrong-password `login`s, assert real `<= 3`, real plus dummy
`== 100`, every result `Left InvalidCredentials`, exactly one `Event.AccountLocked`, and
`isLocked` afterwards; run it once against the unmodified workflow (stash the `Workflow.hs`
hunk) and paste the red output into Surprises. Add a locked case to `TimingSpec` asserting one
verification. `shomei-postgres/test/Main.hs`: `testFailedLoginRoundTripBudget` (4, beside
`testLoginRoundTripBudget` at 1247) and `testLockoutRecordAndCountIsAtomicUnderRace` — eight
gated threads each call `recordLoginFailure` with `LockPolicy 5 later`; the returned `failures`
are exactly `{1..8}` and exactly one `lockedNow`; red first by deleting the `lockAccountKeyStmt`
line. Docs: `docs/user/security.md` 232–236 — the failure is recorded and counted atomically
*before* the password is verified, so parallel guesses cannot exceed the budget; 195–201 — add
the locked account to the exactly-one-verification list; `docs/user/deployment.md` 364–368 —
rows exist only while a lock is set, a successful login deletes them, elapsed ones are swept.
Commit: `fix(session): make the login lockout an atomic record-and-count before hashing`.

### Milestone 2 — Compare-and-swap the TOTP and passkey counters

Afterwards the replay high-water marks advance only for the request presenting a strictly newer
value, a loser is refused as a replay, and two concurrent completions of one code yield one
login in both suites. Replace `setCounterStmt` (`Totp/Postgres.hs:226-235`) and
`updateSignCounterStmt` (`Passkey/Postgres.hs:207-220`) with:

```sql
UPDATE shomei.shomei_totp_credentials SET last_used_counter = $2
WHERE totp_credential_id = $1 AND (last_used_counter IS NULL OR last_used_counter < $2) RETURNING totp_credential_id
UPDATE shomei.shomei_webauthn_credentials SET sign_counter = $2, last_used_at = $3
WHERE passkey_id = $1 AND (sign_counter < $2 OR ($2 = 0 AND sign_counter = 0)) RETURNING passkey_id
```

decoded `D.rowMaybe (D.column (D.nonNullable D.uuid))`, surfaced as `isJust`. Ports:
`SetTotpLastUsedCounter :: TotpCredentialId -> Int64 -> TotpCredentialStore m Bool`
(`Mfa/Totp/Store.hs:36`) and `UpdatePasskeySignCounter :: PasskeyId -> SignatureCounter ->
UTCTime -> PasskeyStore m Bool` (`Passkey/Store.hs:47`), haddocks saying `False` is replay.
In memory (`InMemory.hs:1017-1018`, 819–820): `casWorld` under the same predicates.

Workflows: `Mfa/Workflow.hs:212` → `Just accepted -> do won <- setTotpLastUsedCounter
totpCredentialId accepted; unless won (failTyped (Just uid) "totp_replayed" TotpCodeInvalid)`;
`Totp/Workflow.hs:127` and `:153` → the same `unless won` with that module's `MfaFailed`
publish and `TotpCodeInvalid` throw; `Mfa/Workflow.hs:190` and `:304` → `won <-
updatePasskeySignCounter passkeyId newSignCounter ts; unless won (failMfa (Just uid) "signature
counter replayed")` (`pkUid` on the passwordless path). `docs/user/mfa.md:21-23` becomes true.

Tests. Core, `ConcurrencySpec`: `testConcurrentTotpCompletionsHaveOneWinner` — enroll and
confirm TOTP for Alice with the helpers the spec under `shomei-core/test/Shomei/Mfa/Totp/` uses,
run `login` 100 times sequentially (each `MfaRequired` carries its own ceremony id, so the
ceremonies do not contend), compute one code from the fixed clock with
`Shomei.Mfa.Totp.Algorithm`, complete all 100 concurrently; assert one `Right`, 99
`Left TotpCodeInvalid`, one `MfaSucceeded` event; red first by reverting the fake to
`modifyWorld`. Postgres: `testTotpCounterIsCompareAndSwap` (set 42 → `True`; 42 → `False`; 41 →
`False`; 43 → `True`), `testTotpCounterCasUnderRace` (eight gated threads set 42; one `True`),
and the passkey pair including zero-to-zero accepted and zero-after-nonzero refused; bind the
`Bool` at 752 and 1703. Commit: `fix(mfa): compare-and-swap the TOTP and passkey counters`.

### Milestone 3 — Transactional credential and revocation tails, and refresh fidelity

Afterwards the reset, change, logout, and reuse tails are each one `BEGIN … COMMIT` in Postgres
and one atomic world update in memory; a `revoked` token answers `session_revoked`; the
100-racer refresh test asserts exactly one reuse event. `Session/UnitOfWork/Store.hs` gains:

```haskell
  -- | Consume the reset token (CAS); then update the hash, revoke every session and refresh
  -- token of the user, revoke the user's other outstanding reset tokens, and record the events
  -- — atomically. 'False': the CAS lost, nothing written. The caller computes the hash.
  CompletePasswordReset :: PasswordResetTokenId -> UserId -> PasswordHash -> UTCTime -> [AuthEvent] -> AuthUnitOfWork m Bool
  -- | The same tail with no token to consume.
  CompletePasswordChange :: UserId -> PasswordHash -> UTCTime -> [AuthEvent] -> AuthUnitOfWork m ()
  -- | CAS the session active → revoked; only on success revoke its refresh tokens and record
  -- the events. 'False': the session was already dead, nothing written.
  RevokeSessionWithTokens :: SessionId -> UTCTime -> [AuthEvent] -> AuthUnitOfWork m Bool
```

with lower-case `send` wrappers. Export, with plan 33's "shared with the unit-of-work
interpreter" comment: `updatePasswordHashStmt` (`Account/Credential/Postgres.hs`),
`markConsumedStmt` and `revokeUserTokensStmt` (`Account/PasswordReset/Postgres.hs`),
`revokeSessionStmt` and `revokeAllUserSessionsStmt` (`Session/Postgres.hs`),
`revokeSessionTokensStmt` and `revokeUserTokensStmt` (`Session/RefreshToken/Postgres.hs`;
qualify the homonyms). Give `revokeSessionStmt` `AND status = 'active'` and `RETURNING
session_id`, decoded `D.rowMaybe`; the standalone `RevokeSession` arm ignores it. Then:

```haskell
  CompletePasswordReset tid uid newHash ts events -> do
    rows <- traverse toEventRow events
    res <- runTransaction do
      won <- Tx.statement (passwordResetTokenIdToUUID tid, ts) PR.markConsumedStmt
      case won of
        Nothing -> pure False
        Just _ -> do
          Tx.statement (userIdToUUID uid, passwordHashText newHash) updatePasswordHashStmt
          Tx.statement (userIdToUUID uid, ts) revokeAllUserSessionsStmt
          Tx.statement (userIdToUUID uid, ts) RT.revokeUserTokensStmt
          Tx.statement (userIdToUUID uid, ts) PR.revokeUserTokensStmt  -- skips the consumed one (guard)
          True <$ traverse_ (\r -> Tx.statement r insertAuthEventStmt) rows
    either dbFail pure res
```

`CompletePasswordChange` is the same body without the CAS; `RevokeSessionWithTokens` runs
`revokeSessionStmt` and, on `Just`, `revokeSessionTokensStmt` plus the events. In memory each is
one `atomicModifyIORef'`: the reset checks `OneTimeTokenActive`, then applies the consume, the
hash replacement over `credsByLoginId`, both revocations, the sibling revocation, and the event
prepend; the session operation checks `SessionActive` first.

Workflows. Lifecycle 202–207 → `won <- completePasswordReset tok.passwordResetTokenId
tok.userId newHash ts [Event.PasswordResetCompleted …]; unless won (throwError
PasswordResetTokenInvalid)`; 236–239 → one `completePasswordChange`; both drop `SessionStore`,
`RefreshTokenStore`, `AuthEventPublisher` and add `AuthUnitOfWork`. 135–136: add
`revokeUserVerificationTokens user.userId ts` after `markUserEmailVerified`.
`Authentication/Workflow.hs`: line 360 → `RT.RefreshTokenRevoked -> pure (Left SessionRevoked)`;
`reuseDetected` → `won <- revokeSessionWithTokens tok.sessionId ts
[Event.RefreshTokenReuseDetected …]; pure (Left (if won then RefreshTokenReuseDetected else
SessionRevoked))`; `logout` → `_ <- revokeSessionWithTokens sid ts [Event.SessionRevoked
(Event.SessionRevokedData sid Nothing ts)]; pure (Right ())` (still idempotent; a repeat now
audits nothing). Every assembly already interprets `AuthUnitOfWork` (grep `runAuthUnitOfWork`).

Tests. Core: in `testConcurrentRefreshHasOneWinner` (ConcurrencySpec 103–127) add
`length (filter isReuse w.publishedEvents) @?= 1` — red first (99) — keeping the loser set
`[RefreshTokenReuseDetected, SessionRevoked]`; `WorkflowSpec`: logout then present the old
token → `Left SessionRevoked`, no reuse event; `AccountSpec`: two resets requested, one
confirmed, the other `PasswordResetTokenInvalid`; likewise verification. Postgres: extend
`testWorkflowPasswordReset` (1322) to seed two tokens and assert the second reads `revoked`; add
`testLogoutRoundTripBudget` (2), `testPasswordResetRoundTripBudget` (3), and
`testRevokeSessionIsCompareAndSwap` (second call `False`, no event row). Docs: `docs/user/api.md`
refresh — a token revoked by logout answers `401 session_revoked`; `docs/user/security.md`
249–250 — the tails are one transaction and other reset links are revoked. Commit:
`feat(session): transactional credential and revocation tails in the unit of work`.

### Milestone 4 — Compare-and-swap the admin status transition

Change `UpdateUserStatus` (`Account/User/Store.hs:69`) to
`UserId -> [UserStatus] -> UserStatus -> UTCTime -> UserStore m Bool`; the statement:

```sql
UPDATE shomei.shomei_users SET status = $2, updated_at = $4
WHERE user_id = $1 AND status = ANY ($3)
RETURNING user_id
```

encoding `$3` with `E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text)))` as
`Audit/Reader/Postgres.hs` does for `event_type`, decoded `D.rowMaybe`; in memory a `casWorld`
transitioning only when the current status is in the list. In `transition` (Admin 99–109) keep
the pre-read (it distinguishes `UserNotFound` from `InvalidUserStatus`), then
`won <- updateUserStatus target allowed newStatus ts; if won then after ts >> pure (Right ())
else pure (Left InvalidUserStatus)`. No other caller exists. Tests: `Account/Admin/WorkflowSpec`
`testConcurrentSuspendsAuditOnce` — 100 racers call `suspendUser`; one `Right`, the rest
`Left InvalidUserStatus`, one `Event.UserSuspended`; red first by reverting the fake. Postgres:
sequential CAS (`True` then `False`) and the eight-thread race with one `True`. Commit:
`fix(admin): compare-and-swap the user status transition`.

### Milestone 5 — Duplicate email answers 409, at the workflow and at the boundary

In `signup` (Authentication 145–146), after the login-id check: `forM_ cmd.email \e -> do
existingByEmail <- findUserByEmail e; when (isJust existingByEmail) (throwError
EmailAlreadyRegistered)`. In `Database/Postgres.hs` add:

```haskell
-- | The constraint name of a unique violation (SQLSTATE 23505), if that is what failed.
uniqueViolation :: UsageError -> Maybe Text
uniqueViolation = \case
  SessionUsageError (StatementSessionError _ _ _ _ _ (ServerStatementError (ServerError "23505" msg _ _ _))) ->
    constraintName msg   -- the name quoted in: violates unique constraint "…"
  _ -> Nothing

-- | 'postgresUnavailable', except a named unique violation may map to a typed conflict.
postgresWriteError :: (Text -> Maybe AuthError) -> UsageError -> AuthError
postgresWriteError classify err = fromMaybe (postgresUnavailable err) (classify =<< uniqueViolation err)
```

The arities are hasql 1.10.3.x as read in `Hasql/Engine/Errors.hs` of the corpus that
`mori registry show hasql/hasql --full` points at (1.10.3.5); the build resolves 1.10.3.7
(`dist-newstyle/cache/plan.json`), so confirm the patterns compile. `CreateUser`
(`User/Postgres.hs:41-42`) and `CreatePasswordCredential` (`Credential/Postgres.hs:38-39`) use
`postgresWriteError identityConflict`, which maps `shomei_users_login_id_key`,
`shomei_password_credentials_login_id_key`, and M6's `…_login_id_lower_key` pair to
`LoginIdAlreadyRegistered`, and the four email index names to `EmailAlreadyRegistered`. Tests —
Postgres: tighten `test/Main.hs:843-846` to `dup @?= Left LoginIdAlreadyRegistered` (observe
`DependencyUnavailable PostgreSQL` first) and add a duplicate-email case. Servant:
`scenarioSignupConflicts` beside `scenarioNoEmail` (2321), registered with `freshEnv` like its
neighbours: sign up `dup@example.com`; a second signup with a new `loginId` and the same email
is `409` with `code == "email_taken"`; the same `loginId` again is `409 login_id_taken`.
Commit: `fix(account): answer 409 for a duplicate email at signup and map unique violations`.

### Milestone 6 — Schema hygiene, the PostgreSQL floor, and distillation

Run `just new-migration status-checks-and-case-insensitive-identity` from the repository root;
it creates `shomei-migrations/migrations/shomei/0029-status-checks-and-case-insensitive-identity.sql`
and appends it to the manifest. After `SET search_path TO shomei, pg_catalog;`, one
`DROP CONSTRAINT IF EXISTS` / `ADD CONSTRAINT` pair per column (PostgreSQL has no
`ADD CONSTRAINT IF NOT EXISTS`) and four indexes:

```sql
ALTER TABLE shomei_users DROP CONSTRAINT IF EXISTS shomei_users_status_check;
ALTER TABLE shomei_users ADD CONSTRAINT shomei_users_status_check
  CHECK (status IN ('active', 'suspended', 'deleted'));
-- same pair for: shomei_sessions.status ('active','revoked','expired');
--   shomei_refresh_tokens.status ('active','used','revoked','expired');
--   shomei_signing_keys.status ('pending','active','retired','revoked');
--   shomei_email_verification_tokens.status, shomei_password_reset_tokens.status
--     ('active','consumed','revoked','expired'); shomei_login_attempts.outcome ('success','failure');
--   shomei_webauthn_pending_ceremonies.kind ('registration','authentication');
--   shomei_service_accounts.status, shomei_oauth_clients.status ('active','revoked');
--   shomei_oauth_clients.client_type ('confidential','public')
CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_login_id_lower_key ON shomei_users (lower(login_id));
CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_email_lower_key ON shomei_users (lower(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_login_id_lower_key ON shomei_password_credentials (lower(login_id));
CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_email_lower_key ON shomei_password_credentials (lower(email)) WHERE email IS NOT NULL;
```

Write every pair out in full; the values are read from `Codec/Postgres.hs:39-119`,
`Passkey/Ceremony/Postgres.hs:54-55`, `ServiceAccount/Postgres.hs:45-46`, and
`OAuth/Client/Postgres.hs:40-52`. Each `ADD CONSTRAINT` scans its table under an exclusive lock
inside the migration's transaction — fine for a 0.1.0.0 install; a populated host gets the note
REV-6 finding 4 asks for, beside the version floor. `cabal build shomei-migrations` re-embeds the
manifest. Add a Postgres test that raw SQL inserting `status = 'bogus'`, or `Alice@Example.com`
beside `alice@example.com`, fails. In `docs/user/deployment.md`, after "Sizing the connection
pool", add `### PostgreSQL version`: migrations run through pg-migrate, which refuses a server
whose major version is not 17 or 18 (`UnsupportedPostgresVersion`); the suites run on 17; a
populated host should expect the 0029 constraint scans. Add an Unreleased entry to the
`CHANGELOG.md` of `shomei-core`, `shomei-postgres`, `shomei-migrations`, and `shomei-servant`
(the port signature changes are breaking for library callers). Then the distillation pass: if
`docs/adr/` still does not exist, create it per `.claude/skills/exec-plan/ADR.md` with one
record — every single-use or counter transition is one conditional statement returning whether
it happened, and per-key serialization that must enclose a read uses a transaction-scoped
advisory lock — and cite it from Outcomes. Commit:
`feat(migrations): CHECK status columns and case-insensitive identity indexes`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. Every
commit body ends with these trailers:

```text
MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/55-atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

Before M1, confirm the lock statement's shape once against the dev database
(`process-compose up --no-server` provides it); it must print one row holding `1`:

```bash
psql "$PG_CONNECTION_STRING" -c "BEGIN; SELECT 1 FROM pg_advisory_xact_lock(hashtextextended('k', 0)); COMMIT;"
```

If the `FROM` form is refused, use `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))` with
`D.noResult` and record it in the Decision Log. Per milestone: edit; `cabal build all`; the
suite the milestone names; `cabal test all -j1 --test-options="-j1"`; `nix fmt -- <changed
files>`; commit. Run every race test once against the pre-fix code (stash the hunk, or revert
the in-memory handler as the milestone says) and paste the red output into Surprises &
Discoveries before running it green. Expected shapes:

```text
$ cabal test shomei-core --test-options='-p Concurrency'
100 concurrent wrong passwords: at most 3 real verifications, one lock:  FAIL   (pre-fix)
  real verifications: expected <= 3 but got 100; AccountLocked events: expected 1, got several
100 concurrent wrong passwords: at most 3 real verifications, one lock:  OK     (post-fix)
$ cabal test shomei-postgres
  a wrong password costs exactly 4 database round-trips:                 OK
  lockout: eight racing failures count 1..8 and lock once:               OK
  totp counter: eight racing sets, exactly one winner:                   OK
```

For M6, `just new-migration status-checks-and-case-insensitive-identity` prints the created path,
and `tail -1 shomei-migrations/migrations/shomei/manifest` must read `0029-status-checks-and-case-insensitive-identity.sql`.


## Validation and Acceptance

Acceptance is the Purpose made observable against the standalone server on the dev database.
Sixty parallel wrong-password `POST /v1/auth/login` requests for one account
(`seq 60 | xargs -P 60 -I{} curl -s -o /dev/null -w '%{http_code}\n' …`) all answer `401`;
`shomei_login_attempts` holds sixty `failure` rows for the key, `shomei_account_lockouts` one
row with a future `locked_until`, `shomei_auth_events` one `account_locked` row (that at most
five reached the stored hash is what the `ConcurrencySpec` case proves). A correct password
while locked answers the same `401 invalid_login` after the same delay. A TOTP login completed
twice with one code answers `200` once and `401` once in either arrival order. Logout then
refresh with the old token answers `401 session_revoked` with no `refresh_token_reuse_detected`
row. A reset confirmed with one of two outstanding links leaves the other `revoked`. Two
simultaneous suspends answer one `204` and one `409 invalid_user_status` with one
`user_suspended` row. A second signup with an existing email answers `409 email_taken`. `psql`
inserting `status = 'bogus'`, or `Alice@Example.com` beside a lower-case row, fails. With
`log_statement = 'all'`, one HTTP reset shows two `SELECT`s then one `BEGIN … COMMIT` holding
the consume `UPDATE`, the hash `UPDATE`, three revocation `UPDATE`s, and one audit `INSERT`.
`cabal test all -j1 --test-options="-j1"` is green with budgets login 10, wrong password 4,
refresh 5, logout 2, reset 3.


## Idempotence and Recovery

Every step is a source edit plus tests and is safe to repeat. The migration is allocated once
by `just new-migration`; if the recipe runs twice, delete the second file and its manifest line
before rebuilding (the embed fails compilation on a missing or unlisted file). Its
`DROP … IF EXISTS` / `ADD CONSTRAINT` pairs and `CREATE INDEX IF NOT EXISTS` make hand
re-application harmless; pg-migrate's ledger never re-runs it. If a port change leaves the tree
uncompilable mid-way, the compiler lists every call site — finish them rather than reverting. If
a race test is neither reliably red nor green, raise `rounds` or the thread count first; the
properties are exact, so one spurious extra winner is a real bug. Commit per milestone.


## Interfaces and Dependencies

No new package dependencies: `async` is already a `shomei-core` test dependency and
`shomei-postgres/test/Main.hs` already imports `Control.Concurrent` and `MVar`.
`mori registry show hasql/hasql --full` locates hasql, hasql-pool, and hasql-transaction (corpus
1.10.3.5 / 1.4.2 / 1.2.2; resolved build 1.10.3.7 / 1.4.2.3 / 1.2.3.1 — verify constructor
shapes against the resolved versions); a losing CAS commits an empty transaction, never `condemn`.

Signatures that must exist at the end of each milestone, by full module path: M1 —
`Shomei.Id.LoginAttemptId` and its three helpers; `Shomei.Session.LoginAttempt.Domain.LockPolicy`,
`FailureOutcome`, `LoginAttempt.attemptId`; `Shomei.Session.LoginAttempt.Store.RecordLoginFailure`
and `ConvertLoginAttemptToSuccess` as written above, `RecordLoginAttempt` gone. M2 —
`Shomei.Mfa.Totp.Store.SetTotpLastUsedCounter` and `Shomei.Passkey.Store.UpdatePasskeySignCounter`
returning `Bool`. M3 — the three `Shomei.Session.UnitOfWork.Store` operations with wrappers, the
seven exported statements, `Shomei.Session.Postgres.revokeSessionStmt :: Statement (UUID, UTCTime) (Maybe UUID)`.
M4 — `Shomei.Account.User.Store.UpdateUserStatus` as written above. M5 —
`Shomei.Persistence.Database.Postgres.uniqueViolation` and `postgresWriteError`. M6 — migration
`0029` in the manifest and the `deployment.md` subsection.

Sibling plans: `docs/plans/54-…` owns the login-attempt vocabulary. `RecordLoginFailure` takes
the whole `NewLoginAttempt`, so a factor discriminator flows through the insert unchanged and
the count predicate stays `outcome = 'failure'`; if EP-4 introduces a new outcome value instead
of a column, EP-4 extends `countByAccountStmt`, the `0011` partial indexes, and the `CHECK`.
EP-4 may move `convertLoginAttemptToSuccess` to after the second factor; this plan places it
where `LoginSuccess` is recorded today. `docs/plans/56-…` owns hashing: the unit-of-work
operations take a precomputed `PasswordHash`, and the `shomei_password_credentials (user_id)` index is EP-6's.
