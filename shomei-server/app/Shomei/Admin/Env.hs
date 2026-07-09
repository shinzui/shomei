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
import Shomei.Crypto (Argon2Params (..), defaultArgon2Params)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Postgres.Pool (acquirePool)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data AdminEnv = AdminEnv
  { config :: !ShomeiConfig,
    pool :: !Pool,
    connStr :: !Text,
    -- | Argon2id cost parameters for @users create@. Read from the same @SHOMEI_ARGON2_*@
    --     variables the server uses, so a password seeded by the CLI is hashed exactly as one
    --     created through @POST \/auth\/signup@ would be.
    argon2 :: !Argon2Params
  }

loadAdminEnv :: IO AdminEnv
loadAdminEnv = do
  cs <- requireEnv "DATABASE_URL"
  iss <- envOr "SHOMEI_ISSUER" "shomei"
  aud <- envOr "SHOMEI_AUDIENCE" "shomei-clients"
  let cfg = defaultShomeiConfig (Issuer iss) (Audience aud)
  params <- argon2FromEnv
  p <- acquirePool 4 10 cs
  pure AdminEnv {config = cfg, pool = p, connStr = cs, argon2 = params}

argon2FromEnv :: IO Argon2Params
argon2FromEnv = do
  mem <- intEnvOr "SHOMEI_ARGON2_MEMORY_KIB" defaultArgon2Params.memoryKiB
  iters <- intEnvOr "SHOMEI_ARGON2_ITERATIONS" defaultArgon2Params.iterations
  lanes <- intEnvOr "SHOMEI_ARGON2_PARALLELISM" defaultArgon2Params.parallelism
  pure Argon2Params {memoryKiB = mem, iterations = iters, parallelism = lanes}

intEnvOr :: Text -> Int -> IO Int
intEnvOr name def = do
  m <- lookupEnv (Text.unpack name)
  case m of
    Just v | not (null v) -> case readMaybe v of
      Just n | n > 0 -> pure n
      _ -> ioError (userError (Text.unpack name <> " must be a positive integer"))
    _ -> pure def

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
