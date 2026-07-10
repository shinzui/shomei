-- | Integration tests for the PostgreSQL adapters, run against throwaway databases
-- provisioned by @shomei-migrations:test-support@ (ephemeral-pg + codd). Each test gets a
-- fresh migrated database, acquires a hasql pool, runs the real interpreters, and asserts
-- behavior — first port-by-port round-trips, then EP-2's workflows driven through the
-- PostgreSQL interpreters with database-state assertions.
module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Monad (forM_, replicateM, void)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpose, interpret_, send)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..), defaultRateLimitConfig, defaultShomeiConfig)
import Shomei.Crypto
  ( Argon2Params (..),
    defaultArgon2Params,
    dummyHashFor,
    hashPasswordArgon2id,
    newHashingLimiter,
    peakHashingConcurrency,
    runPasswordHasherCrypto,
    runTokenGenCrypto,
    verifyPasswordArgon2id,
    withHashingPermit,
  )
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Role (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.EventCodec (reconstructAuthEvent)
import Shomei.Domain.LoginAttempt (AccountKey (..), AccountLockout (..), ClientIp (..), LoginOutcome (..), NewLoginAttempt (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail, loginIdText, mkLoginId)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken, OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.Passkey
  ( CeremonyKind (..),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
  )
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken (NewRefreshToken (..), PersistedRefreshToken (..), RefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (..))
import Shomei.Domain.VerificationToken (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.AuthEventReader
  ( AuditCursor (..),
    AuditEventQuery (..),
    AuthEventReader,
    StoredAuthEvent (..),
    countAuthEvents,
    emptyAuditQuery,
    queryAuthEvents,
  )
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork)
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher, runClaimsEnricherNull)
import Shomei.Effect.Clock (Clock (..), now)
import Shomei.Effect.CredentialStore (CredentialStore, createPasswordCredential, findPasswordCredentialByEmail, findPasswordCredentialByLoginId)
import Shomei.Effect.InMemory (emptyWorld, runPasswordBreachCheckerFake, runWebAuthnCeremonyFake)
import Shomei.Effect.LoginAttemptStore
  ( LoginAttemptStore,
    clearAccountLockout,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    recordLoginAttempt,
    setAccountLockout,
  )
import Shomei.Effect.Notifier (Notifier (..))
import Shomei.Effect.PasskeyStore
  ( PasskeyStore,
    countPasskeysByUser,
    createPasskey,
    deletePasskey,
    findPasskeyByCredentialId,
    findPasskeysByUser,
    findPasskeysByUserHandle,
    updatePasskeySignCounter,
  )
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPasswordDummy)
import Shomei.Effect.PasswordResetTokenStore
  ( PasswordResetTokenStore,
    createPasswordResetToken,
    findPasswordResetTokenByHash,
    markPasswordResetTokenConsumed,
  )
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony, takePendingCeremony)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore, createRefreshToken, findRefreshTokenByHash, markRefreshTokenUsed)
import Shomei.Effect.RoleStore
  ( RoleDefinition (..),
    RoleStore,
    defineRole,
    grantRole,
    listDefinedRoles,
    listRolesForUser,
    revokeRole,
  )
import Shomei.Effect.SessionStore (SessionStore, createSession, findSessionById, listSessionsForUser, revokeSession)
import Shomei.Effect.SigningKeyStore (SigningKeyStore, findSigningKeyByKid, insertSigningKey, listActiveSigningKeys, listPublishableSigningKeys, updateSigningKeyStatus)
import Shomei.Effect.TokenGen (TokenGen, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.UserStore
  ( UserCursor (..),
    UserListQuery (..),
    UserStore,
    createUser,
    emptyUserListQuery,
    findUserByEmail,
    findUserById,
    findUserByLoginId,
    listUsers,
    markUserEmailVerified,
    updateUserStatus,
  )
import Shomei.Effect.VerificationTokenStore
  ( VerificationTokenStore,
    createVerificationToken,
    findVerificationTokenByHash,
    markVerificationTokenConsumed,
  )
import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)
import Shomei.Error (AuthError (InternalAuthError, InvalidCredentials, RefreshTokenReuseDetected, RoleNotDefined, UserNotFound))
import Shomei.Id (PasskeyId, genCeremonyId, genSessionId, genUserId, userIdToUUID)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.AuthEventReader (runAuthEventReaderPostgres)
import Shomei.Postgres.AuthUnitOfWork (runAuthUnitOfWorkPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database (..), runDatabasePool)
import Shomei.Postgres.LoginAttemptStore (runLoginAttemptStorePostgres)
import Shomei.Postgres.Maintenance
  ( SweepConfig (..),
    SweepReport (..),
    defaultSweepConfig,
    emptySweepReport,
    sweepOnce,
  )
import Shomei.Postgres.PasskeyStore (runPasskeyStorePostgres)
import Shomei.Postgres.PasswordResetTokenStore (runPasswordResetTokenStorePostgres)
import Shomei.Postgres.PendingCeremonyStore (runPendingCeremonyStorePostgres)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.RoleStore (runRoleStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Postgres.VerificationTokenStore (runVerificationTokenStorePostgres)
import Shomei.Workflow (login, refresh, signup)
import Shomei.Workflow.Roles (grantRoleTo)
import Shomei.Workflow.Session (buildEnrichedClaims)
import Shomei.Workflow.Account
  ( ConfirmEmailVerification (..),
    ConfirmPasswordReset (..),
    RequestEmailVerification (..),
    RequestPasswordReset (..),
    confirmEmailVerification,
    confirmPasswordReset,
    requestEmailVerification,
    requestPasswordReset,
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase, (@?=))

-- | The full interpreter stack used by every test. The store interpreters are peeled
-- first (Database/IOE/Error remain available to them); @TokenSigner@ is a trivial fake
-- because real signing is EP-4.
type AppEffects =
  '[ UserStore,
     RoleStore,
     CredentialStore,
     SessionStore,
     RefreshTokenStore,
     AuthUnitOfWork,
     VerificationTokenStore,
     PasswordResetTokenStore,
     LoginAttemptStore,
     PasskeyStore,
     PendingCeremonyStore,
     Notifier,
     ClaimsEnricher,
     WebAuthnCeremony,
     AuthEventPublisher,
     AuthEventReader,
     SigningKeyStore,
     TokenSigner,
     PasswordBreachChecker,
     PasswordHasher,
     TokenGen,
     Clock,
     Database,
     Error AuthError,
     IOE
   ]

runApp :: Pool -> Eff AppEffects a -> IO (Either AuthError a)
runApp pool action = do
  ref <- newIORef []
  runAppWithNotifications ref pool action

runAppWithNotifications :: IORef [Notification] -> Pool -> Eff AppEffects a -> IO (Either AuthError a)
runAppWithNotifications ref pool action = do
  wref <- newIORef (emptyWorld (UTCTime (fromGregorian 2000 1 1) 0))
  limiter <- newHashingLimiter 2
  ( runEff
      . runErrorNoCallStack
      . runDatabasePool pool
      . runClockIO
      . runTokenGenCrypto
      -- Cheap parameters: these workflow tests hash real passwords, and the production cost
      -- (~100 ms per hash) would dominate the suite. The argon2 tests below cover the real ones.
      . runPasswordHasherCrypto limiter cheapParams
      . runPasswordBreachCheckerFake wref
      . runTokenSignerFake
      . runSigningKeyStorePostgres
      . runAuthEventReaderPostgres
      . runAuthEventPublisherPostgres
      . runWebAuthnCeremonyFake wref
      . runClaimsEnricherNull
      . runNotifierRef ref
      . runPendingCeremonyStorePostgres
      . runPasskeyStorePostgres
      . runLoginAttemptStorePostgres
      . runPasswordResetTokenStorePostgres
      . runVerificationTokenStorePostgres
      . runAuthUnitOfWorkPostgres
      . runRefreshTokenStorePostgres
      . runSessionStorePostgres
      . runCredentialStorePostgres
      . runRoleStorePostgres
      . runUserStorePostgres
    )
    action

-- | Run the stack with a FIXED clock (the EP-2 lockout tests need to advance time
-- deterministically across calls against the same database). Notifications are discarded.
runAppAtTime :: UTCTime -> Pool -> Eff AppEffects a -> IO (Either AuthError a)
runAppAtTime t pool action = do
  ref <- newIORef []
  wref <- newIORef (emptyWorld t)
  limiter <- newHashingLimiter 2
  ( runEff
      . runErrorNoCallStack
      . runDatabasePool pool
      . runClockFixed t
      . runTokenGenCrypto
      . runPasswordHasherCrypto limiter cheapParams
      . runPasswordBreachCheckerFake wref
      . runTokenSignerFake
      . runSigningKeyStorePostgres
      . runAuthEventReaderPostgres
      . runAuthEventPublisherPostgres
      . runWebAuthnCeremonyFake wref
      . runClaimsEnricherNull
      . runNotifierRef ref
      . runPendingCeremonyStorePostgres
      . runPasskeyStorePostgres
      . runLoginAttemptStorePostgres
      . runPasswordResetTokenStorePostgres
      . runVerificationTokenStorePostgres
      . runAuthUnitOfWorkPostgres
      . runRefreshTokenStorePostgres
      . runSessionStorePostgres
      . runCredentialStorePostgres
      . runRoleStorePostgres
      . runUserStorePostgres
    )
    action

runClockFixed :: UTCTime -> Eff (Clock : es) a -> Eff es a
runClockFixed t = interpret_ \case
  Now -> pure t

-- | A trivial 'TokenSigner' (real signing is EP-4); the DB-state assertions never inspect
-- the access token's contents.
runTokenSignerFake :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFake = interpret_ \case
  SignAccessToken _ -> pure (AccessToken "test-access-token")

