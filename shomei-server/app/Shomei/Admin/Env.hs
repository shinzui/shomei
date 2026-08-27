-- | The configuration/assembly for @shomei-admin@.
--
-- A single stable entry point ('loadAdminEnv') reads @DATABASE_URL@, loads the same core Dhall
-- and environment policy as the server, and acquires a @hasql@ pool.
--
-- It deliberately skips server-only listen and pool validation. Every core field an admin
-- workflow consumes still comes from the deployment's real policy.
module Shomei.Admin.Env
  ( AdminEnv (..),
    loadAdminEnv,
  )
where

import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Pool (Pool)
import Shomei.Account.Password.Hash.Postgres (Argon2Params (..), argon2HardFloor, defaultArgon2Params)
import Shomei.Config (ShomeiConfig)
import Shomei.Persistence.Pool.Postgres (acquirePool)
import Shomei.Server.Config (defaultDbStatementTimeoutMs, loadCoreConfig)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data AdminEnv = AdminEnv
  { config :: !ShomeiConfig,
    pool :: !Pool,
    connStr :: !Text,
    -- | Argon2id cost parameters for @users create@. Read from the same @SHOMEI_ARGON2_*@
    --     variables the server uses, so a password seeded by the CLI is hashed exactly as one
    --     created through @POST \/v1\/auth\/signup@ would be.
    argon2 :: !Argon2Params
  }

loadAdminEnv :: IO AdminEnv
loadAdminEnv = do
  cs <- requireEnv "DATABASE_URL"
  cfg <- loadCoreConfig
  params <- argon2FromEnv
  p <- acquirePool 4 10 defaultDbStatementTimeoutMs cs
  pure AdminEnv {config = cfg, pool = p, connStr = cs, argon2 = params}

argon2FromEnv :: IO Argon2Params
argon2FromEnv = do
  mem <- intEnvOr "SHOMEI_ARGON2_MEMORY_KIB" defaultArgon2Params.memoryKiB
  iters <- intEnvOr "SHOMEI_ARGON2_ITERATIONS" defaultArgon2Params.iterations
  lanes <- intEnvOr "SHOMEI_ARGON2_PARALLELISM" defaultArgon2Params.parallelism
  let params = Argon2Params {memoryKiB = mem, iterations = iters, parallelism = lanes}
  for_ (argon2HardFloor params) \why ->
    ioError
      ( userError
          ( "SHOMEI_ARGON2_MEMORY_KIB/SHOMEI_ARGON2_ITERATIONS/SHOMEI_ARGON2_PARALLELISM "
              <> "are rejected by the Argon2 implementation: "
              <> Text.unpack why
          )
      )
  pure params

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
    Just v
      | let stripped = Text.strip (Text.pack v), not (Text.null stripped) -> pure stripped
    _ -> ioError (userError (Text.unpack name <> " is not set"))
