{- | Refresh-token types.

'RefreshToken' is the opaque secret handed to the client. 'RefreshTokenHash' is what
is persisted (the server never stores the raw token). 'PersistedRefreshToken' is the
stored row, including the @parentTokenId@ link that forms a rotation /family/ — the
chain of tokens descended from one login. Reuse of a token already marked
'RefreshTokenUsed' (or 'RefreshTokenRevoked') is treated as theft and revokes the
whole family (see 'Shomei.Workflow.refresh').
-}
module Shomei.Domain.RefreshToken (
    RefreshToken (..),
    RefreshTokenHash (..),
    RefreshTokenStatus (..),
    PersistedRefreshToken (..),
    NewRefreshToken (..),
) where

import Shomei.Prelude

import Shomei.Id (RefreshTokenId, SessionId)

newtype RefreshToken = RefreshToken Text
    deriving stock (Generic)
    deriving newtype (Eq, Show, FromJSON, ToJSON)

newtype RefreshTokenHash = RefreshTokenHash Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data RefreshTokenStatus
    = RefreshTokenActive
    | RefreshTokenUsed
    | RefreshTokenRevoked
    | RefreshTokenExpired
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data PersistedRefreshToken = PersistedRefreshToken
    { refreshTokenId :: !RefreshTokenId
    , sessionId :: !SessionId
    , tokenHash :: !RefreshTokenHash
    , parentTokenId :: !(Maybe RefreshTokenId)
    , status :: !RefreshTokenStatus
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    , usedAt :: !(Maybe UTCTime)
    , revokedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NewRefreshToken = NewRefreshToken
    { sessionId :: !SessionId
    , tokenHash :: !RefreshTokenHash
    , parentTokenId :: !(Maybe RefreshTokenId)
    , createdAt :: !UTCTime
    , expiresAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
