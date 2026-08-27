-- | Shared abuse-protection policy for every unauthenticated credential proof.
--
-- Keeping the gate, failure accounting, and success reset here gives later workflows one seam to
-- reuse. EP-5 can make failure recording atomic by changing 'recordProofFailure' without finding
-- and rewriting every credential workflow again.
module Shomei.Session.LoginAttempt.Workflow
  ( AbuseGate (..),
    guardAbuse,
    recordProofFailure,
    recordProofSuccess,
  )
where

import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Config (RateLimitConfig (..))
import Shomei.Error (AuthError (TooManyRequests))
import Shomei.Prelude
import Shomei.Session.Command (ClientContext (..))
import Shomei.Session.LoginAttempt.Domain
  ( AccountLockout (..),
    AttemptFactor,
    LoginOutcome (..),
    NewLoginAttempt (..),
  )
import Shomei.Session.LoginAttempt.Store
  ( LoginAttemptStore,
    clearAccountLockout,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    recordLoginAttempt,
    setAccountLockout,
  )

-- | State read before a proof. A standing row may be expired; successful proof removes it.
data AbuseGate = AbuseGate
  { standingLockout :: !(Maybe AccountLockout),
    locked :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Enforce the per-IP failure budget, then read account lockout state. This operation records
-- nothing so a throttled caller cannot extend its own throttle merely by retrying.
guardAbuse ::
  (LoginAttemptStore :> es, AuthEventPublisher :> es, Error AuthError :> es) =>
  RateLimitConfig ->
  ClientContext ->
  UTCTime ->
  Eff es AbuseGate
guardAbuse rl ctx ts
  | not rl.rateLimitEnabled = pure (AbuseGate Nothing False)
  | otherwise = do
      let cutoff = addUTCTime (negate rl.lockoutWindow) ts
      ipFails <- countRecentFailuresByIp ctx.clientIp cutoff
      when (ipFails >= rl.maxFailedLoginsPerIp) do
        publishAuthEvent (Event.LoginThrottled (Event.LoginThrottledData ctx.clientIp ipFails ts))
        throwError TooManyRequests
      lockRow <- getAccountLockout ctx.accountKey
      let isLocked = maybe False (maybe False (> ts) . (.lockedUntil)) lockRow
      pure (AbuseGate lockRow isLocked)

-- | Record and count one failed credential proof. Every factor contributes to the same account
-- budget; the factor field exists for auditability, not separate budgets.
recordProofFailure ::
  (LoginAttemptStore :> es, AuthEventPublisher :> es) =>
  RateLimitConfig ->
  ClientContext ->
  AttemptFactor ->
  UTCTime ->
  Eff es ()
recordProofFailure rl ctx factor ts = do
  recordLoginAttempt
    NewLoginAttempt
      { accountKey = ctx.accountKey,
        clientIp = ctx.clientIp,
        outcome = LoginFailure,
        occurredAt = ts,
        factor
      }
  when rl.rateLimitEnabled do
    let cutoff = addUTCTime (negate rl.lockoutWindow) ts
    acctFails <- countRecentFailuresByAccount ctx.accountKey cutoff
    when (acctFails >= rl.maxFailedLoginsPerAccount) do
      let lockedUntil = addUTCTime rl.lockoutDuration ts
      setAccountLockout (AccountLockout ctx.accountKey acctFails (Just lockedUntil) ts)
      publishAuthEvent
        (Event.AccountLocked (Event.AccountLockedData ctx.accountKey ctx.clientIp acctFails lockedUntil ts))

-- | Record a successful proof and clear a standing lockout row. The read-before-write guard avoids
-- an unnecessary delete on the overwhelmingly common no-lockout path.
recordProofSuccess ::
  (LoginAttemptStore :> es) =>
  ClientContext ->
  AttemptFactor ->
  Maybe AccountLockout ->
  UTCTime ->
  Eff es ()
recordProofSuccess ctx factor standing ts = do
  recordLoginAttempt
    NewLoginAttempt
      { accountKey = ctx.accountKey,
        clientIp = ctx.clientIp,
        outcome = LoginSuccess,
        occurredAt = ts,
        factor
      }
  when (isJust standing) (clearAccountLockout ctx.accountKey)
