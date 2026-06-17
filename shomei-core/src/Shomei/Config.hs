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
    WebAuthnConfig (..),
    UserVerificationPolicy (..),
    AttestationPolicy (..),
    ImpersonationConfig (..),
    defaultWebAuthnConfig,
    defaultImpersonationConfig,
    defaultShomeiConfig,
    defaultAccessTokenTTL,
    defaultRefreshTokenTTL,
    defaultSessionTTL,
    defaultVerificationTokenTTL,
    defaultPasswordResetTokenTTL,
    defaultRateLimitConfig,
    defaultObservabilityConfig,
    configSigningAlgorithm,
) where

import Shomei.Prelude

import Data.Time (NominalDiffTime)
import Shomei.Domain.Claims (Audience (..), Issuer (..), Scope (..))
import Shomei.Domain.Password (PasswordPolicy, defaultPasswordPolicy)
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256), signingAlgorithmFromText)

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

{- | WebAuthn / passkey policy (MasterPlan 3, IP-3). Carries the Relying Party
identity (the @rpId@ scope domain, the allowed @origins@, the human RP name) and
ceremony policy. Every field has a default (see 'defaultWebAuthnConfig') so the
record stays append-only per IP-3; the @shomei-webauthn@ interpreter reads the RP
identity and 'EP-4' reads 'mfaRequired'.
-}
data UserVerificationPolicy = UVRequired | UVPreferred | UVDiscouraged
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data AttestationPolicy = AttestationNone | AttestationDirect
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data WebAuthnConfig = WebAuthnConfig
    { rpId :: !Text
    -- ^ the scope domain a passkey is bound to, e.g. @auth.example.com@
    , rpName :: !Text
    -- ^ the human-readable Relying Party name shown by the authenticator
    , origins :: ![Text]
    -- ^ allowed web origins, e.g. @https://auth.example.com@
    , userVerification :: !UserVerificationPolicy
    , attestation :: !AttestationPolicy
    , ceremonyTimeout :: !NominalDiffTime
    -- ^ browser-facing ceremony timeout
    , pendingCeremonyTTL :: !NominalDiffTime
    -- ^ how long a begun ceremony's options blob stays valid server-side
    , mfaRequired :: !Bool
    -- ^ whether accounts that have a passkey MUST complete MFA at login
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

{- | Impersonation / delegated-token policy (token-exchange plan). Carries the
scope a caller must hold to start impersonation, the lifetime of the delegated
session/token, and how recently the caller must have authenticated. Every field
has a default (see 'defaultImpersonationConfig') so the record stays append-only.
-}
data ImpersonationConfig = ImpersonationConfig
    { impersonateScope :: !Scope
    -- ^ scope a caller must hold to start impersonation; default @impersonate:user@
    , impersonationSessionTTL :: !NominalDiffTime
    -- ^ lifetime of the delegated session/token; default 30 minutes
    , actorFreshnessWindow :: !NominalDiffTime
    -- ^ caller's own access token must have been issued within this window; default 5 minutes
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultImpersonationConfig :: ImpersonationConfig
defaultImpersonationConfig =
    ImpersonationConfig
        { impersonateScope = Scope "impersonate:user"
        , impersonationSessionTTL = 30 * 60
        , actorFreshnessWindow = 5 * 60
        }

defaultWebAuthnConfig :: WebAuthnConfig
defaultWebAuthnConfig =
    WebAuthnConfig
        { rpId = "localhost"
        , rpName = "Shōmei"
        , origins = ["http://localhost:8080"]
        , userVerification = UVPreferred
        , attestation = AttestationNone
        , ceremonyTimeout = 300
        , pendingCeremonyTTL = 300
        , mfaRequired = True
        }

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
    , webauthnConfig :: !WebAuthnConfig
    , impersonationConfig :: !ImpersonationConfig
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

{- | The signing algorithm a config selects, parsed from
@signingKeyConfig.algorithm@. Defaults to 'ES256' on absent/invalid text so a
misconfigured deployment stays on the safe default rather than failing to boot.
-}
configSigningAlgorithm :: ShomeiConfig -> SigningAlgorithm
configSigningAlgorithm cfg =
    either (const ES256) id (signingAlgorithmFromText cfg.signingKeyConfig.algorithm)

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
        , webauthnConfig = defaultWebAuthnConfig
        , impersonationConfig = defaultImpersonationConfig
        }
