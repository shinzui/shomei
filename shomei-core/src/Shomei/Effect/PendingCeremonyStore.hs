{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | Store effect for short-lived pending WebAuthn ceremony state.

Between a ceremony's "begin" and "complete" halves the server must remember the
challenge and the serialized options blob it issued. This port persists that state
keyed by a 'CeremonyId' and consumes it exactly once.

'TakePendingCeremony' is the security heart: it is __consume-once__. It removes the
row and returns it only if the ceremony is present AND not yet expired
(@expiresAt > now@); it returns 'Nothing' if the ceremony is absent OR expired. The
@now@ 'UTCTime' is supplied by the caller (read from the 'Shomei.Effect.Clock' port).
An expired ceremony is still removed from the store when taken, so a stale row cannot
linger and be retried; 'DeleteExpiredCeremonies' is a coarse bulk sweep for rows that
were never taken.

The ceremony domain type is owned by EP-1 ('Shomei.Domain.Passkey'); this module only
references it. EP-2 supplies the in-memory and PostgreSQL interpreters.
-}
module Shomei.Effect.PendingCeremonyStore (
    PendingCeremonyStore (..),
    putPendingCeremony,
    takePendingCeremony,
    deleteExpiredCeremonies,
) where

import Shomei.Prelude

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Passkey (PendingCeremony)
import Shomei.Id (CeremonyId)

data PendingCeremonyStore :: Effect where
    PutPendingCeremony :: PendingCeremony -> PendingCeremonyStore m ()
    -- | Consume-once: remove the row and return it iff present AND @expiresAt > now@;
    -- otherwise return 'Nothing' (removing an expired row too). @now@ is the second arg.
    TakePendingCeremony :: CeremonyId -> UTCTime -> PendingCeremonyStore m (Maybe PendingCeremony)
    -- | Bulk sweep: delete every ceremony whose @expiresAt <= now@.
    DeleteExpiredCeremonies :: UTCTime -> PendingCeremonyStore m ()

type instance DispatchOf PendingCeremonyStore = Dynamic

putPendingCeremony :: (PendingCeremonyStore :> es) => PendingCeremony -> Eff es ()
putPendingCeremony = send . PutPendingCeremony

takePendingCeremony :: (PendingCeremonyStore :> es) => CeremonyId -> UTCTime -> Eff es (Maybe PendingCeremony)
takePendingCeremony c t = send (TakePendingCeremony c t)

deleteExpiredCeremonies :: (PendingCeremonyStore :> es) => UTCTime -> Eff es ()
deleteExpiredCeremonies = send . DeleteExpiredCeremonies
