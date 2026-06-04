-- | The password credential entity: the binding of an email + password hash to a user.
module Shomei.Domain.Credential (
    Credential (..),
) where

import Shomei.Prelude

import Shomei.Domain.Email (Email)
import Shomei.Domain.Password (PasswordHash)
import Shomei.Id (CredentialId, UserId)

data Credential = PasswordCredential
    { credentialId :: !CredentialId
    , userId :: !UserId
    , email :: !Email
    , passwordHash :: !PasswordHash
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
