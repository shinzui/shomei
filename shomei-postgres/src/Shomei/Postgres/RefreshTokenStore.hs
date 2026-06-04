{- | PostgreSQL interpreter for the 'RefreshTokenStore' port, including the recursive-CTE
family revocation that powers reuse detection.
-}
module Shomei.Postgres.RefreshTokenStore (
    runRefreshTokenStorePostgres,
) where

import Shomei.Prelude

import Data.UUID (UUID)
import "contravariant-extras" Contravariant.Extras (contrazip2, contrazip9)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)

import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)

import Shomei.Domain.RefreshToken (
    NewRefreshToken (..),
    PersistedRefreshToken (..),
    RefreshTokenHash (..),
    RefreshTokenStatus (RefreshTokenActive),
 )
import Shomei.Error (AuthError (..))
import Shomei.Id (
    RefreshTokenId,
    genRefreshTokenId,
    refreshTokenIdFromUUID,
    refreshTokenIdToUUID,
    sessionIdFromUUID,
    sessionIdToUUID,
    userIdToUUID,
 )
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore (..))
import Shomei.Postgres.Codec (refreshTokenStatusFromText, refreshTokenStatusToText, tshow)
import Shomei.Postgres.Database (Database, runSession)

type RefreshTokenRow =
    (UUID, UUID, Text, Maybe UUID, Text, UTCTime, UTCTime, Maybe UTCTime, Maybe UTCTime)

runRefreshTokenStorePostgres ::
    (Database :> es, IOE :> es, Error AuthError :> es) =>
    Eff (RefreshTokenStore : es) a ->
    Eff es a
runRefreshTokenStorePostgres = interpret_ \case
    CreateRefreshToken nrt -> do
        rid <- genRefreshTokenId
        let persisted = mkPersisted rid nrt
            row =
                ( refreshTokenIdToUUID rid
                , sessionIdToUUID nrt.sessionId
                , refreshTokenHashText nrt.tokenHash
                , fmap refreshTokenIdToUUID nrt.parentTokenId
                , refreshTokenStatusToText RefreshTokenActive
                , nrt.createdAt
                , nrt.expiresAt
                , Nothing
                , Nothing
                )
        res <- runSession (Session.statement row insertRefreshTokenStmt)
        either dbFail (const (pure persisted)) res
    FindRefreshTokenByHash h -> do
        res <- runSession (Session.statement (refreshTokenHashText h) findByHashStmt)
        row <- either dbFail pure res
        traverse rebuild row
    MarkRefreshTokenUsed rid t -> do
        res <- runSession (Session.statement (refreshTokenIdToUUID rid, t) markUsedStmt)
        either dbFail (const (pure ())) res
    RevokeRefreshTokenFamily rid t -> do
        res <- runSession (Session.statement (refreshTokenIdToUUID rid, t) revokeFamilyStmt)
        either dbFail (const (pure ())) res
    RevokeSessionRefreshTokens sid t -> do
        res <- runSession (Session.statement (sessionIdToUUID sid, t) revokeSessionTokensStmt)
        either dbFail (const (pure ())) res
    RevokeAllUserRefreshTokens uid t -> do
        res <- runSession (Session.statement (userIdToUUID uid, t) revokeUserTokensStmt)
        either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildToken r)

refreshTokenHashText :: RefreshTokenHash -> Text
refreshTokenHashText (RefreshTokenHash t) = t

mkPersisted :: RefreshTokenId -> NewRefreshToken -> PersistedRefreshToken
mkPersisted rid nrt =
    PersistedRefreshToken
        { refreshTokenId = rid
        , sessionId = nrt.sessionId
        , tokenHash = nrt.tokenHash
        , parentTokenId = nrt.parentTokenId
        , status = RefreshTokenActive
        , createdAt = nrt.createdAt
        , expiresAt = nrt.expiresAt
        , usedAt = Nothing
        , revokedAt = Nothing
        }

rebuildToken :: RefreshTokenRow -> Either Text PersistedRefreshToken
rebuildToken (rid, sid, h, parent, st, c, e, used, revoked) = do
    status <- refreshTokenStatusFromText st
    pure
        PersistedRefreshToken
            { refreshTokenId = refreshTokenIdFromUUID rid
            , sessionId = sessionIdFromUUID sid
            , tokenHash = RefreshTokenHash h
            , parentTokenId = fmap refreshTokenIdFromUUID parent
            , status = status
            , createdAt = c
            , expiresAt = e
            , usedAt = used
            , revokedAt = revoked
            }

tokenRowDecoder :: D.Row RefreshTokenRow
tokenRowDecoder =
    (,,,,,,,,)
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)

insertRefreshTokenStmt :: Statement RefreshTokenRow ()
insertRefreshTokenStmt =
    preparable
        """
        INSERT INTO shomei.shomei_refresh_tokens
          (refresh_token_id, session_id, token_hash, parent_token_id, status,
           created_at, expires_at, used_at, revoked_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """
        ( contrazip9
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nullable E.uuid))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nonNullable E.timestamptz))
            (E.param (E.nullable E.timestamptz))
            (E.param (E.nullable E.timestamptz))
        )
        D.noResult

findByHashStmt :: Statement Text (Maybe RefreshTokenRow)
findByHashStmt =
    preparable
        """
        SELECT refresh_token_id, session_id, token_hash, parent_token_id, status,
               created_at, expires_at, used_at, revoked_at
        FROM shomei.shomei_refresh_tokens
        WHERE token_hash = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe tokenRowDecoder)

markUsedStmt :: Statement (UUID, UTCTime) ()
markUsedStmt =
    preparable
        """
        UPDATE shomei.shomei_refresh_tokens
        SET status = 'used', used_at = $2
        WHERE refresh_token_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult

-- Walk up from the presented token to the family root (the ancestor with no parent),
-- then walk down from that root to collect every descendant, and revoke the whole family.
revokeFamilyStmt :: Statement (UUID, UTCTime) ()
revokeFamilyStmt =
    preparable
        """
        WITH RECURSIVE ancestors AS (
          SELECT refresh_token_id, parent_token_id
          FROM shomei.shomei_refresh_tokens
          WHERE refresh_token_id = $1
          UNION
          SELECT t.refresh_token_id, t.parent_token_id
          FROM shomei.shomei_refresh_tokens t
          JOIN ancestors a ON t.refresh_token_id = a.parent_token_id
        ),
        root AS (
          SELECT refresh_token_id FROM ancestors WHERE parent_token_id IS NULL LIMIT 1
        ),
        family AS (
          SELECT refresh_token_id FROM root
          UNION
          SELECT t.refresh_token_id
          FROM shomei.shomei_refresh_tokens t
          JOIN family f ON t.parent_token_id = f.refresh_token_id
        )
        UPDATE shomei.shomei_refresh_tokens
        SET status = 'revoked', revoked_at = $2
        WHERE refresh_token_id IN (SELECT refresh_token_id FROM family)
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult

revokeSessionTokensStmt :: Statement (UUID, UTCTime) ()
revokeSessionTokensStmt =
    preparable
        """
        UPDATE shomei.shomei_refresh_tokens
        SET status = 'revoked', revoked_at = $2
        WHERE session_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult

revokeUserTokensStmt :: Statement (UUID, UTCTime) ()
revokeUserTokensStmt =
    preparable
        """
        UPDATE shomei.shomei_refresh_tokens rt
        SET status = 'revoked', revoked_at = $2
        FROM shomei.shomei_sessions s
        WHERE rt.session_id = s.session_id
          AND s.user_id = $1
        """
        (contrazip2 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult
