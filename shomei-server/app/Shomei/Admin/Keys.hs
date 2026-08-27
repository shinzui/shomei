-- | The signing-key lifecycle for @shomei-admin@ (EP-4, M2): generate → activate (old key
-- auto-retires) → retire → revoke, plus the two read helpers @keys list@ and the
-- publishable-key read used to build a JWKS during rotation.
--
-- Key state is read and written with binary-local @hasql@ statements rather than the
-- 'Shomei.SigningKey.Store' effect, because (a) the effect's @ListActiveSigningKeys@ only
-- returns @active@ keys, but rotation needs to publish @active@ AND @retired@ keys, and (b) a CLI
-- benefits from one consistent, explicit SQL style with no effect-stack assembly. We deliberately
-- do NOT reuse @shomei-jwt@'s MasterPlan-1 @rotateSigningKey@ (which inserts new keys directly as
-- @active@); the CLI drives the fuller @pending → active → retired → revoked@ lifecycle, reusing
-- only key generation and the 'StoredSigningKey' conversion from @shomei-jwt@.
module Shomei.Admin.Keys
  ( keysGenerate,
    keysActivate,
    keysRetire,
    keysRevoke,
    keysList,
    keysRewrap,
    listPublishableSigningKeys,
    listAllKeys,
    summarizeUsageError,
  )
where

import Contravariant.Extras (contrazip2, contrazip9)
import Control.Monad (forM, forM_, unless)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Errors qualified as Hasql
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSession
import Shomei.Persistence.Codec.Postgres (signingKeyStatusFromText, signingKeyStatusToText)
import Shomei.Server.DatabaseError (summarizeUsageError)
import Shomei.SigningKey.Domain (SigningAlgorithm, SigningKeyStatus (..), StoredSigningKey (..), signingAlgorithmToText)
import Shomei.SigningKey.Key.Jwt (generateSigningKeyFor, toStoredSigningKeyFor)
import Shomei.SigningKey.Protection.Jwt
  ( KeyEncryptionKey,
    decryptPrivateJwk,
    encryptPrivateJwk,
    protectStoredSigningKey,
  )
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- Public actions -------------------------------------------------------------

-- | Mint a new key for @alg@ in @pending@ status and print its @kid@. When a
-- key-encryption key is configured, the private material is encrypted before it is written,
-- so a rotation never introduces a plaintext row into an encrypted table.
keysGenerate :: KeyEncryptionKey -> SigningAlgorithm -> Pool -> IO ()
keysGenerate kek alg pool = do
  now <- getCurrentTime
  jwk <- generateSigningKeyFor alg
  stored <- either (die . Text.unpack) pure (toStoredSigningKeyFor alg now jwk)
  pending <-
    protectStoredSigningKey
      kek
      stored
        { status = KeyPending,
          activatedAt = Nothing,
          retiredAt = Nothing,
          revokedAt = Nothing
        }
  runSess pool (Session.statement (keyRow pending) insertKeyStmt)
  putStrLn ("generated pending " <> Text.unpack (signingAlgorithmToText alg) <> " key: " <> Text.unpack pending.keyId)

-- | Promote a @pending@ key to @active@ and demote every prior @active@ key to @retired@,
-- atomically at one timestamp. Refuses if the key is not @pending@.
keysActivate :: Pool -> Text -> IO ()
keysActivate pool kid = do
  mk <- runSess pool (Session.statement kid findByKidStmt) >>= rebuildMaybe
  key <- requireKey kid mk
  unless (key.status == KeyPending) (die ("key " <> Text.unpack kid <> " is " <> show key.status <> ", expected pending"))
  now <- getCurrentTime
  retired <- runTx pool do
    oldKids <- Tx.statement now retireActiveStmt
    Tx.statement (kid, now) setActiveStmt
    pure oldKids
  putStrLn ("activated " <> Text.unpack kid)
  forM_ retired \oldKid -> putStrLn ("retired (auto) " <> Text.unpack oldKid)

-- | Demote an @active@ key to @retired@ (still trusted in the JWKS), stamping @retired_at@.
keysRetire :: Pool -> Text -> IO ()
keysRetire pool kid = do
  key <- requireKey kid =<< (runSess pool (Session.statement kid findByKidStmt) >>= rebuildMaybe)
  unless (key.status == KeyActive) (die ("key " <> Text.unpack kid <> " is " <> show key.status <> "; cannot retire"))
  now <- getCurrentTime
  runSess pool (Session.statement (kid, now) setRetiredStmt)
  putStrLn ("retired " <> Text.unpack kid)

-- | Mark a key @revoked@ (immediately untrusted, removed from the JWKS). Allowed from any
-- state except @revoked@.
keysRevoke :: Pool -> Text -> IO ()
keysRevoke pool kid = do
  key <- requireKey kid =<< (runSess pool (Session.statement kid findByKidStmt) >>= rebuildMaybe)
  unless (key.status `elem` [KeyPending, KeyActive, KeyRetired]) (die ("key " <> Text.unpack kid <> " is already revoked"))
  now <- getCurrentTime
  runSess pool (Session.statement (kid, now) setRevokedStmt)
  putStrLn ("revoked " <> Text.unpack kid)

