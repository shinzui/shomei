{- | Integration tests for the PostgreSQL adapters, run against throwaway databases
provisioned by @shomei-migrations:test-support@ (ephemeral-pg + codd). Each test gets a
fresh migrated database, acquires a hasql pool, runs the real interpreters, and asserts
behavior — first port-by-port round-trips, then EP-2's workflows driven through the
PostgreSQL interpreters with database-state assertions.
-}
module Main (main) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)

import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)

import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (RateLimitConfig (..), ShomeiConfig (..), defaultRateLimitConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, emailText, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (AccountKey (..), AccountLockout (..), ClientIp (..), LoginOutcome (..), NewLoginAttempt (..))
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken, OneTimeTokenHash (..), OneTimeTokenStatus (..))
import Shomei.Domain.Passkey (
    CeremonyKind (..),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
 )
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken (NewRefreshToken (..), PersistedRefreshToken (..), RefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (NewUser (..), User (..))
import Shomei.Domain.VerificationToken (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Error (AuthError (InvalidCredentials, RefreshTokenReuseDetected))
import Shomei.Id (PasskeyId, genCeremonyId, genUserId)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock (..), now)
import Shomei.Effect.CredentialStore (CredentialStore, createPasswordCredential, findPasswordCredentialByEmail)
import Shomei.Effect.LoginAttemptStore (
    LoginAttemptStore,
    clearAccountLockout,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    recordLoginAttempt,
    setAccountLockout,
 )
import Shomei.Effect.Notifier (Notifier (..))
import Shomei.Effect.PasskeyStore (
    PasskeyStore,
    countPasskeysByUser,
    createPasskey,
    deletePasskey,
    findPasskeyByCredentialId,
    findPasskeysByUser,
    findPasskeysByUserHandle,
    updatePasskeySignCounter,
 )
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword)
import Shomei.Effect.PasswordResetTokenStore (
    PasswordResetTokenStore,
    createPasswordResetToken,
    findPasswordResetTokenByHash,
    markPasswordResetTokenConsumed,
 )
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony, takePendingCeremony)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore, createRefreshToken, findRefreshTokenByHash, markRefreshTokenUsed)
import Shomei.Effect.SessionStore (SessionStore, createSession, findSessionById, revokeSession)
import Shomei.Effect.SigningKeyStore (SigningKeyStore, findSigningKeyByKid, insertSigningKey, listActiveSigningKeys)
import Shomei.Effect.TokenGen (TokenGen, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.InMemory (emptyWorld, runWebAuthnCeremonyFake)
import Shomei.Effect.UserStore (UserStore, createUser, findUserByEmail, findUserById, markUserEmailVerified)
import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)
import Shomei.Effect.VerificationTokenStore (
    VerificationTokenStore,
    createVerificationToken,
    findVerificationTokenByHash,
    markVerificationTokenConsumed,
 )
import Shomei.Workflow (login, refresh, signup)
import Shomei.Workflow.Account (
    ConfirmEmailVerification (..),
    ConfirmPasswordReset (..),
    RequestEmailVerification (..),
    RequestPasswordReset (..),
    confirmEmailVerification,
    confirmPasswordReset,
    requestEmailVerification,
    requestPasswordReset,
 )

import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.LoginAttemptStore (runLoginAttemptStorePostgres)
import Shomei.Postgres.PasskeyStore (runPasskeyStorePostgres)
import Shomei.Postgres.PasswordResetTokenStore (runPasswordResetTokenStorePostgres)
import Shomei.Postgres.PendingCeremonyStore (runPendingCeremonyStorePostgres)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)
import Shomei.Postgres.VerificationTokenStore (runVerificationTokenStorePostgres)

{- | The full interpreter stack used by every test. The store interpreters are peeled
first (Database/IOE/Error remain available to them); @TokenSigner@ is a trivial fake
because real signing is EP-4.
-}
type AppEffects =
    '[ UserStore
     , CredentialStore
     , SessionStore
     , RefreshTokenStore
     , VerificationTokenStore
     , PasswordResetTokenStore
     , LoginAttemptStore
     , PasskeyStore
     , PendingCeremonyStore
     , Notifier
     , WebAuthnCeremony
     , AuthEventPublisher
     , SigningKeyStore
     , TokenSigner
     , PasswordHasher
     , TokenGen
     , Clock
     , Database
     , Error AuthError
     , IOE
     ]

