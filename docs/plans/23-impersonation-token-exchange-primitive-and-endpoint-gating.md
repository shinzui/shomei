---
id: 23
slug: impersonation-token-exchange-primitive-and-endpoint-gating
title: "Impersonation token-exchange primitive and endpoint gating"
kind: exec-plan
created_at: 2026-06-17T18:37:42Z
intention: "intention_01kvbdq6zjeqpsgprn8pjz12xk"
---

# Impersonation token-exchange primitive and endpoint gating

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei is a Haskell authentication toolkit. It proves *who you are*: it verifies passwords
and passkeys, starts sessions, rotates refresh tokens, and signs JSON Web Tokens (JWTs — the
signed bearer credentials clients send on every request). Today every token Shōmei mints says
exactly one thing: "the bearer is user X." There is no way for an authorized internal operator
(a support agent) to act *on behalf of* a customer while keeping their own identity attached.

This plan adds the **authentication-layer slice** of user impersonation: a *token-exchange*
endpoint that mints a short-lived **delegated session** for a target customer, where the signed
token carries **two identities at once** — the customer being acted upon (the "subject") and the
real operator performing the action (the "actor"). After this change:

- An authenticated caller who holds the `impersonate:user` scope (a permission string carried in
  their token) and whose own login is *recent* can POST to `/auth/impersonate` with a target user
  id, a required `reason`, and an optional support `ticketId`, and receive back a short-lived
  access token whose `sub` claim is the target customer and whose `act` claim names the operator.
- That delegated token is a brand-new dedicated session row, never a copy or reuse of the
  customer's own session, and it carries **no refresh token**, so it cannot be silently renewed
  and expires quickly.
- Shōmei's own credential-changing endpoints (password change, passkey enrollment, passkey
  removal) **refuse** any request bearing a delegated token, returning HTTP 403 and writing an
  audit record. An operator can look but cannot change the customer's credentials.
- Every start, stop, and blocked action is written to Shōmei's existing audit-event log with
  **both** the actor and subject user ids, the reason, the ticket id, and the client IP.

What this plan deliberately does **not** include, because those concerns belong to the services
that embed Shōmei rather than to the authentication toolkit itself: the policy of *who may
impersonate whom* (e.g. "you may not impersonate another admin"), the support console UI and its
"Impersonating Jane Smith" banner, the capture/validation of ticket workflows, and the blocking
of *business* actions (billing changes, data export, sending messages) that live in other
microservices. Shōmei supplies the verifiable two-identity token and gates only its own
endpoints; downstream services read the `act`/`sub` claims out of the token and enforce the rest.

You can see the whole thing working at the end via an HTTP transcript: log in as an operator,
exchange for a delegated token, call `/auth/me` and observe the customer's identity with the
operator recorded as actor, attempt a password change and observe a 403, stop the impersonation,
and read the audit log showing `impersonation_started`, `impersonation_action_blocked`, and
`impersonation_stopped` rows each carrying both user ids.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `actor :: Maybe UserId` to `AuthClaims`; encode/decode the `act` JWT claim; round-trip test passes. (done 2026-06-17)
- [x] M2: Add `actor :: Maybe UserId` to `Session`/`NewSession`; add `actor_user_id` column migration; update Postgres + in-memory session stores; store/load test passes. (done 2026-06-17)
- [ ] M3: Add `ImpersonationConfig` to `ShomeiConfig`; add `AuthError` constructors; add `AuthEvent` constructors; implement `Shomei.Workflow.Impersonation` (`startImpersonation`, `stopImpersonation`); core spec passes.
- [ ] M4: Add Servant DTOs, the `impersonate` + `stopImpersonate` routes, handlers, error mappings, and the `denyUnderImpersonation` gate on password-change + passkey handlers; project new events in the Postgres publisher; servant/integration tests pass.
- [ ] M5: End-to-end HTTP validation transcript captured; `docs/security.md` and `docs/api.md` updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- M2: The migration SQL files are embedded into `Shomei.Migrations` at **compile time** via a
  `embedDir "sql-migrations"` Template Haskell splice. Adding a new `.sql` file does not take
  effect until that module recompiles. Touching the source (a note comment, per the module's
  existing convention) forces the rebuild; without it the ephemeral-DB test harness applied only
  the 14 previously-embedded migrations and the new `actor_user_id` column was missing, surfacing
  as `column "actor_user_id" ... does not exist` (Postgres SQLSTATE 42703) on every session insert.
  Date: 2026-06-17


## Decision Log

Record every decision made while working on the plan.

