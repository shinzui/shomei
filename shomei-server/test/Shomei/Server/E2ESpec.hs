-- | End-to-end test for the standalone server: a fresh ephemeral PostgreSQL database
-- (via @shomei-migrations:test-support@), the real server in-process through warp's
-- 'testWithApplication', driven over HTTP with @http-client@. Asserts the full lifecycle —
-- signup, login, me (with and without a token), refresh rotation, refresh-token reuse
-- detection (HTTP 401 plus the persisted session revocation and reuse event), logout, the
-- public JWKS document, and health — i.e. the vertical slice actually behaves against real
-- PostgreSQL and real ES256 signing.
module Shomei.Server.E2ESpec (tests) where

import Data.Aeson (Value (Array, Object, String), decode, encode, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.IORef (newIORef)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    defaultManagerSettings,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types (Header, statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Shomei.Config (defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.SigningKey (SigningAlgorithm (ES256))
import Shomei.Migrations.TestSupport (withShomeiMigratedDatabase)
import Shomei.Postgres.Pool (acquirePool)
import Shomei.Server.App (Env (..))
import Shomei.Server.Boot (application)
import Shomei.Server.Keys (bootstrapKeys)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "auth lifecycle over HTTP against PostgreSQL"
    [ testCase "signup → login → me(±token) → refresh → reuse-detect → logout → jwks → health" $
        withShomeiMigratedDatabase \connStr -> do
          pool <- acquirePool 4 connStr
          keysRef <- newIORef =<< bootstrapKeys Nothing ES256 pool
          envMgr <- newManager defaultManagerSettings
          let cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")
              env = Env {envPool = pool, envConfig = cfg, envKeys = keysRef, envKek = Nothing, envHttpManager = envMgr}
          testWithApplication (pure (application env)) (scenario pool)
    ]

scenario :: Pool -> Int -> IO ()
scenario pool port = do
  mgr <- newManager defaultManagerSettings

  -- (a) signup: 200 with a token pair and an active user.
  (sStatus, sBody) <- postJSON mgr port "/auth/signup" signupBody
  sStatus @?= 200
  sresp <- must "signup body" sBody
  (dig ["user", "email"] sresp >>= asText) @?= Just email
  (dig ["user", "status"] sresp >>= asText) @?= Just "active"
  signupRefresh <- must "signup refreshToken" (dig ["token", "refreshToken"] sresp >>= asText)

  -- (b) login: a fresh token pair.
  (lStatus, lBody) <- postJSON mgr port "/auth/login" loginBody
  lStatus @?= 200
  lresp <- must "login body" lBody
  loginAccess <- must "login accessToken" (dig ["token", "accessToken"] lresp >>= asText)

  -- (c) me with Bearer → 200; (d) without → 401.
  (meStatus, meBody) <- getJSON mgr port "/auth/me" (bearer loginAccess)
  meStatus @?= 200
  meresp <- must "me body" meBody
  (dig ["email"] meresp >>= asText) @?= Just email
  (noTokStatus, _) <- getJSON mgr port "/auth/me" []
  noTokStatus @?= 401

  -- (e) refresh rotates the signup token.
  (rStatus, rBody) <- postJSON mgr port "/auth/refresh" (object ["refreshToken" .= signupRefresh])
  rStatus @?= 200
  rresp <- must "refresh body" rBody
  rotatedRefresh <- must "rotated refreshToken" (dig ["refreshToken"] rresp >>= asText)
  assertBool "rotated refresh token differs" (rotatedRefresh /= signupRefresh)

  -- (f) replaying the OLD signup refresh token is detected as theft → 401.
  (reuseStatus, _) <- postJSON mgr port "/auth/refresh" (object ["refreshToken" .= signupRefresh])
  reuseStatus @?= 401

  -- reuse must have landed in PostgreSQL: the family's session is revoked and a
  -- reuse event row exists.
  revokedSessions <- scalarInt pool "SELECT count(*) FROM shomei.shomei_sessions WHERE status = 'revoked'"
  assertBool "reuse revoked the signup session" (revokedSessions >= 1)
  reuseEvents <-
    scalarInt
      pool
      "SELECT count(*) FROM shomei.shomei_auth_events WHERE event_type = 'refresh_token_reuse_detected'"
  reuseEvents @?= 1

  -- (g) the rotated token is now dead too (the whole session was revoked).
  (deadStatus, _) <- postJSON mgr port "/auth/refresh" (object ["refreshToken" .= rotatedRefresh])
  deadStatus @?= 401

  -- (h) logout the login session → 204.
  (logoutStatus, _) <- postJSON mgr port "/auth/logout" (object [])
  -- logout needs a Bearer token; send it as a header-only POST.
  logoutStatus' <- postNoBody mgr port "/auth/logout" (bearer loginAccess)
  logoutStatus @?= 401 -- no token → 401
  logoutStatus' @?= 204

  -- (i) JWKS: a public key with a kid and no private "d".
  (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
  jStatus @?= 200
  jwks <- must "jwks body" jBody
  assertBool "jwks has keys[].kid" (jwksHasKid jwks)
  assertBool "jwks has no private 'd'" (not (hasKeyDeep "d" jwks))

  -- (j) health → 200.
  (hStatus, _) <- getJSON mgr port "/health" []
  hStatus @?= 200
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text
    signupBody = object ["email" .= email, "password" .= password, "displayName" .= ("Ada Lovelace" :: Text)]
    loginBody = object ["email" .= email, "password" .= password]

-- HTTP helpers (parseRequest does not throw on non-2xx, so 401/404 come back as responses).

postJSON :: Manager -> Int -> String -> Value -> IO (Int, Maybe Value)
postJSON mgr port path body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = [("Content-Type", "application/json")],
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | POST with no body, only headers (used for the authenticated logout). Returns status.
postNoBody :: Manager -> Int -> String -> [Header] -> IO Int
postNoBody mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "POST", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp))

getJSON :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
getJSON mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

bearer :: Text -> [Header]
bearer tok = [("Authorization", "Bearer " <> Text.encodeUtf8 tok)]

-- A scalar count(*) query run directly against the pool, for DB-state assertions.
scalarInt :: Pool -> Text -> IO Int
scalarInt pool sql = do
  res <- Pool.use pool (Session.statement () stmt)
  either (assertFailure . ("scalar query failed: " <>) . show) pure res
  where
    stmt :: Statement () Int
    stmt = preparable sql E.noParams (D.singleRow (fromIntegral64 <$> D.column (D.nonNullable D.int8)))
    fromIntegral64 :: Int64 -> Int
    fromIntegral64 = fromIntegral

-- JSON navigation helpers.

must :: String -> Maybe a -> IO a
must label = maybe (assertFailure ("missing: " <> label)) pure

field :: Text -> Value -> Maybe Value
field k (Object o) = KM.lookup (K.fromText k) o
field _ _ = Nothing

dig :: [Text] -> Value -> Maybe Value
dig ks v0 = foldl (\mv k -> mv >>= field k) (Just v0) ks

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing

jwksHasKid :: Value -> Bool
jwksHasKid v = case dig ["keys"] v of
  Just (Array xs) -> case toList xs of
    (k0 : _) -> isJust (field "kid" k0)
    [] -> False
  _ -> False

hasKeyDeep :: Text -> Value -> Bool
hasKeyDeep k = go
  where
    go (Object o) = any (\(kk, vv) -> K.toText kk == k || go vv) (KM.toList o)
    go (Array xs) = any go (toList xs)
    go _ = False
