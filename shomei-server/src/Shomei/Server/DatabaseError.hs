-- | Secret-free summaries of PostgreSQL pool failures suitable for operator output and logs.
--
-- A 'UsageError' can carry the SQL text, rendered parameters, and PostgreSQL's primary message.
-- Those details may include encrypted key envelopes or other credentials and must remain inside
-- the persistence boundary.
module Shomei.Server.DatabaseError (summarizeUsageError) where

import Data.Text (Text)
import Hasql.Errors qualified as Hasql
import Hasql.Pool (UsageError (..))

summarizeUsageError :: UsageError -> Text
summarizeUsageError = \case
  ConnectionUsageError _ -> "could not connect to PostgreSQL"
  AcquisitionTimeoutUsageError -> "timed out acquiring a connection"
  SessionUsageError
    ( Hasql.StatementSessionError
        _
        _
        _
        _
        _
        (Hasql.ServerStatementError (Hasql.ServerError code _ _ _ _))
      ) -> "statement failed (SQLSTATE " <> code <> ")"
  SessionUsageError (Hasql.ScriptSessionError _ (Hasql.ServerError code _ _ _ _)) ->
    "statement failed (SQLSTATE " <> code <> ")"
  SessionUsageError _ -> "statement failed"
