---
id: 69
slug: recover-undelivered-refresh-token-rotations-without-weakening-theft-detection
title: "Recover undelivered refresh-token rotations without weakening theft detection"
kind: exec-plan
created_at: 2026-11-01T21:08:22Z
intention: "intention_01m6cf25q1e3n8zkq3xj09rwfx"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-01T21:08:22Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-01T21:25:48Z
      mode: "update"
      note: "Recovery CAS names the replacement row by id; limit doc corrected; revision note added"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-01T21:30:47Z
      mode: "update"
      note: "Withdrawn before implementation; owner found a fix that keeps the strict reuse contract"
---

# Recover undelivered refresh-token rotations without weakening theft detection

**Status: withdrawn (2026-11-01), before any implementation.** The owner found a fix for IR-4
that does not require Shōmei to accept the bounded theft window this plan trades for
availability, so the plan is not to be implemented. It is kept, complete and consistent, so it
can be revived with `/exec-plan update` if that decision changes; nothing in the working tree
or the database reflects it, and every milestone below is unstarted.

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements improvement request IR-4,
[docs/improvement-requests/recover-undelivered-refresh-rotations.md](../improvement-requests/recover-undelivered-refresh-rotations.md).
Read that request first: it holds the production evidence (two remembered sessions on the labs
intranet revoked within 25 hours because a rotated refresh token never reached the browser) and
the open design questions, every one of which this plan settles in its Decision Log.


## Purpose / Big Picture

Shōmei rotates a refresh token on every use: the presented token is marked spent and a
replacement is returned. If the HTTP response carrying the replacement is lost on its way to
the client (the browser closed the tab, the laptop slept, a reverse proxy's upstream answered
after the browser had gone), the client still holds the spent token. Today its next refresh is
indistinguishable from a thief replaying a stolen token, so Shōmei revokes the whole session and
the person has to sign in again. After this change, a client that presents a spent token whose
replacement nobody ever used, within a bounded window after the rotation, gets a fresh token
pair and keeps its session. Theft detection is preserved: a spent token whose replacement has
been used still trips the alarm, the replacement retired by a recovery becomes a tripwire of
its own, and a thief who gets in through a recovery is caught on the legitimate client's next
refresh.

Someone can see it working against a running `shomei-server` like this: sign up (the response
carries refresh token T), refresh with T (200, carries T1), refresh with T again (200, carries
T2: the recovery), refresh with T1 (401 `token_reuse`: the retired replacement is a tripwire and
the session is now revoked), refresh with T2 (401 `session_revoked`). The audit log shows one
`refresh_token_rotated`, one `refresh_rotation_recovered`, and one
`refresh_token_reuse_detected` row for that session, and
`shomei-admin audit count --type refresh_rotation_recovered` counts recoveries separately from
rotations. Two new settings, `SHOMEI_REFRESH_RECOVERY_WINDOW` and
`SHOMEI_REFRESH_RECOVERY_LIMIT`, bound the behaviour; a window of `0` restores today's contract
exactly.


## Progress

Withdrawn on 2026-11-01 with no milestone started; the checkboxes below describe the work as
planned, not work in flight.

- [ ] M1 — Persistence: a `superseded` refresh-token status (migration 0038), the
  `refresh_rotation_recovered` audit event, and a `RecoverRefreshRotation` unit-of-work
  operation in PostgreSQL and in memory whose single-winner guarantee is proven under real
  database concurrency.
- [ ] M2 — Workflow: `refreshFrom` recovers an undelivered rotation for first-party sessions
  within the configured window and limit, records `refresh_rotation_recovered`, treats a
  superseded token as reuse, and the in-memory test matrix (orderings, bounds, concurrency,
  OAuth exclusion, expiry cap, `remembered`) passes.
- [ ] M3 — Deployment surface: Dhall and environment configuration with boot validation, the
  HTTP end-to-end scenario above, and package changelogs.
- [ ] M4 — Documentation and durable context: `docs/user/security.md`, `api.md`,
  `deployment.md`, `oidc.md` describe the new contract and the accepted theft window; a new
  ADR records the decision; IR-4 is linked and its status advanced; friction triaged and the
  retrospective written.


## Surprises & Discoveries

(None yet. Findings that change the plan go here with evidence; friction with tools and
documents goes to the friction log and is cited here by `FRIC-N` only when it also changed the
plan.)


## Decision Log

- Decision: A recovery supersedes the spent token's unused replacement and issues a new token
  whose parent is the spent token itself, so a spent token may have several children: every
  earlier one `superseded`, at most one live. The retired replacement gets the new status
  `superseded` and its retirement instant is stored in the existing `revoked_at` column; no
  new column is added.
  Rationale: the single-winner guarantee then comes for free from a compare-and-swap on the
  replacement (`status = 'active'` → `'superseded'`), exactly the shape ADR-7 requires, and
  the recursive family walk, the in-memory root walk, and the maintenance sweeper already
  handle a token with several children. A distinct status (not `revoked`) is what IR-4
  demands so that presenting the retired replacement raises the alarm instead of the quiet
  `session_revoked`. Reusing `revoked_at` keeps the row shape, the nine-column codec, and
  every test fixture that lists the columns unchanged; the status column says why the token
  was retired.
  Date: 2026-11-01

- Decision: Every refusal keeps today's behaviour. A spent token is recovered only when the
  feature is on, the presentation is within the window, the session passes every check a
  fresh token would pass (origin binding, absolute deadline, status, email-verification gate),
  the replacement is unused and unexpired, and the limit is not exhausted. Any other
  presentation of a spent token, including the loser of two concurrent recoveries, is reuse:
  family and session revoked, `refresh_token_reuse_detected` published, `401 token_reuse`.
  Rationale: fail closed. The only new behaviour is the narrowly defined recovery; the
  documented contract that a concurrent loser is reuse stays true for recoveries as it is for
  rotations, so a client must still serialize refreshes of one token (nagare-access's
  coalescer does). The alternative, a quiet failure for the loser, would let a thief who wins
  a race against the victim's own retry keep the session undetected after the victim signs in
  again.
  Date: 2026-11-01

- Decision: Recovery applies to first-party sessions only (`BespokeRefresh` at
  `POST /v1/auth/refresh`). A spent token presented by an OAuth client at `POST /oauth/token`
  (`OAuthClientRefresh`) is reuse, as today.
  Rationale: the contract for third-party clients is published in `docs/user/oidc.md` and
  follows the OAuth 2.0 security best current practice; relaxing it is a separate decision
  with a different audience. The labs client is first-party. Extending recovery to OAuth
  sessions is deliberately left as future work and would be one guard in `refreshFrom`.
  Date: 2026-11-01

- Decision: Shipped defaults are on, a 24-hour window, and 3 recoveries per spent token. A
  window of `0` disables recovery and restores today's contract. The user chose these on
  2026-11-01 over a 1-hour window, off-by-default, and a window bounded only by the
  replacement's expiry.
  Rationale: 24 hours covers the observed gaps (15 and 34 minutes) and an overnight idle
  period, while bounding how long a stolen spent token stays useful. The accepted theft window
  is stated in the security argument below and must be written into `docs/user/security.md`.
  Date: 2026-11-01

