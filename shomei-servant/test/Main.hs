{-# LANGUAGE TypeApplications #-}

-- | End-to-end HTTP test for @shomei-servant@.
--
-- Boots the 'ShomeiAPI' server in-process on an ephemeral port with a /hybrid/
-- interpreter stack — EP-2's in-memory stores together with EP-4's real @jose@ ES256
-- signer and verifier — so signing and verification are genuinely exercised (not
-- stubbed). Then drives @http-client@ requests and asserts the behaviors from the
-- plan's Purpose: signup, login, me (+ 401 on missing/garbage token), refresh
-- rotation, the public JWKS document, and the @RequireRole "admin"@ guard (403/200).
module Main (main) where

import Crypto.JOSE.JWK (JWK, JWKSet)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Effectful (Eff, runEff)
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
    responseHeaders,
    responseStatus,
  )
import Network.HTTP.Types (Header, statusCode)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Application, Request)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant
  ( Context (EmptyContext, (:.)),
    ErrorFormatters,
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
import Shomei.Config (ImpersonationConfig (..), NotifierConfig (..), ServiceAccountConfig (..), ServiceAccountId (..), ServiceTokenConfig (..), ShomeiConfig (..), TokenTransport (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Role (..), Scope (..))
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.LoginAttempt (AccountKey (..))
import Shomei.Domain.LoginId (mkLoginId)
import Shomei.Domain.Notification (Notification (..))
import Shomei.Domain.OneTimeToken (OneTimeToken (..))
import Shomei.Domain.Passkey (PublicKeyBytes (..), UserHandle (..), WebAuthnCredentialId (..))
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Session (Session (..), SessionStatus (SessionRevoked))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.InMemory
  ( World (..),
    emptyWorld,
    runAuthEventPublisher,
    runAuthEventReader,
    runAuthUnitOfWork,
    runClock,
    runCredentialStore,
    runLoginAttemptStore,
    runNotifier,
    runClaimsEnricherNull,
    runPasskeyStore,
    runPasswordBreachCheckerFake,
    runPasswordHasher,
    runPasswordResetTokenStore,
    runPendingCeremonyStore,
    runInMemory,
    runRefreshTokenStore,
    runSessionStore,
    runSigningKeyStore,
    runTokenGen,
    runRoleStore,
    runUserStore,
    runVerificationTokenStore,
    runWebAuthnCeremonyFake,
  )
import Shomei.Id (UserId, genSessionId, genUserId, parseId)
import Shomei.Jwt.Jwks (KeySet (..), jwksDocument, keySetPublicJwks)
import Shomei.Jwt.Key (generateSigningKey)
import Shomei.Jwt.Sign (runTokenSignerJwt, signAccessToken)
import Shomei.Jwt.Verify (runTokenVerifierJwt, verifyToken)
import Shomei.Prelude ((&), (.~), (^.))
import Shomei.Servant.API (ShomeiRoutes)
import Shomei.Servant.Auth (AuthUser, authHandler, cookiePolicyFromConfig)
import Shomei.Servant.Authz (RequireRole, RequireScope)
import Shomei.Servant.DTO (UserResponse)
import Shomei.Servant.Error (shomeiErrorFormatters)
import Shomei.Servant.Handlers (shomeiRoutes)
import Shomei.Servant.Middleware (problemMiddleware)
import Shomei.Servant.Seam (AppEffects, Env (..))
import Shomei.Workflow qualified as Wf
import Shomei.Workflow.Roles (grantRoleTo, revokeRoleFrom)
import Shomei.Workflow.ServiceToken (sha256Hex)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

serviceAccount :: ServiceAccountId
serviceAccount = ServiceAccountId "connector:rei"

serviceLoginId :: Text
serviceLoginId = "connector-rei"

serviceSecret :: Text
serviceSecret = "test-secret"

servicePassword :: Text
servicePassword = "correct horse battery staple"

ingestScope :: Scope
ingestScope = Scope "kawa:ingest"

-- | The test API: the whole served Shōmei tree ('ShomeiRoutes', so application routes answer
-- under @\/v1@ exactly as they do in production) plus two host routes protected /only/ by the
-- 'RequireRole' and 'RequireScope' combinators. Their handlers contain no authorization code
-- at all, so the 401/403/200 assertions below prove the route type alone enforces — which is
-- the entire point of the combinators having 'HasServer' instances.
--
-- The two host routes are deliberately unversioned: they belong to the embedding application,
-- not to Shōmei, and a host is free to shape its own paths.
--
-- The combinators sit where 'Authenticated' used to: they run the same auth handler themselves
-- and pass the resulting 'AuthUser' through to the handler.
type TestAPI =
  NamedRoutes ShomeiRoutes
    :<|> RequireRole "admin" :> "admin" :> "users" :> Get '[JSON] [UserResponse]
    :<|> RequireScope "kawa:ingest" :> "ingest" :> Get '[JSON] [UserResponse]

testServer :: Env -> Server TestAPI
testServer env = shomeiRoutes env :<|> adminUsersH :<|> ingestH
  where
    adminUsersH :: AuthUser -> Handler [UserResponse]
    adminUsersH _user = pure []
    ingestH :: AuthUser -> Handler [UserResponse]
    ingestH _user = pure []

-- | The test app wraps the Servant application in 'problemMiddleware', exactly as
-- 'Shomei.Server.Boot.application' does, so the 405 assertions exercise the real stack.
app :: Env -> Application
app env = problemMiddleware (serveWithContext (Proxy @TestAPI) ctx (testServer env))
  where
    ctx :: Context '[AuthHandler Request AuthUser, ErrorFormatters]
    ctx =
      authHandler (cookiePolicyFromConfig env.config) env.verifier
        :. shomeiErrorFormatters
        :. EmptyContext

-- | The hybrid runner: in-memory stores + real @jose@ signer/verifier, in the same
-- effect order as EP-2's @runInMemory@ (so 'AppEffects' lines up).
runHybrid :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> Eff AppEffects a -> IO a
runHybrid ref jwk jwkset cfg =
  runEff
    . runTokenGen ref
    . runClock ref
    . runSigningKeyStore ref
    . runAuthEventReader ref
    . runAuthEventPublisher ref
    . runTokenVerifierJwt jwkset cfg
    . runTokenSignerJwt jwk cfg
    . runPasswordHasher ref
    . runPasswordBreachCheckerFake ref
    . runWebAuthnCeremonyFake ref
    . runClaimsEnricherNull
    . runNotifier ref
    . runPendingCeremonyStore ref
    . runPasskeyStore ref
    . runLoginAttemptStore ref
    . runPasswordResetTokenStore ref
    . runVerificationTokenStore ref
    . runAuthUnitOfWork ref
    . runRefreshTokenStore ref
    . runSessionStore ref
    . runCredentialStore ref
    . runRoleStore ref
    . runUserStore ref

-- | Grant the @admin@ role to a user through the real audited workflow, straight against the
-- in-memory world the server is running on. The next token minted for that user (by login or
-- refresh) will carry the role.
grantAdminTo :: IORef World -> Text -> IO ()
grantAdminTo ref userIdText = do
  uid <- parseUserId userIdText
  outcome <- runInMemory ref (grantRoleTo Nothing uid (Role "admin"))
  case outcome of
    Right True -> pure ()
    Right False -> assertFailure "expected the admin grant to be new"
    Left e -> assertFailure ("granting admin failed: " <> show e)

-- | The inverse. The next token minted for the user carries no @admin@ role.
revokeAdminFrom :: IORef World -> Text -> IO ()
revokeAdminFrom ref userIdText = do
  uid <- parseUserId userIdText
  outcome <- runInMemory ref (revokeRoleFrom Nothing uid (Role "admin"))
  case outcome of
    Right True -> pure ()
    Right False -> assertFailure "expected an admin grant to revoke"
    Left e -> assertFailure ("revoking admin failed: " <> show e)

parseUserId :: Text -> IO UserId
parseUserId t =
  either (\e -> assertFailure ("bad user id " <> show t <> ": " <> show e)) pure (parseId t)

-- | Mint an access token carrying the @admin@ role by signing claims directly with the in-test
-- key. Kept alongside the real grant path in (g): it isolates the combinator's claim check from
-- the store, so a failure in one does not mask a failure in the other.
mkAdminToken :: JWK -> ShomeiConfig -> IO Text
mkAdminToken jwk cfg = do
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
            roles = Set.fromList [Role "admin"],
            actor = Nothing,
            extraClaims = mempty
          }
  r <- signAccessToken jwk claims
  case r of
    Right (AccessToken tok) -> pure tok
    Left e -> assertFailure ("admin token signing failed: " <> show e)

-- | Mint a fresh access token carrying the impersonation scope (the workflows issue no
-- scopes, so a token holding @impersonate:user@ must be signed directly). Issued at the
-- world clock @t0@, so the freshness check passes against the in-memory 'Clock'.
mkImpersonatorToken :: JWK -> ShomeiConfig -> UTCTime -> IO Text
mkImpersonatorToken jwk cfg t = do
  uid <- genUserId
  sid <- genSessionId
  let claims =
        AuthClaims
          { subject = uid,
            sessionId = sid,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = t,
            expiresAt = addUTCTime 900 t,
            scopes = Set.fromList [cfg.impersonationConfig.impersonateScope],
            roles = Set.empty,
            actor = Nothing,
            extraClaims = mempty
          }
  r <- signAccessToken jwk claims
  case r of
    Right (AccessToken tok) -> pure tok
    Left e -> assertFailure ("impersonator token signing failed: " <> show e)

main :: IO ()
main = do
  jwk <- generateSigningKey
  let cfg = defaultShomeiConfig (Issuer "https://shomei.test") (Audience "shomei-clients")
      jwkset = keySetPublicJwks (KeySet jwk [])
  t0 <- getCurrentTime
  ref <- newIORef (emptyWorld t0)
  -- Build an 'Env' over a FRESH in-memory World. Each test case that mutates state must use
  -- its own env: tasty runs cases in parallel, so sharing one World IORef races.
  let mkEnvWith cfg' r =
        Env
          { runPorts = runHybrid r jwk jwkset cfg',
            config = cfg',
            verifier = verifyToken jwkset cfg',
            jwksJson = pure (fromMaybe (Object KM.empty) (decode (jwksDocument [jwk]))),
            accountKeyOf = AccountKey
          }
      mkEnv = mkEnvWith cfg
      freshEnv = mkEnv <$> newIORef (emptyWorld t0)
      -- 'emailVerificationRequired' on, over its own World. The World ref comes back too, so
      -- the scenario can read the verification token the notifier captured.
      freshGatedEnv = do
        r <- newIORef (emptyWorld t0)
        pure (r, mkEnvWith gatedCfg r)
      gatedCfg = cfg {notifierConfig = cfg.notifierConfig {emailVerificationRequired = True}}
      -- One env per transport, each over its own World (tasty runs cases in parallel).
      cookieCfg = cfg {tokenTransport = HttpOnlyCookie}
      bothCfg = cfg {tokenTransport = BearerAndCookie}
      freshCookieEnv = mkEnvWith cookieCfg <$> newIORef (emptyWorld t0)
      freshBothEnv = mkEnvWith bothCfg <$> newIORef (emptyWorld t0)
      freshServiceEnv = do
        r <- newIORef (emptyWorld t0)
        serviceUser <- seedServiceUser r jwk jwkset cfg
        let serviceCfg =
              cfg
                & #serviceTokenConfig
                .~ ServiceTokenConfig
                  { enabled = True,
                    ttl = 300,
                    accounts =
                      [ ServiceAccountConfig
                          { accountId = serviceAccount,
                            userId = serviceUser ^. #userId,
                            secretHash = sha256Hex serviceSecret,
                            allowedScopes = Set.singleton ingestScope
                          }
                      ]
                  }
        pure (mkEnvWith serviceCfg r)
      env = mkEnv ref
  adminToken <- mkAdminToken jwk cfg
  impToken <- mkImpersonatorToken jwk cfg t0
  defaultMain (tests ref env freshEnv freshGatedEnv freshCookieEnv freshBothEnv freshServiceEnv adminToken impToken)

seedServiceUser :: IORef World -> JWK -> JWKSet -> ShomeiConfig -> IO User
seedServiceUser ref jwk jwkset cfg = do
  loginId <- either (assertFailure . ("bad service login id: " <>) . show) pure (mkLoginId serviceLoginId)
  email <- either (assertFailure . ("bad service email: " <>) . show) pure (mkEmail "connector-rei@example.com")
  result <-
    runHybrid
      ref
      jwk
      jwkset
      cfg
      ( Wf.signup
          cfg
          SignupCommand
            { loginId,
              email = Just email,
              password = PlainPassword servicePassword,
              displayName = Just "Connector Rei"
            }
      )
  case result of
    Right (user, _) -> pure user
    Left err -> assertFailure ("service user signup failed: " <> show err)

-- | Every failure, from every layer, is an RFC 7807 problem document.
--
-- Each assertion names the layer it exercises, because they fail for different reasons: the
-- auth handler and the authz combinator throw before any handler runs; @resolvePrincipal@
-- throws inside one; Servant's @ErrorFormatters@ handle its own request parsers; and the bare
-- 405 a method mismatch raises sits below every Servant hook, converted by 'problemMiddleware'.
scenarioProblemEnvelope :: Int -> IO ()
scenarioProblemEnvelope port = do
  mgr <- newManager defaultManagerSettings

  -- (1) The auth handler: no credential at all. The commonest failure in any deployment.
  r1 <- getRaw mgr port "/v1/auth/me" []
  assertProblem "missing token" 401 "missing_token" r1
  headerValue "WWW-Authenticate" (headersOf r1) @?= Just "Bearer"

  -- (2) The auth handler: a credential that fails verification. Deliberately indistinguishable
  --     from an expired one -- the code is the same.
  r2 <- getRaw mgr port "/v1/auth/me" (bearer "garbage.token.value")
  assertProblem "invalid token" 401 "token_invalid" r2
  headerValue "WWW-Authenticate" (headersOf r2) @?= Just "Bearer"

  -- (3) The authorization combinator: authenticated, but lacking the role. 403, and no
  --     WWW-Authenticate -- the credential itself was fine.
  let signupBody' =
        object
          [ "email" .= ("envelope@example.com" :: Text),
            "password" .= ("correct horse battery staple" :: Text),
            "displayName" .= ("Envelope" :: Text)
          ]
  (_, sBody) <- postJSON mgr port "/v1/auth/signup" signupBody'
  sresp <- must "signup body" sBody
  access <- must "signup accessToken" (dig ["token", "accessToken"] sresp >>= asText)
  r3 <- getRaw mgr port "/admin/users" (bearer access)
  assertProblem "missing role" 403 "missing_role" r3
  headerValue "WWW-Authenticate" (headersOf r3) @?= Nothing

  -- (4) A handler's own rejection, with the specific reason carried in `detail`.
  r4 <- postRaw' mgr port "/v1/auth/login" [] (object ["password" .= ("x" :: Text)])
  assertProblem "handler bad request" 400 "bad_request" r4
  (bodyOf r4 >>= dig ["detail"] >>= asText) @?= Just "loginId or email required"

  -- (5) Servant's own body parser, via ErrorFormatters. The parse message rides in `detail`.
  r5 <- postRawBytes mgr port "/v1/auth/signup" "{"
  assertProblem "body parse error" 400 "body_parse_error" r5
  assertBool "body_parse_error carries a detail" (isJust (bodyOf r5 >>= dig ["detail"]))

  -- (6) Servant's not-found formatter.
  r6 <- getRaw mgr port "/no/such/route" []
  assertProblem "unknown route" 404 "not_found" r6

  -- (7) The method check -- below every Servant hook, rewritten by problemMiddleware.
  r7 <- getRaw mgr port "/v1/auth/login" []
  assertProblem "method not allowed" 405 "method_not_allowed" r7

-- | The versioning boundary: every application route answers only under @\/v1@, and the
-- protocol/infrastructure endpoints answer only at the root. Both halves are asserted, because
-- a record that accidentally nested the probes under @\/v1@ would still pass the first half.
--
-- The old unprefixed paths are gone outright — no redirect, no 410 — so an unmigrated client
-- gets a 404 problem document naming nothing it can act on but the CHANGELOG. That is the
-- declared cost of the pre-1.0 breaking window.
scenarioVersionBoundary :: Int -> IO ()
scenarioVersionBoundary port = do
  mgr <- newManager defaultManagerSettings

  -- The old paths are 404 -- and a 404 that is itself a problem document.
  old <- postRaw' mgr port "/auth/login" [] (object ["loginId" .= ("someone" :: Text)])
  assertProblem "old login path" 404 "not_found" old
  oldMe <- getRaw mgr port "/auth/me" []
  assertProblem "old me path" 404 "not_found" oldMe

  -- ...and the versioned one routes: no token, so the auth handler answers 401, which is proof
  -- the request reached the route rather than falling off the end of the tree.
  newMe <- getRaw mgr port "/v1/auth/me" []
  assertProblem "versioned me path routes" 401 "missing_token" newMe

  -- Probes and JWKS stay at the root.
  (healthStatus, _) <- getJSON mgr port "/health" []
  healthStatus @?= 200
  (jwksStatus, jwksHdrs, _) <- getRaw mgr port "/.well-known/jwks.json" []
  jwksStatus @?= 200
  headerValue "Cache-Control" jwksHdrs @?= Just "public, max-age=300"

  -- ...and nothing bleeds into /v1: the version prefix covers the application record only.
  v1Health <- getRaw mgr port "/v1/health" []
  assertProblem "no /v1/health" 404 "not_found" v1Health
  v1Jwks <- getRaw mgr port "/v1/.well-known/jwks.json" []
  assertProblem "no /v1/.well-known/jwks.json" 404 "not_found" v1Jwks

type RawResponse = (Int, [Header], Maybe Value)

headersOf :: RawResponse -> [Header]
headersOf (_, h, _) = h

bodyOf :: RawResponse -> Maybe Value
bodyOf (_, _, b) = b

-- | Assert the response is a problem document: the right status, @application/problem+json@, and
-- a body whose @code@ matches, whose @status@ member mirrors the HTTP status, and which carries
-- @type@ and @title@.
assertProblem :: String -> Int -> Text -> RawResponse -> IO ()
assertProblem what expectedStatus expectedCode (status, hdrs, body) = do
  status @?= expectedStatus
  headerValue "Content-Type" hdrs @?= Just "application/problem+json"
  doc <- must (what <> ": body") body
  (dig ["code"] doc >>= asText) @?= Just expectedCode
  (dig ["type"] doc >>= asText) @?= Just "about:blank"
  assertBool (what <> ": has a title") (isJust (dig ["title"] doc))
  case dig ["status"] doc of
    Just (Number n) -> (round n :: Int) @?= expectedStatus
    _ -> assertFailure (what <> ": problem document has no numeric status")

headerValue :: Text -> [Header] -> Maybe Text
headerValue name hdrs =
  listToMaybe [Text.decodeUtf8 v | (n, v) <- hdrs, n == CI.mk (Text.encodeUtf8 name)]

-- | GET, exposing status, headers, and the decoded body.
getRaw :: Manager -> Int -> String -> [Header] -> IO RawResponse
getRaw mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | POST a JSON value, exposing status, headers, and the decoded body.
postRaw' :: Manager -> Int -> String -> [Header] -> Value -> IO RawResponse
postRaw' mgr port path hdrs body = postRaw mgr port path hdrs body

-- | POST an arbitrary (here: malformed) body, to exercise Servant's body parser.
postRawBytes :: Manager -> Int -> String -> LBS.ByteString -> IO RawResponse
postRawBytes mgr port path raw = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = [("Content-Type", "application/json")],
            requestBody = RequestBodyLBS raw
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

tests :: IORef World -> Env -> IO Env -> IO (IORef World, Env) -> IO Env -> IO Env -> IO Env -> Text -> Text -> TestTree
tests ref env freshEnv freshGatedEnv freshCookieEnv freshBothEnv freshServiceEnv adminToken impToken =
  testGroup
    "HTTP end-to-end (in-memory interpreters + in-test ES256 key)"
    [ testCase "problem+json envelope from every layer (auth handler, authz, handler, servant formatters, method check)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioProblemEnvelope,
      testCase "the /v1 boundary: application routes are versioned, probes and JWKS are not" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioVersionBoundary,
      testCase "signup → verify/reset → login → me(±token) → refresh → jwks → RequireRole → passkey CRUD → MFA step-up → passwordless → impersonation" $
        testWithApplication (pure (app env)) (scenario ref adminToken impToken),
      testCase "signup/login by loginId with no email (email == null)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioNoEmail,
      testCase "email-only signup defaults loginId to the email (backward compat)" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioEmailDefaultsLoginId,
      testCase "service token with allowed scope passes RequireScope while normal login token fails" $ do
        e <- freshServiceEnv
        testWithApplication (pure (app e)) scenarioServiceToken,
      testCase "emailVerificationRequired blocks login with 403 until the email is verified" $ do
        (r, e) <- freshGatedEnv
        testWithApplication (pure (app e)) (scenarioEmailVerificationRequired r),
      testCase "cookie transport: sets HttpOnly cookies, omits body tokens, authenticates, clears on logout" $ do
        e <- freshCookieEnv
        testWithApplication (pure (app e)) scenarioCookieTransport,
      testCase "cookie transport: CSRF gate on mutating requests (Origin / Referer / none / foreign)" $ do
        e <- freshCookieEnv
        testWithApplication (pure (app e)) scenarioCsrfMatrix,
      testCase "cookie transport: refresh reads the shomei_refresh cookie, rotates, and is CSRF-gated" $ do
        e <- freshCookieEnv
        testWithApplication (pure (app e)) scenarioCookieRefresh,
      testCase "bearer transport: no Set-Cookie, body tokens present, a cookie is not a credential" $ do
        e <- freshEnv
        testWithApplication (pure (app e)) scenarioBearerRejectsCookies,
      testCase "both transport: cookies set AND body tokens present" $ do
        e <- freshBothEnv
        testWithApplication (pure (app e)) scenarioBothTransport
    ]

-- | SH-25 M4 acceptance: an HTTP caller can sign up with ONLY a @loginId@ (no email). The
-- returned user has that login id and a @null@ email, and the same identifier logs in.
scenarioNoEmail :: Int -> IO ()
scenarioNoEmail port = do
  mgr <- newManager defaultManagerSettings
  let pw = "correct horse battery staple" :: Text
      signupB = object ["loginId" .= ("agent-x" :: Text), "password" .= pw, "displayName" .= ("" :: Text)]
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupB
  sStatus @?= 200
  sresp <- must "signup body" sBody
  (dig ["user", "loginId"] sresp >>= asText) @?= Just "agent-x"
  dig ["user", "email"] sresp @?= Just Null
  (lStatus, lBody) <- postJSON mgr port "/v1/auth/login" (object ["loginId" .= ("agent-x" :: Text), "password" .= pw])
  lStatus @?= 200
  lresp <- must "login body" lBody
  assertBool "login by identifier yields a token" (isJust (dig ["token", "accessToken"] lresp >>= asText))

-- | SH-25 M4 backward compatibility: an email-only signup (no @loginId@) yields a user whose
-- @loginId@ equals the email text.
scenarioEmailDefaultsLoginId :: Int -> IO ()
scenarioEmailDefaultsLoginId port = do
  mgr <- newManager defaultManagerSettings
  let em = "grace@example.com" :: Text
      pw = "correct horse battery staple" :: Text
      signupB = object ["email" .= em, "password" .= pw, "displayName" .= ("" :: Text)]
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupB
  sStatus @?= 200
  sresp <- must "signup body" sBody
  (dig ["user", "loginId"] sresp >>= asText) @?= Just em
  (dig ["user", "email"] sresp >>= asText) @?= Just em

-- | With @emailVerificationRequired@ on, signup still hands out its initial pair (changing
-- that would break the response shape), but the first re-login and the first refresh are
-- refused with @403 email_not_verified@ — a distinct code, because the password was correct.
-- Confirming the emailed token unblocks both.
scenarioEmailVerificationRequired :: IORef World -> Int -> IO ()
scenarioEmailVerificationRequired ref port = do
  mgr <- newManager defaultManagerSettings
  let em = "unverified@example.com" :: Text
      pw = "correct horse battery staple" :: Text
      loginBody = object ["loginId" .= em, "password" .= pw]
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" (object ["email" .= em, "password" .= pw, "displayName" .= ("" :: Text)])
  sStatus @?= 200
  sresp <- must "signup body" sBody
  refreshTok <- must "signup refreshToken" (dig ["token", "refreshToken"] sresp >>= asText)

  -- Unverified: a correct password is refused, and so is a silent renewal.
  (blockedLogin, blockedBody) <- postJSON mgr port "/v1/auth/login" loginBody
  blockedLogin @?= 403
  bresp <- must "blocked login body" blockedBody
  (dig ["code"] bresp >>= asText) @?= Just "email_not_verified"
  (blockedRefresh, _) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= refreshTok])
  blockedRefresh @?= 403

  -- Verify the email, and both work again.
  (reqStatus, _) <- postJSON mgr port "/v1/auth/verify-email/request" (object ["email" .= em])
  reqStatus @?= 202
  token <- latestVerificationToken ref
  (confirmStatus, _) <- postJSON mgr port "/v1/auth/verify-email/confirm" (object ["token" .= token])
  confirmStatus @?= 202
  (okLogin, okBody) <- postJSON mgr port "/v1/auth/login" loginBody
  okLogin @?= 200
  okResp <- must "login body" okBody
  assertBool "verified login yields a token" (isJust (dig ["token", "accessToken"] okResp >>= asText))

-- Cookie transport -----------------------------------------------------------

cookieEmail :: Text
cookieEmail = "cookie@example.com"

cookiePassword :: Text
cookiePassword = "correct horse battery staple"

cookieSignupBody :: Value
cookieSignupBody = object ["email" .= cookieEmail, "password" .= cookiePassword, "displayName" .= ("C" :: Text)]

-- | The origin the default 'CookieConfig' allows.
allowedOrigin :: Header
allowedOrigin = ("Origin", "http://localhost:8080")

foreignOrigin :: Header
foreignOrigin = ("Origin", "https://evil.example.com")

-- | Sign up in cookie mode and return the two cookie values.
cookieSignup :: Manager -> Int -> IO (Text, Text, Maybe Value)
cookieSignup mgr port = do
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 200
  let cookies = setCookies hdrs
  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" cookies)
  refr <- must "shomei_refresh cookie" (cookieValueOf "shomei_refresh" cookies)
  pure (sess, refr, body)

sessionCookieHeader :: Text -> Header
sessionCookieHeader v = ("Cookie", Text.encodeUtf8 ("shomei_session=" <> v))

refreshCookieHeader :: Text -> Header
refreshCookieHeader v = ("Cookie", Text.encodeUtf8 ("shomei_refresh=" <> v))

-- | Cookie mode: the attributes browsers rely on, the token-free body, cookie authentication,
-- and logout clearing.
scenarioCookieTransport :: Int -> IO ()
scenarioCookieTransport port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 200
  let cookies = setCookies hdrs
  length cookies @?= 2

  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" cookies)
  sessionAttrs <- must "shomei_session attributes" (listToMaybe (filter (T.isPrefixOf "shomei_session=") cookies))
  refreshAttrs <- must "shomei_refresh attributes" (listToMaybe (filter (T.isPrefixOf "shomei_refresh=") cookies))

  -- HttpOnly is what puts the token out of an XSS payload's reach.
  assertBool ("session HttpOnly: " <> T.unpack sessionAttrs) ("HttpOnly" `T.isInfixOf` sessionAttrs)
  assertBool "session Secure" ("Secure" `T.isInfixOf` sessionAttrs)
  assertBool "session SameSite=Lax" ("SameSite=Lax" `T.isInfixOf` sessionAttrs)
  assertBool "session Path=/" ("Path=/;" `T.isInfixOf` sessionAttrs)
  assertBool "session Max-Age=900" ("Max-Age=900" `T.isInfixOf` sessionAttrs)
  -- The long-lived credential is presented to exactly one endpoint.
  assertBool ("refresh Path: " <> T.unpack refreshAttrs) ("Path=/v1/auth/refresh" `T.isInfixOf` refreshAttrs)
  assertBool "refresh HttpOnly" ("HttpOnly" `T.isInfixOf` refreshAttrs)
  assertBool "refresh Max-Age=2592000" ("Max-Age=2592000" `T.isInfixOf` refreshAttrs)

  -- The body carries no token values at all — not nulls, not empty strings.
  resp <- must "signup body" body
  assertBool "no accessToken key" (isNothing (dig ["token", "accessToken"] resp))
  assertBool "no refreshToken key" (isNothing (dig ["token", "refreshToken"] resp))
  assertBool "expiresIn present" (isJust (dig ["token", "expiresIn"] resp))

  -- A GET authenticated only by the cookie works, and needs no Origin (safe method).
  (meStatus, _) <- getJSON mgr port "/v1/auth/me" [sessionCookieHeader sess]
  meStatus @?= 200

  -- Logout clears both cookies: same names, empty values, Max-Age=0.
  (outStatus, outHdrs, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess, allowedOrigin] Null
  outStatus @?= 204
  let cleared = setCookies outHdrs
  length cleared @?= 2
  assertBool ("session cleared: " <> show cleared) (any (\c -> "shomei_session=;" `T.isPrefixOf` c && "Max-Age=0" `T.isInfixOf` c) cleared)
  assertBool ("refresh cleared: " <> show cleared) (any (\c -> "shomei_refresh=;" `T.isPrefixOf` c && "Max-Age=0" `T.isInfixOf` c) cleared)

