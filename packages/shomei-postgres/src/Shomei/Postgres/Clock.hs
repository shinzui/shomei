-- | The 'Clock' port interpreted as the real wall clock.
module Shomei.Postgres.Clock (
    runClockIO,
) where

import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Port.Clock (Clock (..))

runClockIO :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runClockIO = interpret_ \case
    Now -> liftIO getCurrentTime
