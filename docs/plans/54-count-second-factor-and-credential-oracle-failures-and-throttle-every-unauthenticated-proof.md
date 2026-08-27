---
id: 54
slug: count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof
title: "Count Second-Factor and Credential-Oracle Failures and Throttle Every Unauthenticated Proof"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Count Second-Factor and Credential-Oracle Failures and Throttle Every Unauthenticated Proof

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. It counts wrong *passwords*: after five failures in
fifteen minutes an account is locked, and a per-IP throttle plus a WAI token bucket slow the caller
down. It counts nothing else. This is EP-4 of MasterPlan 8
(`docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md`,
Phase 2, soft dependency on EP-5 = `docs/plans/55-atomic-state-transitions-round-two-lockout-counters-and-transactional-credential-tails.md`).
It closes the review findings that all reduce to "a credential proof that is not a password is free
to guess" — in `docs/reviews/`: REV-1 finding 4 (`project-security-and-performance-baseline.md`),
REV-2 findings 2, 7, 12, 14, 16 (`shomei-core-security-and-performance.md`), REV-4 finding 1
(`shomei-webauthn-security.md`), REV-7 findings 5 and 11 (`shomei-servant-security-and-performance.md`),
and REV-8 finding 8 (`shomei-server-security-and-performance.md`).

After this plan, five things a human can observe are true. A password-holder guessing TOTP codes at
`POST /v1/auth/mfa/complete` is locked out after `maxFailedLoginsPerAccount` wrong codes exactly as
a password guesser is — likewise recovery codes, passkey assertions, the current password at
`POST /v1/auth/password/change`, and the code at `DELETE /v1/auth/totp`; a locked account cannot
complete MFA, and the lockout clears only when the *second* factor passes. A suspended account's
attempts are counted and audited, and a locked account's login still costs one Argon2id verification,
so `docs/user/security.md`'s "exactly one verification" is true on every path. Every access token
carries `auth_time` — the instant the last credential was proven — which a refresh preserves, and
the freshness gates (recovery-code regeneration, impersonation, and now TOTP removal) read it, so
`403 reauthentication_required` genuinely means "log in again". The `RateLimited` marker becomes
real: the limiter's path set is derived from the API type, and the MFA completion, passkey login,
password-change, confirm, and `/oauth/token` routes join it. And passwordless passkey login demands
user verification (PIN/biometric) regardless of the step-up policy.

The proof that matters is an end-to-end negative: a scripted TOTP-guessing loop that *succeeds*
against today's code after five wrong codes and is locked out once M2 lands.


## Progress

- [x] (2026-08-27T17:33:39Z) M1: `AttemptFactor` vocabulary; accounting helpers in `Shomei.Session.LoginAttempt.Workflow`;
      `login` refactored: suspended branch counted, locked branch hashes, MFA branch records no
      success and clears no lockout; `TimingSpec` and `LockoutSpec` cases; 262 core and 61
      PostgreSQL tests passed.
- [x] (2026-08-27T17:27:58Z) M2 regression: added the HTTP TOTP-guessing scenario and observed
      the pre-fix correct proof return `200` after the fifth wrong code (transcript in Surprises).
- [x] (2026-08-27T17:48:45Z) M2: `ProofContext`; the four proof workflows gated and counted;
      `PasswordChangeFailed`; `RemoteHost` on four routes; TOTP, passkey, password-change, and
      removal lockout regressions green. The core, PostgreSQL, Servant, and server suites passed.
- [x] (2026-08-27T18:02:41Z) M3: `auth_time` on claims, sessions, and the wire; refresh preserves it;
      gates read it; TOTP removal requires freshness; compatibility and forgery tests plus user
      docs complete. Core (267), JWT (63), Servant/OpenAPI (62), and PostgreSQL (61) tests passed.
- [ ] M4: `Shomei.Servant.Throttle`; thirteen routes marked; conformance test; `api.md` and
      `docs/api/openapi.json` updated.
- [ ] M5: passwordless forces `UVRequired`; docs and capability catalog; ADR distillation; Outcomes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The M2 HTTP regression reproduced the unbounded TOTP oracle before any workflow changes. A
  ceremony created before the fifth bad proof still minted tokens when completed with the correct
  code afterward:

  ```text
  EP-4: a TOTP guessing loop is locked out after maxFailedLoginsPerAccount wrong codes: FAIL
    locked completion body: Just (Object ... accessToken ...)
    expected: 401
     but got: 200
  ```

  The command was `cabal test shomei-servant --test-options='-p EP-4'
  --test-show-details=direct`; the unrelated OpenAPI test executable rejected the forwarded tasty
  pattern, while `shomei-servant-test` ran the scenario and produced the evidence above.

- The migration allocator placed `login-attempts-factor` at `0033`, not the draft's illustrative
  `0029`, because EP-1 through EP-3 had already landed migrations through `0032`. This confirms the
  MasterPlan rule that migration slugs, rather than draft numbers, carry identity.

- The initial HTTP regression advanced the proof clock but left the successful enrollment/login in
  the future. Because failure counting deliberately starts after the latest success, those failures
  were correctly excluded. Keeping the enrollment at the fixture clock and moving only the proof
  clock forward made the test model real monotonic time and exposed the intended pre-fix `200`.

- The freshness HTTP regression uses the in-memory workflow clock while jose validates `iat` against
  the real wall clock. Refreshing after moving the fake clock ten minutes forward therefore produced
  a future-issued JWT and a misleading `401`, before the freshness handler ran. Starting the TOTP
  scenario twelve minutes in the past lets it advance across the five-minute freshness window while
  keeping both the refreshed `iat` and `exp` valid against jose's real clock.

- The migration allocator placed `sessions-authenticated-at` at `0034`, immediately after M1's
  `0033`, and the PostgreSQL compatibility test confirmed a `NULL authenticated_at` reads as the
  session's `created_at`.


## Decision Log