- Decision: The window is measured from the spent token's `used_at`, the instant of the
  original rotation, and is never extended by a recovery. The limit counts the spent token's
  children in the same statement that supersedes the replacement, so repeated recoveries of
  one token cannot run past it even when they race.
  Rationale: a recovery must not be able to keep a dead token alive indefinitely, and the
  count belongs inside the compare-and-swap predicate so that the limit is a database
  invariant, not a workflow-level read followed by a write.
  Date: 2026-11-01

- Decision: The recovery swap names the replacement row. The workflow first reads the spent
  token's children, picks the single active, unexpired replacement, and only then runs the
  compare-and-swap on that row by id (`refresh_token_id = <replacement> AND parent_token_id =
  <spent> AND status = 'active' …`). It never targets "whichever child is active".
  Rationale: a predicate on "any active child" is single-winner only under the unit of work's
  current READ COMMITTED, no-retry transaction. If plan 65 adds transaction retries, or the
  isolation level changes, a retried loser would find the winner's freshly inserted child and
  supersede it, turning "the loser is reuse" into "up to the limit succeed". Naming the row
  makes the single-winner property independent of isolation and retry policy: a loser keeps
  naming the row that is now `superseded` and can never pick up the winner's child. This is
  the same read-then-swap-by-id shape rotation already uses (`findRefreshTokenByHash`, then
  `markUsedStmt` on that id), and what ADR-7 means by a predicate that names the complete
  valid source state. The cost is one extra read per recovery, and it removes the need for a
  multi-row guard in the interpreter.
  Date: 2026-11-01 (revision)

- Decision: Existing tests that encode "present a token twice, expect reuse" must first spend
  the replacement (rotate it once more) before replaying the original, because under the new
  contract the plain replay is a recovery. The strict concurrency test for rotation
  (`testConcurrentRefreshHasOneWinner`) runs with the window set to `0`, and new race tests
  cover recovery itself.
  Rationale: those tests pin the reuse contract and must keep doing so; weakening their
  assertions to "at most 1 + limit winners" would hide a regression in the rotation
  compare-and-swap. The mixed case (a burst against an active token with recovery on) gets
  its own test with the bound it actually has.
  Date: 2026-11-01

- Decision: Withdraw the plan before implementation.
  Rationale: the owner found a fix for the undelivered-rotation sign-outs that does not
  require Shōmei to accept the theft window described in the security argument (a stolen
  spent token staying useful for up to the window after the legitimate rotation). Shōmei's
  reuse-detection contract therefore stays exactly as documented in `docs/user/security.md`.
  The plan is kept rather than deleted because its design, security argument, and test matrix
  are the starting point if the trade is ever reconsidered.
  Date: 2026-11-01


## Outcomes & Retrospective

Withdrawn on 2026-11-01 before any milestone began. Nothing was delivered and nothing needs to
be undone: no code, migration, configuration, documentation, ADR, or improvement-request change
was made under this plan, and no friction entries were recorded. What the planning itself
produced and is worth keeping: a written security argument for the only relaxation of refresh
reuse detection that could be defended (recovery of an unused, unexpired replacement within a
bounded window, with the retired replacement as a tripwire), the finding that such a recovery
swap must name the replacement row by id to stay single-winner under any transaction retry
policy, and the list of existing tests that silently encode the strict contract. The lesson
for future work on this surface is that the availability problem is better solved where the
undelivered response is lost than by widening what the authentication service accepts.


## Context and Orientation

### Terms

A **refresh token** is an opaque random string a client holds to obtain new access tokens.
Shōmei stores only its SHA-256 hash in `shomei.shomei_refresh_tokens`. **Rotation** is what
happens on every refresh: the presented token is marked `used` (its `used_at` stamped) and a
new token is inserted whose `parent_token_id` points at it; the chain of tokens descended from
one sign-in is the token's **family**. **Reuse detection** is the theft response: presenting a
token that is already `used` revokes the session and every token of the session and publishes
the audit event `refresh_token_reuse_detected`. A **compare-and-swap** (CAS) is a single
conditional `UPDATE … WHERE status = 'active' RETURNING …`: of two concurrent callers exactly
one gets a row back, and the loser learns it lost from the empty result without re-reading.
The **unit of work** is the effect `AuthUnitOfWork` whose PostgreSQL interpreter runs one
multi-table write tail as one transaction, and whose in-memory interpreter applies the same
tail in one `atomicModifyIORef'`. A refresh's **origin** is either `BespokeRefresh` (the
first-party `POST /v1/auth/refresh`) or `OAuthClientRefresh clientId` (`POST /oauth/token` by
an OAuth client); a session minted by an OAuth client can only be refreshed by that client. A
**remembered** session is one whose owner asked to stay signed in; it lasts
`rememberedSessionTTL` (365 days by default) and every token pair it yields reports
`remembered = true`.

An **undelivered rotation** is the failure IR-4 documents: the rotation committed, the response
carrying the replacement never reached the client, and the client's next refresh presents the
spent token. In the labs deployment the client is **nagare-access**, a reverse proxy that
refreshes with Shōmei and delivers the rotated cookie on the upstream response; a browser that
disconnects during the upstream's latency never receives it. nagare-access already coalesces
concurrent refreshes of one token in memory for 30 seconds
(`mori://shinzui/nagare/plans/211-keep-protected-site-sessions-across-concurrent-refreshes-and-shomei-outages`),
which handles bursts; this plan handles the gaps. The origin of the request is
`mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option`.

A **recovery** is the behaviour this plan adds: a spent token's unused replacement is retired
with the new status `superseded` and a new replacement is issued, atomically, to the client
that presented the spent token.

### Where the current behaviour lives

`shomei-core/src/Shomei/Session/Authentication/Workflow.hs` holds `refreshFrom` (the refresh
workflow; `refresh` is its `BespokeRefresh` specialisation), `reuseDetected`, and
`originMayRefresh`. Today a token read as `RT.RefreshTokenUsed` goes straight to
`reuseDetected`, which calls `revokeSessionWithTokens` with a `RefreshTokenReuseDetected` event
and answers `RefreshTokenReuseDetected` when that CAS won, `SessionRevoked` when the session was
already dead. An `RT.RefreshTokenActive` token goes through, in this order: the session is
loaded; `originMayRefresh`; the session's absolute deadline (`SessionExpired`); the session's
status (`SessionRevoked`); the token's own expiry (`RefreshTokenExpired`); the
email-verification gate (`EmailNotVerified`, only when `emailVerificationRequired` is on); then
`rotateRefreshToken` with a `NewRefreshToken` whose `expiresAt` is
`min (addUTCTime cfg.refreshTokenTTL ts) s.expiresAt`; a `RotationConflict` is reuse; a
`Rotated` outcome re-runs claims enrichment and signs the access token with
`authTime = s.authenticatedAt` and `remembered = s.remembered`.

