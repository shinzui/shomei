{-# LANGUAGE DataKinds #-}

-- | Domain types for the EP-7 TOTP credential and recovery-code stores.
--
-- A 'TotpCredential' carries the /raw/ 'TotpSecret' (Decision Log: encryption lives at the
-- PostgreSQL interpreter boundary, never in the workflows or the port). These types are
-- persisted through native columns (@bytea@ for the encrypted secret, @text@ for a recovery
-- code hash), not JSON, so — unlike 'Shomei.Domain.Passkey' — they carry no aeson instances;
-- the raw 'TotpSecret' has no JSON representation by design.
module Shomei.Domain.Totp
  ( NewTotpCredential (..),
    TotpCredential (..),
    NewRecoveryCode (..),
    RecoveryCode (..),
    isTotpConfirmed,
  )
where

import Data.Int (Int64)
import Shomei.Id (RecoveryCodeId, TotpCredentialId, UserId)
import Shomei.Prelude
import Shomei.Totp (TotpSecret)

-- | A freshly generated (unconfirmed) TOTP enrollment, ready for the store to persist.
data NewTotpCredential = NewTotpCredential
  { totpCredentialId :: !TotpCredentialId,
    userId :: !UserId,
    secret :: !TotpSecret,
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | A persisted TOTP credential. @confirmedAt = Nothing@ marks an enrollment that has not yet
-- been activated with a first valid code; @lastUsedCounter@ is the replay-defense high-water
-- mark (RFC 6238 §5.2), 'Nothing' until the first acceptance.
data TotpCredential = TotpCredential
  { totpCredentialId :: !TotpCredentialId,
    userId :: !UserId,
    secret :: !TotpSecret,
    lastUsedCounter :: !(Maybe Int64),
    confirmedAt :: !(Maybe UTCTime),
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | One recovery code to persist: only its hash is stored (the plaintext is shown to the user
-- once and never again).
data NewRecoveryCode = NewRecoveryCode
  { recoveryCodeId :: !RecoveryCodeId,
    codeHash :: !Text,
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | A persisted recovery code. @usedAt = Nothing@ marks it still spendable; consumption is a
-- compare-and-set that stamps @usedAt@ exactly once.
data RecoveryCode = RecoveryCode
  { recoveryCodeId :: !RecoveryCodeId,
    userId :: !UserId,
    codeHash :: !Text,
    createdAt :: !UTCTime,
    usedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

-- | Whether a credential has been activated with a first valid code. A 'DuplicateRecordFields'
-- record's @.confirmedAt@ dot access is ambiguous at call sites that do not fix the type, so
-- this named predicate is the canonical read.
isTotpConfirmed :: TotpCredential -> Bool
isTotpConfirmed TotpCredential {confirmedAt} = isJust confirmedAt
