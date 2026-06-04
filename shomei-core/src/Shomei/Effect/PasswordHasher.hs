{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The password-hasher port: hashing and verifying passwords (Argon2id in production,
EP-3).
-}
module Shomei.Effect.PasswordHasher (
    PasswordHasher (..),
    hashPassword,
    verifyPassword,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Password (PasswordHash, PlainPassword)

data PasswordHasher :: Effect where
    HashPassword :: PlainPassword -> PasswordHasher m PasswordHash
    VerifyPassword :: PlainPassword -> PasswordHash -> PasswordHasher m Bool

type instance DispatchOf PasswordHasher = Dynamic

hashPassword :: (PasswordHasher :> es) => PlainPassword -> Eff es PasswordHash
hashPassword = send . HashPassword

verifyPassword :: (PasswordHasher :> es) => PlainPassword -> PasswordHash -> Eff es Bool
verifyPassword p h = send (VerifyPassword p h)