The token row and status are in `shomei-core/src/Shomei/Session/RefreshToken/Domain.hs`
(`RefreshTokenStatus` with `Active | Used | Revoked | Expired`; `PersistedRefreshToken` with
`parentTokenId`, `usedAt`, `revokedAt`). The per-table port is
`shomei-core/src/Shomei/Session/RefreshToken/Store.hs`. The transactional port is
`shomei-core/src/Shomei/Session/UnitOfWork/Store.hs` (`RotateRefreshToken`, `RotationOutcome`,
`RevokeSessionWithTokens`). Its PostgreSQL interpreter is
`shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs`, which lifts prepared statements
owned by `shomei-postgres/src/Shomei/Session/RefreshToken/Postgres.hs` (`markUsedStmt`,
`insertRefreshTokenStmt`, `revokeFamilyStmt`, `revokeSessionTokensStmt`) into one
`runTransaction`. The status text codec is `refreshTokenStatusToText` /
`refreshTokenStatusFromText` in `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs`. The
in-memory interpreter is `runAuthUnitOfWork` in `shomei-core/src/Shomei/Test/InMemory.hs`
(the `World` record has `refreshTokens` and `refreshByHash`; `rootOf` walks parent links).

Audit events are the sum type `AuthEvent` in `shomei-core/src/Shomei/Audit/Event/Domain.hs`,
projected to `(user_id, session_id, event_type, payload, created_at)` by `projectAuthEvent` and
reconstructed by `reconstructAuthEvent` in `shomei-core/src/Shomei/Audit/Event/Codec.hs`;
`shomei-core/test/Shomei/Audit/Event/CodecSpec.hs` round-trips one value per constructor.
Events published inside a unit-of-work transaction go through `toEventRow` in the PostgreSQL
interpreter. Domain errors are `AuthError` in `shomei-core/src/Shomei/Error.hs`; the HTTP
mapping is `authErrorProblem` in `shomei-servant/src/Shomei/Servant/Error.hs`
(`RefreshTokenReuseDetected` → `401 token_reuse`, `SessionRevoked` → `401 session_revoked`).
No new error is needed.

Configuration: `ShomeiConfig` in `shomei-core/src/Shomei/Config.hs` carries the TTLs
(`refreshTokenTTL`, `sessionTTL`, `rememberedSessionTTL`) with `default…` constants and
`defaultShomeiConfig`. The server loads a Dhall file into `FileConfig`
(`shomei-server/src/Shomei/Server/Config.hs`, fields such as `rememberedSessionTtlSeconds ::
Maybe Int`, applied with `maybe cfg0.x fromIntegral fc.x`), overlays the environment in
`overlayCoreFromEnv` (`ttlEnv "SHOMEI_REMEMBERED_SESSION_TTL"`, `intEnvMaybe`), and validates
with helpers such as `requirePositive`. The Dhall record type and its defaults are in
`config/shomei-types.dhall`, and `dhallSchemaMatchesFileConfig` in
`shomei-server/test/Shomei/Server/ConfigSpec.hs` fails when the two drift. Commit `6179d56`
(the remembered-session change) is a complete worked example of adding one setting across
these files and the docs.

Migrations live in `shomei-migrations/migrations/shomei/` with a `manifest`; the newest is
`0037-remembered-sessions.sql`. `just new-migration <slug>` allocates the number, creates the
file with the `SET LOCAL search_path = pg_catalog, pg_temp;` header, and appends to the
manifest; `just migration-check` validates. The status CHECK constraint on refresh tokens was
introduced by `0035-status-checks-and-case-insensitive-identity.sql` as
`shomei_refresh_tokens_status_check CHECK (status IN ('active', 'used', 'revoked', 'expired'))`.
The maintenance sweeper (`shomei-postgres/src/Shomei/Persistence/Maintenance/Postgres.hs`)
deletes dead sessions' tokens one whole session at a time precisely because
`parent_token_id` is a self-referencing foreign key, so a token with several children is safe
there. `oauthIntrospectH` in `shomei-servant/src/Shomei/OAuth/Handler.hs` reports any refresh
token whose status is not `RefreshTokenActive` as inactive, and `oauthRevokeH` revokes the
whole family through `revokeRefreshTokenFamily`; neither needs a change for a `superseded`
token, but both must be re-read to confirm it.

Tests that pin the current contract and will need to change: `testReuseDetected` and
`testReuseRevokesSession` in
`shomei-core/test/Shomei/Session/Authentication/WorkflowSpec.hs` (signup, refresh, replay the
original, expect reuse); `testConcurrentRefreshHasOneWinner` in
`shomei-core/test/Shomei/Session/Authentication/ConcurrencySpec.hs` (100 racers on one
active token, exactly one winner); `testWorkflowReuseRevokesFamily` in
`shomei-postgres/test/Main.hs`; and the reuse step near the end of the lifecycle case in
`shomei-server/test/Shomei/Server/E2ESpec.hs` (it replays the signup token after one refresh and
expects 401). `testAuthorizationCodeConsumeIsAtomicUnderRace` in `shomei-postgres/test/Main.hs`
is the house pattern for a real-database race (eight forked threads released by one `MVar`
gate). The test suites run with `cabal test <package>`; the PostgreSQL and server suites start
an ephemeral PostgreSQL per case and are flaky under `cabal test all` in parallel, so run them
serially (`-j1`) or one package at a time.

### The security argument

Every claim below must survive implementation; the test matrix in M2 is its proof. Let T be a
refresh token the victim holds and T1 its replacement after a rotation.

Today, a spent token is never accepted. A thief who steals T can use it only until the victim
rotates it. If the thief rotates first, the thief holds the session until the victim's next
refresh, which trips the alarm and ends the session for both. If the victim rotates first, the
thief's later replay trips the alarm immediately; the thief gets nothing and the victim is
signed out.

After this change, within the window and while T1 is unused, T is a recovery key. The orderings:

1. Victim rotates T → T1 (delivered or not). Thief replays T within the window before the victim
   refreshes again: the thief recovers, T1 is superseded, the thief holds T2. The victim's next
   refresh presents T1 (superseded) or T (whose live child T2 is unused: a second recovery that
   supersedes T2) — in the first case the alarm fires at once; in the second, the thief's next
   presentation of T2 fires it. Either way theft is detected at the next legitimate refresh,
   exactly when it is detected today in the thief-rotates-first ordering. **This is the accepted
   theft window**: a stolen token remains useful for up to the window after the legitimate
   rotation, not only before it, and a thief who enters through it holds the session until the
   victim's next refresh.
2. Thief rotates T first → T1 (thief). Victim replays T within the window: the victim recovers,
   T1 is superseded, the victim holds T2. The thief's next refresh presents T1: alarm. Today the
   victim's replay fires the alarm; now the thief's does. Same detection point, and the victim
   keeps working until then.
3. Thief replays T after T1 has been used by anyone: reuse, alarm, as today.
4. Thief presents a superseded token: reuse, alarm. Required by IR-4 so that a recovery can
   never quietly orphan the legitimate holder.
5. Two concurrent presentations of a spent token: one recovers, the other is reuse and revokes
   the session (Decision 2). A thief racing the victim's own retry cannot keep the session.
