-- | Shared validated recovery. Calling surfaces enforce authority before invoking it.
module Shomei.Account.Admin.Recovery (module Shomei.Account.Admin.Recovery.Domain, resetUserSecondFactors) where

import Effectful (Eff, (:>))
import Shomei.Account.Admin.Recovery.Domain
import Shomei.Account.Notification.Domain (Notification (SecondFactorsReset))
import Shomei.Account.Notification.Store (Notifier, sendNotification)
import Shomei.Error (AuthError)
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork, resetSecondFactors)
import Shomei.Time.Store (Clock, now)

resetUserSecondFactors :: (AuthUnitOfWork :> es, Clock :> es, Notifier :> es) => RecoveryActor -> UserId -> RecoveryCommand -> Eff es (Either AuthError RecoveryResult)
resetUserSecondFactors actor uid command = case validateRecovery actor command of
  Left err -> pure (Left err)
  Right () -> do
    ts <- now
    result <- resetSecondFactors actor uid command ts
    case result of
      Left err -> pure (Left err)
      Right (committed, destination) -> do
        -- The destination was captured under the same user lock as the committed reset.
        forM_ destination \address -> sendNotification (SecondFactorsReset address ts "Your second factors were reset by an administrator. Sign in with your password and immediately enroll replacement factors and new recovery codes. If you did not request this, contact your established support channel immediately.")
        pure (Right committed)
