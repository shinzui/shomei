-- | PostgreSQL interpreter for the 'CredentialStore' port.
module Shomei.Postgres.CredentialStore (
    runCredentialStorePostgres,
) where

import Shomei.Prelude

import Data.UUID (UUID)
import "contravariant-extras" Contravariant.Extras (contrazip2, contrazip6)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, emailText)
import Shomei.Domain.Password (PasswordHash (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (CredentialId, UserId, credentialIdFromUUID, credentialIdToUUID, genCredentialId, userIdFromUUID, userIdToUUID)
import Shomei.Port.CredentialStore (CredentialStore (..))
import Shomei.Postgres.Codec (emailFromDb, tshow)
import Shomei.Postgres.Database (Database, runSession)

type CredRow = (UUID, UUID, Text, Text, UTCTime, UTCTime)

runCredentialStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (CredentialStore : es) a ->
    Eff es a
runCredentialStorePostgres = interpret_ \case
    CreatePasswordCredential uid email pwHash -> do
        cid <- genCredentialId
        ts <- liftIO getCurrentTime
        let row = (credentialIdToUUID cid, userIdToUUID uid, emailText email, passwordHashText pwHash, ts, ts)
        res <- runSession (Session.statement row insertCredentialStmt)
        either dbFail (const (pure (mkCredential cid uid email pwHash ts))) res
    FindPasswordCredentialByEmail email -> do
        res <- runSession (Session.statement (emailText email) findCredByEmailStmt)
        row <- either dbFail pure res
        traverse rebuild row
    UpdatePasswordHash uid pwHash -> do
        res <- runSession (Session.statement (userIdToUUID uid, passwordHashText pwHash) updatePasswordHashStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildCredential r)

passwordHashText :: PasswordHash -> Text
passwordHashText (PasswordHash t) = t

mkCredential :: CredentialId -> UserId -> Email -> PasswordHash -> UTCTime -> Credential
mkCredential cid uid email pwHash ts =
    PasswordCredential
        { credentialId = cid
        , userId = uid
        , email = email
        , passwordHash = pwHash
        , createdAt = ts
        , updatedAt = ts
        }

rebuildCredential :: CredRow -> Either Text Credential
rebuildCredential (cid, uid, e, ph, c, u) = do
    email <- emailFromDb e
    pure
        PasswordCredential
            { credentialId = credentialIdFromUUID cid
            , userId = userIdFromUUID uid
            , email = email
            , passwordHash = PasswordHash ph
            , createdAt = c
            , updatedAt = u
            }

credRowDecoder :: D.Row CredRow
credRowDecoder =
    (,,,,,)
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

insertCredentialStmt :: Statement CredRow ()
insertCredentialStmt =
    preparable
        """
        INSERT INTO shomei.shomei_password_credentials
          (credential_id, user_id, email, password_hash, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """
        ( contrazip6
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

findCredByEmailStmt :: Statement Text (Maybe CredRow)
findCredByEmailStmt =
    preparable
        """
        SELECT credential_id, user_id, email, password_hash, created_at, updated_at
        FROM shomei.shomei_password_credentials
        WHERE email = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe credRowDecoder)

updatePasswordHashStmt :: Statement (UUID, Text) ()
updatePasswordHashStmt =
    preparable
        """
        UPDATE shomei.shomei_password_credentials
        SET password_hash = $2
        WHERE user_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.text)))
        D.noResult
