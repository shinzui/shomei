-- | Behavioral tests for the RFC 8693 token-exchange workflow
-- ('Shomei.OAuth.TokenExchange.Workflow'), run entirely through the in-memory interpreter
-- ('Shomei.Test.InMemory.runInMemory'). The in-memory 'Shomei.SigningKey.Signer' renders
-- 'AuthClaims' as JSON and the matching 'Shomei.SigningKey.Verifier' parses it back, so a
-- subject\/actor token is just a signed 'AuthClaims' and the minted token decodes for inspection.
module Shomei.OAuth.TokenExchange.WorkflowSpec (tests) where

import Data.Aeson (eitherDecode)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Shomei.Account.Email.Domain (Email, emailText, mkEmail)
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.User.Domain (User (..), UserStatus (UserActive, UserSuspended))
import Shomei.Account.User.Store (updateUserStatus)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Authorization.Claims.Domain (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Config (ImpersonationConfig (..), MachineTokenConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId, genServiceAccountDbId, genUserId, idText)
import Shomei.OAuth.TokenExchange.Workflow
  ( ExchangeRequest (..),
    ExchangedToken (..),
    accessTokenType,
    exchangeToken,
    tokenExchangeSubjectScope,
    userIdTokenType,
  )
import Shomei.ServiceAccount.Domain (ServiceAccount (..), ServiceAccountStatus (..))
import Shomei.Session.Authentication.Workflow (signup)
import Shomei.Session.Command (SignupCommand (..))
import Shomei.Session.RefreshToken.Domain (PersistedRefreshToken (..))
import Shomei.Session.Store (revokeSession)
import Shomei.Session.Token.Domain (AccessToken (..), TokenPair (..))
import Shomei.SigningKey.Signer (signAccessToken)
import Shomei.Test.InMemory (World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- Fixtures -------------------------------------------------------------------

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

impScope :: Scope
impScope = cfg.impersonationConfig.impersonateScope

ingestScope, readScope, adminScope :: Scope
ingestScope = Scope "kawa:ingest"
readScope = Scope "kawa:read"
adminScope = Scope "admin:everything"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' t = either (\e -> error ("bad test email: " <> show e)) id (mkEmail t)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

-- | Sign up a user with the given email and return their active user/session pair.
seedPrincipal :: IORef World -> Text -> IO (UserId, SessionId)
seedPrincipal ref email = do
  let e = mkEmail' email
  (user, pair) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand {loginId = either (error . show) id (mkLoginId (emailText e)), email = Just e, password = strongPw, displayName = Just "User"}))
  claims <- decodeAccess pair.accessToken
  pure (user.userId, claims.sessionId)

seedUser :: IORef World -> Text -> IO UserId
seedUser ref email = fst <$> seedPrincipal ref email

-- | Build claims for a principal. The in-memory verifier accepts them verbatim.
claimsFor :: UserId -> SessionId -> Set Scope -> Maybe UserId -> UTCTime -> AuthClaims
claimsFor uid sid scs act iat =
  AuthClaims
    { subject = uid,
      sessionId = sid,
      issuer = cfg.issuer,
      audience = cfg.audience,
      issuedAt = iat,
      expiresAt = addUTCTime 900 iat,
      authTime = iat,
      scopes = scs,
      roles = Set.empty,
      permissions = Set.empty,
      actor = act,
      extraClaims = mempty
    }

-- | Sign an access token for a principal (through the in-memory signer, so it round-trips).
signToken :: IORef World -> AuthClaims -> IO Text
signToken ref claims = do
  AccessToken t <- runInMemory ref (signAccessToken claims)
  pure t

-- | A fresh operator token holding the impersonation scope, issued now.
freshOperatorToken :: IORef World -> IO Text
freshOperatorToken ref = do
  (op, sid) <- seedPrincipal ref "operator@example.com"
  signToken ref (claimsFor op sid (Set.singleton impScope) Nothing fixedTime)

-- | A service account with the given allowed scopes, backed by 'svcUser'.
mkServiceAccount :: UserId -> Set Scope -> IO ServiceAccount
mkServiceAccount svcUser scopes = do
  dbid <- genServiceAccountDbId
  pure
    ServiceAccount
      { serviceAccountId = dbid,
        clientId = idText dbid,
        userId = svcUser,
        secretHash = "0000000000000000000000000000000000000000000000000000000000000000",
        displayName = "svc",
        allowedScopes = scopes,
        status = ServiceAccountActive,
        createdAt = fixedTime,
        rotatedAt = Nothing,
        revokedAt = Nothing
      }

-- | The base impersonation request: the target's id as the user-id subject, the operator token as
-- the actor. Extension parameters left at their defaults.
impersonationReq :: UserId -> Text -> ExchangeRequest
impersonationReq target operatorToken =
  ExchangeRequest
    { subjectToken = idText target,
      subjectTokenType = userIdTokenType,
      actorToken = Just operatorToken,
      actorTokenType = Just accessTokenType,
      requestedScopes = Nothing,
      requestedTokenType = Nothing,
      reason = Nothing,
      ticketId = Nothing,
      clientIp = Just "203.0.113.7",
      authenticatedService = Nothing
    }

-- | The base on-behalf-of request: a user's access token as the subject, presented by an
-- authenticated service account.
onBehalfReq :: Text -> ServiceAccount -> Maybe (Set Scope) -> ExchangeRequest
onBehalfReq subjectToken svc requested =
  ExchangeRequest
    { subjectToken = subjectToken,
      subjectTokenType = accessTokenType,
      actorToken = Nothing,
      actorTokenType = Nothing,
      requestedScopes = requested,
      requestedTokenType = Nothing,
      reason = Nothing,
      ticketId = Nothing,
      clientIp = Nothing,
      authenticatedService = Just svc
    }

decodeAccess :: AccessToken -> IO AuthClaims
decodeAccess (AccessToken t) =
  either
    (\e -> assertFailure ("could not decode access token: " <> e))
    pure
    (eitherDecode (TLE.encodeUtf8 (TL.fromStrict t)))

-- | Assert no refresh token was minted for the delegated session.
assertNoRefresh :: IORef World -> SessionId -> IO ()
assertNoRefresh ref sid = do
  world <- readIORef ref
  let refs = filter (\PersistedRefreshToken {sessionId = s} -> s == sid) (Map.elems world.refreshTokens)
  assertBool "delegated session has no refresh token" (null refs)

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Shomei.OAuth.TokenExchange.Workflow"
    [ testImpersonationHappyPath,
      testImpersonationDefaultReason,
      testImpersonationMissingScope,
      testImpersonationStaleActor,
      testImpersonationSelfTarget,
      testImpersonationDelegatedActorRefused,
      testImpersonationRevokedOperator,
      testImpersonationSuspendedOperator,
      testOnBehalfHappyPath,
      testOnBehalfDefaultScopes,
      testOnBehalfMissingGateScope,
      testOnBehalfScopeOutsideCeiling,
      testOnBehalfGateNeverGranted,
      testOnBehalfSubjectScopeBoundOk,
      testOnBehalfSubjectScopeBoundViolation,
      testOnBehalfChainRefused,
      testOnBehalfInactiveSubject,
      testOnBehalfRevokedSubject,
      testRefreshlessRequestedTypeRejected
    ]

testImpersonationHappyPath :: TestTree
testImpersonationHappyPath = testCase "impersonation: target sub + operator act, refresh-less, audited" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  opTok <- freshOperatorToken ref
  operatorClaims <- decodeAccess (AccessToken opTok)
  result <- expectRight =<< runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  claims <- decodeAccess result.accessToken
  claims.subject @?= target
  claims.actor @?= Just operatorClaims.subject
  result.grantedScopes @?= Set.empty
  result.expiresIn @?= cfg.impersonationConfig.impersonationSessionTTL
  assertNoRefresh ref result.sessionId
  world <- readIORef ref
  assertBool "ImpersonationStarted published" (any (startedFor operatorClaims.subject target) world.publishedEvents)
  where
    startedFor actorId subj = \case
      Event.ImpersonationStarted d -> d.actorUserId == actorId && d.subjectUserId == subj
      _ -> False

testImpersonationDefaultReason :: TestTree
testImpersonationDefaultReason = testCase "impersonation: absent reason defaults to token_exchange" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  opTok <- freshOperatorToken ref
  _ <- expectRight =<< runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  world <- readIORef ref
  assertBool "reason defaulted to token_exchange" (any defaulted world.publishedEvents)
  where
    defaulted = \case
      Event.ImpersonationStarted d -> d.reason == "token_exchange"
      _ -> False

testImpersonationMissingScope :: TestTree
testImpersonationMissingScope = testCase "impersonation: operator without impersonate:user is forbidden" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  (op, sid) <- seedPrincipal ref "operator@example.com"
  opTok <- signToken ref (claimsFor op sid Set.empty Nothing fixedTime)
  res <- runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  fmap (const ()) res @?= Left ImpersonationForbidden

testImpersonationStaleActor :: TestTree
testImpersonationStaleActor = testCase "impersonation: operator token past the freshness window is forbidden" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  (op, sid) <- seedPrincipal ref "operator@example.com"
  let stale = addUTCTime (negate (cfg.impersonationConfig.actorFreshnessWindow + 1)) fixedTime
  opTok <- signToken ref (claimsFor op sid (Set.singleton impScope) Nothing stale)
  res <- runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  fmap (const ()) res @?= Left ImpersonationForbidden

testImpersonationSelfTarget :: TestTree
testImpersonationSelfTarget = testCase "impersonation: targeting the operator themselves is invalid" do
  ref <- newIORef (emptyWorld fixedTime)
  (op, sid) <- seedPrincipal ref "operator@example.com"
  opTok <- signToken ref (claimsFor op sid (Set.singleton impScope) Nothing fixedTime)
  res <- runInMemory ref (exchangeToken cfg (impersonationReq op opTok))
  fmap (const ()) res @?= Left ImpersonationTargetInvalid

testImpersonationDelegatedActorRefused :: TestTree
testImpersonationDelegatedActorRefused = testCase "impersonation: a delegated actor token is refused (no chains)" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  (op, sid) <- seedPrincipal ref "operator@example.com"
  other <- genUserId
  -- An actor token that already carries `act` cannot be used to start another exchange.
  opTok <- signToken ref (claimsFor op sid (Set.singleton impScope) (Just other) fixedTime)
  res <- runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  fmap (const ()) res @?= Left OAuthGrantInvalid

testImpersonationRevokedOperator :: TestTree
testImpersonationRevokedOperator = testCase "impersonation: a revoked operator session is an invalid grant" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  (op, sid) <- seedPrincipal ref "operator@example.com"
  opTok <- signToken ref (claimsFor op sid (Set.singleton impScope) Nothing fixedTime)
  runInMemory ref (revokeSession sid fixedTime)
  res <- runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  fmap (const ()) res @?= Left OAuthGrantInvalid

testImpersonationSuspendedOperator :: TestTree
testImpersonationSuspendedOperator = testCase "impersonation: a suspended operator is forbidden" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  (op, sid) <- seedPrincipal ref "operator@example.com"
  opTok <- signToken ref (claimsFor op sid (Set.singleton impScope) Nothing fixedTime)
  _ <- runInMemory ref (updateUserStatus op [UserActive] UserSuspended fixedTime)
  res <- runInMemory ref (exchangeToken cfg (impersonationReq target opTok))
  fmap (const ()) res @?= Left ImpersonationForbidden

testOnBehalfHappyPath :: TestTree
testOnBehalfHappyPath = testCase "on-behalf-of: user sub + service act, narrowed scopes, audited, refresh-less" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, readScope, tokenExchangeSubjectScope])
  result <- expectRight =<< runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton ingestScope))))
  claims <- decodeAccess result.accessToken
  claims.subject @?= user
  claims.actor @?= Just svcUser
  claims.scopes @?= Set.singleton ingestScope
  result.grantedScopes @?= Set.singleton ingestScope
  result.expiresIn @?= cfg.machineTokenConfig.machineTokenTTL
  assertNoRefresh ref result.sessionId
  world <- readIORef ref
  assertBool "ServiceOnBehalfIssued published" (any (behalfFor svcUser user) world.publishedEvents)
  where
    behalfFor act subj = \case
      Event.ServiceOnBehalfIssued d ->
        d.actorUserId == act && d.subjectUserId == subj && d.scopes == Set.singleton ingestScope
      _ -> False

testOnBehalfDefaultScopes :: TestTree
testOnBehalfDefaultScopes = testCase "on-behalf-of: absent scope grants the ceiling, never the gate scope" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, readScope, tokenExchangeSubjectScope])
  result <- expectRight =<< runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc Nothing))
  -- The gate scope is stripped; the two functional scopes remain.
  result.grantedScopes @?= Set.fromList [ingestScope, readScope]
  assertBool "gate scope is never granted" (not (tokenExchangeSubjectScope `Set.member` result.grantedScopes))

