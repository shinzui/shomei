-- | PostgreSQL interpreter for the 'SessionStore' port.
module Shomei.Postgres.SessionStore
  ( runSessionStorePostgres,

    -- * Statements shared with the unit-of-work interpreter

    -- | Exported so @Shomei.Postgres.AuthUnitOfWork@ can lift them into a transaction with
    --     @Hasql.Transaction.statement@ instead of restating the SQL. Keep them here: two
    --     copies of an INSERT drift, and the columns are the interpreter's business, not the
    --     transaction's.
    SessionRow,
    insertSessionStmt,
    mkSession,
  )
where

import Contravariant.Extras (contrazip2, contrazip7)
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (SessionActive))
import Shomei.Effect.SessionStore (SessionStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, genSessionId, sessionIdFromUUID, sessionIdToUUID, userIdFromUUID, userIdToUUID)
import Shomei.Postgres.Codec (sessionStatusFromText, sessionStatusToText, tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

type SessionRow = (UUID, UUID, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UUID)

runSessionStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (SessionStore : es) a ->
  Eff es a
runSessionStorePostgres = interpret_ \case
  CreateSession ns -> do
    sid <- genSessionId
    let session = mkSession sid ns
        row =
          ( sessionIdToUUID sid,
            userIdToUUID ns.userId,
            sessionStatusToText SessionActive,
            ns.createdAt,
            ns.expiresAt,
            Nothing,
            userIdToUUID <$> ns.actor
          )
    res <- runSession (Session.statement row insertSessionStmt)
    either dbFail (const (pure session)) res
  FindSessionById sid -> do
    res <- runSession (Session.statement (sessionIdToUUID sid) findSessionByIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  RevokeSession sid t -> do
    res <- runSession (Session.statement (sessionIdToUUID sid, t) revokeSessionStmt)
    either dbFail (const (pure ())) res
  RevokeAllUserSessions uid t -> do
    res <- runSession (Session.statement (userIdToUUID uid, t) revokeAllUserSessionsStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildSession r)

mkSession :: SessionId -> NewSession -> Session
mkSession sid ns =
  Session
    { sessionId = sid,
      userId = ns.userId,
      status = SessionActive,
      createdAt = ns.createdAt,
      expiresAt = ns.expiresAt,
      revokedAt = Nothing,
      actor = ns.actor
    }

rebuildSession :: SessionRow -> Either Text Session
rebuildSession (sid, uid, st, c, e, r, act) = do
  status <- sessionStatusFromText st
  pure
    Session
      { sessionId = sessionIdFromUUID sid,
        userId = userIdFromUUID uid,
        status = status,
        createdAt = c,
        expiresAt = e,
        revokedAt = r,
        actor = userIdFromUUID <$> act
      }

sessionRowDecoder :: D.Row SessionRow
sessionRowDecoder =
  (,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.uuid)

insertSessionStmt :: Statement SessionRow ()
insertSessionStmt =
  preparable
    """
    INSERT INTO shomei.shomei_sessions
      (session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    """
    ( contrazip7
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.uuid))
    )
    D.noResult

findSessionByIdStmt :: Statement UUID (Maybe SessionRow)
findSessionByIdStmt =
  preparable
    """
    SELECT session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id
    FROM shomei.shomei_sessions
    WHERE session_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe sessionRowDecoder)

revokeSessionStmt :: Statement (UUID, UTCTime) ()
revokeSessionStmt =
  preparable
    """
    UPDATE shomei.shomei_sessions
    SET status = 'revoked', revoked_at = $2
    WHERE session_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult

revokeAllUserSessionsStmt :: Statement (UUID, UTCTime) ()
revokeAllUserSessionsStmt =
  preparable
    """
    UPDATE shomei.shomei_sessions
    SET status = 'revoked', revoked_at = $2
    WHERE user_id = $1 AND status = 'active'
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult
