{-# LANGUAGE DataKinds #-}

-- | Pure tests for the in-memory 'Shomei.Effect.OAuthCodeStore' interpreter and for
-- 'Shomei.Workflow.OAuthAuthorize.authorize', the policy the authorize endpoint enforces.
--
-- The store's contract is consume-once: a code is redeemable exactly once, never after it
-- expires, and a replay is indistinguishable from an unknown code. Those three misses are what
-- the token endpoint answers @invalid_grant@ for, and getting any of them wrong turns a
-- single-use credential into a reusable one. The same behavior is re-proven against real
-- PostgreSQL — including under a genuine race — by @shomei-postgres@'s integration test.
--
-- The workflow's contract is the PKCE and scope policy: a public client cannot skip PKCE, only
-- S256 is accepted, and a client cannot be granted a scope it was never registered for.
module Shomei.OAuthCodeStoreSpec (tests) where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Data.UUID qualified as UUID
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Domain.AuthorizationCode (AuthorizationCode (..), NewAuthorizationCode (..))
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.OAuthClient (ClientType (..), NewOAuthClient (..), OAuthClient (..))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Effect.OAuthClientStore (createOAuthClient)
import Shomei.Effect.OAuthCodeStore
  ( consumeAuthorizationCode,
    deleteExpiredAuthorizationCodes,
    putAuthorizationCode,
  )
import Shomei.Id (SessionId, UserId, genOAuthClientId, genUserId, idText, sessionIdFromUUID)
import Shomei.Workflow.OAuthAuthorize
  ( AuthorizeError (..),
    AuthorizeParams (..),
    IssuedCode (..),
    authorize,
    isValidS256Challenge,
  )
import Shomei.Workflow.ServiceToken (sha256Hex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "OAuthCodeStore and the authorize workflow"
    [ testGroup
        "OAuthCodeStore (in-memory)"
        [ testCase "a stored code is consumable exactly once" consumeOnce,
          testCase "an expired code never consumes" expiredNeverConsumes,
          testCase "an unknown code hash consumes to Nothing" unknownConsumes,
          testCase "deleteExpired removes only what is past its expiry" deleteExpired
        ],
      testGroup
        "authorize (workflow policy)"
        [ testCase "a valid request mints a code, stores only its digest, and audits it" happyPath,
          testCase "a public client without a code_challenge is refused" publicClientNeedsPkce,
          testCase "a confidential client may omit PKCE" confidentialMayOmitPkce,
          testCase "code_challenge_method other than S256 is refused" onlyS256,
          testCase "a code_challenge present with no method is refused (no silent `plain`)" noImplicitPlain,
          testCase "a malformed code_challenge is refused at authorize" malformedChallenge,
          testCase "response_type other than code is unsupported_response_type" onlyCodeResponseType,
          testCase "an absent scope grants the client's whole allow-list" absentScopeGrantsAll,
          testCase "a scope outside the allow-list is invalid_scope" scopeOutsideAllowList,
          testCase "an empty scope parameter is invalid_scope, not a request for nothing" emptyScope,
          testCase "auth_time is the authorizing token's iat, not now" authTimeIsTokenIat,
          testCase "isValidS256Challenge accepts only 43 unpadded base64url chars" challengeShape
        ]
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 7 10) 0

-- | The stock config: 'authorize' reads only @oauthConfig.authorizationCodeTTL@ from it (60s by
-- default). @oidcEnabled@ gates the /route/, not the workflow.
cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "https://shomei.test") (Audience "shomei-clients")

-- | 'authorize' never reads the session id, but 'AuthClaims' is strict, so it must be a real one.
someSessionId :: SessionId
someSessionId = sessionIdFromUUID (UUID.fromWords 0 0 0 3)

newWorld :: IO (IORef World)
newWorld = newIORef (emptyWorld t0)

callbackUri :: Text
callbackUri = "https://app.example.com/callback"

-- | A well-formed S256 challenge: 43 unpadded base64url characters.
challenge :: Text
challenge = Text.replicate 43 "a"

openidScope, profileScope :: Scope
openidScope = Scope "openid"
profileScope = Scope "profile"

allowed :: Set Scope
allowed = Set.fromList [openidScope, profileScope]

baseParams :: AuthorizeParams
baseParams =
  AuthorizeParams
    { responseType = Just "code",
      redirectUri = callbackUri,
      scope = Nothing,
      state = Nothing,
      nonce = Nothing,
      codeChallenge = Just challenge,
      codeChallengeMethod = Just "S256"
    }

-- | Claims for a user who authenticated an hour before the request reached authorize, so a test
-- can tell @auth_time@ (the token's @iat@) from "now".
claimsFor :: UserId -> AuthClaims
claimsFor uid =
  AuthClaims
    { subject = uid,
      sessionId = someSessionId,
      issuer = Issuer "https://shomei.test",
      audience = Audience "shomei-clients",
      issuedAt = addUTCTime (-3600) t0,
      expiresAt = addUTCTime 900 t0,
      scopes = Set.empty,
      roles = Set.empty,
      actor = Nothing,
      extraClaims = mempty
    }

newCode :: UserId -> UTCTime -> Text -> NewAuthorizationCode
newCode uid expiresAt codeHash =
  NewAuthorizationCode
    { codeHash,
      clientId = "oauthclient_x",
      redirectUri = callbackUri,
      userId = uid,
      scopes = Set.singleton openidScope,
      nonce = Nothing,
      codeChallenge = Just challenge,
      authTime = t0,
      createdAt = t0,
      expiresAt
    }

-- Store ----------------------------------------------------------------------

-- | The single most important property in this plan: a code is a one-shot credential.
consumeOnce :: IO ()
consumeOnce = do
  ref <- newWorld
  (first', second') <- runInMemory ref do
    uid <- genUserId
    putAuthorizationCode (newCode uid (addUTCTime 60 t0) "hash-1")
    a <- consumeAuthorizationCode "hash-1" t0
    b <- consumeAuthorizationCode "hash-1" t0
    pure (a, b)
  assertBool "the first consume returns the code" (isJust first')
  fmap (.consumedAt) first' @?= Just (Just t0)
  assertBool "the second consume returns nothing" (isNothing second')

expiredNeverConsumes :: IO ()
expiredNeverConsumes = do
  ref <- newWorld
  result <- runInMemory ref do
    uid <- genUserId
    putAuthorizationCode (newCode uid (addUTCTime 60 t0) "hash-1")
    -- One second past the expiry.
    consumeAuthorizationCode "hash-1" (addUTCTime 61 t0)
  assertBool "an expired code must not consume" (isNothing result)

unknownConsumes :: IO ()
unknownConsumes = do
  ref <- newWorld
  result <- runInMemory ref (consumeAuthorizationCode "no-such-hash" t0)
  assertBool "an unknown code hash consumes to Nothing" (isNothing result)

deleteExpired :: IO ()
deleteExpired = do
  ref <- newWorld
  remaining <- runInMemory ref do
    uid <- genUserId
    putAuthorizationCode (newCode uid (addUTCTime 10 t0) "expired")
    putAuthorizationCode (newCode uid (addUTCTime 600 t0) "live")
    deleteExpiredAuthorizationCodes (addUTCTime 60 t0)
    (,) <$> consumeAuthorizationCode "expired" (addUTCTime 60 t0) <*> consumeAuthorizationCode "live" (addUTCTime 60 t0)
  assertBool "the expired code is gone" (isNothing (fst remaining))
  assertBool "the live code survives" (isJust (snd remaining))

-- Workflow -------------------------------------------------------------------

-- | Run 'authorize' against a freshly registered client of the given type.
runAuthorize :: ClientType -> AuthorizeParams -> IO (Either AuthorizeError IssuedCode, World)
runAuthorize clientType params = do
  ref <- newWorld
  result <- runInMemory ref do
    uid <- genUserId
    ocid <- genOAuthClientId
    client <-
      createOAuthClient
        NewOAuthClient
          { oauthClientId = ocid,
            clientId = idText ocid,
            secretHash = case clientType of
              ConfidentialClient -> Just "hash"
              PublicClient -> Nothing,
            clientType,
            displayName = "test",
            redirectUris = [callbackUri],
            allowedScopes = allowed,
            createdAt = t0
          }
    authorize cfg client (claimsFor uid) params
  world <- readIORef ref
  pure (result, world)

expectLeft :: Either AuthorizeError IssuedCode -> IO AuthorizeError
expectLeft = either pure (const (assertFailure "expected the authorize request to be refused"))

expectRight :: Either AuthorizeError IssuedCode -> IO IssuedCode
expectRight = either (\e -> assertFailure ("expected success, got " <> show e)) pure

happyPath :: IO ()
happyPath = do
  (result, world) <- runAuthorize ConfidentialClient baseParams {state = Just "xyz", nonce = Just "n-0S6"}
  issued <- expectRight result
  issued.state @?= Just "xyz"
  issued.grantedScopes @?= allowed
  -- Only the digest is stored: the code itself lives in the redirect URL and nowhere else.
  case Map.elems (oauthCodes world) of
    [stored] -> do
      stored.codeHash @?= sha256Hex issued.code
      assertBool "the plaintext code is never a key" (Map.notMember issued.code (oauthCodes world))
      stored.nonce @?= Just "n-0S6"
      stored.consumedAt @?= Nothing
      stored.expiresAt @?= addUTCTime 60 t0
    other -> assertFailure ("expected exactly one stored code, got " <> show (length other))
  -- The audit trail records the authorization without naming the code.
  assertBool
    "an oauth_code_issued event is published"
    (any isCodeIssued (publishedEvents world))
  where
    isCodeIssued = \case
      Event.OAuthCodeIssued _ -> True
      _ -> False

publicClientNeedsPkce :: IO ()
publicClientNeedsPkce = do
  (result, _) <- runAuthorize PublicClient baseParams {codeChallenge = Nothing, codeChallengeMethod = Nothing}
  e <- expectLeft result
  case e of
    AuthorizeInvalidRequest _ -> pure ()
    other -> assertFailure ("expected invalid_request, got " <> show other)

confidentialMayOmitPkce :: IO ()
confidentialMayOmitPkce = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {codeChallenge = Nothing, codeChallengeMethod = Nothing}
  _ <- expectRight result
  pure ()

onlyS256 :: IO ()
onlyS256 = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {codeChallengeMethod = Just "plain"}
  e <- expectLeft result
  case e of
    AuthorizeInvalidRequest _ -> pure ()
    other -> assertFailure ("expected invalid_request, got " <> show other)

-- | RFC 7636 defaults an absent method to @plain@. Accepting that default would silently downgrade
-- a client that meant S256, so the method must be spelled out.
noImplicitPlain :: IO ()
noImplicitPlain = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {codeChallengeMethod = Nothing}
  e <- expectLeft result
  case e of
    AuthorizeInvalidRequest _ -> pure ()
    other -> assertFailure ("expected invalid_request, got " <> show other)

malformedChallenge :: IO ()
malformedChallenge = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {codeChallenge = Just "too-short"}
  e <- expectLeft result
  case e of
    AuthorizeInvalidRequest _ -> pure ()
    other -> assertFailure ("expected invalid_request, got " <> show other)

onlyCodeResponseType :: IO ()
onlyCodeResponseType = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {responseType = Just "token"}
  e <- expectLeft result
  e @?= UnsupportedResponseType

absentScopeGrantsAll :: IO ()
absentScopeGrantsAll = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {scope = Nothing}
  issued <- expectRight result
  issued.grantedScopes @?= allowed

scopeOutsideAllowList :: IO ()
scopeOutsideAllowList = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {scope = Just "openid admin:everything"}
  e <- expectLeft result
  e @?= AuthorizeInvalidScope

emptyScope :: IO ()
emptyScope = do
  (result, _) <- runAuthorize ConfidentialClient baseParams {scope = Just "   "}
  e <- expectLeft result
  e @?= AuthorizeInvalidScope

-- | OIDC's @auth_time@ means "when the user authenticated", which is the authorizing access
-- token's @iat@ — an hour ago here — not the moment the browser reached authorize.
authTimeIsTokenIat :: IO ()
authTimeIsTokenIat = do
  (result, world) <- runAuthorize ConfidentialClient baseParams
  _ <- expectRight result
  case Map.elems (oauthCodes world) of
    [stored] -> stored.authTime @?= addUTCTime (-3600) t0
    _ -> assertFailure "expected exactly one stored code"

challengeShape :: IO ()
challengeShape = do
  assertBool "43 base64url chars is valid" (isValidS256Challenge challenge)
  assertBool "42 chars is not" (not (isValidS256Challenge (Text.replicate 42 "a")))
  assertBool "44 chars is not" (not (isValidS256Challenge (Text.replicate 44 "a")))
  -- Standard base64 (+ /) and padding are exactly what a client that forgot base64url emits.
  assertBool "'+' is not base64url" (not (isValidS256Challenge (Text.replicate 42 "a" <> "+")))
  assertBool "'/' is not base64url" (not (isValidS256Challenge (Text.replicate 42 "a" <> "/")))
  assertBool "'=' padding is not accepted" (not (isValidS256Challenge (Text.replicate 42 "a" <> "=")))
  assertBool "'-' and '_' are base64url" (isValidS256Challenge (Text.replicate 41 "a" <> "-_"))
