-- | Roles reaching the token: the grant path, the claims-enrichment hook, and default roles.
module Shomei.Workflow.RolesSpec (tests) where

import Data.Aeson (eitherDecode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Effectful (Eff, IOE, (:>))
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Domain.Claims (Audience (..), AuthClaims (..), Issuer (..), Permission (..), Role (..), Scope (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Email (mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (LoginId, mkLoginId)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.ClaimsEnricher (ClaimsDelta (..), emptyClaimsDelta)
import Shomei.Effect.InMemory (World (..), emptyWorld, runInMemory, runInMemoryWith)
import Shomei.Effect.RoleStore (allowPermission, defineRole)
import Shomei.Id (genSessionId)
import Shomei.Prelude
import Shomei.Workflow (LoginResult (..), login, refresh, signup)
import Shomei.Workflow.Roles (grantRoleTo, revokeRoleFrom, rolesOf, undefinedDefaultRoles)
import Shomei.Workflow.Session (buildEnrichedClaims)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Shomei.Workflow.Roles"
    [ testGrantedRoleReachesTheNextToken,
      testRefreshPicksUpAGrant,
      testRevocationDropsTheRoleOnRefresh,
      testEnricherCannotForgeReservedClaims,
      testEnricherAddsRolesAndScopes,
      testDefaultRolesLandOnTheFirstToken,
      testUndefinedDefaultRolesAreReported,
      testPermissionUnionReachesTheToken,
      testExpiredGrantDropsRoleAndPermissions,
      testEnricherRoleContributesPermissions
    ]

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

baseCfg :: ShomeiConfig
baseCfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

adminRole, memberRole, betaRole, supportRole, billingRole :: Role
adminRole = Role "admin"
memberRole = Role "member"
betaRole = Role "beta-tester"
supportRole = Role "support"
billingRole = Role "billing"

strongPw :: PlainPassword
strongPw = PlainPassword "correct horse battery staple"

aliceLogin :: LoginId
aliceLogin = either (\e -> error ("bad test login id: " <> show e)) id (mkLoginId "alice@example.com")

-- | The abuse store plays no part in these tests; one fixed IP and account key throughout.
ctx :: ClientContext
ctx = ClientContext {clientIp = ClientIp "1.2.3.4", accountKey = AccountKey "k-alice"}

signupCmd :: SignupCommand
signupCmd =
  SignupCommand
    { loginId = aliceLogin,
      email = Just (either (\e -> error ("bad test email: " <> show e)) id (mkEmail "alice@example.com")),
      password = strongPw,
      displayName = Nothing
    }

loginCmd :: LoginCommand
loginCmd = LoginCommand {loginId = aliceLogin, password = strongPw}

-- | Unwrap a workflow's @Either AuthError@ inside the effect stack; a 'Left' is a test bug.
orFail :: (Show e) => Either e a -> Eff es a
orFail = either (\e -> error ("workflow failed: " <> show e)) pure

-- | The access token from a login that must not have demanded a second factor.
completeLogin :: (IOE :> es) => LoginResult -> Eff es AccessToken
completeLogin = \case
  LoginComplete _ pair -> pure pair.accessToken
  MfaRequired _ -> error "unexpected MFA challenge"

decodeAccess :: AccessToken -> IO AuthClaims
decodeAccess (AccessToken t) =
  either
    (\e -> assertFailure ("could not decode access token: " <> e))
    pure
    (eitherDecode (TLE.encodeUtf8 (TL.fromStrict t)))

-- | A granted role does not appear in an already-issued token, but does appear in the next one
-- minted by login. This is the staleness contract stated in @docs/user/security.md@.
testGrantedRoleReachesTheNextToken :: TestTree
testGrantedRoleReachesTheNextToken =
  testCase "a role granted after signup appears in the next login's token, not the old one" do
    ref <- newIORef (emptyWorld fixedTime)
    (before, after, storedRoles) <- runInMemory ref do
      (user, firstPair) <- orFail =<< signup baseCfg signupCmd
      _ <- orFail =<< grantRoleTo Nothing Nothing user.userId adminRole
      after <- completeLogin =<< orFail =<< login baseCfg ctx loginCmd
      roles <- orFail =<< rolesOf user.userId
      pure (firstPair.accessToken, after, roles)
    beforeClaims <- decodeAccess before
    afterClaims <- decodeAccess after
    beforeClaims.roles @?= Set.empty
    afterClaims.roles @?= Set.singleton adminRole
    storedRoles @?= Set.singleton adminRole

-- | @refresh@ re-runs the enrichment, which is why a grant propagates without a fresh login.
testRefreshPicksUpAGrant :: TestTree
testRefreshPicksUpAGrant =
  testCase "a role granted after login appears in the token minted by refresh" do
    ref <- newIORef (emptyWorld fixedTime)
    refreshed <- runInMemory ref do
      (user, pair) <- orFail =<< signup baseCfg signupCmd
      _ <- orFail =<< grantRoleTo Nothing Nothing user.userId adminRole
      newPair <- orFail =<< refresh baseCfg RefreshCommand {refreshToken = pair.refreshToken}
      pure newPair.accessToken
    claims <- decodeAccess refreshed
    claims.roles @?= Set.singleton adminRole

-- | And the same lever in reverse: revoking then refreshing mints a role-less token.
testRevocationDropsTheRoleOnRefresh :: TestTree
testRevocationDropsTheRoleOnRefresh =
  testCase "a role revoked after a grant is gone from the token minted by refresh" do
    ref <- newIORef (emptyWorld fixedTime)
    refreshed <- runInMemory ref do
      (user, pair) <- orFail =<< signup baseCfg signupCmd
      _ <- orFail =<< grantRoleTo Nothing Nothing user.userId adminRole
      _ <- orFail =<< revokeRoleFrom Nothing user.userId adminRole
      newPair <- orFail =<< refresh baseCfg RefreshCommand {refreshToken = pair.refreshToken}
      pure newPair.accessToken
    claims <- decodeAccess refreshed
    claims.roles @?= Set.empty

-- | The hook's extra-claims object runs through @mkExtraClaims@, so a host cannot override a
-- standard claim through it — not @sub@, not @roles@, not @scopes@.
testEnricherCannotForgeReservedClaims :: TestTree
testEnricherCannotForgeReservedClaims =
  testCase "a ClaimsDelta cannot smuggle reserved claim keys into extraClaims" do
    ref <- newIORef (emptyWorld fixedTime)
    let forged =
          KeyMap.fromList
            [ ("sub", toJSON ("attacker" :: Text)),
              ("roles", toJSON ["admin" :: Text]),
              ("scopes", toJSON ["impersonate:user" :: Text]),
              ("permissions", toJSON ["billing:write" :: Text]),
              ("iss", toJSON ("evil" :: Text)),
              ("act", toJSON ("operator" :: Text)),
              ("tenant", toJSON ("acme" :: Text))
            ]
        -- Named constructor, not a record update: 'extraClaims' lives on both 'ClaimsDelta'
        -- and 'AuthClaims', so an update would be ambiguous under DuplicateRecordFields.
        hook _ _ = ClaimsDelta {extraRoles = Set.empty, extraScopes = Set.empty, extraClaims = forged}
    (claims, realUserId) <- runInMemoryWith hook ref do
      (user, _) <- orFail =<< signup baseCfg signupCmd
      sid <- genSessionId
      c <- buildEnrichedClaims baseCfg user.userId sid fixedTime
      pure (c, user.userId)
    -- Only the non-reserved key survives, and the standard claims are the real ones.
    KeyMap.keys claims.extraClaims @?= ["tenant"]
    claims.subject @?= realUserId
    claims.issuer @?= baseCfg.issuer
    claims.roles @?= Set.empty
    claims.scopes @?= Set.empty
    claims.permissions @?= Set.empty
    claims.actor @?= Nothing

-- | The hook's roles are unioned with the stored ones; its scopes are the only source of scopes.
testEnricherAddsRolesAndScopes :: TestTree
testEnricherAddsRolesAndScopes =
  testCase "a ClaimsDelta's roles union with the store's, and its scopes reach the token" do
    ref <- newIORef (emptyWorld fixedTime)
    let hook _ _ =
          emptyClaimsDelta
            { extraRoles = Set.singleton betaRole,
              extraScopes = Set.singleton (Scope "reports:read")
            }
    access <- runInMemoryWith hook ref do
      (user, _) <- orFail =<< signup baseCfg signupCmd
      _ <- orFail =<< grantRoleTo Nothing Nothing user.userId adminRole
      completeLogin =<< orFail =<< login baseCfg ctx loginCmd
    claims <- decodeAccess access
    claims.roles @?= Set.fromList [adminRole, betaRole]
    claims.scopes @?= Set.singleton (Scope "reports:read")

-- | Default roles are applied inside 'signup', before the first token is minted, and each is
-- audited as a 'Event.RoleGranted' with no acting admin.
testDefaultRolesLandOnTheFirstToken :: TestTree
testDefaultRolesLandOnTheFirstToken =
  testCase "signup under defaultRoles mints them on the FIRST token and audits each grant" do
    ref <- newIORef (emptyWorld fixedTime)
    let cfg = baseCfg {defaultRoles = Set.singleton memberRole}
    firstAccess <- runInMemory ref do
      _ <- defineRole memberRole (Just "an ordinary user") fixedTime
      (_user, pair) <- orFail =<< signup cfg signupCmd
      pure pair.accessToken
    claims <- decodeAccess firstAccess
    claims.roles @?= Set.singleton memberRole
    world <- readIORef ref
    let grants = [d | Event.RoleGranted d <- world.publishedEvents]
    map (.role) grants @?= [memberRole]
    -- The bootstrap/system actor: no acting admin, exactly like a CLI grant.
    map (.grantedBy) grants @?= [Nothing]

-- | The @permissions@ claim (EP-9) is the deduplicated union of the granted roles' catalog
-- permissions — the whole point of the indirection: a consumer checks @tickets:read@ regardless
-- of which of the user's roles supplies it.
testPermissionUnionReachesTheToken :: TestTree
testPermissionUnionReachesTheToken =
  testCase "the permissions claim is the deduplicated union of the granted roles' permissions" do
    ref <- newIORef (emptyWorld fixedTime)
    access <- runInMemory ref do
      (user, _) <- orFail =<< signup baseCfg signupCmd
      _ <- defineRole supportRole (Just "support staff") fixedTime
      _ <- defineRole billingRole (Just "billing staff") fixedTime
      _ <- allowPermission supportRole (Permission "tickets:write") fixedTime
      _ <- allowPermission supportRole (Permission "tickets:read") fixedTime
      _ <- allowPermission billingRole (Permission "tickets:read") fixedTime -- overlaps support
      _ <- allowPermission billingRole (Permission "invoices:read") fixedTime
      _ <- orFail =<< grantRoleTo Nothing Nothing user.userId supportRole
      _ <- orFail =<< grantRoleTo Nothing Nothing user.userId billingRole
      completeLogin =<< orFail =<< login baseCfg ctx loginCmd
    claims <- decodeAccess access
    claims.roles @?= Set.fromList [supportRole, billingRole]
    claims.permissions
      @?= Set.fromList [Permission "invoices:read", Permission "tickets:read", Permission "tickets:write"]

-- | Grant expiry is passive and read-time: a grant whose expiry has passed contributes neither its
-- role nor its permissions to a token minted after the expiry instant, while one minted before it
-- carries both — from the same grant, with nothing fired in between.
testExpiredGrantDropsRoleAndPermissions :: TestTree
testExpiredGrantDropsRoleAndPermissions =
  testCase "an expired grant contributes neither its role nor its permissions at mint" do
    ref <- newIORef (emptyWorld fixedTime)
    let expiry = addUTCTime 3600 fixedTime
        afterExpiry = addUTCTime 7200 fixedTime
    (live, expired) <- runInMemory ref do
      (user, _) <- orFail =<< signup baseCfg signupCmd
      _ <- defineRole supportRole (Just "support staff") fixedTime
      _ <- allowPermission supportRole (Permission "tickets:write") fixedTime
      _ <- orFail =<< grantRoleTo Nothing (Just expiry) user.userId supportRole
      sid1 <- genSessionId
      live <- buildEnrichedClaims baseCfg user.userId sid1 fixedTime -- before expiry
      sid2 <- genSessionId
      expired <- buildEnrichedClaims baseCfg user.userId sid2 afterExpiry -- after expiry
      pure (live, expired)
    live.roles @?= Set.singleton supportRole
    live.permissions @?= Set.singleton (Permission "tickets:write")
    expired.roles @?= Set.empty
    expired.permissions @?= Set.empty

-- | Permissions are resolved from the /effective/ role set (Decision Log): a role a host injects
-- through its 'ClaimsEnricher' brings its catalog permissions exactly as a granted role would.
testEnricherRoleContributesPermissions :: TestTree
testEnricherRoleContributesPermissions =
  testCase "an enricher-added role brings its catalog permissions into the token" do
    ref <- newIORef (emptyWorld fixedTime)
    let hook _ _ = emptyClaimsDelta {extraRoles = Set.singleton betaRole}
    claims <- runInMemoryWith hook ref do
      (user, _) <- orFail =<< signup baseCfg signupCmd
      _ <- defineRole betaRole (Just "beta cohort") fixedTime
      _ <- allowPermission betaRole (Permission "beta:features") fixedTime
      sid <- genSessionId
      buildEnrichedClaims baseCfg user.userId sid fixedTime
    claims.roles @?= Set.singleton betaRole
    claims.permissions @?= Set.singleton (Permission "beta:features")

-- | The boot-time guard: a configured default role missing from the registry is reported.
testUndefinedDefaultRolesAreReported :: TestTree
testUndefinedDefaultRolesAreReported =
  testCase "undefinedDefaultRoles names exactly the configured roles absent from the registry" do
    ref <- newIORef (emptyWorld fixedTime)
    -- 'admin' is seeded by emptyWorld (mirroring the migration); 'member' and 'staff' are not.
    let cfg = baseCfg {defaultRoles = Set.fromList [adminRole, memberRole, Role "staff"]}
    missing <- runInMemory ref (undefinedDefaultRoles cfg)
    missing @?= Set.fromList [memberRole, Role "staff"]

    -- Define one of them and it drops out of the report.
    missing' <- runInMemory ref do
      _ <- defineRole memberRole Nothing fixedTime
      undefinedDefaultRoles cfg
    missing' @?= Set.singleton (Role "staff")

    -- An empty config short-circuits without reading the registry at all.
    none <- runInMemory ref (undefinedDefaultRoles baseCfg)
    assertBool "no defaultRoles means nothing is missing" (Set.null none)
