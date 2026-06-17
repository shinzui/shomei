{- | The session entity: a server-side record of an authenticated login, against which
refresh tokens are issued and (optionally) access tokens are checked.
-}
module Shomei.Domain.Session (
    SessionStatus (..),
    Session (..),
    NewSession (..),
) where

import Shomei.Prelude

import Shomei.Id (SessionId, UserId)

data SessionStatus = SessionActive | SessionRevoked | SessionExpired
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data Session = Session
    { sessionId :: !SessionId
    , userId :: !UserId
    , status :: !SessionStatus
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    , revokedAt :: !(Maybe UTCTime)
    , actor :: !(Maybe UserId)
    -- ^ for a delegated (impersonation) session, the operator acting on behalf
    -- of 'userId'; 'Nothing' for every ordinary login session.
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NewSession = NewSession
    { userId :: !UserId
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    , actor :: !(Maybe UserId)
    -- ^ set to @Just operator@ when minting a delegated session; 'Nothing' otherwise.
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