- Decision: Scope this plan to the Shōmei authentication layer only (token-exchange primitive,
  its own endpoint gating, and audit events). Exclude who-may-impersonate-whom policy, the
  support UI/banner, ticket workflows, and cross-service business-action blocking.
  Rationale: Those concerns require a model of customer business data, an admin org, and a
  product UI that Shōmei deliberately does not have (`docs/initial-spec.md` lists "Full
  authorization policy engine", "Admin UI", "Organization/team management" as out of scope).
  Only the place that mints and verifies tokens can guarantee the two-identity invariant and
  refuse credential changes, so that is exactly what lives here. The broader cross-service
  feature is a master-plan-level initiative tracked outside this repository.
  Date: 2026-06-17

- Decision: Represent the second identity as an `actor :: Maybe UserId` field on `AuthClaims`,
  serialized as a JWT custom claim named `act`, mirroring RFC 8693 (OAuth 2.0 Token Exchange),
  whose actor-claim convention is `act`.
  Rationale: `AuthClaims` already extends the JWT with custom claims (`sid`, `scopes`, `roles`)
  via `addClaim`/`unregisteredClaims`, so adding one more is the established pattern. `Maybe`
  keeps every existing non-impersonation token byte-identical (the claim is simply absent),
  so no existing test or consumer changes behavior.
  Date: 2026-06-17

- Decision: A delegated (impersonation) token gets a **dedicated new session row** with the
  `actor_user_id` column set, a short TTL, and **no refresh token**.
  Rationale: The source spec's non-goals say "do not create a normal login session for the
  target" and "do not reuse/mint a normal session." A distinct, separately-revocable, refresh-less
  session row honors that while keeping session lookup working (the token's `sid` still resolves
  in `shomei.shomei_sessions`, so `/auth/me` and `/auth/session` continue to function). Omitting
  the refresh token means the delegated session cannot be silently renewed and dies at its TTL.
  Date: 2026-06-17

- Decision: Keep `reason` and `ticketId` out of the `Session` domain type / sessions table; record
  them only in the `impersonation_started` audit-event payload.
  Rationale: Reason and ticket id are support metadata, not authentication state. The audit log
  (the `shomei.shomei_auth_events` table) is the correct system of record for "why did this
  happen"; the session type stays minimal (it gains only the `actor` link).
  Date: 2026-06-17

- Decision: "Recent login or MFA re-authentication" is enforced as a **freshness window**: the
  caller's presented access token must have been issued within `actorFreshnessWindow` (default 5
  minutes) of the current time. A true interactive MFA step-up re-prompt is NOT built here.
  Rationale: Shōmei has no general step-up primitive today (MFA is bound to the login path, per
  `shomei-core/src/Shomei/Workflow/Mfa.hs`). The access token already carries `issuedAt`, so a
  freshness check is implementable now, satisfies the spirit of the requirement, and leaves a
  clear extension point. Recorded as a known limitation in the Validation section.
  Date: 2026-06-17

- Decision: Shōmei validates the target only as "exists, is active, and is not the caller
  themselves." It does NOT implement the "target must not be another admin" rule.
  Rationale: Shōmei has no per-user role store surfaced to workflows (roles in `AuthClaims` are
  empty in the current MVP, set by `issueSession`), so it cannot reliably know a target's roles.
  Who-may-impersonate-whom is authorization policy and belongs to the embedding service. This is
  consistent with the scope decision above.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project. A "package" is a unit with its own `.cabal`
build file. The packages relevant to this plan, with their full paths and roles:

- `shomei-core/` — transport-agnostic domain. Pure types, commands, events, errors, and *effect
  interfaces* called "ports." It has no web/database/JWT dependencies. An "effect" here is a typed
  capability (using the `effectful` library) such as "I can store sessions" (`SessionStore`) or "I
  can publish an audit event" (`AuthEventPublisher`); a "port" is the abstract declaration of one,
  and an "interpreter" is a concrete implementation (in-memory for tests, Postgres for production).
- `shomei-jwt/` — turns `AuthClaims` (the domain's description of a token's contents) into a signed
  JWT string and back. Depends on `shomei-core`.
- `shomei-postgres/` — PostgreSQL interpreters of the core ports (session store, audit-event
  publisher, etc.) using the `hasql` library. Depends on `shomei-core` and `shomei-migrations`.
- `shomei-migrations/` — SQL schema migrations managed by the `codd` tool. Each migration is a
  `.sql` file in `shomei-migrations/sql-migrations/`.
- `shomei-servant/` — the HTTP layer: route declarations (`ShomeiAPI`), auth combinators, request
  handlers, request/response DTOs (data-transfer objects: the JSON wire shapes), and error mapping.

The exact existing definitions you will extend (verified against the working tree):

**JWT claims** live in `shomei-core/src/Shomei/Domain/Claims.hs`:

```haskell
data AuthClaims = AuthClaims
    { subject :: !UserId
    , sessionId :: !SessionId
    , issuer :: !Issuer
    , audience :: !Audience
    , issuedAt :: !UTCTime
    , expiresAt :: !UTCTime
    , scopes :: !(Set Scope)
    , roles :: !(Set Role)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
```

`Scope` and `Role` in the same file are `newtype`s over `Text`. `UserId`/`SessionId` are id
newtypes elsewhere in the domain; `idText :: UserId -> Text` renders one and `parseId :: Text ->
Either e UserId` parses one (these are the helpers used in the JWT encode/decode below).

**JWT encode** is in `shomei-jwt/src/Shomei/Jwt/Sign.hs`, function `claimsFromAuth`:

```haskell
claimsFromAuth :: AuthClaims -> ClaimsSet
claimsFromAuth ac =
    emptyClaimsSet
        & claimIss ?~ sou (issuerText ac.issuer)
        & claimSub ?~ sou (idText ac.subject)
        & claimAud ?~ Audience [sou (audienceText ac.audience)]
        & claimIat ?~ NumericDate ac.issuedAt
        & claimExp ?~ NumericDate ac.expiresAt
        & addClaim "sid" (Aeson.String (idText ac.sessionId))
        & addClaim "scopes" (Aeson.toJSON (Set.toList ac.scopes))
        & addClaim "roles" (Aeson.toJSON (Set.toList ac.roles))
```

