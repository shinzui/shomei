-- | EP-3: the effectful breach-policy guard, appended to every password-accepting workflow
-- after the pure 'Shomei.Domain.Password.validatePassword' step. Honors the EP-1 policy flags:
-- no-op when disabled; rejects breached passwords; on an unreachable checker, fails open or
-- closed per 'breachCheckFailClosed'.
module Shomei.Workflow.Breach (enforceBreachPolicy) where

import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Shomei.Domain.Password (PasswordPolicy (..), PlainPassword)
import Shomei.Effect.PasswordBreachChecker (BreachResult (..), PasswordBreachChecker, checkPasswordBreached)
import Shomei.Error (AuthError (..), PasswordPolicyViolation (..))

-- | Run the opt-in breach check for a password. A no-op unless @breachCheckEnabled@ is set.
-- A 'Breached' result always rejects; an unreachable checker rejects only under
-- @breachCheckFailClosed@ (the default is fail-open). The 'Error AuthError' effect is supplied
-- by each workflow's enclosing 'runErrorNoCallStack', so the guard is callable from inside the
-- workflow @do@ blocks.
enforceBreachPolicy ::
  (PasswordBreachChecker :> es, Error AuthError :> es) =>
  PasswordPolicy ->
  PlainPassword ->
  Eff es ()
enforceBreachPolicy policy pw
  | not policy.breachCheckEnabled = pure ()
  | otherwise = do
      r <- checkPasswordBreached pw
      case r of
        NotBreached -> pure ()
        Breached -> throwError (WeakPassword PasswordBreached)
        BreachCheckUnavailable ->
          if policy.breachCheckFailClosed
            then throwError (WeakPassword PasswordBreached)
            else pure ()
