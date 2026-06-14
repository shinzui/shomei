-- | PostgreSQL interpreter for the password-reset token store.
module Shomei.Postgres.PasswordResetTokenStore (
    runPasswordResetTokenStorePostgres,
) where

import Shomei.Prelude

import Data.UUID (UUID)
import Contravariant.Extras (contrazip2, contrazip8)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.OneTimeToken (OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Effect.PasswordResetTokenStore (PasswordResetTokenStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (
    PasswordResetTokenId,
    genPasswordResetTokenId,
    passwordResetTokenIdFromUUID,
    passwordResetTokenIdToUUID,
    userIdFromUUID,
    userIdToUUID,
 )
import Shomei.Postgres.Codec (oneTimeTokenStatusFromText, oneTimeTokenStatusToText, tshow)
import Shomei.Postgres.Database (Database, runSession)

type TokenRow = (UUID, UUID, Text, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UTCTime)

runPasswordResetTokenStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (PasswordResetTokenStore : es) a ->
    Eff es a
runPasswordResetTokenStorePostgres = interpret_ \case
    CreatePasswordResetToken nrt -> do
        tid <- genPasswordResetTokenId
        let persisted = mkPersisted tid nrt
            row =
                ( passwordResetTokenIdToUUID tid
                , userIdToUUID nrt.userId
                , tokenHashText nrt.tokenHash
                , oneTimeTokenStatusToText OneTimeTokenActive
                , nrt.createdAt
                , nrt.expiresAt
                , Nothing
                , Nothing
                )
        res <- runSession (Session.statement row insertTokenStmt)
        either dbFail (const (pure persisted)) res
    FindPasswordResetTokenByHash h -> do
        res <- runSession (Session.statement (tokenHashText h) findByHashStmt)
        row <- either dbFail pure res
        traverse rebuild row
    MarkPasswordResetTokenConsumed tid t -> do
        res <- runSession (Session.statement (passwordResetTokenIdToUUID tid, t) markConsumedStmt)
        either dbFail (const (pure ())) res
    RevokeUserPasswordResetTokens uid t -> do
        res <- runSession (Session.statement (userIdToUUID uid, t) revokeUserTokensStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildToken r)

tokenHashText :: OneTimeTokenHash -> Text
tokenHashText (OneTimeTokenHash t) = t

mkPersisted :: PasswordResetTokenId -> NewPasswordResetToken -> PersistedPasswordResetToken
mkPersisted tid nrt =
    PersistedPasswordResetToken
        { passwordResetTokenId = tid
        , userId = nrt.userId
        , tokenHash = nrt.tokenHash
        , status = OneTimeTokenActive
        , createdAt = nrt.createdAt
        , expiresAt = nrt.expiresAt
        , consumedAt = Nothing
        , revokedAt = Nothing
        }

rebuildToken :: TokenRow -> Either Text PersistedPasswordResetToken
rebuildToken (tid, uid, h, st, c, e, consumed, revoked) = do
    status <- oneTimeTokenStatusFromText st
    pure
        PersistedPasswordResetToken
            { passwordResetTokenId = passwordResetTokenIdFromUUID tid
            , userId = userIdFromUUID uid
            , tokenHash = OneTimeTokenHash h
            , status = status
            , createdAt = c
            , expiresAt = e
            , consumedAt = consumed
            , revokedAt = revoked
            }

tokenRowDecoder :: D.Row TokenRow
tokenRowDecoder =
    (,,,,,,,)
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)

insertTokenStmt :: Statement TokenRow ()
insertTokenStmt =
    preparable
        """
        INSERT INTO shomei.shomei_password_reset_tokens
          (password_reset_token_id, user_id, token_hash, status, created_at, expires_at,
           consumed_at, revoked_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        """
        ( contrazip8
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nullable E.timestamptz))
            (E.param (E.nullable E.timestamptz))
        )
        D.noResult

findByHashStmt :: Statement Text (Maybe TokenRow)
findByHashStmt =
    preparable
        """
        SELECT password_reset_token_id, user_id, token_hash, status, created_at, expires_at,
               consumed_at, revoked_at
        FROM shomei.shomei_password_reset_tokens
        WHERE token_hash = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe tokenRowDecoder)

markConsumedStmt :: Statement (UUID, UTCTime) ()
markConsumedStmt =
    preparable
        """
        UPDATE shomei.shomei_password_reset_tokens
        SET status = 'consumed', consumed_at = $2
        WHERE password_reset_token_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult

revokeUserTokensStmt :: Statement (UUID, UTCTime) ()
revokeUserTokensStmt =
    preparable
        """
        UPDATE shomei.shomei_password_reset_tokens
        SET status = 'revoked', revoked_at = $2
        WHERE user_id = $1
          AND status = 'active'
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult
