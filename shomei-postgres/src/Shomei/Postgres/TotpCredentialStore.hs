{-# LANGUAGE ScopedTypeVariables #-}

-- | PostgreSQL interpreter for the EP-7 TOTP credential store, with AES-256-GCM encryption of
-- the shared secret at the storage boundary.
--
-- The port ('Shomei.Effect.TotpCredentialStore') speaks in raw 'Shomei.Totp.TotpSecret's;
-- encryption lives here so the workflows stay pure policy over ports and the in-memory tests
-- exercise TOTP logic rather than AES (Decision Log). Each write draws a fresh 96-bit nonce and
-- stores @nonce || ciphertext || tag@ in one @bytea@; the key comes from the server 'Env'
-- (@SHOMEI_TOTP_ENCRYPTION_KEY@), never from the database, so a dump alone yields no usable
-- secret. This follows the ChaChaPoly1305 AEAD shape in
-- @shomei-jwt/src/Shomei/Jwt/KeyProtection.hs@, adapted to AES-256-GCM.
module Shomei.Postgres.TotpCredentialStore
  ( runTotpCredentialStorePostgres,
    TotpEncryptionKey,
    totpEncryptionKeyFromBytes,
    totpEncryptionKeyFromBase64,
  )
where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types
  ( AEAD,
    AEADMode (AEAD_GCM),
    AuthTag (..),
    aeadInit,
    aeadSimpleDecrypt,
    aeadSimpleEncrypt,
    cipherInit,
  )
import Crypto.Error (CryptoFailable (..))
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base64), convertFromBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.Totp (NewTotpCredential (..), TotpCredential (..))
import Shomei.Effect.TotpCredentialStore (TotpCredentialStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id
  ( totpCredentialIdFromUUID,
    totpCredentialIdToUUID,
    userIdFromUUID,
    userIdToUUID,
  )
import Shomei.Postgres.Codec (tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude
import Shomei.Totp (TotpSecret (..))

-- | The AES-256-GCM key that encrypts stored TOTP secrets. Abstract: no 'Show', no JSON, so a
-- leak is a type error rather than a review question. 32 bytes, held as 'BA.ScrubbedBytes'.
newtype TotpEncryptionKey = TotpEncryptionKey BA.ScrubbedBytes

-- | Build a key from exactly 32 raw bytes.
totpEncryptionKeyFromBytes :: ByteString -> Either Text TotpEncryptionKey
totpEncryptionKeyFromBytes bs
  | BS.length bs == 32 = Right (TotpEncryptionKey (BA.convert bs))
  | otherwise = Left ("TOTP encryption key must be exactly 32 bytes, got " <> tshow (BS.length bs))

-- | Parse a key from base64 text (the value of @SHOMEI_TOTP_ENCRYPTION_KEY@); requires exactly
-- 32 decoded bytes. The 'Left' explains how to make a valid one.
totpEncryptionKeyFromBase64 :: Text -> Either Text TotpEncryptionKey
totpEncryptionKeyFromBase64 raw =
  case convertFromBase Base64 (TE.encodeUtf8 (Text.strip raw)) :: Either String ByteString of
    Left err -> Left (bad ("it is not valid base64 (" <> Text.pack err <> ")"))
    Right bs
      | BS.length bs == 32 -> Right (TotpEncryptionKey (BA.convert bs))
      | otherwise -> Left (bad ("it decodes to " <> tshow (BS.length bs) <> " bytes, not 32"))
  where
    bad reason = "is not a valid TOTP encryption key: " <> reason <> ". Generate one with: openssl rand -base64 32"

-- | The AEAD state for @(key, nonce)@ under AES-256-GCM, shared by encrypt and decrypt.
aeadState :: BA.ScrubbedBytes -> ByteString -> CryptoFailable (AEAD AES256)
aeadState key nonce = do
  cipher <- cipherInit key
  aeadInit AEAD_GCM cipher nonce

-- | Encrypt raw secret bytes: draw a 96-bit nonce, and lay out @nonce || ciphertext || tag@.
encryptSecret :: TotpEncryptionKey -> ByteString -> IO ByteString
encryptSecret (TotpEncryptionKey key) plaintext = do
  nonce <- getRandomBytes 12 :: IO ByteString
  case aeadState key nonce of
    CryptoFailed e -> ioError (userError ("shomei: cannot initialize TOTP encryption: " <> show e))
    CryptoPassed st -> do
      let (tag, ciphertext) = aeadSimpleEncrypt st (BS.empty :: ByteString) plaintext 16
      pure (nonce <> ciphertext <> BA.convert (unAuthTag tag))

-- | Recover raw secret bytes from a stored @secret_enc@ blob. A wrong key, a tampered
-- ciphertext, or a truncated blob all fail the same way (one indistinguishable error).
decryptSecret :: TotpEncryptionKey -> ByteString -> Either Text ByteString
decryptSecret (TotpEncryptionKey key) blob
  | BS.length blob < 12 + 16 = Left "TOTP secret ciphertext is shorter than nonce + tag"
  | otherwise =
      let (nonce, rest) = BS.splitAt 12 blob
          (ciphertext, tagBytes) = BS.splitAt (BS.length rest - 16) rest
       in case aeadState key nonce of
            CryptoFailed _ -> Left "TOTP secret: bad AES-GCM initialization"
            CryptoPassed st ->
              case aeadSimpleDecrypt st (BS.empty :: ByteString) ciphertext (AuthTag (BA.convert tagBytes)) of
                Just pt -> Right pt
                Nothing -> Left "TOTP secret failed authentication"

-- | The stored row, column order matching @shomei_totp_credentials@:
-- @(totp_credential_id, user_id, secret_enc, last_used_counter, confirmed_at, created_at)@.
type TotpRow = (UUID, UUID, ByteString, Maybe Int64, Maybe UTCTime, UTCTime)

runTotpCredentialStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  TotpEncryptionKey ->
  Eff (TotpCredentialStore : es) a ->
  Eff es a
runTotpCredentialStorePostgres key = interpret_ \case
  UpsertTotpEnrollment NewTotpCredential {totpCredentialId, userId, secret = TotpSecret raw, createdAt} -> do
    enc <- liftIO (encryptSecret key raw)
    let params = (totpCredentialIdToUUID totpCredentialId, userIdToUUID userId, enc, createdAt)
    res <- runSession (Session.statement params upsertStmt)
    either dbFail (const (pure ())) res
    pure
      TotpCredential
        { totpCredentialId,
          userId,
          secret = TotpSecret raw,
          lastUsedCounter = Nothing,
          confirmedAt = Nothing,
          createdAt
        }
  FindTotpByUser uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) findByUserStmt)
    row <- either dbFail pure res
    traverse rebuild row
  ConfirmTotp tcid t -> do
    res <- runSession (Session.statement (totpCredentialIdToUUID tcid, t) confirmStmt)
    either dbFail (const (pure ())) res
  SetTotpLastUsedCounter tcid c -> do
    res <- runSession (Session.statement (totpCredentialIdToUUID tcid, c) setCounterStmt)
    either dbFail (const (pure ())) res
  DeleteTotpByUser uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) deleteByUserStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild row = either (throwError . InternalAuthError) pure (rebuildCredential key row)