- Decision: The vocabulary is a `factor` column on `shomei_login_attempts`
  (`password | totp | recovery | passkey | password_change`, `NOT NULL DEFAULT 'password'`);
  `outcome` stays `success | failure`.
  Rationale: Integration Point 4 warns that migration `0011`'s partial indexes are on `outcome`. A new
  *outcome* value would sit outside both indexes and both counting statements; a new *column* leaves
  every statement, index, and count correct and lets the audit trail tell factors apart.
  Date: 2026-08-27

- Decision: The account key reaches the second-factor, passwordless, password-change, and TOTP
  removal workflows through `ProofContext {clientIp, accountKeyOf :: Text -> AccountKey}`, built by
  the handler from `Env.accountKeyOf` and the socket peer; the workflow derives the key from the
  resolved user's `loginId` (or, for a passwordless assertion naming an unknown credential, from the
  presented credential id).
  Rationale: Storing the key on the pending-ceremony row covers only step-up: passwordless has no user
  at begin time, and password change and TOTP removal have no ceremony. One mechanism covers all four;
  the core still holds no crypto (it receives the opaque function `Env.accountKeyOf` already is); and
  the derived key equals the one `login` used, because `mkLoginId` normalizes and the credential row
  matched on that text. `login`'s `ClientContext` is untouched for EP-8.
  Date: 2026-08-27

- Decision: A password proof that leads to an MFA challenge records *no* attempt row and clears *no*
  lockout; the second-factor completion records `success` with its factor and clears it.
  Rationale: The per-account count is "failures since the most recent success" (plan 9). If the
  challenged password proof recorded a success, every TOTP guess would be preceded by a login that
  resets the counter and the lockout could never trip. A third outcome (`challenged`) was rejected for
  the index reason above; `MfaChallenged` remains the forensic record.
  Date: 2026-08-27

- Decision: A locked account presenting a second factor is refused with the *same* error a bad proof
  returns (`TotpCodeInvalid`, `RecoveryCodeInvalid`, `MfaAssertionInvalid`), spends the ceremony,
  publishes `MfaFailed` with reason `account_locked`, and records nothing.
  Rationale: Lock state must not leak through completion any more than through login (plan 9); not
  recording while locked mirrors `login` and stops an attacker extending a victim's lockout.
  Date: 2026-08-27

- Decision: `auth_time` is persisted as `shomei_sessions.authenticated_at` (`timestamptz NULL`, read
  as `COALESCE(authenticated_at, created_at)`) and `Session`/`NewSession.authenticatedAt :: UTCTime`
  appended after `oauthClientId`; on the wire it is a jose `NumericDate` written after the extra
  claims; a token without it reads as `iat`; delegated and machine tokens set it to `iat`.
  Rationale: Integration Point 1 prescribes nullable-with-default = `created_at`, which a `COALESCE`
  read gives with no table rewrite; this is the third plan extending the record after EP-1 (`kind`)
  and EP-2 (`grantedScopes`), so the field is appended, never reordered. Writing it exactly like `iat`
  means EP-3's whole-second truncation applies for free; the `iat` fallback keeps pre-deploy tokens
  verifiable, and `iat` *was* the freshness clock. Delegated and machine tokens are not interactive.
  Date: 2026-08-27

- Decision: The throttled path set is derived by a type class (`Shomei.Servant.Throttle.HasThrottledRoutes`)
  walking `NamedRoutes`, `:>`, `:<|>`, and every combinator the API uses, evaluated once in
  `Shomei.Server.Boot.main` and handed to `newRateLimiterFor`; a conformance test pins the derived set
  to the documented routes.
  Rationale: Integration Point 6 says EP-4 "derives the path set from the routes that carry the
  `RateLimited` marker, so the marker becomes true". The class is about 120 lines, and its failure
  mode is the loud one `throttledPath`'s own comment asks for: a combinator without an instance does
  not compile, and a route that gains `RateLimited` is throttled with no list to remember. A test-only
  alternative keeps two lists that can drift and gives an embedding host (EP-9) nothing.
  Date: 2026-08-27

- Decision: `DELETE /v1/auth/totp` is marked `RateLimited` beside the routes the MasterPlan lists.
  Rationale: REV-1 finding 4 names it as the stolen-token TOTP oracle, and it is a "second-factor
  route" in Integration Point 6's words.
  Date: 2026-08-27

- Decision: Passwordless login passes `UVRequired` to `BeginAuthenticationCeremony` unconditionally;
  `webauthnConfig.userVerification` governs the step-up ceremony only; no new configuration key.
  Rationale: REV-4 finding 1. A key defaulting to `required` would exist only to weaken a
  single-factor login to possession-only, and every key costs Dhall, env, and `deployment.md` work
  (Integration Point 7); PIN-less keys keep working for password + step-up.
  Date: 2026-08-27

- Decision: `changePassword`'s wrong-current-password path publishes a new `PasswordChangeFailed`
  event (`password_change_failed`, subject `userId`) rather than reusing `LoginFailed`.
  Rationale: `LoginFailedData` carries a login id and no user id; a password-change failure has a
  proven user and no presented identifier, and `shomei-admin audit user <id>` should show it.
  Date: 2026-08-27

- Decision: Socket-address rendering lives in the lower-level `Shomei.Servant.RemoteHost` module;
  `Shomei.Session.Handler` re-exports `clientIpText` for compatibility while account, MFA, and
  passkey handlers import the lower module directly.
  Rationale: Importing the existing session handler helper from the account handler introduced an
  account/session handler cycle. The conversion is transport infrastructure shared by all handlers,
  not session behavior.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled in. Before completion, distill "every credential proof is a counted login attempt" and
"`auth_time`, not `iat`, is the freshness clock" into `docs/adr/`, created per `ADR.md` if absent.)


## Context and Orientation

