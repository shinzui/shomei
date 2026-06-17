{- | The shared token-issuing tail of the authentication workflows.

'issueSession' mints a fresh session + refresh token + signed access token for an
already-authenticated user and publishes 'LoginSucceeded' + 'SessionStarted'. It is the
exact tail that 'Shomei.Workflow.login' (non-MFA path), 'Shomei.Workflow.Mfa.completeMfa',
and 'Shomei.Workflow.Mfa.completePasswordlessLogin' share, factored out so the call sites
cannot drift. 'buildClaims' assembles the access-token claims for a fresh session.

This module is a leaf: it imports no passkey domain types, so it is free of the
@OverloadedRecordDot@/@HasField@ ambiguity that co-importing the passkey records triggers
(a MasterPlan-3 discovery). It exists as its own module to break the import cycle that
would otherwise form between 'Shomei.Workflow' (which calls 'issueSession') and
'Shomei.Workflow.Mfa' (which also calls 'issueSession'). 'Shomei.Workflow' re-exports
'issueSession' so the public interface remains @Shomei.Workflow.issueSession@.
-}
module Shomei.Workflow.Session (
    buildClaims,
    issueSession,
) where

import Shomei.Prelude

import Data.Set qualified as Set
import Data.Time (addUTCTime)

import Effectful (Eff, (:>))

import Shomei.Config (ShomeiConfig (..))
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.RefreshToken (NewRefreshToken (..))
import Shomei.Domain.Session (NewSession (..), Session (..))
import Shomei.Domain.Token (TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Id (SessionId, UserId)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore, createRefreshToken)
import Shomei.Effect.SessionStore (SessionStore, createSession)
import Shomei.Effect.TokenGen (TokenGen, generateOpaqueToken, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner, signAccessToken)

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
        , actor = Nothing
        }

{- | Mint a fresh session + refresh token + signed access token for an authenticated user,
publishing 'LoginSucceeded' and 'SessionStarted'. Returns the new session id alongside the
token pair so a caller (e.g. 'Shomei.Workflow.Mfa.completeMfa') can name the session in its
own audit event. The session id is fresh each call.
-}
issueSession ::
    ( SessionStore :> es
    , RefreshTokenStore :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    User ->
    UTCTime ->
    Eff es (SessionId, TokenPair)
issueSession cfg user ts = do
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
        ( session.sessionId
        , TokenPair{accessToken = access, refreshToken = rawToken, expiresIn = cfg.accessTokenTTL}
        )
