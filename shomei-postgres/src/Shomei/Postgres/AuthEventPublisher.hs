-- | PostgreSQL interpreter for the 'AuthEventPublisher' port. Each 'AuthEvent' arm is
-- projected to (user_id?, session_id?, event_type, JSON payload, occurredAt) and inserted
-- into @shomei_auth_events@.
module Shomei.Postgres.AuthEventPublisher
  ( runAuthEventPublisherPostgres,
  )
where

import Contravariant.Extras (contrazip6)
import Data.Aeson (Value)
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.EventCodec (projectAuthEvent)
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Error (AuthError (..))
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

type AuthEventRow = (UUID, Maybe UUID, Maybe UUID, Text, Value, UTCTime)

runAuthEventPublisherPostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (AuthEventPublisher : es) a ->
  Eff es a
runAuthEventPublisherPostgres = interpret_ \case
  PublishAuthEvent ev -> do
    eid <- liftIO UUIDv4.nextRandom
    let (mUser, mSession, etype, payload, ts) = projectAuthEvent ev
    res <- runSession (Session.statement (eid, mUser, mSession, etype, payload, ts) insertAuthEventStmt)
    either (\e -> throwError (InternalAuthError ("database error: " <> tshow e))) (const (pure ())) res

insertAuthEventStmt :: Statement AuthEventRow ()
insertAuthEventStmt =
  preparable
    """
    INSERT INTO shomei.shomei_auth_events
      (event_id, user_id, session_id, event_type, payload, created_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    """
    ( contrazip6
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nullable E.uuid))
        (E.param (E.nullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.jsonb))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult
