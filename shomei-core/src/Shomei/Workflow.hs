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
import Shomei.Config (RateLimitConfig (..), SessionCheckMode (..), ShomeiConfig (..), WebAuthnConfig (..))
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
import Shomei.Effect.PasswordBreachChecker (PasswordBreachChecker)
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPassword)
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore)
import Shomei.Effect.RefreshTokenStore
  ( RefreshTokenStore,
    createRefreshToken,
    findRefreshTokenByHash,
    markRefreshTokenUsed,
    revokeRefreshTokenFamily,
    revokeSessionRefreshTokens,
  )
import Shomei.Effect.SessionStore (SessionStore, createSession, findSessionById, revokeSession)
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
import Shomei.Workflow.Session (buildClaims, issueSession)

-- | The WebAuthn step-up challenge handed back when an account with a passkey logs in with
-- the correct password and @mfaRequired@ is on. 'ceremonyId' is the consume-once pending-MFA
-- handle the client echoes to 'Shomei.Workflow.Mfa.completeMfa'; 'options' is the
-- @navigator.credentials.get()@ options the browser runs.
data MfaChallenge = MfaChallenge
  { ceremonyId :: !CeremonyId,
    options :: !Value
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
    SessionStore :> es,
    RefreshTokenStore :> es,
    PasswordHasher :> es,
    PasswordBreachChecker :> es,
    TokenSigner :> es,
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
  session <-
    createSession
      NewSession
        { userId = user.userId,
          createdAt = ts,
          expiresAt = addUTCTime cfg.sessionTTL ts,
          actor = Nothing
        }
  rawToken <- generateOpaqueToken
  tokHash <- hashRefreshToken rawToken
  _ <-
    createRefreshToken
      NewRefreshToken
        { sessionId = session.sessionId,
          tokenHash = tokHash,
          parentTokenId = Nothing,
          createdAt = ts,
          expiresAt = addUTCTime cfg.refreshTokenTTL ts
        }
  access <- signAccessToken (buildClaims cfg user.userId session.sessionId ts)
  publishAuthEvent (Event.UserRegistered (Event.UserRegisteredData user.userId cmd.loginId cmd.email ts))
  publishAuthEvent (Event.SessionStarted (Event.SessionStartedData session.sessionId user.userId ts))
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
    SessionStore :> es,
    RefreshTokenStore :> es,
    PasswordHasher :> es,
    TokenSigner :> es,
    AuthEventPublisher :> es,
    LoginAttemptStore :> es,
    PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
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
  when rl.rateLimitEnabled do
    ipFails <- countRecentFailuresByIp ctx.clientIp cutoff
    when (ipFails >= rl.maxFailedLoginsPerIp) do
      publishAuthEvent (Event.LoginThrottled (Event.LoginThrottledData ctx.clientIp ipFails ts))
      throwError TooManyRequests
    -- Account lockout: a still-locked account returns the SAME generic error as a wrong
    -- password (never 'AccountLocked'), so a locked account is indistinguishable.
    mLock <- getAccountLockout ctx.accountKey
    when (maybe False (\lo -> maybe False (> ts) lo.lockedUntil) mLock) (throwError InvalidCredentials)
  mCred <- findPasswordCredentialByLoginId cmd.loginId
  cred <- maybe (failLogin rl ctx cmd.loginId ts) pure mCred
  mUser <- findUserById cred.userId
  user <- maybe (failLogin rl ctx cmd.loginId ts) pure mUser
  when (user.status /= UserActive) (throwError UserNotActive)
  ok <- verifyPassword cmd.password cred.passwordHash
  unless ok (failLogin rl ctx cmd.loginId ts)
  recordLoginAttempt
    NewLoginAttempt
      { accountKey = ctx.accountKey,
        clientIp = ctx.clientIp,
        outcome = LoginSuccess,
        occurredAt = ts
      }
  clearAccountLockout ctx.accountKey
  -- The password factor succeeded; success is recorded and the lockout cleared above,
  -- regardless of whether a second factor is then demanded (so an attacker who guesses the
  -- password but cannot pass MFA cannot lock out the legitimate user). NOW branch: if the
  -- account has a passkey and MFA is required, return a challenge WITHOUT a token; otherwise
  -- mint the session inline as before.
  passkeyCount <- countPasskeysByUser user.userId
  if mfaRequired (webauthnConfig cfg) && passkeyCount > 0
    then do
      (cid, optionsJson) <- prepareMfaChallenge cfg user ts
      pure (MfaRequired MfaChallenge {ceremonyId = cid, options = optionsJson})
    else do
      (_sid, pair) <- issueSession cfg user ts
      pure (LoginComplete user pair)

-- | The shared failure path for 'login': record the failed attempt, publish 'LoginFailed',
-- lock the account if the windowed per-account failure budget is now exhausted, then throw the
-- generic 'InvalidCredentials'. Both the unknown-account branch and the wrong-password branch
-- call this so they remain byte-for-byte identical at the boundary.
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
    TokenSigner :> es,
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
                markRefreshTokenUsed tok.refreshTokenId ts
                rawNew <- generateOpaqueToken
                newHash <- hashRefreshToken rawNew
                _ <-
                  createRefreshToken
                    NewRefreshToken
                      { sessionId = tok.sessionId,
                        tokenHash = newHash,
                        parentTokenId = Just tok.refreshTokenId,
                        createdAt = ts,
                        -- Never mint a token that outlives its session.
                        expiresAt = min (addUTCTime cfg.refreshTokenTTL ts) s.expiresAt
                      }
                access <- signAccessToken (buildClaims cfg s.userId s.sessionId ts)
                publishAuthEvent
                  (Event.RefreshTokenRotated (Event.RefreshTokenRotatedData tok.sessionId tok.refreshTokenId ts))
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
      publishAuthEvent (Event.SessionRevoked (Event.SessionRevokedData sid ts))
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
