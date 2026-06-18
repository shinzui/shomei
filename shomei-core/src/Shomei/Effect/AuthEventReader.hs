{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The audit-event *reader* port: the read counterpart to
-- 'Shomei.Effect.AuthEventPublisher'. It exposes filtered, keyset-paginated reads over the
-- append-only @shomei_auth_events@ table. The PostgreSQL interpreter lives in
-- @Shomei.Postgres.AuthEventReader@.
--
-- A 'StoredAuthEvent' carries the raw @storedPayload :: Value@ rather than a reconstructed
-- 'Shomei.Domain.Event.AuthEvent'; reconstruction is the caller's choice via
-- 'Shomei.Domain.EventCodec.reconstructAuthEvent'. This keeps the storage read decoupled from
-- the JSON shape: an unrecognized future @event_type@ still lists (with its raw payload)
-- instead of breaking the whole query.
module Shomei.Effect.AuthEventReader
  ( AuthEventReader (..),
    AuditEventQuery (..),
    AuditCursor (..),
    StoredAuthEvent (..),
    emptyAuditQuery,
    maxAuditLimit,
    clampLimit,
    queryAuthEvents,
    countAuthEvents,
  )
where

import Data.Aeson (Value)
import Data.UUID (UUID)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Prelude

-- | A keyset-pagination cursor: the @(created_at, event_id)@ of the last row seen.
data AuditCursor = AuditCursor
  { cursorCreatedAt :: !UTCTime,
    cursorEventId :: !UUID
  }
  deriving stock (Eq, Show)

-- | Filters for an audit-event query. An empty 'queryEventTypes' means "all types".
data AuditEventQuery = AuditEventQuery
  { queryUserId :: !(Maybe UUID),
    querySessionId :: !(Maybe UUID),
    queryEventTypes :: ![Text],
    -- | inclusive lower bound on created_at
    querySince :: !(Maybe UTCTime),
    -- | exclusive upper bound on created_at
    queryUntil :: !(Maybe UTCTime),
    -- | clamp with 'clampLimit' before use
    queryLimit :: !Int,
    queryBefore :: !(Maybe AuditCursor)
  }
  deriving stock (Eq, Show)

-- | One row of the audit trail: the envelope columns plus the raw event payload.
data StoredAuthEvent = StoredAuthEvent
  { storedEventId :: !UUID,
    storedEventType :: !Text,
    storedUserId :: !(Maybe UUID),
    storedSessionId :: !(Maybe UUID),
    storedCreatedAt :: !UTCTime,
    storedPayload :: !Value
  }
  deriving stock (Eq, Show)

emptyAuditQuery :: AuditEventQuery
emptyAuditQuery = AuditEventQuery Nothing Nothing [] Nothing Nothing 50 Nothing

maxAuditLimit :: Int
maxAuditLimit = 1000

-- | Clamp a requested limit into @[1, maxAuditLimit]@. Both surfaces share this clamp.
clampLimit :: Int -> Int
clampLimit n = max 1 (min maxAuditLimit n)

data AuthEventReader :: Effect where
  QueryAuthEvents :: AuditEventQuery -> AuthEventReader m [StoredAuthEvent]
  CountAuthEvents :: AuditEventQuery -> AuthEventReader m Int

type instance DispatchOf AuthEventReader = Dynamic

queryAuthEvents :: (AuthEventReader :> es) => AuditEventQuery -> Eff es [StoredAuthEvent]
queryAuthEvents = send . QueryAuthEvents

countAuthEvents :: (AuthEventReader :> es) => AuditEventQuery -> Eff es Int
countAuthEvents = send . CountAuthEvents
