---
type: Review
title: shomei-core workflows under a security and performance lens
description: >-
  The session, rotation, one-time-token, and claims invariants hold in the workflows, but
  /oauth/authorize accepts delegated and machine tokens and exchanges them into full
  sessions, second-factor failures are counted nowhere, token exchange ignores session
  liveness, and lockout is a non-atomic read-then-act — so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-2
subject: mori://shinzui/shomei/packages/shomei-core
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - correctness
  - performance
  - test-coverage
  - documentation
context: >-
  Two reader agents split the package: one read Session/**, Account/**, Config, Error, Id,
  Audit/**, Time, and Test/InMemory with the timing, lockout, and concurrency specs; the
  other read OAuth/**, Mfa/**, Passkey/**, ServiceAccount/**, Delegation, Authorization/**,
  and the SigningKey ports with their specs. Both followed calls into shomei-postgres and
  shomei-servant far enough to confirm which guards are wired in production, and read
  crypton, ram, mmzk-typeid, tweag/webauthn, and jose source through mori where a
  library's behavior decided a finding. The review of record re-read the authorize, exchange,
  session-issue, login, and MFA-completion code before grading the top findings. The
  shomei-core test suite (377 cases across seven groups) passed at the commit.
---

# shomei-core workflows under a security and performance lens

## Verdict

Changes requested. The workflows that the July hardening touched are right: login pays exactly
one Argon2 verification on every failing path that reaches a stored hash, refresh is a
compare-and-swap whose loser is treated as theft, the absolute session deadline caps every
rotated token, one-time tokens are consumed by CAS after validation and before the write, and
`ensureEmailVerified` is the single gate on login, refresh, and MFA completion. The claims
model is sound: `mkExtraClaims` drops all ten reserved names, the enricher returns a delta with
no actor field, and `act`, `roles`, `permissions`, and `scopes` are written last by the signer.

The problems are in the newer OAuth, delegation, and MFA workflows and in how they compose with
the session core.

## Findings

**1. Critical — `authorize` never inspects `claims.actor`, so any verifying token becomes a
full session.** `Shomei.OAuth.Authorize.Workflow.authorize` stores `userId = claims.subject`
(`src/Shomei/OAuth/Authorize/Workflow.hs:150-151`; the module never mentions `actor`), and
`exchangeAuthorizationCode` calls `issueSessionWith` with `actor = Nothing`, a refresh token,
and `buildEnrichedClaims` (`src/Shomei/OAuth/TokenGrant/Workflow.hs:165-175`,
`src/Shomei/Session/Workflow.hs:182-207`). An impersonation token (30 minutes, refresh-less,
`roles = ∅`, `act = operator`), an on-behalf-of token, or a `client_credentials` token thus
launders into a 30-day refreshable session carrying the subject's stored roles and permissions
and no `act`. The HTTP side compounds it (REV-7), but the core is where the guard belongs: refuse
`actor /= Nothing`, and record on `Session` whether it was interactively established so a
machine session cannot authorize either. No core test presents a delegated or machine token to
`authorize`.

**2. High — second-factor failures are counted nowhere.** Login records `LoginSuccess` and clears
the lockout before the MFA branch (`src/Shomei/Session/Authentication/Workflow.hs:253-264,
274-280`); `completeMfa`'s TOTP and recovery arms publish `MfaFailed` and throw, with no
`LoginAttemptStore` constraint on the function (`src/Shomei/Mfa/Workflow.hs:207-214, 235-244`).
With three accepted codes per step (`src/Shomei/Mfa/Totp/Algorithm.hs:90`), a password-holder
expects success in about 3·10⁵ guesses, bounded only by whatever the HTTP layer throttles (and
REV-8 shows the completion routes are not throttled). `removeTotp` verifies a code on an
authenticated route with the same absence of accounting
(`src/Shomei/Mfa/Totp/Workflow.hs:146-165`). Remedy: record second-factor failures against the
account key with the existing lockout machinery, and defer the lockout clear until the second
factor passes.

**3. Medium (high under `VerifyTokenAndSession`) — token exchange and delegation verify
statelessly.** `TokenExchange.verifyToken` is `verifyAccessToken` alone
(`src/Shomei/OAuth/TokenExchange/Workflow.hs:272-277`); `SessionStore` is in the constraint at
`:120` but never consulted for liveness; `Delegation.Workflow` checks the target user only
(`src/Shomei/Delegation/Workflow.hs:67-79`). A revoked session or a suspended operator keeps
minting delegated sessions for one access-token TTL, and a deployment that paid for
`VerifyTokenAndSession` does not get it here. Contrast `verifyToken` at
`src/Shomei/Session/Authentication/Workflow.hs:451-470`, which is config-aware.

**4. Medium — OAuth-client scopes are minted into the user's own token and the privilege gates
are ordinary scopes.** `issueSessionWith` unions `opts.extraScopes` into the claims
(`src/Shomei/Session/Workflow.hs:204-206`); `impersonate:user` (`src/Shomei/Delegation/Workflow.hs:72`)
and `token-exchange:subject` are read from those scopes; nothing refuses them in a client or
service-account allow-list. A client registered with a privilege scope hands it to every user
who authorizes through it.

**5. Medium — the per-account lockout is a non-atomic read-then-act.** The gate reads
`getAccountLockout` before hashing (`Authentication/Workflow.hs:227-239`) and records the failure
after (`:317-334`), with no port operation that increments-and-tests. Sixty parallel
wrong-password requests (the default per-IP burst) all pass the gate and are all verified; the
documented budget of five becomes at least sixty per IP per window. Neither `ConcurrencySpec` nor
`LockoutSpec` races failed logins. Remedy: a CAS-shaped increment, or record before hashing.

**6. Medium — the reset and verification request workflows do unequal work on hit and miss.**
`requestPasswordReset` inserts a token, calls `sendNotification` inline, and publishes an event
only when the user exists (`src/Shomei/Account/Lifecycle/Workflow.hs:149-167`; same shape at
`:90-108`). The byte-identical `202` is documented as making the side effect invisible; the
latency is not. The synchronous notifier lives in shomei-server (REV-8); the core workflow is
where a fixed-cost miss path or a deferred delivery would go.

**7. Medium — `changePassword`'s current-password check has no throttle, lockout, or audit on
failure** (`src/Shomei/Account/Lifecycle/Workflow.hs:222-239`, `:232-233` throws without any
store or publisher call). A stolen access token is an unbounded password oracle whose success
mints a fresh MFA-less credential and revokes the owner's sessions.

**8. Medium — a duplicate email at signup is a `503`, not the documented `409`.** `signup` checks
only login-id uniqueness (`Authentication/Workflow.hs:145-150`); `EmailAlreadyRegistered` is
constructed nowhere; the partial unique index fires and every hasql error collapses to
`DependencyUnavailable PostgreSQL`. Clients retry a permanent conflict.

**9. Medium — scopes granted by the authorization-code flow are not persisted with the
session**, so every refresh silently drops them, including `openid`
(`src/Shomei/Session/Workflow.hs:112-123, 204-206`; `NewSession` has no scopes field,
`src/Shomei/Session/Domain.hs:36-46`). Fail-safe in direction, broken in function, untested.

**10. Medium — refresh tokens minted for OAuth clients are client-bound only at `/oauth/token`.**
`Session/Domain.hs:27-30` admits that the bespoke refresh "ignores it"; `oidc.md` says another
client cannot rotate it. Remedy: `refresh` refuses sessions with `oauthClientId = Just _`.

**11. Medium — TOTP replay protection is read-then-write.** `completeTotp` compares against the
previously read `lastUsedCounter` and `SetTotpLastUsedCounter` is unconditional
(`src/Shomei/Mfa/Workflow.hs:207-213`; the Postgres statement is in REV-5). Two concurrent
completions of one observed code both succeed, against `mfa.md`'s "never accepted twice". The
passkey sign counter has the same shape (`:304, 326-346`).

**12. Low — the locked-account branch performs zero password verifications**
(`Authentication/Workflow.hs:236-237` precedes `:244`). It leaks lock state, not existence
(lockouts are keyed on the hashed identifier whether or not it exists), but `security.md`
promises exactly one verification and `TimingSpec` has no locked case.

**13. Low — outstanding reset and verification tokens are never revoked.**
`revokeUserPasswordResetTokens` and `revokeUserVerificationTokens` exist on the ports with no
callers; `confirmPasswordReset` and `changePassword` consume only the presented token. A second
reset link stays redeemable for its hour.

**14. Low — login attempts against suspended or deleted accounts are invisible to the lockout,
the IP throttle, and the audit trail** (`Authentication/Workflow.hs:248-250`).

**15. Low — `LoginFailedData` stores the submitted identifier verbatim with `user_id = NULL`**
(`src/Shomei/Audit/Event/Domain.hs:82-87`, `Codec.hs:95-96`); a password typed into the login
field lands in an append-only table retained forever by default.

**16. Low — the freshness gates measure from the access token's `iat`**, which a refresh renews
without re-authentication (`src/Shomei/Delegation/Workflow.hs:74`); the actor's own status is
never checked. There is no `auth_time` claim to gate on.

**17. Low — replay of a consumed authorization code is not detected as such** and does not
revoke the first exchange's session (RFC 6749 §4.1.2); the consumed row carries no session id
(`src/Shomei/OAuth/AuthorizationCode/Store.hs:28-37`).

**18. Low — `emailVerificationRequired` is not applied to the authorization-code exchange**
(`TokenGrant/Workflow.hs:165-175` has no `ensureEmailVerified`), so an unverified account renews
indefinitely through authorize → exchange without ever refreshing.

**19. Low — TOTP secret ciphertexts have empty AEAD data**, unlike signing keys, so a database
writer can transplant a secret between rows (REV-5 has the statement).

**20. Low — audit fidelity.** A token revoked by logout that is re-presented is reported as
reuse and triggers the theft response (`Authentication/Workflow.hs:359-360, 421-426`); the admin
lifecycle transition is read-then-write, so two concurrent suspends both audit
(`src/Shomei/Account/Admin/Workflow.hs:99-109`); machine and delegated mints insert a session row
per token that is never reused.

**21. Low — the in-memory fake mutates the `World` non-atomically in three handlers**
(`src/Shomei/Test/InMemory.hs:1190-1200, 1240-1246, 796-806`), against MasterPlan 5's claim of
atomic helpers only; `ConcurrencySpec`'s one-winner property passes by scheduling luck.

**22. Low — configuration.** SMTP password and webhook secret live in the `Show`/`ToJSON`
`ShomeiConfig` (`src/Shomei/Config.hs:170-199, 418-449`), the same record `security.md` gives
as the reason the KEK is kept out; an unparseable signing-algorithm string silently becomes
ES256 (`:481-486`); `reservedClaimKeys` omits `nbf` and `jti`, which jose then drops on the wire.

**23. Info — interop and shape.** The JWT `act` is a bare user-id string while introspection
renders the RFC 8693 object; `code_verifier` is not validated to RFC 7636 §4.1; raw refresh
tokens derive `Show`/`ToJSON` (unlike `PlainPassword`); the `cloneWarning` branch in
`completePasskeyLogin` is dead because the interpreter maps clones to `Left`; passkeys per user
are uncapped; `UserNotActive` is a distinct constructor that only the HTTP layer collapses, so a
library caller of `login` can distinguish suspended from wrong-password.

## Verified holds

- Rotation CAS and lost race → `reuseDetected` → family and session revoked
  (`Authentication/Workflow.hs:397-426`); `ConcurrencySpec` pins one winner over 100 racers × 10
  rounds.
- Absolute expiry before status and token checks (`:370-372`); rotated token capped at
  `session.expiresAt` (`:407`); `verifyToken` under `VerifyTokenAndSession` checks both (`:466-469`).
- Exactly one verification on the unknown-id, missing-user, wrong-password, suspended, and
  success paths via `failLoginTimed` → `verifyPasswordDummy` (`:245-252, 299-301`); `TimingSpec`
  counts invocations for four of the five paths.
- Lockout: failure recorded before the decision, windowed, counted since last success; per-IP
  count not reset by success; account key is SHA-256 of the normalized login id.
- Suspend and delete revoke all sessions at once; suspended users cannot log in, refresh, or
  complete MFA; deletion is soft; self-target refusal is in the HTTP layer as the workflow
  header requires.
- One-time tokens: CAS consume after policy validation, TTL, reset revokes all sessions and
  refresh tokens, new password passes policy and breach check with the user's context;
  `ConcurrencySpec` pins one winner.
- Signup and every user-session mint go through `persistNewSession` (one transaction; signing
  outside it).
- Authorization code: single-use CAS, 60 s TTL, SHA-256 stored, bound to client id, redirect URI,
  and S256 challenge with `constEq`; PKCE mandatory for public clients, `plain` refused.
- Client authentication: confidential requires a secret, public must present none, constant-time,
  single `invalid_client`; redirect URI exact match tested against prefix, suffix, and traversal.
- ID token carries iss/sub/aud/iat/exp/auth_time/nonce; unusable as an access token (audience and
  required `sid`).
- Token exchange: chained exchanges refused for actor and subject; gate scopes stripped from every
  grant; granted ⊆ ceiling ⊆ subject scopes when non-empty; delegated tokens carry `roles = ∅`,
  `permissions = ∅`, `act = actor`, no refresh token, separately revocable; `act` cannot be injected
  through `extraClaims` or the enricher (tested).
- Client credentials: constant-time secret before status, scope ⊆ allow-list, `sub` = backing
  user, no refresh token, no roles or permissions on machine tokens.
- TOTP: RFC 6238 vectors pinned, window [c−1, c+1], strictly-greater counter, constant-time
  digit compare, enrollment needs a first valid code; recovery codes 10 × 50 bits, SHA-256,
  CAS consume, regeneration replaces the set.
- MFA pending state is a database row keyed by a UUIDv7 ceremony id, consumed once by
  `DELETE … RETURNING`, bound to kind and user, checked for status and email verification; a
  failed proof spends the ceremony.
- Passkeys: step-up `allowCredentials` restricted to the user's ids after password proof;
  ownership re-checked after verification; counter clones fail closed; registration bound to the
  authenticated user.
- Roles: registry enforced at grant plus FK; expiry filtered at mint; permissions are the union
  over effective roles; `mkExtraClaims` drops all reserved names.

## Not examined

Test bodies were read by inventory and targeted scenario, not line by line; `Test/InMemory.hs`
lines 806–1100 (passkey, service-account, OAuth, and TOTP fakes) were skimmed. The `network`
package's `HostAddress` `Show` was not read (the decimal-IP rendering is graded plausible in
REV-7). No test suite was extended or run beyond the full `cabal test all` pass recorded in REV-1.
