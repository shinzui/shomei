-- | The service-account entity (EP-4): a machine credential an operator creates, rotates, and
-- revokes at runtime, authenticating at @POST \/oauth\/token@ with the OAuth2
-- @client_credentials@ grant.
--
-- Distinct from 'Shomei.Config.ServiceAccountConfig', the static config-defined account behind
-- the deprecated @POST \/v1\/auth\/service-token@ endpoint. Both mint the same shape of
-- short-lived, refresh-less machine token; only this one has a runtime lifecycle.
--
-- 'secretHash' is a lowercase 64-char SHA-256 hex digest, the same format the config accounts
-- use, so 'Shomei.Workflow.ServiceToken.verifyServiceSecret' verifies both.
module Shomei.Domain.ServiceAccount
  ( ServiceAccountStatus (..),
    ServiceAccount (..),
    NewServiceAccount (..),
  )
where

import Data.Set (Set)
import Shomei.Domain.Claims (Scope)
import Shomei.Id (ServiceAccountDbId, UserId)
import Shomei.Prelude

-- | A revoked account keeps its row: audit events naming it must still resolve, and a revoked
-- credential must be refused, not forgotten.
data ServiceAccountStatus = ServiceAccountActive | ServiceAccountRevoked
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data ServiceAccount = ServiceAccount
  { serviceAccountId :: !ServiceAccountDbId,
    -- | the TypeID text rendering of 'serviceAccountId'; the OAuth2 @client_id@. Public.
    clientId :: !Text,
    -- | the @shomei_users@ row backing this account's sessions and claims @sub@
    userId :: !UserId,
    secretHash :: !Text,
    displayName :: !Text,
    -- | the ceiling on what a token from this account may carry. A @client_credentials@
    --     request with no @scope@ parameter is granted all of them.
    allowedScopes :: !(Set Scope),
    status :: !ServiceAccountStatus,
    createdAt :: !UTCTime,
    rotatedAt :: !(Maybe UTCTime),
    revokedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data NewServiceAccount = NewServiceAccount
  { serviceAccountId :: !ServiceAccountDbId,
    clientId :: !Text,
    userId :: !UserId,
    secretHash :: !Text,
    displayName :: !Text,
    allowedScopes :: !(Set Scope),
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
