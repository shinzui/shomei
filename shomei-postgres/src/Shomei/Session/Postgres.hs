-- | PostgreSQL interpreter for the 'SessionStore' port.
module Shomei.Session.Postgres
  ( runSessionStorePostgres,

    -- * Statements shared with the unit-of-work interpreter

    -- | Exported so @Shomei.Session.UnitOfWork.Postgres@ can lift them into a transaction with
    --     @Hasql.Transaction.statement@ instead of restating the SQL. Keep them here: two
    --     copies of an INSERT drift, and the columns are the interpreter's business, not the
    --     transaction's.
    SessionRow,
    insertSessionStmt,
    mkSession,
    revokeSessionStmt,
    revokeAllUserSessionsStmt,
    revokeAllUserSessionsSql,
  )
where

import Contravariant.Extras (contrazip12, contrazip2, contrazip3, contrazip4)
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Authorization.Claims.Domain (Scope (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, genSessionId, sessionIdFromUUID, sessionIdToUUID, userIdFromUUID, userIdToUUID)
import Shomei.Persistence.Codec.Postgres (sessionKindFromText, sessionKindToText, sessionStatusFromText, sessionStatusToText)
import Shomei.Persistence.Database.Postgres (Database, postgresUnavailable, runSession, runTransaction)
import Shomei.Persistence.Transaction.Postgres qualified as Tx
import Shomei.Prelude
import Shomei.Session.Domain (NewSession (..), Session (..), SessionStatus (SessionActive))
import Shomei.Session.Store (SessionCursor (..), SessionListQuery (..), SessionStore (..), clampSessionLimit)

type SessionRow = (UUID, UUID, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UUID, Maybe Text, Maybe Text, [Text], Maybe UTCTime, Bool)

runSessionStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (SessionStore : es) a ->
  Eff es a
runSessionStorePostgres = interpret_ \case
  CreateSession ns -> do
    sid <- genSessionId
    let session = mkSession sid ns
        row = sessionToRow session
    res <- runSession (Session.statement row insertSessionStmt)
    either dbFail (const (pure session)) res
  CreateSessionWithinLimit cap ns -> do
    sid <- genSessionId
    let session = mkSession sid ns
        principals = Set.toAscList (Set.fromList (ns.userId : maybe [] pure ns.actor))
    res <- runTransaction do
      -- UUID ordering prevents two overlapping actor/subject pairs from deadlocking.
      locked <- Tx.statement (map userIdToUUID principals) lockPrincipalsStmt
      if length locked /= length principals
        then pure (Left UserNotFound)
        else do
          counts <- forM principals \principal -> Tx.statement (userIdToUUID principal, ns.createdAt, fromIntegral cap) activePrincipalSessionsStmt
          if any (>= fromIntegral cap) counts
            then pure (Left SessionLimitReached)
            else Right session <$ Tx.statement (sessionToRow session) insertSessionStmt
    either dbFail pure res
  FindSessionById sid -> do
    res <- runSession (Session.statement (sessionIdToUUID sid) findSessionByIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  RevokeSession sid t -> do
    res <- runSession (Session.statement (sessionIdToUUID sid, t) revokeSessionStmt)
    either dbFail (const (pure ())) res
  RevokeAllUserSessions uid t -> do
    res <- runSession (Session.statement (userIdToUUID uid, t) revokeAllUserSessionsStmt)
    either dbFail (pure . map sessionIdFromUUID) res
  ListSessionPage uid query -> do
    let params = (userIdToUUID uid, (.cursorCreatedAt) <$> query.queryBefore, sessionIdToUUID . (.cursorSessionId) <$> query.queryBefore, fromIntegral (clampSessionLimit query.queryLimit))
    res <- runSession (Session.statement params listSessionPageStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  ListSessionsForUser uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) listSessionsForUserStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  where
    dbFail = throwError . postgresUnavailable
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
      actor = ns.actor,
      oauthClientId = ns.oauthClientId,
      kind = ns.kind,
      grantedScopes = ns.grantedScopes,
      authenticatedAt = ns.authenticatedAt,
      remembered = ns.remembered
    }

rebuildSession :: SessionRow -> Either Text Session
rebuildSession (sid, uid, st, c, e, r, act, oauthClientId, mKind, scopeTexts, mAuthenticatedAt, remembered) = do
  status <- sessionStatusFromText st
  kind <- maybe (Left "session kind is missing") sessionKindFromText mKind
  pure
    Session
      { sessionId = sessionIdFromUUID sid,
        userId = userIdFromUUID uid,
        status = status,
        createdAt = c,
        expiresAt = e,
        revokedAt = r,
        actor = userIdFromUUID <$> act,
        oauthClientId,
        kind,
        grantedScopes = Set.fromList (map Scope scopeTexts),
        authenticatedAt = fromMaybe c mAuthenticatedAt,
        remembered
      }

sessionRowDecoder :: D.Row SessionRow
sessionRowDecoder =
  (,,,,,,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.uuid)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable (D.listArray (D.nonNullable D.text)))
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nonNullable D.bool)