6. Repeated recoveries of one spent token: the limit ends them with the alarm, so a thief and a
   victim cannot ping-pong an unused replacement between them indefinitely, and a client that
   keeps retrying without ever using a replacement is eventually treated as reuse.

What does not change: a token with no row is `RefreshTokenInvalid`; a `revoked` token is
`SessionRevoked` without an alarm; nothing a caller without a token can do differs, so there is
no new oracle; the recovery issues a token capped at the session's `expiresAt`, preserves
`auth_time` and `remembered`, and re-runs claims enrichment, exactly as rotation does; events
carry token identifiers, never token values (ADR-13); an OAuth client session is unaffected.
The whole feature is off with a window of `0`.

### Relevant ADRs

- [ADR-7 Security state transitions are atomic at the persistence boundary](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md):
  a single-use transition is one conditional statement whose predicate includes the complete
  valid source state; a missing returned row is a domain outcome, not a failure; winner-only
  side effects and the audit event commit in the same transaction. The recovery operation is
  built exactly this way.
- [ADR-8 Runtime configuration is open strict and synchronized](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md):
  new settings go into the Dhall record type, its defaults, `FileConfig`, the environment
  overlay, and the docs together; the schema test enforces the first three.
- [ADR-19 Migration components do not mutate shared namespace state](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md):
  migrations are schema-qualified and additive.
- [ADR-13 Credential values and submitted identifiers do not cross diagnostic boundaries](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md):
  the new event carries identifiers only.
- [ADR-6 Authentication freshness is based on credential proof time](../adr/0006-authentication-freshness-is-based-on-credential-proof-time.md):
  a recovered access token keeps `auth_time = session.authenticatedAt`.

No ADR records the reuse-detection contract itself; M4 creates one. No cross-repository ADR
applies.


## Plan of Work

### Milestone 1 — The `superseded` status and the recovery operation

At the end of this milestone the database and both unit-of-work interpreters know how to
retire an unused replacement and issue a new one atomically, and a real-database race proves
that exactly one of several concurrent recoveries succeeds. Nothing user-visible changes yet:
`refreshFrom` does not call the operation.

Add `RefreshTokenSuperseded` to `RefreshTokenStatus` in
`shomei-core/src/Shomei/Session/RefreshToken/Domain.hs`, documented as "a replacement retired
because its rotation was recovered; presenting it is reuse". Map it to and from `"superseded"`
in `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs`. The compiler will point at every
incomplete match; `refreshFrom` gets its arm in M2.

Scaffold the migration with `just new-migration refresh-token-superseded-status` (it allocates
`0038`), then make its body re-create the status constraint, following `0035`:

```sql
-- refresh-token-superseded-status

SET LOCAL search_path = pg_catalog, pg_temp;

-- 'superseded': a rotation's replacement that was retired by a recovery of that rotation,
-- because the client never received it. Presenting a superseded token is treated as reuse.
-- The retirement instant is stored in revoked_at; the status says why the token was retired.
ALTER TABLE shomei.shomei_refresh_tokens
  DROP CONSTRAINT IF EXISTS shomei_refresh_tokens_status_check;
ALTER TABLE shomei.shomei_refresh_tokens
  ADD CONSTRAINT shomei_refresh_tokens_status_check
  CHECK (status IN ('active', 'used', 'superseded', 'revoked', 'expired'));
```

Adding a CHECK constraint validates every existing row under a brief exclusive lock; `0035`
accepted that on the same table, so follow it, but note in the migration changelog that a very
large deployment can split it into `NOT VALID` plus `VALIDATE CONSTRAINT` by hand.

Add the audit event the operation records. In `shomei-core/src/Shomei/Audit/Event/Domain.hs`:

```haskell
-- | A spent refresh token was presented again while its replacement was still unused, and
-- the rotation was recovered: the unused replacement was superseded and a new one issued.
-- Distinct from 'RefreshTokenRotated' so recoveries can be counted and audited separately.
data RefreshRotationRecoveredData = RefreshRotationRecoveredData
  { sessionId :: !SessionId,
    spentTokenId :: !RefreshTokenId,
    supersededTokenId :: !RefreshTokenId,
    occurredAt :: !UTCTime
  }
```

with the constructor `RefreshRotationRecovered RefreshRotationRecoveredData` in `AuthEvent`,
the type string `"refresh_rotation_recovered"` in both directions of
`shomei-core/src/Shomei/Audit/Event/Codec.hs` (projected with no user id and the session id,
exactly like `RefreshTokenRotated`), and a round-trip case in
`shomei-core/test/Shomei/Audit/Event/CodecSpec.hs`.

The workflow needs to read a spent token's children before it can name the replacement. Add
`FindRefreshTokenChildren :: RefreshTokenId -> RefreshTokenStore m [PersistedRefreshToken]`
to the per-table port in `shomei-core/src/Shomei/Session/RefreshToken/Store.hs` with a
`findRefreshTokenChildren` smart constructor; in
`shomei-postgres/src/Shomei/Session/RefreshToken/Postgres.hs` it is
`SELECT … FROM shomei.shomei_refresh_tokens WHERE parent_token_id = $1 ORDER BY created_at`
decoded with `D.rowList tokenRowDecoder` (the existing
`shomei_refresh_tokens_parent_token_id_idx` index serves it); in
`shomei-core/src/Shomei/Test/InMemory.hs` it is a filter over `refreshTokens` on
`parentTokenId`.

Add the operation to `AuthUnitOfWork` in `shomei-core/src/Shomei/Session/UnitOfWork/Store.hs`,
with a smart constructor beside `rotateRefreshToken`:

```haskell
-- | The result of an atomic recovery of an undelivered rotation.
--
-- 'RecoveryRefused' means the named replacement was no longer the spent token's live, unused,
-- unexpired child (another recovery superseded it, or a rotation spent it), or the spent
-- token's recovery limit is exhausted. Callers treat it as reuse and never re-read the token
-- to "confirm" it.
data RecoveryOutcome
  = Recovered !PersistedRefreshToken
  | RecoveryRefused
  deriving stock (Generic, Eq, Show)

-- In AuthUnitOfWork:
  -- | Supersede the named replacement of the spent token (CAS @active → superseded@ on that
  -- row by id), insert the new replacement, and record the event — atomically. The first id
  -- is the spent token, the second its replacement as the caller read it. The 'Int' is the
  -- recovery limit: the swap also refuses once the spent token's children (its original
  -- replacement plus one per recovery) exceed it, so at most that many recoveries of one
  -- spent token can ever succeed. The 'UTCTime' is the retirement stamp and the expiry floor
  -- for the replacement being retired.
  RecoverRefreshRotation ::
    RefreshTokenId ->
    RefreshTokenId ->
    UTCTime ->
    Int ->
    NewRefreshToken ->
    AuthEvent ->
    AuthUnitOfWork m RecoveryOutcome
```

In `shomei-postgres/src/Shomei/Session/RefreshToken/Postgres.hs` add and export the statement.
Its predicate names the complete valid source state: that row, still a child of the spent
token, still active, not yet expired, and the spent token's limit not exhausted. The limit is
the subquery, so it is checked in the same snapshot as the swap:

