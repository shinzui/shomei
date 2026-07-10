{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The session-store port: persisting, looking up, and revoking sessions.
module Shomei.Effect.SessionStore
  ( SessionStore (..),
    createSession,
    findSessionById,
    revokeSession,
    revokeAllUserSessions,
    listSessionsForUser,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Session (NewSession, Session)
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude

data SessionStore :: Effect where
  CreateSession :: NewSession -> SessionStore m Session
  FindSessionById :: SessionId -> SessionStore m (Maybe Session)
  RevokeSession :: SessionId -> UTCTime -> SessionStore m ()
  RevokeAllUserSessions :: UserId -> UTCTime -> SessionStore m ()
  -- | Every session ever created for a user, newest first, in every status. Unpaginated:
  -- sessions per user are bounded small in practice (roughly one per device), unlike users
  -- per deployment.
  ListSessionsForUser :: UserId -> SessionStore m [Session]

type instance DispatchOf SessionStore = Dynamic

createSession :: (SessionStore :> es) => NewSession -> Eff es Session
createSession = send . CreateSession

findSessionById :: (SessionStore :> es) => SessionId -> Eff es (Maybe Session)
findSessionById = send . FindSessionById

revokeSession :: (SessionStore :> es) => SessionId -> UTCTime -> Eff es ()
revokeSession sid t = send (RevokeSession sid t)

revokeAllUserSessions :: (SessionStore :> es) => UserId -> UTCTime -> Eff es ()
revokeAllUserSessions uid t = send (RevokeAllUserSessions uid t)

listSessionsForUser :: (SessionStore :> es) => UserId -> Eff es [Session]
listSessionsForUser = send . ListSessionsForUser
