-- | Acquire a @hasql@ connection pool from a libpq connection string.
module Shomei.Persistence.Pool.Postgres
  ( acquirePool,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (DiffTime)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Config
import Hasql.Session qualified as Session

-- | Acquire a pool of @size@ connections against a libpq connection string.
--
-- @acquisitionTimeout@ bounds how long a caller of @Hasql.Pool.use@ waits for a free
-- connection before giving up with @AcquisitionTimeoutUsageError@; it is @hasql-pool@'s own
-- 10-second default unless the operator narrows it. A short timeout sheds load (a request
-- fails fast instead of queueing behind a saturated pool); a long one absorbs bursts.
--
-- @statementTimeoutMs@ is installed on every new connection as both PostgreSQL's
-- @statement_timeout@ and @idle_in_transaction_session_timeout@. This bounds a hung statement or
-- leaked transaction holding a pool slot; zero disables both settings.
acquirePool :: Int -> DiffTime -> Int -> Text -> IO Pool
acquirePool size acquisitionTimeout statementTimeoutMs connStr =
  Pool.acquire
    ( Config.settings
        [ Config.staticConnectionSettings (Settings.connectionString connStr),
          Config.size size,
          Config.acquisitionTimeout acquisitionTimeout,
          Config.initSession (Session.script (sessionSetup (max 0 statementTimeoutMs)))
        ]
    )
  where
    sessionSetup ms =
      "SET statement_timeout = "
        <> Text.pack (show ms)
        <> "; SET idle_in_transaction_session_timeout = "
        <> Text.pack (show ms)
