---
id: 17
slug: passkey-enrollment-workflow-and-management-api
title: "Passkey enrollment workflow and management API"
kind: exec-plan
created_at: 2026-06-17T14:38:15Z
intention: "intention_01kvazmabnevhva7cq6ap01g95"
master_plan: "docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md"
---

# Passkey enrollment workflow and management API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A **passkey** is a public-key credential. The user's device (a phone's Touch ID / Face ID,
a Windows Hello sensor, a hardware key such as a YubiKey, or a synced provider such as
iCloud Keychain or 1Password) holds a *private* key that never leaves the device; the
server stores only the matching *public* key. To create one, the browser runs the WebAuthn
registration ceremony — it calls the JavaScript function `navigator.credentials.create()`,
the device mints a fresh key pair, and the browser hands the server a JSON blob containing
the new public key plus a signature proving the device produced it. The server verifies that
blob and stores the public key. Later, at login, the device signs a fresh server-chosen
challenge with the private key to prove possession (that login flow is a *separate* ExecPlan,
EP-4 / `docs/plans/18-passkey-login-mfa-step-up-and-passwordless.md`; this plan does **not**
implement login).

After this change, an **already-logged-in** Shōmei user can do four new things over HTTP:

1. **Begin** enrolling a passkey — `POST /auth/passkeys/register/begin` returns the WebAuthn
   *creation options* (a JSON `Value` the browser feeds to `navigator.credentials.create()`)
   plus a short-lived `ceremonyId` that ties the eventual answer back to this request.
2. **Complete** the enrollment — `POST /auth/passkeys/register/complete` accepts the
   browser's credential JSON (the output of `navigator.credentials.create()`, serialized by
   the standard `webauthn-json` browser helper), the server verifies it, and the new passkey
   is stored against the user's account with an optional human label ("Ada's YubiKey").
3. **List** their enrolled passkeys — `GET /auth/passkeys` returns one row per stored passkey
   (its id, label, transports, and timestamps; never the public-key bytes).
4. **Remove** one — `DELETE /auth/passkeys/{passkeyId}` deletes a passkey *they own* (a user
   cannot delete another user's passkey; that is a 404, not a 403, so credential ids are not
   enumerable).

You can see it working with the in-process HTTP test added in Milestone 2: it logs a user in,
calls begin → complete (feeding a canned credential blob that the *deterministic fake*
WebAuthn interpreter accepts), then `GET /auth/passkeys` shows the new passkey and
`DELETE` removes it. Two audit rows are also written — `passkey_registered` on enrollment and
`passkey_removed` on deletion — observable in the in-memory event log and (under PostgreSQL)
in the `shomei_auth_events` table.

This plan is **EP-3** of MasterPlan 3 (`docs/masterplans/3-webauthn-passkey-multi-factor-authentication.md`).
It **hard-depends** on two prior ExecPlans whose deliverables it consumes verbatim:

