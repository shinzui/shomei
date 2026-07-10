-- | PostgreSQL interpreter for the EP-7 recovery-code store.
--
-- Codes are stored only as SHA-256 hex hashes. 'ConsumeRecoveryCode' is the compare-and-set
-- @UPDATE … WHERE used_at IS NULL … RETURNING@ that makes a double-spend impossible even under a
-- race; 'ReplaceRecoveryCodes' deletes the user's set and inserts the new one in one 'Session'
-- so they land together.
module Shomei.Postgres.RecoveryCodeStore
  ( runRecoveryCodeStorePostgres,
  )
where

import Contravariant.Extras (contrazip3, contrazip4)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.Totp (NewRecoveryCode (..))
import Shomei.Effect.RecoveryCodeStore (RecoveryCodeStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (recoveryCodeIdToUUID, userIdToUUID)
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

runRecoveryCodeStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (RecoveryCodeStore : es) a ->
  Eff es a
runRecoveryCodeStorePostgres = interpret_ \case
  ReplaceRecoveryCodes uid newCodes -> do
    let uidU = userIdToUUID uid
        rows =
          [ (recoveryCodeIdToUUID nc.recoveryCodeId, uidU, nc.codeHash, nc.createdAt)
          | nc <- newCodes
          ]
    res <- runSession do
      Session.statement uidU deleteForUserStmt
      mapM_ (`Session.statement` insertStmt) rows
    either dbFail (const (pure ())) res
  ConsumeRecoveryCode uid h t -> do
    res <- runSession (Session.statement (userIdToUUID uid, h, t) consumeStmt)
    either dbFail (pure . isJust) res
  CountUnusedRecoveryCodes uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) countUnusedStmt)
    n <- either dbFail pure res
    pure (fromIntegral n)
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))

-- | The four columns an INSERT writes; @used_at@ is always NULL on a fresh row.
type InsertRow = (UUID, UUID, Text, UTCTime)

deleteForUserStmt :: Statement UUID ()
deleteForUserStmt =
  preparable
    "DELETE FROM shomei.shomei_recovery_codes WHERE user_id = $1"
    (E.param (E.nonNullable E.uuid))
    D.noResult

insertStmt :: Statement InsertRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_recovery_codes
      (recovery_code_id, user_id, code_hash, created_at, used_at)
    VALUES ($1, $2, $3, $4, NULL)
    """
    ( contrazip4
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

-- | Spend one unused code matching @(user_id, code_hash)@. The @RETURNING recovery_code_id@ sits
-- on its own line: a 'MultilineString' drops its trailing newline, so keeping @RETURNING@ apart
-- from the column avoids concatenating into @RETURNINGrecovery_code_id@ (EP-5 discovery).
consumeStmt :: Statement (UUID, Text, UTCTime) (Maybe UUID)
consumeStmt =
  preparable
    """
    UPDATE shomei.shomei_recovery_codes
    SET used_at = $3
    WHERE user_id = $1 AND code_hash = $2 AND used_at IS NULL
    RETURNING recovery_code_id
    """
    ( contrazip3
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    (D.rowMaybe (D.column (D.nonNullable D.uuid)))

countUnusedStmt :: Statement UUID Int64
countUnusedStmt =
  preparable
    "SELECT count(*) FROM shomei.shomei_recovery_codes WHERE user_id = $1 AND used_at IS NULL"
    (E.param (E.nonNullable E.uuid))
    (D.singleRow (D.column (D.nonNullable D.int8)))
