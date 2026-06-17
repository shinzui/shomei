{- | Behavioral tests for the impersonation token-exchange workflow
('Shomei.Workflow.Impersonation'), run entirely through the in-memory interpreter
('Shomei.Effect.InMemory.runInMemory'). No cryptography, no database, no network.

The in-memory 'Shomei.Effect.TokenSigner' fake renders 'AuthClaims' as JSON, so a
minted access token decodes straight back to 'AuthClaims' for inspection.
-}
module Shomei.Workflow.ImpersonationSpec (tests) where

import Data.Aeson (eitherDecode)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Scope (..))
import Shomei.Domain.Command (SignupCommand (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.RefreshToken (PersistedRefreshToken (..))
import Shomei.Domain.Session (Session (..), SessionStatus (SessionRevoked))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User (..), UserStatus (UserSuspended))
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory)
import Shomei.Effect.UserStore (updateUserStatus)
import Shomei.Error (AuthError (ImpersonationForbidden, ImpersonationTargetInvalid))
import Shomei.Id (SessionId, UserId, genSessionId, genUserId)
import Shomei.Workflow (signup)
import Shomei.Workflow.Impersonation (StartImpersonation (..), startImpersonation, stopImpersonation)

-- Fixtures -------------------------------------------------------------------

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

impScope :: Scope
impScope = cfg.impersonationConfig.impersonateScope

customerEmail :: Email
customerEmail = mkEmail' "customer@example.com"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

mkEmail' :: Text -> Email
mkEmail' t = either (\e -> error ("bad test email: " <> show e)) id (mkEmail t)

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure ("expected Right, got Left: " <> show e)) pure

{- | Caller (operator) claims with the given scopes, issued at @iat@. The caller need
not be a stored user — the workflow only reads scopes/issuedAt/subject from the token.
-}
callerClaims :: UserId -> SessionId -> Set Scope -> UTCTime -> AuthClaims
callerClaims uid sid scs iat =
    AuthClaims
        { subject = uid
        , sessionId = sid
        , issuer = cfg.issuer
        , audience = cfg.audience
        , issuedAt = iat
        , expiresAt = addUTCTime 900 iat
        , scopes = scs
        , roles = Set.empty
        , actor = Nothing
        , extraClaims = mempty
        }

-- | Sign up the customer and return their (active) user id.
seedCustomer :: IORef World -> IO UserId
seedCustomer ref = do
    (user, _) <- expectRight =<< runInMemory ref (signup cfg (SignupCommand customerEmail strongPw (Just "Customer")))
    pure user.userId

-- | A fresh operator (caller) holding the impersonation scope, issued now.
freshOperator :: IO AuthClaims
freshOperator = do
    op <- genUserId
    sid <- genSessionId
    pure (callerClaims op sid (Set.singleton impScope) fixedTime)

mkStart :: AuthClaims -> UserId -> StartImpersonation
mkStart caller target =
    StartImpersonation
        { actorClaims = caller
        , targetUserId = target
        , reason = "Debugging support issue"
        , ticketId = Just "SUP-1234"
        , clientIp = Just "203.0.113.7"
        }

-- | Decode the JSON the in-memory signer renders back into 'AuthClaims'.
decodeAccess :: AccessToken -> IO AuthClaims
decodeAccess (AccessToken t) =
    either (\e -> assertFailure ("could not decode access token: " <> e)) pure
        (eitherDecode (TLE.encodeUtf8 (TL.fromStrict t)))

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
    testGroup
        "Shomei.Workflow.Impersonation"
        [ testHappyPath
        , testMissingScope
        , testStaleCaller
        , testSelfTarget
        , testUnknownTarget
        , testInactiveTarget
        , testStop
        ]

