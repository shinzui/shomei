-- | The password credential entity: the binding of a login id + password hash to a user.
module Shomei.Account.Credential.Domain
  ( Credential (..),
  )
where

import Data.Aeson (withObject, (.:), (.:?))
import Shomei.Account.Email.Domain (Email, parseStoredEmail)
import Shomei.Account.LoginId.Domain (LoginId, parseLoginIdForAuthentication)
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
  deriving anyclass (ToJSON)

instance FromJSON Credential where
  parseJSON = withObject "Credential" \o -> do
    loginId <- o .: "loginId" >>= either (const (fail "invalid stored login identifier")) pure . parseLoginIdForAuthentication
    email <- o .:? "email" >>= traverse (either (const (fail "invalid stored email")) pure . parseStoredEmail)
    PasswordCredential
      <$> o .: "credentialId"
      <*> o .: "userId"
      <*> pure loginId
      <*> pure email
      <*> o .: "passwordHash"
      <*> o .: "createdAt"
      <*> o .: "updatedAt"
