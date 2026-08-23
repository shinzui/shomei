-- | OAuth 2.0 protocol routes. These use protocol result types rather than application problems.
module Shomei.OAuth.Api (OAuthApi (..)) where

import Data.Aeson (Value)
import Servant.API
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.OAuth (TokenResponse)
import Web.FormUrlEncoded (Form)

data OAuthApi mode = OAuthApi
  { authorize :: mode :- "authorize" :> Header "Authorization" Text :> Header "Cookie" Text :> QueryParam "response_type" Text :> QueryParam "client_id" Text :> QueryParam "redirect_uri" Text :> QueryParam "scope" Text :> QueryParam "state" Text :> QueryParam "nonce" Text :> QueryParam "code_challenge" Text :> QueryParam "code_challenge_method" Text :> Verb 'GET 302 '[JSON] (Headers '[Header "Location" Text, Header "Cache-Control" Text] NoContent),
    token :: mode :- "token" :> Header "Authorization" Text :> RemoteHost :> ReqBody '[FormUrlEncoded] Form :> Post '[JSON] (Headers '[Header "Cache-Control" Text, Header "Pragma" Text] TokenResponse),
    userinfo :: mode :- "userinfo" :> Authenticated :> Get '[JSON] Value,
    introspect :: mode :- "introspect" :> Header "Authorization" Text :> ReqBody '[FormUrlEncoded] Form :> Post '[JSON] Value,
    revoke :: mode :- "revoke" :> Header "Authorization" Text :> ReqBody '[FormUrlEncoded] Form :> Post '[JSON] NoContent
  }
  deriving stock (Generic)