**JWT decode** is in `shomei-jwt/src/Shomei/Jwt/Verify.hs`, function `claimsToAuth`, which reads
custom claims out of the verified claim set via the `unregisteredClaims` lens and helpers
`lookupString`/`lookupStringList`. You will add a `lookupString "act"` read there.

**Session** is in `shomei-core/src/Shomei/Domain/Session.hs`:

```haskell
data Session = Session
    { sessionId :: !SessionId
    , userId :: !UserId
    , status :: !SessionStatus
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    , revokedAt :: !(Maybe UTCTime)
    }

data NewSession = NewSession
    { userId :: !UserId
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    }
```

The `SessionStore` port is in `shomei-core/src/Shomei/Effect/SessionStore.hs`:

```haskell
data SessionStore :: Effect where
    CreateSession :: NewSession -> SessionStore m Session
    FindSessionById :: SessionId -> SessionStore m (Maybe Session)
    RevokeSession :: SessionId -> UTCTime -> SessionStore m ()
    RevokeAllUserSessions :: UserId -> UTCTime -> SessionStore m ()
```

Its Postgres interpreter is `shomei-postgres/src/Shomei/Postgres/SessionStore.hs` (rows are
`(UUID, UUID, Text, UTCTime, UTCTime, Maybe UTCTime)` via `hasql`'s `contrazip6`), and the
in-memory interpreter is in `shomei-core/src/Shomei/Effect/InMemory.hs`. The session table is
defined in `shomei-migrations/sql-migrations/2026-06-03-00-00-03-shomei-sessions.sql`.

**The shared token-minting tail** is `issueSession` in `shomei-core/src/Shomei/Workflow/Session.hs`.
It creates a session, creates a refresh token, signs an access token via `buildClaims`, and
publishes `LoginSucceeded` + `SessionStarted`. The impersonation workflow will be a *parallel*
function (it deliberately does NOT call `issueSession`, because it must skip the refresh token and
the login events and instead set the `actor`). `buildClaims` for reference:

```haskell
buildClaims :: ShomeiConfig -> UserId -> SessionId -> UTCTime -> AuthClaims
buildClaims cfg uid sid ts =
    AuthClaims
        { subject = uid
        , sessionId = sid
        , issuer = cfg.issuer
        , audience = cfg.audience
        , issuedAt = ts
        , expiresAt = addUTCTime cfg.accessTokenTTL ts
        , scopes = Set.empty
        , roles = Set.empty
        }
```

**Domain events** are the sum type `AuthEvent` in `shomei-core/src/Shomei/Domain/Event.hs`; each
constructor wraps a `*Data` record (e.g. `MfaSucceededData { userId, sessionId, occurredAt }`).
Events are published with `publishAuthEvent :: AuthEvent -> Eff es ()` (port in
`shomei-core/src/Shomei/Effect/AuthEventPublisher.hs`). The Postgres publisher
`shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs` maps each event to the tuple
`(Maybe UUID userId, Maybe UUID sessionId, Text eventType, Value payload, UTCTime)` in
`projectAuthEvent` and inserts it into `shomei.shomei_auth_events`.

**Errors** are the sum type `AuthError` in `shomei-core/src/Shomei/Error.hs`.

**HTTP routes** are the record `ShomeiAPI` in `shomei-servant/src/Shomei/Servant/API.hs`. An
authenticated route uses the `Authenticated` combinator (`= AuthProtect "shomei-jwt"`), which
injects an `AuthUser` value as the handler's leading argument:

```haskell
data AuthUser = AuthUser
    { authUserId :: !UserId
    , authSessionId :: !SessionId
    , authRoles :: !(Set Role)
    , authScopes :: !(Set Scope)
    , authClaims :: !AuthClaims
    }
```

(`AuthUser` is in `shomei-servant/src/Shomei/Servant/Auth.hs`; `requireScope :: Scope -> AuthUser
-> Handler ()` is in `shomei-servant/src/Shomei/Servant/Authz.hs`.) Handlers are assembled in
`shomei-servant/src/Shomei/Servant/Handlers.hs`; they call core workflows through `runAuth env
workflow` (which maps `Left AuthError` to a `ServerError`) or `runPort env action` (plain). DTOs
are in `shomei-servant/src/Shomei/Servant/DTO.hs`; error mapping is `authErrorToServerError` in
`shomei-servant/src/Shomei/Servant/Error.hs`. The fixed effect stack `AppEffects` is in
`shomei-servant/src/Shomei/Servant/Seam.hs`.

**Config** is `ShomeiConfig` in `shomei-core/src/Shomei/Config.hs`, built by
`defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig`. Sub-records such as `WebAuthnConfig`
are the pattern to copy for a new `ImpersonationConfig`.


## Plan of Work

The work proceeds bottom-up: first the token can carry two identities (M1), then sessions can
record an actor (M2), then the core workflow ties policy + minting + auditing together (M3), then
the HTTP surface exposes and gates it (M4), then we prove the whole thing end-to-end (M5). Each
milestone compiles and its tests pass before the next begins.

### Milestone M1 — `act` claim round-trips through the JWT

Scope: teach `AuthClaims` and the JWT encoder/decoder about a second identity. At the end, an
`AuthClaims` value with `actor = Just someUserId` signs to a JWT carrying an `act` claim and
verifies back to an equal value, while `actor = Nothing` produces a byte-identical token to today.

Edits:

1. In `shomei-core/src/Shomei/Domain/Claims.hs`, add a field to `AuthClaims`:
   `, actor :: !(Maybe UserId)`. Place it after `roles`. Because the record derives `FromJSON`/
   `ToJSON` via `Generic`, and `Maybe` fields encode as absent/`null`, this is backward compatible.
2. Every place that *constructs* `AuthClaims` must now set `actor`. The only constructor today is
   `buildClaims` in `shomei-core/src/Shomei/Workflow/Session.hs`; set `actor = Nothing` there.
   Search the whole tree for `AuthClaims` record construction to catch test fixtures too:
   `rg -n "AuthClaims" --type haskell`. Set `actor = Nothing` in each non-impersonation site.
3. In `shomei-jwt/src/Shomei/Jwt/Sign.hs`, in `claimsFromAuth`, conditionally add the claim:
   when `ac.actor` is `Just uid`, append `& addClaim "act" (Aeson.String (idText uid))`; when
   `Nothing`, add nothing. Implement with a `case`/helper so the `Nothing` path leaves the claim
   set untouched (preserving byte-compatibility).
4. In `shomei-jwt/src/Shomei/Jwt/Verify.hs`, in `claimsToAuth`, read it back:
   `let actor' = parseId <$> lookupString "act"` then fold a parse failure into `Left
   TokenMalformed` and a missing claim into `Nothing`; set `actor = actor'` in the returned record.
5. Add a round-trip test. The jwt package has a test suite — find it with `rg -n "Sign|Verify"
   shomei-jwt/test 2>/dev/null` or inspect `shomei-jwt/*.cabal` `test-suite` stanza. Add a case:
   build `AuthClaims` with `actor = Just u`, sign with a generated JWK, verify, assert equality;
   and a case with `actor = Nothing` asserting the decoded value also has `actor = Nothing`.

Acceptance: `cabal test shomei-jwt` passes, including the new round-trip cases.

### Milestone M2 — sessions can record an actor

Scope: a session row can carry the operator's id. At the end, `createSession` accepts an optional
actor, the Postgres and in-memory stores persist and return it, and a migration adds the column.

Edits:

1. In `shomei-core/src/Shomei/Domain/Session.hs`, add `, actor :: !(Maybe UserId)` to both
   `Session` and `NewSession`.
2. Update every `NewSession`/`Session` construction site (`rg -n "NewSession|Session \{" --type
   haskell`). The main one is `issueSession` in `Workflow/Session.hs`: set `actor = Nothing` for
   normal logins. The Postgres store's `mkSession` helper and in-memory store likewise.
3. New migration file
   `shomei-migrations/sql-migrations/2026-06-17-00-00-00-shomei-sessions-actor.sql`:

   ```sql
   -- codd: in-txn

   SET search_path TO shomei, pg_catalog;

   ALTER TABLE shomei_sessions
     ADD COLUMN IF NOT EXISTS actor_user_id uuid NULL REFERENCES shomei_users(user_id);

   CREATE INDEX IF NOT EXISTS shomei_sessions_actor_user_id_idx
     ON shomei_sessions (actor_user_id);
   ```

   (`IF NOT EXISTS` keeps it idempotent; `codd` records applied migrations, so re-running `codd up`
   is also safe.)
4. In `shomei-postgres/src/Shomei/Postgres/SessionStore.hs`: widen the row tuple from 6 to 7 fields
   to include `actor_user_id` (`Maybe UUID`); update `insertSessionStmt` SQL column list + `VALUES`
   + `contrazip6` → `contrazip7`; update `findSessionByIdStmt` SELECT list and `sessionRowDecoder`
   to read the new nullable column; map it to/from `Maybe UserId` (use the existing
   `userIdToUUID`/`uuidToUserId` helpers).
5. In `shomei-core/src/Shomei/Effect/InMemory.hs`, carry `actor` through the in-memory `CreateSession`
   so tests see the same value back.
6. Add/extend a store test asserting that creating a session with `actor = Just op` and finding it
   by id returns `actor = Just op`, and that `actor = Nothing` round-trips as `Nothing`. The
   Postgres tests use the `ephemeral-pg` test-support sublibrary in `shomei-migrations`; follow the
   existing session-store test pattern (`rg -n "findSessionById|CreateSession" shomei-postgres/test`).

Acceptance: `cabal test shomei-postgres` passes; the new migration applies cleanly against a fresh
ephemeral database (the test harness runs migrations on startup).

### Milestone M3 — core impersonation workflow

Scope: the pure-domain heart. At the end there is `Shomei.Workflow.Impersonation` exposing
`startImpersonation` and `stopImpersonation`, plus the config, error, and event vocabulary they
need, all exercised by an in-memory spec that needs no database or HTTP.

Edits:

1. Config — in `shomei-core/src/Shomei/Config.hs`, add a sub-record and wire it in:

   ```haskell
   data ImpersonationConfig = ImpersonationConfig
       { impersonateScope :: !Scope
       -- ^ scope a caller must hold to start impersonation; default @impersonate:user@
       , impersonationSessionTTL :: !NominalDiffTime
       -- ^ lifetime of the delegated session/token; default 30 minutes
       , actorFreshnessWindow :: !NominalDiffTime
       -- ^ caller's own access token must have been issued within this window; default 5 minutes
       }
       deriving stock (Generic, Eq, Show)
       deriving anyclass (FromJSON, ToJSON)
   ```

   Add `, impersonationConfig :: !ImpersonationConfig` to `ShomeiConfig`, a
   `defaultImpersonationConfig` (scope `Scope "impersonate:user"`, TTL `30 * 60`, window `5 * 60`),
   and set `impersonationConfig = defaultImpersonationConfig` in `defaultShomeiConfig`.

2. Errors — in `shomei-core/src/Shomei/Error.hs`, add to `AuthError`:
   `| ImpersonationForbidden` (caller lacks scope or is not fresh enough),
   `| ImpersonationTargetInvalid` (target missing, not active, or equals the caller),
   `| ImpersonationActionBlocked` (a credential-changing action attempted under a delegated token).

3. Events — in `shomei-core/src/Shomei/Domain/Event.hs`, add three constructors and their `*Data`
   records:

   ```haskell
   data ImpersonationStartedData = ImpersonationStartedData
       { actorUserId :: !UserId
       , subjectUserId :: !UserId
       , sessionId :: !SessionId
       , reason :: !Text
       , ticketId :: !(Maybe Text)
       , clientIp :: !(Maybe Text)
       , occurredAt :: !UTCTime
       }
       deriving stock (Generic, Eq, Show)
       deriving anyclass (FromJSON, ToJSON)

   data ImpersonationStoppedData = ImpersonationStoppedData
       { actorUserId :: !UserId
       , subjectUserId :: !UserId
       , sessionId :: !SessionId
       , occurredAt :: !UTCTime
       }
       deriving stock (Generic, Eq, Show)
       deriving anyclass (FromJSON, ToJSON)

   data ImpersonationActionBlockedData = ImpersonationActionBlockedData
       { actorUserId :: !UserId
       , subjectUserId :: !UserId
       , sessionId :: !SessionId
       , action :: !Text   -- e.g. "password_change", "passkey_register"
       , occurredAt :: !UTCTime
       }
       deriving stock (Generic, Eq, Show)
       deriving anyclass (FromJSON, ToJSON)
   ```

   Add `ImpersonationStarted ImpersonationStartedData`, `ImpersonationStopped
   ImpersonationStoppedData`, `ImpersonationActionBlocked ImpersonationActionBlockedData` to the
   `AuthEvent` sum.

4. New module `shomei-core/src/Shomei/Workflow/Impersonation.hs` (add it to the `exposed-modules`
   list in `shomei-core/shomei-core.cabal`). It exposes a command record and two functions:

   ```haskell
   data StartImpersonation = StartImpersonation
       { actorClaims :: !AuthClaims   -- the caller's verified token contents
       , targetUserId :: !UserId
       , reason :: !Text
       , ticketId :: !(Maybe Text)
       , clientIp :: !(Maybe Text)
       }

   startImpersonation ::
       ( UserStore :> es
       , SessionStore :> es
       , TokenSigner :> es
       , AuthEventPublisher :> es
       , Clock :> es
       ) =>
       ShomeiConfig ->
       StartImpersonation ->
       Eff es (Either AuthError (Session, AccessToken))

   stopImpersonation ::
       ( SessionStore :> es
       , AuthEventPublisher :> es
       , Clock :> es
       ) =>
       AuthClaims ->            -- the delegated token's claims (carries actor + subject + sid)
       Eff es (Either AuthError ())
   ```

   `startImpersonation` logic, in order (use `runErrorNoCallStack`/`Either` like
   `Account.changePassword`):
   - `now <- currentTime` (the `Clock` port).
   - **Scope check**: if `cfg.impersonationConfig.impersonateScope` is not in
     `actorClaims.scopes`, return `Left ImpersonationForbidden`.
   - **Freshness check**: if `now` is later than `actorClaims.issuedAt` plus
     `cfg.impersonationConfig.actorFreshnessWindow`, return `Left ImpersonationForbidden`.
   - **Self check**: if `targetUserId == actorClaims.subject`, return `Left
     ImpersonationTargetInvalid`.
   - **Target check**: `findUserById targetUserId`; if absent or its status is not active
     (`UserActive`), return `Left ImpersonationTargetInvalid`. (Use the `UserStore` lookup; confirm
     its exact name with `rg -n "FindUserById|findUserById" shomei-core/src`.)
   - **Mint**: `createSession NewSession{ userId = targetUserId, actor = Just actorClaims.subject,
     createdAt = now, expiresAt = addUTCTime cfg.impersonationConfig.impersonationSessionTTL now }`.
     Build `AuthClaims{ subject = targetUserId, sessionId = newSession.sessionId, ...issuer/
     audience from cfg..., issuedAt = now, expiresAt = addUTCTime impersonationSessionTTL now,
     scopes = Set.empty, roles = Set.empty, actor = Just actorClaims.subject }` and
     `signAccessToken` it. **No refresh token is created.**
   - **Audit**: `publishAuthEvent (ImpersonationStarted (ImpersonationStartedData{ actorUserId =
     actorClaims.subject, subjectUserId = targetUserId, sessionId = newSession.sessionId, reason,
     ticketId, clientIp, occurredAt = now }))`.
   - Return `Right (newSession, accessToken)`.

   `stopImpersonation` logic: read `subject = claims.subject`, `actor = claims.actor` (must be
   `Just`; if `Nothing` the token is not a delegated token → `Left ImpersonationActionBlocked` is
   wrong here, return `Left ImpersonationTargetInvalid` or a dedicated error — see step), `sid =
   claims.sessionId`. `revokeSession sid now`. Publish `ImpersonationStopped`. Return `Right ()`.
   (Because the token has no refresh token, revoking the session is sufficient to end it.)

5. Core spec — add `shomei-core/test/Shomei/Workflow/ImpersonationSpec.hs` (register it in the test
   suite's `other-modules` in `shomei-core.cabal` and import it in `shomei-core/test/Main.hs`,
   following how `Shomei.Workflow.MfaSpec` is wired). Using the in-memory interpreters, assert:
   - happy path: a fresh caller with the `impersonate:user` scope impersonating an active target
     gets `Right`, the returned session has `actor = Just caller`, the returned token decodes (via
     the jwt verifier or by inspecting the built claims) with `subject = target` and `actor = Just
     caller`, no refresh token row exists for that session, and an `ImpersonationStarted` event was
     published carrying both ids + the reason;
   - missing scope → `Left ImpersonationForbidden`;
   - stale caller (issuedAt older than the freshness window) → `Left ImpersonationForbidden`;
   - target equals caller → `Left ImpersonationTargetInvalid`;
   - unknown / inactive target → `Left ImpersonationTargetInvalid`;
   - `stopImpersonation` revokes the delegated session and publishes `ImpersonationStopped`.

Acceptance: `cabal test shomei-core` passes including `ImpersonationSpec`.

### Milestone M4 — HTTP endpoints, gating, and audit projection

Scope: expose the workflow over HTTP, gate Shōmei's own credential endpoints against delegated
tokens, and persist the new events. At the end the routes exist, behave, and write audit rows.

Edits:

1. DTOs — in `shomei-servant/src/Shomei/Servant/DTO.hs`:

   ```haskell
   data ImpersonateRequest = ImpersonateRequest
       { userId :: !Text
       , reason :: !Text
       , ticketId :: !(Maybe Text)
       }
       deriving stock (Generic)
       deriving anyclass (FromJSON, ToJSON)

   data ImpersonateResponse = ImpersonateResponse
       { accessToken :: !Text
       , subjectUserId :: !Text
       , actorUserId :: !Text
       , expiresAt :: !Text   -- iso8601
       }
       deriving stock (Generic)
       deriving anyclass (FromJSON, ToJSON)
   ```

2. Routes — in `shomei-servant/src/Shomei/Servant/API.hs`, add two fields to `ShomeiAPI`:

   ```haskell
   , impersonate ::
       mode :- "auth" :> "impersonate" :> Authenticated :> RemoteHost
           :> ReqBody '[JSON] ImpersonateRequest :> Post '[JSON] ImpersonateResponse
   , stopImpersonate ::
       mode :- "auth" :> "impersonate" :> Authenticated :> DeleteNoContent
   ```

   (`RemoteHost` injects the peer `SockAddr`, exactly as `login` uses it, so the handler can record
   the client IP.)

3. Handlers — in `shomei-servant/src/Shomei/Servant/Handlers.hs`, wire both into `shomeiServer` and
   implement:

   ```haskell
   impersonateH :: Env -> AuthUser -> SockAddr -> ImpersonateRequest -> Handler ImpersonateResponse
   impersonateH env caller peer req = do
       target <- either (const (throwError (authErrorToServerError ImpersonationTargetInvalid))) pure
                        (parseId req.userId)
       result <- runAuth env $
           Imp.startImpersonation env.config Imp.StartImpersonation
               { actorClaims = caller.authClaims
               , targetUserId = target
               , reason = req.reason
               , ticketId = req.ticketId
               , clientIp = Just (clientIpText peer)
               }
       pure (impersonationToResponse result)

   stopImpersonateH :: Env -> AuthUser -> Handler NoContent
   stopImpersonateH env caller = do
       runAuth env (Imp.stopImpersonation caller.authClaims)
       pure NoContent
   ```

   (`runAuth` already unwraps `Either AuthError a`; `clientIpText` is the helper `loginH` uses.)

4. Gating — add a guard used by sensitive handlers. In
   `shomei-servant/src/Shomei/Servant/Handlers.hs` (or `Authz.hs`), add:

   ```haskell
   -- | Refuse a request that arrives on a delegated (impersonation) token: any token whose
   -- claims carry an @act@ actor is acting on behalf of someone and must not change credentials.
   denyUnderImpersonation :: Env -> Text -> AuthUser -> Handler ()
   denyUnderImpersonation env action user =
       case user.authClaims.actor of
           Nothing -> pure ()
           Just actorId -> do
               runPort env $ publishAuthEvent $
                   Event.ImpersonationActionBlocked Event.ImpersonationActionBlockedData
                       { actorUserId = actorId
                       , subjectUserId = user.authUserId
                       , sessionId = user.authSessionId
                       , action = action
                       , occurredAt = <now from Clock via runPort>
                       }
               throwError (authErrorToServerError ImpersonationActionBlocked)
   ```

   Call `denyUnderImpersonation env "password_change" user` at the top of `passwordChangeH`, and
   `denyUnderImpersonation env "passkey_register"/"passkey_remove" user` at the top of the passkey
   enrollment and removal handlers (identify them with `rg -n "passkey" shomei-servant/src/Shomei/
   Servant/Handlers.hs`). Add a `-- TODO` comment listing the future endpoints (email change,
   account deletion) that must also call this guard when they are added.

5. Error mapping — in `shomei-servant/src/Shomei/Servant/Error.hs`, add cases to
   `authErrorToServerError`:
   - `ImpersonationForbidden -> json err403 "impersonation_forbidden" "Not allowed to impersonate"`
   - `ImpersonationTargetInvalid -> json err400 "impersonation_target_invalid" "Invalid impersonation target"`
   - `ImpersonationActionBlocked -> json err403 "impersonation_action_blocked" "This action is not permitted while impersonating"`

6. Audit projection — in `shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs`, extend
   `projectAuthEvent` with the three new events, mapping subject to the `user_id` column and the new
   session to `session_id`, with event-type strings `"impersonation_started"`,
   `"impersonation_stopped"`, `"impersonation_action_blocked"` and the `*Data` record as the JSONB
   payload (the actor id and reason live inside the payload). If
   `docs/plans/14-audit-log-retrieval-api-and-cli.md` defines an event-type allow-list or decoder,
   add the three strings there too.

7. Tests — extend the servant/integration test suite (`rg -n "loginH|spec" shomei-servant/test`):
   exchange-then-call-me returns the subject identity; a delegated token hitting password change
   returns 403; stop revokes the session.

Acceptance: `cabal build all` succeeds; `cabal test shomei-servant` (and `shomei-postgres`) pass.

### Milestone M5 — end-to-end proof and docs

Scope: demonstrate the feature against the running server and document it. No new behavior — this
milestone is the observable proof and the written record.

Run the standalone server (see Concrete Steps) and capture the HTTP transcript described in
Validation. Then update `docs/security.md` with a short "Impersonation / delegated tokens" section
(two identities, short TTL, no refresh token, credential endpoints refuse delegated tokens, every
action audited with both ids) and add the two endpoints to `docs/api.md` following the existing
entry format. Write the Outcomes & Retrospective section.

Acceptance: the transcript in Validation reproduces; docs build/lint (if the repo lints docs) and
read correctly.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` unless noted.

Build and test per package as you implement each milestone:

```bash
cabal build shomei-core shomei-jwt
cabal test shomei-jwt          # M1
cabal test shomei-postgres     # M2
cabal test shomei-core         # M3
cabal build all                # M4
cabal test shomei-servant shomei-postgres   # M4
```

Find construction sites you must update when widening a record (run after each record change so the
compiler-driven list is complete; the compiler will also error on each missed site):

```bash
rg -n "AuthClaims" --type haskell
rg -n "NewSession|Session \{" --type haskell
```

To exercise the running server in M5, start the standalone server. Confirm its run instructions
first (the README shows `cabal run exe:shomei-server`); it needs a PostgreSQL database with
migrations applied:

```bash
cabal run shomei-admin -- migrate          # applies codd migrations incl. the new actor column
cabal run exe:shomei-server                # starts warp; note the bound port (default 8080)
```

(If the project provides a different local-run path — e.g. a Nix devshell or a test fixture that
boots an ephemeral database — discover it with `rg -n "shomei-server|run " README.md docs/` and use
that instead. Record whatever you actually ran here.)


## Validation and Acceptance

The definitive end-to-end check (M5). It assumes the server is reachable at
`http://localhost:8080`, an operator account exists and holds the `impersonate:user` scope, and a
customer account `user_123` exists and is active. Adjust ids to your seeded data; record the real
transcript in this section when you run it.

1. **Log in as the operator** and capture the access token:

   ```bash
   curl -s -X POST http://localhost:8080/auth/login \
     -H 'Content-Type: application/json' \
     -d '{"email":"operator@example.com","password":"<pw>"}'
   ```

   Expect HTTP 200 with `accessToken`/`refreshToken`. Export `OP=<accessToken>`.

2. **Exchange for a delegated token**:

   ```bash
   curl -s -X POST http://localhost:8080/auth/impersonate \
     -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
     -d '{"userId":"user_123","reason":"Debugging support issue","ticketId":"SUP-1234"}'
   ```

   Expect HTTP 200 with `{"accessToken":"…","subjectUserId":"user_123","actorUserId":"<operator>",
   "expiresAt":"…"}`. Export `IMP=<accessToken>`.

3. **Confirm the two identities**: call `/auth/me` with the delegated token and observe the
   *customer's* identity returned, while the token itself carries the operator as actor (decode the
   JWT payload locally to see `"sub":"user_123"` and `"act":"<operator>"`):

   ```bash
   curl -s http://localhost:8080/auth/me -H "Authorization: Bearer $IMP"
   ```

   Expect HTTP 200 describing `user_123`.

4. **Credential change is refused**: attempt a password change with the delegated token:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/auth/password/change \
     -H "Authorization: Bearer $IMP" -H 'Content-Type: application/json' \
     -d '{"currentPassword":"x","newPassword":"y"}'
   ```

   Expect `403`. (The same operator's *own* token `$OP` would instead reach the normal
   credential-check path — i.e. impersonation is what is blocked, not password change in general.)

5. **Stop impersonating**:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://localhost:8080/auth/impersonate \
     -H "Authorization: Bearer $IMP"
   ```

   Expect `204`. A subsequent `/auth/me` with `$IMP` should now fail session validation if the
   server runs in a session-checking mode (`sessionCheckMode`), since the delegated session is
   revoked.

6. **Audit trail**: query the audit log (via the retrieval API/CLI from
   `docs/plans/14-audit-log-retrieval-api-and-cli.md`, if available, or directly):

   ```bash
   psql "$DATABASE_URL" -c \
     "SELECT event_type, user_id, payload->>'actorUserId' AS actor, payload->>'reason' AS reason \
      FROM shomei.shomei_auth_events \
      WHERE event_type LIKE 'impersonation%' ORDER BY created_at;"
   ```

   Expect rows for `impersonation_started` (with `actor` = operator, `user_id` = customer, `reason`
   = "Debugging support issue"), `impersonation_action_blocked` (action `password_change`), and
   `impersonation_stopped`, each carrying both ids.

