-- | PostgreSQL interpreter for the 'AuthUnitOfWork' port: each operation is exactly one
-- @BEGIN … COMMIT@.
--
-- This module uses 'Shomei.Persistence.Database.Postgres.runTransaction' for workflow write
-- tails. 'Shomei.Session.LoginAttempt.Postgres' also owns one transaction because its
-- transaction-scoped advisory lock must enclose the corresponding insert and count; that is a
-- serialized store operation rather than a workflow tail. Other interpreters issue one statement
-- per 'Shomei.Persistence.Database.Postgres.runSession', which is one pool checkout per statement.
--
-- Ordinary write tails reuse the prepared statements owned by each store; recovery and
-- bulk revocation own their coordinated statements here. Each is lifted with 'Tx.statement'. This matters most
-- for 'markUsedStmt', the refresh-token compare-and-swap whose shape is owned by
-- @docs/plans/28-enforce-absolute-session-expiry-and-atomic-token-state-transitions.md@: this
-- module moves it inside a transaction and reads its result, but never alters it.
module Shomei.Session.UnitOfWork.Postgres
  ( runAuthUnitOfWorkPostgres,
  )
where

import Contravariant.Extras (contrazip3)
import Data.Aeson (Value, object)
import Data.Aeson qualified as Aeson
import Data.Either (isRight)
import Data.Foldable (traverse_)
import Data.Functor.Contravariant (contramap)
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.UUID (UUID)
import Data.UUID.V4 qualified as UUIDv4
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Shomei.Account.Admin.Recovery.Domain
import Shomei.Account.Credential.Postgres (updatePasswordHashStmt)
import Shomei.Account.Email.Domain (parseStoredEmail)
import Shomei.Account.Password.Domain (PasswordHash (..))
import Shomei.Account.PasswordReset.Postgres qualified as PR
import Shomei.Audit.Event.Codec (projectAuthEvent)
import Shomei.Audit.Event.Domain (AuthEvent)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Postgres (AuthEventRow, insertAuthEventStmt)
import Shomei.Authorization.Claims.Domain (Scope (..))
import Shomei.Error (AuthError (..))
import Shomei.Id
  ( RefreshTokenId,
    genRefreshTokenId,
    genSessionId,
    passwordResetTokenIdToUUID,
    refreshTokenIdToUUID,
    sessionIdToUUID,
    userIdFromUUID,
    userIdToUUID,
  )
import Shomei.Persistence.Codec.Postgres (refreshTokenStatusToText, sessionKindToText, sessionStatusToText)
import Shomei.Persistence.Database.Postgres (Database, postgresUnavailable, runTransaction)
import Shomei.Persistence.Transaction.Postgres qualified as Tx
import Shomei.Prelude
import Shomei.Session.Authentication.Guard (AuthenticationGuard (..))
import Shomei.Session.Authentication.Guard.Postgres (checkAuthentication, lockAuthenticationUser)
import Shomei.Session.Domain (NewSession (..), Session (..), SessionStatus (SessionActive))
import Shomei.Session.Postgres
  ( SessionRow,
    insertSessionStmt,
    mkSession,
    revokeAllUserSessionsSql,
    revokeAllUserSessionsStmt,
    revokeSessionStmt,
  )
import Shomei.Session.RefreshToken.Domain (NewRefreshToken (..))
import Shomei.Session.RefreshToken.Domain qualified as RT
import Shomei.Session.RefreshToken.Postgres
  ( RefreshTokenRow,
    insertRefreshTokenStmt,
    markUsedStmt,
    mkPersisted,
    refreshTokenHashText,
  )
import Shomei.Session.RefreshToken.Postgres qualified as RTP
import Shomei.Session.UnitOfWork.Store (AuthUnitOfWork (..), NewSessionToken (..), RotationOutcome (..))

runAuthUnitOfWorkPostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (AuthUnitOfWork : es) a ->
  Eff es a
