{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The OAuth-client port (EP-5): the @shomei_oauth_clients@ table behind the
-- authorization-code flow.
--
-- Lookup is by @client_id@ (the public TypeID text), because that is what an OAuth client
-- presents at @\/oauth\/authorize@ and @\/oauth\/token@. Mutations are by 'OAuthClientId',
-- because that is what an administrator holds after a create or a list. This mirrors
-- "Shomei.Effect.ServiceAccountStore" exactly.
module Shomei.Effect.OAuthClientStore
  ( OAuthClientStore (..),
    createOAuthClient,
    findOAuthClientByClientId,
    listOAuthClients,
    revokeOAuthClient,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.OAuthClient (NewOAuthClient, OAuthClient)
import Shomei.Id (OAuthClientId)
import Shomei.Prelude

data OAuthClientStore :: Effect where
  CreateOAuthClient :: NewOAuthClient -> OAuthClientStore m OAuthClient
  -- | The authorize- and token-time lookup. Returns revoked clients too: refusing a revoked
  -- client is the workflow's job, and at the token endpoint the refusal must be
  -- indistinguishable from a wrong secret.
  FindOAuthClientByClientId :: Text -> OAuthClientStore m (Maybe OAuthClient)
  -- | The whole table, newest first. Deployments have few OAuth clients; no paging.
  ListOAuthClients :: OAuthClientStore m [OAuthClient]
  RevokeOAuthClient :: OAuthClientId -> UTCTime -> OAuthClientStore m ()

type instance DispatchOf OAuthClientStore = Dynamic

createOAuthClient :: (OAuthClientStore :> es) => NewOAuthClient -> Eff es OAuthClient
createOAuthClient = send . CreateOAuthClient

findOAuthClientByClientId :: (OAuthClientStore :> es) => Text -> Eff es (Maybe OAuthClient)
findOAuthClientByClientId = send . FindOAuthClientByClientId

listOAuthClients :: (OAuthClientStore :> es) => Eff es [OAuthClient]
listOAuthClients = send ListOAuthClients

revokeOAuthClient :: (OAuthClientStore :> es) => OAuthClientId -> UTCTime -> Eff es ()
revokeOAuthClient cid t = send (RevokeOAuthClient cid t)
