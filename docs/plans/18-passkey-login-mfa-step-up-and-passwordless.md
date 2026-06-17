---
id: 18
slug: passkey-login-mfa-step-up-and-passwordless
title: "Passkey login: MFA step-up and passwordless"
kind: exec-plan
created_at: 2026-06-17T14:38:15Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
master_plan: "docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md"
---

# Passkey login: MFA step-up and passwordless

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. Today, when a user logs in with email and
password (`POST /auth/login`), the server immediately returns an access/refresh token pair —
the password is the *only* factor. After this change, an account that has at least one
**passkey** enrolled (a WebAuthn public-key credential, the cryptographic credential a
YubiKey, Touch ID, Windows Hello, or iCloud Keychain creates) no longer gets tokens from the
password alone. Instead, a correct password yields an **MFA challenge**: the server returns a
short-lived ceremony id plus the WebAuthn authentication options the browser feeds to
`navigator.credentials.get()`. The browser signs the challenge with the passkey's private
key and posts the signed assertion to `POST /auth/mfa/complete`; only then does the server
mint the token pair. This is the headline multi-factor (MFA) step-up behavior: **possession
of the password alone no longer grants a session** for an account that has a passkey.

This plan also adds a **passwordless** path: `POST /auth/login/passkey/begin` starts a
WebAuthn authentication ceremony with no account named (the browser's *discoverable
credential* picker chooses one), and `POST /auth/login/passkey/complete` verifies the
assertion, resolves which Shōmei user the credential belongs to, and mints tokens — no email
or password typed at all.

The user-visible outcomes, all observable over HTTP after this change:

- A user with **no** passkey (or with `mfaRequired = False`) logs in exactly as before:
  `POST /auth/login` returns the user and a token pair. Nothing about that flow changes.
- A user **with** a passkey and `mfaRequired = True` who posts the correct password to
  `POST /auth/login` receives a body `{"status":"mfa_required","ceremonyId":"…","options":{…}}`
  and **no token**. The access token they need does not exist yet.
- That user then posts `{"ceremonyId":"…","assertion":{…}}` to `POST /auth/mfa/complete` with
  a valid WebAuthn assertion and receives the token pair; the access token works on
  `GET /auth/me`.
- A user can instead start at `POST /auth/login/passkey/begin`, get options, sign with their
  passkey, post to `POST /auth/login/passkey/complete`, and get tokens with no password.

How you see it working end to end (Milestone 2): an in-process HTTP test signs a user up,
enrolls a passkey for them through the EP-3 endpoints, logs in with the password and asserts
the response says `mfa_required` and carries **no** token, posts the assertion to
`/auth/mfa/complete`, gets a token pair, and proves that token authenticates `GET /auth/me`.

This plan is **EP-4** of MasterPlan 3
(`docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md`). It **hard-depends** on:

- **EP-1** (`docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md`):
  the `WebAuthnCeremony` port (it produces authentication options and verifies the browser's
  signed assertion), the passkey domain types, the `WebAuthnConfig` config sub-record (with
  `mfaRequired` and `pendingCeremonyTTL`), and a deterministic **fake** ceremony interpreter
  for tests.
- **EP-2** (`docs/plans/16-passkey-and-pending-ceremony-persistence.md`): the `PasskeyStore`
  (persisted passkeys) and `PendingCeremonyStore` (consume-once challenge state) ports and
  their in-memory and PostgreSQL interpreters.

It **soft-depends** on **EP-3**
(`docs/plans/17-passkey-enrollment-workflow-and-management-api.md`): EP-3's enrollment
endpoints are the convenient way to put a passkey on an account for the end-to-end HTTP test,
but this plan's *unit* tests seed passkeys directly through EP-2's `PasskeyStore` and EP-3's
deterministic fake, so EP-3 does not block it.

Because EP-1/EP-2/EP-3 may still be skeletons when you read this, the exact shared types this
plan consumes are reproduced verbatim under **Interfaces and Dependencies → Consumed contract**
below, so this plan stands alone. If those plans land with a different shape, update that
section and the Decision Log rather than guessing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — widen `login`, add `completeMfa`, the shared `issueSession` helper, new
error/event vocabulary (pure, in-memory tests):

- [ ] Confirm EP-1/EP-2/EP-3 are merged and the Consumed-contract section matches their real
      types; reconcile any drift in the Decision Log.
- [ ] Add `MfaChallengedData`, `MfaSucceededData`, `MfaFailedData` records and the
      `MfaChallenged`/`MfaSucceeded`/`MfaFailed` arms to `Shomei.Domain.Event`
      (`shomei-core/src/Shomei/Domain/Event.hs`); export the records.
- [ ] Confirm `Shomei.Error.AuthError` already carries `WebAuthnCeremonyError WebAuthnError`,
      `PasskeyNotFound`, `PendingCeremonyNotFound` (added by EP-3). If EP-3 has not landed,
      add them here and record it; add `MfaAssertionInvalid` (this plan's own arm).
- [ ] Factor the session-minting tail of `login` into `issueSession cfg user ts` in
      `Shomei.Workflow`; rewrite `login`'s success tail to call it.
- [ ] Add `LoginResult`/`MfaChallenge` and widen `login` to
      `Eff es (Either AuthError LoginResult)`, branching on `mfaRequired && passkeyCount > 0`.
- [ ] Create `Shomei.Workflow.Mfa` with `completeMfa`, `beginPasswordlessLogin`,
      `completePasswordlessLogin`, and `resolveUserFromAssertion`; add to
      `shomei-core/shomei-core.cabal` `exposed-modules`.
- [ ] Add `shomei-core/test/Shomei/Workflow/MfaSpec.hs` proving the four M1 behaviors; register
      it in `shomei-core.cabal` `other-modules` and `shomei-core/test/Main.hs`.
- [ ] Update the existing `Shomei.WorkflowSpec` callers of `login` (they pattern-match the old
      `(User, TokenPair)`); they must now match `LoginComplete`.
- [ ] `nix develop --command cabal build all` and `… cabal test all` green.

Milestone 2 — HTTP routes + DTOs + handlers + LoginResponse widening + event publisher wiring,
in-process HTTP test:

- [ ] Widen `LoginResponse` in `Shomei.Servant.DTO` to a tagged sum; add `MfaCompleteRequest`,
      `PasskeyLoginBeginResponse`, `PasskeyLoginCompleteRequest`; export them and the mapper
      `loginResultToResponse`.
- [ ] Add the `mfaComplete`, `passkeyLoginBegin`, `passkeyLoginComplete` routes to
      `Shomei.Servant.API.ShomeiAPI` (do NOT add `/auth/mfa/begin` — see Decision Log).
- [ ] Update `loginH` to map `LoginResult` → the new `LoginResponse`; add `mfaCompleteH`,
      `passkeyLoginBeginH`, `passkeyLoginCompleteH`; wire them into `shomeiServer`.
- [ ] Add `MfaAssertionInvalid` to `Shomei.Servant.Error.authErrorToServerError` (401) — the
      other three error arms (404/404/400) come from EP-3.
- [ ] Wire `MfaChallenged`/`MfaSucceeded`/`MfaFailed` into
      `Shomei.Postgres.AuthEventPublisher.projectAuthEvent`.
- [ ] Extend `shomei-servant/test/Main.hs`: add the EP-1/EP-2/EP-3 interpreters to `runHybrid`,
      enroll a passkey, log in → `mfa_required`, `/auth/mfa/complete` → tokens, token works on
      `/auth/me`, and the login body carried no token.
- [ ] `nix develop --command cabal build all` and `… cabal test all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

These were surfaced while authoring this plan (2026-06-17) by reading the real Shōmei source
(`shomei-core/src/Shomei/Workflow.hs`, the servant API/DTO/handlers, the postgres event
publisher, the servant in-process test). Confirm or correct each as you implement.

- **`login` today returns `(User, TokenPair)` and `loginH` destructures it positionally.**
  `shomei-core/src/Shomei/Workflow.hs` `login` ends with
  `pure (user, TokenPair{…})`; `shomei-servant/src/Shomei/Servant/Handlers.hs` `loginH` does
  `(user, pair) <- runAuth env (Wf.login env.config ctx cmd)`. Widening the result to
  `LoginResult` breaks both. This plan rewrites both in lock-step (the breaking-type /
  additive-behavior change MasterPlan IP-8 anticipates).

- **`login`'s success tail and `signup`'s success tail are byte-for-byte the same five
  steps** (createSession, generateOpaqueToken, hashRefreshToken, createRefreshToken,
  signAccessToken, then build a `TokenPair`). `completeMfa` and `completePasswordlessLogin`
  need that exact tail too. To avoid four copies, this plan factors it into one helper
  `issueSession cfg user ts` in `Shomei.Workflow` and reuses it from `login` and the new MFA
  workflows. (`signup` is left as-is to keep this plan's diff minimal; it could adopt
  `issueSession` later — noted, not done here.)

- **The WebAuthn user handle is derived from the `UserId` (EP-3 decision), so passwordless
  resolution is reversible.** EP-3 sets each user's handle to the 16 bytes of their UserId
  UUID. But this plan does **not** reverse the handle bytes to find the user; it resolves the
  user from the `credentialId` the assertion carries via EP-2's
  `FindPasskeyByCredentialId :: WebAuthnCredentialId -> Eff es (Maybe PasskeyCredential)`,
  whose result already carries `userId`. See the Decision Log for why credential-id lookup is
  preferred over handle-byte reversal.

- **The `WebAuthnCeremony.CompleteAuthenticationCeremony` op needs the stored credential.**
  Its signature is
  `CompleteAuthenticationCeremony :: ByteString -> StoredCredentialForVerify -> Value -> …`.
  So both `completeMfa` and `completePasswordlessLogin` must first look the credential up (to
  build `StoredCredentialForVerify`), which is exactly the lookup that also resolves the user
  in the passwordless case. The credential id the assertion carries is the key.

(No implementation surprises yet — record compiler/test output here as you implement.)


## Decision Log

Record every decision made while working on the plan.

- Decision: **`login`'s success type becomes the sum
  `data LoginResult = LoginComplete User TokenPair | MfaRequired MfaChallenge`**, where
  `data MfaChallenge = MfaChallenge { ceremonyId :: CeremonyId, options :: Value }`. `login`
  returns `Eff es (Either AuthError LoginResult)`.
  Rationale: This is MasterPlan IP-8's prescribed shape. A sum (not, say, a record with
  nullable token fields) makes the two outcomes mutually exclusive at the type level — a
  caller *cannot* read a token out of an MFA challenge, which is the security property we
  want (no token leaks before the second factor). `MfaChallenge` carries the `CeremonyId` (the
  pending-MFA handle the client echoes to `/auth/mfa/complete`) and the WebAuthn `get()`
  options `Value` verbatim. `LoginComplete` keeps the existing `(User, TokenPair)` payload so
  the no-passkey path is unchanged in behavior.
  Date: 2026-06-17

- Decision: **Record login success (`recordLoginAttempt LoginSuccess`) and clear the account
  lockout at PASSWORD success, BEFORE the MFA branch — not after MFA completion.**
  Rationale: The password factor genuinely succeeded; the abuse-protection layer
  (`LoginAttemptStore`) exists to stop password-guessing, and a correct password is the
  signal it cares about. If we deferred the success record until MFA completed, an attacker
  who guessed the password but cannot pass MFA would keep accumulating "failures" that could
  lock out the *legitimate* user (a denial-of-service via the lockout). Treating a
  failed/abandoned second factor as a *separate* concern — surfaced as the `MfaFailed` audit
  event, not a `LoginAttemptStore` failure — keeps the password throttle's accounting honest.
  The pending ceremony is itself short-lived and consume-once, which bounds MFA-side abuse. So
  the order in `login` is: verify password → `recordLoginAttempt LoginSuccess` +
  `clearAccountLockout` → THEN branch (MFA challenge vs. mint tokens).
  Date: 2026-06-17

- Decision: **A successful password whose account needs MFA publishes `LoginSucceeded` only
  after the SECOND factor completes (in `completeMfa`), not at password success.** At password
  success in the MFA branch we publish `MfaChallenged`; `completeMfa` publishes
  `MfaSucceeded` and then `LoginSucceeded` + `SessionStarted` (because the session is created
  there). The non-MFA path keeps publishing `LoginSucceeded` + `SessionStarted` inline as
  today.
  Rationale: `LoginSucceeded`/`SessionStarted` describe a *session being issued*; in the MFA
  flow no session exists until `completeMfa`. Publishing them at password success would record
  a session that does not yet exist. `MfaChallenged` is the correct audit signal for "password
  ok, second factor demanded."
  Date: 2026-06-17

- Decision: **Resolve the passwordless user from the assertion's `credentialId` via
  `FindPasskeyByCredentialId`, not by reversing the user-handle bytes.**
  Rationale: EP-2's `FindPasskeyByCredentialId` returns a `PasskeyCredential` whose `userId`
  field is exactly the account we need, and the credential id is what the assertion always
  carries and what `CompleteAuthenticationCeremony` must verify against anyway — so the same
  single lookup both resolves the user AND yields the `StoredCredentialForVerify`. Reversing
  the 16 handle bytes back into a `UserId` UUID would work (EP-3 derives the handle from the
  UserId) but is a second, redundant code path that couples this plan to EP-3's exact byte
  derivation; if EP-3 ever changed the derivation, passwordless login would silently break.
  Credential-id lookup is derivation-agnostic. (`FindPasskeysByUserHandle` remains available
  as a fallback/cross-check but is not on the happy path.)
  Date: 2026-06-17

- Decision: **`LoginResponse` becomes a `status`-tagged sum encoded as a flat JSON object,
  represented in Haskell as `data LoginResponse = LoginCompleteResponse {…} | LoginMfaRequiredResponse {…}`
  with HAND-WRITTEN `ToJSON`/`FromJSON` that switch on a `"status"` field.**
  The two wire shapes are:
  ```json
  { "status": "complete",     "user": { … }, "token": { … } }
  { "status": "mfa_required", "ceremonyId": "…", "options": { …get options… } }
  ```
  Rationale: A flat tagged object is the simplest thing a browser/SDK can branch on
  (`if (resp.status === "mfa_required") …`). We write the instances by hand (rather than
  aeson's generic sum encodings, which produce nested `{"tag":…,"contents":…}` or
  single-field objects) so the wire shape is exactly the documented flat object and stable
  across refactors. The alternative — one record with a `status` field plus four `Maybe`
  fields — was rejected because it lets impossible combinations exist (a `complete` with a
  `ceremonyId`, an `mfa_required` with a `token`), which is exactly the leak the type system
  should prevent. The two passkey-login endpoints return existing/simple DTOs
  (`PasskeyLoginBeginResponse`, and `/passkey/complete` reuses the **completed** branch as a
  plain `TokenPairResponse`-style payload — it never returns an MFA challenge, since
  passwordless IS the strong factor).
  Date: 2026-06-17

- Decision: **Do NOT add `POST /auth/mfa/begin`.** The MFA challenge is delivered *by the
  login response itself* (`status: mfa_required`), so the client already holds the ceremony id
  and options after `POST /auth/login`. The only step-up endpoint needed is
  `POST /auth/mfa/complete`.
  Rationale: MasterPlan IP-4 lists `/auth/mfa/begin` as optional; the recommended design folds
  the challenge into the login response, eliminating a round-trip. A separate `/auth/mfa/begin`
  would only be useful to *re-issue* a challenge after one expired, but the client can simply
  POST `/auth/login` again (the password is still valid) to get a fresh challenge — no extra
  endpoint, no extra state. If a future need for challenge re-issuance without re-sending the
  password arises, add `/auth/mfa/begin` then, with a Decision Log entry.
  Date: 2026-06-17

- Decision: **Add a new `MfaAssertionInvalid` arm to `AuthError`, mapped to HTTP 401**, and
  reuse EP-3's `PendingCeremonyNotFound` (404) for a missing/expired/consumed ceremony and
  EP-3's `WebAuthnCeremonyError` (400) for a malformed assertion that fails decoding.
  Rationale: A *valid-shaped* assertion that fails verification at the MFA/login step (wrong
  signature, clone-counter, user not present) is an authentication failure → 401, distinct
  from an enrollment-body problem (400) and from a not-found ceremony (404). We use a dedicated
  `MfaAssertionInvalid` rather than overloading `InvalidCredentials` so the audit/log layer can
  tell "password was wrong" from "second factor was wrong," while the *HTTP body* stays generic
  (`{"error":"mfa_failed", …}`) so nothing leaks. `MfaFailed` (the event) is published on this
  path.
  Date: 2026-06-17

- Decision: ...
  Rationale: (reserve for decisions made during implementation.)
  Date: ...


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section orients a reader who has never seen this repository. Everything you need is in
the working tree plus this file, plus the three sibling plans referenced by path.

Shōmei is a multi-package Haskell authentication toolkit built with **GHC 9.12.4** inside a
Nix dev shell; every build/test command runs from the repository root
`/Users/shinzui/Keikaku/bokuno/shomei` prefixed with `nix develop --command`. It is
**hexagonal** (ports-and-adapters):

- `shomei-core` (`shomei-core/src/Shomei/…`) holds domain types (`Shomei.Domain.*`), the
  effect **ports** (`Shomei.Effect.*`, built with the `effectful` library — a "port" is a
  typed capability such as "can read/write sessions"), and the **workflows**
  (`Shomei.Workflow`, `Shomei.Workflow.Account`, and EP-3's `Shomei.Workflow.Passkey`). It has
  **no** database, JWT, HTTP, or WebAuthn-library dependency.
- `shomei-postgres`, `shomei-jwt`, and the EP-1 `shomei-webauthn` package *interpret* those
  ports against real infrastructure. `shomei-core/src/Shomei/Effect/InMemory.hs` interprets
  every port purely (IORef-backed `World`) for the test suites.
- `shomei-servant` (`shomei-servant/src/Shomei/Servant/…`) exposes the HTTP API as a Servant
  `NamedRoutes` record (`Shomei.Servant.API.ShomeiAPI`), with DTOs (`Shomei.Servant.DTO`),
  handlers (`Shomei.Servant.Handlers`), the seam onto the effect stack
  (`Shomei.Servant.Seam`), and the error mapping (`Shomei.Servant.Error`).
- `shomei-server` (`shomei-server/`) assembles everything (`Shomei.Server.App.runAppIO`).

**Terms used below, defined once:**

- *Ceremony.* One WebAuthn exchange. *Authentication* (a.k.a. assertion) proves possession of
  an existing passkey. It has a *begin* step (server emits options with a random *challenge*)
  and a *complete* step (server verifies the browser's signed *assertion*).
- *Assertion.* The JSON the browser returns from `navigator.credentials.get()` (serialized by
  the standard `webauthn-json` helper). It crosses the API and the port boundary as an aeson
  `Value` verbatim, so the core never names a WebAuthn library type.
- *Pending ceremony.* The short-lived server-side challenge/options blob, created at *begin*
  and consumed **exactly once** at *complete* (EP-2's `PendingCeremonyStore` enforces this
  with a TTL and a consume-once `TakePendingCeremony`).
- *MFA (multi-factor authentication) step-up.* Requiring a second factor (the passkey) after
  the first (the password) before issuing a session.
- *Passwordless.* Logging in with the passkey alone (no password), using the browser's
  discoverable-credential picker.
- *Abuse protection.* The existing per-IP throttle + per-account lockout layered into `login`
  via the `LoginAttemptStore` port. This plan **preserves it unchanged**; the MFA branch runs
  only *after* a fully successful password check.

The files this plan reads and changes, with their roles:

- `shomei-core/src/Shomei/Workflow.hs` — defines `login` (widened here), `signup`, `refresh`,
  `logout`, `verifyToken`, the `buildClaims` helper, and `failLogin`. The new
  `issueSession` helper lives here too.
- `shomei-core/src/Shomei/Workflow/Mfa.hs` — **new**; holds `completeMfa`,
  `beginPasswordlessLogin`, `completePasswordlessLogin`.
- `shomei-core/src/Shomei/Domain/Event.hs`, `…/Error.hs` — extended with the MFA events and
  (if EP-3 has not) the WebAuthn errors plus this plan's `MfaAssertionInvalid`.
- `shomei-servant/src/Shomei/Servant/{API,DTO,Handlers,Error}.hs` — routes, DTOs, handlers,
  error mapping.
- `shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs` — persist the new events.
- `shomei-servant/test/Main.hs` — the in-process HTTP test harness; its `runHybrid` runner must
  gain the EP-1/EP-2/EP-3 interpreters.

The current state of `login` (the function this plan widens), copied so you can see exactly
what changes:

```haskell
-- shomei-core/src/Shomei/Workflow.hs  (current)
login ::
    ( UserStore :> es, CredentialStore :> es, SessionStore :> es, RefreshTokenStore :> es
    , PasswordHasher :> es, TokenSigner :> es, AuthEventPublisher :> es
    , LoginAttemptStore :> es, Clock :> es, TokenGen :> es ) =>
    ShomeiConfig -> ClientContext -> LoginCommand ->
    Eff es (Either AuthError (User, TokenPair))
login cfg ctx cmd = runErrorNoCallStack do
    ts <- now
    -- … per-IP throttle + lockout gate (UNCHANGED) …
    mCred <- findPasswordCredentialByEmail cmd.email
    cred <- maybe (failLogin rl ctx cmd.email ts) pure mCred
    mUser <- findUserById cred.userId
    user <- maybe (failLogin rl ctx cmd.email ts) pure mUser
    when (user.status /= UserActive) (throwError UserNotActive)
    ok <- verifyPassword cmd.password cred.passwordHash
    unless ok (failLogin rl ctx cmd.email ts)
    recordLoginAttempt NewLoginAttempt{ … outcome = LoginSuccess … }
    clearAccountLockout ctx.accountKey
    -- vvv  THIS TAIL becomes `issueSession` AND gains an MFA branch above it  vvv
    session <- createSession NewSession{ … }
    rawToken <- generateOpaqueToken
    tokHash <- hashRefreshToken rawToken
    _ <- createRefreshToken NewRefreshToken{ … }
    access <- signAccessToken (buildClaims cfg user.userId session.sessionId ts)
    publishAuthEvent (Event.LoginSucceeded …)
    publishAuthEvent (Event.SessionStarted …)
    pure (user, TokenPair{ … })
```

The two effect-stack lists that `login`'s widened signature touches indirectly are already
correct for this plan: EP-1 added `WebAuthnCeremony` and EP-2 added
`PasskeyStore`/`PendingCeremonyStore` to `Shomei.Servant.Seam.AppEffects`,
`Shomei.Server.App.AppEffects`/`runAppIO`, `Shomei.Effect.InMemory.runInMemory`, and the
`shomei-postgres` test stack. **This plan adds no new ports**, so it touches none of those
lists — it only *uses* ports that are already present. (If, when you implement, those ports
are NOT in the stacks, EP-1/EP-2 are incomplete: stop and finish them, recording it as a
Surprise. Do not add ports here.)


## Plan of Work

Two milestones. Milestone 1 is pure `shomei-core`: widen `login`, add the MFA workflows and the
shared `issueSession` helper, the new events and the `MfaAssertionInvalid` error, and prove
everything with an in-memory test using EP-1's fake ceremony interpreter + EP-2's in-memory
stores. Milestone 2 exposes it over HTTP (routes, the widened `LoginResponse`, handlers),
wires the events into the PostgreSQL publisher, and proves the whole step-up flow with an
in-process HTTP test.


### Milestone 1 — widen `login`, add `completeMfa` + passwordless, shared helper, events/errors

**Scope.** At the end of M1, `Shomei.Workflow.login` returns `Either AuthError LoginResult`;
`Shomei.Workflow.issueSession` exists and is shared; `Shomei.Workflow.Mfa` defines
`completeMfa`, `beginPasswordlessLogin`, `completePasswordlessLogin`; `AuthEvent` has three new
arms; `AuthError` has `MfaAssertionInvalid` (plus EP-3's three WebAuthn arms if absent); and a
new pure test proves the four required behaviors. No HTTP, no PostgreSQL. `cabal test all` is
green.

**Step 1.1 — events.** In `shomei-core/src/Shomei/Domain/Event.hs`, add three records and three
sum arms, and export the records. `UserId`/`SessionId` already imported; `CeremonyId` comes from
`Shomei.Id` (EP-1) — extend the `import Shomei.Id (…)` line to include `CeremonyId`.

```haskell
-- in the export list, alongside the other *Data exports:
    MfaChallengedData (..),
    MfaSucceededData (..),
    MfaFailedData (..),

-- with the other record declarations:
data MfaChallengedData = MfaChallengedData
    { userId :: !UserId
    , ceremonyId :: !CeremonyId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data MfaSucceededData = MfaSucceededData
    { userId :: !UserId
    , sessionId :: !SessionId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data MfaFailedData = MfaFailedData
    { userId :: !(Maybe UserId)   -- Nothing when the user could not be resolved (passwordless)
    , reason :: !Text
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- new arms appended to `data AuthEvent = …`:
    | MfaChallenged MfaChallengedData
    | MfaSucceeded MfaSucceededData
    | MfaFailed MfaFailedData
```

`CeremonyId` is `KindID "webauthn_ceremony"` (EP-1) and `KindID` already has
`FromJSON`/`ToJSON`, so the derived instances on `MfaChallengedData` compile.

**Step 1.2 — errors.** In `shomei-core/src/Shomei/Error.hs`, add one constructor (this plan's
own), keeping it next to the EP-3 WebAuthn arms:

```haskell
-- appended to `data AuthError = …`, before `InternalAuthError Text`:
    | -- | A WebAuthn login/step-up assertion failed verification (bad signature, clone
      -- counter, user-not-present). The HTTP layer maps this to a generic 401.
      MfaAssertionInvalid
```

If EP-3 has **not** yet added `WebAuthnCeremonyError WebAuthnError`, `PasskeyNotFound`, and
`PendingCeremonyNotFound`, add them here too (importing `WebAuthnError` from
`Shomei.Effect.WebAuthnCeremony`) and record it as a Surprise — they belong to EP-3 but this
plan needs them. EP-3's `docs/plans/17-…md` Step 1.2 shows the exact additions.

**Step 1.3 — the shared `issueSession` helper.** In `shomei-core/src/Shomei/Workflow.hs`, add a
helper that is exactly the current success tail of `login`/`signup`. It runs inside the
`Error AuthError` effect (so it can be called from a `runErrorNoCallStack do` block) and uses
the same ports `login` already constrains. Place it after `buildClaims`:

```haskell
{- | Mint a fresh session + refresh token + signed access token for an authenticated user,
publishing 'LoginSucceeded' and 'SessionStarted'. This is the exact token-issuing tail that
'login' (non-MFA path), 'completeMfa', and 'completePasswordlessLogin' share, factored out so
the four call sites cannot drift. The session id is fresh each call. -}
issueSession ::
    ( SessionStore :> es
    , RefreshTokenStore :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    User ->
    UTCTime ->
    Eff es TokenPair
issueSession cfg user ts = do
    session <-
        createSession
            NewSession
                { userId = user.userId
                , createdAt = ts
                , expiresAt = addUTCTime cfg.sessionTTL ts
                }
    rawToken <- generateOpaqueToken
    tokHash <- hashRefreshToken rawToken
    _ <-
        createRefreshToken
            NewRefreshToken
                { sessionId = session.sessionId
                , tokenHash = tokHash
                , parentTokenId = Nothing
                , createdAt = ts
                , expiresAt = addUTCTime cfg.refreshTokenTTL ts
                }
    access <- signAccessToken (buildClaims cfg user.userId session.sessionId ts)
    publishAuthEvent (Event.LoginSucceeded (Event.LoginSucceededData user.userId session.sessionId ts))
    publishAuthEvent (Event.SessionStarted (Event.SessionStartedData session.sessionId user.userId ts))
    pure TokenPair{accessToken = access, refreshToken = rawToken, expiresIn = cfg.accessTokenTTL}
```

Export `issueSession` from `Shomei.Workflow` (add it to the module export list) so
`Shomei.Workflow.Mfa` can import it.

**Step 1.4 — the `LoginResult` type and the widened `login`.** Still in
`shomei-core/src/Shomei/Workflow.hs`, add the result types near the top (after the imports) and
export them:

```haskell
-- export list additions:
    LoginResult (..),
    MfaChallenge (..),
    issueSession,

-- type declarations:
{- | The WebAuthn step-up challenge handed back when an account with a passkey logs in with
the correct password and 'mfaRequired' is on. 'ceremonyId' is the consume-once pending-MFA
handle the client echoes to 'completeMfa'; 'options' is the @navigator.credentials.get()@
options the browser runs. -}
data MfaChallenge = MfaChallenge
    { ceremonyId :: !CeremonyId
    , options :: !Value
    }
    deriving stock (Generic, Eq, Show)

{- | The outcome of 'login'. 'LoginComplete' is the legacy success (user + tokens), returned
unchanged for accounts with no passkey or with 'mfaRequired' off. 'MfaRequired' means the
password was correct but a second factor is now demanded; NO token is issued yet. -}
data LoginResult
    = LoginComplete User TokenPair
    | MfaRequired MfaChallenge
    deriving stock (Generic, Show)
```

Add the needed imports to `Shomei.Workflow.hs`: `Data.Aeson (Value)`, `Shomei.Id (CeremonyId)`
(extend the existing `Shomei.Id` import), the EP-1 ceremony port
(`Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony, BeginCeremony (..), beginAuthenticationCeremony)`),
the EP-2 stores
(`Shomei.Effect.PasskeyStore (PasskeyStore, countPasskeysByUser, findPasskeysByUser)` and
`Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony)`), the EP-1
config field accessor (`Shomei.Config (WebAuthnConfig (..))` — `ShomeiConfig` is already
imported; pull `WebAuthnConfig (..)` in the same line so `cfg.webauthnConfig.mfaRequired` and
`.pendingCeremonyTTL` resolve), and the passkey domain
(`Shomei.Domain.Passkey (CeremonyKind (AuthenticationCeremony), PendingCeremony (..), WebAuthnCredentialId)`).
Also add `genCeremonyId` from `Shomei.Id` (EP-1) for minting the pending-MFA ceremony id.

Now widen `login`. Change the signature's result to `Eff es (Either AuthError LoginResult)` and
**add** the three new effect constraints `PasskeyStore :> es`, `PendingCeremonyStore :> es`,
`WebAuthnCeremony :> es`. Replace the success tail (everything from `session <- createSession …`
down to the final `pure (user, TokenPair{…})`) with the MFA branch:

```haskell
login ::
    ( UserStore :> es
    , CredentialStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasswordHasher :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , LoginAttemptStore :> es
    , PasskeyStore :> es              -- NEW
    , PendingCeremonyStore :> es      -- NEW
    , WebAuthnCeremony :> es          -- NEW
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    ClientContext ->
    LoginCommand ->
    Eff es (Either AuthError LoginResult)
login cfg ctx cmd = runErrorNoCallStack do
    ts <- now
    -- … the per-IP throttle + lockout gate, the credential/user lookups, the password
    --   verification, recordLoginAttempt LoginSuccess, and clearAccountLockout are ALL
    --   UNCHANGED from the current implementation. Keep them verbatim. The change is below. …
    -- (password has succeeded; success recorded; lockout cleared)
    passkeyCount <- countPasskeysByUser user.userId
    if cfg.webauthnConfig.mfaRequired && passkeyCount > 0
        then do
            -- Step up: build a WebAuthn assertion challenge restricted to this user's
            -- credentials, stash it consume-once, and return the challenge WITHOUT a token.
            creds <- findPasskeysByUser user.userId
            let allowIds = map (.credentialId) creds :: [WebAuthnCredentialId]
            BeginCeremony{optionsJson, optionsBlob} <- beginAuthenticationCeremony allowIds
            cid <- genCeremonyId
            putPendingCeremony
                PendingCeremony
                    { ceremonyId = cid
                    , userId = Just user.userId
                    , kind = AuthenticationCeremony
                    , optionsBlob = optionsBlob
                    , createdAt = ts
                    , expiresAt = addUTCTime cfg.webauthnConfig.pendingCeremonyTTL ts
                    }
            publishAuthEvent (Event.MfaChallenged (Event.MfaChallengedData user.userId cid ts))
            pure (MfaRequired (MfaChallenge{ceremonyId = cid, options = optionsJson}))
        else do
            pair <- issueSession cfg user ts
            pure (LoginComplete user pair)
```

Notes:

- `genCeremonyId :: MonadIO m => m CeremonyId` is EP-1's generator in `Shomei.Id`. It runs in
  `Eff` because the workflow's `es` includes `IOE` at the base (every interpreter stack ends in
  `IOE`); if EP-1 instead exposes ceremony-id generation through the `WebAuthnCeremony` port
  (some EP-3 drafts mention a `generateCeremonyId` op), call that and drop `genCeremonyId` —
  record which in the Decision Log. EP-3's enrollment workflow already makes this exact choice,
  so match it.
- The `TokenGen` constraint stays (`issueSession` uses `generateOpaqueToken`/`hashRefreshToken`).
- Everything above the `passkeyCount` line is preserved byte-for-byte, including `failLogin`,
  the per-IP throttle, the lockout gate, `recordLoginAttempt LoginSuccess`, and
  `clearAccountLockout`. The MFA branch is reached ONLY after a fully successful password check.

**Step 1.5 — the `Shomei.Workflow.Mfa` module.** Create
`shomei-core/src/Shomei/Workflow/Mfa.hs`. It mirrors `Shomei.Workflow`'s style and reuses
`issueSession`. It defines: `completeMfa` (finish a step-up), `beginPasswordlessLogin` and
`completePasswordlessLogin` (the no-password path), and a private `resolveUserFromAssertion`
helper. The full intended module:

```haskell
{- | The second-factor completion and the passwordless login workflows (EP-4).

'completeMfa' finishes a step-up begun by 'Shomei.Workflow.login' (which returned an
'MfaRequired' challenge): it consumes the pending ceremony, verifies the browser's assertion
against the user's stored passkey, and — on success — mints the session and tokens.
'beginPasswordlessLogin'/'completePasswordlessLogin' authenticate with the passkey ALONE: begin
emits options for a discoverable credential (no account named), complete resolves the account
from the asserted credential id, verifies, and mints tokens. All three share
'Shomei.Workflow.issueSession' so the token-issuing tail never drifts. -}
module Shomei.Workflow.Mfa (
    completeMfa,
    beginPasswordlessLogin,
    completePasswordlessLogin,
) where

import Shomei.Prelude

import Data.Aeson (Value)
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)

import Shomei.Config (ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Passkey (
    CeremonyKind (AuthenticationCeremony),
    PasskeyCredential (..),
    PendingCeremony (..),
    StoredCredentialForVerify (..),
 )
import Shomei.Domain.Token (TokenPair)
import Shomei.Domain.User (User (..), UserStatus (UserActive))
import Shomei.Error (AuthError (..))
import Shomei.Id (CeremonyId)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.PasskeyStore (
    PasskeyStore,
    findPasskeyByCredentialId,
    updatePasskeySignCounter,
 )
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony, takePendingCeremony)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Effect.WebAuthnCeremony (
    BeginCeremony (..),
    VerifiedAuthentication (..),
    WebAuthnCeremony,
    WebAuthnError,
    beginAuthenticationCeremony,
    completeAuthenticationCeremony,
 )
import Shomei.Id (genCeremonyId)
import Shomei.Workflow (issueSession)

import Shomei.Domain.Passkey (WebAuthnCredentialId)

{- | Finish a password-then-passkey step-up. The client posts the ceremony id from the
'MfaRequired' challenge plus the browser's signed assertion. We consume the pending ceremony
(rejecting a missing/expired/consumed/non-authentication ceremony with the user mismatch as a
404-mapped error), look the stored passkey up to build the verifier input, verify, bump the
sign counter, publish 'MfaSucceeded', and mint tokens via the shared 'issueSession'. On a
verification failure we publish 'MfaFailed' and return an auth error. -}
completeMfa ::
    ( UserStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    CeremonyId ->
    Value ->
    Eff es (Either AuthError (User, TokenPair))
completeMfa cfg ceremonyId assertion = runErrorNoCallStack do
    ts <- now
    pending <-
        maybe (throwError PendingCeremonyNotFound) pure
            =<< takePendingCeremony ceremonyId ts
    when (pending.kind /= AuthenticationCeremony) (throwError PendingCeremonyNotFound)
    uid <- maybe (throwError PendingCeremonyNotFound) pure pending.userId
    user <- maybe (throwError InvalidCredentials) pure =<< findUserById uid
    when (user.status /= UserActive) (throwError UserNotActive)
    verified <-
        verifyAssertion (Just uid) pending.optionsBlob assertion
    -- The verified credential must belong to this user (defence in depth: a ceremony's
    -- allowCredentials already restricts it, but re-check the resolved owner).
    passkey <- requireOwnedCredential uid verified.credentialId
    updatePasskeySignCounter passkey.passkeyId verified.newSignCounter ts
    publishAuthEvent (Event.MfaSucceeded (Event.MfaSucceededData uid undefinedSessionPlaceholder ts))
    -- ^ see note: MfaSucceeded carries the sessionId; we publish it AFTER issueSession so we
    --   know the session id. The line above is illustrative; the real order is below.
    pair <- issueSession cfg user ts
    pure (user, pair)

{- | Begin a passwordless login: emit authentication options with NO allowCredentials so the
browser offers its discoverable passkeys, stash the pending ceremony with no user attached, and
hand the client the ceremony id + options. -}
beginPasswordlessLogin ::
    ( PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    Eff es (Either AuthError (CeremonyId, Value))
beginPasswordlessLogin cfg = runErrorNoCallStack do
    ts <- now
    BeginCeremony{optionsJson, optionsBlob} <- beginAuthenticationCeremony []
    cid <- genCeremonyId
    putPendingCeremony
        PendingCeremony
            { ceremonyId = cid
            , userId = Nothing
            , kind = AuthenticationCeremony
            , optionsBlob = optionsBlob
            , createdAt = ts
            , expiresAt = addUTCTime cfg.webauthnConfig.pendingCeremonyTTL ts
            }
    pure (cid, optionsJson)

{- | Finish a passwordless login: consume the pending ceremony, resolve the user from the
asserted credential id, verify, bump the counter, and mint tokens. -}
completePasswordlessLogin ::
    ( UserStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    CeremonyId ->
    Value ->
    Eff es (Either AuthError (User, TokenPair))
completePasswordlessLogin cfg ceremonyId assertion = runErrorNoCallStack do
    ts <- now
    pending <-
        maybe (throwError PendingCeremonyNotFound) pure
            =<< takePendingCeremony ceremonyId ts
    when (pending.kind /= AuthenticationCeremony) (throwError PendingCeremonyNotFound)
    -- Discoverable flow: the ceremony has no user attached; resolve it from the credential.
    (passkey, verified) <- verifyAndResolve pending.optionsBlob assertion
    user <- maybe (throwError InvalidCredentials) pure =<< findUserById passkey.userId
    when (user.status /= UserActive) (throwError UserNotActive)
    updatePasskeySignCounter passkey.passkeyId verified.newSignCounter ts
    pair <- issueSession cfg user ts
    pure (user, pair)
```

The `completeMfa` body above has an illustrative-but-wrong inline (`undefinedSessionPlaceholder`)
to flag a real ordering subtlety: `MfaSucceeded` carries the `sessionId`, but the session is
created *inside* `issueSession`. There are two clean fixes; **use fix (b)** and record it:

- (a) have `completeMfa` create the session itself (inline the session-create, then call a
  thinner token-only helper), OR
- (b) **keep `issueSession` as the single tail, and publish `MfaSucceeded` carrying the user id
  with the session id obtained by having `issueSession` *return* the session id alongside the
  pair.** Concretely, change `issueSession` to return `(Session, TokenPair)` (or `(SessionId,
  TokenPair)`), have `login`'s non-MFA branch ignore the session, and have `completeMfa` use the
  returned session id in `MfaSucceeded`. This keeps one tail and gives `completeMfa` the id it
  needs. **Adopt (b): `issueSession :: … -> Eff es (SessionId, TokenPair)`** and adjust `login`'s
  `LoginComplete user pair` to `(_sid, pair) <- issueSession …; pure (LoginComplete user pair)`.
  Update the helper's type/return in Step 1.3 accordingly, and `completeMfa` becomes:

```haskell
    passkey <- requireOwnedCredential uid verified.credentialId
    updatePasskeySignCounter passkey.passkeyId verified.newSignCounter ts
    (sid, pair) <- issueSession cfg user ts
    publishAuthEvent (Event.MfaSucceeded (Event.MfaSucceededData uid sid ts))
    pure (user, pair)
```

The private helpers in `Shomei.Workflow.Mfa`:

```haskell
{- | Look the stored passkey up by the credential id the verifier resolved and confirm it
belongs to the expected user; otherwise the assertion is for an unknown/foreign credential. -}
requireOwnedCredential ::
    (PasskeyStore :> es, Error AuthError :> es) =>
    UserId -> WebAuthnCredentialId -> Eff es PasskeyCredential
requireOwnedCredential uid cid = do
    mPk <- findPasskeyByCredentialId cid
    case mPk of
        Just pk | pk.userId == uid -> pure pk
        _ -> throwError MfaAssertionInvalid

{- | Verify a step-up assertion: find the passkey the assertion claims (by the credential id
embedded in the assertion JSON — the verifier needs the stored credential to check the
signature), then call the ceremony port. We look the credential up FIRST because
'CompleteAuthenticationCeremony' takes a 'StoredCredentialForVerify'. The credential id is read
from the assertion via the EP-1 helper 'assertionCredentialId' (see note). On a Left or on a
clone warning we publish 'MfaFailed' and throw 'MfaAssertionInvalid'. -}
verifyAssertion ::
    ( PasskeyStore :> es
    , WebAuthnCeremony :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , Error AuthError :> es
    ) =>
    Maybe UserId -> ByteString -> Value -> Eff es VerifiedAuthentication
verifyAssertion mUid blob assertion = do
    cid <- maybe (failMfa mUid "missing credential id") pure (assertionCredentialId assertion)
    pk <- maybe (failMfa mUid "unknown credential") pure =<< findPasskeyByCredentialId cid
    let stored =
            StoredCredentialForVerify
                { credentialId = pk.credentialId
                , userHandle = pk.userHandle
                , publicKey = pk.publicKey
                , signCounter = pk.signCounter
                , transports = pk.transports
                }
    res <- completeAuthenticationCeremony blob stored assertion
    case res of
        Left _ -> failMfa mUid "assertion verification failed"
        Right v
            | v.cloneWarning -> failMfa mUid "signature counter clone warning"
            | otherwise -> pure v

failMfa ::
    (AuthEventPublisher :> es, Clock :> es, Error AuthError :> es) =>
    Maybe UserId -> Text -> Eff es a
failMfa mUid reason = do
    ts <- now
    publishAuthEvent (Event.MfaFailed (Event.MfaFailedData mUid reason ts))
    throwError MfaAssertionInvalid
```

Two notes that the implementer must resolve against the real EP-1 surface:

- `assertionCredentialId :: Value -> Maybe WebAuthnCredentialId` reads the credential id out of
  the browser's assertion JSON (the standard `webauthn-json` assertion has a top-level
  base64url `"id"`/`"rawId"`). EP-1's interpreter already decodes this internally; **prefer an
  EP-1-provided helper if one exists** (e.g. exported from `Shomei.Effect.WebAuthnCeremony` or
  the `shomei-webauthn` package). If EP-1 exposes none, write a tiny local decoder in
  `Shomei.Workflow.Mfa` that pulls `"rawId"` (base64url) using the same base64url helpers EP-1
  defined for `WebAuthnCredentialId`'s JSON instance (the contract in EP-1 gives those). Record
  the choice in the Decision Log. (This is the one place the core peeks into the assertion JSON;
  it is a lookup key only — the *cryptographic* verification still happens entirely in EP-1's
  interpreter via `completeAuthenticationCeremony`.)
- For `completePasswordlessLogin`, `verifyAndResolve` is exactly `verifyAssertion Nothing` plus
  returning the looked-up passkey: refactor `verifyAssertion` to also return the `pk`, i.e.
  `verifyAssertion :: … -> Eff es (PasskeyCredential, VerifiedAuthentication)`, and have
  `completeMfa` additionally check `pk.userId == uid` (the `requireOwnedCredential` step) while
  `completePasswordlessLogin` takes `pk.userId` as the resolved user. This unifies the two
  paths around one verifier. Adopt that unified shape; the snippets above are the conceptual
  decomposition.

Add `Shomei.Workflow.Mfa` to `shomei-core/shomei-core.cabal` `exposed-modules` (next to
`Shomei.Workflow.Passkey`). No new dependencies.

**Step 1.6 — the pure test.** Create `shomei-core/test/Shomei/Workflow/MfaSpec.hs`, registered in
`shomei-core.cabal` `other-modules` and added to `shomei-core/test/Main.hs`'s test list. It uses
EP-2's in-memory stores, EP-1's deterministic fake `WebAuthnCeremony`, and (to seed a passkey) a
direct `createPasskey` call or EP-3's `completePasskeyRegistration`. Build a fixed clock `t0` and
an `IORef World` via `emptyWorld t0`, run through `runInMemory ref`, and assert:

```haskell
-- Pseudocode of the four required behaviors (HUnit-style); use the real fake/stack EP-1/EP-2 ship.
-- (i) NO-MFA: a user with no passkey logs in and gets tokens (LoginComplete), unchanged.
--     Right (LoginComplete _u pair) <- run (login cfg ctx loginCmd)
--     assertBool "token present" (… pair.accessToken is non-empty …)
-- (ii) MFA REQUIRED: seed a passkey for the user (createPasskey …) with cfg.webauthnConfig.mfaRequired = True;
--     Right (MfaRequired ch) <- run (login cfg ctx loginCmd)
--     -- no usable token exists: the result carries only ceremonyId + options
-- (iii) COMPLETE: craft an assertion Value the fake accepts (echoing the challenge in ch's
--       options blob and carrying the seeded credential id); then
--       Right (_u, pair) <- run (completeMfa cfg ch.ceremonyId assertionValue)
--       assertBool "token present" (… pair.accessToken non-empty …)
-- (iv) WRONG/EXPIRED CEREMONY: completeMfa with a bogus CeremonyId -> Left PendingCeremonyNotFound;
--      and a SECOND completeMfa of the same (already-consumed) ceremony -> Left PendingCeremonyNotFound.
-- (optional) completePasswordlessLogin with a valid discoverable assertion resolves the user and mints tokens.
```

The fake's accepted-assertion shape: EP-1's fake `completeAuthenticationCeremony` succeeds when
the assertion's embedded challenge matches the ceremony blob and the asserted credential id
equals `stored.credentialId` (per EP-1's Milestone-1 fake contract). Craft the assertion `Value`
to carry the seeded `credentialId` under the key `assertionCredentialId` reads (`"rawId"`,
base64url) plus the challenge the fake checks. Define `acceptedAssertion` once at the top.

**Step 1.7 — update existing `login` callers in tests.** Search the repo for callers that
pattern-match `login`'s old result and update them to the `LoginResult` sum:

```bash
nix develop --command grep -rn "Wf.login\|Workflow.login\| login cfg\|login env" \
  shomei-core/test shomei-postgres/test shomei-servant/test
```

The known core caller is `shomei-core/test/Shomei/WorkflowSpec.hs` (it asserts on the
`(User, TokenPair)` returned by `login`). Change each `Right (user, pair) <- … login …` to
`Right (LoginComplete user pair) <- … login …` (these tests use no passkey + `mfaRequired`
default; if `defaultWebAuthnConfig.mfaRequired = True`, they still get `LoginComplete` because
the user has zero passkeys — `passkeyCount > 0` is False). If any existing core test sets up a
passkey AND expects tokens from `login`, update it to go through `completeMfa`. The servant test
caller (`loginH`) is updated in Milestone 2.

**Acceptance for Milestone 1.** From the repo root:

```bash
nix develop --command cabal build all
nix develop --command cabal test all
```

both green; `MfaSpec` passes all four required cases and the updated `WorkflowSpec` still passes.

```text
shomei-core
  Shomei.Workflow.Mfa
    no-passkey login yields LoginComplete with a token:     OK
    passkey + mfaRequired login yields MfaRequired, no token: OK
    completeMfa with a valid assertion yields a token pair:  OK
    bogus/consumed ceremony is rejected (PendingCeremonyNotFound): OK
All N tests passed
```


### Milestone 2 — HTTP routes, widened LoginResponse, handlers, event wiring, in-process HTTP test

**Scope.** At the end of M2, `ShomeiAPI` has three new routes (`mfaComplete`,
`passkeyLoginBegin`, `passkeyLoginComplete`); `LoginResponse` is a tagged sum; `loginH` maps
`LoginResult` to it and three new handlers exist; `MfaAssertionInvalid` maps to 401; the three
new events persist; and an in-process HTTP test proves the step-up flow. `cabal build all` and
`cabal test all` are green.

**Step 2.1 — widen `LoginResponse` + new DTOs.** In `shomei-servant/src/Shomei/Servant/DTO.hs`,
replace the current record `LoginResponse` with a tagged sum and hand-written JSON, and add the
three new DTOs and a mapper. Export them all (extend the module header export list:
`LoginResponse (..)`, `MfaCompleteRequest (..)`, `PasskeyLoginBeginResponse (..)`,
`PasskeyLoginCompleteRequest (..)`, `loginResultToResponse`). Add imports
`Data.Aeson (Value, object, withObject, (.=), (.:), (.:?))` and the EP-1/EP-4 domain
(`Shomei.Domain.Token (TokenPair)`, `Shomei.Domain.User (User)`,
`Shomei.Workflow (LoginResult (..), MfaChallenge (..))`, `Shomei.Id (idText)`).

```haskell
{- | @POST /auth/login@ response. Either a completed login (user + token) or an MFA challenge.
The wire JSON is a flat, @status@-tagged object:

@{ "status":"complete",     "user":{…}, "token":{…} }@
@{ "status":"mfa_required", "ceremonyId":"…", "options":{…} }@ -}
data LoginResponse
    = LoginCompleteResponse
        { user :: !UserResponse
        , token :: !TokenPairResponse
        }
    | LoginMfaRequiredResponse
        { ceremonyId :: !Text
        , options :: !Value
        }
    deriving stock (Generic)

instance ToJSON LoginResponse where
    toJSON = \case
        LoginCompleteResponse u t ->
            object ["status" .= ("complete" :: Text), "user" .= u, "token" .= t]
        LoginMfaRequiredResponse cid opts ->
            object ["status" .= ("mfa_required" :: Text), "ceremonyId" .= cid, "options" .= opts]

instance FromJSON LoginResponse where
    parseJSON = withObject "LoginResponse" \o -> do
        status <- o .: "status" :: Parser Text
        case status of
            "complete" -> LoginCompleteResponse <$> o .: "user" <*> o .: "token"
            "mfa_required" -> LoginMfaRequiredResponse <$> o .: "ceremonyId" <*> o .: "options"
            other -> fail ("unknown login status: " <> Text.unpack other)

-- | @POST /auth/mfa/complete@ body: the ceremony id from the login challenge + the assertion JSON.
data MfaCompleteRequest = MfaCompleteRequest
    { ceremonyId :: !Text
    , assertion :: !Value
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/login/passkey/begin@ response: the ceremony id + the get() options.
data PasskeyLoginBeginResponse = PasskeyLoginBeginResponse
    { ceremonyId :: !Text
    , options :: !Value
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/login/passkey/complete@ body: the ceremony id from begin + the assertion JSON.
data PasskeyLoginCompleteRequest = PasskeyLoginCompleteRequest
    { ceremonyId :: !Text
    , assertion :: !Value
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Map the core 'LoginResult' to the wire 'LoginResponse'.
loginResultToResponse :: LoginResult -> LoginResponse
loginResultToResponse = \case
    LoginComplete user pair ->
        LoginCompleteResponse{user = userToResponse user, token = tokenPairToResponse pair}
    MfaRequired ch ->
        LoginMfaRequiredResponse{ceremonyId = idText ch.ceremonyId, options = ch.options}
```

`Parser` comes from `Data.Aeson.Types (Parser)` — add that import. `Text.unpack` needs the
existing `Data.Text qualified as Text` import (present). The `/auth/login/passkey/complete` and
`/auth/mfa/complete` endpoints return a **token pair** (a `TokenPairResponse`) — passwordless and
step-up *completion* never themselves return an MFA challenge — so they reuse the existing
`TokenPairResponse` DTO and `tokenPairToResponse` mapper. (We do not return the `User` there to
keep the completion response symmetric with `/auth/refresh`; the client already has the user from
the login attempt, and can call `/auth/me`. If the client needs the user inline, widen later.)

**Step 2.2 — routes.** In `shomei-servant/src/Shomei/Servant/API.hs`, add three fields to the
`ShomeiAPI` record (the `login` field's type stays the same — `LoginResponse` just changed shape).
Add imports for the three new DTOs from `Shomei.Servant.DTO` and `TokenPairResponse` (already
imported). Do **not** add `/auth/mfa/begin` (Decision Log).

```haskell
    , mfaComplete ::
        mode
            :- "auth"
                :> "mfa"
                :> "complete"
                :> ReqBody '[JSON] MfaCompleteRequest
                :> Post '[JSON] TokenPairResponse
    , passkeyLoginBegin ::
        mode
            :- "auth"
                :> "login"
                :> "passkey"
                :> "begin"
                :> Post '[JSON] PasskeyLoginBeginResponse
    , passkeyLoginComplete ::
        mode
            :- "auth"
                :> "login"
                :> "passkey"
                :> "complete"
                :> ReqBody '[JSON] PasskeyLoginCompleteRequest
                :> Post '[JSON] TokenPairResponse
```

These three are **unauthenticated** (no `Authenticated` combinator): the caller has no session
yet — proving the second factor (or the passkey) is exactly how they *get* one. They carry no
`RemoteHost` (the per-IP throttle lives on the password `login`; the ceremony's consume-once TTL
is the abuse bound for the completion endpoints). Update the module doc comment's route inventory.

**Step 2.3 — handlers.** In `shomei-servant/src/Shomei/Servant/Handlers.hs`:

- Rewrite `loginH` to map the new `LoginResult`:

```haskell
loginH :: Env -> SockAddr -> LoginRequest -> Handler LoginResponse
loginH env peer req = do
    email <- either (throwError . authErrorToServerError) pure (mkEmail req.email)
    let cmd = LoginCommand{email = email, password = PlainPassword req.password}
        ctx =
            ClientContext
                { clientIp = ClientIp (clientIpText peer)
                , accountKey = env.accountKeyOf email
                }
    result <- runAuth env (Wf.login env.config ctx cmd)
    pure (loginResultToResponse result)
```

- Add the three new handlers and wire them into `shomeiServer`:

```haskell
mfaCompleteH :: Env -> MfaCompleteRequest -> Handler TokenPairResponse
mfaCompleteH env req = do
    cid <- either (const (throwError err400{errBody = "invalid ceremonyId"})) pure (parseId req.ceremonyId)
    (_user, pair) <- runAuth env (Mfa.completeMfa env.config cid req.assertion)
    pure (tokenPairToResponse pair)

passkeyLoginBeginH :: Env -> Handler PasskeyLoginBeginResponse
passkeyLoginBeginH env = do
    (cid, options) <- runAuth env (Mfa.beginPasswordlessLogin env.config)
    pure PasskeyLoginBeginResponse{ceremonyId = idText cid, options = options}

passkeyLoginCompleteH :: Env -> PasskeyLoginCompleteRequest -> Handler TokenPairResponse
passkeyLoginCompleteH env req = do
    cid <- either (const (throwError err400{errBody = "invalid ceremonyId"})) pure (parseId req.ceremonyId)
    (_user, pair) <- runAuth env (Mfa.completePasswordlessLogin env.config cid req.assertion)
    pure (tokenPairToResponse pair)
```

Wire into the `shomeiServer` record:

```haskell
        , mfaComplete = mfaCompleteH env
        , passkeyLoginBegin = passkeyLoginBeginH env
        , passkeyLoginComplete = passkeyLoginCompleteH env
```

Add imports: `import Shomei.Workflow.Mfa qualified as Mfa`,
`import Shomei.Id (idText, parseId)` (extend the existing import; `parseId`/`idText` are exported
by `Shomei.Id`), `err400` from `Servant` (extend the existing `Servant (… )` import),
`Shomei.Workflow (LoginResult)` is not needed in Handlers (the mapper lives in DTO), and the new
DTO names `LoginResponse (..)` (already imported), `MfaCompleteRequest (..)`,
`PasskeyLoginBeginResponse (..)`, `PasskeyLoginCompleteRequest (..)`, and `loginResultToResponse`
from `Shomei.Servant.DTO`. Note `loginH`'s import of `LoginResponse (..)` must now include the
constructors (it returns it via the mapper, so it does not need constructors directly — but the
record-field accessor `user`/`token` was removed; ensure `loginH` no longer constructs
`LoginResponse{…}` by hand — it now uses `loginResultToResponse`).

**Step 2.4 — error mapping.** In `shomei-servant/src/Shomei/Servant/Error.hs`, add this plan's
arm to `authErrorToServerError` (the EP-3 arms for `PasskeyNotFound`/`PendingCeremonyNotFound`/
`WebAuthnCeremonyError` are added by EP-3; if EP-3 has not landed, add those too, per EP-3's
Step 2.4):

```haskell
    MfaAssertionInvalid -> json err401 "mfa_failed" "Multi-factor authentication failed"
```

`err401` is already imported. The body stays generic (no leak of why the assertion failed).

**Step 2.5 — PostgreSQL event projection.** In
`shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs`, add three arms to
`projectAuthEvent`, mirroring the existing user-scoped events. `MfaChallenged`/`MfaSucceeded`
carry a `userId`; `MfaFailed` carries a `Maybe UserId`:

```haskell
    Event.MfaChallenged d@(Event.MfaChallengedData uid _ occ) ->
        (Just (userIdToUUID uid), Nothing, "mfa_challenged", toJSON d, occ)
    Event.MfaSucceeded d@(Event.MfaSucceededData uid sid occ) ->
        (Just (userIdToUUID uid), Just (sessionIdToUUID sid), "mfa_succeeded", toJSON d, occ)
    Event.MfaFailed d@(Event.MfaFailedData mUid _ occ) ->
        (fmap userIdToUUID mUid, Nothing, "mfa_failed", toJSON d, occ)
```

`projectAuthEvent` is a total `case`; adding these three keeps it exhaustive (otherwise
`-Wincomplete-patterns` flags the new constructors and the build is not clean). No new SQL or
migration — they land in the existing `shomei_auth_events` table.

**Step 2.6 — the in-process HTTP test.** Extend `shomei-servant/test/Main.hs`. Two parts:

First, the `runHybrid` runner must interpret the EP-1 `WebAuthnCeremony` fake and the EP-2
`PasskeyStore`/`PendingCeremonyStore` in-memory interpreters, in the same effect order EP-1/EP-2
use in `runInMemory`. Import them from `Shomei.Effect.InMemory`
(`runWebAuthnCeremony` / `runPasskeyStore` / `runPendingCeremonyStore` — names per EP-1/EP-2;
EP-1's fake may be `runWebAuthnCeremonyFake` — match the export) and slot them into the
composition between `runNotifier ref` and `runLoginAttemptStore ref` (PasskeyStore,
PendingCeremonyStore) and right after `runNotifier ref` (WebAuthnCeremony), so the textual
composition matches the canonical order
`… LoginAttemptStore, PasskeyStore, PendingCeremonyStore, Notifier, WebAuthnCeremony …`:

```haskell
runHybrid ref jwk jwkset cfg =
    runEff
        . runTokenGen ref
        . runClock ref
        . runSigningKeyStore ref
        . runAuthEventPublisher ref
        . runTokenVerifierJwt jwkset cfg
        . runTokenSignerJwt jwk cfg
        . runPasswordHasher ref
        . runWebAuthnCeremony ref      -- NEW (EP-1 fake)
        . runNotifier ref
        . runPendingCeremonyStore ref  -- NEW (EP-2)
        . runPasskeyStore ref          -- NEW (EP-2)
        . runLoginAttemptStore ref
        . runPasswordResetTokenStore ref
        . runVerificationTokenStore ref
        . runRefreshTokenStore ref
        . runSessionStore ref
        . runCredentialStore ref
        . runUserStore ref
```

(Verify the exact composition order against `Shomei.Effect.InMemory.runInMemory` — the type-list
position is the source of truth; a mismatch is a compile error. The block above follows the
canonical order EP-2 documents: PasskeyStore/PendingCeremonyStore between LoginAttemptStore and
Notifier, WebAuthnCeremony after Notifier.)

Second, add a scenario after the existing `refresh`/`jwks` block (it reuses `mgr`, `port`, and
the `email`/`password`). It must turn `mfaRequired` ON in the test config (the default already is
`True` per EP-1's `defaultWebAuthnConfig`, but assert it), enroll a passkey via the EP-3
endpoints, then prove the step-up:

```haskell
    -- (i) enroll a passkey for the logged-in user (EP-3 endpoints), using the fake-accepted blobs.
    (pbStatus, pbBody) <- postJSONAuth mgr port "/auth/passkeys/register/begin" (bearer access) (object [])
    pbStatus @?= 200
    pbresp <- must "passkey begin body" pbBody
    regCid <- must "reg ceremonyId" (dig ["ceremonyId"] pbresp >>= asText)
    let regComplete = object
            [ "ceremonyId" .= regCid
            , "credential" .= acceptedRegistration   -- the fake-accepted registration credential JSON
            , "label" .= ("Test Key" :: Text)
            ]
    (pcStatus, pcBody) <- postJSONAuth mgr port "/auth/passkeys/register/complete" (bearer access) regComplete
    pcStatus @?= 200
    credId <- must "enrolled credentialId" (dig ["credentialId"] <$> pcBody >>= id >>= asText)
    -- ^ if PasskeyResponse does not expose credentialId, read it from the seeded fixture instead.

    -- (j) log in with the password: now MFA is required, so NO token, status = mfa_required.
    (mlStatus, mlBody) <- postJSON mgr port "/auth/login" loginBody
    mlStatus @?= 200
    mlresp <- must "mfa login body" mlBody
    (dig ["status"] mlresp >>= asText) @?= Just "mfa_required"
    assertBool "no access token in mfa_required body" (isNothing (dig ["token"] mlresp))
    mfaCid <- must "mfa ceremonyId" (dig ["ceremonyId"] mlresp >>= asText)

    -- (k) complete MFA with a fake-accepted assertion -> token pair.
    let assertion = acceptedAssertion credId   -- assertion JSON the fake accepts for this credential
    (mcStatus, mcBody) <- postJSON mgr port "/auth/mfa/complete" (object ["ceremonyId" .= mfaCid, "assertion" .= assertion])
    mcStatus @?= 200
    mcresp <- must "mfa complete body" mcBody
    mfaAccess <- must "mfa accessToken" (dig ["accessToken"] mcresp >>= asText)

    -- (l) that access token works on /auth/me.
    (meMfaStatus, _) <- getJSON mgr port "/auth/me" (bearer mfaAccess)
    meMfaStatus @?= 200
```

Add the test helper `postJSONAuth` (POST with an Authorization header) if EP-3 has not already
added it (EP-3's Step 2.6 defines it); reuse EP-3's if present. `acceptedRegistration`/
`acceptedAssertion`/the `credId` plumbing depend on EP-1's fake contract: the fake accepts a
canned registration credential and an assertion carrying the matching challenge + credential id.
Define them once at the top of the scenario to match the fake. If `PasskeyResponse` does not
expose the credential id, capture the credential id from the same fixture the registration fake
consumed (the fake controls what credential id it mints), so `acceptedAssertion` can echo it.

**Acceptance for Milestone 2.** From the repo root:

```bash
nix develop --command cabal build all
nix develop --command cabal test all
```

both green; the servant HTTP scenario shows: passkey enroll begin/complete=200, password
login=200 with `"status":"mfa_required"` and no `token`, `/auth/mfa/complete`=200 with an
accessToken, and `/auth/me` with that token=200.

```text
Test suite shomei-servant-test: RUNNING...
HTTP end-to-end (in-memory interpreters + in-test ES256 key)
  signup → … → passkey enroll → login(mfa_required) → mfa/complete → me: OK
All 1 tests passed
Test suite shomei-servant-test: PASS
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop` (the project's GHC 9.12.4 toolchain).

### Step 0 — verify the EP-1/EP-2/EP-3 preconditions

```bash
nix develop --command bash -c '
  ls shomei-core/src/Shomei/Effect/WebAuthnCeremony.hs \
     shomei-core/src/Shomei/Effect/PasskeyStore.hs \
     shomei-core/src/Shomei/Effect/PendingCeremonyStore.hs \
     shomei-core/src/Shomei/Domain/Passkey.hs &&
  grep -nE "mfaRequired|pendingCeremonyTTL" shomei-core/src/Shomei/Config.hs &&
  grep -nE "WebAuthnCeremonyError|PasskeyNotFound|PendingCeremonyNotFound" shomei-core/src/Shomei/Error.hs &&
  grep -nE "WebAuthnCeremony|PasskeyStore|PendingCeremonyStore" shomei-servant/src/Shomei/Servant/Seam.hs
'
```

Expected: the four files exist, `Config` mentions `mfaRequired`/`pendingCeremonyTTL`, `Error`
mentions the three WebAuthn arms, and `Seam.AppEffects` lists the three new ports. If any is
missing, the corresponding prior plan is incomplete — finish it (or, for the `Error` arms only,
add them here and record it as a Surprise).

### Step 1 — Milestone 1 source (Plan of Work Steps 1.1–1.7), then:

```bash
nix develop --command cabal build shomei-core
nix develop --command cabal test shomei-core
```

Expected tail:

```text
  Shomei.Workflow.Mfa
    no-passkey login yields LoginComplete with a token:      OK
    passkey + mfaRequired login yields MfaRequired, no token: OK
    completeMfa with a valid assertion yields a token pair:   OK
    bogus/consumed ceremony is rejected:                      OK
All N tests passed
```

### Step 2 — Milestone 2 source (Steps 2.1–2.6), then:

```bash
nix develop --command cabal build all
nix develop --command cabal test all
```

Expected: both green; the servant suite's passkey/MFA scenario passes.

### Step 3 — (optional) live `curl` sketch against a running server

After `nix develop --command cabal run shomei-server` (config with a passkey-bearing account and
`mfaRequired = true`), shown for shape only (a real assertion is a genuine browser
`navigator.credentials.get()` payload, produced by EP-5's demo, not hand-written):

```bash
# Password login -> mfa_required (no token):
curl -s -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"ada@example.com","password":"…"}'
# -> {"status":"mfa_required","ceremonyId":"webauthn_ceremony_01j…","options":{"publicKey":{"challenge":"…","allowCredentials":[…]}}}

# Complete MFA (ASSERTION is the browser's navigator.credentials.get() output):
curl -s -X POST http://localhost:8080/auth/mfa/complete \
  -H "Content-Type: application/json" \
  -d '{"ceremonyId":"webauthn_ceremony_01j…","assertion":'"$ASSERTION"'}'
# -> {"accessToken":"eyJ…","refreshToken":"…","expiresIn":900}

# Passwordless begin -> options:
curl -s -X POST http://localhost:8080/auth/login/passkey/begin
# -> {"ceremonyId":"webauthn_ceremony_01j…","options":{"publicKey":{"challenge":"…","allowCredentials":[]}}}

# Passwordless complete:
curl -s -X POST http://localhost:8080/auth/login/passkey/complete \
  -H "Content-Type: application/json" \
  -d '{"ceremonyId":"webauthn_ceremony_01j…","assertion":'"$ASSERTION"'}'
# -> {"accessToken":"eyJ…","refreshToken":"…","expiresIn":900}
```


## Validation and Acceptance

Acceptance is observable behavior, not just compilation.

- **No-MFA login unchanged.** A user with no passkey (or with `mfaRequired = False`) posting
  correct credentials to `POST /auth/login` gets HTTP 200 with
  `{"status":"complete","user":{…},"token":{…}}` — a token they can use on `GET /auth/me`. This
  is the legacy behavior, now under the `"complete"` tag.
- **MFA step-up.** A user WITH a passkey and `mfaRequired = True` posting correct credentials to
  `POST /auth/login` gets HTTP 200 with `{"status":"mfa_required","ceremonyId":"…","options":{…}}`
  and **no `token` field**. The access token they need does not exist yet — proven by the test
  asserting `isNothing (dig ["token"] body)`.
- **MFA completion.** Posting `{"ceremonyId":"…","assertion":{…}}` with a valid assertion to
  `POST /auth/mfa/complete` returns HTTP 200 with `{"accessToken":…,"refreshToken":…,"expiresIn":…}`,
  and that access token authenticates `GET /auth/me` (200).
- **Ceremony hygiene.** A `POST /auth/mfa/complete` with a missing/expired/already-consumed
  ceremony id returns HTTP 404 (`{"error":"ceremony_not_found",…}` from EP-3's mapping of
  `PendingCeremonyNotFound`). A valid-shaped assertion that fails verification returns HTTP 401
  (`{"error":"mfa_failed",…}`). The body never leaks why.
- **Passwordless.** `POST /auth/login/passkey/begin` returns options + a ceremony id;
  `POST /auth/login/passkey/complete` with a valid discoverable assertion returns a token pair,
  resolving the account from the asserted credential id with no email/password.
- **Abuse protection preserved.** The per-IP throttle (429) and per-account lockout (generic 401)
  on `POST /auth/login` behave exactly as before; the MFA branch runs only after a fully
  successful password check, and a successful password records success + clears the lockout
  regardless of whether MFA then completes (Decision Log). A failed/abandoned MFA is recorded as
  the `mfa_failed` audit event, not a login-attempt failure.
- **Audit.** A step-up challenge writes `mfa_challenged`; a successful completion writes
  `mfa_succeeded` (+ the usual `login_succeeded`/`session_started` from `issueSession`); a failed
  assertion writes `mfa_failed`. In the in-memory test these are observable in the `World` event
  log; under PostgreSQL they appear in `shomei_auth_events` with those `event_type`s.
- **Tests.** `cabal test all` is green; the new `shomei-core` `MfaSpec` and the extended
  `shomei-servant` HTTP scenario both pass. They fail before the change (the module/routes do not
  exist; `login` returns the old tuple) and pass after — that delta is the proof beyond compiling.

The headline user-visible outcome: a password alone no longer grants a session for an account
with a passkey; the user must also prove possession of the passkey, and a passwordless passkey
login is available as an alternative.


## Idempotence and Recovery

Every edit is additive or a localized rewrite and may be re-applied safely:

- Adding `AuthEvent` arms, the `MfaAssertionInvalid` `AuthError`, the new DTOs/routes/handlers,
  and the event-projection arms is additive; re-running the steps re-states the same code. A
  partial edit may leave the build red (e.g. a non-exhaustive `projectAuthEvent` after adding the
  events but before mapping them, or `loginH` not yet updated after `login`'s type changed) —
  finish the remaining step in the same milestone to restore green. Implement Milestone 1 fully
  before Milestone 2.
- The `login` widening is the one breaking-type change. The recovery if the build breaks at a
  caller is mechanical: every `login` caller must match `LoginResult` (`LoginComplete user pair`
  for the no-MFA path). Enumerate callers with the grep in Step 1.7 and fix each. The known
  callers are: `Shomei.Servant.Handlers.loginH` (updated in M2), `shomei-core`'s `WorkflowSpec`
  (updated in M1 Step 1.7), and the `shomei-client` `login` (updated by **EP-5**, by path —
  `docs/plans/19-passkey-client-demo-and-documentation.md`; not this plan). If the
  `shomei-postgres`/`shomei-servant` tests also call `login`, the same grep finds them.
- The MFA `begin`/`complete` round-trip is safe to retry: each password `login` mints a fresh
  ceremony; abandoned ceremonies expire via the TTL (`takePendingCeremony` filters on expiry and
  is consume-once). A duplicate `complete` (double-submit) finds nothing and returns 404 — the
  correct, safe behavior. Passwordless `begin`/`complete` is the same.
- No migration is introduced (the events reuse the existing `shomei_auth_events` table), so there
  is nothing to roll back at the schema level.
- If EP-1/EP-2/EP-3 land with different names than the Consumed-contract section assumes, the
  recovery is mechanical: update the imports and that section, re-run `cabal build`, and record
  the rename in the Decision Log. The *logic* of the workflows does not change.


## Interfaces and Dependencies

This plan adds the module `Shomei.Workflow.Mfa` (in `shomei-core`), widens
`Shomei.Workflow.login`, adds `Shomei.Workflow.issueSession`, extends `Shomei.Domain.Event`,
`Shomei.Error`, `Shomei.Servant.API`, `Shomei.Servant.DTO`, `Shomei.Servant.Handlers`,
`Shomei.Servant.Error`, and `Shomei.Postgres.AuthEventPublisher`, and extends the `shomei-servant`
test. It introduces no new package and no new third-party dependency (it reuses `aeson`,
`effectful`, `servant`, `time`, `text`, `bytestring`, `uuid` already present). The
`shomei-webauthn` package and the `webauthn` library are pulled in transitively via the ports
EP-1/EP-2 already wired into the effect stacks; this plan does not depend on them directly.

### Types and functions that must exist at the end of each milestone

**End of M1 (`shomei-core`):**

```haskell
-- Shomei.Workflow
data MfaChallenge = MfaChallenge { ceremonyId :: CeremonyId, options :: Value }
data LoginResult = LoginComplete User TokenPair | MfaRequired MfaChallenge
issueSession ::
    ( SessionStore :> es, RefreshTokenStore :> es, TokenSigner :> es
    , AuthEventPublisher :> es, TokenGen :> es ) =>
    ShomeiConfig -> User -> UTCTime -> Eff es (SessionId, TokenPair)
login ::
    ( UserStore :> es, CredentialStore :> es, SessionStore :> es, RefreshTokenStore :> es
    , PasswordHasher :> es, TokenSigner :> es, AuthEventPublisher :> es
    , LoginAttemptStore :> es, PasskeyStore :> es, PendingCeremonyStore :> es
    , WebAuthnCeremony :> es, Clock :> es, TokenGen :> es ) =>
    ShomeiConfig -> ClientContext -> LoginCommand -> Eff es (Either AuthError LoginResult)

-- Shomei.Workflow.Mfa
completeMfa ::
    ( UserStore :> es, SessionStore :> es, RefreshTokenStore :> es, PasskeyStore :> es
    , PendingCeremonyStore :> es, WebAuthnCeremony :> es, TokenSigner :> es
    , AuthEventPublisher :> es, Clock :> es, TokenGen :> es ) =>
    ShomeiConfig -> CeremonyId -> Value -> Eff es (Either AuthError (User, TokenPair))
beginPasswordlessLogin ::
    ( PendingCeremonyStore :> es, WebAuthnCeremony :> es, Clock :> es, TokenGen :> es ) =>
    ShomeiConfig -> Eff es (Either AuthError (CeremonyId, Value))
completePasswordlessLogin ::
    ( UserStore :> es, SessionStore :> es, RefreshTokenStore :> es, PasskeyStore :> es
    , PendingCeremonyStore :> es, WebAuthnCeremony :> es, TokenSigner :> es
    , AuthEventPublisher :> es, Clock :> es, TokenGen :> es ) =>
    ShomeiConfig -> CeremonyId -> Value -> Eff es (Either AuthError (User, TokenPair))

-- Shomei.Domain.Event: + MfaChallenged/MfaSucceeded/MfaFailed (+ their *Data records)
-- Shomei.Error.AuthError: + MfaAssertionInvalid (+ EP-3's three WebAuthn arms if absent)
```

**End of M2 (`shomei-servant`, `shomei-postgres`):**

```haskell
-- Shomei.Servant.DTO
data LoginResponse = LoginCompleteResponse { user :: UserResponse, token :: TokenPairResponse }
                   | LoginMfaRequiredResponse { ceremonyId :: Text, options :: Value }
                   -- hand-written status-tagged ToJSON/FromJSON
data MfaCompleteRequest = MfaCompleteRequest { ceremonyId :: Text, assertion :: Value }
data PasskeyLoginBeginResponse = PasskeyLoginBeginResponse { ceremonyId :: Text, options :: Value }
data PasskeyLoginCompleteRequest = PasskeyLoginCompleteRequest { ceremonyId :: Text, assertion :: Value }
loginResultToResponse :: LoginResult -> LoginResponse

-- Shomei.Servant.API.ShomeiAPI: + mfaComplete, passkeyLoginBegin, passkeyLoginComplete
--   (POST /auth/mfa/complete, POST /auth/login/passkey/{begin,complete}); NO /auth/mfa/begin
-- Shomei.Servant.Handlers: loginH rewritten; + mfaCompleteH, passkeyLoginBeginH, passkeyLoginCompleteH
-- Shomei.Servant.Error: MfaAssertionInvalid -> 401 ("mfa_failed")
-- Shomei.Postgres.AuthEventPublisher: + mfa_challenged/mfa_succeeded/mfa_failed arms
```

### Consumed contract (from EP-1, EP-2, EP-3 — reproduced verbatim so this plan stands alone)

If the real types differ when you implement, update this section and the Decision Log.

```haskell
-- EP-1 (Shomei.Effect.WebAuthnCeremony): the ceremony port. This plan uses only the
-- authentication operations.
BeginAuthenticationCeremony
    :: [WebAuthnCredentialId] -> WebAuthnCeremony m BeginCeremony   -- [] = passwordless discovery
CompleteAuthenticationCeremony
    :: ByteString -> StoredCredentialForVerify -> Value
    -> WebAuthnCeremony m (Either WebAuthnError VerifiedAuthentication)
beginAuthenticationCeremony    :: (WebAuthnCeremony :> es) => [WebAuthnCredentialId] -> Eff es BeginCeremony
completeAuthenticationCeremony :: (WebAuthnCeremony :> es) => ByteString -> StoredCredentialForVerify -> Value
                                  -> Eff es (Either WebAuthnError VerifiedAuthentication)
data BeginCeremony = BeginCeremony { optionsJson :: Value, optionsBlob :: ByteString }
data StoredCredentialForVerify = StoredCredentialForVerify
    { credentialId :: WebAuthnCredentialId, userHandle :: UserHandle
    , publicKey :: PublicKeyBytes, signCounter :: SignatureCounter, transports :: [Text] }
data VerifiedAuthentication = VerifiedAuthentication
    { credentialId :: WebAuthnCredentialId, newSignCounter :: SignatureCounter, cloneWarning :: Bool }
data WebAuthnError = …   -- derives Generic/Eq/Show/FromJSON/ToJSON

-- EP-1 (Shomei.Domain.Passkey): the domain types and the pending-ceremony record.
newtype WebAuthnCredentialId = WebAuthnCredentialId ByteString   -- JSON via base64url text
data CeremonyKind = RegistrationCeremony | AuthenticationCeremony
data PasskeyCredential = PasskeyCredential
    { passkeyId :: PasskeyId, userId :: UserId, credentialId :: WebAuthnCredentialId
    , userHandle :: UserHandle, publicKey :: PublicKeyBytes, signCounter :: SignatureCounter
    , transports :: [Text], label :: Maybe Text, createdAt :: UTCTime, lastUsedAt :: Maybe UTCTime }
data PendingCeremony = PendingCeremony
    { ceremonyId :: CeremonyId, userId :: Maybe UserId, kind :: CeremonyKind
    , optionsBlob :: ByteString, createdAt :: UTCTime, expiresAt :: UTCTime }

-- EP-1 (Shomei.Id): the ceremony id + generator.
type CeremonyId = KindID "webauthn_ceremony"
genCeremonyId :: MonadIO m => m CeremonyId     -- (or a WebAuthnCeremony port op; match EP-1)

-- EP-1 (Shomei.Config): the WebAuthn config sub-record this plan reads.
data WebAuthnConfig = WebAuthnConfig { …, pendingCeremonyTTL :: NominalDiffTime, mfaRequired :: Bool }
-- ShomeiConfig gains `webauthnConfig :: WebAuthnConfig`.

-- EP-2 (Shomei.Effect.PasskeyStore): the persistence port. This plan uses these ops.
findPasskeysByUser        :: (PasskeyStore :> es) => UserId -> Eff es [PasskeyCredential]
findPasskeyByCredentialId :: (PasskeyStore :> es) => WebAuthnCredentialId -> Eff es (Maybe PasskeyCredential)
updatePasskeySignCounter  :: (PasskeyStore :> es) => PasskeyId -> SignatureCounter -> UTCTime -> Eff es ()
countPasskeysByUser       :: (PasskeyStore :> es) => UserId -> Eff es Int

-- EP-2 (Shomei.Effect.PendingCeremonyStore): the consume-once challenge store.
putPendingCeremony  :: (PendingCeremonyStore :> es) => PendingCeremony -> Eff es ()
takePendingCeremony :: (PendingCeremonyStore :> es) => CeremonyId -> UTCTime -> Eff es (Maybe PendingCeremony)

-- EP-3 (Shomei.Error.AuthError): the three WebAuthn arms this plan reuses.
--   WebAuthnCeremonyError WebAuthnError   -- 400
--   PasskeyNotFound                       -- 404
--   PendingCeremonyNotFound               -- 404
-- EP-3 also owns userHandleForUser (UserId -> UserHandle), used by enrollment; this plan
-- resolves users by credential id, not by reversing the handle.
```

### Libraries and modules used, and why

- **`effectful`** — the effect system; `login` and the MFA workflows are written purely against
  ports and run unchanged over the in-memory and PostgreSQL+webauthn interpreter assemblies.
- **`aeson` (`Value`, `object`, `withObject`, `Parser`)** — the assertion/options JSON crosses
  the API and port boundary verbatim; the hand-written `LoginResponse` instances switch on the
  `status` tag.
- **`servant`** — the three new routes are plain `ReqBody`/`Post` fields on `ShomeiAPI`; the
  completion endpoints are unauthenticated (proving the factor IS how a session is obtained).
- **`Shomei.Workflow.issueSession`** — the single shared token-issuing tail; `login`,
  `completeMfa`, and `completePasswordlessLogin` all call it so the four (counting `signup`,
  which keeps its own copy for a minimal diff) token-mint sites cannot drift.
- **EP-1 `WebAuthnCeremony`, EP-2 `PasskeyStore`/`PendingCeremonyStore`** — already present in
  every effect-stack list (EP-1/EP-2 wired them); this plan only *uses* them, adding no port.

### Callers of `login` that this plan (or EP-5) must update — enumerated

1. **`Shomei.Servant.Handlers.loginH`** — rewritten in M2 Step 2.3 to map `LoginResult` →
   `LoginResponse` via `loginResultToResponse`.
2. **`shomei-core/test/Shomei/WorkflowSpec.hs`** — updated in M1 Step 1.7 to match
   `LoginComplete user pair`.
3. **Any `shomei-postgres`/`shomei-servant` test that calls `login`** — found via the Step 1.7
   grep; update each to match `LoginComplete` (or to drive `completeMfa` if it sets up a passkey).
4. **`shomei-client`'s `login`** — updated by **EP-5**
   (`docs/plans/19-passkey-client-demo-and-documentation.md`), NOT this plan. Referenced here by
   path so EP-5's client decoder matches the widened `LoginResponse` wire shape.
