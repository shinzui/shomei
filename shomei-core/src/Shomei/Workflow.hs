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
-- clearly that way). The 'Shomei.Domain.Event' module is imported qualified and its values
-- are built positionally, because several of its constructors deliberately share names
-- with 'AuthError' constructors.
module Shomei.Workflow
  ( signup,
    login,
    refresh,
    logout,
    verifyToken,
    LoginResult (..),
    MfaChallenge (..),
    issueSession,
  )
where

import Data.Aeson (Value)
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shomei.Config (NotifierConfig (..), RateLimitConfig (..), SessionCheckMode (..), ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Domain.Command (ClientContext (..), LoginCommand (..), LogoutCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (emailText)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt
  ( AccountLockout (..),
    LoginOutcome (..),
    NewLoginAttempt (..),
  )
import Shomei.Domain.LoginId (LoginId)
import Shomei.Domain.Password (PasswordContext (..), validatePassword)
import Shomei.Domain.RefreshToken (NewRefreshToken (..), PersistedRefreshToken (..))
import Shomei.Domain.RefreshToken qualified as RT
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (SessionActive))
import Shomei.Domain.Token (AccessToken, TokenPair (..))
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.AuthUnitOfWork
  ( AuthUnitOfWork,
    NewSessionToken (..),
    RotationOutcome (..),
    persistNewSession,
    rotateRefreshToken,
  )
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.CredentialStore (CredentialStore, createPasswordCredential, findPasswordCredentialByLoginId)
import Shomei.Effect.LoginAttemptStore
  ( LoginAttemptStore,
    clearAccountLockout,
    countRecentFailuresByAccount,
    countRecentFailuresByIp,
    getAccountLockout,
    recordLoginAttempt,
    setAccountLockout,
  )
import Shomei.Effect.PasskeyStore (PasskeyStore, countPasskeysByUser)
import Shomei.Effect.RecoveryCodeStore (RecoveryCodeStore)
import Shomei.Domain.Totp (isTotpConfirmed)
import Shomei.Effect.TotpCredentialStore (TotpCredentialStore, findTotpByUser)
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPassword, verifyPasswordDummy)
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore)
import Shomei.Effect.RefreshTokenStore
  ( RefreshTokenStore,
    findRefreshTokenByHash,
    revokeRefreshTokenFamily,
    revokeSessionRefreshTokens,
  )
import Shomei.Effect.RoleStore (RoleStore)
import Shomei.Effect.SessionStore (SessionStore, findSessionById, revokeSession)
import Shomei.Effect.TokenGen (TokenGen, generateOpaqueToken, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner, signAccessToken)
import Shomei.Effect.TokenVerifier (TokenVerifier, verifyAccessToken)
import Shomei.Effect.UserStore (UserStore, createUser, findUserById, findUserByLoginId)
import Shomei.Effect.WebAuthnCeremony (WebAuthnCeremony)
import Shomei.Error (AuthError (..))
import Shomei.Id (CeremonyId)
import Shomei.Prelude
import Shomei.Workflow.Breach (enforceBreachPolicy)
import Shomei.Workflow.Mfa (prepareMfaChallenge)
import Shomei.Workflow.Roles (applyDefaultRoles)
import Shomei.Workflow.Session (buildEnrichedClaims, ensureEmailVerified, issueSession)

