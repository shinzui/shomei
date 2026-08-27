-- | Domain types for brute-force protection: a log of login attempts (keyed by a hashed
-- account identifier and a client IP) and a per-account lockout record. The account key is a
-- hash, never the plaintext email, so the abuse store cannot become an enumeration oracle.
module Shomei.Session.LoginAttempt.Domain
  ( LoginOutcome (..),
    AttemptFactor (..),
    AccountKey (..),
    ClientIp (..),
    LoginAttempt (..),
    NewLoginAttempt (..),
    AccountLockout (..),
  )
where

import Shomei.Prelude

-- | Whether an attempt succeeded or failed. (We log both; success clears the counter.)
data LoginOutcome = LoginSuccess | LoginFailure
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Which credential an attempt proved or failed to prove. All factors share one lockout.
data AttemptFactor
  = FactorPassword
  | FactorTotp
  | FactorRecoveryCode
  | FactorPasskey
  | FactorPasswordChange
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A SHA-256 (hex) of the normalized email presented at login. Opaque key for counting.
newtype AccountKey = AccountKey Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

-- | The client's source IP as text (e.g. "203.0.113.7"). Source of the per-IP throttle.
newtype ClientIp = ClientIp Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

-- | A persisted login attempt (one row in @shomei_login_attempts@).
data LoginAttempt = LoginAttempt
  { accountKey :: !AccountKey,
    clientIp :: !ClientIp,
    outcome :: !LoginOutcome,
    occurredAt :: !UTCTime,
    factor :: !AttemptFactor
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Input for recording an attempt (identical fields; no server-assigned columns).
data NewLoginAttempt = NewLoginAttempt
  { accountKey :: !AccountKey,
    clientIp :: !ClientIp,
    outcome :: !LoginOutcome,
    occurredAt :: !UTCTime,
    factor :: !AttemptFactor
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The lockout state for one account key (one row in @shomei_account_lockouts@).
data AccountLockout = AccountLockout
  { accountKey :: !AccountKey,
    failedCount :: !Int,
    lockedUntil :: !(Maybe UTCTime),
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
