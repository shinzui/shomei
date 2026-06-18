-- | PostgreSQL interpreter for the 'SigningKeyStore' port. JWK material is stored as
-- opaque @text@ (IP-4); only @shomei-jwt@ interprets it.
module Shomei.Postgres.SigningKeyStore
  ( runSigningKeyStorePostgres,
  )
where

import Contravariant.Extras (contrazip2, contrazip8)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shomei.Domain.SigningKey (StoredSigningKey (..))
import Shomei.Effect.SigningKeyStore (SigningKeyStore (..))
import Shomei.Error (AuthError (..))
import Shomei.Postgres.Codec (signingKeyStatusFromText, signingKeyStatusToText, tshow)
import Shomei.Postgres.Database (Database, runSession)
import Shomei.Prelude

type KeyRow = (Text, Text, Text, Text, Text, UTCTime, Maybe UTCTime, Maybe UTCTime)

runSigningKeyStorePostgres ::
  (Database :> es, Error AuthError :> es) =>
  Eff (SigningKeyStore : es) a ->
  Eff es a
runSigningKeyStorePostgres = interpret_ \case
  ListActiveSigningKeys -> do
    res <- runSession (Session.statement () listActiveStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  FindSigningKeyByKid kid -> do
    res <- runSession (Session.statement kid findByKidStmt)
    row <- either dbFail pure res
    traverse rebuild row
  InsertSigningKey k -> do
    res <- runSession (Session.statement (keyRow k) insertKeyStmt)
    either dbFail (const (pure ())) res
  UpdateSigningKeyStatus kid st _t -> do
    res <- runSession (Session.statement (kid, signingKeyStatusToText st) updateStatusStmt)
    either dbFail (const (pure ())) res
  where
    dbFail e = throwError (InternalAuthError ("database error: " <> tshow e))
    rebuild r = either (throwError . InternalAuthError) pure (rebuildKey r)

keyRow :: StoredSigningKey -> KeyRow
keyRow k =
  ( k.keyId,
    k.algorithm,
    k.publicKeyJwk,
    k.privateKeyJwk,
    signingKeyStatusToText k.status,
    k.createdAt,
    k.activatedAt,
    k.retiredAt
  )

rebuildKey :: KeyRow -> Either Text StoredSigningKey
rebuildKey (kid, alg, pub, priv, st, c, act, ret) = do
  status <- signingKeyStatusFromText st
  pure
    StoredSigningKey
      { keyId = kid,
        algorithm = alg,
        publicKeyJwk = pub,
        privateKeyJwk = priv,
        status = status,
        createdAt = c,
        activatedAt = act,
        retiredAt = ret
      }

keyRowDecoder :: D.Row KeyRow
keyRowDecoder =
  (,,,,,,,)
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

listActiveStmt :: Statement () [KeyRow]
listActiveStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
           created_at, activated_at, retired_at
    FROM shomei.shomei_signing_keys
    WHERE status = 'active'
    """
    E.noParams
    (D.rowList keyRowDecoder)

findByKidStmt :: Statement Text (Maybe KeyRow)
findByKidStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
           created_at, activated_at, retired_at
    FROM shomei.shomei_signing_keys
    WHERE key_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe keyRowDecoder)

insertKeyStmt :: Statement KeyRow ()
insertKeyStmt =
  preparable
    """
    INSERT INTO shomei.shomei_signing_keys
      (key_id, algorithm, public_key_jwk, private_key_jwk, status,
       created_at, activated_at, retired_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    """
    ( contrazip8
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
    )
    D.noResult

updateStatusStmt :: Statement (Text, Text) ()
updateStatusStmt =
  preparable
    """
    UPDATE shomei.shomei_signing_keys SET status = $2 WHERE key_id = $1
    """
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
    D.noResult