-- | Re-wrap every key under a new KEK: decrypt with @oldKek@, encrypt with @newKek@. Any
-- All-or-nothing: the full decrypt pass runs in memory /before/ the first write, so a wrong
-- @SHOMEI_KEY_ENCRYPTION_KEY_OLD@ aborts having modified nothing. (A half-rewrapped table
-- would be unreadable by either KEK.)
keysRewrap :: KeyEncryptionKey -> KeyEncryptionKey -> Pool -> IO ()
keysRewrap oldKek newKek pool = do
  keys <- listAllKeys pool
  -- Pass 1: decrypt everything, or die before touching a row.
  decrypted <- traverse decryptOne keys
  -- Pass 2: re-encrypt every row before opening the all-or-nothing write transaction.
  rewrapped <- forM decrypted \(k, plain) -> do
    enc <- encryptPrivateJwk newKek k.keyId plain
    pure (k.keyId, enc)
  runTx pool (forM_ rewrapped \row -> Tx.statement row setPrivateKeyStmt)
  putStrLn ("rewrapped " <> show (length decrypted) <> " key(s)")
  where
    decryptOne k =
      case decryptPrivateJwk oldKek k.keyId k.privateKeyJwk of
        Right plain -> pure (k, plain)
        Left err ->
          die
            ( "cannot decrypt key "
                <> Text.unpack k.keyId
                <> " with SHOMEI_KEY_ENCRYPTION_KEY_OLD ("
                <> show err
                <> "); no rows were modified"
            )

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
            <> "\trevoked="
            <> show k.revokedAt
        )

-- Read helpers (also used by the integration tests) --------------------------

-- | Keys that belong in the published JWKS: @active@ and @retired@ (overlap during rotation).
listPublishableSigningKeys :: Pool -> IO [StoredSigningKey]
listPublishableSigningKeys pool = runSess pool (Session.statement () listPublishableStmt) >>= traverse rebuild

listAllKeys :: Pool -> IO [StoredSigningKey]
listAllKeys pool = runSess pool (Session.statement () listAllStmt) >>= traverse rebuild

-- Internals ------------------------------------------------------------------

requireKey :: Text -> Maybe StoredSigningKey -> IO StoredSigningKey
requireKey kid = maybe (die ("no such key: " <> Text.unpack kid)) pure

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure

runSess :: Pool -> Session a -> IO a
runSess pool s = do
  res <- Pool.use pool s
  either (\e -> die (Text.unpack (summarizeUsageError e))) pure res

runTx :: Pool -> Transaction a -> IO a
runTx pool transaction = do
  res <- Pool.use pool (TxSession.transaction TxSession.ReadCommitted TxSession.Write transaction)
  case res of
    Right value -> pure value
    Left err
      | uniqueViolation err ->
          die "another key became active concurrently; run keys list and retry"
      | otherwise -> die (Text.unpack (summarizeUsageError err))
  where
    uniqueViolation = \case
      Pool.SessionUsageError
        ( Hasql.StatementSessionError
            _
            _
            _
            _
            _
            (Hasql.ServerStatementError (Hasql.ServerError "23505" _ _ _ _))
          ) -> True
      _ -> False

rebuild :: KeyRow -> IO StoredSigningKey
rebuild r = either (\e -> die ("corrupt key row: " <> Text.unpack e)) pure (rebuildKey r)

rebuildMaybe :: Maybe KeyRow -> IO (Maybe StoredSigningKey)
rebuildMaybe = traverse rebuild

-- Row mapping and statements (mirror Shomei.SigningKey.Postgres) ---------

type KeyRow = (Text, Text, Text, Text, Text, UTCTime, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime)

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
  pure StoredSigningKey {keyId = kid, algorithm = alg, publicKeyJwk = pub, privateKeyJwk = priv, status = status, createdAt = c, activatedAt = act, retiredAt = ret, revokedAt = rev}

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

findByKidStmt :: Statement Text (Maybe KeyRow)
findByKidStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at, revoked_at
    FROM shomei.shomei_signing_keys WHERE key_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe keyRowDecoder)

listAllStmt :: Statement () [KeyRow]
listAllStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at, revoked_at
    FROM shomei.shomei_signing_keys ORDER BY created_at
    """
    E.noParams
    (D.rowList keyRowDecoder)

listPublishableStmt :: Statement () [KeyRow]
listPublishableStmt =
  preparable
    """
    SELECT key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at, revoked_at
    FROM shomei.shomei_signing_keys WHERE status IN ('active','retired') ORDER BY created_at
    """
    E.noParams
    (D.rowList keyRowDecoder)

insertKeyStmt :: Statement KeyRow ()
insertKeyStmt =
  preparable
    """
    INSERT INTO shomei.shomei_signing_keys
      (key_id, algorithm, public_key_jwk, private_key_jwk, status, created_at, activated_at, retired_at, revoked_at)
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

-- | Replace a key's private material (encrypt-at-rest backfill and KEK rewrap). Never
-- touches @public_key_jwk@ or @status@.
setPrivateKeyStmt :: Statement (Text, Text) ()
setPrivateKeyStmt =
  preparable
    "UPDATE shomei.shomei_signing_keys SET private_key_jwk = $2 WHERE key_id = $1"
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

retireActiveStmt :: Statement UTCTime [Text]
retireActiveStmt =
  preparable
    """
    UPDATE shomei.shomei_signing_keys
    SET status = 'retired', retired_at = $1
    WHERE status = 'active'
    RETURNING key_id
    """
    (E.param (E.nonNullable E.timestamptz))
    (D.rowList (D.column (D.nonNullable D.text)))

setRevokedStmt :: Statement (Text, UTCTime) ()
setRevokedStmt =
  preparable
    "UPDATE shomei.shomei_signing_keys SET status = 'revoked', revoked_at = $2 WHERE key_id = $1"
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult
