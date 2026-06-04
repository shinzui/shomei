-- | PostgreSQL interpreter for the email-verification token store.
module Shomei.Postgres.VerificationTokenStore (
    runVerificationTokenStorePostgres,
) where

import Shomei.Prelude

import Data.UUID (UUID)
import "contravariant-extras" Contravariant.Extras (contrazip2, contrazip8)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.OneTimeToken (OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.VerificationToken (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Effect.VerificationTokenStore (VerificationTokenStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (
    VerificationTokenId,
    genVerificationTokenId,
    userIdFromUUID,
    userIdToUUID,
    verificationTokenIdFromUUID,
    verificationTokenIdToUUID,
 )
import Shomei.Postgres.Codec (oneTimeTokenStatusFromText, oneTimeTokenStatusToText, tshow)
import Shomei.Postgres.Database (Database, runSession)

type TokenRow = (UUID, UUID, Text, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UTCTime)

runVerificationTokenStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (VerificationTokenStore : es) a ->
    Eff es a
runVerificationTokenStorePostgres = interpret_ \case
    CreateVerificationToken nvt -> do
        tid <- genVerificationTokenId
        let persisted = mkPersisted tid nvt
            row =
                ( verificationTokenIdToUUID tid
                , userIdToUUID nvt.userId
                , tokenHashText nvt.tokenHash
                , oneTimeTokenStatusToText OneTimeTokenActive
                , nvt.createdAt
                , nvt.expiresAt
                , Nothing
                , Nothing
                )
        res <- runSession (Session.statement row insertTokenStmt)
        either dbFail (const (pure persisted)) res
    FindVerificationTokenByHash h -> do
        res <- runSession (Session.statement (tokenHashText h) findByHashStmt)
        row <- either dbFail pure res
        traverse rebuild row
    MarkVerificationTokenConsumed tid t -> do
        res <- runSession (Session.statement (verificationTokenIdToUUID tid, t) markConsumedStmt)
        either dbFail (const (pure ())) res
    RevokeUserVerificationTokens uid t -> do
        res <- runSession (Session.statement (userIdToUUID uid, t) revokeUserTokensStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildToken r)

tokenHashText :: OneTimeTokenHash -> Text
tokenHashText (OneTimeTokenHash t) = t

mkPersisted :: VerificationTokenId -> NewVerificationToken -> PersistedVerificationToken
mkPersisted tid nvt =
    PersistedVerificationToken
        { verificationTokenId = tid
        , userId = nvt.userId
        , tokenHash = nvt.tokenHash
        , status = OneTimeTokenActive
        , createdAt = nvt.createdAt
        , expiresAt = nvt.expiresAt
        , consumedAt = Nothing
        , revokedAt = Nothing
        }

rebuildToken :: TokenRow -> Either Text PersistedVerificationToken
rebuildToken (tid, uid, h, st, c, e, consumed, revoked) = do
    status <- oneTimeTokenStatusFromText st
    pure
        PersistedVerificationToken
            { verificationTokenId = verificationTokenIdFromUUID tid
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
        INSERT INTO shomei.shomei_email_verification_tokens
          (verification_token_id, user_id, token_hash, status, created_at, expires_at,
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
        SELECT verification_token_id, user_id, token_hash, status, created_at, expires_at,
               consumed_at, revoked_at
        FROM shomei.shomei_email_verification_tokens
        WHERE token_hash = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe tokenRowDecoder)

markConsumedStmt :: Statement (UUID, UTCTime) ()
markConsumedStmt =
    preparable
        """
        UPDATE shomei.shomei_email_verification_tokens
        SET status = 'consumed', consumed_at = $2
        WHERE verification_token_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult

revokeUserTokensStmt :: Statement (UUID, UTCTime) ()
revokeUserTokensStmt =
    preparable
        """
        UPDATE shomei.shomei_email_verification_tokens
        SET status = 'revoked', revoked_at = $2
        WHERE user_id = $1
          AND status = 'active'
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult
