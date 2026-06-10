{- | PostgreSQL interpreter for the 'LoginAttemptStore' port (EP-2 brute-force protection).

Attempts are appended to @shomei_login_attempts@ (an append-only forensic log); the
per-account lockout state lives in @shomei_account_lockouts@. Windowed failure counting is
asymmetric: the per-account count only counts failures since the most recent success (so a
successful login resets the account's brute-force progress), while the per-IP count is a
plain windowed count (so an attacker cannot reset the IP throttle by logging into their own
account). Both are still bounded by the caller-supplied window cutoff.
-}
module Shomei.Postgres.LoginAttemptStore (
    runLoginAttemptStorePostgres,
) where

import Shomei.Prelude

import Data.Int (Int32, Int64)
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import "contravariant-extras" Contravariant.Extras (contrazip2, contrazip4, contrazip5)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.LoginAttempt (
    AccountKey (..),
    AccountLockout (..),
    ClientIp (..),
    NewLoginAttempt (..),
 )
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Postgres.Codec (loginOutcomeToText, tshow)
import Shomei.Postgres.Database (Database, runSession)

runLoginAttemptStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (LoginAttemptStore : es) a ->
    Eff es a
runLoginAttemptStorePostgres = interpret_ \case
    RecordLoginAttempt na -> do
        aid <- liftIO UUIDv4.nextRandom
        let AccountKey k = na.accountKey
            ClientIp ip = na.clientIp
            row = (aid, k, ip, loginOutcomeToText na.outcome, na.occurredAt)
        res <- runSession (Session.statement row insertAttemptStmt)
        either dbFail (const (pure ())) res
    CountRecentFailuresByAccount (AccountKey k) cutoff -> do
        res <- runSession (Session.statement (k, cutoff) countByAccountStmt)
        either dbFail (pure . fromIntegral) res
    CountRecentFailuresByIp (ClientIp ip) cutoff -> do
        res <- runSession (Session.statement (ip, cutoff) countByIpStmt)
        either dbFail (pure . fromIntegral) res
    GetAccountLockout k@(AccountKey kt) -> do
        res <- runSession (Session.statement kt findLockoutStmt)
        row <- either dbFail pure res
        pure (fmap (rebuildLockout k) row)
    SetAccountLockout lo -> do
        let AccountKey k = lo.accountKey
            row = (k, fromIntegral lo.failedCount :: Int32, lo.lockedUntil, lo.updatedAt)
        res <- runSession (Session.statement row upsertLockoutStmt)
        either dbFail (const (pure ())) res
    ClearAccountLockout (AccountKey k) -> do
        res <- runSession (Session.statement k deleteLockoutStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))

rebuildLockout :: AccountKey -> (Int32, Maybe UTCTime, UTCTime) -> AccountLockout
rebuildLockout k (fc, lu, ua) =
    AccountLockout
        { accountKey = k
        , failedCount = fromIntegral fc
        , lockedUntil = lu
        , updatedAt = ua
        }

type AttemptRow = (UUID, Text, Text, Text, UTCTime)

insertAttemptStmt :: Statement AttemptRow ()
insertAttemptStmt =
    preparable
        """
        INSERT INTO shomei.shomei_login_attempts
          (attempt_id, account_key, client_ip, outcome, occurred_at)
        VALUES ($1, $2, $3, $4, $5)
        """
        ( contrazip5
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

-- Per-account failures in the window AND strictly after the most recent success.
countByAccountStmt :: Statement (Text, UTCTime) Int64
countByAccountStmt =
    preparable
        """
        SELECT count(*) FROM shomei.shomei_login_attempts
        WHERE account_key = $1 AND outcome = 'failure' AND occurred_at >= $2
          AND occurred_at > COALESCE(
                (SELECT max(occurred_at) FROM shomei.shomei_login_attempts
                 WHERE account_key = $1 AND outcome = 'success'),
                '-infinity'::timestamptz)
        """
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
        (D.singleRow (D.column (D.nonNullable D.int8)))

-- Per-IP failures in the window (plain windowed count; no success reset).
countByIpStmt :: Statement (Text, UTCTime) Int64
countByIpStmt =
    preparable
        """
        SELECT count(*) FROM shomei.shomei_login_attempts
        WHERE client_ip = $1 AND outcome = 'failure' AND occurred_at >= $2
        """
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
        (D.singleRow (D.column (D.nonNullable D.int8)))

findLockoutStmt :: Statement Text (Maybe (Int32, Maybe UTCTime, UTCTime))
findLockoutStmt =
    preparable
        """
        SELECT failed_count, locked_until, updated_at
        FROM shomei.shomei_account_lockouts
        WHERE account_key = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe lockoutRowDecoder)

lockoutRowDecoder :: D.Row (Int32, Maybe UTCTime, UTCTime)
lockoutRowDecoder =
    (,,)
        <$> D.column (D.nonNullable D.int4)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

type LockoutRow = (Text, Int32, Maybe UTCTime, UTCTime)

upsertLockoutStmt :: Statement LockoutRow ()
upsertLockoutStmt =
    preparable
        """
        INSERT INTO shomei.shomei_account_lockouts
          (account_key, failed_count, locked_until, updated_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (account_key) DO UPDATE
          SET failed_count = EXCLUDED.failed_count,
              locked_until = EXCLUDED.locked_until,
              updated_at = EXCLUDED.updated_at
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

deleteLockoutStmt :: Statement Text ()
deleteLockoutStmt =
    preparable
        """
        DELETE FROM shomei.shomei_account_lockouts WHERE account_key = $1
        """
        (E.param (E.nonNullable E.text))
        D.noResult