rebuildCredential :: TotpEncryptionKey -> TotpRow -> Either Text TotpCredential
rebuildCredential key (tcid, uid, enc, lastUsed, confirmed, created) = do
  raw <- decryptSecret key enc
  pure
    TotpCredential
      { totpCredentialId = totpCredentialIdFromUUID tcid,
        userId = userIdFromUUID uid,
        secret = TotpSecret raw,
        lastUsedCounter = lastUsed,
        confirmedAt = confirmed,
        createdAt = created
      }

totpRowDecoder :: D.Row TotpRow
totpRowDecoder =
  (,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.bytea)
    <*> D.column (D.nullable D.int8)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)

selectCols :: Text
selectCols = "totp_credential_id, user_id, secret_enc, last_used_counter, confirmed_at, created_at"

-- | Insert, or replace an existing (unconfirmed) enrollment for the user: on a @user_id@
-- conflict the id and secret are swapped in and the counter/confirmation are reset to NULL. The
-- workflow refuses to reach here when a /confirmed/ credential exists.
upsertStmt :: Statement (UUID, UUID, ByteString, UTCTime) ()
upsertStmt =
  preparable
    """
    INSERT INTO shomei.shomei_totp_credentials
      (totp_credential_id, user_id, secret_enc, last_used_counter, confirmed_at, created_at)
    VALUES ($1, $2, $3, NULL, NULL, $4)
    ON CONFLICT (user_id) DO UPDATE
    SET totp_credential_id = EXCLUDED.totp_credential_id,
        secret_enc = EXCLUDED.secret_enc,
        last_used_counter = NULL,
        confirmed_at = NULL,
        created_at = EXCLUDED.created_at
    """
    ( contrazip4
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.bytea))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

findByUserStmt :: Statement UUID (Maybe TotpRow)
findByUserStmt =
  preparable
    ("SELECT " <> selectCols <> " FROM shomei.shomei_totp_credentials WHERE user_id = $1")
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe totpRowDecoder)

confirmStmt :: Statement (UUID, UTCTime) ()
confirmStmt =
  preparable
    """
    UPDATE shomei.shomei_totp_credentials
    SET confirmed_at = $2
    WHERE totp_credential_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult

setCounterStmt :: Statement (UUID, Int64) ()
setCounterStmt =
  preparable
    """
    UPDATE shomei.shomei_totp_credentials
    SET last_used_counter = $2
    WHERE totp_credential_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.int8)))
    D.noResult

deleteByUserStmt :: Statement UUID ()
deleteByUserStmt =
  preparable
    "DELETE FROM shomei.shomei_totp_credentials WHERE user_id = $1"
    (E.param (E.nonNullable E.uuid))
    D.noResult
