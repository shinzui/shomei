-- | Load runtime configuration into the core 'ShomeiConfig' plus the server-only
-- 'ServerSettings' (listen port, connection string).
--
-- Precedence (lowest to highest, twelve-factor): (1) built-in 'defaultShomeiConfig'; (2) a typed
-- Dhall file at @$SHOMEI_CONFIG@ (if set and present), rendered to JSON by the @dhall-to-json@
-- CLI and decoded here; (3) individual @SHOMEI_*@ / @PG_CONNECTION_STRING@ environment variables.
-- If @$SHOMEI_CONFIG@ is unset the file step is skipped and the server still boots from defaults
-- + env (preserving the turnkey behavior).
--
-- Dhall is rendered with the @dhall-to-json@ binary (provided by the toolchain / container) rather
-- than the heavyweight @dhall@ Haskell library, and the rendered JSON is decoded with @aeson@ into
-- a flat 'FileConfig' of optional scalar overrides — see EP-5's Decision Log. @loadConfigFromEnv@
-- remains as the env-only entry point EP-4's @shomei-admin@ and the legacy path use.
module Shomei.Server.Config
  ( ServerSettings (..),
    loadConfig,
    loadConfigFromEnv,
    FileConfig (..),
  )
where

import Data.Aeson (eitherDecodeStrict')
import Data.Char (isHexDigit)
import Data.Foldable (traverse_)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime)
import Shomei.Config
  ( AttestationPolicy (..),
    NotifierConfig (..),
    ObservabilityConfig (..),
    RateLimitConfig (..),
    ServiceAccountConfig (..),
    ServiceAccountId (..),
    ServiceTokenConfig (..),
    SessionCheckMode (..),
    ShomeiConfig (..),
    SigningKeyConfig (..),
    TokenTransport (..),
    UserVerificationPolicy (..),
    WebAuthnConfig (..),
    defaultShomeiConfig,
  )
import Shomei.Domain.Claims (Audience (..), Issuer (..), Scope (..))
import Shomei.Domain.Password (PasswordPolicy (..))
import Shomei.Id (parseId)
import Shomei.Prelude
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcess)
import Text.Read (readMaybe)

-- | Server-only settings not part of the transport-agnostic 'ShomeiConfig'.
data ServerSettings = ServerSettings
  { serverPort :: !Int,
    serverConnStr :: !Text
  }
  deriving stock (Show, Generic)

