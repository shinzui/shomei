-- | PostgreSQL interpreter for the 'UserStore' port.
module Shomei.Postgres.UserStore
  ( runUserStorePostgres,
  )
where

import Contravariant.Extras (contrazip2, contrazip7)
import Data.UUID (UUID)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.Email (emailText)
import Shomei.Domain.LoginId (loginIdText)
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (UserActive))
import Shomei.Effect.UserStore (UserStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId, genUserId, userIdFromUUID, userIdToUUID)
import Shomei.Postgres.Codec (loginIdFromDb, maybeEmailFromDb, tshow, userStatusFromText, userStatusToText)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

type InsertUserRow = (UUID, Text, Maybe Text, Maybe Text, Text, UTCTime, UTCTime)

type UserRow = (UUID, Text, Maybe Text, Maybe Text, Text, Maybe UTCTime, UTCTime, UTCTime)

runUserStorePostgres ::
  (Database :> es, IOE :> es, Error AuthError :> es) =>
  Eff (UserStore : es) a ->
  Eff es a
runUserStorePostgres = interpret_ \case
  CreateUser nu -> do
    uid <- genUserId
    ts <- liftIO getCurrentTime
    let row = (userIdToUUID uid, loginIdText nu.loginId, emailText <$> nu.email, nu.displayName, userStatusToText UserActive, ts, ts)
    res <- runSession (Session.statement row insertUserStmt)
    either dbFail (const (pure (mkUser uid nu ts))) res
  FindUserById uid -> do
    res <- runSession (Session.statement (userIdToUUID uid) findUserByIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  FindUserByLoginId lid -> do
    res <- runSession (Session.statement (loginIdText lid) findUserByLoginIdStmt)
    row <- either dbFail pure res
    traverse rebuild row
  FindUserByEmail email -> do
    res <- runSession (Session.statement (emailText email) findUserByEmailStmt)
    row <- either dbFail pure res
    traverse rebuild row
  UpdateUserStatus uid st -> do
    res <- runSession (Session.statement (userIdToUUID uid, userStatusToText st) updateUserStatusStmt)
    either dbFail (const (pure ())) res
  MarkUserEmailVerified uid ts -> do
    res <- runSession (Session.statement (userIdToUUID uid, ts) markEmailVerifiedStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildUser r)

mkUser :: UserId -> NewUser -> UTCTime -> User
mkUser uid nu ts =
  User
    { userId = uid,
      loginId = nu.loginId,
      email = nu.email,
      displayName = nu.displayName,
      status = UserActive,
      emailVerifiedAt = Nothing,
      createdAt = ts,
      updatedAt = ts
    }

rebuildUser :: UserRow -> Either Text User
rebuildUser (uid, lid, e, dn, st, verified, c, u) = do
  loginId <- loginIdFromDb lid
  email <- maybeEmailFromDb e
  status <- userStatusFromText st
  pure
    User
      { userId = userIdFromUUID uid,
        loginId = loginId,
        email = email,
        displayName = dn,
        status = status,
        emailVerifiedAt = verified,
        createdAt = c,
        updatedAt = u
      }

userRowDecoder :: D.Row UserRow
userRowDecoder =
  (,,,,,,,)
    <$> D.column (D.nonNullable D.uuid)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)

insertUserStmt :: Statement InsertUserRow ()
insertUserStmt =
  preparable
    """
    INSERT INTO shomei.shomei_users
      (user_id, login_id, email, display_name, status, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    """
    ( contrazip7
        (E.param (E.nonNullable E.uuid))
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
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
    SELECT user_id, login_id, email, display_name, status, email_verified_at, created_at, updated_at
    FROM shomei.shomei_users
    WHERE user_id = $1
    """
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe userRowDecoder)

findUserByLoginIdStmt :: Statement Text (Maybe UserRow)
findUserByLoginIdStmt =
  preparable
    """
    SELECT user_id, login_id, email, display_name, status, email_verified_at, created_at, updated_at
    FROM shomei.shomei_users
    WHERE login_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe userRowDecoder)

findUserByEmailStmt :: Statement Text (Maybe UserRow)
findUserByEmailStmt =
  preparable
    """
    SELECT user_id, login_id, email, display_name, status, email_verified_at, created_at, updated_at
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

markEmailVerifiedStmt :: Statement (UUID, UTCTime) ()
markEmailVerifiedStmt =
  preparable
    """
    UPDATE shomei.shomei_users
    SET email_verified_at = $2, updated_at = $2
    WHERE user_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult
