{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The signing-key-store port (IP-4): persisting and listing 'StoredSigningKey' records.
-- Key material is opaque JWK JSON; this port never touches @jose@.
module Shomei.SigningKey.Store
  ( SigningKeyStore (..),
    listActiveSigningKeys,
    listPublishableSigningKeys,
    findSigningKeyByKid,
    insertSigningKey,
    updateSigningKeyStatus,
    replaceActiveSigningKey,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Prelude
import Shomei.SigningKey.Domain (SigningKeyStatus, StoredSigningKey)

data SigningKeyStore :: Effect where
  ListActiveSigningKeys :: SigningKeyStore m [StoredSigningKey]
  -- | Every key that belongs in the published JWKS and the verifier key set:
  -- @active@ and @retired@ (they overlap during a rotation window). Excludes
  -- @pending@ (not yet trusted) and @revoked@ (explicitly distrusted).
  ListPublishableSigningKeys :: SigningKeyStore m [StoredSigningKey]
  FindSigningKeyByKid :: Text -> SigningKeyStore m (Maybe StoredSigningKey)
  InsertSigningKey :: StoredSigningKey -> SigningKeyStore m ()
  UpdateSigningKeyStatus :: Text -> SigningKeyStatus -> UTCTime -> SigningKeyStore m ()
  -- | In one transaction, retire every active key with @retired_at = t@, then insert the
  -- given key (or promote the row with its @kid@) as active with @activated_at = t@.
  ReplaceActiveSigningKey :: StoredSigningKey -> UTCTime -> SigningKeyStore m ()

type instance DispatchOf SigningKeyStore = Dynamic

listActiveSigningKeys :: (SigningKeyStore :> es) => Eff es [StoredSigningKey]
listActiveSigningKeys = send ListActiveSigningKeys

listPublishableSigningKeys :: (SigningKeyStore :> es) => Eff es [StoredSigningKey]
listPublishableSigningKeys = send ListPublishableSigningKeys

findSigningKeyByKid :: (SigningKeyStore :> es) => Text -> Eff es (Maybe StoredSigningKey)
findSigningKeyByKid = send . FindSigningKeyByKid

insertSigningKey :: (SigningKeyStore :> es) => StoredSigningKey -> Eff es ()
insertSigningKey = send . InsertSigningKey

updateSigningKeyStatus :: (SigningKeyStore :> es) => Text -> SigningKeyStatus -> UTCTime -> Eff es ()
updateSigningKeyStatus kid st t = send (UpdateSigningKeyStatus kid st t)

replaceActiveSigningKey :: (SigningKeyStore :> es) => StoredSigningKey -> UTCTime -> Eff es ()
replaceActiveSigningKey key t = send (ReplaceActiveSigningKey key t)
