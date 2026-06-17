-- | PostgreSQL interpreter for the consume-once pending-ceremony store.
module Shomei.Postgres.PendingCeremonyStore (
    runPendingCeremonyStorePostgres,
) where

import Shomei.Prelude

import Contravariant.Extras (contrazip6)
import Data.ByteString (ByteString)
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.Passkey (CeremonyKind (..), PendingCeremony (..))
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (ceremonyIdFromUUID, ceremonyIdToUUID, userIdFromUUID, userIdToUUID)
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)

{- | The pending-ceremony row, column order matching
@shomei_webauthn_pending_ceremonies@: @(ceremony_id, user_id, kind, options_blob,
created_at, expires_at)@. @user_id@ is nullable (a passwordless ceremony has no user yet).
-}
type CeremonyRow = (UUID, Maybe UUID, Text, ByteString, UTCTime, UTCTime)

runPendingCeremonyStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (PendingCeremonyStore : es) a ->
    Eff es a
runPendingCeremonyStorePostgres = interpret_ \case
    PutPendingCeremony pc -> do
        res <- runSession (Session.statement (toRow pc) insertStmt)
        either dbFail (const (pure ())) res
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
    DeleteExpiredCeremonies now' -> do
        res <- runSession (Session.statement now' deleteExpiredStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
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
pcExpiresAt PendingCeremony{expiresAt} = expiresAt

toRow :: PendingCeremony -> CeremonyRow
toRow PendingCeremony{ceremonyId, userId, kind, optionsBlob, createdAt, expiresAt} =
    ( ceremonyIdToUUID ceremonyId
    , fmap userIdToUUID userId
    , ceremonyKindToText kind
    , optionsBlob
    , createdAt
    , expiresAt
    )

rebuildCeremony :: CeremonyRow -> Either Text PendingCeremony
rebuildCeremony (cid, uid, k, blob, ca, ea) = do
    kind <- ceremonyKindFromText k
    pure
        PendingCeremony
            { ceremonyId = ceremonyIdFromUUID cid
            , userId = fmap userIdFromUUID uid
            , kind
            , optionsBlob = blob
            , createdAt = ca
            , expiresAt = ea
            }

ceremonyRowDecoder :: D.Row CeremonyRow
ceremonyRowDecoder =
    (,,,,,)
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.bytea)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

ceremonyRowEncoder :: E.Params CeremonyRow
ceremonyRowEncoder =
    contrazip6
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.bytea))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.timestamptz))

selectCols :: Text
selectCols = "ceremony_id, user_id, kind, options_blob, created_at, expires_at"

insertStmt :: Statement CeremonyRow ()
insertStmt =
    preparable
        """
        INSERT INTO shomei.shomei_webauthn_pending_ceremonies
          (ceremony_id, user_id, kind, options_blob, created_at, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6)
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

deleteExpiredStmt :: Statement UTCTime ()
deleteExpiredStmt =
    preparable
        """
        DELETE FROM shomei.shomei_webauthn_pending_ceremonies WHERE expires_at <= $1
        """
        (E.param (E.nonNullable E.timestamptz))
        D.noResult
