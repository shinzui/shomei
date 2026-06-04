-- | Shared opaque single-use token types for account lifecycle flows.
module Shomei.Domain.OneTimeToken (
    OneTimeToken (..),
    OneTimeTokenHash (..),
    OneTimeTokenStatus (..),
    oneTimeTokenText,
    oneTimeTokenHashText,
) where

import Shomei.Prelude

newtype OneTimeToken = OneTimeToken Text
    deriving stock (Generic)
    deriving newtype (Eq, Show, FromJSON, ToJSON)

newtype OneTimeTokenHash = OneTimeTokenHash Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data OneTimeTokenStatus
    = OneTimeTokenActive
    | OneTimeTokenConsumed
    | OneTimeTokenRevoked
    | OneTimeTokenExpired
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

oneTimeTokenText :: OneTimeToken -> Text
oneTimeTokenText (OneTimeToken t) = t

oneTimeTokenHashText :: OneTimeTokenHash -> Text
oneTimeTokenHashText (OneTimeTokenHash t) = t
