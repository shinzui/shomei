{- | The signing-key lifecycle for @shomei-admin@ (EP-4, M2): generate → activate (old key
auto-retires) → retire → revoke, plus the two read helpers @keys list@ and the
publishable-key read used to build a JWKS during rotation.

Key state is read and written with binary-local @hasql@ statements rather than the
'Shomei.Effect.SigningKeyStore' effect, because (a) the effect's @ListActiveSigningKeys@ only
returns @active@ keys, but rotation needs to publish @active@ AND @retired@ keys, and (b) a CLI
benefits from one consistent, explicit SQL style with no effect-stack assembly. We deliberately
do NOT reuse @shomei-jwt@'s MasterPlan-1 @rotateSigningKey@ (which inserts new keys directly as
@active@); the CLI drives the fuller @pending → active → retired → revoked@ lifecycle, reusing
only key generation and the 'StoredSigningKey' conversion from @shomei-jwt@.
-}
module Shomei.Admin.Keys (
    keysGenerate,
    keysActivate,
    keysRetire,
    keysRevoke,
    keysList,
    listPublishableSigningKeys,
    listAllKeys,
) where

import Control.Monad (forM_, unless)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import "contravariant-extras" Contravariant.Extras (contrazip2, contrazip8)
import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session (Session)
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (Statement, preparable)
import "hasql-pool" Hasql.Pool (Pool)
import "hasql-pool" Hasql.Pool qualified as Pool

import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Jwt.Key (generateSigningKey, toStoredSigningKey)
import Shomei.Postgres.Codec (signingKeyStatusFromText, signingKeyStatusToText, tshow)

-- Public actions -------------------------------------------------------------

-- | Mint a new ES256 key in @pending@ status and print its @kid@.
keysGenerate :: Pool -> IO ()
keysGenerate pool = do
    now <- getCurrentTime
    jwk <- generateSigningKey
    let stored = toStoredSigningKey now jwk
        pending =
            stored
                { status = KeyPending
                , activatedAt = Nothing
                , retiredAt = Nothing
                }
    runSess pool (Session.statement (keyRow pending) insertKeyStmt)
    putStrLn ("generated pending key: " <> Text.unpack pending.keyId)

{- | Promote a @pending@ key to @active@ and demote every prior @active@ key to @retired@,
atomically at one timestamp. Refuses if the key is not @pending@.
-}
keysActivate :: Pool -> Text -> IO ()
keysActivate pool kid = do
    mk <- runSess pool (Session.statement kid findByKidStmt) >>= rebuildMaybe
    key <- requireKey kid mk
    unless (key.status == KeyPending) (die ("key " <> Text.unpack kid <> " is " <> show key.status <> ", expected pending"))
    now <- getCurrentTime
    priorActive <- listByStatus pool KeyActive
    runSess pool (Session.statement (kid, now) setActiveStmt)
    forM_ priorActive \old -> runSess pool (Session.statement (old.keyId, now) setRetiredStmt)
    putStrLn ("activated " <> Text.unpack kid)
    forM_ priorActive \old -> putStrLn ("retired (auto) " <> Text.unpack old.keyId)

-- | Demote an @active@ key to @retired@ (still trusted in the JWKS), stamping @retired_at@.
keysRetire :: Pool -> Text -> IO ()
keysRetire pool kid = do
    key <- requireKey kid =<< (runSess pool (Session.statement kid findByKidStmt) >>= rebuildMaybe)
    unless (key.status == KeyActive) (die ("key " <> Text.unpack kid <> " is " <> show key.status <> "; cannot retire"))
    now <- getCurrentTime
    runSess pool (Session.statement (kid, now) setRetiredStmt)
    putStrLn ("retired " <> Text.unpack kid)

{- | Mark a key @revoked@ (immediately untrusted, removed from the JWKS). Allowed from any
state except @revoked@.
-}
keysRevoke :: Pool -> Text -> IO ()
keysRevoke pool kid = do
    key <- requireKey kid =<< (runSess pool (Session.statement kid findByKidStmt) >>= rebuildMaybe)
    unless (key.status `elem` [KeyPending, KeyActive, KeyRetired]) (die ("key " <> Text.unpack kid <> " is already revoked"))
    runSess pool (Session.statement (kid, signingKeyStatusToText KeyRevoked) updateStatusStmt)
    putStrLn ("revoked " <> Text.unpack kid)

