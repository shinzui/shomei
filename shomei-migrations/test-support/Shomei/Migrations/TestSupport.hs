-- | Provision a fresh, isolated ephemeral PostgreSQL with the complete Shōmei schema
-- applied in-process through @pg-migrate@. Each call gets a brand-new database
-- (@ephemeral-pg@ caches only the @initdb@ cluster and hands back a fresh server plus
-- database per call), so tests stay isolated.
module Shomei.Migrations.TestSupport
  ( withShomeiMigratedDatabase,
  )
where

import Data.Text (Text)
import EphemeralPg qualified as Pg
import Shomei.Migrations (applyShomeiMigrations)

-- | Run @action@ against a fresh ephemeral PostgreSQL connection string whose database
-- already has the full Shōmei schema applied.
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
withShomeiMigratedDatabase action = do
  result <- Pg.withCached \db -> do
    let connStr = Pg.connectionString db
    applied <- applyShomeiMigrations connStr
    case applied of
      Left migrationError ->
        error ("Failed to migrate ephemeral Shōmei database: " <> show migrationError)
      Right _ -> action connStr
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right value -> pure value
