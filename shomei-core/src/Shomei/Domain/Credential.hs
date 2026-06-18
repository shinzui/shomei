-- | The password credential entity: the binding of a login id + password hash to a user.
module Shomei.Domain.Credential
  ( Credential (..),
  )
where

import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginId (LoginId)
import Shomei.Domain.Password (PasswordHash)
import Shomei.Id (CredentialId, UserId)
import Shomei.Prelude

data Credential = PasswordCredential
  { credentialId :: !CredentialId,
    userId :: !UserId,
    loginId :: !LoginId,
    email :: !(Maybe Email),
    passwordHash :: !PasswordHash,
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
