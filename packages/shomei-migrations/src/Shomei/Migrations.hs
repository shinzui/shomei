{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Shomei.Migrations (
    shomeiMigrations,
    runShomeiMigrationsNoCheck,
) where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Streaming.Prelude qualified as Streaming

{- | All Shōmei migrations, parsed from the embedded SQL files (ordered by codd by
the timestamp encoded in each filename).
-}
shomeiMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
shomeiMigrations = traverse parseEmbeddedMigration embeddedFiles
  where
    parseEmbeddedMigration :: forall m. (MonadFail m, EnvVars m) => (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
        let stream :: PureStream m
            stream = PureStream (Streaming.yield (TE.decodeUtf8 bytes))
        result <- parseAddedSqlMigration name stream
        case result of
            Left err -> fail ("Invalid Shōmei migration " <> name <> ": " <> err)
            Right migration -> pure migration

-- NB: 'embedDir' is a Template Haskell splice evaluated at COMPILE time. A brand-new
-- .sql file under sql-migrations/ is not re-embedded until this module is recompiled;
-- the @migrate@ Justfile recipe touches the .cabal first to force that rebuild.
embeddedFiles :: [(FilePath, ByteString)]
embeddedFiles = $(embedDir "sql-migrations")

-- | Apply all migrations through codd WITHOUT expected-schema verification.
runShomeiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runShomeiMigrationsNoCheck settings connectTimeout =
    runCoddLogger do
        migrations <- shomeiMigrations
        applyMigrationsNoCheck settings (Just migrations) connectTimeout (const (pure SchemasNotVerified))
