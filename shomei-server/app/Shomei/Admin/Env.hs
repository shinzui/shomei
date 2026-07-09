-- | The minimal environment-variable configuration/assembly for @shomei-admin@ (EP-4).
--
-- A single stable entry point ('loadAdminEnv') that reads @DATABASE_URL@ (required),
-- @SHOMEI_ISSUER@/@SHOMEI_AUDIENCE@ (optional, defaulted), builds a 'ShomeiConfig' with
-- 'defaultShomeiConfig', and acquires a @hasql@ pool. EP-5's typed Dhall/env loader (IP-6) is
-- expected to supersede the body of this function without changing its name or type.
module Shomei.Admin.Env
  ( AdminEnv (..),
    loadAdminEnv,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool (Pool)
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Postgres.Pool (acquirePool)
import System.Environment (lookupEnv)

data AdminEnv = AdminEnv
  { config :: !ShomeiConfig,
    pool :: !Pool,
    connStr :: !Text
  }

loadAdminEnv :: IO AdminEnv
loadAdminEnv = do
  cs <- requireEnv "DATABASE_URL"
  iss <- envOr "SHOMEI_ISSUER" "shomei"
  aud <- envOr "SHOMEI_AUDIENCE" "shomei-clients"
  let cfg = defaultShomeiConfig (Issuer iss) (Audience aud)
  p <- acquirePool 4 10 cs
  pure AdminEnv {config = cfg, pool = p, connStr = cs}

requireEnv :: Text -> IO Text
requireEnv name = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Just v | not (null v) -> pure (Text.pack v)
    _ -> ioError (userError (Text.unpack name <> " is not set"))

envOr :: Text -> Text -> IO Text
envOr name def = do
  m <- lookupEnv (Text.unpack name)
  pure $ case m of
    Just v | not (null v) -> Text.pack v
    _ -> def
