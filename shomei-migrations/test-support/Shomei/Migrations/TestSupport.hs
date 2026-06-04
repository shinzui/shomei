{- | Provision a fresh, isolated ephemeral PostgreSQL with the complete Shōmei schema
applied in-process through codd via 'runShomeiMigrationsNoCheck'. Each call gets a
brand-new database (ephemeral-pg caches only the @initdb@ cluster and hands back a
fresh server+database per call), so tests stay isolated.
-}
module Shomei.Migrations.TestSupport (
    withShomeiMigratedDatabase,
) where

import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Shomei.Migrations (coddSettingsFromConnString, runShomeiMigrationsNoCheck)

{- | Run @action@ against a fresh ephemeral PostgreSQL connection string whose database
already has the full Shōmei schema applied (via codd, without expected-schema
verification).
-}
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
withShomeiMigratedDatabase action = do
    result <- Pg.withCached \db -> do
        let connStr = Pg.connectionString db
        _ <- runShomeiMigrationsNoCheck (coddSettingsFromConnString connStr) (secondsToDiffTime 5)
        action connStr
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right value -> pure value