runNotifierRef :: (IOE :> es) => IORef [Notification] -> Eff (Notifier : es) a -> Eff es a
runNotifierRef ref = interpret_ \case
  SendNotification n -> liftIO (modifyIORef' ref (n :))

-- Helpers --------------------------------------------------------------------

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

-- | Tightened thresholds for the EP-2 lockout test (lock after 3 per-account failures).
lockCfg :: ShomeiConfig
lockCfg = cfg {rateLimitConfig = defaultRateLimitConfig {maxFailedLoginsPerAccount = 3}}

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

bobEmail :: Email
bobEmail = mkEmail' "bob@example.com"

aliceLogin :: LoginId
aliceLogin = loginIdFromEmail aliceEmail

bobLogin :: LoginId
bobLogin = loginIdFromEmail bobEmail

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' t = case mkEmail t of
  Right e -> e
  Left err -> error ("bad test email: " <> show err)

mkLoginId' :: Text -> LoginId
mkLoginId' t = case mkLoginId t of
  Right l -> l
  Left err -> error ("bad test login id: " <> show err)

-- | Run an action over a fresh migrated database and a pool.
withDb :: (Pool -> IO a) -> IO a
withDb action = withShomeiMigratedDatabase \connStr -> do
  pool <- acquirePool 4 10 connStr
  action pool

-- | Unwrap the @Either AuthError@ from 'runApp' (the interpreter-level failure channel).
expectApp :: (Show e) => Either e a -> IO a
expectApp = either (\e -> assertFailure ("interpreter error: " <> show e)) pure

-- | Unwrap a workflow's own @Either AuthError@ result.
expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- | Run a (possibly multi-statement) SQL script directly against the pool, for seeding.
execSql :: Pool -> Text -> IO ()
execSql pool sql = do
  res <- Pool.use pool (Session.script sql)
  either (\e -> assertFailure ("seed script failed: " <> show e)) pure res

-- | Unwrap the @Either UsageError@ that 'sweepOnce' returns.
expectSweep :: Either Pool.UsageError SweepReport -> IO SweepReport
expectSweep = either (\e -> assertFailure ("sweep failed: " <> show e)) pure

-- | A scalar @count(*)@ (or any single-bigint) query, run directly against the pool.
scalarInt :: Pool -> Text -> IO Int
scalarInt pool sql = do
  res <- Pool.use pool (Session.statement () stmt)
  either (\e -> assertFailure ("scalar query failed: " <> show e)) pure res
  where
    stmt =
      preparable
        sql
        E.noParams
        (D.singleRow (fromIntegral64 <$> D.column (D.nonNullable D.int8)))
    fromIntegral64 :: Int64 -> Int
    fromIntegral64 = fromIntegral

-- Tests ----------------------------------------------------------------------

main :: IO ()
main = defaultMain (testGroup "shomei-postgres" tests)

tests :: [TestTree]
tests =
  [ testUserRoundTrip,
    testUserNoEmailAndUniqueLoginId,
    testListUsersOrderFilterAndPaging,
    testListSessionsForUser,
    testCredentialRoundTrip,
    testSessionRevoke,
    testSessionActorRoundTrip,
    testRefreshTokenMarkUsed,
    testVerificationTokenRoundTrip,
    testPasswordResetTokenRoundTrip,
    testMarkUserEmailVerified,
    testSigningKeys,
    testPublishableSigningKeys,
    testPublishEvent,
    testAuditEventReader,
    testWorkflowSignup,
    testLoginRoundTripBudget,
    testRefreshRoundTripBudget,
    testWorkflowRefreshRotation,
    testWorkflowReuseRevokesFamily,
    testWorkflowAccountVerification,
    testWorkflowPasswordReset,
    testLoginAttemptStore,
    testWorkflowLockout,
    testPasskeyCreateAndFind,
    testPasskeyUpdateCountDelete,
    testPendingCeremonyConsumeOnce,
    testPendingCeremonyExpired,
    testArgon2NewHashesArePhcFormatted,
    testArgon2LegacyFixtureStillVerifies,
    testArgon2ParamsChangeLeavesOldHashesVerifiable,
    testArgon2MalformedHashesVerifyFalse,
    testArgon2DummyHashTracksConfiguredParams,
    testHashingLimiterBoundsConcurrency 1,
    testHashingLimiterBoundsConcurrency 2,
    testInterpreterHonorsTheLimiter,
    testDummyVerificationTakesAPermit,
    testSweepDeletesExpiredRows,
    testSweepIsIdempotent,
    testSweepAuthEventRetention,
    testSweepBatchesUntilDrained,
    testSweepBatchesWholeTokenFamilies,
    testRoleRegistry,
    testRoleGrants,
    testRoleGrantForeignKeys,
    testGrantedRoleReachesEnrichedClaims
  ]

-- | The registry: seeded with @admin@ by the migration, idempotent definition, sorted listing.
testRoleRegistry :: TestTree
testRoleRegistry =
  testCase "role registry: seeded with admin; define is idempotent; list is sorted" $ withDb \pool -> do
    result <- runApp pool do
      seeded <- listDefinedRoles
      ts <- now
      firstDefine <- defineRole (Role "auditor") (Just "read the audit trail") ts
      secondDefine <- defineRole (Role "auditor") (Just "a different description") ts
      after' <- listDefinedRoles
      pure (seeded, firstDefine, secondDefine, after')
    (seeded, firstDefine, secondDefine, after') <- expectApp result
    map (.role) seeded @?= [Role "admin"]
    firstDefine @?= True
    -- Re-defining is a no-op: it reports no change and does NOT overwrite the description.
    secondDefine @?= False
    map (.role) after' @?= [Role "admin", Role "auditor"]
    map (.description) after' @?= [Just adminSeedDescription, Just "read the audit trail"]

-- | Grants: idempotent insert, listing, revocation, and the "nothing to revoke" report.
testRoleGrants :: TestTree
testRoleGrants =
  testCase "role grants: idempotent grant/revoke round-trip" $ withDb \pool -> do
    result <- runApp pool do
      u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
      ts <- now
      _ <- defineRole (Role "auditor") Nothing ts
      firstGrant <- grantRole u.userId (Role "admin") Nothing ts
      secondGrant <- grantRole u.userId (Role "admin") Nothing ts
      _ <- grantRole u.userId (Role "auditor") (Just u.userId) ts
      granted <- listRolesForUser u.userId
      firstRevoke <- revokeRole u.userId (Role "admin")
      secondRevoke <- revokeRole u.userId (Role "admin")
      remaining <- listRolesForUser u.userId
      pure (firstGrant, secondGrant, granted, firstRevoke, secondRevoke, remaining)
    (firstGrant, secondGrant, granted, firstRevoke, secondRevoke, remaining) <- expectApp result
    firstGrant @?= True
    secondGrant @?= False
    granted @?= Set.fromList [Role "admin", Role "auditor"]
    firstRevoke @?= True
    secondRevoke @?= False
    remaining @?= Set.singleton (Role "auditor")

-- | The database enforces both foreign keys, so code that bypasses 'Shomei.Workflow.Roles'
-- still cannot create a dangling grant. The raw port surfaces the violation as
-- 'InternalAuthError'; the workflow catches both cases first and returns a typed error.
testRoleGrantForeignKeys :: TestTree
testRoleGrantForeignKeys =
  testCase "role grants: FKs reject undefined roles and unknown users; workflow pre-checks" $ withDb \pool -> do
    setup <- runApp pool do
      u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
      pure u.userId
    uid <- expectApp setup

    -- Raw port, undefined role: the shomei_role_grants.role FK fires.
    rawUndefinedRole <- runApp pool do
      ts <- now
      grantRole uid (Role "nosuchrole") Nothing ts
    expectInternalError "grant of an undefined role" rawUndefinedRole

    -- Raw port, unknown user: the shomei_role_grants.user_id FK fires.
    ghost <- genUserId
    rawUnknownUser <- runApp pool do
      ts <- now
      grantRole ghost (Role "admin") Nothing ts
    expectInternalError "grant to a nonexistent user" rawUnknownUser

    -- The workflow refuses both BEFORE touching the table, with typed errors.
    workflowUndefinedRole <- runApp pool (grantRoleTo Nothing uid (Role "nosuchrole"))
    expectApp workflowUndefinedRole >>= \r -> r @?= Left (RoleNotDefined (Role "nosuchrole"))

    workflowUnknownUser <- runApp pool (grantRoleTo Nothing ghost (Role "admin"))
    expectApp workflowUnknownUser >>= \r -> r @?= Left UserNotFound

    -- And the happy path still lands a row plus exactly one role_granted audit event.
    ok <- runApp pool (grantRoleTo Nothing uid (Role "admin"))
    expectApp ok >>= \r -> r @?= Right True
    again <- runApp pool (grantRoleTo Nothing uid (Role "admin"))
    expectApp again >>= \r -> r @?= Right False
    grants <- scalarInt pool "SELECT count(*) FROM shomei.shomei_role_grants"
    grants @?= 1
    events <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'role_granted'"
    events @?= 1
  where
    expectInternalError what = \case
      Left (InternalAuthError _) -> pure ()
      Left e -> assertFailure (what <> ": expected InternalAuthError, got " <> show e)
      Right _ -> assertFailure (what <> ": expected the foreign key to reject it")

-- | The claims path end to end over the real store: a role granted through the workflow shows
-- up in the claims 'buildEnrichedClaims' assembles, which is what every token mint signs.
testGrantedRoleReachesEnrichedClaims :: TestTree
testGrantedRoleReachesEnrichedClaims =
  testCase "buildEnrichedClaims reads roles from the real PostgreSQL store" $ withDb \pool -> do
    result <- runApp pool do
      u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
      sid <- genSessionId
      ts <- now
      before <- buildEnrichedClaims cfg u.userId sid ts
      _ <- grantRoleTo Nothing u.userId (Role "admin")
      after' <- buildEnrichedClaims cfg u.userId sid ts
      pure (before, after')
    (before, after') <- expectApp result
    before.roles @?= Set.empty
    after'.roles @?= Set.singleton (Role "admin")
    -- Shōmei persists no scopes; the null enricher adds none.
    after'.scopes @?= Set.empty

-- | The description the @shomei-role-grants@ migration seeds onto the @admin@ role.
adminSeedDescription :: Text
adminSeedDescription = "Full access to the shomei /admin surface and admin CLI-equivalent HTTP routes"

testUserRoundTrip :: TestTree
testUserRoundTrip = testCase "create + find user round-trips" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Just "Alice"})
    byId <- findUserById u.userId
    byEmail <- findUserByEmail aliceEmail
    pure (u, byId, byEmail)
  (u, byId, byEmail) <- expectApp result
  fmap (.userId) byId @?= Just u.userId
  fmap (.loginId) byId @?= Just aliceLogin
  fmap (.email) byId @?= Just (Just aliceEmail)
  fmap (.displayName) byId @?= Just (Just "Alice")
  fmap (.userId) byEmail @?= Just u.userId

-- | The M3 acceptance: a user can be created with NO email, round-trips by login id with
-- @email IS NULL@, the @login_id@ unique index rejects a duplicate principal, and the
-- partial unique index on @email@ permits multiple NULL emails.
testUserNoEmailAndUniqueLoginId :: TestTree
testUserNoEmailAndUniqueLoginId =
  testCase "user: NULL email round-trips; login_id unique; NULL emails don't collide" $ withDb \pool -> do
    let svc = mkLoginId' "svc-bot"
        svc2 = mkLoginId' "svc-bot-2"
    created <- runApp pool do
      u <- createUser (NewUser {loginId = svc, email = Nothing, displayName = Nothing})
      byLogin <- findUserByLoginId svc
      pure (u, byLogin)
    (u, byLogin) <- expectApp created
    fmap (.email) byLogin @?= Just Nothing
    fmap (.loginId) byLogin @?= Just svc
    fmap (.userId) byLogin @?= Just u.userId
    -- a duplicate login id is rejected by the unique index (interpreter surfaces a Left)
    dup <- runApp pool (createUser (NewUser {loginId = svc, email = Nothing, displayName = Nothing}))
    case dup of
      Left _ -> pure ()
      Right _ -> assertFailure "expected duplicate login_id to be rejected by the unique index"
    -- a second no-email user with a distinct login id is allowed: NULL emails don't collide
    second <- runApp pool (createUser (NewUser {loginId = svc2, email = Nothing, displayName = Nothing}))
    _ <- expectApp second
    nullEmails <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users WHERE email IS NULL"
    nullEmails @?= 2

-- | The admin listing's three promises, against the real statement: newest-first order, the
-- status filter, and a keyset walk that is both disjoint and complete.
--
-- The walk matters more than it looks. An OFFSET pager over @ORDER BY created_at DESC@ would
-- pass a two-page test on distinct timestamps and silently skip or repeat rows the moment two
-- users share one — which is exactly what a bulk import produces. The cursor compares the whole
-- @(created_at, user_id)@ tuple, so this test seeds three users and asserts the pages partition
-- them.
testListUsersOrderFilterAndPaging :: TestTree
testListUsersOrderFilterAndPaging = testCase "listUsers: newest-first, status-filtered, keyset-paged" $ withDb \pool -> do
  result <- runApp pool do
    u1 <- createUser (NewUser {loginId = mkLoginId' "one", email = Nothing, displayName = Nothing})
    u2 <- createUser (NewUser {loginId = mkLoginId' "two", email = Nothing, displayName = Nothing})
    u3 <- createUser (NewUser {loginId = mkLoginId' "three", email = Nothing, displayName = Nothing})
    updateUserStatus u2.userId UserSuspended
    everyone <- listUsers emptyUserListQuery
    suspended <- listUsers emptyUserListQuery {queryStatus = Just UserSuspended}
    active <- listUsers emptyUserListQuery {queryStatus = Just UserActive}
    page1 <- listUsers emptyUserListQuery {queryLimit = 2}
    page2 <- case reverse page1 of
      [] -> pure []
      (lastUser : _) ->
        listUsers
          emptyUserListQuery
            { queryLimit = 2,
              queryBefore = Just (UserCursor {cursorCreatedAt = lastUser.createdAt, cursorUserId = lastUser.userId})
            }
    pure (u1, u2, u3, everyone, suspended, active, page1, page2)
  (u1, u2, u3, everyone, suspended, active, page1, page2) <- expectApp result

  -- Newest first. Rows created in one transaction can share a created_at, so assert on the set
  -- and on the ordering key rather than on a fixed permutation.
  map (.userId) everyone `shouldContainExactly` [u1.userId, u2.userId, u3.userId]
  assertBool "newest-first" (isDescending (map (\u -> (u.createdAt, u.userId)) everyone))

  map (.userId) suspended @?= [u2.userId]
  map (.userId) active `shouldContainExactly` [u1.userId, u3.userId]

  -- The keyset walk partitions the users: no overlap, nothing lost.
  length page1 @?= 2
  length page2 @?= 1
  (map (.userId) page1 <> map (.userId) page2) `shouldContainExactly` [u1.userId, u2.userId, u3.userId]

testListSessionsForUser :: TestTree
testListSessionsForUser = testCase "listSessionsForUser returns every status, newest-first, for one user only" $ withDb \pool -> do
  result <- runApp pool do
    alice <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    bob <- createUser (NewUser {loginId = bobLogin, email = Just bobEmail, displayName = Nothing})
    t <- now
    s1 <- createSession (NewSession {userId = alice.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
    s2 <- createSession (NewSession {userId = alice.userId, createdAt = addUTCTime 1 t, expiresAt = addUTCTime 3600 t, actor = Nothing})
    _ <- createSession (NewSession {userId = bob.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
    revokeSession s1.sessionId t
    aliceSessions <- listSessionsForUser alice.userId
    pure (s1, s2, aliceSessions)
  (s1, s2, aliceSessions) <- expectApp result
  -- Bob's session is absent; a revoked session is still listed (an admin must see it).
  map (.sessionId) aliceSessions @?= [s2.sessionId, s1.sessionId]
  map (.status) aliceSessions @?= [SessionActive, SessionRevoked]

-- | Set equality with a readable failure, without imposing an order.
shouldContainExactly :: (Ord a, Show a) => [a] -> [a] -> Assertion
shouldContainExactly actual expected = sort actual @?= sort expected

isDescending :: (Ord a) => [a] -> Bool
isDescending xs = and (zipWith (>=) xs (drop 1 xs))

testCredentialRoundTrip :: TestTree
testCredentialRoundTrip = testCase "create credential + find-by-email" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    h <- hashPassword strongPw
    _ <- createPasswordCredential u.userId aliceLogin (Just aliceEmail) h
    byEmail <- findPasswordCredentialByEmail aliceEmail
    byLogin <- findPasswordCredentialByLoginId aliceLogin
    pure (u, h, byEmail, byLogin)
  (u, h, byEmail, byLogin) <- expectApp result
  fmap (.userId) byEmail @?= Just u.userId
  fmap (.email) byEmail @?= Just (Just aliceEmail)
  fmap (.passwordHash) byEmail @?= Just h
  fmap (.userId) byLogin @?= Just u.userId
  fmap (.loginId) byLogin @?= Just aliceLogin

testSessionRevoke :: TestTree
testSessionRevoke = testCase "create session + revoke" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    s <- createSession (NewSession {userId = u.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
    revokeSession s.sessionId t
    findSessionById s.sessionId
  found <- expectApp result
  fmap (.status) found @?= Just SessionRevoked

testSessionActorRoundTrip :: TestTree
testSessionActorRoundTrip = testCase "create delegated session persists actor" $ withDb \pool -> do
  result <- runApp pool do
    subject <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    operator <- createUser (NewUser {loginId = bobLogin, email = Just bobEmail, displayName = Nothing})
    t <- now
    delegated <-
      createSession
        ( NewSession
            { userId = subject.userId,
              createdAt = t,
              expiresAt = addUTCTime 3600 t,
              actor = Just operator.userId
            }
        )
    normal <- createSession (NewSession {userId = subject.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
    foundDelegated <- findSessionById delegated.sessionId
    foundNormal <- findSessionById normal.sessionId
    pure (operator.userId, foundDelegated, foundNormal)
  (op, foundDelegated, foundNormal) <- expectApp result
  fmap (.actor) foundDelegated @?= Just (Just op)
  fmap (.actor) foundNormal @?= Just Nothing

-- | Pins the compare-and-swap semantics of the @UPDATE … AND status = 'active' RETURNING@
-- statement: the first mark wins and stamps @used_at@, a second mark of the same token loses
-- and leaves the row (including the winner's @used_at@) untouched. This is the statement-level
-- guarantee that makes two concurrent refreshes of one token impossible to both succeed.
testRefreshTokenMarkUsed :: TestTree
testRefreshTokenMarkUsed = testCase "refresh token: find-by-hash + mark-used is a compare-and-swap" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    s <- createSession (NewSession {userId = u.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
    h <- hashRefreshToken (RefreshToken "token-1")
    persisted <-
      createRefreshToken
        NewRefreshToken
          { sessionId = s.sessionId,
            tokenHash = h,
            parentTokenId = Nothing,
            createdAt = t,
            expiresAt = addUTCTime 86400 t
          }
    beforeUse <- findRefreshTokenByHash h
    firstMark <- markRefreshTokenUsed persisted.refreshTokenId t
    afterUse <- findRefreshTokenByHash h
    secondMark <- markRefreshTokenUsed persisted.refreshTokenId (addUTCTime 60 t)
    afterSecond <- findRefreshTokenByHash h
    pure (beforeUse, afterUse, firstMark, secondMark, afterSecond)
  (beforeUse, afterUse, firstMark, secondMark, afterSecond) <- expectApp result
  fmap (.status) beforeUse @?= Just RefreshTokenActive
  fmap (.status) afterUse @?= Just RefreshTokenUsed
  firstMark @?= True
  secondMark @?= False
  -- The loser overwrote nothing: the row still carries the winner's used_at.
  fmap (.usedAt) afterSecond @?= fmap (.usedAt) afterUse
  fmap (.status) afterSecond @?= Just RefreshTokenUsed

testVerificationTokenRoundTrip :: TestTree
testVerificationTokenRoundTrip = testCase "verification token: consume is a compare-and-swap" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    let h = OneTimeTokenHash "hash:verify-1"
    persisted <-
      createVerificationToken
        NewVerificationToken
          { userId = u.userId,
            tokenHash = h,
            createdAt = t,
            expiresAt = addUTCTime 3600 t
          }
    before <- findVerificationTokenByHash h
    firstConsume <- markVerificationTokenConsumed persisted.verificationTokenId t
    after <- findVerificationTokenByHash h
    secondConsume <- markVerificationTokenConsumed persisted.verificationTokenId (addUTCTime 60 t)
    afterSecond <- findVerificationTokenByHash h
    pure (before, after, firstConsume, secondConsume, afterSecond)
  (before, after, firstConsume, secondConsume, afterSecond) <- expectApp result
  fmap (.status) before @?= Just OneTimeTokenActive
  fmap (.status) after @?= Just OneTimeTokenConsumed
  firstConsume @?= True
  secondConsume @?= False
  fmap (.consumedAt) afterSecond @?= fmap (.consumedAt) after

testPasswordResetTokenRoundTrip :: TestTree
testPasswordResetTokenRoundTrip = testCase "password reset token: consume is a compare-and-swap" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    let h = OneTimeTokenHash "hash:reset-1"
    persisted <-
      createPasswordResetToken
        NewPasswordResetToken
          { userId = u.userId,
            tokenHash = h,
            createdAt = t,
            expiresAt = addUTCTime 3600 t
          }
    before <- findPasswordResetTokenByHash h
    firstConsume <- markPasswordResetTokenConsumed persisted.passwordResetTokenId t
    after <- findPasswordResetTokenByHash h
    secondConsume <- markPasswordResetTokenConsumed persisted.passwordResetTokenId (addUTCTime 60 t)
    afterSecond <- findPasswordResetTokenByHash h
    pure (before, after, firstConsume, secondConsume, afterSecond)
  (before, after, firstConsume, secondConsume, afterSecond) <- expectApp result
  fmap (.status) before @?= Just OneTimeTokenActive
  fmap (.status) after @?= Just OneTimeTokenConsumed
  firstConsume @?= True
  secondConsume @?= False
  fmap (.consumedAt) afterSecond @?= fmap (.consumedAt) after

testMarkUserEmailVerified :: TestTree
testMarkUserEmailVerified = testCase "mark user email verified sets the timestamp" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    markUserEmailVerified u.userId t
    findUserById u.userId
  found <- expectApp result
  assertBool "email_verified_at is populated" (maybe False (isJust . (.emailVerifiedAt)) found)

testSigningKeys :: TestTree
testSigningKeys = testCase "insert + list signing keys" $ withDb \pool -> do
  result <- runApp pool do
    t <- now
    let key =
          StoredSigningKey
            { keyId = "kid-1",
              algorithm = "ES256",
              publicKeyJwk = "{\"kty\":\"EC\"}",
              privateKeyJwk = "{\"kty\":\"EC\",\"d\":\"x\"}",
              status = KeyActive,
              createdAt = t,
              activatedAt = Just t,
              retiredAt = Nothing
            }
    insertSigningKey key
    active <- listActiveSigningKeys
    byKid <- findSigningKeyByKid "kid-1"
    pure (active, byKid)
  (active, byKid) <- expectApp result
  fmap (.keyId) active @?= ["kid-1"]
  fmap (.keyId) byKid @?= Just "kid-1"

-- | @listPublishableSigningKeys@ returns exactly the active + retired keys (the JWKS
-- contents), while @listActiveSigningKeys@ still returns only the signing key.
testPublishableSigningKeys :: TestTree
testPublishableSigningKeys = testCase "publishable signing keys are active + retired" $ withDb \pool -> do
  result <- runApp pool do
    t <- now
    let key kid st =
          StoredSigningKey
            { keyId = kid,
              algorithm = "ES256",
              publicKeyJwk = "{\"kty\":\"EC\"}",
              privateKeyJwk = "{\"kty\":\"EC\",\"d\":\"x\"}",
              status = st,
              createdAt = t,
              activatedAt = Just t,
              retiredAt = Nothing
            }
    -- Insert each row Pending, then drive it to its target status through the port, so
    -- the test exercises updateSigningKeyStatus rather than trusting the insert.
    forM_ [("k-active", KeyActive), ("k-retired", KeyRetired), ("k-revoked", KeyRevoked)] \(kid, st) -> do
      insertSigningKey (key kid KeyPending)
      updateSigningKeyStatus kid st t
    insertSigningKey (key "k-pending" KeyPending)
    publishable <- listPublishableSigningKeys
    active <- listActiveSigningKeys
    pure (publishable, active)
  (publishable, active) <- expectApp result
  sort (fmap (.keyId) publishable) @?= ["k-active", "k-retired"]
  fmap (.keyId) active @?= ["k-active"]

testPublishEvent :: TestTree
testPublishEvent = testCase "publish auth event lands a row" $ withDb \pool -> do
  result <- runApp pool do
    t <- now
    publishAuthEvent (Event.LoginFailed (Event.LoginFailedData aliceLogin t))
  _ <- expectApp result
  n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events"
  n @?= 1

testAuditEventReader :: TestTree
testAuditEventReader = testCase "audit reader: filter + order + keyset pagination + reconstruct" $ withDb \pool -> do
  let tt :: Int -> UTCTime
      tt n = addUTCTime (fromIntegral n) t0
  result <- runApp pool do
    alice <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    bob <- createUser (NewUser {loginId = bobLogin, email = Just bobEmail, displayName = Nothing})
    s1 <- genSessionId
    s2 <- genSessionId
    -- Five events at strictly increasing times (newest = tt 4).
    publishAuthEvent (Event.LoginFailed (Event.LoginFailedData aliceLogin (tt 0)))
    publishAuthEvent (Event.LoginSucceeded (Event.LoginSucceededData alice.userId s1 (tt 1)))
    publishAuthEvent (Event.LoginFailed (Event.LoginFailedData bobLogin (tt 2)))
    publishAuthEvent (Event.PasswordChanged (Event.PasswordChangedData alice.userId (tt 3)))
    publishAuthEvent (Event.LoginSucceeded (Event.LoginSucceededData bob.userId s2 (tt 4)))
    allEvents <- queryAuthEvents emptyAuditQuery
    aliceEvents <- queryAuthEvents emptyAuditQuery {queryUserId = Just (userIdToUUID alice.userId)}
    failedEvents <- queryAuthEvents emptyAuditQuery {queryEventTypes = ["login_failed"]}
    windowEvents <- queryAuthEvents emptyAuditQuery {querySince = Just (tt 1), queryUntil = Just (tt 3)}
    total <- countAuthEvents emptyAuditQuery
    failedTotal <- countAuthEvents emptyAuditQuery {queryEventTypes = ["login_failed"]}
    page1 <- queryAuthEvents emptyAuditQuery {queryLimit = 2}
    page2 <- case page1 of
      [] -> pure []
      rows ->
        let lastRow = last rows
            cur = AuditCursor (storedCreatedAt lastRow) (storedEventId lastRow)
         in queryAuthEvents emptyAuditQuery {queryLimit = 2, queryBefore = Just cur}
    pure (allEvents, aliceEvents, failedEvents, windowEvents, total, failedTotal, page1, page2)
  (allEvents, aliceEvents, failedEvents, windowEvents, total, failedTotal, page1, page2) <- expectApp result
  -- newest-first ordering across all five
  map storedEventType allEvents
    @?= ["login_succeeded", "password_changed", "login_failed", "login_succeeded", "login_failed"]
  -- user filter: only alice's two rows, newest-first
  map storedEventType aliceEvents @?= ["password_changed", "login_succeeded"]
  -- type filter: the two failed logins (tt 2 = bob, tt 0 = alice)
  map storedEventType failedEvents @?= ["login_failed", "login_failed"]
  -- since (inclusive) tt1 .. until (exclusive) tt3 → tt2 then tt1
  map storedEventType windowEvents @?= ["login_failed", "login_succeeded"]
  total @?= 5
  failedTotal @?= 2
  -- keyset pagination walks the set with no gaps or repeats
  length page1 @?= 2
  length page2 @?= 2
  let ids1 = map storedEventId page1
      ids2 = map storedEventId page2
  assertBool "pages are disjoint" (all (`notElem` ids2) ids1)
  map storedEventType (page1 <> page2) @?= ["login_succeeded", "password_changed", "login_failed", "login_succeeded"]
  -- the oldest failed-login row reconstructs to the typed event we published
  case reverse failedEvents of
    (oldest : _) ->
      reconstructAuthEvent (storedEventType oldest) (storedPayload oldest)
        @?= Right (Event.LoginFailed (Event.LoginFailedData aliceLogin (tt 0)))
    [] -> assertFailure "expected at least one failed-login row"

testWorkflowSignup :: TestTree
testWorkflowSignup = testCase "workflow: signup persists user + session + token" $ withDb \pool -> do
  inner <- runApp pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw (Just "Alice")))
  _ <- expectApp inner >>= expectRight
  users <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users"
  sessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions"
  toks <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens"
  users @?= 1
  sessions @?= 1
  toks @?= 1

-- Round-trip budget ----------------------------------------------------------

-- | Count every 'Database' dispatch a workflow makes.
--
-- 'interpose' replaces the 'Database' handler for the wrapped action only; re-'send'ing the
-- operation from inside the handler dispatches to the /upstream/ handler ('runDatabasePool'),
-- not back into this one, so the workflow still talks to PostgreSQL and there is no recursion.
-- Both constructors are counted: a @RunSession@ is one pool checkout for one
-- statement, and a @RunTransaction@ is one pool checkout for the whole transaction. That is
-- exactly the quantity these tests pin — network round-trips, not statements.
countingDatabase :: (Database :> es, IOE :> es) => IORef Int -> Eff es a -> Eff es a
countingDatabase counter = interpose \_env op -> do
  liftIO (atomicModifyIORef' counter \n -> (n + 1, ()))
  case op of
    RunSession sess -> send (RunSession sess)
    RunTransaction t -> send (RunTransaction t)

-- | A successful password login costs exactly eight database round-trips:
--
--   1. @countRecentFailuresByIp@   (per-IP throttle)
--   2. @getAccountLockout@         (lockout gate)
--   3. @findPasswordCredentialByLoginId@
--   4. @findUserById@
--   5. @recordLoginAttempt@        (success row)
--   6. @countPasskeysByUser@       (MFA gate)
--   7. @persistNewSession@         (ONE transaction: session + refresh token + 2 audit events)
--   8. @listRolesForUser@          (the roles claim, via @buildEnrichedClaims@)
--
-- There is deliberately no @clearAccountLockout@: the lockout read at step 2 found nothing.
-- Password verification and access-token signing are CPU-only and cost no round-trip.
--
-- Step 8 is the price of a populated @roles@ claim: every user-session mint reads the grant
-- table once. It is a single-row indexed lookup on the primary key prefix, and it buys the
-- alternative — re-reading roles on every /verification/ — never happening.
--
-- If this number drifts, something added a round-trip to the login path. Find it before
-- changing the constant.
testLoginRoundTripBudget :: TestTree
testLoginRoundTripBudget = testCase "a successful login costs exactly 8 database round-trips" $ withDb \pool -> do
  signupRes <- runApp pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  _ <- expectApp signupRes >>= expectRight
  counter <- newIORef 0
  let ctx = ClientContext (ClientIp "10.0.0.1") (AccountKey (loginIdText aliceLogin))
  loginRes <- runApp pool (countingDatabase counter (login cfg ctx (LoginCommand aliceLogin strongPw)))
  _ <- expectApp loginRes >>= expectRight
  readIORef counter >>= (@?= 8)

-- | A token refresh costs exactly four database round-trips:
--
--   1. @findRefreshTokenByHash@
--   2. @findSessionById@
--   3. @rotateRefreshToken@  (ONE transaction: mark-used CAS + child insert + rotation event)
--   4. @listRolesForUser@    (the roles claim, via @buildEnrichedClaims@)
--
-- The user row is not read because @emailVerificationRequired@ is off in 'cfg'; turning it on
-- adds a fifth round-trip by design.
--
-- Step 4 is what makes a role change take effect on refresh rather than only at the next login.
testRefreshRoundTripBudget :: TestTree
testRefreshRoundTripBudget = testCase "a token refresh costs exactly 4 database round-trips" $ withDb \pool -> do
  signupRes <- runApp pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  (_, pair) <- expectApp signupRes >>= expectRight
  counter <- newIORef 0
  refreshRes <- runApp pool (countingDatabase counter (refresh cfg (RefreshCommand pair.refreshToken)))
  _ <- expectApp refreshRes >>= expectRight
  readIORef counter >>= (@?= 4)

testWorkflowRefreshRotation :: TestTree
testWorkflowRefreshRotation = testCase "workflow: refresh rotation marks used + inserts child" $ withDb \pool -> do
  signupRes <- runApp pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  (_, pair) <- expectApp signupRes >>= expectRight
  refreshRes <- runApp pool (refresh cfg (RefreshCommand pair.refreshToken))
  _ <- expectApp refreshRes >>= expectRight
  toks <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens"
  used <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens WHERE status = 'used'"
  children <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens WHERE parent_token_id IS NOT NULL"
  toks @?= 2
  used @?= 1
  children @?= 1

testWorkflowReuseRevokesFamily :: TestTree
testWorkflowReuseRevokesFamily = testCase "workflow: reuse revokes the family + session" $ withDb \pool -> do
  signupRes <- runApp pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  (_, pair) <- expectApp signupRes >>= expectRight
  rotateRes <- runApp pool (refresh cfg (RefreshCommand pair.refreshToken))
  _ <- expectApp rotateRes >>= expectRight
  reuseRes <- runApp pool (refresh cfg (RefreshCommand pair.refreshToken))
  reuse <- expectApp reuseRes
  reuse @?= Left RefreshTokenReuseDetected
  revokedToks <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens WHERE status = 'revoked'"
  totalToks <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens"
  revokedSessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions WHERE status = 'revoked'"
  assertBool "every refresh token in the family is revoked" (revokedToks == totalToks)
  revokedSessions @?= 1

testWorkflowAccountVerification :: TestTree
testWorkflowAccountVerification = testCase "workflow: account verification consumes token + marks user" $ withDb \pool -> do
  notifications <- newIORef []
  signupRes <- runAppWithNotifications notifications pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  _ <- expectApp signupRes >>= expectRight
  requestRes <- runAppWithNotifications notifications pool (requestEmailVerification cfg (RequestEmailVerification aliceEmail))
  _ <- expectApp requestRes >>= expectRight
  raw <- latestVerificationToken =<< readIORef notifications
  confirmRes <- runAppWithNotifications notifications pool (confirmEmailVerification cfg (ConfirmEmailVerification raw))
  _ <- expectApp confirmRes >>= expectRight
  verified <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users WHERE email_verified_at IS NOT NULL"
  consumed <- scalarInt pool "SELECT count(*) FROM shomei.shomei_email_verification_tokens WHERE status = 'consumed'"
  verified @?= 1
  consumed @?= 1

testWorkflowPasswordReset :: TestTree
testWorkflowPasswordReset = testCase "workflow: password reset changes password and revokes sessions" $ withDb \pool -> do
  notifications <- newIORef []
  signupRes <- runAppWithNotifications notifications pool (signup cfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  (_, pair) <- expectApp signupRes >>= expectRight
  requestRes <- runAppWithNotifications notifications pool (requestPasswordReset cfg (RequestPasswordReset aliceEmail))
  _ <- expectApp requestRes >>= expectRight
  raw <- latestResetToken =<< readIORef notifications
  confirmRes <- runAppWithNotifications notifications pool (confirmPasswordReset cfg (ConfirmPasswordReset raw (PlainPassword "correct horse battery staple two")))
  _ <- expectApp confirmRes >>= expectRight
  loginRes <- runAppWithNotifications notifications pool (login cfg (ClientContext (ClientIp "test-ip") (AccountKey (loginIdText aliceLogin))) (LoginCommand aliceLogin (PlainPassword "correct horse battery staple two")))
  _ <- expectApp loginRes >>= expectRight
  oldRefreshRes <- runAppWithNotifications notifications pool (refresh cfg (RefreshCommand pair.refreshToken))
  oldRefresh <- expectApp oldRefreshRes
  oldRefresh @?= Left RefreshTokenReuseDetected
  consumed <- scalarInt pool "SELECT count(*) FROM shomei.shomei_password_reset_tokens WHERE status = 'consumed'"
  revokedSessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions WHERE status = 'revoked'"
  revokedRefresh <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens WHERE status = 'revoked'"
  consumed @?= 1
  assertBool "existing sessions are revoked" (revokedSessions >= 1)
  assertBool "existing refresh tokens are revoked" (revokedRefresh >= 1)

testLoginAttemptStore :: TestTree
testLoginAttemptStore = testCase "login attempt store: record + windowed count + lockout upsert/clear" $ withDb \pool -> do
  let key = AccountKey "k-abc"
      ip = ClientIp "1.2.3.4"
  result <- runApp pool do
    t <- now
    let cutoff = addUTCTime (-900) t
    recordLoginAttempt (NewLoginAttempt key ip LoginFailure t)
    recordLoginAttempt (NewLoginAttempt key ip LoginFailure t)
    recordLoginAttempt (NewLoginAttempt key (ClientIp "9.9.9.9") LoginFailure t)
    accFails <- countRecentFailuresByAccount key cutoff
    ipFails <- countRecentFailuresByIp ip cutoff
    future <- countRecentFailuresByAccount key (addUTCTime 3600 t)
    setAccountLockout (AccountLockout key 5 (Just (addUTCTime 900 t)) t)
    lo1 <- getAccountLockout key
    clearAccountLockout key
    lo2 <- getAccountLockout key
    pure (accFails, ipFails, future, lo1, lo2)
  (accFails, ipFails, future, lo1, lo2) <- expectApp result
  accFails @?= 3 -- all three failures share the account key
  ipFails @?= 2 -- only two came from 1.2.3.4
  future @?= 0 -- a cutoff in the future excludes everything
  fmap (.failedCount) lo1 @?= Just 5
  lo2 @?= Nothing

testWorkflowLockout :: TestTree
testWorkflowLockout = testCase "workflow over PostgreSQL: lock-after-N then unlock-after-cooldown" $ withDb \pool -> do
  seeded <- runAppAtTime t0 pool (signup lockCfg (SignupCommand aliceLogin (Just aliceEmail) strongPw Nothing))
  _ <- expectApp seeded >>= expectRight
  let ctx = ClientContext (ClientIp "10.0.0.9") (AccountKey (loginIdText aliceLogin))
      badLogin = login lockCfg ctx (LoginCommand aliceLogin (PlainPassword "wrong"))
  _ <- runAppAtTime t0 pool badLogin >>= expectApp
  _ <- runAppAtTime t0 pool badLogin >>= expectApp
  r3 <- runAppAtTime t0 pool badLogin >>= expectApp
  r3 @?= Left InvalidCredentials
  locked <- scalarInt pool "SELECT count(*) FROM shomei.shomei_account_lockouts WHERE locked_until IS NOT NULL"
  locked @?= 1
  -- The correct password while still locked returns the SAME generic error (no leak).
  denied <- runAppAtTime t0 pool (login lockCfg ctx (LoginCommand aliceLogin strongPw)) >>= expectApp
  denied @?= Left InvalidCredentials
  -- After the cooldown (15 min default) the correct password succeeds and clears the lockout.
  ok <- runAppAtTime (addUTCTime (16 * 60) t0) pool (login lockCfg ctx (LoginCommand aliceLogin strongPw)) >>= expectApp
  _ <- expectRight ok
  remaining <- scalarInt pool "SELECT count(*) FROM shomei.shomei_account_lockouts"
  remaining @?= 0

-- Passkey field accessors: OverloadedRecordDot is unreliable for these
-- DuplicateRecordFields records (MasterPlan 3 discovery), so read via record-pattern.
pkPasskeyId :: PasskeyCredential -> PasskeyId
pkPasskeyId PasskeyCredential {passkeyId} = passkeyId

pkSignCounter :: PasskeyCredential -> SignatureCounter
pkSignCounter PasskeyCredential {signCounter} = signCounter

pkLastUsedAt :: PasskeyCredential -> Maybe UTCTime
pkLastUsedAt PasskeyCredential {lastUsedAt} = lastUsedAt

pkTransports :: PasskeyCredential -> [Text]
pkTransports PasskeyCredential {transports} = transports

pkLabel :: PasskeyCredential -> Maybe Text
pkLabel PasskeyCredential {label} = label

-- | A 'NewPasskeyCredential' with canned bytes for the given user and time.
newPasskey :: User -> UTCTime -> NewPasskeyCredential
newPasskey u t =
  NewPasskeyCredential
    { userId = u.userId,
      credentialId = WebAuthnCredentialId "cred-1",
      userHandle = UserHandle "uh-1",
      publicKey = PublicKeyBytes "pk-1",
      signCounter = SignatureCounter 0,
      transports = ["usb", "nfc"],
      label = Just "key",
      createdAt = t
    }

testPasskeyCreateAndFind :: TestTree
testPasskeyCreateAndFind = testCase "passkey store: create + find by user/credential-id/user-handle" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    created <- createPasskey (newPasskey u t)
    byUser <- findPasskeysByUser u.userId
    byCred <- findPasskeyByCredentialId (WebAuthnCredentialId "cred-1")
    byHandle <- findPasskeysByUserHandle (UserHandle "uh-1")
    pure (created, byUser, byCred, byHandle)
  (created, byUser, byCred, byHandle) <- expectApp result
  -- all three lookups resolve to the created passkey
  map pkPasskeyId byUser @?= [pkPasskeyId created]
  fmap pkPasskeyId byCred @?= Just (pkPasskeyId created)
  map pkPasskeyId byHandle @?= [pkPasskeyId created]
  -- the jsonb transports + bigint counter + label survived the round trip
  fmap pkTransports byCred @?= Just ["usb", "nfc"]
  fmap pkLabel byCred @?= Just (Just "key")
  fmap pkSignCounter byCred @?= Just (SignatureCounter 0)
  n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_credentials"
  n @?= 1

testPasskeyUpdateCountDelete :: TestTree
testPasskeyUpdateCountDelete = testCase "passkey store: update sign counter + count + delete (user-scoped)" $ withDb \pool -> do
  result <- runApp pool do
    u <- createUser (NewUser {loginId = aliceLogin, email = Just aliceEmail, displayName = Nothing})
    t <- now
    created <- createPasskey (newPasskey u t)
    let pid = pkPasskeyId created
    updatePasskeySignCounter pid (SignatureCounter 42) t
    afterUpdate <- findPasskeyByCredentialId (WebAuthnCredentialId "cred-1")
    cnt <- countPasskeysByUser u.userId
    otherUid <- genUserId
    deletePasskey otherUid pid -- wrong user: must NOT delete
    pure (afterUpdate, cnt, u.userId, pid)
  (afterUpdate, cnt, uid, pid) <- expectApp result
  fmap pkSignCounter afterUpdate @?= Just (SignatureCounter 42)
  assertBool "last_used_at is populated after the counter bump" (maybe False (isJust . pkLastUsedAt) afterUpdate)
  cnt @?= 1
  afterWrongUser <- scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_credentials"
  afterWrongUser @?= 1 -- wrong-user delete left it
  _ <- runApp pool (deletePasskey uid pid) >>= expectApp
  afterOwner <- scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_credentials"
  afterOwner @?= 0 -- owner delete removed it

testPendingCeremonyConsumeOnce :: TestTree
testPendingCeremonyConsumeOnce = testCase "pending ceremony store: put then take consumes exactly once" $ withDb \pool -> do
  result <- runApp pool do
    cid <- genCeremonyId
    t <- now
    putPendingCeremony
      PendingCeremony
        { ceremonyId = cid,
          userId = Nothing,
          kind = RegistrationCeremony,
          optionsBlob = "{\"challenge\":\"abc\"}",
          createdAt = t,
          expiresAt = addUTCTime 300 t
        }
    first <- takePendingCeremony cid t
    pure (cid, t, first)
  (cid, t, first) <- expectApp result
  assertBool "first take returns the ceremony" (isJust first)
  afterFirst <- scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_pending_ceremonies"
  afterFirst @?= 0 -- DELETE ... RETURNING removed it
  second <- runApp pool (takePendingCeremony cid t) >>= expectApp
  second @?= (Nothing :: Maybe PendingCeremony)

testPendingCeremonyExpired :: TestTree
testPendingCeremonyExpired = testCase "pending ceremony store: expired ceremony is not returned" $ withDb \pool -> do
  result <- runApp pool do
    cid <- genCeremonyId
    t <- now
    putPendingCeremony
      PendingCeremony
        { ceremonyId = cid,
          userId = Nothing,
          kind = AuthenticationCeremony,
          optionsBlob = "{\"challenge\":\"xyz\"}",
          createdAt = t,
          expiresAt = t -- expires immediately
        }
    -- "now" is past expiry: returns Nothing but still removes the stale row
    takePendingCeremony cid (addUTCTime 1 t)
  taken <- expectApp result
  taken @?= (Nothing :: Maybe PendingCeremony)
  remaining <- scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_pending_ceremonies"
  remaining @?= 0

-- Argon2 parameters ----------------------------------------------------------

-- | A hash produced by the pre-plan code, whose format recorded no parameters.
--
-- Captured from the interpreter before the PHC format landed, of the password
-- @"correct horse battery staple"@. It is the compatibility contract: if this test ever
-- fails, every user hashed by an older Shōmei is locked out. Do not regenerate it.
legacyFixtureHash :: PasswordHash
legacyFixtureHash =
  PasswordHash "argon2id$4gw0llx5tfM4Dfi23hUsTA==$8zWIeRIFVtmuSuMdAv4MW13Fsw1BCjfREVf4eaHwp+I="

legacyFixturePassword :: Text
legacyFixturePassword = "correct horse battery staple"

-- | Cheap parameters, so the parameter tests do not each pay the ~100 ms production cost.
cheapParams :: Argon2Params
cheapParams = Argon2Params {memoryKiB = 8192, iterations = 1, parallelism = 1}

testArgon2NewHashesArePhcFormatted :: TestTree
testArgon2NewHashesArePhcFormatted =
  testCase "argon2: new hashes are PHC-formatted and verify" do
    PasswordHash stored <- hashPasswordArgon2id defaultArgon2Params "hunter2"
    assertBool
      ("expected a PHC prefix carrying the default params, got " <> Text.unpack stored)
      ("$argon2id$v=19$m=65536,t=3,p=1$" `Text.isPrefixOf` stored)
    verifyPasswordArgon2id "hunter2" (PasswordHash stored) @?= True
    verifyPasswordArgon2id "wrong" (PasswordHash stored) @?= False

testArgon2LegacyFixtureStillVerifies :: TestTree
testArgon2LegacyFixtureStillVerifies =
  testCase "argon2: a legacy-format hash still verifies" do
    verifyPasswordArgon2id legacyFixturePassword legacyFixtureHash @?= True
    verifyPasswordArgon2id "wrong" legacyFixtureHash @?= False

testArgon2ParamsChangeLeavesOldHashesVerifiable :: TestTree
testArgon2ParamsChangeLeavesOldHashesVerifiable =
  testCase "argon2: changing params leaves old hashes verifiable" do
    -- A hash made with the defaults, and one made with different params, coexist.
    defaultHash <- hashPasswordArgon2id defaultArgon2Params "hunter2"
    cheapHash <- hashPasswordArgon2id cheapParams "hunter2"
    assertBool "the two hashes differ" (defaultHash /= cheapHash)

    -- Each verifies with the parameters IT carries, not with any ambient configuration.
    verifyPasswordArgon2id "hunter2" defaultHash @?= True
    verifyPasswordArgon2id "hunter2" cheapHash @?= True
    -- ...and the legacy fixture still verifies alongside both.
    verifyPasswordArgon2id legacyFixturePassword legacyFixtureHash @?= True

testArgon2MalformedHashesVerifyFalse :: TestTree
testArgon2MalformedHashesVerifyFalse =
  testCase "argon2: malformed hashes verify False without crashing" do
    let malformed =
          [ "$argon2id$v=19$m=notanumber,t=3,p=1$AAAAAAAAAAAAAAAAAAAAAA==$AAAA",
            "$argon2id$v=99$m=65536,t=3,p=1$AAAAAAAAAAAAAAAAAAAAAA==$AAAA",
            "$argon2id$v=19$m=65536,t=3$AAAAAAAAAAAAAAAAAAAAAA==$AAAA",
            "$argon2id$v=19$m=0,t=3,p=1$AAAAAAAAAAAAAAAAAAAAAA==$AAAA",
            "$argon2i$v=19$m=65536,t=3,p=1$AAAAAAAAAAAAAAAAAAAAAA==$AAAA",
            "not-a-hash",
            ""
          ]
    forM_ malformed \h ->
      assertBool
        ("expected False for " <> Text.unpack h)
        (not (verifyPasswordArgon2id "hunter2" (PasswordHash h)))

-- | The login timing oracle, at the level where it is actually created.
--
-- A login that never reaches a stored hash burns 'dummyHashFor' instead. That must cost what
-- verifying a real hash costs, or response time reveals whether an account exists. This is
-- asserted structurally — same embedded parameters — rather than with a stopwatch, because
-- equal parameters mean equal Argon2 work by construction, and a wall-clock assertion would
-- be flaky. ('Shomei.Workflow.TimingSpec' asserts the complementary property: that every
-- login path performs exactly one such operation.)
testArgon2DummyHashTracksConfiguredParams :: TestTree
testArgon2DummyHashTracksConfiguredParams =
  testCase "argon2: the dummy hash carries the configured params, so a miss costs what a hit costs" do
    forM_ [defaultArgon2Params, cheapParams, Argon2Params 19456 2 1] \params -> do
      real <- hashPasswordArgon2id params "hunter2"
      let dummy = dummyHashFor params
      assertEqual
        ("the dummy must derive with the same params as a real hash, for " <> show params)
        (costFields real)
        (costFields dummy)
      -- It must be well-formed: a malformed dummy would return False WITHOUT hashing (~9 µs
      -- versus ~100 ms), silently reopening the oracle it exists to close. Verifying against
      -- it does full Argon2 work and then fails the comparison, which is exactly the point.
      verifyPasswordArgon2id "hunter2" dummy @?= False
  where
    -- The version and parameter fields of a PHC string: everything that decides the cost.
    costFields (PasswordHash t) = case Text.splitOn "$" t of
      ("" : "argon2id" : version : params : _) -> Just (version, params)
      _ -> Nothing

-- Hashing limiter -------------------------------------------------------------

-- | At most @limit@ Argon2 derivations may run at once, no matter how many requests arrive.
--
-- Sixteen threads race for permits. Each holds its permit for a fixed 25 ms before hashing, so
-- the first @limit@ of them are provably in flight together and the high-water mark reaches
-- @limit@ exactly. The assertion that matters is @peak <= limit@ — that is the bound; the
-- @peak == limit@ half only confirms the test actually saturated the gate rather than
-- trivially passing.
testHashingLimiterBoundsConcurrency :: Int -> TestTree
testHashingLimiterBoundsConcurrency limit =
  testCase ("hashing limiter: peak concurrency never exceeds the limit (" <> show limit <> ")") do
    limiter <- newHashingLimiter limit
    dones <- replicateM 16 newEmptyMVar
    forM_ (zip [1 :: Int ..] dones) \(i, done) ->
      void $ forkIO do
        h <- withHashingPermit limiter do
          threadDelay 25_000
          hashPasswordArgon2id cheapParams ("pw" <> Text.pack (show i))
        putMVar done (i, h)
    results <- mapM takeMVar dones

    peak <- peakHashingConcurrency limiter
    assertBool ("peak " <> show peak <> " exceeded the limit " <> show limit) (peak <= limit)
    assertEqual "the test must saturate the gate, or it proves nothing" limit peak

    -- Every hash is real and verifies: the gate serializes work, it does not corrupt it.
    forM_ results \(i, h) ->
      assertBool
        ("hash " <> show i <> " must verify")
        (verifyPasswordArgon2id ("pw" <> Text.pack (show i)) h)

-- | The bound must hold through the effect interpreter, not merely around 'withHashingPermit'.
-- A refactor that dropped the bracket from 'runPasswordHasherCrypto' would leave the previous
-- test green and the server unbounded.
testInterpreterHonorsTheLimiter :: TestTree
testInterpreterHonorsTheLimiter =
  testCase "hashing limiter: the PasswordHasher interpreter acquires a permit" do
    limiter <- newHashingLimiter 2
    dones <- replicateM 8 newEmptyMVar
    forM_ (zip [1 :: Int ..] dones) \(i, done) ->
      void $ forkIO do
        h <-
          runEff
            . runPasswordHasherCrypto limiter cheapParams
            $ hashPassword (PlainPassword ("pw" <> Text.pack (show i)))
        putMVar done h
    _ <- mapM takeMVar dones
    peak <- peakHashingConcurrency limiter
    -- Both halves matter. @peak <= 2@ is the bound. @peak >= 1@ proves a permit was taken at
    -- all: without it, deleting the bracket from the interpreter leaves @peak == 0@ and this
    -- test would pass while the server hashed without limit.
    assertBool ("interpreter allowed " <> show peak <> " concurrent hashes") (peak <= 2)
    assertBool "the interpreter never acquired a permit" (peak >= 1)

-- | A verification of a *dummy* hash also takes a permit — the miss path must be bounded
-- exactly like the hit path, or a flood of logins for nonexistent accounts bypasses the gate.
testDummyVerificationTakesAPermit :: TestTree
testDummyVerificationTakesAPermit =
  testCase "hashing limiter: the dummy verification path is bounded too" do
    limiter <- newHashingLimiter 1
    dones <- replicateM 4 newEmptyMVar
    forM_ dones \done ->
      void $ forkIO do
        runEff . runPasswordHasherCrypto limiter cheapParams $ verifyPasswordDummy (PlainPassword "pw")
        putMVar done ()
    _ <- mapM takeMVar dones
    peak <- peakHashingConcurrency limiter
    peak @?= 1

-- Maintenance sweep ----------------------------------------------------------

-- | A database with one row on each side of every sweep cutoff.
--
-- Ages are expressed relative to the database's @now()@; 'sweepOnce' is handed Haskell's
-- 'getCurrentTime'. The two clocks differ by milliseconds while every offset here is hours or
-- days, so no row sits near a boundary.
--
-- Three sessions: one expired 40 days ago (dead by @expires_at@, holding a three-token
-- rotation family so the sweep must respect @parent_token_id@'s self-referencing foreign
-- key); one revoked 40 days ago but with a far-future @expires_at@ (dead only by the
-- @revoked_at@ branch of the sweep's OR predicate); and one live session that must survive
-- with both of its tokens.
seedSweepFixture :: Pool -> IO ()
seedSweepFixture pool =
  execSql
    pool
    """
    INSERT INTO shomei.shomei_users (user_id, email, display_name, status, created_at, updated_at, login_id) VALUES
      ('11111111-1111-1111-1111-111111111111', 'sweep1@example.com', 'Sweep One', 'active', now() - interval '90 days', now(), 'sweep1@example.com'),
      ('22222222-2222-2222-2222-222222222222', 'sweep2@example.com', 'Sweep Two', 'active', now() - interval '90 days', now(), 'sweep2@example.com');

    INSERT INTO shomei.shomei_sessions (session_id, user_id, status, created_at, expires_at, revoked_at) VALUES
      ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active',  now() - interval '60 days', now() - interval '40 days', NULL),
      ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'revoked', now() - interval '60 days', now() + interval '30 days', now() - interval '40 days'),
      ('aaaaaaaa-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'active',  now() - interval '1 day',   now() + interval '30 days', NULL);

    -- A three-generation rotation family on the expired session, then a single token on the
    -- revoked one, then two live tokens that must survive.
    INSERT INTO shomei.shomei_refresh_tokens
      (refresh_token_id, session_id, token_hash, parent_token_id, status, created_at, expires_at, used_at, revoked_at) VALUES
      ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'hash-dead-1', NULL,                                   'used',   now() - interval '60 days', now() - interval '40 days', now() - interval '59 days', NULL),
      ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'hash-dead-2', 'bbbbbbbb-0000-0000-0000-000000000001', 'used',   now() - interval '59 days', now() - interval '40 days', now() - interval '58 days', NULL),
      ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'hash-dead-3', 'bbbbbbbb-0000-0000-0000-000000000002', 'active', now() - interval '58 days', now() - interval '40 days', NULL, NULL),
      ('bbbbbbbb-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000002', 'hash-revk-1', NULL,                                   'revoked', now() - interval '60 days', now() + interval '30 days', NULL, now() - interval '40 days'),
      ('cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000003', 'hash-live-1', NULL,                                   'used',   now() - interval '1 day', now() + interval '30 days', now() - interval '1 hour', NULL),
      ('cccccccc-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000003', 'hash-live-2', 'cccccccc-0000-0000-0000-000000000001', 'active', now() - interval '1 hour', now() + interval '30 days', NULL, NULL);

    -- One expired past the 7-day grace, one still live.
    INSERT INTO shomei.shomei_email_verification_tokens
      (verification_token_id, user_id, token_hash, status, created_at, expires_at, consumed_at, revoked_at) VALUES
      ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'vhash-old', 'active', now() - interval '11 days', now() - interval '10 days', NULL, NULL),
      ('dddddddd-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'vhash-new', 'active', now(), now() + interval '1 day', NULL, NULL);

    INSERT INTO shomei.shomei_password_reset_tokens
      (password_reset_token_id, user_id, token_hash, status, created_at, expires_at, consumed_at, revoked_at) VALUES
      ('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'phash-old', 'active', now() - interval '11 days', now() - interval '10 days', NULL, NULL),
      ('eeeeeeee-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'phash-new', 'active', now(), now() + interval '1 day', NULL, NULL);

    -- Expired 2 hours ago (past the 60-minute grace); expired 30 minutes ago (inside it); live.
    INSERT INTO shomei.shomei_webauthn_pending_ceremonies (ceremony_id, user_id, kind, options_blob, created_at, expires_at) VALUES
      ('ffffffff-0000-0000-0000-000000000001', NULL, 'authentication', '\\x00'::bytea, now() - interval '3 hours',  now() - interval '2 hours'),
      ('ffffffff-0000-0000-0000-000000000002', NULL, 'authentication', '\\x00'::bytea, now() - interval '90 minutes', now() - interval '30 minutes'),
      ('ffffffff-0000-0000-0000-000000000003', NULL, 'registration',   '\\x00'::bytea, now(), now() + interval '1 hour');

    -- Elapsed past the 7-day grace; elapsed yesterday (inside it); not locked at all.
    INSERT INTO shomei.shomei_account_lockouts (account_key, failed_count, locked_until, updated_at) VALUES
      ('lockout-elapsed', 5, now() - interval '10 days', now() - interval '10 days'),
      ('lockout-recent',  5, now() - interval '1 day',   now() - interval '1 day'),
      ('lockout-counting', 2, NULL, now());

    -- Past the 90-day retention window; inside it.
    INSERT INTO shomei.shomei_login_attempts (attempt_id, account_key, client_ip, outcome, occurred_at) VALUES
      ('99999999-0000-0000-0000-000000000001', 'acct', '10.0.0.1', 'failure', now() - interval '100 days'),
      ('99999999-0000-0000-0000-000000000002', 'acct', '10.0.0.1', 'failure', now() - interval '10 days');

    -- Audit events are retained forever by default; the 400-day-old one only goes when an
    -- explicit retention window is configured.
    INSERT INTO shomei.shomei_auth_events (event_id, user_id, session_id, event_type, payload, created_at) VALUES
      ('88888888-0000-0000-0000-000000000001', NULL, NULL, 'login_succeeded', '{}'::jsonb, now() - interval '400 days'),
      ('88888888-0000-0000-0000-000000000002', NULL, NULL, 'login_succeeded', '{}'::jsonb, now());
    """

testSweepDeletesExpiredRows :: TestTree
testSweepDeletesExpiredRows =
  testCase "maintenance sweep: deletes exactly the expired rows and spares the rest" $ withDb \pool -> do
    seedSweepFixture pool
    t <- getCurrentTime
    report <- sweepOnce pool defaultSweepConfig t >>= expectSweep
    report
      @?= SweepReport
        { -- three from the expired session's rotation family, one from the revoked session
          refreshTokensDeleted = 4,
          -- the expired one and the revoked one; the live session stays
          sessionsDeleted = 2,
          verificationTokensDeleted = 1,
          resetTokensDeleted = 1,
          ceremoniesDeleted = 1,
          lockoutsDeleted = 1,
          loginAttemptsDeleted = 1,
          -- retention disabled by default
          authEventsDeleted = 0
        }

    -- The survivors are exactly the rows on the live side of each cutoff.
    scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions" >>= (@?= 1)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens" >>= (@?= 2)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_email_verification_tokens" >>= (@?= 1)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_password_reset_tokens" >>= (@?= 1)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_pending_ceremonies" >>= (@?= 2)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_account_lockouts" >>= (@?= 2)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_login_attempts" >>= (@?= 1)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events" >>= (@?= 2)
    -- Users are never swept.
    scalarInt pool "SELECT count(*) FROM shomei.shomei_users" >>= (@?= 2)
    -- The live session kept its whole token chain, parent link intact.
    scalarInt
      pool
      "SELECT count(*) FROM shomei.shomei_refresh_tokens WHERE session_id = 'aaaaaaaa-0000-0000-0000-000000000003'"
      >>= (@?= 2)

testSweepIsIdempotent :: TestTree
testSweepIsIdempotent =
  testCase "maintenance sweep: a second sweep is a no-op" $ withDb \pool -> do
    seedSweepFixture pool
    t <- getCurrentTime
    _ <- sweepOnce pool defaultSweepConfig t >>= expectSweep
    second <- sweepOnce pool defaultSweepConfig t >>= expectSweep
    second @?= emptySweepReport

testSweepAuthEventRetention :: TestTree
testSweepAuthEventRetention =
  testCase "maintenance sweep: audit events go only when a retention window is configured" $ withDb \pool -> do
    seedSweepFixture pool
    t <- getCurrentTime
    -- Default config leaves both events in place.
    def <- sweepOnce pool defaultSweepConfig t >>= expectSweep
    def.authEventsDeleted @?= 0
    scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events" >>= (@?= 2)

    -- A 365-day window takes the 400-day-old event and nothing else.
    let retaining = defaultSweepConfig {authEventRetentionDays = Just 365}
    withWindow <- sweepOnce pool retaining t >>= expectSweep
    withWindow @?= emptySweepReport {authEventsDeleted = 1}
    scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events" >>= (@?= 1)

testSweepBatchesUntilDrained :: TestTree
testSweepBatchesUntilDrained =
  testCase "maintenance sweep: batches until drained" $ withDb \pool -> do
    -- 25 expired ceremonies with a batch size of 10 needs three passes of the drain loop.
    execSql
      pool
      """
      INSERT INTO shomei.shomei_webauthn_pending_ceremonies (ceremony_id, user_id, kind, options_blob, created_at, expires_at)
      SELECT gen_random_uuid(), NULL, 'authentication', '\\x00'::bytea, now() - interval '3 hours', now() - interval '2 hours'
      FROM generate_series(1, 25);
      """
    t <- getCurrentTime
    report <- sweepOnce pool defaultSweepConfig {batchSize = 10} t >>= expectSweep
    report.ceremoniesDeleted @?= 25
    scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_pending_ceremonies" >>= (@?= 0)

-- | A whole rotation family must be deleted by one statement: @parent_token_id@ is a
-- self-referencing foreign key with no @ON DELETE@ action, so a row-bounded batch that split
-- a family would fail with a foreign-key violation. 'sweepOnce' batches by /session/ to avoid
-- this, which a batch size of 1 exercises directly — one session per statement, five tokens.
testSweepBatchesWholeTokenFamilies :: TestTree
testSweepBatchesWholeTokenFamilies =
  testCase "maintenance sweep: a batch never splits a refresh-token rotation family" $ withDb \pool -> do
    execSql
      pool
      """
      INSERT INTO shomei.shomei_users (user_id, email, display_name, status, created_at, updated_at, login_id) VALUES
        ('11111111-1111-1111-1111-111111111111', 'fam@example.com', 'Fam', 'active', now(), now(), 'fam@example.com');

      INSERT INTO shomei.shomei_sessions (session_id, user_id, status, created_at, expires_at, revoked_at) VALUES
        ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'active', now() - interval '60 days', now() - interval '40 days', NULL),
        ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'active', now() - interval '60 days', now() - interval '40 days', NULL);

      INSERT INTO shomei.shomei_refresh_tokens
        (refresh_token_id, session_id, token_hash, parent_token_id, status, created_at, expires_at, used_at, revoked_at) VALUES
        ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'h1', NULL,                                   'used',   now(), now() - interval '40 days', now(), NULL),
        ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'h2', 'bbbbbbbb-0000-0000-0000-000000000001', 'used',   now(), now() - interval '40 days', now(), NULL),
        ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'h3', 'bbbbbbbb-0000-0000-0000-000000000002', 'active', now(), now() - interval '40 days', NULL, NULL),
        ('bbbbbbbb-0000-0000-0000-000000000011', 'aaaaaaaa-0000-0000-0000-000000000002', 'h4', NULL,                                   'used',   now(), now() - interval '40 days', now(), NULL),
        ('bbbbbbbb-0000-0000-0000-000000000012', 'aaaaaaaa-0000-0000-0000-000000000002', 'h5', 'bbbbbbbb-0000-0000-0000-000000000011', 'active', now(), now() - interval '40 days', NULL, NULL);
      """
    t <- getCurrentTime
    report <- sweepOnce pool defaultSweepConfig {batchSize = 1} t >>= expectSweep
    report.refreshTokensDeleted @?= 5
    report.sessionsDeleted @?= 2
    scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens" >>= (@?= 0)
    scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions" >>= (@?= 0)

latestVerificationToken :: [Notification] -> IO OneTimeToken
latestVerificationToken = \case
  EmailVerificationRequested {token = raw} : _ -> pure raw
  _ -> assertFailure "expected email-verification notification"

latestResetToken :: [Notification] -> IO OneTimeToken
latestResetToken = \case
  PasswordResetRequested {token = raw} : _ -> pure raw
  _ -> assertFailure "expected password-reset notification"
