-- | The password credential entity: the binding of a login id + password hash to a user.
module Shomei.Account.Credential.Domain
  ( Credential (..),
  )
where

import Shomei.Account.Email.Domain (Email)
import Shomei.Account.LoginId.Domain (LoginId)
import Shomei.Account.Password.Domain (PasswordHash)
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
