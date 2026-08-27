-- | Registration policy for OAuth clients.
module Shomei.OAuth.Client.Workflow
  ( ClientRegistrationError (..),
    registerOAuthClient,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Effectful (Eff, (:>))
import Shomei.Authorization.Claims.Domain (Scope)
import Shomei.Authorization.Scope.Domain (privilegeScopesIn)
import Shomei.Config (ShomeiConfig)
import Shomei.OAuth.Client.Domain (NewOAuthClient (..), OAuthClient)
import Shomei.OAuth.Client.Store (OAuthClientStore, createOAuthClient)
import Shomei.Prelude

data ClientRegistrationError = PrivilegeScopesRefused (Set Scope)
  deriving stock (Generic, Eq, Show)

-- | Register an OAuth client only when its allow-list cannot confer a Shōmei privilege gate on
-- every user who authorizes through it. The store remains policy-free for migrations and tests;
-- this workflow is the application registration seam.
registerOAuthClient ::
  (OAuthClientStore :> es) =>
  ShomeiConfig ->
  NewOAuthClient ->
  Eff es (Either ClientRegistrationError OAuthClient)
registerOAuthClient cfg newClient =
  let refused = privilegeScopesIn cfg newClient.allowedScopes
   in if Set.null refused
        then Right <$> createOAuthClient newClient
        else pure (Left (PrivilegeScopesRefused refused))
