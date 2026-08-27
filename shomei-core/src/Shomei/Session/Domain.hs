-- | The session entity: a server-side record of an authenticated login, against which
-- refresh tokens are issued and (optionally) access tokens are checked.
module Shomei.Session.Domain
  ( SessionStatus (..),
    SessionKind (..),
    Session (..),
    NewSession (..),
  )
where

import Data.Set (Set)
import Shomei.Authorization.Claims.Domain (Scope)
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude

data SessionStatus = SessionActive | SessionRevoked | SessionExpired
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | How a session was established. This provenance is selected by the minting path rather than
-- by a caller-supplied option, so privilege-minting operations can distinguish a human login
-- from a machine credential or a delegation.
data SessionKind
  = -- | A human proved a credential, or exchanged a code authorized by such a session.
    InteractiveSession
  | -- | @client_credentials@: a service acting as itself, with no human involved.
    MachineSession
  | -- | Impersonation or RFC 8693 on-behalf-of: the token carries an @act@ claim.
    DelegatedSession
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data Session = Session
  { sessionId :: !SessionId,
    userId :: !UserId,
    status :: !SessionStatus,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime,
    revokedAt :: !(Maybe UTCTime),
    -- | for a delegated (impersonation) session, the operator acting on behalf
    -- of 'userId'; 'Nothing' for every ordinary login session.
    actor :: !(Maybe UserId),
    -- | the OAuth2 @client_id@ that minted this session through the authorization-code grant
    --     (EP-5); 'Nothing' for every other flow, including every session that predates the
    --     column. It exists to bind refresh: a token issued through client A must not be
    --     rotatable by client B at @\/oauth\/token@. The bespoke @\/v1\/auth\/refresh@ refuses it.
    oauthClientId :: !(Maybe Text),
    -- | how this session was established; see 'SessionKind'.
    kind :: !SessionKind,
    -- | the scopes the authorization-code grant granted, re-applied on every refresh so a
    --     rotated access token keeps @openid@ and friends. Empty for every other flow and for
    --     every row that predates the column.
    grantedScopes :: !(Set Scope),
    -- | when the last credential was proven; preserved across refresh and emitted as @auth_time@.
    authenticatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data NewSession = NewSession
  { userId :: !UserId,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime,
    -- | set to @Just operator@ when minting a delegated session; 'Nothing' otherwise.
    actor :: !(Maybe UserId),
    -- | set to @Just client_id@ by the authorization-code grant; 'Nothing' otherwise.
    oauthClientId :: !(Maybe Text),
    -- | how this session was established; see 'SessionKind'.
    kind :: !SessionKind,
    -- | the authorization-code grant's persisted scope set; empty for every other flow.
    grantedScopes :: !(Set Scope),
    -- | when the credential establishing this session was proven.
    authenticatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