```haskell
-- | Compare-and-swap for a recovery: retire the replacement the caller read, by id. Two
-- concurrent recoveries name the same row; under READ COMMITTED the second blocks on the
-- first's row lock, re-evaluates @status = 'active'@ against the committed row (now
-- @superseded@), matches nothing, and returns no row. Because the row is named, a loser that
-- is retried or arrives later still names the superseded row and loses under any isolation
-- level: it can never pick up the winner's freshly inserted child. The count is the recovery
-- limit: the spent token's children are its original replacement plus one per recovery.
supersedeReplacementStmt :: Statement (UUID, UUID, UTCTime, Int64) (Maybe UUID)
supersedeReplacementStmt =
  preparable
    """
    UPDATE shomei.shomei_refresh_tokens
    SET status = 'superseded', revoked_at = $3
    WHERE refresh_token_id = $2
      AND parent_token_id = $1
      AND status = 'active'
      AND expires_at > $3
      AND (SELECT count(*) FROM shomei.shomei_refresh_tokens c
           WHERE c.parent_token_id = $1) <= $4
    RETURNING refresh_token_id
    """
    ( contrazip4
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.int8))
    )
    (D.rowMaybe (D.column (D.nonNullable D.uuid)))
```

`contrazip4` is already imported from `Contravariant.Extras` by
`shomei-postgres/src/Shomei/Mfa/RecoveryCode/Postgres.hs`; follow that use. In
`shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs` add the arm, mirroring
`RotateRefreshToken` exactly: generate the id and the event row outside the transaction, run
the swap, and on `Just` insert the replacement and the event and answer `Recovered`; on
`Nothing` answer `RecoveryRefused` with nothing written. No multi-row guard is needed: the
statement names one row.

In `shomei-core/src/Shomei/Test/InMemory.hs` add the arm to `runAuthUnitOfWork` as one
`atomicModifyIORef'`: look up the named replacement in `refreshTokens`; when it exists, its
`parentTokenId` is the spent token, its status is `RefreshTokenActive`, its `expiresAt > ts`,
and the number of the spent token's children is at most the limit, set its status to
`RefreshTokenSuperseded` and its `revokedAt` to `Just ts`, insert the new token and its hash,
prepend the event, and answer `Recovered`; otherwise leave the world untouched and answer
`RecoveryRefused`.

Tests for this milestone, all in `shomei-postgres/test/Main.hs` against the real database,
driving the ports directly (sign up, call `refresh` once to obtain T → T1, read T1's id with
`findRefreshTokenChildren T`, then the operation):

- `testRecoverRefreshRotationSupersedesUnusedReplacement`: `Recovered`; T is still `used`, T1
  is `superseded` with `revoked_at` set, the new token is `active` with `parent_token_id = T`,
  `findRefreshTokenChildren T` lists exactly T1 and the new token, the session is untouched,
  and exactly one `refresh_rotation_recovered` event row exists, written in the same
  transaction.
- `testRecoverRefreshRotationRefusesUsedReplacement`: rotate T1 first; the operation answers
  `RecoveryRefused` and inserts nothing.
- `testRecoverRefreshRotationRefusesExpiredReplacement`: set `expires_at` of T1 into the past
  with `execSql`; `RecoveryRefused`.
- `testRecoverRefreshRotationRefusesStaleReplacement`: recover once (T1 superseded, T2 live),
  then call the operation again naming T1: `RecoveryRefused`, T2 untouched, no new row. This is
  the property Decision 6 buys: a loser cannot pick up the winner's child.
- `testRecoverRefreshRotationRefusesForeignReplacement`: name a token that is not a child of
  T (for example T itself, or a token of another session): `RecoveryRefused`.
- `testRecoverRefreshRotationHonoursLimit`: with limit 2, two recoveries succeed and the third
  is refused with no new row.
- `testRecoverRefreshRotationIsAtomicUnderRace`: eight gated threads that all name T1 (the id
  read once before the gate opens), exactly one `Recovered`, `count(*) WHERE parent_token_id =
  T` is 2, exactly one event row, and exactly one row with status `superseded`.

Commit: `feat(session): add the superseded refresh-token status and an atomic rotation
recovery` with the plan and intention trailers.

### Milestone 2 — The recovery path in `refreshFrom`

At the end of this milestone the in-memory workflow recovers an undelivered rotation under the
rules in the Decision Log, and the test matrix proves the security argument.

Add two fields to `ShomeiConfig` in `shomei-core/src/Shomei/Config.hs`, next to the TTLs, with
exported defaults `defaultRefreshRecoveryWindow = 24 * 60 * 60` and
`defaultRefreshRecoveryLimit = 3`, and set them in `defaultShomeiConfig`:

```haskell
    -- | how long after a rotation a spent refresh token may be presented again to recover a
    --     replacement the client never received. Measured from the spent token's @used_at@;
    --     a recovery never extends it. @0@ disables recovery: every spent token is reuse.
    refreshRecoveryWindow :: !NominalDiffTime,
    -- | how many times one spent token may be recovered; the next presentation is reuse.
    refreshRecoveryLimit :: !Int,
```

Restructure `refreshFrom` in `shomei-core/src/Shomei/Session/Authentication/Workflow.hs` so the
active path and the recovery path share the session checks. Split today's guard chain into a
function that loads the session and applies the origin, deadline, and status checks, and a
separate email-verification gate; keep the presented token's own expiry check in the active
path only (a recovery is judged on the replacement's expiry, inside the swap). Then the status
dispatch becomes:

```haskell
    Just tok -> case tok.status of
      RT.RefreshTokenActive -> -- today's path, unchanged in behaviour and error order
      RT.RefreshTokenUsed
        | recoverable origin cfg tok ts -> do
            live <- liveSessionFor origin cfg tok ts   -- origin, deadline, status, email gate
            case live of
              Left _ -> reuseDetected tok ts            -- any refusal is today's behaviour
              Right s -> recover cfg tok s ts
        | otherwise -> reuseDetected tok ts
      RT.RefreshTokenSuperseded -> reuseDetected tok ts
      RT.RefreshTokenRevoked -> pure (Left SessionRevoked)
      RT.RefreshTokenExpired -> pure (Left RefreshTokenExpired)
```

where `recoverable` is true only for `BespokeRefresh`, a positive window, and
`ts <= addUTCTime cfg.refreshRecoveryWindow usedAt` for the token's `usedAt` (a `used` token
with no `usedAt` is corrupt state and is not recoverable). `recover` first reads
`findRefreshTokenChildren tok.refreshTokenId` and chooses the replacement: there must be
exactly one child whose status is `RefreshTokenActive` and whose `expiresAt > ts`, no child
may be `RefreshTokenUsed`, and the number of children must be at most
`cfg.refreshRecoveryLimit`; anything else is `reuseDetected` without touching the database
again. The read is advisory, exactly as `findRefreshTokenByHash` is for rotation: the swap
re-checks every condition by id. With the replacement `r` chosen, `recover` generates and
hashes the new opaque token and calls
`recoverRefreshRotation tok.refreshTokenId r.refreshTokenId ts cfg.refreshRecoveryLimit` with
a `NewRefreshToken` whose `parentTokenId = Just tok.refreshTokenId` and whose `expiresAt` is
`min (addUTCTime cfg.refreshTokenTTL ts) s.expiresAt`, and the event
`Event.RefreshRotationRecovered (Event.RefreshRotationRecoveredData tok.sessionId tok.refreshTokenId r.refreshTokenId ts)`;
`RecoveryRefused` goes to `reuseDetected`, and `Recovered` mints the pair exactly as the
rotation branch does (share that code: enrichment, `authTime = s.authenticatedAt`,
`remembered = s.remembered`). Keep the round-trip shape in mind: a recovery costs exactly one
read more than a rotation (the children of the spent token), and the email gate must still
load the user only when the flag is on.

