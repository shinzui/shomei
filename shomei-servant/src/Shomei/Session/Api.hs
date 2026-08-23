-- | Session-owned HTTP routes.
module Shomei.Session.Api
  ( SessionApi (..),
    LoginRoute,
    RefreshRoute,
    LogoutRoute,
    CurrentSessionRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses, RateLimited)
import Shomei.Servant.Result (ApplicationContentTypes, BadRequestPreHandlerResponses)
import Shomei.Session.Dto (LoginRequest, RefreshRequest)
import Shomei.Session.Result

type LoginRoute = "login" :> RateLimited :> RemoteHost :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] LoginRequest :> MultiVerb 'POST ApplicationContentTypes LoginResponses LoginResult

type RefreshRoute = "refresh" :> RateLimited :> CsrfProtected :> Header "Cookie" Text :> Header "Origin" Text :> Header "Referer" Text :> PreHandlerResponses BadRequestPreHandlerResponses :> ReqBody '[JSON] RefreshRequest :> MultiVerb 'POST ApplicationContentTypes RefreshResponses RefreshResult

type LogoutRoute = "logout" :> Authenticated :> CsrfProtected :> MultiVerb 'POST ApplicationContentTypes LogoutResponses LogoutResult

type CurrentSessionRoute = Authenticated :> "session" :> MultiVerb 'GET ApplicationContentTypes CurrentSessionResponses CurrentSessionResult

data SessionApi mode = SessionApi
  { login :: mode :- LoginRoute,
    refresh :: mode :- RefreshRoute,
    logout :: mode :- LogoutRoute,
    currentSession :: mode :- CurrentSessionRoute
  }
  deriving stock (Generic)