runAuthUnitOfWorkPostgres = interpret_ \case
  PersistNewSession guard ns nst mkEvents -> do
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
      checked <- checkAuthentication ns.userId guard ns.createdAt
      case checked of
        Left err -> pure (Left err)
        Right () -> do
          Tx.statement (sessionRow session) insertSessionStmt
          Tx.statement (tokenRow rid newToken) insertRefreshTokenStmt
          traverse_ (\row -> Tx.statement row insertAuthEventStmt) eventRows
          pure (Right (session, persisted))
    either dbFail pure res
  RotateRefreshToken presentedId usedAt newToken ev -> do
    rid <- genRefreshTokenId
    eventRow <- toEventRow ev
    let persisted = mkPersisted rid newToken
    res <- runTransaction do
      -- The compare-and-swap runs first and its result decides the rest. A conflict leaves the
      -- transaction with nothing but a no-op UPDATE to commit; there is no need to abort it,
      -- and nothing to roll back.
      -- Resolve without a row lock, then always acquire user before session/token.
      owner <- Tx.statement (sessionIdToUUID newToken.sessionId) sessionOwnerStmt
      live <- case owner of
        Nothing -> pure False
        Just uid -> do
          locked <- lockAuthenticationUser (userIdFromUUID uid)
          case locked of
            Just ("active", generation) -> do
              checked <- checkAuthentication (userIdFromUUID uid) (AuthenticationGuard generation (Just newToken.sessionId) Nothing) usedAt
              pure (isRight checked)
            _ -> pure False
      won <- if live then Tx.statement (refreshTokenIdToUUID presentedId, usedAt) markUsedStmt else pure Nothing
      case (live, won) of
        (False, _) -> pure RotationInvalid
        (True, Nothing) -> pure RotationConflict
        (True, Just _) -> do
          Tx.statement (tokenRow rid newToken) insertRefreshTokenStmt
          Tx.statement eventRow insertAuthEventStmt
          pure (Rotated persisted)
    either dbFail pure res
  CompletePasswordReset tid uid newHash ts events -> do
    eventRows <- traverse toEventRow events
    res <- runTransaction do
      _ <- lockAuthenticationUser uid
      won <- Tx.statement (passwordResetTokenIdToUUID tid, ts) PR.markConsumedStmt
      case won of
        Nothing -> pure False
        Just _ -> do
          Tx.statement (userIdToUUID uid, passwordHashText newHash, ts) updatePasswordHashStmt
          _ <- Tx.statement (userIdToUUID uid, ts) revokeAllUserSessionsStmt
          Tx.statement (userIdToUUID uid, ts) RTP.revokeUserTokensStmt
          -- The consumed token is no longer active, so this revokes only its live siblings.
          Tx.statement (userIdToUUID uid, ts) PR.revokeUserTokensStmt
          True <$ traverse_ (\row -> Tx.statement row insertAuthEventStmt) eventRows
    either dbFail pure res
  CompletePasswordChange uid newHash ts events -> do
    eventRows <- traverse toEventRow events
    res <- runTransaction do
      _ <- lockAuthenticationUser uid
      Tx.statement (userIdToUUID uid, passwordHashText newHash, ts) updatePasswordHashStmt
      _ <- Tx.statement (userIdToUUID uid, ts) revokeAllUserSessionsStmt
      Tx.statement (userIdToUUID uid, ts) RTP.revokeUserTokensStmt
      traverse_ (\row -> Tx.statement row insertAuthEventStmt) eventRows
    either dbFail pure res
  ResetUserSecondFactors actor uid cmd ts -> do
    eid <- liftIO UUIDv4.nextRandom
    let revocationPayload = object ["revokedBy" Aeson..= recoveryActorUser actor, "recoveryActor" Aeson..= actor, "occurredAt" Aeson..= ts]
    res <- runTransaction do
      user <- lockAuthenticationUser uid
      case user of
        Nothing -> pure (Left UserNotFound)
        Just (status, _) | status /= "active" -> pure (Left InvalidUserStatus)
        Just _ -> do
          Tx.statement (userIdToUUID uid) advanceGenerationStmt
          pk <- Tx.statement (userIdToUUID uid) (deleteCountStmt "shomei_webauthn_credentials")
          totp <- Tx.statement (userIdToUUID uid) (deleteCountStmt "shomei_totp_credentials")
          codes <- Tx.statement (userIdToUUID uid) (deleteCountStmt "shomei_recovery_codes")
          ceremonies <- Tx.statement (userIdToUUID uid) (deleteCountStmt "shomei_webauthn_pending_ceremonies")
          -- Count tokens before the session CTE transitions them.
          tokens <- Tx.statement (userIdToUUID uid) activeUserTokenCountStmt
          sessions <- Tx.statement (userIdToUUID uid, ts, revocationPayload) revokeUserSessionsWithAuditStmt
          -- Also retire tokens belonging to already expired/revoked sessions.
          Tx.statement (userIdToUUID uid, ts) RTP.revokeUserTokensStmt
          authCodes <- Tx.statement (userIdToUUID uid) (deleteCountStmt "shomei_oauth_authorization_codes")
          resetTokens <- Tx.statement (userIdToUUID uid, ts) revokeResetCountStmt
          storedDestination <- Tx.statement (userIdToUUID uid) verifiedDestinationStmt
          let destination = storedDestination >>= either (const Nothing) Just . parseStoredEmail
          let counts = RecoveryCounts pk totp codes ceremonies (fromIntegral sessions) tokens authCodes resetTokens
              ev = Event.UserSecondFactorsReset (Event.UserSecondFactorsResetData uid actor cmd.caseReference counts ts)
              (mu, ms, et, payload, occurred) = projectAuthEvent ev
          Tx.statement (eid, mu, ms, et, payload, occurred) insertAuthEventStmt
          pure (Right (RecoveryResult ts counts (isJust destination), destination))
    either dbFail pure res
  RevokeUserSessionsWithAudit actor uid ts -> do
    let payload = object ["revokedBy" Aeson..= actor, "occurredAt" Aeson..= ts]
    res <- runTransaction (Tx.statement (userIdToUUID uid, ts, payload) revokeUserSessionsWithAuditStmt)
    either dbFail (pure . fromIntegral) res
  RevokeSessionWithTokens sid ts events -> do
    eventRows <- traverse toEventRow events
    res <- runTransaction do
      won <- Tx.statement (sessionIdToUUID sid, ts) revokeSessionStmt
      case won of
        Nothing -> pure False
        Just _ -> do
          Tx.statement (sessionIdToUUID sid, ts) RTP.revokeSessionTokensStmt
          True <$ traverse_ (\row -> Tx.statement row insertAuthEventStmt) eventRows
    either dbFail pure res
  where
    dbFail = throwError . postgresUnavailable

passwordHashText :: PasswordHash -> Text
passwordHashText (PasswordHash t) = t

-- | Mint the event's row id outside the transaction (it is a random UUID, not a database
-- default), and project the event exactly as 'Shomei.Audit.Publisher.Postgres' does.
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
    userIdToUUID <$> session.actor,
    session.oauthClientId,
    Just (sessionKindToText session.kind),
    [scope | Scope scope <- Set.toList session.grantedScopes],
    Just session.authenticatedAt,
    session.remembered
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

-- Winners and audit payloads remain inside PostgreSQL: the application receives one count.
-- A bulk revocation's event UUID is the unique session UUID; each session has at most one
-- active→revoked winner. All other event writers allocate UUIDv4 keys independently.
revokeUserSessionsWithAuditStmt :: Statement (UUID, UTCTime, Value) Int64
revokeUserSessionsWithAuditStmt =
  preparable
    ( "WITH winners AS ("
        <> revokeAllUserSessionsSql
        <> """
           ), tokens AS (
             UPDATE shomei.shomei_refresh_tokens SET status = 'revoked', revoked_at = $2
             WHERE session_id IN (SELECT session_id FROM winners) AND status <> 'revoked'
           ), events AS (
             INSERT INTO shomei.shomei_auth_events(event_id, user_id, session_id, event_type, payload, created_at)
             SELECT session_id, NULL, session_id, 'session_revoked',
               $3::jsonb || jsonb_build_object('sessionId', session_id::text), $2 FROM winners
             RETURNING event_id
           ) SELECT count(*) FROM events
           """
    )
    (contrazip3 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)) (E.param (E.nonNullable E.jsonb)))
    (D.singleRow (D.column (D.nonNullable D.int8)))

advanceGenerationStmt :: Statement UUID ()
advanceGenerationStmt =
  preparable
    "UPDATE shomei.shomei_users SET authentication_generation = authentication_generation + 1 WHERE user_id = $1"
    (E.param (E.nonNullable E.uuid))
    D.noResult

-- Table names are closed literals owned by this module, never request input.
deleteCountStmt :: Text -> Statement UUID Int
deleteCountStmt table =
  preparable
    ("WITH removed AS (DELETE FROM shomei." <> table <> " WHERE user_id = $1 RETURNING 1) SELECT count(*) FROM removed")
    (E.param (E.nonNullable E.uuid))
    (fromIntegral <$> D.singleRow (D.column (D.nonNullable D.int8)))

activeUserTokenCountStmt :: Statement UUID Int
activeUserTokenCountStmt =
  preparable
    "SELECT count(*) FROM shomei.shomei_refresh_tokens WHERE session_id IN (SELECT session_id FROM shomei.shomei_sessions WHERE user_id = $1) AND status <> 'revoked'"
    (E.param (E.nonNullable E.uuid))
    (fromIntegral <$> D.singleRow (D.column (D.nonNullable D.int8)))

revokeResetCountStmt :: Statement (UUID, UTCTime) Int
revokeResetCountStmt =
  preparable
    "WITH revoked AS (UPDATE shomei.shomei_password_reset_tokens SET status = 'revoked', revoked_at = $2 WHERE user_id = $1 AND status = 'active' RETURNING 1) SELECT count(*) FROM revoked"
    (contramap fst (E.param (E.nonNullable E.uuid)) <> contramap snd (E.param (E.nonNullable E.timestamptz)))
    (fromIntegral <$> D.singleRow (D.column (D.nonNullable D.int8)))

verifiedDestinationStmt :: Statement UUID (Maybe Text)
verifiedDestinationStmt =
  preparable
    "SELECT CASE WHEN email_verified_at IS NOT NULL THEN email ELSE NULL END FROM shomei.shomei_users WHERE user_id = $1"
    (E.param (E.nonNullable E.uuid))
    (D.singleRow (D.column (D.nullable D.text)))

sessionOwnerStmt :: Statement UUID (Maybe UUID)
sessionOwnerStmt =
  preparable
    "SELECT user_id FROM shomei.shomei_sessions WHERE session_id = $1"
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe (D.column (D.nonNullable D.uuid)))