Unit/spec acceptance (run continuously during implementation): `cabal test shomei-jwt`,
`cabal test shomei-core`, `cabal test shomei-postgres`, `cabal test shomei-servant` all pass.

**Known limitation to state plainly in the retrospective:** "recent authentication" is enforced as
a token-freshness window (`actorFreshnessWindow`), not as an interactive MFA re-prompt. A future
plan can add a true step-up ceremony and require it here.


## Idempotence and Recovery

The code edits are additive and compiler-checked: widening `AuthClaims`/`Session`/`NewSession`
makes the compiler enumerate every construction site, so a partial edit fails to build rather than
silently misbehaving — fix the listed sites and rebuild. Re-running `cabal build`/`cabal test` is
always safe.

The migration uses `ADD COLUMN IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`, and `codd` records
which migrations have been applied, so `cabal run shomei-admin -- migrate` is safe to run
repeatedly. The column is nullable with no default, so existing session rows remain valid
(`actor_user_id` is simply `NULL` for all pre-existing and all normal-login sessions); there is no
backfill and no destructive change. To roll back during development, drop the column
(`ALTER TABLE shomei.shomei_sessions DROP COLUMN IF EXISTS actor_user_id;`) on a throwaway database;
do not edit an already-applied migration file in place — add a new migration if a schema change is
needed later.

