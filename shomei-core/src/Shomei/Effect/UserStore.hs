{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The user-store port: persisting and looking up 'User' records.
module Shomei.Effect.UserStore
  ( UserStore (..),
    createUser,
    findUserById,
    findUserByLoginId,
    findUserByEmail,
    updateUserStatus,
    markUserEmailVerified,

    -- * Listing (EP-2)
    UserCursor (..),
    UserListQuery (..),
    emptyUserListQuery,
    maxUserLimit,
    clampUserLimit,
    listUsers,
  )
where

import Data.Time (UTCTime)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginId (LoginId)
import Shomei.Domain.User (NewUser, User, UserStatus)
import Shomei.Id (UserId)

-- | A keyset-pagination cursor over @(created_at, user_id)@, newest first. Pointing at a row
-- rather than counting offsets means a page boundary cannot shift under concurrent signups.
data UserCursor = UserCursor
  { cursorCreatedAt :: !UTCTime,
    cursorUserId :: !UserId
  }
  deriving stock (Eq, Show)

-- | Filters and pagination for 'ListUsers'. Deliberately its own type rather than a share with
-- 'Shomei.Effect.AuthEventReader.AuditEventQuery': different port, different filters.
data UserListQuery = UserListQuery
  { queryStatus :: !(Maybe UserStatus),
    -- | Pass through 'clampUserLimit' before it reaches a database.
    queryLimit :: !Int,
    queryBefore :: !(Maybe UserCursor)
  }
  deriving stock (Eq, Show)

-- | No filter, 50 rows, from the top.
emptyUserListQuery :: UserListQuery
emptyUserListQuery = UserListQuery Nothing 50 Nothing

maxUserLimit :: Int
maxUserLimit = 1000

clampUserLimit :: Int -> Int
clampUserLimit n = max 1 (min maxUserLimit n)

data UserStore :: Effect where
  CreateUser :: NewUser -> UserStore m User
  FindUserById :: UserId -> UserStore m (Maybe User)
  -- | Look a user up by their principal login identifier.
  FindUserByLoginId :: LoginId -> UserStore m (Maybe User)
  -- | Look a user up by email. No longer the principal lookup, but retained for the
  -- reset/verification flows a caller initiates /by typing an email/.
  FindUserByEmail :: Email -> UserStore m (Maybe User)
  UpdateUserStatus :: UserId -> UserStatus -> UserStore m ()
  MarkUserEmailVerified :: UserId -> UTCTime -> UserStore m ()
  -- | Newest-first page of users, optionally filtered by status. Soft-deleted users are
  -- included: the admin surface is honest about them.
  ListUsers :: UserListQuery -> UserStore m [User]

type instance DispatchOf UserStore = Dynamic

createUser :: (UserStore :> es) => NewUser -> Eff es User
createUser = send . CreateUser

findUserById :: (UserStore :> es) => UserId -> Eff es (Maybe User)
findUserById = send . FindUserById

findUserByLoginId :: (UserStore :> es) => LoginId -> Eff es (Maybe User)
findUserByLoginId = send . FindUserByLoginId

findUserByEmail :: (UserStore :> es) => Email -> Eff es (Maybe User)
findUserByEmail = send . FindUserByEmail

updateUserStatus :: (UserStore :> es) => UserId -> UserStatus -> Eff es ()
updateUserStatus uid st = send (UpdateUserStatus uid st)

markUserEmailVerified :: (UserStore :> es) => UserId -> UTCTime -> Eff es ()
markUserEmailVerified uid t = send (MarkUserEmailVerified uid t)

listUsers :: (UserStore :> es) => UserListQuery -> Eff es [User]
listUsers = send . ListUsers
