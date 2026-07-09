{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The password-hasher port: hashing and verifying passwords (Argon2id in production,
-- EP-3).
module Shomei.Effect.PasswordHasher
  ( PasswordHasher (..),
    hashPassword,
    verifyPassword,
    verifyPasswordDummy,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Password (PasswordHash, PlainPassword)

data PasswordHasher :: Effect where
  HashPassword :: PlainPassword -> PasswordHasher m PasswordHash
  VerifyPassword :: PlainPassword -> PasswordHash -> PasswordHasher m Bool
  -- | Perform exactly the work one 'VerifyPassword' costs, and discard the answer.
  --
  -- This exists for the login timing oracle: a login that fails before it ever reaches a
  -- stored hash (unknown account, suspended user) must be indistinguishable, by response
  -- time, from one that fails on a wrong password. Such a path has no hash to verify, so it
  -- burns an equivalent amount of hashing work instead.
  --
  -- It is a port operation rather than "verify against some constant hash" because only the
  -- interpreter knows the cost parameters in force. An Argon2 verification costs whatever the
  -- parameters embedded in the /stored/ hash say, so a hardcoded constant would drift out of
  -- step the moment an operator tuned the parameters — a login miss would cost 102 ms while a
  -- hit cost 19 ms, which is the very oracle this closes.
  VerifyPasswordDummy :: PlainPassword -> PasswordHasher m ()

type instance DispatchOf PasswordHasher = Dynamic

hashPassword :: (PasswordHasher :> es) => PlainPassword -> Eff es PasswordHash
hashPassword = send . HashPassword

verifyPassword :: (PasswordHasher :> es) => PlainPassword -> PasswordHash -> Eff es Bool
verifyPassword p h = send (VerifyPassword p h)

-- | Burn one verification's worth of hashing work; see 'VerifyPasswordDummy'.
verifyPasswordDummy :: (PasswordHasher :> es) => PlainPassword -> Eff es ()
verifyPasswordDummy = send . VerifyPasswordDummy
