-- | PostgreSQL interpreter for the consume-once pending-ceremony store.
module Shomei.Passkey.Ceremony.Postgres
  ( runPendingCeremonyStorePostgres,
  )
where

import Contravariant.Extras (contrazip8)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Error (AuthError (..))
import Shomei.Id (ceremonyIdFromUUID, ceremonyIdToUUID, sessionIdFromUUID, sessionIdToUUID, userIdFromUUID, userIdToUUID)
import Shomei.Passkey.Ceremony.Store (PendingCeremonyStore (..))
import Shomei.Passkey.Domain (CeremonyKind (..), PendingCeremony (..))
import Shomei.Persistence.Database.Postgres (Database, postgresUnavailable, runSession, runTransaction)
import Shomei.Persistence.Transaction.Postgres qualified as Tx
import Shomei.Prelude
import Shomei.Session.Authentication.Guard (AuthenticationGuard (..))
import Shomei.Session.Authentication.Guard.Postgres (checkAuthentication)

-- | The pending-ceremony row, column order matching
-- @shomei_webauthn_pending_ceremonies@: @(ceremony_id, user_id, kind, options_blob,
-- created_at, expires_at)@. @user_id@ is nullable (a passwordless ceremony has no user yet).
type CeremonyRow = (UUID, Maybe UUID, Text, ByteString, UTCTime, UTCTime, Maybe Int64, Maybe UUID)

runPendingCeremonyStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (PendingCeremonyStore : es) a ->
  Eff es a
runPendingCeremonyStorePostgres = interpret_ \case
  PutPendingCeremony pc -> do
    let PendingCeremony {userId, authenticationGeneration, initiatingSession, createdAt} = pc
    res <- runTransaction do
      checked <- case (userId, authenticationGeneration) of
        (Nothing, _) -> pure (Right ())
        (Just uid, Just generation) -> checkAuthentication uid (AuthenticationGuard generation initiatingSession Nothing) createdAt
        _ -> pure (Left StaleAuthentication)
      case checked of
        Left err -> pure (Left err)
        Right () -> Right <$> Tx.statement (toRow pc) insertStmt
    either dbFail pure res
  TakePendingCeremony cid now' -> do
    -- DELETE ... RETURNING is atomic: at most one concurrent transaction removes and
    -- returns the row, so a challenge is usable at most once. We still filter on expiry
    -- AFTER the delete, so an expired ceremony is removed (cannot linger) yet not honored.
    res <- runSession (Session.statement (ceremonyIdToUUID cid) takeStmt)
    row <- either dbFail pure res
    case row of
      Nothing -> pure Nothing
      Just r -> do
        pc <- rebuild r
        pure (if pcExpiresAt pc > now' then Just pc else Nothing)
  where
    dbFail = throwError . postgresUnavailable
    rebuild r = either (throwError . InternalAuthError) pure (rebuildCeremony r)

ceremonyKindToText :: CeremonyKind -> Text
ceremonyKindToText = \case
  RegistrationCeremony -> "registration"
  AuthenticationCeremony -> "authentication"

ceremonyKindFromText :: Text -> Either Text CeremonyKind
ceremonyKindFromText = \case
  "registration" -> Right RegistrationCeremony
  "authentication" -> Right AuthenticationCeremony
  t -> Left ("unknown ceremony kind: " <> t)

pcExpiresAt :: PendingCeremony -> UTCTime
pcExpiresAt PendingCeremony {expiresAt} = expiresAt

toRow :: PendingCeremony -> CeremonyRow
toRow PendingCeremony {ceremonyId, userId, kind, optionsBlob, createdAt, expiresAt, authenticationGeneration, initiatingSession} =
  ( ceremonyIdToUUID ceremonyId,
    fmap userIdToUUID userId,
    ceremonyKindToText kind,
    optionsBlob,
    createdAt,
    expiresAt,
    authenticationGeneration,
    sessionIdToUUID <$> initiatingSession
  )

rebuildCeremony :: CeremonyRow -> Either Text PendingCeremony
rebuildCeremony (cid, uid, k, blob, ca, ea, generation, source) = do
  kind <- ceremonyKindFromText k
  pure
    PendingCeremony
      { authenticationGeneration = generation,
        initiatingSession = sessionIdFromUUID <$> source,
        ceremonyId = ceremonyIdFromUUID cid,
        userId = fmap userIdFromUUID uid,
        kind,
        optionsBlob = blob,
        createdAt = ca,
        expiresAt = ea
      }

ceremonyRowDecoder :: D.Row CeremonyRow
ceremonyRowDecoder =
  (,,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.bytea)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.int8)
    <*> D.column (D.nullable D.uuid)

ceremonyRowEncoder :: E.Params CeremonyRow
ceremonyRowEncoder =
  contrazip8
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nullable E.uuid))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.bytea))
    (E.param (E.nonNullable E.timestamptz))
    (E.param (E.nonNullable E.timestamptz))
    (E.param (E.nullable E.int8))
    (E.param (E.nullable E.uuid))

selectCols :: Text
selectCols = "ceremony_id, user_id, kind, options_blob, created_at, expires_at, authentication_generation, initiating_session_id"

insertStmt :: Statement CeremonyRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_webauthn_pending_ceremonies
      (ceremony_id, user_id, kind, options_blob, created_at, expires_at, authentication_generation, initiating_session_id)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    """
    ceremonyRowEncoder
    D.noResult

takeStmt :: Statement UUID (Maybe CeremonyRow)
takeStmt =
  preparable
    ( "DELETE FROM shomei.shomei_webauthn_pending_ceremonies WHERE ceremony_id = $1 RETURNING "
        <> selectCols
    )
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe ceremonyRowDecoder)
