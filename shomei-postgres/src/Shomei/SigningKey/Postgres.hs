-- | PostgreSQL interpreter for the 'SigningKeyStore' port. JWK material is stored as
-- opaque @text@ (IP-4); only @shomei-jwt@ interprets it.
module Shomei.SigningKey.Postgres
  ( runSigningKeyStorePostgres,
  )
where

import Contravariant.Extras (contrazip3, contrazip9)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Shomei.Error (AuthError (..))
import Shomei.Persistence.Codec.Postgres (signingKeyStatusFromText, signingKeyStatusToText)
import Shomei.Persistence.Database.Postgres (Database, postgresUnavailable, runSession, runTransaction)
import Shomei.Prelude
import Shomei.SigningKey.Domain (SigningKeyStatus (KeyActive), StoredSigningKey (..))
import Shomei.SigningKey.Store (SigningKeyStore (..))

type KeyRow = (Text, Text, Text, Text, Text, UTCTime, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime)

runSigningKeyStorePostgres ::
  (Database :> es, Error AuthError :> es) =>
  Eff (SigningKeyStore : es) a ->
  Eff es a
runSigningKeyStorePostgres = interpret_ \case
  ListActiveSigningKeys -> do
    res <- runSession (Session.statement () listActiveStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  ListPublishableSigningKeys -> do
    res <- runSession (Session.statement () listPublishableStmt)
    rows <- either dbFail pure res
    traverse rebuild rows
  FindSigningKeyByKid kid -> do
    res <- runSession (Session.statement kid findByKidStmt)
    row <- either dbFail pure res
    traverse rebuild row
  InsertSigningKey k -> do
    res <- runSession (Session.statement (keyRow k) insertKeyStmt)
    either dbFail (const (pure ())) res
  UpdateSigningKeyStatus kid st t -> do
    res <- runSession (Session.statement (kid, signingKeyStatusToText st, t) updateStatusStmt)
    either dbFail (const (pure ())) res
  ReplaceActiveSigningKey key t -> do
    let active = key {status = KeyActive, activatedAt = Just t}
    res <- runTransaction do
      Tx.statement t retireActiveStmt
      Tx.statement (keyRow active) upsertActiveStmt
    either dbFail (const (pure ())) res
  where
    dbFail = throwError . postgresUnavailable
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
    k.retiredAt,
    k.revokedAt
  )

rebuildKey :: KeyRow -> Either Text StoredSigningKey
rebuildKey (kid, alg, pub, priv, st, c, act, ret, rev) = do
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
        retiredAt = ret,
        revokedAt = rev
      }

keyRowDecoder :: D.Row KeyRow
keyRowDecoder =
  (,,,,,,,,)
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)

listActiveStmt :: Statement () [KeyRow]
listActiveStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
           created_at, activated_at, retired_at, revoked_at
    FROM shomei.shomei_signing_keys
    WHERE status = 'active'
    """
    E.noParams
    (D.rowList keyRowDecoder)

-- | The keys that belong in the published JWKS and the verifier key set: @active@ plus
-- @retired@ (still trusted so tokens minted before a rotation keep verifying). Ordered by
-- @created_at@ for stable output.
listPublishableStmt :: Statement () [KeyRow]
listPublishableStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
           created_at, activated_at, retired_at, revoked_at
    FROM shomei.shomei_signing_keys
    WHERE status IN ('active','retired')
    ORDER BY created_at
    """
    E.noParams
    (D.rowList keyRowDecoder)

findByKidStmt :: Statement Text (Maybe KeyRow)
findByKidStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status,
           created_at, activated_at, retired_at, revoked_at
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
       created_at, activated_at, retired_at, revoked_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    """
    ( contrazip9
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
    )
    D.noResult

updateStatusStmt :: Statement (Text, Text, UTCTime) ()
updateStatusStmt =
  preparable
    """
    UPDATE shomei.shomei_signing_keys
    SET status = $2,
        activated_at = CASE WHEN $2 = 'active'  THEN $3 ELSE activated_at END,
        retired_at   = CASE WHEN $2 = 'retired' THEN $3 ELSE retired_at END,
        revoked_at   = CASE WHEN $2 = 'revoked' THEN $3 ELSE revoked_at END
    WHERE key_id = $1
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

retireActiveStmt :: Statement UTCTime ()
retireActiveStmt =
  preparable
    """
    UPDATE shomei.shomei_signing_keys
    SET status = 'retired', retired_at = $1
    WHERE status = 'active'
    """
    (E.param (E.nonNullable E.timestamptz))
    D.noResult

upsertActiveStmt :: Statement KeyRow ()
upsertActiveStmt =
  preparable
    """
    INSERT INTO shomei.shomei_signing_keys
      (key_id, algorithm, public_key_jwk, private_key_jwk, status,
       created_at, activated_at, retired_at, revoked_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (key_id) DO UPDATE
    SET status = 'active', activated_at = EXCLUDED.activated_at
    """
    ( contrazip9
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
        (E.param (E.nullable E.timestamptz))
    )
    D.noResult
