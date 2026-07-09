-- | Acquire a @hasql@ connection pool from a libpq connection string.
module Shomei.Postgres.Pool
  ( acquirePool,
  )
where

import Data.Text (Text)
import Data.Time (DiffTime)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Config

-- | Acquire a pool of @size@ connections against a libpq connection string.
--
-- @acquisitionTimeout@ bounds how long a caller of @Hasql.Pool.use@ waits for a free
-- connection before giving up with @AcquisitionTimeoutUsageError@; it is @hasql-pool@'s own
-- 10-second default unless the operator narrows it. A short timeout sheds load (a request
-- fails fast instead of queueing behind a saturated pool); a long one absorbs bursts.
acquirePool :: Int -> DiffTime -> Text -> IO Pool
acquirePool size acquisitionTimeout connStr =
  Pool.acquire
    ( Config.settings
        [ Config.staticConnectionSettings (Settings.connectionString connStr),
          Config.size size,
          Config.acquisitionTimeout acquisitionTimeout
        ]
    )
