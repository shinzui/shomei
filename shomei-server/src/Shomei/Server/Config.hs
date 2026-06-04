{- | Load runtime configuration from the environment into the core 'ShomeiConfig' plus
the server-only 'ServerSettings' (listen port, connection string).

Env-var based by deliberate choice (Decision Log); Dhall-file config is the documented
future option per the house hierarchical-config convention. Required variables that are
missing fail fast at boot with a clear 'userError'; optional ones fall back to
'defaultShomeiConfig'.

Variables:

* @PG_CONNECTION_STRING@   libpq connection string (required).
* @SHOMEI_PORT@            warp listen port (default 8080).
* @SHOMEI_ISSUER@          JWT @iss@ (default @shomei@).
* @SHOMEI_AUDIENCE@        JWT @aud@ (default @shomei-clients@).
* @SHOMEI_ACCESS_TTL@      access-token lifetime, seconds (default: ShomeiConfig).
* @SHOMEI_REFRESH_TTL@     refresh-token lifetime, seconds (default: ShomeiConfig).
* @SHOMEI_SESSION_TTL@     session lifetime, seconds (default: ShomeiConfig).
* @SHOMEI_TOKEN_TRANSPORT@ @bearer@ | @cookie@ | @both@ (default: ShomeiConfig).
* @SHOMEI_SESSION_CHECK@   @token-only@ | @token-and-session@ (default: ShomeiConfig).
-}
module Shomei.Server.Config (
    ServerSettings (..),
    loadConfig,
) where

import Shomei.Prelude

import Data.Time (NominalDiffTime)
import "base" System.Environment (lookupEnv)
import "base" Text.Read (readMaybe)
import "text" Data.Text qualified as Text

import Shomei.Config (
    SessionCheckMode (..),
    ShomeiConfig (..),
    TokenTransport (..),
    defaultShomeiConfig,
 )
import Shomei.Domain.Claims (Audience (..), Issuer (..))

-- | Server-only settings not part of the transport-agnostic 'ShomeiConfig'.
data ServerSettings = ServerSettings
    { serverPort :: !Int
    , serverConnStr :: !Text
    }
    deriving stock (Show, Generic)

-- | Load both records from the environment.
loadConfig :: IO (ShomeiConfig, ServerSettings)
loadConfig = do
    connStr <- requireEnv "PG_CONNECTION_STRING"
    port <- intEnv "SHOMEI_PORT" 8080
    iss <- textEnv "SHOMEI_ISSUER" "shomei"
    aud <- textEnv "SHOMEI_AUDIENCE" "shomei-clients"
    cfg <- overlayFromEnv (defaultShomeiConfig (Issuer iss) (Audience aud))
    pure (cfg, ServerSettings{serverPort = port, serverConnStr = connStr})

-- | Apply the optional TTL/transport/session-check overrides, keeping defaults otherwise.
overlayFromEnv :: ShomeiConfig -> IO ShomeiConfig
overlayFromEnv base = do
    acc <- ttlEnv "SHOMEI_ACCESS_TTL"
    ref <- ttlEnv "SHOMEI_REFRESH_TTL"
    ses <- ttlEnv "SHOMEI_SESSION_TTL"
    tr <- transportEnv
    sc <- sessionCheckEnv
    pure
        base
            { accessTokenTTL = fromMaybe base.accessTokenTTL acc
            , refreshTokenTTL = fromMaybe base.refreshTokenTTL ref
            , sessionTTL = fromMaybe base.sessionTTL ses
            , tokenTransport = fromMaybe base.tokenTransport tr
            , sessionCheckMode = fromMaybe base.sessionCheckMode sc
            }

requireEnv :: Text -> IO Text
requireEnv name = do
    m <- lookupEnv (Text.unpack name)
    case m of
        Just v | not (null v) -> pure (Text.pack v)
        _ -> ioError (userError (Text.unpack name <> " is not set"))

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

sessionCheckEnv :: IO (Maybe SessionCheckMode)
sessionCheckEnv = do
    m <- lookupEnv "SHOMEI_SESSION_CHECK"
    case m of
        Nothing -> pure Nothing
        Just "" -> pure Nothing
        Just "token-only" -> pure (Just VerifyTokenOnly)
        Just "token-and-session" -> pure (Just VerifyTokenAndSession)
        Just other -> ioError (userError ("SHOMEI_SESSION_CHECK must be token-only|token-and-session, got " <> other))
