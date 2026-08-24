{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

-- | Shōmei's PostgreSQL schema as a @pg-migrate@ component.
--
-- The SQL under @migrations\/shomei\/@ is embedded at compile time from the ordered
-- manifest beside it, so a built binary never reads the migration directory at runtime.
--
-- Host applications that also own migrations should compose 'shomeiMigrationComponent'
-- with their own components into a single 'MigrationPlan', so the whole database is
-- described by one plan and tracked by one ledger. Applications that only need Shōmei's
-- schema can use 'shomeiMigrationPlan' or 'applyShomeiMigrations' directly.
module Shomei.Migrations
  ( shomeiMigrationComponent,
    shomeiMigrationPlan,
    resolveShomeiMigrationPlan,
    applyShomeiMigrations,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Hasql.Connection.Settings qualified as Settings

-- | Shōmei's migration component. Its durable identities are @shomei\/0001-shomei-schema@
-- and so on, in manifest order. It depends on no other component.
shomeiMigrationComponent :: Either DefinitionError MigrationComponent
shomeiMigrationComponent =
  migrationComponentFromEmbeddedSql
    "shomei"
    Set.empty
    $(embedMigrationManifest "migrations/shomei/manifest")

-- | A single-component plan containing only Shōmei's schema.
shomeiMigrationPlan :: Either DefinitionError (Either PlanError MigrationPlan)
shomeiMigrationPlan = do
  component <- shomeiMigrationComponent
  pure (migrationPlan (component :| []))

-- | Resolve 'shomeiMigrationPlan', failing loudly. Both failure modes are programmer
-- errors in a compiled binary: the SQL is embedded and validated at compile time.
resolveShomeiMigrationPlan :: IO MigrationPlan
resolveShomeiMigrationPlan =
  case shomeiMigrationPlan of
    Left definitionError -> fail ("Invalid Shōmei migration component: " <> show definitionError)
    Right (Left planError) -> fail ("Invalid Shōmei migration plan: " <> show planError)
    Right (Right plan) -> pure plan

-- | Apply Shōmei's schema to the database named by a libpq connection string, using
-- @pg-migrate@'s default ledger (schema @pgmigrate@), indefinite advisory-lock waiting,
-- and no statement timeout. Idempotent: already-applied migrations are reported as such
-- and not re-run.
applyShomeiMigrations :: Text -> IO (Either MigrationError MigrationReport)
applyShomeiMigrations connStr = do
  plan <- resolveShomeiMigrationPlan
  runMigrationPlan defaultRunOptions (Settings.connectionString connStr) plan