runApp :: Pool -> Eff AppEffects a -> IO (Either AuthError a)
runApp pool action = do
    ref <- newIORef []
    runAppWithNotifications ref pool action

runAppWithNotifications :: IORef [Notification] -> Pool -> Eff AppEffects a -> IO (Either AuthError a)
runAppWithNotifications ref pool action = do
    wref <- newIORef (emptyWorld (UTCTime (fromGregorian 2000 1 1) 0))
    ( runEff
            . runErrorNoCallStack
            . runDatabasePool pool
            . runClockIO
            . runTokenGenCrypto
            . runPasswordHasherCrypto
            . runTokenSignerFake
            . runSigningKeyStorePostgres
            . runAuthEventPublisherPostgres
            . runWebAuthnCeremonyFake wref
            . runNotifierRef ref
            . runPendingCeremonyStorePostgres
            . runPasskeyStorePostgres
            . runLoginAttemptStorePostgres
            . runPasswordResetTokenStorePostgres
            . runVerificationTokenStorePostgres
            . runRefreshTokenStorePostgres
            . runSessionStorePostgres
            . runCredentialStorePostgres
            . runUserStorePostgres
        )
        action

{- | Run the stack with a FIXED clock (the EP-2 lockout tests need to advance time
deterministically across calls against the same database). Notifications are discarded.
-}
runAppAtTime :: UTCTime -> Pool -> Eff AppEffects a -> IO (Either AuthError a)
runAppAtTime t pool action = do
    ref <- newIORef []
    wref <- newIORef (emptyWorld t)
    ( runEff
            . runErrorNoCallStack
            . runDatabasePool pool
            . runClockFixed t
            . runTokenGenCrypto
            . runPasswordHasherCrypto
            . runTokenSignerFake
            . runSigningKeyStorePostgres
            . runAuthEventPublisherPostgres
            . runWebAuthnCeremonyFake wref
            . runNotifierRef ref
            . runPendingCeremonyStorePostgres
            . runPasskeyStorePostgres
            . runLoginAttemptStorePostgres
            . runPasswordResetTokenStorePostgres
            . runVerificationTokenStorePostgres
            . runRefreshTokenStorePostgres
            . runSessionStorePostgres
            . runCredentialStorePostgres
            . runUserStorePostgres
        )
        action

runClockFixed :: UTCTime -> Eff (Clock : es) a -> Eff es a
runClockFixed t = interpret_ \case
    Now -> pure t

{- | A trivial 'TokenSigner' (real signing is EP-4); the DB-state assertions never inspect
the access token's contents.
-}
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
lockCfg = cfg{rateLimitConfig = defaultRateLimitConfig{maxFailedLoginsPerAccount = 3}}

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

bobEmail :: Email
bobEmail = mkEmail' "bob@example.com"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' t = case mkEmail t of
    Right e -> e
    Left err -> error ("bad test email: " <> show err)

-- | Run an action over a fresh migrated database and a pool.
withDb :: (Pool -> IO a) -> IO a
withDb action = withShomeiMigratedDatabase \connStr -> do
    pool <- acquirePool 4 connStr
    action pool

-- | Unwrap the @Either AuthError@ from 'runApp' (the interpreter-level failure channel).
expectApp :: (Show e) => Either e a -> IO a
expectApp = either (\e -> assertFailure ("interpreter error: " <> show e)) pure

-- | Unwrap a workflow's own @Either AuthError@ result.
expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

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
    [ testUserRoundTrip
    , testCredentialRoundTrip
    , testSessionRevoke
    , testSessionActorRoundTrip
    , testRefreshTokenMarkUsed
    , testVerificationTokenRoundTrip
    , testPasswordResetTokenRoundTrip
    , testMarkUserEmailVerified
    , testSigningKeys
    , testPublishEvent
    , testWorkflowSignup
    , testWorkflowRefreshRotation
    , testWorkflowReuseRevokesFamily
    , testWorkflowAccountVerification
    , testWorkflowPasswordReset
    , testLoginAttemptStore
    , testWorkflowLockout
    , testPasskeyCreateAndFind
    , testPasskeyUpdateCountDelete
    , testPendingCeremonyConsumeOnce
    , testPendingCeremonyExpired
    ]

