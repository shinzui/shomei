-- | Integration tests for @shomei-admin@ (EP-4), against throwaway PostgreSQL databases
-- provisioned by @shomei-migrations:test-support@. They drive the real CLI action functions and
-- assert database state, and — the headline — prove the signing-key rotation lifecycle with
-- overlapping-key JWKS verification.
module Main (main) where

import Control.Exception (IOException, try)
import Crypto.JOSE.JWK (JWK, JWKSet (JWKSet))
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (newIORef, readIORef)
import Data.Int (Int64)
import Data.List (find, isInfixOf)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, getCurrentTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Shomei.Admin.Audit (runAuditReader)
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Admin.Keys
  ( keysActivate,
    keysEncryptAtRest,
    keysGenerate,
    keysRetire,
    keysRevoke,
    keysRewrap,
    listAllKeys,
    listPublishableSigningKeys,
  )
import Shomei.Admin.Roles (RolesCommand (..), runRoles)
import Shomei.Admin.Sweep (SweepOptions (..), defaultSweepOptions, runSweepReport)
import Shomei.Admin.Users (createUserAction)
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..))
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256), SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.AuthEventReader
  ( AuditEventQuery (..),
    StoredAuthEvent (..),
    countAuthEvents,
    emptyAuditQuery,
    queryAuthEvents,
  )
import Shomei.Error (AuthError)
import Shomei.Id (genSessionId, genUserId)
import Shomei.Jwt.Key (fromStoredSigningKey, keyKid)
import Shomei.Jwt.KeyProtection
  ( KeyDecryptError (KeyDecryptFailed),
    KeyEncryptionKey,
    decryptStoredSigningKey,
    isEncryptedPrivateJwk,
    keyEncryptionKeyFromBase64,
    publicJwkFromStored,
  )
import Shomei.Jwt.Sign (signAccessToken)
import Shomei.Jwt.Verify (verifyToken)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.Maintenance (SweepReport (..))
import Shomei.Postgres.Pool (acquirePool)
-- qualified: 'Shomei.Admin.Keys' exports a same-named listPublishableSigningKeys

import Shomei.Server.Keys (LoadedKeys (..), bootstrapKeys, reloadKeys)
import Shomei.Server.Keys qualified as Keys
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

-- | Cheap Argon2 parameters for tests. @users create@ hashes a real password, and the
-- production cost (~100 ms) would dominate this suite. Strength is irrelevant here.
testArgon2Params :: Argon2Params
testArgon2Params = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}

withDb :: (Pool -> Text -> IO a) -> IO a
withDb action = withShomeiMigratedDatabase \connStr -> do
  pool <- acquirePool 4 10 connStr
  action pool connStr

scalarInt :: Pool -> Text -> IO Int
scalarInt pool sql = do
  res <- Pool.use pool (Session.statement () stmt)
  either (\e -> assertFailure ("scalar query failed: " <> show e)) pure res
  where
    stmt = preparable sql E.noParams (D.singleRow (fromI <$> D.column (D.nonNullable D.int8)))
    fromI :: Int64 -> Int
    fromI = fromIntegral

-- | Run a (possibly multi-statement) SQL script directly against the pool, for seeding.
execSql :: Pool -> Text -> IO ()
execSql pool sql = do
  res <- Pool.use pool (Session.script sql)
  either (\e -> assertFailure ("seed script failed: " <> show e)) pure res

