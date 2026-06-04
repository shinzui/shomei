{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The session-store port: persisting, looking up, and revoking sessions.
module Shomei.Port.SessionStore (
    SessionStore (..),
    createSession,
    findSessionById,
    revokeSession,
    revokeAllUserSessions,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Session (NewSession, Session)
import Shomei.Id (SessionId, UserId)

data SessionStore :: Effect where
    CreateSession :: NewSession -> SessionStore m Session
    FindSessionById :: SessionId -> SessionStore m (Maybe Session)
    RevokeSession :: SessionId -> UTCTime -> SessionStore m ()
    RevokeAllUserSessions :: UserId -> UTCTime -> SessionStore m ()

type instance DispatchOf SessionStore = Dynamic

createSession :: (SessionStore :> es) => NewSession -> Eff es Session
createSession = send . CreateSession

findSessionById :: (SessionStore :> es) => SessionId -> Eff es (Maybe Session)
findSessionById = send . FindSessionById

revokeSession :: (SessionStore :> es) => SessionId -> UTCTime -> Eff es ()
revokeSession sid t = send (RevokeSession sid t)

revokeAllUserSessions :: (SessionStore :> es) => UserId -> UTCTime -> Eff es ()
revokeAllUserSessions uid t = send (RevokeAllUserSessions uid t)
