{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The signing-key-store port (IP-4): persisting and listing 'StoredSigningKey' records.
Key material is opaque JWK JSON; this port never touches @jose@.
-}
module Shomei.Effect.SigningKeyStore (
    SigningKeyStore (..),
    listActiveSigningKeys,
    findSigningKeyByKid,
    insertSigningKey,
    updateSigningKeyStatus,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.SigningKey (SigningKeyStatus, StoredSigningKey)

data SigningKeyStore :: Effect where
    ListActiveSigningKeys :: SigningKeyStore m [StoredSigningKey]
    FindSigningKeyByKid :: Text -> SigningKeyStore m (Maybe StoredSigningKey)
    InsertSigningKey :: StoredSigningKey -> SigningKeyStore m ()
    UpdateSigningKeyStatus :: Text -> SigningKeyStatus -> UTCTime -> SigningKeyStore m ()

type instance DispatchOf SigningKeyStore = Dynamic

listActiveSigningKeys :: (SigningKeyStore :> es) => Eff es [StoredSigningKey]
listActiveSigningKeys = send ListActiveSigningKeys

findSigningKeyByKid :: (SigningKeyStore :> es) => Text -> Eff es (Maybe StoredSigningKey)
findSigningKeyByKid = send . FindSigningKeyByKid

insertSigningKey :: (SigningKeyStore :> es) => StoredSigningKey -> Eff es ()
insertSigningKey = send . InsertSigningKey

updateSigningKeyStatus :: (SigningKeyStore :> es) => Text -> SigningKeyStatus -> UTCTime -> Eff es ()
updateSigningKeyStatus kid st t = send (UpdateSigningKeyStatus kid st t)
