-- | PostgreSQL interpreter for the EP-5 authorization-code store.
module Shomei.OAuth.AuthorizationCode.Postgres
  ( runOAuthCodeStorePostgres,
  )
where

import Contravariant.Extras (contrazip11, contrazip2)
import Data.Aeson (Result (..), Value)
import Data.Int (Int64)
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
import Shomei.Error (AuthError (..))
import Shomei.Id (sessionIdFromUUID, sessionIdToUUID, userIdFromUUID, userIdToUUID)
import Shomei.OAuth.AuthorizationCode.Domain (AuthorizationCode (..), NewAuthorizationCode (..))
import Shomei.OAuth.AuthorizationCode.Store (OAuthCodeStore (..))
import Shomei.Persistence.Database.Postgres (Database, postgresUnavailable, runSession, runTransaction)
import Shomei.Persistence.Transaction.Postgres qualified as Tx
import Shomei.Prelude
import Shomei.Session.Authentication.Guard (AuthenticationGuard (..))
import Shomei.Session.Authentication.Guard.Postgres (checkAuthentication, lockAuthenticationUser)

-- | The stored row, column order matching @shomei_oauth_authorization_codes@:
-- @(code_hash, client_id, user_id, redirect_uri, scopes, nonce, code_challenge, auth_time,
-- created_at, expires_at, consumed_at, session_id, authentication_generation)@.
type CodeRow = (Text, Text, UUID, Text, Value, Maybe Text, Maybe Text, UTCTime, UTCTime, UTCTime, Maybe UTCTime, Maybe UUID, Maybe Int64)

runOAuthCodeStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (OAuthCodeStore : es) a ->
  Eff es a
runOAuthCodeStorePostgres = interpret_ \case
  PutAuthorizationCode proofState new -> do
    res <- runTransaction do
      checked <- checkAuthentication new.userId proofState new.createdAt
      case checked of
        Left err -> pure (Left err)
        Right () -> Right <$> Tx.statement (toInsertRow proofState new) insertStmt
    either dbFail pure res
  ConsumeAuthorizationCode h t -> do
    -- ONE statement. `UPDATE … WHERE consumed_at IS NULL AND expires_at > $2 RETURNING …` takes a
    -- row lock and returns the row only to the transaction that flipped it, so two racing
    -- exchanges of the same code cannot both receive it. Filtering expiry inside the same WHERE
    -- means an expired code is never consumed and never returned.
    res <- runTransaction do
      owner <- Tx.statement h codeOwnerStmt
      case owner of
        Nothing -> pure Nothing
        Just uid -> do
          _ <- lockAuthenticationUser (userIdFromUUID uid)
          Tx.statement (h, t) consumeStmt
    row <- either dbFail pure res
    traverse rebuild row
  BindAuthorizationCodeSession h sid -> do
    res <- runSession (Session.statement (h, sessionIdToUUID sid) bindSessionStmt)
    either dbFail (const (pure ())) res
  FindConsumedAuthorizationCode h t -> do
    res <- runSession (Session.statement (h, t) findConsumedStmt)
    row <- either dbFail pure res
    traverse rebuild row
  where
    dbFail = throwError . postgresUnavailable
    rebuild r = either (throwError . InternalAuthError) pure (rebuildCode r)

-- | The ten columns an INSERT writes; @consumed_at@ is always NULL on a fresh row.
type InsertRow = (Text, Text, UUID, Text, Value, Maybe Text, Maybe Text, UTCTime, UTCTime, UTCTime, Int64)

toInsertRow :: AuthenticationGuard -> NewAuthorizationCode -> InsertRow
toInsertRow proofState NewAuthorizationCode {codeHash, clientId, redirectUri, userId, scopes, nonce, codeChallenge, authTime, createdAt, expiresAt} =
  ( codeHash,
    clientId,
    userIdToUUID userId,
    redirectUri,
    toJSON (Set.toList scopes),
    nonce,
    codeChallenge,
    authTime,
    createdAt,
    expiresAt,
    proofState.generation
  )

rebuildCode :: CodeRow -> Either Text AuthorizationCode
rebuildCode (h, cid, uid, uri, scopesJson, nonce, challenge, authTime, createdAt, expiresAt, consumedAt, sessionId, generation) = do
  scopes <- case fromJSON scopesJson of
    Success ss -> Right (Set.fromList ss)
    Error msg -> Left ("invalid scopes json: " <> Text.pack msg)
  pure
    AuthorizationCode
      { authenticationGeneration = generation,
        codeHash = h,
        clientId = cid,
        redirectUri = uri,
        userId = userIdFromUUID uid,
        scopes,
        nonce,
        codeChallenge = challenge,
        authTime,
        createdAt,
        expiresAt,
        consumedAt,
        sessionId = sessionIdFromUUID <$> sessionId
      }

codeRowDecoder :: D.Row CodeRow
codeRowDecoder =
  (,,,,,,,,,,,,)
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
    <*> D.column (D.nullable D.uuid)
    <*> D.column (D.nullable D.int8)

insertRowEncoder :: E.Params InsertRow
insertRowEncoder =
  contrazip11
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
    (E.param (E.nonNullable E.int8))

-- | The SELECT/RETURNING column list (matches 'CodeRow' / 'codeRowDecoder' order).
selectCols :: Text
selectCols =
  "code_hash, client_id, user_id, redirect_uri, scopes, nonce, code_challenge, auth_time, created_at, expires_at, consumed_at, session_id, authentication_generation"

insertStmt :: Statement InsertRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_oauth_authorization_codes
      (code_hash, client_id, user_id, redirect_uri, scopes, nonce, code_challenge, auth_time,
       created_at, expires_at, consumed_at, session_id, authentication_generation)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, NULL, $11)
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

bindSessionStmt :: Statement (Text, UUID) ()
bindSessionStmt =
  preparable
    """
    UPDATE shomei.shomei_oauth_authorization_codes
    SET session_id = $2
    WHERE code_hash = $1 AND consumed_at IS NOT NULL AND session_id IS NULL
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.uuid)))
    D.noResult

findConsumedStmt :: Statement (Text, UTCTime) (Maybe CodeRow)
findConsumedStmt =
  preparable
    ( "SELECT "
        <> selectCols
        <> " FROM shomei.shomei_oauth_authorization_codes WHERE code_hash = $1 AND consumed_at IS NOT NULL AND expires_at > $2"
    )
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
    (D.rowMaybe codeRowDecoder)

codeOwnerStmt :: Statement Text (Maybe UUID)
codeOwnerStmt =
  preparable
    "SELECT user_id FROM shomei.shomei_oauth_authorization_codes WHERE code_hash = $1"
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (D.column (D.nonNullable D.uuid)))