Update the tests that pin the old contract (Decision 7): in `WorkflowSpec`,
`testReuseDetected` and `testReuseRevokesSession` must rotate the replacement once more before
replaying the original; in `ConcurrencySpec`, `testConcurrentRefreshHasOneWinner` runs with
`cfg {refreshRecoveryWindow = 0}` and keeps every assertion.

Add to `WorkflowSpec`, each a `testCase` on the in-memory world with the default config unless
stated (helper: `advanceTo` already moves the clock):

- `testRecoversUndeliveredRotation`: signup (T), refresh (T1), refresh with T again is `Right`;
  the session is active; T1 is `RefreshTokenSuperseded` with `revokedAt` set; the new token is
  active with `parentTokenId = Just T`; exactly one `RefreshRotationRecovered` event and no
  `RefreshTokenReuseDetected`; the pair's `remembered` equals the session's; the new token's
  `expiresAt` is `min (ts + refreshTokenTTL) session.expiresAt`; the access token's `authTime`
  equals `session.authenticatedAt`. Then refresh with the recovered pair: `Right` (a normal
  rotation).
- `testRecoveryIsCappedAtSessionDeadline`: a remembered login near its deadline; the recovered
  token's `expiresAt` equals `session.expiresAt` and `remembered` is still `True`.
- `testUsedReplacementIsReuse`: T → T1 → T2; replay T: `Left RefreshTokenReuseDetected`, session
  revoked, one reuse event.
- `testSupersededTokenIsReuse`: T → T1; recover with T (T2); present T1:
  `Left RefreshTokenReuseDetected`; session revoked; then T2: `Left SessionRevoked`.
- `testThiefReplaysSpentTokenFirst` (ordering 1): victim rotates T → T1 (delivered); thief
  presents T and gets T2; victim presents T1: reuse, session revoked; thief's T2:
  `SessionRevoked`.
- `testThiefRotatesFirst` (ordering 2): thief rotates T → T1; victim presents T and gets T2;
  thief presents T1: reuse, session revoked; victim's T2: `SessionRevoked`.
- `testRecoveryWindowIsMeasuredFromTheRotation`: T → T1; advance past the window; present T:
  reuse. And: recover once inside the window, advance past the window measured from the
  original rotation, present T again: reuse, even though the last recovery was recent.
- `testRecoveryDisabledIsTodaysContract`: `refreshRecoveryWindow = 0`; T → T1; present T: reuse.
- `testRecoveryLimit`: `refreshRecoveryLimit = 2`; T → T1; T recovers twice; the third
  presentation of T is reuse and revokes the session.
- `testRecoveryRefusedForOAuthClientSession`: build a client-bound session as
  `testBespokeRefreshRejectsOAuthSession` does; rotate through `refreshFrom (OAuthClientRefresh
  client)`; replay through the same origin: reuse.
- `testRecoveryRefusedWhenSessionExpired`: T → T1; advance past `session.expiresAt` but inside
  the window; present T: `Left RefreshTokenReuseDetected` (today's behaviour, not
  `SessionExpired`).
- `testRecoveryHonoursEmailVerificationGate`: `emailVerificationRequired = True`, unverified
  user, T → T1 cannot even happen for an unverified user, so verify the user, rotate, then
  un-verify in the world and present T: reuse.
- `testRefreshAfterLogoutIsSessionRevoked` stays as is and now also proves a revoked token is
  never recovered.

Add to `ConcurrencySpec`:

- `testConcurrentRecoveriesHaveOneWinner`: after signup and one refresh, 100 racers present T;
  exactly one `Right`; every failure is `RefreshTokenReuseDetected` or `SessionRevoked`; T has
  exactly two children; exactly one `RefreshRotationRecovered` event; the session is revoked
  (losers exist).
- `testConcurrentRefreshWithRecoveryIsBounded`: 100 racers present an active token with the
  default config; the number of `Right` results is at most `1 + refreshRecoveryLimit`; the
  session is revoked; the presented token has at most `1 + refreshRecoveryLimit` children. Put
  a comment on the test explaining why the bound is not 1: a racer that reads the token as
  `used` after the rotation winner committed is a legitimate recovery, and only a racer that
  loses a compare-and-swap is reuse.

Commit: `feat(session): recover an undelivered refresh-token rotation within a bounded window`.

### Milestone 3 — Configuration, the HTTP scenario, and changelogs

At the end of this milestone an operator can set the window and limit in Dhall or the
environment, the server refuses invalid values at boot, and the end-to-end suite exercises the
whole scenario over HTTP against PostgreSQL.

In `shomei-server/src/Shomei/Server/Config.hs` add `refreshRecoveryWindowSeconds :: Maybe Int`
and `refreshRecoveryLimit :: Maybe Int` to `FileConfig` and apply them where the TTLs are
applied; overlay `SHOMEI_REFRESH_RECOVERY_WINDOW` (seconds, via `ttlEnv`) and
`SHOMEI_REFRESH_RECOVERY_LIMIT` (via `intEnvMaybe`) in `overlayCoreFromEnv`; validate at boot
beside the existing calls: `requireNonNegative` for the window and `requirePositive` for the
limit (both helpers exist in that file; adapt the argument type to the resolved values). Add
both fields to the record type and to the defaults in `config/shomei-types.dhall` as
`Optional Natural`, so `dhallSchemaMatchesFileConfig` stays green, and extend
`testLoadAndOverride` in `shomei-server/test/Shomei/Server/ConfigSpec.hs` (the one case that
loads a Dhall file and overrides it from the environment) with the two new settings.

In `shomei-server/test/Shomei/Server/E2ESpec.hs`, fix the reuse step that replays the signup
token after one refresh (it would now be a recovery): rotate the replacement once more before
the replay so it still asserts `401 token_reuse`. Then add a case, in the style of the existing
remembered-session case, that runs the Purpose scenario: refresh T → 200 with T1; refresh T →
200 with T2 and `remembered` unchanged; refresh T1 → `401` with problem code `token_reuse`;
refresh T2 → `401 session_revoked`; and in the database one `refresh_rotation_recovered` row and
one `refresh_token_reuse_detected` row for the session. Also run the same first three steps
with `SHOMEI_REFRESH_RECOVERY_WINDOW=0` in the server's environment (or the config the test
builds) and assert the second refresh with T is `401 token_reuse`.