Shōmei is a multi-package Cabal project built inside `nix develop` from
`/Users/shinzui/Keikaku/bokuno/shomei`. `shomei-core` holds domain types, *ports* (the `effectful`
capabilities such as `LoginAttemptStore`), workflows, and an in-memory fake of every port
(`shomei-core/src/Shomei/Test/InMemory.hs`); `shomei-postgres` the hasql interpreters;
`shomei-migrations/migrations/shomei/` the numbered SQL files `pg-migrate` applies; `shomei-jwt` the
signer and verifier; `shomei-webauthn` the `webauthn` wrapper; `shomei-servant` the HTTP layer (route
types in each concept's `Api.hs`, handlers in `Handler.hs`); `shomei-server` the standalone binary and
its WAI middleware. Tests are tasty; database suites provision an ephemeral PostgreSQL themselves.

Architecture Decision Records: this repository has no `docs/adr/` bundle (checked 2026-08-27;
`mori.dhall` declares `improvement-requests`, `capabilities`, and `reviews` only), so no local ADR
applies; the records the MasterPlan cites (`mori://shinzui/shomei/okf/improvement-requests/concepts/IR-1`
and `IR-2`) do not bear on abuse protection. Plans 51, 53, 55, and 58 are skeletons at HEAD `5dfd2a6`.

**The login workflow today** — `shomei-core/src/Shomei/Session/Authentication/Workflow.hs`, `login`
(194–282). The abuse gate (227–239) reads the per-IP failure count and the lockout row; line 237
`when (maybe False … lockRow) (throwError InvalidCredentials)` returns *before* any hashing (REV-2
finding 12). The suspended branch (248–250) records and publishes nothing (REV-2 finding 14):

```haskell
  when (user.status /= UserActive) do
    verifyPasswordDummy cmd.password
    throwError UserNotActive
```

Lines 253–263 record `LoginSuccess` and clear the lockout, and only then (276–282) branch to
`prepareMfaChallenge` (REV-2 finding 2). The failure path `failLogin` (307–334) is
`recordLoginAttempt` → `LoginFailed` → `countRecentFailuresByAccount` → maybe `setAccountLockout` +
`AccountLocked` → `throwError`; EP-5 will make that pair one atomic statement, so every new caller
here goes through *one helper*.

**The store** — `shomei-core/src/Shomei/Session/LoginAttempt/Domain.hs` (`LoginOutcome`,
`NewLoginAttempt {accountKey, clientIp, outcome, occurredAt}`), `…/Store.hs` (six operations),
`shomei-postgres/src/Shomei/Session/LoginAttempt/Postgres.hs` (`insertAttemptStmt` 81–96, five
columns; `countByAccountStmt` 99–111 counts `outcome = 'failure'` since the last `'success'`;
`countByIpStmt` 114–122), migration `0011` (partial indexes on `outcome`), the fake at `InMemory.hs`
731–774, `loginOutcomeToText` in `shomei-postgres/src/Shomei/Persistence/Codec/Postgres.hs` 110–113,
and `testLoginAttemptStore` (`shomei-postgres/test/Main.hs` 1343–1366, positional `NewLoginAttempt`).

**Second factors** — `shomei-core/src/Shomei/Mfa/Workflow.hs`: `completeMfa` (148–195) takes the
consume-once ceremony, loads the user (173), and dispatches to a passkey arm, `completeTotp`
(200–214), or `completeRecovery` (219–229); failures go through `failTyped` (234–243) or `failMfa`
(349–357), which publish `MfaFailed` and throw; there is no `LoginAttemptStore` constraint. The
ceremony row (`PendingCeremony`, `Passkey/Domain.hs` 122) carries `userId` only.
`beginPasswordlessLogin` (248–269) calls `beginAuthenticationCeremony []` (258); `prepareMfaChallenge`
passes the user's ids (125). `completePasswordlessLogin` (274–307) resolves the user from the asserted
credential (296–299). `removeTotp` (`Mfa/Totp/Workflow.hs` 136–165) has the same audit-only failure.
TOTP accepts three counters per step (`Mfa/Totp/Algorithm.hs` 90).

**The password oracle** — `shomei-core/src/Shomei/Account/Lifecycle/Workflow.hs` `changePassword`
(209–239): line 233 `unless ok (throwError InvalidCredentials)` with no store or publisher call
(REV-2 finding 7). Its handler `passwordChangeH` (`shomei-servant/src/Shomei/Account/Handler.hs`
111–117) and route `PasswordChangeRoute` (`Account/Api.hs` 40) have no `RemoteHost`.

**Freshness** — `AuthClaims` (`shomei-core/src/Shomei/Authorization/Claims/Domain.hs` 46–73) has
`issuedAt` and no `auth_time`; `reservedClaimKeys` (79) is EP-3's list. `claimsFromAuth`
(`shomei-jwt/src/Shomei/SigningKey/Sign/Jwt.hs` 84–114) seeds `extraClaims` first and writes the
managed claims last; `claimsToAuth` (`…/Verify/Jwt.hs` 126–167) keeps a `managed` list (142).
`requireFreshAuth` (`shomei-servant/src/Shomei/Mfa/Handler.hs` 80–85) and `startImpersonation`
(`shomei-core/src/Shomei/Delegation/Workflow.hs` 74) compare `now` to `issuedAt`, which `refresh`
(`Authentication/Workflow.hs` 415) renews without a credential (REV-2 finding 16, REV-7 finding 5);
`totpDeleteH` (`Mfa/Handler.hs` 61–65) has no gate. `Session`/`NewSession` (`Session/Domain.hs`
17–46) are persisted by `shomei-postgres/src/Shomei/Session/Postgres.hs` (`mkSession` 74,
`rebuildSession` 87, `sessionRowDecoder` 102, `insertSessionStmt` 114) and `…/UnitOfWork/Postgres.hs`
(`sessionRow` 110–120); `OAuth/Authorize/Workflow.hs` 155 stamps the ID token's `authTime` from `issuedAt`.

**Throttling** — `shomei-servant/src/Shomei/Servant/PreHandler.hs` 41–44 routes `RateLimited :> api`
straight through; `shomei-server/src/Shomei/Server/Middleware/RateLimit.hs` `throttledPath` (162–172)
is a literal list of five `POST` paths and `clientKey` (177–181) is EP-8's. `RateLimited` sits on
`login`, `refresh` (`Session/Api.hs` 20, 22), `signup`, `verify-email/request`,
`password-reset/request` (`Account/Api.hs` 30, 32, 36) — the same five. `docs/user/api.md` 197 says
"`/oauth/token` is **not** rate-limited". `docs/api/openapi.json` is the committed snapshot; the
`RateLimited` `HasOpenApi` instance (`Servant/OpenApi.hs` 412) adds a 429 to marked operations.

**User verification** — `shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs` 132 sets
`coaUserVerification = mapUV (userVerification cfg)` for *both* begins; the library enforces UV only
for `Required`; the default is `UVPreferred` (`shomei-core/src/Shomei/Config.hs` 412).

## Plan of Work

### Milestone M1 — the vocabulary, the shared accounting helper, and the login fixes

Scope: after M1 the attempt table says *which* factor failed, every counting and locking decision
goes through one module, `login` counts suspended-account attempts, hashes on the locked branch, and
no longer resets the counter on a password proof that leads to an MFA challenge.

1. From the repository root run `just new-migration login-attempts-factor` (it allocates the next
   number — `0029` at HEAD — and appends the file to the manifest). Content:

   ```sql
   SET search_path TO shomei, pg_catalog;

   -- Which credential the attempt proved or failed to prove; every pre-existing row was a password
   -- attempt. Counting stays by outcome (all factors share one lockout), so 0011's indexes stay right.
   ALTER TABLE shomei_login_attempts
     ADD COLUMN IF NOT EXISTS factor text NOT NULL DEFAULT 'password';
   ```

2. `LoginAttempt/Domain.hs` (after `cabal build shomei-migrations` re-embeds the file): add and export

   ```haskell
   -- | Which credential an attempt proved (or failed to prove). All factors share ONE lockout.
   data AttemptFactor = FactorPassword | FactorTotp | FactorRecoveryCode | FactorPasskey | FactorPasswordChange
     deriving stock (Generic, Eq, Show)
     deriving anyclass (FromJSON, ToJSON)
   ```

   and append `factor :: !AttemptFactor` as the **last** field of `LoginAttempt` and
   `NewLoginAttempt`. Add `attemptFactorToText` (`password`, `totp`, `recovery`, `passkey`,
   `password_change`) to `Codec/Postgres.hs`; widen `AttemptRow` and `insertAttemptStmt` to six
   columns (`contrazip6`), count statements untouched; copy `factor` in `InMemory.hs` `toAttempt`
   (746–752). Rewrite `testLoginAttemptStore` with record syntax and assert a `FactorTotp` failure
   is counted by `countRecentFailuresByAccount`.

3. New `shomei-core/src/Shomei/Session/LoginAttempt/Workflow.hs` (register in `shomei-core.cabal`
   after `Shomei.Session.LoginAttempt.Store`):

   ```haskell
   -- | The one place a credential proof is counted. EP-5 replaces the record-then-count pair
   -- inside 'recordProofFailure' with its atomic statement; nothing else needs to change.
   data AbuseGate = AbuseGate {standingLockout :: !(Maybe AccountLockout), locked :: !Bool}

   -- | Per-IP throttle (throws 'TooManyRequests', publishes 'LoginThrottled'), then the lockout
   -- read. Records nothing; with rate limiting off returns 'AbuseGate Nothing False'.
   guardAbuse :: (LoginAttemptStore :> es, AuthEventPublisher :> es, Error AuthError :> es)
     => RateLimitConfig -> ClientContext -> UTCTime -> Eff es AbuseGate

   -- | Record a failure, count, lock when the budget is spent ('AccountLocked'). Never throws.
   recordProofFailure :: (LoginAttemptStore :> es, AuthEventPublisher :> es)
     => RateLimitConfig -> ClientContext -> AttemptFactor -> UTCTime -> Eff es ()

   -- | Record a success and clear the standing lockout row, if one was read.
   recordProofSuccess :: (LoginAttemptStore :> es)
     => ClientContext -> AttemptFactor -> Maybe AccountLockout -> UTCTime -> Eff es ()
   ```

   The bodies are lifted verbatim from `login` 227–239 and 253–263 and `failLogin` 318–333.

4. Rewrite `login`: `gate <- guardAbuse rl ctx ts`; when `gate.locked`, `verifyPasswordDummy
   cmd.password` then `throwError InvalidCredentials`. The suspended branch becomes
   `verifyPasswordDummy`, `recordProofFailure rl ctx FactorPassword ts`, `publishAuthEvent
   (Event.LoginFailed …)`, `throwError UserNotActive`. `failLogin` becomes `recordProofFailure` +
   `LoginFailed` + `throwError InvalidCredentials`. Move the success record and clear **into the
   non-MFA branch** (`recordProofSuccess ctx FactorPassword gate.standingLockout ts` before
   `issueSession`); the MFA branch records nothing.

5. Tests. `TimingSpec`: "locked account still verifies a password" — five wrong logins for Alice,
   reset the counter, correct password → `Left InvalidCredentials`, `hashCalls @?= 1`. `LockoutSpec`
   (threshold 3): "attempts against a suspended account count toward lockout and publish
   LoginFailed" (suspend, three logins, `isLocked`, three `LoginFailed` in `w.publishedEvents`); "a
   password proof that yields an MFA challenge neither records a success nor clears the lockout"
   (seed a passkey as `Mfa/WorkflowSpec.seedUserWithPasskey` does, plant an expired lockout row, log
   in → `MfaRequired`, the row survives and no `LoginSuccess` attempt exists). `testWorkflowLockout`
   (1368–1385) still passes. Run the three new cases once against the unmodified workflow first.

Acceptance: `cabal test shomei-core shomei-postgres` green. Commit:

```text
feat(core): count every login attempt by factor and hash on the locked branch

Add the AttemptFactor discriminator and the shared accounting helpers; count suspended-account
attempts; hash on the locked branch; stop resetting the counter on an MFA-challenged proof.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M2 — second-factor and credential-oracle accounting, proven by the negative test

Scope: TOTP, recovery-code, and passkey completions (step-up and passwordless), the current password
at change, and the proof at TOTP removal are gated by the lockout and per-IP throttle and counted
against the account; the guessing loop is locked out.

1. **Write the negative test first and watch it fail against HEAD** — the required pre-fix
   observation. In `shomei-servant/test/Main.hs` add `scenarioTotpLockout :: IORef World -> Int -> IO ()`,
   registered as `testCase "EP-4: a TOTP guessing loop is locked out after maxFailedLoginsPerAccount
   wrong codes"` over `freshTotpEnv`, reusing `scenarioTotp`'s enrol/verify prologue (2887–2912). With
   `wrong = "000000"` and the default threshold of 5: four times `login` → `cid` → `complete cid
   wrong` (`401 totp_code_invalid`); then `login` → `cidA`, `login` → `cidB` (both unconsumed);
   `complete cidA wrong` (the fifth failure); `complete cidB (codeAt t)` with the *correct* code; then
   `login` once more. Assert the post-fix contract: `cidB` answers `401 totp_code_invalid` and the
   final login `401 invalid_login`. Against HEAD both come back `200`; paste that into Surprises.

2. `Shomei/Session/Command.hs`: `data ProofContext = ProofContext {clientIp :: !ClientIp,
   accountKeyOf :: !(Text -> AccountKey)}` (no `Show`); `proofContextFor :: ProofContext -> Text -> ClientContext`.

3. `Mfa/Workflow.hs`: `completeMfa` and `completePasswordlessLogin` gain `LoginAttemptStore :> es`
   and a `ProofContext` argument after `cfg`. In `completeMfa`, after `ensureEmailVerified` (178):
   `let ctx = proofContextFor pctx (loginIdText user.loginId)`; `gate <- guardAbuse
   cfg.rateLimitConfig ctx ts`; when `gate.locked`, publish `MfaFailed (Just uid) "account_locked"`
   and throw the arm's error (`TotpCodeInvalid`, `RecoveryCodeInvalid`, `MfaAssertionInvalid`).
   Thread `ctx` and the config into `completeTotp`, `completeRecovery`, `failTyped`, and `failMfa`,
   each calling `recordProofFailure rl ctx factor ts` before publishing `MfaFailed`; after the arm
   succeeds and before `issueSession`, `recordProofSuccess ctx factor gate.standingLockout ts`. In
   `completePasswordlessLogin`,
   `verifyAssertion` runs before the user is known: derive its failure key from the presented
   credential id text (or the literal `"unknown-credential"`), then from `user.loginId` for the gate
   and the success record. `verifyTotpEnrollment` is *not* gated (the enrollee owns the secret).
   `removeTotp` (`Totp/Workflow.hs` 146–165) gets the same gate and `FactorTotp`/`FactorRecoveryCode`
   accounting.

4. `changePassword`: add `LoginAttemptStore :> es` and a `ProofContext`; after the user loads,
   `gate <- guardAbuse …` (locked → `verifyPasswordDummy`, then `InvalidCredentials`, so every path
   still hashes once); on a wrong current password `recordProofFailure rl ctx FactorPasswordChange
   ts`, `publishAuthEvent (Event.PasswordChangeFailed (Event.PasswordChangeFailedData user.userId
   ts))`, throw; on success `recordProofSuccess ctx FactorPasswordChange …`. Add the constructor after
   `PasswordChanged` in `Audit/Event/Domain.hs`, `"password_change_failed"` (subject `userId`) to both
   directions of `Audit/Event/Codec.hs`, and bump `CodecSpec`'s count 40 → 41 with a round trip.

5. Handlers: add `RemoteHost` to `MfaCompleteRoute`, `PasskeyLoginCompleteRoute`,
   `PasswordChangeRoute`, and `TotpDeleteRoute` (client-transparent, as plan 9 established); export
   `clientIpText` from `Shomei.Session.Handler` and build `ProofContext {clientIp = ClientIp
   (clientIpText peer), accountKeyOf = env.accountKeyOf}` in the four handlers.

6. Tests. `Mfa/WorkflowSpec`: "five wrong TOTP codes lock the account and a sixth login is refused";
   "a locked account cannot complete with a correct recovery code"; "five bad passkey assertions
   lock"; "passwordless: an unknown credential id is counted per IP"; "second-factor success clears
   the lockout". `AccountSpec`: "five wrong current passwords lock the account, publish
   password_change_failed, and the correct password at login is then refused". TOTP workflow tests:
   "wrong removal codes count; a locked account cannot remove". The M2-1 scenario now passes. Extend
   `totpScenario` (`shomei-server/test/Shomei/Server/E2ESpec.hs` 603) with the same loop and a
   `SELECT factor, outcome FROM shomei.shomei_login_attempts` showing five `totp | failure` rows.

Acceptance: `cabal test shomei-core shomei-servant shomei-server` green. Commit:

```text
feat(core,servant): count second-factor, passkey, password-change, and TOTP-removal failures

Gate the four proof workflows on the lockout and per-IP throttle, record failures by factor,
clear the lockout only when the second factor passes, and prove it with a TOTP guessing loop.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M3 — the `auth_time` claim and the freshness gates

Scope: every access token carries `auth_time`; refresh preserves it; the three freshness gates read
it; TOTP removal is gated; the docs stop implying a refresh counts as authentication.

1. `Claims/Domain.hs`: add `authTime :: !UTCTime` after `expiresAt` ("when the last credential was
   proven; preserved across refresh; the freshness clock"); append `"auth_time"` to `reservedClaimKeys`.
2. `Session/Domain.hs`: append `authenticatedAt :: !UTCTime` to `Session` and `NewSession` after
   `oauthClientId`. Run `just new-migration sessions-authenticated-at`:

   ```sql
   SET search_path TO shomei, pg_catalog;

   -- When the session's last credential was proven (the auth_time claim, which a refresh must not
   -- renew). NULL for rows that predate the column; read as created_at.
   ALTER TABLE shomei_sessions
     ADD COLUMN IF NOT EXISTS authenticated_at timestamptz NULL;
   ```

   `Session/Postgres.hs`: ninth column in `SessionRow`, `insertSessionStmt` (`contrazip9`),
   `sessionRowDecoder` (`D.nullable D.timestamptz`), `rebuildSession` (`fromMaybe c`), both `SELECT`s;
   `UnitOfWork/Postgres.hs` `sessionRow` adds `Just session.authenticatedAt`; `InMemory.hs`
   `mkSession` copies it. The strict field makes every `NewSession` literal a compile error until it
   sets `authenticatedAt = ts` (`Session/Workflow.hs` 187, `Authentication/Workflow.hs` 160,
   `Delegation/Workflow.hs` 143, `ClientCredentials/Workflow.hs` 99, `shomei-postgres/test/Main.hs` 955).
3. `Session/Workflow.hs` `buildClaims` sets `authTime = ts`. `Authentication/Workflow.hs` 415 becomes
   `claims <- buildEnrichedClaims …; access <- signAccessToken claims {authTime = s.authenticatedAt}`
   (the OAuth `refresh_token` grant delegates to `refresh` and inherits this). `Delegation/Workflow.hs`
   151–160 sets `authTime = ts`; `Authorize/Workflow.hs` 155 becomes `authTime = claims.authTime`.
   Every other `AuthClaims` literal the compiler reports (`shomei-jwt/test/…/TestSupport.hs` 42 and
   the `shomei-core`, `shomei-servant`, `shomei-server` tests) sets `authTime = issuedAt`.
4. `Sign/Jwt.hs` `claimsFromAuth`: after the `permissions` line add `& addClaim "auth_time"
   (Aeson.toJSON (NumericDate ac.authTime))` — after `addExtra`, so a forged `auth_time` in
   `extraClaims` is overwritten. `Verify/Jwt.hs` `claimsToAuth`: add `"auth_time"` to `managed`; parse
   `Map.lookup "auth_time" claims >>= parseMaybe parseJSON :: Maybe NumericDate`, defaulting to
   `issuedAt'`. `shomei-jwt` tests: add `authTime` to the round-trip field list (`TestSupport.hs` 60)
   and "an extraClaims auth_time cannot forge the claim" beside the existing `act` forgery case.
