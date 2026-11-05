-- | Database-only transactions whose statements inherit a shrinking server-side budget.
-- There is no MonadIO instance or raw transaction constructor. Generate IDs and perform
-- non-database effects before/after the transaction. Audit inserts are ordinary transactional SQL.
module Shomei.Persistence.Transaction.Postgres
  ( Transaction,
    statement,
    transactionSession,
  )
where

import Data.Int (Int64)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as Sessions
import Shomei.Prelude

newtype Transaction a = Transaction (Tx.Transaction a)
  deriving newtype (Functor, Applicative, Monad)

statement :: a -> Statement a b -> Transaction b
statement params query = Transaction do
  _ <- Tx.statement () capStatementBudget
  Tx.statement params query

-- | One whole attempt, with dependency automatic retries disabled. The local settings reset
-- on COMMIT/ROLLBACK. Retrying starts a fresh server budget from the remaining client deadline.
transactionSession :: Int -> Transaction a -> Session a
transactionSession milliseconds (Transaction body) =
  Sessions.transactionNoRetry Sessions.ReadCommitted Sessions.Write do
    _ <- Tx.statement (fromIntegral milliseconds) initializeBudget
    body

initializeBudget :: Statement Int64 (Text, Text)
initializeBudget =
  preparable
    """
    SELECT set_config('shomei.transaction_deadline', (clock_timestamp() + $1::bigint * interval '1 millisecond')::text, true),
           set_config('shomei.statement_limit_ms', (extract(epoch FROM current_setting('statement_timeout')::interval) * 1000)::bigint::text, true)
    """
    (E.param (E.nonNullable E.int8))
    (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.text)))

capStatementBudget :: Statement () Text
capStatementBudget =
  preparable
    """
    SELECT set_config('statement_timeout',
      greatest(1, least(
        floor(extract(epoch FROM (current_setting('shomei.transaction_deadline')::timestamptz - clock_timestamp())) * 1000)::bigint,
        nullif(current_setting('shomei.statement_limit_ms')::bigint,0)
      ))::text, true)
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.text)))
