-- | PostgreSQL interpreter for the registered-passkey store.
module Shomei.Postgres.PasskeyStore
  ( runPasskeyStorePostgres,
  )
where

import Contravariant.Extras (contrazip10, contrazip2, contrazip3)
import Data.Aeson (Result (..), Value)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.Passkey
  ( NewPasskeyCredential (..),
    PasskeyCredential (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
  )
import Shomei.Effect.PasskeyStore (PasskeyStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id
  ( genPasskeyId,
    passkeyIdFromUUID,
    passkeyIdToUUID,
    userIdFromUUID,
    userIdToUUID,
  )
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

-- | The stored-credential row, column order matching @shomei_webauthn_credentials@:
-- @(passkey_id, user_id, credential_id, user_handle, public_key, sign_counter, transports,
-- label, created_at, last_used_at)@. The 'Word32' signature counter is stored as a signed
-- @bigint@ (it overflows @int4@ but fits @int8@); @transports :: [Text]@ rides as @jsonb@.
type PasskeyRow = (UUID, UUID, ByteString, ByteString, ByteString, Int64, Value, Maybe Text, UTCTime, Maybe UTCTime)

runPasskeyStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (PasskeyStore : es) a ->
  Eff es a
runPasskeyStorePostgres = interpret_ \case
  CreatePasskey NewPasskeyCredential {userId, credentialId, userHandle, publicKey, signCounter, transports, label, createdAt} -> do
    pid <- genPasskeyId
    let pc =
          PasskeyCredential
            { passkeyId = pid,
              userId,
              credentialId,
              userHandle,
              publicKey,
              signCounter,
              transports,
              label,
              createdAt,
              lastUsedAt = Nothing
            }
    res <- runSession (Session.statement (toRow pc) insertStmt)
    either dbFail (const (pure pc)) res
  FindPasskeysByUser uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) findByUserStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  FindPasskeyByCredentialId (WebAuthnCredentialId cid) -> do
    res <- runSession (Session.statement cid findByCredentialIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  FindPasskeysByUserHandle (UserHandle uh) -> do
    res <- runSession (Session.statement uh findByUserHandleStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  UpdatePasskeySignCounter pid (SignatureCounter c) t -> do
    res <- runSession (Session.statement (passkeyIdToUUID pid, fromIntegral c :: Int64, t) updateSignCounterStmt)
    either dbFail (const (pure ())) res
  DeletePasskey uid pid -> do
    res <- runSession (Session.statement (userIdToUUID uid, passkeyIdToUUID pid) deletePasskeyStmt)
    either dbFail (const (pure ())) res
  CountPasskeysByUser uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) countByUserStmt)
    n <- either dbFail pure res
    pure (fromIntegral n)
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildPasskey r)

-- | Flatten a 'PasskeyCredential' into its stored row (unwrapping the byte newtypes and
-- widening the 'Word32' counter to 'Int64').
toRow :: PasskeyCredential -> PasskeyRow
toRow
  PasskeyCredential
    { passkeyId,
      userId,
      credentialId = WebAuthnCredentialId cid,
      userHandle = UserHandle uh,
      publicKey = PublicKeyBytes pk,
      signCounter = SignatureCounter sc,
      transports,
      label,
      createdAt,
      lastUsedAt
    } =
    ( passkeyIdToUUID passkeyId,
      userIdToUUID userId,
      cid,
      uh,
      pk,
      fromIntegral sc,
      toJSON transports,
      label,
      createdAt,
      lastUsedAt
    )

rebuildPasskey :: PasskeyRow -> Either Text PasskeyCredential
rebuildPasskey (pid, uid, cid, uh, pk, sc, tj, lbl, ca, lua) = do
  ts <- case fromJSON tj of
    Success ts -> Right ts
    Error msg -> Left ("invalid transports json: " <> Text.pack msg)
  pure
    PasskeyCredential
      { passkeyId = passkeyIdFromUUID pid,
        userId = userIdFromUUID uid,
        credentialId = WebAuthnCredentialId cid,
        userHandle = UserHandle uh,
        publicKey = PublicKeyBytes pk,
        signCounter = SignatureCounter (fromIntegral sc),
        transports = ts,
        label = lbl,
        createdAt = ca,
        lastUsedAt = lua
      }

passkeyRowDecoder :: D.Row PasskeyRow
passkeyRowDecoder =
  (,,,,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.bytea)
    <*> D.column (D.nonNullable D.bytea)
    <*> D.column (D.nonNullable D.bytea)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

passkeyRowEncoder :: E.Params PasskeyRow
passkeyRowEncoder =
  contrazip10
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nonNullable E.uuid))
    (E.param (E.nonNullable E.bytea))
    (E.param (E.nonNullable E.bytea))
    (E.param (E.nonNullable E.bytea))
    (E.param (E.nonNullable E.int8))
    (E.param (E.nonNullable E.jsonb))
    (E.param (E.nullable E.text))
    (E.param (E.nonNullable E.timestamptz))
    (E.param (E.nullable E.timestamptz))

-- | The SELECT column list (matches 'PasskeyRow' / 'passkeyRowDecoder' order).
selectCols :: Text
selectCols =
  "passkey_id, user_id, credential_id, user_handle, public_key, sign_counter, transports, label, created_at, last_used_at"

insertStmt :: Statement PasskeyRow ()
insertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_webauthn_credentials
      (passkey_id, user_id, credential_id, user_handle, public_key, sign_counter,
       transports, label, created_at, last_used_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    """
    passkeyRowEncoder
    D.noResult

findByUserStmt :: Statement UUID [PasskeyRow]
findByUserStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_webauthn_credentials WHERE user_id = $1")
    (E.param (E.nonNullable E.uuid))
    (D.rowList passkeyRowDecoder)

findByCredentialIdStmt :: Statement ByteString (Maybe PasskeyRow)
findByCredentialIdStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_webauthn_credentials WHERE credential_id = $1")
    (E.param (E.nonNullable E.bytea))
    (D.rowMaybe passkeyRowDecoder)

findByUserHandleStmt :: Statement ByteString [PasskeyRow]
findByUserHandleStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_webauthn_credentials WHERE user_handle = $1")
    (E.param (E.nonNullable E.bytea))
    (D.rowList passkeyRowDecoder)

updateSignCounterStmt :: Statement (UUID, Int64, UTCTime) ()
updateSignCounterStmt =
  preparable
    """
    UPDATE shomei.shomei_webauthn_credentials
    SET sign_counter = $2, last_used_at = $3
    WHERE passkey_id = $1
    """
    ( contrazip3
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

deletePasskeyStmt :: Statement (UUID, UUID) ()
deletePasskeyStmt =
  preparable
    """
    DELETE FROM shomei.shomei_webauthn_credentials
    WHERE user_id = $1 AND passkey_id = $2
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.uuid)))
    D.noResult

countByUserStmt :: Statement UUID Int64
countByUserStmt =
  preparable
    """
    SELECT count(*) FROM shomei.shomei_webauthn_credentials WHERE user_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.singleRow (D.column (D.nonNullable D.int8)))
