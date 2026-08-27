-- | The commands that drive the auth workflows.
--
-- The password-bearing commands ('SignupCommand', 'LoginCommand') carry a
-- 'PlainPassword', so they get a 'Show' only via the redacting 'PlainPassword' instance
-- and deliberately no JSON instances. EP-5's DTO layer maps HTTP requests to these.
module Shomei.Session.Command
  ( SignupCommand (..),
    LoginCommand (..),
    RefreshCommand (..),
    RefreshOrigin (..),
    LogoutCommand (..),
    ClientContext (..),
  )
where

import Shomei.Account.Email.Domain (Email)
import Shomei.Account.LoginId.Domain (LoginId)
import Shomei.Account.Password.Domain (PlainPassword)
import Shomei.Id (SessionId)
import Shomei.Prelude
import Shomei.Session.LoginAttempt.Domain (AccountKey, ClientIp)
import Shomei.Session.RefreshToken.Domain (RefreshToken)

data SignupCommand = SignupCommand
  { loginId :: !LoginId,
    email :: !(Maybe Email),
    password :: !PlainPassword,
    displayName :: !(Maybe Text)
  }
  deriving stock (Generic, Show)

data LoginCommand = LoginCommand
  { loginId :: !LoginId,
    password :: !PlainPassword
  }
  deriving stock (Generic, Show)

newtype RefreshCommand = RefreshCommand {refreshToken :: RefreshToken}
  deriving stock (Generic, Show)

-- | Which endpoint is rotating. The bespoke endpoint has no client identity, so it may not
-- rotate a session an OAuth client minted; the OAuth grant may rotate only its own.
data RefreshOrigin = BespokeRefresh | OAuthClientRefresh Text
  deriving stock (Generic, Eq, Show)

newtype LogoutCommand = LogoutCommand {sessionId :: SessionId}
  deriving stock (Generic, Show)

-- | Per-request context the 'Shomei.Session.Authentication.Workflow.login' workflow needs for abuse protection:
-- the client's source IP (for the per-IP failure throttle) and the precomputed hashed account
-- key for the presented login identifier (so the core never needs a crypto dependency, and the
-- abuse store never holds a plaintext principal).
data ClientContext = ClientContext
  { clientIp :: !ClientIp,
    accountKey :: !AccountKey
  }
  deriving stock (Generic, Show)
