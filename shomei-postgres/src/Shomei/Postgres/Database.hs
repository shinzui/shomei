-- | The @Database@ effect: a thin @effectful@ wrapper over a @hasql@ connection pool.
-- Interpreters run a 'Session' (or a 'Transaction') and surface a @Left UsageError@ for
-- the caller to translate into a domain failure.
module Shomei.Postgres.Database
  ( Database (..),
    runSession,
    runTransaction,
    runDatabasePool,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Session (Session)
import Hasql.Transaction (Transaction)
import Hasql.Transaction.Sessions qualified as Tx

data Database :: Effect where
  RunSession :: Session a -> Database m (Either UsageError a)
  RunTransaction :: Transaction a -> Database m (Either UsageError a)

type instance DispatchOf Database = Dynamic

runSession :: (Database :> es) => Session a -> Eff es (Either UsageError a)
runSession = send . RunSession

runTransaction :: (Database :> es) => Transaction a -> Eff es (Either UsageError a)
runTransaction = send . RunTransaction

-- | Interpret @Database@ against a concrete @hasql@ 'Pool'. Transactions run
-- read-committed, read-write (with @hasql-transaction@'s automatic retry on
-- serialization failures).
runDatabasePool :: (IOE :> es) => Pool -> Eff (Database : es) a -> Eff es a
runDatabasePool pool = interpret_ \case
  RunSession sess -> liftIO (Pool.use pool sess)
  RunTransaction t -> liftIO (Pool.use pool (Tx.transaction Tx.ReadCommitted Tx.Write t))
