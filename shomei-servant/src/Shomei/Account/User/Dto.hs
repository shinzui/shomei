-- | User and administrative-account wire types.
module Shomei.Account.User.Dto
  ( UserResponse (..),
    AdminUserResponse (..),
    AdminUsersPage (..),
    AdminStatusFilter (..),
    UserPageCursor (..),
    userToResponse,
    adminUserToResponse,
    encodeUserCursor,
    decodeUserCursor,
  )
where

import Data.List (sort)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID qualified as UUID
import Shomei.Account.Email.Domain (emailText)
import Shomei.Account.LoginId.Domain (loginIdText)
import Shomei.Account.User.Domain (User (..), UserStatus (..))
import Shomei.Account.User.Store (UserCursor (..))
import Shomei.Authorization.Claims.Domain (Role (..))
import Shomei.Id (idText, userIdFromUUID, userIdToUUID)
import Shomei.Prelude
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

data UserResponse = UserResponse
  { userId :: !Text,
    loginId :: !Text,
    email :: !(Maybe Text),
    displayName :: !Text,
    status :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdminUserResponse = AdminUserResponse
  { user :: !UserResponse,
    roles :: ![Text]
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdminUsersPage = AdminUsersPage
  { users :: ![UserResponse],
    nextCursor :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype AdminStatusFilter = AdminStatusFilter {userStatus :: UserStatus}
  deriving stock (Eq, Show)

instance FromHttpApiData AdminStatusFilter where
  parseUrlPiece = \case
    "active" -> Right (AdminStatusFilter UserActive)
    "suspended" -> Right (AdminStatusFilter UserSuspended)
    "deleted" -> Right (AdminStatusFilter UserDeleted)
    other -> Left ("invalid status parameter: " <> other <> " (expected active, suspended, or deleted)")

instance ToHttpApiData AdminStatusFilter where
  toUrlPiece (AdminStatusFilter status) = renderUserStatus status

newtype UserPageCursor = UserPageCursor {userCursor :: UserCursor}
  deriving stock (Eq, Show)

instance FromHttpApiData UserPageCursor where
  parseUrlPiece value = maybe (Left "invalid before cursor") (Right . UserPageCursor) (decodeUserCursor value)

instance ToHttpApiData UserPageCursor where
  toUrlPiece = encodeUserCursor . (.userCursor)

userToResponse :: User -> UserResponse
userToResponse user =
  UserResponse
    { userId = idText user.userId,
      loginId = loginIdText user.loginId,
      email = emailText <$> user.email,
      displayName = fromMaybe "" user.displayName,
      status = renderUserStatus user.status
    }

adminUserToResponse :: User -> Set Role -> AdminUserResponse
adminUserToResponse user roles =
  AdminUserResponse
    { user = userToResponse user,
      roles = sort [name | Role name <- Set.toList roles]
    }

renderUserStatus :: UserStatus -> Text
renderUserStatus = \case
  UserActive -> "active"
  UserSuspended -> "suspended"
  UserDeleted -> "deleted"

encodeUserCursor :: UserCursor -> Text
encodeUserCursor cursor =
  Text.pack (iso8601Show cursor.cursorCreatedAt)
    <> ";"
    <> UUID.toText (userIdToUUID cursor.cursorUserId)

decodeUserCursor :: Text -> Maybe UserCursor
decodeUserCursor value = case Text.breakOn ";" value of
  (timestamp, rest)
    | Just identifier <- Text.stripPrefix ";" rest -> do
        createdAt <- iso8601ParseM (Text.unpack timestamp)
        userId <- userIdFromUUID <$> UUID.fromText identifier
        pure UserCursor {cursorCreatedAt = createdAt, cursorUserId = userId}
  _ -> Nothing
