-- | MFA, TOTP, and recovery-code wire types.
module Shomei.Mfa.Dto
  ( MfaProof (..),
    MfaCompleteRequest (..),
    mfaCompletionOf,
    TotpEnrollResponse (..),
    TotpVerifyRequest (..),
    TotpRemoveRequest (..),
    totpRemovalProofOf,
    RecoveryCodesResponse (..),
    RecoveryCodesCountResponse (..),
  )
where

import Data.Aeson (Value, object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.List (sort)
import Data.Maybe (catMaybes, isJust)
import Data.Text qualified as Text
import Shomei.Mfa.Totp.Workflow (TotpRemovalProof (..))
import Shomei.Mfa.Workflow (MfaCompletion (..))
import Shomei.Prelude

data MfaProof
  = PasskeyProof {assertion :: !Value}
  | TotpProof {code :: !Text}
  | RecoveryCodeProof {code :: !Text}
  deriving stock (Generic)

instance FromJSON MfaProof where
  parseJSON = withObject "MfaProof" \objectValue -> do
    proofType <- objectValue .: "type" :: Parser Text
    case proofType of
      "passkey" -> requireKeys ["assertion", "type"] objectValue >> PasskeyProof <$> objectValue .: "assertion"
      "totp" -> requireKeys ["code", "type"] objectValue >> TotpProof <$> objectValue .: "code"
      "recovery_code" -> requireKeys ["code", "type"] objectValue >> RecoveryCodeProof <$> objectValue .: "code"
      other -> fail ("unknown MFA proof type: " <> Text.unpack other)
    where
      requireKeys expected objectValue =
        unless (sort (map Key.toText (KeyMap.keys objectValue)) == expected) $
          fail "MFA proof contains missing or unexpected fields"

instance ToJSON MfaProof where
  toJSON = \case
    PasskeyProof assertion -> object ["type" Aeson..= ("passkey" :: Text), "assertion" Aeson..= assertion]
    TotpProof code -> object ["type" Aeson..= ("totp" :: Text), "code" Aeson..= code]
    RecoveryCodeProof code -> object ["type" Aeson..= ("recovery_code" :: Text), "code" Aeson..= code]

data MfaCompleteRequest = MfaCompleteRequest
  { ceremonyId :: !Text,
    proof :: !MfaProof
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

mfaCompletionOf :: MfaCompleteRequest -> MfaCompletion
mfaCompletionOf MfaCompleteRequest {proof} = case proof of
  PasskeyProof assertion -> MfaPasskey assertion
  TotpProof code -> MfaTotp code
  RecoveryCodeProof code -> MfaRecoveryCode code

data TotpEnrollResponse = TotpEnrollResponse
  { secret :: !Text,
    otpauthUri :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype TotpVerifyRequest = TotpVerifyRequest {code :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data TotpRemoveRequest = TotpRemoveRequest
  { code :: !(Maybe Text),
    recoveryCode :: !(Maybe Text)
  }
  deriving stock (Generic)

instance FromJSON TotpRemoveRequest where
  parseJSON = withObject "TotpRemoveRequest" \objectValue -> do
    code <- objectValue .:? "code"
    recoveryCode <- objectValue .:? "recoveryCode"
    case (isJust code, isJust recoveryCode) of
      (True, False) -> pure (TotpRemoveRequest code recoveryCode)
      (False, True) -> pure (TotpRemoveRequest code recoveryCode)
      _ -> fail "exactly one of code, recoveryCode must be present"

instance ToJSON TotpRemoveRequest where
  toJSON (TotpRemoveRequest code recoveryCode) =
    object (catMaybes [("code" Aeson..=) <$> code, ("recoveryCode" Aeson..=) <$> recoveryCode])

totpRemovalProofOf :: TotpRemoveRequest -> TotpRemovalProof
totpRemovalProofOf (TotpRemoveRequest code recoveryCode) = case (code, recoveryCode) of
  (Just value, _) -> RemoveWithCode value
  (_, Just value) -> RemoveWithRecoveryCode value
  _ -> RemoveWithCode ""

newtype RecoveryCodesResponse = RecoveryCodesResponse {codes :: [Text]}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype RecoveryCodesCountResponse = RecoveryCodesCountResponse {remaining :: Int}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)