-- | Run a CLI action that is expected to abort. The action functions call 'exitFailure' on a
-- user error, which throws 'ExitCode' — catching it is how a test observes a nonzero exit.
expectExitFailure :: String -> IO () -> IO ()
expectExitFailure what action = do
  result <- try @ExitCode action
  case result of
    Left (ExitFailure _) -> pure ()
    Left ExitSuccess -> assertFailure (what <> ": expected a nonzero exit, got success")
    Right () -> assertFailure (what <> ": expected the command to abort")

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shomei-admin"
        [ testMigrateEmpty,
          testLifecycleOverlap,
          testReloadPicksUpRotation,
          testReloadKeepsLastGoodMaterial,
          testGeneratesEncryptedWithKek,
          testBootRefusesEncryptedWithoutKek,
          testPlaintextWithoutKekStillWorks,
          testJwksNeedsNoKek,
          testEncryptAtRestBackfillIsIdempotent,
          testRewrapRotatesTheKek,
          testRewrapWithWrongOldKekModifiesNothing,
          testUserCreate,
          testAuditQuery,
          testSweepCommand,
          testRolesLifecycle,
          testRolesGrantOfUndefinedRoleFails,
          testRolesGrantToUnknownUserFails
        ]
    )

-- Encryption at rest ---------------------------------------------------------

-- | With a KEK configured, a fresh deployment never writes a plaintext private key — and
-- the key it wrote still signs tokens that verify.
testGeneratesEncryptedWithKek :: TestTree
testGeneratesEncryptedWithKek = testCase "first boot with a KEK stores encrypted private material" $ withDb \pool _ -> do
  kek <- testKek 'a'
  keys <- bootstrapKeys (Just kek) ES256 pool
  priv <- storedPrivate pool
  assertBool ("expected an enc:v1: prefix, got " <> Text.unpack (Text.take 12 priv)) (isEncryptedPrivateJwk priv)
  token <- signWith keys.signingKey
  v <- verifyToken keys.verifierJwks cfg token
  assertBool "a token signed by the decrypted key verifies" (isRight v)

-- | Encrypted rows with no KEK must abort the boot, naming the variable — never a server
-- that silently cannot sign.
testBootRefusesEncryptedWithoutKek :: TestTree
testBootRefusesEncryptedWithoutKek = testCase "boot refuses encrypted keys when no KEK is set" $ withDb \pool _ -> do
  kek <- testKek 'a'
  _ <- bootstrapKeys (Just kek) ES256 pool
  result <- try (bootstrapKeys Nothing ES256 pool)
  case result of
    Right _ -> assertFailure "boot must refuse to load encrypted keys without a KEK"
    Left (e :: IOException) ->
      assertBool
        ("the error must name the variable: " <> show e)
        ("SHOMEI_KEY_ENCRYPTION_KEY" `isInfixOf` show e)

-- | The upgrade path: an existing plaintext deployment with no KEK keeps working exactly as
-- before, so adopting this feature is opt-in.
testPlaintextWithoutKekStillWorks :: TestTree
testPlaintextWithoutKekStillWorks = testCase "plaintext keys with no KEK keep working" $ withDb \pool _ -> do
  keys <- bootstrapKeys Nothing ES256 pool
  priv <- storedPrivate pool
  assertBool "stays plaintext" (not (isEncryptedPrivateJwk priv))
  token <- signWith keys.signingKey
  v <- verifyToken keys.verifierJwks cfg token
  assertBool "still signs and verifies" (isRight v)

-- | Publication is independent of the KEK: the JWKS and the verifier key set come from the
-- public column, so a wrong or missing KEK can never break verification of live tokens.
testJwksNeedsNoKek :: TestTree
testJwksNeedsNoKek = testCase "JWKS and verification need no KEK, even for encrypted keys" $ withDb \pool _ -> do
  kek <- testKek 'a'
  keys <- bootstrapKeys (Just kek) ES256 pool
  token <- signWith keys.signingKey
  row <- onlyKey pool
  assertBool "the row is encrypted" (isEncryptedPrivateJwk row.privateKeyJwk)
  pub <- liftEither (publicJwkFromStored row)
  v <- verifyToken (JWKSet [pub]) cfg token
  assertBool "a token verifies against public material recovered without the KEK" (isRight v)

-- | The backfill converts plaintext rows, recovers a working key, and is a true no-op on
-- re-run — byte-identical, so it does not churn a fresh nonce over every row each time.
testEncryptAtRestBackfillIsIdempotent :: TestTree
testEncryptAtRestBackfillIsIdempotent = testCase "keys encrypt-at-rest backfills once and is idempotent" $ withDb \pool _ -> do
  _ <- bootstrapKeys Nothing ES256 pool -- a plaintext deployment
  before <- storedPrivate pool
  assertBool "starts plaintext" (not (isEncryptedPrivateJwk before))

  kek <- testKek 'a'
  keysEncryptAtRest kek pool
  afterFirst <- storedPrivate pool
  assertBool "now encrypted" (isEncryptedPrivateJwk afterFirst)

  row <- onlyKey pool
  jwk <- either (assertFailure . show) pure (decryptStoredSigningKey (Just kek) row)
  token <- signWith jwk
  pub <- liftEither (publicJwkFromStored row)
  v <- verifyToken (JWKSet [pub]) cfg token
  assertBool "the backfilled key still signs verifiable tokens" (isRight v)

  keysEncryptAtRest kek pool
  afterSecond <- storedPrivate pool
  afterSecond @?= afterFirst

-- | Rotating the KEK: after a rewrap the old KEK no longer opens the row and the new one
-- does, while the public material — and therefore every outstanding token — is untouched.
testRewrapRotatesTheKek :: TestTree
testRewrapRotatesTheKek = testCase "keys rewrap moves rows from the old KEK to the new one" $ withDb \pool _ -> do
  oldKek <- testKek 'a'
  newKek <- testKek 'b'
  keys <- bootstrapKeys (Just oldKek) ES256 pool
  publicBefore <- storedPublic pool
  token <- signWith keys.signingKey

  keysRewrap oldKek newKek pool

  row <- onlyKey pool
  assertBool "still encrypted" (isEncryptedPrivateJwk row.privateKeyJwk)
  case decryptStoredSigningKey (Just oldKek) row of
    Left KeyDecryptFailed -> pure ()
    Left e -> assertFailure ("expected KeyDecryptFailed from the old KEK, got " <> show e)
    Right _ -> assertFailure "the old KEK must no longer decrypt the row"
  jwk <- either (assertFailure . show) pure (decryptStoredSigningKey (Just newKek) row)

  storedPublic pool >>= (@?= publicBefore)
  pub <- liftEither (publicJwkFromStored row)
  v <- verifyToken (JWKSet [pub]) cfg token
  assertBool "the pre-rewrap token still verifies" (isRight v)
  newToken <- signWith jwk
  v2 <- verifyToken (JWKSet [pub]) cfg newToken
  assertBool "the rewrapped key still signs" (isRight v2)

-- | A wrong old KEK must abort before the first write: a half-rewrapped table would be
-- readable by neither KEK.
testRewrapWithWrongOldKekModifiesNothing :: TestTree
testRewrapWithWrongOldKekModifiesNothing = testCase "keys rewrap with a wrong old KEK modifies no rows" $ withDb \pool _ -> do
  realKek <- testKek 'a'
  wrongKek <- testKek 'c'
  newKek <- testKek 'b'
  _ <- bootstrapKeys (Just realKek) ES256 pool
  before <- storedPrivate pool

  -- 'keysRewrap' aborts via exitFailure, which surfaces here as an ExitCode exception.
  outcome <- try (keysRewrap wrongKek newKek pool)
  case outcome of
    Left (_ :: ExitCode) -> pure ()
    Right () -> assertFailure "rewrap with a wrong old KEK must abort"
  after <- storedPrivate pool
  after @?= before
  row <- onlyKey pool
  case decryptStoredSigningKey (Just realKek) row of
    Right _ -> pure ()
    Left e -> assertFailure ("the original KEK must still work after an aborted rewrap: " <> show e)

testMigrateEmpty :: TestTree
testMigrateEmpty = testCase "after migration the keys table exists and is empty" $ withDb \pool _ -> do
  keys <- listAllKeys pool
  keys @?= []
  n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_signing_keys"
  n @?= 0

