-- | PostgreSQL interpreter for the 'AuthUnitOfWork' port: each operation is exactly one
-- @BEGIN … COMMIT@.
--
-- This is the only module in @shomei-postgres@ that uses
-- 'Shomei.Postgres.Database.runTransaction'; every other interpreter issues one statement per
-- 'Shomei.Postgres.Database.runSession', which is one pool checkout per statement. Here the
-- statements of a workflow's write tail are composed into a single @hasql-transaction@
-- 'Transaction' and run in one checkout, so they are both atomic and cheap.
--
-- No SQL is written here. Every statement is the prepared 'Statement' its own store
-- interpreter already uses, lifted into the transaction with 'Tx.statement'. That matters most
-- for 'markUsedStmt', the refresh-token compare-and-swap whose shape is owned by
-- @docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md@: this
-- module moves it inside a transaction and reads its result, but never alters it.
module Shomei.Postgres.AuthUnitOfWork
  ( runAuthUnitOfWorkPostgres,
  )
where

import Data.Foldable (traverse_)
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Transaction qualified as Tx
import Shomei.Domain.Event (AuthEvent)
import Shomei.Domain.EventCodec (projectAuthEvent)
import Shomei.Domain.RefreshToken (NewRefreshToken (..))
import Shomei.Domain.RefreshToken qualified as RT
import Shomei.Domain.Session (Session (..), SessionStatus (SessionActive))
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork (..), NewSessionToken (..), RotationOutcome (..))
import Shomei.Error (AuthError (..))
import Shomei.Id
  ( RefreshTokenId,
    genRefreshTokenId,
    genSessionId,
    refreshTokenIdToUUID,
    sessionIdToUUID,
    userIdToUUID,
  )
import Shomei.Postgres.AuthEventPublisher (AuthEventRow, insertAuthEventStmt)
import Shomei.Postgres.Codec (refreshTokenStatusToText, sessionStatusToText, tshow)
import Shomei.Postgres.Database (Database, runTransaction)
import Shomei.Postgres.RefreshTokenStore
  ( RefreshTokenRow,
    insertRefreshTokenStmt,
    markUsedStmt,
    mkPersisted,
    refreshTokenHashText,
  )
import Shomei.Postgres.SessionStore (SessionRow, insertSessionStmt, mkSession)
import Shomei.Prelude

runAuthUnitOfWorkPostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (AuthUnitOfWork : es) a ->
  Eff es a
runAuthUnitOfWorkPostgres = interpret_ \case
  PersistNewSession ns nst mkEvents -> do
    -- The ids are generated here, before the transaction opens, exactly as the per-table
    -- interpreters generate them: they are client-side (TypeID/UUIDv7-style) values, so no
    -- round-trip is needed and the events can name the session id.
    sid <- genSessionId
    rid <- genRefreshTokenId
    let session = mkSession sid ns
        newToken =
          NewRefreshToken
            { sessionId = sid,
              tokenHash = nst.tokenHash,
              parentTokenId = Nothing,
              createdAt = nst.createdAt,
              expiresAt = nst.expiresAt
            }
        persisted = mkPersisted rid newToken
    eventRows <- traverse toEventRow (mkEvents sid)
    res <- runTransaction do
      Tx.statement (sessionRow session) insertSessionStmt
      Tx.statement (tokenRow rid newToken) insertRefreshTokenStmt
      traverse_ (\row -> Tx.statement row insertAuthEventStmt) eventRows
    either dbFail (const (pure (session, persisted))) res
  RotateRefreshToken presentedId usedAt newToken ev -> do
    rid <- genRefreshTokenId
    eventRow <- toEventRow ev
    let persisted = mkPersisted rid newToken
    res <- runTransaction do
      -- The compare-and-swap runs first and its result decides the rest. A conflict leaves the
      -- transaction with nothing but a no-op UPDATE to commit; there is no need to abort it,
      -- and nothing to roll back.
      won <- Tx.statement (refreshTokenIdToUUID presentedId, usedAt) markUsedStmt
      case won of
        Nothing -> pure RotationConflict
        Just _ -> do
          Tx.statement (tokenRow rid newToken) insertRefreshTokenStmt
          Tx.statement eventRow insertAuthEventStmt
          pure (Rotated persisted)
    either dbFail pure res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))

-- | Mint the event's row id outside the transaction (it is a random UUID, not a database
-- default), and project the event exactly as 'Shomei.Postgres.AuthEventPublisher' does.
toEventRow :: (IOE :> es) => AuthEvent -> Eff es AuthEventRow
toEventRow ev = do
  eid <- liftIO UUIDv4.nextRandom
  let (mUser, mSession, etype, payload, ts) = projectAuthEvent ev
  pure (eid, mUser, mSession, etype, payload, ts)

-- | The column tuple 'insertSessionStmt' encodes, built from the session this interpreter just
-- constructed. A fresh session is always active and never revoked.
sessionRow :: Session -> SessionRow
sessionRow session =
  ( sessionIdToUUID session.sessionId,
    userIdToUUID session.userId,
    sessionStatusToText SessionActive,
    session.createdAt,
    session.expiresAt,
    Nothing,
    userIdToUUID <$> session.actor
  )

-- | The column tuple 'insertRefreshTokenStmt' encodes. A freshly inserted token is always
-- active, never used, never revoked.
tokenRow :: RefreshTokenId -> NewRefreshToken -> RefreshTokenRow
tokenRow rid nrt =
  ( refreshTokenIdToUUID rid,
    sessionIdToUUID nrt.sessionId,
    refreshTokenHashText nrt.tokenHash,
    fmap refreshTokenIdToUUID nrt.parentTokenId,
    refreshTokenStatusToText RT.RefreshTokenActive,
    nrt.createdAt,
    nrt.expiresAt,
    Nothing,
    Nothing
  )
