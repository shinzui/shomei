{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The session-store port: persisting, looking up, and revoking sessions.
module Shomei.Session.Store
  ( SessionStore (..),
    createSession,
    createSessionWithinLimit,
    findSessionById,
    revokeSession,
    revokeAllUserSessions,
    listSessionsForUser,
    SessionCursor (..),
    SessionListQuery (..),
    emptySessionListQuery,
    clampSessionLimit,
    listSessionPage,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Shomei.Session.Domain (NewSession (..), Session, SessionKind (InteractiveSession))

data SessionStore :: Effect where
  CreateSession :: NewSession -> SessionStore m Session
  CreateSessionWithinLimit :: Int -> NewSession -> SessionStore m (Either AuthError Session)
  FindSessionById :: SessionId -> SessionStore m (Maybe Session)
  RevokeSession :: SessionId -> UTCTime -> SessionStore m ()
  RevokeAllUserSessions :: UserId -> UTCTime -> SessionStore m [SessionId]
  ListSessionPage :: UserId -> SessionListQuery -> SessionStore m [Session]
  -- | Compatibility only: every session, materialized in memory. HTTP must use ListSessionPage.
  ListSessionsForUser :: UserId -> SessionStore m [Session]

type instance DispatchOf SessionStore = Dynamic

createSession :: (SessionStore :> es) => NewSession -> Eff es Session
createSession = send . CreateSession

findSessionById :: (SessionStore :> es) => SessionId -> Eff es (Maybe Session)
findSessionById = send . FindSessionById

revokeSession :: (SessionStore :> es) => SessionId -> UTCTime -> Eff es ()
revokeSession sid t = send (RevokeSession sid t)

revokeAllUserSessions :: (SessionStore :> es) => UserId -> UTCTime -> Eff es [SessionId]
revokeAllUserSessions uid t = send (RevokeAllUserSessions uid t)

listSessionsForUser :: (SessionStore :> es) => UserId -> Eff es [Session]
listSessionsForUser = send . ListSessionsForUser

-- | Stable newest-first keyset over timestamp and unique ID.
data SessionCursor = SessionCursor
  { cursorCreatedAt :: !UTCTime,
    cursorSessionId :: !SessionId
  }
  deriving stock (Eq, Show)

data SessionListQuery = SessionListQuery
  { queryLimit :: !Int,
    queryBefore :: !(Maybe SessionCursor)
  }
  deriving stock (Eq, Show)

emptySessionListQuery :: SessionListQuery
emptySessionListQuery = SessionListQuery 50 Nothing

clampSessionLimit :: Int -> Int
clampSessionLimit = max 1 . min 200

listSessionPage :: (SessionStore :> es) => UserId -> SessionListQuery -> Eff es [Session]
listSessionPage uid query = send (ListSessionPage uid query {queryLimit = clampSessionLimit query.queryLimit})

-- | Each machine/delegated session spends its subject and (when distinct) actor's active
-- budget. Lock both principals in stable order at persistence. Expired sessions spend none.
createSessionWithinLimit :: (SessionStore :> es) => Int -> NewSession -> Eff es (Either AuthError Session)
createSessionWithinLimit cap session
  | cap < 1 || session.kind == InteractiveSession = pure (Left InvalidInput)
  | otherwise = send (CreateSessionWithinLimit cap session)