The HTTP behavior is safe to retry: starting impersonation twice simply creates two independent
short-lived delegated sessions; each `DELETE /auth/impersonate` revokes the session named by the
presented token and is harmless if that session is already revoked.


## Interfaces and Dependencies

No new external libraries are required; this plan composes existing ones (`effectful` for ports,
`jose` for JWT, `hasql` for Postgres, `servant-server` for HTTP, `aeson` for JSON).

Types and signatures that must exist at the end of each milestone (full module paths):

- M1 — `Shomei.Domain.Claims.AuthClaims` has field `actor :: Maybe UserId`;
  `Shomei.Jwt.Sign.claimsFromAuth` emits the `act` claim iff `actor` is `Just`;
  `Shomei.Jwt.Verify.claimsToAuth` populates `actor` from the `act` claim.
- M2 — `Shomei.Domain.Session.Session` and `.NewSession` have field `actor :: Maybe UserId`; the
  `Shomei.Effect.SessionStore.SessionStore` port is unchanged in signature (it already takes
  `NewSession`), and both its interpreters (`Shomei.Postgres.SessionStore`,
  `Shomei.Effect.InMemory`) persist/return `actor`; migration
  `shomei-migrations/sql-migrations/2026-06-17-00-00-00-shomei-sessions-actor.sql` exists.
