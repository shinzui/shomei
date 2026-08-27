{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The login-attempt store effect: the durable state behind brute-force lockout and per-IP
-- login throttling. Counting is windowed (failures since a cutoff time); lockout is keyed by
-- the hashed account identifier.
module Shomei.Session.LoginAttempt.Store
  ( LoginAttemptStore (..),
    recordLoginFailure,
    convertLoginAttemptToSuccess,
    discardLoginAttempt,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    setAccountLockout,
    clearAccountLockout,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Id (LoginAttemptId)
import Shomei.Prelude
import Shomei.Session.LoginAttempt.Domain (AccountKey, AccountLockout, ClientIp, FailureOutcome, LockPolicy, NewLoginAttempt)

data LoginAttemptStore :: Effect where
  -- | Serialize on the account key, append a provisional failure, count it in the current
  -- window, and optionally transition the account to locked in the same operation.
  RecordLoginFailure :: NewLoginAttempt -> UTCTime -> Maybe LockPolicy -> LoginAttemptStore m FailureOutcome
  -- | Convert a provisional failure to success without adding a second attempt row.
  ConvertLoginAttemptToSuccess :: LoginAttemptId -> LoginAttemptStore m ()
  -- | Remove a provisional row after a correct password advances into an MFA challenge. It is
  -- neither a failed proof nor a fully authenticated success, so it must affect neither budget.
  DiscardLoginAttempt :: LoginAttemptId -> LoginAttemptStore m ()
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

recordLoginFailure ::
  (LoginAttemptStore :> es) =>
  NewLoginAttempt ->
  UTCTime ->
  Maybe LockPolicy ->
  Eff es FailureOutcome
recordLoginFailure attempt cutoff policy = send (RecordLoginFailure attempt cutoff policy)

convertLoginAttemptToSuccess :: (LoginAttemptStore :> es) => LoginAttemptId -> Eff es ()
convertLoginAttemptToSuccess = send . ConvertLoginAttemptToSuccess

discardLoginAttempt :: (LoginAttemptStore :> es) => LoginAttemptId -> Eff es ()
discardLoginAttempt = send . DiscardLoginAttempt

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
