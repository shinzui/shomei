-- | PostgreSQL interpreter for the EP-4 service-account store.
module Shomei.Postgres.ServiceAccountStore
  ( runServiceAccountStorePostgres,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip8)
import Data.Aeson (Result (..), Value)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.ServiceAccount
  ( NewServiceAccount (..),
    ServiceAccount (..),
    ServiceAccountStatus (..),
  )
import Shomei.Effect.ServiceAccountStore (ServiceAccountStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id
  ( serviceAccountDbIdFromUUID,
    serviceAccountDbIdToUUID,
    userIdFromUUID,
    userIdToUUID,
  )
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

-- | The stored row, column order matching @shomei_service_accounts@:
-- @(service_account_id, client_id, user_id, secret_hash, display_name, allowed_scopes, status,
-- created_at, rotated_at, revoked_at)@. @allowed_scopes :: Set Scope@ rides as a @jsonb@ array
-- of scope texts, as @shomei_webauthn_credentials.transports@ does.
type ServiceAccountRow = (UUID, Text, UUID, Text, Text, Value, Text, UTCTime, Maybe UTCTime, Maybe UTCTime)

-- | The @status@ column's two values. Kept in one place so the encoder and the decoder cannot
-- drift: a typo would silently make every account look revoked.
renderStatus :: ServiceAccountStatus -> Text
renderStatus = \case
  ServiceAccountActive -> "active"
  ServiceAccountRevoked -> "revoked"

parseStatus :: Text -> Either Text ServiceAccountStatus
parseStatus = \case
  "active" -> Right ServiceAccountActive
  "revoked" -> Right ServiceAccountRevoked
  other -> Left ("invalid service-account status: " <> other)

runServiceAccountStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (ServiceAccountStore : es) a ->
  Eff es a
runServiceAccountStorePostgres = interpret_ \case
  CreateServiceAccount NewServiceAccount {serviceAccountId, clientId, userId, secretHash, displayName, allowedScopes, createdAt} -> do
    let sa =
          ServiceAccount
            { serviceAccountId,
              clientId,
              userId,
              secretHash,
              displayName,
              allowedScopes,
              status = ServiceAccountActive,
              createdAt,
              rotatedAt = Nothing,
              revokedAt = Nothing
            }
    res <- runSession (Session.statement (toInsertRow sa) insertStmt)
    either dbFail (const (pure sa)) res
  FindServiceAccountByClientId cid -> do
    res <- runSession (Session.statement cid findByClientIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  ListServiceAccounts -> do
    res <- runSession (Session.statement () listStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  RotateServiceAccountSecret sid h t -> do
    res <- runSession (Session.statement (serviceAccountDbIdToUUID sid, h, t) rotateSecretStmt)
    either dbFail (const (pure ())) res
  RevokeServiceAccount sid t -> do
    res <- runSession (Session.statement (serviceAccountDbIdToUUID sid, t) revokeStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildServiceAccount r)

-- | The eight columns an INSERT writes. @rotated_at@ and @revoked_at@ are always NULL on a
-- fresh row, so they are literals in the statement rather than parameters.
type InsertRow = (UUID, Text, UUID, Text, Text, Value, Text, UTCTime)

toInsertRow :: ServiceAccount -> InsertRow
toInsertRow ServiceAccount {serviceAccountId, clientId, userId, secretHash, displayName, allowedScopes, status, createdAt} =
  ( serviceAccountDbIdToUUID serviceAccountId,
    clientId,
    userIdToUUID userId,
    secretHash,
    displayName,
    toJSON (Set.toList allowedScopes),
    renderStatus status,
    createdAt
  )

rebuildServiceAccount :: ServiceAccountRow -> Either Text ServiceAccount
rebuildServiceAccount (said, cid, uid, sh, dn, scopesJson, st, ca, ra, rva) = do
  scopes <- case fromJSON scopesJson of
    Success ss -> Right (Set.fromList ss)
    Error msg -> Left ("invalid allowed_scopes json: " <> Text.pack msg)
  status <- parseStatus st
  pure
    ServiceAccount
      { serviceAccountId = serviceAccountDbIdFromUUID said,
        clientId = cid,
        userId = userIdFromUUID uid,
        secretHash = sh,
        displayName = dn,
        allowedScopes = scopes,
        status,
        createdAt = ca,
        rotatedAt = ra,
        revokedAt = rva
      }

serviceAccountRowDecoder :: D.Row ServiceAccountRow
serviceAccountRowDecoder =
  (,,,,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

insertRowEncoder :: E.Params InsertRow
insertRowEncoder =
  contrazip8
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.jsonb))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.timestamptz))

-- | The SELECT column list (matches 'ServiceAccountRow' / 'serviceAccountRowDecoder' order).
selectCols :: Text
selectCols =
  "service_account_id, client_id, user_id, secret_hash, display_name, allowed_scopes, status, created_at, rotated_at, revoked_at"

insertStmt :: Statement InsertRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_service_accounts
      (service_account_id, client_id, user_id, secret_hash, display_name, allowed_scopes,
       status, created_at, rotated_at, revoked_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULL, NULL)
    """
    insertRowEncoder
    D.noResult

findByClientIdStmt :: Statement Text (Maybe ServiceAccountRow)
findByClientIdStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_service_accounts WHERE client_id = $1")
    (E.param (E.nonNullable E.text))
    (D.rowMaybe serviceAccountRowDecoder)

-- | Newest first, tie-broken by id so the order is total (the in-memory interpreter sorts the
-- same way, and the servant suite walks both).
listStmt :: Statement () [ServiceAccountRow]
listStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_service_accounts ORDER BY created_at DESC, service_account_id DESC")
    E.noParams
    (D.rowList serviceAccountRowDecoder)

rotateSecretStmt :: Statement (UUID, Text, UTCTime) ()
rotateSecretStmt =
  preparable
    """
    UPDATE shomei.shomei_service_accounts
    SET secret_hash = $2, rotated_at = $3
    WHERE service_account_id = $1
    """
    ( contrazip3
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

revokeStmt :: Statement (UUID, UTCTime) ()
revokeStmt =
  preparable
    """
    UPDATE shomei.shomei_service_accounts
    SET status = 'revoked', revoked_at = $2
    WHERE service_account_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult
