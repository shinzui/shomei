{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Store effect for a user's TOTP (RFC 6238) credential (EP-7).
--
-- One credential per user (@UNIQUE (user_id)@). The port speaks in /raw/ 'TotpSecret's; the
-- PostgreSQL interpreter encrypts on the way in and decrypts on the way out (AES-256-GCM),
-- while the in-memory interpreter holds the raw bytes. 'UpsertTotpEnrollment' replaces an
-- existing /unconfirmed/ enrollment (re-scanning the QR); refusing to overwrite a /confirmed/
-- credential is the workflow's job, not the store's.
module Shomei.Effect.TotpCredentialStore
  ( TotpCredentialStore (..),
    upsertTotpEnrollment,
    findTotpByUser,
    confirmTotp,
    setTotpLastUsedCounter,
    deleteTotpByUser,
  )
where

import Data.Int (Int64)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Totp (NewTotpCredential, TotpCredential)
import Shomei.Id (TotpCredentialId, UserId)
import Shomei.Prelude

data TotpCredentialStore :: Effect where
  -- | Insert the enrollment, replacing any existing (unconfirmed) row for the user.
  UpsertTotpEnrollment :: NewTotpCredential -> TotpCredentialStore m TotpCredential
  FindTotpByUser :: UserId -> TotpCredentialStore m (Maybe TotpCredential)
  -- | Mark the credential confirmed (activated) at the given time.
  ConfirmTotp :: TotpCredentialId -> UTCTime -> TotpCredentialStore m ()
  -- | Persist the replay-defense high-water counter after a successful verification.
  SetTotpLastUsedCounter :: TotpCredentialId -> Int64 -> TotpCredentialStore m ()
  DeleteTotpByUser :: UserId -> TotpCredentialStore m ()

type instance DispatchOf TotpCredentialStore = Dynamic

upsertTotpEnrollment :: (TotpCredentialStore :> es) => NewTotpCredential -> Eff es TotpCredential
upsertTotpEnrollment = send . UpsertTotpEnrollment

findTotpByUser :: (TotpCredentialStore :> es) => UserId -> Eff es (Maybe TotpCredential)
findTotpByUser = send . FindTotpByUser

confirmTotp :: (TotpCredentialStore :> es) => TotpCredentialId -> UTCTime -> Eff es ()
confirmTotp i t = send (ConfirmTotp i t)

setTotpLastUsedCounter :: (TotpCredentialStore :> es) => TotpCredentialId -> Int64 -> Eff es ()
setTotpLastUsedCounter i c = send (SetTotpLastUsedCounter i c)

deleteTotpByUser :: (TotpCredentialStore :> es) => UserId -> Eff es ()
deleteTotpByUser = send . DeleteTotpByUser
