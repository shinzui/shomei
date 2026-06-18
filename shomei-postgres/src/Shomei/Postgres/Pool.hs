-- | Acquire a @hasql@ connection pool from a libpq connection string.
module Shomei.Postgres.Pool
  ( acquirePool,
  )
where

import Data.Text (Text)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Config

-- | Acquire a pool of @size@ connections against a libpq connection string.
acquirePool :: Int -> Text -> IO Pool
acquirePool size connStr =
  Pool.acquire
    ( Config.settings
        [ Config.staticConnectionSettings (Settings.connectionString connStr),
          Config.size size
        ]
    )
