{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

module Main (main) where

import Data.ByteString qualified
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Database.PostgreSQL.Migrate.Test
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Shomei.Migrations (shomeiMigrationComponent)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain
    ( testGroup
        "Shomei migrations"
        [ testCase
            "composition preserves a host component's namespace state"
            testCompositionPreservesHostNamespace,
          testCase "generation upgrade preserves credentials/sessions and marks old pending flows as legacy" testGenerationUpgrade,
          testCase "provenance upgrade repairs legacy machine and actor rows and defaults unknown writers safely" testProvenanceUpgrade
        ]
    )

testCompositionPreservesHostNamespace :: Assertion
testCompositionPreservesHostNamespace = do
  result <-
    withMigratedDatabase composedPlan $ \connection ->
      Connection.use connection (Session.statement () compositionSnapshotStatement)
  case result of
    Right (Right snapshot) ->
      assertEqual
        "the host probe and collision table remain in the host schema"
        (CompositionSnapshot 1 True True True True)
        snapshot
    other -> assertFailure ("unexpected composed migration result: " <> show other)

composedPlan :: MigrationPlan
composedPlan =
  expectRight
    ( migrationPlan
        ( hostBeforeComponent
            :| [expectRight shomeiMigrationComponent, hostAfterComponent]
        )
    )

hostBeforeComponent :: MigrationComponent
hostBeforeComponent =
  expectRight
    ( migrationComponent
        "host-before"
        Set.empty
        ( expectRight
            ( sqlMigration
                "0001-host-fixture"
                """
                CREATE SCHEMA host;
                SET search_path TO host, pg_catalog;

                CREATE TABLE host_probe (
                  value text NOT NULL
                );

                CREATE TABLE shomei_users (
                  host_marker text NOT NULL
                );
                """
            )
            :| []
        )
    )

hostAfterComponent :: MigrationComponent
hostAfterComponent =
  expectRight
    ( migrationComponent
        "host-after"
        (Set.fromList ["host-before", "shomei"])
        ( expectRight
            ( sqlMigration
                "0001-use-host-namespace"
                "INSERT INTO host_probe (value) VALUES ('after-shomei')"
            )
            :| []
        )
    )

data CompositionSnapshot = CompositionSnapshot
  { probeRows :: !Int64,
    hostCollisionExists :: !Bool,
    shomeiUsersExists :: !Bool,
    hostMarkerExists :: !Bool,
    hostUserIdAbsent :: !Bool
  }
  deriving stock (Eq, Show)

compositionSnapshotStatement :: Statement () CompositionSnapshot
compositionSnapshotStatement =
  Statement.preparable
    """
    SELECT
      (SELECT count(*)::int8 FROM host.host_probe),
      to_regclass('host.shomei_users') IS NOT NULL,
      to_regclass('shomei.shomei_users') IS NOT NULL,
      EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'host'
          AND table_name = 'shomei_users'
          AND column_name = 'host_marker'
      ),
      NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'host'
          AND table_name = 'shomei_users'
          AND column_name = 'user_id'
      )
    """
    Encoders.noParams
    ( Decoders.singleRow
        ( CompositionSnapshot
            <$> required Decoders.int8
            <*> required Decoders.bool
            <*> required Decoders.bool
            <*> required Decoders.bool
            <*> required Decoders.bool
        )
    )
  where
    required = Decoders.column . Decoders.nonNullable

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id

-- Apply the exact embedded history through 0042, seed rows with its legacy default,
-- then run the real 0043 migration through the same runner in its own transaction.
testProvenanceUpgrade :: Assertion
testProvenanceUpgrade = do
  let history = NE.toList embeddedHistory
      (before, upgradeAndLater) = span ((/= "0043-enforce-session-provenance-upgrades.sql") . fst) history
      fixture = ("0042-upgrade-fixture.sql", legacySessionFixture)
      component = expectRight (migrationComponentFromEmbeddedSql "provenance-upgrade" Set.empty (NE.fromList (before <> [fixture] <> upgradeAndLater)))
      plan = expectRight (migrationPlan (component :| []))
  result <- withMigratedDatabase plan \connection -> do
    initial <- Connection.use connection (Session.statement () provenanceSnapshot)
    initial @?= Right (1, 3, 1, True)
    inserted <- Connection.use connection (Session.script "INSERT INTO shomei.shomei_sessions(session_id,user_id,status,created_at,expires_at) VALUES ('aaaaaaaa-0000-0000-0000-000000000006','11111111-1111-1111-1111-111111111111','active',now(),now()+interval '1 day')")
    inserted @?= Right ()
    omitted <- Connection.use connection (Session.statement () provenanceSnapshot)
    omitted @?= Right (1, 4, 1, True)
    invalid <- Connection.use connection (Session.script "UPDATE shomei.shomei_sessions SET kind='unknown' WHERE kind='interactive'")
    case invalid of
      Left _ -> pure ()
      Right _ -> assertFailure "unknown provenance was admitted"
    final <- Connection.use connection (Session.statement () provenanceSnapshot)
    final @?= Right (1, 4, 1, True)
  case result of
    Left err -> assertFailure (show err)
    Right () -> pure ()

legacySessionFixture :: Data.ByteString.ByteString
legacySessionFixture =
  """
  INSERT INTO shomei.shomei_users(user_id,login_id,status,created_at,updated_at) VALUES
    ('11111111-1111-1111-1111-111111111111','human','active',now(),now()),
    ('22222222-2222-2222-2222-222222222222','machine','active',now(),now());
  INSERT INTO shomei.shomei_service_accounts(service_account_id,client_id,user_id,secret_hash,display_name,allowed_scopes,status,created_at)
    VALUES ('33333333-3333-3333-3333-333333333333','machine-client','22222222-2222-2222-2222-222222222222','public-fixture','Machine','[]','active',now());
  INSERT INTO shomei.shomei_sessions(session_id,user_id,status,created_at,expires_at,actor_user_id,kind) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','active',now(),now()+interval '1 day',NULL,'interactive'),
    ('aaaaaaaa-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','active',now(),now()+interval '1 day',NULL,'interactive'),
    ('aaaaaaaa-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','active',now(),now()+interval '1 day','22222222-2222-2222-2222-222222222222','interactive'),
    ('aaaaaaaa-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','active',now(),now()+interval '1 day',NULL,NULL),
    ('aaaaaaaa-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','active',now(),now()+interval '1 day',NULL,'interactive');
  INSERT INTO shomei.shomei_refresh_tokens(refresh_token_id,session_id,token_hash,status,created_at,expires_at)
    VALUES ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','public-human-refresh-fixture','active',now(),now()+interval '1 day');
  """

provenanceSnapshot :: Statement () (Int64, Int64, Int64, Bool)
provenanceSnapshot =
  Statement.preparable
    "SELECT count(*) FILTER (WHERE kind='interactive'), count(*) FILTER (WHERE kind='machine'), count(*) FILTER (WHERE kind='delegated'), bool_and(CASE session_id::text WHEN 'aaaaaaaa-0000-0000-0000-000000000001' THEN kind='interactive' WHEN 'aaaaaaaa-0000-0000-0000-000000000003' THEN kind='delegated' ELSE kind='machine' END) FROM shomei.shomei_sessions"
    Encoders.noParams
    (Decoders.singleRow ((,,,) <$> required <*> required <*> required <*> Decoders.column (Decoders.nonNullable Decoders.bool)))
  where
    required = Decoders.column (Decoders.nonNullable Decoders.int8)

embeddedHistory :: NonEmpty (FilePath, Data.ByteString.ByteString)
embeddedHistory = $(embedMigrationManifest "migrations/shomei/manifest")

testGenerationUpgrade :: Assertion
testGenerationUpgrade = do
  let history = NE.toList embeddedHistory
      (before, upgrade) = span ((/= "0044-add-authentication-generation.sql") . fst) history
      fixture = ("0043-generation-fixture.sql", generationFixture)
      component = expectRight (migrationComponentFromEmbeddedSql "generation-upgrade" Set.empty (NE.fromList (before <> [fixture] <> upgrade)))
      plan = expectRight (migrationPlan (component :| []))
  result <- withMigratedDatabase plan \connection -> do
    snapshot <- Connection.use connection (Session.statement () generationSnapshot)
    snapshot @?= Right True
    invalid <- Connection.use connection (Session.script "UPDATE shomei.shomei_users SET authentication_generation = -1")
    case invalid of
      Left _ -> pure ()
      Right () -> assertFailure "negative generation admitted"
  case result of
    Left err -> assertFailure (show err)
    Right () -> pure ()

generationFixture :: Data.ByteString.ByteString
generationFixture =
  """
  INSERT INTO shomei.shomei_users(user_id,login_id,status,created_at,updated_at)
    VALUES ('11111111-1111-1111-1111-111111111111','generation-user','active',now(),now());
  INSERT INTO shomei.shomei_sessions(session_id,user_id,status,created_at,expires_at,kind)
    VALUES ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','active',now(),now()+interval '1 day','interactive');
  INSERT INTO shomei.shomei_webauthn_pending_ceremonies(ceremony_id,user_id,kind,options_blob,created_at,expires_at)
    VALUES ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','authentication','public-fixture',now(),now()+interval '5 minutes');
  INSERT INTO shomei.shomei_totp_credentials(totp_credential_id,user_id,secret_enc,created_at,confirmed_at,envelope_version)
    VALUES ('cccccccc-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','public-fixture',now(),now(),1);
  """

generationSnapshot :: Statement () Bool
generationSnapshot =
  Statement.preparable
    """
    SELECT (SELECT count(*) = 1 AND bool_and(authentication_generation = 0) FROM shomei.shomei_users)
      AND (SELECT count(*) = 1 AND bool_and(status = 'active') FROM shomei.shomei_sessions)
      AND (SELECT count(*) = 1 AND bool_and(confirmed_at IS NOT NULL) FROM shomei.shomei_totp_credentials)
      AND (SELECT count(*) = 1 AND bool_and(authentication_generation IS NULL) FROM shomei.shomei_webauthn_pending_ceremonies)
    """
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))
