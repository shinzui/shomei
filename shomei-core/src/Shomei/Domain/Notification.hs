-- | Notifications emitted by account lifecycle workflows.
module Shomei.Domain.Notification (
    Notification (..),
) where

import Shomei.Prelude

import Shomei.Domain.Email (Email)
import Shomei.Domain.OneTimeToken (OneTimeToken)

data Notification
    = EmailVerificationRequested
        { email :: !Email
        , token :: !OneTimeToken
        , expiresAt :: !UTCTime
        }
    | PasswordResetRequested
        { email :: !Email
        , token :: !OneTimeToken
        , expiresAt :: !UTCTime
        }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