-- | Print every key with kid / status / timestamps.
keysList :: Pool -> IO ()
keysList pool = do
    keys <- listAllKeys pool
    if null keys
        then putStrLn "(no signing keys)"
        else forM_ keys \k ->
            putStrLn
                ( Text.unpack k.keyId
                    <> "\t"
                    <> show k.status
                    <> "\tcreated="
                    <> show k.createdAt
                    <> "\tactivated="
                    <> show k.activatedAt
                    <> "\tretired="
                    <> show k.retiredAt
                )

-- Read helpers (also used by the integration tests) --------------------------

-- | Keys that belong in the published JWKS: @active@ and @retired@ (overlap during rotation).
listPublishableSigningKeys :: Pool -> IO [StoredSigningKey]
listPublishableSigningKeys pool = runSess pool (Session.statement () listPublishableStmt) >>= traverse rebuild

listAllKeys :: Pool -> IO [StoredSigningKey]
listAllKeys pool = runSess pool (Session.statement () listAllStmt) >>= traverse rebuild

-- Internals ------------------------------------------------------------------

listByStatus :: Pool -> SigningKeyStatus -> IO [StoredSigningKey]
listByStatus pool st =
    runSess pool (Session.statement (signingKeyStatusToText st) listByStatusStmt) >>= traverse rebuild

requireKey :: Text -> Maybe StoredSigningKey -> IO StoredSigningKey
requireKey kid = maybe (die ("no such key: " <> Text.unpack kid)) pure

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure

runSess :: Pool -> Session a -> IO a
runSess pool s = do
    res <- Pool.use pool s
    either (\e -> die ("database error: " <> Text.unpack (tshow e))) pure res

rebuild :: KeyRow -> IO StoredSigningKey
rebuild r = either (\e -> die ("corrupt key row: " <> Text.unpack e)) pure (rebuildKey r)

rebuildMaybe :: Maybe KeyRow -> IO (Maybe StoredSigningKey)
rebuildMaybe = traverse rebuild

-- Row mapping and statements (mirror Shomei.Postgres.SigningKeyStore) ---------

type KeyRow = (Text, Text, Text, Text, Text, UTCTime, Maybe UTCTime, Maybe UTCTime)

keyRow :: StoredSigningKey -> KeyRow
keyRow k =
    ( k.keyId
    , k.algorithm
    , k.publicKeyJwk
    , k.privateKeyJwk
    , signingKeyStatusToText k.status
    , k.createdAt
    , k.activatedAt
    , k.retiredAt
    )

rebuildKey :: KeyRow -> Either Text StoredSigningKey
rebuildKey (kid, alg, pub, priv, st, c, act, ret) = do
    status <- signingKeyStatusFromText st
    pure StoredSigningKey{keyId = kid, algorithm = alg, publicKeyJwk = pub, privateKeyJwk = priv, status = status, createdAt = c, activatedAt = act, retiredAt = ret}

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

findByKidStmt :: Statement Text (Maybe KeyRow)
findByKidStmt =
    preparable
        """
        SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at
        FROM shomei.shomei_signing_keys WHERE key_id = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe keyRowDecoder)

listAllStmt :: Statement () [KeyRow]
listAllStmt =
    preparable
        """
        SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at
        FROM shomei.shomei_signing_keys ORDER BY created_at
        """
        E.noParams
        (D.rowList keyRowDecoder)

listByStatusStmt :: Statement Text [KeyRow]
listByStatusStmt =
    preparable
        """
        SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at
        FROM shomei.shomei_signing_keys WHERE status = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowList keyRowDecoder)

listPublishableStmt :: Statement () [KeyRow]
listPublishableStmt =
    preparable
        """
        SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at
        FROM shomei.shomei_signing_keys WHERE status IN ('active','retired') ORDER BY created_at
        """
        E.noParams
        (D.rowList keyRowDecoder)

insertKeyStmt :: Statement KeyRow ()
insertKeyStmt =
    preparable
        """
        INSERT INTO shomei.shomei_signing_keys
          (key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at)
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
        "UPDATE shomei.shomei_signing_keys SET status = $2 WHERE key_id = $1"
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
        D.noResult

setActiveStmt :: Statement (Text, UTCTime) ()
setActiveStmt =
    preparable
        "UPDATE shomei.shomei_signing_keys SET status = 'active', activated_at = $2 WHERE key_id = $1"
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult

setRetiredStmt :: Statement (Text, UTCTime) ()
setRetiredStmt =
    preparable
        "UPDATE shomei.shomei_signing_keys SET status = 'retired', retired_at = $2 WHERE key_id = $1"
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
        D.noResult