-- | The CSRF matrix on a cookie-authenticated mutating route.
scenarioCsrfMatrix :: Int -> IO ()
scenarioCsrfMatrix port = do
  mgr <- newManager defaultManagerSettings
  (sess, _, _) <- cookieSignup mgr port

  -- No Origin, no Referer: fail closed. This is the attack shape.
  (noneStatus, _, noneBody) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess] Null
  noneStatus @?= 403
  nb <- must "csrf body" noneBody
  (dig ["code"] nb >>= asText) @?= Just "csrf_rejected"

  -- A foreign origin: refused.
  (evilStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess, foreignOrigin] Null
  evilStatus @?= 403

  -- Referer fallback, for agents that omit Origin.
  (refStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess, ("Referer", "http://localhost:8080/app/settings")] Null
  refStatus @?= 204

  -- A Referer that merely *starts with* an allowed origin must not pass.
  (sess2, _, _) <- cookieSignupAs mgr port "csrf2@example.com"
  (badRefStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess2, ("Referer", "http://localhost:8080.evil.com/x")] Null
  badRefStatus @?= 403

  -- An allow-listed Origin: accepted.
  (okStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [sessionCookieHeader sess2, allowedOrigin] Null
  okStatus @?= 204

  -- A bearer credential is never CSRF-gated, even from a foreign origin: a page cannot set
  -- the Authorization header, and gating it would break every non-browser client.
  (sess3, _, _) <- cookieSignupAs mgr port "csrf3@example.com"
  (bearerStatus, _, _) <- postRaw mgr port "/v1/auth/logout" [("Authorization", Text.encodeUtf8 ("Bearer " <> sess3)), foreignOrigin] Null
  bearerStatus @?= 204

-- | Sign up a distinct account in cookie mode.
cookieSignupAs :: Manager -> Int -> Text -> IO (Text, Text, Maybe Value)
cookieSignupAs mgr port email = do
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] (object ["email" .= email, "password" .= cookiePassword, "displayName" .= ("C" :: Text)])
  status @?= 200
  let cookies = setCookies hdrs
  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" cookies)
  refr <- must "shomei_refresh cookie" (cookieValueOf "shomei_refresh" cookies)
  pure (sess, refr, body)

