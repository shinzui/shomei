---
id: 28
slug: enforce-absolute-session-expiry-and-atomic-token-state-transitions
title: "Enforce Absolute Session Expiry and Atomic Token-State Transitions"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
intention: "intention_01kx25bwnqecss3zgjtj70zpce"
master_plan: "docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md"
---

# Enforce Absolute Session Expiry and Atomic Token-State Transitions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. A *session* is the durable server-side record of
one login; it carries an absolute deadline (`expiresAt`, set at login to now +
`sessionTTL`, default 30 days). A *refresh token* is the opaque secret a client trades in at
`POST /auth/refresh` for a fresh access token plus a *rotated* replacement refresh token; the
old one is marked `used`, and presenting a `used` token again is treated as theft ("reuse
detection") and revokes the whole token family and the session. *One-time tokens* (password
reset, email verification) are similar single-use secrets.

A July 2026 security review found three holes, all instances of one defect class — a state
transition that is either never checked or checked and applied non-atomically:

1. **Absolute session lifetime is never enforced.** The `refresh` and `verifyToken` workflows
   in `shomei-core/src/Shomei/Workflow.hs` check `s.status /= SessionActive` but never
   `s.expiresAt <= now`. Because each refresh mints a new refresh token expiring at now +
   `refreshTokenTTL` (a sliding window), a client that keeps refreshing holds a session
   forever — the documented 30-day session lifetime is a fiction.
2. **Refresh rotation races.** Marking a refresh token `used` is an unconditional SQL
   `UPDATE` with no `AND status = 'active'` guard and no `RETURNING`. Two requests presenting
   the *same* refresh token concurrently both pass the workflow's status check (both read
   `active`), both "win", and each mints its own replacement — the token family silently
   forks into two live branches and reuse detection never fires. This is exactly the race an
   attacker who stole a refresh token exploits to coexist with the legitimate client.
3. **One-time-token consumption races.** Password-reset and email-verification confirmation
   do find → validate → act → mark-consumed as separate statements, and the mark-consumed
   `UPDATE` also has no status guard, so two concurrent confirmations of the same token can
   both succeed.

After this plan: a session that keeps refreshing still dies at its absolute `expiresAt`
(refresh returns `401 session_expired`); two concurrent presentations of the same refresh
token can never both succeed — the loser of the race is treated as reuse (family + session
revoked, `401 token_reuse`); and two concurrent confirmations of the same password-reset or
email-verification token can never both succeed. All three fixes use the same
compare-and-swap (CAS) pattern — a conditional `UPDATE … WHERE … AND status = 'active'
RETURNING`/row-count check — modeled on the already-correct consume-once
`DELETE … RETURNING` in `shomei-postgres/src/Shomei/Postgres/PendingCeremonyStore.hs`. The
in-memory interpreters get the same semantics, so the pure test suite proves the behavior
without a database, and new concurrency regression tests exercise the actual races.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] M1: `refresh` rejects a session past `expiresAt` with `SessionExpired`; new refresh
      tokens are capped at the session's absolute deadline; core regression tests
      `testRefreshRejectsExpiredSession` and `testSlidingRefreshStillDiesAtDeadline` pass
      (2026-07-08; both observed failing against the pre-fix code — see Surprises).
- [x] M1: `verifyToken` (in `VerifyTokenAndSession` mode) rejects a session past
      `expiresAt`; `Clock` constraint added (no caller needed a change — the only callers
      are tests, whose stacks already interpret `Clock`); core regression test passes
      (2026-07-08).
- [x] M2: `MarkRefreshTokenUsed` effect operation returns `Bool` (won/lost the CAS); the
      compiler flagged no call sites outside the two interpreters and `refresh` (2026-07-08).
