-- | Notifications emitted by account lifecycle workflows.
module Shomei.Account.Notification.Domain
  ( Notification (..),
  )
where

import Shomei.Account.Email.Domain (Email)
import Shomei.Account.OneTimeToken.Domain (OneTimeToken)
import Shomei.Prelude

data Notification
  = EmailVerificationRequested
      { email :: !Email,
        token :: !OneTimeToken,
        expiresAt :: !UTCTime
      }
  | PasswordResetRequested
      { email :: !Email,
        token :: !OneTimeToken,
        expiresAt :: !UTCTime
      }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
