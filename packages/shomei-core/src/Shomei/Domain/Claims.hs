{- | The claims embedded in an access token, plus the small newtypes that make the claim
fields type-safe.
-}
module Shomei.Domain.Claims (
    Issuer (..),
    Audience (..),
    Scope (..),
    Role (..),
    AuthClaims (..),
) where

import Shomei.Prelude

import Data.Set (Set)
import Shomei.Id (SessionId, UserId)

newtype Issuer = Issuer Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype Audience = Audience Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype Scope = Scope Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype Role = Role Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data AuthClaims = AuthClaims
    { subject :: !UserId
    , sessionId :: !SessionId
    , issuer :: !Issuer
    , audience :: !Audience
    , issuedAt :: !UTCTime
    , expiresAt :: !UTCTime
    , scopes :: !(Set Scope)
    , roles :: !(Set Role)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
