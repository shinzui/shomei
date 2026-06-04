{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The credential-store port: persisting and looking up password credentials.
module Shomei.Effect.CredentialStore (
    CredentialStore (..),
    createPasswordCredential,
    findPasswordCredentialByEmail,
    updatePasswordHash,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Credential (Credential)
import Shomei.Domain.Email (Email)
import Shomei.Domain.Password (PasswordHash)
import Shomei.Id (UserId)

data CredentialStore :: Effect where
    CreatePasswordCredential :: UserId -> Email -> PasswordHash -> CredentialStore m Credential
    FindPasswordCredentialByEmail :: Email -> CredentialStore m (Maybe Credential)
    UpdatePasswordHash :: UserId -> PasswordHash -> CredentialStore m ()

type instance DispatchOf CredentialStore = Dynamic

createPasswordCredential :: (CredentialStore :> es) => UserId -> Email -> PasswordHash -> Eff es Credential
createPasswordCredential uid e h = send (CreatePasswordCredential uid e h)

findPasswordCredentialByEmail :: (CredentialStore :> es) => Email -> Eff es (Maybe Credential)
findPasswordCredentialByEmail = send . FindPasswordCredentialByEmail

updatePasswordHash :: (CredentialStore :> es) => UserId -> PasswordHash -> Eff es ()
updatePasswordHash uid h = send (UpdatePasswordHash uid h)
