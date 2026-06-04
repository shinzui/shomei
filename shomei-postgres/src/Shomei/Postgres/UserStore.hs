-- | PostgreSQL interpreter for the 'UserStore' port.
module Shomei.Postgres.UserStore (
    runUserStorePostgres,
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

import Shomei.Domain.Email (emailText)
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (UserActive))
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId, genUserId, userIdFromUUID, userIdToUUID)
import Shomei.Effect.UserStore (UserStore (..))
import Shomei.Postgres.Codec (emailFromDb, tshow, userStatusFromText, userStatusToText)
import Shomei.Postgres.Database (Database, runSession)

type UserRow = (UUID, Text, Maybe Text, Text, UTCTime, UTCTime)

runUserStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (UserStore : es) a ->
    Eff es a
runUserStorePostgres = interpret_ \case
    CreateUser nu -> do
        uid <- genUserId
        ts <- liftIO getCurrentTime
        let row = (userIdToUUID uid, emailText nu.email, nu.displayName, userStatusToText UserActive, ts, ts)
        res <- runSession (Session.statement row insertUserStmt)
        either dbFail (const (pure (mkUser uid nu ts))) res
    FindUserById uid -> do
        res <- runSession (Session.statement (userIdToUUID uid) findUserByIdStmt)
        row <- either dbFail pure res
        traverse rebuild row
    FindUserByEmail email -> do
        res <- runSession (Session.statement (emailText email) findUserByEmailStmt)
        row <- either dbFail pure res
        traverse rebuild row
    UpdateUserStatus uid st -> do
        res <- runSession (Session.statement (userIdToUUID uid, userStatusToText st) updateUserStatusStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildUser r)

mkUser :: UserId -> NewUser -> UTCTime -> User
mkUser uid nu ts =
    User
        { userId = uid
        , email = nu.email
        , displayName = nu.displayName
        , status = UserActive
        , createdAt = ts
        , updatedAt = ts
        }

rebuildUser :: UserRow -> Either Text User
rebuildUser (uid, e, dn, st, c, u) = do
    email <- emailFromDb e
    status <- userStatusFromText st
    pure
        User
            { userId = userIdFromUUID uid
            , email = email
            , displayName = dn
            , status = status
            , createdAt = c
            , updatedAt = u
            }

userRowDecoder :: D.Row UserRow
userRowDecoder =
    (,,,,,)
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)

insertUserStmt :: Statement UserRow ()
insertUserStmt =
    preparable
        """
        INSERT INTO shomei.shomei_users
          (user_id, email, display_name, status, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """
        ( contrazip6
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
        )
        D.noResult

findUserByIdStmt :: Statement UUID (Maybe UserRow)
findUserByIdStmt =
    preparable
        """
        SELECT user_id, email, display_name, status, created_at, updated_at
        FROM shomei.shomei_users
        WHERE user_id = $1
        """
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe userRowDecoder)

findUserByEmailStmt :: Statement Text (Maybe UserRow)
findUserByEmailStmt =
    preparable
        """
        SELECT user_id, email, display_name, status, created_at, updated_at
        FROM shomei.shomei_users
        WHERE email = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe userRowDecoder)

updateUserStatusStmt :: Statement (UUID, Text) ()
updateUserStatusStmt =
    preparable
        """
        UPDATE shomei.shomei_users SET status = $2 WHERE user_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.text)))
        D.noResult
