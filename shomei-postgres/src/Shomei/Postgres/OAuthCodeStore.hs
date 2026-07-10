-- | PostgreSQL interpreter for the EP-5 authorization-code store.
module Shomei.Postgres.OAuthCodeStore
  ( runOAuthCodeStorePostgres,
  )
where

import Contravariant.Extras (contrazip10, contrazip2)
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
import Shomei.Domain.AuthorizationCode (AuthorizationCode (..), NewAuthorizationCode (..))
import Shomei.Effect.OAuthCodeStore (OAuthCodeStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (userIdFromUUID, userIdToUUID)
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

-- | The stored row, column order matching @shomei_oauth_authorization_codes@:
-- @(code_hash, client_id, redirect_uri, user_id, scopes, nonce, code_challenge, auth_time,
-- created_at, expires_at, consumed_at)@.
type CodeRow = (Text, Text, UUID, Text, Value, Maybe Text, Maybe Text, UTCTime, UTCTime, UTCTime, Maybe UTCTime)

runOAuthCodeStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (OAuthCodeStore : es) a ->
  Eff es a
runOAuthCodeStorePostgres = interpret_ \case
  PutAuthorizationCode new -> do
    res <- runSession (Session.statement (toInsertRow new) insertStmt)
    either dbFail (const (pure ())) res
  ConsumeAuthorizationCode h t -> do
    -- ONE statement. `UPDATE … WHERE consumed_at IS NULL AND expires_at > $2 RETURNING …` takes a
    -- row lock and returns the row only to the transaction that flipped it, so two racing
    -- exchanges of the same code cannot both receive it. Filtering expiry inside the same WHERE
    -- means an expired code is never consumed and never returned.
    res <- runSession (Session.statement (h, t) consumeStmt)
    row <- either dbFail pure res
    traverse rebuild row
  DeleteExpiredAuthorizationCodes t -> do
    res <- runSession (Session.statement t deleteExpiredStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildCode r)

-- | The ten columns an INSERT writes; @consumed_at@ is always NULL on a fresh row.
type InsertRow = (Text, Text, UUID, Text, Value, Maybe Text, Maybe Text, UTCTime, UTCTime, UTCTime)

toInsertRow :: NewAuthorizationCode -> InsertRow
toInsertRow NewAuthorizationCode {codeHash, clientId, redirectUri, userId, scopes, nonce, codeChallenge, authTime, createdAt, expiresAt} =
  ( codeHash,
    clientId,
    userIdToUUID userId,
    redirectUri,
    toJSON (Set.toList scopes),
    nonce,
    codeChallenge,
    authTime,
    createdAt,
    expiresAt
  )

rebuildCode :: CodeRow -> Either Text AuthorizationCode
rebuildCode (h, cid, uid, uri, scopesJson, nonce, challenge, authTime, createdAt, expiresAt, consumedAt) = do
  scopes <- case fromJSON scopesJson of
    Success ss -> Right (Set.fromList ss)
    Error msg -> Left ("invalid scopes json: " <> Text.pack msg)
  pure
    AuthorizationCode
      { codeHash = h,
        clientId = cid,
        redirectUri = uri,
        userId = userIdFromUUID uid,
        scopes,
        nonce,
        codeChallenge = challenge,
        authTime,
        createdAt,
        expiresAt,
        consumedAt
      }

codeRowDecoder :: D.Row CodeRow
codeRowDecoder =
  (,,,,,,,,,,)
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

insertRowEncoder :: E.Params InsertRow
insertRowEncoder =
  contrazip10
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nonNullable E.text))
    (E.param (E.nonNullable E.jsonb))
    (E.param (E.nullable E.text))
    (E.param (E.nullable E.text))
    (E.param (E.nonNullable E.timestamptz))
    (E.param (E.nonNullable E.timestamptz))
    (E.param (E.nonNullable E.timestamptz))

-- | The SELECT/RETURNING column list (matches 'CodeRow' / 'codeRowDecoder' order).
selectCols :: Text
selectCols =
  "code_hash, client_id, user_id, redirect_uri, scopes, nonce, code_challenge, auth_time, created_at, expires_at, consumed_at"

insertStmt :: Statement InsertRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_oauth_authorization_codes
      (code_hash, client_id, user_id, redirect_uri, scopes, nonce, code_challenge, auth_time,
       created_at, expires_at, consumed_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL)
    """
    insertRowEncoder
    D.noResult

-- | Redeem atomically: at most one caller ever sees a given code unconsumed.
consumeStmt :: Statement (Text, UTCTime) (Maybe CodeRow)
consumeStmt =
  preparable
    ( """
      UPDATE shomei.shomei_oauth_authorization_codes
      SET consumed_at = $2
      WHERE code_hash = $1 AND consumed_at IS NULL AND expires_at > $2
      RETURNING
      """
        -- The multiline string drops its trailing newline, so the column list needs a separator
        -- of its own or the statement reads `RETURNINGcode_hash`.
        <> " "
        <> selectCols
    )
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
    (D.rowMaybe codeRowDecoder)

deleteExpiredStmt :: Statement UTCTime ()
deleteExpiredStmt =
  preparable
    "DELETE FROM shomei.shomei_oauth_authorization_codes WHERE expires_at <= $1"
    (E.param (E.nonNullable E.timestamptz))
    D.noResult
