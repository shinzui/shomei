-- | The authentication workflows, written purely against the port effects.
--
-- These five functions are the behavioral heart of Shōmei: 'signup', 'login', 'refresh'
-- (rotation with reuse detection), 'logout', and 'verifyToken'. They contain the rules of
-- the system and no infrastructure — every external capability is a port effect, so the
-- same workflows run against the in-memory interpreter (tests, here) and the real
-- PostgreSQL + JWT interpreters (EP-3/EP-4/EP-6).
--
-- 'signup' and 'login' use a local 'Effectful.Error.Static' 'Error' effect to
-- short-circuit on the first 'AuthError'; 'refresh'/'logout'/'verifyToken' return
-- @Either AuthError@ directly via explicit case analysis (the rotation logic reads more
-- clearly that way). The 'Shomei.Audit.Event.Domain' module is imported qualified and its values
-- are built positionally, because several of its constructors deliberately share names
-- with 'AuthError' constructors.
module Shomei.Session.Authentication.Workflow
  ( signup,
    login,
    refresh,
    refreshFrom,
    logout,
    verifyToken,
    verifyTokenWith,
    LoginResult (..),
    MfaChallenge (..),
    Refreshed (..),
    issueSession,
  )
where

import Data.Aeson (Value)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shomei.Account.Credential.Domain (Credential (..))
import Shomei.Account.Credential.Store (CredentialStore, createPasswordCredential, findPasswordCredentialByLoginId)
import Shomei.Account.Email.Domain (emailText)
import Shomei.Account.LoginId.Domain (LoginId)
import Shomei.Account.Password.Breach.Store (PasswordBreachChecker)
import Shomei.Account.Password.Breach.Workflow (enforceBreachPolicy)
import Shomei.Account.Password.Domain (PasswordContext (..), validatePassword)
import Shomei.Account.Password.Hash.Store (PasswordHasher, hashPassword, verifyPassword, verifyPasswordDummy)
import Shomei.Account.User.Domain (NewUser (..), User (..), UserStatus (UserActive))
import Shomei.Account.User.Store (UserStore, createUser, findUserById, findUserByLoginId)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Authorization.Claims.Domain (AuthClaims (..), Scope)
import Shomei.Authorization.Claims.Store (ClaimsEnricher)
import Shomei.Authorization.Role.Store (RoleStore)
import Shomei.Authorization.Role.Workflow (applyDefaultRoles)
import Shomei.Config (MfaConfig (..), NotifierConfig (..), RateLimitConfig (..), SessionCheckMode (..), ShomeiConfig (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (CeremonyId)
import Shomei.Mfa.RecoveryCode.Store (RecoveryCodeStore)
import Shomei.Mfa.Totp.Domain (isTotpConfirmed)
import Shomei.Mfa.Totp.Store (TotpCredentialStore, findTotpByUser)
import Shomei.Mfa.Workflow (prepareMfaChallenge)
import Shomei.Passkey.Ceremony.Port (WebAuthnCeremony)
import Shomei.Passkey.Ceremony.Store (PendingCeremonyStore)
import Shomei.Passkey.Store (PasskeyStore, countPasskeysByUser)
import Shomei.Prelude
import Shomei.Session.Command (ClientContext (..), LoginCommand (..), LogoutCommand (..), RefreshCommand (..), RefreshOrigin (..), SignupCommand (..))
import Shomei.Session.Domain (NewSession (..), Session (..), SessionKind (InteractiveSession), SessionStatus (SessionActive))
import Shomei.Session.LoginAttempt.Domain (AttemptFactor (FactorPassword))
import Shomei.Session.LoginAttempt.Store (LoginAttemptStore)
import Shomei.Session.LoginAttempt.Workflow
  ( AbuseGate (..),
    guardAbuse,
    recordProofFailure,
    recordProofSuccess,
  )
import Shomei.Session.RefreshToken.Domain (NewRefreshToken (..), PersistedRefreshToken (..))
import Shomei.Session.RefreshToken.Domain qualified as RT
import Shomei.Session.RefreshToken.Store
  ( RefreshTokenStore,
    findRefreshTokenByHash,
    revokeRefreshTokenFamily,
    revokeSessionRefreshTokens,
  )
import Shomei.Session.Store (SessionStore, findSessionById, revokeSession)
import Shomei.Session.Token.Domain (AccessToken, TokenPair (..))
import Shomei.Session.Token.Generator (TokenGen, generateOpaqueToken, hashRefreshToken)
import Shomei.Session.UnitOfWork.Store
  ( AuthUnitOfWork,
    NewSessionToken (..),
    RotationOutcome (..),
    persistNewSession,
    rotateRefreshToken,
  )
import Shomei.Session.Workflow (buildEnrichedClaims, ensureEmailVerified, issueSession, requireLiveSession)
import Shomei.SigningKey.Signer (TokenSigner, signAccessToken)
import Shomei.SigningKey.Verifier (TokenVerifier, verifyAccessToken)
import Shomei.Time.Store (Clock, now)

-- | The step-up challenge handed back when an account with any enrolled second factor logs in
-- with the correct password and second-factor policy is on. 'ceremonyId' is the consume-once
-- pending-MFA handle the client echoes to 'Shomei.Mfa.Workflow.completeMfa'; 'options' is the
-- @navigator.credentials.get()@ options the browser runs (the empty object @{}@ for a TOTP-only
-- user, who has no WebAuthn ceremony); 'methods' advertises which factors can complete it
-- (@"passkey"@, @"totp"@, @"recovery_code"@).
data MfaChallenge = MfaChallenge
  { ceremonyId :: !CeremonyId,
    options :: !Value,
    methods :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

-- | The outcome of 'login'. 'LoginComplete' contains the user and tokens and is returned
-- unchanged for accounts with no second factor or with the MFA policy off. 'MfaRequired' means the
-- password was correct but a second factor is now demanded; NO token is issued yet.
data LoginResult
  = LoginComplete User TokenPair
  | MfaRequired MfaChallenge
  deriving stock (Generic, Eq, Show)

signup ::
  ( UserStore :> es,
    CredentialStore :> es,
    AuthUnitOfWork :> es,
    PasswordHasher :> es,
    PasswordBreachChecker :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    -- 'applyDefaultRoles' audits each grant it makes. Note that this workflow's own
    -- UserRegistered/SessionStarted events go through 'persistNewSession' (inside its
    -- transaction) instead, which is why signup carried no publisher constraint before.
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
  ) =>
  ShomeiConfig ->
  SignupCommand ->
  Eff es (Either AuthError (User, TokenPair))
signup cfg cmd = runErrorNoCallStack do
  let pwContext =
        PasswordContext
          { contextEmail = emailText <$> cmd.email,
            contextDisplayName = cmd.displayName
          }
  either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy pwContext cmd.password)
  enforceBreachPolicy cfg.passwordPolicy cmd.password
  existing <- findUserByLoginId cmd.loginId
  when (isJust existing) (throwError LoginIdAlreadyRegistered)
  pwHash <- hashPassword cmd.password
  ts <- now
  user <- createUser NewUser {loginId = cmd.loginId, email = cmd.email, displayName = cmd.displayName}
  _ <- createPasswordCredential user.userId cmd.loginId cmd.email pwHash
  -- Before the session (and therefore before the first token is minted), so the very first
  -- access token already carries the configured default roles.
  applyDefaultRoles cfg user.userId ts
  rawToken <- generateOpaqueToken
  tokHash <- hashRefreshToken rawToken
  -- Session row, refresh-token row, and both audit events in one transaction: a crash here
  -- leaves the new user with no session rather than a session with no token.
  (session, _token) <-
    persistNewSession
      NewSession
        { userId = user.userId,
          createdAt = ts,
          expiresAt = addUTCTime cfg.sessionTTL ts,
          actor = Nothing,
          oauthClientId = Nothing,
          kind = InteractiveSession,
          grantedScopes = Set.empty,
          authenticatedAt = ts
        }
      NewSessionToken
        { tokenHash = tokHash,
          createdAt = ts,
          expiresAt = addUTCTime cfg.refreshTokenTTL ts
        }
      \sid ->
        [ Event.UserRegistered (Event.UserRegisteredData user.userId cmd.loginId cmd.email ts),
          Event.SessionStarted (Event.SessionStartedData sid user.userId ts)
        ]
  access <- signAccessToken =<< buildEnrichedClaims cfg user.userId session.sessionId ts
  pure
    ( user,
      TokenPair {accessToken = access, refreshToken = rawToken, expiresIn = cfg.accessTokenTTL}
    )

-- | Authenticate a login-id/password pair, with EP-2 abuse protection layered on the
-- existing generic-error contract. Before verifying the password the workflow consults the
-- per-IP failure budget and the per-account lockout state; every failure path records an
-- attempt and, once the per-account budget is exhausted within the window, locks the account
-- for the configured cooldown. To preserve the no-leak guarantee, a wrong password, an unknown
-- account, and a locked account all return the single generic 'InvalidCredentials'; only the
-- per-IP throttle returns the IP-keyed 'TooManyRequests' (which discloses nothing about which
-- accounts exist). A successful login records a success and clears the lockout.
--
-- The caller supplies a 'ClientContext' carrying the request's source IP and the precomputed
-- hashed account key for the presented login identifier, so the core needs no crypto dependency
-- and the abuse store never holds a plaintext principal.
login ::
  ( UserStore :> es,
    CredentialStore :> es,
    AuthUnitOfWork :> es,
    PasswordHasher :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    AuthEventPublisher :> es,
    LoginAttemptStore :> es,
    PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    TotpCredentialStore :> es,
    RecoveryCodeStore :> es,
    Clock :> es,
    TokenGen :> es,
    IOE :> es
  ) =>
  ShomeiConfig ->
  ClientContext ->
  LoginCommand ->
  Eff es (Either AuthError LoginResult)
login cfg ctx cmd = runErrorNoCallStack do
  ts <- now
  let rl = cfg.rateLimitConfig
  gate <- guardAbuse rl ctx ts
  -- A locked account is still charged one Argon2id verification. Returning before hashing made
  -- lock state observable through response time even though the HTTP error stayed generic.
  when gate.locked do
    verifyPasswordDummy cmd.password
    throwError InvalidCredentials
  -- Every failure path below performs exactly one password-hashing operation. The paths that
  -- never reach a stored hash call 'verifyPasswordDummy' instead, which burns an equivalent
  -- amount of Argon2id work, so a miss cannot be told apart from a wrong password by response
  -- time.
  mCred <- findPasswordCredentialByLoginId cmd.loginId
  cred <- maybe (failLoginTimed rl ctx cmd ts) pure mCred
  mUser <- findUserById cred.userId
  user <- maybe (failLoginTimed rl ctx cmd ts) pure mUser
  when (user.status /= UserActive) do
    verifyPasswordDummy cmd.password
    recordProofFailure rl ctx FactorPassword ts
    publishAuthEvent (Event.LoginFailed (Event.LoginFailedData cmd.loginId ts))
    throwError UserNotActive
  ok <- verifyPassword cmd.password cred.passwordHash
  unless ok (failLogin rl ctx cmd.loginId ts)
  -- Gate before the MFA branch, so an account with an unverified email is not even offered a
  -- ceremony. The password was already proven correct here, so naming the reason discloses
  -- nothing the caller does not know (see 'EmailNotVerified').
  either throwError pure (ensureEmailVerified cfg user)
  -- A password that leads to MFA is not yet a successful login: recording success here would let
  -- every password proof reset the counter immediately before another second-factor guess.
  passkeyCount <- countPasskeysByUser user.userId
  totpEnrolled <- maybe False isTotpConfirmed <$> findTotpByUser user.userId
  let hasSecondFactor = passkeyCount > 0 || totpEnrolled
  if requireSecondFactor (mfaConfig cfg) && hasSecondFactor
    then do
      (cid, optionsJson, methods) <- prepareMfaChallenge cfg user ts
      pure (MfaRequired MfaChallenge {ceremonyId = cid, options = optionsJson, methods = methods})
    else do
      recordProofSuccess ctx FactorPassword gate.standingLockout ts
      (_sid, pair) <- issueSession cfg user ts
      pure (LoginComplete user pair)

-- | 'failLogin' preceded by a dummy Argon2id verification, for the login paths that fail
-- before ever reaching a stored password hash: an unknown login identifier, and a credential
-- row whose user row is missing. Without the dummy work these return in microseconds while a
-- wrong password costs ~100 ms, which enumerates accounts through the identical @401@.
failLoginTimed ::
  ( LoginAttemptStore :> es,
    AuthEventPublisher :> es,
    PasswordHasher :> es,
    Error AuthError :> es
  ) =>
  RateLimitConfig ->
  ClientContext ->
  LoginCommand ->
  UTCTime ->
  Eff es a
failLoginTimed rl ctx cmd ts = do
  verifyPasswordDummy cmd.password
  failLogin rl ctx cmd.loginId ts

-- | The shared failure path for 'login': record the failed attempt, publish 'LoginFailed',
-- lock the account if the windowed per-account failure budget is now exhausted, then throw the
-- generic 'InvalidCredentials'. Both the unknown-account branch and the wrong-password branch
-- reach this so they remain byte-for-byte identical at the boundary.
failLogin ::
  ( LoginAttemptStore :> es,
    AuthEventPublisher :> es,
    Error AuthError :> es
  ) =>
  RateLimitConfig ->
  ClientContext ->
  LoginId ->
  UTCTime ->
  Eff es a
failLogin rl ctx loginId ts = do
  recordProofFailure rl ctx FactorPassword ts
  publishAuthEvent (Event.LoginFailed (Event.LoginFailedData loginId ts))
  throwError InvalidCredentials

data Refreshed = Refreshed
  { tokens :: !TokenPair,
    -- | the session's persisted OAuth grant; empty for sessions no OAuth client minted.
    grantedScopes :: !(Set Scope)
  }
  deriving stock (Generic, Show)

refresh ::
  ( SessionStore :> es,
    RefreshTokenStore :> es,
    AuthUnitOfWork :> es,
    -- only consulted when 'emailVerificationRequired' is enabled
    UserStore :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
  ) =>
  ShomeiConfig ->
  RefreshCommand ->
  Eff es (Either AuthError TokenPair)
refresh cfg cmd = fmap (.tokens) <$> refreshFrom BespokeRefresh cfg cmd

refreshFrom ::
  ( SessionStore :> es,
    RefreshTokenStore :> es,
    AuthUnitOfWork :> es,
    UserStore :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
  ) =>
  RefreshOrigin ->
  ShomeiConfig ->
  RefreshCommand ->
  Eff es (Either AuthError Refreshed)
refreshFrom origin cfg cmd = do
  ts <- now
  tokHash <- hashRefreshToken cmd.refreshToken
  mTok <- findRefreshTokenByHash tokHash
  case mTok of
    Nothing -> pure (Left RefreshTokenInvalid)
    Just tok -> case tok.status of
      RT.RefreshTokenUsed -> reuseDetected tok ts
      RT.RefreshTokenRevoked -> reuseDetected tok ts
      RT.RefreshTokenExpired -> pure (Left RefreshTokenExpired)
      RT.RefreshTokenActive -> do
        mSession <- findSessionById tok.sessionId
        case mSession of
          Nothing -> pure (Left SessionNotFound)
          Just s
            | not (originMayRefresh origin s) -> pure (Left RefreshTokenInvalid)
            -- The session's absolute deadline is checked before the presented token's own
            -- expiry: rotation caps every child token at 's.expiresAt', so at the deadline
            -- both are expired and 'SessionExpired' ("log in again") is the informative one.
            | s.expiresAt <= ts -> pure (Left SessionExpired)
            | s.status /= SessionActive -> pure (Left SessionRevoked)
            | tok.expiresAt <= ts -> pure (Left RefreshTokenExpired)
            | otherwise -> do
                -- The emailVerificationRequired gate, before rotation: a silent renewal must
                -- not keep an unverified account alive past its first access-token lifetime.
                -- The user row is loaded ONLY when the flag is on — refresh otherwise never
                -- touches the user table, and most deployments leave the flag off.
                gate <-
                  if cfg.notifierConfig.emailVerificationRequired
                    then do
                      mUser <- findUserById s.userId
                      -- A session whose user row is gone is corrupt state; SessionNotFound is
                      -- the existing least-leaking fit.
                      pure (maybe (Left SessionNotFound) (ensureEmailVerified cfg) mUser)
                    else pure (Right ())
                case gate of
                  Left e -> pure (Left e)
                  Right () -> do
                    rawNew <- generateOpaqueToken
                    newHash <- hashRefreshToken rawNew
                    -- One transaction: the compare-and-swap that transitions this token
                    -- active → used, the insert of its replacement, and the rotation event.
                    -- Only the caller that wins the swap may rotate; losing the race means
                    -- someone else has already spent the token, which is indistinguishable
                    -- from theft — so take the reuse path. A conflict inserts nothing, and the
                    -- token is never re-read to "confirm" it.
                    outcome <-
                      rotateRefreshToken
                        tok.refreshTokenId
                        ts
                        NewRefreshToken
                          { sessionId = tok.sessionId,
                            tokenHash = newHash,
                            parentTokenId = Just tok.refreshTokenId,
                            createdAt = ts,
                            -- Never mint a token that outlives its session.
                            expiresAt = min (addUTCTime cfg.refreshTokenTTL ts) s.expiresAt
                          }
                        (Event.RefreshTokenRotated (Event.RefreshTokenRotatedData tok.sessionId tok.refreshTokenId ts))
                    case outcome of
                      RotationConflict -> reuseDetected tok ts
                      Rotated _ -> do
                        -- Re-running the enrichment here is what makes a role change take
                        -- effect on refresh (the staleness contract in docs/user/security.md).
                        base <- buildEnrichedClaims cfg s.userId s.sessionId ts
                        let claims = base {scopes = base.scopes <> s.grantedScopes, authTime = s.authenticatedAt}
                        access <- signAccessToken claims
                        pure
                          ( Right
                              Refreshed
                                { tokens = TokenPair {accessToken = access, refreshToken = rawNew, expiresIn = cfg.accessTokenTTL},
                                  grantedScopes = s.grantedScopes
                                }
                          )
  where
    reuseDetected tok ts = do
      revokeRefreshTokenFamily tok.refreshTokenId ts
      revokeSession tok.sessionId ts
      publishAuthEvent
        (Event.RefreshTokenReuseDetected (Event.RefreshTokenReuseDetectedData tok.sessionId tok.refreshTokenId ts))
      pure (Left RefreshTokenReuseDetected)

originMayRefresh :: RefreshOrigin -> Session -> Bool
originMayRefresh BespokeRefresh session = isNothing session.oauthClientId
originMayRefresh (OAuthClientRefresh clientId) session = session.oauthClientId == Just clientId

logout ::
  ( SessionStore :> es,
    RefreshTokenStore :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  LogoutCommand ->
  Eff es (Either AuthError ())
logout _cfg cmd = do
  ts <- now
  let sid = cmd.sessionId
  mSession <- findSessionById sid
  case mSession of
    Nothing -> pure (Left SessionNotFound)
    Just _ -> do
      revokeSession sid ts
      revokeSessionRefreshTokens sid ts
      -- Self-service logout: no administrator revoked this session.
      publishAuthEvent (Event.SessionRevoked (Event.SessionRevokedData sid Nothing ts))
      pure (Right ())

verifyToken ::
  (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
  ShomeiConfig ->
  AccessToken ->
  Eff es (Either AuthError AuthClaims)
verifyToken cfg = verifyTokenWith cfg.sessionCheckMode

-- | Verify a token under an explicit session-check policy. Privilege-minting callers use
-- 'VerifyTokenAndSession' even when ordinary route authentication remains stateless.
verifyTokenWith ::
  (TokenVerifier :> es, SessionStore :> es, Clock :> es) =>
  SessionCheckMode ->
  AccessToken ->
  Eff es (Either AuthError AuthClaims)
verifyTokenWith mode token = do
  result <- verifyAccessToken token
  case result of
    Left te -> pure (Left (TokenInvalid te))
    Right claims -> case mode of
      VerifyTokenOnly -> pure (Right claims)
      VerifyTokenAndSession -> do
        ts <- now
        fmap (const claims) <$> requireLiveSession ts claims.sessionId
