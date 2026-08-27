-- The typed schema for a Shōmei runtime configuration file.
-- Every field is optional; an absent field falls back to the built-in default, and any
-- SHOMEI_* variable overrides the file. Use record completion so omitted fields become None:
--     let Shomei = ./shomei-types.dhall
--     in Shomei::{ databaseUrl = Some "host=localhost dbname=shomei" }
--
-- The server renders the completed file with `dhall-to-json` and decodes it. Database
-- credentials may live here, so the live `config/shomei.dhall` file is gitignored. Notifier,
-- signing-key, and TOTP encryption secrets remain environment-only.
let ConfigType =
      { issuer : Optional Text
      , audience : Optional Text
      , databaseUrl : Optional Text
      , port : Optional Natural
      , trustedProxies : Optional (List Text)
      , proxyProtocol : Optional Text
      , dbPoolSize : Optional Natural
      , dbPoolAcquisitionTimeoutMs : Optional Natural
      , dbStatementTimeoutMs : Optional Natural
      , sweepEnabled : Optional Bool
      , sweepIntervalSeconds : Optional Natural
      , sweepBatchSize : Optional Natural
      , sweepDeadSessionGraceDays : Optional Natural
      , sweepOneTimeTokenGraceDays : Optional Natural
      , sweepCeremonyGraceMinutes : Optional Natural
      , loginAttemptRetentionDays : Optional Natural
      , authEventRetentionDays : Optional Natural
      , argon2MemoryKiB : Optional Natural
      , argon2Iterations : Optional Natural
      , argon2Parallelism : Optional Natural
      , hashingMaxConcurrency : Optional Natural
      , accessTokenTtlSeconds : Optional Natural
      , refreshTokenTtlSeconds : Optional Natural
      , sessionTtlSeconds : Optional Natural
      , publicBaseUrl : Optional Text
      , emailVerificationRequired : Optional Bool
      , notifierTransport : Optional Text
      , alsoLogNotifications : Optional Bool
      , smtpHost : Optional Text
      , smtpPort : Optional Natural
      , smtpTlsMode : Optional Text
      , smtpUsername : Optional Text
      , smtpFromAddress : Optional Text
      , smtpTimeoutSeconds : Optional Natural
      , webhookUrl : Optional Text
      , webhookTimeoutSeconds : Optional Natural
      , webhookMaxAttempts : Optional Natural
      , notifierQueueSize : Optional Natural
      , rateLimitEnabled : Optional Bool
      , maxFailedLoginsPerAccount : Optional Natural
      , maxFailedLoginsPerIp : Optional Natural
      , perIpRequestsPerMinute : Optional Natural
      , perIpBurst : Optional Natural
      , lockoutWindowSeconds : Optional Natural
      , lockoutDurationSeconds : Optional Natural
      , metricsEnabled : Optional Bool
      , requestLoggingEnabled : Optional Bool
      , gracefulShutdownTimeoutSeconds : Optional Natural
      , passwordMinLength : Optional Natural
      , passwordMaxLength : Optional Natural
      , passwordRejectCommon : Optional Bool
      , passwordRejectContextual : Optional Bool
      , passwordBreachCheckEnabled : Optional Bool
      , passwordBreachCheckFailClosed : Optional Bool
      , passwordBreachCheckTimeoutMs : Optional Natural
      , webauthnRpId : Optional Text
      , webauthnRpName : Optional Text
      , webauthnOrigins : Optional (List Text)
      , webauthnUserVerification : Optional Text
      , webauthnAttestation : Optional Text
      , webauthnCeremonyTimeoutSeconds : Optional Natural
      , webauthnPendingCeremonyTtlSeconds : Optional Natural
      , mfaRequireSecondFactor : Optional Bool
      , totpEnabled : Optional Bool
      , totpEnrollmentTtlSeconds : Optional Natural
      , machineTokenTtlSeconds : Optional Natural
      , oidcEnabled : Optional Bool
      , oauthLoginUrl : Optional Text
      , oauthAuthorizationCodeTtlSeconds : Optional Natural
      , oauthIdTokenTtlSeconds : Optional Natural
      , allowedClockSkewSeconds : Optional Natural
      , signingAlgorithm : Optional Text
      , keyRefreshIntervalSeconds : Optional Natural
      , tokenTransport : Optional Text
      , cookieSecure : Optional Bool
      , cookieSameSite : Optional Text
      , csrfAllowedOrigins : Optional (List Text)
      , defaultRoles : Optional (List Text)
      }

