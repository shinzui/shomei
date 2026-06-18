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
  )
where

import Data.Time (UTCTime)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Email (Email)
import Shomei.Domain.LoginId (LoginId)
import Shomei.Domain.User (NewUser, User, UserStatus)
import Shomei.Id (UserId)

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
