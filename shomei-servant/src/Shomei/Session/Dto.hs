-- | Session, token, and login wire types.
module Shomei.Session.Dto
  ( TokenPairResponse (..),
    LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    SessionResponse (..),
    tokenPairToResponse,
    loginResultToResponse,
    sessionToResponse,
  )
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Shomei.Account.User.Dto (UserResponse, userToResponse)
import Shomei.Config (ShomeiConfig (..), transportIncludesBodyTokens)
import Shomei.Id (idText)
import Shomei.Prelude
import Shomei.Session.Authentication.Workflow (LoginResult (..), MfaChallenge (..))
import Shomei.Session.Domain (Session (..), SessionStatus (..))
import Shomei.Session.RefreshToken.Domain (RefreshToken (..))
import Shomei.Session.Token.Domain (AccessToken (..), TokenPair (..))

data TokenPairResponse = TokenPairResponse
  { accessToken :: !(Maybe Text),
    refreshToken :: !(Maybe Text),
    expiresIn :: !Int
  }
  deriving stock (Generic)

instance ToJSON TokenPairResponse where
  toJSON response =
    object $
      catMaybes
        [ ("accessToken" Aeson..=) <$> response.accessToken,
          ("refreshToken" Aeson..=) <$> response.refreshToken,
          Just ("expiresIn" Aeson..= response.expiresIn)
        ]

instance FromJSON TokenPairResponse where
  parseJSON = withObject "TokenPairResponse" \objectValue ->
    TokenPairResponse
      <$> objectValue Aeson..:? "accessToken"
      <*> objectValue Aeson..:? "refreshToken"
      <*> objectValue .: "expiresIn"

data LoginRequest = LoginRequest
  { loginId :: !Text,
    password :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data LoginResponse
  = LoginCompleteResponse
      { user :: !UserResponse,
        token :: !TokenPairResponse
      }
  | LoginMfaRequiredResponse
      { ceremonyId :: !Text,
        options :: !Value,
        methods :: ![Text]
      }
  deriving stock (Generic)

instance ToJSON LoginResponse where
  toJSON = \case
    LoginCompleteResponse user token ->
      object ["status" Aeson..= ("complete" :: Text), "user" Aeson..= user, "token" Aeson..= token]
    LoginMfaRequiredResponse ceremonyId options methods ->
      object
        [ "status" Aeson..= ("mfa_required" :: Text),
          "ceremonyId" Aeson..= ceremonyId,
          "options" Aeson..= options,
          "methods" Aeson..= methods
        ]

instance FromJSON LoginResponse where
  parseJSON = withObject "LoginResponse" \objectValue -> do
    status <- objectValue .: "status" :: Parser Text
    case status of
      "complete" -> LoginCompleteResponse <$> objectValue .: "user" <*> objectValue .: "token"
      "mfa_required" -> LoginMfaRequiredResponse <$> objectValue .: "ceremonyId" <*> objectValue .: "options" <*> objectValue .: "methods"
      other -> fail ("unknown login status: " <> Text.unpack other)

newtype RefreshRequest = RefreshRequest {refreshToken :: Maybe Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data SessionResponse = SessionResponse
  { sessionId :: !Text,
    userId :: !Text,
    createdAt :: !Text,
    expiresAt :: !Text,
    status :: !Text,
    revokedAt :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

tokenPairToResponse :: ShomeiConfig -> TokenPair -> TokenPairResponse
tokenPairToResponse config pair =
  TokenPairResponse
    { accessToken = bodyToken (unAccess pair.accessToken),
      refreshToken = bodyToken (unRefresh pair.refreshToken),
      expiresIn = round (realToFrac pair.expiresIn :: Double)
    }
  where
    bodyToken token = if transportIncludesBodyTokens config.tokenTransport then Just token else Nothing
    unAccess (AccessToken token) = token
    unRefresh (RefreshToken token) = token

loginResultToResponse :: ShomeiConfig -> LoginResult -> LoginResponse
loginResultToResponse config = \case
  LoginComplete user pair ->
    LoginCompleteResponse {user = userToResponse user, token = tokenPairToResponse config pair}
  MfaRequired (MfaChallenge ceremonyId options methods) ->
    LoginMfaRequiredResponse {ceremonyId = idText ceremonyId, options = options, methods = methods}

sessionToResponse :: Session -> SessionResponse
sessionToResponse session =
  SessionResponse
    { sessionId = idText session.sessionId,
      userId = idText session.userId,
      createdAt = Text.pack (iso8601Show session.createdAt),
      expiresAt = Text.pack (iso8601Show session.expiresAt),
      status = renderStatus session.status,
      revokedAt = Text.pack . iso8601Show <$> session.revokedAt
    }
  where
    renderStatus = \case
      SessionActive -> "active"
      SessionRevoked -> "revoked"
      SessionExpired -> "expired"
