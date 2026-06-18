-- | Authenticated passkey enrollment and management workflows (MasterPlan 3, EP-3).
--
-- A "passkey" is a stored public-key credential. These workflows let an already-authenticated
-- user begin a WebAuthn registration ceremony, complete it (verifying the browser's answer and
-- storing the public key), list their passkeys, and remove one. They are written purely against
-- port effects, so the same code runs over the in-memory test interpreters and the real
-- PostgreSQL + @shomei-webauthn@ interpreters. Login (the assertion ceremony) is EP-4, not here.
--
-- The ceremony types ('CredentialUserInfo', 'BeginCeremony', 'VerifiedRegistration') and the
-- ceremony effect live in 'Shomei.Effect.WebAuthnCeremony' (EP-1); the stored passkey/pending
-- types in 'Shomei.Domain.Passkey' (EP-1); the two stores in 'Shomei.Effect.PasskeyStore' /
-- 'Shomei.Effect.PendingCeremonyStore' (EP-2). OverloadedRecordDot is unreliable for those EP-1
-- records (a MasterPlan-3 discovery), so they are read via plain record-pattern matching.
module Shomei.Workflow.Passkey
  ( beginPasskeyRegistration,
    completePasskeyRegistration,
    listPasskeys,
    removePasskey,
  )
where

import Data.Aeson (Value)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Config (ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginId (loginIdText)
import Shomei.Domain.Passkey
  ( CeremonyKind (RegistrationCeremony),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    UserHandle (..),
  )
import Shomei.Domain.User (User (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.PasskeyStore (PasskeyStore, createPasskey, deletePasskey, findPasskeysByUser)
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony, takePendingCeremony)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Effect.WebAuthnCeremony
  ( BeginCeremony (..),
    CredentialUserInfo (..),
    VerifiedRegistration (..),
    WebAuthnCeremony,
    beginRegistrationCeremony,
    completeRegistrationCeremony,
  )
import Shomei.Error (AuthError (..))
import Shomei.Id (CeremonyId, PasskeyId, UserId, genCeremonyId, userIdToUUID)
import Shomei.Prelude

-- | Derive a stable WebAuthn user handle from the Shōmei user id: the 16 bytes of the
-- user's UUID. All of a user's passkeys therefore share one handle, so a passwordless login
-- (EP-4) can resolve the user from the handle alone. We deliberately do not use a random
-- handle (see the MasterPlan Decision Log).
userHandleForUser :: UserId -> UserHandle
userHandleForUser uid = UserHandle (BSL.toStrict (UUID.toByteString (userIdToUUID uid)))

-- | Collapse a blank label to 'Nothing' (mirrors @mkDisplayName@ in the handlers).
normalizeLabel :: Text -> Maybe Text
normalizeLabel t
  | Text.null (Text.strip t) = Nothing
  | otherwise = Just (Text.strip t)

beginPasskeyRegistration ::
  ( UserStore :> es,
    PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    Clock :> es,
    IOE :> es
  ) =>
  ShomeiConfig ->
  UserId ->
  Eff es (Either AuthError (CeremonyId, Value))
beginPasskeyRegistration cfg uid = runErrorNoCallStack do
  ts <- now
  user <- maybe (throwError InvalidCredentials) pure =<< findUserById uid
  existing <- findPasskeysByUser uid
  -- The human-readable label shown in the browser's passkey UI: prefer the email when
  -- present, otherwise fall back to the login identifier (the user handle itself is
  -- always derived from the user id, so it is unaffected by a missing email).
  let accountLabel = maybe (loginIdText user.loginId) emailText user.email
      info =
        CredentialUserInfo
          { userHandle = userHandleForUser uid,
            accountName = accountLabel,
            displayName = fromMaybe accountLabel user.displayName
          }
      excludeIds = map (\PasskeyCredential {credentialId} -> credentialId) existing
  BeginCeremony {optionsJson, optionsBlob} <- beginRegistrationCeremony info excludeIds
  ceremonyId <- genCeremonyId
  putPendingCeremony
    PendingCeremony
      { ceremonyId = ceremonyId,
        userId = Just uid,
        kind = RegistrationCeremony,
        optionsBlob = optionsBlob,
        createdAt = ts,
        expiresAt = addUTCTime (pendingCeremonyTTL (webauthnConfig cfg)) ts
      }
  pure (ceremonyId, optionsJson)

completePasskeyRegistration ::
  ( PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  UserId ->
  CeremonyId ->
  Value ->
  Maybe Text ->
  Eff es (Either AuthError PasskeyCredential)
completePasskeyRegistration _cfg uid ceremonyId credentialJson mLabel = runErrorNoCallStack do
  ts <- now
  PendingCeremony {kind, userId = pendingUid, optionsBlob} <-
    maybe (throwError PendingCeremonyNotFound) pure =<< takePendingCeremony ceremonyId ts
  -- Reject a ceremony that is not a registration, or that was begun for a different user.
  when (kind /= RegistrationCeremony) (throwError PendingCeremonyNotFound)
  when (pendingUid /= Just uid) (throwError PendingCeremonyNotFound)
  VerifiedRegistration {credentialId, userHandle, publicKey, signCounter, transports} <-
    either (throwError . WebAuthnCeremonyError) pure
      =<< completeRegistrationCeremony optionsBlob credentialJson
  passkey <-
    createPasskey
      NewPasskeyCredential
        { userId = uid,
          credentialId,
          userHandle,
          publicKey,
          signCounter,
          transports,
          label = normalizeLabel =<< mLabel,
          createdAt = ts
        }
  let PasskeyCredential {passkeyId} = passkey
  publishAuthEvent (Event.PasskeyRegistered (Event.PasskeyRegisteredData uid passkeyId ts))
  pure passkey

listPasskeys ::
  (PasskeyStore :> es) =>
  UserId ->
  Eff es [PasskeyCredential]
listPasskeys = findPasskeysByUser

removePasskey ::
  ( PasskeyStore :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  UserId ->
  PasskeyId ->
  Eff es (Either AuthError ())
removePasskey uid pid = runErrorNoCallStack do
  ts <- now
  owned <- findPasskeysByUser uid
  unless (any (\PasskeyCredential {passkeyId} -> passkeyId == pid) owned) (throwError PasskeyNotFound)
  deletePasskey uid pid
  publishAuthEvent (Event.PasskeyRemoved (Event.PasskeyRemovedData uid pid ts))
