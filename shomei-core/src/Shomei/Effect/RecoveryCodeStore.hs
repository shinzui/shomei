{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Store effect for single-use MFA recovery codes (EP-7).
--
-- Codes are stored only as hashes. 'ConsumeRecoveryCode' is a compare-and-set — it stamps
-- @used_at@ exactly once, so a double-spend is impossible even under concurrent requests —
-- returning 'True' iff this caller was the one that spent an unused matching code.
-- 'ReplaceRecoveryCodes' deletes the user's existing set and inserts a new one in a single
-- transaction (regeneration invalidates the old codes).
module Shomei.Effect.RecoveryCodeStore
  ( RecoveryCodeStore (..),
    replaceRecoveryCodes,
    consumeRecoveryCode,
    countUnusedRecoveryCodes,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Totp (NewRecoveryCode)
import Shomei.Id (UserId)
import Shomei.Prelude

data RecoveryCodeStore :: Effect where
  -- | Atomically replace the user's whole recovery-code set (delete existing, insert new).
  ReplaceRecoveryCodes :: UserId -> [NewRecoveryCode] -> RecoveryCodeStore m ()
  -- | Compare-and-set: spend an unused code whose hash matches. 'True' iff a row was consumed.
  ConsumeRecoveryCode :: UserId -> Text -> UTCTime -> RecoveryCodeStore m Bool
  CountUnusedRecoveryCodes :: UserId -> RecoveryCodeStore m Int

type instance DispatchOf RecoveryCodeStore = Dynamic

replaceRecoveryCodes :: (RecoveryCodeStore :> es) => UserId -> [NewRecoveryCode] -> Eff es ()
replaceRecoveryCodes u cs = send (ReplaceRecoveryCodes u cs)

consumeRecoveryCode :: (RecoveryCodeStore :> es) => UserId -> Text -> UTCTime -> Eff es Bool
consumeRecoveryCode u h t = send (ConsumeRecoveryCode u h t)

countUnusedRecoveryCodes :: (RecoveryCodeStore :> es) => UserId -> Eff es Int
countUnusedRecoveryCodes = send . CountUnusedRecoveryCodes
