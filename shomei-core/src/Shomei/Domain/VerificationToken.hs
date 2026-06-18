-- | Email-verification token rows.
module Shomei.Domain.VerificationToken
  ( PersistedVerificationToken (..),
    NewVerificationToken (..),
  )
where

import Shomei.Domain.OneTimeToken (OneTimeTokenHash, OneTimeTokenStatus)
import Shomei.Id (UserId, VerificationTokenId)
import Shomei.Prelude

data PersistedVerificationToken = PersistedVerificationToken
  { verificationTokenId :: !VerificationTokenId,
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

data NewVerificationToken = NewVerificationToken
  { userId :: !UserId,
    tokenHash :: !OneTimeTokenHash,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