testUserRoundTrip :: TestTree
testUserRoundTrip = testCase "create + find user round-trips" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Just "Alice"})
        byId <- findUserById u.userId
        byEmail <- findUserByEmail aliceEmail
        pure (u, byId, byEmail)
    (u, byId, byEmail) <- expectApp result
    fmap (.userId) byId @?= Just u.userId
    fmap (.email) byId @?= Just aliceEmail
    fmap (.displayName) byId @?= Just (Just "Alice")
    fmap (.userId) byEmail @?= Just u.userId

testCredentialRoundTrip :: TestTree
testCredentialRoundTrip = testCase "create credential + find-by-email" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        h <- hashPassword strongPw
        _ <- createPasswordCredential u.userId aliceEmail h
        found <- findPasswordCredentialByEmail aliceEmail
        pure (u, h, found)
    (u, h, found) <- expectApp result
    fmap (.userId) found @?= Just u.userId
    fmap (.email) found @?= Just aliceEmail
    fmap (.passwordHash) found @?= Just h

testSessionRevoke :: TestTree
testSessionRevoke = testCase "create session + revoke" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        t <- now
        s <- createSession (NewSession{userId = u.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
        revokeSession s.sessionId t
        findSessionById s.sessionId
    found <- expectApp result
    fmap (.status) found @?= Just SessionRevoked

testSessionActorRoundTrip :: TestTree
testSessionActorRoundTrip = testCase "create delegated session persists actor" $ withDb \pool -> do
    result <- runApp pool do
        subject <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        operator <- createUser (NewUser{email = bobEmail, displayName = Nothing})
        t <- now
        delegated <-
            createSession
                ( NewSession
                    { userId = subject.userId
                    , createdAt = t
                    , expiresAt = addUTCTime 3600 t
                    , actor = Just operator.userId
                    }
                )
        normal <- createSession (NewSession{userId = subject.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
        foundDelegated <- findSessionById delegated.sessionId
        foundNormal <- findSessionById normal.sessionId
        pure (operator.userId, foundDelegated, foundNormal)
    (op, foundDelegated, foundNormal) <- expectApp result
    fmap (.actor) foundDelegated @?= Just (Just op)
    fmap (.actor) foundNormal @?= Just Nothing

testRefreshTokenMarkUsed :: TestTree
testRefreshTokenMarkUsed = testCase "create refresh token + find-by-hash + mark-used" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        t <- now
        s <- createSession (NewSession{userId = u.userId, createdAt = t, expiresAt = addUTCTime 3600 t, actor = Nothing})
        h <- hashRefreshToken (RefreshToken "token-1")
        persisted <-
            createRefreshToken
                NewRefreshToken
                    { sessionId = s.sessionId
                    , tokenHash = h
                    , parentTokenId = Nothing
                    , createdAt = t
                    , expiresAt = addUTCTime 86400 t
                    }
        beforeUse <- findRefreshTokenByHash h
        markRefreshTokenUsed persisted.refreshTokenId t
        afterUse <- findRefreshTokenByHash h
        pure (beforeUse, afterUse)
    (beforeUse, afterUse) <- expectApp result
    fmap (.status) beforeUse @?= Just RefreshTokenActive
    fmap (.status) afterUse @?= Just RefreshTokenUsed

testVerificationTokenRoundTrip :: TestTree
testVerificationTokenRoundTrip = testCase "create verification token + consume" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        t <- now
        let h = OneTimeTokenHash "hash:verify-1"
        persisted <-
            createVerificationToken
                NewVerificationToken
                    { userId = u.userId
                    , tokenHash = h
                    , createdAt = t
                    , expiresAt = addUTCTime 3600 t
                    }
        before <- findVerificationTokenByHash h
        markVerificationTokenConsumed persisted.verificationTokenId t
        after <- findVerificationTokenByHash h
        pure (before, after)
    (before, after) <- expectApp result
    fmap (.status) before @?= Just OneTimeTokenActive
    fmap (.status) after @?= Just OneTimeTokenConsumed

testPasswordResetTokenRoundTrip :: TestTree
testPasswordResetTokenRoundTrip = testCase "create password reset token + consume" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        t <- now
        let h = OneTimeTokenHash "hash:reset-1"
        persisted <-
            createPasswordResetToken
                NewPasswordResetToken
                    { userId = u.userId
                    , tokenHash = h
                    , createdAt = t
                    , expiresAt = addUTCTime 3600 t
                    }
        before <- findPasswordResetTokenByHash h
        markPasswordResetTokenConsumed persisted.passwordResetTokenId t
        after <- findPasswordResetTokenByHash h
        pure (before, after)
    (before, after) <- expectApp result
    fmap (.status) before @?= Just OneTimeTokenActive
    fmap (.status) after @?= Just OneTimeTokenConsumed

testMarkUserEmailVerified :: TestTree
testMarkUserEmailVerified = testCase "mark user email verified sets the timestamp" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
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
                    { keyId = "kid-1"
                    , algorithm = "ES256"
                    , publicKeyJwk = "{\"kty\":\"EC\"}"
                    , privateKeyJwk = "{\"kty\":\"EC\",\"d\":\"x\"}"
                    , status = KeyActive
                    , createdAt = t
                    , activatedAt = Just t
                    , retiredAt = Nothing
                    }
        insertSigningKey key
        active <- listActiveSigningKeys
        byKid <- findSigningKeyByKid "kid-1"
        pure (active, byKid)
    (active, byKid) <- expectApp result
    fmap (.keyId) active @?= ["kid-1"]
    fmap (.keyId) byKid @?= Just "kid-1"

testPublishEvent :: TestTree
testPublishEvent = testCase "publish auth event lands a row" $ withDb \pool -> do
    result <- runApp pool do
        t <- now
        publishAuthEvent (Event.LoginFailed (Event.LoginFailedData aliceEmail t))
    _ <- expectApp result
    n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_auth_events"
    n @?= 1

testWorkflowSignup :: TestTree
testWorkflowSignup = testCase "workflow: signup persists user + session + token" $ withDb \pool -> do
    inner <- runApp pool (signup cfg (SignupCommand aliceEmail strongPw (Just "Alice")))
    _ <- expectApp inner >>= expectRight
    users <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users"
    sessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions"
    toks <- scalarInt pool "SELECT count(*) FROM shomei.shomei_refresh_tokens"
    users @?= 1
    sessions @?= 1
    toks @?= 1

testWorkflowRefreshRotation :: TestTree
testWorkflowRefreshRotation = testCase "workflow: refresh rotation marks used + inserts child" $ withDb \pool -> do
    signupRes <- runApp pool (signup cfg (SignupCommand aliceEmail strongPw Nothing))
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
    signupRes <- runApp pool (signup cfg (SignupCommand aliceEmail strongPw Nothing))
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
    signupRes <- runAppWithNotifications notifications pool (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    (user, _) <- expectApp signupRes >>= expectRight
    requestRes <- runAppWithNotifications notifications pool (requestEmailVerification cfg (RequestEmailVerification user.email))
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
    signupRes <- runAppWithNotifications notifications pool (signup cfg (SignupCommand aliceEmail strongPw Nothing))
    (_, pair) <- expectApp signupRes >>= expectRight
    requestRes <- runAppWithNotifications notifications pool (requestPasswordReset cfg (RequestPasswordReset aliceEmail))
    _ <- expectApp requestRes >>= expectRight
    raw <- latestResetToken =<< readIORef notifications
    confirmRes <- runAppWithNotifications notifications pool (confirmPasswordReset cfg (ConfirmPasswordReset raw (PlainPassword "correct horse battery staple two")))
    _ <- expectApp confirmRes >>= expectRight
    loginRes <- runAppWithNotifications notifications pool (login cfg (ClientContext (ClientIp "test-ip") (AccountKey (emailText aliceEmail))) (LoginCommand aliceEmail (PlainPassword "correct horse battery staple two")))
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
    seeded <- runAppAtTime t0 pool (signup lockCfg (SignupCommand aliceEmail strongPw Nothing))
    _ <- expectApp seeded >>= expectRight
    let ctx = ClientContext (ClientIp "10.0.0.9") (AccountKey (emailText aliceEmail))
        badLogin = login lockCfg ctx (LoginCommand aliceEmail (PlainPassword "wrong"))
    _ <- runAppAtTime t0 pool badLogin >>= expectApp
    _ <- runAppAtTime t0 pool badLogin >>= expectApp
    r3 <- runAppAtTime t0 pool badLogin >>= expectApp
    r3 @?= Left InvalidCredentials
    locked <- scalarInt pool "SELECT count(*) FROM shomei.shomei_account_lockouts WHERE locked_until IS NOT NULL"
    locked @?= 1
    -- The correct password while still locked returns the SAME generic error (no leak).
    denied <- runAppAtTime t0 pool (login lockCfg ctx (LoginCommand aliceEmail strongPw)) >>= expectApp
    denied @?= Left InvalidCredentials
    -- After the cooldown (15 min default) the correct password succeeds and clears the lockout.
    ok <- runAppAtTime (addUTCTime (16 * 60) t0) pool (login lockCfg ctx (LoginCommand aliceEmail strongPw)) >>= expectApp
    _ <- expectRight ok
    remaining <- scalarInt pool "SELECT count(*) FROM shomei.shomei_account_lockouts"
    remaining @?= 0

-- Passkey field accessors: OverloadedRecordDot is unreliable for these
-- DuplicateRecordFields records (MasterPlan 3 discovery), so read via record-pattern.
pkPasskeyId :: PasskeyCredential -> PasskeyId
pkPasskeyId PasskeyCredential{passkeyId} = passkeyId

pkSignCounter :: PasskeyCredential -> SignatureCounter
pkSignCounter PasskeyCredential{signCounter} = signCounter

pkLastUsedAt :: PasskeyCredential -> Maybe UTCTime
pkLastUsedAt PasskeyCredential{lastUsedAt} = lastUsedAt

pkTransports :: PasskeyCredential -> [Text]
pkTransports PasskeyCredential{transports} = transports

pkLabel :: PasskeyCredential -> Maybe Text
pkLabel PasskeyCredential{label} = label

-- | A 'NewPasskeyCredential' with canned bytes for the given user and time.
newPasskey :: User -> UTCTime -> NewPasskeyCredential
newPasskey u t =
    NewPasskeyCredential
        { userId = u.userId
        , credentialId = WebAuthnCredentialId "cred-1"
        , userHandle = UserHandle "uh-1"
        , publicKey = PublicKeyBytes "pk-1"
        , signCounter = SignatureCounter 0
        , transports = ["usb", "nfc"]
        , label = Just "key"
        , createdAt = t
        }

testPasskeyCreateAndFind :: TestTree
testPasskeyCreateAndFind = testCase "passkey store: create + find by user/credential-id/user-handle" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
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
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
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
                { ceremonyId = cid
                , userId = Nothing
                , kind = RegistrationCeremony
                , optionsBlob = "{\"challenge\":\"abc\"}"
                , createdAt = t
                , expiresAt = addUTCTime 300 t
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
                { ceremonyId = cid
                , userId = Nothing
                , kind = AuthenticationCeremony
                , optionsBlob = "{\"challenge\":\"xyz\"}"
                , createdAt = t
                , expiresAt = t -- expires immediately
                }
        -- "now" is past expiry: returns Nothing but still removes the stale row
        takePendingCeremony cid (addUTCTime 1 t)
    taken <- expectApp result
    taken @?= (Nothing :: Maybe PendingCeremony)
    remaining <- scalarInt pool "SELECT count(*) FROM shomei.shomei_webauthn_pending_ceremonies"
    remaining @?= 0

latestVerificationToken :: [Notification] -> IO OneTimeToken
latestVerificationToken = \case
    EmailVerificationRequested{token = raw} : _ -> pure raw
    _ -> assertFailure "expected email-verification notification"

latestResetToken :: [Notification] -> IO OneTimeToken
latestResetToken = \case
    PasswordResetRequested{token = raw} : _ -> pure raw
    _ -> assertFailure "expected password-reset notification"