-- | Refresh from the cookie: rotates, re-sets cookies, and is CSRF-gated like any mutation.
scenarioCookieRefresh :: Int -> IO ()
scenarioCookieRefresh port = do
  mgr <- newManager defaultManagerSettings
  (_, refr, _) <- cookieSignup mgr port

  -- Without an Origin the cookie-borne refresh token is refused.
  (noOrigin, _, _) <- postRaw mgr port "/v1/auth/refresh" [refreshCookieHeader refr] (object [])
  noOrigin @?= 403

  -- With an allow-listed Origin it rotates and hands back fresh cookies.
  (okStatus, okHdrs, okBody) <- postRaw mgr port "/v1/auth/refresh" [refreshCookieHeader refr, allowedOrigin] (object [])
  okStatus @?= 200
  let cookies = setCookies okHdrs
  newRefresh <- must "rotated shomei_refresh" (cookieValueOf "shomei_refresh" cookies)
  assertBool "the refresh token rotated" (newRefresh /= refr)
  resp <- must "refresh body" okBody
  assertBool "cookie mode omits body tokens on refresh" (isNothing (dig ["accessToken"] resp))

  -- Presenting the old token again is reuse: rotation already consumed it.
  (reuseStatus, _, _) <- postRaw mgr port "/v1/auth/refresh" [refreshCookieHeader refr, allowedOrigin] (object [])
  assertBool ("old refresh token must be rejected, got " <> show reuseStatus) (reuseStatus >= 400)

-- | Bearer mode: no cookies emitted, body tokens present, and — the review's finding — a
-- cookie is not accepted as a credential.
scenarioBearerRejectsCookies :: Int -> IO ()
scenarioBearerRejectsCookies port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 200
  setCookies hdrs @?= []
  resp <- must "signup body" body
  access <- must "accessToken" (dig ["token", "accessToken"] resp >>= asText)
  assertBool "refreshToken present" (isJust (dig ["token", "refreshToken"] resp))

  -- The bearer token authenticates.
  (bearerStatus, _) <- getJSON mgr port "/v1/auth/me" [("Authorization", Text.encodeUtf8 ("Bearer " <> access))]
  bearerStatus @?= 200

  -- The very same token presented as a shomei_session cookie does not. Before this plan the
  -- cookie fallback was unconditional and this returned 200.
  (cookieStatus, _) <- getJSON mgr port "/v1/auth/me" [sessionCookieHeader access]
  cookieStatus @?= 401

-- | Both: cookies AND body tokens, for clients migrating between transports.
scenarioBothTransport :: Int -> IO ()
scenarioBothTransport port = do
  mgr <- newManager defaultManagerSettings
  (status, hdrs, body) <- postRaw mgr port "/v1/auth/signup" [] cookieSignupBody
  status @?= 200
  length (setCookies hdrs) @?= 2
  resp <- must "signup body" body
  assertBool "accessToken present in both mode" (isJust (dig ["token", "accessToken"] resp))
  assertBool "refreshToken present in both mode" (isJust (dig ["token", "refreshToken"] resp))
  sess <- must "shomei_session cookie" (cookieValueOf "shomei_session" (setCookies hdrs))
  (meStatus, _) <- getJSON mgr port "/v1/auth/me" [sessionCookieHeader sess]
  meStatus @?= 200

