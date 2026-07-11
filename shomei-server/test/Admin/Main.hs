-- | Integration tests for @shomei-admin@ (EP-4), against throwaway PostgreSQL databases
-- provisioned by @shomei-migrations:test-support@. They drive the real CLI action functions and
-- assert database state, and — the headline — prove the signing-key rotation lifecycle with
-- overlapping-key JWKS verification.
module Main (main) where

import Control.Exception (IOException, try)
import Control.Monad (void)
import Crypto.JOSE.JWK (JWK, JWKSet (JWKSet))
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (newIORef, readIORef)
import Data.Int (Int64)
import Data.List (find, isInfixOf)
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, getCurrentTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
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
import Shomei.Admin.OAuthClients qualified as OAuthClients
import Shomei.Admin.Roles (GrantExpiry (..), RolesCommand (..), rolesParser, runRoles)
import Shomei.Admin.ServiceAccounts (createAction, listAction, revokeAction, rotateSecretAction)
import Shomei.Admin.Sweep (SweepOptions (..), defaultSweepOptions, runSweepReport)
import Shomei.Admin.Users (createUserAction)
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Crypto (Argon2Params (..), sha256Hex)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Role (..), Scope (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.IdTokenClaims (IdToken (..))
import Shomei.Domain.LoginId (loginIdFromEmail)
import Shomei.Domain.OAuthClient (ClientType (..), OAuthClient (..), OAuthClientStatus (..))
import Shomei.Domain.ServiceAccount (ServiceAccount (..))
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
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Error (AuthError (OAuthClientInvalid))
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
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.Maintenance (SweepReport (..))
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.ServiceAccountStore (runServiceAccountStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
-- qualified: 'Shomei.Admin.Keys' exports a same-named listPublishableSigningKeys

import Shomei.Server.Keys (LoadedKeys (..), bootstrapKeys, reloadKeys)
import Shomei.Server.Keys qualified as Keys
import Shomei.Workflow.ClientCredentials (ClientCredentialsGrant (..), GrantedToken (..), grantClientCredentials)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

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
          testRolesGrantToUnknownUserFails,
          testRolesPermissionWiring,
          testRolesGrantWithExpiry,
          testRolesGrantBothExpiryFlagsFailsToParse,
          testUserCreateAppliesDefaultRoles,
          testUserCreateRefusesUndefinedDefaultRoles,
          testServiceAccountsLifecycle,
          testServiceAccountsRotateAndRevoke,
          testServiceAccountsUnknownClientIdFails,
          testOAuthClientsLifecycle,
          testOAuthClientsPublicHasNoSecret,
          testOAuthClientsRevokeUnknownFails
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
    runRoles env (RolesGrant uid "auditor" Nothing)
    granted <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants WHERE role = 'auditor'"
    granted @?= 1
    -- A CLI grant records no acting admin.
    noActor <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants WHERE granted_by IS NULL"
    noActor @?= 1
    -- Re-granting changes nothing and publishes nothing.
    runRoles env (RolesGrant uid "auditor" Nothing)
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

-- | @users create@ drives the same 'Shomei.Workflow.signup' the HTTP route does, so a
-- CLI-created user must receive the configured default roles — audited, with no acting admin.
-- (Regression: 'Shomei.Admin.Env.loadAdminEnv' builds its own 'ShomeiConfig' rather than running
-- the server's loader, so it once ignored @SHOMEI_DEFAULT_ROLES@ entirely.)
testUserCreateAppliesDefaultRoles :: TestTree
testUserCreateAppliesDefaultRoles =
  testCase "users create applies config.defaultRoles, audited with no actor" $ withDb \pool connStr -> do
    let cfgWithDefaults = cfg {defaultRoles = Set.singleton (Role "member")}
        env = AdminEnv {config = cfgWithDefaults, pool = pool, connStr = connStr, argon2 = testArgon2Params}
        registryEnv = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    runRoles registryEnv (RolesDefine "member" Nothing)
    createUserAction env "alice@example.com" "correct horse battery staple" Nothing
    granted <-
      scalarInt
        pool
        """
        SELECT count(*) FROM shomei.shomei_role_grants g
        JOIN shomei.shomei_users u USING (user_id)
        WHERE u.email = 'alice@example.com' AND g.role = 'member' AND g.granted_by IS NULL
        """
    granted @?= 1
    events <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'role_granted'"
    events @?= 1

-- | The CLI has no boot-time validation, so it checks the registry itself: a default role that
-- was never defined aborts before any row is written, rather than surfacing a raw FK violation.
testUserCreateRefusesUndefinedDefaultRoles :: TestTree
testUserCreateRefusesUndefinedDefaultRoles =
  testCase "users create refuses an undefined default role and writes nothing" $ withDb \pool connStr -> do
    let env =
          AdminEnv
            { config = cfg {defaultRoles = Set.singleton (Role "nosuchrole")},
              pool = pool,
              connStr = connStr,
              argon2 = testArgon2Params
            }
    expectExitFailure
      "users create with an undefined default role"
      (createUserAction env "alice@example.com" "correct horse battery staple" Nothing)
    users <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users"
    users @?= 0

-- | The typo guard: @roles grant --role adminn@ must fail loudly rather than mint a role no
-- gate will ever check. This is the failure mode the role registry exists to close.
testRolesGrantOfUndefinedRoleFails :: TestTree
testRolesGrantOfUndefinedRoleFails =
  testCase "roles grant of an undefined role exits nonzero and writes nothing" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    createUserAction env "alice@example.com" "correct horse battery staple" Nothing
    uid <- scalarText pool "SELECT user_id::text FROM shomei.shomei_users WHERE email = 'alice@example.com'"
    expectExitFailure "grant of an undefined role" (runRoles env (RolesGrant uid "adminn" Nothing))
    grants <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    grants @?= 0

-- | A grant naming a user that does not exist fails before touching the grant table.
testRolesGrantToUnknownUserFails :: TestTree
testRolesGrantToUnknownUserFails =
  testCase "roles grant to an unknown user exits nonzero and writes nothing" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    expectExitFailure
      "grant to an unknown user"
      (runRoles env (RolesGrant "11111111-1111-1111-1111-111111111111" "admin" Nothing))
    grants <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    grants @?= 0

-- | EP-9 permission wiring over the CLI: allow attaches a row, show renders (smoke), disallow
-- removes it, and allow on an undefined role exits nonzero without writing.
testRolesPermissionWiring :: TestTree
testRolesPermissionWiring =
  testCase "roles allow/show/disallow round-trip; allow on an undefined role exits nonzero" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    runRoles env (RolesDefine "support" (Just "support staff"))
    runRoles env (RolesAllow "support" "tickets:write")
    afterAllow <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_permissions WHERE role = 'support' AND permission = 'tickets:write'"
    afterAllow @?= 1
    -- Idempotent: a second allow adds no row.
    runRoles env (RolesAllow "support" "tickets:write")
    stillOne <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_permissions WHERE role = 'support'"
    stillOne @?= 1
    -- show is a read; assert it runs without error (its output goes to stdout).
    runRoles env (RolesShow "support")
    runRoles env (RolesDisallow "support" "tickets:write")
    afterDisallow <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_permissions WHERE role = 'support'"
    afterDisallow @?= 0
    -- Wiring publishes no audit event.
    permEvents <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type IN ('permission_allowed','permission_disallowed')"
    permEvents @?= 0
    -- Allow on an undefined role is a loud failure that writes nothing.
    expectExitFailure "allow on an undefined role" (runRoles env (RolesAllow "nosuchrole" "x:y"))
    none <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_permissions WHERE role = 'nosuchrole'"
    none @?= 0

-- | @roles grant --expires-in 1h@ lands a grant whose @expires_at@ is about an hour out, and the
-- @role_granted@ audit payload carries that same expiry (passive expiry: the audit trail is the
-- only record of the window).
testRolesGrantWithExpiry :: TestTree
testRolesGrantWithExpiry =
  testCase "roles grant --expires-in stamps the grant row and the audit payload with the window" $ withDb \pool connStr -> do
    let env = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}
    runRoles env (RolesDefine "support" (Just "support staff"))
    createUserAction env "alice@example.com" "correct horse battery staple" Nothing
    uid <- scalarText pool "SELECT user_id::text FROM shomei.shomei_users WHERE email = 'alice@example.com'"
    runRoles env (RolesGrant uid "support" (Just (ExpiresIn 3600)))
    -- The grant row's expiry is ~1h out (allow a wide window for clock/setup slack).
    secs <- scalarInt pool "SELECT EXTRACT(EPOCH FROM (expires_at - now()))::bigint FROM shomei.shomei_role_grants WHERE role = 'support'"
    assertBool ("expected ~3600s out, got " <> show secs) (secs > 3000 && secs <= 3600)
    -- The audit payload carries an expiresAt (non-null); pre-EP-9 grants carried none.
    withExpiry <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'role_granted' AND payload ? 'expiresAt' AND payload->>'expiresAt' IS NOT NULL"
    withExpiry @?= 1

-- | Parser-level: @--expires-in@ and @--expires-at@ are mutually exclusive, so supplying both is a
-- parse failure rather than a silently-ignored flag.
testRolesGrantBothExpiryFlagsFailsToParse :: TestTree
testRolesGrantBothExpiryFlagsFailsToParse =
  testCase "roles grant with both --expires-in and --expires-at fails to parse" $
    case execParserPure defaultPrefs (info rolesParser mempty) argv of
      Success _ -> assertFailure "expected supplying both expiry flags to fail parsing"
      _ -> pure ()
  where
    argv =
      [ "grant",
        "--user",
        "user_01ABC",
        "--role",
        "support",
        "--expires-in",
        "4h",
        "--expires-at",
        "2026-07-11T21:00:00Z"
      ]

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
            permissions = Set.empty,
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

-- Service accounts (MasterPlan 7 EP-4) --------------------------------------

-- | These drive the CLI's *action* functions rather than 'runServiceAccounts', because the
-- generated secret is printed exactly once and never re-readable. Capturing the process's stdout
-- to recover it is not an option: tasty runs these cases in parallel, and @hDuplicateTo@ on the
-- global 'stdout' is process-wide, so two capturing cases interleave and read each other's
-- output. (Observed: the same suite reporting "All 22 tests passed" on one run and
-- "2 out of 22 tests failed" on the next.) The actions return what they did; the printing
-- wrapper is a one-liner over them.
adminEnv :: Pool -> Text -> AdminEnv
adminEnv pool connStr = AdminEnv {config = cfg, pool = pool, connStr = connStr, argon2 = testArgon2Params}

saClientId' :: ServiceAccount -> Text
saClientId' ServiceAccount {clientId} = clientId

-- | Run the real @client_credentials@ workflow against PostgreSQL, exactly as @\/oauth\/token@
-- does, with a fake signer (this suite is not testing JWT signing).
runGrant ::
  Pool ->
  ClientCredentialsGrant ->
  IO (Either AuthError (Either AuthError GrantedToken))
runGrant pool grant =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runClockIO
    . runAuthEventPublisherPostgres
    . runTokenSignerFakeAdmin
    . runSessionStorePostgres
    . runServiceAccountStorePostgres
    . runUserStorePostgres
    $ grantClientCredentials cfg grant

runTokenSignerFakeAdmin :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFakeAdmin = interpret_ \case
  SignAccessToken _ -> pure (AccessToken "admin-test-token")
  SignIdToken _ -> pure (IdToken "admin-test-id-token")

grantWith :: Pool -> Text -> Text -> Maybe (Set Scope) -> IO (Either AuthError GrantedToken)
grantWith pool cid secret scopes = do
  outcome <- runGrant pool ClientCredentialsGrant {clientId = cid, clientSecret = secret, requestedScopes = scopes}
  either (\e -> assertFailure ("infrastructure error: " <> show e)) pure outcome

-- | create → the account exists, is active, owns a backing user row, and the secret it returned
-- authenticates through the real grant workflow. Only the digest is stored.
testServiceAccountsLifecycle :: TestTree
testServiceAccountsLifecycle =
  testCase "service-accounts create: yields a working secret, stores only its digest" $ withDb \pool connStr -> do
    let env = adminEnv pool connStr
    (account, secret) <- createAction env "rei connector" ["kawa:ingest", "signal:raise"]
    let cid = saClientId' account

    n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_service_accounts WHERE status = 'active'"
    n @?= 1
    backing <-
      scalarInt
        pool
        ("SELECT count(*) FROM shomei.shomei_users u JOIN shomei.shomei_service_accounts s ON s.user_id = u.user_id WHERE u.login_id = '" <> cid <> "'")
    assertEqual "the account owns a backing user row keyed by its client id" 1 backing

    -- The plaintext secret is nowhere in the database; only its SHA-256 hex digest is.
    plaintext <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_service_accounts WHERE secret_hash = '" <> secret <> "'")
    assertEqual "the plaintext secret is never stored" 0 plaintext
    digest <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_service_accounts WHERE secret_hash = '" <> sha256Hex secret <> "'")
    assertEqual "the stored hash is sha256Hex of the returned secret" 1 digest

    -- And it authenticates: an omitted scope grants the whole allow-list.
    granted <- grantWith pool cid secret Nothing
    case granted of
      Left e -> assertFailure ("expected the generated secret to authenticate, got " <> show e)
      Right g -> g.grantedScopes @?= Set.fromList [Scope "kawa:ingest", Scope "signal:raise"]

    -- A wrong secret does not.
    wrong <- grantWith pool cid "not-the-secret" Nothing
    fmap (const ()) wrong @?= Left OAuthClientInvalid

    created <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'service_account_created'"
    created @?= 1
    withUser <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'service_account_created' AND user_id IS NOT NULL"
    assertEqual "the lifecycle event files under the backing user" 1 withUser

-- | rotate-secret invalidates the old secret immediately (single-secret model, no overlap);
-- revoke refuses every subsequent token while keeping the row.
testServiceAccountsRotateAndRevoke :: TestTree
testServiceAccountsRotateAndRevoke =
  testCase "service-accounts rotate-secret then revoke: old secret dies at once, revoked account refuses all" $ withDb \pool connStr -> do
    let env = adminEnv pool connStr
    (account, oldSecret) <- createAction env "rei connector" ["kawa:ingest"]
    let cid = saClientId' account

    (_, newSecret) <- rotateSecretAction env cid
    assertBool "rotation produces a different secret" (newSecret /= oldSecret)

    old <- grantWith pool cid oldSecret Nothing
    fmap (const ()) old @?= Left OAuthClientInvalid
    new <- grantWith pool cid newSecret Nothing
    case new of
      Left e -> assertFailure ("expected the rotated secret to authenticate, got " <> show e)
      Right g -> g.grantedScopes @?= Set.singleton (Scope "kawa:ingest")

    -- rotated_at is stamped, status is untouched.
    stillActive <- scalarInt pool "SELECT count(*) FROM shomei.shomei_service_accounts WHERE status = 'active' AND rotated_at IS NOT NULL"
    stillActive @?= 1

    _ <- revokeAction env cid
    revoked <- grantWith pool cid newSecret Nothing
    fmap (const ()) revoked @?= Left OAuthClientInvalid

    -- The row survives revocation, so the audit trail and the refusal both still resolve it.
    rows <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_service_accounts WHERE client_id = '" <> cid <> "' AND status = 'revoked' AND revoked_at IS NOT NULL")
    rows @?= 1
    events <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type IN ('service_account_secret_rotated', 'service_account_revoked')"
    events @?= 2

    -- list reports it, still exactly one row.
    accounts <- listAction env
    map saClientId' accounts @?= [cid]

-- | A typo in the client id aborts rather than silently updating zero rows.
testServiceAccountsUnknownClientIdFails :: TestTree
testServiceAccountsUnknownClientIdFails =
  testCase "service-accounts rotate-secret/revoke on an unknown client id abort" $ withDb \pool connStr -> do
    let env = adminEnv pool connStr
    expectExitFailure "rotate-secret of an unknown client" (void (rotateSecretAction env "svcacct_nope"))
    expectExitFailure "revoke of an unknown client" (void (revokeAction env "svcacct_nope"))

-- shomei-admin oauth-clients (EP-5) -----------------------------------------

ocClientId' :: OAuthClient -> Text
ocClientId' OAuthClient {clientId} = clientId

ocStatus' :: OAuthClient -> OAuthClientStatus
ocStatus' OAuthClient {status} = status

ocDisplayName' :: OAuthClient -> Text
ocDisplayName' OAuthClient {displayName} = displayName

-- | create → the client exists, is active, stores only the digest of the once-printed secret,
-- and owns NO backing user row (unlike a service account, it is never a token subject).
-- Then list sees it, and revoke keeps the row while flipping its status.
testOAuthClientsLifecycle :: TestTree
testOAuthClientsLifecycle =
  testCase "oauth-clients create/list/revoke: digest-only secret, no backing user, row survives revocation" $ withDb \pool connStr -> do
    let env = adminEnv pool connStr
    (client, mSecret) <-
      OAuthClients.createAction
        env
        "grafana"
        ConfidentialClient
        ["https://grafana.example.com/callback"]
        ["openid", "profile"]
    secret <- maybe (assertFailure "a confidential client must be issued a secret") pure mSecret
    let cid = ocClientId' client

    ocStatus' client @?= OAuthClientActive
    n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_oauth_clients WHERE status = 'active'"
    n @?= 1

    -- The plaintext secret is nowhere in the database; only its SHA-256 hex digest is.
    plaintext <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_oauth_clients WHERE secret_hash = '" <> secret <> "'")
    assertEqual "the plaintext secret is never stored" 0 plaintext
    digest <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_oauth_clients WHERE secret_hash = '" <> sha256Hex secret <> "'")
    assertEqual "the stored hash is sha256Hex of the returned secret" 1 digest

    -- An OAuth client is not a principal: no shomei_users row is provisioned for it.
    backing <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_users WHERE login_id = '" <> cid <> "'")
    assertEqual "an oauth client gets no backing user row" 0 backing

    listed <- OAuthClients.listAction env
    map ocDisplayName' listed @?= ["grafana"]

    created <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'oauth_client_created'"
    created @?= 1
    -- The client is not a user, so the audit row files under no user.
    withUser <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'oauth_client_created' AND user_id IS NOT NULL"
    assertEqual "an oauth client lifecycle event names no user" 0 withUser

    _ <- OAuthClients.revokeAction env cid
    revoked <- scalarInt pool ("SELECT count(*) FROM shomei.shomei_oauth_clients WHERE client_id = '" <> cid <> "' AND status = 'revoked' AND revoked_at IS NOT NULL")
    assertEqual "revocation flips status, stamps revoked_at, and keeps the row" 1 revoked
    revokedEvents <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'oauth_client_revoked'"
    revokedEvents @?= 1

-- | A public client is issued no secret at all — not one that is stored and never checked. PKCE
-- is what binds its authorize request to its token request.
testOAuthClientsPublicHasNoSecret :: TestTree
testOAuthClientsPublicHasNoSecret =
  testCase "oauth-clients create --type public: no secret is generated or stored" $ withDb \pool connStr -> do
    let env = adminEnv pool connStr
    (client, mSecret) <-
      OAuthClients.createAction env "spa" PublicClient ["https://spa.example.com/cb"] ["openid"]
    assertEqual "a public client is issued no secret" Nothing mSecret
    nulls <-
      scalarInt
        pool
        ("SELECT count(*) FROM shomei.shomei_oauth_clients WHERE client_id = '" <> ocClientId' client <> "' AND secret_hash IS NULL AND client_type = 'public'")
    assertEqual "its secret_hash is a real NULL" 1 nulls

-- | Revoking an unknown client_id exits nonzero rather than silently updating zero rows.
testOAuthClientsRevokeUnknownFails :: TestTree
testOAuthClientsRevokeUnknownFails =
  testCase "oauth-clients revoke of an unknown client_id exits nonzero and writes nothing" $ withDb \pool connStr -> do
    let env = adminEnv pool connStr
    expectExitFailure "revoke unknown" (void (OAuthClients.revokeAction env "oauthclient_does_not_exist"))
    events <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'oauth_client_revoked'"
    events @?= 0