- **EP-1** (`docs/plans/15-webauthn-ceremony-port-and-shomei-webauthn-interpreter-package.md`):
  the `WebAuthnCeremony` port (the effect that produces creation options and verifies the
  browser's answer), the passkey domain types, and the `WebAuthnConfig` config sub-record.
- **EP-2** (`docs/plans/16-passkey-and-pending-ceremony-persistence.md`): the `PasskeyStore`
  (persisted passkeys) and `PendingCeremonyStore` (the consume-once challenge state) ports
  and their in-memory and PostgreSQL interpreters.

Because EP-1 and EP-2 are skeletons at the time this plan was authored, the exact shared
types this plan relies on are reproduced verbatim under **Interfaces and Dependencies →
Consumed contract from EP-1 and EP-2** below. If EP-1/EP-2 land with a *different* shape,
update that section and the Decision Log rather than guessing.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — core enrollment workflow + error/event vocabulary (pure, in-memory tests):

- [ ] Confirm EP-1 and EP-2 are merged and that the Consumed-contract section below matches their real types; reconcile any drift in the Decision Log.
- [ ] Add `PasskeyRegisteredData` / `PasskeyRemovedData` records and the `PasskeyRegistered` / `PasskeyRemoved` arms to `Shomei.Domain.Event` (`shomei-core/src/Shomei/Domain/Event.hs`).
- [ ] Add `WebAuthnCeremonyError WebAuthnError`, `PasskeyNotFound`, and `PendingCeremonyNotFound` to `Shomei.Error.AuthError` (`shomei-core/src/Shomei/Error.hs`); import `WebAuthnError` from EP-1's module.
- [ ] Create `shomei-core/src/Shomei/Workflow/Passkey.hs` with `beginPasskeyRegistration`, `completePasskeyRegistration`, `listPasskeys`, `removePasskey`; add the module to `shomei-core/shomei-core.cabal`.
- [ ] Derive the stable per-user `UserHandle` helper (`userHandleForUser`) and document the derivation in the Decision Log.
- [ ] Add `shomei-core/test/Shomei/Workflow/PasskeySpec.hs` proving begin→complete stores a passkey, list returns it, remove deletes it, wrong-user complete is rejected, and an expired/absent ceremony is `PendingCeremonyNotFound`.
- [ ] `cabal test all` green.

Milestone 2 — HTTP surface (routes + DTOs + handlers), event publisher wiring, in-process HTTP test:

- [ ] Add `PasskeyId` re-export plumbing if needed and the four routes to `Shomei.Servant.API.ShomeiAPI`.
- [ ] Add `PasskeyRegisterBeginResponse`, `PasskeyRegisterCompleteRequest`, `PasskeyResponse`, and `passkeyToResponse` to `Shomei.Servant.DTO`.
- [ ] Add `passkeyRegisterBeginH`, `passkeyRegisterCompleteH`, `passkeysListH`, `passkeyDeleteH` to `Shomei.Servant.Handlers` and wire them into the `shomeiServer` record.
- [ ] Map the three new `AuthError` constructors in `Shomei.Servant.Error.authErrorToServerError`.
- [ ] Wire `PasskeyRegistered` / `PasskeyRemoved` into `Shomei.Postgres.AuthEventPublisher.projectAuthEvent`.
- [ ] Extend the `shomei-servant` test harness (`shomei-servant/test/Main.hs`) with the begin→complete→list→delete scenario; the hybrid runner must interpret the new EP-1/EP-2 ports.
- [ ] Confirm the `AppAPI` embedded example still type-checks.
- [ ] `cabal build all` and `cabal test all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. Record concrete evidence — compiler output, test transcripts — as you implement.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Derive each user's WebAuthn **user handle** deterministically from their `UserId`
  rather than generating a random one per passkey.
  Rationale: The WebAuthn "user handle" identifies the *account* the credential belongs to.
  Shōmei enrolls passkeys against an already-existing account (a step-up / second-factor
  design), so all of one user's passkeys should share one stable handle — that is what lets
  a future passwordless login (EP-4) resolve "which Shōmei user is this credential for?" from
  the handle alone. A `UserId` is a `KindID "passkey"`-style typed id whose underlying value
  is a 16-byte UUID (v7); the handle is exactly those 16 bytes: `userHandleForUser u =
  UserHandle (BS.pack (... the 16 bytes of (userIdToUUID u.userId) ...))`. This is stable,
  collision-free (UUIDs are unique), and reversible enough for EP-4 to look the user up. The
  EP-1 library helper `generateUserHandle` makes *random* handles; we deliberately do not use
  it here. If EP-1 names the derivation differently, keep the *semantics* (16 stable bytes
  from the UserId UUID) and note the rename here.
  Date: 2026-06-17

- Decision: Map the new errors to HTTP as follows — `PasskeyNotFound` → **404**,
  `PendingCeremonyNotFound` → **404**, `WebAuthnCeremonyError _` → **400**.
  Rationale: A not-found passkey or a missing/expired/consumed pending ceremony is a
  resource-absence condition (404). A WebAuthn verification failure (bad attestation, origin
  mismatch, challenge mismatch, malformed credential JSON) is a *client* error in the request
  body, so 400 — we do not use 401 because the caller is already authenticated (they hold a
  valid bearer token); the *body* is what is wrong, which is the 400/422 family. We choose 400
  over 422 to stay consistent with the existing `VerificationTokenInvalid`/`mkEmail` 400s in
  `Shomei.Servant.Error`. The error body stays generic (`{"error":...,"message":...}`) so it
  never leaks why verification failed. If EP-4 later needs a 401 for the *login* assertion
  path, that is EP-4's own mapping; this plan's enrollment errors are 400/404.
  Date: 2026-06-17

- Decision: The passkey **label** is optional, supplied by the client at *complete* time
  (`PasskeyRegisterCompleteRequest.label :: Maybe Text`), stored as-is, and never required.
  Rationale: A label is a human convenience ("Ada's YubiKey"); the credential is fully usable
  without one. Putting it on *complete* (not *begin*) means the browser can prompt for it
  after the device names the authenticator, and it keeps *begin* a pure ceremony-start. An
  empty/whitespace label is normalized to `Nothing` (mirroring `mkDisplayName` in the existing
  handlers) so blank input does not store an empty string.
  Date: 2026-06-17

- Decision: `removePasskey` and `DELETE /auth/passkeys/{passkeyId}` scope the delete by the
  authenticated user and treat "not yours / not found" identically as `PasskeyNotFound` → 404.
  Rationale: A user must not be able to delete another user's passkey, and the response must
  not reveal whether some *other* user's passkey id exists. EP-2's `DeletePasskey :: UserId ->
  PasskeyId -> Eff es ()` is already user-scoped; the workflow first confirms the passkey
  exists *and belongs to this user* (via `FindPasskeysByUser`) and otherwise returns
  `PasskeyNotFound`, so the 404 is uniform.
  Date: 2026-06-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shōmei is a Haskell authentication toolkit organized as a set of Cabal packages following a
**hexagonal** (ports-and-adapters) architecture. You do not need prior knowledge of these
packages beyond what is written here.

- `shomei-core` (`shomei-core/`) holds the transport- and infrastructure-agnostic heart:
  domain types (`Shomei.Domain.*`), **ports** (effect interfaces under `Shomei.Effect.*`,
  built with the `effectful` library), and **workflows** (`Shomei.Workflow`,
  `Shomei.Workflow.Account`) that orchestrate ports. It depends on no database and no HTTP
  library. *An "effect" / "port" here is a typed capability* (e.g. `UserStore` is "can read
  and write users"); a workflow names the effects it needs as constraints like `UserStore :>
  es` and stays oblivious to how they are implemented.
- `shomei-postgres` (`shomei-postgres/`) interprets those ports against PostgreSQL.
- `shomei-jwt` (`shomei-jwt/`) interprets the token ports against the `jose` library.
- `shomei-webauthn` (`shomei-webauthn/`, **created by EP-1**) interprets the new
  `WebAuthnCeremony` port against the `tweag/webauthn` library. EP-3 does *not* touch this
  package's internals; it only calls the port.
- `shomei-servant` (`shomei-servant/`) exposes the HTTP API as a Servant `NamedRoutes` record
  (`Shomei.Servant.API.ShomeiAPI`), with request/response DTOs (`Shomei.Servant.DTO`),
  handlers (`Shomei.Servant.Handlers`), the auth combinator and principal
  (`Shomei.Servant.Auth`), the seam onto the effect stack (`Shomei.Servant.Seam`), and the
  error mapping (`Shomei.Servant.Error`).
- `shomei-server` (`shomei-server/`) assembles everything and serves it with `warp`
  (`Shomei.Server.Boot`).

**Key terms used below**, defined once:

- *Ceremony.* One round-trip of the WebAuthn protocol. A *registration* ceremony enrolls a
  new passkey; an *authentication* ceremony proves possession at login. This plan implements
  only registration.
- *Creation options.* The JSON the server sends the browser to start a registration ceremony;
  the browser passes it to `navigator.credentials.create()`. It includes a random
  *challenge*, the relying-party identity, the user's handle, and the list of
  *excludeCredentials* (already-enrolled credentials, so the device refuses to double-enroll).
- *Credential JSON.* The JSON the browser returns after the device creates the credential —
  the output of `navigator.credentials.create()` serialized by the `webauthn-json` browser
  helper. The server verifies it.
- *Relying Party (RP).* The server's identity in WebAuthn terms (an `rpId` domain and a
  human-readable `rpName`). EP-1's `WebAuthnConfig` carries these; the EP-1 interpreter reads
  them. This plan only passes the user-specific bits (`CredentialUserInfo`) to the port.
- *Pending ceremony.* The short-lived server-side state (the challenge / options blob) created
  at *begin* and consumed exactly once at *complete*. EP-2's `PendingCeremonyStore` persists
  it with a TTL (time-to-live) expiry.
- *`AuthUser`.* The principal a handler receives for an authenticated route, defined in
  `Shomei.Servant.Auth`: it carries `authUserId :: UserId` and `authSessionId :: SessionId`
  (plus roles/scopes/claims). We use `authUserId` to scope every passkey operation.
- *`Value`.* `Data.Aeson.Value`, an arbitrary JSON value. The WebAuthn JSON crosses the API
  and the port boundary as a `Value` verbatim, so the core never names a WebAuthn library type.

The four existing files this plan reads and mirrors most closely:

- `shomei-core/src/Shomei/Workflow/Account.hs` — the workflow *style* (effect constraints,
  `runErrorNoCallStack`/`throwError`, `now`, `publishAuthEvent`). The new workflow module
  copies this structure.
- `shomei-servant/src/Shomei/Servant/Handlers.hs` — `passwordChangeH` and `meH` are the two
  templates: `passwordChangeH` shows an authenticated handler that calls `runAuth env (…)` on
  an `Either AuthError`-returning workflow; `meH` shows an authenticated handler that calls
  `runPort` and branches on the result itself.
- `shomei-servant/src/Shomei/Servant/DTO.hs` — the wire-DTO conventions (records deriving
  `FromJSON`/`ToJSON` anyclass, plus `*ToResponse` mapping functions rendering ids with
  `idText` and timestamps with `iso8601Show`).
- `shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs` — how a *new* `AuthEvent` arm
  must be added to `projectAuthEvent` so it persists with the right event-type string.


## Plan of Work

The work is two milestones. Milestone 1 builds and tests the **core** enrollment workflow with
no HTTP involved — it is fully verifiable with a pure in-memory test using EP-1's deterministic
fake ceremony interpreter and EP-2's in-memory stores. Milestone 2 exposes that workflow over
HTTP, wires the audit events into the PostgreSQL publisher, and proves the whole thing
end-to-end with an in-process HTTP test.


### Milestone 1 — core enrollment workflow, error vocabulary, audit events

**Scope.** At the end of this milestone, `shomei-core` defines a new workflow module
`Shomei.Workflow.Passkey` with four functions (`beginPasskeyRegistration`,
`completePasskeyRegistration`, `listPasskeys`, `removePasskey`), the `AuthError` type has three
new constructors, the `AuthEvent` sum has two new arms with their `*Data` records, and a new
test proves enrollment behavior purely in memory. No HTTP, no PostgreSQL. Run `cabal test all`
in the repo root; the new `PasskeySpec` group passes.

**Step 1.1 — events.** In `shomei-core/src/Shomei/Domain/Event.hs`, add two records and two sum
arms. Mirror `PasswordChangedData` exactly (it carries a `userId` and an `occurredAt`); add a
`passkeyId`. Insert the records near the other `*Data` records and the arms at the end of the
`AuthEvent` data declaration, and **export** the two new record names from the module header.

```haskell
-- in the export list of Shomei.Domain.Event, alongside the other *Data exports:
    PasskeyRegisteredData (..),
    PasskeyRemovedData (..),

-- with the other record declarations (PasskeyId comes from Shomei.Id, re-exported by EP-1):
data PasskeyRegisteredData = PasskeyRegisteredData
    { userId :: !UserId
    , passkeyId :: !PasskeyId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data PasskeyRemovedData = PasskeyRemovedData
    { userId :: !UserId
    , passkeyId :: !PasskeyId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- new arms appended to `data AuthEvent = ...`:
    | PasskeyRegistered PasskeyRegisteredData
    | PasskeyRemoved PasskeyRemovedData
```

`PasskeyId` is `type PasskeyId = KindID "passkey"`, defined by EP-1 in `Shomei.Id`. Import it
with the existing `import Shomei.Id (RefreshTokenId, SessionId, UserId)` line — extend that to
`import Shomei.Id (PasskeyId, RefreshTokenId, SessionId, UserId)`. `KindID` already has
`FromJSON`/`ToJSON` instances (used elsewhere), so the `deriving anyclass (FromJSON, ToJSON)`
on the records is fine.

**Step 1.2 — errors.** In `shomei-core/src/Shomei/Error.hs`, add three constructors to
`AuthError` and import `WebAuthnError`. `WebAuthnError` is defined by EP-1 in its ceremony
module (per the Consumed-contract section, `Shomei.Effect.WebAuthnCeremony`); it derives
`Generic`/`Eq`/`Show`/`FromJSON`/`ToJSON`, so wrapping it preserves `AuthError`'s own derived
instances.

```haskell
import Shomei.Effect.WebAuthnCeremony (WebAuthnError)

-- appended to `data AuthError = ...`, before `InternalAuthError Text`:
    | -- | A WebAuthn registration verification failed (bad attestation, origin/challenge
      -- mismatch, or malformed credential JSON). The HTTP layer maps this to 400.
      WebAuthnCeremonyError WebAuthnError
    | -- | No passkey with the given id is owned by the requesting user. Maps to 404.
      PasskeyNotFound
    | -- | The pending ceremony was missing, already consumed, or expired. Maps to 404.
      PendingCeremonyNotFound
```

If importing `Shomei.Effect.WebAuthnCeremony` into `Shomei.Error` creates an import cycle
(because EP-1's effect module imports `Shomei.Error`), define `WebAuthnError` in a small leaf
module that both import — EP-1 owns that placement. Record any such adjustment in the Decision
Log. (At authoring time EP-1 is a skeleton; the expectation per MasterPlan IP-1 is that
`WebAuthnError` is a plain domain sum with no dependency on `Shomei.Error`, so no cycle.)

**Step 1.3 — the workflow module.** Create `shomei-core/src/Shomei/Workflow/Passkey.hs`. It
mirrors `Shomei.Workflow.Account`'s style: explicit effect constraints, `now` from
`Shomei.Effect.Clock`, `runErrorNoCallStack`/`throwError` from `Effectful.Error.Static`,
`publishAuthEvent` from `Shomei.Effect.AuthEventPublisher`, and qualified `Shomei.Domain.Event`.
The full intended module:

```haskell
-- | Authenticated passkey enrollment and management workflows (EP-3).
--
-- A "passkey" is a stored public-key credential. These workflows let an already-authenticated
-- user begin a WebAuthn registration ceremony, complete it (verifying the browser's answer and
-- storing the public key), list their passkeys, and remove one. They are written purely against
-- port effects, so the same code runs over the in-memory test interpreters and the real
-- PostgreSQL + shomei-webauthn interpreters.
module Shomei.Workflow.Passkey (
    beginPasskeyRegistration,
    completePasskeyRegistration,
    listPasskeys,
    removePasskey,
) where

import Shomei.Prelude

import Data.Aeson (Value)
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)

import Shomei.Config (ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Passkey (
    BeginCeremony (..),
    CeremonyKind (RegistrationCeremony),
    CredentialUserInfo (..),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    UserHandle (..),
    VerifiedRegistration (..),
 )
import Shomei.Domain.User (User (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (PasskeyId, UserId, userIdToUUID)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.PasskeyStore (
    PasskeyStore,
    createPasskey,
    deletePasskey,
    findPasskeysByUser,
 )
import Shomei.Effect.PendingCeremonyStore (
    PendingCeremonyStore,
    putPendingCeremony,
    takePendingCeremony,
 )
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Effect.WebAuthnCeremony (
    WebAuthnCeremony,
    beginRegistrationCeremony,
    completeRegistrationCeremony,
    generateCeremonyId,
 )

import Data.UUID qualified as UUID
import Data.ByteString.Lazy qualified as BSL

{- | Derive a stable WebAuthn user handle from the Shōmei user id: the 16 bytes of the user's
UUID. All of a user's passkeys therefore share one handle, so a passwordless login (EP-4) can
resolve the user from the handle alone. See the Decision Log for why we do not use a random
handle. -}
userHandleForUser :: UserId -> UserHandle
userHandleForUser uid = UserHandle (BSL.toStrict (UUID.toByteString (userIdToUUID uid)))

beginPasskeyRegistration ::
    ( UserStore :> es
    , PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    UserId ->
    Eff es (Either AuthError (CeremonyId, Value))
beginPasskeyRegistration cfg uid = runErrorNoCallStack do
    ts <- now
    user <- maybe (throwError InvalidCredentials) pure =<< findUserById uid
    existing <- findPasskeysByUser uid
    let info =
            CredentialUserInfo
                { userHandle = userHandleForUser uid
                , accountName = emailText user.email
                , displayName = fromMaybe (emailText user.email) user.displayName
                }
        excludeIds = map (.credentialId) existing
    BeginCeremony{optionsJson, optionsBlob} <-
        beginRegistrationCeremony info excludeIds
    ceremonyId <- generateCeremonyId
    putPendingCeremony
        PendingCeremony
            { ceremonyId = ceremonyId
            , userId = Just uid
            , kind = RegistrationCeremony
            , optionsBlob = optionsBlob
            , createdAt = ts
            , expiresAt = addUTCTime cfg.webauthnConfig.pendingCeremonyTTL ts
            }
    pure (ceremonyId, optionsJson)

completePasskeyRegistration ::
    ( PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , AuthEventPublisher :> es
    , Clock :> es
    ) =>
    ShomeiConfig ->
    UserId ->
    CeremonyId ->
    Value ->
    Maybe Text ->
    Eff es (Either AuthError PasskeyCredential)
completePasskeyRegistration _cfg uid ceremonyId credentialJson mLabel = runErrorNoCallStack do
    ts <- now
    pending <-
        maybe (throwError PendingCeremonyNotFound) pure
            =<< takePendingCeremony ceremonyId ts
    -- Reject a ceremony that is not a registration, or that was begun for a different user.
    when (pending.kind /= RegistrationCeremony) (throwError PendingCeremonyNotFound)
    when (pending.userId /= Just uid) (throwError PendingCeremonyNotFound)
    verified <-
        either (throwError . WebAuthnCeremonyError) pure
            =<< completeRegistrationCeremony pending.optionsBlob credentialJson
    passkey <-
        createPasskey
            NewPasskeyCredential
                { userId = uid
                , credentialId = verified.credentialId
                , userHandle = verified.userHandle
                , publicKey = verified.publicKey
                , signCounter = verified.signCounter
                , transports = verified.transports
                , label = normalizeLabel =<< mLabel
                , createdAt = ts
                }
    publishAuthEvent
        (Event.PasskeyRegistered (Event.PasskeyRegisteredData uid passkey.passkeyId ts))
    pure passkey

listPasskeys ::
    (PasskeyStore :> es) =>
    UserId ->
    Eff es [PasskeyCredential]
listPasskeys = findPasskeysByUser

removePasskey ::
    ( PasskeyStore :> es
    , AuthEventPublisher :> es
    , Clock :> es
    ) =>
    UserId ->
    PasskeyId ->
    Eff es (Either AuthError ())
removePasskey uid pid = runErrorNoCallStack do
    ts <- now
    owned <- findPasskeysByUser uid
    unless (any (\p -> p.passkeyId == pid) owned) (throwError PasskeyNotFound)
    deletePasskey uid pid
    publishAuthEvent (Event.PasskeyRemoved (Event.PasskeyRemovedData uid pid ts))
    pure ()
```

Notes on the workflow:

- `CeremonyId` is `type CeremonyId = KindID "webauthn_ceremony"` (EP-1). The id is generated by
  the `WebAuthnCeremony` port's `generateCeremonyId` (EP-1 owns it; it lives in the ceremony
  effect because EP-1 generates ids there). If EP-1 instead exposes a plain `genCeremonyId ::
  MonadIO m => m CeremonyId` in `Shomei.Id`, call that via `liftIO`/the `TokenGen` port and drop
  `generateCeremonyId` from the `WebAuthnCeremony` import — record which one in the Decision Log.
  (The `TokenGen` constraint is kept on `beginPasskeyRegistration` for exactly this reason, and
  because a fresh id may need random bytes; remove it if unused once EP-1's id source is known.)
- The unknown-user branch returns `InvalidCredentials` (not a new error) — an authenticated
  principal whose user row is missing is the same "shouldn't happen / treat as auth failure"
  case `meH` handles with a 404; here we keep it inside the workflow's `AuthError` and map it as
  the existing generic 401. (This branch is unreachable in practice because the principal was
  just verified; it exists for totality.)
- `normalizeLabel` collapses a blank label to `Nothing`, mirroring `mkDisplayName`:

```haskell
normalizeLabel :: Text -> Maybe Text
normalizeLabel t
    | Data.Text.null (Data.Text.strip t) = Nothing
    | otherwise = Just (Data.Text.strip t)
```

  Add `import Data.Text qualified as Text` and use `Text.null` / `Text.strip` (the qualified
  form is shown unqualified above only for readability; write it qualified in the file).

**Step 1.4 — register the module.** In `shomei-core/shomei-core.cabal`, add
`Shomei.Workflow.Passkey` to the library's `exposed-modules` (next to `Shomei.Workflow.Account`).
If EP-1/EP-2 added new dependencies (`uuid` for `userIdToUUID`'s `Data.UUID`), confirm `uuid` is
in `build-depends`; `Shomei.Id` already uses `Data.UUID` so it should be present.

**Step 1.5 — the pure test.** Create `shomei-core/test/Shomei/Workflow/PasskeySpec.hs` (and add
it to the test suite's `other-modules` in `shomei-core.cabal`). It runs the workflow over EP-2's
in-memory stores plus EP-1's **deterministic fake** `WebAuthnCeremony` interpreter. EP-1 must
provide a fake interpreter for tests (per its own plan); the canonical expectation is a function
like `runWebAuthnCeremonyFake :: IORef World -> Eff (WebAuthnCeremony : es) a -> Eff es a` whose
`beginRegistrationCeremony` returns a fixed `optionsBlob`/`optionsJson` and whose
`completeRegistrationCeremony` returns `Right` a canned `VerifiedRegistration` whenever the input
`Value` equals a known `acceptedCredentialJson` and `Left` a `WebAuthnError` otherwise. If EP-1
names these differently, adapt the imports and note it here.

The test asserts the five behaviors below. Use the in-memory `World`/`runInMemory` pattern from
`shomei-core`'s existing `WorkflowSpec` for the non-WebAuthn ports, threaded with the new EP-1/EP-2
interpreters in the same effect order EP-2 established.

```haskell
-- Pseudocode of the assertions (HUnit-style); fill in the concrete interpreter stack EP-1/EP-2 ship.
-- A. begin → complete stores a passkey:
--    (ceremonyId, _opts) <- mustRight =<< run (beginPasskeyRegistration cfg uid)
--    pk <- mustRight =<< run (completePasskeyRegistration cfg uid ceremonyId acceptedCredentialJson (Just "YubiKey"))
--    pk.label @?= Just "YubiKey"
-- B. list returns it:
--    [seen] <- run (listPasskeys uid)
--    seen.passkeyId @?= pk.passkeyId
-- C. remove deletes it:
--    mustRight =<< run (removePasskey uid pk.passkeyId)
--    [] <- run (listPasskeys uid)  -- now empty
-- D. wrong-user complete is rejected (begin as uid, complete as otherUid):
--    (cid, _) <- mustRight =<< run (beginPasskeyRegistration cfg uid)
--    Left PendingCeremonyNotFound <- run (completePasskeyRegistration cfg otherUid cid acceptedCredentialJson Nothing)
-- E. expired/absent ceremony is rejected:
--    Left PendingCeremonyNotFound <- run (completePasskeyRegistration cfg uid bogusCeremonyId acceptedCredentialJson Nothing)
--    -- and: a second complete of the same (already-consumed) ceremony is also PendingCeremonyNotFound
-- F. (optional but recommended) a credential the fake rejects yields WebAuthnCeremonyError:
--    (cid2, _) <- mustRight =<< run (beginPasskeyRegistration cfg uid)
--    Left (WebAuthnCeremonyError _) <- run (completePasskeyRegistration cfg uid cid2 rejectedCredentialJson Nothing)
```

**Acceptance for Milestone 1.** From the repository root `/Users/shinzui/Keikaku/bokuno/shomei`,
`cabal test all` is green and the `PasskeySpec` group reports all cases passing.


### Milestone 2 — HTTP routes, DTOs, handlers, event publisher wiring, in-process HTTP test

**Scope.** At the end of this milestone, `ShomeiAPI` has four new authenticated routes, three
new DTOs and a mapper, four new handlers wired into `shomeiServer`, the three new `AuthError`s
mapped to HTTP statuses, the two new events persisted by the PostgreSQL publisher, and an
in-process HTTP test that enrolls/lists/deletes a passkey end-to-end. Run `cabal build all` and
`cabal test all` from the repo root; both are green and the new HTTP scenario passes.

**Step 2.1 — routes.** In `shomei-servant/src/Shomei/Servant/API.hs`, extend the `ShomeiAPI`
record with four fields. They mirror the existing `passwordChange` (an `Authenticated` POST with
a body) and `me` (an `Authenticated` GET) shapes. Import `PasskeyId` from `Shomei.Id` and the new
DTOs from `Shomei.Servant.DTO`.

```haskell
    , passkeyRegisterBegin ::
        mode
            :- "auth"
                :> "passkeys"
                :> "register"
                :> "begin"
                :> Authenticated
                :> Post '[JSON] PasskeyRegisterBeginResponse
    , passkeyRegisterComplete ::
        mode
            :- "auth"
                :> "passkeys"
                :> "register"
                :> "complete"
                :> Authenticated
                :> ReqBody '[JSON] PasskeyRegisterCompleteRequest
                :> Post '[JSON] PasskeyResponse
    , passkeyList ::
        mode
            :- "auth"
                :> "passkeys"
                :> Authenticated
                :> Get '[JSON] [PasskeyResponse]
    , passkeyDelete ::
        mode
            :- "auth"
                :> "passkeys"
                :> Authenticated
                :> Capture "passkeyId" PasskeyId
                :> Verb 'DELETE 204 '[JSON] NoContent
```

`Verb 'DELETE 204 '[JSON] NoContent` returns HTTP 204 No Content (the `Verb` combinator with an
explicit status, as the existing `verifyEmailRequest` uses `Verb 'POST 202`). `PasskeyId` parses
from the URL segment via the orphan `instance FromHttpApiData (KindID p)` already defined in
`Shomei.Id` (confirmed present). Add the imports:

```haskell
import Shomei.Id (PasskeyId)
import Shomei.Servant.DTO (
    -- ... existing imports ...
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
 )
```

Also update the module doc comment's route inventory and the `AppAPI` example *need not* change
(it mounts `NamedRoutes ShomeiAPI` whole), but re-confirm it type-checks since the record grew.

**Step 2.2 — DTOs.** In `shomei-servant/src/Shomei/Servant/DTO.hs`, add three records and one
mapper, exported from the module header. The `Value` fields carry the WebAuthn JSON verbatim.

```haskell
-- | @POST /auth/passkeys/register/begin@ response: the ceremony id (to echo back at
-- complete) and the WebAuthn creation options the browser feeds to navigator.credentials.create().
data PasskeyRegisterBeginResponse = PasskeyRegisterBeginResponse
    { ceremonyId :: !Text
    , options :: !Value
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | @POST /auth/passkeys/register/complete@ body: the ceremony id from begin, the browser's
-- credential JSON verbatim (the webauthn-json registration response), and an optional label.
data PasskeyRegisterCompleteRequest = PasskeyRegisterCompleteRequest
    { ceremonyId :: !Text
    , credential :: !Value
    , label :: !(Maybe Text)
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | A stored passkey as wire JSON. Never includes the public-key bytes.
data PasskeyResponse = PasskeyResponse
    { passkeyId :: !Text
    , label :: !(Maybe Text)
    , transports :: ![Text]
    , createdAt :: !Text
    , lastUsedAt :: !(Maybe Text)
    }
    deriving stock (Generic)
    deriving anyclass (FromJSON, ToJSON)
```

The mapper renders the EP-1 domain `PasskeyCredential` to `PasskeyResponse`, with ids as
`idText`, timestamps as ISO-8601 (as the existing `sessionToResponse` does), and transports as
their text. EP-1's `transports` field is a list of a `WebAuthnTransport`/text type; render each
to `Text` with the helper EP-1 provides (assumed `transportText`); if EP-1 stores transports as
`[Text]` already, drop the map.

```haskell
passkeyToResponse :: PasskeyCredential -> PasskeyResponse
passkeyToResponse p =
    PasskeyResponse
        { passkeyId = idText p.passkeyId
        , label = p.label
        , transports = map transportText p.transports
        , createdAt = Text.pack (iso8601Show p.createdAt)
        , lastUsedAt = Text.pack . iso8601Show <$> p.lastUsedAt
        }
```

Add imports for `Data.Aeson (Value)`, the EP-1 passkey domain module (`Shomei.Domain.Passkey
(PasskeyCredential (..), transportText)`), and extend the export list with the three records and
`passkeyToResponse`.

**Step 2.3 — handlers.** In `shomei-servant/src/Shomei/Servant/Handlers.hs`, add four handlers
and wire them into the `shomeiServer` record. They mirror `passwordChangeH` (authenticated,
calls `runAuth`) and `meH`/`sessionH` (authenticated, calls `runPort` and maps). Parse the
incoming `ceremonyId` text into a `CeremonyId` with `parseId` (a 400 on a malformed id), as
`signupH` parses the email with `mkEmail`.

```haskell
passkeyRegisterBeginH :: Env -> AuthUser -> Handler PasskeyRegisterBeginResponse
passkeyRegisterBeginH env user = do
    (cid, options) <- runAuth env (Passkey.beginPasskeyRegistration env.config user.authUserId)
    pure PasskeyRegisterBeginResponse{ceremonyId = idText cid, options = options}

passkeyRegisterCompleteH :: Env -> AuthUser -> PasskeyRegisterCompleteRequest -> Handler PasskeyResponse
passkeyRegisterCompleteH env user req = do
    cid <- either (const (throwError err400{errBody = "invalid ceremonyId"})) pure (parseId req.ceremonyId)
    passkey <-
        runAuth
            env
            (Passkey.completePasskeyRegistration env.config user.authUserId cid req.credential req.label)
    pure (passkeyToResponse passkey)

passkeysListH :: Env -> AuthUser -> Handler [PasskeyResponse]
passkeysListH env user = do
    passkeys <- runPort env (Passkey.listPasskeys user.authUserId)
    pure (map passkeyToResponse passkeys)

passkeyDeleteH :: Env -> AuthUser -> PasskeyId -> Handler NoContent
passkeyDeleteH env user pid = do
    runAuth env (Passkey.removePasskey user.authUserId pid)
    pure NoContent
```

Wire into the record:

```haskell
        , passkeyRegisterBegin = passkeyRegisterBeginH env
        , passkeyRegisterComplete = passkeyRegisterCompleteH env
        , passkeyList = passkeysListH env
        , passkeyDelete = passkeyDeleteH env
```

Add imports: `import Shomei.Workflow.Passkey qualified as Passkey`,
`import Shomei.Id (PasskeyId, CeremonyId, idText, parseId)` (extend the existing
`Shomei.Id` import; EP-1 exports `CeremonyId`/`PasskeyId` from `Shomei.Id`), `err400` from
`Servant`, and the three DTO names plus `passkeyToResponse` from `Shomei.Servant.DTO`. Note
`listPasskeys` returns a plain `[PasskeyCredential]` (no `Either`), so `passkeysListH` uses
`runPort`, exactly like `meH`/`sessionH`. `beginPasskeyRegistration`,
`completePasskeyRegistration`, and `removePasskey` return `Either AuthError`, so they use
`runAuth`, exactly like `passwordChangeH`.

**A note on the seam stack.** `runAuth`/`runPort` run in `Shomei.Servant.Seam.AppEffects`. EP-1
adds `WebAuthnCeremony` and EP-2 adds `PasskeyStore`/`PendingCeremonyStore` to that
`AppEffects` list (MasterPlan IP-6 makes those additions EP-1/EP-2's responsibility, not EP-3's).
EP-3 therefore writes no new `Seam`/`Boot` wiring; it relies on those ports already being present
in the stack and interpreted in `runAppIO` (server) and the in-memory runner (tests). If, when
EP-3 is implemented, EP-1/EP-2 have **not** yet added their ports to `AppEffects`, that is a
missing prerequisite — add them in the same relative position across `AppEffects`,
`Shomei.Server.App.AppEffects`/`runAppIO`, and `Shomei.Effect.InMemory.runInMemory`, and record
it as a Surprise here (it would mean EP-1/EP-2 were incomplete).

**Step 2.4 — error mapping.** In `shomei-servant/src/Shomei/Servant/Error.hs`, add three cases to
`authErrorToServerError`, matching the Decision Log:

```haskell
    PasskeyNotFound -> json err404 "passkey_not_found" "Passkey not found"
    PendingCeremonyNotFound -> json err404 "ceremony_not_found" "Registration ceremony not found or expired"
    WebAuthnCeremonyError _ -> json err400 "webauthn_verification_failed" "Passkey registration could not be verified"
```

`err404` and `err400` are already imported in that module. Do not include the inner
`WebAuthnError` detail in the body (no leak).

**Step 2.5 — PostgreSQL event projection.** In
`shomei-postgres/src/Shomei/Postgres/AuthEventPublisher.hs`, add two cases to `projectAuthEvent`,
mirroring `PasswordChanged` (a user-scoped event with no session id):

```haskell
    Event.PasskeyRegistered d@(Event.PasskeyRegisteredData uid _ occ) ->
        (Just (userIdToUUID uid), Nothing, "passkey_registered", toJSON d, occ)
    Event.PasskeyRemoved d@(Event.PasskeyRemovedData uid _ occ) ->
        (Just (userIdToUUID uid), Nothing, "passkey_removed", toJSON d, occ)
```

`projectAuthEvent` is a total `case`; adding the two arms keeps it exhaustive (the
`-Wincomplete-patterns` warning would otherwise flag the new constructors, so this step is
*required* for the build to stay clean). No new SQL or migration is needed — the events land in
the existing `shomei_auth_events` table.

**Step 2.6 — in-process HTTP test.** Extend `shomei-servant/test/Main.hs`. The existing test
boots `ShomeiAPI` on an ephemeral port with a *hybrid* runner (`runHybrid`): EP-2 in-memory stores
+ real `jose` signer/verifier. EP-3's additions need the EP-1 `WebAuthnCeremony` fake interpreter
and the EP-2 `PasskeyStore`/`PendingCeremonyStore` in-memory interpreters added to that runner, in
the same effect order EP-1/EP-2 use in `runInMemory`. Then add a scenario block after the existing
`refresh`/`jwks` assertions (reuse the already-obtained `access` bearer token from the login step):

```haskell
    -- (i) passkey: begin → complete → list → delete
    (beginStatus, beginBody) <- postJSONAuth mgr port "/auth/passkeys/register/begin" (bearer access) (object [])
    beginStatus @?= 200
    bresp <- must "begin body" beginBody
    cid <- must "ceremonyId" (dig ["ceremonyId"] bresp >>= asText)
    -- The fake interpreter accepts a known canned credential JSON regardless of the options.
    let completeBody = object ["ceremonyId" .= cid, "credential" .= acceptedCredentialJson, "label" .= ("YubiKey" :: Text)]
    (compStatus, compBody) <- postJSON mgr port "/auth/passkeys/register/complete" completeBody
    -- NOTE: complete is authenticated too; send the bearer header (see postJSONAuth).
    compStatus @?= 200
    cresp <- must "complete body" compBody
    pkId <- must "passkeyId" (dig ["passkeyId"] cresp >>= asText)
    (dig ["label"] cresp >>= asText) @?= Just "YubiKey"

    (listStatus, listBody) <- getJSON mgr port "/auth/passkeys" (bearer access)
    listStatus @?= 200
    listResp <- must "list body" listBody
    case listResp of
        Array xs -> assertBool "one passkey listed" (length xs == 1)
        _ -> assertFailure "expected a JSON array of passkeys"

    (delStatus, _) <- deleteAuth mgr port ("/auth/passkeys/" <> Text.unpack pkId) (bearer access)
    delStatus @?= 204

    (list2Status, list2Body) <- getJSON mgr port "/auth/passkeys" (bearer access)
    list2Status @?= 200
    list2Resp <- must "list2 body" list2Body
    case list2Resp of
        Array xs -> assertBool "no passkeys after delete" (null xs)
        _ -> assertFailure "expected a JSON array"

    -- (j) a complete with the wrong ceremony id is a 404
    (badStatus, _) <- postJSON mgr port "/auth/passkeys/register/complete"
        (object ["ceremonyId" .= ("webauthn_ceremony_00000000000000000000000000" :: Text), "credential" .= acceptedCredentialJson])
    badStatus @?= 404
```

Two small test helpers are needed (the existing `postJSON`/`getJSON` set Bearer only for GET):

```haskell
-- POST with an Authorization header.
postJSONAuth :: Manager -> Int -> String -> [Header] -> Value -> IO (Int, Maybe Value)
postJSONAuth mgr port path hdrs body = do
    req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
    let req = req0
            { method = "POST"
            , requestHeaders = ("Content-Type", "application/json") : hdrs
            , requestBody = RequestBodyLBS (encode body)
            }
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), decode (responseBody resp))

-- DELETE with an Authorization header.
deleteAuth :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
deleteAuth mgr port path hdrs = do
    req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
    let req = req0{method = "DELETE", requestHeaders = hdrs}
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), decode (responseBody resp))
```

Make the begin/complete posts authenticated: use `postJSONAuth ... (bearer access) ...` for both
`/register/begin` and `/register/complete` (the snippet above uses plain `postJSON` for complete
for brevity — switch it to `postJSONAuth` with the bearer header, otherwise the route returns 401
before the handler runs). `acceptedCredentialJson :: Value` is whatever canned JSON EP-1's fake
`completeRegistrationCeremony` is wired to accept (e.g. `object ["fake" .= ("ok" :: Text)]`);
define it once at the top of the scenario and pass the same value the fake interpreter checks for.

**Acceptance for Milestone 2.** From `/Users/shinzui/Keikaku/bokuno/shomei`, `cabal build all`
and `cabal test all` are green; the servant HTTP test's passkey block shows begin=200,
complete=200 with the label echoed, list=200 with one entry, delete=204, list=200 empty, and the
wrong-ceremony complete=404.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop` (the project's GHC 9.12.4 toolchain). Shōmei uses Cabal; `mori show --full` (run
once at the start) confirms the package layout.

Milestone 1:

```bash
# 1. Confirm EP-1 / EP-2 are present (their modules must import cleanly).
cabal build shomei-core

# 2. After editing Event.hs, Error.hs, adding Workflow/Passkey.hs + PasskeySpec.hs and the cabal stanzas:
cabal build shomei-core
cabal test shomei-core
```

Expected (abbreviated) on success:

```text
Build profile: -w ghc-9.12.4 -O1
...
Test suite shomei-core-test: RUNNING...
  Shomei.Workflow.Passkey
    begin then complete stores a passkey:        OK
    list returns the enrolled passkey:           OK
    remove deletes the passkey:                  OK
    wrong-user complete is rejected:             OK
    absent/expired ceremony is rejected:         OK
    rejected credential yields WebAuthnError:     OK
All N tests passed
Test suite shomei-core-test: PASS
```

Milestone 2:

```bash
# After editing API.hs, DTO.hs, Handlers.hs, Error.hs (servant), AuthEventPublisher.hs (postgres),
# and the servant test Main.hs:
cabal build all
cabal test all
```

Expected (abbreviated) for the servant suite:

```text
Test suite shomei-servant-test: RUNNING...
HTTP end-to-end (in-memory interpreters + in-test ES256 key)
  signup → ... → passkey begin/complete/list/delete: OK
All 1 tests passed
Test suite shomei-servant-test: PASS
```

Optional manual `curl` walkthrough against a running server (after `cabal run shomei-server`, with
a real login to obtain `$ACCESS`). This exercises the *real* `shomei-webauthn` interpreter, so the
`credential` payload must be a genuine browser `webauthn-json` registration response — in practice
produced by EP-5's demo page, not hand-written. Shown for shape only:

```bash
# Begin (authenticated):
curl -s -X POST http://localhost:8080/auth/passkeys/register/begin \
  -H "Authorization: Bearer $ACCESS"
# -> {"ceremonyId":"webauthn_ceremony_01j...","options":{ "publicKey": { "challenge": "...", "rp": {...}, "user": {...}, "excludeCredentials": [], ... } }}

# Complete (authenticated; CREDENTIAL is the browser's navigator.credentials.create() output):
curl -s -X POST http://localhost:8080/auth/passkeys/register/complete \
  -H "Authorization: Bearer $ACCESS" -H "Content-Type: application/json" \
  -d '{"ceremonyId":"webauthn_ceremony_01j...","credential":'"$CREDENTIAL"',"label":"Ada'\''s YubiKey"}'
# -> {"passkeyId":"passkey_01j...","label":"Ada's YubiKey","transports":["internal"],"createdAt":"2026-06-17T...","lastUsedAt":null}

# List:
curl -s http://localhost:8080/auth/passkeys -H "Authorization: Bearer $ACCESS"
# -> [{"passkeyId":"passkey_01j...","label":"Ada's YubiKey","transports":["internal"],"createdAt":"...","lastUsedAt":null}]

# Delete:
curl -s -o /dev/null -w "%{http_code}\n" -X DELETE \
  http://localhost:8080/auth/passkeys/passkey_01j... -H "Authorization: Bearer $ACCESS"
# -> 204
```


## Validation and Acceptance

Acceptance is observable behavior, not just compilation:

- **Enroll.** After Milestone 2, a request to `POST /auth/passkeys/register/begin` with a valid
  bearer token returns HTTP 200 and a body `{"ceremonyId":"webauthn_ceremony_…","options":{…}}`
  whose `options` is the WebAuthn creation options object. A follow-up `POST
  /auth/passkeys/register/complete` echoing that `ceremonyId` with an acceptable `credential`
  returns HTTP 200 and a `PasskeyResponse` whose `label` matches what was sent.
- **List.** `GET /auth/passkeys` then returns a one-element array containing that passkey, and
  the response never contains the public-key bytes (only id, label, transports, timestamps).
- **Remove.** `DELETE /auth/passkeys/{passkeyId}` returns HTTP 204; a subsequent `GET
  /auth/passkeys` returns an empty array.
- **Isolation.** A complete with a wrong/absent/expired/already-consumed ceremony id returns HTTP
  404 with `{"error":"ceremony_not_found",…}`. A delete of a passkey id not owned by the caller
  returns HTTP 404 with `{"error":"passkey_not_found",…}`. A complete whose `credential` fails
  verification returns HTTP 400 with `{"error":"webauthn_verification_failed",…}`. Every passkey
  route without a bearer token returns 401 (handled by the existing `Authenticated` combinator).
- **Audit.** Enrollment writes a `passkey_registered` event and deletion a `passkey_removed`
  event. In the in-memory test these are observable in the `World`'s event log; under PostgreSQL
  they appear in `shomei_auth_events` with the corresponding `event_type` and a JSON payload
  carrying `userId`, `passkeyId`, `occurredAt`.
- **Tests.** `cabal test all` is green; the new `shomei-core` `PasskeySpec` and the extended
  `shomei-servant` HTTP scenario both pass. These tests fail before the changes (the modules/routes
  do not exist) and pass after — that delta is the proof the change is effective beyond compiling.

The headline user-visible outcome: an authenticated user can enroll, list, and remove passkeys
over HTTP, and the server stores only public keys and records an audit trail.


## Idempotence and Recovery

Every edit is additive and may be re-applied safely:

- Adding `AuthEvent` arms, `AuthError` constructors, DTOs, routes, and handlers is purely
  additive; re-running the steps just re-states the same code. If a partial edit leaves the build
  red (e.g. a non-exhaustive `projectAuthEvent` after adding the events but before mapping them),
  finishing the remaining step in the same milestone restores green — implement Milestone 1 fully
  before Milestone 2.
- The *begin* operation is **safe to retry**: each call mints a fresh `ceremonyId` and pending
  row; abandoned ceremonies expire via the TTL (EP-2's `takePendingCeremony` filters on
  `expiresAt`). *Complete* is **consume-once** by construction — `takePendingCeremony` removes the
  row, so a duplicate complete (a double-submit) finds nothing and returns 404, which is the
  correct, safe behavior.
- *Delete* is idempotent at the observable level: deleting an already-deleted (or never-existed)
  passkey returns 404; the system state is unchanged either way. No destructive migration is
  introduced by this plan (the events reuse the existing table), so there is nothing to roll back
  at the schema level.
- If EP-1/EP-2 land with different type names than the Consumed-contract section assumes, the
  recovery is mechanical: update the imports and the Consumed-contract section, re-run
  `cabal build`, and record the rename in the Decision Log. The *logic* of the workflow does not
  change.


## Interfaces and Dependencies

This plan adds the module `Shomei.Workflow.Passkey` (in `shomei-core`), extends
`Shomei.Domain.Event`, `Shomei.Error`, `Shomei.Servant.API`, `Shomei.Servant.DTO`,
`Shomei.Servant.Handlers`, `Shomei.Servant.Error`, and `Shomei.Postgres.AuthEventPublisher`, and
extends the `shomei-servant` test. It introduces no new package and no new third-party dependency
(it reuses `aeson`, `effectful`, `servant`, `time`, `text`, `uuid` already present). The
`shomei-webauthn` package and the `webauthn` library are pulled in *transitively* via EP-1's
ports — EP-3 names no `webauthn` library type.

### Function signatures that must exist at the end of each milestone

End of Milestone 1 (in `Shomei.Workflow.Passkey`):

```haskell
beginPasskeyRegistration ::
    (UserStore :> es, PasskeyStore :> es, PendingCeremonyStore :> es,
     WebAuthnCeremony :> es, Clock :> es, TokenGen :> es) =>
    ShomeiConfig -> UserId -> Eff es (Either AuthError (CeremonyId, Value))

completePasskeyRegistration ::
    (PasskeyStore :> es, PendingCeremonyStore :> es, WebAuthnCeremony :> es,
     AuthEventPublisher :> es, Clock :> es) =>
    ShomeiConfig -> UserId -> CeremonyId -> Value -> Maybe Text ->
    Eff es (Either AuthError PasskeyCredential)

listPasskeys :: (PasskeyStore :> es) => UserId -> Eff es [PasskeyCredential]

removePasskey ::
    (PasskeyStore :> es, AuthEventPublisher :> es, Clock :> es) =>
    UserId -> PasskeyId -> Eff es (Either AuthError ())
```

And in `Shomei.Error`: `WebAuthnCeremonyError WebAuthnError`, `PasskeyNotFound`,
`PendingCeremonyNotFound` are constructors of `AuthError`. In `Shomei.Domain.Event`:
`PasskeyRegistered PasskeyRegisteredData`, `PasskeyRemoved PasskeyRemovedData`, with the records
exported.

End of Milestone 2 (in `Shomei.Servant.DTO`):

```haskell
data PasskeyRegisterBeginResponse = PasskeyRegisterBeginResponse { ceremonyId :: !Text, options :: !Value }
data PasskeyRegisterCompleteRequest = PasskeyRegisterCompleteRequest { ceremonyId :: !Text, credential :: !Value, label :: !(Maybe Text) }
data PasskeyResponse = PasskeyResponse { passkeyId :: !Text, label :: !(Maybe Text), transports :: ![Text], createdAt :: !Text, lastUsedAt :: !(Maybe Text) }
passkeyToResponse :: PasskeyCredential -> PasskeyResponse
```

The four `ShomeiAPI` fields `passkeyRegisterBegin`, `passkeyRegisterComplete`, `passkeyList`,
`passkeyDelete` exist with the route shapes from Step 2.1, and the four handlers are wired into
`shomeiServer`.

### Wire JSON shapes (the HTTP contract)

`POST /auth/passkeys/register/begin` — request: empty body (the principal comes from the bearer
token). Response 200:

```json
{
  "ceremonyId": "webauthn_ceremony_01j8z9m4q5e7f8g9h0j1k2l3m4",
  "options": {
    "publicKey": {
      "challenge": "Base64URL-challenge",
      "rp": { "id": "auth.example.com", "name": "Example" },
      "user": { "id": "Base64URL-userHandle", "name": "ada@example.com", "displayName": "Ada Lovelace" },
      "pubKeyCredParams": [ { "type": "public-key", "alg": -7 } ],
      "excludeCredentials": [],
      "authenticatorSelection": { "userVerification": "preferred" },
      "timeout": 60000,
      "attestation": "none"
    }
  }
}
```

`POST /auth/passkeys/register/complete` — request:

```json
{
  "ceremonyId": "webauthn_ceremony_01j8z9m4q5e7f8g9h0j1k2l3m4",
  "credential": {
    "id": "Base64URL-credentialId",
    "rawId": "Base64URL-credentialId",
    "type": "public-key",
    "response": {
      "clientDataJSON": "Base64URL...",
      "attestationObject": "Base64URL..."
    },
    "clientExtensionResults": {}
  },
  "label": "Ada's YubiKey"
}
```

Response 200 (and the same shape is one element of the `GET /auth/passkeys` array):

```json
{
  "passkeyId": "passkey_01j8z9m4q5e7f8g9h0j1k2l3m4",
  "label": "Ada's YubiKey",
  "transports": ["internal", "hybrid"],
  "createdAt": "2026-06-17T14:38:15Z",
  "lastUsedAt": null
}
```

`GET /auth/passkeys` — response 200: a JSON array of the above object. `DELETE
/auth/passkeys/{passkeyId}` — response 204 with no body. Error bodies use the existing structured
shape, e.g. `{"error":"ceremony_not_found","message":"Registration ceremony not found or
expired"}` (404), `{"error":"passkey_not_found","message":"Passkey not found"}` (404),
`{"error":"webauthn_verification_failed","message":"Passkey registration could not be verified"}`
(400).

### Consumed contract from EP-1 and EP-2 (reproduce verbatim; reconcile if they drift)

These are the EP-1/EP-2 types and effects this plan calls. They are stated here so this plan is
self-contained; the authoritative definitions live in EP-1 (`docs/plans/15-…`) and EP-2
(`docs/plans/16-…`). If those plans land with different names, update this section and the
Decision Log, then adjust the imports.

EP-1 domain types (assumed module `Shomei.Domain.Passkey`, re-exporting ids from `Shomei.Id`):

```haskell
type PasskeyId   = KindID "passkey"            -- from Shomei.Id (EP-1)
type CeremonyId  = KindID "webauthn_ceremony"  -- from Shomei.Id (EP-1)

newtype WebAuthnCredentialId = WebAuthnCredentialId ByteString
newtype UserHandle           = UserHandle ByteString
newtype PublicKeyBytes       = PublicKeyBytes ByteString
newtype SignatureCounter     = SignatureCounter Word32

data CredentialUserInfo = CredentialUserInfo
    { userHandle  :: UserHandle
    , accountName :: Text   -- the email
    , displayName :: Text
    }

data BeginCeremony = BeginCeremony
    { optionsJson :: Value       -- browser-facing creation options
    , optionsBlob :: ByteString  -- opaque persisted blob for later verify
    }

data VerifiedRegistration = VerifiedRegistration
    { credentialId :: WebAuthnCredentialId
    , userHandle   :: UserHandle
    , publicKey    :: PublicKeyBytes
    , signCounter  :: SignatureCounter
    , transports   :: [Text]     -- (or a transport newtype with `transportText`)
    }

data PasskeyCredential = PasskeyCredential
    { passkeyId    :: PasskeyId
    , userId       :: UserId
    , credentialId :: WebAuthnCredentialId
    , userHandle   :: UserHandle
    , publicKey    :: PublicKeyBytes
    , signCounter  :: SignatureCounter
    , transports   :: [Text]
    , label        :: Maybe Text
    , createdAt    :: UTCTime
    , lastUsedAt   :: Maybe UTCTime
    }

data NewPasskeyCredential = NewPasskeyCredential
    { userId       :: UserId
    , credentialId :: WebAuthnCredentialId
    , userHandle   :: UserHandle
    , publicKey    :: PublicKeyBytes
    , signCounter  :: SignatureCounter
    , transports   :: [Text]
    , label        :: Maybe Text
    , createdAt    :: UTCTime
    }

data CeremonyKind = RegistrationCeremony | AuthenticationCeremony  deriving Eq

data PendingCeremony = PendingCeremony
    { ceremonyId  :: CeremonyId
    , userId      :: Maybe UserId
    , kind        :: CeremonyKind
    , optionsBlob :: ByteString
    , createdAt   :: UTCTime
    , expiresAt   :: UTCTime
    }
```

EP-1 effect `Shomei.Effect.WebAuthnCeremony` (the smart-constructor send functions in lowercase):

```haskell
data WebAuthnError = ...  -- a domain sum; derives Generic/Eq/Show/FromJSON/ToJSON

beginRegistrationCeremony    :: (WebAuthnCeremony :> es) => CredentialUserInfo -> [WebAuthnCredentialId] -> Eff es BeginCeremony
completeRegistrationCeremony :: (WebAuthnCeremony :> es) => ByteString -> Value -> Eff es (Either WebAuthnError VerifiedRegistration)
-- generateCeremonyId is assumed for minting CeremonyIds; if EP-1 puts id generation in Shomei.Id
-- (e.g. genCeremonyId :: MonadIO m => m CeremonyId) call that instead and drop the import. See Decision Log.
generateCeremonyId           :: (WebAuthnCeremony :> es) => Eff es CeremonyId
```

EP-2 effects `Shomei.Effect.PasskeyStore` and `Shomei.Effect.PendingCeremonyStore`:

```haskell
createPasskey            :: (PasskeyStore :> es) => NewPasskeyCredential -> Eff es PasskeyCredential
findPasskeysByUser       :: (PasskeyStore :> es) => UserId -> Eff es [PasskeyCredential]
findPasskeyByCredentialId:: (PasskeyStore :> es) => WebAuthnCredentialId -> Eff es (Maybe PasskeyCredential)
deletePasskey            :: (PasskeyStore :> es) => UserId -> PasskeyId -> Eff es ()
countPasskeysByUser      :: (PasskeyStore :> es) => UserId -> Eff es Int

putPendingCeremony  :: (PendingCeremonyStore :> es) => PendingCeremony -> Eff es ()
takePendingCeremony :: (PendingCeremonyStore :> es) => CeremonyId -> UTCTime -> Eff es (Maybe PendingCeremony)
```

EP-1 config (`Shomei.Config`): `ShomeiConfig` gains `webauthnConfig :: WebAuthnConfig`, and
`WebAuthnConfig` has at least `pendingCeremonyTTL :: NominalDiffTime` and `rpName :: Text` (the
interpreter reads `rpId`/`rpName`/origins; this plan only reads `pendingCeremonyTTL`).

EP-1/EP-2 must (per MasterPlan IP-6) have already appended `WebAuthnCeremony`, `PasskeyStore`,
and `PendingCeremonyStore` to `Shomei.Servant.Seam.AppEffects`, `Shomei.Server.App.AppEffects`
(+ `runAppIO`), and `Shomei.Effect.InMemory.runInMemory`, with their interpreters. EP-3 relies on
that and adds none of it.