- [x] M2: Postgres `markUsedStmt` converted to `UPDATE … AND status = 'active' RETURNING`;
      0 rows ⇒ `False`; `cabal test shomei-postgres` green (23/23) with a new statement-level
      CAS assertion (first mark `True`, second `False`, winner's `used_at` preserved)
      (2026-07-08).
- [x] M2: In-memory `MarkRefreshTokenUsed` converted to an atomic CAS via a new `casWorld`
      helper; *all* `World` mutations became atomic (`modifyWorld`) — see Decision Log
      (2026-07-08).
- [x] M2: `refresh` workflow treats a lost CAS as reuse (invokes the existing
      `reuseDetected` path); `testMarkUsedIsCompareAndSwap` (sequential double-spend) passes
      (2026-07-08).
- [x] M2: Concurrency regression test `Shomei.Workflow.ConcurrencySpec` (100 parallel
      refreshes × 10 rounds; exactly one winner, ≤1 child, session revoked) passes; observed
      failing with **7 winners** against the pre-fix interpreter (2026-07-08).
- [x] M3: `MarkPasswordResetTokenConsumed` / `MarkVerificationTokenConsumed` return `Bool`;
      Postgres statements gained `AND status = 'active' RETURNING`; in-memory interpreters use
      the same `casWorld` CAS (2026-07-08).
- [x] M3: `confirmPasswordReset` / `confirmEmailVerification` consume the token *before*
      acting and abort when the CAS is lost; the pre-existing `testRejectConsumedReset` /
      `testRejectConsumedVerification` cases in `shomei-core/test/Shomei/AccountSpec.hs`
      already covered the sequential double-confirm and still pass unchanged (2026-07-08).
- [x] M3: Concurrency regression test for one-time tokens passes (100 concurrent
      `confirmPasswordReset`: exactly one `Right`, exactly one `PasswordResetCompleted`
      event); observed failing with **2 winners** against the pre-fix interpreter
      (2026-07-08).
- [x] M4: `cabal test all -j1` green — all 12 suites (core 121, postgres 23, servant, jwt,
      server, admin, client, webauthn, openapi, config, and both examples). Postgres CAS
      statement tests pass for all three stores. Docs updated: `docs/user/security.md`
      (compare-and-swap rotation + absolute session lifetime) and `docs/user/api.md`
      (`401 session_expired` on `POST /auth/refresh`) (2026-07-08).
- [x] Living sections of this plan updated; Outcomes & Retrospective written (2026-07-08).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The pre-fix code really does refresh an expired session forever (M1, confirmed).** The
  three new M1 cases were written first and observed red against the unmodified workflow:

  ```text
  refresh rejects a session past its absolute expiry:      FAIL
    expected: Left SessionExpired
     but got: Right (TokenPair {accessToken = "{...\"expiresAt\":\"2026-01-31T00:15:01Z\"...}",
                                refreshToken = "rt-1", expiresIn = 900s})
  sliding refresh still dies at the session deadline:      FAIL
  verifyToken (token+session) rejects an expired session:  FAIL
    expected: Left SessionExpired
     but got: Right (AuthClaims {...})
  ```

  Note the *minted* access token in the first failure: the session's deadline was 30 days
  after signup and the clock stood at day 31, yet `refresh` issued a token valid for another
  15 minutes.

- **The `SessionExpired` error was unreachable at the shared deadline until the guard order
  changed (M1).** With the new cap, a rotated token's `expiresAt` *equals* its session's
  `expiresAt`, and `refresh` checked `tok.expiresAt <= ts` before it ever looked the session
  up — so every deadline crossing would have reported `RefreshTokenExpired` and
  `session_expired` would never be observable in the default configuration
  (`sessionTTL == refreshTokenTTL == 30 d`). `refresh` now looks the session up first and
  checks, in order: session expiry, session status, token expiry. See the Decision Log.

- **Tokens minted by `signup`/`issueSession` are *not* capped at the session deadline.** The
  Decision Log argued no cap is needed there because `sessionTTL >= refreshTokenTTL` "by
  construction"; that holds only for the *default* config. A deployment that sets
  `refreshTokenTTL > sessionTTL` gets a signup token that outlives its session — harmless
  (the session check in `refresh` catches it, which is exactly what
  `testRefreshRejectsExpiredSession` exercises) but it means `testSlidingRefreshStillDiesAtDeadline`
  asserts the cap over *rotated* tokens only.

- **The refresh race is real and wide: 7 winners out of 100 (M2, confirmed).** With the
  in-memory `MarkRefreshTokenUsed` temporarily reverted to `modifyIORef'` + unconditional
  `Map.adjust`, the new concurrency test reports:

  ```text
  100 concurrent refreshes: exactly one winner: FAIL
    expected: 1
     but got: 7
  ```

  Seven live branches of one token family, no reuse detection — exactly the coexistence an
  attacker with a stolen refresh token wants. With the CAS in place the count is 1, over 10
  rounds.

- **A CAS loser can also observe `SessionRevoked`, not only `RefreshTokenReuseDetected`.** The
  plan predicted every loser sees `RefreshTokenReuseDetected`. In fact a thread that read the
  token as `active` *before* another loser's reuse response revoked the session, and reached
  `findSessionById` *after* it, gets `SessionRevoked`. Both are 401s and both mean "the family
  is dead"; the concurrency test accepts either.

- **The one-time-token race is narrower but real: 2 winners out of 100 (M3, confirmed).** With
  the in-memory `MarkPasswordResetTokenConsumed` reverted to the unconditional adjust, the new
  test reports `expected: 1 / but got: 2`. The window is small (find → validate → hash →
  consume) but two threads did change the password and publish two `PasswordResetCompleted`
  events.

- **The email-verification table is `shomei.shomei_email_verification_tokens`,** not
  `shomei.shomei_verification_tokens` as this plan's M3 sketch stated. No schema change was
  needed — the statement was rewritten in place against the real table name.

- **The sequential double-confirm regression anchors already existed.** M3's first test bullet
  asked for them; `testRejectConsumedReset` and `testRejectConsumedVerification` in
  `AccountSpec` already assert exactly that, and they still pass after the workflows moved the
  consume ahead of the act. No new sequential cases were written.

- **`cabal test all` (parallel) is flaky for `shomei-postgres`, independent of this change.**
  Under the load of twelve suites building and running at once, ephemeral-pg times out:

  ```text
  create session + revoke:                                     FAIL
    Exception: Failed to start ephemeral PostgreSQL: TimeoutError
      (ConnectionTimeout {durationSeconds = 60, host = "…/T/pg--1f8cec1a…", port = 52057})
  ```

  Note the first casualty is a test this plan never touched. `cabal test shomei-postgres` alone
  is 23/23, and `cabal test all -j1` is green across all twelve suites. Validation was done
  serially; a future operational plan may want to bound the harness's startup concurrency.

- **`Shomei.Error.SessionExpired` and `Shomei.Domain.Session.SessionExpired` collide.** The
  `AuthError` constructor and the `SessionStatus` constructor share a name; test modules that
  import both must qualify one. `WorkflowSpec` imports `Shomei.Error qualified as Err`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Change the return type of `MarkRefreshTokenUsed`,
  `MarkPasswordResetTokenConsumed`, and `MarkVerificationTokenConsumed` from `()` to `Bool`
  ("did I win the compare-and-swap?") instead of adding new parallel operations.
  Rationale: the old unconditional semantics are exactly the bug; keeping them around as a
  callable operation would invite the same mistake back. The compiler enumerates every call
  site when the type changes, so no caller can be missed. `Bool` (not
  `Maybe Persisted…Token`) suffices because every caller already holds the row it read.
  Date: 2026-07-07

- Decision: The lost-race path for refresh tokens is treated as **reuse** (revoke family +
  session, publish `RefreshTokenReuseDetected`, return `RefreshTokenReuseDetected`), not as
  a benign retry.
  Rationale: at the moment the CAS fails, some other request has already spent this token.
  That is indistinguishable from theft by construction — it is the same observable event the
  existing `used`-status branch handles — and the safe response to possible theft is family
  revocation. A legitimate client that double-submitted merely has to log in again.
  Date: 2026-07-07

- Decision: Session absolute expiry returns the existing `SessionExpired` error (mapped to
  `401 {"error":"session_expired"}` in `shomei-servant/src/Shomei/Servant/Error.hs`), a
  *distinct* code from `session_revoked` and `token_expired`.
  Rationale: the constructor and mapping already exist but are unused by any workflow. The
  error is non-leaking: it is only reachable *after* presenting a valid refresh token or a
  validly-signed access token, so it discloses nothing about other accounts; and a distinct
  code lets clients implement "re-login required" UX correctly.
  Date: 2026-07-07

- Decision: New refresh tokens minted by `refresh` (and only there) cap their expiry at
  `min (now + refreshTokenTTL) session.expiresAt`.
  Rationale: without the cap, a refresh token could outlive its session and every use of it
  would need the session lookup to save it — which works, but leaves a window where a
  revoked-by-expiry session still has "active-looking" rows. Capping keeps stored state
  consistent with the enforced rule. `signup`/`issueSession` need no cap because there
  `sessionTTL` (30 d) ≥ `refreshTokenTTL` (30 d) at creation time by construction — both
  start at the same instant.
  Date: 2026-07-07

- Decision: `verifyToken` gains a `Clock :> es` constraint to compare `s.expiresAt` with the
  current time.
  Rationale: the workflow currently has no notion of "now". Every assembly that runs it
  (in-memory `runInMemory`, the server's `Shomei.Server.App.runAppIO` stack) already
  interprets `Clock`, so the constraint is purely additive.
  Date: 2026-07-07

- Decision: Concurrency regression tests run against the **in-memory** interpreter (with the
  relevant operations made atomic via `atomicModifyIORef'`), spawning genuinely concurrent
  green threads with `Control.Concurrent.Async.mapConcurrently` (new `async` test
  dependency). A Postgres-side test asserts the CAS *statement* semantics sequentially
  (second mark returns `False`; row not double-updated).
  Rationale: a scheduler-level race against real Postgres is flaky in CI; the security
  property lives in the CAS semantics, which the sequential Postgres test pins down exactly,
  while the in-memory concurrent test proves the workflow-level "exactly one winner"
  property deterministically enough (100 threads, assert winners == 1).
  Date: 2026-07-07

- Decision: This plan deliberately does **not** wrap the refresh workflow tail
  (mark-used + insert-new + sign + publish) in a single database transaction. It owns only
  the CAS statement semantics.
  Rationale: the MasterPlan splits ownership: transaction batching of the whole tail belongs
  to the Operational MasterPlan's plan
  `docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md`. The CAS
  alone closes the exploitable security race (two winners) even without cross-statement
  transactions; what remains without a transaction is only a crash-consistency wart (a crash
  between mark-used and insert-new loses the token, forcing re-login — safe). Whichever plan
  lands second reconciles against the other's edits in
  `shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`; plan 33 must preserve the CAS
  statement shape.
  Date: 2026-07-07

- Decision: In `refresh`, evaluate the session's guards (`expiresAt`, then `status`) *before*
  the presented token's own `expiresAt`, rather than the plan's original order.
  Rationale: the plan sketched an expiry-first session branch but left the token-expiry check
  where it was — ahead of the session lookup. Combined with the new cap
  (`min (now + refreshTokenTTL) session.expiresAt`), a rotated token expires at exactly the
  session's deadline, so `RefreshTokenExpired` would always fire first and `SessionExpired`
  would be dead code in the default configuration. Session-first makes `401 session_expired`
  the answer at the absolute deadline ("log in again") and keeps `401 token_expired` for the
  case it describes: a stale token presented against a still-live session. Both are 401s
  reachable only by presenting a valid token secret, so neither leaks. No existing test
  asserted `RefreshTokenExpired`.
  Date: 2026-07-08

- Decision: Make *every* in-memory `World` mutation atomic, not just the three CAS
  operations: `Data.IORef.modifyIORef'` is replaced throughout `Shomei.Effect.InMemory` by a
  local `modifyWorld` built on `atomicModifyIORef'`, plus a `casWorld` helper for the
  conditional transitions.
  Rationale: the concurrency tests drive whole *workflows* — signup, refresh, reuse response —
  from many threads against one shared `IORef World`. An atomic CAS surrounded by
  read-modify-write neighbours (`createRefreshToken`, `revokeSession`, `publishAuthEvent`)
  would let a neighbour's stale write clobber the CAS's result, making the test assert on
  corrupted state rather than on the property under test. Single-threaded behavior is
  unchanged.
  Date: 2026-07-08

- Decision: `confirmPasswordReset` performs the CAS-consume *after* password-policy
  validation but *before* `updatePasswordHash`; `confirmEmailVerification` CAS-consumes
  before `markUserEmailVerified`.
  Rationale: consuming before acting is what closes the race (the CAS is the linearization
  point; only the single winner proceeds to act). Validating the new password *before*
  consuming means a typo'd weak password does not burn the user's reset token — a pure-read
  check cannot widen the race because losers still fail the CAS.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Delivered the purpose in full. All three findings are closed, each with a regression test that
was **observed red against the pre-fix code**:

1. *Absolute session lifetime.* `refresh` and `verifyToken` now consult `session.expiresAt`.
   A session that keeps refreshing dies at its deadline with `401 session_expired`, and rotated
   refresh tokens are capped at `min (now + refreshTokenTTL) session.expiresAt` so stored state
   can never outlive the session. Pre-fix, day-31 refresh happily minted a fresh access token.
2. *Refresh rotation.* `MarkRefreshTokenUsed` is a compare-and-swap in both interpreters
   (`UPDATE … AND status = 'active' RETURNING` / `atomicModifyIORef'`), and the workflow routes
   a lost race into the existing reuse path. Pre-fix, 100 concurrent refreshes of one token
   produced **7** winners and a 7-way forked family with no reuse detection; now exactly 1.
3. *One-time tokens.* Password-reset and email-verification consumption is the same CAS, and
   both workflows consume before acting. Pre-fix, 100 concurrent reset confirmations produced
   **2** winners and two `PasswordResetCompleted` events; now exactly 1.

Deviations from the plan, all recorded above: (a) `refresh` checks the session's guards before
the presented token's own expiry — without that reordering the new cap made `SessionExpired`
dead code; (b) every in-memory `World` mutation became atomic, not just the three CAS
operations, because read-modify-write neighbours would otherwise clobber the CAS under the very
concurrency the tests create; (c) a CAS loser may observe `SessionRevoked` rather than
`RefreshTokenReuseDetected` when another loser's revocation lands first — both are 401s on a
dead family; (d) the sequential double-confirm cases M3 asked for already existed.

Scope held: no schema migration, no new production dependency (only `async` in the core test
suite), and the refresh tail is still not transactional — that remains
`docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md`'s job, which
must preserve the CAS statement shape this plan introduced.

Gaps worth naming: the concurrency proofs live at the in-memory interpreter, while PostgreSQL's
guarantee is pinned only *sequentially* (first mark `True`, second `False`, winner's timestamp
preserved). That is the deliberate trade from the Decision Log — a scheduler race against real
Postgres would be flaky — but it means the SQL row-lock reasoning is argued, not executed. And
`cabal test all` run in parallel is flaky for reasons unrelated to this plan (see Surprises);
validation used `-j1`.


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project built inside a Nix devshell. The packages
this plan touches:

- `shomei-core/` — the transport-agnostic domain: pure types, workflows, and *port effects*
  (typed capabilities in the `effectful` library, e.g. "I can store refresh tokens" =
  `RefreshTokenStore`). An *interpreter* is a concrete implementation of a port: in-memory
  for tests, PostgreSQL for production.
- `shomei-postgres/` — PostgreSQL interpreters of the core ports using the `hasql` library
  (SQL statements are written as `Statement` values with typed encoders/decoders).
- Tests: `shomei-core/test/` (tasty + tasty-hunit, pure, in-memory interpreters) and
  `shomei-postgres/test/Main.hs` (integration tests against throwaway databases provisioned
  by the `shomei-migrations:test-support` ephemeral-pg harness).

The exact current state (verified against the working tree):

**The refresh workflow** is `refresh` in `shomei-core/src/Shomei/Workflow.hs` (lines
269–324). Its happy path today:

```haskell
RT.RefreshTokenActive
  | tok.expiresAt <= ts -> pure (Left RefreshTokenExpired)
  | otherwise -> do
      mSession <- findSessionById tok.sessionId
      case mSession of
        Nothing -> pure (Left SessionNotFound)
        Just s
          | s.status /= SessionActive -> pure (Left SessionRevoked)
          | otherwise -> do
              markRefreshTokenUsed tok.refreshTokenId ts
              rawNew <- generateOpaqueToken
              newHash <- hashRefreshToken rawNew
              _ <-
                createRefreshToken
                  NewRefreshToken
                    { sessionId = tok.sessionId,
                      tokenHash = newHash,
                      parentTokenId = Just tok.refreshTokenId,
                      createdAt = ts,
                      expiresAt = addUTCTime cfg.refreshTokenTTL ts
                    }
              ...
```

Note the two bugs in this excerpt: `s.expiresAt` is never consulted (only `s.status`), and
`markRefreshTokenUsed` is fire-and-forget. The reuse branch already exists in the same
function as the local helper `reuseDetected` (lines 318–324): it calls
`revokeRefreshTokenFamily`, `revokeSession`, publishes
`Event.RefreshTokenReuseDetected`, and returns `Left RefreshTokenReuseDetected`.

**Token/session verification** is `verifyToken` in the same file (lines 347–365). In
`VerifyTokenAndSession` mode it looks the session up and checks only
`s.status /= SessionActive`. It has constraints `(TokenVerifier :> es, SessionStore :> es)`
and no `Clock`.

**Session `expiresAt` is set at creation** in `issueSession`
(`shomei-core/src/Shomei/Workflow/Session.hs`, line ~87: `expiresAt = addUTCTime
cfg.sessionTTL ts`) and in `signup` (`Workflow.hs` line ~138) — and never re-checked
anywhere after that.

**The refresh-token store port** is `shomei-core/src/Shomei/Effect/RefreshTokenStore.hs`:

```haskell
data RefreshTokenStore :: Effect where
  CreateRefreshToken :: NewRefreshToken -> RefreshTokenStore m PersistedRefreshToken
  FindRefreshTokenByHash :: RefreshTokenHash -> RefreshTokenStore m (Maybe PersistedRefreshToken)
  MarkRefreshTokenUsed :: RefreshTokenId -> UTCTime -> RefreshTokenStore m ()
  RevokeRefreshTokenFamily :: RefreshTokenId -> UTCTime -> RefreshTokenStore m ()
  RevokeSessionRefreshTokens :: SessionId -> UTCTime -> RefreshTokenStore m ()
  RevokeAllUserRefreshTokens :: UserId -> UTCTime -> RefreshTokenStore m ()
```

Its Postgres interpreter is `shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`; the
buggy statement (lines 162–171):

```haskell
markUsedStmt :: Statement (UUID, UTCTime) ()
markUsedStmt =
  preparable
    """
    UPDATE shomei.shomei_refresh_tokens
    SET status = 'used', used_at = $2
    WHERE refresh_token_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult
```

No `AND status = 'active'`, no `RETURNING`: two concurrent refreshes both find the row
`active` (separate SELECT), both run this UPDATE (both "succeed"; the second is a no-op
overwrite), and both insert children — forking the family.

**One-time tokens.** `shomei-core/src/Shomei/Workflow/Account.hs` holds
`confirmPasswordReset` (lines 165–198) and `confirmEmailVerification` (lines 110–132). Both
do: hash the presented token → `find…ByHash` → check `status == OneTimeTokenActive &&
expiresAt > ts` (pure helpers `ensureUsableReset`/`ensureUsableVerification`, lines
243–253) → perform the effect (update password / mark email verified) → `mark…Consumed`.
The Postgres `markConsumedStmt` in
`shomei-postgres/src/Shomei/Postgres/PasswordResetTokenStore.hs` (lines 144–153) is again an
unconditional `UPDATE … SET status = 'consumed' WHERE password_reset_token_id = $1` with no
status guard; `shomei-postgres/src/Shomei/Postgres/VerificationTokenStore.hs` has the same
shape for email verification. The one-time-token effect ports are
`shomei-core/src/Shomei/Effect/PasswordResetTokenStore.hs` and
`shomei-core/src/Shomei/Effect/VerificationTokenStore.hs`
(`MarkPasswordResetTokenConsumed :: PasswordResetTokenId -> UTCTime -> … m ()`, and the
verification twin).

**The correct model to copy** is the pending-ceremony store,
`shomei-postgres/src/Shomei/Postgres/PendingCeremonyStore.hs` (lines 127–134): its
`takeStmt` is `DELETE FROM … WHERE ceremony_id = $1 RETURNING <cols>` decoded with
`D.rowMaybe` — at most one concurrent transaction removes and returns the row, so a
challenge is consumable exactly once. Our stores keep their rows (audit value), so the
analogue is a conditional `UPDATE … RETURNING` instead of a `DELETE`, but the
atomicity principle is identical: *the state transition and the "did I get it?" answer are
one statement.*

**The in-memory interpreters** live in `shomei-core/src/Shomei/Effect/InMemory.hs`. All
state is one `World` record in an `IORef`; mutations use `modifyIORef'`, which is **not
atomic** (it is a read-modify-write; two green threads can interleave). The relevant
handlers today:

```haskell
MarkRefreshTokenUsed rid t ->
  liftIO (modifyIORef' ref (#refreshTokens %~ Map.adjust (markUsed t) rid))
...
MarkPasswordResetTokenConsumed tid t ->
  liftIO (modifyIORef' ref (#passwordResetTokens %~ Map.adjust (consume t) tid))
```

They must become CAS operations with `atomicModifyIORef'` so the pure test suite can
exercise real concurrency.

**Error vocabulary** is `AuthError` in `shomei-core/src/Shomei/Error.hs`; it already
contains `SessionExpired`, `SessionRevoked`, `RefreshTokenExpired`,
`RefreshTokenReuseDetected`, `PasswordResetTokenInvalid`, `VerificationTokenInvalid` — no
new constructor is needed. The HTTP mapping is `authErrorToServerError` in
`shomei-servant/src/Shomei/Servant/Error.hs` (`SessionExpired → 401 session_expired`,
already present).

**Refresh-token statuses** (`shomei-core/src/Shomei/Domain/RefreshToken.hs`):
`RefreshTokenActive | RefreshTokenUsed | RefreshTokenRevoked | RefreshTokenExpired`, stored
as the text column `status` (`'active'`/`'used'`/`'revoked'`/`'expired'`, codec in
`shomei-postgres/src/Shomei/Postgres/Codec.hs`). One-time-token statuses
(`Shomei/Domain/OneTimeToken.hs`): `OneTimeTokenActive | OneTimeTokenConsumed |
OneTimeTokenRevoked | OneTimeTokenExpired` (`'active'`/`'consumed'`/…).

Build/test commands (run from the repository root, inside `nix develop`): `cabal build all`,
`cabal test all` (or per package: `cabal test shomei-core`, `cabal test shomei-postgres` —
the latter needs a local PostgreSQL toolchain, which the devshell provides for the
ephemeral-pg harness).


## Plan of Work

Four milestones. M1 enforces the missing absolute-expiry check (no signature changes beyond
one added constraint). M2 converts refresh-token mark-used to a CAS end-to-end (port,
Postgres, in-memory, workflow, tests). M3 applies the identical treatment to the two
one-time-token stores and their workflows. M4 is the full-suite validation plus
documentation. M2 and M3 are independent of each other; both depend on nothing in M1, but
doing M1 first keeps the `refresh` diff reviewable in two small steps.

### Milestone M1 — sessions actually die at `expiresAt`

Scope: after this milestone a refresh against a session whose `expiresAt` has passed returns
`Left SessionExpired` (HTTP `401 session_expired`), a `verifyToken` in
`VerifyTokenAndSession` mode does the same, and no refresh token can ever expire later than
its session. Nothing else changes behavior.

Edits, all in `shomei-core`:

1. In `shomei-core/src/Shomei/Workflow.hs`, function `refresh`, extend the session case
   analysis. Replace the two-guard `Just s` branch with three guards, checking expiry
   *before* status so an expired-and-later-revoked session reports expiry consistently
   (order is observable only when both hold; either order is defensible — pick
   expiry-first and keep it):

   ```haskell
   Just s
     | s.expiresAt <= ts -> pure (Left SessionExpired)
     | s.status /= SessionActive -> pure (Left SessionRevoked)
     | otherwise -> do ...
   ```

2. In the same `otherwise` branch, cap the new token's expiry (per the Decision Log):

   ```haskell
   expiresAt = min (addUTCTime cfg.refreshTokenTTL ts) s.expiresAt
   ```

   (`min` on `UTCTime` is ordinary `Ord`; no import change — `addUTCTime` is already
   imported.)

3. In `verifyToken` (same file), add `Clock :> es` to the constraint list, bind `ts <- now`
   inside the `VerifyTokenAndSession` branch (import `now` is already in scope via
   `Shomei.Effect.Clock (Clock, now)`), and add the same expiry guard:

   ```haskell
   verifyToken ::
     (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
     ShomeiConfig ->
     AccessToken ->
     Eff es (Either AuthError AuthClaims)
   verifyToken cfg token = do
     result <- verifyAccessToken token
     case result of
       Left te -> pure (Left (TokenInvalid te))
       Right claims -> case cfg.sessionCheckMode of
         VerifyTokenOnly -> pure (Right claims)
         VerifyTokenAndSession -> do
           ts <- now
           mSession <- findSessionById claims.sessionId
           case mSession of
             Nothing -> pure (Left SessionNotFound)
             Just s
               | s.expiresAt <= ts -> pure (Left SessionExpired)
               | s.status /= SessionActive -> pure (Left SessionRevoked)
               | otherwise -> pure (Right claims)
   ```

   Then `cabal build all` and fix every caller the compiler flags for the new constraint
   (find them with `rg -n "verifyToken" --type haskell`; the callers all run stacks that
   already interpret `Clock`, so each fix is only a constraint propagation, no new
   interpreters).

4. Tests in `shomei-core/test/Shomei/WorkflowSpec.hs` (tasty/HUnit style; each case builds a
   fresh `World` in an `IORef` and runs workflows through
   `Shomei.Effect.InMemory.runInMemory`). The in-memory clock is the `World.clock` field —
   a *fixed* test time set by `emptyWorld fixedTime`; advance time by writing the field
   (`modifyIORef' ref (#clock .~ later)`) between calls. Add:
   - `testRefreshRejectsExpiredSession`: signup at `fixedTime`; set the clock to
     `fixedTime + sessionTTL + 1`; refresh with the signup's refresh token; expect
     `Left SessionExpired`. This test **fails before** the M1 edit (today it either
     succeeds or reports `RefreshTokenExpired` depending on TTLs — with
     `refreshTokenTTL == sessionTTL` use a config where `refreshTokenTTL` is *longer*, e.g.
     `cfg {refreshTokenTTL = 61 * 24 * 60 * 60}`, so only the session check can catch it).
   - `testSlidingRefreshStillDiesAtDeadline`: signup; loop: advance the clock by 15 days
     and refresh (rotating each time) — three iterations pass; at 45 days total the
     session deadline (30 d) has passed and the refresh returns `Left SessionExpired`.
     Before the fix this loop refreshes forever. Also assert the *stored* expiry of the
     last successfully-minted refresh token is `<=` the session's `expiresAt` (read
     `World.refreshTokens` back from the `IORef`), proving the cap.
   - a `verifyToken` case: with `cfg {sessionCheckMode = VerifyTokenAndSession}`, verify
     the access token from signup after advancing past the deadline; expect
     `Left SessionExpired`.

Acceptance: `cabal test shomei-core` passes with the three new cases; the new cases fail if
the workflow edits are reverted.

### Milestone M2 — refresh-token mark-used becomes a compare-and-swap

Scope: at the end, `markRefreshTokenUsed` answers "did I transition it from active?", both
interpreters implement that atomically, the workflow treats "no" as reuse, and concurrency
tests prove exactly-one-winner.

1. Port (`shomei-core/src/Shomei/Effect/RefreshTokenStore.hs`): change the operation and its
   helper to return `Bool` (`True` = this call performed the `active → used` transition;
   `False` = the token was not `active` anymore — someone else got there first):

   ```haskell
   MarkRefreshTokenUsed :: RefreshTokenId -> UTCTime -> RefreshTokenStore m Bool

   markRefreshTokenUsed :: (RefreshTokenStore :> es) => RefreshTokenId -> UTCTime -> Eff es Bool
   markRefreshTokenUsed i t = send (MarkRefreshTokenUsed i t)
   ```

2. Postgres (`shomei-postgres/src/Shomei/Postgres/RefreshTokenStore.hs`): make the statement
   conditional and observable. Replace `markUsedStmt` with:

   ```haskell
   markUsedStmt :: Statement (UUID, UTCTime) (Maybe UUID)
   markUsedStmt =
     preparable
       """
       UPDATE shomei.shomei_refresh_tokens
       SET status = 'used', used_at = $2
       WHERE refresh_token_id = $1
         AND status = 'active'
       RETURNING refresh_token_id
       """
       (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
       (D.rowMaybe (D.column (D.nonNullable D.uuid)))
   ```

   and the handler:

   ```haskell
   MarkRefreshTokenUsed rid t -> do
     res <- runSession (Session.statement (refreshTokenIdToUUID rid, t) markUsedStmt)
     either dbFail (pure . isJust) res
   ```

   (import `Data.Maybe (isJust)` if the module's prelude does not already provide it).
   Why this is race-free: PostgreSQL row-locks the target row inside the single UPDATE;
   under READ COMMITTED the second concurrent UPDATE waits for the first to commit,
   re-evaluates `status = 'active'` against the new row version, matches zero rows, and
   returns no `RETURNING` row. The check and the write cannot interleave.

3. In-memory (`shomei-core/src/Shomei/Effect/InMemory.hs`): make it a real CAS. Replace the
   `MarkRefreshTokenUsed` handler with an `atomicModifyIORef'` (import it from
   `Data.IORef`, alongside the existing imports) that inspects and transitions in one
   atomic step:

   ```haskell
   MarkRefreshTokenUsed rid t -> liftIO $
     atomicModifyIORef' ref \w ->
       case Map.lookup rid w.refreshTokens of
         Just tok | tok.status == RefreshTokenActive ->
           (w & #refreshTokens %~ Map.adjust (markUsed t) rid, True)
         _ -> (w, False)
   ```

   `atomicModifyIORef'` applies the pure function as one uninterruptible swap, so two
   concurrent callers serialize and exactly one sees `True` — the same guarantee the SQL
   row lock gives.

4. Workflow (`shomei-core/src/Shomei/Workflow.hs`, `refresh`): consume the answer.

   ```haskell
   | otherwise -> do
       won <- markRefreshTokenUsed tok.refreshTokenId ts
       if not won
         then reuseDetected tok ts
         else do
           rawNew <- generateOpaqueToken
           ...
   ```

   The `reuseDetected` helper is unchanged — the lost race takes exactly the theft path
   (family + session revoked, event published, `Left RefreshTokenReuseDetected`).

5. Tests:
   - Sequential double-spend (extend `shomei-core/test/Shomei/WorkflowSpec.hs`, near the
     existing `testReuseDetected`): store-level case — create a refresh token through the
     in-memory store, call `markRefreshTokenUsed` twice; first `@?= True`, second
     `@?= False`.
   - Concurrency regression (new module
     `shomei-core/test/Shomei/Workflow/ConcurrencySpec.hs`; register it in
     `shomei-core.cabal`'s test-suite `other-modules` and in `shomei-core/test/Main.hs`'s
     `testGroup`, following how `Shomei.Workflow.MfaSpec` is wired; add `async` to the
     test-suite `build-depends`): signup once, capture the refresh token, then run
     `mapConcurrently (\_ -> runInMemory ref (refresh cfg cmd)) [1..100 :: Int]` against
     the *shared* `IORef World`. Assert exactly one `Right` among the results, and that the
     losers are `Left RefreshTokenReuseDetected` (the CAS losers) — note: once one loser
     triggers family revocation, later starters may instead observe
     `Left RefreshTokenReuseDetected` via the `used`/`revoked` status branch, which is the
     same constructor, so the assertion is simply `length rights == 1` and all lefts `elem
     [RefreshTokenReuseDetected]`. Also assert on the final `World`: the session is
     revoked iff at least one loser existed, and no *two* children of the presented token
     exist (`length [t | t <- Map.elems w.refreshTokens, t.parentTokenId == Just spent] <= 1`).
     Run the whole scenario a handful of times (e.g. 10 iterations) to shake scheduling.
     This test fails (two winners / forked family) if step 3's CAS is reverted to
     `modifyIORef'` + unconditional adjust — verify that once by temporarily reverting.
   - Postgres statement semantics (extend `shomei-postgres/test/Main.hs`, following the
     existing refresh-token round-trip tests there): create session + token through the
     real interpreters, `markRefreshTokenUsed` twice; expect `True` then `False`; re-read
     the row via `findRefreshTokenByHash` and assert status `RefreshTokenUsed` with the
     *first* call's timestamp in `usedAt`.

Acceptance: `cabal test shomei-core` and `cabal test shomei-postgres` pass; the concurrency
test proves exactly-one-winner.

### Milestone M3 — one-time-token consumption becomes a compare-and-swap

Scope: the same treatment for password-reset and email-verification tokens: consumption is
conditional and atomic, and the workflows consume *before* acting.

1. Ports: in `shomei-core/src/Shomei/Effect/PasswordResetTokenStore.hs` change
   `MarkPasswordResetTokenConsumed :: PasswordResetTokenId -> UTCTime ->
   PasswordResetTokenStore m Bool` (and the `markPasswordResetTokenConsumed` helper's
   type); in `shomei-core/src/Shomei/Effect/VerificationTokenStore.hs` likewise for
   `MarkVerificationTokenConsumed`.

2. Postgres: in `shomei-postgres/src/Shomei/Postgres/PasswordResetTokenStore.hs` replace
   `markConsumedStmt` with the conditional/returning form (mirroring M2 step 2):

   ```haskell
   markConsumedStmt :: Statement (UUID, UTCTime) (Maybe UUID)
   markConsumedStmt =
     preparable
       """
       UPDATE shomei.shomei_password_reset_tokens
       SET status = 'consumed', consumed_at = $2
       WHERE password_reset_token_id = $1
         AND status = 'active'
       RETURNING password_reset_token_id
       """
       (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
       (D.rowMaybe (D.column (D.nonNullable D.uuid)))
   ```

   handler: `either dbFail (pure . isJust) res`. Do the identical edit in
   `shomei-postgres/src/Shomei/Postgres/VerificationTokenStore.hs` (table
   `shomei.shomei_verification_tokens`, key column `verification_token_id`).

3. In-memory (`shomei-core/src/Shomei/Effect/InMemory.hs`): convert both `Mark…Consumed`
   handlers to the `atomicModifyIORef'` CAS shape from M2 step 3, checking
   `tok.status == OneTimeTokenActive`.

4. Workflows (`shomei-core/src/Shomei/Workflow/Account.hs`):
   - `confirmPasswordReset`: keep find → `ensureUsableReset` → password-policy checks →
     `hashPassword`, then **move the consume up** and gate on it:

     ```haskell
     newHash <- hashPassword cmd.newPassword
     won <- markPasswordResetTokenConsumed tok.passwordResetTokenId ts
     unless won (throwError PasswordResetTokenInvalid)
     updatePasswordHash tok.userId newHash
     revokeAllUserSessions tok.userId ts
     revokeAllUserRefreshTokens tok.userId ts
     publishAuthEvent (Event.PasswordResetCompleted (Event.PasswordResetCompletedData tok.userId ts))
     ```

     The loser observes exactly what a stale-token presenter observes
     (`PasswordResetTokenInvalid` → `400 password_reset_token_invalid`) — no new error, no
     leak.
   - `confirmEmailVerification`: same shape — after the existing user/email checks, do
     `won <- markVerificationTokenConsumed tok.verificationTokenId ts`,
     `unless won (throwError VerificationTokenInvalid)`, then `markUserEmailVerified` and
     the event.

5. Tests:
   - `shomei-core/test/Shomei/AccountSpec.hs` (the existing account-workflow spec): add a
     sequential double-confirm case for each flow — request a reset, confirm it twice with
     the same token; first `Right`, second `Left PasswordResetTokenInvalid`; likewise for
     verification (`Left VerificationTokenInvalid`). (Today the second confirm *also*
     fails — but only because the sequential second read sees `consumed`; keep these as
     regression anchors.)
   - Extend `shomei-core/test/Shomei/Workflow/ConcurrencySpec.hs`: 100 concurrent
     `confirmPasswordReset` calls with the same token against a shared world; assert
     exactly one `Right` and that `updatePasswordHash` happened once (the in-memory
     credential's hash equals the fake hasher's tag `"argon2-fake:<newpw>"`, and — the
     sharper assertion — count the `PasswordResetCompleted` events in
     `World.publishedEvents`: exactly 1).
   - `shomei-postgres/test/Main.hs`: double-consume statement test for both token stores
     (`True` then `False`), mirroring M2.

Acceptance: `cabal test shomei-core` and `cabal test shomei-postgres` pass, including the
new exactly-one-winner assertions.

### Milestone M4 — full validation and documentation

Scope: no new behavior; prove everything together and write it down.

Run the full build and every test suite (commands in Concrete Steps). Then update the user
docs to state the now-true guarantees:

- `docs/user/security.md`, "Tokens" section: after the sentence about refresh-token
  rotation/reuse, add that rotation is a *compare-and-swap* — two concurrent presentations
  of one refresh token can never both succeed; the loser triggers family+session revocation
  — and add a sentence that sessions carry an absolute lifetime (`sessionTTL`): refreshing
  extends nothing past `session.expiresAt`, and refresh-token expiry is capped at the
  session deadline. State the same single-winner property for the one-time reset/verify
  tokens.
- `docs/user/api.md`, `POST /auth/refresh` entry: document the additional
  `401 session_expired` outcome ("the session has reached its absolute lifetime; log in
  again").

Finally fill in this plan's Progress/Surprises/Outcomes sections and note any deviation.

Acceptance: `cabal build all` and `cabal test all` green; docs updated; plan sections
current.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei`, inside the
Nix devshell (`nix develop` first if not already in it).

```bash
nix develop            # once, for the toolchain (GHC, cabal, postgres for ephemeral tests)
cabal build all        # after each milestone's edits; must be warning-clean per project flags
cabal test shomei-core           # M1, M2, M3 core tests
cabal test shomei-postgres      # M2, M3 statement tests (spins up throwaway databases)
cabal test all         # M4
```

Expected shape of a passing core run (counts will be higher than today's; the groups shown
are the ones this plan adds):

```text
shomei-core-test
  Shomei.Workflow
    refresh rejects a session past its absolute expiry:            OK
    sliding refresh still dies at the session deadline:            OK
    verifyToken (token+session) rejects an expired session:        OK
    mark-used CAS: second sequential mark returns False:           OK
  Shomei.Workflow.Concurrency
    100 concurrent refreshes: exactly one winner:                  OK
    100 concurrent password-reset confirms: exactly one winner:    OK
  Shomei.Account
    second confirm of a consumed reset token is rejected:          OK
    second confirm of a consumed verification token is rejected:   OK

All N tests passed
```

When changing the three effect GADTs, let the compiler drive: after each signature change
run `cabal build all` and fix every reported call site. Enumerate them up front with:

```bash
rg -n "markRefreshTokenUsed|MarkRefreshTokenUsed" --type haskell
rg -n "markPasswordResetTokenConsumed|MarkPasswordResetTokenConsumed" --type haskell
rg -n "markVerificationTokenConsumed|MarkVerificationTokenConsumed" --type haskell
```

(Expected call sites: the effect module itself, the Postgres interpreter, the in-memory
interpreter, and the one workflow per operation. Test files may pattern-match them too.)

No database migration is needed: every SQL change is statement-side (`WHERE … AND status`,
`RETURNING`); the schema is untouched. Do not create a migration file.

To try it against a live server (optional, illustrative): `just create-database` (creates +
migrates `$PGDATABASE`; idempotent), `cabal run exe:shomei-server`, then in another shell
sign up, capture `refreshToken`, and fire two refreshes in parallel:

```bash
TOK='<refresh token from signup>'
for i in 1 2; do
  curl -s -X POST http://localhost:8080/auth/refresh \
    -H 'Content-Type: application/json' \
    -d "{\"refreshToken\":\"$TOK\"}" &
done; wait
```

Expect exactly one `200 {"accessToken":…}` and one `401 {"error":"token_reuse",…}` (order
nondeterministic); a third call with `$TOK` also returns `401 token_reuse`, and the *winner's*
new token now also fails with `401 token_reuse` because the family was revoked — that is the
theft response working as designed.


## Validation and Acceptance

Acceptance is behavioral:

1. **Absolute expiry.** With the in-memory clock advanced past `signup time + sessionTTL`,
   `refresh` returns `Left SessionExpired` and (in `VerifyTokenAndSession` mode)
   `verifyToken` returns `Left SessionExpired`. Over HTTP that is
   `401 {"error":"session_expired","message":"Session expired"}`. The
   `testSlidingRefreshStillDiesAtDeadline` case demonstrates that repeated refreshing does
   not extend life past the deadline, and that stored refresh-token expiries never exceed
   the session's `expiresAt`.
2. **Refresh CAS.** `markRefreshTokenUsed` returns `True` at most once per token, under
   both interpreters. The concurrency test's invariant — among 100 simultaneous refreshes
   of one token, exactly one `Right`, all others `Left RefreshTokenReuseDetected`, at most
   one child token, session revoked — holds across repeated runs. The Postgres test pins
   the statement semantics (`True`/`False`, single `used_at`).
3. **One-time-token CAS.** Among 100 simultaneous `confirmPasswordReset` calls with one
   token, exactly one `Right` and exactly one `PasswordResetCompleted` event. Sequential
   double-confirm of reset and verification tokens is rejected with the existing generic
   token-invalid errors.
4. **No regressions.** `cabal test all` is green: the existing reuse-detection,
   rotation, lockout, MFA, impersonation, and servant end-to-end suites all still pass —
   in particular the servant E2E scenario (`shomei-servant/test/Main.hs`) which drives
   refresh through the HTTP surface.

Each new test must be observed to *fail* against the pre-fix code at least once during
development (write test first, or temporarily revert the fix) — record that observation in
Surprises & Discoveries with the failure output.


## Idempotence and Recovery

All edits are ordinary compiler-checked source changes; re-running `cabal build`/`cabal
test` is always safe. Changing the three effect operations' return types makes the compiler
enumerate every call site — a partial edit fails to build rather than silently misbehaving;
fix the listed sites and rebuild.

There is no schema migration and no data backfill, so there is nothing to roll back in the
database. Existing rows are untouched: an `active` row behaves as before on its first
consumption; `used`/`consumed` rows now lose the CAS, which is the intended tightening.

Behaviorally the change is safe to deploy mid-fleet: an old node's unconditional UPDATE and
a new node's conditional UPDATE cannot corrupt state (worst case during a mixed window is
the old, weaker behavior). The lost-race response reuses the *existing* family-revocation
path, so operational runbooks for `token_reuse` events are unchanged.

If the concurrency tests flake in CI (they should not — the winner count is exact, not
timing-based), do not weaken the assertion; investigate, because a flake here means the CAS
is not atomic. The only legitimately nondeterministic aspect is *which* caller wins.


## Interfaces and Dependencies

No new library dependencies in production code. Test-suite addition: `async` (for
`Control.Concurrent.Async.mapConcurrently`) in `shomei-core/shomei-core.cabal`'s
`test-suite shomei-core-test` `build-depends`.

Signatures that must exist at the end (full module paths):

- `Shomei.Effect.RefreshTokenStore.MarkRefreshTokenUsed :: RefreshTokenId -> UTCTime ->
  RefreshTokenStore m Bool` and helper
  `markRefreshTokenUsed :: (RefreshTokenStore :> es) => RefreshTokenId -> UTCTime -> Eff es Bool`.
- `Shomei.Effect.PasswordResetTokenStore.MarkPasswordResetTokenConsumed ::
  PasswordResetTokenId -> UTCTime -> PasswordResetTokenStore m Bool` (+ helper).
- `Shomei.Effect.VerificationTokenStore.MarkVerificationTokenConsumed ::
  VerificationTokenId -> UTCTime -> VerificationTokenStore m Bool` (+ helper).
- `Shomei.Workflow.verifyToken :: (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
  ShomeiConfig -> AccessToken -> Eff es (Either AuthError AuthClaims)`.
- `Shomei.Workflow.refresh` — unchanged signature; new behavior: session-expiry guard,
  refresh-expiry cap, CAS-gated rotation with lost-race → reuse.
- Both interpreters of each changed port (`Shomei.Postgres.RefreshTokenStore`,
  `Shomei.Postgres.PasswordResetTokenStore`, `Shomei.Postgres.VerificationTokenStore`,
  `Shomei.Effect.InMemory`) implement the `Bool`-returning CAS semantics; the in-memory ones
  via `atomicModifyIORef'`.

Boundary with other plans: transaction batching of the refresh tail is owned by
`docs/plans/33-transactional-auth-workflows-and-configurable-connection-pool.md` (Operational
MasterPlan). This plan owns the CAS statement shape (`UPDATE … AND status = 'active'
RETURNING`); plan 33 must preserve it when wrapping the statements in one transaction.
Plan 30 (`docs/plans/30-login-timing-oracle-fix-email-verification-enforcement-and-notifier-token-redaction.md`)
edits the disjoint `login` function in the same `Shomei/Workflow.hs`; ordinary rebase
discipline suffices.
