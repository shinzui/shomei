-- | State observed before checking a proof. Persistence checks it under the user lock.
module Shomei.Session.Authentication.Guard (AuthenticationGuard (..), userGuard) where

import Data.Int (Int64)
import Shomei.Account.User.Domain (User (..))
import Shomei.Id (PasskeyId, SessionId)
import Shomei.Prelude

data AuthenticationGuard = AuthenticationGuard
  { generation :: !Int64,
    initiatingSession :: !(Maybe SessionId),
    assertedPasskey :: !(Maybe PasskeyId)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

userGuard :: User -> AuthenticationGuard
userGuard user = AuthenticationGuard user.authenticationGeneration Nothing Nothing
