-- | Account lifecycle request and response wire types.
module Shomei.Account.Dto
  ( SignupRequest (..),
    SignupResponse (..),
    VerifyEmailRequest (..),
    ConfirmEmailVerificationRequest (..),
    PasswordResetRequest (..),
    ConfirmPasswordResetRequest (..),
    ChangePasswordRequest (..),
  )
where

import Shomei.Account.User.Dto (UserResponse)
import Shomei.Prelude
import Shomei.Session.Dto (TokenPairResponse)

data SignupRequest = SignupRequest
  { loginId :: !Text,
    email :: !(Maybe Text),
    password :: !Text,
    displayName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data SignupResponse = SignupResponse
  { user :: !UserResponse,
    token :: !TokenPairResponse
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype VerifyEmailRequest = VerifyEmailRequest {email :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype ConfirmEmailVerificationRequest = ConfirmEmailVerificationRequest {token :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype PasswordResetRequest = PasswordResetRequest {email :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data ConfirmPasswordResetRequest = ConfirmPasswordResetRequest
  { token :: !Text,
    newPassword :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data ChangePasswordRequest = ChangePasswordRequest
  { currentPassword :: !Text,
    newPassword :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)