-- | The step-up challenge handed back when an account with any enrolled second factor logs in
-- with the correct password and @mfaRequired@ is on. 'ceremonyId' is the consume-once
-- pending-MFA handle the client echoes to 'Shomei.Workflow.Mfa.completeMfa'; 'options' is the
-- @navigator.credentials.get()@ options the browser runs (the empty object @{}@ for a TOTP-only
-- user, who has no WebAuthn ceremony); 'methods' advertises which factors can complete it
-- (@"passkey"@, @"totp"@, @"recovery_code"@).
data MfaChallenge = MfaChallenge
  { ceremonyId :: !CeremonyId,
    options :: !Value,
    methods :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

-- | The outcome of 'login'. 'LoginComplete' is the legacy success (user + tokens), returned
-- unchanged for accounts with no passkey or with @mfaRequired@ off. 'MfaRequired' means the
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
          oauthClientId = Nothing
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
      cutoff = addUTCTime (negate rl.lockoutWindow) ts
  -- Per-IP throttle first: a read-only, account-agnostic gate that leaks nothing. We do
  -- NOT record a new attempt here (that would let an attacker keep themselves throttled).
  --
  -- The lockout row this reads is carried to the success path below, which clears it only when
  -- one actually exists. When rate limiting is off no lockout can exist — only the rate-limited
  -- failure path ever writes one — so 'Nothing' is correct for that branch too.
  mLock <-
    if rl.rateLimitEnabled
      then do
        ipFails <- countRecentFailuresByIp ctx.clientIp cutoff
        when (ipFails >= rl.maxFailedLoginsPerIp) do
          publishAuthEvent (Event.LoginThrottled (Event.LoginThrottledData ctx.clientIp ipFails ts))
          throwError TooManyRequests
        -- Account lockout: a still-locked account returns the SAME generic error as a wrong
        -- password (never 'AccountLocked'), so a locked account is indistinguishable.
        lockRow <- getAccountLockout ctx.accountKey
        when (maybe False (\lo -> maybe False (> ts) lo.lockedUntil) lockRow) (throwError InvalidCredentials)
        pure lockRow
      else pure Nothing
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
    throwError UserNotActive
  ok <- verifyPassword cmd.password cred.passwordHash
  unless ok (failLogin rl ctx cmd.loginId ts)
  recordLoginAttempt
    NewLoginAttempt
      { accountKey = ctx.accountKey,
        clientIp = ctx.clientIp,
        outcome = LoginSuccess,
        occurredAt = ts
      }
  -- Only delete a lockout row that the read above actually found. Lockouts are rare, so the
  -- unconditional DELETE this replaces cost a wasted round-trip on virtually every login. A row
  -- whose 'lockedUntil' has already passed is still cleared, exactly as before.
  when (isJust mLock) (clearAccountLockout ctx.accountKey)
  -- Gate before the MFA branch, so an account with an unverified email is not even offered a
  -- ceremony. The password was already proven correct here, so naming the reason discloses
  -- nothing the caller does not know (see 'EmailNotVerified').
  either throwError pure (ensureEmailVerified cfg user)
  -- The password factor succeeded; success is recorded and the lockout cleared above,
  -- regardless of whether a second factor is then demanded (so an attacker who guesses the
  -- password but cannot pass MFA cannot lock out the legitimate user). NOW branch: if the
  -- account has a passkey and MFA is required, return a challenge WITHOUT a token; otherwise
  -- mint the session inline as before.
  passkeyCount <- countPasskeysByUser user.userId
  totpEnrolled <- maybe False isTotpConfirmed <$> findTotpByUser user.userId
  let hasSecondFactor = passkeyCount > 0 || totpEnrolled
  if mfaRequired (webauthnConfig cfg) && hasSecondFactor
    then do
      (cid, optionsJson, methods) <- prepareMfaChallenge cfg user ts
      pure (MfaRequired MfaChallenge {ceremonyId = cid, options = optionsJson, methods = methods})
    else do
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
  recordLoginAttempt
    NewLoginAttempt
      { accountKey = ctx.accountKey,
        clientIp = ctx.clientIp,
        outcome = LoginFailure,
        occurredAt = ts
      }
  publishAuthEvent (Event.LoginFailed (Event.LoginFailedData loginId ts))
  when rl.rateLimitEnabled do
    let cutoff = addUTCTime (negate rl.lockoutWindow) ts
    acctFails <- countRecentFailuresByAccount ctx.accountKey cutoff
    when (acctFails >= rl.maxFailedLoginsPerAccount) do
      let lockedUntil = addUTCTime rl.lockoutDuration ts
      setAccountLockout (AccountLockout ctx.accountKey acctFails (Just lockedUntil) ts)
      publishAuthEvent
        (Event.AccountLocked (Event.AccountLockedData ctx.accountKey ctx.clientIp acctFails lockedUntil ts))
  throwError InvalidCredentials

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
refresh cfg cmd = do
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
                        access <- signAccessToken =<< buildEnrichedClaims cfg s.userId s.sessionId ts
                        pure
                          ( Right
                              TokenPair {accessToken = access, refreshToken = rawNew, expiresIn = cfg.accessTokenTTL}
                          )
  where
    reuseDetected tok ts = do
      revokeRefreshTokenFamily tok.refreshTokenId ts
      revokeSession tok.sessionId ts
      publishAuthEvent
        (Event.RefreshTokenReuseDetected (Event.RefreshTokenReuseDetectedData tok.sessionId tok.refreshTokenId ts))
      pure (Left RefreshTokenReuseDetected)

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
verifyToken cfg token = do
  result <- verifyAccessToken token
  case result of
    Left te -> pure (Left (TokenInvalid te))
    Right claims -> case cfg.sessionCheckMode of
      VerifyTokenOnly -> pure (Right claims)
      VerifyTokenAndSession -> do
        ts <- now
        mSession <- findSessionById claims.sessionId
        case mSession of
          Nothing -> pure (Left SessionNotFound)
          Just s
            | s.expiresAt <= ts -> pure (Left SessionExpired)
            | s.status /= SessionActive -> pure (Left SessionRevoked)
            | otherwise -> pure (Right claims)
