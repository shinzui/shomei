-- | Session-owned HTTP routes.
module Shomei.Session.Api (SessionApi (..)) where

import Servant.API
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Cookie (WithCookies)
import Shomei.Servant.PreHandler (CsrfProtected, RateLimited)
import Shomei.Session.Dto (LoginRequest, LoginResponse, RefreshRequest, SessionResponse, TokenPairResponse)

data SessionApi mode = SessionApi
  { login :: mode :- "login" :> RateLimited :> RemoteHost :> ReqBody '[JSON] LoginRequest :> Post '[JSON] (WithCookies LoginResponse),
    refresh :: mode :- "refresh" :> RateLimited :> CsrfProtected :> Header "Cookie" Text :> Header "Origin" Text :> Header "Referer" Text :> ReqBody '[JSON] RefreshRequest :> Post '[JSON] (WithCookies TokenPairResponse),
    logout :: mode :- "logout" :> Authenticated :> CsrfProtected :> Verb 'POST 204 '[JSON] (WithCookies NoContent),
    currentSession :: mode :- Authenticated :> "session" :> Get '[JSON] SessionResponse
  }
  deriving stock (Generic)
