-- | Route-local control flow for typed application results.
--
-- 'ApplicationHandler' uses 'ExceptT' only inside a handler to short-circuit expected failures.
-- 'runApplicationHandler' turns that value into 'ApplicationResult'; it never calls Servant's
-- 'throwError'. This keeps pre-handler rejection and operation-owned outcomes visibly separate.
module Shomei.Servant.Application
  ( ApplicationHandler,
    runApplicationHandler,
    port,
    workflow,
    rejectAuth,
    rejectProblem,
  )
where

import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Void (Void, absurd)
import Effectful (Eff)
import Servant (Handler)
import Shomei.Error (AuthError)
import Shomei.Servant.Error (ProblemOccurrence, ProblemSpec)
import Shomei.Servant.Result (ApplicationResult (..), applicationError, mapApplicationResult, problemResult)
import Shomei.Servant.Seam (AppEffects, Env, runPortResult, runWorkflowResult)

type ApplicationHandler = ExceptT (ApplicationResult Void) Handler

runApplicationHandler :: ApplicationHandler a -> Handler (ApplicationResult a)
runApplicationHandler action =
  runExceptT action >>= \case
    Left failure -> pure (mapApplicationResult absurd failure)
    Right value -> pure (ApplicationSuccess value)

port :: Env -> Eff AppEffects a -> ApplicationHandler a
port env action = ExceptT (either (Left . applicationError) Right <$> runPortResult env action)

workflow :: Env -> Eff AppEffects (Either AuthError a) -> ApplicationHandler a
workflow env action = ExceptT (either (Left . applicationError) Right <$> runWorkflowResult env action)

rejectAuth :: AuthError -> ApplicationHandler a
rejectAuth = throwE . applicationError

rejectProblem :: ProblemSpec -> ProblemOccurrence -> ApplicationHandler a
rejectProblem spec occurrence = throwE (problemResult spec occurrence)