insertSessionStmt :: Statement SessionRow ()
insertSessionStmt =
  preparable
    """
    INSERT INTO shomei.shomei_sessions
      (session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id, oauth_client_id, kind, granted_scopes, authenticated_at, remembered)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
    """
    ( contrazip12
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.uuid))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nonNullable E.bool))
    )
    D.noResult

-- | Every session of one user, newest first, in every status. Unpaginated by design (see the
-- port's haddock); @shomei_sessions@ already indexes @user_id@, so this is one index scan.
listSessionsForUserStmt :: Statement UUID [SessionRow]
listSessionsForUserStmt =
  preparable
    """
    SELECT session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id, oauth_client_id, kind, granted_scopes, authenticated_at, remembered
    FROM shomei.shomei_sessions
    WHERE user_id = $1
    ORDER BY created_at DESC, session_id DESC
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowList sessionRowDecoder)

findSessionByIdStmt :: Statement UUID (Maybe SessionRow)
findSessionByIdStmt =
  preparable
    """
    SELECT session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id, oauth_client_id, kind, granted_scopes, authenticated_at, remembered
    FROM shomei.shomei_sessions
    WHERE session_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe sessionRowDecoder)

revokeSessionStmt :: Statement (UUID, UTCTime) (Maybe UUID)
revokeSessionStmt =
  preparable
    """
    UPDATE shomei.shomei_sessions
    SET status = 'revoked', revoked_at = $2
    WHERE session_id = $1
      AND status = 'active'
    RETURNING session_id
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    (D.rowMaybe (D.column (D.nonNullable D.uuid)))

revokeAllUserSessionsStmt :: Statement (UUID, UTCTime) [UUID]
revokeAllUserSessionsStmt =
  preparable
    revokeAllUserSessionsSql
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    (D.rowList (D.column (D.nonNullable D.uuid)))

-- | Shared winner-producing update, also embedded in the bulk audited CTE. No application
-- materialization of winners is needed by that operation.
revokeAllUserSessionsSql :: Text
revokeAllUserSessionsSql =
  """
  UPDATE shomei.shomei_sessions SET status = 'revoked', revoked_at = $2
  WHERE user_id = $1 AND status = 'active'
  RETURNING session_id
  """

listSessionPageStmt :: Statement (UUID, Maybe UTCTime, Maybe UUID, Int64) [SessionRow]
listSessionPageStmt =
  preparable
    """
    SELECT session_id, user_id, status, created_at, expires_at, revoked_at, actor_user_id, oauth_client_id, kind, granted_scopes, authenticated_at, remembered
    FROM shomei.shomei_sessions
    WHERE user_id = $1 AND ($2::timestamptz IS NULL OR (created_at, session_id) < ($2,$3))
    ORDER BY created_at DESC, session_id DESC LIMIT $4
    """
    ( contrazip4
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.uuid))
        (E.param (E.nonNullable E.int8))
    )
    (D.rowList sessionRowDecoder)

sessionToRow :: Session -> SessionRow
sessionToRow session =
  ( sessionIdToUUID session.sessionId,
    userIdToUUID session.userId,
    sessionStatusToText session.status,
    session.createdAt,
    session.expiresAt,
    session.revokedAt,
    userIdToUUID <$> session.actor,
    session.oauthClientId,
    Just (sessionKindToText session.kind),
    [scope | Scope scope <- Set.toList session.grantedScopes],
    Just session.authenticatedAt,
    session.remembered
  )

lockPrincipalsStmt :: Statement [UUID] [UUID]
lockPrincipalsStmt =
  preparable
    "SELECT user_id FROM shomei.shomei_users WHERE user_id = ANY($1) ORDER BY user_id FOR UPDATE"
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
    (D.rowList (D.column (D.nonNullable D.uuid)))

activePrincipalSessionsStmt :: Statement (UUID, UTCTime, Int64) Int64
activePrincipalSessionsStmt =
  preparable
    """
    SELECT count(*) FROM (
      SELECT 1 FROM shomei.shomei_sessions
      WHERE (user_id=$1 OR actor_user_id=$1) AND status='active'
        AND kind IN ('machine','delegated') AND expires_at > $2
      LIMIT $3
    ) AS active
    """
    (contrazip3 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)) (E.param (E.nonNullable E.int8)))
    (D.singleRow (D.column (D.nonNullable D.int8)))