testOnBehalfMissingGateScope :: TestTree
testOnBehalfMissingGateScope = testCase "on-behalf-of: account without the gate scope is refused" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, readScope])
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton ingestScope))))
  fmap (const ()) res @?= Left OAuthScopeInvalid

testOnBehalfScopeOutsideCeiling :: TestTree
testOnBehalfScopeOutsideCeiling = testCase "on-behalf-of: requesting a scope outside the ceiling is refused" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, tokenExchangeSubjectScope])
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton adminScope))))
  fmap (const ()) res @?= Left OAuthScopeInvalid

testOnBehalfGateNeverGranted :: TestTree
testOnBehalfGateNeverGranted = testCase "on-behalf-of: requesting the gate scope itself yields an empty grant, refused" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, tokenExchangeSubjectScope])
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton tokenExchangeSubjectScope))))
  fmap (const ()) res @?= Left OAuthScopeInvalid

testOnBehalfSubjectScopeBoundOk :: TestTree
testOnBehalfSubjectScopeBoundOk = testCase "on-behalf-of: non-empty subject scopes that contain the grant are allowed" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  -- The subject token itself carries a scope set; the grant must be within it.
  subjTok <- signToken ref (claimsFor user usid (Set.fromList [ingestScope, readScope]) Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, readScope, tokenExchangeSubjectScope])
  result <- expectRight =<< runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton ingestScope))))
  result.grantedScopes @?= Set.singleton ingestScope

testOnBehalfSubjectScopeBoundViolation :: TestTree
testOnBehalfSubjectScopeBoundViolation = testCase "on-behalf-of: a grant exceeding non-empty subject scopes is refused" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  -- Subject holds only kawa:ingest; the service asks for kawa:read too — outside the user's authority.
  subjTok <- signToken ref (claimsFor user usid (Set.singleton ingestScope) Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, readScope, tokenExchangeSubjectScope])
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.fromList [ingestScope, readScope]))))
  fmap (const ()) res @?= Left OAuthScopeInvalid

testOnBehalfChainRefused :: TestTree
testOnBehalfChainRefused = testCase "on-behalf-of: an already-delegated subject token is refused (no chains)" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  other <- genUserId
  -- Subject token already carries `act`: it is itself a delegated token and cannot be re-exchanged.
  subjTok <- signToken ref (claimsFor user usid Set.empty (Just other) fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, tokenExchangeSubjectScope])
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton ingestScope))))
  fmap (const ()) res @?= Left OAuthGrantInvalid

testOnBehalfInactiveSubject :: TestTree
testOnBehalfInactiveSubject = testCase "on-behalf-of: an inactive subject user is refused" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  _ <- runInMemory ref (updateUserStatus user [UserActive] UserSuspended fixedTime)
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, tokenExchangeSubjectScope])
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton ingestScope))))
  fmap (const ()) res @?= Left OAuthGrantInvalid

testOnBehalfRevokedSubject :: TestTree
testOnBehalfRevokedSubject = testCase "on-behalf-of: a revoked subject session is an invalid grant" do
  ref <- newIORef (emptyWorld fixedTime)
  (user, usid) <- seedPrincipal ref "customer@example.com"
  svcUser <- seedUser ref "svc@example.com"
  subjTok <- signToken ref (claimsFor user usid Set.empty Nothing fixedTime)
  svc <- mkServiceAccount svcUser (Set.fromList [ingestScope, tokenExchangeSubjectScope])
  runInMemory ref (revokeSession usid fixedTime)
  res <- runInMemory ref (exchangeToken cfg (onBehalfReq subjTok svc (Just (Set.singleton ingestScope))))
  fmap (const ()) res @?= Left OAuthGrantInvalid

testRefreshlessRequestedTypeRejected :: TestTree
testRefreshlessRequestedTypeRejected = testCase "a requested_token_type other than access_token is malformed" do
  ref <- newIORef (emptyWorld fixedTime)
  target <- seedUser ref "customer@example.com"
  opTok <- freshOperatorToken ref
  let req = (impersonationReq target opTok) {requestedTokenType = Just "urn:ietf:params:oauth:token-type:refresh_token"}
  res <- runInMemory ref (exchangeToken cfg req)
  fmap (const ()) res @?= Left OAuthRequestMalformed
