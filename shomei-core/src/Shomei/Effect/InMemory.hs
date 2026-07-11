{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | A pure, in-memory interpreter for every Shōmei port, backing the EP-2 test suite.
--
-- A single mutable 'World' (held in an 'IORef') holds the user/credential/session/
-- refresh-token/signing-key stores plus the published-event log, a fixed test clock, and
-- a deterministic token counter. 'runInMemory' stacks an interpreter for every port over
-- 'IOE'. There is no database, JWT library, or network here: the
-- 'Shomei.Effect.PasswordHasher' fake tags and compares plaintext, the
-- 'Shomei.Effect.TokenGen' fake emits @rt-0@, @rt-1@, … and the
-- 'Shomei.Effect.TokenSigner'/'Shomei.Effect.TokenVerifier' fakes round-trip 'AuthClaims'
-- through JSON.
module Shomei.Effect.InMemory
  ( World (..),
    emptyWorld,
    runInMemory,
    runInMemoryWith,

    -- * Individual interpreters

    -- | Exported so an assembly can compose a /hybrid/ stack — e.g. these
    --     in-memory store/support interpreters together with EP-4's real @jose@
    --     'Shomei.Effect.TokenSigner'/'Shomei.Effect.TokenVerifier' interpreters — keeping
    --     the same effect order as 'runInMemory'. ('Shomei.Servant''s end-to-end test
    --     uses exactly that hybrid so signing/verification exercise real ES256.)
    runUserStore,
    runCredentialStore,
    runSessionStore,
    runRefreshTokenStore,
    runRoleStore,
    runAuthUnitOfWork,
    runVerificationTokenStore,
    runPasswordResetTokenStore,
    runLoginAttemptStore,
    runPasskeyStore,
    runPendingCeremonyStore,
    runServiceAccountStore,
    runOAuthClientStore,
    runOAuthCodeStore,
    runTotpCredentialStore,
    runRecoveryCodeStore,
    runNotifier,
    runClaimsEnricherNull,
    runPasswordHasher,
    runPasswordBreachCheckerFake,
    runTokenSigner,
    runTokenVerifier,
    runAuthEventPublisher,
    runAuthEventReader,
    runSigningKeyStore,
    runClock,
    runTokenGen,
    runWebAuthnCeremonyFake,
  )
where

import Data.Aeson (Value, eitherDecode, eitherDecodeStrict', encode, object)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseMaybe, withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', readIORef, writeIORef)
import Data.List (sortBy, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, listToMaybe)
import Data.Ord (Down (..), comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Domain.AuthorizationCode
  ( AuthorizationCode (..),
    NewAuthorizationCode (..),
  )
import Shomei.Domain.Claims (AuthClaims, Issuer (..), Permission (..), Role (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.EventCodec (projectAuthEvent)
import Shomei.Domain.IdTokenClaims (IdToken (..), IdTokenClaims (..))
import Shomei.Domain.LoginAttempt
  ( AccountKey,
    AccountLockout (..),
    LoginAttempt (..),
    LoginOutcome (..),
    NewLoginAttempt (..),
  )
import Shomei.Domain.LoginId (LoginId)
import Shomei.Domain.Notification (Notification)
import Shomei.Domain.OAuthClient
  ( NewOAuthClient (..),
    OAuthClient (..),
    OAuthClientStatus (..),
  )
import Shomei.Domain.OneTimeToken (OneTimeTokenHash, OneTimeTokenStatus (..))
import Shomei.Domain.Passkey
  ( NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    PublicKeyBytes,
    SignatureCounter (..),
    UserHandle,
    WebAuthnCredentialId,
  )
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken
  ( NewRefreshToken (..),
    PersistedRefreshToken (..),
    RefreshToken (..),
    RefreshTokenHash (..),
    RefreshTokenStatus (..),
  )
import Shomei.Domain.ServiceAccount
  ( NewServiceAccount (..),
    ServiceAccount (..),
    ServiceAccountStatus (..),
  )
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.Totp
  ( NewRecoveryCode (..),
    NewTotpCredential (..),
    RecoveryCode (..),
    TotpCredential (..),
  )
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (..))
import Shomei.Domain.VerificationToken (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Effect.AuthEventReader
  ( AuditCursor (..),
    AuditEventQuery (..),
    AuthEventReader (..),
    StoredAuthEvent (..),
    clampLimit,
  )
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork (..), NewSessionToken (..), RotationOutcome (..))
import Shomei.Effect.ClaimsEnricher (ClaimsDelta, ClaimsEnricher, emptyClaimsDelta, runClaimsEnricherNull, runClaimsEnricherPure)
import Shomei.Effect.Clock (Clock (..))
import Shomei.Effect.CredentialStore (CredentialStore (..))
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore (..))
import Shomei.Effect.Notifier (Notifier (..))
import Shomei.Effect.OAuthClientStore (OAuthClientStore (..))
import Shomei.Effect.OAuthCodeStore (OAuthCodeStore (..))
import Shomei.Effect.PasskeyStore (PasskeyStore (..))
import Shomei.Effect.PasswordBreachChecker (BreachResult (..), PasswordBreachChecker (..))
import Shomei.Effect.PasswordHasher (PasswordHasher (..))
import Shomei.Effect.PasswordResetTokenStore (PasswordResetTokenStore (..))
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore (..))
import Shomei.Effect.RecoveryCodeStore (RecoveryCodeStore (..))
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore (..))
import Shomei.Effect.RoleStore (RoleDefinition (..), RoleStore (..))
import Shomei.Effect.ServiceAccountStore (ServiceAccountStore (..))
import Shomei.Effect.SessionStore (SessionStore (..))
import Shomei.Effect.SigningKeyStore (SigningKeyStore (..))
import Shomei.Effect.TokenGen (TokenGen (..))
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.TokenVerifier (TokenVerifier (..))
import Shomei.Effect.TotpCredentialStore (TotpCredentialStore (..))
import Shomei.Effect.UserStore (UserCursor (..), UserListQuery (..), UserStore (..), clampUserLimit)
import Shomei.Effect.VerificationTokenStore (VerificationTokenStore (..))
import Shomei.Effect.WebAuthnCeremony
  ( BeginCeremony (..),
    StoredCredentialForVerify (..),
    VerifiedAuthentication (..),
    VerifiedRegistration (..),
    WebAuthnCeremony (..),
    WebAuthnError (..),
  )
import Shomei.Error (TokenError (..))
import Shomei.Id
  ( CeremonyId,
    OAuthClientId,
    PasskeyId,
    PasswordResetTokenId,
    RecoveryCodeId,
    RefreshTokenId,
    ServiceAccountDbId,
    SessionId,
    TotpCredentialId,
    UserId,
    VerificationTokenId,
    genCredentialId,
    genPasskeyId,
    genPasswordResetTokenId,
    genRefreshTokenId,
    genSessionId,
    genUserId,
    genVerificationTokenId,
    idText,
    sessionIdToUUID,
    userIdToUUID,
  )
import Shomei.Prelude

