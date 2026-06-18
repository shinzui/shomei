-- | Password-reset token rows.
module Shomei.Domain.PasswordResetToken
  ( PersistedPasswordResetToken (..),
    NewPasswordResetToken (..),
  )
where

import Shomei.Domain.OneTimeToken (OneTimeTokenHash, OneTimeTokenStatus)
import Shomei.Id (PasswordResetTokenId, UserId)
import Shomei.Prelude

data PersistedPasswordResetToken = PersistedPasswordResetToken
  { passwordResetTokenId :: !PasswordResetTokenId,
    userId :: !UserId,
    tokenHash :: !OneTimeTokenHash,
    status :: !OneTimeTokenStatus,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime,
    consumedAt :: !(Maybe UTCTime),
    revokedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data NewPasswordResetToken = NewPasswordResetToken
  { userId :: !UserId,
    tokenHash :: !OneTimeTokenHash,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