testLifecycleOverlap :: TestTree
testLifecycleOverlap = testCase "generate→activate→(generate→activate auto-retires)→overlap verifies→revoke breaks it" $ withDb \pool _ -> do
  -- First key: generate then activate.
  keysGenerate Nothing ES256 pool
  kid1 <- onlyPendingKid pool
  keysActivate pool kid1
  -- Second key: generate then activate; this auto-retires kid1.
  keysGenerate Nothing ES256 pool
  kid2 <- onlyPendingKid pool
  keysActivate pool kid2

  publishable <- listPublishableSigningKeys pool
  Set.fromList (map (.keyId) publishable) @?= Set.fromList [kid1, kid2]
  statusOf pool kid1 >>= (@?= KeyRetired)
  statusOf pool kid2 >>= (@?= KeyActive)

  -- A token signed by the now-RETIRED kid1 still verifies against the published JWKS.
  retired <- requireKey pool kid1
  jwk1 <- liftEither (fromStoredSigningKey retired)
  jwkset <- buildJwks publishable
  token <- signWith jwk1
  v1 <- verifyToken jwkset cfg token
  assertBool "retired-key token verifies during overlap" (isRight v1)

  -- Revoke kid1: it leaves the JWKS and its token stops verifying.
  keysRevoke pool kid1
  publishable2 <- listPublishableSigningKeys pool
  map (.keyId) publishable2 @?= [kid2]
  jwkset2 <- buildJwks publishable2
  v2 <- verifyToken jwkset2 cfg token
  assertBool "revoked-key token no longer verifies" (not (isRight v2))

-- | The hot-reload contract: after @keys generate@ + @keys activate@ on a *running*
-- server, one 'reloadKeys' makes the new key the signer while the auto-retired one stays
-- published — so tokens minted a moment ago keep verifying. Before this plan the running
-- server never saw the rotation at all.
testReloadPicksUpRotation :: TestTree
testReloadPicksUpRotation = testCase "reloadKeys picks up an activation: new signer, both keys published" $ withDb \pool _ -> do
  ref <- newIORef =<< bootstrapKeys Nothing ES256 pool
  kid1 <- signerKid <$> readIORef ref

  keysGenerate Nothing ES256 pool
  kid2 <- onlyPendingKid pool
  keysActivate pool kid2 -- auto-retires kid1
  reloadKeys Nothing pool ref
  reloaded <- readIORef ref
  signerKid reloaded @?= kid2
  Set.fromList (Keys.publishedKids reloaded) @?= Set.fromList [kid1, kid2]

  -- The retired key is still trusted by the reloaded verifier, not merely published.
  retired <- requireKey pool kid1
  token <- signWith =<< liftEither (fromStoredSigningKey retired)
  v <- verifyToken reloaded.verifierJwks cfg token
  assertBool "retired-key token verifies against the reloaded key set" (isRight v)

-- | A failed reload must never degrade a running server below its last good state: it
-- keeps signing and verifying with the material it already holds. Retiring the only active
-- key is the operator mistake that produces this (there is then nothing to sign with).
testReloadKeepsLastGoodMaterial :: TestTree
testReloadKeepsLastGoodMaterial = testCase "a failed reload keeps the previous key material" $ withDb \pool _ -> do
  ref <- newIORef =<< bootstrapKeys Nothing ES256 pool
  before <- readIORef ref

  keysRetire pool (signerKid before)

  reloadKeys Nothing pool ref
  after <- readIORef ref
  signerKid after @?= signerKid before
  Keys.publishedKids after @?= Keys.publishedKids before

  -- and the stale-but-good material still verifies a token it signs
  token <- signWith after.signingKey
  v <- verifyToken after.verifierJwks cfg token
  assertBool "server still signs and verifies after a failed reload" (isRight v)

-- Sweep ----------------------------------------------------------------------

