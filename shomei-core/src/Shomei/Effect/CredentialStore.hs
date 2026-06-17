{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The credential-store port: persisting and looking up password credentials.
module Shomei.Effect.CredentialStore (
    CredentialStore (..),
    createPasswordCredential,
    findPasswordCredentialByLoginId,
    findPasswordCredentialByEmail,
    updatePasswordHash,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Credential (Credential)
import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginId (LoginId)
import Shomei.Domain.Password (PasswordHash)
import Shomei.Id (UserId)

data CredentialStore :: Effect where
    -- | Create a password credential. The principal is the login id; email is optional
    -- metadata retained for the reset-by-email path.
    CreatePasswordCredential :: UserId -> LoginId -> Maybe Email -> PasswordHash -> CredentialStore m Credential
    -- | Resolve a credential by its principal login identifier (the login lookup).
    FindPasswordCredentialByLoginId :: LoginId -> CredentialStore m (Maybe Credential)
    -- | Resolve a credential by email; retained for the reset-by-email path.
    FindPasswordCredentialByEmail :: Email -> CredentialStore m (Maybe Credential)
    UpdatePasswordHash :: UserId -> PasswordHash -> CredentialStore m ()

type instance DispatchOf CredentialStore = Dynamic

createPasswordCredential :: (CredentialStore :> es) => UserId -> LoginId -> Maybe Email -> PasswordHash -> Eff es Credential
createPasswordCredential uid lid mEmail h = send (CreatePasswordCredential uid lid mEmail h)

findPasswordCredentialByLoginId :: (CredentialStore :> es) => LoginId -> Eff es (Maybe Credential)
findPasswordCredentialByLoginId = send . FindPasswordCredentialByLoginId

findPasswordCredentialByEmail :: (CredentialStore :> es) => Email -> Eff es (Maybe Credential)
findPasswordCredentialByEmail = send . FindPasswordCredentialByEmail

updatePasswordHash :: (CredentialStore :> es) => UserId -> PasswordHash -> Eff es ()
updatePasswordHash uid h = send (UpdatePasswordHash uid h)