-- | The flat, all-optional shape the Dhall config file is rendered into (via @dhall-to-json@).
-- Every field is a 'Maybe' scalar so a partial file is valid and absent keys fall back to the
-- defaults / env.
data FileConfig = FileConfig
  { issuer :: !(Maybe Text),
    audience :: !(Maybe Text),
    databaseUrl :: !(Maybe Text),
    port :: !(Maybe Int),
    accessTokenTtlSeconds :: !(Maybe Int),
    refreshTokenTtlSeconds :: !(Maybe Int),
    sessionTtlSeconds :: !(Maybe Int),
    publicBaseUrl :: !(Maybe Text),
    emailVerificationRequired :: !(Maybe Bool),
    rateLimitEnabled :: !(Maybe Bool),
    maxFailedLoginsPerAccount :: !(Maybe Int),
    perIpRequestsPerMinute :: !(Maybe Int),
    metricsEnabled :: !(Maybe Bool),
    requestLoggingEnabled :: !(Maybe Bool),
    gracefulShutdownTimeoutSeconds :: !(Maybe Int),
    passwordMinLength :: !(Maybe Int),
    passwordMaxLength :: !(Maybe Int),
    passwordRejectCommon :: !(Maybe Bool),
    passwordRejectContextual :: !(Maybe Bool),
    passwordBreachCheckEnabled :: !(Maybe Bool),
    passwordBreachCheckFailClosed :: !(Maybe Bool),
    passwordBreachCheckTimeoutMs :: !(Maybe Int),
    webauthnRpId :: !(Maybe Text),
    webauthnRpName :: !(Maybe Text),
    webauthnOrigins :: !(Maybe [Text]),
    -- | @required@ | @preferred@ | @discouraged@
    webauthnUserVerification :: !(Maybe Text),
    -- | @none@ | @direct@
    webauthnAttestation :: !(Maybe Text),
    webauthnCeremonyTimeoutSeconds :: !(Maybe Int),
    webauthnPendingCeremonyTtlSeconds :: !(Maybe Int),
    webauthnMfaRequired :: !(Maybe Bool),
    serviceToken :: !(Maybe FileServiceTokenConfig),
    -- | @ES256@ | @RS256@; the JWT signing algorithm for keys generated on first boot
    signingAlgorithm :: !(Maybe Text),
    -- | seconds between background reloads of signing-key material; 0 disables them
    keyRefreshIntervalSeconds :: !(Maybe Int)
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

data FileServiceTokenConfig = FileServiceTokenConfig
  { enabled :: !(Maybe Bool),
    ttlSeconds :: !(Maybe Int),
    accounts :: !(Maybe [FileServiceAccount])
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

data FileServiceAccount = FileServiceAccount
  { accountId :: !Text,
    userId :: !Text,
    secretSha256 :: !Text,
    allowedScopes :: ![Text]
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

-- | The full loader: defaults → Dhall file (if @$SHOMEI_CONFIG@) → env.
loadConfig :: IO (ShomeiConfig, ServerSettings)
loadConfig = do
  mFile <- loadDhallFile
  (cfg0, settings0) <- baseFromFile mFile
  overlayFromEnvBoth cfg0 settings0

-- | The env-only loader (no Dhall file). Stable entry point for @shomei-admin@ and legacy use.
loadConfigFromEnv :: IO (ShomeiConfig, ServerSettings)
loadConfigFromEnv = do
  (cfg, settings) <- baseDefaults
  overlayFromEnvBoth cfg settings

-- Dhall file ----------------------------------------------------------------

loadDhallFile :: IO (Maybe FileConfig)
loadDhallFile = do
  mPath <- lookupEnv "SHOMEI_CONFIG"
  case mPath of
    Just path | not (null path) -> do
      out <- readProcess "dhall-to-json" ["--file", path] ""
      case eitherDecodeStrict' (TE.encodeUtf8 (Text.pack out)) of
        Right fc -> pure (Just fc)
        Left err -> do
          hPutStrLn stderr ("shomei: could not decode rendered Dhall config " <> path <> ": " <> err)
          ioError (userError ("invalid SHOMEI_CONFIG: " <> path))
    _ -> pure Nothing

baseDefaults :: IO (ShomeiConfig, ServerSettings)
baseDefaults =
  pure
    ( defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients"),
      ServerSettings {serverPort = 8080, serverConnStr = ""}
    )

baseFromFile :: Maybe FileConfig -> IO (ShomeiConfig, ServerSettings)
baseFromFile Nothing = baseDefaults
baseFromFile (Just fc) = do
  algFile <- traverse (normalizeSigningAlg "signingAlgorithm (config file)") fc.signingAlgorithm
  let iss = fromMaybe "shomei" fc.issuer
      aud = fromMaybe "shomei-clients" fc.audience
      cfg0 = defaultShomeiConfig (Issuer iss) (Audience aud)
  serviceTokenCfg <- mergeServiceToken "serviceToken (config file)" cfg0.serviceTokenConfig fc.serviceToken
  let cfg =
        cfg0
          { accessTokenTTL = maybe cfg0.accessTokenTTL fromIntegral fc.accessTokenTtlSeconds,
            refreshTokenTTL = maybe cfg0.refreshTokenTTL fromIntegral fc.refreshTokenTtlSeconds,
            sessionTTL = maybe cfg0.sessionTTL fromIntegral fc.sessionTtlSeconds,
            notifierConfig =
              cfg0.notifierConfig
                { emailVerificationRequired = fromMaybe cfg0.notifierConfig.emailVerificationRequired fc.emailVerificationRequired,
                  publicBaseUrl = fromMaybe cfg0.notifierConfig.publicBaseUrl fc.publicBaseUrl
                },
            rateLimitConfig =
              cfg0.rateLimitConfig
                { rateLimitEnabled = fromMaybe cfg0.rateLimitConfig.rateLimitEnabled fc.rateLimitEnabled,
                  maxFailedLoginsPerAccount = fromMaybe cfg0.rateLimitConfig.maxFailedLoginsPerAccount fc.maxFailedLoginsPerAccount,
                  perIpRequestsPerMinute = fromMaybe cfg0.rateLimitConfig.perIpRequestsPerMinute fc.perIpRequestsPerMinute
                },
            passwordPolicy =
              cfg0.passwordPolicy
                { minLength = fromMaybe cfg0.passwordPolicy.minLength fc.passwordMinLength,
                  maxLength = fromMaybe cfg0.passwordPolicy.maxLength fc.passwordMaxLength,
                  rejectCommonPasswords = fromMaybe cfg0.passwordPolicy.rejectCommonPasswords fc.passwordRejectCommon,
                  rejectContextualPasswords = fromMaybe cfg0.passwordPolicy.rejectContextualPasswords fc.passwordRejectContextual,
                  breachCheckEnabled = fromMaybe cfg0.passwordPolicy.breachCheckEnabled fc.passwordBreachCheckEnabled,
                  breachCheckFailClosed = fromMaybe cfg0.passwordPolicy.breachCheckFailClosed fc.passwordBreachCheckFailClosed,
                  breachCheckTimeoutMs = fromMaybe cfg0.passwordPolicy.breachCheckTimeoutMs fc.passwordBreachCheckTimeoutMs
                },
            observabilityConfig =
              cfg0.observabilityConfig
                { metricsEnabled = fromMaybe cfg0.observabilityConfig.metricsEnabled fc.metricsEnabled,
                  requestLoggingEnabled = fromMaybe cfg0.observabilityConfig.requestLoggingEnabled fc.requestLoggingEnabled,
                  gracefulShutdownTimeoutSeconds = fromMaybe cfg0.observabilityConfig.gracefulShutdownTimeoutSeconds fc.gracefulShutdownTimeoutSeconds
                },
            webauthnConfig = mergeWebAuthn (webauthnConfig cfg0) fc,
            serviceTokenConfig = serviceTokenCfg,
            signingKeyConfig =
              cfg0.signingKeyConfig
                { algorithm = fromMaybe cfg0.signingKeyConfig.algorithm algFile,
                  refreshIntervalSeconds =
                    fromMaybe cfg0.signingKeyConfig.refreshIntervalSeconds fc.keyRefreshIntervalSeconds
                }
          }
      settings = ServerSettings {serverPort = fromMaybe 8080 fc.port, serverConnStr = fromMaybe "" fc.databaseUrl}
  pure (cfg, settings)

-- Env overrides --------------------------------------------------------------

overlayFromEnvBoth :: ShomeiConfig -> ServerSettings -> IO (ShomeiConfig, ServerSettings)
overlayFromEnvBoth baseCfg baseSettings = do
  connStr <- textEnv "PG_CONNECTION_STRING" baseSettings.serverConnStr
  portV <- intEnv "SHOMEI_PORT" baseSettings.serverPort
  iss <- textEnv "SHOMEI_ISSUER" (issuerText baseCfg.issuer)
  aud <- textEnv "SHOMEI_AUDIENCE" (audienceText baseCfg.audience)
  cfg <- overlayCoreFromEnv baseCfg {issuer = Issuer iss, audience = Audience aud}
  when (Text.null connStr) (ioError (userError "PG_CONNECTION_STRING is not set (and no databaseUrl in the Dhall config)"))
  pure (cfg, ServerSettings {serverPort = portV, serverConnStr = connStr})
  where
    issuerText (Issuer t) = t
    audienceText (Audience t) = t

overlayCoreFromEnv :: ShomeiConfig -> IO ShomeiConfig
overlayCoreFromEnv base = do
  acc <- ttlEnv "SHOMEI_ACCESS_TTL"
  ref <- ttlEnv "SHOMEI_REFRESH_TTL"
  ses <- ttlEnv "SHOMEI_SESSION_TTL"
  tr <- transportEnv
  sc <- sessionCheckEnv
  wa <- overlayWebAuthnFromEnv base.webauthnConfig
  serviceTokenCfg <- overlayServiceTokenFromEnv base.serviceTokenConfig
  pwMin <- intEnvMaybe "SHOMEI_PASSWORD_MIN_LENGTH"
  pwMax <- intEnvMaybe "SHOMEI_PASSWORD_MAX_LENGTH"
  pwRejCommon <- boolEnv "SHOMEI_PASSWORD_REJECT_COMMON"
  pwRejCtx <- boolEnv "SHOMEI_PASSWORD_REJECT_CONTEXTUAL"
  pwBreach <- boolEnv "SHOMEI_PASSWORD_BREACH_CHECK"
  pwBreachFC <- boolEnv "SHOMEI_PASSWORD_BREACH_FAIL_CLOSED"
  pwBreachTo <- intEnvMaybe "SHOMEI_PASSWORD_BREACH_TIMEOUT_MS"
  alg <- signingAlgEnv
  keyRefresh <- keyRefreshIntervalEnv
  -- Deliberately env-only, with no Dhall-file field: logging raw one-time tokens must be an
  -- explicit per-process decision, not something that lingers unnoticed in a committed file.
  logSecrets <- boolEnv "SHOMEI_NOTIFIER_LOG_SECRETS"
  pure
    base
      { accessTokenTTL = fromMaybe base.accessTokenTTL acc,
        notifierConfig =
          base.notifierConfig
            { logRawTokens = fromMaybe base.notifierConfig.logRawTokens logSecrets
            },
        signingKeyConfig =
          base.signingKeyConfig
            { algorithm = fromMaybe base.signingKeyConfig.algorithm alg,
              refreshIntervalSeconds = fromMaybe base.signingKeyConfig.refreshIntervalSeconds keyRefresh
            },
        refreshTokenTTL = fromMaybe base.refreshTokenTTL ref,
        sessionTTL = fromMaybe base.sessionTTL ses,
        tokenTransport = fromMaybe base.tokenTransport tr,
        sessionCheckMode = fromMaybe base.sessionCheckMode sc,
        webauthnConfig = wa,
        serviceTokenConfig = serviceTokenCfg,
        passwordPolicy =
          base.passwordPolicy
            { minLength = fromMaybe base.passwordPolicy.minLength pwMin,
              maxLength = fromMaybe base.passwordPolicy.maxLength pwMax,
              rejectCommonPasswords = fromMaybe base.passwordPolicy.rejectCommonPasswords pwRejCommon,
              rejectContextualPasswords = fromMaybe base.passwordPolicy.rejectContextualPasswords pwRejCtx,
              breachCheckEnabled = fromMaybe base.passwordPolicy.breachCheckEnabled pwBreach,
              breachCheckFailClosed = fromMaybe base.passwordPolicy.breachCheckFailClosed pwBreachFC,
              breachCheckTimeoutMs = fromMaybe base.passwordPolicy.breachCheckTimeoutMs pwBreachTo
            }
      }

mergeServiceToken :: Text -> ServiceTokenConfig -> Maybe FileServiceTokenConfig -> IO ServiceTokenConfig
mergeServiceToken _ base Nothing = pure base
mergeServiceToken label base (Just fileCfg) = do
  parsedAccounts <- traverse (parseServiceAccounts label) mAccounts
  validateServiceTokenConfig
    label
    ServiceTokenConfig
      { enabled = fromMaybe baseEnabled mEnabled,
        ttl = maybe baseTtl fromIntegral mTtlSeconds,
        accounts = fromMaybe baseAccounts parsedAccounts
      }
  where
    ServiceTokenConfig {enabled = baseEnabled, ttl = baseTtl, accounts = baseAccounts} = base
    FileServiceTokenConfig {enabled = mEnabled, ttlSeconds = mTtlSeconds, accounts = mAccounts} = fileCfg

overlayServiceTokenFromEnv :: ServiceTokenConfig -> IO ServiceTokenConfig
overlayServiceTokenFromEnv base = do
  mEnabled <- boolEnv "SHOMEI_SERVICE_TOKEN_ENABLED"
  mTtl <- ttlEnv "SHOMEI_SERVICE_TOKEN_TTL"
  mAccounts <- serviceAccountsEnv
  validateServiceTokenConfig
    "service-token environment variables"
    ServiceTokenConfig
      { enabled = fromMaybe baseEnabled mEnabled,
        ttl = fromMaybe baseTtl mTtl,
        accounts = fromMaybe baseAccounts mAccounts
      }
  where
    ServiceTokenConfig {enabled = baseEnabled, ttl = baseTtl, accounts = baseAccounts} = base

serviceAccountsEnv :: IO (Maybe [ServiceAccountConfig])
serviceAccountsEnv = do
  m <- lookupEnv "SHOMEI_SERVICE_ACCOUNTS_JSON"
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just raw ->
      case eitherDecodeStrict' (TE.encodeUtf8 (Text.pack raw)) of
        Left err -> ioError (userError ("SHOMEI_SERVICE_ACCOUNTS_JSON must decode as a service-account JSON array: " <> err))
        Right accounts -> Just <$> parseServiceAccounts "SHOMEI_SERVICE_ACCOUNTS_JSON" accounts

parseServiceAccounts :: Text -> [FileServiceAccount] -> IO [ServiceAccountConfig]
parseServiceAccounts label = traverse (parseServiceAccount label)

parseServiceAccount :: Text -> FileServiceAccount -> IO ServiceAccountConfig
parseServiceAccount label FileServiceAccount {accountId = rawAccountId, userId = rawUserId, secretSha256 = rawSecret, allowedScopes = rawScopes} = do
  uid <- either (\err -> ioError (userError (Text.unpack label <> " has invalid userId " <> Text.unpack rawUserId <> ": " <> Text.unpack err))) pure (parseId rawUserId)
  secretHash <- normalizeSha256Hex label rawSecret
  pure
    ServiceAccountConfig
      { accountId = ServiceAccountId rawAccountId,
        userId = uid,
        secretHash = secretHash,
        allowedScopes = Set.fromList (Scope <$> rawScopes)
      }

validateServiceTokenConfig :: Text -> ServiceTokenConfig -> IO ServiceTokenConfig
validateServiceTokenConfig label cfg@ServiceTokenConfig {accounts = configuredAccounts} = do
  traverse_ validateAccount configuredAccounts
  pure cfg
  where
    validateAccount ServiceAccountConfig {accountId = ServiceAccountId rawAccountId, allowedScopes}
      | Set.null allowedScopes =
          ioError (userError (Text.unpack label <> " account " <> Text.unpack rawAccountId <> " must allow at least one scope"))
      | otherwise = pure ()

normalizeSha256Hex :: Text -> Text -> IO Text
normalizeSha256Hex label raw =
  let stripped = Text.toLower (Text.strip raw)
   in if Text.length stripped == 64 && Text.all isHexDigit stripped
        then pure stripped
        else ioError (userError (Text.unpack label <> " service account secretSha256 must be a 64-character hex SHA-256 digest"))

-- | Apply the optional @webauthn*@ fields of a decoded Dhall 'FileConfig' onto a base
-- 'WebAuthnConfig'. The base record is read via record destructuring (not @value.field@ dot
-- syntax), which the new passkey/config records do not support under @DuplicateRecordFields@
-- (MasterPlan 3, EP-1 discovery); @fc.field@ dot access on 'FileConfig' is unaffected.
mergeWebAuthn :: WebAuthnConfig -> FileConfig -> WebAuthnConfig
mergeWebAuthn base fc =
  base
    { rpId = fromMaybe baseRpId fc.webauthnRpId,
      rpName = fromMaybe baseRpName fc.webauthnRpName,
      origins = fromMaybe baseOrigins fc.webauthnOrigins,
      userVerification = maybe baseUv parseUserVerification fc.webauthnUserVerification,
      attestation = maybe baseAtt parseAttestation fc.webauthnAttestation,
      ceremonyTimeout = maybe baseTimeout fromIntegral fc.webauthnCeremonyTimeoutSeconds,
      pendingCeremonyTTL = maybe baseTtl fromIntegral fc.webauthnPendingCeremonyTtlSeconds,
      mfaRequired = fromMaybe baseMfa fc.webauthnMfaRequired
    }
  where
    WebAuthnConfig
      { rpId = baseRpId,
        rpName = baseRpName,
        origins = baseOrigins,
        userVerification = baseUv,
        attestation = baseAtt,
        ceremonyTimeout = baseTimeout,
        pendingCeremonyTTL = baseTtl,
        mfaRequired = baseMfa
      } = base

-- | Overlay the @SHOMEI_WEBAUTHN_*@ environment variables onto the WebAuthn policy.
overlayWebAuthnFromEnv :: WebAuthnConfig -> IO WebAuthnConfig
overlayWebAuthnFromEnv base = do
  rpId' <- textEnv "SHOMEI_WEBAUTHN_RP_ID" baseRpId
  rpName' <- textEnv "SHOMEI_WEBAUTHN_RP_NAME" baseRpName
  origins' <- originsEnv baseOrigins
  uv <- uvEnv
  att <- attestationEnv
  timeout' <- ttlEnv "SHOMEI_WEBAUTHN_CEREMONY_TIMEOUT"
  ttl' <- ttlEnv "SHOMEI_WEBAUTHN_PENDING_TTL"
  mfa <- boolEnv "SHOMEI_WEBAUTHN_MFA_REQUIRED"
  pure
    base
      { rpId = rpId',
        rpName = rpName',
        origins = origins',
        userVerification = fromMaybe baseUv uv,
        attestation = fromMaybe baseAtt att,
        ceremonyTimeout = fromMaybe baseTimeout timeout',
        pendingCeremonyTTL = fromMaybe baseTtl ttl',
        mfaRequired = fromMaybe baseMfa mfa
      }
  where
    WebAuthnConfig
      { rpId = baseRpId,
        rpName = baseRpName,
        origins = baseOrigins,
        userVerification = baseUv,
        attestation = baseAtt,
        ceremonyTimeout = baseTimeout,
        pendingCeremonyTTL = baseTtl,
        mfaRequired = baseMfa
      } = base
    -- A comma-separated list, e.g. "https://auth.example.com,https://www.example.com".
    originsEnv def = do
      m <- lookupEnv "SHOMEI_WEBAUTHN_ORIGINS"
      pure $ case m of
        Just v | not (null v) -> filter (not . Text.null) (map Text.strip (Text.splitOn "," (Text.pack v)))
        _ -> def
    uvEnv = do
      m <- lookupEnv "SHOMEI_WEBAUTHN_USER_VERIFICATION"
      case m of
        Nothing -> pure Nothing
        Just "" -> pure Nothing
        Just s -> case parseUserVerificationMaybe (Text.pack s) of
          Just p -> pure (Just p)
          Nothing -> ioError (userError "SHOMEI_WEBAUTHN_USER_VERIFICATION must be required|preferred|discouraged")
    attestationEnv = do
      m <- lookupEnv "SHOMEI_WEBAUTHN_ATTESTATION"
      case m of
        Nothing -> pure Nothing
        Just "" -> pure Nothing
        Just s -> case parseAttestationMaybe (Text.pack s) of
          Just p -> pure (Just p)
          Nothing -> ioError (userError "SHOMEI_WEBAUTHN_ATTESTATION must be none|direct")

boolEnv :: Text -> IO (Maybe Bool)
boolEnv name = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just s -> case Text.toLower (Text.pack s) of
      "true" -> pure (Just True)
      "false" -> pure (Just False)
      _ -> ioError (userError (Text.unpack name <> " must be true|false"))

-- | Parse a WebAuthn user-verification policy string (Dhall path; defaults to @preferred@ on
-- unrecognized input, matching 'defaultWebAuthnConfig').
parseUserVerification :: Text -> UserVerificationPolicy
parseUserVerification = fromMaybe UVPreferred . parseUserVerificationMaybe

parseUserVerificationMaybe :: Text -> Maybe UserVerificationPolicy
parseUserVerificationMaybe t = case Text.toLower t of
  "required" -> Just UVRequired
  "preferred" -> Just UVPreferred
  "discouraged" -> Just UVDiscouraged
  _ -> Nothing

-- | Parse a WebAuthn attestation policy string (Dhall path; defaults to @none@ on
-- unrecognized input, matching 'defaultWebAuthnConfig').
parseAttestation :: Text -> AttestationPolicy
parseAttestation = fromMaybe AttestationNone . parseAttestationMaybe

parseAttestationMaybe :: Text -> Maybe AttestationPolicy
parseAttestationMaybe t = case Text.toLower t of
  "none" -> Just AttestationNone
  "direct" -> Just AttestationDirect
  _ -> Nothing

textEnv :: Text -> Text -> IO Text
textEnv name def = do
  m <- lookupEnv (Text.unpack name)
  pure $ case m of
    Just v | not (null v) -> Text.pack v
    _ -> def

intEnv :: Text -> Int -> IO Int
intEnv name def = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Nothing -> pure def
    Just "" -> pure def
    Just s -> case readMaybe s of
      Just n -> pure n
      Nothing -> ioError (userError (Text.unpack name <> " must be an integer"))

-- | Like 'intEnv' but overlay-only: absent/empty → Nothing, non-integer → error.
intEnvMaybe :: Text -> IO (Maybe Int)
intEnvMaybe name = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just s -> case readMaybe s of
      Just n -> pure (Just n)
      Nothing -> ioError (userError (Text.unpack name <> " must be an integer"))

ttlEnv :: Text -> IO (Maybe NominalDiffTime)
ttlEnv name = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just s -> case readMaybe s :: Maybe Integer of
      Just n -> pure (Just (fromIntegral n))
      Nothing -> ioError (userError (Text.unpack name <> " must be an integer (seconds)"))

transportEnv :: IO (Maybe TokenTransport)
transportEnv = do
  m <- lookupEnv "SHOMEI_TOKEN_TRANSPORT"
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just "bearer" -> pure (Just BearerToken)
    Just "cookie" -> pure (Just HttpOnlyCookie)
    Just "both" -> pure (Just BearerAndCookie)
    Just other -> ioError (userError ("SHOMEI_TOKEN_TRANSPORT must be bearer|cookie|both, got " <> other))

-- | Read @SHOMEI_KEY_REFRESH_INTERVAL@ (seconds between signing-key reloads; 0 disables
-- the periodic reload). Rejects a negative value, which would otherwise silently disable
-- the refresh the operator meant to tighten.
keyRefreshIntervalEnv :: IO (Maybe Int)
keyRefreshIntervalEnv = do
  m <- intEnvMaybe "SHOMEI_KEY_REFRESH_INTERVAL"
  case m of
    Just n | n < 0 -> ioError (userError "SHOMEI_KEY_REFRESH_INTERVAL must be >= 0 (0 disables the periodic reload)")
    _ -> pure m

-- | Read and validate @SHOMEI_SIGNING_ALG@ (@ES256@|@RS256@); absent/empty → Nothing.
signingAlgEnv :: IO (Maybe Text)
signingAlgEnv = do
  m <- lookupEnv "SHOMEI_SIGNING_ALG"
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just s -> Just <$> normalizeSigningAlg "SHOMEI_SIGNING_ALG" (Text.pack s)

-- | Validate a signing-algorithm string from config (file or env), erroring on
-- anything other than @ES256@/@RS256@ so a typo fails the boot loudly. @label@ names
-- the source for the error message.
normalizeSigningAlg :: Text -> Text -> IO Text
normalizeSigningAlg label t = case Text.strip t of
  "ES256" -> pure "ES256"
  "RS256" -> pure "RS256"
  other -> ioError (userError (Text.unpack label <> " must be ES256|RS256, got " <> Text.unpack other))

sessionCheckEnv :: IO (Maybe SessionCheckMode)
sessionCheckEnv = do
  m <- lookupEnv "SHOMEI_SESSION_CHECK"
  case m of
    Nothing -> pure Nothing
    Just "" -> pure Nothing
    Just "token-only" -> pure (Just VerifyTokenOnly)
    Just "token-and-session" -> pure (Just VerifyTokenAndSession)
    Just other -> ioError (userError ("SHOMEI_SESSION_CHECK must be token-only|token-and-session, got " <> other))
