-- | Provision a fresh, isolated ephemeral PostgreSQL with the complete Shōmei schema
-- applied in-process through @pg-migrate@. Each call gets a brand-new database
-- (@ephemeral-pg@ caches only the @initdb@ cluster and hands back a fresh server plus
-- database per call), so tests stay isolated.
module Shomei.Migrations.TestSupport
  ( withShomeiMigratedDatabase,
  )
where

import Data.Monoid qualified as EphemeralMonoid
import Data.Text (Text)
import EphemeralPg qualified as Pg
import Shomei.Migrations (applyShomeiMigrations)
import System.Directory qualified as EphemeralDirectory
import System.Posix.User qualified as EphemeralUser

-- | Run @action@ against a fresh ephemeral PostgreSQL connection string whose database
-- already has the full Shōmei schema applied.
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
withShomeiMigratedDatabase action = do
  result <- withEphemeralPg \db -> do
    let connStr = Pg.connectionString db
    applied <- applyShomeiMigrations connStr
    case applied of
      Left migrationError ->
        error ("Failed to migrate ephemeral Shōmei database: " <> show migrationError)
      Right _ -> action connStr
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right value -> pure value

-- | Stable per-user root lets the next invocation reap abandoned clusters.
-- See mori://shinzui/ephemeral-pg/docs/guides (temporary-roots-and-stale-cleanup.md; artifact URI pending).
withEphemeralPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withEphemeralPg action = do
  uid <- EphemeralUser.getEffectiveUserID
  let root = "/tmp/ephpg-shomei-" <> show uid
  EphemeralDirectory.createDirectoryIfMissing True root
  let config = Pg.defaultConfig {Pg.temporaryRoot = EphemeralMonoid.Last (Just root)}
  Pg.withCachedConfig config Pg.defaultCacheConfig action
