-- | The @Database@ effect: a thin @effectful@ wrapper over a @hasql@ connection pool.
-- Interpreters run a 'Session' (or a 'Transaction') and surface a @Left UsageError@ for
-- the caller to translate with 'postgresUnavailable'.
module Shomei.Persistence.Database.Postgres
  ( Database (..),
    runSession,
    runTransaction,
    postgresUnavailable,
    uniqueViolation,
    postgresWriteError,
    runDatabasePool,
    runDatabasePoolWith,
    TransactionRetryPolicy (..),
    defaultTransactionRetryPolicy,
    validateTransactionRetryPolicy,
    retryableTransactionError,
  )
where

import Control.Concurrent (threadDelay)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Errors qualified as Hasql
import Hasql.Session (Session)
import Shomei.Error (AuthDependency (PostgreSQL), AuthError (DependencyUnavailable))
import Shomei.Persistence.Pool.Postgres (Pool, UsageError)
import Shomei.Persistence.Pool.Postgres qualified as Pool
import Shomei.Persistence.Transaction.Postgres (Transaction)
import Shomei.Persistence.Transaction.Postgres qualified as Bounded
import System.Timeout (timeout)

data Database :: Effect where
  RunSession :: Session a -> Database m (Either UsageError a)
  RunTransaction :: Transaction a -> Database m (Either UsageError a)

type instance DispatchOf Database = Dynamic

runSession :: (Database :> es) => Session a -> Eff es (Either UsageError a)
runSession = send . RunSession

runTransaction :: (Database :> es) => Transaction a -> Eff es (Either UsageError a)
runTransaction = send . RunTransaction

-- | Collapse all Hasql execution details to the one typed dependency failure.
-- Driver messages and SQL must never cross the persistence boundary.
postgresUnavailable :: UsageError -> AuthError
postgresUnavailable _ = DependencyUnavailable PostgreSQL

-- | The constraint name of a PostgreSQL unique violation (SQLSTATE 23505), when the server
-- supplied one in its primary message. Other failures deliberately remain opaque.
uniqueViolation :: UsageError -> Maybe Text
uniqueViolation = \case
  Pool.SessionUsageError
    ( Hasql.StatementSessionError
        _
        _
        _
        _
        _
        (Hasql.ServerStatementError (Hasql.ServerError "23505" message _ _ _))
      ) -> constraintName message
  _ -> Nothing

-- | Preserve a domain conflict for recognized unique indexes; otherwise keep the existing
-- fail-closed dependency error and never expose SQL or driver text.
postgresWriteError :: (Text -> Maybe AuthError) -> UsageError -> AuthError
postgresWriteError classify err =
  maybe (postgresUnavailable err) id (uniqueViolation err >>= classify)

constraintName :: Text -> Maybe Text
constraintName message =
  case Text.breakOn marker message of
    (_, rest)
      | Text.null rest -> Nothing
      | otherwise ->
          case Text.breakOn "\"" (Text.drop (Text.length marker) rest) of
            (name, closing)
              | not (Text.null name) && not (Text.null closing) -> Just name
            _ -> Nothing
  where
    marker = "unique constraint \""

-- | Validated at startup; an invalid direct policy refuses work without touching the pool.
-- The deadline covers checkout, every attempt, and backoff. No retry follows an ambiguous
-- connection/commit failure. Transaction bodies are Hasql database statements only.
data TransactionRetryPolicy = TransactionRetryPolicy
  { maxAttempts :: !Int,
    deadlineMs :: !Int
  }
  deriving stock (Eq, Show)

defaultTransactionRetryPolicy :: TransactionRetryPolicy
defaultTransactionRetryPolicy = TransactionRetryPolicy 3 5000

validateTransactionRetryPolicy :: TransactionRetryPolicy -> Either Text ()
validateTransactionRetryPolicy policy
  | policy.maxAttempts < 1 = Left "transaction max attempts must be positive"
  | policy.deadlineMs < 1 || policy.deadlineMs > min 2147483647 (maxBound `div` 1000) = Left "transaction deadline milliseconds must be positive and representable"
  | otherwise = Right ()

retryableTransactionError :: UsageError -> Bool
retryableTransactionError = \case
  Pool.SessionUsageError (Hasql.StatementSessionError _ _ _ _ _ (Hasql.ServerStatementError (Hasql.ServerError code _ _ _ _))) -> retryable code
  Pool.SessionUsageError (Hasql.ScriptSessionError _ (Hasql.ServerError code _ _ _ _)) -> retryable code
  _ -> False
  where
    retryable code = code == "40001" || code == "40P01"

runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a -> Eff es a
runDatabasePool = runDatabasePoolWith defaultTransactionRetryPolicy

runDatabasePoolWith :: (IOE :> es) => TransactionRetryPolicy -> Pool -> Eff (Database : es) a -> Eff es a
runDatabasePoolWith policy pool = interpret_ \case
  RunSession sess -> liftIO (Pool.use pool sess)
  RunTransaction transaction -> liftIO do
    case validateTransactionRetryPolicy policy of
      Left _ -> pure (Left Pool.AcquisitionTimeoutUsageError)
      Right () -> do
        started <- getMonotonicTimeNSec
        let deadline = toInteger started + toInteger policy.deadlineMs * 1000000
            attempt remainingAttempts = do
              now <- getMonotonicTimeNSec
              let remainingMicros = (deadline - toInteger now) `div` 1000
              if remainingMicros <= 0
                then pure (Left Pool.AcquisitionTimeoutUsageError)
                else do
                  -- Hasql cancels and rolls back an interrupted session before returning its
                  -- connection. Keep the operation unmasked so the deadline can interrupt
                  -- query I/O. A timeout is never retried.
                  result <- timeout (fromInteger remainingMicros) (Pool.use pool (Bounded.transactionSession (max 1 (fromInteger (remainingMicros `div` 1000))) transaction))
                  case result of
                    Nothing -> pure (Left Pool.AcquisitionTimeoutUsageError)
                    Just (Left err) | remainingAttempts > 1 && retryableTransactionError err -> do
                      after <- getMonotonicTimeNSec
                      let pause = min 10000 ((deadline - toInteger after) `div` 1000)
                      if pause <= 0
                        then pure (Left err)
                        else threadDelay (fromInteger pause) >> attempt (remainingAttempts - 1)
                    Just outcome -> pure outcome
        attempt policy.maxAttempts
