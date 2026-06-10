{-# LANGUAGE TypeApplications #-}

{- | End-to-end HTTP test for @shomei-servant@.

Boots the 'ShomeiAPI' server in-process on an ephemeral port with a /hybrid/
interpreter stack — EP-2's in-memory stores together with EP-4's real @jose@ ES256
signer and verifier — so signing and verification are genuinely exercised (not
stubbed). Then drives @http-client@ requests and asserts the behaviors from the
plan's Purpose: signup, login, me (+ 401 on missing/garbage token), refresh
rotation, the public JWKS document, and the @RequireRole "admin"@ guard (403/200).
-}
module Main (main) where

import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Text

import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM

import Data.Time (addUTCTime, getCurrentTime)

import Effectful (Eff, runEff)

import Network.HTTP.Client (
    Manager,
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
import Network.Wai (Application, Request)
import Network.Wai.Handler.Warp (testWithApplication)

import Servant (
    Context (EmptyContext, (:.)),
    Get,
    Handler,
    JSON,
    NamedRoutes,
    Proxy (Proxy),
    Server,
    serveWithContext,
    type (:<|>) ((:<|>)),
    type (:>),
 )
import Servant.Server.Experimental.Auth (AuthHandler)

import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Role (..))
import Shomei.Domain.Email (emailText)
import Shomei.Domain.LoginAttempt (AccountKey (..))
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Effect.InMemory (
    World (..),
    emptyWorld,
    runAuthEventPublisher,
    runClock,
    runCredentialStore,
    runLoginAttemptStore,
    runNotifier,
    runPasswordHasher,
    runPasswordResetTokenStore,
    runRefreshTokenStore,
    runSessionStore,
    runSigningKeyStore,
    runTokenGen,
    runUserStore,
    runVerificationTokenStore,
 )
import Shomei.Id (genSessionId, genUserId)

import Shomei.Jwt.Jwks (KeySet (..), jwksDocument, keySetPublicJwks)
import Shomei.Jwt.Key (generateSigningKey)
import Shomei.Jwt.Sign (runTokenSignerJwt, signAccessToken)
import Shomei.Jwt.Verify (runTokenVerifierJwt, verifyToken)
import "jose" Crypto.JOSE.JWK (JWK, JWKSet)

import Shomei.Servant.API (ShomeiAPI)
import Shomei.Servant.Auth (AuthUser, Authenticated, authHandler)
import Shomei.Servant.Authz (requireRole)
import Shomei.Servant.DTO (UserResponse)
import Shomei.Servant.Handlers (shomeiServer)
import Shomei.Servant.Seam (AppEffects, Env (..))

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

{- | The test API: the whole Shōmei API plus a host admin route guarded by the
'requireRole' function (proving embeddability + the @RequireRole@ behavior).
-}
type TestAPI =
    NamedRoutes ShomeiAPI
        :<|> "admin" :> "users" :> Authenticated :> Get '[JSON] [UserResponse]

testServer :: Env -> Server TestAPI
testServer env = shomeiServer env :<|> adminUsersH
  where
    adminUsersH :: AuthUser -> Handler [UserResponse]
    adminUsersH user = requireRole (Role "admin") user >> pure []

app :: Env -> Application
app env = serveWithContext (Proxy @TestAPI) ctx (testServer env)
  where
    ctx :: Context '[AuthHandler Request AuthUser]
    ctx = authHandler env.verifier :. EmptyContext

{- | The hybrid runner: in-memory stores + real @jose@ signer/verifier, in the same
effect order as EP-2's @runInMemory@ (so 'AppEffects' lines up).
-}
runHybrid :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> Eff AppEffects a -> IO a
runHybrid ref jwk jwkset cfg =
    runEff
        . runTokenGen ref
        . runClock ref
        . runSigningKeyStore ref
        . runAuthEventPublisher ref
        . runTokenVerifierJwt jwkset cfg
        . runTokenSignerJwt jwk cfg
        . runPasswordHasher ref
        . runNotifier ref
        . runLoginAttemptStore ref
        . runPasswordResetTokenStore ref
        . runVerificationTokenStore ref
        . runRefreshTokenStore ref
        . runSessionStore ref
        . runCredentialStore ref
        . runUserStore ref

{- | Mint an access token carrying the @admin@ role by signing claims directly with
the in-test key (the workflows issue no roles, so this is the only way to get one).
-}
mkAdminToken :: JWK -> ShomeiConfig -> IO Text
mkAdminToken jwk cfg = do
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
                , roles = Set.fromList [Role "admin"]
                }
    r <- signAccessToken jwk claims
    case r of
        Right (AccessToken tok) -> pure tok
        Left e -> assertFailure ("admin token signing failed: " <> show e)

