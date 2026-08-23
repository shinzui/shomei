{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Notification-sending effect for account lifecycle messages.
module Shomei.Account.Notification.Store
  ( Notifier (..),
    sendNotification,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Account.Notification.Domain (Notification)

data Notifier :: Effect where
  SendNotification :: Notification -> Notifier m ()

type instance DispatchOf Notifier = Dynamic

sendNotification :: (Notifier :> es) => Notification -> Eff es ()
sendNotification = send . SendNotification