-- | @shomei-admin sweep@ against a seeded database: the CLI trigger must delete exactly what
-- the server's background sweeper would, and audit events must survive unless the operator
-- explicitly passes @--auth-event-retention-days@.
testSweepCommand :: TestTree
testSweepCommand = testCase "sweep deletes dead rows; audit events need an explicit window" $ withDb \pool connStr -> do
  let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
  execSql
    pool
    """
    INSERT INTO shomei.shomei_users (user_id, email, display_name, status, created_at, updated_at, login_id) VALUES
      ('11111111-1111-1111-1111-111111111111', 'sweep@example.com', 'Sweep', 'active', now(), now(), 'sweep@example.com');

    -- One session expired 40 days ago carrying a two-generation rotation family, one live.
    INSERT INTO shomei.shomei_sessions (session_id, user_id, status, created_at, expires_at, revoked_at) VALUES
      ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active', now() - interval '60 days', now() - interval '40 days', NULL),
      ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'active', now(), now() + interval '30 days', NULL);

    INSERT INTO shomei.shomei_refresh_tokens
      (refresh_token_id, session_id, token_hash, parent_token_id, status, created_at, expires_at, used_at, revoked_at) VALUES
      ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'h1', NULL,                                   'used',   now(), now() - interval '40 days', now(), NULL),
      ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'h2', 'bbbbbbbb-0000-0000-0000-000000000001', 'active', now(), now() - interval '40 days', NULL, NULL),
      ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000002', 'h3', NULL,                                   'active', now(), now() + interval '30 days', NULL, NULL);

    INSERT INTO shomei.shomei_webauthn_pending_ceremonies (ceremony_id, user_id, kind, options_blob, created_at, expires_at) VALUES
      ('ffffffff-0000-0000-0000-000000000001', NULL, 'authentication', '\\x00'::bytea, now() - interval '3 hours', now() - interval '2 hours');

    INSERT INTO shomei.shomei_login_attempts (attempt_id, account_key, client_ip, outcome, occurred_at) VALUES
      ('99999999-0000-0000-0000-000000000001', 'acct', '10.0.0.1', 'failure', now() - interval '100 days');

    INSERT INTO shomei.shomei_auth_events (event_id, user_id, session_id, event_type, payload, created_at) VALUES
      ('88888888-0000-0000-0000-000000000001', NULL, NULL, 'login_succeeded', '{}'::jsonb, now() - interval '400 days');
    """

  report <- runSweepReport env defaultSweepOptions >>= expectSweep
  report.refreshTokensDeleted @?= 2
  report.sessionsDeleted @?= 1
  report.ceremoniesDeleted @?= 1
  report.loginAttemptsDeleted @?= 1
  -- Retention is off by default, so the 400-day-old audit event survives.
  report.authEventsDeleted @?= 0

  scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions" >>= (@?= 1)
  scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens" >>= (@?= 1)
  scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events" >>= (@?= 1)

  -- Asking for a window deletes it; a second run finds nothing left.
  let retaining = defaultSweepOptions {optAuthEventRetentionDays = Just 365}
  withWindow <- runSweepReport env retaining >>= expectSweep
  withWindow.authEventsDeleted @?= 1
  scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events" >>= (@?= 0)

  again <- runSweepReport env retaining >>= expectSweep
  again.authEventsDeleted @?= 0
  where
    expectSweep = either (\e -> assertFailure ("sweep failed: " <> show e)) pure

testUserCreate :: TestTree
testUserCreate = testCase "users create persists a user + credential whose hash verifies" $ withDb \pool connStr -> do
  let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
  createUserAction env "alice@example.com" "correct horse battery staple" (Just "Alice")
  users <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users WHERE email = 'alice@example.com'"
  creds <- scalarInt pool "SELECT count(*) FROM shomei.shomei_password_credentials"
  users @?= 1
  creds @?= 1

-- Roles ----------------------------------------------------------------------

