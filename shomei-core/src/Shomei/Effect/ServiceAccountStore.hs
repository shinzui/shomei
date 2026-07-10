{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The service-account port (EP-4): the @shomei_service_accounts@ table behind the OAuth2
-- @client_credentials@ grant.
--
-- Lookup is by @client_id@ (the public TypeID text), because that is what an OAuth2 client
-- presents. Mutations are by 'ServiceAccountDbId', because that is what an administrator holds
-- after a create or a list.
module Shomei.Effect.ServiceAccountStore
  ( ServiceAccountStore (..),
    createServiceAccount,
    findServiceAccountByClientId,
    listServiceAccounts,
    rotateServiceAccountSecret,
    revokeServiceAccount,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.ServiceAccount (NewServiceAccount, ServiceAccount)
import Shomei.Id (ServiceAccountDbId)
import Shomei.Prelude

data ServiceAccountStore :: Effect where
  CreateServiceAccount :: NewServiceAccount -> ServiceAccountStore m ServiceAccount
  -- | The authentication lookup. Returns revoked accounts too: refusing a revoked credential
  -- is the workflow's job, and it must be indistinguishable from a wrong secret.
  FindServiceAccountByClientId :: Text -> ServiceAccountStore m (Maybe ServiceAccount)
  -- | The whole table, newest first. Deployments have few service accounts; no paging.
  ListServiceAccounts :: ServiceAccountStore m [ServiceAccount]
  -- | Replace the secret hash and stamp @rotated_at@. Takes the /new hash/, never a plaintext:
  -- the secret is generated and shown once by the caller.
  RotateServiceAccountSecret :: ServiceAccountDbId -> Text -> UTCTime -> ServiceAccountStore m ()
  RevokeServiceAccount :: ServiceAccountDbId -> UTCTime -> ServiceAccountStore m ()

type instance DispatchOf ServiceAccountStore = Dynamic

createServiceAccount :: (ServiceAccountStore :> es) => NewServiceAccount -> Eff es ServiceAccount
createServiceAccount = send . CreateServiceAccount

findServiceAccountByClientId :: (ServiceAccountStore :> es) => Text -> Eff es (Maybe ServiceAccount)
findServiceAccountByClientId = send . FindServiceAccountByClientId

listServiceAccounts :: (ServiceAccountStore :> es) => Eff es [ServiceAccount]
listServiceAccounts = send ListServiceAccounts

rotateServiceAccountSecret :: (ServiceAccountStore :> es) => ServiceAccountDbId -> Text -> UTCTime -> Eff es ()
rotateServiceAccountSecret sid h t = send (RotateServiceAccountSecret sid h t)

revokeServiceAccount :: (ServiceAccountStore :> es) => ServiceAccountDbId -> UTCTime -> Eff es ()
revokeServiceAccount sid t = send (RevokeServiceAccount sid t)
