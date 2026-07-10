{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Shomei.Migrations
  ( shomeiMigrations,
    runShomeiMigrationsNoCheck,
    coddSettingsFromConnString,
  )
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings (..), applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), connStringParser, parseAddedSqlMigration)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Streaming.Prelude qualified as Streaming

-- | All Shōmei migrations, parsed from the embedded SQL files (ordered by codd by
-- the timestamp encoded in each filename).
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
-- Account-lifecycle migrations were added on 2026-06-04, so this module must recompile.
-- Abuse-protection migrations (shomei_login_attempts, shomei_account_lockouts) were added
-- on 2026-06-05 by EP-2, requiring another recompile of this splice.
-- WebAuthn migrations (shomei_webauthn_credentials, shomei_webauthn_pending_ceremonies)
-- were added on 2026-06-18 by MasterPlan-3 EP-2, requiring another recompile of this splice.
-- The impersonation actor column (shomei_sessions.actor_user_id) was added on 2026-06-17
-- by the impersonation token-exchange plan, requiring another recompile of this splice.
-- The generalized login identifier (shomei_users.login_id / shomei_password_credentials.login_id,
-- with email relaxed to nullable + partial-unique) was added on 2026-06-19 by SH-25,
-- requiring another recompile of this splice.
-- The sweeper's expiry indexes (and the drop of the four dead single-column status indexes)
-- were added on 2026-07-09 by MasterPlan-6 EP-2, requiring another recompile of this splice.
-- The role registry and grant table (shomei_roles, shomei_role_grants) were added on
-- 2026-07-09 by MasterPlan-7 EP-1, requiring another recompile of this splice.
-- Database-backed service accounts (shomei_service_accounts) were added on 2026-07-10 by
-- MasterPlan-7 EP-4, requiring another recompile of this splice.
-- OAuth2/OIDC clients (shomei_oauth_clients) were added on 2026-07-10 by MasterPlan-7 EP-5,
-- requiring another recompile of this splice.
-- Single-use authorization codes (shomei_oauth_authorization_codes) were added on 2026-07-10 by
-- MasterPlan-7 EP-5, requiring another recompile of this splice.
-- The OAuth client binding (shomei_sessions.oauth_client_id) was added on 2026-07-10 by
-- MasterPlan-7 EP-5, requiring another recompile of this splice.
--
-- NB: touching the .cabal file (as the @migrate@ recipe does) does NOT force this rebuild —
-- cabal detects changes by content hash, not mtime. Editing THIS module is what does; that is
-- why every migration wave above appended a line here.
embeddedFiles :: [(FilePath, ByteString)]
embeddedFiles = $(embedDir "sql-migrations")

-- | Apply all migrations through codd WITHOUT expected-schema verification.
runShomeiMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runShomeiMigrationsNoCheck settings connectTimeout =
  runCoddLogger do
    migrations <- shomeiMigrations
    applyMigrationsNoCheck settings (Just migrations) connectTimeout (const (pure SchemasNotVerified))

-- | Build codd settings directly from a libpq connection string (NOT from the
-- @CODD_*@ environment). We always apply WITHOUT expected-schema verification, so
-- @onDiskReps@ / @namespacesToCheck@ carry harmless placeholders. Used by the standalone
-- server's startup migration and by the @test-support@ ephemeral-database helper.
coddSettingsFromConnString :: Text -> CoddSettings
coddSettingsFromConnString connStr =
  CoddSettings
    { migsConnString = parseConnString connStr,
      sqlMigrations = [],
      onDiskReps = Right (DbRep Null Map.empty Map.empty),
      namespacesToCheck = IncludeSchemas [SqlSchema "shomei", SqlSchema "public"],
      extraRolesToCheck = [],
      retryPolicy = singleTryPolicy,
      txnIsolationLvl = DbDefault,
      schemaAlgoOpts = SchemaAlgo False False False
    }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
  case parseOnly (connStringParser <* endOfInput) connStr of
    Left err -> error ("Could not parse PostgreSQL connection string for codd: " <> err)
    Right parsed -> parsed