-- | The whole mutable test world.
data World = World
  { users :: !(Map UserId User),
    credsByLoginId :: !(Map LoginId Credential),
    sessions :: !(Map SessionId Session),
    refreshTokens :: !(Map RefreshTokenId PersistedRefreshToken),
    refreshByHash :: !(Map RefreshTokenHash RefreshTokenId),
    verificationTokens :: !(Map VerificationTokenId PersistedVerificationToken),
    verificationByHash :: !(Map OneTimeTokenHash VerificationTokenId),
    passwordResetTokens :: !(Map PasswordResetTokenId PersistedPasswordResetToken),
    passwordResetByHash :: !(Map OneTimeTokenHash PasswordResetTokenId),
    signingKeys :: !(Map Text StoredSigningKey),
    -- | the role registry, pre-seeded with @admin@ to mirror the migration's seed row so a
    --     fresh in-memory world and a freshly migrated database agree
    definedRoles :: !(Map Role RoleDefinition),
    -- | durable @(user, role)@ grants, each with an optional expiry (@Nothing@ = forever), mirroring
    --     @shomei_role_grants.expires_at@ (EP-9). Unlike PostgreSQL, this map enforces no foreign key
    --     into 'definedRoles': the registry check lives in 'Shomei.Workflow.Roles.grantRoleTo',
    --     which is the tested path. The database FK is defense in depth for code that bypasses
    --     the workflow, and has no in-memory analogue.
    roleGrants :: !(Map UserId (Map Role (Maybe UTCTime))),
    -- | role→permission definitions (@shomei_role_permissions@, EP-9), resolved to a union at mint.
    --     As with 'roleGrants', no FK into 'definedRoles' is enforced here.
    rolePermissions :: !(Map Role (Set Permission)),
    -- | newest-first append-only attempt log (EP-2 brute-force protection)
    loginAttempts :: ![LoginAttempt],
    accountLockouts :: !(Map AccountKey AccountLockout),
    passkeys :: !(Map PasskeyId PasskeyCredential),
    pendingCeremonies :: !(Map CeremonyId PendingCeremony),
    -- | EP-4 database-backed service accounts, keyed by id. Unlike PostgreSQL this map
    --     enforces no unique index on @clientId@; the id /is/ the client id's source, so a
    --     collision is impossible by construction.
    serviceAccounts :: !(Map ServiceAccountDbId ServiceAccount),
    -- | EP-5 OAuth2/OIDC clients, keyed by id. As with 'serviceAccounts', @clientId@ is derived
    --     from the id, so the database's unique index has no in-memory analogue to enforce.
    oauthClients :: !(Map OAuthClientId OAuthClient),
    -- | EP-5 single-use authorization codes, keyed by the code's SHA-256 hex digest exactly as
    --     the PostgreSQL primary key is. Consumed rows stay, so a replay finds a consumed row.
    oauthCodes :: !(Map Text AuthorizationCode),
    -- | EP-7 TOTP credentials, keyed by user id (@UNIQUE (user_id)@). The in-memory interpreter
    --     holds the /raw/ 'Shomei.Totp.TotpSecret'; only the PostgreSQL boundary encrypts it.
    totpCredentials :: !(Map UserId TotpCredential),
    -- | EP-7 recovery codes, keyed by id. Consumed rows stay (with @usedAt@ set), so a replayed
    --     code finds a spent row exactly as the database does.
    recoveryCodes :: !(Map RecoveryCodeId RecoveryCode),
    -- | newest-first
    publishedEvents :: ![Event.AuthEvent],
    -- | newest-first
    sentNotifications :: ![Notification],
    -- | fixed test time
    clock :: !UTCTime,
    -- | deterministic opaque tokens
    tokenCounter :: !Int,
    -- | deterministic WebAuthn ceremony challenges (fake interpreter)
    ceremonyCounter :: !Int,
    -- | EP-3: plaintexts the breach-checker fake treats as breached
    breachedPasswords :: !(Set Text),
    -- | EP-3: when False the fake returns 'BreachCheckUnavailable' (test seam for fail-open/closed)
    breachCheckAvailable :: !Bool
  }
  deriving stock (Generic)

emptyWorld :: UTCTime -> World
emptyWorld t =
  World
    { users = Map.empty,
      credsByLoginId = Map.empty,
      sessions = Map.empty,
      refreshTokens = Map.empty,
      refreshByHash = Map.empty,
      verificationTokens = Map.empty,
      verificationByHash = Map.empty,
      passwordResetTokens = Map.empty,
      passwordResetByHash = Map.empty,
      signingKeys = Map.empty,
      definedRoles = Map.singleton adminRole (RoleDefinition adminRole (Just adminRoleDescription) t),
      roleGrants = Map.empty,
      rolePermissions = Map.empty,
      loginAttempts = [],
      accountLockouts = Map.empty,
      passkeys = Map.empty,
      pendingCeremonies = Map.empty,
      serviceAccounts = Map.empty,
      oauthClients = Map.empty,
      oauthCodes = Map.empty,
      totpCredentials = Map.empty,
      recoveryCodes = Map.empty,
      publishedEvents = [],
      sentNotifications = [],
      clock = t,
      tokenCounter = 0,
      ceremonyCounter = 0,
      breachedPasswords = Set.empty,
      breachCheckAvailable = True
    }

