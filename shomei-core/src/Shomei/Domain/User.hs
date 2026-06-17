-- | The user entity and its lifecycle status.
module Shomei.Domain.User (
    UserStatus (..),
    User (..),
    NewUser (..),
) where

import Shomei.Prelude

import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginId (LoginId)
import Shomei.Id (UserId)

data UserStatus = UserActive | UserSuspended | UserDeleted
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data User = User
    { userId :: !UserId
    , loginId :: !LoginId
    , email :: !(Maybe Email)
    , displayName :: !(Maybe Text)
    , status :: !UserStatus
    , emailVerifiedAt :: !(Maybe UTCTime)
    , createdAt :: !UTCTime
    , updatedAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NewUser = NewUser
    { loginId :: !LoginId
    , email :: !(Maybe Email)
    , displayName :: !(Maybe Text)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
