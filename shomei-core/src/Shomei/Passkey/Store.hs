{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Store effect for registered passkeys (WebAuthn public-key credentials).
--
-- A passkey is the public half of a WebAuthn credential that an authenticator
-- created during a registration ceremony. This port persists those credentials and
-- offers the three lookups the workflows need: by owning user (enrollment listing),
-- by the authenticator-assigned credential id (the assertion key the browser returns),
-- and by the per-user 'UserHandle' (passwordless discovery in EP-4). It also bumps the
-- clone-detection signature counter, counts a user's passkeys, and deletes one.
--
-- The credential domain types are owned by EP-1 ('Shomei.Passkey.Domain'); this module
-- only references them. EP-2 supplies the in-memory and PostgreSQL interpreters.
module Shomei.Passkey.Store
  ( PasskeyStore (..),
    createPasskey,
    findPasskeysByUser,
    findPasskeyByCredentialId,
    findPasskeysByUserHandle,
    updatePasskeySignCounter,
    deletePasskey,
    countPasskeysByUser,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Id (PasskeyId, UserId)
import Shomei.Passkey.Domain
  ( NewPasskeyCredential,
    PasskeyCredential,
    SignatureCounter,
    UserHandle,
    WebAuthnCredentialId,
  )
import Shomei.Prelude

data PasskeyStore :: Effect where
  CreatePasskey :: NewPasskeyCredential -> PasskeyStore m PasskeyCredential
  FindPasskeysByUser :: UserId -> PasskeyStore m [PasskeyCredential]
  FindPasskeyByCredentialId :: WebAuthnCredentialId -> PasskeyStore m (Maybe PasskeyCredential)
  FindPasskeysByUserHandle :: UserHandle -> PasskeyStore m [PasskeyCredential]
  -- | Compare-and-swap the signature counter and @last_used_at@. 'False' means replay. A
  -- counterless authenticator's zero-to-zero update is accepted, matching WebAuthn clone checks.
  UpdatePasskeySignCounter :: PasskeyId -> SignatureCounter -> UTCTime -> PasskeyStore m Bool
  -- | Delete only when both the owning user and the passkey id match (a user action).
  DeletePasskey :: UserId -> PasskeyId -> PasskeyStore m ()
  CountPasskeysByUser :: UserId -> PasskeyStore m Int

type instance DispatchOf PasskeyStore = Dynamic

createPasskey :: (PasskeyStore :> es) => NewPasskeyCredential -> Eff es PasskeyCredential
createPasskey = send . CreatePasskey

findPasskeysByUser :: (PasskeyStore :> es) => UserId -> Eff es [PasskeyCredential]
findPasskeysByUser = send . FindPasskeysByUser

findPasskeyByCredentialId :: (PasskeyStore :> es) => WebAuthnCredentialId -> Eff es (Maybe PasskeyCredential)
findPasskeyByCredentialId = send . FindPasskeyByCredentialId

findPasskeysByUserHandle :: (PasskeyStore :> es) => UserHandle -> Eff es [PasskeyCredential]
findPasskeysByUserHandle = send . FindPasskeysByUserHandle

updatePasskeySignCounter :: (PasskeyStore :> es) => PasskeyId -> SignatureCounter -> UTCTime -> Eff es Bool
updatePasskeySignCounter i c t = send (UpdatePasskeySignCounter i c t)

deletePasskey :: (PasskeyStore :> es) => UserId -> PasskeyId -> Eff es ()
deletePasskey u p = send (DeletePasskey u p)

countPasskeysByUser :: (PasskeyStore :> es) => UserId -> Eff es Int
countPasskeysByUser = send . CountPasskeysByUser
