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
    RateLimitConfig (..),
    ObservabilityConfig (..),
    LogFormat (..),
    defaultShomeiConfig,
    defaultAccessTokenTTL,
    defaultRefreshTokenTTL,
    defaultSessionTTL,
    defaultVerificationTokenTTL,
    defaultPasswordResetTokenTTL,
    defaultRateLimitConfig,
    defaultObservabilityConfig,
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

{- | Which built-in 'Shomei.Effect.Notifier.Notifier' interpreter the standalone
server uses.

Shōmei does __not__ send email itself. It emits a 'Shomei.Domain.Notification.Notification'
(recipient, one-time link/token, expiry) through the 'Notifier' effect; delivering that to a
user is the operator's responsibility, wired to their existing provider (SendGrid, Resend, …)
by supplying their own 'Notifier' interpreter. The toolkit ships one built-in interpreter —
'LogNotifier', which writes the link to the server log (ideal for development and for
operators who scrape logs) — plus an in-memory interpreter for tests. A dedicated
@shomei-email@ package may add provider-backed senders in the future; until then the effect
itself is the integration seam.
-}
data NotifierTransport = LogNotifier
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

{- | The abuse-protection policy (EP-2). Every field carries a default (see
'defaultRateLimitConfig') so the record is append-only per IP-3.
-}
data RateLimitConfig = RateLimitConfig
    { maxFailedLoginsPerAccount :: !Int
    -- ^ failures within 'lockoutWindow' before the account is locked (default 5)
    , maxFailedLoginsPerIp :: !Int
    -- ^ failures within 'lockoutWindow' from one IP before that IP is throttled (default 20)
    , lockoutWindow :: !NominalDiffTime
    -- ^ rolling window over which failures are counted (default 15 min)
    , lockoutDuration :: !NominalDiffTime
    -- ^ how long an account stays locked once tripped (default 15 min)
    , perIpRequestsPerMinute :: !Int
    -- ^ WAI token-bucket sustained rate per client IP (default 60)
    , perIpBurst :: !Int
    -- ^ WAI token-bucket capacity / burst per client IP (default 60)
    , rateLimitEnabled :: !Bool
    -- ^ master switch; False disables all EP-2 protections (default True)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | How the per-request structured log line is rendered (EP-3 observability).
data LogFormat = LogJson | LogPlain
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

{- | Observability policy (EP-3). Every field carries a default (see
'defaultObservabilityConfig') so the record stays append-only per IP-3.
-}
data ObservabilityConfig = ObservabilityConfig
    { logFormat :: !LogFormat
    -- ^ JSON (default) or plain text per-request log lines
    , requestLoggingEnabled :: !Bool
    -- ^ emit one structured log line per request (default True)
    , metricsEnabled :: !Bool
    -- ^ serve @GET /metrics@ and record HTTP/domain metrics (default True)
    , gracefulShutdownTimeoutSeconds :: !Int
    -- ^ how long warp waits for in-flight requests to drain on shutdown (default 30)
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
    , rateLimitConfig :: !RateLimitConfig
    , observabilityConfig :: !ObservabilityConfig
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

defaultRateLimitConfig :: RateLimitConfig
defaultRateLimitConfig =
    RateLimitConfig
        { maxFailedLoginsPerAccount = 5
        , maxFailedLoginsPerIp = 20
        , lockoutWindow = 15 * 60
        , lockoutDuration = 15 * 60
        , perIpRequestsPerMinute = 60
        , perIpBurst = 60
        , rateLimitEnabled = True
        }

defaultObservabilityConfig :: ObservabilityConfig
defaultObservabilityConfig =
    ObservabilityConfig
        { logFormat = LogJson
        , requestLoggingEnabled = True
        , metricsEnabled = True
        , gracefulShutdownTimeoutSeconds = 30
        }

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
        , rateLimitConfig = defaultRateLimitConfig
        , observabilityConfig = defaultObservabilityConfig
        }