testHappyPath :: TestTree
testHappyPath = testCase "fresh scoped caller impersonating an active target succeeds" do
    ref <- newIORef (emptyWorld fixedTime)
    target <- seedCustomer ref
    caller <- freshOperator
    (session, access) <- expectRight =<< runInMemory ref (startImpersonation cfg (mkStart caller target))
    -- the delegated session records the operator as actor
    session.actor @?= Just caller.subject
    session.userId @?= target
    -- the token names the customer as subject and the operator as actor
    claims <- decodeAccess access
    claims.subject @?= target
    claims.actor @?= Just caller.subject
    -- no refresh token was minted for the delegated session
    world <- readIORef ref
    let refsForSession = filter (\PersistedRefreshToken{sessionId = s} -> s == session.sessionId) (Map.elems world.refreshTokens)
    assertBool "delegated session has no refresh token" (null refsForSession)
    -- an ImpersonationStarted event carrying both ids + the reason was published
    assertBool "ImpersonationStarted published" (any (matchesStarted caller.subject target) world.publishedEvents)
  where
    matchesStarted actorId subj = \case
        Event.ImpersonationStarted d ->
            d.actorUserId == actorId
                && d.subjectUserId == subj
                && d.reason == "Debugging support issue"
        _ -> False

testMissingScope :: TestTree
testMissingScope = testCase "caller without the impersonate scope is forbidden" do
    ref <- newIORef (emptyWorld fixedTime)
    target <- seedCustomer ref
    op <- genUserId
    sid <- genSessionId
    let caller = callerClaims op sid Set.empty fixedTime
    res <- runInMemory ref (startImpersonation cfg (mkStart caller target))
    fmap (const ()) res @?= Left ImpersonationForbidden

testStaleCaller :: TestTree
testStaleCaller = testCase "caller whose token predates the freshness window is forbidden" do
    ref <- newIORef (emptyWorld fixedTime)
    target <- seedCustomer ref
    op <- genUserId
    sid <- genSessionId
    -- issued one second before the freshness window opens
    let stale = addUTCTime (negate (cfg.impersonationConfig.actorFreshnessWindow + 1)) fixedTime
        caller = callerClaims op sid (Set.singleton impScope) stale
    res <- runInMemory ref (startImpersonation cfg (mkStart caller target))
    fmap (const ()) res @?= Left ImpersonationForbidden

testSelfTarget :: TestTree
testSelfTarget = testCase "impersonating yourself is an invalid target" do
    ref <- newIORef (emptyWorld fixedTime)
    caller <- freshOperator
    res <- runInMemory ref (startImpersonation cfg (mkStart caller caller.subject))
    fmap (const ()) res @?= Left ImpersonationTargetInvalid

testUnknownTarget :: TestTree
testUnknownTarget = testCase "unknown target is an invalid target" do
    ref <- newIORef (emptyWorld fixedTime)
    caller <- freshOperator
    ghost <- genUserId
    res <- runInMemory ref (startImpersonation cfg (mkStart caller ghost))
    fmap (const ()) res @?= Left ImpersonationTargetInvalid

testInactiveTarget :: TestTree
testInactiveTarget = testCase "suspended target is an invalid target" do
    ref <- newIORef (emptyWorld fixedTime)
    target <- seedCustomer ref
    _ <- runInMemory ref (updateUserStatus target UserSuspended)
    caller <- freshOperator
    res <- runInMemory ref (startImpersonation cfg (mkStart caller target))
    fmap (const ()) res @?= Left ImpersonationTargetInvalid

testStop :: TestTree
testStop = testCase "stopImpersonation revokes the delegated session and audits the stop" do
    ref <- newIORef (emptyWorld fixedTime)
    target <- seedCustomer ref
    caller <- freshOperator
    (session, access) <- expectRight =<< runInMemory ref (startImpersonation cfg (mkStart caller target))
    delegatedClaims <- decodeAccess access
    _ <- expectRight =<< runInMemory ref (stopImpersonation delegatedClaims)
    world <- readIORef ref
    -- the delegated session is now revoked
    case Map.lookup session.sessionId world.sessions of
        Just s -> s.status @?= SessionRevoked
        Nothing -> assertFailure "delegated session vanished"
    assertBool "ImpersonationStopped published" (any (matchesStopped caller.subject target) world.publishedEvents)
  where
    matchesStopped actorId subj = \case
        Event.ImpersonationStopped d -> d.actorUserId == actorId && d.subjectUserId == subj
        _ -> False