-- | The role the @shomei_role_grants@ migration seeds into the registry, and its description.
-- Kept in lockstep with @shomei-migrations\/sql-migrations\/*-shomei-role-grants.sql@.
adminRole :: Role
adminRole = Role "admin"

adminRoleDescription :: Text
adminRoleDescription = "Full access to the shomei /admin surface and admin CLI-equivalent HTTP routes"

-- | Strict, /atomic/ world update. Every store shares one 'IORef' 'World', and the
-- concurrency regression tests run workflows from many green threads, so the plain
-- read-modify-write of 'Data.IORef.modifyIORef'' would silently drop updates.
-- 'atomicModifyIORef'' serializes them.
modifyWorld :: IORef World -> (World -> World) -> IO ()
modifyWorld ref f = atomicModifyIORef' ref \w -> (f w, ())

-- | Atomic compare-and-swap over the world: inspect and transition in one uninterruptible
-- step, answering whether this caller performed the transition. The in-memory analogue of a
-- conditional @UPDATE … WHERE status = 'active' RETURNING@.
casWorld :: IORef World -> (World -> Maybe World) -> IO Bool
casWorld ref f = atomicModifyIORef' ref \w -> case f w of
  Just w' -> (w', True)
  Nothing -> (w, False)

-- Token signer/verifier fakes: round-trip claims through JSON.

renderClaims :: AuthClaims -> Text
renderClaims = TL.toStrict . TLE.decodeUtf8 . encode

parseClaims :: Text -> Either TokenError AuthClaims
parseClaims t = case eitherDecode (TLE.encodeUtf8 (TL.fromStrict t)) of
  Left _ -> Left TokenMalformed
  Right c -> Right c

-- | Walk to the root of a refresh-token family by following @parentTokenId@ links.
rootOf :: Map RefreshTokenId PersistedRefreshToken -> RefreshTokenId -> RefreshTokenId
rootOf m tid = case Map.lookup tid m of
  Just t -> maybe tid (rootOf m) t.parentTokenId
  Nothing -> tid

runUserStore :: (IOE :> es) => IORef World -> Eff (UserStore : es) a -> Eff es a
runUserStore ref = interpret_ \case
  CreateUser nu -> do
    uid <- genUserId
    w <- liftIO (readIORef ref)
    let u =
          User
            { userId = uid,
              loginId = nu.loginId,
              email = nu.email,
              displayName = nu.displayName,
              status = UserActive,
              emailVerifiedAt = Nothing,
              createdAt = w.clock,
              updatedAt = w.clock
            }
    liftIO (modifyWorld ref (#users %~ Map.insert uid u))
    pure u
  FindUserById uid -> liftIO ((Map.lookup uid . (.users)) <$> readIORef ref)
  FindUserByLoginId lid -> liftIO (findByLoginId lid <$> readIORef ref)
  FindUserByEmail e -> liftIO (findByEmail e <$> readIORef ref)
  UpdateUserStatus uid st -> liftIO do
    w <- readIORef ref
    modifyWorld ref (#users %~ Map.adjust (\u -> u & #status .~ st & #updatedAt .~ w.clock) uid)
  MarkUserEmailVerified uid t ->
    liftIO (modifyWorld ref (#users %~ Map.adjust (#emailVerifiedAt .~ Just t) uid))
  ListUsers q -> liftIO (page q . Map.elems . (.users) <$> readIORef ref)
  where
    findByLoginId lid w = listToMaybe [u | u <- Map.elems w.users, u.loginId == lid]
    findByEmail e w = listToMaybe [u | u <- Map.elems w.users, u.email == Just e]

    -- The same newest-first keyset page the PostgreSQL statement produces, so the servant
    -- suite's pagination walk exercises identical semantics against the in-memory world.
    page q =
      take (clampUserLimit q.queryLimit)
        . filter (beforeCursor q.queryBefore)
        . filter (matchesStatus q.queryStatus)
        . sortOn (Down . userKey)

    userKey u = (u.createdAt, userIdToUUID u.userId)
    matchesStatus mst u = maybe True (== u.status) mst
    beforeCursor Nothing _ = True
    beforeCursor (Just c) u = userKey u < (c.cursorCreatedAt, userIdToUUID c.cursorUserId)

runCredentialStore :: (IOE :> es) => IORef World -> Eff (CredentialStore : es) a -> Eff es a
runCredentialStore ref = interpret_ \case
  CreatePasswordCredential uid lid mEmail h -> do
    cid <- genCredentialId
    w <- liftIO (readIORef ref)
    let c =
          PasswordCredential
            { credentialId = cid,
              userId = uid,
              loginId = lid,
              email = mEmail,
              passwordHash = h,
              createdAt = w.clock,
              updatedAt = w.clock
            }
    liftIO (modifyWorld ref (#credsByLoginId %~ Map.insert lid c))
    pure c
  FindPasswordCredentialByLoginId lid ->
    liftIO ((Map.lookup lid . (.credsByLoginId)) <$> readIORef ref)
  -- Retained reset-by-email path: a scan over the credential values (mirrors the user
  -- 'findByEmail' scan), matching the optional email metadata.
  FindPasswordCredentialByEmail e ->
    liftIO ((\w -> listToMaybe [c | c <- Map.elems w.credsByLoginId, c.email == Just e]) <$> readIORef ref)
  UpdatePasswordHash uid h ->
    liftIO
      ( modifyWorld
          ref
          (#credsByLoginId %~ Map.map (\c -> if c.userId == uid then c & #passwordHash .~ h else c))
      )

runSessionStore :: (IOE :> es) => IORef World -> Eff (SessionStore : es) a -> Eff es a
runSessionStore ref = interpret_ \case
  CreateSession ns -> do
    sid <- genSessionId
    let s = mkSession sid ns
    liftIO (modifyWorld ref (#sessions %~ Map.insert sid s))
    pure s
  FindSessionById sid -> liftIO ((Map.lookup sid . (.sessions)) <$> readIORef ref)
  RevokeSession sid t ->
    liftIO (modifyWorld ref (#sessions %~ Map.adjust (revoke t) sid))
  RevokeAllUserSessions uid t ->
    liftIO
      ( modifyWorld
          ref
          (#sessions %~ Map.map (\s -> if s.userId == uid then revoke t s else s))
      )
  ListSessionsForUser uid ->
    liftIO (sessionsOf uid <$> readIORef ref)
  where
    revoke t s = s & #status .~ SessionRevoked & #revokedAt .~ Just t
    sessionsOf uid w =
      sortOn (Down . \s -> (s.createdAt, sessionIdToUUID s.sessionId)) [s | s <- Map.elems w.sessions, s.userId == uid]

-- Build a fresh Session from a NewSession (kept separate to avoid a long inline record).
mkSession :: SessionId -> NewSession -> Session
mkSession sid ns =
  Session
    { sessionId = sid,
      userId = ns.userId,
      status = SessionActive,
      createdAt = ns.createdAt,
      expiresAt = ns.expiresAt,
      revokedAt = Nothing,
      actor = ns.actor,
      oauthClientId = ns.oauthClientId
    }

runRefreshTokenStore :: (IOE :> es) => IORef World -> Eff (RefreshTokenStore : es) a -> Eff es a
runRefreshTokenStore ref = interpret_ \case
  CreateRefreshToken nrt -> do
    rid <- genRefreshTokenId
    let prt = mkPersisted rid nrt
    liftIO
      ( modifyWorld
          ref
          ( (#refreshTokens %~ Map.insert rid prt)
              . (#refreshByHash %~ Map.insert nrt.tokenHash rid)
          )
      )
    pure prt
  FindRefreshTokenByHash h ->
    liftIO (lookupByHash h <$> readIORef ref)
  MarkRefreshTokenUsed rid t ->
    liftIO
      ( casWorld ref \w -> case Map.lookup rid w.refreshTokens of
          Just tok
            | tok.status == RefreshTokenActive ->
                Just (w & #refreshTokens %~ Map.adjust (markUsed t) rid)
          _ -> Nothing
      )
  RevokeRefreshTokenFamily rid t ->
    liftIO (modifyWorld ref (revokeFamily rid t))
  RevokeSessionRefreshTokens sid t ->
    liftIO
      ( modifyWorld
          ref
          (#refreshTokens %~ Map.map (\tok -> if tok.sessionId == sid then revoke t tok else tok))
      )
  RevokeAllUserRefreshTokens uid t ->
    liftIO
      ( modifyWorld
          ref
          ( \w ->
              w
                & #refreshTokens
                %~ Map.map
                  ( \tok ->
                      case Map.lookup tok.sessionId w.sessions of
                        Just s | s.userId == uid -> revoke t tok
                        _ -> tok
                  )
          )
      )
  where
    markUsed t tok = tok & #status .~ RefreshTokenUsed & #usedAt .~ Just t
    revoke t tok = tok & #status .~ RefreshTokenRevoked & #revokedAt .~ Just t
    lookupByHash h w = do
      rid <- Map.lookup h w.refreshByHash
      Map.lookup rid w.refreshTokens
    revokeFamily rid t w =
      let m = w.refreshTokens
          target = rootOf m rid
          m' = Map.map (\tok -> if rootOf m tok.refreshTokenId == target then revoke t tok else tok) m
       in w & #refreshTokens .~ m'

mkPersisted :: RefreshTokenId -> NewRefreshToken -> PersistedRefreshToken
mkPersisted rid nrt =
  PersistedRefreshToken
    { refreshTokenId = rid,
      sessionId = nrt.sessionId,
      tokenHash = nrt.tokenHash,
      parentTokenId = nrt.parentTokenId,
      status = RefreshTokenActive,
      createdAt = nrt.createdAt,
      expiresAt = nrt.expiresAt,
      usedAt = Nothing,
      revokedAt = Nothing
    }

-- | In-memory interpreter for the role registry, grant table, and permission definitions.
--
-- @DefineRole@, @GrantRole@, @AllowPermission@, and @DisallowPermission@ report whether they
-- changed anything, so a caller publishes an audit event only on a real state change. Re-defining
-- an existing role does not overwrite its description, matching the PostgreSQL @ON CONFLICT DO
-- NOTHING@; re-granting a role whose expiry differs updates the window (upsert) and reports a
-- change, matching the PostgreSQL @… IS DISTINCT FROM …@ guard; @ListRolesForUser@ filters
-- expired grants as of the supplied instant, exactly as the SQL @expires_at > $2@ does.
runRoleStore :: (IOE :> es) => IORef World -> Eff (RoleStore : es) a -> Eff es a
runRoleStore ref = interpret_ \case
  DefineRole r desc ts ->
    liftIO
      ( casWorld ref \w ->
          if Map.member r w.definedRoles
            then Nothing
            else Just (w & #definedRoles %~ Map.insert r (RoleDefinition r desc ts))
      )
  ListDefinedRoles ->
    liftIO (Map.elems . (.definedRoles) <$> readIORef ref)
  GrantRole uid r _by expiry _ts ->
    liftIO
      ( casWorld ref \w ->
          let held = Map.findWithDefault Map.empty uid w.roleGrants
           in -- Upsert: unchanged only when the role is already held with an identical expiry.
              -- 'insertWith Map.union' is left-biased toward the new singleton, so a differing
              -- expiry overwrites the old one — the in-memory analogue of the SQL upsert.
              if Map.lookup r held == Just expiry
                then Nothing
                else Just (w & #roleGrants %~ Map.insertWith Map.union uid (Map.singleton r expiry))
      )
  RevokeRole uid r ->
    liftIO
      ( casWorld ref \w ->
          if r `Map.member` Map.findWithDefault Map.empty uid w.roleGrants
            then Just (w & #roleGrants %~ Map.adjust (Map.delete r) uid)
            else Nothing
      )
  ListRolesForUser uid asOf ->
    liftIO (unexpired asOf . Map.findWithDefault Map.empty uid . (.roleGrants) <$> readIORef ref)
  AllowPermission r p _ts ->
    liftIO
      ( casWorld ref \w ->
          if p `Set.member` Map.findWithDefault Set.empty r w.rolePermissions
            then Nothing
            else Just (w & #rolePermissions %~ Map.insertWith Set.union r (Set.singleton p))
      )
  DisallowPermission r p ->
    liftIO
      ( casWorld ref \w ->
          if p `Set.member` Map.findWithDefault Set.empty r w.rolePermissions
            then Just (w & #rolePermissions %~ Map.adjust (Set.delete p) r)
            else Nothing
      )
  ListPermissionsForRole r ->
    liftIO (Map.findWithDefault Set.empty r . (.rolePermissions) <$> readIORef ref)
  PermissionsForRoles roles ->
    liftIO ((\w -> foldMap (\r -> Map.findWithDefault Set.empty r w.rolePermissions) (Set.toList roles)) <$> readIORef ref)
  where
    -- Keep the roles whose grant has not expired as of the instant (Nothing = forever).
    unexpired asOf = Map.keysSet . Map.filter (maybe True (> asOf))

-- | In-memory interpreter for the transactional unit-of-work port.
--
-- Where the PostgreSQL interpreter wraps its statements in @BEGIN … COMMIT@, this one applies
-- the whole multi-table update in a single 'atomicModifyIORef'' step, which is the in-memory
-- equivalent: no other green thread can observe a session without its refresh token, and the
-- rotation's compare-and-swap and its inserts land together or not at all. The concurrency
-- regression tests run these workflows from many threads and depend on exactly that.
--
-- 'publishedEvents' is newest-first, so a batch of events is prepended reversed: the last event
-- a workflow authors ends up at the head.
runAuthUnitOfWork :: (IOE :> es) => IORef World -> Eff (AuthUnitOfWork : es) a -> Eff es a
runAuthUnitOfWork ref = interpret_ \case
  PersistNewSession ns nst mkEvents -> do
    sid <- genSessionId
    rid <- genRefreshTokenId
    let session = mkSession sid ns
        newToken =
          NewRefreshToken
            { sessionId = sid,
              tokenHash = nst.tokenHash,
              parentTokenId = Nothing,
              createdAt = nst.createdAt,
              expiresAt = nst.expiresAt
            }
        persisted = mkPersisted rid newToken
        events = mkEvents sid
    liftIO
      ( modifyWorld
          ref
          ( (#sessions %~ Map.insert sid session)
              . (#refreshTokens %~ Map.insert rid persisted)
              . (#refreshByHash %~ Map.insert nst.tokenHash rid)
              . (#publishedEvents %~ (reverse events <>))
          )
      )
    pure (session, persisted)
  RotateRefreshToken presentedId usedAt newToken ev -> do
    rid <- genRefreshTokenId
    let persisted = mkPersisted rid newToken
    liftIO
      ( atomicModifyIORef' ref \w -> case Map.lookup presentedId w.refreshTokens of
          Just tok
            | tok.status == RefreshTokenActive ->
                ( w
                    & #refreshTokens
                    %~ (Map.insert rid persisted . Map.adjust (markUsed usedAt) presentedId)
                    & #refreshByHash
                    %~ Map.insert newToken.tokenHash rid
                    & #publishedEvents
                    %~ (ev :),
                  Rotated persisted
                )
          _ -> (w, RotationConflict)
      )
  where
    markUsed t tok = tok & #status .~ RefreshTokenUsed & #usedAt .~ Just t

runVerificationTokenStore :: (IOE :> es) => IORef World -> Eff (VerificationTokenStore : es) a -> Eff es a
runVerificationTokenStore ref = interpret_ \case
  CreateVerificationToken nvt -> do
    tid <- genVerificationTokenId
    let tok = mkVerificationToken tid nvt
    liftIO
      ( modifyWorld
          ref
          ( (#verificationTokens %~ Map.insert tid tok)
              . (#verificationByHash %~ Map.insert nvt.tokenHash tid)
          )
      )
    pure tok
  FindVerificationTokenByHash h ->
    liftIO (lookupVerification h <$> readIORef ref)
  MarkVerificationTokenConsumed tid t ->
    liftIO
      ( casWorld ref \w -> case Map.lookup tid w.verificationTokens of
          Just tok
            | tok.status == OneTimeTokenActive ->
                Just (w & #verificationTokens %~ Map.adjust (consume t) tid)
          _ -> Nothing
      )
  RevokeUserVerificationTokens uid t ->
    liftIO (modifyWorld ref (#verificationTokens %~ Map.map (\tok -> if tok.userId == uid then revoke t tok else tok)))
  where
    lookupVerification h w = do
      tid <- Map.lookup h w.verificationByHash
      Map.lookup tid w.verificationTokens
    consume t tok = tok & #status .~ OneTimeTokenConsumed & #consumedAt .~ Just t
    revoke t tok = tok & #status .~ OneTimeTokenRevoked & #revokedAt .~ Just t

mkVerificationToken :: VerificationTokenId -> NewVerificationToken -> PersistedVerificationToken
mkVerificationToken tid nvt =
  PersistedVerificationToken
    { verificationTokenId = tid,
      userId = nvt.userId,
      tokenHash = nvt.tokenHash,
      status = OneTimeTokenActive,
      createdAt = nvt.createdAt,
      expiresAt = nvt.expiresAt,
      consumedAt = Nothing,
      revokedAt = Nothing
    }

runPasswordResetTokenStore :: (IOE :> es) => IORef World -> Eff (PasswordResetTokenStore : es) a -> Eff es a
runPasswordResetTokenStore ref = interpret_ \case
  CreatePasswordResetToken nrt -> do
    tid <- genPasswordResetTokenId
    let tok = mkPasswordResetToken tid nrt
    liftIO
      ( modifyWorld
          ref
          ( (#passwordResetTokens %~ Map.insert tid tok)
              . (#passwordResetByHash %~ Map.insert nrt.tokenHash tid)
          )
      )
    pure tok
  FindPasswordResetTokenByHash h ->
    liftIO (lookupReset h <$> readIORef ref)
  MarkPasswordResetTokenConsumed tid t ->
    liftIO
      ( casWorld ref \w -> case Map.lookup tid w.passwordResetTokens of
          Just tok
            | tok.status == OneTimeTokenActive ->
                Just (w & #passwordResetTokens %~ Map.adjust (consume t) tid)
          _ -> Nothing
      )
  RevokeUserPasswordResetTokens uid t ->
    liftIO (modifyWorld ref (#passwordResetTokens %~ Map.map (\tok -> if tok.userId == uid then revoke t tok else tok)))
  where
    lookupReset h w = do
      tid <- Map.lookup h w.passwordResetByHash
      Map.lookup tid w.passwordResetTokens
    consume t tok = tok & #status .~ OneTimeTokenConsumed & #consumedAt .~ Just t
    revoke t tok = tok & #status .~ OneTimeTokenRevoked & #revokedAt .~ Just t

mkPasswordResetToken :: PasswordResetTokenId -> NewPasswordResetToken -> PersistedPasswordResetToken
mkPasswordResetToken tid nrt =
  PersistedPasswordResetToken
    { passwordResetTokenId = tid,
      userId = nrt.userId,
      tokenHash = nrt.tokenHash,
      status = OneTimeTokenActive,
      createdAt = nrt.createdAt,
      expiresAt = nrt.expiresAt,
      consumedAt = Nothing,
      revokedAt = Nothing
    }

runLoginAttemptStore :: (IOE :> es) => IORef World -> Eff (LoginAttemptStore : es) a -> Eff es a
runLoginAttemptStore ref = interpret_ \case
  RecordLoginAttempt na ->
    liftIO (modifyWorld ref (#loginAttempts %~ (toAttempt na :)))
  CountRecentFailuresByAccount k cutoff ->
    liftIO (countAccountFailures k cutoff <$> readIORef ref)
  CountRecentFailuresByIp ip cutoff ->
    liftIO (countWith (\a -> a.clientIp == ip) cutoff <$> readIORef ref)
  GetAccountLockout k ->
    liftIO ((Map.lookup k . (.accountLockouts)) <$> readIORef ref)
  SetAccountLockout lo ->
    liftIO (modifyWorld ref (#accountLockouts %~ Map.insert lo.accountKey lo))
  ClearAccountLockout k ->
    liftIO (modifyWorld ref (#accountLockouts %~ Map.delete k))
  where
    toAttempt na =
      LoginAttempt
        { accountKey = na.accountKey,
          clientIp = na.clientIp,
          outcome = na.outcome,
          occurredAt = na.occurredAt
        }
    -- Pure windowed failure count (used for the per-IP throttle).
    countWith p cutoff w =
      length
        [ a | a <- w.loginAttempts, p a, a.outcome == LoginFailure, a.occurredAt >= cutoff
        ]
    -- Per-account failures within the window AND strictly after the most recent success,
    -- so a successful login resets the account's brute-force progress (counter-reset-on-success)
    -- while the window still bounds the lookback.
    countAccountFailures k cutoff w =
      let successes =
            [ a.occurredAt | a <- w.loginAttempts, a.accountKey == k, a.outcome == LoginSuccess
            ]
          lastSuccess = if null successes then Nothing else Just (maximum successes)
          afterSuccess a = maybe True (\ls -> a.occurredAt > ls) lastSuccess
       in length
            [ a
            | a <- w.loginAttempts,
              a.accountKey == k,
              a.outcome == LoginFailure,
              a.occurredAt >= cutoff,
              afterSuccess a
            ]

-- | Field accessors for the EP-1 passkey records. 'OverloadedRecordDot' is unreliable
-- for these @DuplicateRecordFields@ records (MasterPlan 3 discovery), so read them with
-- plain record-pattern matching instead of @value.field@.
pkUserId :: PasskeyCredential -> UserId
pkUserId PasskeyCredential {userId} = userId

pkCredentialId :: PasskeyCredential -> WebAuthnCredentialId
pkCredentialId PasskeyCredential {credentialId} = credentialId

pkUserHandle :: PasskeyCredential -> UserHandle
pkUserHandle PasskeyCredential {userHandle} = userHandle

pcCeremonyId :: PendingCeremony -> CeremonyId
pcCeremonyId PendingCeremony {ceremonyId} = ceremonyId

pcExpiresAt :: PendingCeremony -> UTCTime
pcExpiresAt PendingCeremony {expiresAt} = expiresAt

runPasskeyStore :: (IOE :> es) => IORef World -> Eff (PasskeyStore : es) a -> Eff es a
runPasskeyStore ref = interpret_ \case
  CreatePasskey NewPasskeyCredential {userId, credentialId, userHandle, publicKey, signCounter, transports, label, createdAt} -> do
    pid <- genPasskeyId
    let pc =
          PasskeyCredential
            { passkeyId = pid,
              userId,
              credentialId,
              userHandle,
              publicKey,
              signCounter,
              transports,
              label,
              createdAt,
              lastUsedAt = Nothing
            }
    liftIO (modifyWorld ref (#passkeys %~ Map.insert pid pc))
    pure pc
  FindPasskeysByUser uid ->
    liftIO ((\w -> [p | p <- Map.elems w.passkeys, pkUserId p == uid]) <$> readIORef ref)
  FindPasskeyByCredentialId cid ->
    liftIO ((\w -> listToMaybe [p | p <- Map.elems w.passkeys, pkCredentialId p == cid]) <$> readIORef ref)
  FindPasskeysByUserHandle uh ->
    liftIO ((\w -> [p | p <- Map.elems w.passkeys, pkUserHandle p == uh]) <$> readIORef ref)
  UpdatePasskeySignCounter pid c t ->
    liftIO (modifyWorld ref (#passkeys %~ Map.adjust (\p -> p & #signCounter .~ c & #lastUsedAt .~ Just t) pid))
  DeletePasskey uid pid ->
    liftIO (modifyWorld ref (#passkeys %~ Map.update (\p -> if pkUserId p == uid then Nothing else Just p) pid))
  CountPasskeysByUser uid ->
    liftIO ((\w -> length [p | p <- Map.elems w.passkeys, pkUserId p == uid]) <$> readIORef ref)

runPendingCeremonyStore :: (IOE :> es) => IORef World -> Eff (PendingCeremonyStore : es) a -> Eff es a
runPendingCeremonyStore ref = interpret_ \case
  PutPendingCeremony pc ->
    liftIO (modifyWorld ref (#pendingCeremonies %~ Map.insert (pcCeremonyId pc) pc))
  TakePendingCeremony cid now' -> liftIO do
    w <- readIORef ref
    case Map.lookup cid w.pendingCeremonies of
      Nothing -> pure Nothing
      Just pc -> do
        -- Consume-once: remove the row regardless, so an expired take also
        -- clears the stale row; return it only if it is still live.
        modifyWorld ref (#pendingCeremonies %~ Map.delete cid)
        pure (if pcExpiresAt pc > now' then Just pc else Nothing)
  DeleteExpiredCeremonies now' ->
    liftIO (modifyWorld ref (#pendingCeremonies %~ Map.filter (\pc -> pcExpiresAt pc > now')))

-- | Field accessors for the EP-4 service-account records. Both 'ServiceAccount' and
-- 'NewServiceAccount' share field names with several other domain records, so read them with
-- plain record-pattern matching rather than @value.field@ (the same 'DuplicateRecordFields'
-- caution the passkey accessors above document).
saId :: ServiceAccount -> ServiceAccountDbId
saId ServiceAccount {serviceAccountId} = serviceAccountId

saClientId :: ServiceAccount -> Text
saClientId ServiceAccount {clientId} = clientId

saCreatedAt :: ServiceAccount -> UTCTime
saCreatedAt ServiceAccount {createdAt} = createdAt

-- | In-memory interpreter for the EP-4 service-account store.
--
-- 'RotateServiceAccountSecret' and 'RevokeServiceAccount' are silent no-ops on an unknown id,
-- matching the PostgreSQL @UPDATE … WHERE service_account_id = $1@ that affects zero rows: the
-- CLI resolves the account by client id before mutating, so an unknown id cannot arise from the
-- tested path.
runServiceAccountStore :: (IOE :> es) => IORef World -> Eff (ServiceAccountStore : es) a -> Eff es a
runServiceAccountStore ref = interpret_ \case
  CreateServiceAccount NewServiceAccount {serviceAccountId, clientId, userId, secretHash, displayName, allowedScopes, createdAt} -> do
    let sa =
          ServiceAccount
            { serviceAccountId,
              clientId,
              userId,
              secretHash,
              displayName,
              allowedScopes,
              status = ServiceAccountActive,
              createdAt,
              rotatedAt = Nothing,
              revokedAt = Nothing
            }
    liftIO (modifyWorld ref (#serviceAccounts %~ Map.insert serviceAccountId sa))
    pure sa
  FindServiceAccountByClientId cid ->
    liftIO ((\w -> listToMaybe [sa | sa <- Map.elems w.serviceAccounts, saClientId sa == cid]) <$> readIORef ref)
  ListServiceAccounts ->
    liftIO (sortOn (Down . \sa -> (saCreatedAt sa, idText (saId sa))) . Map.elems . (.serviceAccounts) <$> readIORef ref)
  RotateServiceAccountSecret sid h t ->
    liftIO (modifyWorld ref (#serviceAccounts %~ Map.adjust (\sa -> sa & #secretHash .~ h & #rotatedAt .~ Just t) sid))
  RevokeServiceAccount sid t ->
    liftIO
      ( modifyWorld
          ref
          (#serviceAccounts %~ Map.adjust (\sa -> sa & #status .~ ServiceAccountRevoked & #revokedAt .~ Just t) sid)
      )

-- | Field accessors for the EP-5 OAuth-client records, for the same 'DuplicateRecordFields'
-- reason as the service-account accessors above: 'OAuthClient' shares @clientId@, @status@,
-- @createdAt@, @displayName@, @secretHash@ and @revokedAt@ with 'ServiceAccount'.
ocId :: OAuthClient -> OAuthClientId
ocId OAuthClient {oauthClientId} = oauthClientId

ocClientId :: OAuthClient -> Text
ocClientId OAuthClient {clientId} = clientId

ocCreatedAt :: OAuthClient -> UTCTime
ocCreatedAt OAuthClient {createdAt} = createdAt

-- | In-memory interpreter for the EP-5 OAuth-client store.
--
-- 'RevokeOAuthClient' is a silent no-op on an unknown id, matching the PostgreSQL
-- @UPDATE … WHERE oauth_client_id = $1@ that affects zero rows.
runOAuthClientStore :: (IOE :> es) => IORef World -> Eff (OAuthClientStore : es) a -> Eff es a
runOAuthClientStore ref = interpret_ \case
  CreateOAuthClient NewOAuthClient {oauthClientId, clientId, secretHash, clientType, displayName, redirectUris, allowedScopes, createdAt} -> do
    let oc =
          OAuthClient
            { oauthClientId,
              clientId,
              secretHash,
              clientType,
              displayName,
              redirectUris,
              allowedScopes,
              status = OAuthClientActive,
              createdAt,
              revokedAt = Nothing
            }
    liftIO (modifyWorld ref (#oauthClients %~ Map.insert oauthClientId oc))
    pure oc
  FindOAuthClientByClientId cid ->
    liftIO ((\w -> listToMaybe [oc | oc <- Map.elems w.oauthClients, ocClientId oc == cid]) <$> readIORef ref)
  ListOAuthClients ->
    liftIO (sortOn (Down . \oc -> (ocCreatedAt oc, idText (ocId oc))) . Map.elems . (.oauthClients) <$> readIORef ref)
  RevokeOAuthClient cid t ->
    liftIO
      ( modifyWorld
          ref
          (#oauthClients %~ Map.adjust (\oc -> oc & #status .~ OAuthClientRevoked & #revokedAt .~ Just t) cid)
      )

-- | Field accessors for the EP-5 authorization-code records ('AuthorizationCode' shares
-- @clientId@ / @createdAt@ / @expiresAt@ / @userId@ / @scopes@ with several other domain records).
acCodeHash :: AuthorizationCode -> Text
acCodeHash AuthorizationCode {codeHash} = codeHash

acExpiresAt :: AuthorizationCode -> UTCTime
acExpiresAt AuthorizationCode {expiresAt} = expiresAt

acConsumedAt :: AuthorizationCode -> Maybe UTCTime
acConsumedAt AuthorizationCode {consumedAt} = consumedAt

-- | In-memory interpreter for the EP-5 authorization-code store.
--
-- 'ConsumeAuthorizationCode' is a single 'modifyWorld', which 'atomicModifyIORef'' makes atomic —
-- the in-memory analogue of PostgreSQL's @UPDATE … WHERE consumed_at IS NULL … RETURNING@. Of two
-- racing consumes of one code, exactly one sees an unconsumed row.
runOAuthCodeStore :: (IOE :> es) => IORef World -> Eff (OAuthCodeStore : es) a -> Eff es a
runOAuthCodeStore ref = interpret_ \case
  PutAuthorizationCode NewAuthorizationCode {codeHash, clientId, redirectUri, userId, scopes, nonce, codeChallenge, authTime, createdAt, expiresAt} -> do
    let code =
          AuthorizationCode
            { codeHash,
              clientId,
              redirectUri,
              userId,
              scopes,
              nonce,
              codeChallenge,
              authTime,
              createdAt,
              expiresAt,
              consumedAt = Nothing
            }
    liftIO (modifyWorld ref (#oauthCodes %~ Map.insert codeHash code))
  ConsumeAuthorizationCode h t ->
    liftIO
      ( atomicModifyIORef' ref \w ->
          case Map.lookup h w.oauthCodes of
            Just code
              | isNothing (acConsumedAt code),
                acExpiresAt code > t ->
                  -- Set through a generic-lens label: @consumedAt@ is shared with the one-time
                  -- token records, so a plain record update on it is ambiguous.
                  let consumed = code & #consumedAt .~ Just t
                   in (w {oauthCodes = Map.insert h consumed w.oauthCodes}, Just consumed)
            -- Unknown, already consumed, or expired: one indistinguishable miss.
            _ -> (w, Nothing)
      )
  DeleteExpiredAuthorizationCodes t ->
    liftIO (modifyWorld ref (#oauthCodes %~ Map.filter (\c -> acExpiresAt c > t)))

-- | Field accessors for the EP-7 TOTP records ('TotpCredential' shares @userId@ / @createdAt@ /
-- @secret@ with other domain records; the 'DuplicateRecordFields' caution applies).
tcId :: TotpCredential -> TotpCredentialId
tcId TotpCredential {totpCredentialId} = totpCredentialId

tcUserId :: TotpCredential -> UserId
tcUserId TotpCredential {userId} = userId

-- | In-memory interpreter for the EP-7 TOTP credential store.
--
-- Keyed by user id, so 'UpsertTotpEnrollment' replaces any existing (unconfirmed) row exactly as
-- the PostgreSQL @ON CONFLICT (user_id) DO UPDATE@ does. Raw secrets are held as-is; the
-- encryption boundary is PostgreSQL-only (Decision Log).
runTotpCredentialStore :: (IOE :> es) => IORef World -> Eff (TotpCredentialStore : es) a -> Eff es a
runTotpCredentialStore ref = interpret_ \case
  UpsertTotpEnrollment NewTotpCredential {totpCredentialId, userId, secret, createdAt} -> do
    let tc =
          TotpCredential
            { totpCredentialId,
              userId,
              secret,
              lastUsedCounter = Nothing,
              confirmedAt = Nothing,
              createdAt
            }
    liftIO (modifyWorld ref (#totpCredentials %~ Map.insert userId tc))
    pure tc
  FindTotpByUser uid ->
    liftIO ((Map.lookup uid . (.totpCredentials)) <$> readIORef ref)
  ConfirmTotp tcid t ->
    liftIO (modifyWorld ref (#totpCredentials %~ Map.map (\c -> if tcId c == tcid then c & #confirmedAt .~ Just t else c)))
  SetTotpLastUsedCounter tcid c ->
    liftIO (modifyWorld ref (#totpCredentials %~ Map.map (\x -> if tcId x == tcid then x & #lastUsedCounter .~ Just c else x)))
  DeleteTotpByUser uid ->
    liftIO (modifyWorld ref (#totpCredentials %~ Map.delete uid))

-- | Field accessors for the EP-7 recovery-code records.
rcId :: RecoveryCode -> RecoveryCodeId
rcId RecoveryCode {recoveryCodeId} = recoveryCodeId

rcUserId :: RecoveryCode -> UserId
rcUserId RecoveryCode {userId} = userId

rcCodeHash :: RecoveryCode -> Text
rcCodeHash RecoveryCode {codeHash} = codeHash

rcUsedAt :: RecoveryCode -> Maybe UTCTime
rcUsedAt RecoveryCode {usedAt} = usedAt

-- | In-memory interpreter for the EP-7 recovery-code store.
--
-- 'ConsumeRecoveryCode' is a single 'casWorld' (atomic), the in-memory analogue of PostgreSQL's
-- @UPDATE … WHERE used_at IS NULL RETURNING@: of two racing consumes of one code, exactly one
-- sees it unused. 'ReplaceRecoveryCodes' drops the user's whole set and inserts the new one.
runRecoveryCodeStore :: (IOE :> es) => IORef World -> Eff (RecoveryCodeStore : es) a -> Eff es a
runRecoveryCodeStore ref = interpret_ \case
  ReplaceRecoveryCodes uid newCodes -> liftIO do
    let fresh =
          [ ( nc.recoveryCodeId,
              RecoveryCode
                { recoveryCodeId = nc.recoveryCodeId,
                  userId = uid,
                  codeHash = nc.codeHash,
                  createdAt = nc.createdAt,
                  usedAt = Nothing
                }
            )
          | nc <- newCodes
          ]
    modifyWorld
      ref
      (#recoveryCodes %~ (\m -> Map.union (Map.fromList fresh) (Map.filter (\rc -> rcUserId rc /= uid) m)))
  ConsumeRecoveryCode uid h t ->
    liftIO
      ( casWorld ref \w ->
          case listToMaybe [rc | rc <- Map.elems w.recoveryCodes, rcUserId rc == uid, rcCodeHash rc == h, isNothing (rcUsedAt rc)] of
            Just rc -> Just (w & #recoveryCodes %~ Map.adjust (#usedAt .~ Just t) (rcId rc))
            Nothing -> Nothing
      )
  CountUnusedRecoveryCodes uid ->
    liftIO ((\w -> length [rc | rc <- Map.elems w.recoveryCodes, rcUserId rc == uid, isNothing (rcUsedAt rc)]) <$> readIORef ref)

runPasswordHasher :: IORef World -> Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasher _ref = interpret_ \case
  HashPassword (PlainPassword pw) -> pure (PasswordHash ("argon2-fake:" <> pw))
  VerifyPassword (PlainPassword pw) (PasswordHash h) -> pure (h == "argon2-fake:" <> pw)
  -- The fake does no work, so there is none to burn. Only the real Argon2 interpreter needs
  -- this operation to cost anything.
  VerifyPasswordDummy _ -> pure ()

-- | EP-3 in-memory breach-checker fake: a password is 'Breached' iff its plaintext is in the
-- 'World''s @breachedPasswords@ set; when @breachCheckAvailable@ is False it returns
-- 'BreachCheckUnavailable' so tests can exercise the fail-open/fail-closed policy branches.
runPasswordBreachCheckerFake :: (IOE :> es) => IORef World -> Eff (PasswordBreachChecker : es) a -> Eff es a
runPasswordBreachCheckerFake ref = interpret_ \case
  CheckPasswordBreached (PlainPassword pw) -> liftIO do
    w <- readIORef ref
    pure
      if not w.breachCheckAvailable
        then BreachCheckUnavailable
        else if Set.member pw w.breachedPasswords then Breached else NotBreached

runTokenSigner :: Eff (TokenSigner : es) a -> Eff es a
runTokenSigner = interpret_ \case
  SignAccessToken claims -> pure (AccessToken (renderClaims claims))
  -- The fake ID token is the claims as JSON, as the fake access token is. It does not round-trip
  -- through 'runTokenVerifier': nothing verifies an ID token server-side (the client does).
  SignIdToken idc -> pure (IdToken (TL.toStrict (TLE.decodeUtf8 (encode (renderIdTokenClaims idc)))))

-- | The fake ID token's payload: the same claim names the real @jose@ signer emits, so a test can
-- assert on them without a JWT library.
renderIdTokenClaims :: IdTokenClaims -> Value
renderIdTokenClaims idc =
  object
    ( [ ("iss", Aeson.String (issuerText idc.issuer)),
        ("sub", Aeson.String (idText idc.subject)),
        ("aud", Aeson.String idc.audience),
        ("auth_time", Aeson.toJSON (floor (utcTimeToPOSIXSeconds idc.authTime) :: Integer))
      ]
        <> foldMap (\n -> [("nonce", Aeson.String n)]) idc.nonce
    )
  where
    issuerText (Issuer t) = t

runTokenVerifier :: Eff (TokenVerifier : es) a -> Eff es a
runTokenVerifier = interpret_ \case
  VerifyAccessToken (AccessToken t) -> pure (parseClaims t)

runAuthEventPublisher :: (IOE :> es) => IORef World -> Eff (AuthEventPublisher : es) a -> Eff es a
runAuthEventPublisher ref = interpret_ \case
  PublishAuthEvent ev -> liftIO (modifyWorld ref (#publishedEvents %~ (ev :)))

-- | In-memory mirror of 'Shomei.Postgres.AuthEventReader.runAuthEventReaderPostgres' over the
-- 'World''s @publishedEvents@ log. Each event is projected with the shared
-- 'Shomei.Domain.EventCodec.projectAuthEvent' (the same mapping the writer uses) and assigned a
-- synthetic, insertion-ordered @event_id@ so the @(created_at, event_id)@ keyset is stable and
-- monotone with insertion. Filters, newest-first ordering, the @before@ cursor, and the limit
-- clamp all match the SQL interpreter; 'CountAuthEvents' applies the filters only (no
-- cursor/limit), as the SQL @COUNT@ does.
runAuthEventReader :: (IOE :> es) => IORef World -> Eff (AuthEventReader : es) a -> Eff es a
runAuthEventReader ref = interpret_ \case
  QueryAuthEvents q -> liftIO (queryRows q <$> readIORef ref)
  CountAuthEvents q -> liftIO (length . filterRows q . allRows <$> readIORef ref)
  where
    -- Oldest-first index → synthetic event_id, so a later insert sorts after an earlier one.
    allRows :: World -> [StoredAuthEvent]
    allRows w = zipWith toStored [0 ..] (reverse w.publishedEvents)
    toStored :: Int -> Event.AuthEvent -> StoredAuthEvent
    toStored i ev =
      let (uid, sid, etype, payload, occ) = projectAuthEvent ev
       in StoredAuthEvent
            { storedEventId = UUID.fromWords 0 0 0 (fromIntegral i),
              storedEventType = etype,
              storedUserId = uid,
              storedSessionId = sid,
              storedCreatedAt = occ,
              storedPayload = payload
            }
    filterRows :: AuditEventQuery -> [StoredAuthEvent] -> [StoredAuthEvent]
    filterRows q =
      filter \r ->
        maybe True (\u -> r.storedUserId == Just u) q.queryUserId
          && maybe True (\s -> r.storedSessionId == Just s) q.querySessionId
          && (null q.queryEventTypes || r.storedEventType `elem` q.queryEventTypes)
          && maybe True (\s -> r.storedCreatedAt >= s) q.querySince
          && maybe True (\u -> r.storedCreatedAt < u) q.queryUntil
    queryRows :: AuditEventQuery -> World -> [StoredAuthEvent]
    queryRows q w =
      let base = filterRows q (allRows w)
          afterCursor = case q.queryBefore of
            Nothing -> base
            Just (AuditCursor t e) -> filter (\r -> (r.storedCreatedAt, r.storedEventId) < (t, e)) base
          ordered = sortBy (comparing (Down . sortKey)) afterCursor
       in take (clampLimit q.queryLimit) ordered
    sortKey r = (r.storedCreatedAt, r.storedEventId)

runNotifier :: (IOE :> es) => IORef World -> Eff (Notifier : es) a -> Eff es a
runNotifier ref = interpret_ \case
  SendNotification n -> liftIO (modifyWorld ref (#sentNotifications %~ (n :)))

runSigningKeyStore :: (IOE :> es) => IORef World -> Eff (SigningKeyStore : es) a -> Eff es a
runSigningKeyStore ref = interpret_ \case
  ListActiveSigningKeys ->
    liftIO (activeKeys <$> readIORef ref)
  ListPublishableSigningKeys ->
    liftIO (publishableKeys <$> readIORef ref)
  FindSigningKeyByKid kid ->
    liftIO ((Map.lookup kid . (.signingKeys)) <$> readIORef ref)
  InsertSigningKey k ->
    liftIO (modifyWorld ref (#signingKeys %~ Map.insert k.keyId k))
  UpdateSigningKeyStatus kid st _t ->
    liftIO (modifyWorld ref (#signingKeys %~ Map.adjust (#status .~ st) kid))
  where
    activeKeys w = [k | k <- Map.elems w.signingKeys, k.status == KeyActive]
    publishableKeys w = [k | k <- Map.elems w.signingKeys, k.status `elem` [KeyActive, KeyRetired]]

runClock :: (IOE :> es) => IORef World -> Eff (Clock : es) a -> Eff es a
runClock ref = interpret_ \case
  Now -> liftIO ((.clock) <$> readIORef ref)

runTokenGen :: (IOE :> es) => IORef World -> Eff (TokenGen : es) a -> Eff es a
runTokenGen ref = interpret_ \case
  GenerateOpaqueToken -> liftIO do
    w <- readIORef ref
    let n = w.tokenCounter
    writeIORef ref (w & #tokenCounter .~ (n + 1))
    pure (RefreshToken ("rt-" <> Text.pack (show n)))
  HashRefreshToken (RefreshToken t) -> pure (RefreshTokenHash ("hash:" <> t))
  -- Deterministic pseudo-random bytes: varied within a call and distinct across calls (the
  -- counter advances), so ten recovery codes drawn in a row differ. Never used for real secrecy.
  GenerateRandomBytes n -> liftIO do
    w <- readIORef ref
    let c = w.tokenCounter
    writeIORef ref (w & #tokenCounter .~ (c + 1))
    pure (BS.pack [fromIntegral ((c * 131 + i * 17 + 7) `mod` 256) | i <- [0 .. n - 1]])

-- | A deterministic, cryptography-free fake of 'WebAuthnCeremony' for tests
-- (EP-3/EP-4 drive their workflows through this without a real authenticator).
--
-- The contract a test must follow:
--
--   * A /begin/ step ('BeginRegistrationCeremony' / 'BeginAuthenticationCeremony')
--     returns a 'BeginCeremony' whose @optionsJson@ is the canned object
--     @{ "challenge": "ceremony-challenge-N" }@ (N from a per-'World' counter) and
--     whose @optionsBlob@ is the UTF-8 'Data.Aeson.encode' of that same object, so the
--     blob and the JSON always agree on the challenge.
--
--   * To complete, the test crafts a credential 'Value' echoing the blob's challenge
--     plus the credential fields it wants verified — an object with keys
--     @challenge@ (matching the begin step), and base64url-without-padding strings
--     @credentialId@, @userHandle@, @publicKey@. 'CompleteRegistrationCeremony'
--     succeeds with those fields and @signCounter = 0@ when the challenges match,
--     else returns @Left WebAuthnChallengeMismatch@ (or @Left WebAuthnDecodeError@ for
--     malformed JSON).
--
--   * 'CompleteAuthenticationCeremony' additionally requires the crafted
--     @credentialId@ to equal the @StoredCredentialForVerify@'s; on success it returns
--     @newSignCounter = stored + 1@ and @cloneWarning = False@, on a credential-id
--     mismatch @Left WebAuthnSignatureInvalid@, on a challenge mismatch
--     @Left WebAuthnChallengeMismatch@.
runWebAuthnCeremonyFake :: (IOE :> es) => IORef World -> Eff (WebAuthnCeremony : es) a -> Eff es a
runWebAuthnCeremonyFake ref = interpret_ \case
  BeginRegistrationCeremony _userInfo _exclude -> liftIO (mkCannedCeremony ref)
  BeginAuthenticationCeremony _allow -> liftIO (mkCannedCeremony ref)
  CompleteRegistrationCeremony blob credJson -> pure (fakeCompleteRegistration blob credJson)
  CompleteAuthenticationCeremony blob stored credJson ->
    pure (fakeCompleteAuthentication blob stored credJson)

-- Build a canned begin result with a deterministic, counter-derived challenge.
mkCannedCeremony :: IORef World -> IO BeginCeremony
mkCannedCeremony ref = do
  w <- readIORef ref
  let n = w.ceremonyCounter
  writeIORef ref (w & #ceremonyCounter .~ (n + 1))
  let chal = "ceremony-challenge-" <> Text.pack (show n)
      optionsJson = object ["challenge" Aeson..= chal]
  pure BeginCeremony {optionsJson, optionsBlob = LBS.toStrict (encode optionsJson)}

-- The challenge baked into a begin step's options blob.
blobChallenge :: ByteString -> Maybe Text
blobChallenge blob = case eitherDecodeStrict' blob of
  Right v -> parseMaybe (withObject "options" (.: "challenge")) v
  Left _ -> Nothing

-- Parse the test-crafted credential JSON into (challenge, credentialId, userHandle, publicKey).
credentialFields :: Value -> Parser (Text, WebAuthnCredentialId, UserHandle, PublicKeyBytes)
credentialFields = withObject "credential" $ \o ->
  (,,,) <$> o .: "challenge" <*> o .: "credentialId" <*> o .: "userHandle" <*> o .: "publicKey"

fakeCompleteRegistration :: ByteString -> Value -> Either WebAuthnError VerifiedRegistration
fakeCompleteRegistration blob credJson =
  case parseMaybe credentialFields credJson of
    Nothing -> Left (WebAuthnDecodeError "fake: malformed credential JSON")
    Just (chal, cid, uh, pk)
      | blobChallenge blob == Just chal ->
          Right
            VerifiedRegistration
              { credentialId = cid,
                userHandle = uh,
                publicKey = pk,
                signCounter = SignatureCounter 0,
                transports = []
              }
      | otherwise -> Left WebAuthnChallengeMismatch

fakeCompleteAuthentication ::
  ByteString -> StoredCredentialForVerify -> Value -> Either WebAuthnError VerifiedAuthentication
fakeCompleteAuthentication blob StoredCredentialForVerify {credentialId = storedCid, signCounter = SignatureCounter n} credJson =
  case parseMaybe credentialFields credJson of
    Nothing -> Left (WebAuthnDecodeError "fake: malformed credential JSON")
    Just (chal, cid, _uh, _pk)
      | blobChallenge blob /= Just chal -> Left WebAuthnChallengeMismatch
      | storedCid /= cid -> Left WebAuthnSignatureInvalid
      | otherwise ->
          Right
            VerifiedAuthentication
              { credentialId = storedCid,
                newSignCounter = SignatureCounter (n + 1),
                cloneWarning = False
              }

-- | Run an 'Eff' computation that uses every port against a shared in-memory 'World', with no
-- claims enrichment. See 'runInMemoryWith' to supply a host hook.
runInMemory :: IORef World -> Eff InMemoryPorts a -> IO a
runInMemory = runInMemoryWith (\_ _ -> emptyClaimsDelta)

-- | The effect list 'runInMemory' provides, in the order 'Shomei.Servant.Seam.AppEffects'
-- fixes. (Named so the servant/core test harnesses can restate it without drift.)
type InMemoryPorts =
  [ UserStore,
    RoleStore,
    CredentialStore,
    SessionStore,
    RefreshTokenStore,
    AuthUnitOfWork,
    VerificationTokenStore,
    PasswordResetTokenStore,
    LoginAttemptStore,
    PasskeyStore,
    PendingCeremonyStore,
    ServiceAccountStore,
    OAuthClientStore,
    OAuthCodeStore,
    TotpCredentialStore,
    RecoveryCodeStore,
    Notifier,
    ClaimsEnricher,
    WebAuthnCeremony,
    PasswordBreachChecker,
    PasswordHasher,
    TokenSigner,
    TokenVerifier,
    AuthEventPublisher,
    SigningKeyStore,
    Clock,
    TokenGen,
    IOE
  ]

-- | 'runInMemory' with a caller-supplied 'ClaimsEnricher' hook, for tests (and embedding-host
-- experiments) that need to observe what a host delta does to minted claims.
runInMemoryWith :: (UserId -> Set Role -> ClaimsDelta) -> IORef World -> Eff InMemoryPorts a -> IO a
runInMemoryWith enrich ref =
  runEff
    . runTokenGen ref
    . runClock ref
    . runSigningKeyStore ref
    . runAuthEventPublisher ref
    . runTokenVerifier
    . runTokenSigner
    . runPasswordHasher ref
    . runPasswordBreachCheckerFake ref
    . runWebAuthnCeremonyFake ref
    . runClaimsEnricherPure enrich
    . runNotifier ref
    . runRecoveryCodeStore ref
    . runTotpCredentialStore ref
    . runOAuthCodeStore ref
    . runOAuthClientStore ref
    . runServiceAccountStore ref
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