scenarioServiceToken :: Int -> IO ()
scenarioServiceToken port = do
  mgr <- newManager defaultManagerSettings
  let body =
        object
          [ "accountId" .= serviceAccountText,
            "secret" .= serviceSecret,
            "scopes" .= [scopeText ingestScope],
            "actorId" .= Null
          ]
  (status, responseBody) <- postJSON mgr port "/v1/auth/service-token" body
  status @?= 200
  response <- must "service-token body" responseBody
  access <- must "service-token accessToken" (dig ["accessToken"] response >>= asText)
  assertBool "service-token response has no refreshToken" (isNothing (dig ["refreshToken"] response))
  (ingestStatus, _) <- getJSON mgr port "/ingest" (bearer access)
  ingestStatus @?= 200

  (deniedStatus, _) <-
    postJSON
      mgr
      port
      "/v1/auth/service-token"
      ( object
          [ "accountId" .= serviceAccountText,
            "secret" .= serviceSecret,
            "scopes" .= ["channel:egress" :: Text],
            "actorId" .= Null
          ]
      )
  deniedStatus @?= 403

  (loginStatus, loginBody) <-
    postJSON
      mgr
      port
      "/v1/auth/login"
      (object ["loginId" .= serviceLoginId, "password" .= servicePassword])
  loginStatus @?= 200
  loginResp <- must "service login body" loginBody
  normalAccess <- must "service login accessToken" (dig ["token", "accessToken"] loginResp >>= asText)
  (normalIngestStatus, _) <- getJSON mgr port "/ingest" (bearer normalAccess)
  normalIngestStatus @?= 403
  where
    serviceAccountText =
      case serviceAccount of
        ServiceAccountId t -> t
    scopeText =
      \case
        Scope t -> t

