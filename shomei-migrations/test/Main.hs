module Main (main) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
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
            testCompositionPreservesHostNamespace
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