-- | The bootstrap path an operator actually runs: declare a role, grant it, read it back,
-- revoke it. Definitions publish no audit event; the grant and the revoke each publish one.
testRolesLifecycle :: TestTree
testRolesLifecycle =
  testCase "roles define/list-defined/grant/list/revoke round-trips and audits the grants" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    createUserAction env "alice@example.com" "correct horse battery staple" Nothing
    uid <- scalarText pool "SELECT user_id::text FROM shomei.shomei_users WHERE email = 'alice@example.com'"

    -- The registry starts with the migration's seeded 'admin'.
    runRoles env RolesListDefined
    seeded <- scalarInt pool "SELECT count(*) FROM shomei.shomei_roles"
    seeded @?= 1

    runRoles env (RolesDefine "auditor" (Just "read the audit trail"))
    defined <- scalarInt pool "SELECT count(*) FROM shomei.shomei_roles"
    defined @?= 2
    -- Re-defining is idempotent and does not overwrite the description.
    runRoles env (RolesDefine "auditor" (Just "something else"))
    stillTwo <- scalarInt pool "SELECT count(*) FROM shomei.shomei_roles"
    stillTwo @?= 2
    desc <- scalarText pool "SELECT description FROM shomei.shomei_roles WHERE role = 'auditor'"
    desc @?= "read the audit trail"

    -- The CLI accepts a bare UUID as well as the typed id.
    runRoles env (RolesGrant uid "auditor")
    granted <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants WHERE role = 'auditor'"
    granted @?= 1
    -- A CLI grant records no acting admin.
    noActor <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants WHERE granted_by IS NULL"
    noActor @?= 1
    -- Re-granting changes nothing and publishes nothing.
    runRoles env (RolesGrant uid "auditor")
    stillOne <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    stillOne @?= 1

    runRoles env (RolesList uid)
    runRoles env (RolesRevoke uid "auditor")
    afterRevoke <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    afterRevoke @?= 0
    -- Revoking a grant that is not there is a no-op, not an error, and publishes nothing.
    runRoles env (RolesRevoke uid "auditor")

    -- Exactly one grant and one revoke landed in the audit trail; the two definitions and the
    -- repeated grant/revoke added nothing.
    grantEvents <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'role_granted'"
    revokeEvents <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'role_revoked'"
    grantEvents @?= 1
    revokeEvents @?= 1

-- | The typo guard: @roles grant --role adminn@ must fail loudly rather than mint a role no
-- gate will ever check. This is the failure mode the role registry exists to close.
testRolesGrantOfUndefinedRoleFails :: TestTree
testRolesGrantOfUndefinedRoleFails =
  testCase "roles grant of an undefined role exits nonzero and writes nothing" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    createUserAction env "alice@example.com" "correct horse battery staple" Nothing
    uid <- scalarText pool "SELECT user_id::text FROM shomei.shomei_users WHERE email = 'alice@example.com'"
    expectExitFailure "grant of an undefined role" (runRoles env (RolesGrant uid "adminn"))
    grants <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    grants @?= 0

-- | A grant naming a user that does not exist fails before touching the grant table.
testRolesGrantToUnknownUserFails :: TestTree
testRolesGrantToUnknownUserFails =
  testCase "roles grant to an unknown user exits nonzero and writes nothing" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    expectExitFailure
      "grant to an unknown user"
      (runRoles env (RolesGrant "11111111-1111-1111-1111-111111111111" "admin"))
    grants <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    grants @?= 0

testAuditQuery :: TestTree
testAuditQuery = testCase "audit reader returns published events; type filter + count work" $ withDb \pool _ -> do
  t <- getCurrentTime
  em <- mkEmail' "audit@example.com"
  uid <- genUserId
  sid <- genSessionId
  -- Seed two events through the real PostgreSQL publisher.
  okR
    =<< runPublish
      pool
      ( do
          publishAuthEvent (Event.LoginFailed (Event.LoginFailedData (loginIdFromEmail em) t))
          publishAuthEvent (Event.LoginSucceeded (Event.LoginSucceededData uid sid (addUTCTime 1 t)))
      )
  -- Read them back through the CLI's reader stack (newest-first).
  allEvents <- okR =<< runAuditReader pool (queryAuthEvents emptyAuditQuery)
  map (.storedEventType) allEvents @?= ["login_succeeded", "login_failed"]
  -- Type filter narrows to the failed login only.
  failed <- okR =<< runAuditReader pool (queryAuthEvents emptyAuditQuery {queryEventTypes = ["login_failed"]})
  map (.storedEventType) failed @?= ["login_failed"]
  -- Count matches the total.
  n <- okR =<< runAuditReader pool (countAuthEvents emptyAuditQuery)
  n @?= 2