5. Gates: `Mfa/Handler.hs` 84 → `user.authClaims.authTime`; `Delegation/Workflow.hs` 74 →
   `caller.authTime`; `totpDeleteH` adds `requireFreshAuth env authUser` before `loadUser`.
6. Tests: `Delegation/WorkflowSpec` freshness case builds `authTime`; `scenarioTotp` gains "refresh
   → recovery-codes → 403 reauthentication_required" and "DELETE /v1/auth/totp on a stale token →
   403"; an `Authentication/WorkflowSpec` case "refresh preserves auth_time" (advance the World clock,
   refresh, the new token's `authTime` equals the login instant).
7. Docs: `docs/user/problem-details.md` 40 → "Log in again (or complete MFA again); refreshing does
   not count."; `docs/user/api.md` 351, 354, `docs/user/mfa.md` 100–105, `docs/user/security.md` 14–48
   and 302–305 describe `auth_time`.

Commit:

```text
feat(jwt,core): carry auth_time on sessions and tokens and gate freshness on it

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M4 — derive the throttled set from `RateLimited` and widen it

Scope: the marker is real; thirteen routes are throttled; `api.md` is correct.

1. New `shomei-servant/src/Shomei/Servant/Throttle.hs` (register in `shomei-servant.cabal`):

   ```haskell
   data PathSegment = Literal Text | Wildcard  deriving (Eq, Show)
   data ThrottledRoute = ThrottledRoute {method :: !Method, path :: ![PathSegment]} deriving (Eq, Show)

   class HasThrottledRoutes api where
     -- | every route beneath 'api', flagged when a 'RateLimited' marker guards it
     allRoutes :: Proxy api -> [(Bool, ThrottledRoute)]
   throttledRoutesOf :: (HasThrottledRoutes api) => Proxy api -> [ThrottledRoute]
   throttledRoutesOf = map snd . filter fst . allRoutes
   matchesThrottledRoute :: [ThrottledRoute] -> Method -> [Text] -> Bool
   ```

   Instances: `(KnownSymbol s, HasThrottledRoutes sub) => (s :> sub)` prepends `Literal`;
   `RateLimited :> sub` sets the flag; `Capture' mods n a :> sub` prepends `Wildcard`; pass-through
   for `CsrfProtected`, `PreHandlerResponses r`, `Authenticated`, `OAuthAuthenticated`, `RequireAdmin`,
   `RequireRole r`, `RequireScope s`, `RequirePermission p`, `RemoteHost`, `ReqBody' mods cts a`,
   `Header' mods n a`, `QueryParam' mods n a`; the leaves `MultiVerb m cts rs r` and `Verb m s cts a`
   yield `[(False, ThrottledRoute (reflectMethod (Proxy @m)) [])]`; `a :<|> b` concatenates;
   `NamedRoutes r` walks `Rep (r AsApi)` through a `GHasThrottledRoutes` helper over `M1`, `:*:`, and
   `K1`. Export `shomeiThrottledRoutes = throttledRoutesOf shomeiRoutesApi` from `Shomei.Servant.Api`.
2. Mark the routes: `MfaCompleteRoute`, `TotpDeleteRoute` (`Mfa/Api.hs`), `PasskeyLoginBeginRoute`,
   `PasskeyLoginCompleteRoute` (`Passkey/Api.hs`), `PasswordChangeRoute`, `VerifyEmailConfirmRoute`,
   `PasswordResetConfirmRoute` (`Account/Api.hs`), `TokenRoute` (`OAuth/Api.hs`) gain `RateLimited :>`.
3. `RateLimit.hs`: `RateLimiter` gains `throttled :: ![ThrottledRoute]`; add `newRateLimiterFor ::
   [ThrottledRoute] -> RateLimitConfig -> IO RateLimiter`; `newRateLimiter = newRateLimiterFor
   shomeiThrottledRoutes` (signature unchanged); `throttledPath :: RateLimiter -> Request -> Bool` uses
   `matchesThrottledRoute` on `requestMethod`/`pathInfo`; delete the literal list and the `methodPost`
   test; `clientKey` untouched. `Boot.hs` 104 calls `newRateLimiterFor shomeiThrottledRoutes …`.
4. `MiddlewareSpec` `testThrottledPathsAreVersioned` (129–150) becomes the conformance test:
   `shomeiThrottledRoutes` equals, as a set, `POST /v1/auth/{login, signup, refresh, mfa/complete,
   login/passkey/begin, login/passkey/complete, password/change, verify-email/request,
   verify-email/confirm, password-reset/request, password-reset/confirm}`, `DELETE /v1/auth/totp`,
   and `POST /oauth/token`; logout, GETs, and the unversioned path stay unthrottled. Regenerate
   `docs/api/openapi.json` (`cabal run shomei-openapi > docs/api/openapi.json`) and commit it.
