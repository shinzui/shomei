{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The audit/security event-publisher port. EP-3 persists events to
-- @shomei_auth_events@.
module Shomei.Effect.AuthEventPublisher
  ( AuthEventPublisher (..),
    publishAuthEvent,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Event (AuthEvent)

data AuthEventPublisher :: Effect where
  PublishAuthEvent :: AuthEvent -> AuthEventPublisher m ()

type instance DispatchOf AuthEventPublisher = Dynamic

publishAuthEvent :: (AuthEventPublisher :> es) => AuthEvent -> Eff es ()
publishAuthEvent = send . PublishAuthEvent