- M3 — `Shomei.Config.ImpersonationConfig` and `ShomeiConfig.impersonationConfig` exist;
  `Shomei.Error.AuthError` has `ImpersonationForbidden`, `ImpersonationTargetInvalid`,
  `ImpersonationActionBlocked`; `Shomei.Domain.Event.AuthEvent` has `ImpersonationStarted`,
  `ImpersonationStopped`, `ImpersonationActionBlocked` with their `*Data` records;
  `Shomei.Workflow.Impersonation` exposes `StartImpersonation`, `startImpersonation`,
  `stopImpersonation` with the signatures shown in M3.
- M4 — `Shomei.Servant.DTO.ImpersonateRequest`/`ImpersonateResponse` exist; `Shomei.Servant.API.ShomeiAPI`
  has `impersonate` and `stopImpersonate` routes; `Shomei.Servant.Handlers` defines `impersonateH`,
  `stopImpersonateH`, and `denyUnderImpersonation` and applies the guard to `passwordChangeH` and the
  passkey handlers; `Shomei.Servant.Error.authErrorToServerError` covers the three new errors;
  `Shomei.Postgres.AuthEventPublisher.projectAuthEvent` covers the three new events.

The `act`/`sub` claim contract is the integration point for everything outside this repository: a
downstream microservice reads `sub` (the customer) and `act` (the operator) from the verified token
to drive its UI banner, write-attribution, and business-action gating. This plan does not implement
those consumers.