main :: IO ()
main = do
    jwk <- generateSigningKey
    let cfg = defaultShomeiConfig (Issuer "https://shomei.test") (Audience "shomei-clients")
        jwkset = keySetPublicJwks (KeySet jwk [])
    t0 <- getCurrentTime
    ref <- newIORef (emptyWorld t0)
    let env =
            Env
                { runPorts = runHybrid ref jwk jwkset cfg
                , config = cfg
                , verifier = verifyToken jwkset cfg
                , jwksJson = fromMaybe (Object KM.empty) (decode (jwksDocument [jwk]))
                , accountKeyOf = AccountKey . emailText
                }
    adminToken <- mkAdminToken jwk cfg
    defaultMain (tests ref env adminToken)

tests :: IORef World -> Env -> Text -> TestTree
tests ref env adminToken =
    testGroup
        "HTTP end-to-end (in-memory interpreters + in-test ES256 key)"
        [ testCase "signup → verify/reset account → login → me(±token) → refresh → jwks → RequireRole(403,200)" $
            testWithApplication (pure (app env)) (scenario ref adminToken)
        ]

scenario :: IORef World -> Text -> Int -> IO ()
scenario ref adminToken port = do
    mgr <- newManager defaultManagerSettings

    -- (a) signup
    (sStatus, sBody) <- postJSON mgr port "/auth/signup" signupBody
    sStatus @?= 200
    sresp <- must "signup body" sBody
    (dig ["user", "email"] sresp >>= asText) @?= Just email
    (dig ["user", "status"] sresp >>= asText) @?= Just "active"
    assertBool "signup access token present" (isJust (dig ["token", "accessToken"] sresp >>= asText))
    assertBool "signup refresh token present" (isJust (dig ["token", "refreshToken"] sresp >>= asText))

    -- (a2) verify email via notifier-captured token
    (verifyReqStatus, _) <- postJSON mgr port "/auth/verify-email/request" (object ["email" .= email])
    verifyReqStatus @?= 202
    emailVerificationToken <- latestVerificationToken ref
    (verifyConfirmStatus, _) <- postJSON mgr port "/auth/verify-email/confirm" (object ["token" .= emailVerificationToken])
    verifyConfirmStatus @?= 202

    -- (b) login
    (lStatus, lBody) <- postJSON mgr port "/auth/login" loginBody
    lStatus @?= 200
    lresp <- must "login body" lBody
    access <- must "login accessToken" (dig ["token", "accessToken"] lresp >>= asText)
    refreshTok <- must "login refreshToken" (dig ["token", "refreshToken"] lresp >>= asText)

    -- (c) me with Bearer
    (meStatus, meBody) <- getJSON mgr port "/auth/me" (bearer access)
    meStatus @?= 200
    meresp <- must "me body" meBody
    (dig ["email"] meresp >>= asText) @?= Just email

    -- (d) me without and with garbage token
    (noTokStatus, _) <- getJSON mgr port "/auth/me" []
    noTokStatus @?= 401
    (garbageStatus, _) <- getJSON mgr port "/auth/me" (bearer "garbage.token.value")
    garbageStatus @?= 401

    -- (e) refresh rotates the token
    (rStatus, rBody) <- postJSON mgr port "/auth/refresh" (object ["refreshToken" .= refreshTok])
    rStatus @?= 200
    rresp <- must "refresh body" rBody
    newRefresh <- must "rotated refreshToken" (dig ["refreshToken"] rresp >>= asText)
    assertBool "rotated refresh token differs" (newRefresh /= refreshTok)

    -- (f) jwks document: public key with kid, no private "d"
    (jStatus, jBody) <- getJSON mgr port "/.well-known/jwks.json" []
    jStatus @?= 200
    jwks <- must "jwks body" jBody
    assertBool "jwks has keys[].kid" (jwksHasKid jwks)
    assertBool "jwks has no private 'd'" (not (hasKeyDeep "d" jwks))

    -- (g) RequireRole: non-admin → 403, admin → 200
    (forbiddenStatus, _) <- getJSON mgr port "/admin/users" (bearer access)
    forbiddenStatus @?= 403
    (adminStatus, _) <- getJSON mgr port "/admin/users" (bearer adminToken)
    adminStatus @?= 200

    -- (h) password-reset request/confirm allows login with the new password.
    (resetReqStatus, _) <- postJSON mgr port "/auth/password-reset/request" (object ["email" .= email])
    resetReqStatus @?= 202
    resetToken <- latestResetToken ref
    let changedPassword = "correct horse battery staple two" :: Text
    (resetConfirmStatus, _) <-
        postJSON
            mgr
            port
            "/auth/password-reset/confirm"
            (object ["token" .= resetToken, "newPassword" .= changedPassword])
    resetConfirmStatus @?= 202
    (newLoginStatus, _) <- postJSON mgr port "/auth/login" (object ["email" .= email, "password" .= changedPassword])
    newLoginStatus @?= 200
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text
    signupBody = object ["email" .= email, "password" .= password, "displayName" .= ("Ada Lovelace" :: Text)]
    loginBody = object ["email" .= email, "password" .= password]

