-- | OAuth 2.0 protocol routes. These use protocol result types rather than application problems.
module Shomei.OAuth.Api
  ( OAuthApi (..),
    AuthorizeRoute,
    TokenRoute,
    UserinfoRoute,
    IntrospectRoute,
    RevokeRoute,
  )
where

import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.OAuth.Result
import Shomei.Prelude
import Shomei.Servant.Auth (OAuthAuthenticated)
import Web.FormUrlEncoded (Form)

type AuthorizeRoute = "authorize" :> Header "Authorization" Text :> Header "Cookie" Text :> QueryParam "response_type" Text :> QueryParam "client_id" Text :> QueryParam "redirect_uri" Text :> QueryParam "scope" Text :> QueryParam "state" Text :> QueryParam "nonce" Text :> QueryParam "code_challenge" Text :> QueryParam "code_challenge_method" Text :> MultiVerb 'GET '[JSON] AuthorizeResponses AuthorizeResult

type TokenRoute = "token" :> Header "Authorization" Text :> RemoteHost :> ReqBody '[FormUrlEncoded] Form :> MultiVerb 'POST '[JSON] TokenResponses TokenResult

type UserinfoRoute = "userinfo" :> OAuthAuthenticated :> MultiVerb 'GET '[JSON] UserinfoResponses UserinfoResult

type IntrospectRoute = "introspect" :> Header "Authorization" Text :> ReqBody '[FormUrlEncoded] Form :> MultiVerb 'POST '[JSON] IntrospectResponses IntrospectResult

type RevokeRoute = "revoke" :> Header "Authorization" Text :> ReqBody '[FormUrlEncoded] Form :> MultiVerb 'POST '[JSON] RevokeResponses RevokeResult

data OAuthApi mode = OAuthApi
  { authorize :: mode :- AuthorizeRoute,
    token :: mode :- TokenRoute,
    userinfo :: mode :- UserinfoRoute,
    introspect :: mode :- IntrospectRoute,
    revoke :: mode :- RevokeRoute
  }
  deriving stock (Generic)
