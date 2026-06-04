{- | Integration tests for the PostgreSQL adapters, run against throwaway databases
provisioned by @shomei-migrations:test-support@ (ephemeral-pg + codd). Each test gets a
fresh migrated database, acquires a hasql pool, runs the real interpreters, and asserts
behavior — first port-by-port round-trips, then EP-2's workflows driven through the
PostgreSQL interpreters with database-state assertions.
-}
module Main (main) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (addUTCTime)

import Effectful (Eff, IOE, runEff)
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

import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Command (RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (NewRefreshToken (..), PersistedRefreshToken (..), RefreshToken (..), RefreshTokenStatus (..))
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (NewUser (..), User (..))
import Shomei.Error (AuthError (RefreshTokenReuseDetected))

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.CredentialStore (CredentialStore, createPasswordCredential, findPasswordCredentialByEmail)
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore, createRefreshToken, findRefreshTokenByHash, markRefreshTokenUsed)
import Shomei.Effect.SessionStore (SessionStore, createSession, findSessionById, revokeSession)
import Shomei.Effect.SigningKeyStore (SigningKeyStore, findSigningKeyByKid, insertSigningKey, listActiveSigningKeys)
import Shomei.Effect.TokenGen (TokenGen, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.UserStore (UserStore, createUser, findUserByEmail, findUserById)
import Shomei.Workflow (refresh, signup)

import Shomei.Crypto (runPasswordHasherCrypto, runTokenGenCrypto)
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.AuthEventPublisher (runAuthEventPublisherPostgres)
import Shomei.Postgres.Clock (runClockIO)
import Shomei.Postgres.CredentialStore (runCredentialStorePostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Postgres.RefreshTokenStore (runRefreshTokenStorePostgres)
import Shomei.Postgres.SessionStore (runSessionStorePostgres)
import Shomei.Postgres.SigningKeyStore (runSigningKeyStorePostgres)
import Shomei.Postgres.UserStore (runUserStorePostgres)

{- | The full interpreter stack used by every test. The store interpreters are peeled
first (Database/IOE/Error remain available to them); @TokenSigner@ is a trivial fake
because real signing is EP-4.
-}
type AppEffects =
    '[ UserStore
     , CredentialStore
     , SessionStore
     , RefreshTokenStore
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
runApp pool =
    runEff
        . runErrorNoCallStack
        . runDatabasePool pool
        . runClockIO
        . runTokenGenCrypto
        . runPasswordHasherCrypto
        . runTokenSignerFake
        . runSigningKeyStorePostgres
        . runAuthEventPublisherPostgres
        . runRefreshTokenStorePostgres
        . runSessionStorePostgres
        . runCredentialStorePostgres
        . runUserStorePostgres

{- | A trivial 'TokenSigner' (real signing is EP-4); the DB-state assertions never inspect
the access token's contents.
-}
runTokenSignerFake :: Eff (TokenSigner : es) a -> Eff es a
runTokenSignerFake = interpret_ \case
    SignAccessToken _ -> pure (AccessToken "test-access-token")

-- Helpers --------------------------------------------------------------------

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

aliceEmail :: Email
aliceEmail = mkEmail' "alice@example.com"

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
    , testRefreshTokenMarkUsed
    , testSigningKeys
    , testPublishEvent
    , testWorkflowSignup
    , testWorkflowRefreshRotation
    , testWorkflowReuseRevokesFamily
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
        s <- createSession (NewSession{userId = u.userId, createdAt = t, expiresAt = addUTCTime 3600 t})
        revokeSession s.sessionId t
        findSessionById s.sessionId
    found <- expectApp result
    fmap (.status) found @?= Just SessionRevoked

testRefreshTokenMarkUsed :: TestTree
testRefreshTokenMarkUsed = testCase "create refresh token + find-by-hash + mark-used" $ withDb \pool -> do
    result <- runApp pool do
        u <- createUser (NewUser{email = aliceEmail, displayName = Nothing})
        t <- now
        s <- createSession (NewSession{userId = u.userId, createdAt = t, expiresAt = addUTCTime 3600 t})
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