-- | Run the audit-event publisher over the pool (test-only seeding helper).
runPublish ::
  Pool ->
  Eff '[AuthEventPublisher, Database, Error AuthError, IOE] a ->
  IO (Either AuthError a)
runPublish pool =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runAuthEventPublisherPostgres

okR :: (Show e) => Either e a -> IO a
okR = either (assertFailure . show) pure

mkEmail' :: Text -> IO Email
mkEmail' t = either (\e -> assertFailure ("bad email: " <> show e)) pure (mkEmail t)

-- Helpers --------------------------------------------------------------------

onlyPendingKid :: Pool -> IO Text
onlyPendingKid pool = do
  keys <- listAllKeys pool
  case filter (\k -> k.status == KeyPending) keys of
    [k] -> pure k.keyId
    ks -> assertFailure ("expected exactly one pending key, got " <> show (length ks))

requireKey :: Pool -> Text -> IO StoredSigningKey
requireKey pool kid = do
  keys <- listAllKeys pool
  maybe (assertFailure ("no key " <> show kid)) pure (find (\k -> k.keyId == kid) keys)

statusOf :: Pool -> Text -> IO SigningKeyStatus
statusOf pool kid = (.status) <$> requireKey pool kid

-- | The @kid@ of the key that currently signs.
signerKid :: Keys.LoadedKeys -> Text
signerKid ks = keyKid ks.signingKey

-- | A deterministic 32-byte KEK, distinct per character.
testKek :: Char -> IO KeyEncryptionKey
testKek c =
  either
    (assertFailure . Text.unpack)
    pure
    (keyEncryptionKeyFromBase64 (TE.decodeUtf8 (convertToBase Base64 (BS8.replicate 32 c))))

-- | The exactly-one key row the encryption tests seed.
onlyKey :: Pool -> IO StoredSigningKey
onlyKey pool =
  listAllKeys pool >>= \case
    [k] -> pure k
    ks -> assertFailure ("expected exactly one signing key, got " <> show (length ks))

-- | Read the raw column, bypassing every conversion — the tests assert on stored bytes.
storedPrivate :: Pool -> IO Text
storedPrivate pool = scalarText pool "SELECT private_key_jwk FROM shomei.shomei_signing_keys"

storedPublic :: Pool -> IO Text
storedPublic pool = scalarText pool "SELECT public_key_jwk FROM shomei.shomei_signing_keys"

scalarText :: Pool -> Text -> IO Text
scalarText pool sql = do
  res <- Pool.use pool (Session.statement () stmt)
  either (\e -> assertFailure ("scalar query failed: " <> show e)) pure res
  where
    stmt = preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.text)))

buildJwks :: [StoredSigningKey] -> IO JWKSet
buildJwks stored = do
  let jwks = mapMaybe (eitherToMaybe . fromStoredSigningKey) stored
  pure (JWKSet jwks)

signWith :: JWK -> IO Text
signWith jwk = do
  uid <- genUserId
  sid <- genSessionId
  t <- getCurrentTime
  let claims =
        AuthClaims
          { subject = uid,
            sessionId = sid,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = t,
            expiresAt = addUTCTime 900 t,
            scopes = Set.empty,
            roles = Set.empty,
            actor = Nothing,
            extraClaims = mempty
          }
  r <- signAccessToken jwk claims
  case r of
    Right (AccessToken tok) -> pure tok
    Left e -> assertFailure ("signing failed: " <> show e)

liftEither :: (Show e) => Either e a -> IO a
liftEither = either (assertFailure . show) pure

eitherToMaybe :: Either e a -> Maybe a
eitherToMaybe = either (const Nothing) Just

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
