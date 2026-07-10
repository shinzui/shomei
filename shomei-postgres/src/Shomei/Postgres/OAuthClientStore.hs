-- | PostgreSQL interpreter for the EP-5 OAuth-client store.
module Shomei.Postgres.OAuthClientStore
  ( runOAuthClientStorePostgres,
  )
where

import Contravariant.Extras (contrazip2, contrazip8)
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
import Shomei.Domain.OAuthClient
  ( ClientType (..),
    NewOAuthClient (..),
    OAuthClient (..),
    OAuthClientStatus (..),
  )
import Shomei.Effect.OAuthClientStore (OAuthClientStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (oauthClientIdFromUUID, oauthClientIdToUUID)
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

-- | The stored row, column order matching @shomei_oauth_clients@:
-- @(oauth_client_id, client_id, secret_hash, client_type, display_name, redirect_uris,
-- allowed_scopes, status, created_at, revoked_at)@. @redirect_uris@ and @allowed_scopes@ ride as
-- @jsonb@ arrays of text, as @shomei_service_accounts.allowed_scopes@ does.
type OAuthClientRow = (UUID, Text, Maybe Text, Text, Text, Value, Value, Text, UTCTime, Maybe UTCTime)

-- | The @client_type@ column's two values, in one place so encoder and decoder cannot drift.
renderClientType :: ClientType -> Text
renderClientType = \case
  ConfidentialClient -> "confidential"
  PublicClient -> "public"

parseClientType :: Text -> Either Text ClientType
parseClientType = \case
  "confidential" -> Right ConfidentialClient
  "public" -> Right PublicClient
  other -> Left ("invalid oauth client_type: " <> other)

renderStatus :: OAuthClientStatus -> Text
renderStatus = \case
  OAuthClientActive -> "active"
  OAuthClientRevoked -> "revoked"

parseStatus :: Text -> Either Text OAuthClientStatus
parseStatus = \case
  "active" -> Right OAuthClientActive
  "revoked" -> Right OAuthClientRevoked
  other -> Left ("invalid oauth client status: " <> other)

runOAuthClientStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (OAuthClientStore : es) a ->
  Eff es a
runOAuthClientStorePostgres = interpret_ \case
  CreateOAuthClient NewOAuthClient {oauthClientId, clientId, secretHash, clientType, displayName, redirectUris, allowedScopes, createdAt} -> do
    let oc =
          OAuthClient
            { oauthClientId,
              clientId,
              secretHash,
              clientType,
              displayName,
              redirectUris,
              allowedScopes,
              status = OAuthClientActive,
              createdAt,
              revokedAt = Nothing
            }
    res <- runSession (Session.statement (toInsertRow oc) insertStmt)
    either dbFail (const (pure oc)) res
  FindOAuthClientByClientId cid -> do
    res <- runSession (Session.statement cid findByClientIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  ListOAuthClients -> do
    res <- runSession (Session.statement () listStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  RevokeOAuthClient cid t -> do
    res <- runSession (Session.statement (oauthClientIdToUUID cid, t) revokeStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildOAuthClient r)

-- | The eight columns an INSERT writes. @revoked_at@ is always NULL on a fresh row, so it is a
-- literal in the statement rather than a parameter.
type InsertRow = (UUID, Text, Maybe Text, Text, Text, Value, Value, UTCTime)

toInsertRow :: OAuthClient -> InsertRow
toInsertRow OAuthClient {oauthClientId, clientId, secretHash, clientType, displayName, redirectUris, allowedScopes, createdAt} =
  ( oauthClientIdToUUID oauthClientId,
    clientId,
    secretHash,
    renderClientType clientType,
    displayName,
    toJSON redirectUris,
    toJSON (Set.toList allowedScopes),
    createdAt
  )

rebuildOAuthClient :: OAuthClientRow -> Either Text OAuthClient
rebuildOAuthClient (ocid, cid, sh, ct, dn, urisJson, scopesJson, st, ca, ra) = do
  redirectUris <- case fromJSON urisJson of
    Success us -> Right us
    Error msg -> Left ("invalid redirect_uris json: " <> Text.pack msg)
  scopes <- case fromJSON scopesJson of
    Success ss -> Right (Set.fromList ss)
    Error msg -> Left ("invalid allowed_scopes json: " <> Text.pack msg)
  clientType <- parseClientType ct
  status <- parseStatus st
  pure
    OAuthClient
      { oauthClientId = oauthClientIdFromUUID ocid,
        clientId = cid,
        secretHash = sh,
        clientType,
        displayName = dn,
        redirectUris,
        allowedScopes = scopes,
        status,
        createdAt = ca,
        revokedAt = ra
      }

oauthClientRowDecoder :: D.Row OAuthClientRow
oauthClientRowDecoder =
  (,,,,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

insertRowEncoder :: E.Params InsertRow
insertRowEncoder =
  contrazip8
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nonNullable E.text))
    (E.param (E.nullable E.text))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.jsonb))
    (E.param (E.nonNullable E.jsonb))
    (E.param (E.nonNullable E.timestamptz))

-- | The SELECT column list (matches 'OAuthClientRow' / 'oauthClientRowDecoder' order).
selectCols :: Text
selectCols =
  "oauth_client_id, client_id, secret_hash, client_type, display_name, redirect_uris, allowed_scopes, status, created_at, revoked_at"

insertStmt :: Statement InsertRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_oauth_clients
      (oauth_client_id, client_id, secret_hash, client_type, display_name, redirect_uris,
       allowed_scopes, status, created_at, revoked_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, 'active', $8, NULL)
    """
    insertRowEncoder
    D.noResult

findByClientIdStmt :: Statement Text (Maybe OAuthClientRow)
findByClientIdStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_oauth_clients WHERE client_id = $1")
    (E.param (E.nonNullable E.text))
    (D.rowMaybe oauthClientRowDecoder)

-- | Newest first, tie-broken by id so the order is total (the in-memory interpreter sorts the
-- same way, and the servant suite walks both).
listStmt :: Statement () [OAuthClientRow]
listStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_oauth_clients ORDER BY created_at DESC, oauth_client_id DESC")
    E.noParams
    (D.rowList oauthClientRowDecoder)

revokeStmt :: Statement (UUID, UTCTime) ()
revokeStmt =
  preparable
    """
    UPDATE shomei.shomei_oauth_clients
    SET status = 'revoked', revoked_at = $2
    WHERE oauth_client_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult
