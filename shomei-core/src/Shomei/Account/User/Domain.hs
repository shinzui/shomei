-- | The user entity and its lifecycle status.
module Shomei.Account.User.Domain
  ( UserStatus (..),
    User (..),
    NewUser (..),
    validateNewUser,
  )
where

import Data.Aeson (withObject, (.:), (.:?))
import Data.Text qualified as Text
import Shomei.Account.Email.Domain (Email, emailText, mkEmail, parseStoredEmail)
import Shomei.Account.LoginId.Domain (LoginId, loginIdText, mkLoginId, parseLoginIdForAuthentication)
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId)
import Shomei.Prelude

data UserStatus = UserActive | UserSuspended | UserDeleted
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data User = User
  { userId :: !UserId,
    loginId :: !LoginId,
    email :: !(Maybe Email),
    displayName :: !(Maybe Text),
    status :: !UserStatus,
    emailVerifiedAt :: !(Maybe UTCTime),
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

-- Wire snapshots of persisted users deliberately retain legacy identity sizes.
instance FromJSON User where
  parseJSON = withObject "User" \o -> do
    loginId <- o .: "loginId" >>= either (const (fail "invalid stored login identifier")) pure . parseLoginIdForAuthentication
    email <- o .:? "email" >>= traverse (either (const (fail "invalid stored email")) pure . parseStoredEmail)
    User
      <$> o .: "userId"
      <*> pure loginId
      <*> pure email
      <*> o .:? "displayName"
      <*> o .: "status"
      <*> o .:? "emailVerifiedAt"
      <*> o .: "createdAt"
      <*> o .: "updatedAt"

data NewUser = NewUser
  { loginId :: !LoginId,
    email :: !(Maybe Email),
    displayName :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

validateNewUser :: NewUser -> Either AuthError ()
validateNewUser new = do
  _ <- mkLoginId (loginIdText new.loginId)
  _ <- traverse (mkEmail . emailText) new.email
  when (maybe False ((> 256) . Text.length) new.displayName) (Left InvalidInput)

instance FromJSON NewUser where
  parseJSON = withObject "NewUser" \o -> do
    new <- NewUser <$> o .: "loginId" <*> o .:? "email" <*> o .:? "displayName"
    either (const (fail "invalid new user")) (const (pure new)) (validateNewUser new)