5. `docs/user/api.md` 197 → "`/oauth/token` is rate-limited per client IP like every other credential
   proof; the `429` is the problem document from the edge, not an OAuth error." List the rate-limited
   routes under Errors (34) and add `429` to the newly marked endpoints.

Commit:

```text
feat(servant,server): derive the throttled path set from the RateLimited marker

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M5 — passwordless user verification, documentation, retrospective

1. `Passkey/Ceremony/Port.hs`: `BeginAuthenticationCeremony :: UserVerificationPolicy ->
   [WebAuthnCredentialId] -> …` and `beginAuthenticationCeremony uv ids` (policy type from
   `Shomei.Config`). `WebAuthn/Ceremony.hs` 80 and 123–137 take `uv` and set `WA.coaUserVerification
   = mapUV uv`. `Mfa/Workflow.hs` 125 → `beginAuthenticationCeremony (userVerification
   (webauthnConfig cfg)) allowIds`; 258 → `beginAuthenticationCeremony UVRequired []`. `InMemory.hs`
   1229 ignores the argument. Fix `shomei-webauthn/test/…/CeremonySpec.hs` 70 and
   `shomei-core/test/Shomei/WebAuthnCeremonySpec.hs` 94; add a `CeremonySpec` case: the passwordless
   blob decodes to `UserVerificationRequirementRequired` even with `userVerification = UVDiscouraged`.
2. Docs: `docs/user/passkeys.md` 66–69 and the `userVerification` row (84) — "applies to the step-up
   ceremony; passwordless always requires user verification". `docs/user/security.md`: 186–201 — the
   locked path hashes too; 230–245 — what is counted (password, TOTP, recovery code, passkey, password
   change, TOTP removal; suspended accounts), the `factor` column, the deferred clear; 267–287 —
   passwordless UV and second-factor lockout; the runbook (675–700) — a `factor` example.
   `docs/user/mfa.md` 80–82 ("one code guess per password proof") → counted toward the lockout; 84–95
   — removal needs a fresh token and counts. `docs/capabilities/abuse-protection.md` 35, 50–51, 72 —
   the derived route set. Sweep: `rg -n "not rate-limited|one code guess|recently-issued" docs/`.
3. ADR distillation per the Outcomes note; write Outcomes; tick the MasterPlan's three EP-4 boxes.

Commit:

```text
feat(webauthn): require user verification for passwordless login; document EP-4

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`.

```bash
just new-migration login-attempts-factor        # M1
just new-migration sessions-authenticated-at    # M3
cabal build shomei-migrations && just migration-check
cabal build all --enable-tests                  # the strict new fields list every missed literal
cabal test shomei-core                          # M1, M2, M3 core cases
cabal test shomei-postgres                      # store, workflow lockout, round-trip budgets
cabal test shomei-servant                       # negative test, freshness, OpenAPI conformance
cabal test shomei-server                        # MiddlewareSpec conformance, E2E TOTP lockout
cabal test shomei-jwt shomei-webauthn           # auth_time round trip, UV per flow
cabal run shomei-openapi > docs/api/openapi.json   # M4
cabal test all                                  # final sweep
```

Expected pre-fix result of the M2 negative test (record the real transcript in Surprises):

```text
EP-4: a TOTP guessing loop is locked out after maxFailedLoginsPerAccount wrong codes: FAIL
  expected: 401
   but got: 200
