{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The user-store port: persisting and looking up 'User' records.
module Shomei.Port.UserStore (
    UserStore (..),
    createUser,
    findUserById,
    findUserByEmail,
    updateUserStatus,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Email (Email)
import Shomei.Domain.User (NewUser, User, UserStatus)
import Shomei.Id (UserId)

data UserStore :: Effect where
    CreateUser :: NewUser -> UserStore m User
    FindUserById :: UserId -> UserStore m (Maybe User)
    FindUserByEmail :: Email -> UserStore m (Maybe User)
    UpdateUserStatus :: UserId -> UserStatus -> UserStore m ()

type instance DispatchOf UserStore = Dynamic

createUser :: (UserStore :> es) => NewUser -> Eff es User
createUser = send . CreateUser

findUserById :: (UserStore :> es) => UserId -> Eff es (Maybe User)
findUserById = send . FindUserById

findUserByEmail :: (UserStore :> es) => Email -> Eff es (Maybe User)
findUserByEmail = send . FindUserByEmail

updateUserStatus :: (UserStore :> es) => UserId -> UserStatus -> Eff es ()
updateUserStatus uid st = send (UpdateUserStatus uid st)
