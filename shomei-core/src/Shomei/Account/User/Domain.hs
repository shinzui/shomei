-- | The user entity and its lifecycle status.
module Shomei.Account.User.Domain
  ( UserStatus (..),
    User (..),
    NewUser (..),
  )
where

import Shomei.Account.Email.Domain (Email)
import Shomei.Account.LoginId.Domain (LoginId)
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
  deriving anyclass (FromJSON, ToJSON)

data NewUser = NewUser
  { loginId :: !LoginId,
    email :: !(Maybe Email),
    displayName :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
