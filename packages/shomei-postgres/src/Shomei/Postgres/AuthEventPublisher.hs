{- | PostgreSQL interpreter for the 'AuthEventPublisher' port. Each 'AuthEvent' arm is
projected to (user_id?, session_id?, event_type, JSON payload, occurredAt) and inserted
into @shomei_auth_events@.
-}
module Shomei.Postgres.AuthEventPublisher (
    runAuthEventPublisherPostgres,
) where

import Shomei.Prelude

import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import "aeson" Data.Aeson (Value)
import "contravariant-extras" Contravariant.Extras (contrazip6)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.Event (AuthEvent)
import Shomei.Domain.Event qualified as Event
import Shomei.Error (AuthError (..))
import Shomei.Id (sessionIdToUUID, userIdToUUID)
import Shomei.Port.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)

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

projectAuthEvent :: AuthEvent -> (Maybe UUID, Maybe UUID, Text, Value, UTCTime)
projectAuthEvent = \case
    Event.UserRegistered d@(Event.UserRegisteredData uid _ occ) ->
        (Just (userIdToUUID uid), Nothing, "user_registered", toJSON d, occ)
    Event.LoginSucceeded d@(Event.LoginSucceededData uid sid occ) ->
        (Just (userIdToUUID uid), Just (sessionIdToUUID sid), "login_succeeded", toJSON d, occ)
    Event.LoginFailed d@(Event.LoginFailedData _ occ) ->
        (Nothing, Nothing, "login_failed", toJSON d, occ)
    Event.SessionStarted d@(Event.SessionStartedData sid uid occ) ->
        (Just (userIdToUUID uid), Just (sessionIdToUUID sid), "session_started", toJSON d, occ)
    Event.SessionRevoked d@(Event.SessionRevokedData sid occ) ->
        (Nothing, Just (sessionIdToUUID sid), "session_revoked", toJSON d, occ)
    Event.RefreshTokenRotated d@(Event.RefreshTokenRotatedData sid _ occ) ->
        (Nothing, Just (sessionIdToUUID sid), "refresh_token_rotated", toJSON d, occ)
    Event.RefreshTokenReuseDetected d@(Event.RefreshTokenReuseDetectedData sid _ occ) ->
        (Nothing, Just (sessionIdToUUID sid), "refresh_token_reuse_detected", toJSON d, occ)
    Event.PasswordChanged d@(Event.PasswordChangedData uid occ) ->
        (Just (userIdToUUID uid), Nothing, "password_changed", toJSON d, occ)
    Event.UserSuspended d@(Event.UserSuspendedData uid occ) ->
        (Just (userIdToUUID uid), Nothing, "user_suspended", toJSON d, occ)
    Event.UserDeleted d@(Event.UserDeletedData uid occ) ->
        (Just (userIdToUUID uid), Nothing, "user_deleted", toJSON d, occ)

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
