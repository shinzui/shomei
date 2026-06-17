{- | PostgreSQL interpreter for the 'AuthEventReader' port: the read counterpart to
'Shomei.Postgres.AuthEventPublisher'. It issues only @SELECT@/@COUNT@ against the
append-only @shomei_auth_events@ table — there is no path here that mutates the audit
trail.

The query is a single parameterized statement that handles every optional filter with the
@($n IS NULL OR col = $n)@ idiom, applies a keyset (seek) predicate on
@(created_at, event_id)@, orders newest-first, and limits. The count uses the same filters
without ordering/limit/cursor.
-}
module Shomei.Postgres.AuthEventReader (
    runAuthEventReaderPostgres,
) where

import Shomei.Prelude

import Data.Functor.Contravariant ((>$<))
import Data.Int (Int64)
import Data.UUID (UUID)

import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Effect.AuthEventReader (
    AuditCursor (..),
    AuditEventQuery (..),
    AuthEventReader (..),
    StoredAuthEvent (..),
    clampLimit,
 )
import Shomei.Error (AuthError (..))
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)

-- Note: unlike 'runAuthEventPublisherPostgres' this interpreter needs no @IOE :> es@
-- constraint — reads go entirely through the @Database@ effect (no @liftIO@). It still
-- slots into any stack that also provides @IOE@.
runAuthEventReaderPostgres ::
    (Database :> es, Error AuthError :> es) =>
    Eff (AuthEventReader : es) a ->
    Eff es a
runAuthEventReaderPostgres = interpret_ \case
    QueryAuthEvents q -> do
        res <- runSession (Session.statement (toQueryParams q) selectStmt)
        either dbErr pure res
    CountAuthEvents q -> do
        res <- runSession (Session.statement (toCountParams q) countStmt)
        either dbErr pure res
  where
    dbErr e = throwError (InternalAuthError ("database error: " <> tshow e))

-- | Parameter bundle for the SELECT (filters, then cursor, then limit).
type QueryParams =
    ( Maybe UUID -- user_id
    , Maybe UUID -- session_id
    , [Text] -- event_type list ([] = all)
    , Maybe UTCTime -- since (>=)
    , Maybe UTCTime -- until (<)
    , Maybe UTCTime -- before cursor created_at
    , Maybe UUID -- before cursor event_id
    , Int64 -- limit
    )

-- | Parameter bundle for the COUNT: the same filters, no cursor/limit.
type CountParams =
    (Maybe UUID, Maybe UUID, [Text], Maybe UTCTime, Maybe UTCTime)

toQueryParams :: AuditEventQuery -> QueryParams
toQueryParams q =
    ( queryUserId q
    , querySessionId q
    , queryEventTypes q
    , querySince q
    , queryUntil q
    , beforeTs
    , beforeId
    , fromIntegral (clampLimit (queryLimit q))
    )
  where
    (beforeTs, beforeId) = case queryBefore q of
        Nothing -> (Nothing, Nothing)
        Just (AuditCursor t e) -> (Just t, Just e)

toCountParams :: AuditEventQuery -> CountParams
toCountParams q =
    (queryUserId q, querySessionId q, queryEventTypes q, querySince q, queryUntil q)

-- | Encode a @text[]@ parameter (for the @event_type = ANY($3)@ filter).
textArray :: E.Value [Text]
textArray = E.foldableArray (E.nonNullable E.text)

queryEncoder :: E.Params QueryParams
queryEncoder =
    ((\(a, _, _, _, _, _, _, _) -> a) >$< E.param (E.nullable E.uuid))
        <> ((\(_, b, _, _, _, _, _, _) -> b) >$< E.param (E.nullable E.uuid))
        <> ((\(_, _, c, _, _, _, _, _) -> c) >$< E.param (E.nonNullable textArray))
        <> ((\(_, _, _, d, _, _, _, _) -> d) >$< E.param (E.nullable E.timestamptz))
        <> ((\(_, _, _, _, e, _, _, _) -> e) >$< E.param (E.nullable E.timestamptz))
        <> ((\(_, _, _, _, _, f, _, _) -> f) >$< E.param (E.nullable E.timestamptz))
        <> ((\(_, _, _, _, _, _, g, _) -> g) >$< E.param (E.nullable E.uuid))
        <> ((\(_, _, _, _, _, _, _, h) -> h) >$< E.param (E.nonNullable E.int8))

countEncoder :: E.Params CountParams
countEncoder =
    ((\(a, _, _, _, _) -> a) >$< E.param (E.nullable E.uuid))
        <> ((\(_, b, _, _, _) -> b) >$< E.param (E.nullable E.uuid))
        <> ((\(_, _, c, _, _) -> c) >$< E.param (E.nonNullable textArray))
        <> ((\(_, _, _, d, _) -> d) >$< E.param (E.nullable E.timestamptz))
        <> ((\(_, _, _, _, e) -> e) >$< E.param (E.nullable E.timestamptz))

{- | Decode a row into a 'StoredAuthEvent'. The SELECT column order is
@event_id, user_id, session_id, event_type, payload, created_at@ but the record field
order differs, so decode positionally (@D.Row@ is 'Applicative', not 'Monad', in this
@hasql@ version) and reassemble the record with 'mk'.
-}
storedRowDecoder :: D.Row StoredAuthEvent
storedRowDecoder =
    mk
        <$> D.column (D.nonNullable D.uuid) -- event_id
        <*> D.column (D.nullable D.uuid) -- user_id
        <*> D.column (D.nullable D.uuid) -- session_id
        <*> D.column (D.nonNullable D.text) -- event_type
        <*> D.column (D.nonNullable D.jsonb) -- payload
        <*> D.column (D.nonNullable D.timestamptz) -- created_at
  where
    mk eid uid sid etype pl cat =
        StoredAuthEvent
            { storedEventId = eid
            , storedEventType = etype
            , storedUserId = uid
            , storedSessionId = sid
            , storedCreatedAt = cat
            , storedPayload = pl
            }

selectStmt :: Statement QueryParams [StoredAuthEvent]
selectStmt =
    preparable
        """
        SELECT event_id, user_id, session_id, event_type, payload, created_at
        FROM shomei.shomei_auth_events
        WHERE ($1::uuid        IS NULL OR user_id    = $1)
          AND ($2::uuid        IS NULL OR session_id = $2)
          AND (cardinality($3::text[]) = 0 OR event_type = ANY($3))
          AND ($4::timestamptz IS NULL OR created_at >= $4)
          AND ($5::timestamptz IS NULL OR created_at <  $5)
          AND ($6::timestamptz IS NULL OR (created_at, event_id) < ($6, $7))
        ORDER BY created_at DESC, event_id DESC
        LIMIT $8
        """
        queryEncoder
        (D.rowList storedRowDecoder)

countStmt :: Statement CountParams Int
countStmt =
    preparable
        """
        SELECT count(*)
        FROM shomei.shomei_auth_events
        WHERE ($1::uuid        IS NULL OR user_id    = $1)
          AND ($2::uuid        IS NULL OR session_id = $2)
          AND (cardinality($3::text[]) = 0 OR event_type = ANY($3))
          AND ($4::timestamptz IS NULL OR created_at >= $4)
          AND ($5::timestamptz IS NULL OR created_at <  $5)
        """
        countEncoder
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int8)))
