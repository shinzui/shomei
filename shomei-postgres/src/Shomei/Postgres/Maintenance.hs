-- | Data hygiene: the batched sweep of expired and dead rows.
--
-- Nothing in Shōmei's domain layer ever deletes anything, so six tables would otherwise grow
-- without bound — most sharply @shomei_refresh_tokens@, which gains a row on every token
-- refresh, forever. This module is the counterweight: 'sweepOnce' performs one full pass,
-- deleting rows that are past their expiry plus a configured grace period.
--
-- Sweeping is an infrastructure maintenance concern rather than a domain operation — no
-- workflow will ever call it — so the statements live here as plain @hasql@ statements
-- instead of widening the seven core store ports (and every in-memory test interpreter) with
-- operations nothing else uses. One near-duplicate exists as a result:
-- @Shomei.Effect.PendingCeremonyStore.DeleteExpiredCeremonies@ (interpreted in
-- "Shomei.Postgres.PendingCeremonyStore") is an unbatched delete of the same rows
-- 'sweepOnce' handles with 'expiredCeremoniesStmt'. It is left in place for API
-- compatibility; it has no callers.
--
-- Definitions used throughout:
--
-- * A /batched delete/ deletes at most @batchSize@ rows (or, for refresh tokens, at most
--   @batchSize@ sessions' worth of rows) per statement, so row locks and the enclosing
--   transaction stay short-lived. Most statements here bound themselves with PostgreSQL's
--   physical row address: @DELETE FROM t WHERE ctid IN (SELECT ctid FROM t WHERE .. LIMIT n)@.
--   @ctid@ is a system column identifying a row version.
--
-- * A /grace period/ is extra time past logical expiry before a row becomes sweepable, kept
--   for forensics and — for refresh tokens — to protect reuse detection.
--
-- * A /retention window/ is the maximum age of rows in an append-only table
--   (@shomei_login_attempts@, @shomei_auth_events@).
--
-- Each batch is its own @Pool.use@ session, deliberately /not/ one big transaction: locks
-- stay short and a crash mid-sweep loses nothing, because every delete here is idempotent.
-- The background thread and @shomei-admin sweep@ may therefore run concurrently without
-- coordination; a batch simply finds fewer rows.
module Shomei.Postgres.Maintenance
  ( SweepConfig (..),
    defaultSweepConfig,
    SweepReport (..),
    emptySweepReport,
    sweepReportCounts,
    sweepReportTotal,
    sweepOnce,
  )
where

import Contravariant.Extras (contrazip2)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.Int (Int64)
import Data.Time (addUTCTime)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Prelude

-- | How much history to keep, and how large each delete batch may be.
--
-- The defaults are deliberately conservative where data is forensic and aggressive where it
-- is worthless: a one-time token is useless minutes after it expires, whereas an audit event
-- may be a compliance record.
data SweepConfig = SweepConfig
  { -- | Rows per @DELETE@ statement (sessions per statement, for refresh tokens).
    batchSize :: !Int,
    -- | Grace period before an expired or revoked session — and the whole rotation family of
    -- refresh tokens hanging off it — becomes sweepable. This must stay generous: reuse
    -- detection recognizes a replayed token by finding its @used@ row still present, so
    -- deleting those rows early would silently downgrade "token reuse" (which revokes the
    -- family) to "invalid token". After the grace period every token in the family is
    -- unusable anyway.
    deadSessionGraceDays :: !Int,
    -- | Grace period past expiry for email-verification tokens, password-reset tokens, and
    -- elapsed account lockouts. Pure debugging slack.
    oneTimeTokenGraceDays :: !Int,
    -- | Grace period past expiry for abandoned WebAuthn ceremonies, which are worthless
    -- seconds after expiry. An hour keeps live debugging possible.
    ceremonyGraceMinutes :: !Int,
    -- | Retention window for @shomei_login_attempts@. Brute-force counting reads a
    -- 15-minute window, so this is forensic slack over the biggest write-rate table.
    loginAttemptRetentionDays :: !Int,
    -- | Retention window for @shomei_auth_events@. 'Nothing' means retain forever, which is
    -- the default: the audit trail is the compliance record, and deleting it must be an
    -- explicit operator decision rather than something a default quietly does.
    authEventRetentionDays :: !(Maybe Int)
  }
  deriving stock (Show, Eq, Generic)

-- | See each field's documentation in 'SweepConfig' for why these values.
defaultSweepConfig :: SweepConfig
defaultSweepConfig =
  SweepConfig
    { batchSize = 1000,
      deadSessionGraceDays = 30,
      oneTimeTokenGraceDays = 7,
      ceremonyGraceMinutes = 60,
      loginAttemptRetentionDays = 90,
      authEventRetentionDays = Nothing
    }

-- | How many rows one 'sweepOnce' pass deleted, per table.
data SweepReport = SweepReport
  { refreshTokensDeleted :: !Int,
    sessionsDeleted :: !Int,
    verificationTokensDeleted :: !Int,
    resetTokensDeleted :: !Int,
    ceremoniesDeleted :: !Int,
    authorizationCodesDeleted :: !Int,
    lockoutsDeleted :: !Int,
    loginAttemptsDeleted :: !Int,
    authEventsDeleted :: !Int
  }
  deriving stock (Show, Eq, Generic)

-- | The report of a sweep that deleted nothing.
emptySweepReport :: SweepReport
emptySweepReport =
  SweepReport
    { refreshTokensDeleted = 0,
      sessionsDeleted = 0,
      verificationTokensDeleted = 0,
      resetTokensDeleted = 0,
      ceremoniesDeleted = 0,
      authorizationCodesDeleted = 0,
      lockoutsDeleted = 0,
      loginAttemptsDeleted = 0,
      authEventsDeleted = 0
    }

-- | The report as @(table_name, rows_deleted)@ pairs in sweep order. The names are the
-- database table names minus the @shomei_@ prefix; log lines and @shomei-admin sweep@ both
-- render this, so operators see one vocabulary.
sweepReportCounts :: SweepReport -> [(Text, Int)]
sweepReportCounts r =
  [ ("refresh_tokens", r.refreshTokensDeleted),
    ("sessions", r.sessionsDeleted),
    ("verification_tokens", r.verificationTokensDeleted),
    ("reset_tokens", r.resetTokensDeleted),
    ("ceremonies", r.ceremoniesDeleted),
    ("authorization_codes", r.authorizationCodesDeleted),
    ("lockouts", r.lockoutsDeleted),
    ("login_attempts", r.loginAttemptsDeleted),
    ("auth_events", r.authEventsDeleted)
  ]

-- | Total rows deleted across every table.
sweepReportTotal :: SweepReport -> Int
sweepReportTotal = sum . map snd . sweepReportCounts

-- | Run one full sweep pass against @pool@, treating @now@ as the current time (injected so
-- tests can seed rows at fixed offsets). Returns the per-table deletion counts, or the first
-- @UsageError@ if the database was unreachable or a statement failed — an unreachable
-- database is an ordinary, expected outcome for a periodic maintenance task, not a crash.
--
-- Statement order is load-bearing. @shomei_refresh_tokens.session_id@ references
-- @shomei_sessions@ with no @ON DELETE@ action, so every dead session's tokens must be gone
-- before the session itself can be deleted.
sweepOnce :: Pool -> SweepConfig -> UTCTime -> IO (Either UsageError SweepReport)
sweepOnce pool cfg now = runExceptT do
  refreshTokensDeleted <- drain deadSessionTokensStmt deadSessionCutoff
  sessionsDeleted <- drain deadSessionsStmt deadSessionCutoff
  verificationTokensDeleted <- drain expiredVerificationTokensStmt oneTimeTokenCutoff
  resetTokensDeleted <- drain expiredResetTokensStmt oneTimeTokenCutoff
  ceremoniesDeleted <- drain expiredCeremoniesStmt ceremonyCutoff
  -- EP-5's authorization codes live 60 seconds and are consumed once. They need no grace period
  -- of their own: a code past `expires_at` can never be exchanged, consumed or not, so the
  -- ceremony grace window (which exists for exactly the same "short-lived, already useless"
  -- shape) is the right one to reuse.
  authorizationCodesDeleted <- drain expiredAuthorizationCodesStmt ceremonyCutoff
  lockoutsDeleted <- drain elapsedLockoutsStmt oneTimeTokenCutoff
  loginAttemptsDeleted <- drain oldLoginAttemptsStmt loginAttemptCutoff
  -- Retaining the audit trail forever is the default; deleting it is opt-in.
  authEventsDeleted <- case cfg.authEventRetentionDays of
    Nothing -> pure 0
    Just days -> drain oldAuthEventsStmt (daysAgo days)
  pure SweepReport {..}
  where
    drain stmt cutoff = ExceptT (drainTable pool stmt cutoff limit)

    -- A non-positive batch size would compile to LIMIT 0, deleting nothing forever. Clamp
    -- rather than fail: a misconfigured sweeper that still works is better than one that
    -- silently no-ops.
    limit = fromIntegral (max 1 cfg.batchSize) :: Int64

    daysAgo d = addUTCTime (negate (fromIntegral d * 86400)) now
    minutesAgo m = addUTCTime (negate (fromIntegral m * 60)) now

    deadSessionCutoff = daysAgo cfg.deadSessionGraceDays
    oneTimeTokenCutoff = daysAgo cfg.oneTimeTokenGraceDays
    ceremonyCutoff = minutesAgo cfg.ceremonyGraceMinutes
    loginAttemptCutoff = daysAgo cfg.loginAttemptRetentionDays

-- | Run one statement repeatedly until it deletes nothing, summing the rows it removed.
--
-- The terminator is "this batch deleted zero rows", not "this batch deleted fewer than
-- @limit@ rows": 'deadSessionTokensStmt' bounds itself by /sessions/, so a batch of one
-- session can legitimately delete a whole rotation family's worth of tokens. Every statement
-- here is guaranteed to make progress while rows match — in particular
-- 'deadSessionTokensStmt' only selects sessions that still have at least one token — so a
-- zero result means the predicate is drained.
drainTable :: Pool -> Statement (UTCTime, Int64) Int64 -> UTCTime -> Int64 -> IO (Either UsageError Int)
drainTable pool stmt cutoff limit = go 0
  where
    go !acc = do
      res <- Pool.use pool (Session.statement (cutoff, limit) stmt)
      case res of
        Left err -> pure (Left err)
        Right deleted
          | deleted <= 0 -> pure (Right (fromIntegral acc))
          | otherwise -> go (acc + deleted)

-- Statements -----------------------------------------------------------------

-- | @$1@ is the cutoff timestamp, @$2@ the batch limit.
cutoffAndLimit :: E.Params (UTCTime, Int64)
cutoffAndLimit =
  contrazip2
    (E.param (E.nonNullable E.timestamptz))
    (E.param (E.nonNullable E.int8))

-- | A bounded delete of the rows a predicate selects, counted.
batchedDelete :: Text -> Statement (UTCTime, Int64) Int64
batchedDelete sql = preparable sql cutoffAndLimit D.rowsAffected

-- | Every refresh token belonging to a session that expired, or was revoked, before the
-- cutoff.
--
-- This batches by /session/ rather than by row, which the @ctid IN (SELECT ctid .. LIMIT n)@
-- shape used elsewhere cannot do safely here: @parent_token_id@ is a self-referencing foreign
-- key with no @ON DELETE@ action, checked at end of statement, so a row-bounded batch that
-- happened to split a rotation family — deleting a parent while its child survives into the
-- next batch — raises
-- @violates foreign key constraint "shomei_refresh_tokens_parent_token_id_fkey"@. Every
-- member of a rotation family shares one @session_id@, so deleting a whole session's tokens
-- in one statement is always internally consistent.
--
-- The @EXISTS@ guard keeps the drain loop honest: without it, a batch could select only
-- already-tokenless sessions, delete zero rows, and stop while other dead sessions still hold
-- tokens.
deadSessionTokensStmt :: Statement (UTCTime, Int64) Int64
deadSessionTokensStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_refresh_tokens rt
    WHERE rt.session_id IN (
      SELECT s.session_id
      FROM shomei.shomei_sessions s
      WHERE (s.expires_at <= $1 OR (s.status = 'revoked' AND s.revoked_at <= $1))
        AND EXISTS (
          SELECT 1 FROM shomei.shomei_refresh_tokens rt2
          WHERE rt2.session_id = s.session_id)
      LIMIT $2)
    """

-- | Sessions dead past the cutoff that no longer have any refresh tokens. The @NOT EXISTS@
-- guard means a partially swept family never strands a token whose session is gone; the
-- leftovers are collected by the next cycle, after 'deadSessionTokensStmt' drains them.
deadSessionsStmt :: Statement (UTCTime, Int64) Int64
deadSessionsStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_sessions
    WHERE ctid IN (
      SELECT s2.ctid
      FROM shomei.shomei_sessions s2
      WHERE (s2.expires_at <= $1 OR (s2.status = 'revoked' AND s2.revoked_at <= $1))
        AND NOT EXISTS (
          SELECT 1 FROM shomei.shomei_refresh_tokens rt
          WHERE rt.session_id = s2.session_id)
      LIMIT $2)
    """

expiredVerificationTokensStmt :: Statement (UTCTime, Int64) Int64
expiredVerificationTokensStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_email_verification_tokens
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_email_verification_tokens
      WHERE expires_at <= $1
      LIMIT $2)
    """

expiredResetTokensStmt :: Statement (UTCTime, Int64) Int64
expiredResetTokensStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_password_reset_tokens
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_password_reset_tokens
      WHERE expires_at <= $1
      LIMIT $2)
    """

expiredCeremoniesStmt :: Statement (UTCTime, Int64) Int64
expiredCeremoniesStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_webauthn_pending_ceremonies
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_webauthn_pending_ceremonies
      WHERE expires_at <= $1
      LIMIT $2)
    """

-- | Authorization codes past their expiry (EP-5). Consumed rows are swept the same way: a
-- consumed code is refused by `expires_at > now` in the consume statement anyway, so keeping it
-- past expiry buys nothing.
expiredAuthorizationCodesStmt :: Statement (UTCTime, Int64) Int64
expiredAuthorizationCodesStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_oauth_authorization_codes
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_oauth_authorization_codes
      WHERE expires_at <= $1
      LIMIT $2)
    """

-- | Lockout rows whose lock has elapsed. Rows with a NULL @locked_until@ are accumulating
-- failure counts for an account that is not currently locked; they are one row per account
-- that has ever failed a login and are left alone.
elapsedLockoutsStmt :: Statement (UTCTime, Int64) Int64
elapsedLockoutsStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_account_lockouts
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_account_lockouts
      WHERE locked_until IS NOT NULL AND locked_until <= $1
      LIMIT $2)
    """

oldLoginAttemptsStmt :: Statement (UTCTime, Int64) Int64
oldLoginAttemptsStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_login_attempts
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_login_attempts
      WHERE occurred_at <= $1
      LIMIT $2)
    """

oldAuthEventsStmt :: Statement (UTCTime, Int64) Int64
oldAuthEventsStmt =
  batchedDelete
    """
    DELETE FROM shomei.shomei_auth_events
    WHERE ctid IN (
      SELECT ctid FROM shomei.shomei_auth_events
      WHERE created_at <= $1
      LIMIT $2)
    """