```

Live check (optional; needs `oathtool`): `just create-database`, `cabal run exe:shomei-server`, sign up `victim`, enrol and verify TOTP keeping the Base32 secret in `$S`, then:

```bash
for i in 1 2 3 4 5 6; do
  CID=$(curl -s -XPOST localhost:8080/v1/auth/login -H 'Content-Type: application/json' \
        -d '{"loginId":"victim","password":"correct horse battery staple"}' | jq -r .ceremonyId)
  curl -s -o /dev/null -w "guess $i: %{http_code}\n" -XPOST localhost:8080/v1/auth/mfa/complete \
        -H 'Content-Type: application/json' \
        -d "{\"ceremonyId\":\"$CID\",\"proof\":{\"type\":\"totp\",\"code\":\"000000\"}}"
done
# post-fix: guesses 1–5 print 401; iteration 6's login answers 401 invalid_login (its completion is
# then a 400 for the null id); the right code (oathtool --totp -b "$S") at an earlier ceremony is 401.
psql "$PG_CONNECTION_STRING" -c "SELECT factor, outcome, count(*) FROM shomei.shomei_login_attempts GROUP BY 1,2"
# → one row:  totp | failure | 5
```


## Validation and Acceptance

1. **The negative test, both ways.** Before M2 the servant case fails with `200` where `401` is
   expected (the correct code at a pre-lock ceremony succeeds and the account still logs in); after M2
   it passes: five `401 totp_code_invalid`, `401` for the correct code at `cidB`, then
   `401 invalid_login`. Both transcripts are recorded in Surprises.
2. **Every proof is counted.** Core cases lock after `maxFailedLoginsPerAccount` wrong recovery codes,
   passkey assertions, current passwords at change, and codes at TOTP removal; the Postgres E2E shows
   `factor = 'totp'` rows; a second-factor success clears the lockout; a challenged password proof
   clears nothing; a suspended account's attempts lock and audit.
3. **Timing.** `TimingSpec` reports `hashCalls == 1` on the locked path (it reports `0` pre-M1).
4. **`auth_time`.** A login token has `auth_time == iat`; after `POST /v1/auth/refresh` the new
   token's `auth_time` still equals the *login* instant while `iat` is later; past the window,
   recovery-code regeneration, `DELETE /v1/auth/totp`, and impersonation answer `403` even on a
   freshly refreshed token; an `extraClaims` `auth_time` is overwritten.
5. **Throttling.** `MiddlewareSpec` pins the derived set to exactly the thirteen `(method, path)` pairs
   in M4; the live server answers `429 too_many_requests` with `Retry-After: 60` on the sixty-first
   `POST /v1/auth/mfa/complete` from one IP within a minute; `docs/api/openapi.json` shows a 429 on
   each marked operation; `rg -n "not rate-limited" docs/user` finds nothing.
6. **User verification.** The passwordless begin blob decodes to `Required` under every setting; the
   step-up blob still follows `userVerification`.
7. `cabal test all` green; `testLoginRoundTripBudget` (10) and `testRefreshRoundTripBudget` (5) unchanged.


## Idempotence and Recovery

Every source edit is compiler-checked and safe to re-run. Both migrations use `ADD COLUMN IF NOT
EXISTS` with a default or `NULL`, so re-applying is a no-op and nothing is rewritten;
`authenticated_at` is read through `COALESCE`, so rolling the binary back leaves a schema the old
code ignores. Never hand-number a migration: `just new-migration` reads the manifest's tail, so
whichever of plans 51, 52, and this one lands first gets the next number. Reverting M2 restores
audit-only failures; the `factor` column is harmless. `auth_time` is compatible in both directions (a
missing claim reads as `iat`; an old verifier ignores the extra claim). `rateLimitEnabled = false`
still switches the throttle off. Re-running the negative test against a locked account needs
`lockoutDuration` (15 min) to elapse or a `DELETE FROM shomei.shomei_account_lockouts WHERE account_key = …`.


## Interfaces and Dependencies

No new library dependencies. Definitions that must exist at the end (full module paths):

- `Shomei.Session.LoginAttempt.Domain.AttemptFactor` (five constructors) on `LoginAttempt` and
  `NewLoginAttempt`; migration `0029-login-attempts-factor.sql`;
  `Shomei.Persistence.Codec.Postgres.attemptFactorToText`;
  `Shomei.Session.LoginAttempt.Workflow.{AbuseGate(..), guardAbuse, recordProofFailure, recordProofSuccess}`
  with the M1 signatures — the single seam plan 55 rewrites.
- `Shomei.Session.Command.ProofContext {clientIp :: ClientIp, accountKeyOf :: Text -> AccountKey}` and
  `proofContextFor :: ProofContext -> Text -> ClientContext`; `Shomei.Session.Handler.clientIpText` exported.
- `Shomei.Mfa.Workflow.completeMfa :: … -> ShomeiConfig -> ProofContext -> CeremonyId -> MfaCompletion -> …`
  and `completePasswordlessLogin :: … -> ShomeiConfig -> ProofContext -> CeremonyId -> Value -> …`
  (both with `LoginAttemptStore :> es`); `Shomei.Mfa.Totp.Workflow.removeTotp` and
  `Shomei.Account.Lifecycle.Workflow.changePassword` likewise take a `ProofContext`.
- `Shomei.Audit.Event.Domain.PasswordChangeFailed PasswordChangeFailedData {userId, occurredAt}`
  (`password_change_failed`).
- `Shomei.Authorization.Claims.Domain.AuthClaims.authTime :: UTCTime`; `"auth_time"` in
  `reservedClaimKeys`; `Shomei.Session.Domain.{Session,NewSession}.authenticatedAt :: UTCTime`;
  migration `sessions-authenticated-at`; signer writes `auth_time` after `extraClaims`; verifier
  parses it (default `iat`) as a managed claim.
- `Shomei.Servant.Throttle.{HasThrottledRoutes(..), ThrottledRoute(..), PathSegment(..), throttledRoutesOf, matchesThrottledRoute}`;
  `Shomei.Servant.Api.shomeiThrottledRoutes`; `RateLimited :>` on the thirteen routes;
  `Shomei.Server.Middleware.RateLimit.newRateLimiterFor :: [ThrottledRoute] -> RateLimitConfig -> IO RateLimiter`
  (`newRateLimiter`, `rateLimitMiddleware`, `clientKey` unchanged).
- `Shomei.Passkey.Ceremony.Port.BeginAuthenticationCeremony :: UserVerificationPolicy -> [WebAuthnCredentialId] -> …`,
  honoured by `Shomei.WebAuthn.Ceremony.beginAuthentication`; `RemoteHost` on `MfaCompleteRoute`,
  `PasskeyLoginCompleteRoute`, `PasswordChangeRoute`, `TotpDeleteRoute` (servant-client unaffected).

Relations to other plans: plan 55 owns the atomic statement shape — it replaces the body of
`recordProofFailure` (the only caller of `recordLoginAttempt`/`countRecentFailuresByAccount`) and
keeps its signature and the `factor` column; plan 53 owns `reservedClaimKeys` and keeps `"auth_time"`
in it and in the write-last set; plan 58 owns `clientKey` and `clientIpText` and changes nothing else
in the limiter; plans 51/52 own the session shape and keep `authenticatedAt` after their fields; plan
59 may call `throttledRoutesOf` on a host's API; plan 60 verifies the M5 documentation sweep.