scenario :: IORef World -> Text -> Text -> Int -> IO ()
scenario ref adminToken impToken port = do
  mgr <- newManager defaultManagerSettings

  -- (a) signup
  (sStatus, sBody) <- postJSON mgr port "/v1/auth/signup" signupBody
  sStatus @?= 200
  sresp <- must "signup body" sBody
  (dig ["user", "email"] sresp >>= asText) @?= Just email
  (dig ["user", "status"] sresp >>= asText) @?= Just "active"
  adaUserId <- must "signup userId" (dig ["user", "userId"] sresp >>= asText)
  assertBool "signup access token present" (isJust (dig ["token", "accessToken"] sresp >>= asText))
  assertBool "signup refresh token present" (isJust (dig ["token", "refreshToken"] sresp >>= asText))

  -- (a2) verify email via notifier-captured token
  (verifyReqStatus, _) <- postJSON mgr port "/v1/auth/verify-email/request" (object ["email" .= email])
  verifyReqStatus @?= 202
  emailVerificationToken <- latestVerificationToken ref
  (verifyConfirmStatus, _) <- postJSON mgr port "/v1/auth/verify-email/confirm" (object ["token" .= emailVerificationToken])
  verifyConfirmStatus @?= 202

  -- (b) login
  (lStatus, lBody) <- postJSON mgr port "/v1/auth/login" loginBody
  lStatus @?= 200
  lresp <- must "login body" lBody
  access <- must "login accessToken" (dig ["token", "accessToken"] lresp >>= asText)
  refreshTok <- must "login refreshToken" (dig ["token", "refreshToken"] lresp >>= asText)

  -- (c) me with Bearer
  (meStatus, meBody) <- getJSON mgr port "/v1/auth/me" (bearer access)
  meStatus @?= 200
  meresp <- must "me body" meBody
  (dig ["email"] meresp >>= asText) @?= Just email

  -- (d) me without and with garbage token
  (noTokStatus, _) <- getJSON mgr port "/v1/auth/me" []
  noTokStatus @?= 401
  (garbageStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer "garbage.token.value")
  garbageStatus @?= 401

  -- (e) refresh rotates the token
  (rStatus, rBody) <- postJSON mgr port "/v1/auth/refresh" (object ["refreshToken" .= refreshTok])
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

  -- (g) The RequireRole combinator enforces, with no handler guard behind it.
  --
  --     No token → 401 (the combinator authenticates before it authorizes); a token whose
  --     principal lacks the role → 403; a token minted AFTER a real grant → 200.
  (noTokenAdminStatus, _) <- getJSON mgr port "/admin/users" []
  noTokenAdminStatus @?= 401
  (garbageAdminStatus, _) <- getJSON mgr port "/admin/users" (bearer "garbage.token.value")
  garbageAdminStatus @?= 401
  (forbiddenStatus, _) <- getJSON mgr port "/admin/users" (bearer access)
  forbiddenStatus @?= 403

  -- A hand-signed token carrying the role passes: the combinator reads the claim.
  (adminStatus, _) <- getJSON mgr port "/admin/users" (bearer adminToken)
  adminStatus @?= 200

  -- ...and so does one minted by the real path: grant the role to the logged-in user through
  -- the audited workflow, log in again, and the fresh token opens the same door. This is the
  -- whole loop the plan exists to close — before EP-1, no production flow could mint this token.
  grantAdminTo ref adaUserId
  (grantedLoginStatus, grantedLoginBody) <- postJSON mgr port "/v1/auth/login" loginBody
  grantedLoginStatus @?= 200
  grantedResp <- must "post-grant login body" grantedLoginBody
  grantedAccess <- must "post-grant accessToken" (dig ["token", "accessToken"] grantedResp >>= asText)
  (grantedStatus, _) <- getJSON mgr port "/admin/users" (bearer grantedAccess)
  grantedStatus @?= 200

  -- The pre-grant token is unchanged: a JWT is self-contained, so the role appears only on
  -- tokens minted after the grant (the staleness contract in docs/user/security.md).
  (staleStatus, _) <- getJSON mgr port "/admin/users" (bearer access)
  staleStatus @?= 403

  -- Revoke it again, and the next mint has no role — the other half of the same contract.
  -- (This also restores the pre-grant state for the rest of the scenario, whose later logins
  -- mint fresh tokens for this very user and expect them to be non-admin.)
  revokeAdminFrom ref adaUserId
  (revokedLoginStatus, revokedLoginBody) <- postJSON mgr port "/v1/auth/login" loginBody
  revokedLoginStatus @?= 200
  revokedResp <- must "post-revoke login body" revokedLoginBody
  revokedAccess <- must "post-revoke accessToken" (dig ["token", "accessToken"] revokedResp >>= asText)
  (revokedStatus, _) <- getJSON mgr port "/admin/users" (bearer revokedAccess)
  revokedStatus @?= 403

  -- (g2) The RequireScope combinator enforces the same way. An ordinary login token carries no
  --      scopes; only a service token holds 'kawa:ingest' (exercised in the service-token suite).
  (noTokenIngestStatus, _) <- getJSON mgr port "/ingest" []
  noTokenIngestStatus @?= 401
  (ingestForbiddenStatus, _) <- getJSON mgr port "/ingest" (bearer revokedAccess)
  ingestForbiddenStatus @?= 403

  -- (h) password-reset request/confirm allows login with the new password.
  (resetReqStatus, _) <- postJSON mgr port "/v1/auth/password-reset/request" (object ["email" .= email])
  resetReqStatus @?= 202
  resetToken <- latestResetToken ref
  let changedPassword = "correct horse battery staple two" :: Text
  (resetConfirmStatus, _) <-
    postJSON
      mgr
      port
      "/v1/auth/password-reset/confirm"
      (object ["token" .= resetToken, "newPassword" .= changedPassword])
  resetConfirmStatus @?= 202
  (newLoginStatus, newLoginBody) <- postJSON mgr port "/v1/auth/login" (object ["email" .= email, "password" .= changedPassword])
  newLoginStatus @?= 200
  newLoginResp <- must "new login body" newLoginBody
  access2 <- must "new login accessToken" (dig ["token", "accessToken"] newLoginResp >>= asText)

  -- (i) passkey: begin → complete → list → delete (authenticated with the fresh token)
  (beginStatus, beginBody) <- postJSONAuth mgr port "/v1/auth/passkeys/register/begin" (bearer access2) (object [])
  beginStatus @?= 200
  bresp <- must "begin body" beginBody
  cid <- must "ceremonyId" (dig ["ceremonyId"] bresp >>= asText)
  chal <- must "challenge" (dig ["options", "challenge"] bresp >>= asText)
  let cred =
        object
          [ "challenge" .= chal,
            "credentialId" .= WebAuthnCredentialId "passkey-cred-1",
            "userHandle" .= UserHandle "passkey-uh-1",
            "publicKey" .= PublicKeyBytes "passkey-pk-1"
          ]
      completeBody = object ["ceremonyId" .= cid, "credential" .= cred, "label" .= ("YubiKey" :: Text)]
  (compStatus, compBody) <- postJSONAuth mgr port "/v1/auth/passkeys/register/complete" (bearer access2) completeBody
  compStatus @?= 200
  cresp <- must "complete body" compBody
  pkId <- must "passkeyId" (dig ["passkeyId"] cresp >>= asText)
  (dig ["label"] cresp >>= asText) @?= Just "YubiKey"

  (listStatus, listBody) <- getJSON mgr port "/v1/auth/passkeys" (bearer access2)
  listStatus @?= 200
  listResp <- must "list body" listBody
  case listResp of
    Array xs -> assertBool "one passkey listed" (length xs == 1)
    _ -> assertFailure "expected a JSON array of passkeys"

  (delStatus, _) <- deleteAuth mgr port ("/v1/auth/passkeys/" <> T.unpack pkId) (bearer access2)
  delStatus @?= 204

  (list2Status, list2Body) <- getJSON mgr port "/v1/auth/passkeys" (bearer access2)
  list2Status @?= 200
  list2Resp <- must "list2 body" list2Body
  case list2Resp of
    Array xs -> assertBool "no passkeys after delete" (null xs)
    _ -> assertFailure "expected a JSON array after delete"

  -- (j) re-completing the now-consumed ceremony is a 404
  (badStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/passkeys/register/complete"
      (bearer access2)
      (object ["ceremonyId" .= cid, "credential" .= cred])
  badStatus @?= 404

  -- (k) a passkey route without a bearer token is a 401
  (unauthStatus, _) <- getJSON mgr port "/v1/auth/passkeys" []
  unauthStatus @?= 401

  -- (l) re-enroll a passkey so the account now requires MFA at the next password login.
  (rbStatus, rbBody) <- postJSONAuth mgr port "/v1/auth/passkeys/register/begin" (bearer access2) (object [])
  rbStatus @?= 200
  rbresp <- must "mfa enroll begin body" rbBody
  rbCid <- must "mfa enroll ceremonyId" (dig ["ceremonyId"] rbresp >>= asText)
  rbChal <- must "mfa enroll challenge" (dig ["options", "challenge"] rbresp >>= asText)
  let credAssertion challengeText =
        object
          [ "challenge" .= challengeText,
            "credentialId" .= WebAuthnCredentialId "passkey-cred-2",
            "userHandle" .= UserHandle "passkey-uh-2",
            "publicKey" .= PublicKeyBytes "passkey-pk-2"
          ]
  (rcStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/passkeys/register/complete"
      (bearer access2)
      (object ["ceremonyId" .= rbCid, "credential" .= credAssertion rbChal, "label" .= ("MFA Key" :: Text)])
  rcStatus @?= 200

  -- (m) the password login now returns an MFA challenge and NO token.
  (mfaLoginStatus, mfaLoginBody) <- postJSON mgr port "/v1/auth/login" (object ["email" .= email, "password" .= changedPassword])
  mfaLoginStatus @?= 200
  mfaLoginResp <- must "mfa login body" mfaLoginBody
  (dig ["status"] mfaLoginResp >>= asText) @?= Just "mfa_required"
  assertBool "no access token in the mfa_required body" (isNothing (dig ["token"] mfaLoginResp))
  mfaCeremonyId <- must "mfa login ceremonyId" (dig ["ceremonyId"] mfaLoginResp >>= asText)
  mfaChallenge <- must "mfa login challenge" (dig ["options", "challenge"] mfaLoginResp >>= asText)

  -- (n) completing MFA with a valid assertion yields a token pair.
  (mfaCompleteStatus, mfaCompleteBody) <-
    postJSON mgr port "/v1/auth/mfa/complete" (object ["ceremonyId" .= mfaCeremonyId, "assertion" .= credAssertion mfaChallenge])
  mfaCompleteStatus @?= 200
  mfaCompleteResp <- must "mfa complete body" mfaCompleteBody
  mfaAccess <- must "mfa complete accessToken" (dig ["accessToken"] mfaCompleteResp >>= asText)

  -- (o) the MFA-issued access token authenticates /auth/me.
  (meMfaStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer mfaAccess)
  meMfaStatus @?= 200

  -- (p) re-submitting the now-consumed ceremony is a 404.
  (mfaStaleStatus, _) <-
    postJSON mgr port "/v1/auth/mfa/complete" (object ["ceremonyId" .= mfaCeremonyId, "assertion" .= credAssertion mfaChallenge])
  mfaStaleStatus @?= 404

  -- (q) passwordless login: begin → complete → me, no password.
  (plBeginStatus, plBeginBody) <- postJSON mgr port "/v1/auth/login/passkey/begin" (object [])
  plBeginStatus @?= 200
  plBeginResp <- must "passwordless begin body" plBeginBody
  plCid <- must "passwordless ceremonyId" (dig ["ceremonyId"] plBeginResp >>= asText)
  plChal <- must "passwordless challenge" (dig ["options", "challenge"] plBeginResp >>= asText)
  (plCompleteStatus, plCompleteBody) <-
    postJSON mgr port "/v1/auth/login/passkey/complete" (object ["ceremonyId" .= plCid, "assertion" .= credAssertion plChal])
  plCompleteStatus @?= 200
  plResp <- must "passwordless complete body" plCompleteBody
  plAccess <- must "passwordless accessToken" (dig ["accessToken"] plResp >>= asText)
  (mePlStatus, _) <- getJSON mgr port "/v1/auth/me" (bearer plAccess)
  mePlStatus @?= 200

  -- (r) impersonation: an operator holding the impersonate scope exchanges for a
  -- delegated token, sees the customer via /auth/me, is refused a credential change,
  -- and can stop.
  let impBody = object ["userId" .= adaUserId, "reason" .= ("Debugging support issue" :: Text), "ticketId" .= ("SUP-1234" :: Text)]
  (impStatus, impRespBody) <- postJSONAuth mgr port "/v1/auth/impersonate" (bearer impToken) impBody
  impStatus @?= 200
  impResp <- must "impersonate body" impRespBody
  (dig ["subjectUserId"] impResp >>= asText) @?= Just adaUserId
  assertBool "actorUserId present" (isJust (dig ["actorUserId"] impResp >>= asText))
  impAccess <- must "delegated accessToken" (dig ["accessToken"] impResp >>= asText)

  -- the delegated token resolves the *customer's* identity on /auth/me
  (meImpStatus, meImpBody) <- getJSON mgr port "/v1/auth/me" (bearer impAccess)
  meImpStatus @?= 200
  meImpResp <- must "me (delegated) body" meImpBody
  (dig ["email"] meImpResp >>= asText) @?= Just email

  -- a credential change under the delegated token is refused with 403
  (impPwStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/password/change"
      (bearer impAccess)
      (object ["currentPassword" .= ("x" :: Text), "newPassword" .= ("y" :: Text)])
  impPwStatus @?= 403

  -- the operator's OWN token is not impersonation-blocked: it reaches the normal
  -- credential path (and fails there as invalid credentials, NOT 403).
  (opPwStatus, _) <-
    postJSONAuth
      mgr
      port
      "/v1/auth/password/change"
      (bearer impToken)
      (object ["currentPassword" .= ("x" :: Text), "newPassword" .= ("y" :: Text)])
  assertBool "operator's own token is not impersonation-blocked" (opPwStatus /= 403)

  -- stop impersonating revokes the delegated session
  (stopStatus, _) <- deleteAuth mgr port "/v1/auth/impersonate" (bearer impAccess)
  stopStatus @?= 204
  world <- readIORef ref
  let delegated = filter (\s -> isJust s.actor) (Map.elems world.sessions)
  case delegated of
    [s] -> s.status @?= SessionRevoked
    _ -> assertFailure ("expected exactly one delegated session, got " <> show (length delegated))

  -- (s) EP-7 audit retrieval: admin reads the trail; non-admin/no-token are refused;
  -- filters and keyset pagination behave.
  (auditNoTokStatus, _) <- getJSON mgr port "/v1/admin/audit/events" []
  auditNoTokStatus @?= 401
  (auditForbiddenStatus, _) <- getJSON mgr port "/v1/admin/audit/events" (bearer plAccess)
  auditForbiddenStatus @?= 403
  (auditStatus, auditBody) <- getJSON mgr port "/v1/admin/audit/events" (bearer adminToken)
  auditStatus @?= 200
  auditResp <- must "audit body" auditBody
  case dig ["events"] auditResp of
    Just (Array xs) -> assertBool "audit trail is non-empty" (not (null xs))
    _ -> assertFailure "expected an events array"

  -- type filter: every returned row is a login_succeeded (and there is at least one)
  (auditTypeStatus, auditTypeBody) <- getJSON mgr port "/v1/admin/audit/events?type=login_succeeded" (bearer adminToken)
  auditTypeStatus @?= 200
  auditTypeResp <- must "audit type body" auditTypeBody
  case dig ["events"] auditTypeResp of
    Just (Array xs) -> do
      assertBool "at least one login_succeeded event" (not (null xs))
      assertBool
        "every returned event is login_succeeded"
        (all (\e -> (field "eventType" e >>= asText) == Just "login_succeeded") (toList xs))
    _ -> assertFailure "expected an events array"

  -- a malformed UUID filter is a 400
  (auditBadStatus, _) <- getJSON mgr port "/v1/admin/audit/events?user=not-a-uuid" (bearer adminToken)
  auditBadStatus @?= 400

  -- keyset pagination: limit=1, then follow nextCursor; the two pages are disjoint.
  (p1Status, p1Body) <- getJSON mgr port "/v1/admin/audit/events?limit=1" (bearer adminToken)
  p1Status @?= 200
  p1Resp <- must "audit page1 body" p1Body
  p1Events <- case dig ["events"] p1Resp of
    Just (Array xs) -> pure (toList xs)
    _ -> assertFailure "expected events array (page1)"
  assertBool "page1 has exactly one event" (length p1Events == 1)
  cursor <- must "page1 nextCursor" (dig ["nextCursor"] p1Resp >>= asText)
  let p1Id = listToMaybe p1Events >>= field "eventId" >>= asText
  (p2Status, p2Body) <-
    getJSON mgr port ("/v1/admin/audit/events?limit=1&before=" <> urlEncodeText cursor) (bearer adminToken)
  p2Status @?= 200
  p2Resp <- must "audit page2 body" p2Body
  p2Events <- case dig ["events"] p2Resp of
    Just (Array xs) -> pure (toList xs)
    _ -> assertFailure "expected events array (page2)"
  assertBool "page2 has exactly one event" (length p2Events == 1)
  let p2Id = listToMaybe p2Events >>= field "eventId" >>= asText
  assertBool "the two pages are disjoint" (p1Id /= p2Id)
  where
    email = "ada@example.com" :: Text
    password = "correct horse battery staple" :: Text
    signupBody = object ["email" .= email, "password" .= password, "displayName" .= ("Ada Lovelace" :: Text)]
    loginBody = object ["email" .= email, "password" .= password]

latestVerificationToken :: IORef World -> IO Text
latestVerificationToken ref = do
  w <- readIORef ref
  case w.sentNotifications of
    EmailVerificationRequested {token = OneTimeToken t} : _ -> pure t
    _ -> assertFailure "expected email-verification notification"

latestResetToken :: IORef World -> IO Text
latestResetToken ref = do
  w <- readIORef ref
  case w.sentNotifications of
    PasswordResetRequested {token = OneTimeToken t} : _ -> pure t
    _ -> assertFailure "expected password-reset notification"

-- Request helpers (parseRequest does not throw on non-2xx, so 401/403/404 come back
-- as ordinary responses).

postJSON :: Manager -> Int -> String -> Value -> IO (Int, Maybe Value)
postJSON mgr port path body = do
  (status, _, b) <- postRaw mgr port path [] body
  pure (status, b)

-- | POST with arbitrary headers, exposing the response's headers too — the cookie tests
-- assert on @Set-Cookie@.
postRaw :: Manager -> Int -> String -> [Header] -> Value -> IO (Int, [Header], Maybe Value)
postRaw mgr port path hdrs body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = ("Content-Type", "application/json") : hdrs,
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), responseHeaders resp, decode (responseBody resp))

-- | The @Set-Cookie@ values of a response, in order.
setCookies :: [Header] -> [Text]
setCookies hdrs = [Text.decodeUtf8 v | (n, v) <- hdrs, n == "Set-Cookie"]

-- | The value of the named cookie from a @Set-Cookie@ list (the bit before the first @;@).
cookieValueOf :: Text -> [Text] -> Maybe Text
cookieValueOf name =
  listToMaybe . mapMaybe (T.stripPrefix (name <> "=") . T.takeWhile (/= ';'))

getJSON :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
getJSON mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "GET", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | POST a JSON body with extra headers (e.g. a Bearer token).
postJSONAuth :: Manager -> Int -> String -> [Header] -> Value -> IO (Int, Maybe Value)
postJSONAuth mgr port path hdrs body = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req =
        req0
          { method = "POST",
            requestHeaders = ("Content-Type", "application/json") : hdrs,
            requestBody = RequestBodyLBS (encode body)
          }
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

-- | DELETE with extra headers (e.g. a Bearer token).
deleteAuth :: Manager -> Int -> String -> [Header] -> IO (Int, Maybe Value)
deleteAuth mgr port path hdrs = do
  req0 <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  let req = req0 {method = "DELETE", requestHeaders = hdrs}
  resp <- httpLbs req mgr
  pure (statusCode (responseStatus resp), decode (responseBody resp))

bearer :: Text -> [Header]
bearer tok = [("Authorization", "Bearer " <> Text.encodeUtf8 tok)]

-- | Percent-encode a query-string value (the audit cursor carries @:@, @.@, @;@).
urlEncodeText :: Text -> String
urlEncodeText = T.unpack . Text.decodeUtf8 . urlEncode True . Text.encodeUtf8

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