Changelogs under `## Unreleased`: root `CHANGELOG.md`; `shomei-core/CHANGELOG.md` (breaking:
`RefreshTokenStatus` gains `RefreshTokenSuperseded`, `AuthUnitOfWork` gains
`RecoverRefreshRotation`, `AuthEvent` gains `RefreshRotationRecovered`, `ShomeiConfig` gains
the two fields); `shomei-postgres/CHANGELOG.md`; `shomei-migrations/CHANGELOG.md` (0038);
`shomei-server/CHANGELOG.md` (the two settings and their defaults).

Commit: `feat(server): configure refresh-rotation recovery and prove it end to end`.

### Milestone 4 — Documentation, ADR, and the request's status

At the end of this milestone the public contract is written down, the decision is durable, and
IR-4 points at this plan.

`docs/user/security.md`: in the "Refresh tokens" bullet and the "Rotation is a compare-and-swap"
bullet, replace "presenting an already-used token is treated as theft" with the new contract:
a spent token whose replacement was never used may be presented again within
`refreshRecoveryWindow` (default 24 hours) at most `refreshRecoveryLimit` (default 3) times and
yields a new pair; the retired replacement is `superseded` and presenting it is theft; a spent
token whose replacement was used is theft; a concurrent loser is still reuse. State the accepted
theft window in the words of the security argument, say that a window of `0` restores the
strict contract, and say that `shomei-admin audit count --type refresh_rotation_recovered`
counts recoveries. `docs/user/api.md`: the `POST /v1/auth/refresh` paragraph, and the
configuration mention near `rememberedSessionTTL`. `docs/user/deployment.md`: two rows in the
environment table. `docs/user/oidc.md`: one sentence at the refresh-token-binding paragraph
saying rotation recovery does not apply at `POST /oauth/token`.

Create the ADR. Allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall
ADR` (it was `ADR-20` when this plan was written; use whatever it answers), write
`docs/adr/00NN-a-spent-refresh-token-is-a-bounded-recovery-key.md` with the shared profile's
frontmatter (copy `0007`'s shape: `type`, `title`, `description`, `docId`, `status: Accepted`,
`date`, `timestamp`, `originatingPlan: docs/plans/69-…md`, `generated`), with Context (the
undelivered-rotation failure and the previous contract), Decision (the rules in the Decision
Log, the status, the window measured from the rotation, the limit, first-party only, the loser
is reuse), Consequences (the accepted theft window; clients must still serialize refreshes of
one token), and Alternatives rejected (client-side persistence of the old→new mapping; a quiet
loser; unbounded window). Append to `docs/adr/log.md` with `okf log add docs/adr --kind
Addition -m "…"`, regenerate the index with `okf index docs/adr --write`, and run
`just adr-validate`.

Advance IR-4: set `status: in-progress` when M1 starts and `completed` when this plan
completes, bump its `timestamp`, add a sentence under the title linking this plan
(`[docs/plans/69-…](../plans/69-…md)`), log each change with `okf log add
docs/improvement-requests -m "…"`, and validate with
`okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce`.

Then triage the friction entries recorded under this plan, write Outcomes & Retrospective, and
run the ADR distillation pass over the Decision Log and Surprises & Discoveries (the ADR above
should already cover them; update it if implementation changed a rule).

Commit: `docs(security): document refresh-rotation recovery and record ADR-NN`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shomei`, inside the
Nix development shell (`nix develop`, or automatically through direnv). Never search or read
`/nix/store`; find dependency sources with `mori registry search <name>` and `mori path <uri>`.

Build and focused tests, one package at a time (the PostgreSQL-backed suites start an
ephemeral database per case and are flaky under a parallel `cabal test all`):

```bash
cabal build all
cabal test shomei-core --test-show-details=failures
cabal test shomei-postgres --test-show-details=failures
cabal test shomei-server --test-show-details=failures
```

Expected: every suite reports `All N tests passed`. To run one case while iterating, pass a
tasty pattern, for example `cabal test shomei-core --test-options='-p recover'`.

Migration scaffold and checks (M1):

```bash
just new-migration refresh-token-superseded-status
# Created shomei-migrations/migrations/shomei/0038-refresh-token-superseded-status.sql with a transaction-local search path header
just migration-check
```

The migration suite in `shomei-migrations` and the PostgreSQL suite apply every migration to a
fresh ephemeral database, so a malformed constraint fails there before it reaches a deployment.

OKF checks (M4):

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf index docs/adr --write
just adr-validate
okf index docs/improvement-requests --write
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Provenance and friction, with the skill's scripts (model id from the current runtime, per
`agents/skills/exec-plan/PROVENANCE.md`):

```bash
bun agents/skills/exec-plan/record-provenance.ts revision \
  --plan docs/plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md \
  --model <your-model-id> --harness <harness> --mode implement --note "<one line>"
bun agents/skills/exec-plan/record-friction.ts log --title "<what cost effort>" \
  --description "<surface and cost>" --kind <documentation|interface|tooling|environment|process> \
  --impact <blocked|detour|slowdown|nuisance> --affects <uri> \
  --plan docs/plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md \
  --attempted "<what you did>" --encountered "<what happened>" --model <your-model-id> --harness <harness>
```

The friction-log bundle does not exist yet in this repository; the script bootstraps
`docs/friction-log/` on first use and the same change must add the bundle to `okfBundles` in
`mori.dhall` (see `agents/skills/exec-plan/FRICTION.md`).

Every commit carries both trailers:

```text
ExecPlan: docs/plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md
Intention: intention_01m6cf25q1e3n8zkq3xj09rwfx
```


## Validation and Acceptance

Required acceptance, mapped to IR-4's acceptance list:

1. Replaying a spent token whose replacement was never used returns a working token pair,
   leaves the session active, and records `refresh_rotation_recovered`:
   `testRecoversUndeliveredRotation` (core), `testRecoverRefreshRotationSupersedesUnusedReplacement`
   (PostgreSQL), the E2E case (HTTP 200 twice with the same T, then the recovered pair works).
2. Replaying a spent token whose replacement has been used revokes the session and raises
   `refresh_token_reuse_detected`: `testUsedReplacementIsReuse`, the updated
   `testWorkflowReuseRevokesFamily`, the updated E2E reuse step.
3. If a thief replays first, the legitimate client's next refresh revokes the session and raises
   the alarm: `testThiefReplaysSpentTokenFirst` and `testThiefRotatesFirst`, plus
   `testSupersededTokenIsReuse` for the tripwire itself.
4. Concurrent replays of one spent token issue at most one usable replacement, under real
   database concurrency: `testRecoverRefreshRotationIsAtomicUnderRace` (PostgreSQL, eight gated
   threads) and `testConcurrentRecoveriesHaveOneWinner` (in memory, 100 racers, 10 rounds).
5. The recovered token's expiry stays capped at the session's `expiresAt` and `remembered` is
   unchanged: `testRecoveryIsCappedAtSessionDeadline` and the `remembered` assertion in the E2E
   case.
6. `docs/user/security.md` describes the new contract and the theft window it accepts: review
   the diff of M4 against the security argument in this plan; every numbered ordering must be
   stated or implied.

