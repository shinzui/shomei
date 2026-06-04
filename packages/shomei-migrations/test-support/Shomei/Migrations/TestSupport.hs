{- | Provision a fresh, isolated ephemeral PostgreSQL with the complete Shōmei schema
applied in-process through codd via 'runShomeiMigrationsNoCheck'. Each call gets a
brand-new database (ephemeral-pg caches only the @initdb@ cluster and hands back a
fresh server+database per call), so tests stay isolated.
-}
module Shomei.Migrations.TestSupport (
    withShomeiMigratedDatabase,
) where

import Codd (CoddSettings (..))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Shomei.Migrations (runShomeiMigrationsNoCheck)

{- | Run @action@ against a fresh ephemeral PostgreSQL connection string whose database
already has the full Shōmei schema applied (via codd, without expected-schema
verification).
-}
withShomeiMigratedDatabase :: (Text -> IO a) -> IO a
withShomeiMigratedDatabase action = do
    result <- Pg.withCached \db -> do
        let connStr = Pg.connectionString db
        _ <- runShomeiMigrationsNoCheck (testCoddSettings connStr) (secondsToDiffTime 5)
        action connStr
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right value -> pure value

{- | codd settings built directly from an ephemeral connection string (NOT from env).
We apply without schema verification, so 'onDiskReps' / 'namespacesToCheck' use
harmless placeholders.
-}
testCoddSettings :: Text -> CoddSettings
testCoddSettings connStr =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Right (DbRep Null Map.empty Map.empty)
        , namespacesToCheck = IncludeSchemas [SqlSchema "shomei", SqlSchema "public"]
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
    case parseOnly (connStringParser <* endOfInput) connStr of
        Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
        Right parsed -> parsed
