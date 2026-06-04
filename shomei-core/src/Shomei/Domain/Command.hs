{- | The commands that drive the auth workflows.

The password-bearing commands ('SignupCommand', 'LoginCommand') carry a
'PlainPassword', so they get a 'Show' only via the redacting 'PlainPassword' instance
and deliberately no JSON instances. EP-5's DTO layer maps HTTP requests to these.
-}
module Shomei.Domain.Command (
    SignupCommand (..),
    LoginCommand (..),
    RefreshCommand (..),
    LogoutCommand (..),
) where

import Shomei.Prelude

import Shomei.Domain.Email (Email)
import Shomei.Domain.Password (PlainPassword)
import Shomei.Domain.RefreshToken (RefreshToken)
import Shomei.Id (SessionId)

data SignupCommand = SignupCommand
    { email :: !Email
    , password :: !PlainPassword
    , displayName :: !(Maybe Text)
    }
    deriving stock (Generic, Show)

data LoginCommand = LoginCommand
    { email :: !Email
    , password :: !PlainPassword
    }
    deriving stock (Generic, Show)

newtype RefreshCommand = RefreshCommand {refreshToken :: RefreshToken}
    deriving stock (Generic, Show)

newtype LogoutCommand = LogoutCommand {sessionId :: SessionId}
    deriving stock (Generic, Show)