latestVerificationToken :: IORef World -> IO Text
latestVerificationToken ref = do
    w <- readIORef ref
    case w.sentNotifications of
        EmailVerificationRequested{token = OneTimeToken t} : _ -> pure t
        _ -> assertFailure "expected email-verification notification"

latestResetToken :: IORef World -> IO Text
latestResetToken ref = do
    w <- readIORef ref
    case w.sentNotifications of
        PasswordResetRequested{token = OneTimeToken t} : _ -> pure t
        _ -> assertFailure "expected password-reset notification"

-- Request helpers (parseRequest does not throw on non-2xx, so 401/403/404 come back
-- as ordinary responses).

postJSON :: Manager -> Int -> String -> Value -> IO (Int, Maybe Value)
postJSON mgr port path body = do
    req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
    let req =
            req0
                { method = "POST"
                , requestHeaders = [("Content-Type", "application/json")]
                , requestBody = RequestBodyLBS (encode body)
                }
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), decode (responseBody resp))

getJSON :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
getJSON mgr port path hdrs = do
    req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
    let req = req0{method = "GET", requestHeaders = hdrs}
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), decode (responseBody resp))

bearer :: Text -> [Header]
bearer tok = [("Authorization", "Bearer " <> Text.encodeUtf8 tok)]

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

-- | Does the document have @keys@ as a non-empty array whose first element has a @kid@?
jwksHasKid :: Value -> Bool
jwksHasKid v = case dig ["keys"] v of
    Just (Array xs) -> case toList xs of
        (k0 : _) -> isJust (field "kid" k0)
        [] -> False
    _ -> False

-- | Recursively: does any object anywhere in the value carry a key named @k@?
hasKeyDeep :: Text -> Value -> Bool
hasKeyDeep k = go
  where
    go (Object o) = any (\(kk, vv) -> K.toText kk == k || go vv) (KM.toList o)
    go (Array xs) = any go (toList xs)
    go _ = False
