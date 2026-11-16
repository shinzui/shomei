-- | Secret-free administrative recovery commands, attribution, and committed effects.
module Shomei.Account.Admin.Recovery.Domain (RecoveryActor (..), RecoveryCommand (..), RecoveryCounts (..), RecoveryResult (..), validateRecovery, recoveryActorUser) where

import Data.Char (isAlphaNum, isAscii)
import Data.Text qualified as Text
import Shomei.Error (AuthError (InvalidInput))
import Shomei.Id (UserId)
import Shomei.Prelude

-- | Local labels are asserted attribution. Service principals are not human operators.
data RecoveryActor = AuthenticatedAdministrator UserId | AdministratorService UserId | LocalOperator Text
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RecoveryCommand = RecoveryCommand {identityVerified :: !Bool, caseReference :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RecoveryCounts = RecoveryCounts
  { passkeysRemoved :: !Int,
    totpCredentialsRemoved :: !Int,
    recoveryCodesRemoved :: !Int,
    ceremoniesRemoved :: !Int,
    sessionsRevoked :: !Int,
    refreshTokensRevoked :: !Int,
    authorizationCodesInvalidated :: !Int,
    passwordResetTokensRevoked :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RecoveryResult = RecoveryResult
  { resetAt :: !UTCTime,
    counts :: !RecoveryCounts,
    verifiedNotificationDestination :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

validateRecovery :: RecoveryActor -> RecoveryCommand -> Either AuthError ()
validateRecovery actor cmd
  | not cmd.identityVerified || not (boundedLabel cmd.caseReference) = Left InvalidInput
  | LocalOperator label <- actor, not (boundedLabel label) = Left InvalidInput
  | otherwise = Right ()
  where
    boundedLabel s = not (Text.null s) && Text.length s <= 128 && Text.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("._:/-" :: String))) s

recoveryActorUser :: RecoveryActor -> Maybe UserId
recoveryActorUser = \case
  AuthenticatedAdministrator uid -> Just uid
  AdministratorService uid -> Just uid
  LocalOperator _ -> Nothing
