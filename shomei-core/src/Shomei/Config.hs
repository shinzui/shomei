{- | The runtime configuration record (IP-5).

'ShomeiConfig' carries the issuer/audience, the access/refresh/session TTLs, the
password policy, the token transport, the signing-key config, and the session-check
mode. 'defaultShomeiConfig' supplies sane defaults given an issuer and audience.
-}
module Shomei.Config (
    ShomeiConfig (..),
    TokenTransport (..),
    SessionCheckMode (..),
    SigningKeyConfig (..),
    NotifierConfig (..),
    NotifierTransport (..),
    defaultShomeiConfig,
    defaultAccessTokenTTL,
    defaultRefreshTokenTTL,
    defaultSessionTTL,
    defaultVerificationTokenTTL,
    defaultPasswordResetTokenTTL,
) where

import Shomei.Prelude

import Data.Time (NominalDiffTime)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Password (PasswordPolicy, defaultPasswordPolicy)

data TokenTransport = BearerToken | HttpOnlyCookie | BearerAndCookie
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data SessionCheckMode = VerifyTokenOnly | VerifyTokenAndSession
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

newtype SigningKeyConfig = SigningKeyConfig {algorithm :: Text}
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NotifierTransport = LogNotifier | SmtpNotifier
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data NotifierConfig = NotifierConfig
    { emailVerificationRequired :: !Bool
    , verificationTokenTTL :: !NominalDiffTime
    , passwordResetTokenTTL :: !NominalDiffTime
    , notifierTransport :: !NotifierTransport
    , publicBaseUrl :: !Text
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data ShomeiConfig = ShomeiConfig
    { issuer :: !Issuer
    , audience :: !Audience
    , accessTokenTTL :: !NominalDiffTime
    , refreshTokenTTL :: !NominalDiffTime
    , sessionTTL :: !NominalDiffTime
    , passwordPolicy :: !PasswordPolicy
    , tokenTransport :: !TokenTransport
    , signingKeyConfig :: !SigningKeyConfig
    , sessionCheckMode :: !SessionCheckMode
    , notifierConfig :: !NotifierConfig
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultAccessTokenTTL, defaultRefreshTokenTTL, defaultSessionTTL :: NominalDiffTime
defaultAccessTokenTTL = 15 * 60 -- 15 minutes
defaultRefreshTokenTTL = 30 * 24 * 60 * 60 -- 30 days
defaultSessionTTL = 30 * 24 * 60 * 60 -- 30 days

defaultVerificationTokenTTL, defaultPasswordResetTokenTTL :: NominalDiffTime
defaultVerificationTokenTTL = 24 * 60 * 60 -- 24 hours
defaultPasswordResetTokenTTL = 60 * 60 -- 1 hour

defaultShomeiConfig :: Issuer -> Audience -> ShomeiConfig
defaultShomeiConfig iss aud =
    ShomeiConfig
        { issuer = iss
        , audience = aud
        , accessTokenTTL = defaultAccessTokenTTL
        , refreshTokenTTL = defaultRefreshTokenTTL
        , sessionTTL = defaultSessionTTL
        , passwordPolicy = defaultPasswordPolicy
        , tokenTransport = BearerToken
        , signingKeyConfig = SigningKeyConfig{algorithm = "ES256"}
        , sessionCheckMode = VerifyTokenOnly
        , notifierConfig =
            NotifierConfig
                { emailVerificationRequired = False
                , verificationTokenTTL = defaultVerificationTokenTTL
                , passwordResetTokenTTL = defaultPasswordResetTokenTTL
                , notifierTransport = LogNotifier
                , publicBaseUrl = "http://localhost:8080"
                }
        }