let default =
      { issuer = None Text
      , audience = None Text
      , databaseUrl = None Text
      , port = None Natural
      , trustedProxies = None (List Text)
      , proxyProtocol = None Text
      , dbPoolSize = None Natural
      , dbPoolAcquisitionTimeoutMs = None Natural
      , dbStatementTimeoutMs = None Natural
      , sweepEnabled = None Bool
      , sweepIntervalSeconds = None Natural
      , sweepBatchSize = None Natural
      , sweepDeadSessionGraceDays = None Natural
      , sweepOneTimeTokenGraceDays = None Natural
      , sweepCeremonyGraceMinutes = None Natural
      , loginAttemptRetentionDays = None Natural
      , authEventRetentionDays = None Natural
      , argon2MemoryKiB = None Natural
      , argon2Iterations = None Natural
      , argon2Parallelism = None Natural
      , hashingMaxConcurrency = None Natural
      , accessTokenTtlSeconds = None Natural
      , refreshTokenTtlSeconds = None Natural
      , sessionTtlSeconds = None Natural
      , publicBaseUrl = None Text
      , emailVerificationRequired = None Bool
      , notifierTransport = None Text
      , alsoLogNotifications = None Bool
      , smtpHost = None Text
      , smtpPort = None Natural
      , smtpTlsMode = None Text
      , smtpUsername = None Text
      , smtpFromAddress = None Text
      , smtpTimeoutSeconds = None Natural
      , webhookUrl = None Text
      , webhookTimeoutSeconds = None Natural
      , webhookMaxAttempts = None Natural
      , notifierQueueSize = None Natural
      , rateLimitEnabled = None Bool
      , maxFailedLoginsPerAccount = None Natural
      , maxFailedLoginsPerIp = None Natural
      , perIpRequestsPerMinute = None Natural
      , perIpBurst = None Natural
      , lockoutWindowSeconds = None Natural
      , lockoutDurationSeconds = None Natural
      , metricsEnabled = None Bool
      , requestLoggingEnabled = None Bool
      , gracefulShutdownTimeoutSeconds = None Natural
      , passwordMinLength = None Natural
      , passwordMaxLength = None Natural
      , passwordRejectCommon = None Bool
      , passwordRejectContextual = None Bool
      , passwordBreachCheckEnabled = None Bool
      , passwordBreachCheckFailClosed = None Bool
      , passwordBreachCheckTimeoutMs = None Natural
      , webauthnRpId = None Text
      , webauthnRpName = None Text
      , webauthnOrigins = None (List Text)
      , webauthnUserVerification = None Text
      , webauthnAttestation = None Text
      , webauthnCeremonyTimeoutSeconds = None Natural
      , webauthnPendingCeremonyTtlSeconds = None Natural
      , mfaRequireSecondFactor = None Bool
      , totpEnabled = None Bool
      , totpEnrollmentTtlSeconds = None Natural
      , machineTokenTtlSeconds = None Natural
      , oidcEnabled = None Bool
      , oauthLoginUrl = None Text
      , oauthAuthorizationCodeTtlSeconds = None Natural
      , oauthIdTokenTtlSeconds = None Natural
      , allowedClockSkewSeconds = None Natural
      , signingAlgorithm = None Text
      , keyRefreshIntervalSeconds = None Natural
      , tokenTransport = None Text
      , cookieSecure = None Bool
      , cookieSameSite = None Text
      , csrfAllowedOrigins = None (List Text)
      , defaultRoles = None (List Text)
      }

in  { Type = ConfigType, default }
