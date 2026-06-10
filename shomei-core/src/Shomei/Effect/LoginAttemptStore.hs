{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The login-attempt store effect: the durable state behind brute-force lockout and per-IP
login throttling. Counting is windowed (failures since a cutoff time); lockout is keyed by
the hashed account identifier.
-}
module Shomei.Effect.LoginAttemptStore (
    LoginAttemptStore (..),
    recordLoginAttempt,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    setAccountLockout,
    clearAccountLockout,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.LoginAttempt (AccountKey, AccountLockout, ClientIp, NewLoginAttempt)

data LoginAttemptStore :: Effect where
    -- | Append one attempt to the log.
    RecordLoginAttempt :: NewLoginAttempt -> LoginAttemptStore m ()
    -- | Count failures for an account since the given cutoff (window start).
    CountRecentFailuresByAccount :: AccountKey -> UTCTime -> LoginAttemptStore m Int
    -- | Count failures from an IP since the given cutoff (window start).
    CountRecentFailuresByIp :: ClientIp -> UTCTime -> LoginAttemptStore m Int
    -- | Read the current lockout record for an account (if any).
    GetAccountLockout :: AccountKey -> LoginAttemptStore m (Maybe AccountLockout)
    -- | Upsert the lockout record (set failedCount / lockedUntil / updatedAt).
    SetAccountLockout :: AccountLockout -> LoginAttemptStore m ()
    -- | Clear the lockout record for an account (on successful login).
    ClearAccountLockout :: AccountKey -> LoginAttemptStore m ()

type instance DispatchOf LoginAttemptStore = Dynamic

recordLoginAttempt :: (LoginAttemptStore :> es) => NewLoginAttempt -> Eff es ()
recordLoginAttempt = send . RecordLoginAttempt

countRecentFailuresByAccount :: (LoginAttemptStore :> es) => AccountKey -> UTCTime -> Eff es Int
countRecentFailuresByAccount k t = send (CountRecentFailuresByAccount k t)

countRecentFailuresByIp :: (LoginAttemptStore :> es) => ClientIp -> UTCTime -> Eff es Int
countRecentFailuresByIp ip t = send (CountRecentFailuresByIp ip t)

getAccountLockout :: (LoginAttemptStore :> es) => AccountKey -> Eff es (Maybe AccountLockout)
getAccountLockout = send . GetAccountLockout

setAccountLockout :: (LoginAttemptStore :> es) => AccountLockout -> Eff es ()
setAccountLockout = send . SetAccountLockout

clearAccountLockout :: (LoginAttemptStore :> es) => AccountKey -> Eff es ()
clearAccountLockout = send . ClearAccountLockout
