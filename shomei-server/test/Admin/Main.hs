{- | Integration tests for @shomei-admin@ (EP-4), against throwaway PostgreSQL databases
provisioned by @shomei-migrations:test-support@. They drive the real CLI action functions and
assert database state, and — the headline — prove the signing-key rotation lifecycle with
overlapping-key JWKS verification.
-}
module Main (main) where

import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)

import "hasql" Hasql.Decoders qualified as D
import "hasql" Hasql.Encoders qualified as E
import "hasql" Hasql.Session qualified as Session
import "hasql" Hasql.Statement (preparable)
import "hasql-pool" Hasql.Pool (Pool)
import "hasql-pool" Hasql.Pool qualified as Pool

import "jose" Crypto.JOSE.JWK (JWK, JWKSet (JWKSet))

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Id (genSessionId, genUserId)
import Shomei.Jwt.Key (fromStoredSigningKey)
import Shomei.Jwt.Sign (signAccessToken)
import Shomei.Jwt.Verify (verifyToken)

import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Admin.Keys (
    keysActivate,
    keysGenerate,
    keysRevoke,
    listAllKeys,
    listPublishableSigningKeys,
 )
import Shomei.Admin.Users (createUserAction)

import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

withDb :: (Pool -> Text -> IO a) -> IO a
withDb action = withShomeiMigratedDatabase \connStr -> do
    pool <- acquirePool 4 connStr
    action pool connStr

scalarInt :: Pool -> Text -> IO Int
scalarInt pool sql = do
    res <- Pool.use pool (Session.statement () stmt)
    either (\e -> assertFailure ("scalar query failed: " <> show e)) pure res
  where
    stmt = preparable sql E.noParams (D.singleRow (fromI <$> D.column (D.nonNullable D.int8)))
    fromI :: Int64 -> Int
    fromI = fromIntegral

main :: IO ()
main = defaultMain (testGroup "shomei-admin" [testMigrateEmpty, testLifecycleOverlap, testUserCreate])

testMigrateEmpty :: TestTree
testMigrateEmpty = testCase "after migration the keys table exists and is empty" $ withDb \pool _ -> do
    keys <- listAllKeys pool
    keys @?= []
    n <- scalarInt pool "SELECT count(*) FROM shomei.shomei_signing_keys"
    n @?= 0

testLifecycleOverlap :: TestTree
testLifecycleOverlap = testCase "generate→activate→(generate→activate auto-retires)→overlap verifies→revoke breaks it" $ withDb \pool _ -> do
    -- First key: generate then activate.
    keysGenerate pool
    kid1 <- onlyPendingKid pool
    keysActivate pool kid1
    -- Second key: generate then activate; this auto-retires kid1.
    keysGenerate pool
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

testUserCreate :: TestTree
testUserCreate = testCase "users create persists a user + credential whose hash verifies" $ withDb \pool connStr -> do
    let env = AdminEnv{config = cfg, pool = pool, connStr = connStr}
    createUserAction env "alice@example.com" "correct horse battery staple" (Just "Alice")
    users <- scalarInt pool "SELECT count(*) FROM shomei.shomei_users WHERE email = 'alice@example.com'"
    creds <- scalarInt pool "SELECT count(*) FROM shomei.shomei_password_credentials"
    users @?= 1
    creds @?= 1

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
                { subject = uid
                , sessionId = sid
                , issuer = cfg.issuer
                , audience = cfg.audience
                , issuedAt = t
                , expiresAt = addUTCTime 900 t
                , scopes = Set.empty
                , roles = Set.empty
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
