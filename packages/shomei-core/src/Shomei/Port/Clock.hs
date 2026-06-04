{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The clock port: the current wall-clock time. Abstracting it lets tests fix or
advance time deterministically.
-}
module Shomei.Port.Clock (
    Clock (..),
    now,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

data Clock :: Effect where
    Now :: Clock m UTCTime

type instance DispatchOf Clock = Dynamic

now :: (Clock :> es) => Eff es UTCTime
now = send Now
