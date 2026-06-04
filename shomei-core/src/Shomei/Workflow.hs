{- | The authentication workflows, written purely against the port effects.

These five functions are the behavioral heart of Shōmei: 'signup', 'login', 'refresh'
(rotation with reuse detection), 'logout', and 'verifyToken'. They contain the rules of
the system and no infrastructure — every external capability is a port effect, so the
same workflows run against the in-memory interpreter (tests, here) and the real
PostgreSQL + JWT interpreters (EP-3/EP-4/EP-6).

'signup' and 'login' use a local 'Effectful.Error.Static' 'Error' effect to
short-circuit on the first 'AuthError'; 'refresh'/'logout'/'verifyToken' return
@Either AuthError@ directly via explicit case analysis (the rotation logic reads more
clearly that way). The 'Shomei.Domain.Event' module is imported qualified and its values
are built positionally, because several of its constructors deliberately share names
with 'AuthError' constructors.
-}
module Shomei.Workflow (
    signup,
    login,
    refresh,
    logout,
    verifyToken,
) where

import Shomei.Prelude

import Data.Set qualified as Set
import Data.Time (addUTCTime)

import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)

import Shomei.Config (SessionCheckMode (..), ShomeiConfig (..))
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Domain.Command (LoginCommand (..), LogoutCommand (..), RefreshCommand (..), SignupCommand (..))
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Email (emailText, mkEmail)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Password (validatePassword)
import Shomei.Domain.RefreshToken (NewRefreshToken (..), PersistedRefreshToken (..))
import Shomei.Domain.RefreshToken qualified as RT
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (SessionActive))
import Shomei.Domain.Token (AccessToken, TokenPair (..))
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (UserActive))
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.CredentialStore (CredentialStore, createPasswordCredential, findPasswordCredentialByEmail)
import Shomei.Effect.PasswordHasher (PasswordHasher, hashPassword, verifyPassword)
import Shomei.Effect.RefreshTokenStore (
    RefreshTokenStore,
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
import Shomei.Effect.UserStore (UserStore, createUser, findUserByEmail, findUserById)

{- | Build the access-token claims for a freshly-authenticated session. The MVP issues no
scopes or roles.
-}
buildClaims :: ShomeiConfig -> UserId -> SessionId -> UTCTime -> AuthClaims
buildClaims cfg uid sid ts =
    AuthClaims
        { subject = uid
        , sessionId = sid
        , issuer = cfg.issuer
        , audience = cfg.audience
        , issuedAt = ts
        , expiresAt = addUTCTime cfg.accessTokenTTL ts
        , scopes = Set.empty
        , roles = Set.empty
        }

signup ::
    ( UserStore :> es
    , CredentialStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasswordHasher :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    SignupCommand ->
    Eff es (Either AuthError (User, TokenPair))
signup cfg cmd = runErrorNoCallStack do
    email <- either throwError pure (mkEmail (emailText cmd.email))
    either (throwError . WeakPassword) pure (validatePassword cfg.passwordPolicy cmd.password)
    existing <- findUserByEmail email
    when (isJust existing) (throwError EmailAlreadyRegistered)
    pwHash <- hashPassword cmd.password
    ts <- now
    user <- createUser NewUser{email = email, displayName = cmd.displayName}
    _ <- createPasswordCredential user.userId email pwHash
    session <-
        createSession
            NewSession
                { userId = user.userId
                , createdAt = ts
                , expiresAt = addUTCTime cfg.sessionTTL ts
                }
    rawToken <- generateOpaqueToken
    tokHash <- hashRefreshToken rawToken
    _ <-
        createRefreshToken
            NewRefreshToken
                { sessionId = session.sessionId
                , tokenHash = tokHash
                , parentTokenId = Nothing
                , createdAt = ts
                , expiresAt = addUTCTime cfg.refreshTokenTTL ts
                }
    access <- signAccessToken (buildClaims cfg user.userId session.sessionId ts)
    publishAuthEvent (Event.UserRegistered (Event.UserRegisteredData user.userId email ts))
    publishAuthEvent (Event.SessionStarted (Event.SessionStartedData session.sessionId user.userId ts))
    pure
        ( user
        , TokenPair{accessToken = access, refreshToken = rawToken, expiresIn = cfg.accessTokenTTL}
        )

login ::
    ( UserStore :> es
    , CredentialStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasswordHasher :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    LoginCommand ->
    Eff es (Either AuthError (User, TokenPair))
login cfg cmd = runErrorNoCallStack do
    mCred <- findPasswordCredentialByEmail cmd.email
    cred <- maybe (throwError InvalidCredentials) pure mCred
    mUser <- findUserById cred.userId
    user <- maybe (throwError InvalidCredentials) pure mUser
    when (user.status /= UserActive) (throwError UserNotActive)
    ok <- verifyPassword cmd.password cred.passwordHash
    ts <- now
    unless ok do
        publishAuthEvent (Event.LoginFailed (Event.LoginFailedData cmd.email ts))
        throwError InvalidCredentials
    session <-
        createSession
            NewSession
                { userId = user.userId
                , createdAt = ts
                , expiresAt = addUTCTime cfg.sessionTTL ts
                }
    rawToken <- generateOpaqueToken
    tokHash <- hashRefreshToken rawToken
    _ <-
        createRefreshToken
            NewRefreshToken
                { sessionId = session.sessionId
                , tokenHash = tokHash
                , parentTokenId = Nothing
                , createdAt = ts
                , expiresAt = addUTCTime cfg.refreshTokenTTL ts
                }
    access <- signAccessToken (buildClaims cfg user.userId session.sessionId ts)
    publishAuthEvent (Event.LoginSucceeded (Event.LoginSucceededData user.userId session.sessionId ts))
    publishAuthEvent (Event.SessionStarted (Event.SessionStartedData session.sessionId user.userId ts))
    pure
        ( user
        , TokenPair{accessToken = access, refreshToken = rawToken, expiresIn = cfg.accessTokenTTL}
        )

refresh ::
    ( SessionStore :> es
    , RefreshTokenStore :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
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
            RT.RefreshTokenActive
                | tok.expiresAt <= ts -> pure (Left RefreshTokenExpired)
                | otherwise -> do
                    mSession <- findSessionById tok.sessionId
                    case mSession of
                        Nothing -> pure (Left SessionNotFound)
                        Just s
                            | s.status /= SessionActive -> pure (Left SessionRevoked)
                            | otherwise -> do
                                markRefreshTokenUsed tok.refreshTokenId ts
                                rawNew <- generateOpaqueToken
                                newHash <- hashRefreshToken rawNew
                                _ <-
                                    createRefreshToken
                                        NewRefreshToken
                                            { sessionId = tok.sessionId
                                            , tokenHash = newHash
                                            , parentTokenId = Just tok.refreshTokenId
                                            , createdAt = ts
                                            , expiresAt = addUTCTime cfg.refreshTokenTTL ts
                                            }
                                access <- signAccessToken (buildClaims cfg s.userId s.sessionId ts)
                                publishAuthEvent
                                    (Event.RefreshTokenRotated (Event.RefreshTokenRotatedData tok.sessionId tok.refreshTokenId ts))
                                pure
                                    ( Right
                                        TokenPair{accessToken = access, refreshToken = rawNew, expiresIn = cfg.accessTokenTTL}
                                    )
  where
    reuseDetected tok ts = do
        revokeRefreshTokenFamily tok.refreshTokenId ts
        revokeSession tok.sessionId ts
        publishAuthEvent
            (Event.RefreshTokenReuseDetected (Event.RefreshTokenReuseDetectedData tok.sessionId tok.refreshTokenId ts))
        pure (Left RefreshTokenReuseDetected)

logout ::
    ( SessionStore :> es
    , RefreshTokenStore :> es
    , AuthEventPublisher :> es
    , Clock :> es
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
    (TokenVerifier :> es, SessionStore :> es) =>
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
                mSession <- findSessionById claims.sessionId
                case mSession of
                    Nothing -> pure (Left SessionNotFound)
                    Just s
                        | s.status /= SessionActive -> pure (Left SessionRevoked)
                        | otherwise -> pure (Right claims)