Required bounds and exclusions beyond IR-4's list: `testRecoveryWindowIsMeasuredFromTheRotation`,
`testRecoveryDisabledIsTodaysContract` (and the E2E run with the window at `0`),
`testRecoveryLimit`, `testRecoveryRefusedForOAuthClientSession`,
`testRecoveryRefusedWhenSessionExpired`, `testRecoveryHonoursEmailVerificationGate`, and the
unchanged `testConcurrentRefreshHasOneWinner` under a zero window.

The manual check, against a server started as `docs/user/deployment.md` describes with
`SHOMEI_TOKEN_TRANSPORT=bearer`:

```bash
curl -s -X POST localhost:8080/v1/auth/signup -H 'content-type: application/json' \
  -d '{"loginId":"alice","email":"alice@example.com","password":"correct horse battery staple"}' | jq -r .token.refreshToken > /tmp/T
curl -s -X POST localhost:8080/v1/auth/refresh -H 'content-type: application/json' \
  -d "{\"refreshToken\":\"$(cat /tmp/T)\"}" | jq -r .refreshToken > /tmp/T1
curl -s -X POST localhost:8080/v1/auth/refresh -H 'content-type: application/json' \
  -d "{\"refreshToken\":\"$(cat /tmp/T)\"}" | jq -r .refreshToken > /tmp/T2      # recovery: 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/v1/auth/refresh -H 'content-type: application/json' \
  -d "{\"refreshToken\":\"$(cat /tmp/T1)\"}"                                       # 401 token_reuse
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/v1/auth/refresh -H 'content-type: application/json' \
  -d "{\"refreshToken\":\"$(cat /tmp/T2)\"}"                                       # 401 session_revoked
shomei-admin audit count --type refresh_rotation_recovered                        # 1
```

Before declaring M4 complete, run the repository's `security-review` skill on the branch and
address or explicitly dismiss each finding in Surprises & Discoveries; the user asked for
particular care here, and the review is cheap relative to the contract change.

Proposals, not required acceptance: a `shomei_refresh_recoveries_total` metric (today's metrics
derive from HTTP status, which cannot distinguish a recovery from a rotation); extending
recovery to OAuth client sessions; a `superseded_at` column if forensics ever need the
retirement instant separated from `revoked_at`.


## Idempotence and Recovery

The migration is idempotent in shape (`DROP CONSTRAINT IF EXISTS` then `ADD CONSTRAINT`) and
additive; re-running the suite re-applies it to a fresh database every time. Rolling the
feature off needs no schema change: set `SHOMEI_REFRESH_RECOVERY_WINDOW=0` (or
`refreshRecoveryWindowSeconds = Some 0`) and every spent token is reuse again. Rolling the
*code* back to a build without the status while `superseded` rows exist makes a presentation of
one of those tokens fail in the codec (`unknown refresh-token status: superseded`) as a 500
instead of a 401; those tokens are dead either way, and the rows can be neutralised first with
`UPDATE shomei.shomei_refresh_tokens SET status = 'revoked' WHERE status = 'superseded'`, which
the old CHECK constraint accepts. Every test is self-contained against an ephemeral database or
an in-memory world; nothing in this plan touches a deployment database.


## Interfaces and Dependencies

New or changed interfaces, by full module path:

- `Shomei.Session.RefreshToken.Domain.RefreshTokenStatus` gains `RefreshTokenSuperseded`;
  `Shomei.Persistence.Codec.Postgres` maps it to `"superseded"`.
- `Shomei.Session.RefreshToken.Store` gains `FindRefreshTokenChildren` with the smart
  constructor `findRefreshTokenChildren`; interpreted by
  `Shomei.Session.RefreshToken.Postgres` and `Shomei.Test.InMemory`.
- `Shomei.Session.UnitOfWork.Store` gains `RecoverRefreshRotation` (spent token id,
  replacement id, stamp, limit, new token, event) and `RecoveryOutcome`
  (`Recovered PersistedRefreshToken | RecoveryRefused`) with the smart constructor
  `recoverRefreshRotation`; interpreted by `Shomei.Session.UnitOfWork.Postgres` and
  `Shomei.Test.InMemory.runAuthUnitOfWork`.
- `Shomei.Session.RefreshToken.Postgres` exports `supersedeReplacementStmt`, a
  compare-and-swap that names the replacement row by id.
- `Shomei.Audit.Event.Domain` gains `RefreshRotationRecovered` and
  `RefreshRotationRecoveredData`; `Shomei.Audit.Event.Codec` maps
  `"refresh_rotation_recovered"`.
- `Shomei.Config.ShomeiConfig` gains `refreshRecoveryWindow :: NominalDiffTime` and
  `refreshRecoveryLimit :: Int`, with `defaultRefreshRecoveryWindow` and
  `defaultRefreshRecoveryLimit`.
- `Shomei.Server.Config.FileConfig` gains `refreshRecoveryWindowSeconds` and
  `refreshRecoveryLimit`; environment `SHOMEI_REFRESH_RECOVERY_WINDOW` and
  `SHOMEI_REFRESH_RECOVERY_LIMIT`; `config/shomei-types.dhall` gains the two optional fields.
- Migration `shomei-migrations/migrations/shomei/0038-refresh-token-superseded-status.sql`.
- `Shomei.Session.Authentication.Workflow.refreshFrom` behaviour as specified; its type is
  unchanged. `Shomei.Error.AuthError` and the HTTP problem catalogue are unchanged.

Dependencies whose choice matters: `hasql` and `hasql-transaction` (`Tx.statement` inside
`runTransaction`, which runs `Tx.ReadCommitted Tx.Write` without application-level retries
today; bounds in `shomei-postgres/shomei-postgres.cabal`), `contravariant-extras`
(`contrazip4`), `effectful` (dynamic effects). Verify an API against the resolved source through
Mori before relying on it: `mori registry search hasql`, then read under
`mori path mori://hasql/hasql/packages/hasql-transaction`. This plan has no parent MasterPlan and
no prerequisite plan; it builds on the committed remembered-session change (`6179d56`) and the
unit-of-work port as it exists in the working tree. If plan 65 lands transaction retries first,
nothing here changes: the recovery swap names its row, so a retried loser still loses.


## Revision Notes

- 2026-11-01: After an adversarial re-read, the recovery compare-and-swap now names the
  replacement row by id instead of "any active child of the spent token" (new Decision 6; M1
  operation signature, statement, in-memory arm, and tests; M2 `recover`; Interfaces). The
  old shape was single-winner only under the current READ COMMITTED, no-retry transaction; a
  retried loser could have superseded the winner's child. The workflow gains one read
  (`findRefreshTokenChildren`), the event no longer needs to be a builder, and the multi-row
  `Tx.condemn` guard is gone. The limit parameter's documentation was also corrected: it is the
  number of recoveries one spent token may have, not a bound on its children after the call.
- 2026-11-01: Withdrawn before implementation (status line at the top, Decision 8, Outcomes &
  Retrospective). The owner found a fix that does not lower Shōmei's reuse-detection contract.
  The body is otherwise left intact so the plan can be revived.
