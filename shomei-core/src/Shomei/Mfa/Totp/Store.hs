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
module Shomei.Mfa.Totp.Store
  ( TotpCredentialStore (..),
    upsertTotpEnrollment,
    findTotpByUser,
    confirmTotp,
    setTotpLastUsedCounter,
    deleteTotpByUser,
    removeTotpCredential,
  )
where

import Data.Int (Int64)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Error (AuthError)
import Shomei.Id (TotpCredentialId, UserId)
import Shomei.Mfa.Totp.Domain (NewTotpCredential, TotpCredential)
import Shomei.Prelude
import Shomei.Session.Authentication.Guard (AuthenticationGuard)

data TotpCredentialStore :: Effect where
  -- | Insert the enrollment, replacing any existing (unconfirmed) row for the user.
  UpsertTotpEnrollment :: AuthenticationGuard -> NewTotpCredential -> TotpCredentialStore m (Either AuthError TotpCredential)
  FindTotpByUser :: UserId -> TotpCredentialStore m (Maybe TotpCredential)
  -- | Mark the credential confirmed (activated) at the given time.
  ConfirmTotp :: UserId -> AuthenticationGuard -> TotpCredentialId -> UTCTime -> TotpCredentialStore m (Either AuthError ())
  -- | Advance the replay-defense high-water counter only when the supplied value is newer.
  -- 'False' means another request already accepted this counter (or a later one).
  SetTotpLastUsedCounter :: TotpCredentialId -> Int64 -> TotpCredentialStore m Bool
  RemoveTotpCredential :: UserId -> AuthenticationGuard -> TotpCredentialId -> UTCTime -> TotpCredentialStore m (Either AuthError ())
  DeleteTotpByUser :: UserId -> TotpCredentialStore m ()

type instance DispatchOf TotpCredentialStore = Dynamic

upsertTotpEnrollment :: (TotpCredentialStore :> es) => AuthenticationGuard -> NewTotpCredential -> Eff es (Either AuthError TotpCredential)
upsertTotpEnrollment proofState = send . UpsertTotpEnrollment proofState

findTotpByUser :: (TotpCredentialStore :> es) => UserId -> Eff es (Maybe TotpCredential)
findTotpByUser = send . FindTotpByUser

confirmTotp :: (TotpCredentialStore :> es) => UserId -> AuthenticationGuard -> TotpCredentialId -> UTCTime -> Eff es (Either AuthError ())
confirmTotp uid proofState i t = send (ConfirmTotp uid proofState i t)

setTotpLastUsedCounter :: (TotpCredentialStore :> es) => TotpCredentialId -> Int64 -> Eff es Bool
setTotpLastUsedCounter i c = send (SetTotpLastUsedCounter i c)

deleteTotpByUser :: (TotpCredentialStore :> es) => UserId -> Eff es ()
deleteTotpByUser = send . DeleteTotpByUser

removeTotpCredential :: (TotpCredentialStore :> es) => UserId -> AuthenticationGuard -> TotpCredentialId -> UTCTime -> Eff es (Either AuthError ())
removeTotpCredential uid proofState tcid ts = send (RemoveTotpCredential uid proofState tcid ts)
