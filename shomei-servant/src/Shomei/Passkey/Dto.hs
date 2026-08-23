-- | Passkey registration, management, and passwordless-login wire types.
module Shomei.Passkey.Dto
  ( PasskeyRegisterBeginResponse (..),
    PasskeyRegisterCompleteRequest (..),
    PasskeyResponse (..),
    PasskeyLoginBeginResponse (..),
    PasskeyLoginCompleteRequest (..),
    passkeyToResponse,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Shomei.Id (idText)
import Shomei.Passkey.Domain (PasskeyCredential (..))
import Shomei.Prelude

data PasskeyRegisterBeginResponse = PasskeyRegisterBeginResponse
  { ceremonyId :: !Text,
    options :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data PasskeyRegisterCompleteRequest = PasskeyRegisterCompleteRequest
  { ceremonyId :: !Text,
    credential :: !Value,
    label :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data PasskeyResponse = PasskeyResponse
  { passkeyId :: !Text,
    label :: !(Maybe Text),
    transports :: ![Text],
    createdAt :: !Text,
    lastUsedAt :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data PasskeyLoginBeginResponse = PasskeyLoginBeginResponse
  { ceremonyId :: !Text,
    options :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data PasskeyLoginCompleteRequest = PasskeyLoginCompleteRequest
  { ceremonyId :: !Text,
    assertion :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

passkeyToResponse :: PasskeyCredential -> PasskeyResponse
passkeyToResponse PasskeyCredential {passkeyId, label, transports, createdAt, lastUsedAt} =
  PasskeyResponse
    { passkeyId = idText passkeyId,
      label = label,
      transports = transports,
      createdAt = Text.pack (iso8601Show createdAt),
      lastUsedAt = Text.pack . iso8601Show <$> lastUsedAt
    }
